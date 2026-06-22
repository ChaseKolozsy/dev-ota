#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { WebSocketServer } from "ws";
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import YAML from "yaml";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TOOL_ROOT = path.resolve(__dirname, "..");
const DEFAULT_DEVOTA_PACKAGE = "io.github.chasekolozsy.devota";

const env = process.env;
const pairToken = env.DEVOTA_PAIR_TOKEN || randomBytes(12).toString("hex");
const wsPort = Number.parseInt(env.DEVOTA_WS_PORT || "8083", 10);
const buildServerUrl = env.DEVOTA_BUILD_SERVER_URL ? stripTrailingSlash(env.DEVOTA_BUILD_SERVER_URL) : null;
const wholeDeviceEnabled = env.DEVOTA_ENABLE_WHOLE_DEVICE === "1";
const buildCommandsEnabled = env.DEVOTA_ENABLE_BUILD_COMMANDS === "1";
const repoRoot = path.resolve(env.DEVOTA_REPO_ROOT || path.resolve(TOOL_ROOT, ".."));
const manifestPath = path.resolve(repoRoot, env.DEVOTA_MANIFEST || "devota.yaml");
const artifactRoot = path.resolve(env.DEVOTA_ARTIFACT_DIR || path.join(TOOL_ROOT, "artifacts"));
const devotaPackage = env.DEVOTA_APP_PACKAGE || DEFAULT_DEVOTA_PACKAGE;

const uiSelectorSchema = z.object({
  text: z.string().optional(),
  contentDescription: z.string().optional(),
  resourceId: z.string().optional(),
  className: z.string().optional(),
  visibleOnly: z.boolean().default(true),
});

class PhoneRelay {
  constructor() {
    this.socket = null;
    this.pending = new Map();
    this.nextId = 1;
    this.hello = null;
    this.status = null;
    this.connectedAt = null;
    this.lastDisconnect = null;
  }

  attach(socket, request) {
    const url = new URL(request.url || "/", `ws://${request.headers.host || "localhost"}`);
    const token = url.searchParams.get("token") || request.headers["x-devota-token"] || request.headers["x-cradle-token"];
    if (token !== pairToken) {
      socket.close(1008, "bad token");
      return;
    }
    if (this.socket) {
      this.socket.close(1000, "replaced by new phone connection");
    }
    this.socket = socket;
    this.connectedAt = new Date().toISOString();
    this.lastDisconnect = null;
    socket.on("message", (data) => this.onMessage(data));
    socket.on("close", () => this.detach(socket));
    socket.on("error", (err) => {
      console.error(`[devota_mcp] phone websocket error: ${err.message}`);
    });
    console.error("[devota_mcp] phone agent connected");
  }

  detach(socket) {
    if (this.socket !== socket) return;
    this.socket = null;
    this.lastDisconnect = new Date().toISOString();
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("phone disconnected"));
    }
    this.pending.clear();
    console.error("[devota_mcp] phone agent disconnected");
  }

  onMessage(data) {
    let msg;
    try {
      msg = JSON.parse(data.toString("utf8"));
    } catch {
      return;
    }
    if (msg.type === "hello") {
      this.hello = msg;
      return;
    }
    if (msg.type === "status") {
      this.status = msg.status || msg;
      return;
    }
    if (!msg.id || !this.pending.has(msg.id)) return;
    const pending = this.pending.get(msg.id);
    this.pending.delete(msg.id);
    clearTimeout(pending.timer);
    if (msg.ok) {
      pending.resolve(msg.result ?? {});
    } else {
      pending.reject(new Error(msg.error || "phone command failed"));
    }
  }

  async command(action, args = {}, timeoutMs = 30000) {
    if (!this.socket || this.socket.readyState !== this.socket.OPEN) {
      throw new Error("DevOTA phone agent is not connected");
    }
    const id = String(this.nextId++);
    const payload = { type: "command", id, action, args };
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`phone command timed out: ${action}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify(payload), (err) => {
        if (!err) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err);
      });
    });
  }

  summary() {
    return {
      connected: Boolean(this.socket && this.socket.readyState === 1),
      connectedAt: this.connectedAt,
      lastDisconnect: this.lastDisconnect,
      hello: this.hello,
      status: this.status,
    };
  }
}

const phone = new PhoneRelay();

const wss = new WebSocketServer({ host: "0.0.0.0", port: wsPort, path: "/phone" });
wss.on("connection", (socket, request) => phone.attach(socket, request));
wss.on("listening", () => {
  const address = wss.address();
  const actualPort = typeof address === "object" && address ? address.port : wsPort;
  console.error(`[devota_mcp] phone relay listening on ws://0.0.0.0:${actualPort}/phone`);
  console.error(`[devota_mcp] pair token: ${pairToken}`);
  console.error(`[devota_mcp] build server URL for phone installs: ${buildServerUrl || "not configured"}`);
});

function stripTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

function textResult(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: "text", text }] };
}

function imageResult(base64, details) {
  return {
    content: [
      { type: "text", text: JSON.stringify(details, null, 2) },
      { type: "image", data: base64, mimeType: "image/png" },
    ],
  };
}

function requireBuildServerUrl() {
  if (!buildServerUrl) {
    throw new Error("DEVOTA_BUILD_SERVER_URL is required for DevOTA project tools");
  }
  return buildServerUrl;
}

async function buildServerJson(pathname, options = {}) {
  const base = requireBuildServerUrl();
  const method = options.method || "GET";
  const headers = { Accept: "application/json", ...(options.headers || {}) };
  const init = { method, headers };
  if (options.data !== undefined) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(options.data);
  }
  const response = await fetch(`${base}${pathname}`, init);
  const text = await response.text();
  let payload = {};
  if (text.trim()) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = { raw: text };
    }
  }
  if (!response.ok) {
    throw new Error(`DevOTA build server ${method} ${pathname} returned HTTP ${response.status}: ${text.trim()}`);
  }
  return payload;
}

function adbArgs(serial, args) {
  return serial ? ["-s", serial, ...args] : args;
}

async function runAdb(args, options = {}) {
  const { serial, timeout = 30000, encoding = "utf8", maxBuffer = 32 * 1024 * 1024 } = options;
  const finalArgs = adbArgs(serial, args);
  return await new Promise((resolve, reject) => {
    execFile("adb", finalArgs, { timeout, encoding, maxBuffer }, (error, stdout, stderr) => {
      if (error) {
        const detail = stderr || stdout || error.message;
        reject(new Error(`adb ${finalArgs.join(" ")} failed: ${String(detail).trim()}`));
        return;
      }
      resolve(stdout);
    });
  });
}

async function adbDevices() {
  const out = await runAdb(["devices", "-l"]);
  return out
    .split(/\r?\n/)
    .slice(1)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [serial, state, ...rest] = line.split(/\s+/);
      const fields = {};
      for (const token of rest) {
        const idx = token.indexOf(":");
        if (idx > 0) fields[token.slice(0, idx)] = token.slice(idx + 1);
      }
      return { serial, state, ...fields };
    });
}

async function chooseAdbSerial(serial) {
  if (serial) return serial;
  const devices = (await adbDevices()).filter((d) => d.state === "device");
  if (devices.length === 0) throw new Error("no adb device connected");
  if (devices.length > 1) throw new Error("multiple adb devices connected; pass serial");
  return devices[0].serial;
}

function publicApp(app) {
  return {
    id: app.id,
    label: app.label,
    packageName: app.packageName,
    notes: app.notes,
    buildDirs: app.buildDirs.map((entry) => entry.relative),
    build: app.build,
  };
}

async function loadManifest() {
  const raw = await readFile(manifestPath, "utf8");
  const data = manifestPath.endsWith(".json") ? JSON.parse(raw) : YAML.parse(raw);
  if (!data || !Array.isArray(data.apps) || data.apps.length === 0) {
    throw new Error(`DevOTA manifest must define a non-empty apps list: ${manifestPath}`);
  }
  const seen = new Set();
  const apps = data.apps.map((app, index) => {
    const id = String(app?.id || "").trim();
    if (!id) throw new Error(`apps[${index}].id is required in ${manifestPath}`);
    if (seen.has(id)) throw new Error(`duplicate app id in ${manifestPath}: ${id}`);
    seen.add(id);
    const buildDirs = Array.isArray(app.buildDirs) ? app.buildDirs : [];
    if (buildDirs.length === 0) throw new Error(`${id}.buildDirs must be a non-empty list`);
    return {
      id,
      label: String(app.label || id),
      packageName: String(app.packageName || ""),
      notes: String(app.notes || ""),
      buildDirs: buildDirs.map((rel) => ({
        relative: String(rel),
        absolute: path.resolve(repoRoot, String(rel)),
      })),
      build: app.build || null,
    };
  });
  return { version: data.version || 1, apps };
}

async function resolveApp(appId) {
  const manifest = await loadManifest();
  if (!appId) return manifest.apps[0];
  const app = manifest.apps.find((item) => item.id === appId);
  if (!app) throw new Error(`unknown DevOTA app id: ${appId}`);
  return app;
}

async function packageNameFor(appId, explicitPackageName) {
  if (explicitPackageName && explicitPackageName.trim()) return explicitPackageName.trim();
  const app = await resolveApp(appId);
  return app.packageName || "";
}

async function walkApks(dir, app, out) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await walkApks(full, app, out);
      continue;
    }
    if (!entry.isFile() || !entry.name.endsWith(".apk")) continue;
    const st = await stat(full);
    const relativePath = path.relative(repoRoot, full).split(path.sep).join("/");
    out.push({
      filename: entry.name,
      size: st.size,
      modifiedMs: st.mtimeMs,
      modified: new Date(st.mtimeMs).toISOString(),
      path: relativePath,
      absolutePath: full,
      appId: app.id,
      appLabel: app.label,
      packageName: app.packageName,
      kind: app.id,
    });
  }
}

async function scanBuilds(appId) {
  const manifest = await loadManifest();
  const builds = [];
  for (const app of manifest.apps) {
    if (appId && app.id !== appId) continue;
    for (const buildDir of app.buildDirs) {
      await walkApks(buildDir.absolute, app, builds);
    }
  }
  builds.sort((a, b) => b.modifiedMs - a.modifiedMs);
  return builds;
}

async function latestBuild(appId) {
  const builds = await scanBuilds(appId);
  if (builds.length === 0) throw new Error(`no ${appId || "matching"} APK builds found`);
  return builds[0];
}

function requireWholeDeviceTool(name) {
  if (!wholeDeviceEnabled) {
    throw new Error(`${name} requires DEVOTA_ENABLE_WHOLE_DEVICE=1 on the MCP server`);
  }
}

function requireBuildCommandTool(name) {
  if (!buildCommandsEnabled) {
    throw new Error(`${name} requires DEVOTA_ENABLE_BUILD_COMMANDS=1 on the MCP server`);
  }
}

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

async function createRunDir(name) {
  const dir = path.join(artifactRoot, "runs", `${stamp()}-${name}`);
  await mkdir(dir, { recursive: true });
  return dir;
}

async function writeJsonArtifact(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`);
  return file;
}

function relArtifact(file) {
  return path.relative(TOOL_ROOT, file).split(path.sep).join("/");
}

async function runExecFile(command, args, options = {}) {
  const { cwd, timeout = 30000, maxBuffer = 32 * 1024 * 1024 } = options;
  return await new Promise((resolve, reject) => {
    execFile(command, args, { cwd, timeout, maxBuffer, encoding: "utf8" }, (error, stdout, stderr) => {
      const result = { command, args, cwd, stdout, stderr, exitCode: error?.code ?? 0 };
      if (error) {
        const detail = stderr || stdout || error.message;
        reject(Object.assign(new Error(`${command} ${args.join(" ")} failed: ${String(detail).trim()}`), { result }));
        return;
      }
      resolve(result);
    });
  });
}

function commandRunner(commandText) {
  if (process.platform === "win32") {
    return { command: "powershell.exe", args: ["-NoProfile", "-Command", commandText] };
  }
  return { command: "bash", args: ["-lc", commandText] };
}

function buildCommandForApp(app, mode) {
  const build = app.build;
  if (!build) return null;
  if (typeof build === "string") return { command: build, workingDir: "." };
  const commands = build.commands || {};
  const command = commands[mode] || build.command;
  if (!command) return null;
  return {
    command: String(command),
    workingDir: String(build.workingDir || "."),
  };
}

async function runConfiguredBuild(appId, mode, runDir) {
  requireBuildCommandTool("android_build_apk");
  const app = await resolveApp(appId);
  const configured = buildCommandForApp(app, mode);
  if (!configured) {
    throw new Error(`app ${app.id} does not define a build command in devota.yaml`);
  }
  const cwd = path.resolve(repoRoot, configured.workingDir);
  const { command, args } = commandRunner(configured.command);

  const startedAt = new Date().toISOString();
  const result = await runExecFile(command, args, {
    cwd,
    timeout: 10 * 60 * 1000,
    maxBuffer: 64 * 1024 * 1024,
  });
  const finishedAt = new Date().toISOString();
  await writeFile(path.join(runDir, "build.stdout.log"), result.stdout || "");
  await writeFile(path.join(runDir, "build.stderr.log"), result.stderr || "");
  const build = await latestBuild(app.id);
  return {
    appId: app.id,
    appLabel: app.label,
    mode,
    startedAt,
    finishedAt,
    command: result.command,
    args: result.args,
    cwd: result.cwd,
    output: {
      stdoutLog: relArtifact(path.join(runDir, "build.stdout.log")),
      stderrLog: relArtifact(path.join(runDir, "build.stderr.log")),
    },
    latestBuild: build,
  };
}

async function installLatestApk(appId, mode, serial) {
  const app = await resolveApp(appId);
  const build = await latestBuild(app.id);
  const selfUpdate = app.packageName === devotaPackage;
  if (mode !== "phone") {
    try {
      const useSerial = await chooseAdbSerial(serial);
      const out = await runAdb(["install", "-r", "-d", "-g", build.absolutePath], {
        serial: useSerial,
        timeout: 120000,
        maxBuffer: 16 * 1024 * 1024,
      });
      return { mode: "adb", serial: useSerial, build, output: out.trim(), completed: true };
    } catch (err) {
      if (mode === "adb") throw err;
    }
  }
  if (!buildServerUrl) {
    throw new Error("DEVOTA_BUILD_SERVER_URL is required for phone-agent installs");
  }
  const result = await phone.command(
    "installFromBuild",
    {
      buildServerUrl,
      path: build.path,
      filename: build.filename,
    },
    180000,
  );
  return {
    mode: "phone",
    app: publicApp(app),
    build,
    result,
    completed: result.status !== "awaiting_user_confirmation",
    selfUpdate,
    manualConfirmationRequired: result.status === "awaiting_user_confirmation",
    note: selfUpdate
      ? "DevOTA self-updates can only download and open Android's package updater. Approve the update on the phone and restart the agent after Android replaces the app."
      : "Phone-agent installs open Android's package updater. Accessibility automation may help with target-app prompts, but user approval can still be required by Android.",
  };
}

async function captureScreenshot(runDir, label, serial) {
  const file = path.join(runDir, `${label}.png`);
  if (phone.summary().connected) {
    const result = await phone.command("screenshot", {}, 45000);
    await writeFile(file, Buffer.from(result.pngBase64, "base64"));
    return { mode: "phone", artifact: file, relativeArtifact: relArtifact(file), ...result, pngBase64: undefined };
  }
  const useSerial = await chooseAdbSerial(serial);
  const png = await runAdb(["exec-out", "screencap", "-p"], {
    serial: useSerial,
    encoding: "buffer",
    maxBuffer: 32 * 1024 * 1024,
  });
  await writeFile(file, png);
  return { mode: "adb", serial: useSerial, artifact: file, relativeArtifact: relArtifact(file), bytes: png.length };
}

async function getUiDump(serial) {
  if (phone.summary().connected) {
    return { mode: "phone", ...(await phone.command("uiDump", {})) };
  }
  const useSerial = await chooseAdbSerial(serial);
  await runAdb(["shell", "uiautomator", "dump", "/sdcard/window.xml"], { serial: useSerial });
  const xml = await runAdb(["exec-out", "cat", "/sdcard/window.xml"], {
    serial: useSerial,
    maxBuffer: 8 * 1024 * 1024,
  });
  return { mode: "adb", serial: useSerial, xml };
}

function nodeText(node) {
  return [node.text, node.contentDescription, node.resourceId, node.className]
    .filter((value) => value !== undefined && value !== null)
    .join(" ");
}

function fieldMatches(actual, expected) {
  if (expected === undefined || expected === null || expected === "") return true;
  return String(actual || "").toLowerCase().includes(String(expected).toLowerCase());
}

function validBounds(bounds) {
  return Boolean(bounds && bounds.right > bounds.left && bounds.bottom > bounds.top && bounds.right > 0 && bounds.bottom > 0);
}

function matchUiNode(node, selector) {
  if (selector.visibleOnly !== false && !validBounds(node.bounds)) return false;
  return (
    fieldMatches(node.text, selector.text) &&
    fieldMatches(node.contentDescription, selector.contentDescription) &&
    fieldMatches(node.resourceId, selector.resourceId) &&
    fieldMatches(node.className, selector.className)
  );
}

async function findUiNodes(selector, serial) {
  const dump = await getUiDump(serial);
  if (!Array.isArray(dump.nodes)) {
    throw new Error("parsed phone-agent UI dump is required for UI selectors");
  }
  const matches = dump.nodes.filter((node) => matchUiNode(node, selector));
  return { dump, matches };
}

function centerOfNode(node) {
  if (!validBounds(node.bounds)) throw new Error("matched UI node has invalid bounds");
  return {
    x: Math.round((node.bounds.left + node.bounds.right) / 2),
    y: Math.round((node.bounds.top + node.bounds.bottom) / 2),
  };
}

async function tapNode(node, packageName, serial) {
  const { x, y } = centerOfNode(node);
  const targetPackage = packageName || node.package || "";
  return {
    x,
    y,
    packageName: targetPackage,
    result: await phoneOrAdb("tap", { x, y, packageName: targetPackage }, async () => {
      const useSerial = await chooseAdbSerial(serial);
      await runAdb(["shell", "input", "tap", String(x), String(y)], { serial: useSerial });
      return { mode: "adb", serial: useSerial, ok: true };
    }),
  };
}

async function captureLogcat({ packageName, durationMs, clear, filter, serial, runDir }) {
  const useSerial = await chooseAdbSerial(serial);
  const duration = Math.min(60000, Math.max(1000, Math.round(durationMs)));
  if (clear) await runAdb(["logcat", "-c"], { serial: useSerial, timeout: 15000 });
  await new Promise((resolve) => setTimeout(resolve, duration));

  let args = ["logcat", "-d", "-v", "time"];
  let pid = null;
  if (filter === "package" && packageName) {
    try {
      pid = String(await runAdb(["shell", "pidof", packageName], { serial: useSerial, timeout: 10000 })).trim().split(/\s+/)[0];
      if (pid) args = ["logcat", "-d", "-v", "time", "--pid", pid];
    } catch {
      pid = null;
    }
  }

  const raw = await runAdb(args, {
    serial: useSerial,
    timeout: 30000,
    maxBuffer: 64 * 1024 * 1024,
  });
  const text = filter === "package" && packageName && !pid
    ? raw.split(/\r?\n/).filter((line) => line.includes(packageName)).join("\n")
    : raw;
  const file = path.join(runDir, "logcat.txt");
  await writeFile(file, text);
  return {
    mode: "adb",
    serial: useSerial,
    packageName,
    durationMs: duration,
    filter,
    pid,
    artifact: file,
    relativeArtifact: relArtifact(file),
    bytes: Buffer.byteLength(text),
    lines: text ? text.split(/\r?\n/).length : 0,
  };
}

function adbStartIntentArgs({ packageName, action, uri, extras = {} }) {
  const args = ["shell", "am", "start"];
  const finalAction = action || (uri ? "android.intent.action.VIEW" : null);
  if (finalAction) args.push("-a", finalAction);
  if (uri) args.push("-d", uri);
  if (packageName) args.push("-p", packageName);
  for (const [key, value] of Object.entries(extras || {})) {
    if (typeof value === "boolean") {
      args.push("--ez", key, String(value));
    } else if (Number.isInteger(value)) {
      args.push("--ei", key, String(value));
    } else if (typeof value === "number") {
      args.push("--ef", key, String(value));
    } else {
      args.push("--es", key, String(value));
    }
  }
  return args;
}

function summarizeNode(node) {
  return {
    package: node.package,
    className: node.className,
    text: node.text,
    contentDescription: node.contentDescription,
    resourceId: node.resourceId,
    clickable: node.clickable,
    enabled: node.enabled,
    focused: node.focused,
    bounds: node.bounds,
  };
}

function permissionDecisionPatterns(decision) {
  if (decision === "deny") return [/don.?t allow/i, /\bdeny\b/i];
  if (decision === "only_this_time") return [/only this time/i];
  if (decision === "while_in_use") return [/while using/i, /while the app/i];
  return [/while using/i, /allow/i, /ok/i];
}

async function phoneOrAdb(action, args, adbFallback) {
  if (phone.summary().connected) return await phone.command(action, args);
  if (adbFallback) return await adbFallback();
  throw new Error("phone agent is not connected and no adb fallback is available");
}

const server = new McpServer({
  name: "devota-android-control",
  version: "0.1.0",
});

server.registerTool(
  "android_status",
  {
    title: "Android Control Status",
    description: "Report phone-agent, relay, build-server, configured apps, and adb status.",
  },
  async () => {
    let adb = { available: false, devices: [], error: null };
    try {
      adb.devices = await adbDevices();
      adb.available = true;
    } catch (err) {
      adb.error = err.message;
    }
    return textResult({
      relay: { port: wsPort, path: "/phone", wholeDeviceEnabled, buildCommandsEnabled },
      phone: phone.summary(),
      adb,
      buildServerUrl,
      repoRoot,
      manifestPath,
      apps: (await loadManifest()).apps.map(publicApp),
    });
  },
);

server.registerTool(
  "android_probe_adb",
  {
    title: "Probe Network ADB",
    description: "Try adb connect against a host:port reachable over your LAN or VPN.",
    inputSchema: {
      hostPort: z.string().optional().describe("ADB host:port. Defaults to DEVOTA_ADB_HOST."),
    },
  },
  async ({ hostPort }) => {
    const target = hostPort || env.DEVOTA_ADB_HOST;
    if (!target) throw new Error("hostPort or DEVOTA_ADB_HOST is required");
    const out = await runAdb(["connect", target], { timeout: 15000 });
    return textResult({ target, output: out.trim(), devices: await adbDevices() });
  },
);

server.registerTool(
  "android_list_builds",
  {
    title: "List Android Builds",
    description: "List APK builds known to DevOTA.",
    inputSchema: {
      appId: z.string().optional(),
    },
  },
  async ({ appId }) => textResult(await scanBuilds(appId)),
);

server.registerTool(
  "devota_projects_board",
  {
    title: "Read DevOTA Project Board",
    description: "Return clients, projects, phases, cards, comments, templates, and email configuration state from the DevOTA build server.",
  },
  async () => textResult(await buildServerJson("/projects/board")),
);

server.registerTool(
  "devota_projects_create_client",
  {
    title: "Create DevOTA Client",
    description: "Create a client record for the DevOTA Projects board.",
    inputSchema: {
      name: z.string(),
      email: z.string().optional(),
      notes: z.string().optional(),
    },
  },
  async ({ name, email, notes }) => textResult(
    await buildServerJson("/projects/clients", {
      method: "POST",
      data: { name, email, notes },
    }),
  ),
);

server.registerTool(
  "devota_projects_create_project",
  {
    title: "Create DevOTA Project",
    description: "Create a project. Pass clientId, or pass clientName/clientEmail to create the client first.",
    inputSchema: {
      clientId: z.number().optional(),
      clientName: z.string().optional(),
      clientEmail: z.string().optional(),
      name: z.string(),
      repoUrl: z.string().optional(),
      buildAppId: z.string().optional(),
      notes: z.string().optional(),
      templateId: z.number().optional(),
      applyTemplate: z.boolean().default(true),
    },
  },
  async ({ clientId, clientName, clientEmail, name, repoUrl, buildAppId, notes, templateId, applyTemplate }) => {
    let actualClientId = clientId;
    let client = null;
    if (!actualClientId) {
      if (!clientName) throw new Error("clientId or clientName is required");
      const created = await buildServerJson("/projects/clients", {
        method: "POST",
        data: { name: clientName, email: clientEmail || "" },
      });
      client = created.item;
      actualClientId = client?.id;
    }
    const project = await buildServerJson("/projects/projects", {
      method: "POST",
      data: {
        clientId: actualClientId,
        name,
        repoUrl,
        buildAppId,
        notes,
        templateId,
        applyTemplate,
      },
    });
    return textResult({ status: "ok", client, project: project.item });
  },
);

server.registerTool(
  "devota_projects_create_template",
  {
    title: "Create DevOTA Phase Template",
    description: "Create a reusable phase template for new projects.",
    inputSchema: {
      name: z.string(),
      phases: z.array(z.string()).min(1),
    },
  },
  async ({ name, phases }) => textResult(
    await buildServerJson("/projects/templates", {
      method: "POST",
      data: { name, phases },
    }),
  ),
);

server.registerTool(
  "devota_projects_create_card",
  {
    title: "Create DevOTA Card",
    description: "Create a Kanban card under an existing phase.",
    inputSchema: {
      phaseId: z.number(),
      title: z.string(),
      body: z.string().optional(),
      status: z.enum(["todo", "doing", "waiting_client", "review", "done"]).default("todo"),
      clientActionRequired: z.boolean().default(false),
    },
  },
  async ({ phaseId, title, body, status, clientActionRequired }) => textResult(
    await buildServerJson("/projects/cards", {
      method: "POST",
      data: { phaseId, title, body, status, clientActionRequired },
    }),
  ),
);

server.registerTool(
  "devota_projects_advance_card",
  {
    title: "Advance DevOTA Card",
    description: "Move a card to a new status and optionally a new phase, with an optional comment.",
    inputSchema: {
      cardId: z.number(),
      status: z.enum(["todo", "doing", "waiting_client", "review", "done"]),
      phaseId: z.number().optional(),
      clientActionRequired: z.boolean().optional(),
      comment: z.string().optional(),
    },
  },
  async ({ cardId, status, phaseId, clientActionRequired, comment }) => {
    const data = { status };
    if (phaseId !== undefined) data.phaseId = phaseId;
    if (clientActionRequired !== undefined) data.clientActionRequired = clientActionRequired;
    const updated = await buildServerJson(`/projects/cards/${cardId}`, {
      method: "PATCH",
      data,
    });
    let addedComment = null;
    if (comment && comment.trim()) {
      const result = await buildServerJson(`/projects/cards/${cardId}/comments`, {
        method: "POST",
        data: { authorType: "me", body: comment.trim(), source: "mcp" },
      });
      addedComment = result.item;
    }
    return textResult({ status: "ok", card: updated.item, comment: addedComment });
  },
);

server.registerTool(
  "devota_projects_add_comment",
  {
    title: "Add DevOTA Card Comment",
    description: "Append a comment to a DevOTA card thread.",
    inputSchema: {
      cardId: z.number(),
      body: z.string(),
      authorType: z.enum(["me", "client", "system"]).default("me"),
    },
  },
  async ({ cardId, body, authorType }) => textResult(
    await buildServerJson(`/projects/cards/${cardId}/comments`, {
      method: "POST",
      data: { body, authorType, source: "mcp" },
    }),
  ),
);

server.registerTool(
  "devota_projects_send_card_email",
  {
    title: "Send DevOTA Card Email",
    description: "Preview or send a Postmark email tied to a card thread.",
    inputSchema: {
      cardId: z.number(),
      event: z.enum(["update", "phase_started", "phase_completed", "client_action"]).default("update"),
      subject: z.string().optional(),
      message: z.string().optional(),
      previewOnly: z.boolean().default(false),
    },
  },
  async ({ cardId, event, subject, message, previewOnly }) => {
    const path = previewOnly
      ? `/projects/cards/${cardId}/email/preview`
      : `/projects/cards/${cardId}/email/send`;
    return textResult(
      await buildServerJson(path, {
        method: "POST",
        data: { event, subject, message },
      }),
    );
  },
);

server.registerTool(
  "devota_projects_pull_replies",
  {
    title: "Pull DevOTA Email Replies",
    description: "Pull inbound reply events from the configured public relay into DevOTA card comments.",
  },
  async () => textResult(
    await buildServerJson("/projects/mail/pull", {
      method: "POST",
      data: {},
    }),
  ),
);

server.registerTool(
  "android_build_apk",
  {
    title: "Build Android APK",
    description: "Run the selected app's optional manifest build command. Requires DEVOTA_ENABLE_BUILD_COMMANDS=1.",
    inputSchema: {
      appId: z.string().optional(),
      mode: z.enum(["debug", "release"]).default("debug"),
    },
  },
  async ({ appId, mode }) => {
    const app = await resolveApp(appId);
    const runDir = await createRunDir(`build-${app.id}-${mode}`);
    const result = await runConfiguredBuild(app.id, mode, runDir);
    const manifest = { tool: "android_build_apk", runDir, relativeRunDir: relArtifact(runDir), result };
    await writeJsonArtifact(path.join(runDir, "manifest.json"), manifest);
    return textResult(manifest);
  },
);

server.registerTool(
  "android_install_latest",
  {
    title: "Install Latest APK",
    description: "Install the selected app's latest APK using adb when available, otherwise ask the phone agent to download and open Android's installer. DevOTA self-updates are manual confirmation only.",
    inputSchema: {
      appId: z.string().optional(),
      mode: z.enum(["auto", "adb", "phone"]).default("auto"),
      serial: z.string().optional(),
    },
  },
  async ({ appId, mode, serial }) => {
    return textResult(await installLatestApk(appId, mode, serial));
  },
);

server.registerTool(
  "android_rebuild_install_launch",
  {
    title: "Rebuild Install Launch",
    description: "Run an optional manifest build command, install the latest APK, launch the app, and collect debug artifacts. Requires DEVOTA_ENABLE_BUILD_COMMANDS=1.",
    inputSchema: {
      appId: z.string().optional(),
      packageName: z.string().optional(),
      buildMode: z.enum(["debug", "release"]).default("debug"),
      installMode: z.enum(["auto", "adb", "phone"]).default("auto"),
      captureLogs: z.boolean().default(false),
      screenshot: z.boolean().default(true),
      serial: z.string().optional(),
    },
  },
  async ({ appId, packageName, buildMode, installMode, captureLogs, screenshot, serial }) => {
    const app = await resolveApp(appId);
    const targetPackage = await packageNameFor(app.id, packageName);
    const runDir = await createRunDir(`rebuild-install-launch-${app.id}`);
    const manifest = {
      tool: "android_rebuild_install_launch",
      runDir,
      relativeRunDir: relArtifact(runDir),
      inputs: { appId: app.id, packageName: targetPackage, buildMode, installMode, captureLogs, screenshot },
      steps: {},
      completed: false,
    };

    try {
      manifest.steps.build = await runConfiguredBuild(app.id, buildMode, runDir);
      manifest.steps.install = await installLatestApk(app.id, installMode, serial);
      if (manifest.steps.install.completed) {
        manifest.steps.launch = await phoneOrAdb("launchApp", { packageName: targetPackage }, async () => {
          const useSerial = await chooseAdbSerial(serial);
          const out = await runAdb(
            ["shell", "monkey", "-p", targetPackage, "-c", "android.intent.category.LAUNCHER", "1"],
            { serial: useSerial },
          );
          return { mode: "adb", serial: useSerial, output: out.trim() };
        });
        await new Promise((resolve) => setTimeout(resolve, 1500));
        if (screenshot) manifest.steps.screenshot = await captureScreenshot(runDir, "launch", serial);
        manifest.steps.uiDump = await getUiDump(serial);
        await writeJsonArtifact(path.join(runDir, "ui-dump.json"), manifest.steps.uiDump);
        if (captureLogs) {
          try {
            manifest.steps.logcat = await captureLogcat({
              packageName: targetPackage,
              durationMs: 5000,
              clear: false,
              filter: "package",
              serial,
              runDir,
            });
          } catch (err) {
            manifest.steps.logcat = { ok: false, error: err.message };
          }
        }
        manifest.completed = true;
      } else {
        manifest.awaitingUserConfirmation = true;
      }
    } catch (err) {
      manifest.error = err.message;
      await writeJsonArtifact(path.join(runDir, "manifest.json"), manifest);
      throw err;
    }
    await writeJsonArtifact(path.join(runDir, "manifest.json"), manifest);
    return textResult(manifest);
  },
);

server.registerTool(
  "android_launch_app",
  {
    title: "Launch Android App",
    description: "Launch a package on the phone. Defaults to the selected manifest app package.",
    inputSchema: {
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ appId, packageName, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    if (!targetPackage) throw new Error("packageName or manifest app packageName is required");
    return textResult(
      await phoneOrAdb("launchApp", { packageName: targetPackage }, async () => {
        const useSerial = await chooseAdbSerial(serial);
        const out = await runAdb(
          ["shell", "monkey", "-p", targetPackage, "-c", "android.intent.category.LAUNCHER", "1"],
          { serial: useSerial },
        );
        return { mode: "adb", serial: useSerial, output: out.trim() };
      }),
    );
  },
);

server.registerTool(
  "android_launch_intent",
  {
    title: "Launch Android Intent",
    description: "Launch a package-scoped Android intent or deep link.",
    inputSchema: {
      appId: z.string().optional(),
      packageName: z.string().optional(),
      action: z.string().optional(),
      uri: z.string().optional(),
      extras: z.record(z.union([z.string(), z.number(), z.boolean()])).optional(),
      serial: z.string().optional(),
    },
  },
  async ({ appId, packageName, action, uri, extras, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    return textResult(
      await phoneOrAdb("launchIntent", { packageName: targetPackage, action, uri, extras: extras || {} }, async () => {
        const useSerial = await chooseAdbSerial(serial);
        if (!action && !uri && targetPackage) {
          const out = await runAdb(
            ["shell", "monkey", "-p", targetPackage, "-c", "android.intent.category.LAUNCHER", "1"],
            { serial: useSerial },
          );
          return { mode: "adb", serial: useSerial, output: out.trim() };
        }
        const out = await runAdb(adbStartIntentArgs({ packageName: targetPackage, action, uri, extras }), {
          serial: useSerial,
          timeout: 30000,
        });
        return { mode: "adb", serial: useSerial, output: out.trim() };
      }),
    );
  },
);

server.registerTool(
  "android_screenshot",
  {
    title: "Android Screenshot",
    description: "Capture a PNG screenshot through the phone agent or adb fallback.",
    inputSchema: {
      serial: z.string().optional(),
    },
  },
  async ({ serial }) => {
    await mkdir(artifactRoot, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const file = path.join(artifactRoot, `screenshot-${stamp}.png`);
    if (phone.summary().connected) {
      const result = await phone.command("screenshot", {}, 45000);
      await writeFile(file, Buffer.from(result.pngBase64, "base64"));
      return imageResult(result.pngBase64, { mode: "phone", artifact: file, ...result, pngBase64: undefined });
    }
    const useSerial = await chooseAdbSerial(serial);
    const png = await runAdb(["exec-out", "screencap", "-p"], {
      serial: useSerial,
      encoding: "buffer",
      maxBuffer: 32 * 1024 * 1024,
    });
    await writeFile(file, png);
    return imageResult(png.toString("base64"), { mode: "adb", serial: useSerial, artifact: file, bytes: png.length });
  },
);

server.registerTool(
  "android_ui_dump",
  {
    title: "Android UI Dump",
    description: "Return current UI hierarchy. Phone-agent mode returns parsed nodes; adb fallback returns raw UIAutomator XML.",
    inputSchema: {
      serial: z.string().optional(),
    },
  },
  async ({ serial }) => textResult(await getUiDump(serial)),
);

server.registerTool(
  "android_logcat_capture",
  {
    title: "Capture Android Logcat",
    description: "Capture logcat through ADB. This tool requires an ADB device; the phone agent cannot read app logs.",
    inputSchema: {
      appId: z.string().optional(),
      packageName: z.string().optional(),
      durationMs: z.number().default(10000),
      clear: z.boolean().default(false),
      filter: z.enum(["package", "none"]).default("package"),
      serial: z.string().optional(),
    },
  },
  async ({ appId, packageName, durationMs, clear, filter, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    const runDir = await createRunDir(`logcat-${(targetPackage || "android").replace(/[^a-zA-Z0-9_.-]/g, "_")}`);
    const result = await captureLogcat({ packageName: targetPackage, durationMs, clear, filter, serial, runDir });
    const manifest = { tool: "android_logcat_capture", runDir, relativeRunDir: relArtifact(runDir), result };
    await writeJsonArtifact(path.join(runDir, "manifest.json"), manifest);
    return textResult(manifest);
  },
);

server.registerTool(
  "android_collect_state",
  {
    title: "Collect Android State",
    description: "Collect status, screenshot, UI dump, and optional logcat into a run artifact directory.",
    inputSchema: {
      appId: z.string().optional(),
      packageName: z.string().optional(),
      includeLogs: z.boolean().default(false),
      serial: z.string().optional(),
    },
  },
  async ({ appId, packageName, includeLogs, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    const runDir = await createRunDir(`state-${(targetPackage || "android").replace(/[^a-zA-Z0-9_.-]/g, "_")}`);
    const status = {
      relay: { port: wsPort, path: "/phone", wholeDeviceEnabled, buildCommandsEnabled },
      phone: phone.summary(),
      buildServerUrl,
    };
    const screenshot = await captureScreenshot(runDir, "state", serial);
    const uiDump = await getUiDump(serial);
    await writeJsonArtifact(path.join(runDir, "ui-dump.json"), uiDump);
    const manifest = {
      tool: "android_collect_state",
      runDir,
      relativeRunDir: relArtifact(runDir),
      packageName: targetPackage,
      status,
      screenshot,
      uiDump: {
        mode: uiDump.mode,
        activePackage: uiDump.activePackage,
        nodeCount: uiDump.nodeCount,
        truncated: uiDump.truncated,
        artifact: relArtifact(path.join(runDir, "ui-dump.json")),
      },
    };
    if (includeLogs) {
      try {
        manifest.logcat = await captureLogcat({ packageName: targetPackage, durationMs: 5000, clear: false, filter: "package", serial, runDir });
      } catch (err) {
        manifest.logcat = { ok: false, error: err.message };
      }
    }
    await writeJsonArtifact(path.join(runDir, "manifest.json"), manifest);
    return textResult(manifest);
  },
);

server.registerTool(
  "android_tap",
  {
    title: "Tap Android Screen",
    description: "Tap screen coordinates.",
    inputSchema: {
      x: z.number(),
      y: z.number(),
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ x, y, appId, packageName, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    return textResult(
      await phoneOrAdb("tap", { x, y, packageName: targetPackage }, async () => {
        const useSerial = await chooseAdbSerial(serial);
        await runAdb(["shell", "input", "tap", String(Math.round(x)), String(Math.round(y))], { serial: useSerial });
        return { mode: "adb", serial: useSerial, ok: true };
      }),
    );
  },
);

server.registerTool(
  "android_find_ui",
  {
    title: "Find Android UI Nodes",
    description: "Find nodes in the current parsed accessibility UI dump.",
    inputSchema: {
      text: z.string().optional(),
      contentDescription: z.string().optional(),
      resourceId: z.string().optional(),
      className: z.string().optional(),
      visibleOnly: z.boolean().default(true),
      serial: z.string().optional(),
    },
  },
  async ({ serial, ...selector }) => {
    const { dump, matches } = await findUiNodes(selector, serial);
    return textResult({
      activePackage: dump.activePackage,
      nodeCount: dump.nodeCount,
      matchCount: matches.length,
      matches: matches.map(summarizeNode),
    });
  },
);

server.registerTool(
  "android_tap_ui",
  {
    title: "Tap Android UI Node",
    description: "Find exactly one UI node by selector and tap its center.",
    inputSchema: {
      selector: uiSelectorSchema,
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ selector, appId, packageName, serial }) => {
    const { dump, matches } = await findUiNodes(selector, serial);
    if (matches.length !== 1) {
      throw new Error(`android_tap_ui expected exactly one match, found ${matches.length}`);
    }
    const targetPackage = await packageNameFor(appId, packageName);
    const tap = await tapNode(matches[0], targetPackage, serial);
    return textResult({ activePackage: dump.activePackage, match: summarizeNode(matches[0]), tap });
  },
);

server.registerTool(
  "android_assert_ui",
  {
    title: "Assert Android UI",
    description: "Assert text presence/absence from the current UI dump and save evidence artifacts.",
    inputSchema: {
      mustContainText: z.array(z.string()).default([]),
      mustNotContainText: z.array(z.string()).default([]),
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ mustContainText, mustNotContainText, appId, packageName, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    const runDir = await createRunDir("assert-ui");
    const screenshot = await captureScreenshot(runDir, "assert", serial);
    const uiDump = await getUiDump(serial);
    await writeJsonArtifact(path.join(runDir, "ui-dump.json"), uiDump);
    const haystack = Array.isArray(uiDump.nodes) ? uiDump.nodes.map(nodeText).join("\n").toLowerCase() : String(uiDump.xml || "").toLowerCase();
    const failures = [];
    for (const text of mustContainText) {
      if (!haystack.includes(text.toLowerCase())) failures.push(`missing expected text: ${text}`);
    }
    for (const text of mustNotContainText) {
      if (haystack.includes(text.toLowerCase())) failures.push(`found forbidden text: ${text}`);
    }
    if (targetPackage && uiDump.activePackage && uiDump.activePackage !== targetPackage) {
      failures.push(`active package ${uiDump.activePackage} did not match ${targetPackage}`);
    }
    const manifest = {
      tool: "android_assert_ui",
      runDir,
      relativeRunDir: relArtifact(runDir),
      pass: failures.length === 0,
      failures,
      screenshot,
      uiDump: {
        mode: uiDump.mode,
        activePackage: uiDump.activePackage,
        nodeCount: uiDump.nodeCount,
        artifact: relArtifact(path.join(runDir, "ui-dump.json")),
      },
    };
    await writeJsonArtifact(path.join(runDir, "manifest.json"), manifest);
    return textResult(manifest);
  },
);

server.registerTool(
  "android_handle_permission_dialog",
  {
    title: "Handle Android Permission Dialog",
    description: "Tap a common Android permission-dialog decision button found in the current UI dump.",
    inputSchema: {
      decision: z.enum(["allow", "deny", "while_in_use", "only_this_time"]).default("allow"),
      serial: z.string().optional(),
    },
  },
  async ({ decision, serial }) => {
    const dump = await getUiDump(serial);
    if (!Array.isArray(dump.nodes)) throw new Error("parsed phone-agent UI dump is required for permission handling");
    const patterns = permissionDecisionPatterns(decision);
    const matches = dump.nodes.filter((node) =>
      validBounds(node.bounds) && patterns.some((pattern) => pattern.test(String(node.text || node.contentDescription || ""))),
    );
    if (matches.length === 0) throw new Error(`no permission dialog button matched decision: ${decision}`);
    const tap = await tapNode(matches[0], undefined, serial);
    return textResult({ decision, activePackage: dump.activePackage, match: summarizeNode(matches[0]), tap });
  },
);

server.registerTool(
  "android_swipe",
  {
    title: "Swipe Android Screen",
    description: "Swipe between screen coordinates.",
    inputSchema: {
      x1: z.number(),
      y1: z.number(),
      x2: z.number(),
      y2: z.number(),
      durationMs: z.number().default(300),
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ x1, y1, x2, y2, durationMs, appId, packageName, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    return textResult(
      await phoneOrAdb("swipe", { x1, y1, x2, y2, durationMs, packageName: targetPackage }, async () => {
        const useSerial = await chooseAdbSerial(serial);
        await runAdb(
          ["shell", "input", "swipe", String(x1), String(y1), String(x2), String(y2), String(durationMs)],
          { serial: useSerial },
        );
        return { mode: "adb", serial: useSerial, ok: true };
      }),
    );
  },
);

server.registerTool(
  "android_long_tap",
  {
    title: "Long Tap Android Screen",
    description: "Long-press screen coordinates.",
    inputSchema: {
      x: z.number(),
      y: z.number(),
      durationMs: z.number().default(750),
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ x, y, durationMs, appId, packageName, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    return textResult(
      await phoneOrAdb("longTap", { x, y, durationMs, packageName: targetPackage }, async () => {
        const useSerial = await chooseAdbSerial(serial);
        await runAdb(
          [
            "shell",
            "input",
            "swipe",
            String(Math.round(x)),
            String(Math.round(y)),
            String(Math.round(x)),
            String(Math.round(y)),
            String(Math.min(5000, Math.max(500, Math.round(durationMs)))),
          ],
          { serial: useSerial },
        );
        return { mode: "adb", serial: useSerial, ok: true };
      }),
    );
  },
);

server.registerTool(
  "android_type_text",
  {
    title: "Type Android Text",
    description: "Set focused text field content through the phone agent; adb fallback is ASCII-oriented.",
    inputSchema: {
      text: z.string(),
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ text, appId, packageName, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    return textResult(
      await phoneOrAdb("typeText", { text, packageName: targetPackage }, async () => {
        const useSerial = await chooseAdbSerial(serial);
        const escaped = text.replace(/%/g, "%25").replace(/\s/g, "%s");
        await runAdb(["shell", "input", "text", escaped], { serial: useSerial });
        return { mode: "adb", serial: useSerial, ok: true };
      }),
    );
  },
);

server.registerTool(
  "android_back",
  {
    title: "Android Back",
    description: "Press Android back.",
    inputSchema: {
      appId: z.string().optional(),
      packageName: z.string().optional(),
      serial: z.string().optional(),
    },
  },
  async ({ appId, packageName, serial }) => {
    const targetPackage = await packageNameFor(appId, packageName);
    return textResult(
      await phoneOrAdb("back", { packageName: targetPackage }, async () => {
        const useSerial = await chooseAdbSerial(serial);
        await runAdb(["shell", "input", "keyevent", "BACK"], { serial: useSerial });
        return { mode: "adb", serial: useSerial, ok: true };
      }),
    );
  },
);

server.registerTool(
  "android_open_uri",
  {
    title: "Open URI On Android",
    description: "Open a URI. Requires whole-device enablement unless handled by app scope.",
    inputSchema: {
      uri: z.string(),
    },
  },
  async ({ uri }) => {
    requireWholeDeviceTool("android_open_uri");
    return textResult(await phone.command("openUri", { uri }));
  },
);

server.registerTool(
  "android_home",
  {
    title: "Android Home",
    description: "Press Android home. Requires whole-device enablement.",
  },
  async () => {
    requireWholeDeviceTool("android_home");
    return textResult(await phone.command("home", {}));
  },
);

server.registerTool(
  "android_recents",
  {
    title: "Android Recents",
    description: "Open Android recents. Requires whole-device enablement.",
  },
  async () => {
    requireWholeDeviceTool("android_recents");
    return textResult(await phone.command("recents", {}));
  },
);

server.registerTool(
  "android_open_settings",
  {
    title: "Open Android Settings",
    description: "Open Android settings. Requires whole-device enablement.",
  },
  async () => {
    requireWholeDeviceTool("android_open_settings");
    return textResult(await phone.command("openSettings", {}));
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
