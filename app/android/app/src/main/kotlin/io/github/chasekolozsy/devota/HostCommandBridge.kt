package io.github.chasekolozsy.devota

import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

internal data class HostMacroCommand(
    val action: String,
    val args: JSONObject,
    val timeoutMs: Long,
)

internal object HostMacroPolicy {
    private val actionKeys = mapOf(
        "clearAppData" to setOf("packageName"),
        "grantPermission" to setOf("packageName", "permission"),
        "revokePermission" to setOf("packageName", "permission"),
        "forceStop" to setOf("packageName"),
        "launchApp" to setOf("packageName"),
        "installLatest" to setOf("appId"),
    )
    private val permissions = setOf(
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.RECORD_AUDIO",
    )
    private val packagePattern = Regex("^[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)+$")
    private val appIdPattern = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

    fun validate(envelope: JSONObject): HostMacroCommand {
        requireExactKeys(envelope, setOf("action", "args"), "hostCommand args")
        val action = envelope.optString("action").trim()
        val allowedKeys = actionKeys[action]
            ?: throw IllegalArgumentException("host macro action is not allowlisted")
        val args = envelope.optJSONObject("args")
            ?: throw IllegalArgumentException("host macro action args must be an object")
        requireExactKeys(args, allowedKeys, "$action args")

        if (action == "installLatest") {
            requiredString(args, "appId", appIdPattern)
        } else {
            requiredString(args, "packageName", packagePattern)
        }
        if (action == "grantPermission" || action == "revokePermission") {
            val permission = args.optString("permission").trim()
            if (permission !in permissions) {
                throw IllegalArgumentException("runtime permission is not allowlisted for host macros")
            }
        }
        val timeoutMs = if (action == "installLatest") 11 * 60 * 1000L else 60 * 1000L
        return HostMacroCommand(action, JSONObject(args.toString()), timeoutMs)
    }

    private fun requireExactKeys(value: JSONObject, allowed: Set<String>, label: String) {
        val keys = value.keys().asSequence().toSet()
        if (keys != allowed) throw IllegalArgumentException("$label must contain exactly ${allowed.sorted().joinToString()}")
    }

    private fun requiredString(value: JSONObject, key: String, pattern: Regex): String {
        val normalized = value.optString(key).trim()
        if (!pattern.matches(normalized)) throw IllegalArgumentException("$key is invalid")
        return normalized
    }
}

/**
 * Correlates a locally pressed macro's host request with the matching result
 * on the already authenticated DevOTA agent socket. It has no shell or ADB
 * surface; the workstation independently re-validates and executes the
 * allowlisted action.
 */
internal class HostCommandBridge(
    private val sendText: (String) -> Boolean,
    private val nextRequestId: () -> String = { "host-${UUID.randomUUID()}" },
) {
    private val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()

    fun request(command: HostMacroCommand): JSONObject {
        val id = reserveRequestId()
        val future = pending.getValue(id)
        val payload = JSONObject()
            .put("type", "hostCommand")
            .put("id", id)
            .put("action", command.action)
            .put("args", command.args)
        if (!sendText(payload.toString())) {
            pending.remove(id)
            throw IllegalStateException("DevOTA agent is not connected to the host relay")
        }
        return try {
            future.get(command.timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            pending.remove(id)
            throw IllegalStateException("privileged host command timed out")
        } catch (error: ExecutionException) {
            throw IllegalStateException(error.cause?.message ?: "privileged host command failed")
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            pending.remove(id)
            throw IllegalStateException("privileged host command was interrupted")
        }
    }

    fun handleHostResult(message: JSONObject): Boolean {
        if (message.optString("type") != "hostResult") return false
        val id = message.optString("id").trim()
        val future = pending.remove(id) ?: return true
        if (message.optBoolean("ok", false)) {
            future.complete(message.optJSONObject("result") ?: JSONObject())
        } else {
            val detail = message.optString("error").trim().take(512)
            future.completeExceptionally(
                IllegalStateException(detail.ifBlank { "privileged host command failed" }),
            )
        }
        return true
    }

    fun failAll(message: String = "host relay disconnected") {
        val error = IllegalStateException(message)
        for ((id, future) in pending.entries) {
            if (pending.remove(id, future)) future.completeExceptionally(error)
        }
    }

    internal fun pendingCount(): Int = pending.size

    private fun reserveRequestId(): String {
        repeat(8) {
            val candidate = nextRequestId()
            if (candidate.matches(Regex("^[A-Za-z0-9._:-]{1,128}$"))) {
                val future = CompletableFuture<JSONObject>()
                if (pending.putIfAbsent(candidate, future) == null) return candidate
            }
        }
        throw IllegalStateException("could not allocate host command request id")
    }
}
