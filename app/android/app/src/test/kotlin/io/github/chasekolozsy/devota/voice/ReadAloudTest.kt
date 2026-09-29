package io.github.chasekolozsy.devota.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A clock-driven scheduler: tasks run when [advance] reaches their time. */
private class ClockScheduler {
    var now = 0L
    private var seq = 0
    private val tasks = mutableListOf<Triple<Long, Int, () -> Unit>>()

    val port = object : LoopScheduler {
        override fun post(delayMs: Long, block: () -> Unit): Any {
            val task = Triple(now + delayMs, seq++, block)
            tasks.add(task)
            return task
        }

        override fun cancel(token: Any) {
            tasks.remove(token)
        }
    }

    fun advance(ms: Long) {
        val until = now + ms
        while (true) {
            val due = tasks.filter { it.first <= until }.minWithOrNull(compareBy({ it.first }, { it.second }))
                ?: break
            tasks.remove(due)
            now = due.first
            due.third()
        }
        now = until
    }
}

private class Recognizer : RecognizerPort {
    var starts = 0
    var cancels = 0
    var session = 0
    override fun create() = true
    override fun start(session: Int) {
        starts++
        this.session = session
    }
    override fun cancel() { cancels++ }
    override fun destroy() = Unit
}

/**
 * The service's glue, against fakes: a real [ListeningLoop] and [ReadAloud],
 * a fake recognizer, and a fake speech engine that "speaks" until
 * [finishChunk]. Mirrors VoiceControlService: speaking holds "speak", speech
 * ending releases it and tells the reader, LISTENING and utterances go to
 * the reader, and Dart's reply is applied by [reply].
 */
private class Harness {
    val clock = ClockScheduler()
    val recognizer = Recognizer()
    val spoken = mutableListOf<String>()
    val ended = mutableListOf<String>()
    val utterances = mutableListOf<String>()
    var silenced = 0
    var speaking: String? = null

    lateinit var reader: ReadAloud
    val loop = ListeningLoop(recognizer, clock.port, { clock.now }, object : LoopListener {
        override fun onUtterance(text: String) {
            reader.onUtterance()
            utterances.add(text)
        }
        override fun onState(state: LoopState, detail: String?) {
            if (state == LoopState.LISTENING) reader.onListening()
        }
        override fun onFatal(reason: String) = Unit
        override fun onSessionStarting() = Unit
        override fun onPaused() = Unit
    })

    init {
        reader = ReadAloud(object : ReaderPort {
            override fun speakChunk(text: String) {
                loop.hold(ListeningLoop.SPEAK)
                spoken.add(text)
                speaking = text
            }
            override fun silence() {
                silenced++
                speaking = null
                loop.release(ListeningLoop.SPEAK)
            }
            override val userSpeaking get() = loop.userSpeaking
            override fun ended(reason: String) { ended.add(reason) }
        }, clock.port)
    }

    /** Listening on and the recognizer ready. */
    fun listen() {
        clock.advance(1_000)
        assertTrue("recognizer should be listening", loop.listening)
        loop.onReady(recognizer.session)
    }

    fun say(text: String) {
        loop.onBeginningOfSpeech(recognizer.session)
        loop.onResults(recognizer.session, text)
    }

    /** Dart's answer, applied the way VoiceControlService.handleReply does. */
    fun reply(read: List<String> = emptyList(), stopReading: Boolean = false) {
        if (read.isEmpty() && stopReading) reader.stop()
        if (read.isNotEmpty()) reader.start(read) else reader.onReply()
        loop.release(ListeningLoop.REPLY)
    }

    /** The engine finished the current chunk (300 ms later the mic reopens). */
    fun finishChunk() {
        speaking = null
        loop.release(ListeningLoop.SPEAK)
        reader.onSpeechDone()
    }
}

class ReadAloudTest {
    private val h = Harness()

    private fun startReading(vararg chunks: String) {
        h.loop.enable()
        h.listen()
        h.say("read screen")
        h.reply(read = chunks.toList())
    }

    @Test
    fun `listening pauses while each chunk plays and resumes between chunks and at the end`() {
        startReading("First part.", "Second part.")
        assertEquals(listOf("First part."), h.spoken)
        assertTrue(ListeningLoop.SPEAK in h.loop.held)
        val startsWhileSpeaking = h.recognizer.starts
        h.clock.advance(10_000)
        assertFalse("never listens to its own voice", h.loop.listening)
        assertEquals(startsWhileSpeaking, h.recognizer.starts)

        h.finishChunk()
        h.listen() // the gap between chunks
        assertEquals(ReadAloud.Phase.GAP, h.reader.phase)
        h.clock.advance(ReadAloud.LISTEN_WINDOW_MS)
        assertEquals(listOf("First part.", "Second part."), h.spoken)
        assertFalse(h.loop.listening)
        assertTrue(ListeningLoop.SPEAK in h.loop.held)

        h.finishChunk()
        assertEquals(listOf("finished"), h.ended)
        assertFalse(h.reader.active)
        h.listen() // back to ordinary listening
        h.clock.advance(30_000)
        assertEquals(2, h.spoken.size)
    }

    @Test
    fun `stop reading between chunks stops at once and nothing more is spoken`() {
        startReading("One.", "Two.", "Three.")
        h.finishChunk()
        h.listen()
        h.say("stop reading")
        assertEquals(ReadAloud.Phase.REPLY, h.reader.phase)
        h.reply(stopReading = true)
        assertEquals(listOf("stopped"), h.ended)
        assertEquals(1, h.silenced)
        assertFalse(h.reader.active)
        h.listen()
        h.clock.advance(60_000)
        assertEquals(listOf("One."), h.spoken)
    }

    @Test
    fun `stop in the middle of a chunk silences it and lets listening resume`() {
        startReading("A long chunk.", "Never spoken.")
        assertEquals("A long chunk.", h.speaking)
        h.reader.stop() // a call, or any stop reason
        assertEquals(null, h.speaking)
        assertEquals(listOf("stopped"), h.ended)
        assertFalse(ListeningLoop.SPEAK in h.loop.held)
        h.listen()
        // A late end-of-speech from the silenced chunk changes nothing.
        h.reader.onSpeechDone()
        h.clock.advance(60_000)
        assertEquals(listOf("A long chunk."), h.spoken)
    }

    @Test
    fun `owner still talking when the window closes delays the next chunk`() {
        startReading("One.", "Two.")
        h.finishChunk()
        h.listen()
        h.loop.onBeginningOfSpeech(h.recognizer.session)
        h.clock.advance(ReadAloud.LISTEN_WINDOW_MS + 3 * ReadAloud.POLL_MS)
        assertEquals(listOf("One."), h.spoken)
        assertTrue(h.loop.listening)
        // The utterance turns out to be a command: reading stops.
        h.loop.onResults(h.recognizer.session, "page up")
        h.reply(stopReading = true)
        assertEquals(listOf("One."), h.spoken)
        assertEquals(listOf("stopped"), h.ended)
    }

    @Test
    fun `dictation in the window lets the reading carry on`() {
        startReading("One.", "Two.")
        h.finishChunk()
        h.listen()
        h.say("fix the parser")
        h.reply()
        assertEquals(listOf("One.", "Two."), h.spoken)
        assertFalse(h.loop.listening)
        h.finishChunk()
        assertEquals(listOf("finished"), h.ended)
    }

    @Test
    fun `a new read replaces the current one without an end event`() {
        startReading("Old one.", "Old two.")
        h.finishChunk()
        h.listen()
        h.say("read reply")
        h.reply(read = listOf("New."))
        assertEquals(listOf("Old one.", "New."), h.spoken)
        assertTrue(h.ended.isEmpty())
        h.finishChunk()
        assertEquals(listOf("finished"), h.ended)
    }

    @Test
    fun `if listening cannot reopen the reading goes on after a timeout`() {
        startReading("One.", "Two.")
        h.loop.hold(ListeningLoop.PLAYBACK) // e.g. the engine still reported as playing
        h.finishChunk()
        h.clock.advance(ReadAloud.READY_TIMEOUT_MS - 1)
        assertEquals(listOf("One."), h.spoken)
        h.clock.advance(1)
        assertEquals(listOf("One.", "Two."), h.spoken)
    }

    @Test
    fun `no answer from Dart carries on like dictation`() {
        startReading("One.", "Two.")
        h.finishChunk()
        h.listen()
        h.say("mumble")
        // VoiceControlService's reply timeout: reader.onReply(), release REPLY.
        h.reader.onReply()
        h.loop.release(ListeningLoop.REPLY)
        assertEquals(listOf("One.", "Two."), h.spoken)
    }

    @Test
    fun `nothing to read ends at once and cancel reports nothing`() {
        h.reader.start(listOf(" ", ""))
        assertEquals(listOf("finished"), h.ended)
        assertTrue(h.spoken.isEmpty())
        startReading("One.")
        h.reader.cancel()
        assertFalse(h.reader.active)
        assertEquals(listOf("finished"), h.ended)
    }
}
