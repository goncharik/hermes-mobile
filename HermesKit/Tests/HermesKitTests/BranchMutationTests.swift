import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// #159: a canonical session-authority host (`gateway.ready.session_authority: true`, Hermes
/// v0.22.3+) refuses the seeded `session.create` and has no `session.activate`. A branch there
/// is the parent's fenced `session.mutate {operation: "branch", payload: {through_message_id}}`,
/// and the child (a persisted copy) opens by stored id.
@MainActor
struct BranchMutationTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// Two finished turns; the user taps "Branch" on the FIRST reply (`uuid(1)`).
  private func authorityState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn, status: .ready)
    state.liveSessionID = "parent"
    state.storedSessionID = "parent"
    state.isSessionAuthority = true
    state.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .user, text: "q1", isComplete: true)),
      ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "a1", isComplete: true)),
      ChatRow(id: uuid(2), kind: .message(role: .user, text: "q2", isComplete: true)),
      ChatRow(id: uuid(3), kind: .message(role: .assistant, text: "a2", isComplete: true)),
    ]
    return state
  }

  private nonisolated static func message(_ role: String, _ text: String, row: Int) -> JSONValue {
    .object(["role": .string(role), "text": .string(text), "row_id": .number(Double(row))])
  }

  private nonisolated static let parentSnapshot: JSONValue = .object([
    "session_id": .string("parent"), "stored_session_id": .string("parent"),
    "revision": .number(4), "execution_generation": .number(2), "running": .bool(false),
    "messages": .array([
      message("user", "q1", row: 10),
      .object(["role": .string("tool"), "name": .string("terminal"), "row_id": .number(12)]),
      message("assistant", "a1", row: 13),
      message("user", "q2", row: 14),
      message("assistant", "a2", row: 15),
    ]),
  ])

  private struct Call: Equatable { let method: String; let params: JSONValue }

  private func makeStore(
    _ initial: ChatFeature.State, calls: LockIsolated<[Call]>,
    reply: @escaping @Sendable (String, JSONValue, Int) throws -> JSONValue
  ) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        let n = calls.withValue { $0.append(Call(method: method, params: params)); return $0.count }
        return try reply(method, params, n)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  @Test func authorityBranchMutatesThroughTheTappedTurnsLastRow() async throws {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(authorityState(), calls: calls) { method, _, _ in
      if method == "session.resume" { return Self.parentSnapshot }
      return .object([
        "session_id": .string("parent"), "operation": .string("branch"),
        "branched_session_id": .string("child"), "copied_messages": .number(3), "revision": .number(5),
      ])
    }

    await store.send(.branchFromMessage(id: uuid(1))) { $0.isBranching = true }
    await store.receive(\.branchMutated.success) { $0.isBranching = false }
    await store.receive(
      \.delegate.branchCreated,
      ChatFeature.Action.Delegate.BranchCreation(
        handle: SessionHandle(sessionID: "child", storedSessionID: "child"), seed: nil
      )
    )

    #expect(calls.value.map(\.method) == ["session.resume", "session.mutate"])
    let params = calls.value[1].params
    #expect(params["session_id"]?.stringValue == "parent")
    #expect(params["operation"]?.stringValue == "branch")
    #expect(params["expected_revision"]?.intValue == 4)
    #expect(params["expected_generation"]?.intValue == 2)
    #expect(params["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
    // Turn 1's last stored row (the reply, after its tool row) — never turn 2's rows.
    #expect(params["payload"] == .object(["through_message_id": .number(13)]))
    // Nothing goes through the legacy seeded create.
    #expect(!calls.value.contains { $0.method == "session.create" })
  }

  @Test func staleFenceRereadsTheParentOnce() async throws {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(authorityState(), calls: calls) { method, _, n in
      if method == "session.resume" { return Self.parentSnapshot }
      if n == 2 { throw GatewayError.server("revision_conflict") }
      return .object(["session_id": .string("parent"), "branched_session_id": .string("child")])
    }

    await store.send(.branchFromMessage(id: uuid(3)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(calls.value.map(\.method) == ["session.resume", "session.mutate", "session.resume", "session.mutate"])
    #expect(calls.value[3].params["payload"] == .object(["through_message_id": .number(15)]))
    #expect(store.state.errorBanner == nil)
  }

  @Test func refusedBranchBannersAndUnlocks() async {
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(authorityState(), calls: calls) { method, _, _ in
      if method == "session.resume" { return Self.parentSnapshot }
      throw GatewayError.server("permission_denied")
    }

    await store.send(.branchFromMessage(id: uuid(1)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(store.state.isBranching == false)
    #expect(store.state.errorBanner == "Couldn’t branch the chat: the server doesn’t allow it here.")
  }

  @Test func boundaryIsTheTappedRepliesStoredRow() throws {
    let json = #"""
    [{"role":"user","text":"q1","row_id":1},{"role":"assistant","text":"same","row_id":2},
     {"role":"user","text":"q2","row_id":3},{"role":"tool","name":"terminal","row_id":4},
     {"role":"assistant","text":"same","row_id":5},
     {"role":"user","text":"q3","row_id":6},{"role":"assistant","text":"a3","row_id":7},
     {"role":"assistant","text":"same","display_kind":"failed_turn","row_id":8}]
    """#
    let messages = try JSONDecoder().decode([SessionMessage].self, from: Data(json.utf8))
    #expect(branchBoundaryRowID(messages, replyText: "a3", occurrenceFromEnd: 0) == 7)
    // Identical answers are told apart by position from the newest; a notice never counts.
    #expect(branchBoundaryRowID(messages, replyText: "same", occurrenceFromEnd: 0) == 5)
    #expect(branchBoundaryRowID(messages, replyText: "same\n", occurrenceFromEnd: 1) == 2)
    #expect(branchBoundaryRowID(messages, replyText: "missing", occurrenceFromEnd: 0) == nil)
    let legacy = try JSONDecoder().decode([SessionMessage].self, from: Data(#"[{"role":"assistant","text":"a"}]"#.utf8))
    #expect(branchBoundaryRowID(legacy, replyText: "a", occurrenceFromEnd: 0) == nil)
  }

  /// Codex review on #164: a turn another client ran reaches this transcript as a reply with no
  /// user bubble, so the local turn count drifts. The boundary must come from the tapped reply.
  @Test func anotherClientsTurnDoesNotShiftTheBoundary() async throws {
    var state = authorityState()
    state.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .user, text: "q1", isComplete: true)),
      ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "a1", isComplete: true)),
      // Desktop's turn: the reply streamed live, its `q2` never did.
      ChatRow(id: uuid(3), kind: .message(role: .assistant, text: "a2", isComplete: true)),
    ]
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(state, calls: calls) { method, _, _ in
      if method == "session.resume" { return Self.parentSnapshot }
      return .object(["session_id": .string("parent"), "branched_session_id": .string("child")])
    }

    await store.send(.branchFromMessage(id: uuid(3)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(calls.value.last?.params["payload"] == .object(["through_message_id": .number(15)]))
  }

  @Test func aReplyNotInTheSnapshotIsRefusedNotGuessed() async {
    let calls = LockIsolated<[Call]>([])
    var state = authorityState()
    state.transcript[id: uuid(3)]?.kind = .message(role: .assistant, text: "unsaved", isComplete: true)
    let store = makeStore(state, calls: calls) { _, _, _ in Self.parentSnapshot }

    await store.send(.branchFromMessage(id: uuid(3)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(calls.value.map(\.method) == ["session.resume"])
    #expect(store.state.isBranching == false)
    #expect(store.state.errorBanner == branchUnsavedMessage)
  }

  /// Review on #164: a commentary row with the same text as the tapped final reply must not take
  /// the match. Turn 1 ends in "Done."; turn 2 has commentary "Done.", a tool call, then "ok".
  @Test func sameTextCommentaryLaterDoesNotTakeTheMatch() async throws {
    var state = authorityState()
    state.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .user, text: "q1", isComplete: true)),
      ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "Done.", isComplete: true)),
      ChatRow(id: uuid(2), kind: .message(role: .user, text: "q2", isComplete: true)),
      ChatRow(id: uuid(3), kind: .message(role: .assistant, text: "Done.", isComplete: true)),
      ChatRow(id: uuid(4), kind: .message(role: .assistant, text: "ok", isComplete: true)),
    ]
    let snapshot: JSONValue = .object([
      "session_id": .string("parent"), "revision": .number(4), "execution_generation": .number(2),
      "messages": .array([
        Self.message("user", "q1", row: 10), Self.message("assistant", "Done.", row: 11),
        Self.message("user", "q2", row: 12), Self.message("assistant", "Done.", row: 13),
        .object(["role": .string("tool"), "name": .string("terminal"), "row_id": .number(14)]),
        Self.message("assistant", "ok", row: 15),
      ]),
    ])
    let calls = LockIsolated<[Call]>([])
    let store = makeStore(state, calls: calls) { method, _, _ in
      method == "session.resume" ? snapshot
        : .object(["session_id": .string("parent"), "branched_session_id": .string("child")])
    }

    await store.send(.branchFromMessage(id: uuid(1)))
    await store.finish()
    await store.skipReceivedActions(strict: false)

    #expect(calls.value.last?.params["payload"] == .object(["through_message_id": .number(11)]))
  }

  @Test func busySessionGetsTheStopFirstBanner() async {
    let store = makeStore(authorityState(), calls: .init([])) { method, _, _ in
      if method == "session.resume" { return Self.parentSnapshot }
      throw GatewayError.server("session_busy")
    }
    await store.send(.branchFromMessage(id: uuid(1)))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.errorBanner == "Stop the current turn before branching.")
  }

  /// The app side: a seedless (session-authority) branch opens the child by STORED id, in the
  /// SOURCE chat's profile (Codex review on #164) — no live-id attach (`session.activate` is gone on v0.22.3+) and no seed to replay.
  @Test func appOpensAnAuthorityBranchByStoredID() async {
    // The source chat stays on "work" after the sidebar switched to the default profile.
    var liveChat = ChatFeature.State(connection: conn, resumeStoredID: "parent", profileName: "work")
    liveChat.liveSessionID = "parent"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: conn),
        path: StackState([ChatScreen.State(sessionKey: "parent")]),
        liveChat: liveChat
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.liveChat(.delegate(.branchCreated(.init(
      handle: SessionHandle(sessionID: "child", storedSessionID: "child"), seed: nil
    )))))
    await store.receive(\.fillLiveChat) {
      $0.liveChat = ChatFeature.State(connection: self.conn, resumeStoredID: "child", profileName: "work")
    }
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.liveChat?.attachLiveSessionID == nil)
    #expect(store.state.liveChat?.branchSeed == nil)
    #expect(store.state.path.last?.sessionKey == "child")

    await store.send(.liveChat(.teardown))
    await store.send(.home(.onDisappear))
  }

  /// Review on #164: refusal codes never show raw.
  @Test func refusalCodesGetPlainBanners() {
    #expect(branchFailureBanner(.server("session_busy")) == "Stop the current turn before branching.")
    #expect(branchFailureBanner(.server("not_found")) == "Couldn’t branch the chat: it no longer exists on the server.")
    #expect(branchFailureBanner(.server("permission_denied")) == "Couldn’t branch the chat: the server doesn’t allow it here.")
    #expect(branchFailureBanner(.server("stale_generation")) == "Couldn’t branch the chat: it changed on the server. Try again.")
    #expect(branchFailureBanner(.server("invalid_params")) == "Couldn’t branch the chat. Try again.")
    #expect(branchFailureBanner(.server(branchUnsavedMessage)) == branchUnsavedMessage)
    // A legacy host's prose stays as the detail.
    #expect(branchFailureBanner(.server("Session cap reached")) == "Couldn’t branch the chat: Session cap reached")
    for reason in ["not_found", "permission_denied", "invalid_params", "revision_conflict", "runtime_draining"] {
      #expect(!branchFailureBanner(.server(reason)).contains(reason))
    }
  }
}
