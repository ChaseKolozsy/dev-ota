const RECORDABLE_ACTIONS = new Set([
  "launchApp",
  "launchIntent",
  "tap",
  "tapImage",
  "tapUi",
  "longTap",
  "swipe",
  "typeText",
  "back",
  "home",
  "recents",
  "openSettings",
  "openUri",
]);

const OBSERVATION_ACTIONS = new Set(["screenshot", "uiDump", "status"]);

export function compileMacroRecording(recording, options = {}) {
  const omitted = new Set((options.omitEntryIndexes || []).map(Number));
  const entries = Array.isArray(recording?.entries) ? recording.entries : [];
  const steps = [];
  const dropped = [];
  const warnings = [];
  let placeholderIndex = 0;

  for (const [offset, entry] of entries.entries()) {
    const entryIndex = Number(entry?.index || offset + 1);
    if (omitted.has(entryIndex)) {
      dropped.push({ index: entryIndex, reason: "operator_pruned" });
      continue;
    }
    if (entry?.ok !== true) {
      dropped.push({ index: entryIndex, reason: "failed_exploration_attempt" });
      continue;
    }
    const action = String(entry?.macroAction || entry?.action || "");
    if (OBSERVATION_ACTIONS.has(action)) {
      dropped.push({ index: entryIndex, reason: "observation_only" });
      continue;
    }
    if (!RECORDABLE_ACTIONS.has(action)) {
      dropped.push({ index: entryIndex, reason: `unsupported_action:${action}` });
      continue;
    }

    const args = structuredClone(entry?.macroArgs || entry?.args || {});
    if (action === "typeText" && typeof args.text === "string" && args.text.startsWith("${INPUT_")) {
      placeholderIndex += 1;
      args.text = `\${INPUT_${placeholderIndex}}`;
      warnings.push({
        index: entryIndex,
        code: "typed_text_placeholder",
        message: `Replace ${args.text} with a non-secret test value before publishing.`,
      });
    }
    if (action === "tap" || action === "longTap" || action === "swipe") {
      warnings.push({
        index: entryIndex,
        code: "coordinate_action",
        message: "Replace recorded coordinates with a stable tapUi selector when possible.",
      });
    }

    const expect = {};
    const activePackage = entry?.after?.activePackage;
    if (typeof activePackage === "string" && activePackage) {
      expect.activePackage = activePackage;
    }
    const label = String(entry?.label || humanizeAction(action));
    const spec = {
      action,
      args,
      ...(Object.keys(expect).length ? { expect } : {}),
      capture: true,
      label,
    };
    const defaultDelay = action === "launchApp" || action === "launchIntent" ? 1.5 : 0.5;
    const requestedDelay = Number(entry?.settleSeconds);
    const delaySeconds = Number.isFinite(requestedDelay)
      ? Math.max(0, Math.min(30, requestedDelay))
      : defaultDelay;
    steps.push({
      id: `step-recorded-${String(steps.length + 1).padStart(4, "0")}`,
      type: "device",
      value: JSON.stringify(spec),
      delaySeconds,
      sourceEntryIndex: entryIndex,
    });
  }

  return {
    format: "devota-recorded-macro-draft",
    version: 1,
    recordingId: recording?.id || null,
    name: String(options.name || recording?.name || "Recorded device workflow").trim(),
    priority: Number.isInteger(options.priority) ? options.priority : Number(recording?.priority || 0),
    steps,
    dropped,
    warnings,
    needsReview: warnings.length > 0 || steps.length === 0,
  };
}

export function sanitizeRecordedArgs(action, args, redactTypedText = true) {
  const copy = sanitizeObject(args || {});
  if (action === "typeText" && redactTypedText && typeof copy.text === "string") {
    copy.text = "${INPUT_REDACTED}";
  }
  return copy;
}

function sanitizeObject(value, key = "") {
  if (Array.isArray(value)) return value.map((item) => sanitizeObject(item));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([childKey, childValue]) => [childKey, sanitizeObject(childValue, childKey)]),
    );
  }
  if (/token|password|secret|private.?key|claim.?code/i.test(key)) return "[REDACTED]";
  return value;
}

function humanizeAction(action) {
  return action.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (value) => value.toUpperCase());
}
