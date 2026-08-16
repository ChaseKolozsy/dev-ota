const HOST_ACTION_ARGUMENTS = Object.freeze({
  clearAppData: new Set(["packageName"]),
  grantPermission: new Set(["packageName", "permission"]),
  revokePermission: new Set(["packageName", "permission"]),
  forceStop: new Set(["packageName"]),
  launchApp: new Set(["packageName"]),
  installLatest: new Set(["appId"]),
});

export const PRIVILEGED_MACRO_ACTIONS = Object.freeze(Object.keys(HOST_ACTION_ARGUMENTS));

// Keep this deliberately small. These are the only runtime permissions needed
// by the apps in the checked-in DevOTA manifest today. Adding another
// permission is a policy change, not a string-validation change.
export const PRIVILEGED_MACRO_PERMISSIONS = Object.freeze([
  "android.permission.POST_NOTIFICATIONS",
  "android.permission.RECORD_AUDIO",
]);

const PACKAGE_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$/;
const APP_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const ANDROID_ID_RE = /^[0-9a-f]{16}$/i;

function plainObject(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function requireExactKeys(value, allowed, label) {
  if (!plainObject(value)) throw new Error(`${label} must be an object`);
  const extras = Object.keys(value).filter((key) => !allowed.has(key));
  if (extras.length > 0) throw new Error(`${label} contains unsupported fields`);
}

function requiredString(value, label, pattern) {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (!normalized || !pattern.test(normalized)) throw new Error(`${label} is invalid`);
  return normalized;
}

function configuredApps(manifest) {
  if (!manifest || !Array.isArray(manifest.apps)) throw new Error("DevOTA manifest apps are unavailable");
  return manifest.apps;
}

function requireAppByPackage(manifest, packageName, devotaPackage) {
  const normalized = requiredString(packageName, "packageName", PACKAGE_RE);
  const matches = configuredApps(manifest).filter((app) => String(app.packageName || "").trim() === normalized);
  if (matches.length !== 1) throw new Error("host macro package is not uniquely allowlisted in devota.yaml");
  if (normalized === devotaPackage) throw new Error("a running macro cannot target DevOTA itself");
  return { app: matches[0], packageName: normalized };
}

function requireAppById(manifest, appId, devotaPackage) {
  const normalized = requiredString(appId, "appId", APP_ID_RE);
  const matches = configuredApps(manifest).filter((app) => String(app.id || "").trim() === normalized);
  if (matches.length !== 1) throw new Error("host macro app is not uniquely allowlisted in devota.yaml");
  const packageName = requiredString(matches[0].packageName, "manifest packageName", PACKAGE_RE);
  if (packageName === devotaPackage) throw new Error("a running macro cannot target DevOTA itself");
  return { app: matches[0], appId: normalized, packageName };
}

export function validatePrivilegedMacroCommand({ action, args, manifest, devotaPackage }) {
  const command = typeof action === "string" ? action.trim() : "";
  const allowedKeys = HOST_ACTION_ARGUMENTS[command];
  if (!allowedKeys) throw new Error("privileged macro action is not allowlisted");
  requireExactKeys(args, allowedKeys, `${command} args`);

  if (command === "installLatest") {
    const target = requireAppById(manifest, args.appId, devotaPackage);
    return { action: command, args: { appId: target.appId }, app: target.app, packageName: target.packageName };
  }

  const target = requireAppByPackage(manifest, args.packageName, devotaPackage);
  if (command === "grantPermission" || command === "revokePermission") {
    const permission = typeof args.permission === "string" ? args.permission.trim() : "";
    if (!PRIVILEGED_MACRO_PERMISSIONS.includes(permission)) {
      throw new Error("runtime permission is not allowlisted for privileged macros");
    }
    return {
      action: command,
      args: { packageName: target.packageName, permission },
      app: target.app,
      packageName: target.packageName,
    };
  }
  return {
    action: command,
    args: { packageName: target.packageName },
    app: target.app,
    packageName: target.packageName,
  };
}

export async function adbSerialForAuthenticatedDevice({ deviceId, adbDevices, runAdb }) {
  const expectedId = typeof deviceId === "string" ? deviceId.trim().toLowerCase() : "";
  if (!ANDROID_ID_RE.test(expectedId)) {
    throw new Error("the authenticated DevOTA phone identity is not a valid Android ID");
  }
  let devices;
  try {
    devices = await adbDevices();
  } catch {
    throw new Error("could not enumerate trusted ADB transports");
  }
  const matches = [];
  for (const device of devices.filter((item) => item.state === "device")) {
    try {
      const observed = String(await runAdb(
        ["shell", "settings", "get", "secure", "android_id"],
        { serial: device.serial, timeout: 10000, maxBuffer: 64 * 1024 },
      )).trim();
      if (ANDROID_ID_RE.test(observed) && observed.toLowerCase() === expectedId) matches.push(device.serial);
    } catch {
      // A transport that cannot prove its Android ID is never eligible.
    }
  }
  if (matches.length !== 1) {
    throw new Error(matches.length === 0
      ? "the authenticated DevOTA phone has no matching ADB connection"
      : "multiple ADB transports reported the authenticated DevOTA phone identity");
  }
  return matches[0];
}

async function runTrustedAdb(runAdb, args, options, operation) {
  try {
    return await runAdb(args, options);
  } catch {
    // Never forward adb's command line, transport serial, or raw output to the
    // phone or macro evidence.
    throw new Error(`trusted ADB ${operation} failed`);
  }
}

export function createPrivilegedMacroExecutor({
  enabled,
  loadManifest,
  adbDevices,
  runAdb,
  latestBuild,
  devotaPackage,
}) {
  return async function executePrivilegedMacroCommand({ deviceId, action, args }) {
    if (!enabled) throw new Error("privileged macro commands are disabled");
    const manifest = await loadManifest();
    const request = validatePrivilegedMacroCommand({ action, args, manifest, devotaPackage });
    // Validate the complete request before discovering or addressing any ADB
    // transport. The authenticated raw device ID stays inside this matcher.
    const serial = await adbSerialForAuthenticatedDevice({ deviceId, adbDevices, runAdb });
    const common = { ok: true, backend: "trusted-adb", action: request.action };

    if (request.action === "clearAppData") {
      await runTrustedAdb(runAdb, ["shell", "pm", "clear", request.packageName], { serial, timeout: 30000 }, "clearAppData");
      return { ...common, packageName: request.packageName };
    }
    if (request.action === "grantPermission" || request.action === "revokePermission") {
      const permission = request.args.permission;
      await runTrustedAdb(
        runAdb,
        ["shell", "pm", request.action === "grantPermission" ? "grant" : "revoke", request.packageName, permission],
        { serial, timeout: 30000 },
        request.action,
      );
      return { ...common, packageName: request.packageName, permission };
    }
    if (request.action === "forceStop" || request.action === "launchApp") {
      const adbArgs = request.action === "forceStop"
        ? ["shell", "am", "force-stop", request.packageName]
        : ["shell", "monkey", "-p", request.packageName, "-c", "android.intent.category.LAUNCHER", "1"];
      await runTrustedAdb(runAdb, adbArgs, { serial, timeout: 30000 }, request.action);
      return { ...common, packageName: request.packageName };
    }
    if (request.action === "installLatest") {
      const build = await latestBuild(request.args.appId);
      await runTrustedAdb(
        runAdb,
        ["install", "-r", build.absolutePath],
        { serial, timeout: 10 * 60 * 1000, maxBuffer: 8 * 1024 * 1024 },
        "installLatest",
      );
      return {
        ...common,
        appId: request.args.appId,
        packageName: request.packageName,
        filename: pathBasename(build.filename),
        size: Number(build.size) || 0,
      };
    }
    // validatePrivilegedMacroCommand makes this unreachable; keep the guard at
    // the execution boundary so future policy edits fail closed.
    throw new Error("privileged macro action is not allowlisted");
  };
}

function pathBasename(value) {
  return String(value || "").replace(/\\/g, "/").split("/").pop() || "";
}
