import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Task 3: client-side rendering window over the full in-memory transcript. There is NO network
/// pagination — the server returns the full history in one `session.resume` payload, so this is a
/// pure client-side window (`windowStart`, `visibleRows`, `hasMoreAbove`, `.loadOlderRequested`)
/// to bound relayout cost on long chats. Invariants:
///   - the window opens at the bottom (newest) and resets there on every wholesale hydrate;
///   - `.loadOlderRequested` reveals a page of older rows and clamps at the top;
///   - newly appended (streaming) rows always stay visible when parked at the bottom window;
///   - a user who scrolled up (loaded older) is never yanked when new rows arrive.
@MainActor
struct ChatWindowingTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  /// Seed-row ids live in a high range so they never collide with the `.incrementing` uuids the
  /// reducer mints for live thinking/streaming rows (which start at 0).
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012x", n))")!
  }

  /// A transcript of `count` simple user/assistant message rows (deterministic ids by index).
  private func rows(_ count: Int) -> IdentifiedArrayOf<ChatRow> {
    IdentifiedArrayOf(uniqueElements: (0..<count).map { i in
      ChatRow(id: uuid(i), kind: .message(role: i.isMultiple(of: 2) ? .user : .assistant,
                                          text: "row \(i)", isComplete: true))
    })
  }

  private func makeStore(
    transcript: IdentifiedArrayOf<ChatRow> = []
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    TestStore(initialState: ChatFeature.State(connection: conn, transcript: transcript)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
  }

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

  // MARK: Initial window

  /// A long transcript opens parked at the bottom `initialWindow` rows.
  @Test func opensAtBottomWindowForLongTranscript() {
    let state = ChatFeature.State(connection: conn, transcript: rows(200))
    #expect(state.windowStart == 200 - ChatFeature.State.initialWindow) // 150
    #expect(state.visibleRows.count == ChatFeature.State.initialWindow)
    #expect(state.hasMoreAbove)
    // The visible slice is the tail (rows 150..199).
    #expect(state.visibleRows.first?.id == uuid(150))
    #expect(state.visibleRows.last?.id == uuid(199))
  }

  /// A transcript shorter than `initialWindow` shows everything, with no "more above".
  @Test func shortTranscriptShowsEverything() {
    let state = ChatFeature.State(connection: conn, transcript: rows(10))
    #expect(state.windowStart == 0)
    #expect(state.visibleRows.count == 10)
    #expect(!state.hasMoreAbove)
  }

  /// An empty transcript has an empty window and no "more above".
  @Test func emptyTranscript() {
    let state = ChatFeature.State(connection: conn)
    #expect(state.windowStart == 0)
    #expect(state.visibleRows.isEmpty)
    #expect(!state.hasMoreAbove)
  }

  /// Exactly `initialWindow` rows: the whole transcript is the bottom window, nothing above.
  @Test func exactlyOneWindow() {
    let state = ChatFeature.State(connection: conn, transcript: rows(ChatFeature.State.initialWindow))
    #expect(state.windowStart == 0)
    #expect(state.visibleRows.count == ChatFeature.State.initialWindow)
    #expect(!state.hasMoreAbove)
  }

  // MARK: loadOlderRequested

  /// `.loadOlderRequested` reveals another `pageSize` of older rows.
  @Test func loadOlderDecrementsByPageSize() async {
    let store = makeStore(transcript: rows(200))
    #expect(store.state.windowStart == 150)
    await store.send(.loadOlderRequested) {
      $0.windowStart = 100
    }
    #expect(store.state.visibleRows.count == 100)
    #expect(store.state.hasMoreAbove)
    await store.send(.loadOlderRequested) {
      $0.windowStart = 50
    }
    await store.send(.loadOlderRequested) {
      $0.windowStart = 0
    }
    #expect(!store.state.hasMoreAbove)
    #expect(store.state.visibleRows.count == 200)
  }

  /// `.loadOlderRequested` clamps at 0 and stays there (never negative).
  @Test func loadOlderClampsAtZero() async {
    let store = makeStore(transcript: rows(60)) // windowStart = 10
    #expect(store.state.windowStart == 10)
    await store.send(.loadOlderRequested) {
      $0.windowStart = 0 // 10 - 50 clamps to 0
    }
    // Already at the top — another request is a no-op.
    await store.send(.loadOlderRequested)
    #expect(store.state.windowStart == 0)
    #expect(!store.state.hasMoreAbove)
  }

  // MARK: Streaming keeps the newest visible

  /// While parked at the bottom window, a streaming append re-pins the window to the bottom so
  /// the newest rows stay visible — and the live window stays bounded by `initialWindow`.
  @Test func streamingAppendKeepsNewestVisible() async {
    let store = makeStore(transcript: rows(200))
    store.exhaustivity = .off
    #expect(store.state.windowStart == 150)

    // message.start appends a thinking row → window slides to keep the bottom window.
    await store.send(.gatewayEvent(.messageStart))
    #expect(store.state.transcript.count == 201)
    #expect(store.state.windowStart == 201 - ChatFeature.State.initialWindow) // 151
    #expect(store.state.visibleRows.last?.id == store.state.transcript.last?.id)
    #expect(store.state.visibleRows.count == ChatFeature.State.initialWindow)

    // A delta materialises the assistant row → still pinned to the bottom window.
    await store.send(.gatewayEvent(.messageDelta(text: "hi")))
    #expect(store.state.windowStart == store.state.transcript.count - ChatFeature.State.initialWindow)
    #expect(store.state.visibleRows.last?.id == store.state.transcript.last?.id)

    await store.send(.onDisappear)
  }

  /// A user who scrolled up (loaded older history) is NOT yanked back to the bottom when a new
  /// row streams in — their window start is preserved (no scroll yank).
  @Test func streamingDoesNotYankScrolledUpUser() async {
    let store = makeStore(transcript: rows(200))
    store.exhaustivity = .off
    // Scroll all the way up.
    await store.send(.loadOlderRequested) // 100
    await store.send(.loadOlderRequested) // 50
    await store.send(.loadOlderRequested) // 0
    #expect(store.state.windowStart == 0)

    // A turn streams in — the window must NOT jump to the bottom.
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.messageDelta(text: "hi")))
    #expect(store.state.windowStart == 0)
    #expect(store.state.hasMoreAbove == false)

    await store.send(.onDisappear)
  }

  // MARK: Hydrate resets to the bottom window

  /// A wholesale hydrate (`session.resume`) resets the window to the bottom, discarding any prior
  /// scroll-up. Server wins.
  @Test func hydrateResetsWindowToBottom() async {
    // 80-message history so the bottom window (30) leaves rows above.
    let messages = (1...80).map { i in
      SessionMessage(id: i, role: i.isMultiple(of: 2) ? "assistant" : "user", content: "m\(i)")
    }
    let payload: JSONValue = .object([
      "session_id": .string("live123"),
      "stored_session_id": .string("stored123"),
      "messages": .array(messages.map {
        .object(["id": .number(Double($0.id ?? 0)), "role": .string($0.role), "content": .string($0.content ?? "")])
      }),
      "running": .bool(false),
    ])
    let store = makeHydratingStore { @Sendable _, _ in payload }
    store.exhaustivity = .off

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    let count = store.state.transcript.count
    #expect(count == 80)
    #expect(store.state.windowStart == ChatFeature.State.bottomWindowStart(count: count)) // 30
    #expect(store.state.visibleRows.count == ChatFeature.State.initialWindow)
    #expect(store.state.visibleRows.last?.id == store.state.transcript.last?.id)
    #expect(store.state.hasMoreAbove)

    await store.send(.onDisappear)
  }

  /// Even after scrolling up, a re-hydrate snaps the window back to the bottom.
  @Test func hydrateAfterScrollUpResetsToBottom() async {
    let messages = (1...80).map { i in
      SessionMessage(id: i, role: "user", content: "m\(i)")
    }
    let payload: JSONValue = .object([
      "session_id": .string("live123"),
      "messages": .array(messages.map {
        .object(["id": .number(Double($0.id ?? 0)), "role": .string($0.role), "content": .string($0.content ?? "")])
      }),
      "running": .bool(false),
    ])
    let store = makeHydratingStore { @Sendable _, _ in payload }
    store.exhaustivity = .off

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    // Scroll up.
    await store.send(.loadOlderRequested)
    #expect(store.state.windowStart < ChatFeature.State.bottomWindowStart(count: 80))

    // A second hydrate (e.g. a foreground re-resume) snaps the window back to the bottom even
    // though the user had scrolled up — server wins on every wholesale replace.
    let response = ActivateResponse(sessionID: "live123", messages: messages, running: false)
    await store.send(.activateResult(.success(response)))
    #expect(store.state.windowStart == ChatFeature.State.bottomWindowStart(count: store.state.transcript.count))

    await store.send(.onDisappear)
  }
}
