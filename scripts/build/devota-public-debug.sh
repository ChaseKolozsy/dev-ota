#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/app/dist/public"
APK="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk"
ARM64_VERSION_OFFSET=2000
MIN_SAFE_ARM64_VERSION_CODE=2026064402

read_existing_arm64_version_code() {
  local badging="$DIST_DIR/devota-arm64-debug.badging.txt"
  [[ -f "$badging" ]] || return 1
  sed -n "s/.*versionCode='\([0-9][0-9]*\)'.*/\1/p" "$badging" | head -1
}

required_min_arm64_version_code() {
  local min_version_code="$MIN_SAFE_ARM64_VERSION_CODE"
  local existing_version_code
  existing_version_code="$(read_existing_arm64_version_code || true)"
  if [[ "$existing_version_code" =~ ^[0-9]+$ ]] && (( existing_version_code > min_version_code )); then
    min_version_code="$existing_version_code"
  fi
  printf '%s\n' "$min_version_code"
}

default_build_number() {
  local min_version_code="$1"
  local candidate
  candidate="$(date +%Y%m%d)01"
  if (( candidate + ARM64_VERSION_OFFSET <= min_version_code )); then
    candidate=$((min_version_code - ARM64_VERSION_OFFSET + 1))
  fi
  printf '%s\n' "$candidate"
}

MIN_ARM64_VERSION_CODE="$(required_min_arm64_version_code)"
if [[ -n "${DEVOTA_BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER="$DEVOTA_BUILD_NUMBER"
else
  BUILD_NUMBER="$(default_build_number "$MIN_ARM64_VERSION_CODE")"
fi

if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "DEVOTA_BUILD_NUMBER must be numeric; got '$BUILD_NUMBER'." >&2
  exit 1
fi

EXPECTED_ARM64_VERSION_CODE=$((BUILD_NUMBER + ARM64_VERSION_OFFSET))
if (( EXPECTED_ARM64_VERSION_CODE <= MIN_ARM64_VERSION_CODE )) && [[ "${DEVOTA_ALLOW_LOWER_BUILD_NUMBER:-}" != "1" ]]; then
  cat >&2 <<EOF
Refusing to stage DevOTA build-number $BUILD_NUMBER.
Expected ARM64 versionCode $EXPECTED_ARM64_VERSION_CODE is not higher than $MIN_ARM64_VERSION_CODE.
Use a higher DEVOTA_BUILD_NUMBER, or set DEVOTA_ALLOW_LOWER_BUILD_NUMBER=1 only for throwaway downgrade testing.
EOF
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.apk "$DIST_DIR"/*.sha256 "$DIST_DIR"/*.badging.txt

echo "Using DevOTA build-number $BUILD_NUMBER (expected ARM64 versionCode $EXPECTED_ARM64_VERSION_CODE)."

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

if [[ -f "$DIST_DIR/devota-arm64-debug.badging.txt" ]]; then
  ACTUAL_ARM64_VERSION_CODE="$(read_existing_arm64_version_code || true)"
  if [[ "$ACTUAL_ARM64_VERSION_CODE" =~ ^[0-9]+$ ]] && (( ACTUAL_ARM64_VERSION_CODE <= MIN_ARM64_VERSION_CODE )) && [[ "${DEVOTA_ALLOW_LOWER_BUILD_NUMBER:-}" != "1" ]]; then
    echo "Refusing staged APK with ARM64 versionCode $ACTUAL_ARM64_VERSION_CODE; expected newer than $MIN_ARM64_VERSION_CODE." >&2
    exit 1
  fi
fi

echo "Staged $DIST_DIR/devota-arm64-debug.apk"
