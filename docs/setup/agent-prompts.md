# Agent Prompts

These prompts are designed to be pasted into Claude Code, Codex, a Pi terminal
agent, or another terminal-based assistant running on the development computer.
They assume the human can complete browser login, account creation, MFA, and
mobile app approval steps when asked.

Replace placeholder paths and network names before pasting.

## Bootstrap DevOTA Host On LAN

```text
You are running on my development computer. Set up this computer so my Android
phone can connect to it over the local network for DevOTA.

Goals:
- Enable OpenSSH so the phone can SSH to this computer on port 22.
- Install WSL Ubuntu only if this is Windows and WSL is not already available.
- Do not expose SSH to the public internet.
- Print the LAN IP address, SSH username, and an exact phone-side SSH target.
- Verify port 22 is listening locally.

Use the DevOTA setup script from this checkout if it exists:
- Windows: scripts/setup/windows-devota-prereqs.ps1
- macOS: scripts/setup/macos-devota-prereqs.sh
- Linux: scripts/setup/linux-devota-prereqs.sh

If administrator or sudo approval is required, ask me before running the command.
Do not handle my account passwords, MFA, browser login, or private keys.
```

## Start The Build Server

```text
You are running on my development computer. Start DevOTA's build server for the
app repo at /path/to/app/repo.

Goals:
- Confirm /path/to/app/repo contains devota.yaml.
- Install Python requirements for DevOTA if needed.
- Start server/devota_server.py from the DevOTA repo with --repo-root
  /path/to/app/repo --host 0.0.0.0 --port 8082.
- Verify http://127.0.0.1:8082/health returns JSON.
- Print the LAN URL the phone should save, using this computer's LAN IP.
- If this is Windows and the server runs inside WSL, configure or request the
  Windows port proxy for port 8082.

Keep the server running and tell me the command needed to restart it.
```

## Start The MCP Phone Relay

```text
You are running on my development computer. Start DevOTA's MCP phone-control
relay so an LLM can inspect screenshots/UI trees and send Android gestures
through the DevOTA phone agent.

Goals:
- Work from the DevOTA repo's mcp directory.
- Run npm install if node_modules is missing.
- Use DEVOTA_REPO_ROOT=/path/to/app/repo.
- Use DEVOTA_BUILD_SERVER_URL=http://<computer-ip>:8082.
- Generate or ask me for a pairing token; do not print secrets into shared logs.
- Start the relay on port 8083.
- Verify the relay is listening.
- Tell me the exact Agent tab URL: ws://<computer-ip>:8083/phone.
- If this is Windows and the relay runs inside WSL, configure or request the
  Windows port proxy for port 8083.

After it starts, wait for the phone to connect and help me test screenshot,
tap, long tap, swipe, and install flows.
```

## Add ZeroTier As The Remote Path

```text
You are running on my development computer. Add ZeroTier as the private remote
network path for DevOTA, without hard-coding DevOTA to ZeroTier.

Goals:
- Determine the operating system.
- Install ZeroTier using official OS-appropriate package manager steps.
- Ask me for the ZeroTier network ID.
- Join that network.
- Ask me to approve/authorize this machine in the ZeroTier web UI if required.
- After approval, print the assigned ZeroTier IP.
- Verify SSH on port 22 is reachable on the ZeroTier interface locally or from
  another machine if a second machine is available.
- Tell me what URL the phone should save for DevOTA, using the ZeroTier IP and
  port 8082.

Do not create my account, bypass MFA, store account credentials, or expose SSH
outside the private ZeroTier network.
```

## Add Another VPN Provider

```text
You are running on my development computer. Add a private network provider for
DevOTA. Use the provider I name: Tailscale, WireGuard, ZeroTier, or another
private network.

Goals:
- Determine the operating system.
- Install the provider using official OS-appropriate package manager steps.
- Ask me for any network name, auth key, invite link, or config file that must
  come from my account.
- Ask me to complete browser login, MFA, or admin-console approval.
- Print the assigned VPN IP or DNS name.
- Verify SSH on port 22 and DevOTA port 8082 are reachable on that private
  network.
- Keep DevOTA provider-neutral; do not rewrite app code to assume this provider.

Do not store secrets in the repo. If a key/config is needed, place it only in
the provider's expected secure local location and tell me what was used.
```

## Configure Windows WSL Port Proxy

```text
You are running on Windows. My DevOTA build server or MCP relay is running
inside WSL Ubuntu, and my Android phone needs to connect through the Windows LAN
or VPN IP.

Goals:
- Find the current WSL Ubuntu IPv4 address.
- Configure Windows portproxy rules for the requested ports, usually 8082 for
  the build server and 8083 for the MCP relay.
- Add Windows firewall allow rules for those ports.
- Verify the Windows host is listening on those ports.
- Print the phone URLs:
  - http://<windows-ip>:8082
  - ws://<windows-ip>:8083/phone

Use scripts/setup/windows-devota-prereqs.ps1 -ConfigureWslPortProxy
-ForwardPorts 8082,8083 if that script is available.
Ask before running Administrator commands.
```

## Verify End-To-End Phone Use

```text
You are helping me verify DevOTA end to end.

Checklist:
- Phone can open DevOTA and discover or save the build server URL.
- Phone can SSH into the development computer.
- Build server /health, /apps, and /latest?app=<app-id> respond.
- DevOTA can download and install the latest APK for the selected app.
- Agent tab connects to the MCP relay with the pairing token.
- MCP relay can capture screenshot and UI tree.
- MCP relay can perform tap, long tap, swipe, text input, back, home, and app
  launch.

Report the exact failure point with command output, server logs, and the phone
screen state if any step fails.
```
