#!/usr/bin/env bash
set -euo pipefail

# Sideload-friendly release build for DevOTA.
# - --release (not --debug) so debuggable=false and Play Protect is less noisy
# - universal APK (no --split-per-abi) so one file works on arm64, arm, x64
# - signed via app/android/app/build.gradle.kts signingConfigs.release
#   which defaults to app/keystores/dev.keystore but honours
#   keystore.properties or DEVOTA_KEYSTORE_* / ANDROID_KEYSTORE_* env vars.
# - zipaligned + v1/v2/v3 signed automatically by Gradle/Flutter
# - staged to app/dist/public for the local DevOTA server + GitHub Actions artifacts

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/app/dist/public"
APK_UNIVERSAL="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-release.apk"
ARM64_VERSION_OFFSET=2000
MIN_SAFE_ARM64_VERSION_CODE=2026064402

read_existing_arm64_version_code() {
  local badging="$DIST_DIR/devota-universal-release.badging.txt"
  [[ -f "$badging" ]] || return 1
  sed -n "s/.*versionCode='\([0-9][0-9]*\)'.*/\1/p" "$badging" | head -1
}

# Also check legacy debug badging so versionCode keeps moving forward even if
# only debug was built before.
read_existing_any_version_code() {
  if badging="$(read_existing_arm64_version_code 2>/dev/null)"; then
    printf '%s\n' "$badging"
    return 0
  fi
  local legacy="$DIST_DIR/devota-arm64-debug.badging.txt"
  [[ -f "$legacy" ]] || return 1
  sed -n "s/.*versionCode='\([0-9][0-9]*\)'.*/\1/p" "$legacy" | head -1
}

required_min_arm64_version_code() {
  local min_version_code="$MIN_SAFE_ARM64_VERSION_CODE"
  local existing_version_code
  existing_version_code="$(read_existing_any_version_code || true)"
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
# Keep debug artefacts if present; just clean old release artefacts for this run.
rm -f "$DIST_DIR/devota-universal-release.apk" "$DIST_DIR/devota-universal-release.apk.sha256" "$DIST_DIR/devota-universal-release.badging.txt"

echo "Using DevOTA build-number $BUILD_NUMBER (expected versionCode $EXPECTED_ARM64_VERSION_CODE) for RELEASE build."

(
  cd "$ROOT_DIR/app"
  flutter build apk --release --build-number="$BUILD_NUMBER"
)

if [[ ! -f "$APK_UNIVERSAL" ]]; then
  echo "Expected universal release APK not found at $APK_UNIVERSAL" >&2
  ls -R "$ROOT_DIR/app/build/app/outputs/flutter-apk" >&2 || true
  exit 1
fi

cp "$APK_UNIVERSAL" "$DIST_DIR/devota-universal-release.apk"
(
  cd "$DIST_DIR"
  sha256sum devota-universal-release.apk > devota-universal-release.apk.sha256
)

if [[ -n "${ANDROID_HOME:-}" ]]; then
  AAPT="$(find "$ANDROID_HOME/build-tools" -path '*/aapt' -type f 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -n "${AAPT:-}" ]]; then
    "$AAPT" dump badging "$DIST_DIR/devota-universal-release.apk" > "$DIST_DIR/devota-universal-release.badging.txt" || true
  fi
  # Prefer apksigner verify + zipalign check when available
  APKSIGNER="$(find "$ANDROID_HOME/build-tools" -path '*/apksigner' -type f 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -n "${APKSIGNER:-}" ]]; then
    echo "Verifying APK signature with apksigner..."
    "$APKSIGNER" verify --verbose "$DIST_DIR/devota-universal-release.apk" || {
      echo "apksigner verify failed" >&2
      exit 1
    }
  fi
  ZIPALIGN="$(find "$ANDROID_HOME/build-tools" -path '*/zipalign' -type f 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -n "${ZIPALIGN:-}" ]]; then
    echo "Checking zipalign..."
    "$ZIPALIGN" -c 4 "$DIST_DIR/devota-universal-release.apk" || {
      echo "zipalign check failed (APK not aligned)" >&2
      exit 1
    }
  fi
fi

if [[ -f "$DIST_DIR/devota-universal-release.badging.txt" ]]; then
  ACTUAL_VERSION_CODE="$(read_existing_arm64_version_code || true)"
  if [[ "$ACTUAL_VERSION_CODE" =~ ^[0-9]+$ ]] && (( ACTUAL_VERSION_CODE <= MIN_ARM64_VERSION_CODE )) && [[ "${DEVOTA_ALLOW_LOWER_BUILD_NUMBER:-}" != "1" ]]; then
    echo "Refusing staged APK with versionCode $ACTUAL_VERSION_CODE; expected newer than $MIN_ARM64_VERSION_CODE." >&2
    exit 1
  fi
  # Ensure debuggable is NOT set for release
  if grep -q "application-debuggable" "$DIST_DIR/devota-universal-release.badging.txt"; then
    echo "Release APK is debuggable — check buildTypes.release config." >&2
    exit 1
  fi
fi

echo "Staged $DIST_DIR/devota-universal-release.apk"
echo "SHA256: $(cat "$DIST_DIR/devota-universal-release.apk.sha256")"
if [[ -f "$DIST_DIR/devota-universal-release.badging.txt" ]]; then
  echo "Badging:"
  cat "$DIST_DIR/devota-universal-release.badging.txt"
fi
