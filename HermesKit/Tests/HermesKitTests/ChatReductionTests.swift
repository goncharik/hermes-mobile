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

  // Slot teardown mid-turn cancels the live thinking timer (no leaked tick loop).
  @Test func teardownCancelsThinkingTimer() async {
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
    // Teardown cancels the loop; advancing further yields no more ticks.
    await store.send(.teardown)
    await clock.advance(by: .seconds(5))
  }

  // Background-grace expiry: `.teardownSocketOnly` cancels the socket effect WITHOUT its
  // trailing `.gatewayClosed` (so no backoff reconnect is scheduled while suspended) and
  // leaves the in-flight turn state intact — live thinking row, pointers, `isSending` —
  // for the #26-preserving foreground hydrate. Only the status flips to `.reconnecting`
  // (the socket is genuinely gone, so a later `.reattached` redials instead of hydrating
  // a dead socket).
  @Test func teardownSocketOnlyKeepsInFlightStateAndSkipsBackoff() async {
    let clock = TestClock()
    let socketClosed = LockIsolated(false)
    var initial = ChatFeature.State(connection: conn)
    // Seed the hydrate guard as a `.ready` would have left it, so `.teardownSocketOnly`'s
    // reset (the next `.ready` must genuinely re-hydrate) is observable below.
    initial.hasRequestedSession = true
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.hermesGateway.connect = { @Sendable _, _ in
        AsyncStream { continuation in
          continuation.onTermination = { _ in socketClosed.setValue(true) }
        }
      }
    }

    await store.send(.task) { $0.hasStarted = true }
    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }

    await store.send(.teardownSocketOnly) {
      $0.status = .reconnecting
      $0.hasRequestedSession = false
    }
    // The socket effect terminated by CANCELLATION — the exhaustive store proves the
    // trailing `.gatewayClosed` was dropped (no reconnect backoff, no in-flight finalize).
    await waitUntil { socketClosed.value }
    #expect(store.state.isSending)
    #expect(store.state.thinkingRowID == uuid(0))

    // The thinking ticker deliberately stays (the hydrate's `reconcileTimer` owns it);
    // full teardown cleans it up.
    await store.send(.teardown)
  }

  // `.viewDisappeared` (the screen left — forwarded by `AppFeature.chatViewDisappeared`)
  // releases only the VIEW-session resources: recording state reset + mic released. The
  // slot's long-running effects are untouched — the thinking ticker (a stand-in for the
  // socket/persist effects rooted alongside it) keeps firing after the view is gone.
  @Test func viewDisappearedReleasesMicButKeepsSlotEffects() async {
    let clock = TestClock()
    let micCancelled = LockIsolated(false)
    var initial = ChatFeature.State(connection: conn)
    initial.recording = .recording
    initial.waveformLevels = [0.4, 0.8]
    initial.recordingSeconds = 7
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.audioRecorder.cancel = { micCancelled.setValue(true) }
    }

    // A turn is running: the live thinking row + elapsed ticker are slot-rooted effects.
    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }

    await store.send(.viewDisappeared) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.recordingSeconds = 0
    }
    // The mic/recording session was released…
    await waitUntil { micCancelled.value }
    // …but the slot's effects survived the view: the ticker still fires.
    await clock.advance(by: .seconds(1))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }

    await store.send(.teardown)
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
    await store.send(.teardown)
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
    await store.send(.teardown)
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
    await store.send(.teardown)
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

  // Leading/trailing whitespace and newlines are trimmed before submit (#31); interior
  // formatting is preserved. The trimmed text is both what's echoed in the user row and
  // what goes out on the wire.
  @Test func composerSubmitTrimsLeadingTrailingWhitespaceAndNewlines() async {
    let sentText = LockIsolated<String?>(nil)
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable _, params in
        sentText.setValue(params["text"]?.stringValue)
        return .object(["status": .string("streaming")])
      }
    }

    let raw = "  \n\nline one\n\n  indented line two  \n \n"
    let trimmed = "line one\n\n  indented line two"
    await store.send(\.binding.composerText, raw) { $0.composerText = raw }
    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .message(role: .user, text: trimmed, isComplete: true))]
      $0.composerText = ""
      $0.isSending = true
    }
    await store.finish()
    #expect(sentText.value == trimmed)
  }

  // Whitespace-only input never submits: canSend is false, so composerSubmitted is a no-op
  // (nothing sent, composer untouched).
  @Test func composerSubmitIgnoresWhitespaceOnlyInput() async {
    let didSend = LockIsolated(false)
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        didSend.setValue(true)
        return .object(["status": .string("streaming")])
      }
    }

    await store.send(\.binding.composerText, "  \n\n \t ") { $0.composerText = "  \n\n \t " }
    #expect(store.state.canSend == false)
    await store.send(.composerSubmitted)
    #expect(didSend.value == false)
  }

  // A submit while a turn streams must never start a second in-flight submit (it would
  // corrupt `isSending`, and if it later failed it would emit a spurious
  // `runningChanged(false)` that tears down a detached slot whose first turn is still
  // genuinely running). Since #66 the mid-turn draft QUEUES instead: no RPC, no transcript
  // row — the entry drains through the normal pipeline once the turn ends.
  @Test func submitWhileSendingQueuesInsteadOfSubmitting() async {
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.composerText = "second message typed mid-turn"
    initial.isSending = true
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }

    #expect(initial.canSend == false)
    #expect(initial.canQueue == true)
    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [
        QueuedPrompt(id: self.uuid(0), text: "second message typed mid-turn")
      ]
      $0.composerText = ""
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
        // The async slash-catalog fetch (#36) fires after create resolves — don't let it
        // clobber the recorded `session.create` call this test asserts on.
        if method != "commands.catalog" {
          sent.setValue(.object(["method": .string(method), "params": params]))
        }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }

    await store.send(.task) {
      $0.hasStarted = true
    }
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      $0.hasHydrated = true
    }
    // New sessions create with no title so the server auto-names from the first message.
    #expect(sent.value?["method"]?.stringValue == "session.create")
    #expect(sent.value?["params"] == .object([:]))
    #expect(sent.value?["params"]?["title"] == nil)
    await store.send(.teardown)
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
        // Ignore the async slash-catalog fetch (#36) — it must not clobber the recorded
        // `session.create` call these assertions read.
        if method != "commands.catalog" {
          sent.setValue(.object(["method": .string(method), "params": params]))
        }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }

    await store.send(.task) {
      $0.hasStarted = true
    }
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      $0.hasHydrated = true
    }
    #expect(sent.value?["method"]?.stringValue == "session.create")
    #expect(sent.value?["params"] == .object(["profile": .string("work")]))
    await store.send(.teardown)
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
        // Ignore the async slash-catalog fetch (#36) — it must not clobber the recorded
        // `session.create` call these assertions read.
        if method != "commands.catalog" {
          sent.setValue(.object(["method": .string(method), "params": params]))
        }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }

    await store.send(.task) {
      $0.hasStarted = true
    }
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
      $0.status = .ready
      $0.hasHydrated = true
    }
    #expect(sent.value?["params"] == .object([:]))
    await store.send(.teardown)
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
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
    }
    #expect(activateParams.value == .object([
      "session_id": .string("stored123"),
      "profile": .string("work"),
    ]))
    // Activate's authoritative `running:false` clears the list glow for this session.
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
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
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(
        input: 120_000, output: 30_000, total: 150_000,
        contextUsed: 150_000, contextMax: 200_000, contextPercent: 75
      )
    }
    // Hydrate itself is the single `session.resume` (the trailing slash-catalog fetch, #36,
    // is a separate concern) — no activate, and no fallback `session.usage` fetch.
    #expect(methods.value.filter { $0 != "commands.catalog" } == ["session.resume"])
    #expect(!methods.value.contains("session.usage"))
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
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
      $0.hasHydrated = true
    }
    // The synchronous delegate send lands before the async usage fetch resolves.
    await store.receive(\.delegate.runningChanged)
    await store.receive(\.usageResponse) {
      $0.usage = Usage(contextUsed: 150_000, contextMax: 200_000, contextPercent: 75)
    }
    #expect(methods.value.first == "session.resume")
    #expect(methods.value.contains("session.usage"))
    #expect(usageParams.value?["session_id"]?.stringValue == "live123")
    await store.send(.teardown)
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
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 10, contextMax: 200_000, contextPercent: 0)
      // Rows carry deterministic, content-derived ids (matching `reconstructTranscript`).
      $0.transcript = IdentifiedArrayOf(uniqueElements: reconstructTranscript([
        SessionMessage(id: 1, role: "user", content: "hi"),
        SessionMessage(id: 2, role: "assistant", content: "hello"),
      ]))
    }
    // Single resume call — no activate, no fallback dance. (The trailing slash-catalog
    // fetch, #36, is a separate concern.)
    #expect(methods.value.filter { $0 != "commands.catalog" } == ["session.resume"])
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
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
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 5, contextMax: 200_000, contextPercent: 0)
      // running == true → working indicator on.
      $0.isSending = true
      // Inflight user row + seeded streaming assistant row + a live thinking row recreated by
      // the timer reconcile (running with no anchor → ticks from 0). The seeded rows now carry
      // DETERMINISTIC, position-derived ids (review finding #4) — not fresh uuids — so repeated
      // hydrates don't churn identity. Derived from their transcript positions (0/1/2).
      let inflightUserID = ChatRow.deterministicID(sequenceIndex: 0, role: .user, kindDiscriminator: "message")
      let inflightAssistantID = ChatRow.deterministicID(sequenceIndex: 1, role: .assistant, kindDiscriminator: "message")
      let inflightThinkingID = ChatRow.deterministicID(sequenceIndex: 2, role: nil, kindDiscriminator: "thinking")
      $0.transcript = [
        ChatRow(id: inflightUserID, kind: .message(role: .user, text: "explain this", isComplete: true)),
        ChatRow(id: inflightAssistantID, kind: .message(role: .assistant, text: "Sure, ", isComplete: false)),
        ChatRow(
          id: inflightThinkingID,
          kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
        ),
      ]
      $0.streamingRowID = inflightAssistantID
      $0.thinkingRowID = inflightThinkingID
    }
    // Activate's authoritative `running:true` lights the list glow for this session.
    await store.receive(\.delegate.runningChanged)
    // The next delta appends to the seeded row — a SINGLE assistant row, no duplicate; the
    // live thinking row is moved to last (keepThinkingLast) but stays the same row.
    let inflightAssistantID = ChatRow.deterministicID(sequenceIndex: 1, role: .assistant, kindDiscriminator: "message")
    await store.send(.gatewayEvent(.messageDelta(text: "here goes."))) {
      $0.transcript[id: inflightAssistantID]?.kind = .message(role: .assistant, text: "Sure, here goes.", isComplete: false)
    }
    // user + assistant + thinking = 3 rows (no duplicate assistant from the delta).
    #expect(store.state.transcript.count == 3)
    await store.send(.teardown)
  }

  @Test func unknownEventIsInertInTheFold() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    }
    // Forward-compat: events the UI doesn't model must not mutate state or crash.
    await store.send(.gatewayEvent(.unknown(type: "tool.progress", raw: .object([:]))))
  }

  // MARK: Review summary (#47) — live-only system row

  @Test func reviewSummaryAppendsStatusRowVerbatim() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    // The wire text (💾 prefix included) lands verbatim in a bubble-less status row.
    await store.send(.gatewayEvent(.reviewSummary(text: "💾 Self-improvement review: tightened the search prompt."))) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .status(kind: "review", text: "💾 Self-improvement review: tightened the search prompt."))
      ]
    }
  }

  @Test func blankReviewSummaryIsDroppedWithoutPersist() async {
    // Session ids are set so the persist gate at the `.gatewayEvent` wrapper is live: if a
    // blank summary counted as persist-relevant, the exhaustive TestStore would fail on the
    // scheduled (never-completed) debounce effect. Proves the fold no-op schedules nothing.
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.status = .ready
    let store = TestStore(initialState: initial) {
      ChatFeature()
    }
    // A payload with no visible text must not render a blank caption row — neither empty
    // nor whitespace-only (a whitespace row would paint as an invisible line).
    await store.send(.gatewayEvent(.reviewSummary(text: "")))
    await store.send(.gatewayEvent(.reviewSummary(text: " \n\t ")))
  }

  @Test func reviewSummaryMidTurnInterleavesWithStreamingAndKeepsThinkingLast() async {
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
    // The turn is actively streaming when the summary lands: the first delta creates the
    // in-flight assistant row (above the pinned thinking row).
    await store.send(.gatewayEvent(.messageDelta(text: "Sure, "))) {
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "Sure, ", isComplete: false)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.streamingRowID = uuid(1)
    }
    // A summary arriving mid-turn slots in BELOW the partial assistant row and above the
    // pinned live thinking row: [assistant][summary][thinking].
    await store.send(.gatewayEvent(.reviewSummary(text: "💾 Self-improvement review: noted."))) {
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "Sure, ", isComplete: false)),
        ChatRow(id: uuid(2), kind: .status(kind: "review", text: "💾 Self-improvement review: noted.")),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
    }
    #expect(store.state.transcript.last?.id == uuid(0))
    // Later deltas keep mutating the SAME streaming row in place, above the summary — the
    // summary must not capture or reorder the stream.
    await store.send(.gatewayEvent(.messageDelta(text: "here goes."))) {
      $0.transcript[id: self.uuid(1)]?.kind = .message(role: .assistant, text: "Sure, here goes.", isComplete: false)
    }
    #expect(store.state.transcript.map(\.id) == [uuid(1), uuid(2), uuid(0)])
    // Turn ends: the empty thinking row is removed; the answer + summary stay in order.
    await store.send(.gatewayEvent(.messageComplete(text: "Sure, here goes.", usage: nil))) {
      $0.transcript[id: self.uuid(1)]?.kind = .message(role: .assistant, text: "Sure, here goes.", isComplete: true)
      $0.transcript.remove(id: self.uuid(0))
      $0.thinkingRowID = nil
      $0.streamingRowID = nil
      $0.isSending = false
    }
    #expect(store.state.transcript.map(\.id) == [uuid(1), uuid(2)])
  }

  @Test func reviewSummaryTriggersSnapshotPersist() async {
    // The appended row must reach the snapshot cache (same debounced write-back as other
    // transcript-changing events) so the next open paints it instantly.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.status = .ready

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 123))
      $0.chatSnapshot = snapshotClient
    }

    await store.send(.gatewayEvent(.reviewSummary(text: "💾 Self-improvement review: done."))) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .status(kind: "review", text: "💾 Self-improvement review: done."))
      ]
    }
    // Nothing persisted yet (still inside the debounce window).
    #expect(snapshotClient.loadSnapshot("stored123") == nil)

    await clock.advance(by: .seconds(1))
    await store.receive(\.persistSnapshotTick)

    let saved = snapshotClient.loadSnapshot("stored123")
    #expect(saved?.rows == [
      ChatRow(id: self.uuid(0), kind: .status(kind: "review", text: "💾 Self-improvement review: done."))
    ])

    await store.send(.teardown)
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
    await store.send(.teardown)
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
    await store.send(.teardown)
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
    await store.send(.teardown)
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
    await store.send(.teardown)
  }

  // MARK: Copy a row to the pasteboard

  @Test func copyRowPutsRawMarkdownOnPasteboardAndShowsThenClearsCheckmark() async {
    let copied = LockIsolated<String?>(nil)
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn)
    initial.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "# copy **me**", isComplete: true))]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable text in copied.setValue(text) }
      $0.continuousClock = clock
    }

    // The pasteboard gets the raw Markdown, and the row-scoped token drives the
    // action bar's transient checkmark (#34).
    await store.send(.copyRow(id: uuid(0))) {
      $0.recentlyCopiedToken = ChatFeature.rowCopyToken(self.uuid(0))
    }
    #expect(copied.value == "# copy **me**")

    await clock.advance(by: .seconds(1.5))
    await store.receive(\.copyFeedbackExpired) {
      $0.recentlyCopiedToken = nil
    }
  }

  @Test func reCopyingARowRestartsTheFeedbackTimer() async {
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn)
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "first", isComplete: true)),
      ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "second", isComplete: true)),
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable _ in }
      $0.continuousClock = clock
    }

    await store.send(.copyRow(id: uuid(0))) {
      $0.recentlyCopiedToken = ChatFeature.rowCopyToken(self.uuid(0))
    }
    // Copying another row before the first expiry cancels it (cancelInFlight) — the
    // checkmark moves and only the second expiry arrives, 1.5s after the second copy.
    await clock.advance(by: .seconds(1.0))
    await store.send(.copyRow(id: uuid(1))) {
      $0.recentlyCopiedToken = ChatFeature.rowCopyToken(self.uuid(1))
    }
    await clock.advance(by: .seconds(1.0)) // 2.0s after first copy — first timer is dead
    await clock.advance(by: .seconds(0.5))
    await store.receive(\.copyFeedbackExpired) { $0.recentlyCopiedToken = nil }
  }

  @Test func rowCopyCancelsPendingCodeCopyFeedback() async {
    // Code-block copy and whole-row copy share one feedback slot (`CancelID.copyFeedback`):
    // a row copy 1s after a code copy cancels the code timer — only ONE expiry arrives,
    // 1.5s after the row copy, and the code token is gone the moment the row copy lands.
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn)
    initial.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "row text", isComplete: true))]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.pasteboard.copy = { @Sendable _ in }
      $0.continuousClock = clock
    }

    await store.send(.copyCode(text: "let x = 1", token: "code#0")) {
      $0.recentlyCopiedToken = "code#0"
    }
    await clock.advance(by: .seconds(1.0))
    await store.send(.copyRow(id: uuid(0))) {
      $0.recentlyCopiedToken = ChatFeature.rowCopyToken(self.uuid(0))
    }
    // 1.5s after the FIRST copy — its timer is dead, nothing fires.
    await clock.advance(by: .seconds(0.5))
    // 1.5s after the row copy: the single surviving expiry clears the row token.
    await clock.advance(by: .seconds(1.0))
    await store.receive(\.copyFeedbackExpired) {
      $0.recentlyCopiedToken = nil
    }
  }

  @Test func copyUnknownRowIsNoOp() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    await store.send(.copyRow(id: uuid(9))) // no such row → no effect, no state change
  }

  @Test func copyEmptyTextRowIsNoOp() async {
    var initial = ChatFeature.State(connection: conn)
    initial.transcript = [ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "", isComplete: true))]
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.copyRow(id: uuid(0))) // empty copyText → no pasteboard, no token
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
      $0.attachmentPicker.pickFiles = { @Sendable in PickedBatch(items: picked) }
    }

    await store.send(.attachFilesTapped)
    await store.receive(\.attachmentAdded) {
      $0.attachments = [picked[0].attachment(id: self.uuid(0))]
    }
    await store.receive(\.attachmentAdded) {
      $0.attachments = [picked[0].attachment(id: self.uuid(0)), picked[1].attachment(id: self.uuid(1))]
    }
  }

  /// A picked photo that never loaded (an iCloud original that wouldn't download in time, a
  /// type that couldn't be re-encoded) used to be a *silent* no-op: the sheet dismissed and
  /// nothing appeared. The sheet can't distinguish that from a cancel on its own, so the
  /// drop count does.
  @Test func aPickThatLoadsNothingIsReported() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.attachmentPicker.pickPhotos = { @Sendable in PickedBatch(droppedCount: 1) }
    }

    await store.send(.attachPhotosTapped)
    await store.receive(\.attachmentsDropped) {
      $0.errorBanner = "Couldn’t add the selected item."
    }
  }

  /// A partial loss is reported too — the chips that made it are staged first, so the banner
  /// is about the ones that didn't.
  @Test func aPartiallyLoadedPickStagesWhatSurvivedAndSaysWhatDidNot() async {
    let picked = [PickedItem(data: Data([1]), filename: "a.png", mimeType: "image/png", kind: .image)]
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.attachmentPicker.pickPhotos = { @Sendable in PickedBatch(items: picked, droppedCount: 2) }
    }

    await store.send(.attachPhotosTapped)
    await store.receive(\.attachmentAdded) {
      $0.attachments = [picked[0].attachment(id: self.uuid(0))]
    }
    await store.receive(\.attachmentsDropped) {
      $0.errorBanner = "Couldn’t add 2 of the selected items."
    }
  }

  /// A re-pick that *works* takes the previous failure's banner down with it — the same rule a
  /// successful paste follows. (The staging runs before the shortfall is reported, so the
  /// partial-loss test above still ends with its banner up.)
  @Test func aSuccessfulRePickClearsAStaleDropBanner() async {
    var initial = ChatFeature.State(connection: conn)
    initial.errorBanner = "Couldn’t add the selected item."
    let picked = [PickedItem(data: Data([1]), filename: "a.png", mimeType: "image/png", kind: .image)]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.attachmentPicker.pickPhotos = { @Sendable in PickedBatch(items: picked) }
    }

    await store.send(.attachPhotosTapped)
    await store.receive(\.attachmentAdded) {
      $0.errorBanner = nil
      $0.attachments = [picked[0].attachment(id: self.uuid(0))]
    }
  }

  // MARK: Pasted images (#54)

  private func pastedImage(_ n: Int) -> PickedItem {
    PickedItem(
      data: Data([0x89, 0x50, UInt8(n)]),
      filename: n == 0 ? "pasted-image.png" : "pasted-image-\(n + 1).png",
      mimeType: "image/png",
      kind: .image
    )
  }

  @Test func pastingImagesStagesThemInOrderWithFreshIDs() async {
    let items = [pastedImage(0), pastedImage(1)]
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(items: items))) {
      $0.pendingPasteCount = 0
      $0.attachments = [
        items[0].attachment(id: self.uuid(0)),
        items[1].attachment(id: self.uuid(1)),
      ]
    }
  }

  @Test func pastingImagesAppendsAfterAlreadyStagedAttachments() async {
    var initial = ChatFeature.State(connection: conn)
    let existing = imageAttachment(9)
    initial.attachments = [existing]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    let pasted = pastedImage(0)
    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(items: [pasted]))) {
      $0.pendingPasteCount = 0
      $0.attachments = [existing, pasted.attachment(id: self.uuid(0))]
    }
  }

  /// The view only hands over a paste it *claimed* (the clipboard advertised an image), so an
  /// empty batch means every provider failed to load or re-encode. iOS offered **Paste**, the
  /// user tapped it — the one outcome that must not happen is silence.
  @Test func pastingImagesThatAllFailedToLoadSurfacesABanner() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(droppedCount: 1))) {
      $0.pendingPasteCount = 0
      $0.errorBanner = "Couldn’t paste the image."
    }
    #expect(store.state.attachments.isEmpty)
  }

  /// …and a paste that *works* takes the stale banner down with it — a failure message left
  /// hanging over a freshly staged chip reads as a verdict on that chip.
  @Test func aSuccessfulPasteClearsAStaleBanner() async {
    var initial = ChatFeature.State(connection: conn)
    initial.errorBanner = "Couldn’t paste the image."
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    let pasted = pastedImage(0)
    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(items: [pasted]))) {
      $0.pendingPasteCount = 0
      $0.errorBanner = nil
      $0.attachments = [pasted.attachment(id: self.uuid(0))]
    }
  }

  /// …except when the agent can't take attachments at all: that flip banners its own
  /// explanation, and a second one on top would be noise.
  @Test func pastingNothingIsSilentWhenAttachmentsUnsupported() async {
    var initial = ChatFeature.State(connection: conn)
    initial.attachmentsUnsupported = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(droppedCount: 1))) { $0.pendingPasteCount = 0 }
  }

  @Test func pastingImagesIsIgnoredWhenAttachmentsUnsupported() async {
    var initial = ChatFeature.State(connection: conn)
    initial.attachmentsUnsupported = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }
    // Backstop for the window the view's own gate can't cover (the capability can flip while
    // the pasted providers are still loading): nothing staged.
    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(items: [pastedImage(0), pastedImage(1)]))) {
      $0.pendingPasteCount = 0
    }
  }

  /// A paste that only *partly* survived says so. Only the survivors used to come back, so a
  /// three-image paste that yielded two was indistinguishable from a two-image paste — and the
  /// user sent an incomplete set believing it complete. The banner lands **after** the staging,
  /// so it is not the chips' own clear that wipes it.
  @Test func aPartiallyLostPasteStagesWhatSurvivedAndSaysSo() async {
    let pasted = pastedImage(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(items: [pasted], droppedCount: 2))) {
      $0.pendingPasteCount = 0
      $0.attachments = [pasted.attachment(id: self.uuid(0))]
      $0.errorBanner = "Couldn’t paste 2 of the images."
    }
  }

  @Test func aSinglyLostPasteIsWordedInTheSingular() async {
    let pasted = pastedImage(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(items: [pasted], droppedCount: 1))) {
      $0.pendingPasteCount = 0
      $0.attachments = [pasted.attachment(id: self.uuid(0))]
      $0.errorBanner = "Couldn’t paste 1 of the images."
    }
  }

  /// A paste is the one attachment source with no modal sheet over it: the composer, with the
  /// user's typed text already in it, stays fully interactive while the clipboard providers
  /// load. Submitting in that window shipped the message *without* the image, which then
  /// reappeared orphaned in the next draft.
  @Test func aPasteInFlightBlocksSubmissionUntilItLands() async {
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.composerText = "look at this"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }
    #expect(store.state.canSend)

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    #expect(!store.state.canSend, "Send has to wait for the bytes it is meant to carry")
    // A submit racing the load is a no-op — the text stays put rather than going out alone.
    await store.send(.composerSubmitted)
    #expect(store.state.composerText == "look at this")

    let pasted = pastedImage(0)
    await store.send(.attachmentsPasted(PickedBatch(items: [pasted]))) {
      $0.pendingPasteCount = 0
      $0.attachments = [pasted.attachment(id: self.uuid(0))]
    }
    #expect(store.state.canSend)
  }

  /// Two fast pastes are both outstanding at once (the view's coordinator chains their loads),
  /// which is why the gate is a counter: a `Bool` would unlock on the first delivery while the
  /// second batch was still loading.
  @Test func overlappingPastesEachHoldTheGate() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 2 }

    let first = pastedImage(0)
    await store.send(.attachmentsPasted(PickedBatch(items: [first]))) {
      $0.pendingPasteCount = 1
      $0.attachments = [first.attachment(id: self.uuid(0))]
    }
    let second = pastedImage(1)
    await store.send(.attachmentsPasted(PickedBatch(items: [second]))) {
      $0.pendingPasteCount = 0
      $0.attachments.append(second.attachment(id: self.uuid(1)))
    }
  }

  /// The gate is released on **every** terminal outcome, not just the happy one — a paste that
  /// loaded nothing, or one that arrived after the capability was withdrawn, must not leave the
  /// composer locked for the rest of the session.
  @Test func theGateIsReleasedByAPasteThatStagesNothing() async {
    var initial = ChatFeature.State(connection: conn)
    initial.attachmentsUnsupported = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(droppedCount: 1))) { $0.pendingPasteCount = 0 }
  }

  /// A batch that arrives at a chat which never pasted is **not this chat's** and is dropped.
  /// The paste load is the one attachment source outside TCA's effect lifecycle — the pickers
  /// are `.run` effects that `ifLet` cancels on teardown, while the coordinator's `Task`
  /// delivers unconditionally through the store `ChatView` captured, which the root's
  /// `ifLet(\.liveChat)` routes to whatever chat now occupies the slot. Over the whole load
  /// window (up to `clipboardLoadTimeout`) an idle pop + open, a push tap (#32) or a branch
  /// creation can have replaced it, and without the pairing check the image would silently
  /// appear in — and upload to — a conversation it was never pasted into.
  @Test func aPasteBatchFromAnotherChatIsIgnored() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    // No `attachmentsPasting`: nothing staged, no banner, and the gate stays where it was.
    await store.send(.attachmentsPasted(PickedBatch(items: [pastedImage(0)], droppedCount: 1)))
    #expect(store.state.attachments.isEmpty)
    #expect(store.state.errorBanner == nil)
    #expect(store.state.pendingPasteCount == 0)
  }

  /// …and a stray batch can't rob a paste this chat *is* waiting on: it is dropped whole
  /// rather than decrementing someone else's gate.
  @Test func aStrayPasteBatchDoesNotConsumeThisChatsPendingPaste() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    let mine = pastedImage(0)
    await store.send(.attachmentsPasted(PickedBatch(items: [mine]))) {
      $0.pendingPasteCount = 0
      $0.attachments = [mine.attachment(id: self.uuid(0))]
    }
    // The other chat's batch, arriving late: the staged attachments are untouched.
    await store.send(.attachmentsPasted(PickedBatch(items: [pastedImage(1)])))
    #expect(store.state.attachments.count == 1)
  }

  /// The pasted→uploaded path end to end: a `PickedItem` handed over by the paste coordinator
  /// is staged and then uploaded through the same `image.attach_bytes` hop a picked photo uses.
  @Test func pastedImagesUploadOnSubmitLikePickedOnes() async {
    let methods = LockIsolated<[String]>([])
    let pasted = pastedImage(0)
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.composerText = "look"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        methods.withValue { $0.append(method) }
        return .object(["attached": .bool(true)])
      }
    }

    await store.send(.attachmentsPasting) { $0.pendingPasteCount = 1 }
    await store.send(.attachmentsPasted(PickedBatch(items: [pasted]))) {
      $0.pendingPasteCount = 0
      $0.attachments = [pasted.attachment(id: self.uuid(0))]
    }
    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.attachments[0].uploadState = .uploading
    }
    await store.receive(\.attachmentsSubmitted) {
      $0.transcript = [ChatRow(
        id: self.uuid(1),
        kind: .message(role: .user, text: "look", isComplete: true),
        attachmentImages: [pasted.data] // the pasted bytes echo back as the thumbnail
      )]
      $0.composerText = ""
      $0.attachments = []
    }
    #expect(methods.value == ["image.attach_bytes", "prompt.submit"])
  }

  /// A cancel carries no items *and* no drops, so it stays silent — the distinction the drop
  /// count exists to draw.
  @Test func cancelledPhotoPickerAddsNothing() async {
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing // captured by the effect even though no item needs an id
      $0.attachmentPicker.pickPhotos = { @Sendable in PickedBatch() }
    }
    await store.send(.attachPhotosTapped) // empty selection → no attachmentAdded, no banner
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
    // Client-side turn end → the slot-teardown/glow delegate fires (no server event follows).
    await store.receive(\.delegate.runningChanged)
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
    // Client-side turn end → the slot-teardown/glow delegate fires (no server event follows).
    await store.receive(\.delegate.runningChanged)
    #expect(methods.value == ["image.attach_bytes"]) // aborted before prompt.submit
    #expect(store.state.composerText == "hi") // input preserved
  }

  // MARK: Push-tap approval recovery (#30 workaround)

  /// A minimal activate response for the recovery tests: no messages/inflight, usage
  /// present (so `applyActivate` skips the on-demand usage fetch) and the given `running`.
  private func activateResponse(running: Bool) -> ActivateResponse {
    ActivateResponse(
      sessionID: "live123",
      storedSessionID: "stored123",
      messages: [],
      info: SessionInfo(
        model: "claude-opus-4-8",
        usage: Usage(contextUsed: 1, contextMax: 200_000, contextPercent: 0)
      ),
      running: running
    )
  }

  /// A TestStore over a chat whose hydrate is driven by direct `.activateResult` sends —
  /// the same reduction path (`applyActivate`) all open/foreground/reattach routes funnel
  /// through. Non-exhaustive: these tests assert the interaction/hint state, not the
  /// timer/persist bookkeeping already covered by `HydrateTests`.
  private func recoveryStore(_ initial: ChatFeature.State) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      // Only `approval.respond` is sent here (hydrates are driven by direct
      // `.activateResult` sends); `resolved: 1` is a clean success — no feedback action
      // fires, the optimistic "Approved"/"Denied" row stands.
      $0.hermesGateway.send = { @Sendable _, _ in .object(["resolved": .number(1)]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  @Test func hydrateWithHintOnRunningTurnSynthesizesRecoveredCard() async {
    // The approval push fired while the socket was down; the tap set the hint. Hydrate
    // reports the turn still running and no real request arrived → the generic
    // command-less card is synthesized and the one-shot hint is consumed.
    var initial = ChatFeature.State(connection: conn)
    initial.expectsPendingApproval = true
    let store = recoveryStore(initial)

    await store.send(.activateResult(.success(activateResponse(running: true))))
    #expect(store.state.pendingInteraction == .approval(ChatFeature.recoveredApprovalRequest))
    #expect(store.state.expectsPendingApproval == false)
    // The synthetic card is command-less by design (the push carries no content).
    if case let .approval(request) = store.state.pendingInteraction {
      #expect(request.command == nil)
      #expect(request.detail?.isEmpty == false)
    }

    // Double hydrate of the same running turn: the hint was consumed on the first pass,
    // so after the user answers the card a re-hydrate must NOT re-synthesize it.
    await store.send(.respondToApproval(approve: true, all: false))
    #expect(store.state.pendingInteraction == nil)
    await store.send(.activateResult(.success(activateResponse(running: true))))
    #expect(store.state.pendingInteraction == nil)
    #expect(store.state.expectsPendingApproval == false)

    await store.send(.teardown)
  }

  @Test func hydrateWithHintOnStoppedTurnSynthesizesNothing() async {
    // The approval resolved / timed out / the turn finished while we were detached:
    // `running == false` → no phantom card, hint still consumed.
    var initial = ChatFeature.State(connection: conn)
    initial.expectsPendingApproval = true
    let store = recoveryStore(initial)

    await store.send(.activateResult(.success(activateResponse(running: false))))
    #expect(store.state.pendingInteraction == nil)
    #expect(store.state.expectsPendingApproval == false)

    await store.send(.teardown)
  }

  @Test func hydrateWithHintLeavesRealInteractionUntouched() async {
    // The socket already delivered a real blocking request before the hydrate landed —
    // the hint must not clobber it with the generic card (it is consumed silently).
    let real = ApprovalRequest(command: "rm -rf /tmp/x", detail: "Removes files", patternKey: "rm")
    var initial = ChatFeature.State(connection: conn)
    initial.expectsPendingApproval = true
    initial.pendingInteraction = .approval(real)
    let store = recoveryStore(initial)

    await store.send(.activateResult(.success(activateResponse(running: true))))
    #expect(store.state.pendingInteraction == .approval(real))
    #expect(store.state.expectsPendingApproval == false)

    await store.send(.teardown)
  }

  @Test func hydrateWithoutHintSynthesizesNothing() async {
    // Zero behavior change for sessions never touched by an approval push: a plain
    // hydrate of a running turn sets no card.
    let store = recoveryStore(ChatFeature.State(connection: conn))

    await store.send(.activateResult(.success(activateResponse(running: true))))
    #expect(store.state.pendingInteraction == nil)
    #expect(store.state.expectsPendingApproval == false)

    await store.send(.teardown)
  }

  @Test func realApprovalRequestOverwritesSyntheticCardAndClearsHint() async {
    // hermes-agent #30 composes with this workaround: when the real event does arrive
    // (e.g. the agent learns to re-surface pending approvals), it overwrites the
    // synthetic card unconditionally AND clears the hint so a later hydrate of the
    // still-running turn cannot re-synthesize over the real details.
    var initial = ChatFeature.State(connection: conn)
    initial.pendingInteraction = .approval(ChatFeature.recoveredApprovalRequest)
    initial.expectsPendingApproval = true // a second tap re-armed the hint meanwhile
    let real = ApprovalRequest(command: "sudo reboot", detail: "Reboots the host", patternKey: "sudo")
    let store = recoveryStore(initial)

    await store.send(.gatewayEvent(.approvalRequest(real))) {
      $0.pendingInteraction = .approval(real)
      $0.expectsPendingApproval = false
    }

    // A follow-up hydrate of the same running turn: the real card stands (no re-synthesis).
    await store.send(.activateResult(.success(activateResponse(running: true))))
    #expect(store.state.pendingInteraction == .approval(real))
    #expect(store.state.expectsPendingApproval == false)

    await store.send(.teardown)
  }

  @Test func hydrateOfStoppedTurnClearsStaleApprovalCard() async {
    // Card synthesized on an earlier hydrate, user backgrounded without answering, the
    // approval was handled elsewhere and the turn ENDED while the socket was down: the
    // next hydrate's authoritative `running == false` must drop the stale card (the
    // server never ends a turn with an approval queued) — never leave a phantom card
    // locking the composer over a finished transcript.
    var initial = ChatFeature.State(connection: conn)
    initial.pendingInteraction = .approval(ChatFeature.recoveredApprovalRequest)
    let store = recoveryStore(initial)

    await store.send(.activateResult(.success(activateResponse(running: false))))
    #expect(store.state.pendingInteraction == nil)
    #expect(store.state.isSending == false)

    await store.send(.teardown)
  }

  @Test func turnCompleteClearsStaleApprovalCardAndHint() async {
    // The mainline recovered-card false positive: the approval was answered on another
    // client, so the turn kept running (card synthesized), then COMPLETED over the live
    // socket. The turn-end event must drop the card (and any re-armed hint) so the
    // finished chat isn't stuck behind it.
    var initial = ChatFeature.State(connection: conn)
    initial.pendingInteraction = .approval(ChatFeature.recoveredApprovalRequest)
    initial.expectsPendingApproval = true // a second tap re-armed the hint meanwhile
    initial.isSending = true
    initial.liveSessionID = "live123"
    initial.composerText = "next prompt"
    let store = recoveryStore(initial)
    #expect(store.state.canSend == false) // blocked while the (stale) card stands

    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    await store.skipReceivedActions()
    #expect(store.state.pendingInteraction == nil)
    #expect(store.state.expectsPendingApproval == false)
    #expect(store.state.isSending == false)
    #expect(store.state.canSend) // composer unblocked

    await store.send(.teardown)
  }

  @Test func turnErrorClearsStaleApprovalCardAndHint() async {
    // Same staleness rule when the turn ends in error.
    var initial = ChatFeature.State(connection: conn)
    initial.pendingInteraction = .approval(ChatFeature.recoveredApprovalRequest)
    initial.expectsPendingApproval = true
    initial.isSending = true
    let store = recoveryStore(initial)

    await store.send(.gatewayEvent(.error(message: "boom")))
    #expect(store.state.pendingInteraction == nil)
    #expect(store.state.expectsPendingApproval == false)

    await store.send(.teardown)
  }

  @Test func hydrateFailureKeepsHintArmedForTheRetry() async {
    // A failed hydrate (offline blip) must NOT consume the hint — recovery would die on
    // the first flaky resume. The follow-up successful hydrate of the still-running turn
    // consumes it and synthesizes the card.
    var initial = ChatFeature.State(connection: conn)
    initial.expectsPendingApproval = true
    let store = recoveryStore(initial)

    await store.send(.activateResult(.failure(.disconnected)))
    #expect(store.state.expectsPendingApproval == true)

    await store.send(.activateResult(.success(activateResponse(running: true))))
    #expect(store.state.pendingInteraction == .approval(ChatFeature.recoveredApprovalRequest))
    #expect(store.state.expectsPendingApproval == false)

    await store.send(.teardown)
  }

  // MARK: Unprompted new chat (iPad split view, #80 — the "new session" no-op predicate)

  /// Fresh state is an unprompted new chat; a composer draft, staged attachments, and a
  /// connected-but-unprompted live session do NOT make it prompted.
  @Test func isUnpromptedNewChatTrueForFreshChatRegardlessOfDraftOrLiveSession() {
    var state = ChatFeature.State(connection: conn)
    #expect(state.isUnpromptedNewChat)

    state.composerText = "typed but never sent"
    state.attachments = [imageAttachment(0)]
    #expect(state.isUnpromptedNewChat, "a draft is exactly what the no-op clears")

    state.liveSessionID = "live"
    state.status = .ready
    #expect(state.isUnpromptedNewChat, "a live session with no DB row holds nothing worth keeping")
  }

  @Test func isUnpromptedNewChatFalseWithStoredID() {
    let state = ChatFeature.State(connection: conn, resumeStoredID: "20260610_abc")
    #expect(!state.isUnpromptedNewChat)
  }

  /// The regular-width seat dials the moment it is seated, and `session.create` hands back a
  /// `stored_session_id` before a single prompt or DB row exists. The predicate must survive
  /// that handshake — otherwise the seat stops qualifying for the "new session" reset, the
  /// profile reseat, and the narrowing drop seconds after launch.
  @Test func isUnpromptedNewChatSurvivesTheSessionCreateHandshake() async {
    let store = recoveryStore(ChatFeature.State(connection: conn))
    #expect(store.state.isUnpromptedNewChat)

    await store.send(.sessionResult(.success(
      SessionHandle(sessionID: "live-1", storedSessionID: "20260610_seat")
    ))) {
      $0.liveSessionID = "live-1"
      $0.storedSessionID = "20260610_seat"
      $0.status = .ready
      $0.hasHydrated = true
    }
    #expect(store.state.isUnpromptedNewChat)
    #expect(store.state.isPristineNewChat)

    await store.send(.teardown)
  }

  /// A branch primed straight from its `session.create` (#34) carries seeded history the
  /// server holds in memory: never a "new chat", even before its first hydrate paints a row.
  /// Modern agents return a `stored_session_id` at create (so the chat resumes one); older
  /// ones don't, which is what the attach/seed clauses cover.
  @Test func isUnpromptedNewChatFalseForAnUnpersistedBranch() {
    var state = ChatFeature.State(connection: conn)
    state.attachLiveSessionID = "live-branch"
    state.branchSeed = ChatFeature.State.BranchSeed(text: "seed", parentSessionID: "parent")
    #expect(state.transcript.isEmpty)
    #expect(!state.isUnpromptedNewChat)
    #expect(!state.isPristineNewChat)
  }

  @Test func isUnpromptedNewChatFalseWithTranscriptRow() {
    var state = ChatFeature.State(connection: conn)
    state.transcript = [ChatRow(id: uuid(0), kind: .message(role: .user, text: "hi", isComplete: true))]
    #expect(!state.isUnpromptedNewChat)
  }

  @Test func isUnpromptedNewChatFalseWhileSending() {
    var state = ChatFeature.State(connection: conn)
    state.isSending = true
    #expect(!state.isUnpromptedNewChat)
  }

  @Test func isUnpromptedNewChatFalseWithQueuedWork() {
    var queued = ChatFeature.State(connection: conn)
    queued.queuedPrompts = [QueuedPrompt(id: uuid(0), text: "later")]
    #expect(!queued.isUnpromptedNewChat)

    var draining = ChatFeature.State(connection: conn)
    draining.drainingEntry = QueuedPrompt(id: uuid(1), text: "now")
    #expect(!draining.isUnpromptedNewChat)
  }

  // MARK: Pristine new chat (iPad split view, #80 — the narrowing-drop predicate)

  /// The regular-width seat exactly as it was seated: nothing typed, staged, or sent.
  @Test func isPristineNewChatTrueForFreshChat() {
    var state = ChatFeature.State(connection: conn)
    #expect(state.isPristineNewChat)

    // A dialled-but-unprompted socket is still pristine — the live session holds nothing.
    state.liveSessionID = "live"
    state.status = .ready
    #expect(state.isPristineNewChat)
  }

  /// A typed draft makes the seat worth keeping: narrowing must push its marker, not drop it.
  @Test func isPristineNewChatFalseWithComposerDraft() {
    var state = ChatFeature.State(connection: conn)
    state.composerText = "typed but never sent"
    #expect(state.isUnpromptedNewChat)
    #expect(!state.isPristineNewChat)
  }

  /// Staged attachments alone (no typed text) are equally the user's work — dropping such a
  /// seat on narrowing would silently discard the picked files.
  @Test func isPristineNewChatFalseWithStagedAttachmentsOnly() {
    var state = ChatFeature.State(connection: conn)
    state.attachments = [imageAttachment(0)]
    #expect(state.composerText.isEmpty)
    #expect(state.isUnpromptedNewChat)
    #expect(!state.isPristineNewChat)
  }

  /// Every non-unprompted chat is non-pristine too (the predicate is a strict narrowing).
  @Test func isPristineNewChatFalseForPromptedChat() {
    let state = ChatFeature.State(connection: conn, resumeStoredID: "20260610_abc")
    #expect(!state.isPristineNewChat)
  }

  /// An empty composer is NOT proof the seat is disposable: a paste still loading or a live
  /// mic will fill it in a moment, and neither survives the narrowing teardown. Both must
  /// read non-pristine so the seat keeps its marker instead.
  @Test func isPristineNewChatFalseWithInFlightComposerInput() {
    var pasting = ChatFeature.State(connection: conn)
    pasting.pendingPasteCount = 1
    #expect(pasting.composerText.isEmpty && pasting.attachments.isEmpty)
    #expect(!pasting.isDiscardableNewChat)
    #expect(!pasting.isPristineNewChat)

    var recording = ChatFeature.State(connection: conn)
    recording.recording = .recording
    #expect(!recording.isDiscardableNewChat)
    #expect(!recording.isPristineNewChat)
  }

  /// The shared seat predicate: unprompted AND nothing still resolving. A plain draft is
  /// discardable (the "New session" reset clears it deliberately); a prompted chat is not.
  @Test func isDiscardableNewChatCoversUnpromptedSeatsWithNothingInFlight() {
    var draft = ChatFeature.State(connection: conn)
    draft.composerText = "typed"
    #expect(draft.isDiscardableNewChat)

    let resumed = ChatFeature.State(connection: conn, resumeStoredID: "20260610_abc")
    #expect(!resumed.isDiscardableNewChat)
  }

  // MARK: In-flight composer input (#80 — what a draft reset cannot reach)

  /// A pending paste and every busy voice phase count; a plain draft does not. These are the
  /// states where clearing `composerText`/`attachments` is not a reset — the batch or the
  /// transcription lands afterwards, in the supposedly fresh composer.
  @Test func hasInFlightComposerInputCoversPendingPasteAndVoice() {
    var draft = ChatFeature.State(connection: conn)
    draft.composerText = "typed"
    draft.attachments = [imageAttachment(0)]
    #expect(!draft.hasInFlightComposerInput)

    var pasting = ChatFeature.State(connection: conn)
    pasting.pendingPasteCount = 1
    #expect(pasting.hasInFlightComposerInput)

    for phase in [ChatFeature.State.RecordingState.requestingPermission, .recording, .transcribing] {
      var voice = ChatFeature.State(connection: conn)
      voice.recording = phase
      #expect(voice.hasInFlightComposerInput, "\(phase) is composer input still resolving")
    }
  }

  // MARK: Empty-chat hero (iPad split view, #80 — `showsEmptyHero` truth table)

  /// A brand-new chat has nothing to wait for: the hero shows at once, before any
  /// handshake, and a composer draft does not hide it.
  @Test func showsEmptyHeroTrueForFreshNewChat() {
    var state = ChatFeature.State(connection: conn)
    #expect(!state.hasHydrated)
    #expect(state.showsEmptyHero)

    state.composerText = "typed but never sent"
    state.attachments = [imageAttachment(0)]
    #expect(state.showsEmptyHero, "a draft lives in the composer, not the transcript region")
  }

  /// A RESUMED session with no snapshot cache has an empty transcript for the round-trip
  /// before history lands — the hero must not flash there.
  @Test func showsEmptyHeroFalseForResumedSessionBeforeHydrate() {
    let state = ChatFeature.State(connection: conn, resumeStoredID: "20260610_abc")
    #expect(state.transcript.isEmpty)
    #expect(!state.hasHydrated)
    #expect(!state.showsEmptyHero)
  }

  /// Once the hydrate has landed, a genuinely empty server history shows the hero.
  @Test func showsEmptyHeroTrueForResumedSessionAfterHydrateWithEmptyHistory() {
    var state = ChatFeature.State(connection: conn, resumeStoredID: "20260610_abc")
    state.hasHydrated = true
    #expect(state.showsEmptyHero)
  }

  @Test func showsEmptyHeroFalseWithAnyTranscriptRow() {
    var fresh = ChatFeature.State(connection: conn)
    fresh.transcript = [ChatRow(id: uuid(0), kind: .message(role: .user, text: "hi", isComplete: true))]
    #expect(!fresh.showsEmptyHero)

    var hydrated = ChatFeature.State(connection: conn, resumeStoredID: "20260610_abc")
    hydrated.hasHydrated = true
    hydrated.transcript = [
      ChatRow(id: uuid(1), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))
    ]
    #expect(!hydrated.showsEmptyHero, "a live thinking row is transcript content too")
  }

  @Test func showsEmptyHeroFalseWhileSending() {
    var state = ChatFeature.State(connection: conn)
    state.isSending = true
    #expect(!state.showsEmptyHero)
  }

  @Test func showsEmptyHeroFalseWithStreamingRow() {
    var state = ChatFeature.State(connection: conn)
    state.streamingRowID = uuid(0)
    #expect(!state.showsEmptyHero)
  }

  /// Reducer path: the resumed chat hides the hero until `activateResult(.success)` with
  /// an empty history lands (`applyActivate` flips `hasHydrated`); the hero then shows;
  /// the next turn's `message.start` + first delta hide it again (`isSending`, then the
  /// lazily created streaming row).
  @Test func hydrateWithEmptyHistoryShowsHeroAndADeltaHidesIt() async {
    let initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    let store = recoveryStore(initial)
    #expect(!store.state.showsEmptyHero)

    await store.send(.activateResult(.success(activateResponse(running: false)))) {
      $0.hasHydrated = true
    }
    #expect(store.state.transcript.isEmpty)
    #expect(store.state.showsEmptyHero)

    await store.send(.gatewayEvent(.messageStart))
    #expect(store.state.isSending)
    #expect(!store.state.showsEmptyHero)

    await store.send(.gatewayEvent(.messageDelta(text: "Hel")))
    #expect(store.state.streamingRowID != nil)
    #expect(!store.state.transcript.isEmpty)
    #expect(!store.state.showsEmptyHero)

    await store.send(.teardown)
  }

  /// A hydrate reporting a STILL-RUNNING turn with empty history hides the hero through
  /// `isSending` even though the transcript is empty (the eager thinking row is added by
  /// `reconcileTurnTimer` — either way, nothing to hero over).
  @Test func hydrateOfRunningTurnWithEmptyHistoryHidesHero() async {
    let store = recoveryStore(ChatFeature.State(connection: conn, resumeStoredID: "stored123"))

    await store.send(.activateResult(.success(activateResponse(running: true))))
    #expect(store.state.hasHydrated)
    #expect(store.state.isSending)
    #expect(!store.state.showsEmptyHero)

    await store.send(.teardown)
  }

  /// The fresh-session `session.create` handle is that chat's hydrate: a handle carrying
  /// a `stored_session_id` must not flip the hero off for a chat the server just created
  /// empty.
  @Test func createHandshakeMarksHydratedSoStoredIDKeepsHero() async {
    let store = recoveryStore(ChatFeature.State(connection: conn))
    #expect(store.state.showsEmptyHero)

    await store.send(.sessionResult(.success(
      SessionHandle(sessionID: "live456", storedSessionID: "20260610_fresh")
    ))) {
      $0.liveSessionID = "live456"
      $0.storedSessionID = "20260610_fresh"
      $0.status = .ready
      $0.hasHydrated = true
    }
    #expect(store.state.showsEmptyHero)

    await store.send(.teardown)
  }
}
