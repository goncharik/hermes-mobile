#!/usr/bin/env bash
#
# Build, install, and launch HermesMobile on a connected physical device.
# Requires a development team (automatic signing) and a trusted, paired device.
#
# Usage:
#   DEVELOPMENT_TEAM=<your 10-char team id> scripts/run-device.sh
# Notes:
#   - Find your team id under the Apple Distribution/Development cert, e.g. 7V99GYC5W7.
#   - The team is baked into the project at generate time, so this regenerates.
#   - Untested in CI here (no device) — drives `xcodebuild` + `devicectl`.
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCHEME="HermesMobile"
WORKSPACE="HermesMobile.xcworkspace"
BUNDLE_ID="${BUNDLE_ID:-me.honcharenko.HermesMobile}"

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM=<your 10-char Apple team id> and re-run}"

echo "▸ Generating project with team $DEVELOPMENT_TEAM"
# Tuist only forwards TUIST_-prefixed env vars to the manifest, so translate.
TUIST_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" TUIST_BUNDLE_ID="$BUNDLE_ID" tuist generate --no-open

# First connected/available physical device UDID.
#
# Two traps in `devicectl list devices` output. Simulators are listed alongside real hardware
# and report State "connected" exactly as a plugged-in phone does, so filtering on state alone
# installs to a simulator and still prints "Running on device". And the two use different
# identifier shapes: a simulator has a 36-char UUID, a modern iPhone has 25 characters (8 hex,
# dash, 16 hex), so a regex written for one silently never matches the other. Excluding
# "simulated" rows and taking the field before the literal "(UDID)" marker avoids both.
DEVICE_UDID="$(
  xcrun devicectl list devices 2>/dev/null \
    | awk '!/simulated/ && /connected|available/ {for (i=1;i<=NF;i++) if ($i == "(UDID)") {print $(i-1); exit}}'
)"
if [ -z "${DEVICE_UDID:-}" ]; then
  echo "✗ No connected device found. Plug in + trust your iPhone, then retry." >&2
  echo "  Devices:" >&2; xcrun devicectl list devices 2>&1 | sed 's/^/    /' >&2
  exit 1
fi
echo "▸ Device: $DEVICE_UDID"

echo "▸ Building (automatic signing)…"
xcodebuild build \
  -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$DEVICE_UDID" \
  -allowProvisioningUpdates \
  -skipMacroValidation \
  -quiet

APP_PATH="$(
  xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
    -destination "id=$DEVICE_UDID" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}'
)"

echo "▸ Installing $(basename "$APP_PATH")"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"
echo "▸ Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"
echo "✓ Running on device"
