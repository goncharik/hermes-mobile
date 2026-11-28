import Foundation

// MARK: - Pure transcript cell sizing guard (#191, platform-independent, unit-testable)

/// The size rule every transcript cell's content answers its self-sizing pass with (#191).
///
/// UIKit asserts (`_UIContentViewAssertValidFittingSize`, a crash) when a self-sizing
/// `UICollectionViewCell`'s content view returns a fitting size that is non-finite, negative,
/// or too TALL — measured on iOS 27.2: a 2.5M pt height passes and a 3M pt height asserts, on
/// both the diff-apply and the plain `layoutSubviews` (prefetch) path. Text content grows
/// without bound as its width shrinks — at a 1pt row, `UITextView` and SwiftUI `Text` lay out
/// one glyph per line, ~19pt of height per character — so a long reply measured during a
/// degenerate layout pass (a collection view a few points wide) crosses that ceiling, and the
/// #128 apply gate cannot help: the layout pass sizes cells without any apply.
///
/// The guard has two halves. ``measuringWidth(proposed:floor:)`` measures content no narrower
/// than the narrowest real row (the app passes `TranscriptLayout.narrowestRowWidth`), so a
/// degenerate pass costs the height of a real row, not a glyph column; and
/// ``reportedSize(content:proposedWidth:)`` makes whatever the content answered finite,
/// non-negative, and no taller than ``maximumCellHeight``.
public enum TranscriptCellSizing {
  /// The tallest height a cell reports: well under the measured assert (between 2.5M and 3M pt)
  /// and far above any real row (a 150k-character reply is ~100k pt at the narrowest row).
  public static let maximumCellHeight: CGFloat = 1_000_000

  /// The width to measure a cell's content at for a proposed width.
  ///
  /// - `nil` / non-finite → `nil`: the content's ideal size (an infinite probe must not come
  ///   back as an infinite width).
  /// - finite but narrower than `floor` (incl. zero and negative) → `floor`.
  /// - otherwise the proposal itself, so every real row measures exactly as before.
  public static func measuringWidth(proposed: CGFloat?, floor: CGFloat) -> CGFloat? {
    guard let proposed, proposed.isFinite else { return nil }
    return max(proposed, floor)
  }

  /// The size a cell reports for content that measured `content` against `proposedWidth`.
  ///
  /// The width is the proposal when it is a real one (finite, non-negative) — what a
  /// `.fractionalWidth(1)` row asks for — else the content's own width; the height is the
  /// content's. Each is made finite and non-negative (a non-finite value becomes 0), and the
  /// height is capped at ``maximumCellHeight``.
  public static func reportedSize(content: CGSize, proposedWidth: CGFloat?) -> CGSize {
    let width: CGFloat
    if let proposedWidth, proposedWidth.isFinite, proposedWidth >= 0 {
      width = proposedWidth
    } else {
      width = sanitized(content.width)
    }
    return CGSize(width: width, height: min(sanitized(content.height), maximumCellHeight))
  }

  /// `value` when finite and positive, else 0 (NaN, ±infinity and negatives all become 0).
  private static func sanitized(_ value: CGFloat) -> CGFloat {
    value.isFinite ? max(value, 0) : 0
  }
}
