#!/usr/bin/env bash
set -euo pipefail

step() {
  printf '\n==> %s\n' "$1"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS."
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

step "Enabling macOS Remote Login"
${SUDO} systemsetup -setremotelogin on
systemsetup -getremotelogin || true

step "Checking localhost SSH"
if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 22 >/dev/null 2>&1; then
  echo "OpenSSH is listening on localhost:22."
else
  echo "Remote Login was enabled, but localhost:22 did not respond yet."
fi

step "Reachable addresses"
for iface in en0 en1 bridge100; do
  ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    echo "${iface}: ${ip}"
  fi
done

if command -v ifconfig >/dev/null 2>&1; then
  ifconfig | awk '
    /flags=/ { iface=$1; sub(":", "", iface) }
    /inet / && $2 !~ /^127\./ { print iface ": " $2 }
  ' | sort -u
fi

username="$(id -un)"
hostname_value="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"

cat <<EOF

Phone SSH target: ${username}@<one-of-the-addresses-above>:22
DevOTA build URL: http://<one-of-the-addresses-above>:8082
DevOTA Agent URL: ws://<one-of-the-addresses-above>:8083/phone
Bonjour host hint: ${hostname_value}.local
EOF
