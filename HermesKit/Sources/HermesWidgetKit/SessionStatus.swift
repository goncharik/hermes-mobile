import Foundation

/// The one state a card's leading status dot paints, mirroring the desktop's
/// `SessionDotState` for the states mobile can know: a pending approval or clarify, a running
/// turn, finished-while-away, or nothing. The desktop's stalled / background / draft states
/// need live socket events for every session, which the list does not have.
///
/// Lives in `HermesWidgetKit` (Foundation-only) so the widget extension can decode it from the
/// App Group mirror; `HermesKit` re-exports it.
public enum SessionStatus: String, Codable, Equatable, Sendable {
  /// An approval or clarify is blocking the turn — the one state that asks the user to act.
  case needsInput
  /// A turn is running.
  case working
  /// New activity since the user last opened the session.
  case unread
  /// Nothing to report.
  case idle

  /// Resolves the flags to one state, highest priority first (desktop order: needs-input
  /// over working over unread).
  public init(needsInput: Bool, isWorking: Bool, isUnread: Bool) {
    if needsInput {
      self = .needsInput
    } else if isWorking {
      self = .working
    } else if isUnread {
      self = .unread
    } else {
      self = .idle
    }
  }

  /// What VoiceOver says for the dot; idle says nothing.
  public var accessibilityText: String? {
    switch self {
    case .needsInput: "Needs input"
    case .working: "Working"
    case .unread: "Unread"
    case .idle: nil
    }
  }
}
