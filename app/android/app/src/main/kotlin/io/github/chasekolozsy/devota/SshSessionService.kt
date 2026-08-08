package io.github.chasekolozsy.devota

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat

/**
 * Keeps the app process out of Android's cached state while an SSH session is
 * live.
 *
 * Android 12+ freezes cached processes seconds after the app stops being
 * visible, and newer builds (Pixel 7 era and later) enforce it hard. A frozen
 * process cannot run dartssh2's keepalive timer or drain its socket, so the
 * session dies the moment the user switches away — which is exactly when a long
 * build or an agent driving the phone needs it alive. No permission exempts a
 * plain background app from the freezer; a foreground service is the supported
 * escape hatch, so this service exists purely to hold the process at
 * foreground-service priority. The socket itself stays in the Flutter isolate.
 */
class SshSessionService : Service() {
    companion object {
        private const val CHANNEL_ID = "ssh_session"
        private const val NOTIFICATION_ID = 24082
        private const val EXTRA_LABEL = "label"

        @Volatile private var running = false

        fun isRunning(): Boolean = running

        fun start(context: Context, label: String) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, SshSessionService::class.java).putExtra(EXTRA_LABEL, label),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SshSessionService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val label = intent?.getStringExtra(EXTRA_LABEL)?.takeIf { it.isNotBlank() }
            ?: "SSH session active"
        val notification = notification(label)
        if (running) {
            // Already foreground: just refresh the text (host changed, reconnecting, ...).
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        } else {
            startForegroundCompat(notification)
            running = true
        }
        // The session lives in the Flutter isolate, so a restarted bare service
        // would keep an empty notification alive after a process death.
        return START_NOT_STICKY
    }

    /**
     * Swiping DevOTA out of recents tears down the Flutter engine and with it
     * the SSH socket, but a foreground service would otherwise survive and keep
     * claiming a session that no longer exists.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat(notification: Notification) {
        when {
            Build.VERSION.SDK_INT >= 34 -> startForeground(
                NOTIFICATION_ID,
                notification,
                // dataSync is capped at 6h/24h on Android 15+, which would drop a
                // session in the middle of a long day of work; specialUse has no
                // such cap and matches what this actually is.
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
            else -> startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "DevOTA SSH Session",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps the SSH terminal connected while DevOTA is in the background"
                setShowBadge(false)
            }
        )
    }

    private fun notification(text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val contentIntent = launch?.let {
            PendingIntent.getActivity(this, 0, it, flags)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("DevOTA terminal")
            .setContentText(text)
            .setOngoing(true)
            .apply { if (contentIntent != null) setContentIntent(contentIntent) }
            .build()
    }
}
