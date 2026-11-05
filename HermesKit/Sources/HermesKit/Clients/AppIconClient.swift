import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Reads and switches the app's home-screen icon. Wraps `UIApplication`'s alternate-icon
/// APIs behind a dependency so reducers never touch UIKit. iOS persists the choice itself;
/// nothing here is mirrored into `PreferencesClient`, so logout never touches it.
@DependencyClient
public struct AppIconClient: Sendable {
  /// The icons this build can switch between (bundle `Info.plist` derived).
  public var catalog: @Sendable () -> AppIconCatalog = { .empty }
  /// The current `alternateIconName` — `nil` means the build's primary icon.
  public var current: @Sendable () async -> String? = { nil }
  /// Switches the icon; `nil` restores the primary. Throws when iOS refuses the change.
  public var set: @Sendable (_ name: String?) async throws -> Void
}

extension AppIconClient: DependencyKey {
  /// In-memory double: the full six-icon catalog with `AppIcon` as primary, `current`
  /// starting at the primary and following every successful `set`.
  public static var testValue: AppIconClient { .inMemory() }

  /// Deterministic in-memory client. `set` records the name and `current` reflects it.
  public static func inMemory(
    catalog: AppIconCatalog = .testCatalog,
    current initial: String? = nil
  ) -> AppIconClient {
    let current = LockIsolated<String?>(initial)
    return AppIconClient(
      catalog: { catalog },
      current: { current.value },
      set: { name in current.setValue(name) }
    )
  }
}

public extension DependencyValues {
  var appIcon: AppIconClient {
    get { self[AppIconClient.self] }
    set { self[AppIconClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

// `UIApplication` is iOS-only; the package is also built/tested on macOS via `swift test`,
// so the live wrapper is compiled in only where UIKit exists. Elsewhere `liveValue` falls
// back to the in-memory double.
#if canImport(UIKit)
  import UIKit

  extension AppIconClient {
    public static var liveValue: AppIconClient {
      AppIconClient(
        catalog: { AppIconCatalog.parse(infoDictionary: Bundle.main.infoDictionary ?? [:]) },
        current: { await MainActor.run { UIApplication.shared.alternateIconName } },
        set: { name in try await applyAlternateIcon(name) }
      )
    }

    @MainActor
    private static func applyAlternateIcon(_ name: String?) async throws {
      try await UIApplication.shared.setAlternateIconName(name)
    }
  }
#else
  extension AppIconClient {
    /// No home-screen icon off-device (macOS `swift test`): the in-memory double.
    public static var liveValue: AppIconClient { testValue }
  }
#endif
