import AppIntents
import HermesKit

// App Intents exposing the app's entry points outside the app (#93): Shortcuts / Siri,
// Spotlight, and the Action button. Home Screen icon long-press Quick Actions are the
// separate UIKit path declared in Project.swift and routed by PushAppDelegate.
//
// All intents are `openAppWhenRun` and only ROUTE — they feed `IntentBridge`, which the
// reducer (`AppFeature.launchIntentReceived`) observes; no agent logic runs from the
// intent (thin-client rule: the socket only lives in the foreground). The bridge is the
// same consume-once pattern as the push-tap bridge (#46), so a launch-from-intent that
// races the store's `.task` observer is buffered, not dropped.

/// Open the app on a fresh chat under the currently-selected profile.
struct StartNewSessionIntent: AppIntent {
  static let title: LocalizedStringResource = "New Hermes chat"
  static let description = IntentDescription(
    "Open Hermes on a fresh chat.",
    categoryName: "Sessions"
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    IntentBridge.shared.received(.startNewSession)
    return .result()
  }
}

/// Open the app on a fresh chat, then immediately start voice input (mic → transcribe
/// into the composer). A denied mic permission surfaces the app's existing banner via the
/// normal `recordingPermission` flow — the intent itself never fails.
struct StartNewSessionWithDictationIntent: AppIntent {
  static let title: LocalizedStringResource = "Dictate to Hermes"
  static let description = IntentDescription(
    "Open Hermes on a fresh chat and start dictation.",
    categoryName: "New Hermes chat"
  )
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    IntentBridge.shared.received(.startNewSessionWithDictation)
    return .result()
  }
}

// The `StartVoiceConversationIntent` variant joins here with #92 (hands-free voice
// conversation mode), which depends on #74 (TTS playback).