#!/usr/bin/env bash
#
# Build, install, and launch HermesMobile on an iOS simulator. No signing needed.
#
# Usage:
#   scripts/run-sim.sh [simulator name]
# Env:
#   SIM_NAME                 simulator to use (default: "iPhone 17 Pro")
#   HERMES_DEFAULT_SERVER_URL  baked into the Debug build at generate time (optional)
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCHEME="HermesMobile"
WORKSPACE="HermesMobile.xcworkspace"
BUNDLE_ID="${BUNDLE_ID:-me.honcharenko.HermesMobile}"
SIM_NAME="${1:-${SIM_NAME:-iPhone 17 Pro}}"

# Tuist only forwards TUIST_-prefixed env vars to the manifest, so translate.
[ -d "$WORKSPACE" ] || TUIST_SERVER_URL="${HERMES_DEFAULT_SERVER_URL:-}" TUIST_BUNDLE_ID="$BUNDLE_ID" tuist generate --no-open

# Resolve a simulator UDID by exact name (first available match).
SIM_UDID="$(
  xcrun simctl list devices available \
    | awk -v n="$SIM_NAME" 'index($0, n" (") {print; exit}' \
    | grep -oE '[0-9A-Fa-f-]{36}' | head -1
)"
if [ -z "${SIM_UDID:-}" ]; then
  echo "✗ No available simulator named '$SIM_NAME'. Available iPhones:" >&2
  xcrun simctl list devices available | grep -E "iPhone" >&2
  exit 1
fi

echo "▸ Simulator: $SIM_NAME ($SIM_UDID)"
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || true
# Xcode 27 dropped Simulator.app in favour of DeviceHub.app. The device is already booted
# by bootstatus above, so failing to raise a window must not abort the run.
open -a Simulator 2>/dev/null || open -a DeviceHub 2>/dev/null || true

echo "▸ Building…"
xcodebuild build \
  -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$SIM_UDID" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

APP_PATH="$(
  xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
    -destination "id=$SIM_UDID" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}'
)"

echo "▸ Installing $(basename "$APP_PATH")"
xcrun simctl install "$SIM_UDID" "$APP_PATH"
echo "▸ Launching $BUNDLE_ID"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null
echo "✓ Running on $SIM_NAME"
