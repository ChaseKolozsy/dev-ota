package io.github.chasekolozsy.devota

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ImageTemplateMatcherInstrumentedTest {
    @Test
    fun rescalesAndCalibratesShiftedControl() {
        val source = Bitmap.createBitmap(1080, 2400, Bitmap.Config.ARGB_8888)
        Canvas(source).apply {
            drawColor(Color.WHITE)
            drawRect(340f, 1000f, 740f, 1160f, Paint().apply { color = Color.rgb(20, 60, 150) })
            drawCircle(540f, 1080f, 26f, Paint().apply { color = Color.YELLOW })
        }
        val template = Bitmap.createBitmap(source, 316, 976, 448, 208)
        val target = Bitmap.createBitmap(720, 1600, Bitmap.Config.ARGB_8888)
        Canvas(target).apply {
            drawColor(Color.WHITE)
            val scaled = Bitmap.createScaledBitmap(template, 299, 139, true)
            drawBitmap(scaled, 250f, 670f, null)
            scaled.recycle()
        }
        val spec = ImageTemplateMatcher.Spec(
            sourceWidth = 1080,
            sourceHeight = 2400,
            expectedCenterX = 0.5,
            expectedCenterY = 1068.0 / 2400.0,
            clickOffsetX = 0.5,
            clickOffsetY = 0.5,
            searchRadiusX = 0.42,
            searchRadiusY = 0.42,
            threshold = 0.84,
        )

        val match = ImageTemplateMatcher.find(target, template, spec)

        assertTrue(match.score >= spec.threshold)
        assertTrue("tapX was ${match.tapX}", kotlin.math.abs(match.tapX - 400) <= 6)
        assertTrue("tapY was ${match.tapY}", kotlin.math.abs(match.tapY - 740) <= 6)
        source.recycle()
        template.recycle()
        target.recycle()
    }
}
