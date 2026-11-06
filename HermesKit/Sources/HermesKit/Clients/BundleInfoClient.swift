import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Static facts about the running build and device: the Settings version row, the prefilled
/// GitHub issue body (`FeedbackLinks`) and the diagnostics report all read these.
public struct BundleInfo: Equatable, Hashable, Sendable {
  /// `CFBundleShortVersionString`, e.g. `"1.0"`.
  public var marketingVersion: String
  /// `CFBundleVersion`, e.g. `"79"`.
  public var build: String
  /// The OS version, e.g. `"18.0"` or `"26.1.2"`.
  public var osVersion: String
  /// The hardware model identifier, e.g. `"iPhone17,1"` (the simulated model on a simulator).
  public var deviceModel: String

  public init(marketingVersion: String, build: String, osVersion: String, deviceModel: String) {
    self.marketingVersion = marketingVersion
    self.build = build
    self.osVersion = osVersion
    self.deviceModel = deviceModel
  }

  /// `"<marketingVersion> (<build>)"`, e.g. `"1.0 (79)"`.
  public var versionAndBuild: String { "\(marketingVersion) (\(build))" }

  /// The `App:` / `iOS:` / `Device:` lines shared by the diagnostics report and the
  /// prefilled issue body.
  public var environmentLines: [String] {
    ["App: \(versionAndBuild)", "iOS: \(osVersion)", "Device: \(deviceModel)"]
  }

  /// The fixed facts `BundleInfoClient.testValue` returns.
  public static let test = BundleInfo(
    marketingVersion: "1.0",
    build: "79",
    osVersion: "18.0",
    deviceModel: "iPhone"
  )
}

/// Reads `BundleInfo` behind a dependency so reducers never touch `Bundle` / `ProcessInfo`
/// and tests get fixed strings.
@DependencyClient
public struct BundleInfoClient: Sendable {
  public var info: @Sendable () -> BundleInfo = { .test }
}

extension BundleInfoClient: DependencyKey {
  /// Reads `Bundle.main` and the process environment. Platform-neutral (no UIKit): the OS
  /// version comes from `ProcessInfo` rather than the main-actor-isolated `UIDevice`.
  public static var liveValue: BundleInfoClient {
    BundleInfoClient(info: {
      BundleInfo(
        marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "0.0",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        osVersion: formatOSVersion(ProcessInfo.processInfo.operatingSystemVersion),
        deviceModel: machineIdentifier(environment: ProcessInfo.processInfo.environment)
      )
    })
  }

  /// Fixed `BundleInfo.test` facts.
  public static var testValue: BundleInfoClient {
    BundleInfoClient(info: { .test })
  }

  /// `UIDevice.systemVersion`-style formatting: `major.minor`, plus `.patch` when non-zero.
  static func formatOSVersion(_ version: OperatingSystemVersion) -> String {
    let base = "\(version.majorVersion).\(version.minorVersion)"
    return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
  }

  /// The `utsname` machine identifier (`"iPhone17,1"`). A simulator reports the host CPU
  /// (`"arm64"`), so the simulated model from `SIMULATOR_MODEL_IDENTIFIER` wins when present.
  static func machineIdentifier(environment: [String: String]) -> String {
    if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
      return simulated
    }
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
      String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    return machine.isEmpty ? "unknown" : machine
  }
}

public extension DependencyValues {
  var bundleInfo: BundleInfoClient {
    get { self[BundleInfoClient.self] }
    set { self[BundleInfoClient.self] = newValue }
  }
}
