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
- **? Uncertain** — the conclusion/context is ambiguous, still working, or the
  local model is unavailable/busy.

The label includes a short reason. These are assessments of an agent's *report*,
not independent verification of its work. They do not automatically run macros,
and one window needing attention does not block the other windows. The human
still chooses which macro to run. No agent-specific logs/hooks or account
credentials are required; excerpts from Claude Code, Codex and other terminal
programs use the same classification path.

The reviewer makes one bounded request per stable content revision, serializes
requests across windows, and does not retry every polling tick. Any new output
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
show Uncertain; Listen continues to work independently.

Model inputs are at most 10,000 characters of cleaned recent text. The prompt
treats terminal content as untrusted data. Responses must be small structured
JSON; positive/negative verdicts require an exact supporting quote present in
the input. Invalid replies become Uncertain. Quote validation cannot establish
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
- `python3 scripts/test/terminal-review-smoke.py` uses five short synthetic
  messages against the existing home model: success, failure, working, a new
  prompt following an old success, and an injected instruction to report a
  false success. No agents are launched.
- The isolated Vim/Android fixture from `terminal-notification-controls.md`
  supports `python3 scripts/test/terminal-notification-ui.py reader --output
  /tmp/devota-terminal-reader-evidence`. It generates synthetic terminal prose,
  checks actual Android TTS onStart callbacks via the playback notification,
  exercises Earlier/Replay/Stop, and verifies DevOTA stays backgrounded.

An emulator callback proves the speech engine began playback; it does not
establish subjective voice quality or Bluetooth/call behavior on a physical
phone. Physical-phone installation and those audio-route checks remain separate.
