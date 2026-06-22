package io.github.chasekolozsy.devota

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityButtonController
import android.accessibilityservice.GestureDescription
import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class ControlAccessibilityService : AccessibilityService() {
    private var accessibilityButtonCallback: AccessibilityButtonController.AccessibilityButtonCallback? = null

    companion object {
        private const val MAX_NODES = 700

        @Volatile private var active: ControlAccessibilityService? = null
        @Volatile private var activePackage: String? = null

        fun isActive(): Boolean = active != null

        fun activePackageName(): String? {
            val service = active ?: return activePackage
            val rootPackage = try {
                service.rootInActiveWindow?.packageName?.toString()
            } catch (_: Exception) {
                null
            }
            return rootPackage ?: activePackage
        }

        fun statusJson(): JSONObject = JSONObject()
            .put("enabled", isActive())
            .put("activePackage", activePackageName())

        fun tap(x: Double, y: Double, packageName: String?, allowWholeDevice: Boolean): JSONObject {
            val service = requireService()
            service.requireScope(packageName, allowWholeDevice)
            val p = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
            return service.runGesture(GestureDescription.StrokeDescription(p, 0, 80))
        }

        fun longTap(
            x: Double,
            y: Double,
            durationMs: Long,
            packageName: String?,
            allowWholeDevice: Boolean,
        ): JSONObject {
            val service = requireService()
            service.requireScope(packageName, allowWholeDevice)
            val p = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
            val duration = durationMs.coerceIn(500, 5000)
            return service.runGesture(GestureDescription.StrokeDescription(p, 0, duration))
                .put("durationMs", duration)
        }

        fun swipe(
            x1: Double,
            y1: Double,
            x2: Double,
            y2: Double,
            durationMs: Long,
            packageName: String?,
            allowWholeDevice: Boolean,
        ): JSONObject {
            val service = requireService()
            service.requireScope(packageName, allowWholeDevice)
            val p = Path().apply {
                moveTo(x1.toFloat(), y1.toFloat())
                lineTo(x2.toFloat(), y2.toFloat())
            }
            return service.runGesture(GestureDescription.StrokeDescription(p, 0, durationMs.coerceAtLeast(1)))
        }

        fun globalAction(action: Int, packageName: String?, allowWholeDevice: Boolean): JSONObject {
            val service = requireService()
            service.requireScope(packageName, allowWholeDevice)
            val ok = service.performGlobalAction(action)
            if (!ok) throw IllegalStateException("global action failed: $action")
            return JSONObject().put("ok", true).put("action", action)
        }

        fun typeText(text: String, packageName: String?, allowWholeDevice: Boolean): JSONObject {
            val service = requireService()
            service.requireScope(packageName, allowWholeDevice)
            val root = service.rootInActiveWindow ?: throw IllegalStateException("no active window")
            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?: throw IllegalStateException("no focused text field")
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            focused.recycle()
            if (!ok) throw IllegalStateException("setting focused text failed")
            return JSONObject().put("ok", true).put("chars", text.length)
        }

        fun uiDump(): JSONObject = requireService().dumpUi()

        fun screenshot(): JSONObject = requireService().takePngScreenshot()

        private fun requireService(): ControlAccessibilityService =
            active ?: throw IllegalStateException("DevOTA accessibility service is not enabled")
    }

    override fun onServiceConnected() {
        active = this
        registerAccessibilityButton()
        super.onServiceConnected()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString()
        if (!pkg.isNullOrBlank()) activePackage = pkg
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        unregisterAccessibilityButton()
        if (active === this) active = null
        super.onDestroy()
    }

    @SuppressLint("NewApi")
    private fun registerAccessibilityButton() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (accessibilityButtonCallback != null) return
        val callback = object : AccessibilityButtonController.AccessibilityButtonCallback() {
            override fun onClicked(controller: AccessibilityButtonController) {
                launchDevota()
            }
        }
        accessibilityButtonController.registerAccessibilityButtonCallback(
            callback,
            Handler(Looper.getMainLooper()),
        )
        accessibilityButtonCallback = callback
    }

    @SuppressLint("NewApi")
    private fun unregisterAccessibilityButton() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val callback = accessibilityButtonCallback ?: return
        accessibilityButtonController.unregisterAccessibilityButtonCallback(callback)
        accessibilityButtonCallback = null
    }

    private fun launchDevota() {
        val launch = packageManager.getLaunchIntentForPackage(packageNameForSelf())
            ?: Intent(this, MainActivity::class.java)
        launch.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        )
        startActivity(launch)
    }

    private fun requireScope(packageName: String?, allowWholeDevice: Boolean) {
        if (allowWholeDevice) return
        val target = packageName?.takeIf { it.isNotBlank() } ?: ControlAgentService.DEFAULT_APP_PACKAGE
        val current = activePackageName()
        if (current == target || current == packageName) return
        if (current == packageNameForSelf()) return
        throw IllegalStateException(
            "active package $current is outside app scope $target; enable whole-device control on both sides"
        )
    }

    private fun packageNameForSelf(): String = applicationContext.packageName

    private fun runGesture(stroke: GestureDescription.StrokeDescription): JSONObject {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            throw IllegalStateException("gestures require Android 7.0/API 24 or newer")
        }
        val latch = CountDownLatch(1)
        val completed = AtomicBoolean(false)
        val cancelled = AtomicBoolean(false)
        Handler(Looper.getMainLooper()).post {
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            val accepted = dispatchGesture(
                gesture,
                object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        completed.set(true)
                        latch.countDown()
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        cancelled.set(true)
                        latch.countDown()
                    }
                },
                null,
            )
            if (!accepted) latch.countDown()
        }
        if (!latch.await(10, TimeUnit.SECONDS)) {
            throw IllegalStateException("gesture timed out")
        }
        if (!completed.get()) {
            throw IllegalStateException(if (cancelled.get()) "gesture cancelled" else "gesture was not accepted")
        }
        return JSONObject().put("ok", true)
    }

    private fun dumpUi(): JSONObject {
        val root = rootInActiveWindow ?: throw IllegalStateException("no active window")
        val nodes = JSONArray()
        appendNode(root, 0, nodes)
        return JSONObject()
            .put("activePackage", activePackageName())
            .put("nodeCount", nodes.length())
            .put("truncated", nodes.length() >= MAX_NODES)
            .put("nodes", nodes)
    }

    private fun appendNode(node: AccessibilityNodeInfo, depth: Int, nodes: JSONArray) {
        if (nodes.length() >= MAX_NODES) return
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val item = JSONObject()
            .put("depth", depth)
            .put("package", node.packageName?.toString())
            .put("className", node.className?.toString())
            .put("text", node.text?.toString())
            .put("contentDescription", node.contentDescription?.toString())
            .put("resourceId", node.viewIdResourceName)
            .put("clickable", node.isClickable)
            .put("enabled", node.isEnabled)
            .put("focused", node.isFocused)
            .put("bounds", JSONObject()
                .put("left", bounds.left)
                .put("top", bounds.top)
                .put("right", bounds.right)
                .put("bottom", bounds.bottom))
        nodes.put(item)
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                appendNode(child, depth + 1, nodes)
            } finally {
                child.recycle()
            }
            if (nodes.length() >= MAX_NODES) return
        }
    }

    @SuppressLint("NewApi")
    private fun takePngScreenshot(): JSONObject {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            throw IllegalStateException("accessibility screenshots require Android 11/API 30 or newer")
        }
        val latch = CountDownLatch(1)
        val bytesRef = AtomicReference<ByteArray?>()
        val errorRef = AtomicReference<String?>()
        val executor = Executor { runnable -> Handler(Looper.getMainLooper()).post(runnable) }
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            executor,
            object : TakeScreenshotCallback {
                override fun onSuccess(screenshot: ScreenshotResult) {
                    try {
                        val buffer = screenshot.hardwareBuffer
                        val bitmap = Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace)
                            ?: throw IllegalStateException("could not wrap screenshot buffer")
                        val out = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                        bitmap.recycle()
                        buffer.close()
                        bytesRef.set(out.toByteArray())
                    } catch (e: Exception) {
                        errorRef.set(e.message ?: e.javaClass.simpleName)
                    } finally {
                        latch.countDown()
                    }
                }

                override fun onFailure(errorCode: Int) {
                    errorRef.set("takeScreenshot failed with errorCode=$errorCode")
                    latch.countDown()
                }
            },
        )
        if (!latch.await(20, TimeUnit.SECONDS)) {
            throw IllegalStateException("screenshot timed out")
        }
        errorRef.get()?.let { throw IllegalStateException(it) }
        val bytes = bytesRef.get() ?: throw IllegalStateException("screenshot returned no bytes")
        return JSONObject()
            .put("pngBase64", Base64.encodeToString(bytes, Base64.NO_WRAP))
            .put("bytes", bytes.size)
            .put("activePackage", activePackageName())
    }
}
