package io.github.chasekolozsy.devota.car

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Cancels the car's redial of DevOTA's stand-in number ([CarStandIn.NUMBER])
 * before the phone places it as a real carrier call, and in car mode turns it
 * into a dictation trigger.
 *
 * Uses the ordered ACTION_NEW_OUTGOING_CALL broadcast (deprecated in API 29
 * but still delivered and still cancellable with a null result on Android 12)
 * because it needs one runtime permission, PROCESS_OUTGOING_CALLS (shown as
 * "Call logs"), and no role. The broadcast is protected (only the system can
 * send it) and the receiver is declared in the manifest, so it works while
 * DevOTA is not running. Every number other than the stand-in passes through
 * untouched; emergency calls are never cancellable by apps anyway.
 */
class CarRedialReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_NEW_OUTGOING_CALL) return
        val original = intent.getStringExtra(Intent.EXTRA_PHONE_NUMBER)
        val current = resultData
        if (!CarStandIn.shouldCancel(original, current, SystemClock.elapsedRealtime(),
                CarTelecom.ownPlacementUntil)) return
        resultData = null
        val number = original ?: current ?: ""
        val ctx = context.applicationContext
        CarRedialLog.record(ctx, number)
        CarBridge.onStandInRedial(ctx, number)
    }
}

/** The redial guard's own small log: cancelled numbers only, newest first. */
internal object CarRedialLog {
    private const val PREFS = "devota_car_redial"
    private const val KEY_COUNT = "cancelled"
    private const val KEY_RECENT = "recent"
    private const val MAX = 10

    fun granted(ctx: Context): Boolean = ContextCompat.checkSelfPermission(ctx,
        Manifest.permission.PROCESS_OUTGOING_CALLS) == PackageManager.PERMISSION_GRANTED

    fun record(ctx: Context, number: String) {
        try {
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val old = try { JSONArray(prefs.getString(KEY_RECENT, "[]")) } catch (_: Exception) { JSONArray() }
            val next = JSONArray().put(JSONObject().put("t", System.currentTimeMillis()).put("number", number.take(40)))
            for (i in 0 until minOf(old.length(), MAX - 1)) next.put(old.get(i))
            prefs.edit().putInt(KEY_COUNT, prefs.getInt(KEY_COUNT, 0) + 1)
                .putString(KEY_RECENT, next.toString()).apply()
        } catch (_: Exception) {}
    }

    fun status(ctx: Context): Map<String, Any?> {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val recent = try { JSONArray(prefs.getString(KEY_RECENT, "[]")) } catch (_: Exception) { JSONArray() }
        return mapOf(
            "granted" to granted(ctx),
            "number" to CarStandIn.NUMBER,
            "cancelled" to prefs.getInt(KEY_COUNT, 0),
            "recent" to (0 until recent.length()).mapNotNull { i ->
                val e = recent.optJSONObject(i) ?: return@mapNotNull null
                mapOf("t" to e.optLong("t"), "number" to e.optString("number"))
            },
        )
    }
}
