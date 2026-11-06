import Foundation

/// What the widgets and the aggregate Live Activity show, derived purely from what the app
/// already knows: the session list's unfiltered rows, the needs-input set and the live slot's
/// running flag. The ONE source both surfaces sync from (`AppFeature.State.agentStatus`).
///
/// Carries no timestamps of its own (`freshUntil` and "now" are stamped at write time), so the
/// `.onChange(of: \.agentStatus)` edge fires only on a real change.
public struct AgentStatusProjection: Equatable, Sendable {
  /// The top `WidgetSessionSnapshot.maxRows` interactive sessions, in display order:
  /// needs-input, then working, then `updatedAt` newest first.
  public var rows: [WidgetSessionRow]
  /// Interactive sessions that need input or are working — the whole list, not just `rows`.
  public var activeCount: Int
  /// The session the Live Activity headlines: the first needs-input row, else the first
  /// working row; `nil` when nothing is active.
  public var headline: WidgetSessionRow?
  /// The "Show session titles" pref. Kept here (not applied to `rows`) so flipping it is a
  /// projection change: the Live Activity drops the title, the Home Screen widgets don't.
  public var showsTitles: Bool

  public init(
    rows: [WidgetSessionRow],
    activeCount: Int,
    headline: WidgetSessionRow?,
    showsTitles: Bool
  ) {
    self.rows = rows
    self.activeCount = activeCount
    self.headline = headline
    self.showsTitles = showsTitles
  }

  /// Builds the projection, or `nil` ("unknown") while there is no unfiltered list yet — a
  /// cached guess must never start anything, so the surfaces hold until the first fetch.
  ///
  /// - Parameters:
  ///   - sessions: the list's unfiltered rows (`SessionListFeature.State.statusSessions`).
  ///   - needsInput: `AppFeature.State.needsInputSessionIDs`.
  ///   - slotRunning: the live slot's session id and running flag; it overrides that row's
  ///     polled `isActive` (the slot's events are authoritative). `nil` when there is no slot,
  ///     its id hasn't resolved, or it belongs to another profile than the list.
  ///   - showsTitles: the "Show session titles" pref.
  ///   - profile: the list's wire profile, stamped on every row for the `openSession` link.
  public static func make(
    sessions: [Session]?,
    needsInput: Set<String>,
    slotRunning: (id: String, running: Bool)?,
    showsTitles: Bool,
    profile: String?
  ) -> AgentStatusProjection? {
    guard let sessions else { return nil }
    let ranked = sessions.enumerated()
      .filter { !$0.element.isCron }
      .map { offset, session in
        let isWorking = slotRunning?.id == session.id
          ? slotRunning?.running == true
          : session.isActive == true
        let status = SessionStatus(
          needsInput: needsInput.contains(session.id),
          isWorking: isWorking,
          // The widgets paint no unread state; leaving it out keeps a read/unread flip from
          // churning the mirror.
          isUnread: false
        )
        return (offset: offset, row: WidgetSessionRow(
          id: session.id,
          title: session.displayName,
          workspace: session.cwd?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? session.workspaceLabel : nil,
          status: status,
          updatedAt: session.updatedAt,
          profile: profile
        ))
      }
      .sorted { lhs, rhs in
        let lhsRank = rank(lhs.row.status), rhsRank = rank(rhs.row.status)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        let lhsDate = lhs.row.updatedAt ?? .distantPast
        let rhsDate = rhs.row.updatedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.offset < rhs.offset  // server order breaks ties: deterministic
      }
      .map(\.row)
    let isActive: (WidgetSessionRow) -> Bool = { $0.status == .needsInput || $0.status == .working }
    return AgentStatusProjection(
      rows: Array(ranked.prefix(WidgetSessionSnapshot.maxRows)),
      activeCount: ranked.filter(isActive).count,
      // Sorted needs-input first, so the first active row is the headline.
      headline: ranked.first.flatMap { isActive($0) ? $0 : nil },
      showsTitles: showsTitles
    )
  }

  /// The aggregate Live Activity's content, or `nil` when nothing is active (the activity
  /// ends). The headline's title is omitted when "Show session titles" is off; the view then
  /// falls back to the workspace.
  public var activityContent: AgentActivityContent? {
    guard activeCount > 0, let headline else { return nil }
    return AgentActivityContent(
      activeCount: activeCount,
      headlineTitle: showsTitles ? headline.title : nil,
      headlineWorkspace: headline.workspace,
      headlineSessionID: headline.id,
      headlineProfile: headline.profile,
      status: headline.status == .needsInput ? .needsInput : .working
    )
  }

  private static func rank(_ status: SessionStatus) -> Int {
    switch status {
    case .needsInput: 0
    case .working: 1
    case .unread, .idle: 2
    }
  }
}
