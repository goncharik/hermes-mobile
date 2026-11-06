import Foundation

/// What the widgets and the aggregate Live Activity show, derived purely from what the app
/// already knows: the session list's unfiltered rows, the needs-input set and the live slot's
/// running flag. The ONE source both surfaces sync from (`AppFeature.State.agentStatus`).
///
/// Carries no timestamps of its own (`freshUntil` and "now" are stamped at write time), so the
/// `agentStatus` edge fires only on a real change.
public struct AgentStatusProjection: Equatable, Sendable {
  /// The top `WidgetSessionSnapshot.maxRows` interactive sessions, in display order:
  /// needs-input, then working, then `updatedAt` newest first.
  public var rows: [WidgetSessionRow]
  /// Interactive sessions that need input or are working — the whole list, not just `rows`.
  public var activeCount: Int
  /// The "Show session titles" pref. Kept here (not applied to `rows`) so flipping it is a
  /// projection change: the Live Activity drops the title, the Home Screen widgets don't.
  public var showsTitles: Bool

  public init(rows: [WidgetSessionRow], activeCount: Int, showsTitles: Bool) {
    self.rows = rows
    self.activeCount = activeCount
    self.showsTitles = showsTitles
  }

  /// The session the Live Activity headlines: the first row when it is active (rows sort
  /// needs-input, then working, first); `nil` when nothing is active.
  public var headline: WidgetSessionRow? {
    rows.first.flatMap { Self.isActive($0) ? $0 : nil }
  }

  /// Builds the projection from a known unfiltered list (an empty one included). "Unknown" —
  /// no unfiltered list yet — is decided before this, by `AppFeature.State.agentStatusInputs`.
  ///
  /// - Parameters:
  ///   - sessions: the list's unfiltered rows (`SessionListFeature.State.statusSessions`).
  ///   - needsInput: `AppFeature.State.needsInputSessionIDs`.
  ///   - slotRunning: the live slot's session id and running flag; it overrides that row's
  ///     polled `isActive` (the slot's events are authoritative). `nil` when there is no slot,
  ///     its id hasn't resolved, or it belongs to another profile than the list.
  ///   - slotSession: the live slot as a row, used only when `sessions` doesn't carry its id
  ///     yet (a new chat the list hasn't fetched since it was created) and the slot is running
  ///     or needs input — so the first turn of a new chat counts at once.
  ///   - showsTitles: the "Show session titles" pref.
  ///   - profile: the list's wire profile, stamped on every row for the `openSession` link.
  public static func make(
    sessions: [Session],
    needsInput: Set<String>,
    slotRunning: (id: String, running: Bool)?,
    slotSession: Session? = nil,
    showsTitles: Bool,
    profile: String?
  ) -> AgentStatusProjection {
    var sessions = sessions
    if let slotSession, let slotRunning, slotSession.id == slotRunning.id,
      slotRunning.running || needsInput.contains(slotSession.id),
      !sessions.contains(where: { $0.id == slotSession.id }) {
      sessions.append(slotSession)
    }
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
          workspace: session.workspaceName,
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
    return AgentStatusProjection(
      rows: Array(ranked.prefix(WidgetSessionSnapshot.maxRows)),
      activeCount: ranked.filter(isActive).count,
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

  private static func isActive(_ row: WidgetSessionRow) -> Bool {
    row.status == .needsInput || row.status == .working
  }

  private static func rank(_ status: SessionStatus) -> Int {
    switch status {
    case .needsInput: 0
    case .working: 1
    case .unread, .idle: 2
    }
  }
}
