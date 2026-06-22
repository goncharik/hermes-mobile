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

  // MARK: - offsetAfterPrepend

  @Test func offsetAfterPrependShiftsByInsertedHeight() {
    // Inserting 300pt of older rows shifts the offset down by exactly 300 so the anchor row
    // stays visually fixed.
    #expect(
      TranscriptScrollMath.offsetAfterPrepend(
        previousOffsetY: 100, insertedHeight: 300,
        contentHeight: 2300, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 400
    )
  }

  @Test func offsetAfterPrependClampsToMax() {
    // Target would exceed the legal max ⇒ clamps to maxOffsetY.
    #expect(
      TranscriptScrollMath.offsetAfterPrepend(
        previousOffsetY: 1400, insertedHeight: 300,
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 0
      ) == 1200
    )
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

  @Test func classifyReorderSameLengthIsReset() {
    // Same length, reordered ids: not in-place (sequence changed) and not a prefix/suffix ⇒ reset.
    let old = ids(3)
    let reordered = [old[2], old[0], old[1]]
    #expect(TranscriptDiffKind.classify(old: old, new: reordered) == .reset)
  }

  @Test func classifyGrowthWithoutPrefixOrSuffixMatchIsReset() {
    // Counts grew but the old sequence is neither a contiguous suffix (not a prepend) nor a
    // contiguous prefix (not an append) ⇒ reset.
    let old = ids(3)
    let new = [old[0], old[1]]
      + [ChatRow.deterministicID(sequenceIndex: 50, role: .user, kindDiscriminator: "status")]
      + [old[2]]
    // old == [0,1,2]; new prefix(3) == [0,1,status] != old and suffix(3) == [1,status,2] != old.
    #expect(TranscriptDiffKind.classify(old: old, new: new) == .reset)
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
}
