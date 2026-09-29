package io.github.chasekolozsy.devota.car

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A manual clock: timers fire only when [advance] passes their due time. */
private class FakeScheduler : CarScheduler {
    var now = 0L
    private val timers = mutableListOf<Triple<Long, () -> Unit, BooleanArray>>()
    override fun schedule(delayMs: Long, action: () -> Unit): CarCancellable {
        val cancelled = BooleanArray(1)
        timers.add(Triple(now + delayMs, action, cancelled))
        return CarCancellable { cancelled[0] = true }
    }
    fun advance(to: Long) {
        now = to
        while (true) {
            val due = timers.filter { !it.third[0] && it.first <= now }.minByOrNull { it.first } ?: break
            timers.remove(due)
            due.second()
        }
    }
}

class CarPressClassifierTest {
    private val clock = FakeScheduler()
    private val out = mutableListOf<CarPress>()
    private val classifier = CarPressClassifier(clock) { out.add(it) }

    private fun press(downAt: Long, upAt: Long) {
        clock.advance(downAt); classifier.onDown(downAt)
        clock.advance(upAt); classifier.onUp(upAt)
    }

    @Test fun `with timing off a single fires on key down with no wait`() {
        classifier.configure(double = false, long = false)
        clock.advance(10); classifier.onDown(10)
        assertEquals(listOf(CarPress.SINGLE), out)
        classifier.onUp(2000) // a long hold is still just one single
        assertEquals(listOf(CarPress.SINGLE), out)
    }

    @Test fun `double enabled waits for the window then fires single`() {
        classifier.configure(double = true, long = false, doubleMs = 400)
        press(0, 80)
        assertTrue(out.isEmpty())
        clock.advance(479)
        assertTrue(out.isEmpty())
        clock.advance(480)
        assertEquals(listOf(CarPress.SINGLE), out)
    }

    @Test fun `second press inside the window is a double`() {
        classifier.configure(double = true, long = false, doubleMs = 400)
        press(0, 80)
        press(300, 360)
        clock.advance(2000)
        assertEquals(listOf(CarPress.DOUBLE), out)
    }

    @Test fun `second press outside the window is two singles`() {
        classifier.configure(double = true, long = false, doubleMs = 400)
        press(0, 80)
        press(600, 660)
        clock.advance(2000)
        assertEquals(listOf(CarPress.SINGLE, CarPress.SINGLE), out)
    }

    @Test fun `hold past the threshold is a long press even without key repeats`() {
        classifier.configure(double = false, long = true, longMs = 700)
        clock.advance(0); classifier.onDown(0)
        clock.advance(699)
        assertTrue(out.isEmpty())
        clock.advance(700)
        assertEquals(listOf(CarPress.LONG), out)
        classifier.onUp(1200)
        assertEquals(listOf(CarPress.LONG), out)
    }

    @Test fun `key repeat past the threshold is a long press`() {
        classifier.configure(double = false, long = true, longMs = 700)
        classifier.onDown(0)
        classifier.onDown(750, repeat = 1)
        assertEquals(listOf(CarPress.LONG), out)
    }

    @Test fun `short press with long enabled is a single on release`() {
        classifier.configure(double = false, long = true, longMs = 700)
        press(0, 120)
        assertEquals(listOf(CarPress.SINGLE), out)
        clock.advance(5000)
        assertEquals(listOf(CarPress.SINGLE), out)
    }

    @Test fun `long disabled never produces a long press`() {
        classifier.configure(double = true, long = false, doubleMs = 400)
        press(0, 3000)
        clock.advance(5000)
        assertEquals(listOf(CarPress.SINGLE), out)
    }

    @Test fun `taps without key timing classify like presses`() {
        classifier.configure(double = true, long = false, doubleMs = 400)
        clock.advance(0); classifier.onTap(0)
        clock.advance(200); classifier.onTap(200)
        clock.advance(2000)
        assertEquals(listOf(CarPress.DOUBLE), out)
    }
}

class CarWavTest {
    @Test fun `header is canonical little endian PCM`() {
        val h = CarWav.header(32000)
        assertEquals(44, h.size)
        assertEquals("RIFF", String(h, 0, 4, Charsets.US_ASCII))
        assertEquals("WAVE", String(h, 8, 4, Charsets.US_ASCII))
        assertEquals("data", String(h, 36, 4, Charsets.US_ASCII))
        val b = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(36 + 32000, b.getInt(4))
        assertEquals(1, b.getShort(20).toInt())      // PCM
        assertEquals(1, b.getShort(22).toInt())      // mono
        assertEquals(16000, b.getInt(24))            // sample rate
        assertEquals(32000, b.getInt(28))            // byte rate
        assertEquals(2, b.getShort(32).toInt())      // block align
        assertEquals(16, b.getShort(34).toInt())     // bits
        assertEquals(32000, b.getInt(40))
    }

    @Test fun `wrap appends pcm after the header and duration is exact`() {
        val pcm = byteArrayOf(1, 2, 3, 4)
        val wav = CarWav.wrap(pcm)
        assertEquals(48, wav.size)
        assertArrayEquals(pcm, wav.copyOfRange(44, 48))
        assertEquals(1000L, CarWav.durationMs(32000))
    }

    @Test fun `tones are short and bounded`() {
        for (kind in listOf("start", "stop", "command", "confirm", "error", "tick", "claim")) {
            val pcm = CarTones.pcm(kind)
            assertTrue(kind, pcm.isNotEmpty() && pcm.size < CarTones.RATE) // under a second
            assertTrue(kind, pcm.maxOf { kotlin.math.abs(it.toInt()) } <= 9000)
        }
    }
}

class CarProbeFormatTest {
    @Test fun `a probe line is one JSON object with sanitized detail`() {
        val entry = CarProbeFormat.entry(1000L, 55L, "media_button", "key",
            mapOf("keycode" to "KEYCODE_MEDIA_NEXT", "action" to "up", "heldMs" to 90L,
                "nested" to listOf(1, 2), "missing" to null, "f" to 1.5f))
        val line = CarProbeFormat.line(entry)
        assertTrue(!line.contains('\n'))
        val json = JSONObject(line)
        assertEquals(1000L, json.getLong("t"))
        assertEquals(55L, json.getLong("up"))
        assertEquals("media_button", json.getString("source"))
        val detail = json.getJSONObject("detail")
        assertEquals("KEYCODE_MEDIA_NEXT", detail.getString("keycode"))
        assertEquals(90L, detail.getLong("heldMs"))
        assertEquals("1,2", detail.getString("nested"))
        assertTrue(detail.isNull("missing"))
        assertEquals(1.5, detail.getDouble("f"), 0.0)
    }

    @Test fun `header line is typed`() {
        val json = JSONObject(CarProbeFormat.headerLine(mapOf("sdk" to 36, "device" to "X")))
        assertEquals("header", json.getString("type"))
        assertEquals(36, json.getInt("sdk"))
    }

    @Test fun `spoken lines name the button and the path`() {
        fun say(source: String, event: String, detail: Map<String, Any?> = emptyMap(), own: Boolean = false) =
            CarProbeFormat.spoken(CarProbeFormat.entry(0, 0, source, event, detail), own)?.text
        assertEquals("Next. Media button. Held 90 milliseconds.",
            say("media_button", "key", mapOf("keycode" to "KEYCODE_MEDIA_NEXT", "action" to "up", "heldMs" to 90L)))
        assertNull(say("media_button", "key", mapOf("keycode" to "KEYCODE_MEDIA_NEXT", "action" to "down", "repeat" to 3)))
        assertEquals("Next. Media session.", say("media_session", "onSkipToNext"))
        assertEquals("Voice button. Voice command.", say("voice_command", "VOICE_COMMAND"))
        assertEquals("Hang up. Telecom disconnect.", say("telecom", "onDisconnect"))
        assertNull(say("speaker", "speak_start"))
        // Its own voice must not narrate the side effects of its own voice.
        assertNull(say("bluetooth", "A2DP_PLAYING_STATE", mapOf("state" to "playing"), own = true))
        // Nor A2DP playing state at all: the car reports it seconds after the voice ends.
        assertNull(say("bluetooth", "A2DP_PLAYING_STATE", mapOf("state" to "stopped")))
        assertNull(say("audio", "devices_added", mapOf("initial" to true)))
    }
}

class CarSpeechCoalescerTest {
    @Test fun `one line per gap and the newest pending line wins`() {
        val c = CarSpeechCoalescer(minGapMs = 700, keyGapMs = 2000)
        assertEquals(CarSpeechCoalescer.Decision.SpeakNow, c.offer(0, CarSpokenLine("a")))
        assertEquals(CarSpeechCoalescer.Decision.Deferred(700), c.offer(100, CarSpokenLine("b")))
        assertEquals(CarSpeechCoalescer.Decision.Replaced, c.offer(200, CarSpokenLine("c")))
        assertEquals("c", c.flush(700))
        assertNull(c.flush(701))
        assertEquals(CarSpeechCoalescer.Decision.Deferred(1400), c.offer(800, CarSpokenLine("d")))
        assertEquals(CarSpeechCoalescer.Decision.SpeakNow, CarSpeechCoalescer().offer(5000, CarSpokenLine("e")))
    }

    @Test fun `rate keyed lines are dropped inside their gap`() {
        val c = CarSpeechCoalescer(minGapMs = 700, keyGapMs = 2000)
        assertEquals(CarSpeechCoalescer.Decision.SpeakNow, c.offer(0, CarSpokenLine("Volume 5.", "volume")))
        assertEquals(CarSpeechCoalescer.Decision.Drop, c.offer(1000, CarSpokenLine("Volume 6.", "volume")))
        assertEquals(CarSpeechCoalescer.Decision.SpeakNow, c.offer(2100, CarSpokenLine("Volume 7.", "volume")))
    }
}
