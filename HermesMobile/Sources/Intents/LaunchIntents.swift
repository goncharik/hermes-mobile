import AppIntents
import HermesKit

// App Intents that open the app on a fresh chat from outside it (#93): Shortcuts, Siri,
// Spotlight and the Action button, all surfaced by `HermesAppShortcuts`.
//
// Both are `openAppWhenRun` and only ROUTE: `perform()` hands the request to
// `LaunchIntentBridge`, which `AppFeature` observes (`launchIntentReceived`). No agent logic
// runs in the intent. The bridge buffers an intent that races the store's `.task` observer on
// a cold launch, and `AppFeature` stashes it until `home` exists, so nothing is dropped.

/// Open the app on a fresh chat under the selected profile.
struct StartNewSessionIntent: AppIntent {
  static let title: LocalizedStringResource = "New Hermes chat"
  static let description = IntentDescription(
    "Open Hermes on a fresh chat.",
    categoryName: "Chats"
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    LaunchIntentBridge.shared.received(.newChat)
    return .result()
  }
}

/// Open the app on a fresh chat and start dictation once it opens. A denied mic permission
/// shows the app's existing banner through the normal recording flow; the intent never fails.
struct StartNewSessionWithDictationIntent: AppIntent {
  static let title: LocalizedStringResource = "Dictate to Hermes"
  static let description = IntentDescription(
    "Open Hermes on a fresh chat and start dictation.",
    categoryName: "Chats"
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    LaunchIntentBridge.shared.received(.newChatWithDictation)
    return .result()
  }
}
