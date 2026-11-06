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
