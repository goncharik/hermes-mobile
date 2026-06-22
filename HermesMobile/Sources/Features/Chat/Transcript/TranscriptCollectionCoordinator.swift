import Foundation
import HermesKit

// MARK: - Pure helpers (platform-independent, unit-testable)

/// Pure scroll/anchor math for the `UICollectionView` transcript engine. Kept outside the
/// `#if canImport(UIKit)` guard so the threshold/anchor logic is platform-independent and
/// directly testable (HermesKit-style), and so the same numbers drive both engines.
enum TranscriptScrollMath {
  /// Distance from the bottom (in points) that still counts as "pinned" — mirrors the
  /// SwiftUI engine's `bottomThreshold` so the two renderers agree on the at-bottom contract.
  static let bottomThreshold: CGFloat = 60

  /// Given the content's full height, the visible viewport height, the bottom inset, and the
  /// current vertical offset, decide whether the viewport is pinned to the bottom edge.
  /// `≤ threshold` of remaining scroll distance below the viewport ⇒ pinned to the latest row.
  static func isPinnedToBottom(
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
  static func maxOffsetY(
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
  static func offsetAfterPrepend(
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

/// Detect whether a `rows` update is a *prepend* (older page loaded at the top) versus an
/// append/in-place mutation. A prepend is the only update that requires offset preservation;
/// everything else follows the pin rule. Pure over the row id sequences so it is testable.
enum TranscriptDiffKind: Equatable {
  /// Older rows were inserted before the previously-first row (load-older).
  case prepend(insertedCount: Int)
  /// Newer rows appended and/or trailing rows mutated in place (streaming / new turn).
  case appendOrMutate
  /// No structural change to the id sequence (pure content mutation, e.g. a delta).
  case inPlace

  /// Classify the transition from `old` row ids to `new` row ids.
  static func classify(old: [ChatRow.ID], new: [ChatRow.ID]) -> TranscriptDiffKind {
    guard !old.isEmpty, let oldFirst = old.first else {
      return new.isEmpty ? .inPlace : .appendOrMutate
    }
    // Prepend: the old sequence still appears as a contiguous suffix of the new one, and the
    // new sequence is strictly longer (older rows added in front of the prior first row).
    if new.count > old.count {
      let suffix = Array(new.suffix(old.count))
      if suffix == old, new.first != oldFirst {
        return .prepend(insertedCount: new.count - old.count)
      }
    }
    if new == old { return .inPlace }
    return .appendOrMutate
  }
}
