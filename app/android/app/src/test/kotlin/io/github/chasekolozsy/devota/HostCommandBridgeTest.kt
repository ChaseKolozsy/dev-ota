package io.github.chasekolozsy.devota

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class HostCommandBridgeTest {
    @Test
    fun `policy accepts only exact allowlisted action arguments and permissions`() {
        val command = HostMacroPolicy.validate(JSONObject(
            """{
              "action":"grantPermission",
              "args":{
                "packageName":"com.example.target",
                "permission":"android.permission.POST_NOTIFICATIONS"
              }
            }""".trimIndent(),
        ))
        assertEquals("grantPermission", command.action)
        assertEquals("com.example.target", command.args.getString("packageName"))

        assertThrows(IllegalArgumentException::class.java) {
            HostMacroPolicy.validate(JSONObject("""{"action":"shell","args":{}}"""))
        }
        assertThrows(IllegalArgumentException::class.java) {
            HostMacroPolicy.validate(JSONObject(
                """{"action":"forceStop","args":{"packageName":"com.example.target","shell":"id"}}""",
            ))
        }
        assertThrows(IllegalArgumentException::class.java) {
            HostMacroPolicy.validate(JSONObject(
                """{"action":"grantPermission","args":{"packageName":"com.example.target","permission":"android.permission.READ_SMS"}}""",
            ))
        }
    }

    @Test
    fun `request correlates hostResult without device or transport identifiers`() {
        val outbound = LinkedBlockingQueue<String>()
        val bridge = HostCommandBridge(
            sendText = { payload -> outbound.put(payload); true },
            nextRequestId = { "host-test-1" },
        )
        val executor = Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit<JSONObject> {
                bridge.request(HostMacroCommand(
                    action = "forceStop",
                    args = JSONObject().put("packageName", "com.example.target"),
                    timeoutMs = 1000,
                ))
            }
            val request = JSONObject(outbound.poll(1, TimeUnit.SECONDS))
            assertEquals("hostCommand", request.getString("type"))
            assertEquals("host-test-1", request.getString("id"))
            assertFalse(request.has("deviceId"))
            assertFalse(request.has("serial"))
            assertEquals(1, bridge.pendingCount())

            assertTrue(bridge.handleHostResult(JSONObject()
                .put("type", "hostResult")
                .put("id", "host-test-1")
                .put("ok", true)
                .put("result", JSONObject()
                    .put("ok", true)
                    .put("backend", "trusted-adb")
                    .put("action", "forceStop")
                    .put("packageName", "com.example.target"))))

            val result = future.get(1, TimeUnit.SECONDS)
            assertEquals("trusted-adb", result.getString("backend"))
            assertEquals("forceStop", result.getString("action"))
            assertEquals(0, bridge.pendingCount())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `out of order results complete only their matching requests`() {
        val outbound = LinkedBlockingQueue<String>()
        val ids = ArrayDeque(listOf("host-a", "host-b"))
        val bridge = HostCommandBridge(
            sendText = { payload -> outbound.put(payload); true },
            nextRequestId = { ids.removeFirst() },
        )
        val executor = Executors.newFixedThreadPool(2)
        try {
            val first = executor.submit<JSONObject> {
                bridge.request(HostMacroCommand("forceStop", JSONObject().put("packageName", "com.example.a"), 1000))
            }
            val firstRequest = JSONObject(outbound.poll(1, TimeUnit.SECONDS))
            val second = executor.submit<JSONObject> {
                bridge.request(HostMacroCommand("launchApp", JSONObject().put("packageName", "com.example.b"), 1000))
            }
            val secondRequest = JSONObject(outbound.poll(1, TimeUnit.SECONDS))

            bridge.handleHostResult(success(secondRequest.getString("id"), "launchApp"))
            bridge.handleHostResult(success(firstRequest.getString("id"), "forceStop"))
            assertEquals("forceStop", first.get(1, TimeUnit.SECONDS).getString("action"))
            assertEquals("launchApp", second.get(1, TimeUnit.SECONDS).getString("action"))
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `disconnect fails pending request and send failure leaves no pending entry`() {
        val outbound = LinkedBlockingQueue<String>()
        val bridge = HostCommandBridge(
            sendText = { payload -> outbound.put(payload); true },
            nextRequestId = { "host-disconnect" },
        )
        val executor = Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit<JSONObject> {
                bridge.request(HostMacroCommand("forceStop", JSONObject().put("packageName", "com.example.target"), 1000))
            }
            outbound.poll(1, TimeUnit.SECONDS)
            bridge.failAll()
            val failure = assertThrows(Exception::class.java) { future.get(1, TimeUnit.SECONDS) }
            assertTrue(failure.cause?.message?.contains("host relay disconnected") == true)
            assertEquals(0, bridge.pendingCount())
        } finally {
            executor.shutdownNow()
        }

        val sendFailure = HostCommandBridge(sendText = { false }, nextRequestId = { "host-send-failure" })
        assertThrows(IllegalStateException::class.java) {
            sendFailure.request(HostMacroCommand("forceStop", JSONObject(), 1000))
        }
        assertEquals(0, sendFailure.pendingCount())
    }

    private fun success(id: String, action: String): JSONObject = JSONObject()
        .put("type", "hostResult")
        .put("id", id)
        .put("ok", true)
        .put("result", JSONObject().put("ok", true).put("action", action))
}
