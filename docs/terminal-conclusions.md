# Listen to terminal conclusions and review reported completion

Each configured terminal notification now offers **Listen** when its pane has
settled. Android reads recent text with an installed offline voice. A separate
reading notification has **Earlier**, **Replay**, and **Stop**; these work while
DevOTA is backgrounded. Only one window speaks at a time. Earlier moves the
starting point backward and rereads from there, fetching older history in small
increments when needed. It does not change the selected tmux window or scroll
the interactive terminal.

The reader strips terminal color/control escapes, box borders, standalone
prompts and common status hints. Speech also simplifies Markdown and announces
omitted fenced code. It preserves failures and negation. Cleanup is conservative:
arbitrary terminal programs can still include unrecognized UI text. The initial
snapshot is 120 history lines plus the screen, starting near the end at a
sentence/chunk boundary. Earlier can extend to 800 history lines; snapshots are
capped at 24,000 characters. It never requests unlimited scrollback. New output,
disconnect, running that pane's macro, Stop, audio-focus loss, or unplugging an
audio route cancels reading. There is no automatic aloud playback.

## Per-window model verdicts

**Terminal → SSH settings → Notification macros → Check conclusions with the
home model** enables automatic assessment once a pane settles (on by default).
Each pane independently shows one of:

- **✓ Reported success** — its latest conclusion reports the required work
  complete with successful checks.
- **⚠ Needs attention** — it reports failed, blocked, unverified, or unfinished
  required work, or needs user action.
- **? Outcome unknown** — the conclusion/context is ambiguous or still working.
- **↻ Check retry 2/3 (or 3/3) pending** — the checker failed, timed out, or
  returned an invalid assessment. This is not a failure verdict about the work.
- **⚠ Check unavailable after 3 attempts** — the retry budget is exhausted;
  the outcome remains unknown. Listen or inspect the conclusion when convenient.

**Macro sent** only means all macro steps were delivered without a transport
error; it does not establish application acceptance or successful work.
**Working · output changing** is the active-output status. It replaces the
confusing submission-unconfirmed warning while output is changing; Enter
recovery still remains available after the pane settles. **Macro sent · waiting
for output** is used if nothing has changed since submission. **Quiet · outcome
unknown** means activity stopped without a completion verdict. **Checking
outcome** means a review request is in flight. Only
**✓ Reported success** is a positive assessment of the agent's final report.

The label includes a short reason. These are assessments of an agent's *report*,
not independent verification of its work. They do not automatically run macros,
and one window needing attention does not block the other windows. The human
still chooses which macro to run. No agent-specific logs/hooks or account
credentials are required; excerpts from Claude Code, Codex and other terminal
programs use the same classification path.

The reviewer serializes requests across windows. A temporary checker/transport
failure or invalid response gets at most three attempts per stable revision,
with 30 seconds before the second attempt and 90 before the third (measured
from the preceding failure). Waiting panes do not block checks for other panes.
A valid but ambiguous assessment is not retried repeatedly. These retries only
read/review text: they never resend macros or Enter. New output starts a fresh
review budget, and late results for older output are discarded. Any new output
invalidates an old verdict. A newly submitted macro cannot reuse an unchanged
old conclusion. Busy/disconnected states continue to disable macro controls.
There is no guarantee of identifying the last complete message from an
arbitrary terminal tail, so uncertain is a normal outcome.

## Reusing the home model

DevOTA runs `python3 dev-ota/server/terminal_review.py` through the existing
authenticated SSH connection. That relative path assumes the DevOTA checkout
is under the SSH user's home directory. The helper reads bounded JSON on stdin
(terminal text is not embedded in process arguments), then calls the existing
Whisper Notes `/v1/chat` service on **trusted loopback port 8095** using its
authenticated encrypted envelope. It reuses the existing Gemma model and GPU
lock; it does not load another copy or change Whisper Notes.

The host needs Python `cryptography`, the running Whisper Notes service, and
read access to its existing token at `~/whisper-notes/.secrets/api-token` (or
`DEVOTA_REVIEW_TOKEN_FILE`). The token never goes to the phone or into the
model prompt. No new public model endpoint is added. Hosts without this setup
show Check unavailable; Listen continues to work independently. Update this
host helper with the app: its optional `retryable` field distinguishes service
or validation failures from a valid uncertain assessment, without exposing
exception details or transcripts.

The helper accepts at most 10,000 characters of cleaned recent text and sends
at most its last 4,000 characters to the small shared model, removing an initial
partial line when possible. It numbers literal source lines, splitting long
lines into substrings of at most 240 characters. The model selects an integer
`evidence_line` instead of copying prose; the helper resolves that line into an
exact source quote for the phone. This avoids rejecting a valid assessment
because the model paraphrased or copied an oversized quote. No fuzzy matching
or fabricated evidence is accepted. Missing/out-of-range references fail closed.
The prompt treats terminal content as untrusted data. Responses must be small
structured JSON. The helper also accepts the observed exact two-line form
`status: reason` followed by `evidence_line: integer`, with a full-string match
and the same schema, bounds, and source-evidence validation. Extra surrounding
prose is rejected. Invalid replies never become success and receive bounded retries.
Busy, timeout, incomplete-output, authentication and context-limit failures get
specific safe messages; authentication/context-limit failures are not retried
unchanged. No credentials or raw exception details appear in those messages.

For counted tasks, the prompt requires full accounting of the requested total
for every required stage. Partial completion or approval (19/20, 5/6, 8/10),
skipped required items, or success over only an attempted subset means Needs
attention. Missing totals or required-stage results mean Uncertain, not success.
Explicit prose such as “all 20 completed and approved” is accepted; unrelated
test counts cannot stand in for task totals. Superseded progress counts do not
override a fully completed final result. Non-counted tasks need no invented
totals. These are model instructions, not deterministic arithmetic validation;
the reviewer still judges only the bounded excerpt, not the actual work.

Count-prompt verification (2026-09-21): **9 reviewer unit tests** and **16
synthetic local-model checks** passed. The first model run classified omitted
totals as Needs attention rather than Uncertain; explicit omission examples
were added, then all 16 checks passed. No live agent sessions were used. This
is a host-helper-only change: subsequent reviews use it without an APK update;
already cached verdicts are not reclassified automatically by this change.
Quote validation cannot establish
that the model interpreted context correctly. No transcripts, model replies,
or exception details are logged by this helper, and no durable review cache is
written. Plaintext necessarily exists in process/model memory during use.

## Verification

Measured on 2026-09-21: all 93 Flutter tests and 3 reviewer unit tests passed;
the emulator passed both the reader controls and three-window Vim macro/Enter
recovery suites. Five synthetic home-model cases passed in one run. A later
rerun passed the first three cases before the service became unavailable;
service availability is not guaranteed, and that path remains Uncertain.

- Flutter tests exercise cleanup without dropping negation, moving Earlier,
  invalid model replies, stale results, unchanged old conclusions after a new
  submission, and independent good/bad windows.
- `python3 -m unittest discover -s server -p test_terminal_review.py` tests
  verdict validation and bounded input handling.
- `python3 scripts/test/terminal-review-smoke.py` uses 16 short synthetic
  messages against the existing home model: success, failure, working, a new
  prompt following an old success, and an injected instruction to report a
  false success, plus full/partial counts, missing totals/approval, attempted
  subsets, superseded progress, and test counts versus task totals. No agents
  are launched.
- The isolated Vim/Android fixture from `terminal-notification-controls.md`
  supports `python3 scripts/test/terminal-notification-ui.py reader --output
  /tmp/devota-terminal-reader-evidence`. It generates synthetic terminal prose,
  checks actual Android TTS onStart callbacks via the playback notification,
  exercises Earlier/Replay/Stop, and verifies DevOTA stays backgrounded.

An emulator callback proves the speech engine began playback; it does not
establish subjective voice quality or Bluetooth/call behavior on a physical
phone. Physical-phone installation and those audio-route checks remain separate.

The deterministic outcome-notification fixture uses
`test_support/terminal_review_demo.dart` with package override
`DEVOTA_APPLICATION_ID=io.github.chasekolozsy.devota.terminaltest`. Build/install
on the same emulator profile and grant notification permission, then launch
it and run `python3 scripts/test/terminal-notification-ui.py review`. It injects
one checker failure and then a valid success, alongside needs-attention and
ambiguous windows, and verifies all three labels and exactly 2/1/1 review calls.
No SSH, coding agents, terminal input, or real model calls are used in this
fixture; it proves controller/native notification behavior, not model accuracy.

### Retry/status follow-up — 2026-09-21

- Flutter: **123 tests passed**, analysis: **no issues**. Reviewer Python tests:
  **5 passed**; build-version tests: **5 passed**. Coverage includes retry
  backoff/exhaustion, late retry rejection after new output, valid ambiguity
  without repeated checks, and independent progress across windows.
- Android 36 notification fixture passed: the first pane displayed a pending
  retry, recovered to Reported success while backgrounded, and the other panes
  independently displayed Needs attention and Outcome unknown. Exact checker
  calls were **2, 1, 1**. Evidence: `/tmp/devota-outcome-retry-verified`.
  The initial UI-driver attempt collapsed an already-expanded summary and hid
  its third row; the corrected driver preserves expansion and the rerun passed.
- Production ARM64 **2026094108** staged; package/version and checksum verified,
  and the served `/builds` listing checked. The host helper is updated too.
- The existing home model remains an external dependency: this fixture does
  not prove continuous availability or accuracy on every real transcript.
  No live terminal macro or coding agent was run during this verification.

### Real completion parsing and slow preflight — 2026-09-21

- Read-only checks reproduced two evidence failures on finished terminal work:
  a nonmatching copied quote, and an exact quote of **1,064 characters** rejected
  by the 300-character limit. A later model response used two-line fields instead
  of JSON. Numbered literal source lines and strict two-line parsing address
  those observed format failures without relaxing source-evidence validation.
- The updated helper returned **reported_success** for the finished window
  corresponding to the user's screenshot (authoring window 1 / notification
  window 2), with exact source evidence, in **1.9 seconds**. The finished reverse
  batch window also returned reported_success with exact source evidence.
- **124 Flutter tests passed**, analysis: **no issues**; **9 reviewer unit tests
  passed**. A regression verifies that an identical preflight capture delayed
  20 seconds can execute a manually requested macro despite an unavailable
  reviewer. Changed preflight content still blocks input and reports Not sent.
- Android 36, real Windows CMD → WSL: three isolated Vim notification macros,
  intentionally dropped Enter and pane-specific recovery, no duplicate input,
  and disconnect action removal all passed. Evidence:
  `/tmp/devota-checker-preflight-evidence`.
- Production ARM64 **2026094110** staged. The screenshot establishes finished
  work, but the exact cause of the user's missed tap is not independently proven;
  future stale/preflight rejections now report a visible reason. No live macro
  was run during debugging. Reconnect SSH after updating to reset exhausted
  reviews; running the macro again is not required to reassess existing output.
