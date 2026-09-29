package io.github.chasekolozsy.devota.voice

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import io.github.chasekolozsy.devota.MainActivity
import io.github.chasekolozsy.devota.SshSessionService

/**
 * The devota/passive_voice channel. Dart owns the switch and the meaning of
 * every utterance; this side only starts and stops the service (through
 * [StartGate]), relays transcripts, speaks, and reports state.
 */
internal object PassiveVoice {
    /** Activity intent from the notification switch: open DevOTA and turn listening on. */
    const val ACTION_LISTEN = "io.github.chasekolozsy.devota.voice.LISTEN"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    @Volatile
    var activityResumed = false
        private set
    private var startRequested = false

    val attached get() = channel != null

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
                        result.error("refused", "Passive listening needs Android 8 or newer", null)
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
                        PassiveVoiceService.start(
                            ctx,
                            call.argument<Boolean>("quietBeeps") ?: true,
                            call.argument<String>("status") ?: "Listening",
                        )
                        result.success(true)
                    }
                }
                "stop" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        PassiveVoiceService.stop(ctx, "Passive listening is off")
                    }
                    result.success(null)
                }
                "speak" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) PassiveVoiceService.instance?.speak(call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "update" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) PassiveVoiceService.instance?.updateStatus(call.argument<String>("status") ?: "")
                    result.success(null)
                }
                "isRunning" -> result.success(running)
                "consumeStartRequest" -> {
                    val requested = startRequested
                    startRequested = false
                    result.success(requested)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The engine is going away: nothing can decide what speech means. */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext?.let { PassiveVoiceService.stop(it, "DevOTA was closed") }
        }
    }

    fun setResumed(resumed: Boolean) {
        activityResumed = resumed
        if (resumed && startRequested) offerStartRequest()
    }

    /** Called with every intent MainActivity receives. */
    fun handleIntent(intent: Intent?) {
        if (intent?.action != ACTION_LISTEN) return
        startRequested = true
        if (activityResumed) offerStartRequest()
    }

    private fun offerStartRequest() {
        val ch = channel ?: return
        ch.invokeMethod("startRequested", null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                startRequested = false
            }

            // Dart not listening yet: it asks with consumeStartRequest later.
            override fun error(code: String, message: String?, details: Any?) = Unit
            override fun notImplemented() = Unit
        })
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

    fun onServiceChanged() {
        SshSessionService.refreshControls()
    }

    fun onServiceStopped(reason: String) {
        channel?.invokeMethod("stopped", mapOf("reason" to reason))
        SshSessionService.refreshControls()
    }

    /** The switch in the SSH session notification. */
    val running get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && PassiveVoiceService.running

    fun sessionAction(context: Context): Notification.Action {
        if (running) {
            return Notification.Action.Builder(null, "Stop listening", PassiveVoiceService.stopIntent(context)).build()
        }
        val open = Intent(context, MainActivity::class.java)
            .setAction(ACTION_LISTEN)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(
            context, 24092, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Action.Builder(null, "Passive listening", pending).build()
    }

    fun dispatch(context: Context, intent: Intent) {
        if (intent.getStringExtra("voiceAction") == "stop" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PassiveVoiceService.stop(context, "Stopped from the notification")
        }
    }
}
