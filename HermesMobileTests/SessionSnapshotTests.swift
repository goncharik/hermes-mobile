import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class SessionSnapshotTests: SnapshotTestCase {
  // MARK: SessionRowView

  /// Identical session fixtures rendered with the working glow off vs on — the only
  /// difference is `isActive`, isolating the brand-tinted pulse the list shows while the
  /// agent is working a session (state-sync Task 10). The glow is driven by the
  /// event-driven `runningChanged` delegate (instant clear) with the poll as backstop.
  private func glowFixtureSession() -> Session {
    Session(
      id: "20260610_120231_afcca6",
      title: "Refactor the streaming parser",
      updatedAt: Date(timeIntervalSince1970: 1_749_599_700)
    )
  }

  func testSessionRow_glowOff() {
    let view = SessionRowView(session: glowFixtureSession(), now: now, isActive: false)
      .padding()
      .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessionRow_glowOn() {
    let view = SessionRowView(session: glowFixtureSession(), now: now, isActive: true)
      .padding()
      .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessionRow() {
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: "Refactor the streaming parser",
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
        preview: "Can you help me refactor the WebSocket JSON-RPC parser?"
      ),
      now: now
    )
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  /// A long title wraps to a second line before truncating. One line loses the part that
  /// distinguishes one session from the next, and the iPad sidebar is narrower than a phone's
  /// full width — rendered here at the sidebar's own width rather than the device's.
  func testSessionRow_longTitleWrapsToTwoLines() {
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: "Dnipro to Bratislava travel options with train changes and border crossings",
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800)
      ),
      now: now
    )
    .padding()
    .frame(width: 320)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessionRow_active() {
    // A session the agent is currently working — renders the brand-tinted glow.
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: "Refactor the streaming parser",
        updatedAt: Date(timeIntervalSince1970: 1_749_599_700),
        isActive: true
      ),
      now: now,
      isActive: true
    )
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessionRow_searchResult() {
    // A search result: no title, `id` is a meaningless stored id, so the snippet is
    // promoted to the headline instead of showing the raw id.
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: nil,
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
        preview: "Can you help me refactor the WebSocket JSON-RPC parser?"
      ),
      now: now,
      showsPreview: true
    )
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testSessionRow_untitledPromotesPreview() {
    // In the grouped list (showsPreview: false) a session with the server's "Untitled"
    // placeholder and no real title promotes its first-message preview to the headline —
    // it must never render the raw id (#13).
    let view = SessionRowView(
      session: Session(
        id: "20260610_120231_afcca6",
        title: "Untitled",
        updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
        preview: "Run the nightly backup and email me the report"
      ),
      now: now
    )
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: SessionListView

  func testSessionList() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    // 6 sessions in one workspace (triggers "Show more"), 1 in another.
    var sessions: [Session] = (0..<6).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass",
                      "Model picker", "Workspace grouping", "Unread badges"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    sessions.append(
      Session(id: "a1", title: nil,
              updatedAt: Date(timeIntervalSince1970: 1_749_300_000),
              cwd: "/Users/me/dev/hermes-agent",
              startedAt: Date(timeIntervalSince1970: 1_749_300_000), messageCount: 4)
    )
    // m0 has new activity since last seen (10 > 7) → unread; the rest are read.
    var seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })
    seen["m0"] = 7

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            expandedGroups: [mobile]
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// The transient "Session ID copied" toast (`CopiedToastView`) shown after the row
  /// context menu's Copy ID — a bottom overlay that floats above the "New chat" bar.
  func testSessionList_copiedIDToast() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<3).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            copiedIDToastToken: 1
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  func testSessionList_pinnedSection() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<4).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP",
                      "UX polish pass", "Workspace grouping"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            pinnedIDs: ["m1"] // "Plan the iOS MVP" floats to the top Pinned section
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  func testSessionList_chronological() {
    let now = self.now
    // Two workspaces, but chronological mode shows one flat recency-ordered list.
    let sessions: [Session] = (0..<5).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass",
                      "Model picker", "Workspace grouping"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: i.isMultiple(of: 2) ? "/Users/me/dev/hermes-mobile" : "/Users/me/dev/hermes-agent",
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            groupingMode: .chronological
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Branch nesting (#34): a parent session with two branch children renders the children
  /// nested underneath with desktop-style elbow stems — newest sibling first (`├─`), last
  /// sibling `└─` — indented, in the parent's workspace group; an unrelated session stays
  /// a normal top-level row below the cluster.
  func testSessionList_branchNesting() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = [
      Session(id: "m0", title: "Refactor the streaming parser",
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800),
              messageCount: 10),
      // Two branches of m0 — b1 is fresher, so it renders first with the middle stem.
      Session(id: "b1", title: "Try an actor-isolated fold",
              updatedAt: Date(timeIntervalSince1970: 1_749_553_200),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_553_200),
              messageCount: 4,
              parentSessionID: "m0"),
      Session(id: "b2", title: "Alternative delta parser",
              updatedAt: Date(timeIntervalSince1970: 1_749_549_600),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_549_600),
              messageCount: 3,
              parentSessionID: "m0"),
      Session(id: "m1", title: "Plan the iOS MVP",
              updatedAt: Date(timeIntervalSince1970: 1_749_470_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_470_400),
              messageCount: 10),
    ]
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            expandedGroups: [mobile]
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  // MARK: Selected-row highlight (iPad sidebar, #80)

  /// The list as the split view's sidebar column renders it: `highlightedSessionID` tints
  /// the row of the session open in the detail column (`SelectedRowBackground`) — the
  /// middle row here, so both plain neighbours show the untouched default background.
  /// Rendered with `deviceImage()` like every other list snapshot: the device layout pins
  /// BOTH dimensions of the scrollable `List`, and the key-window host is what lays the
  /// rows out at all — a `.sizeThatFits` layer render of this list paints the section
  /// header and the FAB but no rows (tried first; the recorded image had no highlight to
  /// show). The phone width stands in for the 320pt sidebar; the tint is what's under test.
  private func highlightedListHost() -> some View {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<3).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    return NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            expandedGroups: [mobile]
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        },
        highlightedSessionID: "m1" // "Plan the iOS MVP" is open in the detail column
      )
    }
  }

  func testSessionList_highlightedRow() {
    assertSnapshot(of: highlightedListHost(), as: deviceImage())
  }

  /// The same highlight over a light background — the accent wash is the case most likely
  /// to read wrong (too loud, or invisible) in the other appearance.
  func testSessionList_highlightedRow_light() {
    assertSnapshot(of: highlightedListHost(), as: deviceImage(appearance: .light))
  }

  // MARK: Cron Jobs section

  /// A mix of interactive + cron sessions: the cron rows are pulled out into a dedicated
  /// "Cron Jobs" section (Clock icon) below the interactive workspace groups, in workspace
  /// grouping mode.
  func testSessionList_cronSection() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    // 3 interactive sessions in one workspace.
    var sessions: [Session] = (0..<3).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    // 2 cron sessions — recency-ordered into their own Cron Jobs section.
    sessions.append(contentsOf: (0..<2).map { i in
      Session(id: "c\(i)",
              title: ["Nightly backup", "Weekly digest"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_540_000 - Double(i) * 3_600),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_540_000 - Double(i) * 3_600),
              messageCount: 5,
              source: "cron")
    })
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            expandedGroups: [mobile]
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Fixtures for the GROUPED Cron Jobs section (#24): two jobs (one scheduled with a
  /// 7-hour countdown, one paused) plus their run sessions; the newest backup run has
  /// unseen output, so the job row shows the unread dot and the header badge reads 1.
  private func cronGroupedFixtures() -> (sessions: [Session], jobs: [CronJob], seen: [String: Int]) {
    let interactive = Session(
      id: "m0", title: "Refactor the streaming parser",
      updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
      cwd: "/Users/me/dev/hermes-mobile",
      startedAt: Date(timeIntervalSince1970: 1_749_556_800),
      messageCount: 10
    )
    let backupRuns = (0..<2).map { i in
      Session(id: "cron_backup01_2026060\(9 - i)_090000",
              title: "Nightly backup",
              updatedAt: Date(timeIntervalSince1970: 1_749_540_000 - Double(i) * 86_400),
              startedAt: Date(timeIntervalSince1970: 1_749_540_000 - Double(i) * 86_400),
              messageCount: 5, source: "cron")
    }
    let digestRun = Session(id: "cron_digest02_20260608_100000",
                            title: "Weekly digest",
                            updatedAt: Date(timeIntervalSince1970: 1_749_400_000),
                            startedAt: Date(timeIntervalSince1970: 1_749_400_000),
                            messageCount: 3, source: "cron")
    let jobs = [
      // now = 1_749_600_000 → next run in 7 hours ("Next in 7 hr.").
      CronJob(id: "backup01", name: "Nightly backup", state: "scheduled",
              nextRunAt: Date(timeIntervalSince1970: 1_749_600_000 + 7 * 3_600)),
      CronJob(id: "digest02", name: "Weekly digest", scheduleDisplay: "every Monday at 10:00",
              state: "paused"),
    ]
    var seen = Dictionary(
      uniqueKeysWithValues: ([interactive] + backupRuns + [digestRun]).map { ($0.id, $0.messageCount ?? 0) }
    )
    seen[backupRuns[0].id] = 2  // newest backup run has unseen output → unread dot + badge 1
    return ([interactive] + backupRuns + [digestRun], jobs, seen)
  }

  /// Grouped Cron Jobs section, collapsed: job rows with state dots (accent scheduled,
  /// amber paused), the 7-hour countdown, the paused job's schedule line, the unread dot
  /// on the backup job, and the header's aggregate unread badge.
  func testSessionList_cronJobsGrouped() {
    let now = self.now
    let (sessions, jobs, seen) = cronGroupedFixtures()
    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            groupingMode: .chronological,
            cronJobs: IdentifiedArray(uniqueElements: jobs)
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.hermesREST.cronJobs = { _, _ in jobs }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Grouped Cron Jobs section with the backup job's inline peek expanded: its runs render
  /// indented via the standard row builder, the unread run keeps its dot, and the peek is
  /// single-open (the paused job stays collapsed).
  func testSessionList_cronJobsGrouped_expandedPeek() {
    let now = self.now
    let (sessions, jobs, seen) = cronGroupedFixtures()
    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            groupingMode: .chronological,
            cronJobs: IdentifiedArray(uniqueElements: jobs),
            expandedCronJobID: "backup01"
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.hermesREST.cronJobs = { _, _ in jobs }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Old agent (no `/api/cron/jobs` → `cronJobsSupported == false`): the section falls
  /// back to today's flat run rows — but the unread badge still works (one unread run).
  func testSessionList_cronJobsFallbackFlatWithBadge() {
    let now = self.now
    let (sessions, _, seen) = cronGroupedFixtures()
    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            groupingMode: .chronological,
            cronJobsSupported: false
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// The Cron Jobs section is orthogonal to the grouping mode: even in chronological mode
  /// the interactive list stays flat while cron rows still break out into their own section.
  func testSessionList_cronSection_chronological() {
    let now = self.now
    var sessions: [Session] = (0..<4).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass",
                      "Model picker"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: i.isMultiple(of: 2) ? "/Users/me/dev/hermes-mobile" : "/Users/me/dev/hermes-agent",
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    sessions.append(
      Session(id: "c0", title: "Nightly backup",
              updatedAt: Date(timeIntervalSince1970: 1_749_540_000),
              cwd: "/Users/me/dev/hermes-mobile",
              startedAt: Date(timeIntervalSince1970: 1_749_540_000),
              messageCount: 5, source: "cron")
    )
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            groupingMode: .chronological
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Regression guard: with zero cron sessions, no "Cron Jobs" section header renders —
  /// the list is just the interactive sessions (mirrors `testSessionList`'s no-cron
  /// fixture). All sessions here are interactive (`source == nil`).
  func testSessionList_noCronSection() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<3).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            expandedGroups: [mobile]
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  // MARK: Profile pill

  /// A list of fixtures shared by the profile-pill snapshots: a default + two custom
  /// profiles.
  private func profileFixtures() -> [Profile] {
    [
      Profile(name: "default", isDefault: true),
      Profile(name: "work", isDefault: false, skillCount: 3),
      Profile(name: "personal", isDefault: false, skillCount: 1),
    ]
  }

  /// Default state: the profiles API is supported, the default profile is active, so the
  /// principal toolbar shows the house-icon "default" pill.
  func testSessionList_profilePill_default() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<3).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            profiles: IdentifiedArray(uniqueElements: profileFixtures()),
            selectedProfileName: "default",
            profilesSupported: true
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// A custom profile is active — the pill shows the name with no leading house icon.
  func testSessionList_profilePill_customSelected() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<3).map { i in
      Session(id: "w\(i)",
              title: ["Quarterly planning", "Standup notes", "Roadmap review"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 8)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            profiles: IdentifiedArray(uniqueElements: profileFixtures()),
            selectedProfileName: "work",
            profilesSupported: true
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Menu-open content. SwiftUI `Menu` popovers don't render in the snapshot host, so this
  /// captures the menu's logical content inline — the same rows the pill's `Menu` builds:
  /// the default profile (with a checkmark on the active one), each custom profile, a
  /// divider, then the "Add profile" row.
  func testSessionList_profileMenu_content() {
    let profiles = profileFixtures()
    // Mirrors the production `profileMenuContent`: no checkmarks (Safari-style) — the
    // default profile shows a house, custom profiles a neutral person glyph. The active
    // profile is indicated by the pill title, not a menu checkmark.
    let view = List {
      ForEach(profiles) { profile in
        if profile.isDefault {
          Label(profile.name, systemImage: "house")
        } else {
          Label(profile.name, systemImage: "person.crop.circle")
        }
      }
      Divider()
      Label("Add profile", systemImage: "plus")
    }
    .listStyle(.plain)
    .frame(width: device.size?.width ?? 390, height: 240)
    assertSnapshot(of: view, as: componentImage())
  }

  /// Fallback: the agent doesn't expose `/api/profiles` (`profilesSupported == false`), so
  /// no profile pill renders — just the "Sessions" list section header and toolbar icons.
  func testSessionList_profilePill_unsupportedFallback() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let sessions: [Session] = (0..<3).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10)
    }
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            seenCounts: seen,
            profilesSupported: false
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  // MARK: BottomActionSheetView

  /// The archive/delete confirmation's content as the custom bottom action sheet renders
  /// it (#73): title, wrapped message, destructive action in red over a plain Cancel. The
  /// sheet chrome (detent, dimming) is presentation-only; the content is what's ours.
  func testBottomActionSheet_archiveConfirmation() {
    let dialog = ConfirmationDialogState<SessionListFeature.Action.Dialog> {
      TextState("Archive session?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchive(id: "s1")) {
        TextState("Archive")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("This hides the session from the list. You can restore it from the server.")
    }
    let view = BottomActionSheetView(
      store: Store(initialState: dialog) {
        EmptyReducer<
          ConfirmationDialogState<SessionListFeature.Action.Dialog>,
          SessionListFeature.Action.Dialog
        >()
      }
    )
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: ArchivedSessionsView

  func testArchivedSessions() {
    let now = self.now
    let sessions: [Session] = [
      Session(id: "x0", title: "Old experiment",
              updatedAt: Date(timeIntervalSince1970: 1_749_300_000),
              cwd: "/Users/me/dev/hermes-mobile", messageCount: 6),
      Session(id: "x1", title: "Scratch session",
              updatedAt: Date(timeIntervalSince1970: 1_749_200_000),
              cwd: "/Users/me/dev/hermes-agent", messageCount: 3),
    ]
    let view = NavigationStack {
      ArchivedSessionsView(
        store: Store(
          initialState: ArchivedSessionsFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now
          )
        ) {
          ArchivedSessionsFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.archivedSessions = { _, _, _ in sessions }
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// The copied-ID toast inside the Archived sheet, whose `List` has no bottom
  /// `safeAreaInset` — this is the screen that proves `CopiedToastView`'s
  /// `.safeAreaPadding(.bottom)` keeps the capsule clear of the home indicator.
  /// (The faint capsule silhouette at the very top edge is a deterministic offscreen-render
  /// artifact of the iOS 26 nav-bar glass backdrop sampling the bottom-most content — it
  /// tracks the toast's position and is not a second toast.)
  func testArchivedSessions_copiedIDToast() {
    let now = self.now
    let sessions: [Session] = [
      Session(id: "x0", title: "Old experiment",
              updatedAt: Date(timeIntervalSince1970: 1_749_300_000),
              cwd: "/Users/me/dev/hermes-mobile", messageCount: 6),
      Session(id: "x1", title: "Scratch session",
              updatedAt: Date(timeIntervalSince1970: 1_749_200_000),
              cwd: "/Users/me/dev/hermes-agent", messageCount: 3),
    ]
    let view = NavigationStack {
      ArchivedSessionsView(
        store: Store(
          initialState: ArchivedSessionsFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            copiedIDToastToken: 1
          )
        ) {
          ArchivedSessionsFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.archivedSessions = { _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  func testArchivedSessions_empty() {
    let now = self.now
    let view = NavigationStack {
      ArchivedSessionsView(
        store: Store(
          initialState: ArchivedSessionsFeature.State(
            connection: ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t"),
            now: now
          )
        ) {
          ArchivedSessionsFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.archivedSessions = { _, _, _ in [] }
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }
}
