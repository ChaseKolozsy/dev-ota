package io.github.chasekolozsy.devota.car

/**
 * DevOTA's stand-in call number and the exact-match test for the car
 * redialling it. Pure JVM (no Android imports) so it is unit-tested.
 *
 * The self-managed "recording" call is what makes the car route its mic and
 * deliver hang-up. Over HFP the car also learns the call's number and keeps
 * it in its own recents; the 2020s Corolla's pick-up button (with no call
 * active) redials the last number it saw, which the phone then places as a
 * REAL carrier call (owner, 2026-09-28: "10000000", shown as 1(000)000-0,
 * "cannot be completed as dialed").
 *
 * Why the number is [NUMBER] = 10000000:
 *  - The car already stores exactly this for DevOTA's earlier calls (it
 *    rendered the non-numeric address "devota:probe" as 10000000), so one
 *    number covers old and new recents entries. The address is now
 *    tel:10000000, so what the car stores is chosen, not guessed.
 *  - It can never be a reachable NANP number: after the trunk prefix 1, an
 *    area code cannot start with 0 (000 is not an area code), and 8 digits
 *    is not a valid length. The owner's carrier confirmed it fails.
 *  - It is not an emergency or short code (911, 112, 999, 000, 988, 211-811,
 *    *xx/#xx feature codes are all 2-4 characters or start with * or #).
 *
 * The guard cancels ONLY this number, however the car or phone punctuates it
 * ("1(000)000-0", "1-000-000-0", "+10000000", "+1 10000000"). Any other
 * digit string, or anything with *, #, pause/wait characters or letters, is
 * left alone.
 */
object CarStandIn {
    const val NUMBER = "10000000"

    /** How long after DevOTA places its own call the guard stands aside. */
    const val OWN_PLACEMENT_GRACE_MS = 5000L

    private val separators = setOf(' ', '-', '(', ')', '.', '/', ' ')
    private val accepted = setOf(NUMBER, "1$NUMBER")

    /** True only for DevOTA's stand-in number. */
    fun isStandIn(dialed: String?): Boolean {
        val s = dialed?.trim() ?: return false
        if (s.isEmpty()) return false
        val body = if (s.startsWith('+')) s.substring(1) else s
        val digits = StringBuilder()
        for (c in body) {
            when {
                c in '0'..'9' -> digits.append(c)
                c in separators -> Unit
                else -> return false // '+' again, '*', '#', ',', ';', letters: never ours.
            }
        }
        return digits.toString() in accepted
    }

    /**
     * Whether an outgoing call must be cancelled. [original] is the number
     * the call was started with, [current] the result data after earlier
     * receivers. [ownPlacementUntil] (same clock as [now]) covers DevOTA's own
     * self-managed placement, which Telecom should never broadcast anyway.
     */
    fun shouldCancel(original: String?, current: String?, now: Long, ownPlacementUntil: Long): Boolean {
        if (now < ownPlacementUntil) return false
        return isStandIn(original) || isStandIn(current)
    }
}

/**
 * The Corolla sends MEDIA_PLAY on its own about 0.5 s after every MEDIA_NEXT.
 * One NEXT then swallows the first PLAY that arrives within [windowMs]; a PLAY
 * with no NEXT before it (or after the window) is a real press. Pure JVM.
 */
class CarSkipEcho(val windowMs: Long = 1200L) {
    private var nextAt: Long? = null

    fun onNext(t: Long) {
        nextAt = t
    }

    /** True when this PLAY is the car's echo of a recent NEXT: drop it. */
    fun swallowPlay(t: Long): Boolean {
        val at = nextAt ?: return false
        nextAt = null
        return t >= at && t - at <= windowMs
    }

    fun reset() {
        nextAt = null
    }
}
