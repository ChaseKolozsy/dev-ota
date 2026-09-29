package io.github.chasekolozsy.devota.voice

/** The recognizer as the loop sees it (SpeechRecognizer in production). */
internal interface RecognizerPort {
    /** Creates a fresh recognizer. False when none is available. */
    fun create(): Boolean

    /** Starts one session; its callbacks must carry [session]. */
    fun start(session: Int)
    fun cancel()
    fun destroy()
}

internal interface LoopScheduler {
    fun post(delayMs: Long, block: () -> Unit): Any
    fun cancel(token: Any)
}

internal enum class LoopState { OFF, LISTENING, WAITING, PAUSED }

internal interface LoopListener {
    /** A final transcript. The loop holds ("reply") until [ListeningLoop.release]. */
    fun onUtterance(text: String)
    fun onState(state: LoopState, detail: String?)

    /** The loop disabled itself; the service must stop. */
    fun onFatal(reason: String)

    /** A session is about to start (quiet the restart beep). */
    fun onSessionStarting()

    /** Listening paused for audio or a call (stop quieting other audio). */
    fun onPaused()
}

/**
 * Keeps the phone's recognizer listening, one session after another, until
 * [disable]. Every recognizer creation and start goes through [startSession],
 * which refuses while disabled or held, and callbacks from an old session are
 * ignored, so after [disable] nothing can start the recognizer again.
 *
 * Holds pause listening: "speak" (DevOTA talking), "playback" (the phone
 * playing speech), "call" (the audio mode is not normal) and "reply" (Dart
 * deciding what an utterance was).
 */
internal class ListeningLoop(
    private val port: RecognizerPort,
    private val scheduler: LoopScheduler,
    private val clock: () -> Long,
    private val listener: LoopListener,
    private val policy: RestartPolicy = RestartPolicy(),
) {
    var enabled = false
        private set
    private val holds = linkedSetOf<String>()
    private var hasRecognizer = false
    private var sessionActive = false
    private var session = 0
    private var sessionStartedAt = 0L
    private var heardSpeech = false
    private var restartToken: Any? = null
    private var waitingStatus: String? = null

    val held: Set<String> get() = holds
    val listening get() = sessionActive

    fun enable() {
        if (enabled) return
        enabled = true
        policy.reset()
        schedule(0, null)
    }

    fun disable() {
        val wasEnabled = enabled
        enabled = false
        holds.clear()
        cancelRestart()
        if (sessionActive) {
            sessionActive = false
            session++
            port.cancel()
        }
        if (hasRecognizer) {
            hasRecognizer = false
            port.destroy()
        }
        if (wasEnabled) {
            listener.onPaused()
            listener.onState(LoopState.OFF, null)
        }
    }

    fun hold(reason: String) {
        if (!enabled || !holds.add(reason)) return
        if (holds.size > 1) return
        cancelRestart()
        if (sessionActive) {
            sessionActive = false
            session++
            port.cancel()
        }
        if (reason != REPLY) listener.onPaused()
        listener.onState(LoopState.PAUSED, reason)
    }

    fun release(reason: String) {
        if (!holds.remove(reason)) return
        if (enabled && holds.isEmpty()) schedule(RESUME_DELAY_MS, null)
    }

    fun onReady(id: Int) {
        if (id != session || !sessionActive) return
        listener.onState(LoopState.LISTENING, null)
    }

    fun onBeginningOfSpeech(id: Int) {
        if (id == session && sessionActive) heardSpeech = true
    }

    fun onResults(id: Int, text: String?) {
        if (id != session || !sessionActive) return
        sessionActive = false
        policy.onSuccess()
        val clean = text?.trim().orEmpty()
        if (clean.isEmpty()) {
            schedule(RestartPolicy.SILENCE_RESTART_MS, null)
            return
        }
        holds.add(REPLY)
        listener.onState(LoopState.PAUSED, REPLY)
        listener.onUtterance(clean)
    }

    fun onError(id: Int, code: Int) {
        if (id != session || !sessionActive) return
        sessionActive = false
        when (val decision = policy.onError(code, clock() - sessionStartedAt, heardSpeech)) {
            is RestartDecision.Fatal -> {
                disable()
                listener.onFatal(decision.reason)
            }
            is RestartDecision.Retry -> {
                if (decision.recreate && hasRecognizer) {
                    hasRecognizer = false
                    port.destroy()
                }
                schedule(decision.delayMs, decision.status)
            }
        }
    }

    private fun schedule(delayMs: Long, status: String?) {
        cancelRestart()
        if (!enabled || holds.isNotEmpty()) return
        waitingStatus = status
        if (status != null) listener.onState(LoopState.WAITING, status)
        restartToken = scheduler.post(delayMs) {
            restartToken = null
            startSession()
        }
    }

    private fun startSession() {
        if (!enabled || holds.isNotEmpty() || sessionActive) return
        val wait = policy.startDelay(clock())
        if (wait > 0) {
            schedule(wait, "Pausing: too many restarts")
            return
        }
        if (!hasRecognizer) {
            if (!port.create()) {
                disable()
                listener.onFatal("No speech recognizer on this phone")
                return
            }
            hasRecognizer = true
        }
        session++
        sessionActive = true
        heardSpeech = false
        sessionStartedAt = clock()
        policy.recordStart(sessionStartedAt)
        listener.onSessionStarting()
        port.start(session)
        if (waitingStatus != null) {
            waitingStatus = null
            listener.onState(LoopState.LISTENING, null)
        }
    }

    private fun cancelRestart() {
        restartToken?.let { scheduler.cancel(it) }
        restartToken = null
    }

    companion object {
        const val REPLY = "reply"
        const val SPEAK = "speak"
        const val PLAYBACK = "playback"
        const val CALL = "call"
        const val RESUME_DELAY_MS = 250L
    }
}
