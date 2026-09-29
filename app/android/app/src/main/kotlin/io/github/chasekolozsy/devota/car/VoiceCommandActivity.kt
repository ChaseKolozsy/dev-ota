package io.github.chasekolozsy.devota.car

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle

/**
 * The car's voice button (HFP AT+BVRA=1) launches ACTION_VOICE_COMMAND. This
 * transparent trampoline is reachable only through the VoiceCommandAlias,
 * which is DISABLED unless car mode or the car probe is running, so Google
 * Assistant keeps the button otherwise (owner decision Q4). It draws nothing,
 * is excluded from recents, and finishes as soon as it has handed the press
 * to CarBridge. It is handled in onResume because only a RESUMED activity
 * makes a microphone foreground-service start legal from the background.
 */
class VoiceCommandActivity : Activity() {
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 34) overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, 0, 0)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handled = false
    }

    override fun onResume() {
        super.onResume()
        if (!handled) {
            handled = true
            try {
                CarBridge.onVoiceCommand(this, intent)
            } catch (_: Exception) {
                // Never leave a transparent activity covering the ride app.
            }
        }
        finish()
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }
}
