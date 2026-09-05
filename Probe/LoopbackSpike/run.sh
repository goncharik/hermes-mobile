#!/bin/bash
# Build + install + launch the loopback spike on a simulator. No Xcode project, no Tuist:
# swiftc straight to a hand-assembled .app so this harness can never leak into a shipped
# target.
#
#   Probe/LoopbackSpike/run.sh <simulator-udid> [ios-target-version]
#
# Prints the app container path; read `Documents/spike.log` from there for the result.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UDID="${1:?usage: run.sh <simulator-udid> [ios-version]}"
IOS_VERSION="${2:-18.0}"
BUNDLE_ID="me.honcharenko.LoopbackSpike"
BUILD="$HERE/build"
APP="$BUILD/LoopbackSpike.app"

rm -rf "$BUILD"
mkdir -p "$APP"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-ios${IOS_VERSION}-simulator" \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -o "$APP/LoopbackSpike" \
  "$HERE/LoopbackSpikeApp.swift"

cat >"$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>LoopbackSpike</string>
  <key>CFBundleIdentifier</key><string>me.honcharenko.LoopbackSpike</string>
  <key>CFBundleName</key><string>LoopbackSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>MinimumOSVersion</key><string>18.0</string>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>Loopback OAuth spike.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 &
sleep 2
xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data
