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

  func testSessionRow_untitledPromotesPreview() {
    // A session with the server's "Untitled" placeholder and no real title promotes its
    // first-message preview to the headline — it must never render the raw id (#13).
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

  // MARK: SessionCardView

  /// The inbox card's full anatomy: workspace (cwd basename) + age header, title, preview
  /// line, and the model · message-count footer. Variants below change one input each.
  private func cardFixtureSession(
    title: String? = "Refactor the streaming parser",
    preview: String? = "Can you help me refactor the WebSocket JSON-RPC parser?",
    cwd: String? = "/Users/eugene/Developer/hermes-mobile",
    messageCount: Int? = 12,
    model: String? = "claude-sonnet-4-5"
  ) -> Session {
    Session(
      id: "20260610_120231_afcca6",
      title: title,
      updatedAt: Date(timeIntervalSince1970: 1_749_599_700),
      preview: preview,
      cwd: cwd,
      messageCount: messageCount,
      model: model
    )
  }

  private func assertCardSnapshot(
    _ card: SessionCardView,
    width: CGFloat? = nil,
    testName: String = #function,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let view = card
      .padding()
      .frame(width: width ?? device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage(), file: file, testName: testName, line: line)
  }

  func testSessionCard_titled() {
    assertCardSnapshot(SessionCardView(session: cardFixtureSession(), now: now))
  }

  /// An untitled session (server "Untitled" placeholder) promotes its preview into the title
  /// slot and drops the preview line — the same text must never render twice.
  func testSessionCard_untitledPromotesPreview() {
    assertCardSnapshot(SessionCardView(session: cardFixtureSession(title: "Untitled"), now: now))
  }

  func testSessionCard_unread() {
    assertCardSnapshot(SessionCardView(session: cardFixtureSession(), now: now, isUnread: true))
  }

  func testSessionCard_pinned() {
    assertCardSnapshot(SessionCardView(session: cardFixtureSession(), now: now, isPinned: true))
  }

  func testSessionCard_workingGlow() {
    assertCardSnapshot(SessionCardView(session: cardFixtureSession(), now: now, isActive: true))
  }

  /// A pending approval outranks the running turn: the status dot turns amber while the glow
  /// still marks the turn as live.
  func testSessionCard_needsInput() {
    assertCardSnapshot(
      SessionCardView(session: cardFixtureSession(), now: now, isActive: true, needsInput: true)
    )
  }

  /// Older agent (no `model`) and zero messages: the whole footer line is omitted, and a
  /// missing `cwd` reads "No workspace".
  func testSessionCard_noFooter() {
    assertCardSnapshot(
      SessionCardView(
        session: cardFixtureSession(cwd: nil, messageCount: 0, model: nil),
        now: now
      )
    )
  }

  func testSessionCard_branchStem() {
    assertCardSnapshot(
      SessionCardView(
        session: cardFixtureSession(title: "Try the incremental decoder instead", messageCount: 1),
        now: now,
        branchStem: "└─ "
      )
    )
  }

  /// A long title wraps to a second line before truncating — rendered at the 320pt iPad
  /// sidebar width, where one line would lose the distinguishing part.
  func testSessionCard_longTitleWrapsToTwoLines() {
    assertCardSnapshot(
      SessionCardView(
        session: cardFixtureSession(
          title: "Dnipro to Bratislava travel options with train changes and border crossings"
        ),
        now: now
      ),
      width: 320
    )
  }

  // MARK: SessionListView

  /// The calendar every list snapshot buckets its date sections with — Gregorian, UTC,
  /// Monday-first, en_US — so the headers never follow the simulator's time zone or locale.
  /// Against `now` (Wed 11 Jun 2025 00:00 UTC, i.e. nominal day Tue 10 Jun under the 4 AM
  /// rollover) the fixtures' 1_749_556_800 − n days land in Today (n = 0), Yesterday (1), and
  /// Last week (2…).
  private var listCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = 2
    return calendar
  }

  /// The default list: interactive sessions as inbox cards split into Today / Yesterday /
  /// Last week sections; one unread card, one from a second workspace, and footers with and
  /// without a model.
  func testSessionList() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    var sessions: [Session] = (0..<6).map { i in
      Session(id: "m\(i)",
              title: ["Refactor the streaming parser", "Plan the iOS MVP", "UX polish pass",
                      "Model picker", "Workspace grouping", "Unread badges"][i],
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              cwd: mobile,
              startedAt: Date(timeIntervalSince1970: 1_749_556_800 - Double(i) * 86_400),
              messageCount: 10,
              model: i.isMultiple(of: 2) ? "claude-sonnet-4-5" : nil)
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
            calendar: listCalendar,
            seenCounts: seen
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
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
            calendar: listCalendar,
            seenCounts: seen,
            copiedIDToastToken: 1
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
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
            calendar: listCalendar,
            seenCounts: seen,
            pinnedIDs: ["m1"] // "Plan the iOS MVP" floats to the top Pinned section
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Branch nesting (#34): a parent session with two branch children renders the children
  /// nested underneath with desktop-style elbow stems — newest sibling first (`├─`), last
  /// sibling `└─` — indented, in the parent's date section; an unrelated session stays
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
            calendar: listCalendar,
            seenCounts: seen
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// The date-section anatomy end to end: a pinned card on top (its own stale date never
  /// opens a section), then Today (a parent with a nested branch card — the cluster stays in
  /// one section), Yesterday, Last week, and a prior-year "December 2024" section.
  func testSessionList_dateSections() {
    let now = self.now
    let mobile = "/Users/me/dev/hermes-mobile"
    let agent = "/Users/me/dev/hermes-agent"
    let sessions: [Session] = [
      Session(id: "p0", title: "Release checklist",
              updatedAt: Date(timeIntervalSince1970: 1_749_124_800), // Thu 5 Jun 12:00
              preview: "Walk me through the TestFlight upload steps",
              cwd: mobile, messageCount: 18, model: "claude-opus-4-1"),
      Session(id: "t0", title: "Refactor the streaming parser",
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800), // Tue 10 Jun 12:00
              preview: "Can you help me refactor the WebSocket JSON-RPC parser?",
              cwd: mobile, messageCount: 12, model: "claude-sonnet-4-5"),
      Session(id: "t1", title: "Try an actor-isolated fold",
              updatedAt: Date(timeIntervalSince1970: 1_749_553_200), // Tue 10 Jun 11:00
              cwd: mobile, messageCount: 4,
              parentSessionID: "t0", model: "claude-sonnet-4-5"),
      Session(id: "y0", title: "Plan the iOS MVP",
              updatedAt: Date(timeIntervalSince1970: 1_749_481_200), // Mon 9 Jun 15:00
              preview: "What should the first TestFlight build include?",
              cwd: agent, messageCount: 7),
      Session(id: "w0", title: "Untitled",
              updatedAt: Date(timeIntervalSince1970: 1_749_038_400), // Wed 4 Jun 12:00
              preview: "Summarise the open pull requests",
              cwd: agent, messageCount: 3, model: "gpt-5"),
      Session(id: "d0", title: "Holiday travel options",
              updatedAt: Date(timeIntervalSince1970: 1_734_264_000), // Sun 15 Dec 2024 12:00
              messageCount: 9),
    ]
    let seen = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messageCount ?? 0) })

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            calendar: listCalendar,
            seenCounts: seen,
            pinnedIDs: ["p0"]
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    // Taller than one phone screen so every header down to "December 2024" is in frame.
    assertSnapshot(of: view, as: deviceImage(height: 1250))
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
            calendar: listCalendar,
            seenCounts: seen
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
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

  // MARK: Bottom-bar tabs + Cron Jobs tab

  /// A mix of interactive + cron sessions on the Sessions tab: the cron rows stay out of the
  /// date sections, and the bottom bar shows the Sessions | Cron Jobs tab pill (Sessions
  /// selected) beside the New chat button.
  func testSessionList_sessionsTabWithTabBar() {
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
    // The jobs behind those runs: with the jobs API, jobs (not runs) bring up the tab pill.
    let jobs = [CronJob(id: "backup", name: "Nightly backup"), CronJob(id: "digest", name: "Weekly digest")]

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            calendar: listCalendar,
            seenCounts: seen,
            cronJobs: IdentifiedArray(uniqueElements: jobs)
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
          $0.hermesREST.cronJobs = { _, _ in jobs }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Fixtures for the Cron Jobs tab (#24, desktop parity): four jobs, one per status caption
  /// (active "Next in 7 hr.", "Paused", "Error", "Overdue · 2 hr. ago"), plus their run
  /// sessions under upstream's `local-*` ids (the job binding is NOT in the id). The newest
  /// backup run has unseen output, so its run row carries the unread dot when expanded.
  private func cronFixtures() -> (sessions: [Session], jobs: [CronJob], seen: [String: Int]) {
    let interactive = Session(
      id: "m0", title: "Refactor the streaming parser",
      updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
      cwd: "/Users/me/dev/hermes-mobile",
      startedAt: Date(timeIntervalSince1970: 1_749_556_800),
      messageCount: 10
    )
    let runs = cronBackupRuns() + [
      Session(id: "local-20260608_100000_d1g3s7",
              title: "Weekly digest",
              updatedAt: Date(timeIntervalSince1970: 1_749_400_000),
              startedAt: Date(timeIntervalSince1970: 1_749_400_000),
              messageCount: 3, source: "cron"),
    ]
    let jobs = [
      // now = 1_749_600_000 → next run in 7 hours ("Next in 7 hr.").
      CronJob(id: "backup01", name: "Nightly backup", state: "scheduled",
              nextRunAt: Date(timeIntervalSince1970: 1_749_600_000 + 7 * 3_600)),
      CronJob(id: "digest02", name: "Weekly digest", scheduleDisplay: "every Monday at 10:00",
              state: "paused",
              nextRunAt: Date(timeIntervalSince1970: 1_749_600_000 + 3_600)),
      CronJob(id: "sync03", name: "Inbox sync", scheduleDisplay: "every 30 minutes",
              state: "error"),
      // Two hours past its next run — beyond the 15 min grace → "Overdue · 2 hr. ago".
      CronJob(id: "report04", name: "Morning report", state: "scheduled",
              nextRunAt: Date(timeIntervalSince1970: 1_749_600_000 - 2 * 3_600)),
    ]
    var seen = Dictionary(
      uniqueKeysWithValues: ([interactive] + runs).map { ($0.id, $0.messageCount ?? 0) }
    )
    seen[runs[0].id] = 2  // newest backup run has unseen output → unread dot on its run row
    return ([interactive] + runs, jobs, seen)
  }

  /// The backup job's two session runs, newest first (also in the list's cron slice).
  private func cronBackupRuns() -> [Session] {
    (0..<2).map { i in
      Session(id: "local-2026060\(9 - i)_072000_b4ck\(i)p",
              title: "Nightly backup",
              updatedAt: Date(timeIntervalSince1970: 1_749_540_000 - Double(i) * 86_400),
              startedAt: Date(timeIntervalSince1970: 1_749_540_000 - Double(i) * 86_400),
              messageCount: 5, source: "cron")
    }
  }

  /// The Cron Jobs tab hosted over `cronFixtures()` with the given cron state.
  private func cronTabHost(
    cronJobsSupported: Bool = true,
    expandedCronJobID: String? = nil,
    expandedCronRuns: [Session]? = nil,
    expandedCronRunsFailed: Bool = false
  ) -> some View {
    let now = self.now
    let (sessions, jobs, seen) = cronFixtures()
    return NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            calendar: listCalendar,
            seenCounts: seen,
            selectedTab: .cron,
            cronJobs: cronJobsSupported ? IdentifiedArray(uniqueElements: jobs) : [],
            cronJobsSupported: cronJobsSupported,
            expandedCronJobID: expandedCronJobID,
            expandedCronRuns: expandedCronRuns,
            expandedCronRunsFailed: expandedCronRunsFailed
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
          $0.hermesREST.cronJobs = { _, _ in jobs }
          $0.hermesREST.cronJobRuns = { _, _, _, _ in expandedCronRuns ?? [] }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
  }

  /// The Cron Jobs tab lists job rows only (desktop parity): one per status — state dots
  /// (green active, amber paused, red error), the captions "Next in 7 hr.",
  /// "Paused", "Error" and the orange "Overdue · 2 hr. ago". No run rows, no unread dot on
  /// any job, and no unread badge on the tab pill.
  func testSessionList_cronJobs_statuses() {
    assertSnapshot(of: cronTabHost(), as: deviceImage())
  }

  /// The backup job expanded: its runs (from `/runs`) render indented as timestamp-only rows —
  /// the newest session run with the unread dot, the older one plain, and a script-only
  /// `cron_output` run as secondary text. Single-open: the other jobs stay collapsed.
  func testSessionList_cronJobs_expandedRuns() {
    let scriptRun = Session(id: "cron_output:backup01:20260608_072000",
                            updatedAt: Date(timeIntervalSince1970: 1_749_540_000 - 2 * 86_400),
                            source: "cron_output")
    assertSnapshot(
      of: cronTabHost(expandedCronJobID: "backup01",
                      expandedCronRuns: cronBackupRuns() + [scriptRun]),
      as: deviceImage()
    )
  }

  /// The backup job expanded before its first `/runs` load lands: a spinner under the job.
  func testSessionList_cronJobs_expandedLoading() {
    assertSnapshot(of: cronTabHost(expandedCronJobID: "backup01"), as: deviceImage())
  }

  /// The backup job expanded after its first `/runs` load failed: "Couldn't load runs".
  func testSessionList_cronJobs_expandedFailed() {
    assertSnapshot(
      of: cronTabHost(expandedCronJobID: "backup01", expandedCronRunsFailed: true),
      as: deviceImage()
    )
  }

  /// The backup job expanded with no runs on the server: "No runs yet".
  func testSessionList_cronJobs_expandedEmpty() {
    assertSnapshot(
      of: cronTabHost(expandedCronJobID: "backup01", expandedCronRuns: []),
      as: deviceImage()
    )
  }

  /// Old agent (no `/api/cron/jobs` → `cronJobsSupported == false`): the Cron Jobs tab falls
  /// back to flat run rows, with no unread badge on the tab pill.
  func testSessionList_cronJobsFallbackFlat() {
    assertSnapshot(of: cronTabHost(cronJobsSupported: false), as: deviceImage())
  }

  // MARK: Search results

  /// The search button's open state with nothing typed yet: the nav bar row gives way to the
  /// glass search field and the round close button, and the tab pill hides.
  func testSessionList_searchOpen() {
    let now = self.now
    let (sessions, jobs, seen) = cronFixtures()
    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            now: now,
            calendar: listCalendar,
            seenCounts: seen,
            isSearchPresented: true,
            cronJobs: IdentifiedArray(uniqueElements: jobs)
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
          $0.hermesREST.cronJobs = { _, _ in jobs }
          $0.continuousClock = ImmediateClock()
          $0.date = .constant(now)
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Search results are flat cards (no date sections). The rows mirror the search DTO's
  /// shape — no title or workspace, the match snippet as `preview` — so the snippet is
  /// promoted into the card's title slot and the header leaves the workspace out.
  func testSessionList_searchResultsCards() {
    let now = self.now
    let sessions: [Session] = [
      Session(id: "20260610_120231_afcca6",
              updatedAt: Date(timeIntervalSince1970: 1_749_556_800),
              preview: "Can you help me refactor the WebSocket JSON-RPC parser?"),
      Session(id: "20260609_090000_b1c2d3",
              updatedAt: Date(timeIntervalSince1970: 1_749_459_600),
              preview: "The parser drops frames larger than 16 MiB — why?"),
      Session(id: "20260530_180000_e4f5a6",
              updatedAt: Date(timeIntervalSince1970: 1_748_628_000),
              preview: "Write a streaming parser test for partial deltas"),
    ]

    let view = NavigationStack {
      SessionListView(
        store: Store(
          initialState: SessionListFeature.State(
            connection: connection,
            sessions: IdentifiedArray(uniqueElements: sessions),
            searchQuery: "parser",
            now: now,
            calendar: listCalendar,
            isSearchPresented: true
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
          $0.hermesREST.search = { _, _, _ in sessions }
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
            calendar: listCalendar,
            seenCounts: seen,
            profiles: IdentifiedArray(uniqueElements: profileFixtures()),
            selectedProfileName: "default",
            profilesSupported: true
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
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
            calendar: listCalendar,
            seenCounts: seen,
            profiles: IdentifiedArray(uniqueElements: profileFixtures()),
            selectedProfileName: "work",
            profilesSupported: true
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
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
            calendar: listCalendar,
            seenCounts: seen,
            profilesSupported: false
          )
        ) {
          SessionListFeature().ignoring(\.task)
        } withDependencies: {
          $0.hermesREST.sessions = { _, _, _, _, _ in sessions }
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
