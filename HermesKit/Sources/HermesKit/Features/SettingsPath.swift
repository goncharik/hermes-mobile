import ComposableArchitecture
import Foundation

/// The Settings sheet's navigation stack: the three rows that push a sub-screen. Top-level
/// (not nested in `SettingsFeature`) per the TCA stack idiom; `SettingsFeature` appends an
/// element in the reducer so every push is a `TestStore` assertion, and `SettingsView` owns
/// the `NavigationStack` that renders it.
@Reducer
public enum SettingsPath {
  case acknowledgements(AcknowledgementsFeature)
  case appIcon(AppIconPickerFeature)
  case diagnostics(DiagnosticsFeature)
}

extension SettingsPath.State: Equatable {}

/// Settings → Acknowledgements: a static list of the open-source packages the app ships.
/// Nothing to reduce — the screen renders `Acknowledgement.all`.
@Reducer
public struct AcknowledgementsFeature {
  @ObservableState
  public struct State: Equatable {
    public init() {}
  }

  public enum Action: Equatable, Sendable {}

  public init() {}

  public var body: some ReducerOf<Self> {
    EmptyReducer()
  }
}

/// One open-source package the app ships at runtime (HermesKit's `Package.swift`
/// dependencies — test-only packages are not listed).
public struct Acknowledgement: Equatable, Hashable, Identifiable, Sendable {
  public let name: String
  public let url: URL
  public let license: String

  public var id: String { name }

  public init(name: String, url: URL, license: String) {
    self.name = name
    self.url = url
    self.license = license
  }

  /// Every runtime dependency, alphabetical by display name.
  public static let all: [Acknowledgement] = [
    Acknowledgement(
      name: "GRDB.swift",
      url: URL(string: "https://github.com/groue/GRDB.swift")!,
      license: "MIT"
    ),
    Acknowledgement(
      name: "swift-composable-architecture",
      url: URL(string: "https://github.com/pointfreeco/swift-composable-architecture")!,
      license: "MIT"
    ),
    Acknowledgement(
      name: "swift-dependencies",
      url: URL(string: "https://github.com/pointfreeco/swift-dependencies")!,
      license: "MIT"
    ),
  ]
}
