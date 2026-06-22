# DevOTA

DevOTA is a local-first Android development tool for serving, installing, and
testing APK builds from a phone. It combines:

- a Flutter Android app for browsing OTA builds, saving commands, and pairing an
  on-phone control agent;
- a small Python build server that serves APKs already produced by your repo;
- a Node MCP relay that lets an LLM inspect screenshots/UI trees and drive
  Android gestures through the paired phone agent.

DevOTA has no hosted backend and no account system. You run the server and MCP
relay on hardware you control, then pair the phone with an explicit token.
The phone and computer only need a trusted network path between them: local
Wi-Fi, a hotspot, Tailscale, ZeroTier, WireGuard, or another VPN are all just
configuration choices.

## Quick Start

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
cd app
flutter build apk --debug
```

4. Open DevOTA on the phone, add the computer's reachable URL such as
   `http://<your-computer-ip>:8082`, refresh, expand an app, and install a
   build.

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

## Manifest

`devota.yaml` must contain one or more apps. Each app has:

- `id`: stable machine-readable ID used by MCP tools and URLs.
- `label`: display label in the Android app.
- `packageName`: Android package for launch/logcat/app-scoped controls.
- `buildDirs`: APK output directories relative to the repo root served by the
  Python server.
- optional `build`: MCP-only build command metadata for local workflows.

The server only serves APKs inside `--repo-root`. It does not build apps.

## HTTP API

- `GET /health`
- `GET /apps`
- `GET /builds`
- `GET /builds?app=<id>`
- `GET /latest?app=<id>`
- `GET /download/<relative-apk-path>`
- `POST /clipboard`

Downloads are gzip-compressed and cached under `.devota-cache/`.

## Roadmap

SSH/terminal support is planned as the next major feature. The intended stack is
`dartssh2` for SSH/SFTP/port forwarding, `xterm` for the terminal widget,
`flutter_secure_storage` for credentials, and `file_picker` for key import.

## License

Apache-2.0.
