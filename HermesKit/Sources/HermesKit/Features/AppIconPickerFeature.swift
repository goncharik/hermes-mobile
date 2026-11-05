import ComposableArchitecture
import Foundation

/// The Settings → App Icon screen: a grid of the icons this build can switch between, with
/// the current one checked.
///
/// A tap is **optimistic** — the checkmark moves at once, then `appIcon.set` runs; a refusal
/// from iOS rolls the checkmark back to the previous icon and raises `errorBanner` (the
/// project's optimistic-then-rollback idiom, as in the model picker). Only a CONFIRMED change
/// reaches the parent (`delegate(.iconChanged)`), so the Settings row value never shows an
/// icon iOS refused. iOS persists the choice itself; nothing here touches `PreferencesClient`,
/// so logout leaves the icon alone.
///
/// `selected == nil` means the build's primary icon (`alternateIconName == nil`): picking the
/// primary tile is `set(nil)`, never the primary's alternate twin (see `AppIconCatalog`).
@Reducer
public struct AppIconPickerFeature {
  @ObservableState
  public struct State: Equatable {
    /// The icons on offer — seeded by `.task` from `appIcon.catalog()`.
    public var catalog: AppIconCatalog
    /// The checked icon's set name; `nil` is the build's primary icon.
    public var selected: String?
    /// The last `set` failure, shown under the grid; cleared by the next tap.
    public var errorBanner: String?

    public init(
      catalog: AppIconCatalog = .empty,
      selected: String? = nil,
      errorBanner: String? = nil
    ) {
      self.catalog = catalog
      self.selected = selected
      self.errorBanner = errorBanner
    }

    /// Whether a tile is the checked one. The primary tile is checked when `selected == nil`
    /// (and, defensively, when `selected` names the primary set itself).
    public func isSelected(_ option: AppIconOption) -> Bool {
      if option == catalog.primary { return selected == nil || selected == option.name }
      return selected == option.name
    }

    /// The `alternateIconName` value a tile maps to: `nil` for the primary, else its name.
    public func iconName(for option: AppIconOption) -> String? {
      option == catalog.primary ? nil : option.name
    }
  }

  public enum Action: Equatable, Sendable {
    /// The screen appeared — load the catalog and the current icon.
    case task
    case loaded(catalog: AppIconCatalog, current: String?)
    /// A tile was tapped; `nil` is the primary icon.
    case iconTapped(String?)
    /// iOS refused the change — restore `previous` and raise the banner.
    case setFailed(previous: String?)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// iOS accepted the change; `nil` is the primary icon.
      case iconChanged(String?)
    }
  }

  static let setFailedBanner = "Couldn’t change the app icon. Try again."

  /// One icon change in flight: a newer tap supersedes an older one so the last tap wins
  /// (a superseded effect's sends are dropped — no stale rollback or delegate lands).
  private enum CancelID { case set }

  @Dependency(\.appIcon) var appIcon

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { [appIcon] send in
          let catalog = appIcon.catalog()
          let current = await appIcon.current()
          await send(.loaded(catalog: catalog, current: current))
        }

      case let .loaded(catalog, current):
        state.catalog = catalog
        state.selected = current
        return .none

      case let .iconTapped(name):
        guard name != state.selected else { return .none }
        let previous = state.selected
        state.selected = name
        state.errorBanner = nil
        return .run { [appIcon] send in
          do {
            try await appIcon.set(name)
            await send(.delegate(.iconChanged(name)))
          } catch {
            await send(.setFailed(previous: previous))
          }
        }
        .cancellable(id: CancelID.set, cancelInFlight: true)

      case let .setFailed(previous):
        state.selected = previous
        state.errorBanner = Self.setFailedBanner
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
