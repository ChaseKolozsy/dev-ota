package io.github.chasekolozsy.devota.car

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat

/**
 * Holds the process at foreground priority while car mode or the car probe
 * runs. All car state lives in CarBridge; this service only owns the ongoing
 * notification and the foreground-service type (mediaPlayback, plus
 * microphone when started from a visible activity, proposal F22).
 */
class CarControlService : Service() {
    companion object {
        const val ACTION_STOP = "io.github.chasekolozsy.devota.car.STOP"
        private const val EXTRA_LABEL = "label"
        private const val EXTRA_MIC = "withMic"
        private const val EXTRA_PROBE = "probe"
        private const val CHANNEL_ID = "car_mode"
        private const val NOTIFICATION_ID = 24090

        @Volatile var running = false
            private set
        @Volatile var micType = false
            private set

        /** Returns false if Android refused to start the service at all. */
        fun start(ctx: Context, label: String, withMic: Boolean, probe: Boolean): Boolean = try {
            ContextCompat.startForegroundService(ctx, Intent(ctx, CarControlService::class.java)
                .putExtra(EXTRA_LABEL, label).putExtra(EXTRA_MIC, withMic).putExtra(EXTRA_PROBE, probe))
            true
        } catch (error: Exception) {
            CarBridge.serviceError("start_${error.javaClass.simpleName}")
            false
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, CarControlService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            CarBridge.onNotificationStop()
            return START_NOT_STICKY
        }
        if (intent == null) {
            // Restarted by the system with no car session to hold: go away.
            stopSelf()
            return START_NOT_STICKY
        }
        val label = intent.getStringExtra(EXTRA_LABEL).orEmpty()
        val probe = intent.getBooleanExtra(EXTRA_PROBE, false)
        val wantMic = intent.getBooleanExtra(EXTRA_MIC, false) || micType
        try {
            startTyped(notification(label, probe), wantMic)
            running = true
        } catch (error: Exception) {
            CarBridge.serviceError("foreground_${error.javaClass.simpleName}")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startTyped(notification: Notification, wantMic: Boolean) {
        if (Build.VERSION.SDK_INT < 29) {
            startForeground(NOTIFICATION_ID, notification)
            return
        }
        val micAllowed = wantMic && Build.VERSION.SDK_INT >= 30 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val media = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        if (micAllowed) {
            try {
                startForeground(NOTIFICATION_ID, notification, media or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                micType = true
                return
            } catch (error: Exception) {
                // Android 14+: a background start may not claim the microphone.
                CarBridge.serviceError("microphone_type_${error.javaClass.simpleName}")
            }
        }
        startForeground(NOTIFICATION_ID, notification, media)
        micType = false
    }

    private fun notification(label: String, probe: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Car mode",
                NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val builder = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else @Suppress("DEPRECATION") Notification.Builder(this))
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(if (probe) "DevOTA car probe" else "DevOTA car mode")
            .setContentText(label.ifBlank { if (probe) "Press each steering-wheel button" else "Steering-wheel control on" })
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(this, 24091, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        val stop = PendingIntent.getService(this, 24092,
            Intent(this, CarControlService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        builder.addAction(Notification.Action.Builder(null, if (probe) "Stop probe" else "Car mode off", stop).build())
        return builder.build()
    }

    override fun onDestroy() {
        running = false
        micType = false
        CarBridge.onServiceDestroyed()
        super.onDestroy()
    }
}
