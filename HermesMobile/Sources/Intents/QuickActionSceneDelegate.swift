import HermesKit
import UIKit

/// Receives Home Screen quick-action taps (#93). The app is scene-based, so UIKit delivers
/// them to the scene delegate, never the app delegate: `connectionOptions.shortcutItem` on a
/// cold launch, `windowScene(_:performActionFor:)` while running. Both only hand the mapped
/// `LaunchIntent` to `LaunchIntentBridge`, which buffers it until `AppFeature` subscribes.
/// SwiftUI still owns the window; this class adds no state.
final class QuickActionSceneDelegate: UIResponder, UIWindowSceneDelegate {
  func scene(
    _: UIScene,
    willConnectTo _: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let item = connectionOptions.shortcutItem {
      Self.route(item)
    }
  }

  func windowScene(
    _: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(Self.route(shortcutItem))
  }

  @discardableResult
  private static func route(_ item: UIApplicationShortcutItem) -> Bool {
    guard let intent = LaunchIntent(shortcutItemType: item.type) else { return false }
    LaunchIntentBridge.shared.received(intent)
    return true
  }
}
