package io.github.chasekolozsy.devota.voice

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * The devota/voice_control channel behind the Terminal tab's "Voice control"
 * toggle. Dart owns the toggle and the meaning of every utterance (it runs
 * the Terminal tab's own button handlers); this side only starts and stops
 * the service (through [StartGate]), relays transcripts, speaks, and reports
 * state. There is no other way to start it: no notification switch, no
 * start-on-boot, no restart after the process dies.
 */
internal object VoiceControl {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    @Volatile
    var activityResumed = false
        private set

    fun attach(context: Context, methodChannel: MethodChannel) {
        appContext = context.applicationContext
        channel = methodChannel
        if (!running) BeepQuieter.recover(context.applicationContext)
        methodChannel.setMethodCallHandler { call, result ->
            val ctx = appContext
            if (ctx == null) {
                result.error("detached", "DevOTA is closing", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "start" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.error("refused", "Voice control needs Android 8 or newer", null)
                        return@setMethodCallHandler
                    }
                    val refusal = StartGate.refusal(
                        switchOn = true,
                        appVisible = activityResumed,
                        micGranted = ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) ==
                            PackageManager.PERMISSION_GRANTED,
                        recognizerAvailable = try {
                            SpeechRecognizer.isRecognitionAvailable(ctx)
                        } catch (_: Exception) {
                            false
                        },
                    )
                    if (refusal != null) {
                        result.error("refused", refusal, null)
                    } else {
                        VoiceControlService.start(
                            ctx,
                            call.argument<Boolean>("quietBeeps") ?: true,
                            call.argument<String>("status") ?: "",
                        )
                        result.success(true)
                    }
                }
                "stop" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        VoiceControlService.stop(ctx, "Voice control is off")
                    }
                    result.success(null)
                }
                "speak" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        VoiceControlService.instance?.speak(call.argument<String>("text") ?: "")
                    }
                    result.success(null)
                }
                "update" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        VoiceControlService.instance?.updateStatus(call.argument<String>("status") ?: "")
                    }
                    result.success(null)
                }
                "isRunning" -> result.success(running)
                else -> result.notImplemented()
            }
        }
    }

    /** The engine is going away: nothing can decide what speech means. */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext?.let { VoiceControlService.stop(it, "DevOTA was closed") }
        }
    }

    fun setResumed(resumed: Boolean) {
        activityResumed = resumed
    }

    /** False when Dart is gone (the service then stops). */
    fun deliverUtterance(text: String, reply: (Map<*, *>?) -> Unit): Boolean {
        val ch = channel ?: return false
        ch.invokeMethod("utterance", mapOf("text" to text), object : MethodChannel.Result {
            override fun success(result: Any?) = reply(result as? Map<*, *> ?: emptyMap<String, Any?>())
            override fun error(code: String, message: String?, details: Any?) =
                reply(emptyMap<String, Any?>())
            override fun notImplemented() = reply(null)
        })
        return true
    }

    fun onState(label: String) {
        channel?.invokeMethod("state", mapOf("state" to label))
    }

    fun onServiceStopped(reason: String) {
        channel?.invokeMethod("stopped", mapOf("reason" to reason))
    }

    val running get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && VoiceControlService.running

    /** The Stop action in the "DevOTA · Voice control" notification. */
    fun dispatch(context: Context, intent: Intent) {
        if (intent.getStringExtra("voiceAction") == "stop" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            VoiceControlService.stop(context, "Stopped from the notification")
        }
    }
}
