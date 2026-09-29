package io.github.chasekolozsy.devota.car

import org.json.JSONObject

/** One probe log entry. `detail` holds only strings, numbers, booleans and null. */
data class CarProbeEntry(
    val t: Long,
    val up: Long,
    val source: String,
    val event: String,
    val detail: Map<String, Any?>,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "t" to t, "up" to up, "source" to source, "event" to event, "detail" to detail,
    )
}

/** A spoken probe line, with an optional rate-limit key (volume, etc.). */
data class CarSpokenLine(val text: String, val rateKey: String? = null)

/**
 * Pure formatting for the car probe (JVM unit-tested). The probe never logs
 * recognized text, terminal text or audio: only signal names and timings.
 */
object CarProbeFormat {
    val SOURCES = setOf(
        "media_session", "media_button", "activity_key", "voice_command", "telecom",
        "bluetooth", "audio", "recognizer", "speaker", "service",
    )

    /** Keeps the channel codec and JSON happy: nested values become strings. */
    fun sanitize(detail: Map<String, Any?>): Map<String, Any?> = detail.mapValues { (_, v) ->
        when (v) {
            null, is String, is Boolean, is Int, is Long, is Double -> v
            is Float -> v.toDouble()
            is Short -> v.toInt()
            is Byte -> v.toInt()
            is Char -> v.toString()
            is Collection<*> -> v.joinToString(",").take(500)
            else -> v.toString().take(500)
        }
    }

    fun entry(t: Long, up: Long, source: String, event: String, detail: Map<String, Any?>) =
        CarProbeEntry(t, up, source, event, sanitize(detail))

    fun line(entry: CarProbeEntry): String = JSONObject().apply {
        put("t", entry.t)
        put("up", entry.up)
        put("source", entry.source)
        put("event", entry.event)
        val d = JSONObject()
        for ((k, v) in entry.detail) d.put(k, v ?: JSONObject.NULL)
        put("detail", d)
    }.toString()

    fun headerLine(fields: Map<String, Any?>): String = JSONObject().apply {
        put("type", "header")
        for ((k, v) in sanitize(fields)) put(k, v ?: JSONObject.NULL)
    }.toString()

    /** "KEYCODE_MEDIA_NEXT" -> "Next". */
    fun keyLabel(keycode: String): String = when (keycode) {
        "KEYCODE_MEDIA_NEXT" -> "Next"
        "KEYCODE_MEDIA_PREVIOUS" -> "Previous"
        "KEYCODE_MEDIA_PLAY_PAUSE" -> "Play pause"
        "KEYCODE_MEDIA_PLAY" -> "Play"
        "KEYCODE_MEDIA_PAUSE" -> "Pause"
        "KEYCODE_MEDIA_STOP" -> "Stop"
        "KEYCODE_HEADSETHOOK" -> "Headset hook"
        "KEYCODE_CALL" -> "Call key"
        "KEYCODE_ENDCALL" -> "End call key"
        "KEYCODE_VOICE_ASSIST" -> "Voice assist key"
        "KEYCODE_SEARCH" -> "Search key"
        "KEYCODE_VOLUME_UP" -> "Volume up key"
        "KEYCODE_VOLUME_DOWN" -> "Volume down key"
        "KEYCODE_MEDIA_FAST_FORWARD" -> "Fast forward"
        "KEYCODE_MEDIA_REWIND" -> "Rewind"
        else -> keycode.removePrefix("KEYCODE_").lowercase().replace('_', ' ')
    }

    private fun sourceWord(source: String) = when (source) {
        "media_button" -> "Media button"
        "media_session" -> "Media session"
        "activity_key" -> "In app key"
        else -> source.replace('_', ' ')
    }

    /**
     * What to say for one entry, or null for silence. [ownAudioRecent] is true
     * while DevOTA's own speech plays and briefly after, so the probe does not
     * narrate the side effects of its own voice in a loop.
     */
    fun spoken(entry: CarProbeEntry, ownAudioRecent: Boolean): CarSpokenLine? {
        val d = entry.detail
        return when (entry.source) {
            "speaker", "recognizer" -> null
            "media_button", "activity_key" -> {
                val label = keyLabel(d["keycode"] as? String ?: "unknown")
                when (d["action"]) {
                    "down" -> if (((d["repeat"] as? Number)?.toInt() ?: 0) > 0) null
                        else CarSpokenLine("$label. ${sourceWord(entry.source)}. Down.")
                    "up" -> CarSpokenLine("$label. ${sourceWord(entry.source)}. Held ${d["heldMs"] ?: 0} milliseconds.")
                    else -> CarSpokenLine("$label. ${sourceWord(entry.source)}.")
                }
            }
            "media_session" -> CarSpokenLine(
                when (entry.event) {
                    "onSkipToNext" -> "Next"
                    "onSkipToPrevious" -> "Previous"
                    "onPlay" -> "Play"
                    "onPause" -> "Pause"
                    "onStop" -> "Stop"
                    "onFastForward" -> "Fast forward"
                    "onRewind" -> "Rewind"
                    "onSeekTo" -> "Seek"
                    else -> entry.event.removePrefix("on")
                } + ". Media session.",
            )
            "voice_command" -> when (entry.event) {
                "VOICE_COMMAND" -> CarSpokenLine("Voice button. Voice command.")
                else -> null // ordering attempts are logged only
            }
            "telecom" -> when (entry.event) {
                "onDisconnect" -> CarSpokenLine("Hang up. Telecom disconnect.")
                "onAnswer" -> CarSpokenLine("Answer. Telecom.")
                "onHold" -> CarSpokenLine("Hold. Telecom.")
                "onUnhold" -> CarSpokenLine("Unhold. Telecom.")
                "onReject" -> CarSpokenLine("Reject. Telecom.")
                "onAbort" -> CarSpokenLine("Call aborted. Telecom.")
                "onPlayDtmfTone" -> CarSpokenLine("Keypad ${d["char"] ?: ""}. Telecom.")
                "onSilence" -> CarSpokenLine("Silence. Telecom.")
                "onCreateOutgoingConnection" -> CarSpokenLine("Test call started.")
                "onCreateOutgoingConnectionFailed", "place_failed" -> CarSpokenLine("Call failed.")
                "onCallAudioStateChanged" -> CarSpokenLine("Call audio ${d["route"] ?: "changed"}.", "call_audio")
                "onCallEndpointChanged" -> CarSpokenLine("Call audio ${d["name"] ?: "changed"}.", "call_audio")
                else -> null
            }
            "bluetooth" -> when (entry.event) {
                "ACL_CONNECTED" -> CarSpokenLine("Bluetooth connected. ${d["name"] ?: ""}".trim())
                "ACL_DISCONNECTED" -> CarSpokenLine("Bluetooth disconnected. ${d["name"] ?: ""}".trim())
                "HEADSET_AUDIO_STATE" -> CarSpokenLine("Bluetooth call audio ${d["state"] ?: "changed"}.")
                "SCO_AUDIO_STATE" -> CarSpokenLine("Bluetooth voice link ${d["state"] ?: "changed"}.", "sco")
                "HEADSET_CONNECTION_STATE" -> CarSpokenLine("Hands free ${d["state"] ?: "changed"}.")
                "A2DP_CONNECTION_STATE" -> CarSpokenLine("Bluetooth media ${d["state"] ?: "changed"}.")
                // Logged, never spoken: the probe's own voice toggles it. A Toyota
                // Corolla reported "stopped" ~2.9 s after each line ended, past
                // any own-audio window, and the probe narrated itself in a loop.
                "A2DP_PLAYING_STATE" -> null
                "VENDOR_SPECIFIC_HEADSET_EVENT" -> CarSpokenLine("Vendor headset event ${d["cmd"] ?: ""}.".replace(" .", "."))
                else -> null
            }
            "audio" -> when (entry.event) {
                "mode_changed" -> CarSpokenLine("Audio mode ${d["mode"] ?: "changed"}.")
                "becoming_noisy" -> CarSpokenLine("Audio becoming noisy.")
                "volume_changed" -> CarSpokenLine("Volume ${d["value"] ?: ""}.".replace(" .", "."), "volume")
                "devices_added" -> if (d["initial"] == true) null
                    else CarSpokenLine("Audio device added. ${d["types"] ?: ""}".trim(), "devices")
                "devices_removed" -> CarSpokenLine("Audio device removed. ${d["types"] ?: ""}".trim(), "devices")
                "focus_change" -> if (ownAudioRecent) null else CarSpokenLine("Audio focus ${d["change"] ?: ""}.", "focus")
                "headset_plug" -> CarSpokenLine("Headset plug ${d["state"] ?: ""}.")
                else -> null
            }
            "service" -> when (entry.event) {
                "probe_started" -> CarSpokenLine("Car probe on. Press each steering wheel button.")
                "error" -> CarSpokenLine("Probe error. ${d["what"] ?: ""}".trim())
                else -> null
            }
            else -> null
        }
    }
}

/**
 * At most one spoken line per [minGapMs]; the newest pending line wins and the
 * rest are only logged. Lines with a rate key (volume, focus) are dropped when
 * the same key spoke less than [keyGapMs] ago. Pure; the caller schedules the
 * flush at the time a [Decision.Deferred] names.
 */
class CarSpeechCoalescer(private val minGapMs: Long = 700L, private val keyGapMs: Long = 2000L) {
    sealed class Decision {
        object SpeakNow : Decision()
        data class Deferred(val at: Long) : Decision()
        object Replaced : Decision()
        object Drop : Decision()
    }

    private var lastSpokenAt: Long? = null
    private val lastByKey = HashMap<String, Long>()
    var pending: String? = null
        private set

    fun offer(now: Long, line: CarSpokenLine): Decision {
        val key = line.rateKey
        if (key != null) {
            val last = lastByKey[key]
            if (last != null && now - last < keyGapMs) return Decision.Drop
            lastByKey[key] = now
        }
        val last = lastSpokenAt
        if (pending == null && (last == null || now - last >= minGapMs)) {
            lastSpokenAt = now
            return Decision.SpeakNow
        }
        val had = pending != null
        pending = line.text
        return if (had) Decision.Replaced else Decision.Deferred((last ?: now) + minGapMs)
    }

    /** The pending line to speak now, if any. */
    fun flush(now: Long): String? {
        val text = pending ?: return null
        pending = null
        lastSpokenAt = now
        return text
    }

    fun reset() {
        pending = null
        lastSpokenAt = null
        lastByKey.clear()
    }
}
