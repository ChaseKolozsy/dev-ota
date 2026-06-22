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

The `devota_projects_*` tools require `DEVOTA_BUILD_SERVER_URL` because they
use the build server's SQLite-backed project APIs. Email sending also requires
Postmark settings to be saved from the DevOTA Projects tab or via
`POST /projects/email/config`.
