import Foundation

// MARK: - Pure transcript scroll/anchor math (platform-independent, unit-testable)

/// Pure scroll/anchor math shared by both transcript rendering engines (the SwiftUI
/// `ScrollView` engine and the `UICollectionView` engine). Foundation-only — no UIKit — so the
/// threshold/anchor logic is platform-independent, lives in `HermesKit` (logic, not views), and
/// is directly unit-testable via `swift test`. Keeping the numbers here is what makes the two
/// renderers agree on the at-bottom contract.
public enum TranscriptScrollMath {
  /// Distance from the bottom (in points) that still counts as "pinned" — both renderers read
  /// this single constant so they agree on the at-bottom contract.
  public static let bottomThreshold: CGFloat = 60

  /// Distance from the *top* (in points) at which scrolling up triggers a load-older page.
  /// Distinct from `bottomThreshold` even though they currently share a value: the top
  /// load-older trigger distance is conceptually independent of the bottom pin tolerance.
  public static let loadOlderTopThreshold: CGFloat = 60

  /// Given the content's full height, the visible viewport height, the bottom inset, and the
  /// current vertical offset, decide whether the viewport is pinned to the bottom edge.
  /// `≤ threshold` of remaining scroll distance below the viewport ⇒ pinned to the latest row.
  public static func isPinnedToBottom(
    contentHeight: CGFloat,
    viewportHeight: CGFloat,
    bottomInset: CGFloat,
    offsetY: CGFloat,
    threshold: CGFloat = bottomThreshold
  ) -> Bool {
    let distanceFromBottom = contentHeight + bottomInset - (offsetY + viewportHeight)
    return distanceFromBottom <= threshold
  }

  /// The maximum legal vertical content offset for a scroll view (clamped at 0 so short
  /// transcripts that don't fill the viewport never produce a negative offset).
  public static func maxOffsetY(
    contentHeight: CGFloat,
    viewportHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
  ) -> CGFloat {
    max(-topInset, contentHeight + bottomInset - viewportHeight)
  }

  /// Offset-preservation across a prepend: when older rows are inserted at the top, the
  /// content grows by `insertedHeight`, so to keep the on-screen anchor row visually fixed we
  /// shift the offset down by exactly that delta. Returns the new offset (clamped to legal).
  public static func offsetAfterPrepend(
    previousOffsetY: CGFloat,
    insertedHeight: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
  ) -> CGFloat {
    let target = previousOffsetY + insertedHeight
    let maxY = maxOffsetY(
      contentHeight: contentHeight,
      viewportHeight: viewportHeight,
      topInset: topInset,
      bottomInset: bottomInset
    )
    return min(max(target, -topInset), maxY)
  }
}

/// Detect whether a `rows` update is a *prepend* (older page loaded at the top), an
/// append/in-place mutation (streaming / new turn), or a *reset* (a wholesale replacement of
/// the visible slice, e.g. a server-authoritative re-hydrate). A prepend requires offset
/// preservation; a reset forces a jump-to-bottom (the open/hydrate contract); everything else
/// follows the pin rule. Pure over the row id sequences so it is testable.
public enum TranscriptDiffKind: Equatable, Sendable {
  /// Older rows were inserted before the previously-first row (load-older).
  case prepend(insertedCount: Int)
  /// Newer rows appended at the bottom and/or trailing rows mutated in place (streaming / a new
  /// turn). The old sequence is a *contiguous prefix* of the new one (or the sequence is
  /// unchanged in length and only content mutated) — the natural follow-the-bottom case.
  case appendOrMutate
  /// No structural change to the id sequence (pure content mutation, e.g. a delta).
  case inPlace
  /// A wholesale replacement of the visible slice: the old sequence is neither a contiguous
  /// prefix (append) nor suffix (prepend) of the new one — a server-authoritative re-hydrate
  /// (`session.resume` rebuilds rows wholesale) or a reorder. Per the open/hydrate contract the
  /// renderer must force a jump-to-bottom on a reset, regardless of pin state.
  case reset

  /// Classify the transition from `old` row ids to `new` row ids.
  public static func classify(old: [ChatRow.ID], new: [ChatRow.ID]) -> TranscriptDiffKind {
    guard !old.isEmpty else {
      // First population (empty → rows): treat as a reset so the renderer performs the
      // open-at-bottom jump. (Both renderers also guard this via their first-population flag.)
      return new.isEmpty ? .inPlace : .reset
    }
    if new == old { return .inPlace }
    // Prepend: the old sequence still appears as a *contiguous suffix* of the new one and the
    // new sequence is strictly longer (older rows added in front of the prior first row). The
    // suffix-match is the authoritative signal — we deliberately do NOT additionally require
    // `new.first != old.first`, because a prepend whose inserted rows happen to start with the
    // old first id is still a prepend (counts grew, suffix preserved) and must not be
    // misclassified as an append.
    if new.count > old.count, Array(new.suffix(old.count)) == old {
      return .prepend(insertedCount: new.count - old.count)
    }
    // Append / in-place mutation: the old sequence is a *contiguous prefix* of the new one
    // (rows appended at the bottom; trailing cells may have mutated content under stable ids).
    if new.count >= old.count, Array(new.prefix(old.count)) == old {
      return .appendOrMutate
    }
    // Neither a prefix nor a suffix relationship: a wholesale replace / reorder ⇒ reset.
    return .reset
  }
}
