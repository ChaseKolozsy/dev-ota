package io.github.chasekolozsy.devota

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Phone TTS only. Terminal text stays in memory and is never logged. */
internal object TerminalSpeech {
    private val handler = Handler(Looper.getMainLooper())
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private var engine: TextToSpeech? = null
    private var ready = false
    private var initializing = false
    private var pending: (() -> Unit)? = null
    private var pendingResult: MethodChannel.Result? = null
    private var focus: AudioFocusRequest? = null
    private var epoch = 0
    private var title = "Terminal conclusion"
    private var earlier = false
    private var active = false
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change < 0) handler.post {
            stop()
            channel?.invokeMethod("readerAction", mapOf("action" to "interrupted"))
        }
    }

    fun attach(ctx: Context, bridge: MethodChannel) {
        context = ctx.applicationContext
        channel = bridge
    }

    fun speak(text: String, label: String, hasEarlier: Boolean, result: MethodChannel.Result) {
        if (text.isBlank() || text.length > 24000) {
            result.error("speech", "No readable text or excerpt too long", null); return
        }
        val ctx = context ?: run { result.error("speech", "Speech unavailable", null); return }
        stop()
        title = label.take(100)
        earlier = hasEarlier
        val current = epoch
        val play = {
            if (current != epoch) {
                result.error("speech", "Reading cancelled", null)
            } else {
                val tts = engine!!
                val voice = tts.voices?.filter { !it.isNetworkConnectionRequired }
                    ?.firstOrNull { it.locale.language == Locale.getDefault().language }
                    ?: tts.voices?.firstOrNull { !it.isNetworkConnectionRequired && it.locale.language == "en" }
                if (!ready || voice == null) {
                    result.error("speech", "Install an offline Android text-to-speech voice", null)
                } else if (!takeFocus(ctx)) {
                    result.error("speech", "Audio is in use", null)
                } else {
                    tts.voice = voice
                    tts.setAudioAttributes(attributes)
                    val chunks = splitText(text)
                    active = true
                    tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(id: String?) {}
                        override fun onDone(id: String?) {
                            if (id != "$current:${chunks.lastIndex}") return
                            handler.post { if (current == epoch) {
                                abandonFocus(); show("Finished reading")
                            } }
                        }
                        @Deprecated("Legacy TTS callback")
                        override fun onError(id: String?) {
                            handler.post { if (current == epoch) {
                                abandonFocus(); show("Speech failed · try Replay")
                            } }
                        }
                    })
                    var ok = true
                    chunks.forEachIndexed { index, chunk ->
                        if (tts.speak(chunk, TextToSpeech.QUEUE_ADD, null, "$current:$index") == TextToSpeech.ERROR) ok = false
                    }
                    if (ok) { show("Reading conclusion"); result.success(null) }
                    else { stop(); result.error("speech", "Speech playback failed", null) }
                }
            }
        }
        if (ready) { play(); return }
        pendingResult = result
        pending = play
        if (!initializing) {
            initializing = true
            engine = TextToSpeech(ctx) { status -> handler.post {
                initializing = false
                ready = status == TextToSpeech.SUCCESS
                val callback = pending
                val reply = pendingResult
                pending = null
                pendingResult = null
                if (ready) callback?.invoke()
                else { reply?.error("speech", "Android speech engine unavailable", null) }
            } }
        }
    }

    internal fun splitText(text: String): List<String> {
        val limit = minOf(TextToSpeech.getMaxSpeechInputLength() - 1, 2500)
        val result = mutableListOf<String>()
        var rest = text
        while (rest.isNotEmpty()) {
            var end = minOf(rest.length, limit)
            if (end < rest.length) {
                val space = rest.lastIndexOf(' ', end)
                if (space > limit / 2) end = space
                if (end > 0 && Character.isHighSurrogate(rest[end - 1])) end--
            }
            result.add(rest.substring(0, end))
            rest = rest.substring(end).trimStart()
        }
        return result
    }

    private fun takeFocus(ctx: Context): Boolean {
        val manager = ctx.getSystemService(AudioManager::class.java)
        return if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attributes).setOnAudioFocusChangeListener(focusListener).build()
            focus = request
            manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        val manager = context?.getSystemService(AudioManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) focus?.let { manager.abandonAudioFocusRequest(it) }
        else { @Suppress("DEPRECATION") manager.abandonAudioFocus(focusListener) }
        focus = null
    }

    fun stop() {
        epoch++
        pending = null
        pendingResult?.error("speech", "Reading cancelled", null)
        pendingResult = null
        engine?.stop()
        abandonFocus()
        active = false
        context?.getSystemService(NotificationManager::class.java)?.cancel("terminal-reader", 0)
    }

    fun detach() {
        stop(); engine?.shutdown(); engine = null; ready = false; channel = null; context = null
    }

    private fun show(status: String) {
        val ctx = context ?: return
        val manager = ctx.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(
            "terminal_reader", "Terminal read aloud", NotificationManager.IMPORTANCE_LOW))
        val builder = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, "terminal_reader")
            else @Suppress("DEPRECATION") Notification.Builder(ctx))
            .setSmallIcon(ctx.applicationInfo.icon).setContentTitle("Listen · $title")
            .setContentText(status).setOnlyAlertOnce(true).setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        for ((action, label) in listOf("earlier" to "Earlier", "replay" to "Replay", "stopReading" to "Stop")) {
            if (action == "earlier" && !earlier) continue
            val intent = Intent(ctx, TerminalActionReceiver::class.java)
                .setData(Uri.parse("devota-reader://$action/$epoch"))
                .putExtra("readerAction", action).putExtra("readerEpoch", epoch)
            val pi = PendingIntent.getBroadcast(ctx, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, label, pi).build())
        }
        manager.notify("terminal-reader", 0, builder.build())
    }

    fun dispatch(intent: Intent) {
        if (!active || intent.getIntExtra("readerEpoch", -1) != epoch) return
        val action = intent.getStringExtra("readerAction") ?: return
        if (action !in listOf("earlier", "replay", "stopReading")) return
        if (action == "stopReading") stop()
        channel?.invokeMethod("readerAction", mapOf("action" to action))
    }
}
