package io.github.chasekolozsy.devota

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "io.github.chasekolozsy.devota/control_agent"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAgent" -> {
                    val url = call.argument<String>("url")?.trim().orEmpty()
                    val token = call.argument<String>("token")?.trim().orEmpty()
                    val allowWholeDevice = call.argument<Boolean>("allowWholeDevice") ?: false
                    if (url.isEmpty() || token.isEmpty()) {
                        result.error("bad_args", "url and token are required", null)
                        return@setMethodCallHandler
                    }
                    val intent = ControlAgentService.intent(this, url, token, allowWholeDevice)
                    ContextCompat.startForegroundService(this, intent)
                    result.success(true)
                }
                "stopAgent" -> {
                    stopService(Intent(this, ControlAgentService::class.java))
                    result.success(true)
                }
                "getAgentStatus" -> result.success(ControlAgentService.statusMap(this))
                "runDeviceAction" -> {
                    val action = call.argument<String>("action")?.trim().orEmpty()
                    val rawArgs = call.argument<Map<String, Any?>>("args") ?: emptyMap()
                    if (action.isEmpty()) {
                        result.error("bad_args", "action is required", null)
                        return@setMethodCallHandler
                    }
                    val allowWholeDevice = ControlAgentService.statusMap(this)["wholeDeviceAllowed"] == true
                    Thread {
                        try {
                            val value = if (action == "hostCommand") {
                                ControlAgentService.executeHostMacroCommand(JSONObject(rawArgs))
                            } else {
                                ControlAgentService.executeLocalCommand(
                                    this,
                                    action,
                                    JSONObject(rawArgs),
                                    allowWholeDevice,
                                )
                            }
                            runOnUiThread { result.success(jsonObjectToMap(value)) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error(
                                    "device_action_failed",
                                    error.message ?: error.javaClass.simpleName,
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                "startSshSession" -> {
                    val label = call.argument<String>("label")?.trim().orEmpty()
                    SshSessionService.start(this, label)
                    result.success(true)
                }
                "stopSshSession" -> {
                    SshSessionService.stop(this)
                    result.success(true)
                }
                "isSshSessionServiceRunning" -> result.success(SshSessionService.isRunning())
                "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                "requestIgnoreBatteryOptimizations" -> {
                    result.success(requestIgnoreBatteryOptimizations())
                }
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(true)
                }
                "isPackageInstalled" -> {
                    val packageName = call.argument<String>("packageName")?.trim().orEmpty()
                    if (packageName.isEmpty()) {
                        result.error("bad_args", "packageName is required", null)
                        return@setMethodCallHandler
                    }
                    result.success(isPackageInstalled(packageName))
                }
                "openPackage" -> {
                    val packageName = call.argument<String>("packageName")?.trim().orEmpty()
                    if (packageName.isEmpty()) {
                        result.error("bad_args", "packageName is required", null)
                        return@setMethodCallHandler
                    }
                    val intent = packageManager.getLaunchIntentForPackage(packageName)
                    if (intent == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    startActivity(intent)
                    result.success(true)
                }
                "openAppStore" -> {
                    val packageName = call.argument<String>("packageName")?.trim().orEmpty()
                    if (packageName.isEmpty()) {
                        result.error("bad_args", "packageName is required", null)
                        return@setMethodCallHandler
                    }
                    openAppStore(packageName)
                    result.success(true)
                }
                "discoverDevotaServers" -> {
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 3500
                    discoverDevotaServers(timeoutMs.coerceIn(1000, 15000), result)
                }
                "saveToDownloads" -> {
                    val filename = call.argument<String>("filename")?.trim().orEmpty()
                    val sourcePath = call.argument<String>("sourcePath")?.trim().orEmpty()
                    val mimeType = call.argument<String>("mimeType")?.trim().orEmpty()
                    if (filename.isEmpty() || sourcePath.isEmpty()) {
                        result.error("bad_args", "filename and sourcePath are required", null)
                        return@setMethodCallHandler
                    }
                    saveToDownloads(filename, sourcePath, mimeType, result)
                }
                "extractZipToDownloads" -> {
                    val zipPath = call.argument<String>("zipPath")?.trim().orEmpty()
                    val topName = call.argument<String>("topName")?.trim().orEmpty()
                    if (zipPath.isEmpty() || topName.isEmpty()) {
                        result.error("bad_args", "zipPath and topName are required", null)
                        return@setMethodCallHandler
                    }
                    extractZipToDownloads(zipPath, topName, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.opt(it)) }
        else -> value
    }

    private fun jsonObjectToMap(value: JSONObject): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>()
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            out[key] = jsonValue(value.opt(key))
        }
        return out
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * Doze/App Standby can still stall an idle session even with a foreground
     * service holding the process, so offer the exemption dialog. Falls back to
     * the system list if the direct prompt is unavailable on this build.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
            )
            true
        } catch (_: ActivityNotFoundException) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (_: ActivityNotFoundException) {
                false
            }
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0)
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun saveToDownloads(
        filename: String,
        sourcePath: String,
        mimeType: String,
        result: MethodChannel.Result,
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        Thread {
            try {
                val source = File(sourcePath)
                if (!source.isFile) {
                    throw IllegalArgumentException("source file not found")
                }
                val effectiveMime = if (mimeType.isNotEmpty()) mimeType else "application/octet-stream"
                val savedLabel: String
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val resolver = contentResolver
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, filename)
                        put(MediaStore.Downloads.MIME_TYPE, effectiveMime)
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("could not create a Downloads entry")
                    resolver.openOutputStream(uri).use { output ->
                        if (output == null) throw IllegalStateException("could not open the Downloads stream")
                        source.inputStream().use { input -> input.copyTo(output) }
                    }
                    val done = ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    }
                    resolver.update(uri, done, null, null)
                    savedLabel = "Downloads/$filename"
                } else {
                    @Suppress("DEPRECATION")
                    val downloads = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    if (!downloads.exists()) downloads.mkdirs()
                    val dest = File(downloads, filename)
                    source.inputStream().use { input ->
                        dest.outputStream().use { output -> input.copyTo(output) }
                    }
                    savedLabel = "Downloads/${dest.name}"
                }
                mainHandler.post { result.success(savedLabel) }
            } catch (e: Exception) {
                mainHandler.post { result.error("save_failed", e.message, null) }
            }
        }.start()
    }

    private fun sanitizeFolderName(name: String): String {
        val base = name.substringAfterLast('/').substringAfterLast('\\').trim()
        val cleaned = base.replace(Regex("[^A-Za-z0-9._-]+"), "-").trim('-', '.')
        return if (cleaned.isEmpty()) "download" else cleaned
    }

    private fun guessMimeForName(name: String): String {
        return when (name.substringAfterLast('.', "").lowercase()) {
            "txt", "md", "log", "csv" -> "text/plain"
            "json" -> "application/json"
            "xml" -> "application/xml"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "svg" -> "image/svg+xml"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            "html", "htm" -> "text/html"
            "mp3" -> "audio/mpeg"
            "mp4" -> "video/mp4"
            else -> "application/octet-stream"
        }
    }

    private fun extractZipToDownloads(
        zipPath: String,
        topName: String,
        result: MethodChannel.Result,
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        Thread {
            try {
                ZipFile(zipPath).use { zf ->
                    val entries = zf.entries().toList().filter { !it.isDirectory }
                    if (entries.isEmpty()) {
                        throw IllegalArgumentException("archive has no files")
                    }
                    val names = entries.map { it.name.replace('\\', '/') }
                    for (n in names) {
                        if (n.split('/').any { it == ".." }) {
                            throw IllegalArgumentException("unsafe path in archive: $n")
                        }
                    }

                    // Common-root detection: if every entry shares the same first
                    // path segment, use it as the folder and strip it; otherwise
                    // wrap everything under the caller-supplied topName so loose
                    // files never land directly in Downloads.
                    val firstSegs = names.map { it.substringBefore('/') }.toSet()
                    val hasCommonRoot = firstSegs.size == 1 &&
                        firstSegs.first().isNotEmpty() &&
                        names.all { it.contains('/') }
                    val folderName = sanitizeFolderName(
                        if (hasCommonRoot) firstSegs.first() else topName
                    )
                    val stripPrefix = if (hasCommonRoot) firstSegs.first() + "/" else ""

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        deleteDownloadsFolder(folderName)
                    }

                    var count = 0
                    for (entry in entries) {
                        val rel = entry.name.replace('\\', '/').removePrefix(stripPrefix).trim('/')
                        if (rel.isEmpty()) continue
                        val leaf = rel.substringAfterLast('/')
                        val relDirs = if (rel.contains('/')) rel.substringBeforeLast('/') else ""
                        writeEntryToDownloads(zf, entry, folderName, relDirs, leaf)
                        count++
                    }
                    val label = "Downloads/$folderName/ ($count file${if (count == 1) "" else "s"})"
                    mainHandler.post { result.success(label) }
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("extract_failed", e.message, null) }
            }
        }.start()
    }

    private fun deleteDownloadsFolder(folderName: String) {
        try {
            val where = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR " +
                "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
            val args = arrayOf("Download/$folderName/", "Download/$folderName/%")
            contentResolver.delete(MediaStore.Downloads.EXTERNAL_CONTENT_URI, where, args)
        } catch (_: Exception) {
            // Best effort; duplicates are preferable to a failed extraction.
        }
    }

    private fun writeEntryToDownloads(
        zf: ZipFile,
        entry: ZipEntry,
        folderName: String,
        relDirs: String,
        leaf: String,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val relativePath = if (relDirs.isEmpty()) {
                "Download/$folderName"
            } else {
                "Download/$folderName/$relDirs"
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, leaf)
                put(MediaStore.MediaColumns.MIME_TYPE, guessMimeForName(leaf))
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("could not create $leaf in Downloads")
            contentResolver.openOutputStream(uri).use { output ->
                if (output == null) throw IllegalStateException("could not open a stream for $leaf")
                zf.getInputStream(entry).use { input -> input.copyTo(output) }
            }
            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            contentResolver.update(uri, done, null, null)
        } else {
            @Suppress("DEPRECATION")
            val downloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            val destDir = if (relDirs.isEmpty()) {
                File(downloads, folderName)
            } else {
                File(File(downloads, folderName), relDirs)
            }
            if (!destDir.exists()) destDir.mkdirs()
            val dest = File(destDir, leaf)
            zf.getInputStream(entry).use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
        }
    }

    private fun openAppStore(packageName: String) {
        val marketIntent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("market://details?id=$packageName")
        ).apply {
            setPackage("com.android.vending")
        }
        try {
            startActivity(marketIntent)
            return
        } catch (_: ActivityNotFoundException) {
            // Fall through to the web Play Store.
        }
        val webIntent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://play.google.com/store/apps/details?id=$packageName")
        )
        startActivity(webIntent)
    }

    private fun discoverDevotaServers(timeoutMs: Int, result: MethodChannel.Result) {
        val nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
        val handler = Handler(Looper.getMainLooper())
        val found = linkedMapOf<String, Map<String, Any>>()
        var finished = false
        lateinit var discoveryListener: NsdManager.DiscoveryListener

        fun finish() {
            if (finished) return
            finished = true
            try {
                nsdManager.stopServiceDiscovery(discoveryListener)
            } catch (_: Exception) {
            }
            result.success(found.values.toList())
        }

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                finish()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (serviceInfo.serviceType != "_devota._tcp.") return
                nsdManager.resolveService(
                    serviceInfo,
                    object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit

                        override fun onServiceResolved(resolved: NsdServiceInfo) {
                            val address = resolved.host
                            val host = when (address) {
                                is Inet4Address -> address.hostAddress
                                else -> address?.hostAddress
                            } ?: return
                            if (resolved.port <= 0) return
                            val url = "http://$host:${resolved.port}"
                            found[url] = mapOf(
                                "name" to resolved.serviceName,
                                "host" to host,
                                "port" to resolved.port,
                                "url" to url,
                            )
                        }
                    }
                )
            }
        }

        try {
            nsdManager.discoverServices("_devota._tcp.", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
            handler.postDelayed({ finish() }, timeoutMs.toLong())
        } catch (e: Exception) {
            result.error("discovery_failed", e.message, null)
        }
    }
}
