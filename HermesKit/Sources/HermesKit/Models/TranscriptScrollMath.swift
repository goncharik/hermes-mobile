import Foundation

// MARK: - Pure transcript scroll/anchor math (platform-independent, unit-testable)

/// Pure scroll/anchor math for the transcript renderer (`CollectionTranscriptView`).
/// Foundation-only — no UIKit — so the threshold/anchor logic is platform-independent, lives in
/// `HermesKit` (logic, not views), and is directly unit-testable via `swift test`.
public enum TranscriptScrollMath {
  /// Distance from the bottom (in points) that still counts as "pinned".
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

  /// The pin after a user-driven scroll moved the offset by `delta` (negative = toward older
  /// rows). Pinning follows the user's direction, not just geometry: scrolling up off the bottom
  /// unpins, and only scrolling down to within `threshold` of the bottom re-pins. A viewport
  /// change (the keyboard hiding grows the list at the bottom and can land a reader who scrolled
  /// up inside the threshold) never re-pins on its own (#125). The `> 0.5` distance guard keeps
  /// the bounce-back from an overscroll at the bottom from counting as scrolling up.
  public static func pinnedAfterUserScroll(
    wasPinned: Bool,
    delta: CGFloat,
    distanceFromBottom: CGFloat,
    threshold: CGFloat = bottomThreshold
  ) -> Bool {
    if delta < -0.5, distanceFromBottom > 0.5 { return false }
    if delta > 0.5, distanceFromBottom <= threshold { return true }
    return wasPinned
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

  /// Offset-preservation for an anchor row that moved in content coordinates by `anchorShift`
  /// (its new `frame.minY` minus its old one): shifting the offset by the same delta keeps the
  /// anchor visually fixed on screen. Negative when rows above the anchor were removed (a window
  /// `.slide` dropping its head), positive when rows were inserted above it (a prepend shifts by
  /// the inserted height). Returns the new offset clamped to `[-topInset, maxOffsetY]`.
  public static func offsetAfterAnchorShift(
    previousOffsetY: CGFloat,
    anchorShift: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
  ) -> CGFloat {
    let target = previousOffsetY + anchorShift
    let maxY = maxOffsetY(
      contentHeight: contentHeight,
      viewportHeight: viewportHeight,
      topInset: topInset,
      bottomInset: bottomInset
    )
    return min(max(target, -topInset), maxY)
  }

  /// Whether an apply holds the reader's place with a ``preservationAnchor(visible:oldOrder:surviving:)``:
  /// after the initial jump, on any row change that keeps old rows
  /// (``TranscriptDiffKind/holdsReaderAnchor``: a `.slide` or an append/mutate), or — for a
  /// reader scrolled up — on a fold expanding or collapsing over unchanged rows (`.inPlace` rows,
  /// a changed item order). The first population and a `.reset` jump and a `.prepend` has its
  /// own offset path, so none of those holds.
  public static func holdsReaderAnchor(
    rowDiff: TranscriptDiffKind, didInitialJump: Bool, isPinned: Bool, itemOrderChanged: Bool
  ) -> Bool {
    guard didInitialJump else { return false }
    if rowDiff.holdsReaderAnchor { return true }
    return rowDiff == .inPlace && itemOrderChanged && !isPinned
  }

  /// The item to hold still across a structural change (a window `.slide`, or a fold expanding
  /// or collapsing while the reader is scrolled up): the first VISIBLE item that survives the
  /// change. When every visible item goes away (the reader is inside a tall row the slide drops,
  /// or was looking at a turn's tool lines as it finished and collapsed), the first surviving
  /// item after them — the turn's final reply — else the last one before.
  ///
  /// - Parameters:
  ///   - visible: the on-screen item ids, top to bottom.
  ///   - oldOrder: every item id before the change, in order.
  ///   - surviving: the item ids after the change.
  public static func preservationAnchor<ID: Hashable>(
    visible: [ID], oldOrder: [ID], surviving: Set<ID>
  ) -> ID? {
    if let first = visible.first(where: surviving.contains) { return first }
    guard let lastVisible = visible.last, let index = oldOrder.firstIndex(of: lastVisible) else {
      return nil
    }
    if let after = oldOrder[(index + 1)...].first(where: surviving.contains) { return after }
    return oldOrder[..<index].last(where: surviving.contains)
  }
}

/// Detect whether a window's row-id update (the renderer passes `visibleRows` ids, not display
/// item ids, so a fold change is never misread) is a *prepend* (older page loaded at the top),
/// an append/in-place mutation (streaming / new turn / rows inserted mid-window), a *slide* (the
/// reducer's fixed bottom window moving under the reader as live rows come and go), or a *reset*
/// (a genuine wholesale replacement of the visible slice, e.g. a server-authoritative
/// re-hydrate). A prepend requires offset preservation; a slide or an append/mutate holds the
/// reader's anchor row and follows if pinned (`holdsReaderAnchor`); a reset forces a
/// jump-to-bottom (the open/hydrate contract). Pure over the row id sequences so it is testable.
public enum TranscriptDiffKind: Equatable, Sendable {
  /// Older rows were inserted before the previously-first row (load-older).
  case prepend(insertedCount: Int)
  /// Newer rows appended at the bottom, trailing rows mutated in place, or the same logical rows
  /// reordered / with rows inserted in the middle. The follow-the-bottom case: follow only if
  /// pinned, **never yank a scrolled-up reader** (the no-yank contract).
  case appendOrMutate
  /// No structural change to the id sequence (pure content mutation, e.g. a delta).
  case inPlace
  /// The window moved under the reader (#125): some old rows are gone but others survive — the
  /// reducer's fixed bottom window (`ChatFeature.State.initialWindow`) dropping `droppedHeadCount`
  /// head rows on a live append, or a turn-end row removal re-admitting an older head row
  /// (`droppedHeadCount == 0`). Follow if pinned; otherwise the renderer holds the reader's anchor
  /// row — **never yank**. Without this case every tool row of a turn on a 50+ row chat, and the
  /// turn end itself, classified as `.reset`.
  case slide(droppedHeadCount: Int)
  /// A *genuine* wholesale replacement of the visible slice: no old id survives, or the window
  /// shrank AND lost its head (a hydrate re-trimming a paged-up window to the bottom) — the
  /// reader's rows are gone. Also first population. Per the open/hydrate contract the renderer
  /// forces a jump-to-bottom on a reset, regardless of pin state. A reorder or a mid-window
  /// insert is NOT a reset, and neither is a `.slide`.
  case reset

  /// Classify the transition from `old` row ids to `new` row ids.
  ///
  /// The ordering of the checks below is deliberate. A sequence that is neither a contiguous
  /// prefix nor suffix match yet keeps every old row (shuffled, or with rows inserted in the
  /// middle) must not read as a genuine hydrate (`reconstructTranscript` mints fresh ids when the
  /// messages changed, so the old ids largely disappear). `.reset` is therefore reserved for the
  /// case where no old row survives, or the window shrank and lost its head — i.e. the reader's
  /// rows were actually replaced, not shuffled, added to, or slid past.
  public static func classify(old: [ChatRow.ID], new: [ChatRow.ID]) -> TranscriptDiffKind {
    guard !old.isEmpty else {
      // First population (empty → rows): treat as a reset so the renderer performs the
      // open-at-bottom jump. (The renderer also guards this via its first-population flag.)
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
    // Neither a contiguous prefix nor suffix — but not necessarily a wholesale replace. Two
    // defensive non-reset shapes (both preserve the old logical rows, so a scrolled-up reader
    // must NOT be yanked):
    //   1. A permutation: the new and old id sets are the same.
    //   2. A superset: every old id survives, with rows inserted mid-window.
    // When neither holds, some old rows are gone; the slide/reset split below decides.
    let oldSet = Set(old)
    let newSet = Set(new)
    if newSet == oldSet { return .appendOrMutate }       // permutation / reorder
    if oldSet.isSubset(of: newSet) { return .appendOrMutate } // superset: old rows preserved
    // Some old rows are gone. No old row survives ⇒ a wholesale replace.
    guard let firstSurvivor = old.firstIndex(where: newSet.contains) else { return .reset }
    // A window that shrank AND lost its head is a hydrate re-trimming a paged-up window to the
    // bottom: the reader's rows are gone, so it keeps the jump-to-bottom contract.
    if new.count < old.count, firstSurvivor > 0 { return .reset }
    // Slide (#125): anything else that keeps old rows is the window moving under the reader —
    // the head dropping on a live append, or a turn-end row removal (e.g. `reparkDrainingEntry`'s
    // echo) re-admitting an older row at the head.
    return .slide(droppedHeadCount: firstSurvivor)
  }

  /// Whether this is a load-older `.prepend`.
  public var isPrepend: Bool {
    if case .prepend = self { return true } else { return false }
  }

  /// Whether the renderer holds the reader's anchor row across this update: every structural
  /// change that keeps old rows on screen (`.slide`, `.appendOrMutate`). A `.prepend` has its own
  /// offset path, a `.reset` jumps, and `.inPlace` changes no row positions.
  public var holdsReaderAnchor: Bool {
    switch self {
    case .slide, .appendOrMutate: true
    case .prepend, .inPlace, .reset: false
    }
  }
}
