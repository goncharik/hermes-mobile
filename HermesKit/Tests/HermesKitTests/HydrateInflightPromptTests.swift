import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// #150: a running turn's prompt is painted exactly once on a re-hydrate. The gateway writes
/// the prompt row at submit, so `session.resume` returns it in `messages` AND `inflight.user`
/// for the whole turn; the seed must not add a second bubble, but must still add the only one
/// when the history lacks it — and never hide a prompt the user really sent twice.
@MainActor
struct HydrateInflightPromptTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  nonisolated private static func user(_ text: String, at timestamp: Double? = nil) -> JSONValue {
    var row: [String: JSONValue] = ["role": .string("user"), "text": .string(text)]
    if let timestamp { row["timestamp"] = .number(timestamp) }
    return .object(row)
  }

  nonisolated private static func assistant(_ text: String) -> JSONValue {
    .object(["role": .string("assistant"), "text": .string(text)])
  }

  nonisolated private static func tool(_ name: String) -> JSONValue {
    .object(["role": .string("tool"), "name": .string(name), "context": .string("Which one?")])
  }

  nonisolated private static func steer(_ text: String) -> JSONValue {
    .object(["role": .string("user"), "text": .string(text), "display_kind": .string("steer")])
  }

  nonisolated private static func running(
    _ messages: [JSONValue], user: String = "now", startedAt: Double? = 970,
    corrections: [String] = []
  ) -> JSONValue {
    var inflight: [String: JSONValue] = [
      "user": .string(user), "assistant": .string(""), "streaming": .bool(true),
    ]
    if let startedAt { inflight["started_at"] = .number(startedAt) }
    if !corrections.isEmpty { inflight["corrections"] = .array(corrections.map(JSONValue.string)) }
    return .object([
      "session_id": .string("live123"),
      "stored_session_id": .string("stored123"),
      "messages": .array(messages),
      "running": .bool(true),
      "inflight": .object(inflight),
    ])
  }

  private func makeStore(_ response: JSONValue) -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in response }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  private func userTexts(_ store: TestStoreOf<ChatFeature>) -> [String] {
    store.state.transcript.compactMap { row in
      if case let .message(.user, text, _) = row.kind { return text }
      return nil
    }
  }

  private func lastTurnHeader(_ store: TestStoreOf<ChatFeature>) -> TurnHeader? {
    store.state.transcriptItems.compactMap { item -> TurnHeader? in
      if case let .turnHeader(header) = item { return header }
      return nil
    }.last
  }

  @Test(arguments: [
    // Re-opened right after sending: only the submit-time row is persisted.
    [Self.user("now", at: 975)],
    // After a mid-turn flush: the turn's tool round follows the prompt (the clarify case).
    [Self.user("now", at: 975), Self.assistant("Let me ask."), Self.tool("clarify")],
    // Whitespace differs between the stored row and the inflight snapshot.
    [Self.user("  now\n", at: 975), Self.tool("clarify")],
  ])
  func aPromptInBothHistoryAndInflightIsPaintedOnce(turn: [JSONValue]) async {
    let history = [Self.user("earlier"), Self.assistant("reply")] + turn
    let store = makeStore(Self.running(history))

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    #expect(userTexts(store).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } == ["earlier", "now"])
    // The streaming row is seeded after the persisted turn, which stays one turn.
    #expect(store.state.transcript.last?.kind == .message(role: .assistant, text: "", isComplete: false))
    #expect(store.state.streamingRowID == store.state.transcript.last?.id)

    // A second running hydrate stays byte-identical.
    let rows = Array(store.state.transcript)
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    #expect(Array(store.state.transcript) == rows)

    await store.send(.teardown)
  }

  @Test func aPromptOnlyInInflightIsStillSeededOnce() async {
    // An agent that hasn't persisted the prompt yet: the history ends with the last turn's
    // final reply, so the seed is the turn's only prompt bubble, stamped with its start.
    let store = makeStore(Self.running([Self.user("earlier"), Self.assistant("reply")]))

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    #expect(userTexts(store) == ["earlier", "now"])
    let prompt = store.state.transcript[store.state.transcript.count - 2]
    #expect(prompt.kind == .message(role: .user, text: "now", isComplete: true))
    #expect(prompt.timestamp == Date(timeIntervalSince1970: 970))

    await store.send(.teardown)
  }

  @Test(arguments: [
    // Last turn's identical prompt, answered; this turn's not persisted yet → seeded.
    [Self.user("hi"), Self.assistant("hello")],
    // This turn's identical prompt already persisted after last turn's reply → not seeded.
    [Self.user("hi"), Self.assistant("hello"), Self.user("hi", at: 975)],
    // Last turn's identical prompt was stopped mid tool round (no final reply), stamped long
    // before this turn started → it is not this turn's row, so the seed stays.
    [Self.user("hi", at: 100), Self.assistant("Let me check."), Self.tool("terminal")],
  ])
  func aPromptTheUserSentTwiceKeepsBothBubbles(history: [JSONValue]) async {
    let store = makeStore(Self.running(history, user: "hi"))

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    #expect(userTexts(store) == ["hi", "hi"])

    await store.send(.teardown)
  }

  @Test func aPersistedSteerAfterThePromptKeepsBothBubblesOnce() async {
    // The prompt and an accepted steer are both in the history: one bubble each.
    let store = makeStore(Self.running(
      [Self.user("now", at: 975), Self.tool("terminal"), Self.steer("also this")],
      corrections: ["also this"]
    ))

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    #expect(userTexts(store) == ["now", "also this"])

    await store.send(.teardown)
  }

  @Test(arguments: [
    (Optional(975.0), 25.0), // the stored row's own stamp wins
    (nil, 30.0), // an unstamped row takes the turn's start
  ])
  func theFinishedTurnTimesFromThePersistedPrompt(stamp: Double?, worked: TimeInterval) async throws {
    let store = makeStore(Self.running([Self.user("now", at: stamp), Self.tool("clarify")]))

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await store.send(.gatewayEvent(.messageDelta(text: "Done")))
    await store.send(.gatewayEvent(.messageComplete(text: "Done.", usage: nil, responseReused: false)))

    #expect(userTexts(store) == ["now"])
    let header = try #require(lastTurnHeader(store))
    #expect(header.duration == worked)

    await store.send(.teardown)
  }

  @Test func aNoticeTurnWhoseNoticeIsPersistedShowsOneNoticeLine() async {
    // #124: a turn Hermes started itself, its notice row already in the history — one status
    // line, never a second one and never a user bubble.
    let payload = "[IMPORTANT: Background process proc_1 finished …]"
    let metadata: JSONValue = .object(["display_text": .string("Background Process Finished: make")])
    let response: JSONValue = .object([
      "session_id": .string("live123"),
      "stored_session_id": .string("stored123"),
      "messages": .array([
        Self.user("earlier"), Self.assistant("reply"),
        .object([
          "role": .string("user"), "text": .string(payload),
          "display_kind": .string("process_complete"), "display_metadata": metadata,
        ]),
      ]),
      "running": .bool(true),
      "inflight": .object([
        "user": .string(payload), "assistant": .string(""), "streaming": .bool(true),
        "display_kind": .string("process_complete"), "display_metadata": metadata,
      ]),
    ])
    let store = makeStore(response)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    let notice = ChatRow.Kind.status(
      kind: ChatRow.Kind.noticeStatusKind, text: "Background Process Finished: make"
    )
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "earlier", isComplete: true),
      .message(role: .assistant, text: "reply", isComplete: true),
      notice,
      .message(role: .assistant, text: "", isComplete: false),
    ])

    await store.send(.teardown)
  }
}
