import Foundation

/// A request to open the app on something specific, raised from outside it by an App Intent
/// (Shortcuts, Siri, Spotlight, the Action button — #93). The intents in the app target only
/// route: `perform()` hands one of these to `LaunchIntentBridge.shared`, and `AppFeature`
/// turns it into the same "New session" handling the list's button runs.
public enum LaunchIntent: Equatable, Sendable {
  /// Open a fresh chat under the selected profile.
  case newChat
  /// Open a fresh chat and start the mic as soon as it opens (one-shot, only from idle).
  case newChatWithDictation
}

extension LaunchIntent {
  /// `UIApplicationShortcutItemType` of the Home Screen quick actions. These must match the
  /// static `UIApplicationShortcutItems` in `Project.swift`, which can't import this package.
  public static let newChatShortcutType = "me.honcharenko.HermesMobile.new-chat"
  public static let dictateShortcutType = "me.honcharenko.HermesMobile.dictate"

  /// The intent a tapped Home Screen quick action requests; `nil` for an unknown type.
  public init?(shortcutItemType: String) {
    switch shortcutItemType {
    case Self.newChatShortcutType: self = .newChat
    case Self.dictateShortcutType: self = .newChatWithDictation
    default: return nil
    }
  }
}
