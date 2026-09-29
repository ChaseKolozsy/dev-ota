package io.github.chasekolozsy.devota.car

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * Android speech recognition for car mode: live listening for commands, and
 * (API 33+) the on-device fallback for a held dictation buffer via
 * EXTRA_AUDIO_SOURCE. Must be used on the main thread. Recognized text is
 * returned to Dart only; it is never logged.
 */
internal class CarRecognizer(
    private val ctx: Context,
    private val log: (String, Map<String, Any?>) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var pending: ((Map<String, Any?>) -> Unit)? = null
    private var timeout: Runnable? = null
    private var pipe: Array<ParcelFileDescriptor>? = null

    fun available(): Boolean = try { SpeechRecognizer.isRecognitionAvailable(ctx) } catch (_: Exception) { false }

    fun onDeviceAvailable(): Boolean = Build.VERSION.SDK_INT >= 31 &&
        try { SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx) } catch (_: Exception) { false }

    val busy get() = pending != null

    private fun baseIntent(language: String?) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, ctx.packageName)
        if (!language.isNullOrBlank()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
    }

    fun listen(biasing: List<String>, timeoutMs: Long, language: String?, reply: (Map<String, Any?>) -> Unit) {
        if (pending != null) return reply(mapOf("error" to "busy"))
        if (!available() && !onDeviceAvailable()) return reply(mapOf("error" to "unavailable"))
        val intent = baseIntent(language)
        if (Build.VERSION.SDK_INT >= 33 && biasing.isNotEmpty()) {
            intent.putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(biasing.take(100)))
        }
        start(intent, timeoutMs.coerceIn(2000L, 60000L), "listen", reply)
    }

    fun recognizeRecording(pcm: ByteArray?, language: String?, reply: (Map<String, Any?>) -> Unit) {
        if (Build.VERSION.SDK_INT < 33) return reply(mapOf("error" to "unsupported"))
        if (pcm == null || pcm.isEmpty()) return reply(mapOf("error" to "no_recording"))
        if (pending != null) return reply(mapOf("error" to "busy"))
        if (!available() && !onDeviceAvailable()) return reply(mapOf("error" to "unavailable"))
        val fds = try { ParcelFileDescriptor.createPipe() } catch (error: Exception) {
            return reply(mapOf("error" to "other:pipe"))
        }
        pipe = fds
        val intent = baseIntent(language).apply {
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, fds[0])
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, CarWav.SAMPLE_RATE)
        }
        Thread({
            try {
                ParcelFileDescriptor.AutoCloseOutputStream(fds[1]).use { it.write(pcm) }
            } catch (_: Exception) {
                // The recognizer closed its end early; the result path reports it.
            }
        }, "devota-car-recognizer-feed").start()
        // A piped source may be consumed at about real time: allow the clip's
        // own length plus margin (16 kHz mono PCM16 = 32,000 bytes a second).
        val clipMs = pcm.size * 1000L / (CarWav.SAMPLE_RATE * 2)
        start(intent, (clipMs + 20000L).coerceIn(30000L, 240000L), "recording", reply)
    }

    private fun start(intent: Intent, timeoutMs: Long, mode: String, reply: (Map<String, Any?>) -> Unit) {
        val onDevice = onDeviceAvailable()
        val r = try {
            if (onDevice && Build.VERSION.SDK_INT >= 31) SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
            else SpeechRecognizer.createSpeechRecognizer(ctx)
        } catch (error: Exception) {
            closePipe()
            return reply(mapOf("error" to "unavailable"))
        }
        recognizer = r
        pending = reply
        log("start", mapOf("mode" to mode, "onDevice" to onDevice))
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onPartialResults(partialResults: Bundle?) = Unit
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
            override fun onError(error: Int) = finish(mapOf("error" to errorName(error)))
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull { it.isNotBlank() }
                finish(if (text == null) mapOf("error" to "no_match") else mapOf("text" to text))
            }
        })
        val expiry = Runnable { finish(mapOf("error" to "speech_timeout")) }
        timeout = expiry
        handler.postDelayed(expiry, timeoutMs)
        try {
            r.startListening(intent)
        } catch (error: Exception) {
            finish(mapOf("error" to "other:${error.javaClass.simpleName}"))
        }
    }

    fun cancel() = finish(mapOf("error" to "cancelled"))

    private fun finish(result: Map<String, Any?>) {
        val reply = pending ?: return
        pending = null
        timeout?.let { handler.removeCallbacks(it) }
        timeout = null
        val r = recognizer
        recognizer = null
        if (r != null) handler.post {
            try { r.cancel() } catch (_: Exception) {}
            r.destroy()
        }
        closePipe()
        log("result", mapOf("error" to result["error"], "hasText" to (result["text"] != null)))
        reply(result)
    }

    private fun closePipe() {
        pipe?.let { fds -> fds.forEach { try { it.close() } catch (_: Exception) {} } }
        pipe = null
    }

    private fun errorName(code: Int) = when (code) {
        SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech_timeout"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "other:permission"
        else -> "other:$code"
    }
}
