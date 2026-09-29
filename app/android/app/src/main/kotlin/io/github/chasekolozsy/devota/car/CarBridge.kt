package io.github.chasekolozsy.devota.car

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference

/**
 * The native half of DevOTA car control, behind MethodChannel "devota/car".
 *
 * INERT until Dart calls it: attach() only installs the method handler. No
 * media session, PhoneAccount, receiver, foreground service or enabled
 * voice-command alias exists unless startCarMode / probeStart (or
 * setAutoDevice) asks for it, and Dart makes no calls while the car master
 * switch is off. Everything runs on the main thread except the recorder's
 * capture thread and the recognizer's audio feeder.
 */
@SuppressLint("StaticFieldLeak") // Only the application context is held.
internal object CarBridge : CarSpeaker.Listener, CarMediaSession.Listener, CarTelecom.Listener {
    private const val ALIAS = "io.github.chasekolozsy.devota.car.VoiceCommandAlias"

    private val handler = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private var activity: WeakReference<Activity>? = null
    private var channel: MethodChannel? = null
    private const val REDIAL_PERMISSION_REQUEST = 4711

    var carModeActive = false
        private set
    var probeActive = false
        private set
    private var serviceLabel = ""
    private var stoppingService = false

    private var session: CarMediaSession? = null
    private var speaker: CarSpeaker? = null
    private var recognizer: CarRecognizer? = null
    private var probe: CarProbe? = null
    private val recorder = CarRecorder(
        onCap = { handler.post { onRecorderCap() } },
        onError = { code -> handler.post { onRecorderError(code) } },
    )
    private val classifier = CarPressClassifier(
        { delayMs, action ->
            val r = Runnable(action)
            handler.postDelayed(r, delayMs)
            CarCancellable { handler.removeCallbacks(r) }
        },
    ) { press ->
        emitSignal(when (press) {
            CarPress.SINGLE -> "playPause"
            CarPress.DOUBLE -> "playPauseDouble"
            CarPress.LONG -> "playPauseLong"
        }, "media_session")
    }

    /** Swallows the Corolla's automatic PLAY after each NEXT. */
    private val skipEcho = CarSkipEcho()

    private var probeBvraOrder = "none"
    private var carBvraOrder = "none"
    private var headset: BluetoothHeadset? = null
    private var ackedDevice: BluetoothDevice? = null
    private var probeReceiver: BroadcastReceiver? = null
    private var carReceiver: BroadcastReceiver? = null
    private var autoReceiver: BroadcastReceiver? = null
    private var autoAddress: String? = null
    private var modeListener: Any? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var deviceCallbackAt = 0L
    private var realCall = false
    private var dictationMax = 180
    private var awaitingCall: Runnable? = null
    private var earconWait: Runnable? = null
    private var probeSeq = 0

    // ---------------------------------------------------------------- channel

    fun attach(activity: Activity, methodChannel: MethodChannel) {
        app = activity.applicationContext
        this.activity = WeakReference(activity)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (error: Exception) {
                result.error("car", error.message ?: error.javaClass.simpleName, null)
            }
        }
    }

    /** The Dart engine is going away: car mode cannot be driven without it. */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        app?.let { if (carModeActive) stopCarMode(it) }
    }

    private fun emit(method: String, args: Map<String, Any?>) {
        handler.post {
            try { channel?.invokeMethod(method, args) } catch (_: Exception) {}
        }
    }

    private fun emitSignal(button: String, source: String) {
        if (!carModeActive || probeActive) return
        emit("signal", mapOf("button" to button, "source" to source, "t" to System.currentTimeMillis()))
    }

    private fun MethodCall.long(name: String, fallback: Long): Long = argument<Number>(name)?.toLong() ?: fallback
    private fun MethodCall.bool(name: String, fallback: Boolean): Boolean = argument<Boolean>(name) ?: fallback

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ctx = app ?: return result.error("car", "Car control unavailable", null)
        when (call.method) {
            "status" -> result.success(status(ctx))
            "startCarMode" -> {
                serviceLabel = call.argument<String>("label").orEmpty()
                carBvraOrder = if (call.argument<String>("bvraOrder") == "ack") "ack" else "none"
                result.success(startCarMode(ctx, call.bool("withMic", false)))
            }
            "stopCarMode" -> { stopCarMode(ctx); result.success(null) }
            "setPressTiming" -> {
                classifier.configure(call.bool("playPauseDouble", false), call.bool("playPauseLong", false),
                    call.long("doubleMs", 400L), call.long("longMs", 700L))
                result.success(null)
            }
            "speak" -> {
                ensureSpeaker(ctx).speak(call.argument<String>("text").orEmpty(),
                    call.argument<String>("id") ?: "speech", call.bool("interrupt", true))
                result.success(null)
            }
            "stopSpeaking" -> { speaker?.stop(); result.success(null) }
            "earcon" -> { ensureSpeaker(ctx).earcon(call.argument<String>("kind") ?: "tick"); result.success(null) }
            "claimButtons" -> {
                ensureSpeaker(ctx).earcon("claim")
                session?.setPlaying(true)
                handler.postDelayed({ if (speaker?.playing != true) session?.setPlaying(false) }, 400)
                result.success(null)
            }
            "startDictation" -> result.success(startDictation(ctx,
                call.argument<String>("label").orEmpty(), call.long("maxSeconds", 180L).toInt(),
                call.bool("useCall", true)))
            "stopDictation" -> result.success(stopDictation())
            "takeRecording" -> result.success(recorder.wav())
            "discardRecording" -> { recorder.discard(); result.success(null) }
            "recognizeRecording" -> ensureRecognizer(ctx).recognizeRecording(recorder.pcmBytes(),
                call.argument<String>("language")) { result.success(it) }
            "startCommandSession" -> {
                if (!carModeActive) return result.success(mapOf("ok" to false, "call" to false, "error" to "car_mode_off"))
                val error = CarTelecom.place(ctx, "commands", "DevOTA · commands")
                result.success(mapOf("ok" to (error == null), "call" to (error == null), "error" to error))
            }
            "endCommandSession" -> {
                if (CarTelecom.connection?.purpose == "commands") CarTelecom.end()
                result.success(null)
            }
            "listenCommand" -> {
                @Suppress("UNCHECKED_CAST")
                val biasing = (call.argument<List<Any?>>("biasing") ?: emptyList()).mapNotNull { it as? String }
                ensureRecognizer(ctx).listen(biasing, call.long("timeoutMs", 10000L),
                    call.argument<String>("language")) { result.success(it) }
            }
            "cancelListening" -> { recognizer?.cancel(); result.success(null) }
            "bondedDevices" -> result.success(bondedDevices(ctx))
            "setAutoDevice" -> { setAutoDevice(ctx, call.argument<String>("address")); result.success(null) }
            "probeStart" -> result.success(probeStart(ctx, call.argument<String>("bvraOrder") ?: "none",
                call.bool("speak", true)))
            "probeStop" -> { probeStop(ctx); result.success(null) }
            "probePlaceTestCall" -> {
                if (!probeActive) return result.success(mapOf("ok" to false, "error" to "probe_off"))
                val error = CarTelecom.place(ctx, "probe", "DevOTA probe call")
                if (error != null) probe?.log("telecom", "place_failed", mapOf("error" to error))
                result.success(mapOf("ok" to (error == null), "error" to error))
            }
            "probeEndTestCall" -> {
                if (CarTelecom.connection?.purpose == "probe") CarTelecom.end()
                stopVoiceRecognition()
                result.success(null)
            }
            "probeLog" -> result.success(probe?.recent(call.long("limit", 500L).toInt()) ?: emptyList<Any>())
            "probeExport" -> result.success(probe?.export())
            "probeClear" -> { probe?.clear(); result.success(null) }
            "redialGuardStatus" -> result.success(CarRedialLog.status(ctx))
            "requestRedialGuard" -> {
                val a = activity?.get()
                if (a != null && !CarRedialLog.granted(ctx)) {
                    ActivityCompat.requestPermissions(a,
                        arrayOf(Manifest.permission.PROCESS_OUTGOING_CALLS), REDIAL_PERMISSION_REQUEST)
                }
                result.success(null)
            }
            "shareFile" -> result.success(shareFile(ctx, call.argument<String>("path").orEmpty(),
                call.argument<String>("mime") ?: "application/json"))
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- status

    private fun granted(ctx: Context, permission: String) =
        ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

    private fun btPermission(ctx: Context) =
        Build.VERSION.SDK_INT < 31 || granted(ctx, Manifest.permission.BLUETOOTH_CONNECT)

    private fun status(ctx: Context): Map<String, Any?> {
        val rec = ensureRecognizer(ctx)
        val alias = try {
            ctx.packageManager.getComponentEnabledSetting(ComponentName(ctx.packageName, ALIAS)) ==
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } catch (_: Exception) { false }
        return mapOf(
            "serviceRunning" to CarControlService.running,
            "microphoneType" to CarControlService.micType,
            "carModeActive" to carModeActive,
            "probeActive" to probeActive,
            "aliasEnabled" to alias,
            "sdk" to Build.VERSION.SDK_INT,
            "telecomSupported" to CarTelecom.supported(ctx),
            "recognizerAvailable" to rec.available(),
            "onDeviceRecognizer" to rec.onDeviceAvailable(),
            "bluetoothPermission" to btPermission(ctx),
            "micPermission" to granted(ctx, Manifest.permission.RECORD_AUDIO),
            "callActive" to CarTelecom.callActive,
            "recording" to recorder.isRecording,
        )
    }

    // ---------------------------------------------------------------- components

    private fun ensureSpeaker(ctx: Context): CarSpeaker = speaker ?: CarSpeaker(ctx, this).also { speaker = it }

    private fun ensureRecognizer(ctx: Context): CarRecognizer = recognizer ?: CarRecognizer(ctx) { event, detail ->
        probe?.log("recognizer", event, detail)
    }.also { recognizer = it }

    private fun ensureSession(ctx: Context) {
        if (session == null) session = CarMediaSession(ctx, this)
    }

    private fun setAlias(ctx: Context, enabled: Boolean) {
        try {
            ctx.packageManager.setComponentEnabledSetting(ComponentName(ctx.packageName, ALIAS),
                if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP)
        } catch (error: Exception) {
            serviceError("alias_${error.javaClass.simpleName}")
        }
    }

    private fun startCarMode(ctx: Context, withMic: Boolean): Boolean {
        stoppingService = false
        if (!CarControlService.start(ctx, serviceLabel, withMic, probe = false)) return false
        carModeActive = true
        realCall = false
        ensureSession(ctx)
        session?.setTitle("DevOTA car mode")
        setAlias(ctx, true)
        CarTelecom.listener = this
        CarTelecom.register(ctx)?.let { serviceError("telecom_$it") }
        registerCommon(ctx)
        registerCarReceiver(ctx)
        if (carBvraOrder == "ack") openHeadsetProxy(ctx)
        return true
    }

    private fun stopCarMode(ctx: Context) {
        val wasActive = carModeActive
        carModeActive = false
        if (wasActive) {
            cancelPendingCapture()
            recognizer?.cancel()
            recorder.stop()
            recorder.discard()
            if (CarTelecom.connection?.purpose != "probe") CarTelecom.end()
            speaker?.stop()
            classifier.reset()
            skipEcho.reset()
            unregister(ctx, carReceiver)
            carReceiver = null
        }
        releaseIfIdle(ctx)
    }

    /** Tears down everything shared once neither car mode nor the probe runs. */
    private fun releaseIfIdle(ctx: Context) {
        if (carModeActive || probeActive) return
        setAlias(ctx, false)
        session?.release()
        session = null
        speaker?.shutdown()
        speaker = null
        unregisterCommon(ctx)
        stopVoiceRecognition()
        closeHeadsetProxy(ctx)
        CarTelecom.end()
        CarTelecom.unregister(ctx)
        if (CarControlService.running) {
            stoppingService = true
            CarControlService.stop(ctx)
        }
    }

    // ---------------------------------------------------------------- media

    override fun onMediaKey(event: KeyEvent) {
        val up = event.action == KeyEvent.ACTION_UP
        probe?.log("media_button", "key", keyDetail(event))
        if (!carModeActive || probeActive) return
        val firstDown = event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0
        when (event.keyCode) {
            KeyEvent.KEYCODE_MEDIA_NEXT -> if (firstDown) {
                skipEcho.onNext(event.downTime)
                emitSignal("next", "media_session")
            }
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> if (firstDown) emitSignal("previous", "media_session")
            // The Corolla sends every key as an instant down/up, so play and
            // pause are not timing-classified: they are separate signals.
            KeyEvent.KEYCODE_MEDIA_PLAY -> if (firstDown) play(event.downTime)
            KeyEvent.KEYCODE_MEDIA_PAUSE -> if (firstDown) emitSignal("pause", "media_session")
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK -> when {
                event.action == KeyEvent.ACTION_DOWN ->
                    classifier.onDown(if (event.repeatCount == 0) event.downTime else event.eventTime, event.repeatCount)
                up -> classifier.onUp(event.eventTime)
            }
        }
    }

    /** A PLAY: dropped when it is the car's echo of a NEXT, else a signal. */
    private fun play(t: Long) {
        if (skipEcho.swallowPlay(t)) {
            probe?.log("media_button", "play_after_next_swallowed", emptyMap())
            return
        }
        emitSignal("play", "media_session")
    }

    private fun keyDetail(event: KeyEvent): Map<String, Any?> = mapOf(
        "keycode" to KeyEvent.keyCodeToString(event.keyCode),
        "action" to when (event.action) {
            KeyEvent.ACTION_DOWN -> "down"
            KeyEvent.ACTION_UP -> "up"
            else -> "multiple"
        },
        "repeat" to event.repeatCount,
        "downTime" to event.downTime,
        "eventTime" to event.eventTime,
        "heldMs" to if (event.action == KeyEvent.ACTION_UP) event.eventTime - event.downTime else null,
        "deviceId" to event.deviceId,
        "inputSource" to event.source,
        "flags" to event.flags,
        "longPress" to event.isLongPress,
    )

    override fun onTransport(name: String, detail: Map<String, Any?>) {
        probe?.log("media_session", name, detail)
        if (!carModeActive || probeActive) return
        when (name) {
            "onSkipToNext" -> {
                skipEcho.onNext(SystemClock.uptimeMillis())
                emitSignal("next", "media_session")
            }
            "onSkipToPrevious" -> emitSignal("previous", "media_session")
            "onPlay" -> play(SystemClock.uptimeMillis())
            "onPause" -> emitSignal("pause", "media_session")
        }
    }

    /** MainActivity forwards its key events here; logged only while probing, never consumed. */
    fun onActivityKey(event: KeyEvent) {
        if (!probeActive) return
        probe?.log("activity_key", "key", keyDetail(event))
    }

    // ---------------------------------------------------------------- speaker

    override fun onSpeechDone(id: String, ok: Boolean) {
        if (id.startsWith("probe:")) return
        emit("speechDone", mapOf("id" to id, "ok" to ok))
    }

    override fun onSpeakerEvent(event: String, detail: Map<String, Any?>) {
        if (event == "focus_change") probe?.log("audio", event, detail) else probe?.log("speaker", event, detail)
    }

    override fun onPlayingChanged(playing: Boolean) {
        session?.setPlaying(playing)
    }

    override fun onFocusLost(change: Int) {
        if (carModeActive && !probeActive) emit("interrupted", mapOf("reason" to "focus_loss"))
    }

    override fun inCall(): Boolean = CarTelecom.callActive

    private fun ownAudioRecent(): Boolean {
        val s = speaker ?: return false
        return s.playing || SystemClock.elapsedRealtime() - s.lastAudioAt < 1500
    }

    // ---------------------------------------------------------------- dictation

    private fun startDictation(ctx: Context, label: String, maxSeconds: Int, useCall: Boolean): Map<String, Any?> {
        if (!carModeActive) return mapOf("ok" to false, "call" to false, "error" to "car_mode_off")
        if (capturing()) return mapOf("ok" to false, "call" to CarTelecom.callActive, "error" to "already_recording")
        if (!granted(ctx, Manifest.permission.RECORD_AUDIO)) {
            return mapOf("ok" to false, "call" to false, "error" to "microphone_permission")
        }
        recorder.discard()
        dictationMax = maxSeconds.coerceIn(5, 600)
        var callError: String? = null
        var call = false
        if (useCall && !realCall) {
            callError = CarTelecom.place(ctx, "recording", "DevOTA · ${label.ifBlank { "car" }} · recording")
            call = callError == null
        }
        val wait = Runnable { beginCapture(ctx) }
        awaitingCall = wait
        // With a call, wait for Telecom to create it (onTelecomEvent), at most 2 s.
        handler.postDelayed(wait, if (call) 2000L else 0L)
        return mapOf("ok" to true, "call" to call, "error" to callError,
            "microphoneType" to CarControlService.micType)
    }

    private fun capturing() = recorder.isRecording || awaitingCall != null || earconWait != null

    private fun beginCapture(ctx: Context) {
        awaitingCall?.let { handler.removeCallbacks(it) }
        awaitingCall = null
        if (!carModeActive) return
        ensureSpeaker(ctx).earcon("start")
        val start = Runnable {
            earconWait = null
            if (!carModeActive) return@Runnable
            val source = if (CarTelecom.callActive) MediaRecorder.AudioSource.VOICE_COMMUNICATION
                else MediaRecorder.AudioSource.MIC
            val error = recorder.start(ctx, source, dictationMax)
            if (error != null) {
                if (CarTelecom.connection?.purpose == "recording") CarTelecom.end()
                emit("dictationStopped", mapOf("reason" to "error", "error" to error))
            }
        }
        earconWait = start
        // Let the start earcon finish so it is not captured.
        handler.postDelayed(start, 300)
    }

    private fun cancelPendingCapture() {
        awaitingCall?.let { handler.removeCallbacks(it) }
        earconWait?.let { handler.removeCallbacks(it) }
        awaitingCall = null
        earconWait = null
    }

    private fun stopDictation(): Map<String, Any?> {
        cancelPendingCapture()
        val (ms, bytes) = recorder.stop()
        if (CarTelecom.connection?.purpose == "recording") CarTelecom.end()
        return mapOf("durationMs" to ms, "bytes" to bytes)
    }

    private fun onRecorderCap() {
        recorder.stop()
        if (CarTelecom.connection?.purpose == "recording") CarTelecom.end()
        emit("dictationStopped", mapOf("reason" to "cap"))
    }

    private fun onRecorderError(code: String) {
        recorder.stop()
        if (CarTelecom.connection?.purpose == "recording") CarTelecom.end()
        emit("dictationStopped", mapOf("reason" to "error", "error" to code))
    }

    // ---------------------------------------------------------------- telecom

    override fun onTelecomEvent(event: String, detail: Map<String, Any?>) {
        probe?.log("telecom", event, detail)
        if (event == "onCreateOutgoingConnection" && detail["purpose"] == "recording") {
            val wait = awaitingCall ?: return
            handler.removeCallbacks(wait)
            handler.postDelayed(wait, 300) // let the call route settle
        }
    }

    private fun realCallMode(ctx: Context): Boolean {
        val mode = ctx.getSystemService(AudioManager::class.java)?.mode ?: return false
        return isRealCallMode(mode)
    }

    private fun isRealCallMode(mode: Int) = mode == AudioManager.MODE_RINGTONE || mode == AudioManager.MODE_IN_CALL ||
        mode == 4 /* MODE_CALL_SCREENING */ || mode == 5 /* MODE_CALL_REDIRECT */

    override fun onCallHangUp(purpose: String) {
        val ctx = app ?: return
        if (purpose == "probe") stopVoiceRecognition()
        if (!carModeActive || probeActive) return
        if (realCallMode(ctx)) interruptForRealCall() else emitSignal("hangUp", "telecom")
    }

    override fun onCallAnswer(purpose: String) = emitSignal("answer", "telecom")

    override fun onCallHold(purpose: String) {
        if (carModeActive && !probeActive) interruptForRealCall()
    }

    override fun onCallEnded(purpose: String) {
        // A recording call that never came up: capture from the phone mic at once.
        if (purpose == "recording") awaitingCall?.let { wait ->
            handler.removeCallbacks(wait)
            handler.post(wait)
        }
    }

    /**
     * The car redialled the stand-in number and CarRedialReceiver cancelled
     * the carrier call. In car mode the pick-up button then means "dictate".
     */
    fun onStandInRedial(ctx: Context, number: String) {
        if (app == null) app = ctx
        handler.post {
            probe?.log("redial_guard", "cancelled", mapOf("number" to number.take(40)))
            // Give Telecom a moment to finish tearing the cancelled call down
            // before the dictation call is placed.
            if (carModeActive && !probeActive) {
                handler.postDelayed({ emitSignal("redial", "redial_guard") }, 400)
            }
        }
    }

    private fun interruptForRealCall() {
        val first = !realCall
        realCall = true
        speaker?.stop()
        recognizer?.cancel()
        val wasCapturing = capturing()
        cancelPendingCapture()
        if (recorder.isRecording) recorder.stop()
        if (CarTelecom.connection?.purpose != "probe") CarTelecom.end()
        if (wasCapturing) emit("dictationStopped", mapOf("reason" to "interrupted"))
        if (first) emit("interrupted", mapOf("reason" to "real_call"))
    }

    private fun onModeChanged(mode: Int) {
        probe?.log("audio", "mode_changed", mapOf("mode" to modeName(mode), "value" to mode))
        val real = isRealCallMode(mode)
        if (real && !realCall) {
            if (carModeActive && !probeActive) interruptForRealCall() else realCall = true
        } else if (!real && mode == AudioManager.MODE_NORMAL && realCall) {
            realCall = false
            if (carModeActive && !probeActive) emit("resumed", mapOf("reason" to "real_call_ended"))
        }
    }

    private fun modeName(mode: Int) = when (mode) {
        AudioManager.MODE_NORMAL -> "normal"
        AudioManager.MODE_RINGTONE -> "ringtone"
        AudioManager.MODE_IN_CALL -> "in call"
        AudioManager.MODE_IN_COMMUNICATION -> "communication"
        4 -> "call screening"
        5 -> "call redirect"
        6 -> "communication redirect"
        else -> mode.toString()
    }

    // ---------------------------------------------------------------- voice command

    fun onVoiceCommand(activity: Activity, intent: Intent?) {
        val ctx = activity.applicationContext
        if (app == null) app = ctx
        if (!carModeActive && !probeActive) {
            setAlias(ctx, false)
            return
        }
        // The trampoline is resumed right now, which makes a microphone
        // foreground-service start legal even though DevOTA is in the background.
        CarControlService.start(ctx, serviceLabel, withMic = carModeActive, probe = !carModeActive)
        val extras = try { intent?.extras?.keySet()?.sorted()?.joinToString(",") } catch (_: Exception) { null }
        probe?.log("voice_command", "VOICE_COMMAND", mapOf(
            "action" to intent?.action,
            "extras" to extras,
            "referrer" to (if (Build.VERSION.SDK_INT >= 22) activity.referrer?.toString() else null),
            "carMode" to carModeActive,
            "serviceMicType" to CarControlService.micType,
        ))
        if (probeActive) {
            runBvraOrder(ctx)
        } else {
            if (carBvraOrder == "ack") ackVoiceRecognition()
            emitSignal("voice", "voice_command")
        }
    }

    private fun runBvraOrder(ctx: Context) {
        when (probeBvraOrder) {
            "ack" -> ackVoiceRecognition()
            "call" -> placeProbeCall(ctx)
            "ack_then_call" -> {
                ackVoiceRecognition()
                handler.postDelayed({ if (probeActive) placeProbeCall(ctx) }, 300)
            }
            else -> probe?.log("voice_command", "bvra_order", mapOf("order" to "none"))
        }
    }

    private fun placeProbeCall(ctx: Context) {
        val error = CarTelecom.place(ctx, "probe", "DevOTA probe call")
        probe?.log("voice_command", "placeCall", mapOf("ok" to (error == null), "error" to error))
    }

    @SuppressLint("MissingPermission")
    private fun ackVoiceRecognition() {
        val ctx = app ?: return
        if (!btPermission(ctx)) {
            probe?.log("voice_command", "startVoiceRecognition", mapOf("ok" to false, "error" to "bluetooth_permission"))
            return
        }
        val h = headset
        if (h == null) {
            openHeadsetProxy(ctx)
            probe?.log("voice_command", "startVoiceRecognition", mapOf("ok" to false, "error" to "no_headset_proxy"))
            return
        }
        try {
            val device = h.connectedDevices.firstOrNull()
            if (device == null) {
                probe?.log("voice_command", "startVoiceRecognition", mapOf("ok" to false, "error" to "no_headset_device"))
                return
            }
            val ok = h.startVoiceRecognition(device)
            if (ok) ackedDevice = device
            probe?.log("voice_command", "startVoiceRecognition", mapOf("ok" to ok))
        } catch (error: Exception) {
            probe?.log("voice_command", "startVoiceRecognition", mapOf("ok" to false, "error" to error.javaClass.simpleName))
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopVoiceRecognition() {
        val device = ackedDevice ?: return
        ackedDevice = null
        try {
            val ok = headset?.stopVoiceRecognition(device)
            probe?.log("voice_command", "stopVoiceRecognition", mapOf("ok" to ok))
        } catch (_: Exception) {}
    }

    private fun adapter(ctx: Context): BluetoothAdapter? =
        ctx.getSystemService(BluetoothManager::class.java)?.adapter

    private fun openHeadsetProxy(ctx: Context) {
        if (headset != null || !btPermission(ctx)) return
        try {
            adapter(ctx)?.getProfileProxy(ctx, object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    if (profile == BluetoothProfile.HEADSET) {
                        if (carModeActive || probeActive) headset = proxy as BluetoothHeadset
                        else adapter(ctx)?.closeProfileProxy(BluetoothProfile.HEADSET, proxy)
                    }
                }
                override fun onServiceDisconnected(profile: Int) {
                    if (profile == BluetoothProfile.HEADSET) headset = null
                }
            }, BluetoothProfile.HEADSET)
        } catch (error: Exception) {
            serviceError("headset_proxy_${error.javaClass.simpleName}")
        }
    }

    private fun closeHeadsetProxy(ctx: Context) {
        val h = headset ?: return
        headset = null
        try { adapter(ctx)?.closeProfileProxy(BluetoothProfile.HEADSET, h) } catch (_: Exception) {}
    }

    // ---------------------------------------------------------------- probe

    private fun probeStart(ctx: Context, bvraOrder: String, speak: Boolean): Boolean {
        stoppingService = false
        probeBvraOrder = if (bvraOrder in setOf("none", "ack", "call", "ack_then_call")) bvraOrder else "none"
        val label = "Press each steering-wheel button"
        if (!carModeActive) serviceLabel = label
        if (!CarControlService.start(ctx, serviceLabel, withMic = false, probe = !carModeActive)) return false
        probeActive = true
        val p = probe ?: CarProbe(ctx,
            speakLine = { text -> ensureSpeaker(ctx).speak(text, "probe:${++probeSeq}", true) },
            ownAudioRecent = { ownAudioRecent() }).also { probe = it }
        val version = try { ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName } catch (_: Exception) { null }
        p.start(speak, mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "device" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "app" to version,
            "package" to ctx.packageName,
            "bvraOrder" to probeBvraOrder,
        ))
        ensureSession(ctx)
        session?.setTitle("DevOTA car probe")
        setAlias(ctx, true)
        CarTelecom.listener = this
        val telecomError = CarTelecom.register(ctx)
        registerCommon(ctx)
        registerProbeReceivers(ctx)
        openHeadsetProxy(ctx)
        p.log("service", "probe_started", mapOf(
            "bvraOrder" to probeBvraOrder,
            "bluetoothPermission" to btPermission(ctx),
            "micPermission" to granted(ctx, Manifest.permission.RECORD_AUDIO),
            "telecomSupported" to CarTelecom.supported(ctx),
            "telecomError" to telecomError,
            "onDeviceRecognizer" to ensureRecognizer(ctx).onDeviceAvailable(),
        ))
        return true
    }

    private fun probeStop(ctx: Context) {
        if (!probeActive) {
            releaseIfIdle(ctx)
            return
        }
        probe?.log("service", "probe_stopped")
        probe?.stop()
        probeActive = false
        unregister(ctx, probeReceiver)
        probeReceiver = null
        stopVoiceRecognition()
        if (CarTelecom.connection?.purpose == "probe") CarTelecom.end()
        speaker?.stop()
        if (carModeActive) session?.setTitle("DevOTA car mode")
        releaseIfIdle(ctx)
    }

    fun serviceError(what: String) {
        probe?.log("service", "error", mapOf("what" to what))
    }

    fun onNotificationStop() {
        val ctx = app ?: return
        val wasActive = carModeActive || probeActive
        if (probeActive) probeStop(ctx)
        if (carModeActive) stopCarMode(ctx)
        releaseIfIdle(ctx)
        if (wasActive) emit("carModeStopped", mapOf("reason" to "notification"))
    }

    fun onServiceDestroyed() {
        if (stoppingService) {
            stoppingService = false
            return
        }
        val ctx = app ?: return
        if (!carModeActive && !probeActive) return
        // Android killed the foreground service: nothing may keep the car session.
        probe?.log("service", "service_killed")
        if (probeActive) probeStop(ctx)
        if (carModeActive) stopCarMode(ctx)
        emit("carModeStopped", mapOf("reason" to "service_killed"))
    }

    // ---------------------------------------------------------------- receivers

    private fun unregister(ctx: Context, receiver: BroadcastReceiver?) {
        if (receiver == null) return
        try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
    }

    /**
     * Bluetooth state broadcasts are sent by the Bluetooth app's own uid, not
     * by `system`, and a RECEIVER_NOT_EXPORTED receiver can miss them on newer
     * Android. Every action registered here is a protected broadcast that no
     * ordinary app can send, so exporting the receiver admits no spoofing.
     */
    private fun register(ctx: Context, receiver: BroadcastReceiver, filter: IntentFilter) {
        try {
            ContextCompat.registerReceiver(ctx, receiver, filter, ContextCompat.RECEIVER_EXPORTED)
        } catch (error: Exception) {
            serviceError("receiver_${error.javaClass.simpleName}")
        }
    }

    /** Real-call detection, needed by both car mode and the probe. */
    private fun registerCommon(ctx: Context) {
        val manager = ctx.getSystemService(AudioManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 31 && modeListener == null) {
            try {
                val listener = AudioManager.OnModeChangedListener { mode -> handler.post { onModeChanged(mode) } }
                manager.addOnModeChangedListener(ctx.mainExecutor, listener)
                modeListener = listener
            } catch (error: Exception) {
                serviceError("mode_listener_${error.javaClass.simpleName}")
            }
        }
    }

    private fun unregisterCommon(ctx: Context) {
        val manager = ctx.getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let {
                try { manager?.removeOnModeChangedListener(it) } catch (_: Exception) {}
            }
        }
        modeListener = null
        deviceCallback?.let { try { manager?.unregisterAudioDeviceCallback(it) } catch (_: Exception) {} }
        deviceCallback = null
    }

    private fun registerCarReceiver(ctx: Context) {
        if (carReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_ACL_DISCONNECTED -> if (recorder.isRecording) {
                        recorder.stop()
                        if (CarTelecom.connection?.purpose == "recording") CarTelecom.end()
                        emit("dictationStopped", mapOf("reason" to "link_lost"))
                    }
                    AudioManager.ACTION_AUDIO_BECOMING_NOISY -> if (carModeActive && !probeActive) {
                        speaker?.stop()
                        emit("interrupted", mapOf("reason" to "noisy"))
                    }
                }
            }
        }
        carReceiver = receiver
        register(ctx, receiver, IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        })
    }

    @SuppressLint("MissingPermission")
    private fun deviceDetail(ctx: Context, intent: Intent): Map<String, Any?> {
        val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }
        if (device == null) return emptyMap()
        val name = if (btPermission(ctx)) try { device.name } catch (_: Exception) { null } else null
        return mapOf("address" to device.address, "name" to name)
    }

    private fun profileState(state: Int) = when (state) {
        BluetoothProfile.STATE_DISCONNECTED -> "disconnected"
        BluetoothProfile.STATE_CONNECTING -> "connecting"
        BluetoothProfile.STATE_CONNECTED -> "connected"
        BluetoothProfile.STATE_DISCONNECTING -> "disconnecting"
        else -> state.toString()
    }

    private fun registerProbeReceivers(ctx: Context) {
        if (probeReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    try { onProbeBroadcast(ctx, intent) } catch (error: Exception) {
                        serviceError("broadcast_${error.javaClass.simpleName}")
                    }
                }
            }
            probeReceiver = receiver
            val filter = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
                addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
                addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED)
                addAction(BluetoothHeadset.ACTION_AUDIO_STATE_CHANGED)
                addAction(BluetoothHeadset.ACTION_VENDOR_SPECIFIC_HEADSET_EVENT)
                // Vendor events carry a company-id category; list the common ones.
                for (id in listOf(76, 85, 224)) {
                    addCategory("${BluetoothHeadset.VENDOR_SPECIFIC_HEADSET_EVENT_COMPANY_ID_CATEGORY}.$id")
                }
                addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
                addAction(BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED)
                addAction(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
                addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                addAction(AudioManager.ACTION_HEADSET_PLUG)
                addAction("android.media.VOLUME_CHANGED_ACTION")
            }
            register(ctx, receiver, filter)
        }
        val manager = ctx.getSystemService(AudioManager::class.java)
        if (deviceCallback == null && manager != null) {
            val callback = object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                    probe?.log("audio", "devices_added", mapOf(
                        "types" to addedDevices?.joinToString(",") { deviceType(it.type) },
                        "initial" to (SystemClock.elapsedRealtime() - deviceCallbackAt < 800),
                    ))
                }
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                    probe?.log("audio", "devices_removed", mapOf(
                        "types" to removedDevices?.joinToString(",") { deviceType(it.type) },
                    ))
                }
            }
            deviceCallbackAt = SystemClock.elapsedRealtime()
            try {
                manager.registerAudioDeviceCallback(callback, handler)
                deviceCallback = callback
            } catch (error: Exception) {
                serviceError("device_callback_${error.javaClass.simpleName}")
            }
        }
    }

    private fun onProbeBroadcast(ctx: Context, intent: Intent) {
        val p = probe ?: return
        when (intent.action) {
            BluetoothDevice.ACTION_ACL_CONNECTED -> p.log("bluetooth", "ACL_CONNECTED", deviceDetail(ctx, intent))
            BluetoothDevice.ACTION_ACL_DISCONNECTED -> p.log("bluetooth", "ACL_DISCONNECTED", deviceDetail(ctx, intent))
            BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED -> p.log("bluetooth", "HEADSET_CONNECTION_STATE",
                deviceDetail(ctx, intent) + mapOf("state" to profileState(intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1))))
            BluetoothHeadset.ACTION_AUDIO_STATE_CHANGED -> p.log("bluetooth", "HEADSET_AUDIO_STATE",
                deviceDetail(ctx, intent) + mapOf("state" to when (intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)) {
                    BluetoothHeadset.STATE_AUDIO_CONNECTED -> "connected"
                    BluetoothHeadset.STATE_AUDIO_CONNECTING -> "connecting"
                    BluetoothHeadset.STATE_AUDIO_DISCONNECTED -> "disconnected"
                    else -> "unknown"
                }))
            BluetoothHeadset.ACTION_VENDOR_SPECIFIC_HEADSET_EVENT -> {
                @Suppress("DEPRECATION")
                val args = intent.extras?.get(BluetoothHeadset.EXTRA_VENDOR_SPECIFIC_HEADSET_EVENT_ARGS)
                p.log("bluetooth", "VENDOR_SPECIFIC_HEADSET_EVENT", deviceDetail(ctx, intent) + mapOf(
                    "cmd" to intent.getStringExtra(BluetoothHeadset.EXTRA_VENDOR_SPECIFIC_HEADSET_EVENT_CMD),
                    "cmdType" to intent.getIntExtra(BluetoothHeadset.EXTRA_VENDOR_SPECIFIC_HEADSET_EVENT_CMD_TYPE, -1),
                    "args" to ((args as? Array<*>)?.joinToString(",") ?: args?.toString()),
                ))
            }
            BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED -> p.log("bluetooth", "A2DP_CONNECTION_STATE",
                deviceDetail(ctx, intent) + mapOf("state" to profileState(intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1))))
            BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED -> p.log("bluetooth", "A2DP_PLAYING_STATE",
                deviceDetail(ctx, intent) + mapOf("state" to when (intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)) {
                    BluetoothA2dp.STATE_PLAYING -> "playing"
                    BluetoothA2dp.STATE_NOT_PLAYING -> "stopped"
                    else -> "unknown"
                }))
            AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED -> p.log("bluetooth", "SCO_AUDIO_STATE", mapOf(
                "state" to when (intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -2)) {
                    AudioManager.SCO_AUDIO_STATE_CONNECTED -> "connected"
                    AudioManager.SCO_AUDIO_STATE_CONNECTING -> "connecting"
                    AudioManager.SCO_AUDIO_STATE_DISCONNECTED -> "disconnected"
                    AudioManager.SCO_AUDIO_STATE_ERROR -> "error"
                    else -> "unknown"
                }))
            AudioManager.ACTION_AUDIO_BECOMING_NOISY -> p.log("audio", "becoming_noisy")
            AudioManager.ACTION_HEADSET_PLUG -> p.log("audio", "headset_plug", mapOf(
                "state" to if (intent.getIntExtra("state", -1) == 1) "in" else "out"))
            "android.media.VOLUME_CHANGED_ACTION" -> p.log("audio", "volume_changed", mapOf(
                "stream" to intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1),
                "value" to intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_VALUE", -1),
                "previous" to intent.getIntExtra("android.media.EXTRA_PREV_VOLUME_STREAM_VALUE", -1),
            ))
        }
    }

    private fun deviceType(type: Int) = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth media"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth call"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "phone mic"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
        else -> if (Build.VERSION.SDK_INT >= 31 && (type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                type == AudioDeviceInfo.TYPE_BLE_SPEAKER)) "bluetooth le" else "type $type"
    }

    // ---------------------------------------------------------------- bluetooth devices

    @SuppressLint("MissingPermission")
    private fun bondedDevices(ctx: Context): List<Map<String, Any?>> {
        if (!btPermission(ctx)) return emptyList()
        return try {
            adapter(ctx)?.bondedDevices?.map { mapOf("address" to it.address, "name" to it.name) } ?: emptyList()
        } catch (_: Exception) { emptyList() }
    }

    private fun setAutoDevice(ctx: Context, address: String?) {
        unregister(ctx, autoReceiver)
        autoReceiver = null
        autoAddress = address?.takeIf { it.isNotBlank() }
        if (autoAddress == null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val detail = deviceDetail(ctx, intent)
                if (detail["address"] != autoAddress) return
                val connected = intent.action == BluetoothDevice.ACTION_ACL_CONNECTED
                emit("carDevice", mapOf("connected" to connected, "address" to detail["address"], "name" to detail["name"]))
            }
        }
        autoReceiver = receiver
        register(ctx, receiver, IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        })
    }

    // ---------------------------------------------------------------- export

    private fun shareFile(ctx: Context, path: String, mime: String): Boolean {
        return try {
            val file = File(path).canonicalFile
            val root = File(ctx.filesDir, "car_probe").canonicalFile
            if (!file.path.startsWith(root.path + File.separator) || !file.isFile) return false
            val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).setType(mime)
                .putExtra(Intent.EXTRA_STREAM, uri)
                .putExtra(Intent.EXTRA_SUBJECT, "DevOTA car probe log")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            ctx.startActivity(Intent.createChooser(send, "Send car probe log")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION))
            true
        } catch (_: Exception) { false }
    }
}
