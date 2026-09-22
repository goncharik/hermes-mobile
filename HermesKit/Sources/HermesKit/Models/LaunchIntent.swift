import Foundation

/// A launch intent fired from *outside* the app — Quick Actions (home-screen long press),
/// Shortcuts / Siri, Spotlight, or the Action button — that requests a specific entry
/// point (#93). Intents only ROUTE: no agent logic runs from them (thin-client rule —
/// the socket only lives in the foreground). The bridge carries the request into the
/// reducer, which does the real work.
public enum LaunchIntent: Equatable, Sendable {
  /// Open the app on a fresh chat under the currently-selected profile.
  case startNewSession
  /// Same, then immediately start voice input (mic → transcribe into the composer).
  case startNewSessionWithDictation
  // `startVoiceConversation` joins here with #92 (hands-free voice conversation), which
  // itself depends on #74 (TTS playback of replies).
}

/// A chat-level voice action armed by a launch intent, consumed once the chat's slot
/// reaches `.ready` (so a recording never fires into a still-bootstrapping chat).
public enum InitialVoiceAction: Equatable, Sendable {
  case startDictation
}
