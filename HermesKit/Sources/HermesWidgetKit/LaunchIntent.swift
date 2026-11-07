import Foundation

/// A request to open the app on something specific, raised from outside it: an App Intent
/// (Shortcuts, Siri, Spotlight, the Action button — #93), a Home Screen quick action, or a
/// widget / control / Live Activity tap (`WidgetDeepLink`). Whatever raises it only routes:
/// it hands one of these to `LaunchIntentBridge.shared`, and `AppFeature` turns it into the
/// same "New session" handling the list's button runs, or the push-tap open of a session.
public enum LaunchIntent: Equatable, Sendable {
  /// Open a fresh chat under the selected profile.
  case newChat
  /// Open a fresh chat and start the mic as soon as it opens (one-shot, only from idle).
  case newChatWithDictation
  /// Open a fresh chat and raise the camera picker as soon as it opens (one-shot).
  case newChatWithCamera
  /// Open a fresh chat and raise the photo picker as soon as it opens (one-shot).
  case newChatWithPhotos
  /// Open an existing session, routed like a push tap (#32). `profile` is the profile the
  /// session belongs to (`nil` when the server has no profiles API); it scopes the resume and
  /// never changes the selected profile.
  case openSession(id: String, profile: String?)

  /// The one-shot action a fresh chat runs once it opens; `nil` for a plain new chat and for
  /// opening an existing session.
  public var launchAction: LaunchAction? {
    switch self {
    case .newChatWithDictation: .dictation
    case .newChatWithCamera: .camera
    case .newChatWithPhotos: .photos
    case .newChat, .openSession: nil
    }
  }
}

extension LaunchIntent {
  /// `UIApplicationShortcutItemType` of the Home Screen quick actions. They are dynamic items
  /// set by `QuickActionsClient` (shown only while signed in), never static Info.plist entries.
  public static let newChatShortcutType = "me.honcharenko.HermesMobile.new-chat"
  public static let dictateShortcutType = "me.honcharenko.HermesMobile.dictate"

  /// The Home Screen quick actions, in menu order. The widget-only intents (camera, photos,
  /// open session) are deliberately not quick actions.
  public static let quickActions: [LaunchIntent] = [.newChat, .newChatWithDictation]

  /// The intent a tapped Home Screen quick action requests; `nil` for an unknown type. Only
  /// the `quickActions` types are accepted — the widget-only intents never arrive this way.
  public init?(shortcutItemType: String) {
    switch shortcutItemType {
    case Self.newChatShortcutType: self = .newChat
    case Self.dictateShortcutType: self = .newChatWithDictation
    default: return nil
    }
  }

  /// The quick action's `UIApplicationShortcutItemType`. The widget-only intents get distinct
  /// literals of their own (never published as quick actions, and not accepted by
  /// `init(shortcutItemType:)`) so the mapping stays total without colliding.
  public var shortcutItemType: String {
    switch self {
    case .newChat: Self.newChatShortcutType
    case .newChatWithDictation: Self.dictateShortcutType
    case .newChatWithCamera: "me.honcharenko.HermesMobile.new-chat-camera"
    case .newChatWithPhotos: "me.honcharenko.HermesMobile.new-chat-photos"
    case .openSession: "me.honcharenko.HermesMobile.open-session"
    }
  }

  /// The quick action's (and control's) title, matching the App Shortcut short titles.
  public var shortcutTitle: String {
    switch self {
    case .newChat: "New Chat"
    case .newChatWithDictation: "Dictate"
    case .newChatWithCamera: "Camera"
    case .newChatWithPhotos: "Photos"
    case .openSession: "Open Session"
    }
  }

  /// The quick action's (and control's) SF Symbol, matching the App Shortcut symbols.
  public var shortcutSymbolName: String {
    switch self {
    case .newChat: "plus.message"
    case .newChatWithDictation: "mic.badge.plus"
    case .newChatWithCamera: "camera"
    case .newChatWithPhotos: "photo.on.rectangle"
    case .openSession: "text.bubble"
    }
  }
}
