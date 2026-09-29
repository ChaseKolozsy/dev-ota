package io.github.chasekolozsy.devota.voice

/** The voice control service as the reader sees it. */
internal interface ReaderPort {
    /**
     * Speaks one chunk through the service's ordinary speech path, which
     * holds listening ("speak", shown as Speaking) until the speech ends.
     */
    fun speakChunk(text: String)

    /** Stops speech at once, drops anything queued, and lets listening resume. */
    fun silence()

    /** The owner is in the middle of an utterance. */
    val userSpeaking: Boolean

    /** The reading is over: finished | stopped | failed. */
    fun ended(reason: String)
}

/**
 * "read screen" / "read reply": speaks a list of chunks one at a time.
 *
 * The recognizer is paused while a chunk is spoken (the service's Speaking
 * hold), so it never transcribes DevOTA's own voice. After each chunk,
 * listening resumes for a short window; if the owner starts talking the
 * reading waits for what they said, and Dart's answer either stops it (any
 * command, "stop reading" included) or lets it carry on (dictation). If
 * they say nothing, the next chunk is spoken.
 *
 * Pure: no Android types, so the JVM tests drive it with fakes.
 */
internal class ReadAloud(
    private val port: ReaderPort,
    private val scheduler: LoopScheduler,
) {
    enum class Phase { IDLE, SPEAKING, GAP, REPLY }

    var phase = Phase.IDLE
        private set
    val active get() = phase != Phase.IDLE

    private var chunks: List<String> = emptyList()
    private var next = 0
    private var windowOpen = false
    private var timer: Any? = null

    /** Starts reading [list], replacing any reading in progress without an end event. */
    fun start(list: List<String>) {
        val clean = list.map { it.trim() }.filter { it.isNotEmpty() }
        cancelTimer()
        if (active) port.silence()
        chunks = clean
        next = 0
        if (clean.isEmpty()) {
            phase = Phase.IDLE
            port.ended("finished")
            return
        }
        speakNext()
    }

    /** "stop reading", any other command, a call, or no speech engine. */
    fun stop(reason: String = "stopped") {
        if (!active) return
        reset()
        port.silence()
        port.ended(reason)
    }

    /** The service is going away: forget everything, report nothing. */
    fun cancel() = reset()

    /** Every queued utterance has been spoken and listening was released. */
    fun onSpeechDone() {
        if (phase != Phase.SPEAKING) return
        if (next >= chunks.size) {
            finish()
            return
        }
        phase = Phase.GAP
        windowOpen = false
        // Listening normally reopens within a second; never wait forever.
        timer = scheduler.post(READY_TIMEOUT_MS) { gapOver() }
    }

    /** The recognizer is ready: give the owner a moment to speak. */
    fun onListening() {
        if (phase != Phase.GAP || windowOpen) return
        windowOpen = true
        cancelTimer()
        timer = scheduler.post(LISTEN_WINDOW_MS) { gapOver() }
    }

    /** An utterance arrived during the window: wait for Dart's answer. */
    fun onUtterance() {
        if (phase != Phase.GAP) return
        cancelTimer()
        phase = Phase.REPLY
    }

    /** Dart answered without stopping or replacing the reading (dictation), or never answered. */
    fun onReply() {
        if (phase == Phase.REPLY) speakNext()
    }

    private fun gapOver() {
        timer = null
        if (phase != Phase.GAP) return
        if (port.userSpeaking) {
            // Mid-utterance: its result (or its end) decides.
            timer = scheduler.post(POLL_MS) { gapOver() }
            return
        }
        speakNext()
    }

    private fun speakNext() {
        cancelTimer()
        if (next >= chunks.size) {
            finish()
            return
        }
        phase = Phase.SPEAKING
        windowOpen = false
        port.speakChunk(chunks[next++])
    }

    private fun finish() {
        reset()
        port.ended("finished")
    }

    private fun reset() {
        cancelTimer()
        phase = Phase.IDLE
        chunks = emptyList()
        next = 0
        windowOpen = false
    }

    private fun cancelTimer() {
        timer?.let { scheduler.cancel(it) }
        timer = null
    }

    companion object {
        /** How long the recognizer listens between chunks before reading on. */
        const val LISTEN_WINDOW_MS = 1_800L

        /** Read on anyway if listening has not reopened by then (a call, a busy mic). */
        const val READY_TIMEOUT_MS = 4_000L
        const val POLL_MS = 400L
    }
}
