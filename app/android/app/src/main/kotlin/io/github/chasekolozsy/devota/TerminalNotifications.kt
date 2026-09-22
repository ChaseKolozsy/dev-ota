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
import android.os.Bundle
import io.flutter.plugin.common.MethodChannel

/** Notification callbacks use the live engine, without launching an Activity.
 * No commands are persisted or replayed after engine/process death. */
internal object TerminalNotifications {
    const val GROUP = "devota_terminal_windows"
    private const val CHANNEL = "terminal_windows"
    private const val SUMMARY_ID = 29999
    const val SNAPSHOT = "devota.terminal.snapshot"
    private val handler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var cards = listOf<Map<String, Any?>>()
    private var expiry: Runnable? = null
    private var appContext: Context? = null
    private var rendered = emptyMap<String, Map<String, Any?>>()
    private var summaryRows = emptyList<Map<String, Any?>>()
    private var lastError: String? = null

    fun attach(context: Context, methodChannel: MethodChannel) {
        appContext = context.applicationContext
        channel = methodChannel
        TerminalSpeech.attach(context, methodChannel)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> TerminalSpeech.speak(call.argument<String>("text") ?: "",
                    call.argument<String>("title") ?: "Terminal", call.argument<Boolean>("earlier") == true, result)
                "stopReading" -> { TerminalSpeech.stop(); result.success(null) }
                "status" -> result.success(status(context.applicationContext))
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
        manager.cancel(SUMMARY_ID)
        cards = emptyList()
        rendered = emptyMap()
        summaryRows = emptyList()
        SshSessionService.refreshControls()
    }

    private fun allowed(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        return manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    }

    private fun status(context: Context): Map<String, Any?> {
        val manager = context.getSystemService(NotificationManager::class.java)
        val ids = manager.activeNotifications.map { it.id }.toSet()
        return mapOf("requested" to cards.size,
            "posted" to cards.count { notificationId(it["id"] as String) in ids },
            "allowed" to allowed(context), "error" to lastError)
    }

    /** The already-visible SSH notification also carries one Run shortcut per
     * window, so OEM group presentation cannot hide the entire control surface. */
    fun decorateSession(context: Context, builder: Notification.Builder) {
        builder.addExtras(Bundle().apply { putString(SNAPSHOT, cards.toString()) })
        if (cards.isEmpty() || !allowed(context)) return
        val style = Notification.InboxStyle().setBigContentTitle("DevOTA terminal · ${cards.size} windows")
        cards.forEachIndexed { index, row ->
            style.addLine("${index + 1}. ${row["status"]} · ${row["title"]}")
            val action = if (row["stop"] == true) "stop" else "run"
            if (row[action] == true) {
                val label = if (action == "stop") "${index + 1}: Stop"
                    else "${index + 1}: ${row["macro"]}"
                builder.addAction(buildAction(context, row, action, label))
            }
        }
        builder.setContentText("${cards.size} monitored windows · expand for macros").setStyle(style)
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
        refresh(context)
        expiry?.let { handler.removeCallbacks(it) }
        expiry = Runnable {
            cards = cards.map { it + mapOf("status" to "Disconnected / status expired",
                "run" to false, "enter" to false, "stop" to false, "listen" to false) }
            TerminalSpeech.stop()
            refresh(context)
        }.also { handler.postDelayed(it, 12000) }
    }

    private fun refresh(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val active = manager.activeNotifications.associateBy { it.id }
        lastError = null
        try {
            cards.forEach { row ->
                val id = row["id"] as String
                if (rendered[id] != row || active[notificationId(id)]?.notification?.extras?.getString(SNAPSHOT) != row.toString()) render(context, row)
            }
            rendered = cards.associateBy { it["id"] as String }
            if (cards.isEmpty()) manager.cancel(SUMMARY_ID)
            else if (summaryRows != cards || active[SUMMARY_ID]?.notification?.extras?.getString(SNAPSHOT) != cards.toString()) {
                val summary = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
                    else @Suppress("DEPRECATION") Notification.Builder(context))
                    .setSmallIcon(context.applicationInfo.icon)
                    .setContentTitle("DevOTA window controls")
                    .setContentText("${cards.size} windows · expand for individual controls")
                    .setGroup(GROUP).setGroupSummary(true).setOnlyAlertOnce(true)
                    .setOngoing(true).setVisibility(Notification.VISIBILITY_PRIVATE)
                    .addExtras(Bundle().apply { putString(SNAPSHOT, cards.toString()) })
                val style = Notification.InboxStyle()
                cards.forEach { style.addLine("${it["title"]}: ${it["status"]}") }
                manager.notify(SUMMARY_ID, summary.setStyle(style).build())
            }
            SshSessionService.refreshControls()
            summaryRows = cards
        } catch (error: Exception) {
            lastError = "${error.javaClass.simpleName}: ${error.message.orEmpty().take(200)}"
        }
    }

    private fun buildAction(context: Context, row: Map<String, Any?>, action: String, label: String): Notification.Action {
        val id = row["id"] as String
        val intent = Intent(context, TerminalActionReceiver::class.java)
            .setData(Uri.parse("devota-terminal://action/${id.removePrefix("%")}/$action?token=${Uri.encode(row["token"] as? String)}"))
            .putExtra("id", id).putExtra("action", action).putExtra("token", row["token"] as? String)
        val pending = PendingIntent.getBroadcast(context, notificationId(id), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Action.Builder(null, label, pending).build()
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
            .addExtras(Bundle().apply { putString(SNAPSHOT, row.toString()) })
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(context,
            notificationId(id), launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        for ((action, label) in listOf("run" to (row["macro"] as? String ?: "Run macro"),
                "enter" to "Send Enter", "stop" to "Stop", "listen" to "Listen")) {
            if (row[action] != true) continue
            builder.addAction(buildAction(context, row, action, label))
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
