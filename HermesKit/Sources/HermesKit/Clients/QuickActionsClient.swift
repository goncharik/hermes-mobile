import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Sets the Home Screen quick actions (#93). They are dynamic `UIApplication.shortcutItems`
/// rather than static Info.plist entries so they can be hidden while signed out: `AppFeature`
/// sets `LaunchIntent.quickActions` once a stored session exists and an empty list when the
/// app falls back to onboarding. iOS persists the items across launches, so they stay on the
/// icon while the app is killed.
@DependencyClient
public struct QuickActionsClient: Sendable {
  /// Replaces the quick actions with `intents` (empty hides them all).
  /// SYNCHRONOUS for the same reason as `IdleTimerClient.setDisabled`: the live value applies
  /// calls in reduction order (one FIFO main-queue hop each), so a sign-in followed quickly by
  /// a sign-out can't land in the wrong order the way two `Effect.run`s could.
  public var setItems: @Sendable (_ intents: [LaunchIntent]) -> Void
}

extension QuickActionsClient: DependencyKey {
  /// No-op double. Override `setItems` with a recorder to assert the transitions.
  public static var testValue: QuickActionsClient {
    QuickActionsClient(setItems: { _ in })
  }
}

public extension DependencyValues {
  var quickActions: QuickActionsClient {
    get { self[QuickActionsClient.self] }
    set { self[QuickActionsClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

#if canImport(UIKit)
  import UIKit

  extension QuickActionsClient {
    public static var liveValue: QuickActionsClient {
      QuickActionsClient(setItems: { intents in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            UIApplication.shared.shortcutItems = intents.map { intent in
              UIApplicationShortcutItem(
                type: intent.shortcutItemType,
                localizedTitle: intent.shortcutTitle,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: intent.shortcutSymbolName)
              )
            }
          }
        }
      })
    }
  }
#else
  extension QuickActionsClient {
    /// No Home Screen off-device (macOS `swift test`): the no-op double.
    public static var liveValue: QuickActionsClient { testValue }
  }
#endif
