import Foundation

/// Which transcript rendering engine the chat screen uses. A device-local preference
/// (persisted in `PreferencesClient`) so the two interchangeable renderers can be A/B'd
/// on identical chats:
/// - `.swiftUI` — the pure-SwiftUI `ScrollView` + `VStack` engine, the default.
/// - `.collectionView` — the UIKit `UICollectionView` engine.
///
/// Not identity-scoped — it is **not** cleared on logout.
public enum ChatRendererKind: String, Sendable, CaseIterable, Equatable {
  case collectionView
  case swiftUI

  /// Default when nothing is persisted yet.
  public static let `default`: ChatRendererKind = .swiftUI

  /// Human-readable label for the Settings picker.
  public var displayName: String {
    switch self {
    case .collectionView: "UICollectionView"
    case .swiftUI: "SwiftUI (default)"
    }
  }
}
