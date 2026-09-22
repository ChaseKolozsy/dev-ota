package io.github.chasekolozsy.devota

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Build
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Notification callbacks use the live engine, without launching an Activity.
 * No commands are persisted or replayed after engine/process death. */
internal object TerminalNotifications {
    const val GROUP = "devota_terminal_windows"
    private const val CHANNEL = "terminal_windows"
    private val handler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var cards = listOf<Map<String, Any?>>()
    private var expiry: Runnable? = null
    private var appContext: Context? = null

    fun attach(context: Context, methodChannel: MethodChannel) {
        appContext = context.applicationContext
        channel = methodChannel
        TerminalSpeech.attach(context, methodChannel)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> TerminalSpeech.speak(call.argument<String>("text") ?: "",
                    call.argument<String>("title") ?: "Terminal", call.argument<Boolean>("earlier") == true, result)
                "stopReading" -> { TerminalSpeech.stop(); result.success(null) }
                "update" -> {
                    val rows = call.argument<List<Map<String, Any?>>>("cards") ?: emptyList()
                    update(context.applicationContext, rows.take(3))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach() {
        TerminalSpeech.detach()
        appContext?.let { clear(it) }
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun notificationId(id: String) = 30000 + id.removePrefix("%").toInt()

    fun clear(context: Context) {
        TerminalSpeech.stop()
        expiry?.let { handler.removeCallbacks(it) }
        expiry = null
        val manager = context.getSystemService(NotificationManager::class.java)
        cards.forEach { manager.cancel(notificationId(it["id"] as String)) }
        cards = emptyList()
    }

    private fun update(context: Context, next: List<Map<String, Any?>>) {
        val valid = next.filter { (it["id"] as? String)?.matches(Regex("%[0-9]{1,7}")) == true }
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL,
            "Terminal macro controls", NotificationManager.IMPORTANCE_LOW))
        val ids = valid.map { it["id"] }.toSet()
        cards.filter { it["id"] !in ids }.forEach {
            manager.cancel(notificationId(it["id"] as String))
        }
        cards = valid
        cards.forEach { render(context, it) }
        expiry?.let { handler.removeCallbacks(it) }
        expiry = Runnable {
            cards = cards.map { it + mapOf("status" to "Disconnected / status expired",
                "run" to false, "enter" to false, "stop" to false, "listen" to false) }
            TerminalSpeech.stop()
            cards.forEach { render(context, it) }
        }.also { handler.postDelayed(it, 12000) }
    }

    private fun render(context: Context, row: Map<String, Any?>) {
        val id = row["id"] as String
        val builder = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(context))
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("DevOTA · ${row["title"]}")
            .setContentText(row["status"] as? String ?: "Unknown")
            .setStyle(Notification.BigTextStyle().bigText(row["status"] as? String ?: "Unknown"))
            .setGroup(GROUP)
            .setSortKey(id.removePrefix("%").padStart(8, '0'))
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(context,
            notificationId(id), launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        for ((action, label) in listOf("run" to (row["macro"] as? String ?: "Run macro"),
                "enter" to "Send Enter", "stop" to "Stop", "listen" to "Listen")) {
            if (row[action] != true) continue
            val intent = Intent(context, TerminalActionReceiver::class.java)
                .setData(Uri.parse("devota-terminal://action/${id.removePrefix("%")}/$action?token=${Uri.encode(row["token"] as? String)}"))
                .putExtra("id", id).putExtra("action", action)
                .putExtra("token", row["token"] as? String)
            val pending = PendingIntent.getBroadcast(context, notificationId(id), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(null, label, pending).build())
        }
        context.getSystemService(NotificationManager::class.java)
            .notify(notificationId(id), builder.build())
    }

    fun dispatch(intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val action = intent.getStringExtra("action") ?: return
        val token = intent.getStringExtra("token") ?: return
        val row = cards.firstOrNull { it["id"] == id } ?: return
        if (row["token"] != token || row[action] != true || action !in setOf("run", "enter", "stop", "listen")) return
        channel?.invokeMethod("action", mapOf("id" to id, "action" to action, "token" to token))
    }
}

class TerminalActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.hasExtra("readerAction")) TerminalSpeech.dispatch(intent)
        else TerminalNotifications.dispatch(intent)
    }
}
