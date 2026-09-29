package io.github.chasekolozsy.devota.car

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream

/** A byte buffer that can be wiped, so a discarded dictation leaves no copy. */
private class WipeableBuffer : ByteArrayOutputStream() {
    fun wipe() {
        java.util.Arrays.fill(buf, 0.toByte())
        reset()
    }
}

/**
 * 16 kHz mono PCM16 capture into MEMORY only (no disk), the same as Whisper
 * Notes. Capped at a maximum length; the cap stops capture and calls [onCap]
 * on the recorder thread.
 */
internal class CarRecorder(
    private val onCap: () -> Unit,
    private val onError: (String) -> Unit,
) {
    private val lock = Any()
    private val pcm = WipeableBuffer()
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null

    val isRecording get() = running

    /** Returns null on success or an error code. */
    @SuppressLint("MissingPermission")
    fun start(ctx: Context, source: Int, maxSeconds: Int): String? {
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED) return "microphone_permission"
        stop()
        discard()
        val rate = CarWav.SAMPLE_RATE
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return "unsupported_format"
        val rec = try {
            AudioRecord(source, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, rate / 5 * 2) * 2)
        } catch (error: Exception) {
            return "init_${error.javaClass.simpleName}"
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return "init_failed"
        }
        val cap = maxSeconds.coerceIn(1, 600) * rate * 2
        try {
            rec.startRecording()
        } catch (error: Exception) {
            rec.release()
            return "start_${error.javaClass.simpleName}"
        }
        record = rec
        running = true
        thread = Thread({
            val buffer = ByteArray(3200)
            var capped = false
            while (running) {
                val n = rec.read(buffer, 0, buffer.size)
                if (n < 0) {
                    running = false
                    onError("read_$n")
                    break
                }
                synchronized(lock) {
                    val room = cap - pcm.size()
                    if (room > 0) pcm.write(buffer, 0, minOf(n, room))
                    if (pcm.size() >= cap) capped = true
                }
                if (capped) {
                    running = false
                    onCap()
                }
            }
        }, "devota-car-recorder").also { it.start() }
        return null
    }

    /** Stops capture and keeps the audio. Returns (durationMs, bytes). */
    fun stop(): Pair<Long, Int> {
        running = false
        val t = thread
        thread = null
        if (t != null && t !== Thread.currentThread()) {
            try { t.join(700) } catch (_: InterruptedException) {}
        }
        record?.let { rec ->
            try { rec.stop() } catch (_: Exception) {}
            rec.release()
        }
        record = null
        val size = synchronized(lock) { pcm.size() }
        return CarWav.durationMs(size) to size
    }

    fun wav(): ByteArray? = synchronized(lock) {
        if (pcm.size() == 0) null else CarWav.wrap(pcm.toByteArray())
    }

    fun pcmBytes(): ByteArray? = synchronized(lock) { if (pcm.size() == 0) null else pcm.toByteArray() }

    fun discard() = synchronized(lock) { pcm.wipe() }
}
