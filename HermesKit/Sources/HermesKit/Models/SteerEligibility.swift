import Foundation

/// Whether a queued entry can be steered into the running turn (desktop `isSteerableEntry`,
/// `apps/desktop/src/store/composer-queue.ts`): text only (`session.steer` carries
/// `params.text` and nothing else), non-empty after trimming (the RPC answers 4002 for an
/// empty `text`), and not a slash command (commands execute, they don't steer). Pure, so the
/// panel and the reducer agree. Whether a turn is running to receive it is reducer state
/// (`ChatFeature.State.canSteerQueued`), kept out of here on purpose.
public enum SteerEligibility {
  public static func isSteerable(_ entry: QueuedPrompt) -> Bool {
    guard entry.attachments.isEmpty else { return false }
    guard let text = entry.text.trimmedNonEmpty else { return false }
    return !SlashSuggestionFilter.isCommandShaped(text)
  }
}

/// What a `session.steer` round-trip means for the queued entry it carried.
public enum SteerOutcome: Equatable, Sendable {
  /// `status: "queued"`: the agent took the text into the live turn (or, during compression,
  /// into the server's next-turn slot). The entry leaves the queue.
  case accepted
  /// Anything that did not deliver: `rejected` (the session went idle), `voice_stopped`, a
  /// missing or unknown status, or a stale live id with no stored id to resume. The entry
  /// stays queued for the ordinary drain.
  case undelivered
  /// `-32601` or 4010: this agent can't steer. The entry stays queued; the action hides.
  case unsupported
  /// Any other failure (transport, server error, a failed resume). The entry stays queued.
  case failed(GatewayError)

  /// The outcome of a `session.steer` result. Only `status == "queued"` is acceptance — the
  /// gateway's `CorrectionStatus` for steer is `queued | rejected`.
  public init(result: JSONValue) {
    self = result["status"]?.stringValue == "queued" ? .accepted : .undelivered
  }

  /// The outcome of a thrown `session.steer`.
  public init(error: GatewayError) {
    self = error.isUnknownMethod || error.isSteerUnsupported ? .unsupported : .failed(error)
  }
}
