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
/// append/in-place mutation (streaming / new turn / live-turn reorder), or a *reset* (a genuine
/// wholesale replacement of the visible slice, e.g. a server-authoritative re-hydrate). A prepend
/// requires offset preservation; a reset forces a jump-to-bottom (the open/hydrate contract);
/// everything else follows the pin rule. Pure over the row id sequences so it is testable.
public enum TranscriptDiffKind: Equatable, Sendable {
  /// Older rows were inserted before the previously-first row (load-older).
  case prepend(insertedCount: Int)
  /// Newer rows appended at the bottom, trailing rows mutated in place, or the same logical rows
  /// reordered/inserted-in-the-middle (a live-turn `keepThinkingLast` reorder). The follow-the-
  /// bottom case: follow only if pinned, **never yank a scrolled-up reader** (the no-yank
  /// contract). Crucially this — NOT `.reset` — is what a live-turn reorder maps to, so a user
  /// who scrolled up mid-turn is not yanked back to the bottom.
  case appendOrMutate
  /// No structural change to the id sequence (pure content mutation, e.g. a delta).
  case inPlace
  /// A *genuine* wholesale replacement of the visible slice: the new id sequence is neither a
  /// reordering nor a superset of the old one — the old rows were largely replaced by different
  /// ids, which is what `reconstructTranscript` produces (fresh deterministic ids) only when the
  /// underlying messages actually changed (a server-authoritative re-hydrate via `session.resume`,
  /// or first population). Per the open/hydrate contract the renderer must force a jump-to-bottom
  /// on a reset, regardless of pin state. A live-turn reorder is explicitly NOT a reset.
  case reset

  /// Classify the transition from `old` row ids to `new` row ids.
  ///
  /// The ordering of the checks below is deliberate. We must distinguish a live-turn reorder
  /// (the `keepThinkingLast` insert-then-move-thinking-to-the-end pattern — which is neither a
  /// contiguous prefix nor suffix match, yet preserves all the old logical rows) from a genuine
  /// hydrate (`reconstructTranscript` mints fresh ids when the messages changed, so the old ids
  /// largely disappear). `.reset` is therefore reserved for the case where the new sequence is
  /// NOT a reordering of the old set and NOT a superset of the old ids — i.e. the old rows were
  /// actually replaced, not merely shuffled or added to.
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
    // Neither a contiguous prefix nor suffix — but it may still be a live-turn reorder rather
    // than a wholesale replace. Two non-reset shapes (both preserve the old logical rows, so a
    // scrolled-up reader must NOT be yanked):
    //   1. A permutation: the new and old id sets are the same multiset (e.g. `keepThinkingLast`
    //      moving the thinking row to the end with no row added).
    //   2. A superset: every old id survives in the new sequence (the usual live-turn case where
    //      a tool/answer row is inserted *above* the thinking row, then thinking is moved last —
    //      counts grow and the insert lands in the middle, so it's neither prefix nor suffix).
    // Only when neither holds — the old ids were largely replaced by different ids — is this a
    // genuine hydrate/wholesale reset.
    let oldSet = Set(old)
    let newSet = Set(new)
    if newSet == oldSet { return .appendOrMutate }       // permutation / reorder
    if oldSet.isSubset(of: newSet) { return .appendOrMutate } // superset: old rows preserved
    // The old rows were largely replaced by different ids ⇒ genuine wholesale reset.
    return .reset
  }
}
