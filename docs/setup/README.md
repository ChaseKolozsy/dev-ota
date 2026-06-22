# LAN-First Desktop Setup

DevOTA assumes the first successful connection happens over a local network:
same Wi-Fi, phone hotspot, USB-tethered network, or another LAN path. After that
works, you can add a VPN such as ZeroTier, Tailscale, WireGuard, or another
private network without changing the DevOTA app model.

This setup kit reduces the amount of manual desktop work needed before the
phone can SSH into the development machine and discover a DevOTA build server.

## What Gets Installed

- Windows: OpenSSH Client, OpenSSH Server, firewall rule for SSH, and optional
  WSL Ubuntu. It can also configure a Windows port proxy for DevOTA services
  running inside WSL.
- macOS: Remote Login, which enables the built-in OpenSSH server.
- Linux: OpenSSH Server through the native package manager, with best-effort
  firewall opening for SSH.

The scripts do not create VPN accounts, bypass browser login, copy secrets, or
open public SSH. They prepare the computer so the phone can connect over a
trusted LAN or VPN address.

## Run The Desktop Script

Run these from the root of the `dev-ota` checkout.

### Windows

Open PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\setup\windows-devota-prereqs.ps1
```

If you run the DevOTA build server or MCP relay inside WSL and need the phone to
reach those ports through Windows, enable the optional port proxy:

```powershell
.\scripts\setup\windows-devota-prereqs.ps1 -ConfigureWslPortProxy -ForwardPorts 8082,8083
```

The phone should SSH to the Windows LAN or VPN IP. From that Windows SSH shell,
an agent can enter Ubuntu with:

```powershell
wsl.exe -d Ubuntu
```

### macOS

```bash
chmod +x scripts/setup/macos-devota-prereqs.sh
./scripts/setup/macos-devota-prereqs.sh
```

### Linux

```bash
chmod +x scripts/setup/linux-devota-prereqs.sh
./scripts/setup/linux-devota-prereqs.sh
```

## Start DevOTA Services

Start the HTTP build server from this repo, pointed at the app repo whose APKs
you want to serve:

```bash
python3 -m pip install -r requirements.txt
python3 server/devota_server.py --repo-root /path/to/app/repo --host 0.0.0.0 --port 8082
```

Open DevOTA on the phone:

1. Use Connect to scan the LAN for `_devota._tcp.local.` servers.
2. If discovery does not find the server, save `http://<computer-ip>:8082`.
3. Use Terminal to SSH into `<computer-ip>` on port `22`.
4. In Terminal, generate a DevOTA phone key and send its public key to the
   build server. In WSL, the server installs it into the Windows administrator
   key file when your Windows account is an administrator, requesting UAC if
   needed; otherwise it uses the Windows user's `authorized_keys`.
5. If Windows shows an administrator prompt, approve it on the computer, return
   to DevOTA, and tap Connect again to verify key-based SSH works.
6. Paste an agent prompt from [agent-prompts.md](agent-prompts.md) into the
   terminal agent you are using on the desktop.

Optional MCP relay:

```bash
cd mcp
npm install
DEVOTA_REPO_ROOT=/path/to/app/repo \
DEVOTA_BUILD_SERVER_URL=http://<computer-ip>:8082 \
DEVOTA_PAIR_TOKEN='choose-a-token' \
npm start
```

Then open DevOTA's Agent tab and connect to:

```text
ws://<computer-ip>:8083/phone
```

## Migrating From Build Installer

The GitHub `Android` workflow publishes a normal DevOTA APK and a legacy package
upgrade APK. Install the legacy upgrade first if you need access to saved Build
Installer data. Open Backup, export settings with secrets enabled if you want
OpenAI keys and SSH private keys included, then import the backup in the public
DevOTA package.

After the desktop build server is running, the Builds tab can use the desktop
`gh` login to run that workflow and download the APK artifact back into the
served build cache.

## Remote Networking

The app is provider-neutral. ZeroTier can be the preferred remote path, but it
is not hard-coded:

- Use LAN first to prove SSH, build serving, and MCP pairing.
- Use Connect on Android to open or install your preferred network helper.
- Ask a desktop agent to install and join the same provider on the computer.
- Keep browser account creation, MFA, and network authorization as human steps.

The prompts in [agent-prompts.md](agent-prompts.md) are written for that split:
the agent performs terminal-safe setup and asks the human to complete account or
browser approval steps.

## Security Notes

- SSH exposes a login surface to the selected network. Use a strong local
  password or SSH key, and keep the network private.
- The public-key install endpoint is for trusted LAN/VPN use. Do not expose the
  build server to the public internet.
- DevOTA does not need inbound public internet access. Prefer LAN, hotspot, or a
  private VPN address.
- Pair the MCP phone-control relay with an explicit token.
- Keep generated APKs and any signing keys inside repos you control.

## Reference Docs

- [Microsoft OpenSSH for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
- [Microsoft WSL setup](https://learn.microsoft.com/en-us/windows/wsl/setup/environment)
- [Ubuntu OpenSSH Server](https://ubuntu.com/server/docs/how-to/security/openssh-server/)
- [Apple Remote Login](https://support.apple.com/guide/remote-desktop/enable-remote-management-apd8b1c65bd/mac)
