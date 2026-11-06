import Foundation

/// Local-only freshness for the widgets. The app vouches for a snapshot until `freshUntil`
/// (8 h while foregrounded, seconds once backgrounded); past it nothing observes the agents,
/// so a working / needs-input row shows "outdated" instead of a guess.
public enum WidgetStaleness {
  /// A row's trailing glyph.
  public enum RowGlyph: Equatable, Sendable {
    case working
    case needsInput
    /// Was working or needed input when the app last looked, which is no longer known.
    case outdated
    /// Nothing to show (idle or unread).
    case none
  }

  /// Whether `snapshot` is past its freshness at `now`. Exactly at `freshUntil` it is
  /// already outdated: the timeline's "outdated" entry is dated `freshUntil` and must render
  /// as such.
  public static func isOutdated(_ snapshot: WidgetSessionSnapshot, at now: Date) -> Bool {
    now >= snapshot.freshUntil
  }

  /// What a row's trailing glyph shows at `now`: working / needs-input become `.outdated` once
  /// the snapshot is; idle and unread rows show nothing either way.
  public static func displayStatus(
    _ row: WidgetSessionRow,
    snapshot: WidgetSessionSnapshot,
    at now: Date
  ) -> RowGlyph {
    let live: RowGlyph
    switch row.status {
    case .working: live = .working
    case .needsInput: live = .needsInput
    case .unread, .idle: return .none
    }
    return isOutdated(snapshot, at: now) ? .outdated : live
  }
}
