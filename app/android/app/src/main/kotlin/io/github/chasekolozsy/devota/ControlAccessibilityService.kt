package io.github.chasekolozsy.devota

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityButtonController
import android.accessibilityservice.GestureDescription
import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Path
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class ControlAccessibilityService : AccessibilityService() {
    private var accessibilityButtonCallback: AccessibilityButtonController.AccessibilityButtonCallback? = null
    private val eventRoots = ConcurrentHashMap<String, AccessibilityNodeInfo>()

    companion object {
        private const val MAX_NODES = 700

        @Volatile private var active: ControlAccessibilityService? = null
        @Volatile private var activePackage: String? = null

        fun isActive(): Boolean = active != null

        fun activePackageName(): String? {
            val service = active ?: return activePackage
            val rootPackage = try {
                service.activeRoot()?.packageName?.toString()
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

        fun tapUi(
            selector: JSONObject,
            packageName: String?,
            allowWholeDevice: Boolean,
        ): JSONObject {
            val service = requireService()
            service.requireScope(packageName, allowWholeDevice)
            val root = service.activeRoot(packageName)
                ?: throw IllegalStateException("no active window")
            val width = service.resources.displayMetrics.widthPixels.toDouble()
            val height = service.resources.displayMetrics.heightPixels.toDouble()
            val matches = mutableListOf<AccessibilityNodeInfo>()
            val pending = ArrayDeque<AccessibilityNodeInfo>()
            pending.add(root)
            while (pending.isNotEmpty() && matches.size <= 1) {
                val node = pending.removeFirst()
                if (matchesSelector(node, selector, width, height)) matches.add(node)
                for (index in 0 until node.childCount) {
                    node.getChild(index)?.let(pending::addLast)
                }
            }
            if (matches.size != 1) {
                throw IllegalStateException("tapUi expected exactly one match, found ${matches.size}")
            }
            val match = matches.single()
            var clickable: AccessibilityNodeInfo? = match
            while (clickable != null && !clickable.isClickable) clickable = clickable.parent
            val bounds = Rect().also(match::getBoundsInScreen)
            if (clickable?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) {
                return JSONObject()
                    .put("ok", true)
                    .put("method", "accessibility_click")
                    .put("bounds", rectJson(bounds))
            }
            val p = Path().apply { moveTo(bounds.exactCenterX(), bounds.exactCenterY()) }
            return service.runGesture(GestureDescription.StrokeDescription(p, 0, 80))
                .put("method", "gesture_fallback")
                .put("bounds", rectJson(bounds))
        }

        private fun matchesSelector(
            node: AccessibilityNodeInfo,
            selector: JSONObject,
            screenWidth: Double,
            screenHeight: Double,
        ): Boolean {
            fun contains(key: String, actual: CharSequence?): Boolean {
                if (!selector.has(key) || selector.isNull(key)) return true
                return actual?.toString()?.contains(selector.getString(key), ignoreCase = true) == true
            }
            if (!contains("text", node.text) ||
                !contains("contentDescription", node.contentDescription) ||
                !contains("resourceId", node.viewIdResourceName) ||
                !contains("className", node.className)) {
                return false
            }
            fun equals(key: String, actual: CharSequence?): Boolean {
                if (!selector.has(key) || selector.isNull(key)) return true
                return actual?.toString()?.equals(selector.getString(key), ignoreCase = true) == true
            }
            if (!equals("textExact", node.text) ||
                !equals("contentDescriptionExact", node.contentDescription) ||
                !equals("resourceIdExact", node.viewIdResourceName) ||
                !equals("classNameExact", node.className)) {
                return false
            }
            val bounds = Rect().also(node::getBoundsInScreen)
            if (selector.optBoolean("visibleOnly", true) && bounds.isEmpty) return false
            val region = selector.optJSONObject("centerRegion") ?: return true
            if (screenWidth <= 0 || screenHeight <= 0) return false
            val left = region.optDouble("left", Double.NaN)
            val right = region.optDouble("right", Double.NaN)
            val top = region.optDouble("top", Double.NaN)
            val bottom = region.optDouble("bottom", Double.NaN)
            if (!left.isFinite() || !right.isFinite() ||
                !top.isFinite() || !bottom.isFinite() ||
                left < 0 || top < 0 || right > 1 || bottom > 1 ||
                right <= left || bottom <= top) {
                return false
            }
            val centerX = bounds.exactCenterX() / screenWidth
            val centerY = bounds.exactCenterY() / screenHeight
            return centerX in left..right && centerY in top..bottom
        }

        private fun rectJson(bounds: Rect): JSONObject = JSONObject()
            .put("left", bounds.left)
            .put("top", bounds.top)
            .put("right", bounds.right)
            .put("bottom", bounds.bottom)

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

        fun tapImage(args: JSONObject, packageName: String?, allowWholeDevice: Boolean): JSONObject {
            val service = requireService()
            service.requireScope(packageName, allowWholeDevice)
            val templateJson = args.optJSONObject("template")
                ?: throw IllegalArgumentException("tapImage args.template is required")
            val encoded = templateJson.optString("pngBase64")
            if (encoded.isBlank() || encoded.length > 600_000) {
                throw IllegalArgumentException("tapImage template bytes are missing or too large")
            }
            val bytes = try {
                Base64.decode(encoded, Base64.DEFAULT)
            } catch (_: IllegalArgumentException) {
                throw IllegalArgumentException("tapImage template is not valid base64")
            }
            if (bytes.size > 384 * 1024) {
                throw IllegalArgumentException("tapImage template exceeds 384 KiB")
            }
            val template = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: throw IllegalArgumentException("tapImage template is not a decodable image")
            val screen = service.takeBitmapScreenshot()
            try {
                if (template.width != templateJson.optInt("width") || template.height != templateJson.optInt("height")) {
                    throw IllegalArgumentException("tapImage template dimensions do not match metadata")
                }
                val match = ImageTemplateMatcher.find(screen, template, ImageTemplateMatcher.parseSpec(templateJson))
                val durationMs = args.optLong("durationMs", 80).coerceIn(80, 5000)
                val p = Path().apply { moveTo(match.tapX.toFloat(), match.tapY.toFloat()) }
                return service.runGesture(GestureDescription.StrokeDescription(p, 0, durationMs))
                    .put("matched", true)
                    .put("score", match.score)
                    .put("threshold", ImageTemplateMatcher.parseSpec(templateJson).threshold)
                    .put("scale", match.scale)
                    .put("tapX", match.tapX)
                    .put("tapY", match.tapY)
                    .put("bounds", JSONObject()
                        .put("left", match.left)
                        .put("top", match.top)
                        .put("right", match.right)
                        .put("bottom", match.bottom))
            } finally {
                template.recycle()
                screen.recycle()
            }
        }

        fun humanCheckpoint(args: JSONObject): JSONObject {
            val title = args.optString("title", "Human check").trim().take(120)
            val instructions = args.optString(
                "instructions",
                "Interact briefly with the screen while DevOTA records evidence.",
            ).trim().take(2_000)
            val countdownSeconds = args.optInt("countdownSeconds", 10).coerceIn(0, 60)
            return requireService().showHumanCheckpointOverlay(
                title.ifBlank { "Human check" },
                instructions,
                countdownSeconds,
            )
        }

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
        val source = event?.source ?: return
        var root = source
        while (root.parent != null) root = root.parent
        val copy = AccessibilityNodeInfo.obtain(root)
        eventRoots.put(pkg ?: copy.packageName?.toString().orEmpty(), copy)?.recycle()
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        unregisterAccessibilityButton()
        eventRoots.values.forEach(AccessibilityNodeInfo::recycle)
        eventRoots.clear()
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
        if (target.isNotBlank() && activeRoot(target) != null) return
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
        val root = activeRoot() ?: throw IllegalStateException("no active window")
        val nodes = JSONArray()
        appendNode(root, 0, nodes)
        return JSONObject()
            .put("activePackage", activePackageName())
            .put("nodeCount", nodes.length())
            .put("truncated", nodes.length() >= MAX_NODES)
            .put("nodes", nodes)
    }

    private fun activeRoot(packageName: String? = null): AccessibilityNodeInfo? {
        if (!packageName.isNullOrBlank()) {
            for (window in windows.orEmpty()) {
                val root = window.root ?: continue
                if (root.packageName?.toString() == packageName) return root
            }
            eventRoots[packageName]?.let { cached ->
                if (cached.refresh()) return cached
                if (eventRoots.remove(packageName, cached)) cached.recycle()
            }
        }
        rootInActiveWindow?.let { return it }
        val available = windows.orEmpty()
        return available.firstOrNull { it.isFocused }?.root
            ?: available.firstOrNull { it.isActive }?.root
            ?: available.asSequence().mapNotNull { it.root }.firstOrNull()
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
        val bitmap = takeBitmapScreenshot()
        try {
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            val bytes = out.toByteArray()
            return JSONObject()
                .put("pngBase64", Base64.encodeToString(bytes, Base64.NO_WRAP))
                .put("bytes", bytes.size)
                .put("activePackage", activePackageName())
        } finally {
            bitmap.recycle()
        }
    }

    @SuppressLint("NewApi")
    private fun takeBitmapScreenshot(): Bitmap {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            throw IllegalStateException("accessibility screenshots require Android 11/API 30 or newer")
        }
        // Android throttles accessibility screenshots across every caller in
        // the service. It can also report INTERNAL_ERROR briefly after the
        // service is enabled or rebound. Retry those two transient results
        // locally so a macro does not fail at startup or merely because an
        // evidence capture happened immediately before tapImage.
        repeat(5) { attempt ->
            val latch = CountDownLatch(1)
            val bitmapRef = AtomicReference<Bitmap?>()
            val errorRef = AtomicReference<String?>()
            val errorCodeRef = AtomicReference<Int?>()
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
                            val copy = bitmap.copy(Bitmap.Config.ARGB_8888, false)
                                ?: throw IllegalStateException("could not copy screenshot bitmap")
                            bitmap.recycle()
                            buffer.close()
                            bitmapRef.set(copy)
                        } catch (e: Exception) {
                            errorRef.set(e.message ?: e.javaClass.simpleName)
                        } finally {
                            latch.countDown()
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        errorCodeRef.set(errorCode)
                        errorRef.set("takeScreenshot failed with errorCode=$errorCode")
                        latch.countDown()
                    }
                },
            )
            if (!latch.await(20, TimeUnit.SECONDS)) {
                throw IllegalStateException("screenshot timed out")
            }
            bitmapRef.get()?.let { return it }
            val retryable = errorCodeRef.get() == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT ||
                errorCodeRef.get() == ERROR_TAKE_SCREENSHOT_INTERNAL_ERROR
            if (retryable && attempt < 4) {
                SystemClock.sleep(1200L * (attempt + 1))
                return@repeat
            }
            errorRef.get()?.let { throw IllegalStateException(it) }
            throw IllegalStateException("screenshot returned no bitmap")
        }
        throw IllegalStateException("screenshot remained unavailable after retries")
    }

    private fun showHumanCheckpointOverlay(
        title: String,
        instructions: String,
        countdownSeconds: Int,
    ): JSONObject {
        val latch = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val finished = AtomicBoolean(false)
        val handler = Handler(Looper.getMainLooper())
        val overlayRef = AtomicReference<View?>()
        val tickerRef = AtomicReference<Runnable?>()

        handler.post {
            val windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
            val density = resources.displayMetrics.density
            fun dp(value: Int): Int = (value * density).toInt()

            val panel = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(28), dp(24), dp(28), dp(20))
                background = GradientDrawable().apply {
                    setColor(Color.rgb(35, 31, 38))
                    cornerRadius = dp(22).toFloat()
                    setStroke(dp(2), Color.rgb(194, 157, 255))
                }
            }
            val titleView = TextView(this).apply {
                text = title
                textSize = 24f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
            }
            val instructionsView = TextView(this).apply {
                text = instructions
                textSize = 17f
                setTextColor(Color.rgb(235, 229, 239))
                gravity = Gravity.CENTER
                setPadding(0, dp(16), 0, dp(14))
            }
            val countdownView = TextView(this).apply {
                textSize = 21f
                setTextColor(Color.rgb(222, 195, 255))
                gravity = Gravity.CENTER
                setPadding(0, 0, 0, dp(16))
            }
            val buttons = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
            }
            val startButton = Button(this).apply { text = "Start now" }
            val cancelButton = Button(this).apply { text = "Cancel test" }
            buttons.addView(startButton)
            buttons.addView(cancelButton)
            panel.addView(titleView)
            panel.addView(instructionsView)
            panel.addView(countdownView)
            panel.addView(buttons)

            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_DIM_BEHIND,
                android.graphics.PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.CENTER
                dimAmount = 0.65f
            }

            fun finish(wasCancelled: Boolean) {
                if (!finished.compareAndSet(false, true)) return
                cancelled.set(wasCancelled)
                tickerRef.get()?.let(handler::removeCallbacks)
                try {
                    windowManager.removeView(panel)
                } catch (_: Exception) {
                }
                overlayRef.set(null)
                latch.countDown()
            }

            startButton.setOnClickListener { finish(false) }
            cancelButton.setOnClickListener { finish(true) }
            overlayRef.set(panel)
            windowManager.addView(panel, params)

            val deadline = SystemClock.uptimeMillis() + countdownSeconds * 1_000L
            val ticker = object : Runnable {
                override fun run() {
                    val remainingMs = deadline - SystemClock.uptimeMillis()
                    if (remainingMs <= 0) {
                        countdownView.text = "Starting now"
                        handler.postDelayed({ finish(false) }, 250)
                        return
                    }
                    val remaining = (remainingMs + 999L) / 1_000L
                    countdownView.text = "Starting in $remaining seconds"
                    handler.postDelayed(this, 200)
                }
            }
            tickerRef.set(ticker)
            ticker.run()
        }

        if (!latch.await(countdownSeconds.toLong() + 30L, TimeUnit.SECONDS)) {
            handler.post {
                val view = overlayRef.getAndSet(null) ?: return@post
                try {
                    (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(view)
                } catch (_: Exception) {
                }
            }
            throw IllegalStateException("human checkpoint overlay timed out")
        }
        if (cancelled.get()) throw IllegalStateException("human cancelled the checkpoint")
        return JSONObject()
            .put("ok", true)
            .put("countdownSeconds", countdownSeconds)
    }
}
