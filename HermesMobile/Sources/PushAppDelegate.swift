import HermesKit
import os
import UIKit
import UserNotifications

/// App-delegate bridge for push notifications (#push C2). Converts UIKit /
/// `UNUserNotificationCenter` callbacks into `PushBridge` calls and nothing more —
/// **no business logic lives here**. All decisions (registration, deep-link, suppression,
/// badging) belong to reducers/clients downstream of the streams `PushBridge` feeds.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  private static let log = Logger(subsystem: "me.honcharenko.HermesMobile", category: "push")

  func application(
    _: UIApplication,
    didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  /// Attach `QuickActionSceneDelegate` so Home Screen quick actions (#93) reach the app —
  /// UIKit hands them to the scene delegate only. SwiftUI keeps managing the window.
  func application(
    _: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options _: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = QuickActionSceneDelegate.self
    return configuration
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
