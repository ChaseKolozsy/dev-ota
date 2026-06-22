#!/usr/bin/env bash
set -euo pipefail

step() {
  printf '\n==> %s\n' "$1"
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is for Linux."
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

install_openssh() {
  step "Installing OpenSSH Server"
  if command -v apt-get >/dev/null 2>&1; then
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y openssh-server
  elif command -v dnf >/dev/null 2>&1; then
    ${SUDO} dnf install -y openssh-server
  elif command -v yum >/dev/null 2>&1; then
    ${SUDO} yum install -y openssh-server
  elif command -v pacman >/dev/null 2>&1; then
    ${SUDO} pacman -Sy --needed --noconfirm openssh
  elif command -v apk >/dev/null 2>&1; then
    ${SUDO} apk add openssh
  else
    echo "Unsupported package manager. Install OpenSSH Server manually."
    exit 1
  fi
}

enable_ssh_service() {
  step "Enabling SSH service"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
      ${SUDO} systemctl enable --now ssh
    elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
      ${SUDO} systemctl enable --now sshd
    else
      echo "No ssh.service or sshd.service unit was found."
    fi
  elif command -v service >/dev/null 2>&1; then
    ${SUDO} service ssh start 2>/dev/null || ${SUDO} service sshd start
  else
    echo "No supported service manager found. Start sshd manually."
  fi
}

open_firewall() {
  step "Checking firewall"
  if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status | grep -qi "Status: active"; then
    ${SUDO} ufw allow OpenSSH || ${SUDO} ufw allow 22/tcp
  elif command -v firewall-cmd >/dev/null 2>&1 && ${SUDO} firewall-cmd --state >/dev/null 2>&1; then
    ${SUDO} firewall-cmd --add-service=ssh --permanent
    ${SUDO} firewall-cmd --reload
  else
    echo "No active ufw/firewalld rule set detected."
  fi
}

check_ssh() {
  step "Checking localhost SSH"
  if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 22 >/dev/null 2>&1; then
    echo "OpenSSH is listening on localhost:22."
  elif timeout 2 bash -c '</dev/tcp/127.0.0.1/22' >/dev/null 2>&1; then
    echo "OpenSSH is listening on localhost:22."
  else
    echo "OpenSSH was configured, but localhost:22 did not respond yet."
  fi
}

print_addresses() {
  step "Reachable addresses"
  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | sort -u || true
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -4 -brief addr show scope global | awk '{ print $1 ": " $3 }' | sed 's#/.*##'
  fi

  username="$(id -un)"
  cat <<EOF

Phone SSH target: ${username}@<one-of-the-addresses-above>:22
DevOTA build URL: http://<one-of-the-addresses-above>:8082
DevOTA Agent URL: ws://<one-of-the-addresses-above>:8083/phone
EOF
}

install_openssh
enable_ssh_service
open_firewall
check_ssh
print_addresses
