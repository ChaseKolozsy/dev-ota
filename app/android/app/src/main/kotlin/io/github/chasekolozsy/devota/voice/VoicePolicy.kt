package io.github.chasekolozsy.devota.voice

/**
 * Pure decisions for passive listening (docs/passive-voice-control.md), kept
 * free of Android types so the JVM unit tests cover them. The integer codes
 * mirror android.speech.SpeechRecognizer and android.media.AudioAttributes.
 */
internal object RecognizerErrors {
    const val NETWORK_TIMEOUT = 1
    const val NETWORK = 2
    const val AUDIO = 3
    const val SERVER = 4
    const val CLIENT = 5
    const val SPEECH_TIMEOUT = 6
    const val NO_MATCH = 7
    const val RECOGNIZER_BUSY = 8
    const val INSUFFICIENT_PERMISSIONS = 9
    const val TOO_MANY_REQUESTS = 10
    const val SERVER_DISCONNECTED = 11
    const val LANGUAGE_NOT_SUPPORTED = 12
    const val LANGUAGE_UNAVAILABLE = 13
}

internal sealed class RestartDecision {
    /** Start again after [delayMs]; [recreate] discards the recognizer first. */
    data class Retry(val delayMs: Long, val recreate: Boolean = false, val status: String? = null) :
        RestartDecision()

    /** Stop listening for good (the switch goes off) and say why. */
    data class Fatal(val reason: String) : RestartDecision()
}

/**
 * When to start the recognizer again. Silence is normal (the phone ends a
 * session after a few quiet seconds) and restarts at once. Everything else
 * backs off exponentially, so a broken recognizer, no network or a busy
 * microphone never becomes a tight loop, and a rate cap bounds starts per
 * minute whatever the cause.
 */
internal class RestartPolicy(
    private val maxStartsPerMinute: Int = 20,
    private val cooldownMs: Long = 15_000,
) {
    private var fastFailures = 0
    private var networkFailures = 0
    private var busyFailures = 0
    private val starts = ArrayDeque<Long>()

    fun reset() {
        fastFailures = 0
        networkFailures = 0
        busyFailures = 0
        starts.clear()
    }

    /** A result arrived: the recognizer works. */
    fun onSuccess() {
        fastFailures = 0
        networkFailures = 0
        busyFailures = 0
    }

    fun onError(code: Int, elapsedMs: Long, heardSpeech: Boolean): RestartDecision = when (code) {
        RecognizerErrors.NO_MATCH, RecognizerErrors.SPEECH_TIMEOUT ->
            if (heardSpeech || elapsedMs >= SILENCE_SESSION_MS) {
                fastFailures = 0
                networkFailures = 0
                busyFailures = 0
                RestartDecision.Retry(SILENCE_RESTART_MS)
            } else {
                // Returned almost at once: a known recognizer fault, not silence.
                fastFailures++
                RestartDecision.Retry(
                    backoff(500, fastFailures, 30_000),
                    recreate = fastFailures >= 3,
                    status = if (fastFailures >= 3) "Recognizer restarting" else null,
                )
            }
        RecognizerErrors.NETWORK_TIMEOUT, RecognizerErrors.NETWORK,
        RecognizerErrors.SERVER, RecognizerErrors.SERVER_DISCONNECTED -> {
            networkFailures++
            val delay = backoff(2_000, networkFailures, 60_000)
            RestartDecision.Retry(
                delay,
                recreate = code == RecognizerErrors.SERVER_DISCONNECTED,
                status = "No speech service · retrying in ${delay / 1000} s",
            )
        }
        RecognizerErrors.TOO_MANY_REQUESTS ->
            RestartDecision.Retry(60_000, recreate = true, status = "Recognizer rate-limited · retrying in 60 s")
        RecognizerErrors.INSUFFICIENT_PERMISSIONS ->
            RestartDecision.Fatal("Microphone permission missing")
        RecognizerErrors.LANGUAGE_NOT_SUPPORTED, RecognizerErrors.LANGUAGE_UNAVAILABLE ->
            RestartDecision.Fatal("Speech language unavailable")
        RecognizerErrors.AUDIO -> {
            busyFailures++
            val delay = backoff(1_000, busyFailures, 30_000)
            RestartDecision.Retry(delay, recreate = true, status = "Microphone busy · retrying in ${delay / 1000} s")
        }
        else -> { // BUSY, CLIENT and anything new
            busyFailures++
            val delay = backoff(1_000, busyFailures, 30_000)
            RestartDecision.Retry(delay, recreate = true, status = if (busyFailures >= 3) "Recognizer busy · retrying" else null)
        }
    }

    /** 0 when a session may start now, otherwise how long to wait first. */
    fun startDelay(nowMs: Long): Long {
        while (starts.isNotEmpty() && nowMs - starts.first() >= 60_000) starts.removeFirst()
        if (starts.size >= maxStartsPerMinute) return cooldownMs
        return 0
    }

    fun recordStart(nowMs: Long) {
        starts.addLast(nowMs)
    }

    private fun backoff(baseMs: Long, attempt: Int, capMs: Long): Long {
        var d = baseMs
        repeat((attempt - 1).coerceIn(0, 16)) { d = (d * 2).coerceAtMost(capMs) }
        return d.coerceAtMost(capMs)
    }

    companion object {
        /** A session that lasted this long before "no match" was real silence. */
        const val SILENCE_SESSION_MS = 2_000L
        const val SILENCE_RESTART_MS = 100L
    }
}

/** What other audio means for listening. */
internal object PlaybackPolicy {
    enum class Kind { SPEECH, MEDIA, IGNORE }

    // AudioAttributes usages and content types.
    private const val USAGE_UNKNOWN = 0
    private const val USAGE_MEDIA = 1
    private const val USAGE_VOICE_COMMUNICATION = 2
    private const val USAGE_VOICE_COMMUNICATION_SIGNALLING = 3
    private const val USAGE_ASSISTANCE_ACCESSIBILITY = 11
    private const val USAGE_ASSISTANCE_NAVIGATION_GUIDANCE = 12
    private const val USAGE_GAME = 14
    private const val USAGE_ASSISTANT = 16
    private const val CONTENT_TYPE_SPEECH = 1
    private const val CONTENT_TYPE_SONIFICATION = 4

    private val speechUsages = setOf(
        USAGE_VOICE_COMMUNICATION, USAGE_VOICE_COMMUNICATION_SIGNALLING,
        USAGE_ASSISTANCE_ACCESSIBILITY, USAGE_ASSISTANCE_NAVIGATION_GUIDANCE, USAGE_ASSISTANT,
    )
    private val mediaUsages = setOf(USAGE_UNKNOWN, USAGE_MEDIA, USAGE_GAME)

    fun classify(usage: Int, contentType: Int): Kind = when {
        usage in speechUsages -> Kind.SPEECH
        usage in mediaUsages && contentType == CONTENT_TYPE_SPEECH -> Kind.SPEECH
        usage in mediaUsages && contentType != CONTENT_TYPE_SONIFICATION -> Kind.MEDIA
        else -> Kind.IGNORE // alarms, notifications, earcons, ringtones (calls use the audio mode)
    }

    /** Speech is playing (navigation, a podcast, DevOTA's reader): pause. */
    fun speechPlaying(players: List<Pair<Int, Int>>) =
        players.any { classify(it.first, it.second) == Kind.SPEECH }

    /** Something audible is playing: never keep the media stream muted. */
    fun audiblePlaying(players: List<Pair<Int, Int>>) =
        players.any { classify(it.first, it.second) != Kind.IGNORE }

    /** Any audio mode but NORMAL (ringing, in a call, VoIP) pauses listening. */
    fun callActive(audioMode: Int) = audioMode != 0
}

/** The only door to the foreground service and the recognizer. */
internal object StartGate {
    fun refusal(
        switchOn: Boolean,
        appVisible: Boolean,
        micGranted: Boolean,
        recognizerAvailable: Boolean,
    ): String? = when {
        !switchOn -> "Passive listening is off"
        !appVisible -> "Open DevOTA to start listening"
        !micGranted -> "Microphone permission missing"
        !recognizerAvailable -> "No speech recognizer on this phone"
        else -> null
    }
}
