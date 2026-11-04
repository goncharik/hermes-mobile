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
  /// reducer mints for live reasoning/streaming rows (which start at 0).
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

    // A reasoning burst appends a row → window slides to keep the bottom window.
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.reasoningDelta(text: "hmm")))
    #expect(store.state.transcript.count == 201)
    #expect(store.state.windowStart == 201 - ChatFeature.State.initialWindow) // 151
    #expect(store.state.visibleRows.last?.id == store.state.transcript.last?.id)
    // Row 151 is an assistant reply: the window snaps down to its turn's user row (150), so
    // one row more than the raw window shows.
    #expect(store.state.visibleRows.first?.id == uuid(150))
    #expect(store.state.visibleRows.count == ChatFeature.State.initialWindow + 1)

    // A delta materialises the assistant row → still pinned to the bottom window.
    await store.send(.gatewayEvent(.messageDelta(text: "hi")))
    #expect(store.state.windowStart == store.state.transcript.count - ChatFeature.State.initialWindow)
    #expect(store.state.visibleRows.last?.id == store.state.transcript.last?.id)

    await store.send(.teardown)
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

    await store.send(.teardown)
  }

  /// #125 regression: on a 50+ row transcript parked at the bottom window, each live tool row
  /// slides the fixed raw window — its head row drops off. The renderer classifies on that raw
  /// window (`windowRowIDs`) and must see a `.slide`, never a `.reset` (which jumps a scrolled-up
  /// reader to the bottom) — even when the SNAPPED window shrinks as its start passes a user row.
  @Test func liveToolCallSlidesWindowNotReset() async {
    let store = makeStore(transcript: rows(200))
    store.exhaustivity = .off
    await store.send(.gatewayEvent(.messageStart))
    var previous = store.state.windowRowIDs
    var visible: [[ChatRow.ID]] = []

    for toolID in ["t1", "t2"] {
      await store.send(.gatewayEvent(.toolStart(toolID: toolID, name: "terminal", title: nil, argsText: nil)))
      let current = store.state.windowRowIDs
      #expect(current.count == ChatFeature.State.initialWindow)
      #expect(TranscriptDiffKind.classify(old: previous, new: current) == .slide(droppedHeadCount: 1))
      previous = current
      visible.append(store.state.visibleRows.map(\.id))
    }
    // The snapped window shrank on the second tool row; classified on its own ids that would be
    // a hydrate re-trim — the yank the raw window avoids.
    #expect(visible[1].count < visible[0].count)
    #expect(TranscriptDiffKind.classify(old: visible[0], new: visible[1]) == .reset)

    await store.send(.teardown)
  }

  /// #125 at turn end: every step of a turn on a 50+ row chat — including the end — must keep a
  /// scrolled-up reader's rows, never `.reset`.
  @Test func turnEndKeepsWindowRowsNotReset() async {
    let store = makeStore(transcript: rows(200))
    store.exhaustivity = .off
    var previous = store.state.windowRowIDs

    for event: GatewayEvent in [
      .messageStart,
      .messageDelta(text: "Hello"),
      .messageComplete(text: "Hello", usage: nil),
    ] {
      await store.send(.gatewayEvent(event))
      let current = store.state.windowRowIDs
      let kind = TranscriptDiffKind.classify(old: previous, new: current)
      #expect(kind != .reset, "\(event)")
      previous = current
    }
    #expect(store.state.transcript.count == 201) // the answer row

    await store.send(.teardown)
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

    await store.send(.teardown)
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
    let pagedUp = store.state.windowRowIDs

    // A second hydrate (e.g. a foreground re-resume) snaps the window back to the bottom even
    // though the user had scrolled up — server wins on every wholesale replace.
    let response = ActivateResponse(sessionID: "live123", messages: messages, running: false)
    await store.send(.activateResult(.success(response)))
    #expect(store.state.windowStart == ChatFeature.State.bottomWindowStart(count: store.state.transcript.count))
    // The re-trim removed the paged-up rows, so the renderer jumps.
    #expect(TranscriptDiffKind.classify(old: pagedUp, new: store.state.windowRowIDs) == .reset)

    await store.send(.teardown)
  }

  /// A re-hydrate at the bottom window that brings one more server message slides the window:
  /// the reader's rows survive, so the renderer holds them rather than jumping.
  @Test func hydrateWithOneMoreMessageSlidesWindow() async {
    let messages = (1...81).map { i in
      SessionMessage(id: i, role: "user", content: "m\(i)")
    }
    let payload: JSONValue = .object([
      "session_id": .string("live123"),
      "messages": .array(messages.dropLast().map {
        .object(["id": .number(Double($0.id ?? 0)), "role": .string($0.role), "content": .string($0.content ?? "")])
      }),
      "running": .bool(false),
    ])
    let store = makeHydratingStore { @Sendable _, _ in payload }
    store.exhaustivity = .off

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    let before = store.state.windowRowIDs

    let response = ActivateResponse(sessionID: "live123", messages: messages, running: false)
    await store.send(.activateResult(.success(response)))
    let after = store.state.windowRowIDs
    #expect(after.count == ChatFeature.State.initialWindow)
    #expect(TranscriptDiffKind.classify(old: before, new: after) == .slide(droppedHeadCount: 1))

    await store.send(.teardown)
  }
}
