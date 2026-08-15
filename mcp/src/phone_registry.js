import { createHash } from "node:crypto";

const OPEN = 1;
const MAX_HOST_COMMANDS_PER_PHONE = 4;
const HOST_REQUEST_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;

export function phoneAlias(deviceId) {
  return `phone-${createHash("sha256").update(String(deviceId)).digest("hex").slice(0, 12)}`;
}

function safeAccessibility(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return {
    enabled: value.enabled ?? null,
    connected: value.connected ?? null,
    canTakeScreenshot: value.canTakeScreenshot ?? null,
    wholeDeviceAllowed: value.wholeDeviceAllowed ?? null,
  };
}

function safeHello(msg) {
  return {
    packageName: msg.packageName ?? null,
    model: msg.model ?? msg.deviceModel ?? null,
    manufacturer: msg.manufacturer ?? null,
    androidSdk: msg.androidSdk ?? null,
    appVersionCode: msg.appVersionCode ?? null,
    appVersionName: msg.appVersionName ?? null,
    targetAppPackageName: msg.targetAppPackageName ?? null,
    targetAppInstalled: msg.targetAppInstalled ?? null,
    targetAppVersionCode: msg.targetAppVersionCode ?? null,
    targetAppVersionName: msg.targetAppVersionName ?? null,
    wholeDeviceAllowed: msg.wholeDeviceAllowed ?? null,
    accessibility: safeAccessibility(msg.accessibility),
  };
}

function safeStatus(status) {
  if (!status || typeof status !== "object" || Array.isArray(status)) return null;
  return {
    running: status.running ?? null,
    connected: status.connected ?? null,
    lastError: status.lastError ?? null,
    wholeDeviceAllowed: status.wholeDeviceAllowed ?? null,
    accessibility: safeAccessibility(status.accessibility),
  };
}

function isOpen(socket) {
  return Boolean(socket && socket.readyState === OPEN);
}

export class PhoneRegistry {
  constructor({ pairToken, logger = console, onChange = null, onHostCommand = null } = {}) {
    this.pairToken = pairToken;
    this.logger = logger;
    this.onChange = onChange;
    this.onHostCommand = onHostCommand;
    this.devices = new Map();
    this.pendingSockets = new Map();
    this.nextId = 1;
  }

  attach(socket, request) {
    const url = new URL(request.url || "/", `ws://${request.headers.host || "localhost"}`);
    const token = url.searchParams.get("token") || request.headers["x-devota-token"];
    if (token !== this.pairToken) {
      socket.close(1008, "bad token");
      return;
    }

    const record = {
      socket,
      deviceId: null,
      alias: null,
      pending: new Map(),
      hello: null,
      status: null,
      connectedAt: null,
      hostInFlight: new Set(),
    };
    this.pendingSockets.set(socket, record);
    socket.on("message", (data) => this.onMessage(record, data));
    socket.on("close", () => this.detach(record));
    socket.on("error", (err) => {
      const label = record.alias || "unidentified phone";
      this.logger.error(`[devota_mcp] ${label} websocket error: ${err.message}`);
    });
  }

  onMessage(record, data) {
    let msg;
    try {
      msg = JSON.parse(data.toString("utf8"));
    } catch {
      return;
    }

    if (msg.type === "hello") {
      const deviceId = typeof msg.deviceId === "string" ? msg.deviceId.trim() : "";
      if (!deviceId) {
        record.socket.close(1008, "hello.deviceId is required");
        return;
      }
      if (record.deviceId && record.deviceId !== deviceId) {
        record.socket.close(1008, "device identity cannot change on an authenticated connection");
        return;
      }

      const alias = phoneAlias(deviceId);
      const previous = this.devices.get(deviceId);
      if (previous && previous !== record) {
        this.rejectPending(previous, "phone reconnected");
        previous.socket.close(1000, "replaced by same phone reconnect");
      }

      record.deviceId = deviceId;
      record.alias = alias;
      record.hello = safeHello(msg);
      record.connectedAt = new Date().toISOString();
      this.pendingSockets.delete(record.socket);
      this.devices.set(deviceId, record);
      this.logger.error(`[devota_mcp] phone agent connected as ${alias}`);
      this.notifyChange();
      return;
    }

    if (!record.deviceId || this.devices.get(record.deviceId) !== record) return;
    if (msg.type === "hostCommand") {
      this.handleHostCommand(record, msg);
      return;
    }
    if (msg.type === "status") {
      record.status = safeStatus(msg.status || msg);
      this.notifyChange();
      return;
    }
    if (!msg.id || !record.pending.has(msg.id)) return;
    const pending = record.pending.get(msg.id);
    record.pending.delete(msg.id);
    clearTimeout(pending.timer);
    if (msg.ok) {
      pending.resolve(msg.result ?? {});
    } else {
      pending.reject(new Error(msg.error || "phone command failed"));
    }
  }

  async handleHostCommand(record, msg) {
    const id = String(msg.id || "").trim();
    if (!HOST_REQUEST_ID_RE.test(id)) {
      this.sendHostResult(record, { id: id.slice(0, 128), ok: false, error: "invalid host command request id" });
      return;
    }
    if (record.hostInFlight.has(id)) {
      this.sendHostResult(record, { id, ok: false, error: "duplicate host command request id" });
      return;
    }
    if (record.hostInFlight.size >= MAX_HOST_COMMANDS_PER_PHONE) {
      this.sendHostResult(record, { id, ok: false, error: "too many host commands are in flight" });
      return;
    }
    if (!this.onHostCommand) {
      this.sendHostResult(record, { id, ok: false, error: "privileged host commands are disabled" });
      return;
    }
    record.hostInFlight.add(id);
    try {
      const result = await this.onHostCommand({
        deviceId: record.deviceId,
        alias: record.alias,
        action: String(msg.action || ""),
        args: msg.args && typeof msg.args === "object" && !Array.isArray(msg.args) ? msg.args : {},
      });
      this.sendHostResult(record, { id, ok: true, result: result ?? {} });
    } catch (error) {
      this.sendHostResult(record, {
        id,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      record.hostInFlight.delete(id);
    }
  }

  sendHostResult(record, payload) {
    if (!isOpen(record.socket) || !record.deviceId || this.devices.get(record.deviceId) !== record) return false;
    record.socket.send(JSON.stringify({ type: "hostResult", ...payload }));
    return true;
  }

  detach(record) {
    this.pendingSockets.delete(record.socket);
    if (!record.deviceId || this.devices.get(record.deviceId) !== record) return;
    this.devices.delete(record.deviceId);
    this.rejectPending(record, "phone disconnected");
    record.hostInFlight.clear();
    this.logger.error(`[devota_mcp] phone agent disconnected: ${record.alias}`);
    this.notifyChange();
  }

  rejectPending(record, message) {
    for (const pending of record.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
    }
    record.pending.clear();
  }

  notifyChange() {
    if (!this.onChange) return;
    try {
      this.onChange(this.summary());
    } catch (err) {
      this.logger.error(`[devota_mcp] phone status update failed: ${err.message}`);
    }
  }

  connectedRecords() {
    return [...this.devices.values()].filter((record) => isOpen(record.socket));
  }

  hasConnected() {
    return this.connectedRecords().length > 0;
  }

  select(selector) {
    const records = this.connectedRecords();
    if (selector) {
      const record = records.find((candidate) => candidate.alias === selector);
      if (!record) {
        const available = records.map((candidate) => candidate.alias).sort().join(", ") || "none";
        throw new Error(`unknown phone selector; available phone selectors: ${available}`);
      }
      return record;
    }
    if (records.length === 0) throw new Error("DevOTA phone agent is not connected");
    if (records.length > 1) {
      const available = records.map((candidate) => candidate.alias).sort().join(", ");
      throw new Error(`multiple phone agents connected (${records.length}); pass device using one of: ${available}`);
    }
    return records[0];
  }

  async command(action, args = {}, timeoutMs = 30000, selector) {
    const record = this.select(selector);
    const id = String(this.nextId++);
    const payload = { type: "command", id, action, args };
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        record.pending.delete(id);
        reject(new Error(`phone command timed out: ${action}`));
      }, timeoutMs);
      record.pending.set(id, { resolve, reject, timer });
      record.socket.send(JSON.stringify(payload), (err) => {
        if (!err) return;
        clearTimeout(timer);
        record.pending.delete(id);
        reject(err);
      });
    });
  }

  async probe(selector) {
    const record = this.select(selector);
    const status = await this.command("status", {}, 30000, record.alias);
    return { device: record.alias, responded: true, status: safeStatus(status) };
  }

  deviceSummary(record) {
    return {
      selector: record.alias,
      alias: record.alias,
      connected: isOpen(record.socket),
      connectedAt: record.connectedAt,
      model: record.hello?.model ?? null,
      androidSdk: record.hello?.androidSdk ?? null,
      appVersionCode: record.hello?.appVersionCode ?? null,
      appVersionName: record.hello?.appVersionName ?? null,
      targetApp: {
        packageName: record.hello?.targetAppPackageName ?? null,
        installed: record.hello?.targetAppInstalled ?? null,
        versionCode: record.hello?.targetAppVersionCode ?? null,
        versionName: record.hello?.targetAppVersionName ?? null,
      },
      hello: record.hello,
      status: record.status,
    };
  }

  summary() {
    const devices = this.connectedRecords()
      .map((record) => this.deviceSummary(record))
      .sort((a, b) => a.selector.localeCompare(b.selector));
    return {
      connected: devices.length > 0,
      connectedCount: devices.length,
      devices,
    };
  }

  legacySummary() {
    const summary = this.summary();
    if (summary.connectedCount === 1) return { ...summary.devices[0], connectedCount: 1 };
    return {
      connected: summary.connected,
      connectedCount: summary.connectedCount,
      multiple: summary.connectedCount > 1,
      devices: summary.devices,
    };
  }
}
