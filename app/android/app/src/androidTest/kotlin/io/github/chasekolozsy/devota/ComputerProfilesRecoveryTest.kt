package io.github.chasekolozsy.devota

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith

/** Real Android UI check, restricted to an isolated fixture package. */
@RunWith(AndroidJUnit4::class)
class ComputerProfilesRecoveryTest {
    @Test fun savedComputersReturnAndSwitchTogether() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue("Run only with the isolated fixture application ID",
            context.packageName == "io.github.chasekolozsy.devota.profilesverify")
        fun profile(id: String, name: String, port: Int) = JSONObject()
            .put("id", id).put("name", name).put("host", "127.0.0.1")
            .put("port", "22").put("username", "fixture-$id")
            .put("usePrivateKey", false)
            .put("serverUrl", "http://127.0.0.1:$port")
            .put("agentUrl", "ws://127.0.0.1:65533/phone")
            .put("agentWholeDevice", false)
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        prefs.edit().clear()
            .putString("flutter.ssh_profiles_json", JSONArray()
                .put(profile("desktop", "Desktop fixture", 1))
                .put(profile("other", "Other computer fixture", 2)).toString())
            .putString("flutter.ssh_selected_profile_id", "desktop")
            .putBoolean("flutter.computer_profiles_migrated", true)
            // Simulate legacy settings written by the intervening older build.
            .putString("flutter.ssh_host", "stale-legacy-host")
            .commit()
        context.startActivity(context.packageManager.getLaunchIntentForPackage(context.packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))

        fun find(label: String): AccessibilityNodeInfo? {
            val root = instrumentation.uiAutomation.rootInActiveWindow ?: return null
            val pending = ArrayDeque<AccessibilityNodeInfo>()
            pending.add(root)
            while (pending.isNotEmpty()) {
                val node = pending.removeFirst()
                if (node.text?.toString()?.contains(label) == true || node.contentDescription?.toString()?.contains(label) == true) {
                    return node
                }
                for (index in 0 until node.childCount) node.getChild(index)?.let(pending::addLast)
            }
            return null
        }
        fun awaitNode(label: String): AccessibilityNodeInfo {
            val deadline = SystemClock.elapsedRealtime() + 15000
            while (SystemClock.elapsedRealtime() < deadline) {
                find(label)?.let { return it }
                SystemClock.sleep(100)
            }
            throw AssertionError("Missing visible UI label: $label")
        }
        fun click(label: String) {
            var node: AccessibilityNodeInfo? = awaitNode(label)
            while (node != null && !node.isClickable) node = node.parent
            assertTrue("Could not click $label", node?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true)
        }
        awaitNode("New computer")
        click("Desktop fixture")
        click("Other computer fixture")
        awaitNode("Other computer fixture")
        val deadline = SystemClock.elapsedRealtime() + 5000
        while ((prefs.getString("flutter.ssh_selected_profile_id", "") != "other" ||
                prefs.getString("flutter.active_server", "") != "http://127.0.0.1:2" ||
                prefs.getString("flutter.ssh_username", "") != "fixture-other") &&
            SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(100)
        assertEquals("other", prefs.getString("flutter.ssh_selected_profile_id", ""))
        assertEquals("http://127.0.0.1:2", prefs.getString("flutter.active_server", ""))
        assertEquals("fixture-other", prefs.getString("flutter.ssh_username", ""))
        assertEquals(2, JSONArray(prefs.getString("flutter.ssh_profiles_json", "[]")).length())
    }
}
