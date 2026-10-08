import Foundation

/// Whether a queued entry can be delivered into a RUNNING turn as a mid-turn correction
/// (desktop's "Steer now").
///
/// Desktop's rule (`apps/desktop/src/store/composer-queue.ts` → `isSteerableEntry`) is the
/// contract this mirrors, so the two clients agree on what a steer can carry:
///
/// - **text only** — a steer rides into the live turn as an injected correction; the
///   gateway's `session.steer` takes `params.text` and nothing else, so attached images/PDFs
///   cannot ride one and must go through the ordinary queue instead;
/// - **non-empty after trimming** — the RPC rejects an empty `text` with 4002;
/// - **not a slash command** — slash commands EXECUTE (their own pipeline, their own worker),
///   they do not steer a running turn.
///
/// A pure function so the view's menu affordance and the reducer's authoritative gate can
/// never disagree, and so the rule is unit-testable without a reducer.
public enum SteerEligibility {
  /// Can `entry` be steered into the live turn?
  ///
  /// Note this deliberately takes no view of whether a turn is running: "is there a turn to
  /// steer into" is reducer state (`isSending`), and combining the two here would hide the
  /// distinction between an unsteerable entry and a momentarily idle session — which are
  /// different failure modes and get different handling (the former never offers the action,
  /// the latter keeps the entry queued).
  public static func isSteerable(_ entry: QueuedPrompt) -> Bool {
    guard entry.attachments.isEmpty else { return false }
    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    return !SlashSuggestionFilter.isCommandShaped(text)
  }

  /// Whether the steer affordance should be offered for `entry` right now: it must be
  /// steerable AND there must be a live turn to receive it.
  public static func canSteerNow(_ entry: QueuedPrompt, isTurnRunning: Bool) -> Bool {
    isTurnRunning && isSteerable(entry)
  }

  /// Why a steer is unavailable, for a menu that wants to explain itself rather than just
  /// disable. `nil` when the entry IS steerable (regardless of turn state).
  public static func unsteerableReason(_ entry: QueuedPrompt) -> String? {
    if !entry.attachments.isEmpty {
      return "Attachments can't be steered into a running turn — they'll send when it finishes."
    }
    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      return "Nothing to steer."
    }
    if SlashSuggestionFilter.isCommandShaped(text) {
      return "Commands run on their own — they'll send when the turn finishes."
    }
    return nil
  }
}
