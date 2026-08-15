import test from "node:test";
import assert from "node:assert/strict";

import { compileMacroRecording, sanitizeRecordedArgs } from "../src/macro_recording.js";

test("compiler prunes failed exploration and keeps semantic selectors", () => {
  const result = compileMacroRecording({
    id: "recording-proof",
    name: "Purchase proof",
    priority: 900,
    entries: [
      { index: 1, action: "tap", args: { x: 10, y: 20 }, ok: false },
      { index: 2, action: "uiDump", args: {}, ok: true },
      {
        index: 3,
        action: "tap",
        macroAction: "tapUi",
        macroArgs: { selector: { text: "Redeem now" } },
        after: { activePackage: "io.github.chasekolozsy.cradlespeak" },
        ok: true,
      },
    ],
  });

  assert.equal(result.steps.length, 1);
  assert.equal(JSON.parse(result.steps[0].value).action, "tapUi");
  assert.equal(JSON.parse(result.steps[0].value).args.selector.text, "Redeem now");
  assert.deepEqual(result.dropped.map((item) => item.reason), [
    "failed_exploration_attempt",
    "observation_only",
  ]);
  assert.equal(result.needsReview, false);
});

test("compiler supports explicit pruning and blocks secret or coordinate drafts", () => {
  const result = compileMacroRecording(
    {
      id: "recording-prune",
      entries: [
        { index: 1, action: "tap", args: { x: 50, y: 60 }, ok: true },
        {
          index: 2,
          action: "typeText",
          args: { text: "${INPUT_REDACTED}" },
          ok: true,
        },
        { index: 3, action: "back", args: {}, ok: true },
      ],
    },
    { omitEntryIndexes: [1] },
  );

  assert.equal(result.steps.length, 2);
  assert.equal(result.dropped[0].reason, "operator_pruned");
  assert.equal(JSON.parse(result.steps[0].value).args.text, "${INPUT_1}");
  assert.equal(result.needsReview, true);
  assert.equal(result.warnings[0].code, "typed_text_placeholder");
});

test("argument sanitizer never records bearer-like fields or typed text", () => {
  assert.deepEqual(
    sanitizeRecordedArgs(
      "typeText",
      { text: "buyer@example.test", token: "secret", nested: { claimCode: "ABC" } },
      true,
    ),
    { text: "${INPUT_REDACTED}", token: "[REDACTED]", nested: { claimCode: "[REDACTED]" } },
  );
});

test("compiler keeps visual tap fallbacks without coordinate review", () => {
  const image = {
    format: "devota-image-template",
    version: 1,
    pngBase64: "iVBORw0KGgo=",
    width: 20,
    height: 20,
    sourceWidth: 1080,
    sourceHeight: 2400,
  };
  const result = compileMacroRecording({
    id: "recording-image",
    entries: [
      {
        index: 1,
        action: "tap",
        macroAction: "tapImage",
        macroArgs: { template: image },
        ok: true,
      },
      {
        index: 2,
        action: "tap",
        macroAction: "tapUi",
        macroArgs: { selector: { text: "Install" }, imageFallback: image },
        ok: true,
      },
    ],
  });

  assert.equal(result.steps.length, 2);
  assert.equal(JSON.parse(result.steps[0].value).action, "tapImage");
  assert.equal(JSON.parse(result.steps[1].value).args.imageFallback.sourceWidth, 1080);
  assert.equal(result.needsReview, false);
});
