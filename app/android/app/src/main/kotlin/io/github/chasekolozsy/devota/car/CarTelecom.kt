package io.github.chasekolozsy.devota.car

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.telecom.CallAudioState
import android.telecom.CallEndpoint
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.annotation.RequiresApi

/**
 * A self-managed Telecom call that stands for a DevOTA recording or command
 * session, so the car shows a call, routes its mic, and delivers HANG-UP
 * (proposal F9/F10). The PhoneAccount exists only while car mode or the probe
 * runs; nothing is registered at app start.
 */
internal object CarTelecom {
    const val ACCOUNT_ID = "devota_car"

    interface Listener {
        fun onTelecomEvent(event: String, detail: Map<String, Any?>)
        fun onCallHangUp(purpose: String)
        fun onCallAnswer(purpose: String)
        fun onCallHold(purpose: String)
        fun onCallEnded(purpose: String)
    }

    var listener: Listener? = null
    internal var pendingPurpose = "recording"

    /** What the car shows for the call (HFP/CNAP name). */
    const val DISPLAY_NAME = "DevOTA"

    /**
     * elapsedRealtime until which the redial guard stands aside for DevOTA's
     * own placement (Telecom does not broadcast self-managed calls; this is
     * belt and braces so the guard can never cancel DevOTA's own call).
     */
    @Volatile var ownPlacementUntil = 0L
        private set
    var connection: DevotaConnection? = null
        internal set
    val callActive get() = connection != null

    fun handle(ctx: Context) = PhoneAccountHandle(
        ComponentName(ctx, DevotaConnectionService::class.java), ACCOUNT_ID)

    fun supported(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        val pm = ctx.packageManager
        @Suppress("DEPRECATION")
        return pm.hasSystemFeature(PackageManager.FEATURE_CONNECTION_SERVICE) ||
            pm.hasSystemFeature(PackageManager.FEATURE_TELECOM)
    }

    /** Returns null on success or an error string. */
    fun register(ctx: Context): String? {
        if (!supported(ctx)) return "unsupported"
        return try {
            val account = PhoneAccount.builder(handle(ctx), "DevOTA car")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .setShortDescription("DevOTA steering-wheel recording and commands")
                .build()
            ctx.getSystemService(TelecomManager::class.java).registerPhoneAccount(account)
            null
        } catch (error: Exception) {
            "register_${error.javaClass.simpleName}"
        }
    }

    fun unregister(ctx: Context) {
        if (!supported(ctx)) return
        try { ctx.getSystemService(TelecomManager::class.java).unregisterPhoneAccount(handle(ctx)) } catch (_: Exception) {}
    }

    /** Places the self-managed call. Returns null on success or an error string. */
    @SuppressLint("MissingPermission")
    fun place(ctx: Context, purpose: String, label: String): String? {
        if (Build.VERSION.SDK_INT < 26 || !supported(ctx)) return "unsupported"
        if (connection != null) return "call_active"
        register(ctx)?.let { return it }
        val telecom = ctx.getSystemService(TelecomManager::class.java)
        val h = handle(ctx)
        return try {
            if (!telecom.isOutgoingCallPermitted(h)) return "not_permitted"
            pendingPurpose = purpose
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, h)
                putBoolean(TelecomManager.EXTRA_START_CALL_WITH_SPEAKERPHONE, false)
            }
            ownPlacementUntil = SystemClock.elapsedRealtime() + CarStandIn.OWN_PLACEMENT_GRACE_MS
            // The address is what the car stores and later redials: see
            // CarStandIn for why it is 10000000 and how the redial is caught.
            // DevOTA holds MANAGE_OWN_CALLS only (no CALL_PHONE), so Telecom
            // cannot turn this into a carrier call.
            telecom.placeCall(Uri.fromParts("tel", CarStandIn.NUMBER, null), extras)
            listener?.onTelecomEvent("place", mapOf("purpose" to purpose, "label" to label.take(80)))
            null
        } catch (error: Exception) {
            "place_${error.javaClass.simpleName}"
        }
    }

    fun end() {
        connection?.endLocal()
    }

    internal fun event(event: String, detail: Map<String, Any?> = emptyMap()) {
        listener?.onTelecomEvent(event, detail)
    }

    internal fun created(c: DevotaConnection) {
        connection = c
        event("onCreateOutgoingConnection", mapOf("purpose" to c.purpose))
    }

    internal fun ended(c: DevotaConnection) {
        if (connection === c) connection = null
        listener?.onCallEnded(c.purpose)
    }
}

class DevotaConnectionService : ConnectionService() {
    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        val purpose = CarTelecom.pendingPurpose
        val c = DevotaConnection(purpose)
        if (Build.VERSION.SDK_INT >= 26) c.setConnectionProperties(Connection.PROPERTY_SELF_MANAGED)
        c.setAudioModeIsVoip(true)
        c.setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
        c.setCallerDisplayName(CarTelecom.DISPLAY_NAME, TelecomManager.PRESENTATION_ALLOWED)
        c.setConnectionCapabilities(Connection.CAPABILITY_HOLD or Connection.CAPABILITY_SUPPORT_HOLD)
        c.setActive()
        CarTelecom.created(c)
        return c
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        CarTelecom.event("onCreateOutgoingConnectionFailed", mapOf("purpose" to CarTelecom.pendingPurpose))
        CarTelecom.listener?.onCallEnded(CarTelecom.pendingPurpose)
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection = Connection.createFailedConnection(DisconnectCause(DisconnectCause.ERROR))
}

class DevotaConnection(val purpose: String) : Connection() {
    private var ended = false

    private fun close(cause: Int) {
        if (ended) return
        ended = true
        setDisconnected(DisconnectCause(cause))
        destroy()
        CarTelecom.ended(this)
    }

    /** DevOTA itself ends the call (stop, cap, car mode off). */
    fun endLocal() = close(DisconnectCause.LOCAL)

    override fun onDisconnect() {
        CarTelecom.event("onDisconnect", mapOf("purpose" to purpose))
        if (!ended) CarTelecom.listener?.onCallHangUp(purpose)
        close(DisconnectCause.LOCAL)
    }

    override fun onAbort() {
        CarTelecom.event("onAbort", mapOf("purpose" to purpose))
        close(DisconnectCause.OTHER)
    }

    override fun onHold() {
        CarTelecom.event("onHold", mapOf("purpose" to purpose))
        setOnHold()
        CarTelecom.listener?.onCallHold(purpose)
    }

    override fun onUnhold() {
        CarTelecom.event("onUnhold", mapOf("purpose" to purpose))
        setActive()
    }

    override fun onAnswer() {
        CarTelecom.event("onAnswer", mapOf("purpose" to purpose))
        CarTelecom.listener?.onCallAnswer(purpose)
    }

    override fun onAnswer(videoState: Int) = onAnswer()

    override fun onReject() {
        CarTelecom.event("onReject", mapOf("purpose" to purpose))
    }

    override fun onPlayDtmfTone(c: Char) {
        CarTelecom.event("onPlayDtmfTone", mapOf("char" to c.toString()))
    }

    override fun onStopDtmfTone() {
        CarTelecom.event("onStopDtmfTone")
    }

    override fun onSilence() {
        CarTelecom.event("onSilence")
    }

    override fun onStateChanged(state: Int) {
        CarTelecom.event("onStateChanged", mapOf("state" to Connection.stateToString(state)))
    }

    @Deprecated("Deprecated in API 34; onCallEndpointChanged is logged there too")
    override fun onCallAudioStateChanged(state: CallAudioState?) {
        if (state == null) return
        CarTelecom.event("onCallAudioStateChanged", mapOf(
            "route" to CallAudioState.audioRouteToString(state.route).lowercase().replace('_', ' '),
            "muted" to state.isMuted,
            "bluetooth" to (Build.VERSION.SDK_INT >= 28 && state.activeBluetoothDevice != null),
        ))
    }

    @RequiresApi(34)
    override fun onCallEndpointChanged(callEndpoint: CallEndpoint) {
        CarTelecom.event("onCallEndpointChanged", mapOf(
            "name" to callEndpoint.endpointName.toString().take(60),
            "type" to callEndpoint.endpointType,
        ))
    }
}
