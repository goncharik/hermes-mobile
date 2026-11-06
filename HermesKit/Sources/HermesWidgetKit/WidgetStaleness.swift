import Foundation

/// Local-only freshness for the widgets. The app vouches for a snapshot until `freshUntil`
/// (8 h while foregrounded, seconds once backgrounded); past it nothing observes the agents,
/// so a working / needs-input row shows "outdated" instead of a guess.
public enum WidgetStaleness {
  /// Whether `snapshot` is past its freshness at `now`. Exactly at `freshUntil` it is
  /// already outdated: the timeline's "outdated" entry is dated `freshUntil` and must render
  /// as such.
  public static func isOutdated(_ snapshot: WidgetSessionSnapshot, at now: Date) -> Bool {
    now >= snapshot.freshUntil
  }

  /// What a row's trailing glyph shows at `now`, in the Live Activity's vocabulary:
  /// working / needs-input become `.outdated` once the snapshot is; idle and unread rows show
  /// nothing (`nil`) either way.
  public static func glyph(
    for row: WidgetSessionRow,
    snapshot: WidgetSessionSnapshot,
    at now: Date
  ) -> AgentActivityContent.DisplayStatus? {
    let live: AgentActivityContent.DisplayStatus
    switch row.status {
    case .working: live = .working
    case .needsInput: live = .needsInput
    case .unread, .idle: return nil
    }
    return isOutdated(snapshot, at: now) ? .outdated : live
  }

  /// The dates of the sessions widget's timeline entries for `snapshot` read at `now`: the
  /// entry for now, plus an "outdated" entry at `freshUntil` while that is still ahead. Past
  /// it, the one entry already renders outdated. The timeline's policy is `.never` — the app
  /// reloads it after every mirror write.
  public static func timelineDates(for snapshot: WidgetSessionSnapshot, at now: Date) -> [Date] {
    snapshot.freshUntil > now ? [now, snapshot.freshUntil] : [now]
  }
}
