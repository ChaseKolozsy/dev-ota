package io.github.chasekolozsy.devota.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.github.chasekolozsy.devota.TerminalActionReceiver

/**
 * Passive listening (docs/passive-voice-control.md): a microphone foreground
 * service, started only from the visible app, that keeps the phone's own
 * SpeechRecognizer listening one session after another and hands each final
 * transcript to Dart, which decides whether it is a command or dictation.
 *
 * It never sends anything itself. It pauses while DevOTA or the phone plays
 * speech and while the audio mode is not normal (calls), and it stops when
 * the switch goes off, on "stop listening", on the notification's Stop, when
 * DevOTA is removed from recents or its engine goes away, and on a fatal
 * recognizer error. Transcripts are held in memory only and never logged.
 */
@RequiresApi(Build.VERSION_CODES.O)
internal class PassiveVoiceService : Service(), LoopListener {
    companion object {
        const val ACTION_START = "io.github.chasekolozsy.devota.voice.START"
        private const val EXTRA_QUIET = "quietBeeps"
        private const val EXTRA_STATUS = "status"
        private const val CHANNEL_ID = "passive_voice"
        private const val NOTIFICATION_ID = 24090
        private const val REPLY_TIMEOUT_MS = 5_000L
        private const val WAKE_TIMEOUT_MS = 30 * 60 * 1000L

        @Volatile
        var running = false
            private set
        internal var instance: PassiveVoiceService? = null
            private set

        internal fun start(context: Context, quietBeeps: Boolean, status: String) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, PassiveVoiceService::class.java)
                    .setAction(ACTION_START)
                    .putExtra(EXTRA_QUIET, quietBeeps)
                    .putExtra(EXTRA_STATUS, status),
            )
        }

        internal fun stop(context: Context, reason: String) {
            val service = instance
            if (service != null) service.stopWith(reason)
            else context.stopService(Intent(context, PassiveVoiceService::class.java))
        }

        /** Broadcast (not a service start) so Stop works from any state. */
        internal fun stopIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context,
            24091,
            Intent(context, TerminalActionReceiver::class.java)
                .setData(android.net.Uri.parse("devota-voice://stop"))
                .putExtra("voiceAction", "stop"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var audio: AudioManager
    private lateinit var quieter: BeepQuieter
    private lateinit var loop: ListeningLoop
    private var recognizer: SpeechRecognizer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val speechQueue = ArrayDeque<String>()
    private var speaking = 0
    private var speechGeneration = 0
    private var focus: AudioFocusRequest? = null
    private var replyToken = 0
    private var statusText = "Listening"
    private var stateLabel = "Starting"
    private var stopped = false
    private var modeListener: Any? = null
    private val modePoll = object : Runnable {
        override fun run() {
            checkCallMode()
            handler.postDelayed(this, 3_000)
        }
    }

    private val scheduler = object : LoopScheduler {
        override fun post(delayMs: Long, block: () -> Unit): Any {
            val r = Runnable { block() }
            handler.postDelayed(r, delayMs)
            return r
        }

        override fun cancel(token: Any) = handler.removeCallbacks(token as Runnable)
    }

    private val port = object : RecognizerPort {
        override fun create(): Boolean {
            if (!SpeechRecognizer.isRecognitionAvailable(this@PassiveVoiceService)) return false
            recognizer = try {
                SpeechRecognizer.createSpeechRecognizer(this@PassiveVoiceService)
            } catch (_: Exception) {
                null
            }
            return recognizer != null
        }

        override fun start(session: Int) {
            val r = recognizer
            if (r == null) {
                handler.post { loop.onError(session, RecognizerErrors.CLIENT) }
                return
            }
            r.setRecognitionListener(listenerFor(session))
            try {
                r.startListening(recognizerIntent())
            } catch (_: Exception) {
                handler.post { loop.onError(session, RecognizerErrors.CLIENT) }
            }
        }

        override fun cancel() {
            try { recognizer?.cancel() } catch (_: Exception) {}
        }

        override fun destroy() {
            try { recognizer?.destroy() } catch (_: Exception) {}
            recognizer = null
        }
    }

    private val playbackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>) {
            evaluatePlayback(configs)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        audio = getSystemService(AudioManager::class.java)
        quieter = BeepQuieter(this, audio)
        BeepQuieter.recover(this)
        loop = ListeningLoop(port, scheduler, { android.os.SystemClock.elapsedRealtime() }, this)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START) {
            // Never resurrect after a process restart: the switch lives in Dart.
            stopSelf()
            return START_NOT_STICKY
        }
        // startForegroundService() requires this promptly, whatever follows.
        startForegroundCompat(notification())
        if (stopped) {
            // Switched on again before the previous stop finished destroying us.
            stopped = false
            instance = this
        }
        quieter.enabled = intent.getBooleanExtra(EXTRA_QUIET, true)
        intent.getStringExtra(EXTRA_STATUS)?.takeIf { it.isNotBlank() }?.let { statusText = it }
        if (!running) {
            running = true
            acquireWake()
            audio.registerAudioPlaybackCallback(playbackCallback, handler)
            watchCallMode()
            loop.enable()
            evaluatePlayback(audio.activePlaybackConfigurations)
            checkCallMode()
            PassiveVoice.onServiceChanged()
        } else {
            refreshNotification()
        }
        return START_NOT_STICKY
    }

    /** Swiping DevOTA away removes the engine that decides what speech means. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopWith("DevOTA was closed")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        teardown("stopped")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    internal fun stopWith(reason: String) {
        teardown(reason)
        stopSelf()
    }

    private fun teardown(reason: String) {
        if (stopped) return
        stopped = true
        replyToken++
        loop.disable()
        handler.removeCallbacksAndMessages(null)
        try { audio.unregisterAudioPlaybackCallback(playbackCallback) } catch (_: Exception) {}
        unwatchCallMode()
        stopSpeech()
        tts?.shutdown()
        tts = null
        quieter.off()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        running = false
        instance = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        PassiveVoice.onServiceStopped(reason)
    }

    // ---- LoopListener -------------------------------------------------------

    override fun onUtterance(text: String) {
        val token = ++replyToken
        handler.postDelayed({
            // Dart did not answer: listen again rather than hang.
            if (token == replyToken && !stopped) {
                replyToken++
                loop.release(ListeningLoop.REPLY)
            }
        }, REPLY_TIMEOUT_MS)
        val delivered = PassiveVoice.deliverUtterance(text) { reply ->
            handler.post { if (token == replyToken && !stopped) handleReply(reply) }
        }
        if (!delivered) stopWith("DevOTA was closed")
    }

    private fun handleReply(reply: Map<*, *>?) {
        replyToken++
        if (reply == null || reply["stop"] == true) {
            stopWith("Passive listening is off")
            return
        }
        val tone = reply["tone"] as? String
        val deferred = deferredSpeech.joinToString(" ")
        deferredSpeech.clear()
        handler.removeCallbacks(flushDeferred)
        val speech = listOf(deferred, reply["speak"] as? String ?: "")
            .filter { it.isNotBlank() }
            .joinToString(" ")
            .takeIf { it.isNotBlank() }
        quieter.off()
        val toneMs = if (tone != null && VoiceTones.known(tone)) playTone(tone) else 0L
        handler.postDelayed({
            if (stopped) return@postDelayed
            if (speech != null) speak(speech)
            loop.release(ListeningLoop.REPLY)
        }, toneMs + 60)
    }

    override fun onState(state: LoopState, detail: String?) {
        stateLabel = when (state) {
            LoopState.OFF -> "Off"
            LoopState.LISTENING -> "Listening"
            LoopState.WAITING -> detail ?: "Waiting"
            LoopState.PAUSED -> when (detail) {
                ListeningLoop.CALL -> "Paused · call"
                ListeningLoop.PLAYBACK -> "Paused · audio playing"
                ListeningLoop.SPEAK -> "Speaking"
                else -> "Listening"
            }
        }
        refreshNotification()
        PassiveVoice.onState(stateLabel)
    }

    override fun onFatal(reason: String) = stopWith(reason)

    override fun onSessionStarting() {
        acquireWake()
        val players = audio.activePlaybackConfigurations.map {
            it.audioAttributes.usage to it.audioAttributes.contentType
        }
        if (!PlaybackPolicy.audiblePlaying(players)) quieter.on()
    }

    override fun onPaused() = quieter.off()

    // ---- Public calls from Dart ----------------------------------------------

    internal fun updateStatus(text: String) {
        statusText = text.take(200)
        refreshNotification()
    }

    private val deferredSpeech = ArrayDeque<String>()
    private val flushDeferred = object : Runnable {
        override fun run() {
            if (stopped || deferredSpeech.isEmpty()) return
            if (loop.userSpeaking) {
                handler.postDelayed(this, 500)
                return
            }
            val text = deferredSpeech.joinToString(" ")
            deferredSpeech.clear()
            speak(text)
        }
    }

    internal fun speak(text: String) {
        if (stopped || text.isBlank()) return
        if (loop.userSpeaking) {
            // Never talk over the owner: say it once their utterance ends.
            deferredSpeech.addLast(text.take(1_000))
            handler.removeCallbacks(flushDeferred)
            handler.postDelayed(flushDeferred, 500)
            return
        }
        loop.hold(ListeningLoop.SPEAK)
        quieter.off()
        speechQueue.addLast(text.take(3_500))
        ensureTts()
        pumpSpeech()
    }

    // ---- Speech and tones ------------------------------------------------------

    private fun ensureTts() {
        if (tts != null) return
        val generation = ++speechGeneration
        tts = TextToSpeech(applicationContext) { status ->
            handler.post {
                if (generation != speechGeneration || stopped) return@post
                ttsReady = status == TextToSpeech.SUCCESS
                if (!ttsReady) {
                    speechQueue.clear()
                    finishSpeech()
                } else {
                    tts?.setAudioAttributes(speechAttributes)
                    tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) = Unit
                        override fun onDone(utteranceId: String?) {
                            handler.post { onUtteranceDone() }
                        }

                        @Deprecated("Legacy TTS callback")
                        override fun onError(utteranceId: String?) {
                            handler.post { onUtteranceDone() }
                        }
                    })
                    pumpSpeech()
                }
            }
        }
    }

    private fun pumpSpeech() {
        val engine = tts ?: return
        if (!ttsReady) return
        while (speechQueue.isNotEmpty()) {
            val text = speechQueue.removeFirst()
            takeFocus()
            speaking++
            if (engine.speak(text, TextToSpeech.QUEUE_ADD, null, "voice:$speaking:${text.hashCode()}") ==
                TextToSpeech.ERROR) {
                speaking--
            }
        }
        if (speaking == 0) finishSpeech()
    }

    private fun onUtteranceDone() {
        if (speaking > 0) speaking--
        if (speaking == 0 && speechQueue.isEmpty()) finishSpeech()
    }

    private fun finishSpeech() {
        abandonFocus()
        // Let the last syllable leave the speaker before the mic opens again.
        handler.postDelayed({ if (!stopped && speaking == 0) loop.release(ListeningLoop.SPEAK) }, 300)
    }

    private fun stopSpeech() {
        speechQueue.clear()
        speaking = 0
        try { tts?.stop() } catch (_: Exception) {}
        abandonFocus()
    }

    private val speechAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    private fun takeFocus() {
        if (focus != null) return
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(speechAttributes)
            .build()
        focus = request
        try { audio.requestAudioFocus(request) } catch (_: Exception) {}
    }

    private fun abandonFocus() {
        focus?.let { try { audio.abandonAudioFocusRequest(it) } catch (_: Exception) {} }
        focus = null
    }

    /** Plays one earcon; returns its length in ms. */
    private fun playTone(kind: String): Long {
        val pcm = VoiceTones.pcm(kind)
        return try {
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(VoiceTones.SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(pcm.size * 2)
                .build()
            track.write(pcm, 0, pcm.size)
            track.play()
            val ms = pcm.size * 1000L / VoiceTones.SAMPLE_RATE
            handler.postDelayed({ try { track.release() } catch (_: Exception) {} }, ms + 200)
            ms
        } catch (_: Exception) {
            0L
        }
    }

    // ---- Recognizer ------------------------------------------------------------

    private fun recognizerIntent() = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
        // Hints only; recognizers are free to ignore them.
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2_000L)
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1_500L)
    }

    private fun listenerFor(session: Int) = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = loop.onReady(session)
        override fun onBeginningOfSpeech() = loop.onBeginningOfSpeech(session)
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onPartialResults(partialResults: Bundle?) = Unit
        override fun onEvent(eventType: Int, params: Bundle?) = Unit
        override fun onError(error: Int) = loop.onError(session, error)
        override fun onResults(results: Bundle?) = loop.onResults(
            session,
            results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull(),
        )
    }

    // ---- Audio around us ---------------------------------------------------------

    private fun evaluatePlayback(configs: List<AudioPlaybackConfiguration>) {
        if (stopped) return
        val players = configs.map { it.audioAttributes.usage to it.audioAttributes.contentType }
        if (PlaybackPolicy.audiblePlaying(players)) quieter.off()
        if (PlaybackPolicy.speechPlaying(players)) loop.hold(ListeningLoop.PLAYBACK)
        else loop.release(ListeningLoop.PLAYBACK)
    }

    private fun checkCallMode() {
        if (stopped) return
        if (PlaybackPolicy.callActive(audio.mode)) loop.hold(ListeningLoop.CALL)
        else loop.release(ListeningLoop.CALL)
    }

    private fun watchCallMode() {
        if (Build.VERSION.SDK_INT >= 31) {
            val listener = AudioManager.OnModeChangedListener { handler.post { checkCallMode() } }
            audio.addOnModeChangedListener(ContextCompat.getMainExecutor(this), listener)
            modeListener = listener
        } else {
            handler.postDelayed(modePoll, 3_000)
        }
    }

    private fun unwatchCallMode() {
        if (Build.VERSION.SDK_INT >= 31) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let {
                try { audio.removeOnModeChangedListener(it) } catch (_: Exception) {}
            }
        }
        modeListener = null
        handler.removeCallbacks(modePoll)
    }

    private fun acquireWake() {
        val lock = wakeLock ?: getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "devota:passive-voice")
            .apply { setReferenceCounted(false) }
            .also { wakeLock = it }
        // Re-armed on every session, so a stuck loop cannot hold it forever.
        lock.acquire(WAKE_TIMEOUT_MS)
    }

    // ---- Notification ------------------------------------------------------------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Passive listening", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while DevOTA listens for voice commands and dictation"
                setShowBadge(false)
            },
        )
    }

    private fun notification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val content = launch?.let {
            PendingIntent.getActivity(
                this, NOTIFICATION_ID, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("DevOTA · $stateLabel")
            .setContentText(statusText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .apply { if (content != null) setContentIntent(content) }
            .addAction(Notification.Action.Builder(null, "Stop", stopIntent(this)).build())
            .build()
    }

    private fun refreshNotification() {
        if (!running || stopped) return
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}

/**
 * Quiets the recognizer's restart beeps by muting the media stream while a
 * session starts and listens, and ONLY while nothing audible is playing, the
 * user has not muted it already, and the owner left "Quiet restart beeps"
 * on. It unmutes the moment listening pauses, other audio starts, DevOTA
 * speaks or plays a tone, or the service stops; a mute left behind by a
 * crash is undone on the next start of DevOTA (the flag is persisted).
 */
internal class BeepQuieter(private val context: Context, private val audio: AudioManager) {
    var enabled = true
    private var muted = false

    fun on() {
        if (!enabled || muted || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            if (audio.isStreamMute(AudioManager.STREAM_MUSIC) || audio.isMusicActive) return
            prefs(context).edit().putBoolean(KEY, true).commit()
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
            muted = true
        } catch (_: Exception) {
            prefs(context).edit().remove(KEY).apply()
        }
    }

    fun off() {
        if (!muted) return
        muted = false
        unmute(context, audio)
    }

    companion object {
        private const val KEY = "media_muted_by_passive_voice"
        private fun prefs(context: Context) =
            context.getSharedPreferences("devota_passive_voice", Context.MODE_PRIVATE)

        private fun unmute(context: Context, audio: AudioManager) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
                } catch (_: Exception) {}
            }
            prefs(context).edit().remove(KEY).apply()
        }

        /** Undoes a mute a killed process left behind. */
        fun recover(context: Context) {
            if (!prefs(context).getBoolean(KEY, false)) return
            unmute(context, context.getSystemService(AudioManager::class.java))
        }
    }
}
