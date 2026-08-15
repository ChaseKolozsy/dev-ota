import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { PhoneRegistry, phoneAlias } from "../src/phone_registry.js";
import { createPrivilegedMacroExecutor } from "../src/privileged_macro.js";

class FakeSocket extends EventEmitter {
  constructor() {
    super();
    this.readyState = 1;
    this.sent = [];
    this.closed = null;
  }

  send(payload, callback) {
    this.sent.push(JSON.parse(payload));
    callback?.(null);
  }

  close(code, reason) {
    if (this.readyState !== 1) return;
    this.readyState = 3;
    this.closed = { code, reason };
    this.emit("close");
  }

  receive(payload) {
    this.emit("message", Buffer.from(JSON.stringify(payload)));
  }
}

const silentLogger = { error() {} };
const request = { url: "/phone?token=test-token", headers: { host: "localhost" } };

function connect(registry, deviceId, extras = {}) {
  const socket = new FakeSocket();
  registry.attach(socket, request);
  socket.receive({ type: "hello", deviceId, ...extras });
  return socket;
}

async function settle() {
  await new Promise((resolve) => setImmediate(resolve));
}

test("keeps devices separate and never exposes authenticated raw ids", () => {
  const registry = new PhoneRegistry({ pairToken: "test-token", logger: silentLogger });
  const firstId = "raw-device-alpha";
  const secondId = "raw-device-beta";
  connect(registry, firstId, { model: "Model A", androidSdk: 31 });
  connect(registry, secondId, { model: "Model B", androidSdk: 35 });

  const summary = registry.summary();
  assert.equal(summary.connectedCount, 2);
  assert.deepEqual(summary.devices.map((device) => device.model).sort(), ["Model A", "Model B"]);
  const encoded = JSON.stringify(summary);
  assert.equal(encoded.includes(firstId), false);
  assert.equal(encoded.includes(secondId), false);
});

test("routes ordinary commands independently and requires a selector for multiple phones", async () => {
  const registry = new PhoneRegistry({ pairToken: "test-token", logger: silentLogger });
  const first = connect(registry, "first-device");
  const second = connect(registry, "second-device");
  await assert.rejects(registry.command("status"), /multiple phone agents connected/);

  const firstPromise = registry.command("status", { marker: "first" }, 1000, phoneAlias("first-device"));
  const secondPromise = registry.command("status", { marker: "second" }, 1000, phoneAlias("second-device"));
  first.receive({ id: first.sent.at(-1).id, ok: true, result: { owner: "first" } });
  second.receive({ id: second.sent.at(-1).id, ok: true, result: { owner: "second" } });
  assert.deepEqual(await Promise.all([firstPromise, secondPromise]), [{ owner: "first" }, { owner: "second" }]);
});

test("hostCommand binds to the authenticated device internally and correlates hostResult", async () => {
  const rawDeviceId = "private-android-id";
  const calls = [];
  const registry = new PhoneRegistry({
    pairToken: "test-token",
    logger: silentLogger,
    onHostCommand: async (request) => {
      calls.push(request);
      return { ok: true, backend: "trusted-adb", action: request.action };
    },
  });
  const socket = connect(registry, rawDeviceId);
  socket.receive({
    type: "hostCommand",
    id: "host-request-1",
    action: "forceStop",
    args: { packageName: "example.app" },
  });
  await settle();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].deviceId, rawDeviceId);
  assert.equal(calls[0].alias, phoneAlias(rawDeviceId));
  const result = socket.sent.at(-1);
  assert.deepEqual(result, {
    type: "hostResult",
    id: "host-request-1",
    ok: true,
    result: { ok: true, backend: "trusted-adb", action: "forceStop" },
  });
  assert.equal(JSON.stringify(result).includes(rawDeviceId), false);
});

test("authenticated hostCommand reaches only the matched ADB transport end to end", async () => {
  const adbCalls = [];
  const execute = createPrivilegedMacroExecutor({
    enabled: true,
    loadManifest: async () => ({
      apps: [
        { id: "target", packageName: "com.example.target" },
        { id: "devota", packageName: "io.github.chasekolozsy.devota" },
      ],
    }),
    adbDevices: async () => [
      { serial: "transport-a", state: "device" },
      { serial: "transport-b", state: "device" },
    ],
    runAdb: async (args, options) => {
      adbCalls.push({ args, serial: options.serial });
      if (args[0] === "shell" && args[1] === "settings") {
        return options.serial === "transport-b" ? "abcdef0123456789\n" : "0123456789abcdef\n";
      }
      return "Success\n";
    },
    latestBuild: async () => ({}),
    devotaPackage: "io.github.chasekolozsy.devota",
  });
  const registry = new PhoneRegistry({ pairToken: "test-token", logger: silentLogger, onHostCommand: execute });
  const socket = connect(registry, "abcdef0123456789");
  socket.receive({
    type: "hostCommand",
    id: "host-e2e-1",
    action: "clearAppData",
    args: { packageName: "com.example.target" },
  });
  await settle();

  assert.deepEqual(adbCalls.at(-1), {
    args: ["shell", "pm", "clear", "com.example.target"],
    serial: "transport-b",
  });
  assert.deepEqual(socket.sent.at(-1), {
    type: "hostResult",
    id: "host-e2e-1",
    ok: true,
    result: {
      ok: true,
      backend: "trusted-adb",
      action: "clearAppData",
      packageName: "com.example.target",
    },
  });
  assert.equal(JSON.stringify(socket.sent.at(-1)).includes("transport-b"), false);
  assert.equal(JSON.stringify(socket.sent.at(-1)).includes("abcdef0123456789"), false);
});

test("host commands fail closed when disabled, duplicated, or over the per-phone limit", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const registry = new PhoneRegistry({
    pairToken: "test-token",
    logger: silentLogger,
    onHostCommand: async () => { await gate; return { ok: true }; },
  });
  const socket = connect(registry, "device-a");
  for (let index = 1; index <= 4; index += 1) {
    socket.receive({ type: "hostCommand", id: `pending-${index}`, action: "forceStop", args: {} });
  }
  socket.receive({ type: "hostCommand", id: "pending-1", action: "forceStop", args: {} });
  socket.receive({ type: "hostCommand", id: "pending-5", action: "forceStop", args: {} });
  assert.match(socket.sent.at(-2).error, /duplicate/);
  assert.match(socket.sent.at(-1).error, /too many/);
  release();
  await settle();

  const disabled = new PhoneRegistry({ pairToken: "test-token", logger: silentLogger });
  const disabledSocket = connect(disabled, "device-b");
  disabledSocket.receive({ type: "hostCommand", id: "disabled-1", action: "forceStop", args: {} });
  assert.match(disabledSocket.sent.at(-1).error, /disabled/);
});

test("an authenticated connection cannot switch its device identity", () => {
  const registry = new PhoneRegistry({ pairToken: "test-token", logger: silentLogger });
  const socket = connect(registry, "device-a");
  socket.receive({ type: "hello", deviceId: "device-b" });
  assert.equal(socket.readyState, 3);
  assert.match(socket.closed.reason, /identity cannot change/);
});
