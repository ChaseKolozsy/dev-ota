package io.github.chasekolozsy.devota

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.MethodChannel

/** Raster snapshot of the selected tmux pane's bottom section, independent of
 * the foreground phone screen. Images and OCR text stay in memory on phone.
 * This is a rendered pane snapshot, not a screenshot of another Android app.
 */
object LocalTerminalReview {
    fun attach(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "recognizeSnapshot") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val text = call.argument<String>("text")
            if (text == null || text.length > 6000) {
                result.error("bad_snapshot", "Terminal snapshot exceeds its bound", null)
                return@setMethodCallHandler
            }
            recognize(text, result)
        }
    }

    internal fun recognize(text: String, result: MethodChannel.Result) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            textSize = 24f
            typeface = Typeface.MONOSPACE
        }
        // Preserve every bounded source line, wrapping by character width
        // so paths and long reports cannot silently fall off the image.
        val lines = text.split('\n').flatMap { line ->
            if (line.isEmpty()) listOf("") else line.chunked(100)
        }
        if (lines.size > 120) {
            result.error("bad_snapshot", "Too many terminal snapshot lines", null)
            return
        }
        val width = (paint.measureText("M") * 100).toInt() + 32
        val height = ((lines.size.coerceAtLeast(1) + 1) * 34) + 32
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        lines.forEachIndexed { index, line ->
            canvas.drawText(line, 16f, 40f + index * 34f, paint)
        }
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { recognized ->
                // Sort by visual position, avoiding column/block reordering.
                val ordered = recognized.textBlocks.flatMap { it.lines }
                    .sortedWith(compareBy({ it.boundingBox?.top ?: 0 },
                        { it.boundingBox?.left ?: 0 }))
                result.success(ordered.joinToString("\n") { it.text })
            }
            .addOnFailureListener {
                result.error("local_ocr_failed", "On-device OCR unavailable", null)
            }
            .addOnCompleteListener {
                recognizer.close()
                bitmap.recycle()
            }
    }
}
