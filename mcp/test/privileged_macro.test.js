import assert from "node:assert/strict";
import test from "node:test";
import {
  adbSerialForAuthenticatedDevice,
  createPrivilegedMacroExecutor,
  validatePrivilegedMacroCommand,
} from "../src/privileged_macro.js";

const manifest = {
  apps: [
    { id: "target", packageName: "com.example.target" },
    { id: "devota", packageName: "io.github.chasekolozsy.devota" },
  ],
};

test("validates exact action, package, argument, and permission allowlists", () => {
  const options = { manifest, devotaPackage: "io.github.chasekolozsy.devota" };
  assert.deepEqual(
    validatePrivilegedMacroCommand({
      ...options,
      action: "grantPermission",
      args: { packageName: "com.example.target", permission: "android.permission.POST_NOTIFICATIONS" },
    }).args,
    { packageName: "com.example.target", permission: "android.permission.POST_NOTIFICATIONS" },
  );
  assert.throws(() => validatePrivilegedMacroCommand({ ...options, action: "shell", args: {} }), /not allowlisted/);
  assert.throws(() => validatePrivilegedMacroCommand({
    ...options,
    action: "forceStop",
    args: { packageName: "com.unknown.target" },
  }), /not uniquely allowlisted/);
  assert.throws(() => validatePrivilegedMacroCommand({
    ...options,
    action: "forceStop",
    args: { packageName: "com.example.target", command: "id" },
  }), /unsupported fields/);
  assert.throws(() => validatePrivilegedMacroCommand({
    ...options,
    action: "grantPermission",
    args: { packageName: "com.example.target", permission: "android.permission.READ_SMS" },
  }), /permission is not allowlisted/);
  assert.throws(() => validatePrivilegedMacroCommand({
    ...options,
    action: "clearAppData",
    args: { packageName: "io.github.chasekolozsy.devota" },
  }), /cannot target DevOTA/);
});

test("matches authenticated device id to exactly one internal ADB transport", async () => {
  const adbDevices = async () => [
    { serial: "private-serial-a", state: "device" },
    { serial: "private-serial-b", state: "device" },
  ];
  const runAdb = async (_args, options) => options.serial === "private-serial-b" ? "abcdef0123456789\n" : "0123456789abcdef\n";
  assert.equal(await adbSerialForAuthenticatedDevice({ deviceId: "abcdef0123456789", adbDevices, runAdb }), "private-serial-b");
  await assert.rejects(
    adbSerialForAuthenticatedDevice({ deviceId: "1111111111111111", adbDevices, runAdb }),
    /no matching ADB connection/,
  );
  await assert.rejects(
    adbSerialForAuthenticatedDevice({
      deviceId: "2222222222222222",
      adbDevices,
      runAdb: async () => "2222222222222222\n",
    }),
    /multiple ADB transports/,
  );
  await assert.rejects(
    adbSerialForAuthenticatedDevice({ deviceId: "null", adbDevices, runAdb }),
    /not a valid Android ID/,
  );
});

test("executes only fixed adb argv and never returns raw ids or serials", async () => {
  const calls = [];
  const execute = createPrivilegedMacroExecutor({
    enabled: true,
    loadManifest: async () => manifest,
    adbDevices: async () => [{ serial: "private-serial", state: "device" }],
    runAdb: async (args, options) => {
      calls.push({ args, options });
      if (args[0] === "shell" && args[1] === "settings") return "abcdef0123456789\n";
      return "Success\n";
    },
    latestBuild: async () => ({ absolutePath: "/trusted/build.apk", filename: "build.apk", size: 123 }),
    devotaPackage: "io.github.chasekolozsy.devota",
  });
  const result = await execute({
    deviceId: "abcdef0123456789",
    action: "installLatest",
    args: { appId: "target" },
  });
  assert.deepEqual(calls.at(-1).args, ["install", "-r", "/trusted/build.apk"]);
  assert.deepEqual(result, {
    ok: true,
    backend: "trusted-adb",
    action: "installLatest",
    appId: "target",
    packageName: "com.example.target",
    filename: "build.apk",
    size: 123,
  });
  const encoded = JSON.stringify(result);
  assert.equal(encoded.includes("abcdef0123456789"), false);
  assert.equal(encoded.includes("private-serial"), false);
});

test("sanitizes adb failures before they cross the hostResult boundary", async () => {
  let probes = 0;
  const execute = createPrivilegedMacroExecutor({
    enabled: true,
    loadManifest: async () => manifest,
    adbDevices: async () => [{ serial: "secret-transport", state: "device" }],
    runAdb: async () => {
      probes += 1;
      if (probes === 1) return "abcdef0123456789\n";
      throw new Error("adb -s secret-transport exploded");
    },
    latestBuild: async () => ({}),
    devotaPackage: "io.github.chasekolozsy.devota",
  });
  await assert.rejects(
    execute({ deviceId: "abcdef0123456789", action: "forceStop", args: { packageName: "com.example.target" } }),
    (error) => error.message === "trusted ADB forceStop failed" && !error.message.includes("secret-transport"),
  );
});
