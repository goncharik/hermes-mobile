import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

struct AgentStatusProjectionTests {
  private let base = Date(timeIntervalSince1970: 1_749_600_000)

  private func session(
    _ id: String, minutesAgo: Double, active: Bool = false, source: String? = nil,
    cwd: String? = "/Users/me/dev/hermes"
  ) -> Session {
    Session(
      id: id, title: "Title \(id)", updatedAt: base.addingTimeInterval(-minutesAgo * 60),
      cwd: cwd, isActive: active, source: source
    )
  }

  private func make(
    _ sessions: [Session]?,
    needsInput: Set<String> = [],
    slotRunning: (id: String, running: Bool)? = nil,
    showsTitles: Bool = true,
    profile: String? = "work"
  ) -> AgentStatusProjection? {
    AgentStatusProjection.make(
      sessions: sessions, needsInput: needsInput, slotRunning: slotRunning,
      showsTitles: showsTitles, profile: profile
    )
  }

  @Test func nilBeforeTheFirstFetch() {
    #expect(make(nil) == nil)
    // An empty unfiltered list is known — not "unknown".
    expectNoDifference(
      make([]),
      AgentStatusProjection(rows: [], activeCount: 0, headline: nil, showsTitles: true)
    )
  }

  @Test func rowsCarryTitleWorkspaceStatusAndProfile() {
    let projection = make([
      session("a", minutesAgo: 1, active: true),
      Session(id: "b", preview: "untitled preview", cwd: "  "),
    ])
    expectNoDifference(projection?.rows, [
      WidgetSessionRow(
        id: "a", title: "Title a", workspace: "hermes", status: .working,
        updatedAt: base.addingTimeInterval(-60), profile: "work"
      ),
      // Untitled → the preview, like the list card; a blank cwd → no workspace (not
      // "No workspace").
      WidgetSessionRow(id: "b", title: "untitled preview", workspace: nil, status: .idle,
                       profile: "work"),
    ])
  }

  @Test func cronSessionsAreExcluded() {
    let projection = make([
      session("cron", minutesAgo: 0, active: true, source: "cron"),
      session("chat", minutesAgo: 5),
    ])
    #expect(projection?.rows.map(\.id) == ["chat"])
    #expect(projection?.activeCount == 0)
    #expect(projection?.headline == nil)
  }

  @Test func sortsNeedsInputThenWorkingThenNewestFirst() {
    let projection = make(
      [
        session("idle-old", minutesAgo: 30),
        session("working-old", minutesAgo: 20, active: true),
        session("idle-new", minutesAgo: 1),
        session("needs-old", minutesAgo: 40),
        session("working-new", minutesAgo: 2, active: true),
        Session(id: "idle-undated", title: "x"),
      ],
      needsInput: ["needs-old"]
    )
    #expect(projection?.rows.map(\.id) == [
      "needs-old", "working-new", "working-old", "idle-new", "idle-old",
    ])
  }

  @Test func equalDatesKeepServerOrder() {
    let projection = make([
      session("first", minutesAgo: 3),
      session("second", minutesAgo: 3),
    ])
    #expect(projection?.rows.map(\.id) == ["first", "second"])
  }

  @Test func capsRowsAtFiveButCountsEveryActiveSession() {
    let sessions = (0..<8).map { session("s\($0)", minutesAgo: Double($0), active: true) }
    let projection = make(sessions)
    #expect(projection?.rows.count == WidgetSessionSnapshot.maxRows)
    #expect(projection?.rows.map(\.id) == ["s0", "s1", "s2", "s3", "s4"])
    #expect(projection?.activeCount == 8)
  }

  @Test func activeCountIsNeedsInputUnionWorking() {
    let projection = make(
      [
        session("both", minutesAgo: 1, active: true),
        session("needs", minutesAgo: 2),
        session("working", minutesAgo: 3, active: true),
        session("idle", minutesAgo: 4),
      ],
      // An id that isn't in the list doesn't count: there is no row to headline.
      needsInput: ["both", "needs", "elsewhere"]
    )
    #expect(projection?.activeCount == 3)
  }

  @Test func headlinePrefersNeedsInputOverNewerWorking() {
    let projection = make(
      [session("working", minutesAgo: 0, active: true), session("needs", minutesAgo: 60)],
      needsInput: ["needs"]
    )
    #expect(projection?.headline?.id == "needs")
    #expect(projection?.activityContent?.status == .needsInput)
  }

  @Test func headlineIsTheNewestWorkingWithoutNeedsInput() {
    let projection = make([
      session("idle", minutesAgo: 0),
      session("working-old", minutesAgo: 10, active: true),
      session("working-new", minutesAgo: 5, active: true),
    ])
    #expect(projection?.headline?.id == "working-new")
    #expect(projection?.activityContent?.status == .working)
  }

  @Test func noHeadlineWhenNothingIsActive() {
    let projection = make([session("idle", minutesAgo: 0)])
    #expect(projection?.headline == nil)
    #expect(projection?.activeCount == 0)
  }

  @Test func slotRunningOverridesThePolledFlag() {
    let sessions = [
      session("slot", minutesAgo: 5, active: false),
      session("other", minutesAgo: 1, active: true),
    ]
    let started = make(sessions, slotRunning: (id: "slot", running: true))
    #expect(started?.rows.first { $0.id == "slot" }?.status == .working)
    #expect(started?.activeCount == 2)

    // The slot's turn ended before the poll caught up: the stale `isActive` is ignored.
    let stopped = make(
      [session("slot", minutesAgo: 5, active: true)], slotRunning: (id: "slot", running: false)
    )
    #expect(stopped?.rows.first?.status == .idle)
    #expect(stopped?.activeCount == 0)
  }

  @Test func activityContentCarriesTheHeadline() {
    let projection = make([session("a", minutesAgo: 1, active: true)])
    expectNoDifference(
      projection?.activityContent,
      AgentActivityContent(
        activeCount: 1, headlineTitle: "Title a", headlineWorkspace: "hermes",
        headlineSessionID: "a", headlineProfile: "work", status: .working
      )
    )
  }

  @Test func titleOmittedFromTheActivityWhenShowTitlesIsOff() {
    let projection = make([session("a", minutesAgo: 1, active: true)], showsTitles: false)
    #expect(projection?.activityContent?.headlineTitle == nil)
    #expect(projection?.activityContent?.headlineWorkspace == "hermes")
    // The Home Screen widgets keep the title.
    #expect(projection?.rows.first?.title == "Title a")
    // Flipping the pref is a projection change (the activity updates through the edge).
    #expect(projection != make([session("a", minutesAgo: 1, active: true)], showsTitles: true))
  }

  @Test func noActivityContentAtZeroActive() {
    #expect(make([session("idle", minutesAgo: 1)])?.activityContent == nil)
    #expect(make([])?.activityContent == nil)
  }
}

@MainActor
struct AppAgentStatusTests {
  private let connection = ServerConnection(
    baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok"
  )

  private func home(
    statusSessions: IdentifiedArrayOf<Session>?, profile: String? = nil
  ) -> SessionListFeature.State {
    var home = SessionListFeature.State(connection: connection, statusSessions: statusSessions)
    if let profile {
      home.profilesSupported = true
      home.selectedProfileName = profile
    }
    return home
  }

  @Test func nilWithoutHomeOrBeforeTheFirstUnfilteredFetch() {
    #expect(AppFeature.State().agentStatus == nil)
    #expect(AppFeature.State(home: home(statusSessions: nil)).agentStatus == nil)
    #expect(AppFeature.State(home: home(statusSessions: [])).agentStatus != nil)
  }

  @Test func readsStatusSessionsNotTheSearchResults() {
    var list = home(statusSessions: [Session(id: "all", isActive: true)])
    list.sessions = [Session(id: "hit")]
    list.searchQuery = "hit"
    let status = AppFeature.State(home: list).agentStatus
    #expect(status?.rows.map(\.id) == ["all"])
    #expect(status?.activeCount == 1)
  }

  @Test func pendingApprovalsAndTheSlotsCardNeedInput() {
    var state = AppFeature.State(
      home: home(statusSessions: [Session(id: "pushed"), Session(id: "slot")]),
      pendingApprovalSessionIDs: ["pushed"]
    )
    #expect(state.agentStatus?.activeCount == 1)
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "slot")
    chat.present(.approval(ApprovalRequest(command: "rm foo", choices: ["once", "deny"])))
    state.liveChat = chat
    #expect(state.agentStatus?.activeCount == 2)
  }

  @Test func slotRunningOverridesOnlyInTheListsProfile() {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "s1", profileName: "work")
    chat.isSending = true
    var state = AppFeature.State(
      home: home(statusSessions: [Session(id: "s1", isActive: false)], profile: "work"),
      liveChat: chat
    )
    #expect(state.agentStatus?.rows.first?.status == .working)
    #expect(state.agentStatus?.rows.first?.profile == "work")

    // The same id opened under another profile is a different session.
    state.liveChat?.profileName = "personal"
    #expect(state.agentStatus?.rows.first?.status == .idle)
  }

  @Test func showTitlesPrefFeedsTheProjection() {
    var state = AppFeature.State(home: home(statusSessions: [Session(id: "s1", title: "T", isActive: true)]))
    #expect(state.agentStatus?.activityContent?.headlineTitle == "T")
    state.liveActivityShowsTitles = false
    #expect(state.agentStatus?.activityContent?.headlineTitle == nil)
  }
}
