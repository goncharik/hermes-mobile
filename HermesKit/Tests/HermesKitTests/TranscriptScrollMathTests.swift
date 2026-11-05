import Foundation
import Testing

@testable import HermesKit

/// Unit tests for the pure scroll/anchor math and the diff classifier shared by both transcript
/// rendering engines. These helpers live in `HermesKit` (logic, not views) and are Foundation-only,
/// so they run under `swift test` with no live scroll view.
@Suite struct TranscriptScrollMathTests {

  // MARK: - isPinnedToBottom

  @Test func pinnedWhenContentShorterThanViewport() {
    // Short transcript that doesn't fill the viewport: distance from bottom is negative ⇒ pinned.
    #expect(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 100, viewportHeight: 800, bottomInset: 0, offsetY: 0
      )
    )
  }

  @Test func pinnedAtExactBottom() {
    // offsetY + viewport == contentHeight ⇒ distance 0 ⇒ pinned.
    #expect(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 0, offsetY: 1200
      )
    )
  }

  @Test func pinnedWithinThreshold() {
    // 40pt above the true bottom is still within the 60pt threshold.
    #expect(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 0, offsetY: 1160
      )
    )
  }

  @Test func notPinnedBeyondThreshold() {
    // 100pt above the bottom exceeds the 60pt threshold ⇒ not pinned.
    #expect(
      !TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 0, offsetY: 1100
      )
    )
  }

  @Test func bottomInsetCountsTowardPin() {
    // The bottom inset extends the content's effective bottom edge.
    #expect(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 50, offsetY: 1250
      )
    )
  }

  // MARK: - maxOffsetY

  @Test func maxOffsetYForTallContent() {
    #expect(
      TranscriptScrollMath.maxOffsetY(
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 1200
    )
  }

  @Test func maxOffsetYClampsForShortContent() {
    // Content shorter than the viewport: the max offset clamps to `-topInset` so a short
    // transcript never produces a positive (over-scrolled) offset.
    #expect(
      TranscriptScrollMath.maxOffsetY(
        contentHeight: 100, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 0
    )
  }

  @Test func maxOffsetYIncludesBottomInset() {
    #expect(
      TranscriptScrollMath.maxOffsetY(
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 50
      ) == 1250
    )
  }

  // MARK: - offsetAfterAnchorShift

  @Test func offsetAfterAnchorShiftForPrependShiftsByInsertedHeight() {
    // Inserting 300pt of older rows shifts the offset down by exactly 300 so the anchor row
    // stays visually fixed.
    #expect(
      TranscriptScrollMath.offsetAfterAnchorShift(
        previousOffsetY: 100, anchorShift: 300,
        contentHeight: 2300, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 400
    )
  }

  @Test func offsetAfterAnchorShiftForPrependClampsToMax() {
    // Target would exceed the legal max ⇒ clamps to maxOffsetY.
    #expect(
      TranscriptScrollMath.offsetAfterAnchorShift(
        previousOffsetY: 1400, anchorShift: 300,
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 1200
    )
  }

  @Test func offsetAfterAnchorShiftNegativeShiftForDroppedHead() {
    // A slide dropped 120pt of head rows above the anchor: the anchor moved up by 120, so the
    // offset moves up by the same amount to keep it on screen in place.
    #expect(
      TranscriptScrollMath.offsetAfterAnchorShift(
        previousOffsetY: 900, anchorShift: -120,
        contentHeight: 3000, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 780
    )
  }

  @Test func offsetAfterAnchorShiftClampsAtNegativeTopInset() {
    // Target would scroll above the top edge ⇒ clamps to -topInset.
    #expect(
      TranscriptScrollMath.offsetAfterAnchorShift(
        previousOffsetY: 50, anchorShift: -200,
        contentHeight: 3000, viewportHeight: 800, topInset: 20, bottomInset: 0
      ) == -20
    )
  }

  @Test func offsetAfterAnchorShiftClampsAtMaxOffsetY() {
    // maxOffsetY = 2000 + 40 - 800 = 1240.
    #expect(
      TranscriptScrollMath.offsetAfterAnchorShift(
        previousOffsetY: 1200, anchorShift: 100,
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 40
      ) == 1240
    )
  }

  @Test func offsetAfterAnchorShiftZeroShiftIsIdentity() {
    #expect(
      TranscriptScrollMath.offsetAfterAnchorShift(
        previousOffsetY: 640, anchorShift: 0,
        contentHeight: 3000, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 640
    )
  }

  // MARK: - pinnedAfterUserScroll (#125)

  @Test func scrollingUpOffTheBottomUnpinsEvenInsideTheThreshold() {
    // The keyboard case: the reader scrolled up and the list grew under them, leaving them
    // 50pt from the bottom. Their scroll went up, so they are not following.
    #expect(!TranscriptScrollMath.pinnedAfterUserScroll(wasPinned: true, delta: -20, distanceFromBottom: 50))
  }

  @Test func scrollingDownToWithinTheThresholdRepins() {
    #expect(TranscriptScrollMath.pinnedAfterUserScroll(wasPinned: false, delta: 30, distanceFromBottom: 40))
  }

  @Test func scrollingDownButStillFarFromTheBottomStaysUnpinned() {
    #expect(!TranscriptScrollMath.pinnedAfterUserScroll(wasPinned: false, delta: 30, distanceFromBottom: 200))
  }

  @Test func bounceBackFromAnOverscrollAtTheBottomKeepsThePin() {
    // Rubber-banding back from past the bottom moves the offset up while still at the bottom.
    #expect(TranscriptScrollMath.pinnedAfterUserScroll(wasPinned: true, delta: -15, distanceFromBottom: -10))
    #expect(TranscriptScrollMath.pinnedAfterUserScroll(wasPinned: true, delta: -15, distanceFromBottom: 0))
  }

  @Test func noMovementKeepsThePin() {
    #expect(TranscriptScrollMath.pinnedAfterUserScroll(wasPinned: true, delta: 0, distanceFromBottom: 300))
    #expect(!TranscriptScrollMath.pinnedAfterUserScroll(wasPinned: false, delta: 0, distanceFromBottom: 0))
  }

  // MARK: - Anchor choice (window slide, fold expand / collapse while scrolled up)

  @Test func anchorIsTheFirstVisibleSurvivor() {
    // A run above the viewport folded away (items 1, 2): the first visible item (3) holds still.
    #expect(TranscriptScrollMath.preservationAnchor(
      visible: [3, 4, 5], oldOrder: [0, 1, 2, 3, 4, 5, 6], surviving: [0, 3, 4, 5, 6]
    ) == 3)
    // The first visible item folded away: the next visible survivor.
    #expect(TranscriptScrollMath.preservationAnchor(
      visible: [2, 3, 4], oldOrder: [0, 1, 2, 3, 4], surviving: [0, 3, 4]
    ) == 3)
  }

  @Test func expandingACallBodyHoldsWhatIsAboveIt() throws {
    // Expanding a call in place inserts its body item right after the line: every old item
    // survives, so the first visible one — above the tapped line — holds still, and nothing
    // from it down to the tapped line moves; only the content below the line shifts down.
    let rows = (0..<4).map { n in
      ChatRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!,
              kind: n == 0 ? .message(role: .user, text: "q", isComplete: true)
                : .tool(name: "terminal", title: "ls", state: .complete, detail: nil, durationS: nil))
    }
    let open = FoldExpansion(turnOverride: [0: .expanded], expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 0)])
    var expanded = open
    expanded.toggleCall(CallKey(turnOrdinal: 0, callOrdinal: 1))
    let before = TranscriptFold.items(rows: rows, expansion: open, runningTurnOrdinal: nil, liveLine: nil).map(\.id)
    let after = TranscriptFold.items(rows: rows, expansion: expanded, runningTurnOrdinal: nil, liveLine: nil).map(\.id)
    #expect(after.count == before.count + 1)
    #expect(Set(before).isSubset(of: Set(after)))
    let tappedLine = rows[2].id
    let tapped = try #require(before.firstIndex(of: tappedLine))
    #expect(tapped >= 2)
    // The reader sees from one item below the top down past the tapped line.
    let visible = Array(before[1...])
    #expect(TranscriptScrollMath.preservationAnchor(
      visible: visible, oldOrder: before, surviving: Set(after)
    ) == before[1])
    #expect(Array(after.prefix(tapped + 1)) == Array(before.prefix(tapped + 1)))
    #expect(after[tapped + 1] == TranscriptItem.toolBodyID(callRowID: tappedLine))
  }

  @Test func anchorHoldIsRowChangesThatKeepRowsOrAFoldChangeWhileScrolledUp() {
    func holds(
      _ diff: TranscriptDiffKind, didInitialJump: Bool = true, isPinned: Bool = false,
      itemOrderChanged: Bool = true
    ) -> Bool {
      TranscriptScrollMath.holdsReaderAnchor(
        rowDiff: diff, didInitialJump: didInitialJump, isPinned: isPinned,
        itemOrderChanged: itemOrderChanged
      )
    }
    // A slide or an append/mutate holds, pinned or not.
    for diff: TranscriptDiffKind in [.slide(droppedHeadCount: 1), .appendOrMutate] {
      #expect(holds(diff))
      #expect(holds(diff, isPinned: true))
    }
    // A fold change over unchanged rows holds only for a scrolled-up reader.
    #expect(holds(.inPlace))
    #expect(!holds(.inPlace, isPinned: true))
    #expect(!holds(.inPlace, itemOrderChanged: false))
    // A prepend or a reset never holds (own offset path / jump), nor anything before the
    // initial jump.
    #expect(!holds(.prepend(insertedCount: 2)))
    #expect(!holds(.reset))
    for diff: TranscriptDiffKind in [.slide(droppedHeadCount: 1), .appendOrMutate, .inPlace] {
      #expect(!holds(diff, didInitialJump: false))
    }
  }

  @Test func anchorFallsToTheFinalReplyWhenEverythingVisibleFolded() {
    // The reader was looking at the turn's tool lines (2...4) when it finished and collapsed:
    // hold the first survivor after them — the final reply (5).
    #expect(TranscriptScrollMath.preservationAnchor(
      visible: [2, 3, 4], oldOrder: [0, 1, 2, 3, 4, 5], surviving: [0, 1, 5]
    ) == 5)
    // Nothing after them survives: the last survivor before them (the header).
    #expect(TranscriptScrollMath.preservationAnchor(
      visible: [2, 3], oldOrder: [0, 1, 2, 3], surviving: [0, 1]
    ) == 1)
    #expect(TranscriptScrollMath.preservationAnchor(
      visible: [Int](), oldOrder: [0, 1], surviving: [0, 1]
    ) == nil)
  }

  @Test func anchorInsideATallDroppedHeadRowIsTheFirstSurvivorBelowIt() {
    // A slide dropped the head row the reader was inside (0): hold the next row (1).
    #expect(TranscriptScrollMath.preservationAnchor(
      visible: [0], oldOrder: [0, 1, 2, 3], surviving: [1, 2, 3, 4]
    ) == 1)
  }

  // MARK: - TranscriptDiffKind.classify

  private func ids(_ count: Int) -> [ChatRow.ID] {
    (0..<count).map { ChatRow.deterministicID(sequenceIndex: $0, role: .user, kindDiscriminator: "message") }
  }

  @Test func classifyBothEmptyIsInPlace() {
    #expect(TranscriptDiffKind.classify(old: [], new: []) == .inPlace)
  }

  @Test func classifyFirstPopulationIsReset() {
    // Empty → rows: a reset so the renderer performs the open-at-bottom jump.
    let new = ids(3)
    #expect(TranscriptDiffKind.classify(old: [], new: new) == .reset)
  }

  @Test func classifyAppend() {
    let base = ids(3)
    let appended = base + [ChatRow.deterministicID(sequenceIndex: 99, role: .assistant, kindDiscriminator: "message")]
    #expect(TranscriptDiffKind.classify(old: base, new: appended) == .appendOrMutate)
  }

  @Test func classifyInPlaceWhenIdentical() {
    let base = ids(4)
    #expect(TranscriptDiffKind.classify(old: base, new: base) == .inPlace)
  }

  @Test func classifyPrepend() {
    let old = ids(3)
    let older = [
      ChatRow.deterministicID(sequenceIndex: 100, role: .user, kindDiscriminator: "tool"),
      ChatRow.deterministicID(sequenceIndex: 101, role: .assistant, kindDiscriminator: "thinking"),
    ]
    let new = older + old
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .prepend(insertedCount: 2))
  }

  @Test func classifyPrependWhereInsertedFirstEqualsOldFirst() {
    // A prepend whose inserted rows START with the old first id. The suffix still matches and
    // counts grew, so it MUST be classified as a prepend — not misread as an append just
    // because `new.first == old.first`. (This is the regression the classifier fix addresses.)
    let old = ids(3)
    let new = [old[0]] + old  // duplicate the old first id at the head
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .prepend(insertedCount: 1))
  }

  @Test func classifyFullReplacementIsReset() {
    // A hydrate over a different transcript: neither prefix nor suffix relationship ⇒ reset,
    // which forces the open/hydrate jump-to-bottom regardless of pin state.
    let old = ids(3)
    let new = [
      ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "thinking"),
      ChatRow.deterministicID(sequenceIndex: 1, role: .assistant, kindDiscriminator: "message"),
    ]
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .reset)
  }

  @Test func classifyReorderSameLengthIsNotReset() {
    // Same length, reordered ids (a permutation of the same logical rows): the id SET is
    // unchanged ⇒ NOT a wholesale reset. It must follow the no-yank pin rule
    // (`.appendOrMutate`), never force a jump.
    let old = ids(3)
    let reordered = [old[2], old[0], old[1]]
    #expect(TranscriptDiffKind.classify(old: old, new: reordered) == .appendOrMutate)
  }

  @Test func classifyMidInsertReorderIsNotReset() {
    // Counts grew and the new row was inserted in the MIDDLE (neither a contiguous prefix nor
    // suffix), but every old id survives. Must be `.appendOrMutate`, never `.reset`, so a user
    // who scrolled up mid-turn is NOT yanked to the bottom.
    let old = ids(3)
    let new = [old[0], old[1]]
      + [ChatRow.deterministicID(sequenceIndex: 50, role: .user, kindDiscriminator: "status")]
      + [old[2]]
    // old == [0,1,2]; new prefix(3) == [0,1,status] != old and suffix(3) == [1,status,2] != old,
    // yet {0,1,2} ⊆ {0,1,status,2} ⇒ old rows preserved ⇒ not a reset.
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .appendOrMutate)
  }

  @Test func classifyHydrateWhileScrolledUpIsReset() {
    // A re-hydrate (session.resume rebuilds rows wholesale to the bottom window) while the user
    // was scrolled up: the new bottom-window ids share nothing structural with the old top
    // slice ⇒ reset, forcing the documented jump-to-bottom.
    let oldTopSlice = ids(50)  // user had paged to the top window
    let newBottomWindow = (200..<250).map {
      ChatRow.deterministicID(sequenceIndex: $0, role: .assistant, kindDiscriminator: "message")
    }
    #expect(TranscriptDiffKind.classify(old: oldTopSlice, new: newBottomWindow) == .reset)
  }

  // MARK: - TranscriptDiffKind.classify — window slide (#125)

  private func id(_ index: Int, _ kind: String = "message") -> ChatRow.ID {
    ChatRow.deterministicID(sequenceIndex: index, role: .assistant, kindDiscriminator: kind)
  }

  @Test func classifyPlainSlideIsSlide() {
    // The reducer's fixed bottom window advanced by one row: the head row dropped off the top,
    // one row appended at the bottom. Not a reset — a scrolled-up reader must not be yanked.
    let old = (0..<50).map { id($0) }
    let new = (1..<51).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 1))
  }

  @Test func classifyLiveToolCallSlideIsSlide() {
    // A row inserted ABOVE the window's last row while the window drops its head row — a
    // mid-insert combined with a dropped head.
    let thinking = id(900, "thinking")
    let tool = id(901, "tool")
    let old = (0...48).map { id($0) } + [thinking]
    let new = (1...48).map { id($0) } + [tool, thinking]
    #expect(old.count == 50 && new.count == 50)
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 1))
  }

  @Test func classifyMultiRowSlideIsSlide() {
    // Two rows appended in one update ⇒ two head rows dropped.
    let old = (0..<50).map { id($0) }
    let new = (2..<52).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 2))
  }

  @Test func classifySlideThatGrewIsSlide() {
    // The head dropped but the window still grew (rare, but the no-shrink rule admits it).
    let old = (0..<50).map { id($0) }
    let new = (1..<52).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 1))
  }

  @Test func classifyShrunkWindowWithOverlapIsReset() {
    // Paged up (100 visible rows), then a hydrate re-trims to the 50-row bottom window: the
    // window shrank and the reader's rows are gone ⇒ still a reset (jump to bottom).
    let old = (100..<200).map { id($0) }
    let new = (150..<200).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .reset)
  }

  @Test func classifyZeroOverlapSameSizeIsReset() {
    let old = (0..<50).map { id($0) }
    let new = (100..<150).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .reset)
  }

  @Test func classifyHoleAfterDroppedHeadIsSlide() {
    // A head row dropped AND a mid-window row vanished: the reader's other rows survive and the
    // window did not shrink ⇒ hold their anchor, never jump.
    let old = (0..<50).map { id($0) }
    let new = (1..<25).map { id($0) } + (26..<52).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 1))
  }

  @Test func classifyTurnEndRowRemovalOnFullWindowIsSlide() {
    // A turn-end row removal on a 50+ row chat (e.g. a re-parked queue entry's echo row): the
    // bottom window re-admits an older head row while its last row leaves.
    let thinking = id(900, "thinking")
    let old = (1...49).map { id($0) } + [thinking]
    let new = (0...49).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 0))
  }

  @Test func classifyTailRemovalThatShrinksIsSlide() {
    // The same turn-end removal on a chat whose window is not full (or was paged up): the window
    // shrinks, but its head survives ⇒ not the paged-up hydrate re-trim.
    let thinking = id(900, "thinking")
    let old = (0..<30).map { id($0) } + [thinking]
    let new = (0..<30).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 0))
  }

  @Test func classifyCompletedTurnHydrateKeepingOnlyOlderRowsIsSlide() {
    // A foreground hydrate after a long turn completed: the turn's live rows (random ids) are
    // rebuilt with history ids, so only the rows above the turn survive — a minority, all off
    // screen for a reader inside the turn. Those survivors are the same server rows (position ids
    // over immutable history), so this is deliberately a slide, not a reset: the reader is held
    // against them instead of being jumped to the bottom.
    let history = (0..<10).map { id($0) }
    let old = history + (0..<40).map { id(1000 + $0, "live") }
    let new = history + (10..<50).map { id($0) }
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 0))
  }

  @Test func classifyDroppedHeadWithReorderedSurvivorsIsSlide() {
    // Survivor order is deliberately not checked: a reorder is never a reset (see the
    // permutation case), so a dropped head plus a reorder is still a slide.
    let old = (0..<50).map { id($0) }
    let new = (1..<48).map { id($0) } + [id(49), id(48), id(50)]
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .slide(droppedHeadCount: 1))
  }

  // MARK: - TranscriptDiffKind predicates

  @Test func isPrependOnlyForPrepend() {
    #expect(TranscriptDiffKind.prepend(insertedCount: 2).isPrepend)
    for kind: TranscriptDiffKind in [.appendOrMutate, .inPlace, .slide(droppedHeadCount: 1), .reset] {
      #expect(!kind.isPrepend)
    }
  }

  @Test func holdsReaderAnchorForSlideAndAppendOnly() {
    #expect(TranscriptDiffKind.slide(droppedHeadCount: 0).holdsReaderAnchor)
    #expect(TranscriptDiffKind.appendOrMutate.holdsReaderAnchor)
    for kind: TranscriptDiffKind in [.prepend(insertedCount: 1), .inPlace, .reset] {
      #expect(!kind.holdsReaderAnchor)
    }
  }

  // MARK: - canApplySnapshot (#128)

  /// The production section inset (`TranscriptLayout.horizontalSectionInset`, app target).
  private let inset: CGFloat = 16

  private func canApply(width: CGFloat, height: CGFloat, hasWindow: Bool = true) -> Bool {
    TranscriptScrollMath.canApplySnapshot(
      width: width, height: height, hasWindow: hasWindow, horizontalSectionInset: inset
    )
  }

  @Test func appliesAtARealSizeInAWindow() {
    // The first real layout pass on open (iPhone 17 Pro, measured in the #128 investigation).
    #expect(canApply(width: 402, height: 619.67))
    #expect(canApply(width: 320, height: 568))
  }

  @Test func defersTheFirstOpenApply() {
    // The first `updateUIView` on open runs at a zero frame with no window: deferred, so the
    // flush on the first real `didLayout` takes the open jump.
    #expect(!canApply(width: 0, height: 0, hasWindow: false))
  }

  @Test func defersWithoutAWindow() {
    #expect(!canApply(width: 402, height: 619.67, hasWindow: false))
  }

  @Test func defersAZeroNegativeOrNonFiniteWidth() {
    for width: CGFloat in [0, -1, -402, .nan, .infinity, -.infinity] {
      #expect(!canApply(width: width, height: 619.67), "width \(width)")
    }
  }

  @Test func defersAWidthThatLeavesNoRowWidth() {
    // A row is `width − 2 × inset`: at or below 32pt it is 0pt wide, a degenerate self-sizing
    // pass (every cell measured at a 0–1pt fitting width).
    #expect(!canApply(width: 20, height: 619.67))
    #expect(!canApply(width: 32, height: 619.67))
    #expect(canApply(width: 33, height: 619.67))
  }

  @Test func defersAZeroNegativeOrNonFiniteHeight() {
    for height: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
      #expect(!canApply(width: 402, height: height), "height \(height)")
    }
  }
}
