package io.github.chasekolozsy.devota.car

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/** Pure WAV helpers (no Android imports; unit-tested on the JVM). */
object CarWav {
    const val SAMPLE_RATE = 16000

    /** A canonical 44-byte PCM RIFF/WAVE header. */
    fun header(dataBytes: Int, sampleRate: Int = SAMPLE_RATE, channels: Int = 1, bits: Int = 16): ByteArray {
        val byteRate = sampleRate * channels * bits / 8
        return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII))
            putInt(36 + dataBytes)
            put("WAVE".toByteArray(Charsets.US_ASCII))
            put("fmt ".toByteArray(Charsets.US_ASCII))
            putInt(16)
            putShort(1) // PCM
            putShort(channels.toShort())
            putInt(sampleRate)
            putInt(byteRate)
            putShort((channels * bits / 8).toShort())
            putShort(bits.toShort())
            put("data".toByteArray(Charsets.US_ASCII))
            putInt(dataBytes)
        }.array()
    }

    fun wrap(pcm: ByteArray, sampleRate: Int = SAMPLE_RATE): ByteArray {
        val out = ByteArray(44 + pcm.size)
        header(pcm.size, sampleRate).copyInto(out)
        pcm.copyInto(out, 44)
        return out
    }

    /** Milliseconds of 16-bit mono audio in [bytes]. */
    fun durationMs(bytes: Int, sampleRate: Int = SAMPLE_RATE): Long = bytes.toLong() * 1000L / (sampleRate * 2L)
}

/** Short generated tones. They play through DevOTA's own AudioTrack. */
object CarTones {
    const val RATE = 22050

    private data class Tone(val hz: Double, val ms: Int, val gap: Int = 0)

    private fun spec(kind: String): List<Tone> = when (kind) {
        "start" -> listOf(Tone(660.0, 90, 30), Tone(990.0, 110))
        "stop" -> listOf(Tone(990.0, 90, 30), Tone(660.0, 110))
        "command" -> listOf(Tone(880.0, 70, 50), Tone(880.0, 70, 50), Tone(1175.0, 90))
        "confirm" -> listOf(Tone(523.0, 90, 20), Tone(784.0, 120))
        "error" -> listOf(Tone(220.0, 260))
        "claim" -> listOf(Tone(1200.0, 25))
        else -> listOf(Tone(1200.0, 40)) // tick
    }

    fun known(kind: String) = kind in setOf("start", "stop", "command", "confirm", "error", "tick", "claim")

    /** 16-bit mono PCM with 5 ms fades so tones do not click. */
    fun pcm(kind: String, rate: Int = RATE): ShortArray {
        val amplitude = if (kind == "claim") 900.0 else 9000.0
        val samples = ArrayList<Short>()
        for (tone in spec(kind)) {
            val n = rate * tone.ms / 1000
            val fade = min(rate * 5 / 1000, n / 2).coerceAtLeast(1)
            for (i in 0 until n) {
                val envelope = when {
                    i < fade -> i.toDouble() / fade
                    i > n - fade -> (n - i).toDouble() / fade
                    else -> 1.0
                }
                samples.add((amplitude * envelope * sin(2 * PI * tone.hz * i / rate)).toInt().toShort())
            }
            repeat(rate * tone.gap / 1000) { samples.add(0) }
        }
        return samples.toShortArray()
    }
}
