import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Task 2: row identity is preserved across streaming deltas, and live (random-id) streaming
/// rows reconcile to the deterministic, content-derived history ids on the next hydrate —
/// without duplicating rows or flickering. The streaming fold helpers
/// (`appendToStreamingMessage`, `appendReasoning`, `closeReasoningBurst`) must mutate the
/// in-place row, never churn its id.
@MainActor
struct RowIdentityTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }
  /// `makeStore`'s pinned `date` — what the fold stamps on live rows.
  private let t0 = Date(timeIntervalSince1970: 0)

  private func makeStore() -> TestStore<ChatFeature.State, ChatFeature.Action> {
    TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(t0)
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
      $0.isTurnLive = true
    }
    // First delta materialises the assistant row (uuid 0) — nothing was created eagerly.
    await store.send(.gatewayEvent(.messageDelta(text: "Hel"))) {
      $0.transcript = [
        ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "Hel", isComplete: false), timestamp: t0),
      ]
      $0.streamingRowID = uuid(0)
    }
    // Subsequent deltas only mutate the text — the id stays uuid(0).
    await store.send(.gatewayEvent(.messageDelta(text: "lo"))) {
      $0.transcript[id: uuid(0)]?.kind = .message(role: .assistant, text: "Hello", isComplete: false)
    }
    await store.send(.gatewayEvent(.messageDelta(text: " world"))) {
      $0.transcript[id: uuid(0)]?.kind = .message(role: .assistant, text: "Hello world", isComplete: false)
    }
    #expect(store.state.streamingRowID == uuid(0))
    #expect(store.state.transcript[id: uuid(0)] != nil)
    // Completion still mutates the same row in place (no new id).
    await store.send(.gatewayEvent(.messageComplete(text: "Hello world", usage: nil))) {
      $0.transcript[id: uuid(0)]?.kind = .message(role: .assistant, text: "Hello world", isComplete: true)
      $0.streamingRowID = nil
      $0.isTurnLive = false
      $0.isSending = false
    }
    #expect(store.state.transcript[id: uuid(0)] != nil)
  }

  /// Reasoning deltas accumulate into the open burst row (created by the first delta); its id
  /// (uuid 0) never changes across deltas, and a status update never touches it.
  @Test func reasoningDeltasPreserveBurstRowID() async {
    let store = makeStore()

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.isTurnLive = true
    }
    await store.send(.gatewayEvent(.reasoningDelta(text: "Plan"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .reasoning(text: "Plan", isComplete: false), timestamp: t0)]
      $0.reasoningRowID = uuid(0)
      $0.liveReasoningRowIDs = [uuid(0)]
    }
    await store.send(.gatewayEvent(.reasoningDelta(text: "ning"))) {
      $0.transcript[id: uuid(0)]?.kind = .reasoning(text: "Planning", isComplete: false)
    }
    await store.send(.gatewayEvent(.statusUpdate(kind: "context", text: "Context: 12%"))) {
      $0.turnStatus = "Context: 12%"
    }
    #expect(store.state.reasoningRowID == uuid(0))
    await store.send(.teardown)
  }

  // MARK: Burst close preserves ids

  /// A tool row ends the open burst: the reasoning row is marked complete IN PLACE (same id,
  /// same position — no reorder), and the tool row lands after it.
  @Test func toolStartClosesBurstInPlace() async {
    let store = makeStore()

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.isTurnLive = true
    }
    await store.send(.gatewayEvent(.reasoningDelta(text: "Plan"))) {
      $0.transcript = [ChatRow(id: uuid(0), kind: .reasoning(text: "Plan", isComplete: false), timestamp: t0)]
      $0.reasoningRowID = uuid(0)
      $0.liveReasoningRowIDs = [uuid(0)]
    }
    await store.send(.gatewayEvent(.toolStart(toolID: "t1", name: "search", title: "Searching", argsText: nil))) {
      $0.transcript = [
        ChatRow(id: uuid(0), kind: .reasoning(text: "Plan", isComplete: true), timestamp: t0),
        ChatRow(id: uuid(1), kind: .tool(name: "search", title: "Searching", state: .running, detail: nil, durationS: nil), timestamp: t0),
      ]
      $0.reasoningRowID = nil
      $0.toolRowIDs["t1"] = uuid(1)
    }
    #expect(store.state.transcript.first?.id == uuid(0))
    #expect(store.state.transcript.last?.id == uuid(1))
    await store.send(.teardown)
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

    await store.send(.teardown)
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

  /// A local `.commandOutput` row (#36 — ephemeral slash-command output, desktop parity) is
  /// dropped by the wholesale hydrate replace: server history never contains it, so after
  /// `session.resume` the transcript equals the server's reconstruction exactly.
  @Test func hydrateWholesaleReplaceDropsLocalCommandOutputRows() async {
    let serverMessages = [
      SessionMessage(id: 1, role: "user", content: "ping"),
      SessionMessage(id: 2, role: "assistant", content: "pong"),
    ]
    // Seed a local command-output row (as the slash pipeline would append it) into the
    // initial transcript, then hydrate.
    let commandRowID = ChatRow.deterministicID(
      sequenceIndex: 99, role: nil, kindDiscriminator: "commandOutput"
    )
    let snapshotClient = ChatSnapshotClient.inMemory()
    var initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }
    initial.transcript = [
      ChatRow(id: commandRowID, kind: .commandOutput(text: "compressed 12 messages"))
    ]
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in
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
    }
    store.exhaustivity = .off
    #expect(store.state.transcript[id: commandRowID] != nil)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    // Server wins wholesale: the local command-output row is gone, transcript matches the
    // server reconstruction byte-for-byte.
    #expect(store.state.transcript[id: commandRowID] == nil)
    #expect(Array(store.state.transcript) == reconstructTranscript(serverMessages))
    #expect(store.state.transcript.allSatisfy { $0.kind.discriminator != "commandOutput" })

    await store.send(.teardown)
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

    await store.send(.teardown)
  }

  /// A reasoning-only turn (reasoning text, no assistant message) keeps the burst row id
  /// stable across deltas and reconciles to the deterministic `.reasoning` id on hydrate.
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
    await store.send(.gatewayEvent(.reasoningDelta(text: "just ")))
    await store.send(.gatewayEvent(.reasoningDelta(text: "reasoning")))
    // The reasoning row kept its id (uuid 0) across both deltas.
    #expect(store.state.reasoningRowID == uuid(0))
    await store.send(.gatewayEvent(.messageComplete(text: "", usage: nil)))
    // Closed reasoning row, still uuid(0).
    #expect(store.state.transcript[id: uuid(0)]?.kind == .reasoning(text: "just reasoning", isComplete: true))

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    // Reconciled to the deterministic .reasoning id at sequence index 0.
    let deterministicReasoningID = ChatRow.deterministicID(
      sequenceIndex: 0, role: nil, kindDiscriminator: "reasoning"
    )
    #expect(store.state.transcript[id: deterministicReasoningID] != nil)
    #expect(store.state.transcript[id: uuid(0)] == nil)

    await store.send(.teardown)
  }
}
