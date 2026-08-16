package io.github.chasekolozsy.devota

import android.graphics.Bitmap
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** A bounded, dependency-free matcher for offline DevOTA macro tap templates. */
object ImageTemplateMatcher {
    data class Spec(
        val sourceWidth: Int,
        val sourceHeight: Int,
        val expectedCenterX: Double,
        val expectedCenterY: Double,
        val clickOffsetX: Double,
        val clickOffsetY: Double,
        val searchRadiusX: Double,
        val searchRadiusY: Double,
        val threshold: Double,
    )

    data class Match(
        val score: Double,
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
        val tapX: Int,
        val tapY: Int,
        val scale: Double,
    )

    fun parseSpec(json: JSONObject): Spec {
        if (json.optString("format") != "devota-image-template" || json.optInt("version") != 1) {
            throw IllegalArgumentException("unsupported DevOTA image template")
        }
        val sourceWidth = json.optInt("sourceWidth")
        val sourceHeight = json.optInt("sourceHeight")
        if (sourceWidth !in 1..10000 || sourceHeight !in 1..10000) {
            throw IllegalArgumentException("image template source dimensions are invalid")
        }
        fun fraction(name: String, fallback: Double, min: Double = 0.0, max: Double = 1.0): Double {
            val value = if (json.has(name)) json.optDouble(name) else fallback
            if (!value.isFinite() || value < min || value > max) {
                throw IllegalArgumentException("image template $name is invalid")
            }
            return value
        }
        return Spec(
            sourceWidth = sourceWidth,
            sourceHeight = sourceHeight,
            expectedCenterX = fraction("expectedCenterX", 0.5),
            expectedCenterY = fraction("expectedCenterY", 0.5),
            clickOffsetX = fraction("clickOffsetX", 0.5),
            clickOffsetY = fraction("clickOffsetY", 0.5),
            searchRadiusX = fraction("searchRadiusX", 0.42, 0.02, 0.5),
            searchRadiusY = fraction("searchRadiusY", 0.42, 0.02, 0.5),
            threshold = fraction("threshold", 0.84, 0.5, 0.99),
        )
    }

    fun find(screen: Bitmap, template: Bitmap, spec: Spec): Match {
        if (template.width !in 8..512 || template.height !in 8..512) {
            throw IllegalArgumentException("image template dimensions must be from 8 to 512 pixels")
        }
        val workScale = min(1.0, 640.0 / max(screen.width, screen.height))
        val workWidth = max(1, (screen.width * workScale).roundToInt())
        val workHeight = max(1, (screen.height * workScale).roundToInt())
        val workScreen = Bitmap.createScaledBitmap(screen, workWidth, workHeight, true)
        val screenPixels = IntArray(workWidth * workHeight)
        workScreen.getPixels(screenPixels, 0, workWidth, 0, 0, workWidth, workHeight)
        if (workScreen !== screen) workScreen.recycle()
        val screenLuma = FloatArray(screenPixels.size)
        for (index in screenPixels.indices) screenLuma[index] = luminance(screenPixels[index])

        val deviceScale = min(
            screen.width.toDouble() / spec.sourceWidth,
            screen.height.toDouble() / spec.sourceHeight,
        )
        var best: Candidate? = null
        val variants = doubleArrayOf(0.85, 0.925, 1.0, 1.075, 1.15)
        for (variant in variants) {
            val fullTemplateWidth = max(8, (template.width * deviceScale * variant).roundToInt())
            val fullTemplateHeight = max(8, (template.height * deviceScale * variant).roundToInt())
            val width = max(4, (fullTemplateWidth * workScale).roundToInt())
            val height = max(4, (fullTemplateHeight * workScale).roundToInt())
            if (width >= workWidth || height >= workHeight) continue
            val scaled = Bitmap.createScaledBitmap(template, width, height, true)
            val templatePixels = IntArray(width * height)
            scaled.getPixels(templatePixels, 0, width, 0, 0, width, height)
            if (scaled !== template) scaled.recycle()
            val samples = TemplateSamples.from(templatePixels, width, height)

            val expectedX = (spec.expectedCenterX * workWidth).roundToInt()
            val expectedY = (spec.expectedCenterY * workHeight).roundToInt()
            val radiusX = (spec.searchRadiusX * workWidth).roundToInt()
            val radiusY = (spec.searchRadiusY * workHeight).roundToInt()
            val minX = max(0, expectedX - radiusX - width / 2)
            val maxX = min(workWidth - width, expectedX + radiusX - width / 2)
            val minY = max(0, expectedY - radiusY - height / 2)
            val maxY = min(workHeight - height, expectedY + radiusY - height / 2)
            val step = max(2, min(width, height) / 8)
            val coarse = search(
                screenLuma,
                workWidth,
                samples,
                width,
                minX,
                maxX,
                minY,
                maxY,
                step,
            ) ?: continue
            val refined = search(
                screenLuma,
                workWidth,
                samples,
                width,
                max(minX, coarse.x - step),
                min(maxX, coarse.x + step),
                max(minY, coarse.y - step),
                min(maxY, coarse.y + step),
                1,
            ) ?: coarse
            if (best == null || refined.score > best.score) {
                best = refined.copy(fullWidth = fullTemplateWidth, fullHeight = fullTemplateHeight, variant = variant)
            }
        }

        val found = best ?: throw IllegalStateException("image template could not be searched on this screen")
        if (found.score < spec.threshold) {
            throw IllegalStateException(
                "image template confidence %.3f is below threshold %.3f".format(found.score, spec.threshold),
            )
        }
        val left = (found.x / workScale).roundToInt().coerceIn(0, screen.width - 1)
        val top = (found.y / workScale).roundToInt().coerceIn(0, screen.height - 1)
        val right = (left + found.fullWidth).coerceAtMost(screen.width)
        val bottom = (top + found.fullHeight).coerceAtMost(screen.height)
        val tapX = (left + spec.clickOffsetX * (right - left)).roundToInt().coerceIn(left, max(left, right - 1))
        val tapY = (top + spec.clickOffsetY * (bottom - top)).roundToInt().coerceIn(top, max(top, bottom - 1))
        return Match(found.score, left, top, right, bottom, tapX, tapY, found.variant)
    }

    private data class Candidate(
        val score: Double,
        val x: Int,
        val y: Int,
        val fullWidth: Int = 0,
        val fullHeight: Int = 0,
        val variant: Double = 1.0,
    )

    private data class TemplateSamples(
        val offsets: IntArray,
        val centeredLuma: FloatArray,
        val norm: Double,
    ) {
        companion object {
            fun from(pixels: IntArray, width: Int, height: Int): TemplateSamples {
                val sampleX = min(10, width)
                val sampleY = min(10, height)
                val count = sampleX * sampleY
                val offsets = IntArray(count)
                val values = FloatArray(count)
                var index = 0
                var sum = 0.0
                for (sy in 0 until sampleY) {
                    val ty = ((sy + 0.5) * height / sampleY).toInt().coerceAtMost(height - 1)
                    for (sx in 0 until sampleX) {
                        val tx = ((sx + 0.5) * width / sampleX).toInt().coerceAtMost(width - 1)
                        offsets[index] = ty * width + tx
                        values[index] = luminance(pixels[offsets[index]])
                        sum += values[index]
                        index++
                    }
                }
                val mean = sum / count
                var variance = 0.0
                for (i in values.indices) {
                    values[i] = (values[i] - mean).toFloat()
                    variance += values[i] * values[i]
                }
                return TemplateSamples(offsets, values, sqrt(variance))
            }
        }
    }

    private fun search(
        screen: FloatArray,
        screenWidth: Int,
        samples: TemplateSamples,
        templateWidth: Int,
        minX: Int,
        maxX: Int,
        minY: Int,
        maxY: Int,
        step: Int,
    ): Candidate? {
        if (maxX < minX || maxY < minY) return null
        var best: Candidate? = null
        var y = minY
        while (y <= maxY) {
            var x = minX
            while (x <= maxX) {
                val score = sampledCorrelation(
                    screen,
                    screenWidth,
                    samples,
                    templateWidth,
                    x,
                    y,
                )
                if (best == null || score > best.score) best = Candidate(score, x, y)
                x += step
            }
            y += step
        }
        return best
    }

    private fun sampledCorrelation(
        screen: FloatArray,
        screenWidth: Int,
        samples: TemplateSamples,
        templateWidth: Int,
        left: Int,
        top: Int,
    ): Double {
        val count = samples.offsets.size
        var screenSum = 0.0
        var screenSquareSum = 0.0
        var numerator = 0.0
        val origin = top * screenWidth + left
        for (i in samples.offsets.indices) {
            val offset = samples.offsets[i]
            val ty = offset / templateWidth
            val tx = offset - ty * templateWidth
            val value = screen[origin + ty * screenWidth + tx].toDouble()
            screenSum += value
            screenSquareSum += value * value
            numerator += samples.centeredLuma[i] * value
        }
        val screenVariance = screenSquareSum - (screenSum * screenSum / count)
        if (samples.norm < 1.0 || screenVariance < 1.0) return 0.0
        val correlation = numerator / (samples.norm * sqrt(screenVariance))
        return ((correlation.coerceIn(-1.0, 1.0) + 1.0) / 2.0)
    }

    private fun luminance(color: Int): Float =
        ((((color shr 16) and 0xff) * 0.299) +
            (((color shr 8) and 0xff) * 0.587) +
            ((color and 0xff) * 0.114)).toFloat()
}
