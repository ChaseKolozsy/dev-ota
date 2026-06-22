package io.github.chasekolozsy.devota

import android.content.Intent
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                else -> result.notImplemented()
            }
        }
    }
}
