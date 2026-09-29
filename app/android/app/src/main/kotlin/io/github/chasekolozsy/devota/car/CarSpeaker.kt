package io.github.chasekolozsy.devota.car

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.io.File
import java.util.Locale

/**
 * Car-mode speech. The TTS engine only SYNTHESISES to a file; DevOTA's own
 * MediaPlayer plays it, so DevOTA is the app that "played audio locally" and
 * keeps the car's AVRCP buttons (proposal F1-F4). Offline voices only, the
 * same rule as TerminalSpeech. Transient ducking focus, never AUDIOFOCUS_GAIN.
 * Text is held in memory and in one short-lived cache file per utterance,
 * deleted after playback; it is never logged.
 */
internal class CarSpeaker(private val ctx: Context, private val listener: Listener) {
    interface Listener {
        fun onSpeechDone(id: String, ok: Boolean)
        fun onSpeakerEvent(event: String, detail: Map<String, Any?>)
        fun onPlayingChanged(playing: Boolean)
        fun onFocusLost(change: Int)
        fun inCall(): Boolean
    }

    private data class Item(val text: String, val id: String, val at: Long)

    private val handler = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ready = false
    private var initializing = false
    private var generation = 0
    private val queue = ArrayDeque<Item>()
    private var current: Item? = null
    private var player: MediaPlayer? = null
    private var currentFile: File? = null
    private var focus: AudioFocusRequest? = null
    private var seq = 0
    private val tracks = mutableListOf<AudioTrack>()
    @Volatile var lastAudioAt = 0L
        private set
    val playing get() = current != null

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        handler.post {
            listener.onSpeakerEvent("focus_change", mapOf("change" to focusName(change)))
            if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                stop()
                listener.onFocusLost(change)
            }
        }
    }

    fun speak(text: String, id: String, interrupt: Boolean) {
        if (interrupt) stop()
        if (text.isBlank()) {
            listener.onSpeechDone(id, false)
            return
        }
        queue.addLast(Item(text.take(4000), id, SystemClock.elapsedRealtime()))
        ensureEngine()
        pump()
    }

    private fun ensureEngine() {
        if (tts != null || initializing) return
        initializing = true
        val gen = ++generation
        tts = TextToSpeech(ctx.applicationContext) { status ->
            handler.post {
                if (gen != generation) return@post
                initializing = false
                ready = status == TextToSpeech.SUCCESS
                if (ready) pump() else {
                    listener.onSpeakerEvent("speak_error", mapOf("error" to "engine_unavailable"))
                    clearQueue()
                    tts?.shutdown()
                    tts = null
                }
            }
        }
    }

    private fun pump() {
        if (!ready || current != null) return
        val now = SystemClock.elapsedRealtime()
        var next: Item? = null
        while (next == null) {
            val candidate = queue.removeFirstOrNull() ?: return
            if (now - candidate.at > 5000) listener.onSpeechDone(candidate.id, false) else next = candidate
        }
        val item = next ?: return
        current = item
        val engine = tts ?: return finish(item, false, "engine_unavailable")
        val voice = try {
            engine.voices?.filter { !it.isNetworkConnectionRequired }
                ?.firstOrNull { it.locale.language == Locale.getDefault().language }
                ?: engine.voices?.firstOrNull { !it.isNetworkConnectionRequired && it.locale.language == "en" }
        } catch (_: Exception) { null }
        if (voice == null) return finish(item, false, "no_offline_voice")
        engine.voice = voice
        val dir = File(ctx.cacheDir, "car_speech").apply { mkdirs() }
        val file = File(dir, "s${++seq}.wav")
        currentFile = file
        val utterance = "car-$seq"
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = Unit
            override fun onDone(utteranceId: String?) {
                handler.post { if (utteranceId == utterance && current === item) play(item, file) }
            }
            @Deprecated("Legacy TTS callback")
            @Suppress("OVERRIDE_DEPRECATION")
            override fun onError(utteranceId: String?) {
                handler.post { if (utteranceId == utterance && current === item) finish(item, false, "synth_error") }
            }
            override fun onError(utteranceId: String?, errorCode: Int) {
                handler.post { if (utteranceId == utterance && current === item) finish(item, false, "synth_error_$errorCode") }
            }
        })
        listener.onSpeakerEvent("speak_start", mapOf("id" to item.id, "chars" to item.text.length))
        val result = try { engine.synthesizeToFile(item.text, Bundle(), file, utterance) } catch (_: Exception) { TextToSpeech.ERROR }
        if (result == TextToSpeech.ERROR) finish(item, false, "synth_error")
    }

    private fun attributes(): AudioAttributes = if (listener.inCall()) {
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    } else {
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    }

    private fun play(item: Item, file: File) {
        if (!takeFocus()) return finish(item, false, "focus_denied")
        val mp = MediaPlayer()
        try {
            mp.setAudioAttributes(attributes())
            mp.setDataSource(file.absolutePath)
            mp.setOnCompletionListener { handler.post { if (player === mp) finish(item, true, null) } }
            mp.setOnErrorListener { _, what, _ ->
                handler.post { if (player === mp) finish(item, false, "player_error_$what") }
                true
            }
            mp.prepare()
            player = mp
            mp.start()
            lastAudioAt = SystemClock.elapsedRealtime()
            listener.onPlayingChanged(true)
        } catch (error: Exception) {
            mp.release()
            if (player === mp) player = null
            finish(item, false, "player_${error.javaClass.simpleName}")
        }
    }

    private fun finish(item: Item, ok: Boolean, error: String?) {
        if (current !== item) return
        current = null
        releasePlayer()
        abandonFocus()
        lastAudioAt = SystemClock.elapsedRealtime()
        listener.onPlayingChanged(false)
        listener.onSpeakerEvent(if (ok) "speak_done" else "speak_error",
            mapOf("id" to item.id, "error" to error))
        listener.onSpeechDone(item.id, ok)
        pump()
    }

    private fun releasePlayer() {
        player?.let { p ->
            try { p.stop() } catch (_: Exception) {}
            p.release()
        }
        player = null
        currentFile?.delete()
        currentFile = null
    }

    private fun clearQueue() {
        while (true) {
            val item = queue.removeFirstOrNull() ?: break
            listener.onSpeechDone(item.id, false)
        }
    }

    /** Immediate stop; the current and every queued id complete with ok=false. */
    fun stop() {
        val item = current
        current = null
        try { tts?.stop() } catch (_: Exception) {}
        val wasPlaying = player != null
        releasePlayer()
        abandonFocus()
        if (item != null) {
            if (wasPlaying) listener.onPlayingChanged(false)
            listener.onSpeechDone(item.id, false)
        }
        clearQueue()
    }

    fun earcon(kind: String) {
        val pcm = CarTones.pcm(if (CarTones.known(kind)) kind else "tick")
        try {
            val track = if (Build.VERSION.SDK_INT >= 23) {
                AudioTrack.Builder()
                    .setAudioAttributes(attributes())
                    .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(CarTones.RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .setBufferSizeInBytes(pcm.size * 2)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                AudioTrack(AudioManager.STREAM_MUSIC, CarTones.RATE, AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT, pcm.size * 2, AudioTrack.MODE_STATIC)
            }
            track.write(pcm, 0, pcm.size)
            track.play()
            tracks.add(track)
            lastAudioAt = SystemClock.elapsedRealtime()
            val ms = pcm.size * 1000L / CarTones.RATE
            handler.postDelayed({
                tracks.remove(track)
                try { track.stop() } catch (_: Exception) {}
                track.release()
            }, ms + 150)
            listener.onSpeakerEvent("earcon", mapOf("kind" to kind))
        } catch (error: Exception) {
            listener.onSpeakerEvent("speak_error", mapOf("error" to "earcon_${error.javaClass.simpleName}"))
        }
    }

    private fun takeFocus(): Boolean {
        val manager = ctx.getSystemService(AudioManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attributes()).setOnAudioFocusChangeListener(focusListener, handler).build()
            focus = request
            manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        val manager = ctx.getSystemService(AudioManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) focus?.let { manager.abandonAudioFocusRequest(it) }
        else { @Suppress("DEPRECATION") manager.abandonAudioFocus(focusListener) }
        focus = null
    }

    fun shutdown() {
        stop()
        generation++
        initializing = false
        ready = false
        tts?.shutdown()
        tts = null
        tracks.toList().forEach { try { it.release() } catch (_: Exception) {} }
        tracks.clear()
    }

    private fun focusName(change: Int) = when (change) {
        AudioManager.AUDIOFOCUS_GAIN -> "gain"
        AudioManager.AUDIOFOCUS_LOSS -> "loss"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "loss transient"
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "duck"
        else -> change.toString()
    }
}
