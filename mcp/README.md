# DevOTA MCP Relay

The DevOTA MCP relay lets an LLM client communicate with a paired Android phone
agent. It uses stdio for MCP and a WebSocket listener for the phone.

The phone and computer only need to be mutually reachable. That can be a local
Wi-Fi network, Tailscale, ZeroTier, WireGuard, a hotspot, or any other trusted
network path.

## Run

```bash
cd mcp
npm install
DEVOTA_PAIR_TOKEN='choose-a-token' \
DEVOTA_REPO_ROOT=/path/to/repo-with-devota-yaml \
DEVOTA_BUILD_SERVER_URL=http://<computer-ip>:8082 \
npm start
```

Useful environment variables:

| Variable | Default | Purpose |
|---|---:|---|
| `DEVOTA_WS_PORT` | `8083` | Phone-agent WebSocket port. |
| `DEVOTA_PAIR_TOKEN` | generated at startup | Token the phone must present. |
| `DEVOTA_REPO_ROOT` | repo above this package | Repo containing `devota.yaml` and APK outputs. |
| `DEVOTA_MANIFEST` | `devota.yaml` | Manifest path relative to `DEVOTA_REPO_ROOT`, unless absolute. |
| `DEVOTA_BUILD_SERVER_URL` | unset | Build server URL reachable from the phone. Required for phone-agent installs. |
| `DEVOTA_ENABLE_WHOLE_DEVICE` | `0` | Enables whole-phone MCP tools on the PC side. The phone app must also opt in. |
| `DEVOTA_ENABLE_BUILD_COMMANDS` | `0` | Enables optional manifest build commands. |
| `DEVOTA_ENABLE_PRIVILEGED_MACROS` | `0` | Enables the narrowly allowlisted host-backed `hostCommand` macro action. |
| `DEVOTA_ADB_HOST` | unset | Optional `ip:port` for probing network ADB. |

## Phone Setup

1. Start `server/devota_server.py`.
2. Start this MCP relay.
3. Open DevOTA on the phone.
4. Open the Agent tab.
5. Set `ws://<computer-ip>:8083/phone` and the pair token.
6. Enable the DevOTA accessibility service when control/screenshot tools are needed.
7. Start the agent.

## Tool Groups

- Build/install: `android_list_builds`, `android_build_apk`, `android_install_latest`, `android_rebuild_install_launch`.
- Visual control: `android_tap_ui` prefers semantic accessibility selectors;
  `android_tap_image` explicitly replays a bounded recorded template through
  the phone-local matcher and reports match confidence/bounds without sending
  the current screenshot back through ZeroTier.
- Macros: `devota_macros_list`, `devota_macros_create`,
  `devota_macros_update`, `devota_macros_delete`, `devota_macro_runs_list`,
  `devota_macro_run_get`, `devota_macro_run_collect`, plus
  `devota_macro_recording_start`, `devota_macro_recording_status`,
  `devota_macro_recording_stop`, and `devota_macro_recording_compile`.
  Device-step macros run
  visibly on the phone when pressed in DevOTA and collect one screenshot/UI
  record per step; records queue durably on the phone and retry delivery after
  connectivity returns, then the collect tool downloads the complete evidence
  ZIP.
  `humanCheckpoint` steps show a countdown overlay, then collect timestamped
  frames at the macro's declared `screenshotsPerSecond` while a person tests.
  `localHttpAssert` performs read-only `GET`/`HEAD` assertions against an app's
  loopback API. It rejects non-loopback URLs and mutating methods. Long local
  installs can use bounded `retryUntilSeconds` polling (up to one hour), which
  records attempts and elapsed time rather than relying on a fixed UI timeout.
  `jsonPaths` records selected progress fields, and
  `captureIntervalSeconds` saves periodic screenshot/UI evidence while the
  poll is active (maximum 120 frames).
  `assertDeviceProfile` fails before navigation unless the phone/emulator
  matches the declared model set, Android SDK, screen sides, and density.

  `hostCommand` is disabled unless `DEVOTA_ENABLE_PRIVILEGED_MACROS=1`. Its
  public macro envelope is backend-neutral, while this relay currently uses a
  trusted local ADB executable. The only nested actions are `clearAppData`,
  `grantPermission`, `revokePermission`, `forceStop`, `launchApp`, and
  `installLatest`. Target packages and app IDs must be unique entries in the
  active `devota.yaml`, and DevOTA itself is never a valid target. Permission
  changes allow only `android.permission.POST_NOTIFICATIONS` and
  `android.permission.RECORD_AUDIO`. There is no raw shell field or raw device
  selector. The relay uses the authenticated phone identity from its WebSocket
  hello only to find exactly one connected ADB transport with the same Android
  `android_id`; it does not expose that identity or the ADB serial in results.
  Each accepted result records the nested action and `backend: trusted-adb`
  plus a small allowlisted result payload for macro evidence.

  For an unknown workflow, start a recording, explore with the Android control
  tools, then stop and compile it. Failed actions and observation-only calls
  are excluded automatically; `omitEntryIndexes` prunes additional detours.
  Raw coordinate actions and redacted `${INPUT_n}` values keep the draft in
  `needsReview` and prevent automatic publication. During an active recording,
  Pillow captures a private pre-tap crop: semantic selectors retain it as a
  fallback and coordinate taps compile to the offline `tapImage` action. The
  Android Agent rescales and searches the expected region before tapping, so a
  small layout/density shift recalibrates the click rather than replaying stale
  coordinates. Replace any remaining uncaptured coordinates with stable UI
  selectors or visual templates before publishing the reusable macro.
  The fast path is to record and mature the macro through DevOTA inside a
  profile-matched emulator, then publish and execute that exact macro on the
  corresponding physical phone.
  A macro may declare a bounded top-level `failureDiagnostics` observer. After
  a failed step, normal actions stop while DevOTA continues collecting local
  screenshots, UI trees, and allowlisted loopback status probes into the same
  durable evidence run. This keeps a client timeout from hiding later backend
  progress without ever continuing unsafe mutations after a failure.
- Project board: `devota_projects_board`, `devota_projects_create_client`,
  `devota_projects_create_project`, `devota_projects_create_template`,
  `devota_projects_create_card`, `devota_projects_advance_card`,
  `devota_projects_add_comment`, `devota_projects_send_card_email`,
  `devota_projects_pull_replies`.
- State capture: `android_status`, `android_collect_state`, `android_screenshot`, `android_ui_dump`, `android_logcat_capture`.
- Interaction: `android_tap`, `android_long_tap`, `android_swipe`, `android_type_text`, `android_back`.
- Whole-device navigation: `android_home`, `android_recents`, `android_open_settings`, `android_open_uri`.
- UI workflows: `android_find_ui`, `android_tap_ui`, `android_assert_ui`, `android_handle_permission_dialog`.

Build commands are optional and disabled unless `DEVOTA_ENABLE_BUILD_COMMANDS=1`.
The core DevOTA path is serving and installing APKs that already exist in the
configured repo.

The `devota_macros_*` and `devota_projects_*` tools require
`DEVOTA_BUILD_SERVER_URL` because they use the build server's local APIs. Email
sending also requires Postmark settings to be saved from the DevOTA Projects tab
or via `POST /projects/email/config`.
