import HermesKit
import os
import UIKit
import UserNotifications

/// App-delegate bridge for push notifications (#push C2) and Home Screen Quick Actions
/// (#93). Converts UIKit / `UNUserNotificationCenter` callbacks into bridge calls and
/// nothing more — **no business logic lives here**. All decisions belong to reducers and
/// clients downstream of the streams the bridges feed.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  private static let log = Logger(subsystem: "me.honcharenko.HermesMobile", category: "push")

  /// Must stay byte-identical to the static `UIApplicationShortcutItems` types in
  /// `Project.swift`. Unknown types are rejected rather than guessed.
  private enum QuickActionType {
    static let newSession = "me.honcharenko.HermesMobile.new-session"
    static let dictate = "me.honcharenko.HermesMobile.dictate"
  }

  func application(
    _: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // Cold launch from a Home Screen Quick Action arrives here before the SwiftUI store's
    // `.task` observer subscribes. IntentBridge buffers it consume-once. Return false so
    // UIKit does not deliver the same action again through `performActionFor`.
    if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
      _ = routeQuickAction(item)
      return false
    }
    return true
  }

  // MARK: - Home Screen Quick Actions

  /// Warm/resumed launch from the app-icon long-press menu. The completion value tells
  /// UIKit whether this app recognizes the declared action.
  func application(
    _: UIApplication,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(routeQuickAction(shortcutItem))
  }

  private func routeQuickAction(_ item: UIApplicationShortcutItem) -> Bool {
    switch item.type {
    case QuickActionType.newSession:
      IntentBridge.shared.received(.startNewSession)
    case QuickActionType.dictate:
      IntentBridge.shared.received(.startNewSessionWithDictation)
    default:
      return false
    }
    return true
  }

  // MARK: - Remote-notification registration

  func application(
    _: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushBridge.shared.tokenReceived(deviceToken)
  }

  func application(
    _: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// User tapped a notification → forward the `session_id` for deep-linking.
  func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    PushBridge.shared.tapReceived(response.notification.request.content.userInfo)
    completionHandler()
  }

  /// A notification arrived while the app is foregrounded. Nav-aware suppression (C5): if the
  /// user is already viewing the push's session we present nothing (the chat already shows the
  /// state); otherwise a banner + sound. The decision is the pure
  /// `PushClient.shouldPresentForeground`, called via the bridge that holds the current session
  /// id — the delegate carries no logic.
  func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let payload = notification.request.content.userInfo
    let present = PushBridge.shared.shouldPresentForeground(for: payload)
    completionHandler(present ? [.banner, .sound] : [])
  }
}
