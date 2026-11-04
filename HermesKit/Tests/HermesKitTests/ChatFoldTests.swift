import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Tool-call display plan, Task 7: the slot's fold expansion state (`State.fold`), the header /
/// run-summary tap actions, `transcriptItems` over the window, and the window snap that keeps a
/// turn's header from ever being orphaned.
@MainActor
struct ChatFoldTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  /// Seed-row ids in a high range so they never collide with `.incrementing` live ids.
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0002-\(String(format: "%012x", n))")!
  }

  private func user(_ n: Int, _ text: String = "q") -> ChatRow {
    ChatRow(id: uuid(n), kind: .message(role: .user, text: text, isComplete: true))
  }

  private func reply(_ n: Int, _ text: String = "a", isComplete: Bool = true) -> ChatRow {
    ChatRow(id: uuid(n), kind: .message(role: .assistant, text: text, isComplete: isComplete))
  }

  private func tool(_ n: Int, _ name: String = "terminal", state: ChatRow.ToolState = .complete) -> ChatRow {
    ChatRow(id: uuid(n), kind: .tool(name: name, title: name, state: state, detail: nil, durationS: nil))
  }

  /// A finished turn: question, two tool calls, the reply.
  private func finishedTurn(base: Int) -> [ChatRow] {
    [user(base), tool(base + 1), tool(base + 2, "read_file"), reply(base + 3)]
  }

  private func makeStore(
    _ rows: [ChatRow], isTurnLive: Bool = false
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    var initial = ChatFeature.State(connection: conn, transcript: IdentifiedArrayOf(uniqueElements: rows))
    initial.isTurnLive = isTurnLive
    return TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
  }

  private func header(_ items: [TranscriptItem]) -> TurnHeader? {
    for item in items { if case let .turnHeader(header) = item { return header } }
    return nil
  }

  private func headers(_ items: [TranscriptItem]) -> [TurnHeader] {
    items.compactMap { if case let .turnHeader(header) = $0 { return header } else { return nil } }
  }

  // MARK: Tri-state toggle (pure)

  @Test func runningTurnToggleCyclesCollapsedThenExpanded() {
    var fold = FoldExpansion()
    #expect(fold.isTurnExpanded(ordinal: 0, isRunning: true))
    fold.toggleTurn(ordinal: 0, isRunning: true)
    #expect(fold.turnOverride[0] == .collapsed)
    #expect(!fold.isTurnExpanded(ordinal: 0, isRunning: true))
    fold.toggleTurn(ordinal: 0, isRunning: true)
    // Back to showing — but recorded as an explicit expand, not the default.
    #expect(fold.turnOverride[0] == .expanded)
    #expect(fold.isTurnExpanded(ordinal: 0, isRunning: true))
  }

  @Test func finishedTurnToggleCyclesExpandedThenCollapsed() {
    var fold = FoldExpansion()
    #expect(!fold.isTurnExpanded(ordinal: 2, isRunning: false))
    fold.toggleTurn(ordinal: 2, isRunning: false)
    #expect(fold.turnOverride[2] == .expanded)
    fold.toggleTurn(ordinal: 2, isRunning: false)
    #expect(fold.turnOverride[2] == .collapsed)
    #expect(!fold.isTurnExpanded(ordinal: 2, isRunning: false))
    // Other turns are untouched.
    #expect(fold.turnOverride[0] == nil)
  }

  @Test func runToggleAndPrune() {
    var fold = FoldExpansion()
    let key = RunKey(turnOrdinal: 1, runOrdinal: 0)
    fold.toggleRun(key)
    #expect(fold.expandedRuns == [key])
    fold.toggleRun(key)
    #expect(fold.expandedRuns.isEmpty)

    fold = FoldExpansion(
      turnOverride: [0: .expanded, 2: .collapsed, 3: .expanded],
      expandedRuns: [RunKey(turnOrdinal: 1, runOrdinal: 0), RunKey(turnOrdinal: 2, runOrdinal: 1)],
      expandedCalls: [CallKey(turnOrdinal: -1, callOrdinal: 0), CallKey(turnOrdinal: 4, callOrdinal: 0)]
    )
    fold.prune(turnCount: 2)
    #expect(fold == FoldExpansion(
      turnOverride: [0: .expanded],
      expandedRuns: [RunKey(turnOrdinal: 1, runOrdinal: 0)],
      expandedCalls: [CallKey(turnOrdinal: -1, callOrdinal: 0)]
    ))
  }

  // MARK: Tap actions

  @Test func headerTapOnAFinishedTurnExpandsItAndTheRunSummaryTapListsTheCalls() async {
    let store = makeStore(finishedTurn(base: 0))
    // Collapsed by default: user, header, reply.
    #expect(store.state.transcriptItems.map(\.id) == [
      uuid(0), TranscriptItem.turnHeaderID(userRowID: uuid(0)), uuid(3),
    ])

    await store.send(.turnHeaderTapped(0)) { $0.fold.turnOverride[0] = .expanded }
    #expect(header(store.state.transcriptItems)?.isExpanded == true)
    // Expanded: the two calls fold into one (collapsed) run summary.
    #expect(store.state.transcriptItems.map(\.id) == [
      uuid(0), TranscriptItem.turnHeaderID(userRowID: uuid(0)),
      TranscriptItem.runSummaryID(firstToolRowID: uuid(1)), uuid(3),
    ])

    let run = RunKey(turnOrdinal: 0, runOrdinal: 0)
    await store.send(.runSummaryTapped(run)) { $0.fold.expandedRuns = [run] }
    #expect(store.state.transcriptItems.map(\.id) == [
      uuid(0), TranscriptItem.turnHeaderID(userRowID: uuid(0)),
      TranscriptItem.runSummaryID(firstToolRowID: uuid(1)), uuid(1), uuid(2), uuid(3),
    ])
    await store.send(.runSummaryTapped(run)) { $0.fold.expandedRuns = [] }

    await store.send(.turnHeaderTapped(0)) { $0.fold.turnOverride[0] = .collapsed }
    #expect(header(store.state.transcriptItems)?.isExpanded == false)
  }

  @Test func headerTapOnTheRunningTurnCollapsesIt() async {
    let store = makeStore([user(0), tool(1, state: .running)], isTurnLive: true)
    let live = header(store.state.transcriptItems)
    #expect(live?.isRunning == true)
    #expect(live?.isExpanded == true)

    await store.send(.turnHeaderTapped(0)) { $0.fold.turnOverride[0] = .collapsed }
    let collapsed = header(store.state.transcriptItems)
    #expect(collapsed?.isExpanded == false)
    #expect(collapsed?.liveLine == "terminal")
  }

  // MARK: Finish collapses unless the last action was expand

  /// Drive a live turn from `message.start` to `message.complete`, applying `taps` header taps
  /// while it runs; returns whether the finished turn's header is expanded.
  private func finishedExpansion(afterTaps taps: Int) async -> Bool? {
    let store = makeStore([user(0)])
    store.exhaustivity = .off
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "terminal", title: "ls", argsText: nil)))
    #expect(header(store.state.transcriptItems)?.isRunning == true)
    for _ in 0..<taps { await store.send(.turnHeaderTapped(0)) }
    await store.send(.gatewayEvent(.toolComplete(
      toolID: "t1", name: "terminal", title: "ls", args: nil, resultText: "ok", inlineDiff: nil,
      durationS: 1
    )))
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    let finished = header(store.state.transcriptItems)
    #expect(finished?.isRunning == false)
    await store.send(.teardown)
    return finished?.isExpanded
  }

  @Test func untouchedRunningTurnCollapsesWhenItFinishes() async {
    #expect(await finishedExpansion(afterTaps: 0) == false)
  }

  @Test func collapsedRunningTurnStaysCollapsedWhenItFinishes() async {
    #expect(await finishedExpansion(afterTaps: 1) == false)
  }

  @Test func reExpandedRunningTurnStaysExpandedWhenItFinishes() async {
    #expect(await finishedExpansion(afterTaps: 2) == true)
  }

  // MARK: Hydrate & teardown

  @Test func foldChoicesSurviveTheHydrateIdRewrite() async {
    // Live rows (client ids) for two finished turns; the user opens turn 1 and its run.
    let rows = finishedTurn(base: 0) + finishedTurn(base: 10)
    let store = makeStore(rows)
    store.exhaustivity = .off
    let run = RunKey(turnOrdinal: 1, runOrdinal: 0)
    await store.send(.turnHeaderTapped(1))
    await store.send(.runSummaryTapped(run))

    // The server's history for the same turns rebuilds every row under a deterministic id.
    let messages: [SessionMessage] = (0..<2).flatMap { turn -> [SessionMessage] in
      let base = turn * 4
      return [
        SessionMessage(id: base, role: "user", content: "q"),
        SessionMessage(id: base + 1, role: "tool", name: "terminal", context: "ls"),
        SessionMessage(id: base + 2, role: "tool", name: "read_file", context: "/etc/hosts"),
        SessionMessage(id: base + 3, role: "assistant", content: "a"),
      ]
    }
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123", messages: messages, running: false
    ))))
    #expect(store.state.transcript.count == 8)
    #expect(!store.state.transcript.ids.contains(uuid(10)))
    #expect(store.state.fold == FoldExpansion(turnOverride: [1: .expanded], expandedRuns: [run]))

    let items = store.state.transcriptItems
    let turnHeaders = headers(items)
    #expect(turnHeaders.map(\.ordinal) == [0, 1])
    #expect(turnHeaders.map(\.isExpanded) == [false, true])
    let summaries = items.compactMap { if case let .runSummary(s) = $0 { return s } else { return nil } }
    #expect(summaries.map(\.key) == [run])
    #expect(summaries.first?.isExpanded == true)
    // The expanded run lists both of turn 1's calls under their NEW (hydrated) ids.
    let calls = items.compactMap { if case let .toolCall(c) = $0 { return c } else { return nil } }
    #expect(calls.map(\.id) == [store.state.transcript[5].id, store.state.transcript[6].id])

    await store.send(.teardown)
  }

  @Test func hydrateDropsChoicesOnTurnsTheHistoryNoLongerHas() async {
    // `/undo` shape: three turns client-side, the server's history keeps one.
    let rows = finishedTurn(base: 0) + finishedTurn(base: 10) + finishedTurn(base: 20)
    var initial = ChatFeature.State(connection: conn, transcript: IdentifiedArrayOf(uniqueElements: rows))
    initial.fold = FoldExpansion(
      turnOverride: [0: .expanded, 2: .expanded],
      expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 0), RunKey(turnOrdinal: 2, runOrdinal: 0)]
    )
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off
    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live123", storedSessionID: "stored123",
      messages: [
        SessionMessage(id: 1, role: "user", content: "q"),
        SessionMessage(id: 2, role: "assistant", content: "a"),
      ],
      running: false
    ))))
    #expect(store.state.fold == FoldExpansion(
      turnOverride: [0: .expanded], expandedRuns: [RunKey(turnOrdinal: 0, runOrdinal: 0)]
    ))
    await store.send(.teardown)
  }

  @Test func teardownResetsTheFold() async {
    let store = makeStore(finishedTurn(base: 0))
    let run = RunKey(turnOrdinal: 0, runOrdinal: 0)
    await store.send(.turnHeaderTapped(0)) { $0.fold.turnOverride[0] = .expanded }
    await store.send(.runSummaryTapped(run)) { $0.fold.expandedRuns = [run] }
    await store.send(.teardown) { $0.fold = FoldExpansion() }
  }

  @Test func aFreshSlotStartsWithAnEmptyFold() {
    // Another session (or a logout, which nils the slot) means a new `State`: nothing carries.
    let state = ChatFeature.State(connection: conn, resumeStoredID: "other")
    #expect(state.fold == FoldExpansion())
  }

  // MARK: Window snap

  /// One turn with 60 tool calls after 2 short turns: the bottom window starts mid-turn.
  private func longTurnTranscript() -> [ChatRow] {
    var rows = [user(0), reply(1), user(2), reply(3), user(4)]
    rows += (0..<60).map { tool(100 + $0) }
    rows.append(reply(200))
    return rows
  }

  @Test func windowStartingMidTurnSnapsDownToTheTurnsUserRow() {
    let rows = longTurnTranscript()
    let state = ChatFeature.State(connection: conn, transcript: IdentifiedArrayOf(uniqueElements: rows))
    #expect(state.windowStart == rows.count - ChatFeature.State.initialWindow) // 16: a tool row
    #expect(state.snappedWindowStart == 4)
    #expect(state.visibleRows.first?.id == uuid(4))
    #expect(state.hasMoreAbove)

    // The header is present, right after its user row, with the ABSOLUTE ordinal.
    let items = state.transcriptItems
    #expect(items.first?.id == uuid(4))
    #expect(items.dropFirst().first?.id == TranscriptItem.turnHeaderID(userRowID: uuid(4)))
    #expect(headers(items).map(\.ordinal) == [2])
  }

  @Test func windowStartingInThePreambleSnapsToTheTop() {
    var rows = (0..<60).map { tool(100 + $0) } // a branch-seed preamble: no user row
    rows += [user(0), reply(1)]
    let state = ChatFeature.State(connection: conn, transcript: IdentifiedArrayOf(uniqueElements: rows))
    #expect(state.windowStart == 12)
    #expect(state.snappedWindowStart == 0)
    #expect(state.visibleRows.count == rows.count)
    #expect(!state.hasMoreAbove)
  }

  @Test func loadOlderPagesFromTheSnappedStart() async {
    var rows: [ChatRow] = []
    for turn in 0..<10 { rows += [user(turn * 20)] + (1...19).map { tool(turn * 20 + $0) } }
    let store = makeStore(rows) // 200 rows, 10 turns of 20
    #expect(store.state.windowStart == 150)
    #expect(store.state.snappedWindowStart == 140)
    await store.send(.loadOlderRequested) { $0.windowStart = 90 } // 140 - 50
    #expect(store.state.snappedWindowStart == 80)
    #expect(headers(store.state.transcriptItems).map(\.ordinal) == [4, 5, 6, 7, 8, 9])
    await store.send(.loadOlderRequested) { $0.windowStart = 30 }
    await store.send(.loadOlderRequested) { $0.windowStart = 0 }
    #expect(!store.state.hasMoreAbove)
    #expect(headers(store.state.transcriptItems).count == 10)
  }

  @Test func noWindowStartEverOrphansAHeader() {
    // A mixed transcript: preamble, short turns, a long tool turn, a running turn.
    var rows = [reply(900, "seed"), tool(901)]
    rows += finishedTurn(base: 0)
    rows += [user(10), reply(11)]
    rows += [user(20)] + (0..<30).map { tool(300 + $0) } + [reply(21)]
    rows += [user(40), tool(41, state: .running), reply(42, "…", isComplete: false)]
    let allTurns = turnSpans(rows, runningTurnOrdinal: 3).filter { $0.userRowIndex != nil }
    for start in 0..<rows.count {
      var state = ChatFeature.State(connection: conn, transcript: IdentifiedArrayOf(uniqueElements: rows))
      state.isTurnLive = true
      state.windowStart = start
      #expect(state.runningTurnOrdinal == 3)
      let items = state.transcriptItems
      for (index, item) in items.enumerated() {
        guard case let .turnHeader(header) = item else { continue }
        // Every header sits right after its own user row, under its absolute ordinal.
        #expect(index > 0)
        let userRow = rows[allTurns[header.ordinal].userRowIndex!]
        #expect(items[index - 1].id == userRow.id, "start \(start)")
        #expect(header.id == TranscriptItem.turnHeaderID(userRowID: userRow.id))
      }
      // The window opens on a user row, or on the transcript's first row.
      #expect(state.snappedWindowStart == 0
        || ChatFeature.State.isUserMessage(rows[state.snappedWindowStart]), "start \(start)")
      // The running turn's header is always there.
      #expect(headers(items).last?.isRunning == true, "start \(start)")
    }
  }
}
