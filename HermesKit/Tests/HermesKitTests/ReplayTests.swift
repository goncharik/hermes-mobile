import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// #98: replay-then-hydrate on the reducer's `.ready`. A slot holding a watermark for
/// its live session reads the gap (`session.events.since`), folds it through the live event
/// path behind the seq gate, then runs the ordinary `session.resume` hydrate, which stays the
/// authority. Every fallback hydrates.
@MainActor
struct ReplayTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  // MARK: Harness

  struct RPC: Equatable, Sendable {
    var method: String
    var params: JSONValue
  }

  /// A scripted chat environment: the gateway records every RPC in send order and answers the
  /// replay read and the resume from mutable replies (everything else gets `{status: ok}`);
  /// redials, `runningChanged` delegates, turn-anchor writes and debug-log notes are recorded.
  final class ReplayHarness: Sendable {
    static let tracked: Set<String> = [
      "session.events.since", "session.resume", "session.activate", "session.create", "prompt.submit",
    ]
    let calls = LockIsolated<[RPC]>([])
    let since = LockIsolated<Result<JSONValue, GatewayError>>(.success(ReplayTests.since([])))
    /// The replay read does not answer while set (until cancelled, or cleared to release it).
    let hangsSince = LockIsolated(false)
    let resume = LockIsolated<JSONValue>(ReplayTests.resume(running: true))
    /// When set, `session.resume` fails with it instead of answering `resume`.
    let resumeError = LockIsolated<GatewayError?>(nil)
    let notes = LockIsolated<[String]>([])
    /// `hermesGateway.connect` calls (a redial).
    let connects = LockIsolated(0)
    /// Every `delegate(.runningChanged)` the chat emitted, in order.
    let running = LockIsolated<[Bool]>([])
    /// Every turn-anchor write, in order: "set" / "clear".
    let anchors = LockIsolated<[String]>([])

    /// The session/turn RPCs in send order (catalog/usage fetches filtered out).
    var rpcs: [RPC] { calls.value.filter { Self.tracked.contains($0.method) } }
    var methods: [String] { rpcs.map(\.method) }

    /// A chat store wired to this harness. `readyOnConnect`: every redial yields one ready
    /// (same process, epoch e1) and then stays open; otherwise a redial yields nothing.
    @MainActor
    func makeStore(
      _ initial: ChatFeature.State, exhaustive: Bool = false, readyOnConnect: Bool = false,
      clock: TestClock<Duration> = TestClock()
    ) -> TestStoreOf<ChatFeature> {
      var snapshot = ChatSnapshotClient.inMemory()
      let setAnchor = snapshot.setTurnAnchor
      let clearAnchor = snapshot.clearTurnAnchor
      snapshot.setTurnAnchor = { @Sendable [self] key, date in
        anchors.withValue { $0.append("set") }
        setAnchor(key, date)
      }
      snapshot.clearTurnAnchor = { @Sendable [self] key in
        anchors.withValue { $0.append("clear") }
        clearAnchor(key)
      }
      let recordRunning = Reduce<ChatFeature.State, ChatFeature.Action> { [self] _, action in
        if case let .delegate(.runningChanged(_, isRunning)) = action {
          running.withValue { $0.append(isRunning) }
        }
        return .none
      }
      let store = TestStore(initialState: initial) {
        CombineReducers {
          ChatFeature()
          recordRunning
        }
      } withDependencies: { [self] in
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1_000))
        $0.chatSnapshot = snapshot
        $0.hermesGateway.connect = { @Sendable [self] _, _ in
          connects.withValue { $0 += 1 }
          return AsyncStream<GatewayFrame> {
            if readyOnConnect { $0.yield(GatewayFrame(.ready, replayEpoch: "e1")) }
          }
        }
        $0.hermesGateway.send = { @Sendable [self] method, params in
          calls.withValue { $0.append(RPC(method: method, params: params)) }
          switch method {
          case "session.events.since":
            while hangsSince.value { try await Task.sleep(for: .milliseconds(5)) }
            return try since.value.get()
          case "session.resume":
            if let error = resumeError.value { throw error }
            return resume.value
          default:
            return .object(["status": .string("ok")])
          }
        }
        $0.debugLog.note = { @Sendable [self] type, summary in
          notes.withValue { $0.append("\(type): \(summary)") }
        }
      }
      if !exhaustive { store.exhaustivity = .off(showSkippedAssertions: false) }
      return store
    }
  }

  /// A slot whose socket dropped: a stored + live session, a watermark at `cursor`, epoch e1.
  private func droppedState(cursor: Int = 41) -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn, resumeStoredID: "stored1")
    state.liveSessionID = "live1"
    state.status = .reconnecting
    state.hasHydrated = true
    state.replayEpoch = "e1"
    state.replayCursor = .init(sessionID: "live1", seq: cursor)
    return state
  }

  private let ready = GatewayFrame(.ready, replayEpoch: "e1")

  // MARK: Wire fixtures

  /// One `events.since` element: the frame's `params` dict.
  nonisolated static func event(
    _ type: String, _ seq: Int, session: String = "live1", _ payload: [String: JSONValue] = [:]
  ) -> JSONValue {
    .object([
      "type": .string(type), "session_id": .string(session),
      "seq": .number(Double(seq)), "payload": .object(payload),
    ])
  }

  nonisolated static func since(
    _ events: [JSONValue], latest: Int? = nil, truncated: Bool = false, epoch: String? = "e1",
    openRequests: [JSONValue] = []
  ) -> JSONValue {
    var fields: [String: JSONValue] = [
      "events": .array(events), "truncated": .bool(truncated),
      "count": .number(Double(events.count)), "open_requests": .array(openRequests),
    ]
    if let latest { fields["latest_seq"] = .number(Double(latest)) }
    if let epoch { fields["epoch"] = .string(epoch) }
    return .object(fields)
  }

  nonisolated static func message(_ id: Int, _ role: String, _ content: String) -> JSONValue {
    .object(["id": .number(Double(id)), "role": .string(role), "content": .string(content)])
  }

  /// A `session.resume` payload (usage present, so no usage fetch).
  nonisolated static func resume(
    live: String = "live1", running: Bool, messages: [JSONValue] = [], openRequests: [JSONValue] = [],
    contract: Int? = 7
  ) -> JSONValue {
    var info: [String: JSONValue] = [
      "model": .string("claude-opus-4-8"),
      "usage": .object([
        "context_used": .number(1), "context_max": .number(200_000), "context_percent": .number(0),
      ]),
    ]
    if let contract { info["desktop_contract"] = .number(Double(contract)) }
    return .object([
      "session_id": .string(live), "stored_session_id": .string("stored1"),
      "messages": .array(messages), "running": .bool(running), "info": .object(info),
      "open_requests": .array(openRequests),
    ])
  }

  nonisolated static func approvalParams(_ command: String) -> JSONValue {
    .object([
      "session_id": .string("live1"), "request_id": .string("q-\(command)"), "command": .string(command),
      "description": .string("Runs \(command)"), "pattern_key": .string("rm_rf"),
      "choices": .array([.string("once"), .string("deny")]),
    ])
  }

  nonisolated static func openRequest(_ id: String, _ command: String = "rm -rf build") -> JSONValue {
    .object(["id": .string(id), "method": .string("approval"), "params": approvalParams(command)])
  }

  private static func queued(_ id: String, _ command: String = "rm -rf build") -> PendingServerRequest {
    PendingServerRequest(id: id, method: "approval", params: approvalParams(command))!
  }

  // MARK: Ordering and wire shape

  @Test func replayReadsTheGapBeforeTheResumeWithExactParams() async {
    let gateway = ReplayHarness()
    var initial = droppedState()
    initial.profileName = "work"
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.eventReplayResult.success)
    await store.receive(\.activateResult.success)

    // `events.since` carries the cursor and nothing else (no profile, no replay_epoch); the
    // resume that follows is the ordinary profile-scoped hydrate.
    #expect(gateway.rpcs == [
      RPC(method: "session.events.since", params: .object([
        "session_id": .string("live1"), "last_seen": .number(41),
      ])),
      RPC(method: "session.resume", params: .object([
        "session_id": .string("stored1"), "profile": .string("work"),
      ])),
    ])
    #expect(gateway.notes.value.isEmpty)
    await store.send(.teardown)
  }

  @Test func foldedToolRowsSurviveTheRunningHydrate() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal"), "context": .string("Run tests")]),
      Self.event("tool.complete", 43, ["tool_id": .string("t1"), "name": .string("terminal"), "result_text": .string("ok")]),
      Self.event("tool.start", 44, ["tool_id": .string("t2"), "name": .string("read")]),
    ], latest: 44)))
    gateway.resume.setValue(Self.resume(running: true, messages: [Self.message(1, "user", "run the tests")]))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.replayCursor = .init(sessionID: "live1", seq: 44)
      $0.toolRowIDs = ["t1": self.uuid(0), "t2": self.uuid(1)]
    }
    await store.receive(\.activateResult.success)

    // #26: the running hydrate rebuilt history and re-appended the gap's tool rows.
    let transcript = store.state.transcript
    #expect(transcript.first?.kind == .message(role: .user, text: "run the tests", isComplete: true))
    #expect(store.state.toolRowIDs == ["t1": uuid(0), "t2": uuid(1)])
    guard case let .tool(_, title, toolState, _, _) = transcript[id: uuid(0)]?.kind else {
      Issue.record("expected the folded t1 tool row"); return
    }
    #expect(title == "Run tests")
    #expect(toolState == .complete)
    guard case let .tool(name, _, secondState, _, _) = transcript[id: uuid(1)]?.kind else {
      Issue.record("expected the folded t2 tool row"); return
    }
    #expect(name == "read")
    #expect(secondState == .running)
    // The running turn's thinking row stays last.
    #expect(transcript.last?.id == store.state.thinkingRowID)
    await store.send(.teardown)
  }

  @Test func replayedReasoningAfterADropLandsInAFreshLiveThinkingRow() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("thinking.delta", 42, ["text": .string("gap reasoning")]),
    ])))
    var initial = droppedState()
    initial.status = .ready
    initial.hasRequestedSession = true
    initial.isSending = true
    initial.transcript = [ChatRow(
      id: uuid(900), kind: .thinking(reasoning: "before", status: nil, elapsedSeconds: 3, isComplete: false)
    )]
    initial.thinkingRowID = uuid(900)
    let store = gateway.makeStore(initial)

    // The drop finalizes in-flight state: the pre-drop thinking row is frozen.
    await store.send(.gatewayClosed)
    #expect(store.state.thinkingRowID == nil)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.thinkingRowID = self.uuid(0)
      $0.replayCursor = .init(sessionID: "live1", seq: 42)
    }
    await store.receive(\.activateResult.success)

    // The running hydrate keeps the fresh live row; the frozen pre-drop row is wiped.
    #expect(store.state.thinkingRowID == uuid(0))
    #expect(store.state.transcript[id: uuid(900)] == nil)
    guard case let .thinking(reasoning, _, _, isComplete) = store.state.transcript.last?.kind else {
      Issue.record("expected the live thinking row last"); return
    }
    #expect(store.state.transcript.last?.id == uuid(0))
    #expect(reasoning == "gap reasoning")
    #expect(!isComplete)
    await store.send(.teardown)
  }

  @Test func replayedReasoningAfterGraceExpiryExtendsTheLiveThinkingRow() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("thinking.delta", 42, ["text": .string(" + gap")]),
    ])))
    var initial = droppedState()
    initial.status = .ready
    initial.hasRequestedSession = true
    initial.isSending = true
    initial.transcript = [ChatRow(
      id: uuid(900), kind: .thinking(reasoning: "before", status: nil, elapsedSeconds: 3, isComplete: false)
    )]
    initial.thinkingRowID = uuid(900)
    let store = gateway.makeStore(initial)

    // Grace expiry keeps every live pointer (nothing is finalized).
    await store.send(.teardownSocketOnly)
    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.transcript[id: self.uuid(900)]?.kind =
        .thinking(reasoning: "before + gap", status: nil, elapsedSeconds: 3, isComplete: false)
    }
    await store.receive(\.activateResult.success)

    #expect(store.state.thinkingRowID == uuid(900))
    #expect(store.state.transcript.last?.id == uuid(900))
    guard case let .thinking(reasoning, _, _, _) = store.state.transcript[id: uuid(900)]?.kind else {
      Issue.record("expected the preserved thinking row"); return
    }
    #expect(reasoning == "before + gap")
    await store.send(.teardown)
  }

  @Test func replayedStatusUpdateRidesTheLiveThinkingRowThroughTheRunningHydrate() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("thinking.delta", 42, ["text": .string("gap reasoning")]),
      Self.event("status.update", 43, ["kind": .string("compress"), "text": .string("Compressing context")]),
    ])))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.thinkingRowID = self.uuid(0)
      $0.replayCursor = .init(sessionID: "live1", seq: 43)
    }
    await store.receive(\.activateResult.success)

    // The gap's status lives in the thinking row, which the running hydrate keeps (#26).
    #expect(store.state.thinkingRowID == uuid(0))
    guard case let .thinking(reasoning, status, _, isComplete) = store.state.transcript.last?.kind else {
      Issue.record("expected the live thinking row last"); return
    }
    #expect(reasoning == "gap reasoning")
    #expect(status == "Compressing context")
    #expect(!isComplete)
    await store.send(.teardown)
  }

  // MARK: Seq gate and fallbacks

  @Test func alreadySeenAndForeignEventsAreSkipped() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 41, ["tool_id": .string("t0"), "name": .string("seen")]),
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("new")]),
      Self.event("tool.start", 50, session: "live2", ["tool_id": .string("t9"), "name": .string("foreign")]),
    ])))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.toolRowIDs = ["t1": self.uuid(0)]
      $0.replayCursor = .init(sessionID: "live1", seq: 42)
    }
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
  }

  @Test func truncatedReplyAdvancesTheCursorFoldsNothingAndHydrates() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 88, ["tool_id": .string("t1"), "name": .string("terminal")]),
    ], latest: 90, truncated: true)))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.replayCursor = .init(sessionID: "live1", seq: 90)
      $0.transcript = []
      $0.toolRowIDs = [:]
    }
    await store.receive(\.activateResult.success)
    #expect(gateway.methods == ["session.events.since", "session.resume"])
    await store.send(.teardown)
  }

  @Test func replyFromANewEpochDropsTheCursorAndHydrates() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal")]),
    ], epoch: "e2")))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.replayCursor = nil
      $0.replayEpoch = "e2"
      $0.transcript = []
    }
    await store.receive(\.activateResult.success)
    #expect(gateway.methods == ["session.events.since", "session.resume"])
    await store.send(.teardown)
  }

  @Test func consecutiveReconnectsReadFromTheCursorTheFirstReplayAdvanced() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal")]),
      Self.event("tool.complete", 43, ["tool_id": .string("t1"), "name": .string("terminal")]),
    ])))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.replayCursor = .init(sessionID: "live1", seq: 43)
    }
    await store.receive(\.activateResult.success)

    // A second drop before any live frame: the read starts where the first replay ended.
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 44, ["tool_id": .string("t2"), "name": .string("read")]),
    ])))
    await store.send(.gatewayClosed)
    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.replayCursor = .init(sessionID: "live1", seq: 44)
    }
    await store.receive(\.activateResult.success)

    let reads = gateway.rpcs.filter { $0.method == "session.events.since" }
    #expect(reads.map { $0.params["last_seen"] } == [.number(41), .number(43)])
    #expect(gateway.methods == [
      "session.events.since", "session.resume", "session.events.since", "session.resume",
    ])
    #expect(Set(store.state.toolRowIDs.keys) == ["t1", "t2"])
    await store.send(.teardown)
  }

  @Test func gatewayRestartDuringTheGapSkipsTheReadAndHydrates() async {
    let gateway = ReplayHarness()
    let store = gateway.makeStore(droppedState())

    // A new process epoch on the ready: the old numbering is gone, so no read is attempted.
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e2"))) {
      $0.status = .ready
      $0.hasRequestedSession = true
      $0.replayEpoch = "e2"
      $0.replayCursor = nil
    }
    await store.receive(\.activateResult.success)
    #expect(gateway.methods == ["session.resume"])
    #expect(gateway.notes.value.isEmpty)
    #expect(store.state.errorBanner == nil)

    // The new process's first stamped frame starts a fresh cursor under e2.
    await store.send(.gatewayFrame(GatewayFrame(.messageStart, sessionID: "live1", seq: 1))) {
      $0.replayCursor = .init(sessionID: "live1", seq: 1)
    }
    await store.send(.teardown)
  }

  @Test func unknownMethodLatchesReplayOffAndHydrates() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.failure(.server("unknown method: session.events.since")))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.failure) {
      $0.replaySupported = false
    }
    await store.receive(\.activateResult.success)
    // The deliberate carve-out: debug log only, no banner.
    #expect(store.state.errorBanner == nil)
    #expect(gateway.notes.value == ["session.events.since: unknown method: session.events.since"])

    // The next reconnect goes straight to the resume.
    await store.send(.gatewayClosed)
    await store.send(.gatewayFrame(ready))
    await store.receive(\.activateResult.success)
    #expect(gateway.methods == ["session.events.since", "session.resume", "session.resume"])
    await store.send(.teardown)
  }

  @Test(arguments: [
    (Result<JSONValue, GatewayError>.success(.object(["latest_seq": .number(3)])),
     "Malformed session.events.since result"),
    (.failure(.timedOut(method: "session.events.since")), "request timed out: session.events.since"),
    (.failure(.server("internal error")), "internal error"),
  ])
  func otherFailuresHydrateWithoutABannerOrALatch(reply: Result<JSONValue, GatewayError>, note: String) async {
    let gateway = ReplayHarness()
    gateway.since.setValue(reply)
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.failure) {
      $0.replaySupported = true
      $0.replayCursor = .init(sessionID: "live1", seq: 41)
    }
    await store.receive(\.activateResult.success)
    #expect(store.state.errorBanner == nil)
    #expect(gateway.notes.value == ["session.events.since: \(note)"])
    #expect(gateway.methods == ["session.events.since", "session.resume"])
    await store.send(.teardown)
  }

  @Test func lateResultOverAReconnectingSocketIsDropped() async {
    let gateway = ReplayHarness()
    // Exhaustive: neither result may change state or start an effect.
    let store = gateway.makeStore(droppedState(), exhaustive: true)

    await store.send(.eventReplayResult(.failure(.disconnected)))
    await store.send(.eventReplayResult(.success(ReplayBatch(events: [
      GatewayFrame(.toolStart(toolID: "t1", name: "terminal", title: nil, argsText: nil), sessionID: "live1", seq: 42),
    ]))))
    #expect(gateway.calls.value.isEmpty)
  }

  @Test func dropDuringTheReadCancelsItAndTheNextReadyReplaysFromTheSameCursor() async {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
    }

    gateway.hangsSince.setValue(false)
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal")]),
    ])))
    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.replayCursor = .init(sessionID: "live1", seq: 42)
    }
    await store.receive(\.activateResult.success)

    let reads = gateway.rpcs.filter { $0.method == "session.events.since" }
    #expect(reads.count == 2)
    #expect(reads.allSatisfy { $0.params["last_seen"] == .number(41) })
    #expect(gateway.methods.last == "session.resume")
    await store.send(.teardown)
  }

  @Test func teardownDuringTheReadCancelsIt() async {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    // Exhaustive: a late `.eventReplayResult` (or a hydrate) would fail the test.
    let store = gateway.makeStore(droppedState(), exhaustive: true)

    await store.send(.gatewayFrame(ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
      $0.isReplayReadPending = true
    }
    await store.send(.teardown) {
      $0.isReplayReadPending = false
    }
    await store.finish()
    #expect(!gateway.methods.contains("session.resume"))
    // A deliberate cancel is not a failed read.
    #expect(gateway.notes.value.isEmpty)
  }

  // MARK: When replay does not run

  @Test(arguments: [nil, ChatFeature.State.ReplayCursor(sessionID: "live-old", seq: 41)])
  func withoutACursorForTheLiveSessionTheResumeIsUnchanged(cursor: ChatFeature.State.ReplayCursor?) async {
    let gateway = ReplayHarness()
    var initial = droppedState()
    initial.replayCursor = cursor
    let store = gateway.makeStore(initial)

    // An older agent's ready (no epoch) and no usable watermark: today's hydrate, byte for byte.
    await store.send(.gatewayFrame(GatewayFrame(.ready)))
    await store.receive(\.activateResult.success)
    #expect(gateway.rpcs == [
      RPC(method: "session.resume", params: .object(["session_id": .string("stored1")])),
    ])
    await store.send(.teardown)
  }

  @Test func sessionAuthorityHostNeverReplays() async {
    let gateway = ReplayHarness()
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1", sessionAuthority: true))) {
      $0.isSessionAuthority = true
    }
    await store.receive(\.activateResult.success)
    #expect(gateway.methods == ["session.resume"])
    await store.send(.teardown)
  }

  @Test func attachLiveBranchNeverReplays() async {
    let gateway = ReplayHarness()
    var initial = droppedState()
    initial.attachLiveSessionID = "live1"
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.activateResult)
    #expect(gateway.methods.first == "session.activate")
    #expect(!gateway.methods.contains("session.events.since"))
    await store.send(.teardown)
  }

  @Test func freshSessionCreateNeverReplays() async {
    let gateway = ReplayHarness()
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live1"
    initial.status = .reconnecting
    initial.replayCursor = .init(sessionID: "live1", seq: 41)
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.sessionResult)
    #expect(gateway.methods == ["session.create"])
    await store.send(.teardown)
  }

  // MARK: #97 interplay (v7 hydrate)

  @Test func replayedTimeoutOfThePresentedCardRaisesTheNextAndTheHydrateRefreshesItInPlace() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("request.cancel", 42, [
        "id": .string("srq-a"), "method": .string("approval"), "reason": .string("timeout"),
      ]),
    ])))
    gateway.resume.setValue(Self.resume(running: true, openRequests: [Self.openRequest("srq-b", "rm b")]))
    var initial = droppedState()
    initial.desktopContract = 7
    initial.serverRequests = [Self.queued("srq-a", "rm a"), Self.queued("srq-b", "rm b")]
    initial.present(Self.queued("srq-a", "rm a").kind)
    let store = gateway.makeStore(initial)
    #expect(store.state.pendingInteractionToken == 1)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.serverRequests = [Self.queued("srq-b", "rm b")]
      $0.pendingInteraction = Self.queued("srq-b", "rm b").kind
      $0.pendingInteractionToken = 2
      $0.transcript = [ChatRow(
        id: self.uuid(0), kind: .status(kind: Self.queued("srq-a").kind.statusKind, text: "Timed out")
      )]
    }
    await store.receive(\.activateResult.success)

    // Same id listed: refreshed in place, no token bump; the "Timed out" row is wiped.
    #expect(store.state.serverRequests.map(\.id) == ["srq-b"])
    #expect(store.state.pendingInteraction == Self.queued("srq-b", "rm b").kind)
    #expect(store.state.pendingInteractionToken == 2)
    #expect(store.state.transcript[id: uuid(0)] == nil)
    await store.send(.teardown)
  }

  @Test func replayedCancelForAnUnknownIdIsANoOpAndForAQueuedIdRemovesItSilently() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("request.cancel", 42, ["id": .string("srq-gone"), "reason": .string("timeout")]),
      Self.event("request.cancel", 43, [
        "id": .string("srq-b"), "method": .string("approval"), "reason": .string("timeout"),
      ]),
    ])))
    gateway.resume.setValue(Self.resume(running: true, openRequests: [Self.openRequest("srq-a", "rm a")]))
    var initial = droppedState()
    initial.desktopContract = 7
    initial.serverRequests = [Self.queued("srq-a", "rm a"), Self.queued("srq-b", "rm b")]
    initial.present(Self.queued("srq-a", "rm a").kind)
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.serverRequests = [Self.queued("srq-a", "rm a")]
      $0.pendingInteraction = Self.queued("srq-a", "rm a").kind
      $0.pendingInteractionToken = 1
      $0.transcript = []
      $0.replayCursor = .init(sessionID: "live1", seq: 43)
    }
    await store.receive(\.activateResult.success)
    #expect(store.state.pendingInteractionToken == 1)
    await store.send(.teardown)
  }

  @Test(arguments: [false, true])
  func foldNeverDrainsTheQueueAndARunningHydrateDoesNotEither(byCancel: Bool) async {
    let gateway = ReplayHarness()
    let turnEnd = byCancel
      ? Self.event("request.cancel", 42, ["id": .string("srq-a"), "reason": .string("resolved")])
      : Self.event("message.complete", 42, ["text": .string("done")])
    gateway.since.setValue(.success(Self.since([turnEnd])))
    gateway.resume.setValue(Self.resume(running: true))
    var initial = droppedState()
    initial.desktopContract = 7
    initial.queuedPrompts = [QueuedPrompt(id: UUID(77), text: "next")]
    if byCancel {
      // A card raised on an idle turn holds the queue; its replayed cancel is an idle edge live.
      initial.serverRequests = [Self.queued("srq-a")]
      initial.present(Self.queued("srq-a").kind)
    }
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.pendingInteraction = nil
      $0.queuedPrompts = [QueuedPrompt(id: UUID(77), text: "next")]
      $0.drainingEntry = nil
    }
    await store.receive(\.activateResult.success)
    #expect(store.state.queuedPrompts.map(\.text) == ["next"])
    #expect(store.state.drainingEntry == nil)
    #expect(!gateway.methods.contains("prompt.submit"))
    await store.send(.teardown)
  }

  @Test func idleHydrateAfterAFoldDrainsTheQueueOnce() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("message.complete", 42, ["text": .string("done")]),
    ])))
    gateway.resume.setValue(Self.resume(running: false))
    var initial = droppedState()
    initial.queuedPrompts = [QueuedPrompt(id: UUID(77), text: "next"), QueuedPrompt(id: UUID(78), text: "later")]
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.drainingEntry = nil
    }
    await store.receive(\.activateResult.success)
    // The hydrate's idle edge drains the head, once; the second entry waits its turn.
    #expect(store.state.drainingEntry?.text == "next")
    #expect(store.state.queuedPrompts.map(\.text) == ["later"])
    await store.send(.teardown)
  }

  @Test func openRequestsOnTheReplyAreIgnoredAndOnlyTheHydrateRaisesTheCard() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([], openRequests: [Self.openRequest("srq-a")])))
    gateway.resume.setValue(Self.resume(running: true, openRequests: [Self.openRequest("srq-a")]))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.pendingInteraction = nil
      $0.pendingInteractionToken = 0
      $0.serverRequests = []
    }
    await store.receive(\.activateResult.success)
    #expect(store.state.serverRequests.map(\.id) == ["srq-a"])
    #expect(store.state.pendingInteraction == Self.queued("srq-a").kind)
    #expect(store.state.pendingInteractionToken == 1)
    await store.send(.teardown)
  }

  @Test func legacyPromptEventsAreSkippedInAReplayButStillPresentLive() async {
    let approval = Self.event("approval.request", 42, [
      "command": .string("rm -rf build"), "description": .string("Runs rm"),
    ])
    let clarify = Self.event("clarify.request", 43, [
      "request_id": .string("c1"), "question": .string("Which?"),
      "choices": .array([.string("a"), .string("b")]),
    ])
    let approvalFrame = GatewayFrame(eventObject: approval)!
    let clarifyFrame = GatewayFrame(eventObject: clarify)!
    #expect(approvalFrame.event.isLegacyPrompt)
    #expect(clarifyFrame.event.isLegacyPrompt)

    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([approval, clarify])))
    gateway.resume.setValue(Self.resume(running: true, contract: nil))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.pendingInteraction = nil
      $0.pendingInteractionToken = 0
      $0.replayCursor = .init(sessionID: "live1", seq: 43)
    }
    await store.receive(\.activateResult.success)
    #expect(store.state.pendingInteraction == nil)

    // The same events arriving live still raise their cards.
    var live = approvalFrame
    live.seq = 44
    await store.send(.gatewayFrame(live))
    guard case .approval = store.state.pendingInteraction else {
      Issue.record("expected the live approval card"); return
    }
    var liveClarify = clarifyFrame
    liveClarify.seq = 45
    await store.send(.gatewayFrame(liveClarify))
    guard case .clarify = store.state.pendingInteraction else {
      Issue.record("expected the live clarify card"); return
    }
    await store.send(.teardown)
  }

  @Test func completedTurnIsReplacedWholesaleAndAReplayedReviewSummaryIsWiped() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal")]),
      Self.event("review.summary", 43, ["text": .string("💾 Self-improvement review: noted.")]),
      Self.event("message.complete", 44, ["text": .string("done")]),
    ])))
    let history = [Self.message(1, "user", "q"), Self.message(2, "assistant", "done")]
    gateway.resume.setValue(Self.resume(running: false, messages: history))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    // The reply text is left to the hydrate (no materialised assistant row in the fold).
    await store.receive(\.eventReplayResult.success) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .tool(name: "terminal", title: "terminal", state: .running, detail: nil, durationS: nil)),
        ChatRow(id: self.uuid(1), kind: .status(kind: ChatRow.Kind.reviewStatusKind, text: "💾 Self-improvement review: noted.")),
      ]
    }
    await store.receive(\.activateResult.success)

    // Server wins: history only, no preserved tool row, no review row.
    #expect(Array(store.state.transcript) == reconstructTranscript([
      SessionMessage(id: 1, role: "user", content: "q"),
      SessionMessage(id: 2, role: "assistant", content: "done"),
    ]))
    #expect(store.state.toolRowIDs.isEmpty)
    await store.send(.teardown)
  }

  // MARK: Past turn boundaries in the fold

  @Test func aReplayedReplyNeverShowsTwiceBeforeTheHydrate() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("message.delta", 42, ["text": .string("lo")]),
      Self.event("message.complete", 43, ["text": .string("Hello")]),
    ])))
    let history = [Self.message(1, "user", "q"), Self.message(2, "assistant", "Hello")]
    gateway.resume.setValue(Self.resume(running: false, messages: history))
    var initial = droppedState()
    initial.status = .ready
    initial.hasRequestedSession = true
    initial.isSending = true
    initial.transcript = [ChatRow(id: uuid(900), kind: .message(role: .assistant, text: "Hel", isComplete: false))]
    initial.streamingRowID = uuid(900)
    let store = gateway.makeStore(initial)

    await store.send(.gatewayClosed)
    await store.send(.gatewayFrame(ready))
    // The drop finalized the pre-drop partial; the fold adds no second assistant row.
    await store.receive(\.eventReplayResult.success) {
      $0.transcript = [ChatRow(id: self.uuid(900), kind: .message(role: .assistant, text: "Hel", isComplete: true))]
      $0.replayCursor = .init(sessionID: "live1", seq: 43)
    }
    await store.receive(\.activateResult.success)
    await store.receive(\.delegate.runningChanged)
    #expect(Array(store.state.transcript) == reconstructTranscript([
      SessionMessage(id: 1, role: "user", content: "q"),
      SessionMessage(id: 2, role: "assistant", content: "Hello"),
    ]))
    // Only the hydrate reports the turn's state.
    #expect(gateway.running.value == [false])
    await store.send(.teardown)
  }

  @Test func aGapAcrossATurnBoundaryWritesOneAnchorAndNoRunningEdge() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal")]),
      Self.event("message.complete", 43, ["text": .string("A done")]),
      Self.event("message.start", 44),
      Self.event("tool.start", 45, ["tool_id": .string("t2"), "name": .string("read")]),
    ])))
    gateway.resume.setValue(Self.resume(running: true))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.toolRowIDs = ["t2": self.uuid(2)]
      $0.replayCursor = .init(sessionID: "live1", seq: 45)
    }
    await store.receive(\.activateResult.success)
    await store.receive(\.delegate.runningChanged)
    // Turn A's tool row is history: the running hydrate keeps only turn B's.
    #expect(store.state.toolRowIDs == ["t2": uuid(2)])
    #expect(store.state.transcript[id: uuid(0)] == nil)
    #expect(store.state.transcript[id: uuid(2)] != nil)
    await store.send(.teardown)
    await store.finish()
    // No glow flicker from the past boundaries, and one anchor write (B started) instead of
    // a racing clear + set.
    #expect(gateway.running.value == [true])
    #expect(gateway.anchors.value == ["set"])
  }

  @Test(arguments: [
    ReplayTests.event("message.complete", 42, ["text": .string("A done")]),
    ReplayTests.event("error", 42, ["message": .string("boom")]),
  ])
  func aReplayedPastTurnEndKeepsThePushTapApprovalHint(turnEnd: JSONValue) async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([turnEnd, Self.event("message.start", 43)])))
    gateway.resume.setValue(Self.resume(running: true, contract: nil))
    var initial = droppedState()
    initial.expectsPendingApproval = true
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success)
    #expect(store.state.expectsPendingApproval)
    await store.receive(\.activateResult.success)
    // Legacy contract: the running hydrate consumes the hint into the recovered card.
    #expect(!store.state.expectsPendingApproval)
    #expect(store.state.pendingInteraction == .approval(ChatFeature.recoveredApprovalRequest))
    await store.send(.teardown)
  }

  @Test func aGapThatStartsAndEndsATurnLeavesNoThinkingTimer() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("message.start", 42),
      Self.event("message.complete", 43, ["text": .string("done")]),
    ])))
    gateway.resumeError.setValue(.server("boom"))
    let clock = TestClock()
    let store = gateway.makeStore(droppedState(), clock: clock)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success)
    await store.receive(\.activateResult.failure)
    // The batch's start never outlives its own complete, even with no hydrate to settle it.
    await clock.advance(by: .seconds(3))
    await store.skipReceivedActions()
    #expect(store.state.thinkingSeconds == 0)
    await store.send(.teardown)
  }

  @Test func aGapEndingAtATurnStartLeavesTheTimerToAStoppedHydrate() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([Self.event("message.start", 42)])))
    gateway.resume.setValue(Self.resume(running: false))
    let clock = TestClock()
    let store = gateway.makeStore(droppedState(), clock: clock)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success)
    await store.receive(\.activateResult.success)
    // The turn finished in the gap: the stopped hydrate leaves no tick and no anchor behind.
    await clock.advance(by: .seconds(3))
    await store.skipReceivedActions()
    #expect(store.state.thinkingSeconds == 0)
    #expect(!store.state.isSending)
    await store.send(.teardown)
    await store.finish()
    #expect(gateway.anchors.value == ["set", "clear"])
  }

  @Test func aGapEndingAtATurnStartTicksOnceTheHydrateSaysRunning() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([Self.event("message.start", 42)])))
    gateway.resume.setValue(Self.resume(running: true))
    let clock = TestClock()
    let store = gateway.makeStore(droppedState(), clock: clock)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success)
    await store.receive(\.activateResult.success)
    await clock.advance(by: .seconds(3))
    await store.skipReceivedActions()
    #expect(store.state.thinkingSeconds == 3)
    await store.send(.teardown)
  }

  @Test func replayedErrorWithSendNowArmedNeverDrainsDuringTheFold() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([Self.event("error", 42, ["message": .string("boom")])])))
    gateway.resume.setValue(Self.resume(running: true))
    var initial = droppedState()
    initial.queuedPrompts = [QueuedPrompt(id: UUID(77), text: "next")]
    initial.sendNowArmed = true
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.drainingEntry = nil
    }
    await store.receive(\.activateResult.success)
    #expect(store.state.queuedPrompts.map(\.text) == ["next"])
    #expect(!gateway.methods.contains("prompt.submit"))
    await store.send(.teardown)
  }

  @Test func replayedErrorDoesNotParkAndTheIdleHydrateDrains() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([Self.event("error", 42, ["message": .string("boom")])])))
    gateway.resume.setValue(Self.resume(running: false))
    var initial = droppedState()
    initial.queuedPrompts = [QueuedPrompt(id: UUID(77), text: "next")]
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.isQueueParked = false
    }
    await store.receive(\.activateResult.success)
    // The past error's banner is wiped and the hydrate's idle edge drains, as without replay.
    #expect(store.state.errorBanner == nil)
    #expect(store.state.drainingEntry?.text == "next")
    await store.send(.teardown)
  }

  // MARK: Nothing races the read

  @Test(arguments: [false, true])
  func foregroundDuringTheReadDefersToTheReplaysHydrate(viaReattach: Bool) async {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.send(viaReattach ? .reattached : .foreground)
    #expect(gateway.methods == ["session.events.since"])

    gateway.hangsSince.setValue(false)
    await store.receive(\.eventReplayResult.success) {
      $0.isReplayReadPending = false
    }
    await store.receive(\.activateResult.success)
    // One hydrate, after the fold.
    #expect(gateway.methods == ["session.events.since", "session.resume"])
    await store.send(.teardown)
  }

  @Test func sendingAndDrainingWaitForTheRead() async {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    gateway.resume.setValue(Self.resume(running: false))
    var initial = droppedState()
    initial.composerText = "typed"
    initial.queuedPrompts = [QueuedPrompt(id: UUID(77), text: "next")]
    initial.isQueueParked = true
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(ready))
    // A `prompt.submit` would attach the socket mid-read.
    #expect(!store.state.canSend)
    await store.send(.composerSubmitted)
    #expect(store.state.composerText == "typed")
    await store.send(.queuedPromptSendNow(id: UUID(77)))
    #expect(store.state.drainingEntry == nil)
    #expect(gateway.methods == ["session.events.since"])

    gateway.hangsSince.setValue(false)
    await store.receive(\.eventReplayResult.success)
    await store.receive(\.activateResult.success)
    // The promoted head drains on the hydrate's idle edge, after the resume.
    #expect(store.state.drainingEntry?.text == "next")
    #expect(!store.state.isReplayReadPending)
    await store.send(.teardown)
  }

  @Test func answeringACardWaitsForTheRead() async {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    gateway.resume.setValue(Self.resume(running: true, openRequests: [Self.openRequest("srq-a")]))
    var initial = droppedState()
    initial.desktopContract = 7
    initial.serverRequests = [Self.queued("srq-a")]
    initial.present(Self.queued("srq-a").kind)
    let store = gateway.makeStore(initial)
    let token = store.state.pendingInteractionToken

    await store.send(.gatewayFrame(ready))
    // An answer would unblock the still-detached agent, whose next events would be lost.
    await store.send(.respondToApproval(token: token, approve: true, all: false))
    #expect(store.state.answeringServerRequestID == nil)
    #expect(!gateway.calls.value.map(\.method).contains("request.answer"))

    gateway.hangsSince.setValue(false)
    await store.receive(\.eventReplayResult.success)
    await store.receive(\.activateResult.success)
    // The hydrate refreshed the card in place; it is answerable once attached.
    await store.send(.respondToApproval(token: token, approve: true, all: false))
    await store.receive(\.serverRequestAnswered)
    #expect(gateway.calls.value.map(\.method).contains("request.answer"))
    await store.send(.teardown)
  }

  // MARK: Cancellation and late results

  @Test func graceExpiryDuringTheReadCancelsIt() async {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    let store = gateway.makeStore(droppedState(), exhaustive: true)

    await store.send(.gatewayFrame(ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
      $0.isReplayReadPending = true
    }
    await store.send(.teardownSocketOnly) {
      $0.status = .reconnecting
      $0.hasRequestedSession = false
      $0.isReplayReadPending = false
    }
    // Released after the cancel: an uncancelled read would now deliver `.eventReplayResult`.
    gateway.hangsSince.setValue(false)
    await store.finish()
    #expect(gateway.methods == ["session.events.since"])
    #expect(gateway.notes.value.isEmpty)
  }

  @Test func reauthPauseDuringTheReadCancelsIt() async {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    let store = gateway.makeStore(droppedState(), exhaustive: true)

    await store.send(.gatewayFrame(ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
      $0.isReplayReadPending = true
    }
    await store.send(.gatewayFrame(GatewayFrame(.authExpired))) {
      $0.awaitingReauth = true
      $0.status = .reconnecting
    }
    await store.receive(\.delegate.sessionExpired)
    await store.send(.gatewayClosed) {
      $0.hasRequestedSession = false
      $0.isReplayReadPending = false
    }
    gateway.hangsSince.setValue(false)
    await store.finish()
    #expect(gateway.methods == ["session.events.since"])
    #expect(gateway.notes.value.isEmpty)
  }

  @Test func dropDuringTheReadCancelsIt() async throws {
    let gateway = ReplayHarness()
    gateway.hangsSince.setValue(true)
    let store = gateway.makeStore(droppedState(), exhaustive: true)

    await store.send(.gatewayFrame(ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
      $0.isReplayReadPending = true
    }
    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.reconnectAttempt = 1
      $0.hasRequestedSession = false
      $0.isReplayReadPending = false
    }
    // Released after the cancel: an uncancelled read would deliver `.eventReplayResult` here,
    // which the exhaustive store rejects at the next send.
    gateway.hangsSince.setValue(false)
    try await Task.sleep(for: .milliseconds(100))
    await store.send(.teardown) // the pending backoff redial
    await store.finish()
    #expect(gateway.methods == ["session.events.since"])
    #expect(gateway.notes.value.isEmpty)
  }

  @Test(arguments: [GatewayError.disconnected, .notConnected])
  func aDeadSocketResultLeavesRecoveryToTheDrop(error: GatewayError) async {
    let gateway = ReplayHarness()
    var initial = droppedState()
    initial.status = .ready
    initial.hasRequestedSession = true
    initial.isReplayReadPending = true
    // Exhaustive: the result may only mark the socket reconnecting; no hydrate over it.
    let store = gateway.makeStore(initial, exhaustive: true)

    await store.send(.eventReplayResult(.failure(error))) {
      $0.isReplayReadPending = false
      $0.status = .reconnecting
    }
    #expect(gateway.calls.value.isEmpty)
  }

  @Test func aResultWithoutAStoredSessionNeverHydrates() async {
    let gateway = ReplayHarness()
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live1"
    initial.status = .ready
    initial.replayCursor = .init(sessionID: "live1", seq: 41)
    let store = gateway.makeStore(initial, exhaustive: true)

    await store.send(.eventReplayResult(.success(ReplayBatch(events: [
      GatewayFrame(.toolStart(toolID: "t1", name: "terminal", title: nil, argsText: nil), sessionID: "live1", seq: 42),
    ]))))
    #expect(gateway.calls.value.isEmpty)
  }

  @Test func aReadTimeoutSpendsTheHydratesSameSocketRetry() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.failure(.timedOut(method: "session.events.since")))
    gateway.resumeError.setValue(.timedOut(method: "session.resume"))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.failure) {
      $0.hydrateRetriedAfterTimeout = true
    }
    await store.receive(\.activateResult.failure) {
      $0.hydrateRetriedAfterTimeout = false
      $0.hasRequestedSession = false
    }
    // A half-open socket redials after the hydrate's first timeout, not a same-socket retry.
    await waitUntil { gateway.connects.value == 1 }
    #expect(gateway.methods == ["session.events.since", "session.resume"])
    await store.send(.teardown)
  }

  // MARK: Reply shapes

  @Test(arguments: [("e1" as String?, nil as String?), (nil, "e1")])
  func aMissingEpochOnEitherSideFoldsNormally(stored: String?, reply: String?) async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal")]),
    ], epoch: reply)))
    var initial = droppedState()
    initial.replayEpoch = stored
    let store = gateway.makeStore(initial)

    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: stored)))
    await store.receive(\.eventReplayResult.success) {
      $0.toolRowIDs = ["t1": self.uuid(0)]
      $0.replayCursor = .init(sessionID: "live1", seq: 42)
      // A reply without an epoch leaves the stored one; one with an epoch is only compared.
      $0.replayEpoch = stored
    }
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
  }

  @Test(arguments: [
    (nil as Int?, "e1", 41 as Int?),  // no latest_seq: the cursor stays
    (30, "e1", 41),                   // an older latest_seq never moves it backwards
    (90, "e2", nil),                  // a new epoch wins over truncation
  ])
  func truncatedRepliesNeverMoveTheCursorBackwards(latest: Int?, epoch: String, seq: Int?) async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 88, ["tool_id": .string("t1"), "name": .string("terminal")]),
    ], latest: latest, truncated: true, epoch: epoch)))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.replayCursor = seq.map { .init(sessionID: "live1", seq: $0) }
      $0.replayEpoch = epoch
      $0.toolRowIDs = [:]
    }
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
  }

  @Test func outOfOrderElementsFoldOnlyWhenNewer() async {
    let gateway = ReplayHarness()
    gateway.since.setValue(.success(Self.since([
      Self.event("tool.start", 43, ["tool_id": .string("t2"), "name": .string("read")]),
      Self.event("tool.start", 42, ["tool_id": .string("t1"), "name": .string("terminal")]),
    ])))
    let store = gateway.makeStore(droppedState())

    await store.send(.gatewayFrame(ready))
    await store.receive(\.eventReplayResult.success) {
      $0.toolRowIDs = ["t2": self.uuid(0)]
      $0.replayCursor = .init(sessionID: "live1", seq: 43)
    }
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
  }
}
