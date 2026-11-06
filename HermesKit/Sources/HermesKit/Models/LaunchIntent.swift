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
  /// `UIApplicationShortcutItemType` of the Home Screen quick actions. They are dynamic items
  /// set by `QuickActionsClient` (shown only while signed in), never static Info.plist entries.
  public static let newChatShortcutType = "me.honcharenko.HermesMobile.new-chat"
  public static let dictateShortcutType = "me.honcharenko.HermesMobile.dictate"

  /// The Home Screen quick actions, in menu order.
  public static let quickActions: [LaunchIntent] = [.newChat, .newChatWithDictation]

  /// The intent a tapped Home Screen quick action requests; `nil` for an unknown type.
  public init?(shortcutItemType: String) {
    switch shortcutItemType {
    case Self.newChatShortcutType: self = .newChat
    case Self.dictateShortcutType: self = .newChatWithDictation
    default: return nil
    }
  }

  /// The quick action's `UIApplicationShortcutItemType`.
  public var shortcutItemType: String {
    switch self {
    case .newChat: Self.newChatShortcutType
    case .newChatWithDictation: Self.dictateShortcutType
    }
  }

  /// The quick action's title, matching the App Shortcut short titles.
  public var shortcutTitle: String {
    switch self {
    case .newChat: "New Chat"
    case .newChatWithDictation: "Dictate"
    }
  }

  /// The quick action's SF Symbol, matching the App Shortcut symbols.
  public var shortcutSymbolName: String {
    switch self {
    case .newChat: "plus.message"
    case .newChatWithDictation: "mic.badge.plus"
    }
  }
}
