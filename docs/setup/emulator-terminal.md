# DevOTA terminal on an Android emulator

DevOTA can use a loopback-only SSH bridge for a convenient host shell while it
runs in an Android emulator. This is useful for testing terminal commands and
macros without enabling a system SSH daemon or exposing a port to the LAN.

Requirements: Go, Android platform tools (`adb`), a running emulator, and a
DevOTA build that includes the Terminal tab.

From the repository root, run:

```bash
DEVOTA_ADB_DEVICE=emulator-5556 scripts/setup/devota-emulator-ssh.sh
```

The launcher adds `adb reverse tcp:2224 tcp:2224` and starts the bridge on
`127.0.0.1:2224`. In DevOTA's Terminal settings use:

- Host: `127.0.0.1`
- Port: `2224`
- User: your host user name
- Authentication: a generated DevOTA key

Trust the host fingerprint on first connection. The host key persists at
`~/.local/state/devota/emulator_bridge_host_key`, so later launches keep the
same fingerprint.

The launcher intentionally passes `--accept-any-key`. That mode is rejected if
the bridge is configured on a non-loopback address; access is additionally
limited to the selected emulator by ADB reverse. For stricter local testing,
run the Go tool directly without `--accept-any-key` and point
`--authorized-keys` at an OpenSSH authorized-keys file.

ADB reverse rules do not survive every emulator restart. Restart the launcher
or run `adb -s emulator-5556 reverse tcp:2224 tcp:2224` again after a reboot.
