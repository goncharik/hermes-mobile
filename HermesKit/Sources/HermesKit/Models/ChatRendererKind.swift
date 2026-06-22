import Foundation

/// Which transcript rendering engine the chat screen uses. A device-local preference
/// (persisted in `PreferencesClient`) so the two interchangeable renderers can be A/B'd
/// on identical chats:
/// - `.collectionView` — UIKit `UICollectionView` engine (Renderer A), the default.
/// - `.swiftUI` — pure-SwiftUI `ScrollView` + `LazyVStack` engine (Renderer C).
///
/// Not identity-scoped — it is **not** cleared on logout.
public enum ChatRendererKind: String, Sendable, CaseIterable, Equatable {
  case collectionView
  case swiftUI

  /// Default when nothing is persisted yet.
  public static let `default`: ChatRendererKind = .collectionView

  /// Human-readable label for the Settings picker.
  public var displayName: String {
    switch self {
    case .collectionView: "UICollectionView"
    case .swiftUI: "SwiftUI"
    }
  }
}
