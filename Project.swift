import Foundation
import ProjectDescription

// Read at generate time via Tuist's `Environment` — Tuist only forwards `TUIST_`-prefixed
// env vars to manifest evaluation (plain `ProcessInfo` env vars are NOT visible here).
// The run scripts translate friendly names (DEVELOPMENT_TEAM, HERMES_DEFAULT_SERVER_URL)
// into TUIST_DEVELOPMENT_TEAM / TUIST_SERVER_URL.

// Debug-only server preset (empty by default; baked into the Debug Info.plist).
let debugServerURL = Environment.serverUrl.getString(default: "")

// Apple team for device/TestFlight signing. Empty for simulator-only work (simulator
// builds pass CODE_SIGNING_ALLOWED=NO).
let developmentTeam = Environment.developmentTeam.getString(default: "")

// Apple registers an App ID to exactly ONE team, so a fork signing with its own team cannot
// reuse the upstream identifier — device and TestFlight builds fail to register it. Default
// stays upstream's, so nothing changes unless a fork sets TUIST_BUNDLE_ID.
let bundleId = Environment.bundleId.getString(default: "me.honcharenko.HermesMobile")

// Push Notifications. A personal Apple team cannot sign the capability at all ("Personal
// development teams do not support the Push Notifications capability"), which blocks device
// builds outright rather than just disabling notifications. Default stays on; set
// TUIST_ENABLE_PUSH=0 to drop the entitlement and build on a personal team, losing push.
let enablePush = Environment.enablePush.getString(default: "1") != "0"

let project = Project(
  name: "HermesMobile",
  packages: [
    .local(path: "HermesKit"),
    .remote(
      url: "https://github.com/pointfreeco/swift-snapshot-testing",
      requirement: .upToNextMajor(from: "1.17.0")
    ),
  ],
  targets: [
    .target(
      name: "HermesMobile",
      // iPad is a first-class destination (#80): the app lays out as a
      // `NavigationSplitView` in regular width. No `UIRequiresFullScreen` — Slide Over and
      // narrow iPadOS windows must resolve to the compact (stack) layout.
      destinations: [.iPhone, .iPad],
      product: .app,
      bundleId: bundleId,
      deploymentTargets: .iOS("18.0"),
      infoPlist: .extendingDefault(with: [
        // Wire the bundle version/short-version to the build settings below so a
        // `CURRENT_PROJECT_VERSION` bump actually reaches the Info.plist (Tuist's
        // default otherwise hardcodes CFBundleVersion = 1, ignoring the setting).
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "UILaunchScreen": ["UIColorName": ""],
        // iPad rotates freely in every orientation; the split view adapts (side-by-side
        // in landscape, overlay sidebar in portrait). iPhone keeps Tuist's default set.
        "UISupportedInterfaceOrientations~ipad": [
          "UIInterfaceOrientationPortrait",
          "UIInterfaceOrientationPortraitUpsideDown",
          "UIInterfaceOrientationLandscapeLeft",
          "UIInterfaceOrientationLandscapeRight",
        ],
        "HermesDefaultServerURL": .string(debugServerURL),
        // The app connects to user-specified self-hosted servers over http (Tailscale/LAN),
        // so domain-scoped ATS exceptions aren't possible — allow cleartext loads.
        "NSAppTransportSecurity": [
          "NSAllowsArbitraryLoads": true,
        ],
        // On device, reaching a private/tailnet host can trigger the local-network prompt.
        "NSLocalNetworkUsageDescription": "Hermes Mobile connects to your self-hosted Hermes server over your private network or Tailscale.",
        // Voice input records a short clip that's transcribed by your Hermes server.
        "NSMicrophoneUsageDescription": "Hermes Mobile records your voice so it can be transcribed into a message by your Hermes server.",
        // Camera attachments let you take a photo to send with a message. (The photo-library
        // picker uses PHPicker, which runs out-of-process and needs no usage string.)
        "NSCameraUsageDescription": "Hermes Mobile uses the camera so you can attach a photo to your message.",
        // Only standard encryption (HTTPS/TLS) — exempt; lets TestFlight skip the
        // export-compliance prompt so builds are testable immediately.
        "ITSAppUsesNonExemptEncryption": false,
        // Wake the app to process incoming remote notifications while backgrounded —
        // the gateway socket drops in the background, so pushes are how the agent reaches us.
        "UIBackgroundModes": ["remote-notification"],
      ]),
      sources: ["HermesMobile/Sources/**"],
      resources: ["HermesMobile/Resources/**"],
      // Push Notifications capability. `aps-environment` is driven by the
      // `$(APS_ENVIRONMENT)` build setting (set per-configuration below) so it tracks
      // the compile-time `apns_env` exactly: Debug → "development" (sandbox APNs host),
      // Release → "production" (App Store / distribution APNs host). Tuist emits the
      // entitlements value verbatim with no Xcode export rewrite, so a static
      // "development" would otherwise ship a sandbox entitlement on Release builds while
      // the app reports production — APNs would reject. The compile-time `apns_env`
      // (DEBUG → "sandbox", else "production") mirrors this.
      entitlements: enablePush
        ? .dictionary(["aps-environment": "$(APS_ENVIRONMENT)"])
        : nil,
      dependencies: [
        .package(product: "HermesKit"),
      ],
      settings: .settings(
        base: [
          "DEVELOPMENT_TEAM": .string(developmentTeam),
          "CODE_SIGN_STYLE": "Automatic",
          "MARKETING_VERSION": "1.0",
          "CURRENT_PROJECT_VERSION": "66",
          // App Store release default — the orange "AppIcon". ONLY App Store submission
          // builds keep it. Debug builds override to the blue "AppIconDev" below, and ALL
          // TestFlight archives (internal AND external — they share one build) override it
          // on the xcodebuild command line (`ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev`)
          // — a custom configuration breaks Tuist's SwiftPM integration, so we switch the
          // icon via a build setting.
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        ],
        configurations: [
          // Local dev → blue icon, so it's visually distinct from the production app.
          // `APS_ENVIRONMENT=development` → sandbox APNs (matches DEBUG `apns_env`).
          .debug(name: "Debug", settings: [
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIconDev",
            "APS_ENVIRONMENT": "development",
          ]),
          // App Store release → orange (base). Every TestFlight archive reuses this config
          // with the icon overridden to AppIconDev on the command line (see docs/development.md).
          // `APS_ENVIRONMENT=production` → production APNs (matches non-DEBUG `apns_env`).
          .release(name: "Release", settings: [
            "APS_ENVIRONMENT": "production",
          ]),
        ]
      )
    ),
    .target(
      name: "HermesMobileTests",
      destinations: [.iPhone, .iPad],
      product: .unitTests,
      bundleId: "\(bundleId)Tests",
      deploymentTargets: .iOS("18.0"),
      sources: ["HermesMobileTests/**"],
      dependencies: [
        .target(name: "HermesMobile"),
        .package(product: "SnapshotTesting"),
      ]
    ),
  ]
)
