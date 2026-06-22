import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ChatReductionTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  // MARK: Streaming fold (no message id — single in-flight row)

  @Test func streamingMessageFold() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    // message.start no longer creates the assistant row (would render as an empty bubble),
    // but it eagerly creates the live thinking row (uuid 0) and starts the timer.
    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.messageDelta(text: "Hel"))) {
      // The assistant row streams in; the live thinking row stays pinned below it.
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "Hel", isComplete: false)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.streamingRowID = uuid(1)
    }
    await store.send(.gatewayEvent(.messageDelta(text: "lo"))) {
      $0.transcript[id: uuid(1)]?.kind = .message(role: .assistant, text: "Hello", isComplete: false)
    }
    // No reasoning/status arrived → the empty thinking row is removed on completion.
    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: uuid(1)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.transcript.remove(id: self.uuid(0))
      $0.streamingRowID = nil
      $0.thinkingRowID = nil
      $0.isSending = false
    }
  }

  // The live thinking row is pinned to the bottom of the transcript: tool rows and the
  // streaming answer slot in above it, and on completion it freezes (as the "Thought" row)
  // still below the answer.
  @Test func thinkingRowStaysLastAsToolsAndAnswerStreamIn() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "Hmm"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Hmm", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    // A tool starts mid-turn: it slots in above the thinking row, which stays last.
    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "search", title: "Searching", argsText: nil))) {
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .tool(name: "search", title: "Searching", state: .running, detail: nil, durationS: nil)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "Hmm", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.toolRowIDs["t1"] = uuid(1)
    }
    // The answer streams in below the tool, still above the pinned thinking row.
    await store.send(.gatewayEvent(.messageDelta(text: "Answer"))) {
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .tool(name: "search", title: "Searching", state: .running, detail: nil, durationS: nil)),
        ChatRow(id: uuid(2), kind: .message(role: .assistant, text: "Answer", isComplete: false)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "Hmm", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.streamingRowID = uuid(2)
    }
    // Completion: answer finalizes, thinking freezes into the "Thought" row — still last.
    await store.send(.gatewayEvent(.messageComplete(text: "Answer", usage: nil))) {
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .tool(name: "search", title: "Searching", state: .running, detail: nil, durationS: nil)),
        ChatRow(id: uuid(2), kind: .message(role: .assistant, text: "Answer", isComplete: true)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "Hmm", status: nil, elapsedSeconds: 0, isComplete: true)),
      ]
      $0.streamingRowID = nil
      $0.thinkingRowID = nil
      $0.isSending = false
    }
    #expect(store.state.transcript.last?.id == uuid(0))
  }

  @Test func toolOnlyTurnLeavesNoEmptyMessageBubble() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    // start → (tool activity) → complete with no text and no reasoning/status: no assistant
    // message row and the empty thinking row is removed too.
    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil))) {
      $0.transcript.remove(id: self.uuid(0))
      $0.thinkingRowID = nil
      $0.isSending = false
    }
    #expect(store.state.transcript.isEmpty)
  }

  // message.start eagerly creates the live thinking row + starts the elapsed timer;
  // reasoning deltas accumulate into that one row; ticks advance thinkingSeconds; the turn
  // completing bakes the elapsed in and freezes the row as a static disclosure.
  @Test func messageStartCreatesLiveThinkingRowTimerTicksThenFreezes() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    // The 1s tick loop drives thinkingSeconds.
    await clock.advance(by: .seconds(3))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 3 }
    // Reasoning accumulates into the existing row, then the assistant message streams.
    await store.send(.gatewayEvent(.thinkingDelta(text: "Thinking"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Thinking", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "…"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Thinking…", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    await store.send(.gatewayEvent(.messageDelta(text: "pong"))) {
      // The assistant row streams in; the live thinking row is pinned below it.
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "pong", isComplete: false)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "Thinking…", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.streamingRowID = uuid(1)
    }
    // Completion freezes the thinking row (3s baked in), keeps it (had reasoning), cancels
    // the timer, and resets the counter.
    await store.send(.gatewayEvent(.messageComplete(text: "pong", usage: nil))) {
      $0.transcript[id: uuid(1)]?.kind = .message(role: .assistant, text: "pong", isComplete: true)
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Thinking…", status: nil, elapsedSeconds: 3, isComplete: true)
      $0.streamingRowID = nil
      $0.thinkingRowID = nil
      $0.thinkingSeconds = 0
      $0.isSending = false
    }
  }

  // statusUpdate routes the context-size line into the active thinking row's status (no
  // longer a persistent footer), and a status-only turn keeps its row on completion.
  @Test func statusUpdateRoutesIntoThinkingRowAndKeepsIt() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.statusUpdate(kind: "lifecycle", text: "Context: 42% used"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "", status: "Context: 42% used", elapsedSeconds: 0, isComplete: false)
    }
    // A status-only turn (no reasoning, no message text) keeps the frozen row.
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "", status: "Context: 42% used", elapsedSeconds: 0, isComplete: true)
      $0.thinkingRowID = nil
      $0.isSending = false
    }
  }

  // Leaving the screen mid-turn cancels the live thinking timer (no leaked tick loop).
  @Test func onDisappearCancelsThinkingTimer() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    // onDisappear cancels the loop; advancing further yields no more ticks.
    await store.send(.onDisappear)
    await clock.advance(by: .seconds(5))
  }

  // Two back-to-back turns: a second message.start (with no intervening message.complete)
  // freezes/clears the first live row before creating the second, and the timer restarts
  // cleanly from 0 (cancelInFlight + reset) — no orphaned shimmering row, no double-ticking.
  @Test func secondMessageStartFreezesPriorRowAndRestartsTimerFromZero() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    // Turn 1: start, accumulate reasoning, tick twice, then complete normally.
    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "First"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "First", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil))) {
      // The answer lands, then the thinking row freezes into a "Thought" row below it.
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "done", isComplete: true)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "First", status: nil, elapsedSeconds: 2, isComplete: true)),
      ]
      $0.thinkingRowID = nil
      $0.thinkingSeconds = 0
      $0.isSending = false
    }

    // Turn 2: a fresh message.start creates a new live row and restarts the timer at 0;
    // exactly one tick per second (no leaked first-turn loop double-ticking).
    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript.append(ChatRow(id: uuid(2), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)))
      $0.thinkingRowID = uuid(2)
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.send(.onDisappear)
    await clock.advance(by: .seconds(3))
  }

  // Defensive: a second message.start with the first row still LIVE (no message.complete in
  // between) freezes the orphaned row rather than leaving it shimmering forever.
  @Test func secondMessageStartFreezesAStillLiveFirstRow() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "Live one"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Live one", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }

    // No message.complete arrives — a fresh message.start freezes the orphan (2s baked in,
    // isComplete=true, kept since it had reasoning) and starts a new live row.
    await store.send(.gatewayEvent(.messageStart)) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Live one", status: nil, elapsedSeconds: 2, isComplete: true)
      $0.transcript.append(ChatRow(id: uuid(1), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)))
      $0.thinkingRowID = uuid(1)
      $0.thinkingSeconds = 0
    }
    await store.send(.onDisappear)
    await clock.advance(by: .seconds(3))
  }

  // An empty live thinking row (no reasoning, no status) is removed on `.error`, the timer
  // cancelled, and the counter reset.
  @Test func errorRemovesEmptyThinkingRowAndCancelsTimer() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }
    // Error on an empty turn: the row is removed entirely, pointer + counter reset, timer
    // cancelled (a leaked tick would fail the test).
    await store.send(.gatewayEvent(.error(message: "boom"))) {
      $0.errorBanner = "boom"
      $0.transcript.remove(id: self.uuid(0))
      $0.thinkingRowID = nil
      $0.thinkingSeconds = 0
      $0.isSending = false
    }
    await clock.advance(by: .seconds(5))
    #expect(store.state.transcript.isEmpty)
  }

  // A socket drop on an empty live turn (no reasoning, no status) removes the thinking row
  // rather than freezing an empty one.
  @Test func socketDropRemovesEmptyThinkingRow() async {
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)),
    ]
    initial.thinkingRowID = uuid(0)
    initial.thinkingSeconds = 4
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.transcript.remove(id: self.uuid(0))
      $0.thinkingRowID = nil
      $0.thinkingSeconds = 0
      $0.isSending = false
      $0.reconnectAttempt = 1
    }
    #expect(store.state.transcript.isEmpty)
    await store.send(.onDisappear)
  }

  // A bare thinkingDelta arriving FIRST (no prior message.start) defensively creates the
  // thinking row with the text and sets thinkingRowID — but does NOT start the timer (that's
  // tied to message.start), so no tick effect leaks.
  @Test func bareThinkingDeltaDefensivelyCreatesRowWithoutStartingTimer() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }

    await store.send(.gatewayEvent(.thinkingDelta(text: "Orphan reasoning"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "Orphan reasoning", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    // No timer was started by a bare delta — advancing the clock yields no ticks.
    await clock.advance(by: .seconds(3))
    #expect(store.state.thinkingSeconds == 0)
  }

  @Test func toolStartThenComplete() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "read_file", title: "Reading /x", argsText: "path=/x"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .tool(
        name: "read_file", title: "Reading /x", state: .running,
        detail: ToolDetail(argsText: "path=/x"), durationS: nil
      ))]
      $0.toolRowIDs = ["t1": uuid(0)]
    }
    await store.send(.gatewayEvent(.toolComplete(
      toolID: "t1", name: "read_file", title: "Read 12 lines",
      args: .object(["path": .string("/x")]), resultText: "ok", inlineDiff: nil, durationS: 1.5
    ))) {
      // Merge keeps the start-time args_text; fills in result + structured args.
      $0.transcript[id: uuid(0)]?.kind = .tool(
        name: "read_file", title: "Read 12 lines", state: .complete,
        detail: ToolDetail(argsText: "path=/x", args: .object(["path": .string("/x")]), resultText: "ok", inlineDiff: nil),
        durationS: 1.5
      )
    }
  }

  @Test func toolTitleFallsBackToNameAndTapPresentsDetail() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    // No context/summary → title falls back to the raw tool name.
    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "grep", title: nil, argsText: nil))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .tool(
        name: "grep", title: "grep", state: .running, detail: nil, durationS: nil
      ))]
      $0.toolRowIDs = ["t1": uuid(0)]
    }
    await store.send(.gatewayEvent(.toolComplete(
      toolID: "t1", name: "grep", title: nil, args: nil, resultText: "2 matches", inlineDiff: nil, durationS: 0.2
    ))) {
      $0.transcript[id: self.uuid(0)]?.kind = .tool(
        name: "grep", title: "grep", state: .complete,
        detail: ToolDetail(resultText: "2 matches"), durationS: 0.2
      )
    }
    await store.send(.toolTapped(id: uuid(0))) {
      $0.presentedTool = $0.transcript[id: self.uuid(0)]
    }
    await store.send(.toolDetailDismissed) {
      $0.presentedTool = nil
    }
  }

  // statusUpdate with no active thinking row creates one defensively (so the line is never
  // dropped); .error then freezes that row and surfaces the banner.
  @Test func statusUpdateDefensivelyCreatesRowAndErrorFreezes() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: { $0.uuid = .incrementing }

    await store.send(.gatewayEvent(.statusUpdate(kind: "lifecycle", text: "searching…"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: "searching…", elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.error(message: "boom"))) {
      $0.errorBanner = "boom"
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "", status: "searching…", elapsedSeconds: 0, isComplete: true)
      $0.thinkingRowID = nil
    }
  }

  // MARK: Composer

  @Test func composerSubmitAppendsUserRowAndSends() async {
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable _, _ in .object(["status": .string("streaming")]) }
    }

    await store.send(\.binding.composerText, "hello") { $0.composerText = "hello" }
    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .message(role: .user, text: "hello", isComplete: true))]
      $0.composerText = ""
      $0.isSending = true
    }
  }

  // MARK: Bootstrap (create on first ready)

  @Test func createsSessionOnFirstReady() async {
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { $0.yield(.ready) } }
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }

    await store.send(.task)
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
    }
    // New sessions create with no title so the server auto-names from the first message.
    #expect(sent.value?["method"]?.stringValue == "session.create")
    #expect(sent.value?["params"] == .object([:]))
    #expect(sent.value?["params"]?["title"] == nil)
    await store.send(.onDisappear)
  }

  @Test func createUnderCustomProfileThreadsProfileParam() async {
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, profileName: "work")
    ) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { $0.yield(.ready) } }
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }

    await store.send(.task)
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
    }
    #expect(sent.value?["method"]?.stringValue == "session.create")
    #expect(sent.value?["params"] == .object(["profile": .string("work")]))
    await store.send(.onDisappear)
  }

  @Test func defaultProfileNameThreadsNoProfileParam() async {
    // A profileName of "default" must produce byte-identical params to nil (regression).
    let sent = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, profileName: "default")
    ) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { $0.yield(.ready) } }
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue(.object(["method": .string(method), "params": params]))
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }

    await store.send(.task)
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
    }
    #expect(sent.value?["params"] == .object([:]))
    await store.send(.onDisappear)
  }

  @Test func resumeUnderCustomProfileThreadsProfileParam() async {
    // A ready frame with a stored id hydrates via `session.resume`, threading the profile.
    let activateParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123", profileName: "work")
    ) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "session.resume" { activateParams.setValue(params) }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([]),
          "running": .bool(false),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object([
              "context_used": .number(0), "context_max": .number(200_000), "context_percent": .number(0),
            ]),
          ]),
        ])
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
    }
    #expect(activateParams.value == .object([
      "session_id": .string("stored123"),
      "profile": .string("work"),
    ]))
    // Activate's authoritative `running:false` clears the list glow for this session.
    await store.receive(\.delegate.runningChanged)
    await store.send(.onDisappear)
  }

  @Test func readyWithStoredIDHydratesViaResume() async {
    // A ready frame *with* a stored id must hydrate via `session.resume` (not create).
    // The resume response carries model + usage directly — no separate usage fetch.
    let methods = LockIsolated<[String]>([])
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        methods.withValue { $0.append(method) }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([]),
          "running": .bool(false),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object([
              "input": .number(120_000), "output": .number(30_000), "total": .number(150_000),
              "context_used": .number(150_000), "context_max": .number(200_000), "context_percent": .number(75),
            ]),
          ]),
        ])
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(
        input: 120_000, output: 30_000, total: 150_000,
        contextUsed: 150_000, contextMax: 200_000, contextPercent: 75
      )
    }
    #expect(methods.value == ["session.resume"])
    // Usage came from `info` — no fallback `session.usage` fetch.
    #expect(!methods.value.contains("session.usage"))
    await store.receive(\.delegate.runningChanged)
    await store.send(.onDisappear)
  }

  @Test func resumeWithNoUsageInResponseFallsBackToUsageFetch() async {
    // An older agent's resume response may omit usage; we then fetch it on-demand
    // so the gauge isn't blank until the next turn (preserves prior resume behavior).
    let methods = LockIsolated<[String]>([])
    let usageParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        methods.withValue { $0.append(method) }
        if method == "session.usage" {
          usageParams.setValue(params)
          return .object([
            "context_used": .number(150_000), "context_max": .number(200_000), "context_percent": .number(75),
          ])
        }
        // No `info`/`usage` in the resume response.
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([]),
          "running": .bool(false),
        ])
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
    }
    // The synchronous delegate send lands before the async usage fetch resolves.
    await store.receive(\.delegate.runningChanged)
    await store.receive(\.usageResponse) {
      $0.usage = Usage(contextUsed: 150_000, contextMax: 200_000, contextPercent: 75)
    }
    #expect(methods.value.first == "session.resume")
    #expect(methods.value.contains("session.usage"))
    #expect(usageParams.value?["session_id"]?.stringValue == "live123")
    await store.send(.onDisappear)
  }

  @Test func resumeHydratesStoredTranscriptModelAndUsage() async {
    // `session.resume` is the single hydrate call (it serves both stored and live sessions);
    // it must rebuild the transcript from `messages` and apply model/usage. Regression guard
    // for the blocker where `session.activate` (live-only) 404'd every stored session.
    let methods = LockIsolated<[String]>([])
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        methods.withValue { $0.append(method) }
        // `session.resume` returns the live id under `session_id` and the stored id under
        // `resumed` (no `stored_session_id`) — exercises the `resumed` decode fallback.
        return .object([
          "session_id": .string("live123"),
          "resumed": .string("stored123"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("user"), "content": .string("hi")]),
            .object(["id": .number(2), "role": .string("assistant"), "content": .string("hello")]),
          ]),
          "running": .bool(false),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object(["context_used": .number(10), "context_max": .number(200_000), "context_percent": .number(0)]),
          ]),
        ])
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 10, contextMax: 200_000, contextPercent: 0)
      // Rows carry deterministic, content-derived ids (matching `reconstructTranscript`).
      $0.transcript = IdentifiedArrayOf(uniqueElements: reconstructTranscript([
        SessionMessage(id: 1, role: "user", content: "hi"),
        SessionMessage(id: 2, role: "assistant", content: "hello"),
      ]))
    }
    // Single resume call — no activate, no fallback dance.
    #expect(methods.value == ["session.resume"])
    await store.receive(\.delegate.runningChanged)
    await store.send(.onDisappear)
  }

  @Test func activateSeedsRunningInflightAndDeltaReusesSeededRow() async {
    // Regression: re-opening a session mid-turn must set the working indicator from
    // `running`, seed the inflight user + streaming assistant rows, and a subsequent
    // `message.delta` must append to the SEEDED streaming row (not create a duplicate).
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable _, _ in
        .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([]),
          "running": .bool(true),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object(["context_used": .number(5), "context_max": .number(200_000), "context_percent": .number(0)]),
          ]),
          "inflight": .object([
            "user": .string("explain this"),
            "assistant": .string("Sure, "),
            "streaming": .bool(true),
          ]),
        ])
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 5, contextMax: 200_000, contextPercent: 0)
      // running == true → working indicator on.
      $0.isSending = true
      // Inflight user row + seeded streaming assistant row (uuid 0, uuid 1) + a live thinking
      // row (uuid 2) recreated by the timer reconcile (running with no anchor → ticks from 0).
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "explain this", isComplete: true)),
        ChatRow(id: self.uuid(1), kind: .message(role: .assistant, text: "Sure, ", isComplete: false)),
        ChatRow(
          id: self.uuid(2),
          kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
        ),
      ]
      $0.streamingRowID = self.uuid(1)
      $0.thinkingRowID = self.uuid(2)
    }
    // Activate's authoritative `running:true` lights the list glow for this session.
    await store.receive(\.delegate.runningChanged)
    // The next delta appends to the seeded row — a SINGLE assistant row, no duplicate; the
    // live thinking row is moved to last (keepThinkingLast) but stays the same row.
    await store.send(.gatewayEvent(.messageDelta(text: "here goes."))) {
      $0.transcript[id: self.uuid(1)]?.kind = .message(role: .assistant, text: "Sure, here goes.", isComplete: false)
    }
    // user + assistant + thinking = 3 rows (no duplicate assistant from the delta).
    #expect(store.state.transcript.count == 3)
    await store.send(.onDisappear)
  }

  @Test func unknownEventIsInertInTheFold() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    // Forward-compat: events the UI doesn't model must not mutate state or crash.
    await store.send(.gatewayEvent(.unknown(type: "tool.progress", raw: .object([:]))))
  }

  @Test func sessionInfoUpdatesModelAndReasoningChip() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "claude-opus-4-8", reasoningEffort: "high")))) {
      $0.model = "claude-opus-4-8"
      $0.reasoningEffort = "high"
    }
    // A later partial session.info (model only) must not clear the reasoning effort.
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "claude-sonnet-4-6")))) {
      $0.model = "claude-sonnet-4-6"
    }
  }

  // MARK: Context usage capture

  @Test func sessionInfoCapturesUsage() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    let usage = Usage(contextUsed: 125_000, contextMax: 200_000, contextPercent: 62)
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "claude-opus-4-8", usage: usage)))) {
      $0.model = "claude-opus-4-8"
      $0.usage = usage
    }
  }

  @Test func messageCompleteCapturesUsage() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    let usage = Usage(input: 800, output: 200, total: 1_000, contextUsed: 1_000, contextMax: 200_000, contextPercent: 1)
    await store.send(.gatewayEvent(.messageComplete(text: "Hi", usage: usage))) {
      $0.usage = usage
      $0.transcript.append(
        ChatRow(id: self.uuid(0), kind: .message(role: .assistant, text: "Hi", isComplete: true))
      )
      $0.isSending = false
    }
  }

  @Test func partialSessionInfoDoesNotClobberUsage() async {
    let usage = Usage(contextUsed: 125_000, contextMax: 200_000, contextPercent: 62)
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(usage: usage)))) {
      $0.usage = usage
    }
    // A later partial session.info (model only, no usage) must not clear the usage.
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(model: "claude-sonnet-4-6")))) {
      $0.model = "claude-sonnet-4-6"
    }
  }

  // MARK: Reconnect / backoff

  @Test func reconnectsAfterBackoffOnClose() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn, status: .ready)) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } } // stays open
    }

    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.reconnectAttempt = 1
    }
    await clock.advance(by: .seconds(1)) // first backoff = 2^0 = 1s
    await store.receive(\.reconnectTick)
    await store.send(.onDisappear)
  }

  // MARK: ws-ticket auth failure vs transient (gated reconnect)

  /// A dead gated session (ws-ticket 401 → `.authExpired`) pauses reconnect: it emits the
  /// `sessionExpired` delegate and the trailing `.gatewayClosed` (finished stream) does NOT
  /// schedule a backoff reconnect.
  @Test func authExpiredSignalsSessionExpiredAndPausesReconnect() async {
    let clock = TestClock()
    let cookieConn = ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!,
      auth: .cookie(CookieSession(cookies: [], username: "alice", provider: "basic"))
    )
    let store = TestStore(initialState: ChatFeature.State(connection: cookieConn, status: .ready)) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.gatewayEvent(.authExpired)) {
      $0.awaitingReauth = true
      $0.status = .reconnecting
    }
    await store.receive(\.delegate.sessionExpired)

    // The stream finishing afterwards is suppressed — no reconnectAttempt bump, no backoff.
    await store.send(.gatewayClosed)
    // No `.reconnectTick` is ever scheduled even after a long advance.
    await clock.advance(by: .seconds(60))
    await store.send(.onDisappear)
  }

  /// A transient gated failure (the ticket mint failed → the stream just finishes, like a
  /// dropped socket) continues the existing backoff/reconnect loop.
  @Test func transientGatedCloseContinuesBackoff() async {
    let clock = TestClock()
    let cookieConn = ServerConnection(
      baseURL: URL(string: "http://mac.tailnet:9119")!,
      auth: .cookie(CookieSession(cookies: [], username: "alice", provider: "basic"))
    )
    let store = TestStore(initialState: ChatFeature.State(connection: cookieConn, status: .ready)) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.reconnectAttempt = 1
    }
    await clock.advance(by: .seconds(1)) // first backoff = 2^0 = 1s
    await store.receive(\.reconnectTick)
    await store.send(.onDisappear)
  }

  // MARK: Reconnect resilience — finalize a row that was mid-stream when the socket dropped

  @Test func closeFinalizesInFlightStreamingRow() async {
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .thinking(reasoning: "Hmm", status: nil, elapsedSeconds: 0, isComplete: false)),
      ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "Half", isComplete: false)),
    ]
    initial.streamingRowID = uuid(1)
    initial.thinkingRowID = uuid(0)
    initial.thinkingSeconds = 7
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }

    // A dropped socket finalizes the streaming message and freezes the live thinking row
    // (7s baked in) so it doesn't spin forever; the timer is cancelled.
    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.transcript[id: self.uuid(1)]?.kind = .message(role: .assistant, text: "Half", isComplete: true)
      $0.transcript[id: self.uuid(0)]?.kind = .thinking(reasoning: "Hmm", status: nil, elapsedSeconds: 7, isComplete: true)
      $0.streamingRowID = nil
      $0.thinkingRowID = nil
      $0.thinkingSeconds = 0
      $0.isSending = false
      $0.reconnectAttempt = 1
    }
    await store.send(.onDisappear)
  }

  // MARK: Copy a row to the pasteboard

  @Test func copyRowPutsTextOnPasteboard() async {
    let copied = LockIsolated<String?>(nil)
    var initial = ChatFeature.State(connection: conn)
    initial.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "copy me", isComplete: true))]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
    }

    await store.send(.copyRow(id: uuid(0)))
    await store.finish()
    #expect(copied.value == "copy me")
  }

  @Test func copyUnknownRowIsNoOp() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    await store.send(.copyRow(id: uuid(9))) // no such row → no effect, no state change
  }

  // MARK: Copy a code block with transient checkmark feedback (#9)

  @Test func copyCodePutsTextOnPasteboardAndShowsThenClearsCheckmark() async {
    let copied = LockIsolated<String?>(nil)
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = clock
    }

    await store.send(.copyCode(text: "let x = 1", token: "row#0")) {
      $0.recentlyCopiedToken = "row#0"
    }
    #expect(copied.value == "let x = 1")

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copyFeedbackExpired) {
      $0.recentlyCopiedToken = nil
    }
  }

  @Test func copyingAnotherBlockMovesTheCheckmarkAndRestartsTimer() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable _ in }
      $0.continuousClock = clock
    }

    await store.send(.copyCode(text: "a", token: "t1")) { $0.recentlyCopiedToken = "t1" }
    // Re-tapping before the first timer fires cancels it (cancelInFlight) and the
    // checkmark moves to the new block — only the second expiry arrives.
    await store.send(.copyCode(text: "b", token: "t2")) { $0.recentlyCopiedToken = "t2" }

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copyFeedbackExpired) { $0.recentlyCopiedToken = nil }
  }

  @Test func copyEmptyCodeIsNoOp() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    await store.send(.copyCode(text: "", token: "t")) // guard → no effect, no state change
  }

  @Test func staleFeedbackExpiryDoesNotClearNewerCheckmark() async {
    // A late expiry for an old token must not wipe a checkmark that has since moved.
    var state = ChatFeature.State(connection: conn)
    state.recentlyCopiedToken = "current"
    let store = TestStore(initialState: state) { ChatFeature() }
    await store.send(.copyFeedbackExpired(token: "stale")) // token mismatch → unchanged
  }

  // MARK: Voice input (#7)

  /// Drive the common path up to an active recording with the test recorder's 3 canned
  /// level samples already folded in. Caller owns the clock so the timer stays paused.
  private func startRecording(_ store: TestStore<ChatFeature.State, ChatFeature.Action>) async {
    await store.send(.voiceButtonTapped) { $0.recording = .requestingPermission }
    await store.receive(\.recordingPermission)
    await store.receive(\.recordingStarted) { $0.recording = .recording }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2] }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2, 0.6] }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2, 0.6, 0.4] }
  }

  @Test func voiceRecordingTranscribesAndAppendsToComposer() async {
    var initial = ChatFeature.State(connection: conn)
    initial.composerText = "draft"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = TestClock() // unadvanced → recording timer never ticks here
      $0.audioRecorder = .testValue
      $0.hermesREST.transcribe = { @Sendable _, _, _ in "hello world" }
    }

    await startRecording(store)

    await store.send(.voiceButtonTapped) { $0.recording = .transcribing }
    await store.receive(\.recordingStopped)
    await store.receive(\.transcriptionSucceeded) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.composerText = "draft hello world" // appended with a separating space
    }
  }

  @Test func voicePermissionDeniedShowsBanner() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.audioRecorder = .testValue
      $0.audioRecorder.requestPermission = { @Sendable in false }
    }

    await store.send(.voiceButtonTapped) { $0.recording = .requestingPermission }
    await store.receive(\.recordingPermission) {
      $0.recording = .idle
      $0.errorBanner = "Microphone access is off. Enable it in Settings to use voice input."
    }
  }

  @Test func voiceTranscriptionFailureSurfacesServerReason() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0.audioRecorder = .testValue
      $0.hermesREST.transcribe = { @Sendable _, _, _ in throw RESTError.transcriptionFailed("no speech detected") }
    }

    await startRecording(store)

    await store.send(.voiceButtonTapped) { $0.recording = .transcribing }
    await store.receive(\.recordingStopped)
    await store.receive(\.voiceInputFailed) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.errorBanner = "no speech detected"
    }
  }

  @Test func recordingTimerAdvancesElapsedSeconds() async {
    let clock = TestClock()
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.audioRecorder = .testValue
    }

    await startRecording(store)

    await clock.advance(by: .seconds(2))
    await store.receive(\.recordingTick) { $0.recordingSeconds = 1 }
    await store.receive(\.recordingTick) { $0.recordingSeconds = 2 }

    // Cancelling tears down the timer/levels and discards the recording.
    await store.send(.recordingCancelled) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.recordingSeconds = 0
    }
  }

  // MARK: Attachments (#8)

  private func imageAttachment(_ n: Int) -> ComposerAttachment {
    ComposerAttachment(
      id: uuid(n), kind: .image, filename: "photo\(n).png",
      mimeType: "image/png", data: Data([0x89, 0x50, UInt8(n)])
    )
  }

  @Test func attachmentAddAndRemove() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    let a = imageAttachment(0)
    let b = imageAttachment(1)
    await store.send(.attachmentAdded(a)) { $0.attachments = [a] }
    await store.send(.attachmentAdded(b)) { $0.attachments = [a, b] }
    await store.send(.removeAttachment(id: a.id)) { $0.attachments = [b] }
  }

  @Test func attachmentOnlyMessageIsSendable() {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live"
    #expect(state.canSend == false) // empty text + no attachments
    state.attachments = [imageAttachment(0)]
    #expect(state.canSend == true) // an attachment alone is enough to send
  }

  @Test func pickingFilesAddsEachWithFreshIDs() async {
    let picked = [
      PickedItem(data: Data([1]), filename: "a.pdf", mimeType: "application/pdf", kind: .pdf),
      PickedItem(data: Data([2]), filename: "b.txt", mimeType: "text/plain", kind: .file),
    ]
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.attachmentPicker.pickFiles = { @Sendable in picked }
    }

    await store.send(.attachFilesTapped)
    await store.receive(\.attachmentAdded) {
      $0.attachments = [picked[0].attachment(id: self.uuid(0))]
    }
    await store.receive(\.attachmentAdded) {
      $0.attachments = [picked[0].attachment(id: self.uuid(0)), picked[1].attachment(id: self.uuid(1))]
    }
  }

  @Test func cancelledPhotoPickerAddsNothing() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing // captured by the effect even though no item needs an id
      $0.attachmentPicker.pickPhotos = { @Sendable in [] }
    }
    await store.send(.attachPhotosTapped) // empty selection → no attachmentAdded, no change
  }

  // MARK: Attachment upload + submit (#8)

  private func pdfAttachment(_ n: Int) -> ComposerAttachment {
    ComposerAttachment(
      id: uuid(n), kind: .pdf, filename: "doc\(n).pdf",
      mimeType: "application/pdf", data: Data([0x25, 0x50, UInt8(n)])
    )
  }

  private func fileAttachment(_ n: Int) -> ComposerAttachment {
    ComposerAttachment(
      id: uuid(n), kind: .file, filename: "file\(n).txt",
      mimeType: "text/plain", data: Data([0x41, UInt8(n)])
    )
  }

  /// A submit store that records the outbound RPC method order and the `prompt.submit`
  /// text. `file.attach` replies with `fileRef`; `fail` makes the first upload throw.
  private func submitStore(
    text: String,
    attachments: [ComposerAttachment],
    methods: LockIsolated<[String]>,
    promptText: LockIsolated<String> = .init(""),
    fileRef: String = "@file:uploads/doc.txt",
    fail: GatewayError? = nil
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.composerText = text
    initial.attachments = attachments
    return TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        methods.withValue { $0.append(method) }
        if method == "prompt.submit" { promptText.setValue(params["text"]?.stringValue ?? "") }
        if let fail { throw fail }
        if method == "file.attach" { return .object(["attached": .bool(true), "ref_text": .string(fileRef)]) }
        return .object(["attached": .bool(true)])
      }
    }
  }

  @Test func imageAttachmentUploadsBytesThenSubmits() async {
    let methods = LockIsolated<[String]>([])
    let store = submitStore(text: "look", attachments: [imageAttachment(5)], methods: methods)

    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.attachments[0].uploadState = .uploading
    }
    await store.receive(\.attachmentsSubmitted) {
      $0.transcript = [ChatRow(
        id: self.uuid(0),
        kind: .message(role: .user, text: "look", isComplete: true),
        attachmentImages: [Data([0x89, 0x50, 5])] // image echoed as a thumbnail
      )]
      $0.composerText = ""
      $0.attachments = []
    }
    #expect(methods.value == ["image.attach_bytes", "prompt.submit"])
  }

  @Test func pdfAttachmentUploadsThenSubmits() async {
    let methods = LockIsolated<[String]>([])
    let store = submitStore(text: "read", attachments: [pdfAttachment(6)], methods: methods)

    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.attachments[0].uploadState = .uploading
    }
    await store.receive(\.attachmentsSubmitted) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "read", isComplete: true))]
      $0.composerText = ""
      $0.attachments = []
    }
    #expect(methods.value == ["pdf.attach", "prompt.submit"])
  }

  @Test func fileAttachmentWeavesRefIntoPromptText() async {
    let methods = LockIsolated<[String]>([])
    let promptText = LockIsolated<String>("")
    let store = submitStore(
      text: "summarize", attachments: [fileAttachment(7)],
      methods: methods, promptText: promptText, fileRef: "@file:uploads/file7.txt"
    )

    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.attachments[0].uploadState = .uploading
    }
    await store.receive(\.attachmentsSubmitted) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "summarize", isComplete: true))]
      $0.composerText = ""
      $0.attachments = []
    }
    #expect(methods.value == ["file.attach", "prompt.submit"])
    #expect(promptText.value == "@file:uploads/file7.txt\nsummarize") // ref prepended on its own line
  }

  @Test func mixedAttachmentsUploadEachByKindThenSubmit() async {
    let methods = LockIsolated<[String]>([])
    let store = submitStore(
      text: "", attachments: [imageAttachment(5), pdfAttachment(6), fileAttachment(7)], methods: methods
    )

    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.attachments[0].uploadState = .uploading
      $0.attachments[1].uploadState = .uploading
      $0.attachments[2].uploadState = .uploading
    }
    await store.receive(\.attachmentsSubmitted) {
      // No text → the image shows as a thumbnail; non-image files fall back to their names.
      $0.transcript = [ChatRow(
        id: self.uuid(0),
        kind: .message(role: .user, text: "doc6.pdf, file7.txt", isComplete: true),
        attachmentImages: [Data([0x89, 0x50, 5])]
      )]
      $0.attachments = []
    }
    #expect(methods.value == ["image.attach_bytes", "pdf.attach", "file.attach", "prompt.submit"])
  }

  @Test func uploadFailureAbortsSubmitAndKeepsAttachments() async {
    let methods = LockIsolated<[String]>([])
    let store = submitStore(
      text: "keep me", attachments: [imageAttachment(5)], methods: methods, fail: .server("boom")
    )

    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.attachments[0].uploadState = .uploading
    }
    await store.receive(\.attachmentUploadFailed) {
      $0.errorBanner = "Attachment failed: boom"
      $0.isSending = false
      $0.attachments[0].uploadState = .failed("boom")
    }
    #expect(store.state.composerText == "keep me") // input preserved for retry
    #expect(store.state.attachments.count == 1)
    #expect(methods.value == ["image.attach_bytes"]) // never reached prompt.submit
  }

  // MARK: Capability gating for old agents (#8, -32601)

  @Test func gatewayErrorDetectsUnknownMethod() {
    #expect(GatewayError.server("unknown method: image.attach_bytes").isUnknownMethod)
    #expect(GatewayError.server("Unknown method: x").isUnknownMethod) // case-insensitive
    #expect(!GatewayError.server("boom").isUnknownMethod)
    #expect(!GatewayError.disconnected.isUnknownMethod)
    #expect(!GatewayError.timedOut(method: "image.attach_bytes").isUnknownMethod)
  }

  @Test func unknownAttachMethodGatesFeatureAndAborts() async {
    let methods = LockIsolated<[String]>([])
    let store = submitStore(
      text: "hi", attachments: [imageAttachment(5)], methods: methods,
      fail: .server("unknown method: image.attach_bytes")
    )

    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.attachments[0].uploadState = .uploading
    }
    await store.receive(\.attachmentsUnsupportedDetected) {
      $0.attachmentsUnsupported = true
      $0.isSending = false
      $0.errorBanner = "This Hermes agent is too old to accept attachments. Update the agent to send files."
      $0.attachments[0].uploadState = .failed("Attachments not supported")
    }
    #expect(methods.value == ["image.attach_bytes"]) // aborted before prompt.submit
    #expect(store.state.composerText == "hi") // input preserved
  }
}
