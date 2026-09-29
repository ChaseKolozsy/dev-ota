#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
device="${DEVOTA_ADB_DEVICE:-emulator-5556}"
port="${DEVOTA_EMULATOR_SSH_PORT:-2224}"

adb -s "$device" get-state >/dev/null
adb -s "$device" reverse "tcp:$port" "tcp:$port"

cd "$repo_dir/tools/emulator-ssh-bridge"
exec go run . \
  --listen "127.0.0.1:$port" \
  --accept-any-key \
  "$@"
