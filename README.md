# DevOTA

DevOTA is a local-first Android development tool for serving, installing, and
testing APK builds from a phone. It combines:

- a Flutter Android app for discovering build servers, opening network helper
  apps, browsing OTA builds, saving commands, collecting voice-transcribed
  issues, and pairing an on-phone control agent;
- a small Python build server that serves APKs already produced by your repo
  and stores local project/client board data;
- a Node MCP relay that lets an LLM inspect screenshots/UI trees and drive
  Android gestures through the paired phone agent.
- an embedded SSH terminal for connecting back to your development machine.

DevOTA has no hosted backend and no account system. You run the server and MCP
relay on hardware you control, then pair the phone with an explicit token.
The phone and computer only need a trusted network path between them: local
Wi-Fi, a hotspot, Tailscale, ZeroTier, WireGuard, or another VPN are all just
configuration choices.

The optional project-board email reply flow can use a tiny public Cloudflare
Worker relay for Postmark inbound webhooks. The relay is only a short-lived
queue; the source of truth remains the local build server's SQLite database
under `.devota-cache/`.

## Quick Start

For the lowest-friction first run, set up the computer on the same LAN as the
phone before adding a VPN. DevOTA includes desktop setup scripts and
paste-ready terminal-agent prompts in [docs/setup](docs/setup/README.md).

1. Add a `devota.yaml` manifest to the repo that produces APKs:

```yaml
version: 1
apps:
  - id: my-app
    label: My App
    packageName: com.example.myapp
    buildDirs:
      - app/build/app/outputs/flutter-apk
```

2. Start the build server from this repo:

```bash
python3 -m pip install -r requirements.txt
python3 server/devota_server.py --repo-root /path/to/your/app/repo --host 0.0.0.0 --port 8082
```

3. Build and install the DevOTA Android app:

```bash
scripts/build/devota-public-debug.sh
```

4. Open DevOTA on the phone. Use the Connect tab to scan for a LAN server, or
   add the computer's reachable URL such as `http://<your-computer-ip>:8082`.
   If the computer is remote, use the Connect tab's ZeroTier, Tailscale, or
   WireGuard helper buttons to open or install your preferred network app.

5. Optional: start the MCP relay for LLM-controlled phone testing:

```bash
cd mcp
npm install
DEVOTA_REPO_ROOT=/path/to/your/app/repo \
DEVOTA_BUILD_SERVER_URL=http://<your-computer-ip>:8082 \
DEVOTA_PAIR_TOKEN='choose-a-token' \
npm start
```

Then open DevOTA's Agent tab, enter `ws://<your-computer-ip>:8083/phone`, enter
the same token, enable the accessibility service, and start the agent.

## Desktop Setup Kit

The setup kit is intentionally LAN-first and provider-neutral. Use it to prepare
the desktop for phone SSH, build serving, and optional MCP phone control before
you introduce ZeroTier, Tailscale, WireGuard, or another private network.

- [LAN-first setup guide](docs/setup/README.md)
- [Terminal-agent prompts](docs/setup/agent-prompts.md)
- [Windows prerequisites script](scripts/setup/windows-devota-prereqs.ps1)
- [macOS prerequisites script](scripts/setup/macos-devota-prereqs.sh)
- [Linux prerequisites script](scripts/setup/linux-devota-prereqs.sh)

## Android App Features

- **Connect**: discovers `_devota._tcp.local.` LAN servers and opens or installs
  ZeroTier, Tailscale, or WireGuard without making one provider mandatory.
- **Builds**: groups APKs by app from `devota.yaml`, downloads gzip-compressed
  APKs, opens Android's package installer, and keeps cached APKs for retry.
- **Projects**: local-first client/project Kanban board with phase templates,
  cards, card comments, Postmark email drafts, manual send confirmation, and
  inbound replies imported as card comments.
- **Terminal**: SSH terminal using password or private-key auth, secure
  credential storage, generated phone-owned Ed25519 keys, public-key install
  through the build server, trust-on-first-use host-key verification, a
  lightweight TCP ping, and voice-to-terminal command submission. While a
  session is live the app runs an ongoing notification so Android 12+ cannot
  freeze the process (and drop SSH) when you switch apps; dropped sessions
  reconnect on their own with a backoff and immediately when you return. Turn
  it off under the terminal's SSH settings if you would rather not have the
  notification.
- **Files**: download files an agent has staged on the build server (in the
  file-transfer directory, or via `POST /files/upload`) straight into the
  phone's public Downloads folder for re-upload elsewhere. Staged **folders**
  (and `.zip` files) are unpacked by the app into a real nested
  `Downloads/<folder>/` tree, so Android never flattens them into loose files.
- **Backup**: export/import saved servers, commands, issues, agent settings,
  OpenAI API keys, and SSH public/private keys.
- **Issues**: voice-transcribed notes that can be added to a numbered issue
  list, copied locally, or pushed to the PC clipboard endpoint.
- **Commands** and **Agent**: saved command snippets and the Android MCP phone
  control agent.

### Device integration-test macros

Macros may contain terminal steps or allowlisted **Device action** JSON steps.
Device macros execute locally through DevOTA's accessibility service, so a
person pressing **Run** sees the phone launch apps, tap controls, type, swipe,
or navigate in real time. Each action can assert the active package and visible
text. DevOTA captures a PNG screenshot and accessibility UI tree after every
step, including a failed step. Evidence is first committed to an app-private
on-phone outbox; delivery to the paired build server retries after reconnect or
app resume. A slow or missing VPN path therefore does not turn successful local
execution into a failed test.

Agents create the same macros through `devota_macros_create`; there is no
separate hidden automation format. A device step value looks like:

```json
{"action":"launchApp","args":{"packageName":"io.github.chasekolozsy.cradlespeak"},"expect":{"activePackage":"io.github.chasekolozsy.cradlespeak"},"capture":true}
```

Supported actions are `launchApp`, `launchIntent`, `tap`, `tapImage`, `longTap`, `swipe`,
`typeText`, `back`, `home`, `recents`, `openSettings`, `openUri`, `tapUi`,
`assertUi`, `assertDeviceProfile`, `localHttpAssert`, `installBuild`,
`humanCheckpoint`, `screenshot`, and `uiDump`. Device macros may also contain Wait steps. Whole-device actions
require both the accessibility service and DevOTA's explicit whole-device
control toggle.

`localHttpAssert` is a read-only product-state oracle for apps such as
Cradlespeak that expose an embedded loopback API. It permits only `GET` or
`HEAD` to `127.0.0.1`, `localhost`, or `::1`, and can assert an HTTP status,
selected JSON paths, and body inclusions/exclusions. DevOTA records only the
requested observations rather than the complete response body:

```json
{"action":"localHttpAssert","args":{"url":"http://127.0.0.1:8002/license?lang=en","method":"GET","expectedStatus":200,"jsonPathEquals":{"licensed":false}}}
```

Long local work such as pack installation can be polled without turning the
macro into a timing guess. `retryUntilSeconds` bounds the whole poll (maximum
3600 seconds), while `timeoutSeconds` bounds each GET/HEAD attempt and
`retryIntervalSeconds` controls the interval. Evidence records attempt and
elapsed counts without retaining the response body:

```json
{"action":"localHttpAssert","args":{"url":"http://127.0.0.1:8002/packs/presence?sku=hu-v2&version=2.1.0","expectedStatus":200,"jsonPathEquals":{"presence":"installed"},"retryUntilSeconds":1800,"retryIntervalSeconds":2}}
```

Add `jsonPaths` to retain non-secret progress fields and
`captureIntervalSeconds` (2–300 seconds, at most 120 frames) to collect
screenshots and UI trees throughout the poll. Expectations such as
`textExcludes:["TimeoutException"]` are checked on every captured frame, not
only after installation finishes.

A device macro can also declare a top-level `failureDiagnostics` tail. Normal
mutating steps stop on the first unexpected failure, but DevOTA remains
connected and performs only bounded read-only observation: screenshots, UI
trees, and optional loopback HTTP probes. Frames enter the same durable
evidence outbox. This is useful when an app reports a client timeout while an
embedded installer may still be working:

```json
{"failureDiagnostics":{"durationSeconds":1800,"intervalSeconds":60,"captureScreenshot":true,"captureUi":true,"probes":[{"url":"http://127.0.0.1:8002/market-client/install-status?sku=hu-v2","expectedStatus":200,"timeoutSeconds":10,"jsonPaths":["phase","bytes_done","bytes_total","updated_at","error"]}]}}
```

Diagnostics last at most one hour, use intervals of 2–300 seconds, collect at
most 120 frames, allow at most eight read-only loopback probes, and never
resume later mutating steps. The original failure remains the run result even
if diagnostic collection itself encounters an error.

Start hardware-specific suites with `assertDeviceProfile`. The profile names a
target and checks real properties before any navigation occurs. One profile may
allow both the physical model and a deliberately tuned emulator model while
requiring the same Android SDK, short/long screen sides, and density:

```json
{"action":"assertDeviceProfile","args":{"profile":"revvl7pro-android36-1080x2436","models":["TMRV07P5G","sdk_gphone64_x86_64"],"androidSdk":36,"shortSidePx":1080,"longSidePx":2436,"densityDpi":480}}
```

### Record exploration, then prune it into a macro

When a workflow has to be discovered interactively, start
`devota_macro_recording_start` before using the Android control tools. Stop it
with `devota_macro_recording_stop`, passing any trial-and-error entry indexes
in `omitEntryIndexes`. The compiler keeps successful actions, drops failed
attempts and observation-only screenshots/UI dumps, and prefers semantic
`tapUi` selectors over their resolved screen coordinates.

While recording, DevOTA uses Pillow on the workstation to save a private
pre-tap screenshot plus a bounded PNG crop around every tap. Semantic `tapUi`
steps carry that crop as an `imageFallback`; raw exploratory taps compile to
`tapImage`. On replay the Android Agent rescales the crop, searches near its
normalized expected region, and recalculates the click from the visual match
and recorded click offset. It refuses low-confidence matches instead of
guessing. Matching and tapping run locally on the phone, so Python and a live
ZeroTier connection are not required during macro execution.

Recordings are durable private JSON artifacts. Typed values and secret-like
fields are redacted. A draft containing a coordinate action or an
`${INPUT_n}` placeholder is marked `needsReview` and cannot be auto-published;
replace those with stable selectors and non-secret test fixtures, then
recompile with `devota_macro_recording_compile`. This makes exploratory work a
source artifact for a reusable test without preserving its dead ends.

Prefer authoring and maturing the workflow in DevOTA running inside a matching
emulator. Publish that pruned macro to the shared build server, then run the
identical macro on the physical phone as the hardware/network acceptance gate.
The emulator is allowed to replace the physical model name only when the macro
still passes the declared device-profile geometry, Android, and density checks.

Use `humanCheckpoint` when timing, animation, audio, or game feel needs a real
person. DevOTA overlays the instructions and countdown above the prepared app,
then removes the overlay and captures the declared cadence while the person
interacts. Frames are captured and timestamped locally before entering the
durable upload outbox, so ZeroTier latency does not alter the requested
schedule:

```json
{"action":"humanCheckpoint","args":{"title":"Prime Mentality check","instructions":"Play briefly and confirm the emoji pacing feels fair.","countdownSeconds":10,"durationSeconds":15,"screenshotsPerSecond":2},"expect":{"activePackage":"io.github.chasekolozsy.cradlespeak"}}
```

Duration is limited to 120 seconds, rate to 0.1–5 screenshots per second, and
each checkpoint to 120 frames. Evidence records every actual capture timestamp.
This local-first behavior is intentional for phones operating far from the
build server—including mobile use in the Philippines, where the phone may move
between good signal, a congested link, and a dead zone during one macro run.

## GitHub Builds

The `Android` GitHub Actions workflow builds two public APK artifacts:

- `devota-universal-release.apk`: sideload-friendly **release** universal APK
  (`io.github.chasekolozsy.devota`, all ABIs, `debuggable=false`,
  zipaligned + v1/v2/v3 signed). Use this for browser/direct sideload
  from the Actions artifact or a GitHub Release.
- `devota-arm64-debug.apk`: public ARM64 debug APK for local OTA iteration
  via the DevOTA Builds tab.

Both are staged to `app/dist/public` by the scripts in `scripts/build/`:

- `scripts/build/devota-public-release.sh` — `flutter build apk --release`
  (universal, release signing via `app/android/app/build.gradle.kts`
  `signingConfigs.release`; defaults to the committed
  `app/keystores/dev.keystore` but honours `keystore.properties` or
  `DEVOTA_KEYSTORE_*`/`ANDROID_KEYSTORE_*` env vars for private signing)
- `scripts/build/devota-public-debug.sh` — `flutter build apk --debug --split-per-abi --target-platform android-arm64`

The default `devota.yaml` serves everything staged in `app/dist/public`.

The Builds tab can ask the build server to dispatch this workflow through the
server's authenticated `gh` CLI, list recent runs, and download the configured
artifact into `.devota-cache/github-artifacts/` so it appears with the served
APKs.

## Manifest

`devota.yaml` must contain one or more apps. Each app has:

- `id`: stable machine-readable ID used by MCP tools and URLs.
- `root`: optional named root from top-level `roots`, or a path. Defaults to
  the manifest repo root.
- `label`: display label in the Android app.
- `packageName`: Android package for launch/logcat/app-scoped controls.
- `buildDirs`: APK output directories relative to that app's root.
- optional `build`: MCP-only build command metadata for local workflows.

Top-level `roots` may define any number of named filesystem roots:

```yaml
roots:
  cradlespeak: /home/chase/Cradlespeak
  devota: /home/chase/dev-ota
apps:
  - id: cradlespeak
    root: cradlespeak
    buildDirs: [app/build/app/outputs/flutter-apk]
  - id: devota
    root: devota
    buildDirs: [app/dist/public]
```

The server resolves downloads through virtual paths such as
`apps/devota/app/dist/public/devota-arm64-debug.apk` and prevents each app from
escaping its configured root. It does not build apps.

## HTTP API

- `GET /health`
- `GET /apps`
- `GET /builds`
- `GET /builds?app=<id>`
- `GET /latest?app=<id>`
- `GET/POST /macros`
- `POST /macros/sync`
- `PATCH/DELETE /macros/<id>`
- `GET /macro-runs` and `GET /macro-runs/<id>` — run/evidence manifests
- `POST /macro-runs/<id>/steps` and `/complete` — phone evidence ingestion
- `GET /macro-runs/<id>/archive` — one ZIP with gallery, UI records, and screenshots
- `GET /github/workflow/runs?repo=<owner/name>&workflow=<file>`
- `GET /download/<virtual-apk-path>`
- `GET /files` — list files and folders staged for the phone, plus the absolute drop directory
- `GET /files/download/<name>`
- `GET /files/archive/<name>` — zip of a staged folder (entries rooted at `<name>/`)
- `POST /files/upload` — multipart `file=@…`, or a raw body with `?name=` / `X-Devota-Filename`
- `DELETE /files/<name>` — remove a staged file or folder
- `POST /github/workflow/run`
- `POST /github/workflow/download`
- `POST /clipboard`
- `POST /ssh/authorized-key`
- `GET /projects/board`
- `GET/POST /projects/clients`
- `GET/POST /projects/projects`
- `GET/POST /projects/phases`
- `GET/POST /projects/cards`
- `GET/POST /projects/templates`
- `GET/POST /projects/cards/<id>/comments`
- `PATCH /projects/clients/<id>`
- `PATCH /projects/projects/<id>`
- `PATCH /projects/phases/<id>`
- `PATCH /projects/cards/<id>`
- `GET/POST /projects/email/config`
- `POST /projects/cards/<id>/email/preview`
- `POST /projects/cards/<id>/email/send`
- `POST /projects/mail/import`
- `POST /projects/mail/pull`

Downloads are gzip-compressed and cached under `.devota-cache/`.

Terminal file attachments are stored outside the served repository under
`~/.devota-cache/terminal-uploads/` by default. Set `DEVOTA_CACHE_DIR` to point
at a different user-level cache directory.

Project-board data is stored in `.devota-cache/projects/devota-projects.sqlite3`.
Postmark credentials and relay settings are stored in
`.devota-cache/projects/email-config.json`, which is intentionally ignored by
git. To receive client replies, deploy `workers/postmark-relay.js` with a KV
binding named `DEVOTA_MAIL_EVENTS` and a secret named `DEVOTA_RELAY_TOKEN`, set
Postmark's inbound webhook URL to `/postmark/inbound`, and set DevOTA's relay
pull URL to `/events`.

`POST /ssh/authorized-key` accepts a text public key or JSON such as
`{"publicKey":"ssh-ed25519 ...","target":"auto"}`. In WSL, `auto` targets the
Windows administrator OpenSSH key file when the Windows account is an
administrator, requesting UAC elevation if needed. After approving the Windows
prompt, return to DevOTA and tap Connect again to verify key-based SSH works.
Otherwise it uses the Windows user's `authorized_keys`. Outside WSL, it targets
the server user's `~/.ssh/authorized_keys`.

## License

Apache-2.0.
