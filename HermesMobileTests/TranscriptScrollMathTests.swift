import HermesKit
import XCTest

@testable import HermesMobile

/// Unit tests for the pure scroll/anchor math and the diff classifier behind the
/// `UICollectionView` transcript engine. These helpers are deliberately kept outside the
/// `#if canImport(UIKit)` guard precisely so they can be tested here without a live scroll
/// view. (They live in the app target, not HermesKit, so this iOS test target — which can
/// `@testable import HermesMobile` — is where they are reachable by the test runner.)
final class TranscriptScrollMathTests: XCTestCase {

  // MARK: - isPinnedToBottom

  func testPinnedWhenContentShorterThanViewport() {
    // Short transcript that doesn't fill the viewport: distance from bottom is negative ⇒ pinned.
    XCTAssertTrue(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 100, viewportHeight: 800, bottomInset: 0, offsetY: 0
      )
    )
  }

  func testPinnedAtExactBottom() {
    // offsetY + viewport == contentHeight ⇒ distance 0 ⇒ pinned.
    XCTAssertTrue(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 0, offsetY: 1200
      )
    )
  }

  func testPinnedWithinThreshold() {
    // 40pt above the true bottom is still within the 60pt threshold.
    XCTAssertTrue(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 0, offsetY: 1160
      )
    )
  }

  func testNotPinnedBeyondThreshold() {
    // 100pt above the bottom exceeds the 60pt threshold ⇒ not pinned.
    XCTAssertFalse(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 0, offsetY: 1100
      )
    )
  }

  func testBottomInsetCountsTowardPin() {
    // The bottom inset extends the content's effective bottom edge.
    XCTAssertTrue(
      TranscriptScrollMath.isPinnedToBottom(
        contentHeight: 2000, viewportHeight: 800, bottomInset: 50, offsetY: 1250
      )
    )
  }

  // MARK: - maxOffsetY

  func testMaxOffsetYForTallContent() {
    XCTAssertEqual(
      TranscriptScrollMath.maxOffsetY(
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 0
      ),
      1200
    )
  }

  func testMaxOffsetYClampsForShortContent() {
    // Content shorter than the viewport: the max offset clamps to `-topInset` so a short
    // transcript never produces a positive (over-scrolled) offset.
    XCTAssertEqual(
      TranscriptScrollMath.maxOffsetY(
        contentHeight: 100, viewportHeight: 800, topInset: 0, bottomInset: 0
      ),
      0
    )
  }

  func testMaxOffsetYIncludesBottomInset() {
    XCTAssertEqual(
      TranscriptScrollMath.maxOffsetY(
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 50
      ),
      1250
    )
  }

  // MARK: - offsetAfterPrepend

  func testOffsetAfterPrependShiftsByInsertedHeight() {
    // Inserting 300pt of older rows shifts the offset down by exactly 300 so the anchor row
    // stays visually fixed.
    XCTAssertEqual(
      TranscriptScrollMath.offsetAfterPrepend(
        previousOffsetY: 100, insertedHeight: 300,
        contentHeight: 2300, viewportHeight: 800, topInset: 0, bottomInset: 0
      ),
      400
    )
  }

  func testOffsetAfterPrependClampsToMax() {
    // Target would exceed the legal max ⇒ clamps to maxOffsetY.
    XCTAssertEqual(
      TranscriptScrollMath.offsetAfterPrepend(
        previousOffsetY: 1400, insertedHeight: 300,
        contentHeight: 2000, viewportHeight: 800, topInset: 0, bottomInset: 0
      ),
      1200
    )
  }

  // MARK: - TranscriptDiffKind.classify

  private func ids(_ count: Int) -> [ChatRow.ID] {
    (0..<count).map { ChatRow.deterministicID(sequenceIndex: $0, role: .user, kindDiscriminator: "message") }
  }

  func testClassifyBothEmptyIsInPlace() {
    XCTAssertEqual(TranscriptDiffKind.classify(old: [], new: []), .inPlace)
  }

  func testClassifyFirstPopulationIsAppend() {
    let new = ids(3)
    XCTAssertEqual(TranscriptDiffKind.classify(old: [], new: new), .appendOrMutate)
  }

  func testClassifyAppend() {
    let base = ids(3)
    let appended = base + [ChatRow.deterministicID(sequenceIndex: 99, role: .assistant, kindDiscriminator: "message")]
    XCTAssertEqual(TranscriptDiffKind.classify(old: base, new: appended), .appendOrMutate)
  }

  func testClassifyInPlaceWhenIdentical() {
    let base = ids(4)
    XCTAssertEqual(TranscriptDiffKind.classify(old: base, new: base), .inPlace)
  }

  func testClassifyPrepend() {
    let old = ids(3)
    let older = [
      ChatRow.deterministicID(sequenceIndex: 100, role: .user, kindDiscriminator: "tool"),
      ChatRow.deterministicID(sequenceIndex: 101, role: .assistant, kindDiscriminator: "thinking"),
    ]
    let new = older + old
    XCTAssertEqual(TranscriptDiffKind.classify(old: old, new: new), .prepend(insertedCount: 2))
  }

  func testClassifyPrependWhereInsertedFirstEqualsOldFirst() {
    // A prepend whose inserted rows START with the old first id. The suffix still matches and
    // counts grew, so it MUST be classified as a prepend — not misread as an append just
    // because `new.first == old.first`. (This is the regression the classifier fix addresses.)
    let old = ids(3)
    let new = [old[0]] + old  // duplicate the old first id at the head
    XCTAssertEqual(TranscriptDiffKind.classify(old: old, new: new), .prepend(insertedCount: 1))
  }

  func testClassifyFullReplacementIsAppendOrMutate() {
    // A hydrate over a different transcript: no suffix relationship ⇒ not a prepend.
    let old = ids(3)
    let new = [
      ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "thinking"),
      ChatRow.deterministicID(sequenceIndex: 1, role: .assistant, kindDiscriminator: "message"),
    ]
    XCTAssertEqual(TranscriptDiffKind.classify(old: old, new: new), .appendOrMutate)
  }

  func testClassifyReorderSameLengthIsAppendOrMutate() {
    // Same length, reordered ids: not in-place (sequence changed) and not a prepend (no growth).
    let old = ids(3)
    let reordered = [old[2], old[0], old[1]]
    XCTAssertEqual(TranscriptDiffKind.classify(old: old, new: reordered), .appendOrMutate)
  }

  func testClassifyGrowthWithoutSuffixMatchIsAppendOrMutate() {
    // Counts grew but the old sequence is NOT a contiguous suffix ⇒ append/mutate, not prepend.
    let old = ids(3)
    let new = [old[0], old[1]]
      + [ChatRow.deterministicID(sequenceIndex: 50, role: .user, kindDiscriminator: "status")]
      + [old[2]]
    // old == [0,1,2]; new suffix(3) == [1, status, 2] != old ⇒ not a prepend.
    XCTAssertEqual(TranscriptDiffKind.classify(old: old, new: new), .appendOrMutate)
  }
}
