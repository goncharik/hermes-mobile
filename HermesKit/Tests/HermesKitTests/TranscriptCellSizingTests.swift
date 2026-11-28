import Foundation
import Testing

@testable import HermesKit

/// The transcript cell sizing guard (#191): every cell measures no narrower than the narrowest
/// real row and reports a finite, non-negative size no taller than the cap, whatever it is
/// proposed and whatever its content answers.
@Suite struct TranscriptCellSizingTests {
  /// The narrowest real row (`TranscriptLayout.narrowestRowWidth`: 320pt minus the insets).
  private let floor: CGFloat = 288

  // MARK: - measuringWidth

  @Test func aRealRowMeasuresAtItsOwnWidth() {
    for width: CGFloat in [288, 343, 370, 661, 728] {
      #expect(TranscriptCellSizing.measuringWidth(proposed: width, floor: floor) == width)
    }
  }

  @Test func aDegenerateWidthMeasuresAtTheFloor() {
    // A collection view a few points wide (33pt → a 1pt row in the 2 × 16pt insets) is the
    // reproduced crash: a long reply measured at 1pt was 3.17M pt tall.
    for width: CGFloat in [287.5, 120, 1, 0.5, 0, -12] {
      #expect(TranscriptCellSizing.measuringWidth(proposed: width, floor: floor) == floor, "width \(width)")
    }
  }

  @Test func anUnspecifiedOrNonFiniteWidthAsksForTheIdealSize() {
    for width: CGFloat? in [nil, .infinity, -.infinity, .nan] {
      #expect(TranscriptCellSizing.measuringWidth(proposed: width, floor: floor) == nil, "width \(String(describing: width))")
    }
  }

  // MARK: - reportedSize

  @Test func aRealRowReportsItsProposedWidthAndContentHeight() {
    let size = TranscriptCellSizing.reportedSize(
      content: CGSize(width: 288, height: 1474), proposedWidth: 288
    )
    #expect(size == CGSize(width: 288, height: 1474))
  }

  @Test func aDegenerateRowKeepsTheProposedWidth() {
    // Measured at the floor, reported at the row's own width: UIKit asked for a 1pt-wide cell.
    let size = TranscriptCellSizing.reportedSize(
      content: CGSize(width: 288, height: 9_000), proposedWidth: 1
    )
    #expect(size == CGSize(width: 1, height: 9_000))
  }

  @Test func theHeightIsCappedBelowUIKitsAssert() {
    let size = TranscriptCellSizing.reportedSize(
      content: CGSize(width: 1, height: 3_168_000), proposedWidth: 1
    )
    #expect(size.height == TranscriptCellSizing.maximumCellHeight)
    #expect(TranscriptCellSizing.maximumCellHeight < 2_500_000, "the largest height measured to pass")
  }

  @Test func nonFiniteAndNegativeValuesBecomeZero() {
    for bad: CGFloat in [.nan, .infinity, -.infinity, -40] {
      let size = TranscriptCellSizing.reportedSize(
        content: CGSize(width: bad, height: bad), proposedWidth: nil
      )
      #expect(size == .zero, "value \(bad)")
    }
  }

  @Test func anUnusableProposalFallsBackToTheContentWidth() {
    for proposal: CGFloat? in [nil, .infinity, .nan, -1] {
      let size = TranscriptCellSizing.reportedSize(
        content: CGSize(width: 412, height: 22), proposedWidth: proposal
      )
      #expect(size == CGSize(width: 412, height: 22), "proposal \(String(describing: proposal))")
    }
  }

  @Test func everyReportIsFiniteAndNonNegative() {
    let values: [CGFloat] = [.nan, .infinity, -.infinity, -1, 0, 1, 288, 3_000_000, .greatestFiniteMagnitude]
    let proposals: [CGFloat?] = [nil] + values.map { $0 }
    for proposal in proposals {
      for width in values {
        for height in values {
          let size = TranscriptCellSizing.reportedSize(
            content: CGSize(width: width, height: height), proposedWidth: proposal
          )
          #expect(size.width.isFinite && size.width >= 0)
          #expect(size.height.isFinite && size.height >= 0)
          #expect(size.height <= TranscriptCellSizing.maximumCellHeight)
        }
      }
    }
  }
}
