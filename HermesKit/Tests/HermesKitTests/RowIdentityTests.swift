import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Task 2: row identity is preserved across streaming deltas, and live (random-id) streaming
/// rows reconcile to the deterministic, content-derived history ids on the next hydrate —
/// without duplicating rows or flickering. The streaming fold helpers
/// (`appendToStreamingMessage`, `appendToThinking`, `setThinkingStatus`, `keepThinkingLast`)
/// must mutate the in-place row, never churn its id.
@MainActor
struct RowIdentityTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func makeStore() -> TestStore<ChatFeature.State, ChatFeature.Action> {
    TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
  }

  /// A store seeded with a stored session id so that sending `.ready` triggers a hydrate
  /// (`session.resume`) returning `gatewaySend`'s payload. An empty `.inMemory()` snapshot
  /// store means no init-time paint, so the transcript starts empty.
  private func makeHydratingStore(
    gatewaySend: @escaping @Sendable (String, JSONValue) async throws -> JSONValue
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    let snapshotClient = ChatSnapshotClient.inMemory()
    let initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }
    return TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = gatewaySend
    }
  }

  // MARK: Delta append preserves the streaming row id

  /// Each `message.delta` mutates the existing assistant row in place — its id is set once on
  /// the first delta and never changes as text accumulates. A diffing renderer needs this so
  /// it animates a content change, not a row replace.
  @Test func messageDeltaAppendPreservesStreamingRowID() async {
    let store = makeStore()

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    // First delta materialises the assistant row (uuid 1).
    await store.send(.gatewayEvent(.messageDelta(text: "Hel"))) {
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .message(role: .assistant, text: "Hel", isComplete: false)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.streamingRowID = uuid(1)
    }
    // Subsequent deltas only mutate the text — the id stays uuid(1).
    await store.send(.gatewayEvent(.messageDelta(text: "lo"))) {
      $0.transcript[id: uuid(1)]?.kind = .message(role: .assistant, text: "Hello", isComplete: false)
    }
    await store.send(.gatewayEvent(.messageDelta(text: " world"))) {
      $0.transcript[id: uuid(1)]?.kind = .message(role: .assistant, text: "Hello world", isComplete: false)
    }
    #expect(store.state.streamingRowID == uuid(1))
    #expect(store.state.transcript[id: uuid(1)] != nil)
    // Completion still mutates the same row in place (no new id).
    await store.send(.gatewayEvent(.messageComplete(text: "Hello world", usage: nil))) {
      $0.transcript[id: uuid(1)]?.kind = .message(role: .assistant, text: "Hello world", isComplete: true)
      $0.transcript.remove(id: self.uuid(0))
      $0.streamingRowID = nil
      $0.thinkingRowID = nil
      $0.isSending = false
    }
    #expect(store.state.transcript[id: uuid(1)] != nil)
  }

  /// Reasoning deltas accumulate into the one thinking row created at `message.start`; its id
  /// (uuid 0) never changes across deltas or the status update.
  @Test func thinkingDeltasPreserveThinkingRowID() async {
    let store = makeStore()

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "Plan"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Plan", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    await store.send(.gatewayEvent(.thinkingDelta(text: "ning"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Planning", status: nil, elapsedSeconds: 0, isComplete: false)
    }
    await store.send(.gatewayEvent(.statusUpdate(kind: "context", text: "Context: 12%"))) {
      $0.transcript[id: uuid(0)]?.kind = .thinking(reasoning: "Planning", status: "Context: 12%", elapsedSeconds: 0, isComplete: false)
    }
    #expect(store.state.thinkingRowID == uuid(0))
    await store.send(.onDisappear)
  }

  // MARK: keepThinkingLast reordering preserves ids

  /// Pinning the thinking row to the bottom reorders the array but must keep every row's id —
  /// it removes-and-re-appends the *same* row instance.
  @Test func keepThinkingLastReorderingPreservesIDs() async {
    let store = makeStore()

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.transcript = [ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false))]
      $0.thinkingRowID = uuid(0)
    }
    // A tool starts: it slots above the thinking row, which is removed-and-re-appended last.
    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "search", title: "Searching", argsText: nil))) {
      $0.transcript = [
        ChatRow(id: uuid(1), kind: .tool(name: "search", title: "Searching", state: .running, detail: nil, durationS: nil)),
        ChatRow(id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)),
      ]
      $0.toolRowIDs["t1"] = uuid(1)
    }
    // The thinking row id survived the reorder unchanged.
    #expect(store.state.transcript.last?.id == uuid(0))
    #expect(store.state.transcript.first?.id == uuid(1))
    #expect(store.state.thinkingRowID == uuid(0))
    await store.send(.onDisappear)
  }

  // MARK: Live → deterministic reconciliation on hydrate

  /// After a turn streams in (rows carry random live ids), a hydrate rebuilds the transcript
  /// wholesale from the server's history with deterministic, content-derived ids. The live
  /// ids are gone, the deterministic ids match `reconstructTranscript`, and there is exactly
  /// one row per logical message — no duplication, no flicker.
  @Test func hydrateAfterTurnReconcilesLiveIDsToDeterministic() async {
    let serverMessages = [
      SessionMessage(id: 1, role: "user", content: "ping"),
      SessionMessage(id: 2, role: "assistant", content: "pong"),
    ]
    let store = makeHydratingStore { @Sendable _, _ in
      .object([
        "session_id": .string("live123"),
        "stored_session_id": .string("stored123"),
        "messages": .array([
          .object(["id": .number(1), "role": .string("user"), "content": .string("ping")]),
          .object(["id": .number(2), "role": .string("assistant"), "content": .string("pong")]),
        ]),
        "running": .bool(false),
      ])
    }
    store.exhaustivity = .off

    // Stream a turn: the assistant row gets a *random* live id (uuid 1), distinct from the
    // deterministic id `reconstructTranscript` will later derive.
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.messageDelta(text: "pong")))
    await store.send(.gatewayEvent(.messageComplete(text: "pong", usage: nil)))
    let liveAssistantID = store.state.streamingRowID ?? store.state.transcript.first?.id
    // Sanity: the live assistant row used a non-deterministic id.
    let deterministicAssistantID = ChatRow.deterministicID(
      sequenceIndex: 1, role: .assistant, kindDiscriminator: "message"
    )
    #expect(liveAssistantID != deterministicAssistantID)

    // Now hydrate. The transcript is rebuilt wholesale with deterministic ids.
    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    let expected = reconstructTranscript(serverMessages)
    #expect(Array(store.state.transcript) == expected)
    // The old live id is gone (no duplicate), the deterministic id is present.
    #expect(store.state.transcript[id: deterministicAssistantID] != nil)
    if let liveAssistantID {
      #expect(store.state.transcript[id: liveAssistantID] == nil)
    }
    // Exactly one row per logical message — no duplication.
    #expect(store.state.transcript.count == expected.count)

    await store.send(.onDisappear)
  }

  /// Re-running `reconstructTranscript` over identical history yields byte-identical ids — the
  /// reconciliation target is stable, so a second hydrate after the first does not churn ids.
  @Test func repeatedReconstructionYieldsIdenticalIDs() {
    let messages = [
      SessionMessage(id: 1, role: "user", content: "ping"),
      SessionMessage(id: 2, role: "assistant", content: "pong", reasoning: "thought"),
    ]
    let first = reconstructTranscript(messages)
    let second = reconstructTranscript(messages)
    #expect(first.map(\.id) == second.map(\.id))
  }

  // MARK: Edge cases

  /// `message.complete` with no preceding deltas (a non-streamed reply) materialises the
  /// assistant row directly; that row still reconciles to the deterministic id on hydrate.
  @Test func messageCompleteWithNoDeltasMaterialisesAndReconciles() async {
    let store = makeHydratingStore { @Sendable _, _ in
      .object([
        "session_id": .string("live123"),
        "messages": .array([
          .object(["id": .number(1), "role": .string("assistant"), "content": .string("instant")]),
        ]),
        "running": .bool(false),
      ])
    }
    store.exhaustivity = .off

    await store.send(.gatewayEvent(.messageStart))
    // No deltas — completion materialises the row directly (random live id).
    await store.send(.gatewayEvent(.messageComplete(text: "instant", usage: nil)))
    let liveRows = store.state.transcript.filter {
      if case let .message(role, text, _) = $0.kind { return role == .assistant && text == "instant" }
      return false
    }
    #expect(liveRows.count == 1)
    let liveID = liveRows.first?.id
    let deterministicID = ChatRow.deterministicID(
      sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"
    )
    #expect(liveID != deterministicID)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    // Reconciled: deterministic id present, live id gone, single row.
    #expect(store.state.transcript[id: deterministicID] != nil)
    if let liveID { #expect(store.state.transcript[id: liveID] == nil) }
    #expect(store.state.transcript.count == 1)

    await store.send(.onDisappear)
  }

  /// A reasoning-only turn (thinking text, no assistant message) keeps the thinking row id
  /// stable across deltas and reconciles to the deterministic `.thinking` id on hydrate.
  @Test func reasoningOnlyTurnPreservesIDAndReconciles() async {
    let store = makeHydratingStore { @Sendable _, _ in
      .object([
        "session_id": .string("live123"),
        "messages": .array([
          .object([
            "id": .number(1), "role": .string("assistant"),
            "reasoning": .string("just reasoning"),
          ]),
        ]),
        "running": .bool(false),
      ])
    }
    store.exhaustivity = .off

    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.thinkingDelta(text: "just ")))
    await store.send(.gatewayEvent(.thinkingDelta(text: "reasoning")))
    // The reasoning row kept its id (uuid 0) across both deltas.
    #expect(store.state.thinkingRowID == uuid(0))
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    // Frozen reasoning row (kept — it carried reasoning), still uuid(0).
    #expect(store.state.transcript[id: uuid(0)] != nil)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    // Reconciled to the deterministic .thinking id at sequence index 0.
    let deterministicThinkingID = ChatRow.deterministicID(
      sequenceIndex: 0, role: nil, kindDiscriminator: "thinking"
    )
    #expect(store.state.transcript[id: deterministicThinkingID] != nil)
    #expect(store.state.transcript[id: uuid(0)] == nil)

    await store.send(.onDisappear)
  }
}
