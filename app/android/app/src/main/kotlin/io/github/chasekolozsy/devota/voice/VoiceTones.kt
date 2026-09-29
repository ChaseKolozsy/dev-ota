package io.github.chasekolozsy.devota.voice

import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/**
 * The three short earcons: a rising two-note chirp for a recognized command,
 * one soft low tick for dictation added to the draft, and a falling pair for
 * an error. 16-bit mono PCM, generated in memory; no files, no assets.
 */
internal object VoiceTones {
    const val SAMPLE_RATE = 22_050

    private val notes = mapOf(
        "command" to listOf(880.0 to 70, 1320.0 to 90),
        "dictation" to listOf(520.0 to 60),
        "error" to listOf(440.0 to 110, 311.0 to 150),
    )

    fun known(kind: String) = kind in notes

    fun pcm(kind: String, volume: Double = 0.35): ShortArray {
        val parts = notes[kind] ?: notes.getValue("dictation")
        val out = ArrayList<Short>()
        for ((index, part) in parts.withIndex()) {
            val (freq, ms) = part
            val n = SAMPLE_RATE * ms / 1000
            val fade = min(n / 4, SAMPLE_RATE * 8 / 1000)
            for (i in 0 until n) {
                val envelope = when {
                    i < fade -> i.toDouble() / fade
                    i >= n - fade -> (n - i).toDouble() / fade
                    else -> 1.0
                }
                val v = sin(2 * PI * freq * i / SAMPLE_RATE) * envelope * volume
                out.add((v * Short.MAX_VALUE).toInt().toShort())
            }
            if (index < parts.lastIndex) repeat(SAMPLE_RATE * 25 / 1000) { out.add(0) }
        }
        return out.toShortArray()
    }

    fun durationMs(kind: String) = pcm(kind).size * 1000L / SAMPLE_RATE
}
