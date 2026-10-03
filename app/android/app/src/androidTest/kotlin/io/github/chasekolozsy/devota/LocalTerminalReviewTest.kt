package io.github.chasekolozsy.devota

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class LocalTerminalReviewTest {
    @Test fun bundledOcrPreservesNegationAndPartialCounts() {
        val done = CountDownLatch(1)
        val output = AtomicReference<String>()
        val error = AtomicReference<String>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            LocalTerminalReview.recognize(
                "Not complete. Tests failed.\n19/20 completed and approved.",
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        output.set(result as String)
                        done.countDown()
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        error.set(code)
                        done.countDown()
                    }
                    override fun notImplemented() { done.countDown() }
                },
            )
        }
        assertTrue("Local OCR timed out", done.await(30, TimeUnit.SECONDS))
        assertNull(error.get())
        assertNotNull(output.get())
        assertTrue(output.get().contains("Not complete"))
        assertTrue(output.get().contains("Tests failed"))
        assertTrue(output.get().contains("19/20"))
    }
}
