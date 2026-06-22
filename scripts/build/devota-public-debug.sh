#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/app/dist/public"
APK="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk"
BUILD_NUMBER="${DEVOTA_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.apk "$DIST_DIR"/*.sha256 "$DIST_DIR"/*.badging.txt

(
  cd "$ROOT_DIR/app"
  flutter build apk --debug --split-per-abi --target-platform android-arm64 \
    --build-number="$BUILD_NUMBER"
)

cp "$APK" "$DIST_DIR/devota-arm64-debug.apk"
(
  cd "$DIST_DIR"
  sha256sum devota-arm64-debug.apk > devota-arm64-debug.apk.sha256
)

if [[ -n "${ANDROID_HOME:-}" ]]; then
  AAPT="$(find "$ANDROID_HOME/build-tools" -path '*/aapt' -type f | sort -V | tail -1)"
  if [[ -n "$AAPT" ]]; then
    "$AAPT" dump badging "$DIST_DIR/devota-arm64-debug.apk" \
      > "$DIST_DIR/devota-arm64-debug.badging.txt"
  fi
fi

echo "Staged $DIST_DIR/devota-arm64-debug.apk"
