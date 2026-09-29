package io.github.chasekolozsy.devota.car

/** What one physical play/pause press meant. */
enum class CarPress { SINGLE, DOUBLE, LONG }

fun interface CarCancellable { fun cancel() }

fun interface CarScheduler { fun schedule(delayMs: Long, action: () -> Unit): CarCancellable }

/**
 * Classifies play/pause presses into single, double and long.
 *
 * Pure JVM code (no Android imports) so it is unit-tested directly. Timing
 * classes are OFF by default (proposal rule S9: only enable a class the Button
 * learning page measured as reliable). With both off a single press is
 * emitted on key down, with no waiting at all.
 */
class CarPressClassifier(
    private val scheduler: CarScheduler,
    private val emit: (CarPress) -> Unit,
) {
    var doubleEnabled = false
        private set
    var longEnabled = false
        private set
    var doubleMs = 400L
        private set
    var longMs = 700L
        private set

    private var holding = false
    private var consumed = false
    private var downAt = 0L
    private var lastUp = 0L
    private var longTimer: CarCancellable? = null
    private var singleTimer: CarCancellable? = null

    fun configure(double: Boolean, long: Boolean, doubleMs: Long = 400L, longMs: Long = 700L) {
        reset()
        doubleEnabled = double
        longEnabled = long
        this.doubleMs = doubleMs.coerceIn(150L, 1500L)
        this.longMs = longMs.coerceIn(300L, 5000L)
    }

    /** A key down. [repeat] is KeyEvent.getRepeatCount(). */
    fun onDown(t: Long, repeat: Int = 0) {
        if (repeat > 0) {
            if (holding && !consumed && longEnabled && t - downAt >= longMs) fireLong()
            return
        }
        if (holding) return // A second down without an up: ignore it.
        holding = true
        consumed = false
        downAt = t
        val pending = singleTimer
        if (pending != null) {
            pending.cancel()
            singleTimer = null
            if (t - lastUp <= doubleMs) {
                consumed = true
                emit(CarPress.DOUBLE)
                return
            }
            emit(CarPress.SINGLE) // A stale first press: settle it before this one.
        }
        if (!doubleEnabled && !longEnabled) {
            consumed = true
            emit(CarPress.SINGLE)
            return
        }
        if (longEnabled) {
            longTimer = scheduler.schedule(longMs) {
                longTimer = null
                if (holding && !consumed) fireLong()
            }
        }
    }

    fun onUp(t: Long) {
        if (!holding) return
        holding = false
        longTimer?.cancel()
        longTimer = null
        if (consumed) return
        consumed = true
        if (longEnabled && t - downAt >= longMs) {
            emit(CarPress.LONG)
            return
        }
        if (doubleEnabled) {
            lastUp = t
            singleTimer = scheduler.schedule(doubleMs) {
                singleTimer = null
                emit(CarPress.SINGLE)
            }
        } else {
            emit(CarPress.SINGLE)
        }
    }

    /** A press with no key timing (AVRCP delivered only as onPlay/onPause). */
    fun onTap(t: Long) {
        onDown(t)
        onUp(t)
    }

    fun reset() {
        longTimer?.cancel()
        singleTimer?.cancel()
        longTimer = null
        singleTimer = null
        holding = false
        consumed = false
    }

    private fun fireLong() {
        consumed = true
        longTimer?.cancel()
        longTimer = null
        emit(CarPress.LONG)
    }
}
