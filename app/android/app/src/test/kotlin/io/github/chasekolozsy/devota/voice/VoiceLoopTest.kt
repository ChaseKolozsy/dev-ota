package io.github.chasekolozsy.devota.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakePort(var available: Boolean = true) : RecognizerPort {
    val calls = mutableListOf<String>()
    var lastSession = 0
    override fun create(): Boolean { calls.add("create"); return available }
    override fun start(session: Int) { calls.add("start"); lastSession = session }
    override fun cancel() { calls.add("cancel") }
    override fun destroy() { calls.add("destroy") }
}

private class FakeScheduler : LoopScheduler {
    val tasks = mutableListOf<Pair<Long, () -> Unit>>()
    override fun post(delayMs: Long, block: () -> Unit): Any {
        val task = delayMs to block
        tasks.add(task)
        return task
    }
    override fun cancel(token: Any) { tasks.remove(token) }
    fun runAll() {
        while (tasks.isNotEmpty()) tasks.removeAt(0).second()
    }
    fun lastDelay() = tasks.last().first
}

private class FakeListener : LoopListener {
    val utterances = mutableListOf<String>()
    val states = mutableListOf<Pair<LoopState, String?>>()
    val fatal = mutableListOf<String>()
    var sessionStarts = 0
    var pauses = 0
    override fun onUtterance(text: String) { utterances.add(text) }
    override fun onState(state: LoopState, detail: String?) { states.add(state to detail) }
    override fun onFatal(reason: String) { fatal.add(reason) }
    override fun onSessionStarting() { sessionStarts++ }
    override fun onPaused() { pauses++ }
}

class VoiceLoopTest {
    private var now = 0L
    private val port = FakePort()
    private val scheduler = FakeScheduler()
    private val listener = FakeListener()
    private val loop = ListeningLoop(port, scheduler, { now }, listener)

    @Test
    fun `switch off means no recognizer is ever created or started`() {
        // Never enabled: nothing is scheduled and callbacks do nothing.
        loop.onResults(1, "submit")
        loop.onError(1, RecognizerErrors.NO_MATCH)
        loop.release(ListeningLoop.REPLY)
        loop.hold(ListeningLoop.CALL)
        scheduler.runAll()
        assertTrue(port.calls.isEmpty())
        assertTrue(listener.utterances.isEmpty())
    }

    @Test
    fun `disable cancels the session and stale callbacks cannot restart it`() {
        loop.enable()
        scheduler.runAll()
        assertEquals(listOf("create", "start"), port.calls)
        val session = port.lastSession
        loop.disable()
        assertEquals(listOf("create", "start", "cancel", "destroy"), port.calls)
        // A late error or result from the old session, a release, or a queued
        // restart must not bring the recognizer back.
        loop.onError(session, RecognizerErrors.NO_MATCH)
        loop.onResults(session, "exit")
        loop.release(ListeningLoop.SPEAK)
        scheduler.runAll()
        assertEquals(4, port.calls.size)
        assertTrue(listener.utterances.isEmpty())
        assertEquals(LoopState.OFF, listener.states.last().first)
    }

    @Test
    fun `a queued restart is dropped when disabled before it fires`() {
        loop.enable()
        loop.disable()
        scheduler.runAll()
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun `a result holds listening until Dart replies`() {
        loop.enable()
        scheduler.runAll()
        now = 3_000
        loop.onResults(port.lastSession, "  fix the tests ")
        assertEquals(listOf("fix the tests"), listener.utterances)
        scheduler.runAll()
        assertEquals(1, port.calls.count { it == "start" })
        loop.release(ListeningLoop.REPLY)
        scheduler.runAll()
        assertEquals(2, port.calls.count { it == "start" })
    }

    @Test
    fun `the owner speaking is visible so DevOTA never talks over them`() {
        loop.enable()
        scheduler.runAll()
        assertFalse(loop.userSpeaking)
        loop.onBeginningOfSpeech(port.lastSession)
        assertTrue(loop.userSpeaking)
        loop.onResults(port.lastSession, "hello")
        assertFalse(loop.userSpeaking)
    }

    @Test
    fun `speech, playback and calls pause listening until every hold is released`() {
        loop.enable()
        scheduler.runAll()
        loop.hold(ListeningLoop.CALL)
        assertEquals("cancel", port.calls.last())
        assertEquals(1, listener.pauses)
        loop.hold(ListeningLoop.PLAYBACK)
        loop.release(ListeningLoop.CALL)
        scheduler.runAll()
        assertEquals(1, port.calls.count { it == "start" })
        loop.release(ListeningLoop.PLAYBACK)
        scheduler.runAll()
        assertEquals(2, port.calls.count { it == "start" })
        // A stale callback from the cancelled session is ignored.
        loop.onError(port.lastSession - 1, RecognizerErrors.CLIENT)
        assertTrue(scheduler.tasks.isEmpty())
    }

    @Test
    fun `silence restarts at once, instant no-match backs off`() {
        loop.enable()
        scheduler.runAll()
        now = 6_000
        loop.onError(port.lastSession, RecognizerErrors.SPEECH_TIMEOUT)
        assertEquals(RestartPolicy.SILENCE_RESTART_MS, scheduler.lastDelay())
        scheduler.runAll()
        val delays = mutableListOf<Long>()
        repeat(4) {
            now += 100
            loop.onError(port.lastSession, RecognizerErrors.NO_MATCH)
            delays.add(scheduler.lastDelay())
            now += scheduler.lastDelay()
            scheduler.runAll()
        }
        assertEquals(listOf(500L, 1_000L, 2_000L, 4_000L), delays)
        assertTrue("third fast failure recreates", port.calls.contains("destroy"))
    }

    @Test
    fun `network errors back off to a minute and permission errors stop`() {
        val policy = RestartPolicy()
        val delays = (1..8).map {
            (policy.onError(RecognizerErrors.NETWORK, 500, false) as RestartDecision.Retry).delayMs
        }
        assertEquals(listOf(2_000L, 4_000L, 8_000L, 16_000L, 32_000L, 60_000L, 60_000L, 60_000L), delays)
        policy.onSuccess()
        assertEquals(2_000L, (policy.onError(RecognizerErrors.SERVER, 500, false) as RestartDecision.Retry).delayMs)
        val busy = policy.onError(RecognizerErrors.RECOGNIZER_BUSY, 50, false) as RestartDecision.Retry
        assertTrue(busy.recreate)
        assertTrue(policy.onError(RecognizerErrors.INSUFFICIENT_PERMISSIONS, 0, false) is RestartDecision.Fatal)
        assertEquals(60_000L, (policy.onError(RecognizerErrors.TOO_MANY_REQUESTS, 0, false) as RestartDecision.Retry).delayMs)
    }

    @Test
    fun `fatal errors disable the loop and report`() {
        loop.enable()
        scheduler.runAll()
        loop.onError(port.lastSession, RecognizerErrors.INSUFFICIENT_PERMISSIONS)
        assertFalse(loop.enabled)
        assertEquals(listOf("Microphone permission missing"), listener.fatal)
        scheduler.runAll()
        assertEquals(1, port.calls.count { it == "start" })
    }

    @Test
    fun `no recognizer available is fatal, not a loop`() {
        val none = FakePort(available = false)
        val l = FakeListener()
        val lp = ListeningLoop(none, scheduler, { now }, l)
        lp.enable()
        scheduler.runAll()
        assertEquals(listOf("create"), none.calls)
        assertEquals(1, l.fatal.size)
        assertFalse(lp.enabled)
    }

    @Test
    fun `starts are capped per minute whatever the cause`() {
        val policy = RestartPolicy(maxStartsPerMinute = 3, cooldownMs = 15_000)
        repeat(3) { policy.recordStart(it * 1_000L) }
        assertEquals(15_000L, policy.startDelay(3_000))
        assertEquals(0L, policy.startDelay(61_000))
    }

    @Test
    fun `playback policy pauses for speech and ignores earcons`() {
        // (usage, contentType)
        assertTrue(PlaybackPolicy.speechPlaying(listOf(12 to 1))) // navigation guidance
        assertTrue(PlaybackPolicy.speechPlaying(listOf(1 to 1))) // media speech (TTS, podcast)
        assertTrue(PlaybackPolicy.speechPlaying(listOf(2 to 1))) // voice call
        assertFalse(PlaybackPolicy.speechPlaying(listOf(1 to 2))) // music
        assertTrue(PlaybackPolicy.audiblePlaying(listOf(1 to 2)))
        assertFalse(PlaybackPolicy.audiblePlaying(listOf(13 to 4, 5 to 4, 1 to 4))) // earcons, notifications
        assertTrue(PlaybackPolicy.callActive(2))
        assertTrue(PlaybackPolicy.callActive(3))
        assertFalse(PlaybackPolicy.callActive(0))
    }

    @Test
    fun `the start gate refuses unless on, visible, permitted and available`() {
        assertNotNull(StartGate.refusal(false, true, true, true))
        assertNotNull(StartGate.refusal(true, false, true, true))
        assertNotNull(StartGate.refusal(true, true, false, true))
        assertNotNull(StartGate.refusal(true, true, true, false))
        assertNull(StartGate.refusal(true, true, true, true))
    }

    @Test
    fun `the three tones are short, audible and distinct`() {
        val kinds = listOf("command", "dictation", "error")
        for (kind in kinds) {
            assertTrue(VoiceTones.known(kind))
            val pcm = VoiceTones.pcm(kind)
            assertTrue(pcm.any { it > 1000 })
            assertTrue(VoiceTones.durationMs(kind) in 40..400)
        }
        assertNotEquals(VoiceTones.pcm("command").toList(), VoiceTones.pcm("dictation").toList())
        assertNotEquals(VoiceTones.pcm("command").toList(), VoiceTones.pcm("error").toList())
    }
}
