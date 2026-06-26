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
  lightweight TCP ping, and voice-to-terminal command submission.
- **Backup**: export/import saved servers, commands, issues, agent settings,
  OpenAI API keys, and SSH public/private keys.
- **Issues**: voice-transcribed notes that can be added to a numbered issue
  list, copied locally, or pushed to the PC clipboard endpoint.
- **Commands** and **Agent**: saved command snippets and the Android MCP phone
  control agent.

## GitHub Builds

The `Android` GitHub Actions workflow builds one public debug APK artifact:

- `devota-arm64-debug.apk`: the public ARM64 DevOTA package,
  `io.github.chasekolozsy.devota`.

The default `devota.yaml` serves only the public DevOTA staged output from
`app/dist/public`.

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
- `GET /github/workflow/runs?repo=<owner/name>&workflow=<file>`
- `GET /download/<virtual-apk-path>`
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
