package io.github.chasekolozsy.devota

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

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
                else -> result.notImplemented()
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
