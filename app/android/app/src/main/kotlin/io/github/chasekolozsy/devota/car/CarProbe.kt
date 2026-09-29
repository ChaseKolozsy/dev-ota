package io.github.chasekolozsy.devota.car

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.BufferedWriter
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The car probe's local log: an in-memory ring buffer plus one append-only
 * JSONL file per probe run under filesDir/car_probe/. Signal names and
 * timings only; never recognized text, terminal text or audio. Each entry is
 * also spoken (coalesced) while the probe runs, so the owner hears what the
 * phone received without looking.
 */
internal class CarProbe(
    private val ctx: Context,
    private val speakLine: (String) -> Unit,
    private val ownAudioRecent: () -> Boolean,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val entries = ArrayDeque<CarProbeEntry>()
    private val coalescer = CarSpeechCoalescer()
    private var writer: BufferedWriter? = null
    private var file: File? = null
    private var header: Map<String, Any?> = emptyMap()
    private val flush = Runnable { coalescer.flush(SystemClock.elapsedRealtime())?.let(speakLine) }

    var active = false
        private set
    var speak = true
        private set

    fun start(speak: Boolean, header: Map<String, Any?>) {
        stop()
        this.speak = speak
        this.header = header
        coalescer.reset()
        openFile()
        active = true
    }

    private fun openFile() {
        writer?.let { try { it.close() } catch (_: Exception) {} }
        val dir = File(ctx.filesDir, "car_probe").apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val f = File(dir, "probe-$stamp.jsonl")
        file = f
        writer = try {
            f.bufferedWriter().also {
                it.write(CarProbeFormat.headerLine(header + mapOf("startedAt" to isoNow())))
                it.newLine()
                it.flush()
            }
        } catch (_: Exception) { null }
    }

    fun stop() {
        active = false
        handler.removeCallbacks(flush)
        writer?.let { try { it.close() } catch (_: Exception) {} }
        writer = null
    }

    fun log(source: String, event: String, detail: Map<String, Any?> = emptyMap()) {
        if (!active) return
        val entry = CarProbeFormat.entry(System.currentTimeMillis(), SystemClock.elapsedRealtime(), source, event, detail)
        entries.addLast(entry)
        while (entries.size > 2000) entries.removeFirst()
        writer?.let { w ->
            try {
                w.write(CarProbeFormat.line(entry))
                w.newLine()
                w.flush()
            } catch (_: Exception) {}
        }
        if (!speak) return
        val line = CarProbeFormat.spoken(entry, ownAudioRecent()) ?: return
        val now = SystemClock.elapsedRealtime()
        when (val decision = coalescer.offer(now, line)) {
            CarSpeechCoalescer.Decision.SpeakNow -> speakLine(line.text)
            is CarSpeechCoalescer.Decision.Deferred -> {
                handler.removeCallbacks(flush)
                handler.postDelayed(flush, (decision.at - now).coerceAtLeast(0))
            }
            CarSpeechCoalescer.Decision.Replaced, CarSpeechCoalescer.Decision.Drop -> Unit
        }
    }

    fun recent(limit: Int): List<Map<String, Any?>> =
        entries.toList().takeLast(limit.coerceIn(1, 2000)).map { it.toMap() }

    /** Path of the JSONL file for this (or the last) run; written fresh if none. */
    fun export(): String? {
        writer?.let { try { it.flush() } catch (_: Exception) {} }
        val existing = file
        if (existing != null && existing.exists()) return existing.absolutePath
        return try {
            val dir = File(ctx.filesDir, "car_probe").apply { mkdirs() }
            val f = File(dir, "probe-export-${SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())}.jsonl")
            f.bufferedWriter().use { w ->
                w.write(CarProbeFormat.headerLine(header + mapOf("startedAt" to isoNow())))
                w.newLine()
                entries.forEach { w.write(CarProbeFormat.line(it)); w.newLine() }
            }
            file = f
            f.absolutePath
        } catch (_: Exception) { null }
    }

    fun clear() {
        entries.clear()
        coalescer.reset()
        handler.removeCallbacks(flush)
        if (active) openFile() else file = null
    }

    private fun isoNow(): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)
        .apply { timeZone = TimeZone.getDefault() }.format(Date())
}
