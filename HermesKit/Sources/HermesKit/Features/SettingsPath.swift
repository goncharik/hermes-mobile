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
