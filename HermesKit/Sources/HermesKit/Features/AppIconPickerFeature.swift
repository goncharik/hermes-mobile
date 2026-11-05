import ComposableArchitecture
import Foundation

/// The Settings → App Icon screen: a grid of the icons this build can switch between, with
/// the current one checked. Seeded by `SettingsFeature` with the catalog and current icon it
/// already loaded.
///
/// A tap is **optimistic** — the checkmark moves at once, then `appIcon.set` runs. One change
/// at a time: a tap while `isApplying` is ignored (cancelling the effect would not stop the
/// UIKit change already under way). A refusal re-reads `appIcon.current()` and shows THAT —
/// what iOS actually has — and raises `errorBanner`. Every outcome reports the resulting icon
/// to the parent (`delegate(.iconChanged)`), so the Settings row follows iOS, not a guess.
/// iOS persists the choice itself; nothing here touches `PreferencesClient`, so logout leaves
/// the icon alone.
///
/// `selected == nil` means the build's primary icon (`alternateIconName == nil`): picking the
/// primary tile is `set(nil)`, never the primary's alternate twin (see `AppIconCatalog`).
@Reducer
public struct AppIconPickerFeature {
  @ObservableState
  public struct State: Equatable {
    /// The icons on offer — seeded by the parent from `appIcon.catalog()`.
    public var catalog: AppIconCatalog
    /// The checked icon's set name; `nil` is the build's primary icon.
    public var selected: String?
    /// The last `set` failure, shown under the grid; cleared by the next tap.
    public var errorBanner: String?
    /// A `set` is in flight; taps are ignored until it settles.
    public var isApplying: Bool

    public init(
      catalog: AppIconCatalog = .empty,
      selected: String? = nil,
      errorBanner: String? = nil,
      isApplying: Bool = false
    ) {
      self.catalog = catalog
      self.selected = selected
      self.errorBanner = errorBanner
      self.isApplying = isApplying
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
    /// A tile was tapped; `nil` is the primary icon.
    case iconTapped(String?)
    /// iOS accepted the change to this icon.
    case setSucceeded(String?)
    /// iOS refused the change; `current` is what `appIcon.current()` reads afterwards.
    case setFailed(current: String?)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// The icon iOS has after a change attempt; `nil` is the primary icon.
      case iconChanged(String?)
    }
  }

  public static let setFailedBanner = "Couldn’t change the app icon. Try again."

  @Dependency(\.appIcon) var appIcon

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .iconTapped(name):
        guard !state.isApplying, name != state.selected else { return .none }
        state.selected = name
        state.errorBanner = nil
        state.isApplying = true
        return .run { [appIcon] send in
          do {
            try await appIcon.set(name)
            await send(.setSucceeded(name))
          } catch {
            await send(.setFailed(current: await appIcon.current()))
          }
        }

      case let .setSucceeded(name):
        state.isApplying = false
        return .send(.delegate(.iconChanged(name)))

      case let .setFailed(current):
        state.isApplying = false
        state.selected = current
        state.errorBanner = Self.setFailedBanner
        return .send(.delegate(.iconChanged(current)))

      case .delegate:
        return .none
      }
    }
  }
}
