package io.github.chasekolozsy.devota

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream

class ControlAgentService : Service() {
    companion object {
        const val DEFAULT_APP_PACKAGE = ""
        private const val PREFS = "control_agent"
        private const val EXTRA_URL = "url"
        private const val EXTRA_TOKEN = "token"
        private const val EXTRA_WHOLE = "allowWholeDevice"
        private const val CHANNEL_ID = "control_agent"
        private const val NOTIFICATION_ID = 24081

        @Volatile private var running = false
        @Volatile private var connected = false
        @Volatile private var lastError: String? = null
        @Volatile private var activeUrl: String? = null
        @Volatile private var wholeDeviceAllowed = false

        fun intent(context: Context, url: String, token: String, allowWholeDevice: Boolean): Intent =
            Intent(context, ControlAgentService::class.java)
                .putExtra(EXTRA_URL, url)
                .putExtra(EXTRA_TOKEN, token)
                .putExtra(EXTRA_WHOLE, allowWholeDevice)

        fun statusMap(context: Context): Map<String, Any?> {
            val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            return mapOf(
                "running" to running,
                "connected" to connected,
                "lastError" to lastError,
                "url" to (activeUrl ?: prefs.getString(EXTRA_URL, "")),
                "wholeDeviceAllowed" to wholeDeviceAllowed,
                "accessibility" to ControlAccessibilityService.statusJson().toMap(),
            )
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val client = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .build()

    private var webSocket: WebSocket? = null
    private var desiredStop = false
    private var url = ""
    private var token = ""
    private var deviceId = ""

    override fun onCreate() {
        super.onCreate()
        deviceId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            ?: UUID.randomUUID().toString()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        desiredStop = false
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        url = intent?.getStringExtra(EXTRA_URL)?.takeIf { it.isNotBlank() }
            ?: prefs.getString(EXTRA_URL, "").orEmpty()
        token = intent?.getStringExtra(EXTRA_TOKEN)?.takeIf { it.isNotBlank() }
            ?: prefs.getString(EXTRA_TOKEN, "").orEmpty()
        wholeDeviceAllowed = intent?.getBooleanExtra(EXTRA_WHOLE, prefs.getBoolean(EXTRA_WHOLE, false))
            ?: prefs.getBoolean(EXTRA_WHOLE, false)
        prefs.edit()
            .putString(EXTRA_URL, url)
            .putString(EXTRA_TOKEN, token)
            .putBoolean(EXTRA_WHOLE, wholeDeviceAllowed)
            .apply()

        activeUrl = url
        running = true
        startForeground(NOTIFICATION_ID, notification("Connecting to control relay"))
        connect()
        return START_STICKY
    }

    override fun onDestroy() {
        desiredStop = true
        running = false
        connected = false
        webSocket?.close(1000, "service stopped")
        webSocket = null
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun connect() {
        if (url.isBlank() || token.isBlank()) {
            lastError = "agent url and token are required"
            stopSelf()
            return
        }
        val request = Request.Builder()
            .url(webSocketUrl(url, token))
            .build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                connected = true
                lastError = null
                sendHello()
                sendStatus()
                updateNotification("Connected to control relay")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(webSocket, text)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                connected = false
                updateNotification("Control relay disconnected")
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                connected = false
                lastError = t.message ?: t.javaClass.simpleName
                updateNotification("Control relay connection failed")
                scheduleReconnect()
            }
        })
    }

    private fun scheduleReconnect() {
        if (desiredStop) return
        mainHandler.postDelayed({ if (!desiredStop && !connected) connect() }, 5000)
    }

    private fun handleMessage(socket: WebSocket, text: String) {
        val msg = try {
            JSONObject(text)
        } catch (e: Exception) {
            return
        }
        if (msg.optString("type") != "command") return
        val id = msg.optString("id")
        val action = msg.optString("action")
        val args = msg.optJSONObject("args") ?: JSONObject()
        executor.execute {
            try {
                val result = handleCommand(action, args)
                socket.send(JSONObject()
                    .put("id", id)
                    .put("ok", true)
                    .put("result", result)
                    .toString())
            } catch (e: Exception) {
                socket.send(JSONObject()
                    .put("id", id)
                    .put("ok", false)
                    .put("error", e.message ?: e.javaClass.simpleName)
                    .toString())
            }
        }
    }

    private fun handleCommand(action: String, args: JSONObject): JSONObject {
        return when (action) {
            "status" -> statusJson()
            "launchApp" -> launchApp(args.optString("packageName", DEFAULT_APP_PACKAGE))
            "launchIntent" -> launchIntent(args)
            "tap" -> ControlAccessibilityService.tap(
                args.getDouble("x"),
                args.getDouble("y"),
                args.optString("packageName", DEFAULT_APP_PACKAGE),
                wholeDeviceAllowed,
            )
            "longTap" -> ControlAccessibilityService.longTap(
                args.getDouble("x"),
                args.getDouble("y"),
                args.optLong("durationMs", 750),
                args.optString("packageName", DEFAULT_APP_PACKAGE),
                wholeDeviceAllowed,
            )
            "swipe" -> ControlAccessibilityService.swipe(
                args.getDouble("x1"),
                args.getDouble("y1"),
                args.getDouble("x2"),
                args.getDouble("y2"),
                args.optLong("durationMs", 300),
                args.optString("packageName", DEFAULT_APP_PACKAGE),
                wholeDeviceAllowed,
            )
            "typeText" -> ControlAccessibilityService.typeText(
                args.optString("text", ""),
                args.optString("packageName", DEFAULT_APP_PACKAGE),
                wholeDeviceAllowed,
            )
            "back" -> ControlAccessibilityService.globalAction(
                AccessibilityService.GLOBAL_ACTION_BACK,
                args.optString("packageName", DEFAULT_APP_PACKAGE),
                wholeDeviceAllowed,
            )
            "home" -> {
                requireWholeDevice()
                ControlAccessibilityService.globalAction(AccessibilityService.GLOBAL_ACTION_HOME, null, true)
            }
            "recents" -> {
                requireWholeDevice()
                ControlAccessibilityService.globalAction(AccessibilityService.GLOBAL_ACTION_RECENTS, null, true)
            }
            "openSettings" -> {
                requireWholeDevice()
                startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                JSONObject().put("ok", true)
            }
            "openUri" -> {
                requireWholeDevice()
                val uri = args.optString("uri")
                if (uri.isBlank()) throw IllegalArgumentException("uri is required")
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                JSONObject().put("ok", true).put("uri", uri)
            }
            "screenshot" -> ControlAccessibilityService.screenshot()
            "uiDump" -> ControlAccessibilityService.uiDump()
            "installFromBuild" -> installFromBuild(args)
            else -> throw IllegalArgumentException("unknown action: $action")
        }
    }

    private fun requireWholeDevice() {
        if (!wholeDeviceAllowed) {
            throw IllegalStateException("whole-device control is disabled in DevOTA")
        }
    }

    private fun launchApp(packageName: String): JSONObject {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: throw IllegalArgumentException("package has no launcher activity: $packageName")
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(launch)
        return JSONObject().put("ok", true).put("packageName", packageName)
    }

    private fun launchIntent(args: JSONObject): JSONObject {
        val packageName = args.optString("packageName", DEFAULT_APP_PACKAGE)
            .takeIf { it.isNotBlank() }
        if (packageName == null) requireWholeDevice()

        val action = args.optString("action").takeIf { it.isNotBlank() }
        val uri = args.optString("uri").takeIf { it.isNotBlank() }
        if (action == null && uri == null && packageName != null) {
            return launchApp(packageName)
        }

        val intent = Intent(action ?: if (uri != null) Intent.ACTION_VIEW else Intent.ACTION_MAIN)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (uri != null) intent.data = Uri.parse(uri)
        if (packageName != null) intent.setPackage(packageName)

        val extras = args.optJSONObject("extras") ?: JSONObject()
        val keys = extras.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            when (val value = extras.opt(key)) {
                is Boolean -> intent.putExtra(key, value)
                is Int -> intent.putExtra(key, value)
                is Long -> intent.putExtra(key, value)
                is Double -> intent.putExtra(key, value)
                is Float -> intent.putExtra(key, value)
                null -> {}
                JSONObject.NULL -> {}
                else -> intent.putExtra(key, value.toString())
            }
        }

        startActivity(intent)
        return JSONObject()
            .put("ok", true)
            .put("packageName", packageName)
            .put("action", intent.action)
            .put("uri", uri)
    }

    private fun installFromBuild(args: JSONObject): JSONObject {
        val base = args.optString("buildServerUrl").trimEnd('/')
        val relPath = args.optString("path")
        val filename = args.optString("filename")
        if (base.isBlank() || relPath.isBlank() || filename.isBlank()) {
            throw IllegalArgumentException("buildServerUrl, path, and filename are required")
        }
        val url = "$base/download/$relPath"
        val request = Request.Builder().url(url).build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IllegalStateException("download failed: HTTP ${response.code}")
            val body = response.body ?: throw IllegalStateException("download returned empty body")
            val installDir = File(cacheDir, "agent_installs").apply { mkdirs() }
            val apk = File(installDir, filename)
            val input = GZIPInputStream(body.byteStream())
            FileOutputStream(apk).use { output -> input.use { it.copyTo(output) } }
            openInstaller(apk)
            return JSONObject()
                .put("ok", true)
                .put("status", "awaiting_user_confirmation")
                .put("url", url)
                .put("apk", apk.absolutePath)
        }
    }

    private fun openInstaller(apk: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(intent)
    }

    private fun sendHello() {
        webSocket?.send(JSONObject()
            .put("type", "hello")
            .put("deviceId", deviceId)
            .put("packageName", packageName)
            .put("androidSdk", Build.VERSION.SDK_INT)
            .put("wholeDeviceAllowed", wholeDeviceAllowed)
            .put("accessibility", ControlAccessibilityService.statusJson())
            .toString())
    }

    private fun sendStatus() {
        webSocket?.send(JSONObject()
            .put("type", "status")
            .put("status", statusJson())
            .toString())
    }

    private fun statusJson(): JSONObject = JSONObject()
        .put("running", running)
        .put("connected", connected)
        .put("lastError", lastError)
        .put("url", activeUrl)
        .put("wholeDeviceAllowed", wholeDeviceAllowed)
        .put("accessibility", ControlAccessibilityService.statusJson())

    private fun webSocketUrl(rawUrl: String, token: String): String {
        val ws = when {
            rawUrl.startsWith("http://") -> "ws://" + rawUrl.removePrefix("http://")
            rawUrl.startsWith("https://") -> "wss://" + rawUrl.removePrefix("https://")
            else -> rawUrl
        }
        val sep = if (ws.contains("?")) "&" else "?"
        return ws + sep + "token=" + URLEncoder.encode(token, "UTF-8")
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.createNotificationChannel(NotificationChannel(
            CHANNEL_ID,
            "DevOTA Control Agent",
            NotificationManager.IMPORTANCE_LOW,
        ))
    }

    private fun updateNotification(text: String) {
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("DevOTA Agent")
            .setContentText(text)
            .setOngoing(true)
            .build()
    }
}

private fun JSONObject.toMap(): Map<String, Any?> {
    val out = linkedMapOf<String, Any?>()
    val keys = keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val value = get(key)
        out[key] = if (value is JSONObject) value.toMap() else value
    }
    return out
}
