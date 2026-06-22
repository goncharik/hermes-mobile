import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Task 5: instant-paint from the non-authoritative snapshot on `init`, server-wins wholesale
/// replacement on hydrate, offline keeping the cache with a reconnecting status, and the
/// debounced write-back.
@MainActor
struct HydrateTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  // MARK: Instant paint

  @Test func initPaintsTranscriptModelUsageFromCache() async {
    // A snapshot persisted for the stored session id must paint into the initial state so the
    // chat renders instantly — before any `session.resume` lands.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: uuid(10), kind: .message(role: .user, text: "earlier question", isComplete: true)),
      ChatRow(id: uuid(11), kind: .message(role: .assistant, text: "earlier answer", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(
      model: "claude-opus-4-8",
      reasoningEffort: "high",
      usage: Usage(contextUsed: 1_000, contextMax: 200_000, contextPercent: 0),
      rows: cachedRows
    ))

    // Constructing State inside a dependency scope lets `init` read the seeded cache.
    let state = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }

    #expect(Array(state.transcript) == cachedRows)
    #expect(state.model == "claude-opus-4-8")
    #expect(state.reasoningEffort == "high")
    #expect(state.usage == Usage(contextUsed: 1_000, contextMax: 200_000, contextPercent: 0))
  }

  @Test func initWithNoCacheLeavesEmptyTranscript() async {
    // No snapshot → no paint (empty transcript, nil model/usage). Regression guard.
    let state = withDependencies {
      $0.chatSnapshot = .inMemory()
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "unknown")
    }
    #expect(state.transcript.isEmpty)
    #expect(state.model == nil)
    #expect(state.usage == nil)
  }

  // MARK: Hydrate replaces the cache wholesale

  @Test func hydrateReplacesCachedRowsWholesale() async {
    // The init-painted cache rows must be fully replaced by the server's `messages` on
    // activate (server wins, no merge): cached rows gone, server rows present.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: uuid(10), kind: .message(role: .user, text: "stale cached", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(
      model: "old-model",
      usage: Usage(contextUsed: 9_999, contextMax: 200_000, contextPercent: 5),
      rows: cachedRows
    ))

    let initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }
    // Sanity: the cache painted.
    #expect(Array(initial.transcript) == cachedRows)
    #expect(initial.model == "old-model")

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
            .object(["id": .number(1), "role": .string("user"), "content": .string("fresh server msg")]),
            .object(["id": .number(2), "role": .string("assistant"), "content": .string("fresh server reply")]),
          ]),
          "running": .bool(false),
          "info": .object([
            "model": .string("claude-opus-4-8"),
            "usage": .object(["context_used": .number(42), "context_max": .number(200_000), "context_percent": .number(0)]),
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
      // Model + usage overwritten by the server (not merged with the cache).
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 42, contextMax: 200_000, contextPercent: 0)
      // Cached row gone; server rows present (wholesale replace). Rows carry deterministic,
      // content-derived ids (matching `reconstructTranscript`).
      $0.transcript = IdentifiedArrayOf(uniqueElements: reconstructTranscript([
        SessionMessage(id: 1, role: "user", content: "fresh server msg"),
        SessionMessage(id: 2, role: "assistant", content: "fresh server reply"),
      ]))
    }
    // The stale cached row id is gone entirely.
    #expect(store.state.transcript[id: self.uuid(10)] == nil)
    // Activate's authoritative `running:false` clears the list glow for this session.
    await store.receive(\.delegate.runningChanged)
    await store.send(.onDisappear)
  }

  // MARK: Cold-resume usage preservation + stale-banner clearing

  @Test func coldResumePreservesCachedUsageAndClearsStaleBanner() async {
    // A freshly-resumed (cold) agent reports zero usage until its first turn re-counts the
    // loaded history. That placeholder must NOT clobber the real cached context gauge — and a
    // stale "Connection lost." banner from a prior drop must clear once we reconnect+hydrate.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedUsage = Usage(contextUsed: 42_000, contextMax: 200_000, contextPercent: 21)
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(
      model: "claude-opus-4-8",
      usage: cachedUsage,
      rows: [ChatRow(id: uuid(10), kind: .message(role: .user, text: "earlier", isComplete: true))]
    ))

    var initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }
    initial.errorBanner = "Connection lost."  // left over from a lock/unlock drop

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in
        // Cold-resume payload: model known, usage all-zero (context_max set, used 0).
        .object([
          "session_id": .string("live123"),
          "resumed": .string("stored123"),
          "messages": .array([
            .object(["role": .string("user"), "text": .string("earlier")]),
          ]),
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
    store.exhaustivity = .off

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    // Usage preserved from cache (the cold zero didn't win); banner cleared on reconnect.
    #expect(store.state.usage == cachedUsage)
    #expect(store.state.errorBanner == nil)
    #expect(store.state.status == .ready)
    await store.send(.onDisappear)
  }

  @Test func realProtocolErrorStillRaisesBanner() async {
    // A genuine (non-`.disconnected`) failure must still surface a banner — only a dropped
    // socket is silenced (the reconnecting status conveys that one).
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { @Sendable _, _ in throw GatewayError.server("boom") }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.failure) {
      $0.errorBanner = "boom"
      $0.status = .reconnecting
    }
    await store.send(.onDisappear)
  }

  // MARK: Offline keeps the cache + reconnecting status

  @Test func offlineKeepsCachedPaintAndShowsReconnecting() async {
    // When `session.resume` fails (offline / connection error) we must NOT blank the
    // screen: keep the cached instant-paint rows + model/usage and show a reconnecting status.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: uuid(10), kind: .message(role: .user, text: "cached question", isComplete: true)),
      ChatRow(id: uuid(11), kind: .message(role: .assistant, text: "cached answer", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(
      model: "claude-opus-4-8",
      usage: Usage(contextUsed: 7, contextMax: 200_000, contextPercent: 0),
      rows: cachedRows
    ))

    let initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in throw GatewayError.disconnected }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.failure) {
      // A dropped socket is conveyed by the reconnecting status alone — no banner is raised
      // for `.disconnected` (it would otherwise linger after reconnect; see the lock/unlock
      // regression). The cached paint stays put.
      $0.status = .reconnecting
    }
    // Cache still on screen — never blanked.
    #expect(Array(store.state.transcript) == cachedRows)
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.usage == Usage(contextUsed: 7, contextMax: 200_000, contextPercent: 0))
  }

  // MARK: Debounced write-back

  @Test func contentUpdatePersistsSnapshotAfterDebounce() async {
    // A content-changing gateway event schedules a debounced persist; after the debounce
    // interval the fresh snapshot (model/usage/rows) is written to the cache.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.status = .ready
    initial.model = "claude-opus-4-8"

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 123))
      $0.chatSnapshot = snapshotClient
    }

    // A completed (non-streamed) assistant message changes the transcript + usage.
    await store.send(.gatewayEvent(.messageComplete(
      text: "hello there",
      usage: Usage(contextUsed: 50, contextMax: 200_000, contextPercent: 0)
    ))) {
      $0.usage = Usage(contextUsed: 50, contextMax: 200_000, contextPercent: 0)
      $0.isSending = false
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .assistant, text: "hello there", isComplete: true))]
    }
    // message.complete clears this session's list glow (running:false).
    await store.receive(\.delegate.runningChanged)

    // Nothing persisted yet (still inside the debounce window).
    #expect(snapshotClient.loadSnapshot("stored123") == nil)

    // Advance past the debounce → the write-back fires.
    await clock.advance(by: .seconds(1))
    await store.receive(\.persistSnapshotTick)

    let saved = snapshotClient.loadSnapshot("stored123")
    #expect(saved?.model == "claude-opus-4-8")
    #expect(saved?.usage == Usage(contextUsed: 50, contextMax: 200_000, contextPercent: 0))
    #expect(saved?.rows == [ChatRow(id: self.uuid(0), kind: .message(role: .assistant, text: "hello there", isComplete: true))])
    #expect(saved?.updatedAt == Date(timeIntervalSince1970: 123))

    await store.send(.onDisappear)
  }

  @Test func burstOfDeltasCoalescesIntoOnePersist() async {
    // Heavy streaming must coalesce into a single write (cancel-in-flight debounce): a burst
    // of deltas within the window yields exactly one persist tick.
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
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Three deltas back-to-back (no clock advance between) — each resets the debounce.
    await store.send(.gatewayEvent(.messageDelta(text: "a")))
    await store.send(.gatewayEvent(.messageDelta(text: "b")))
    await store.send(.gatewayEvent(.messageDelta(text: "c")))

    await clock.advance(by: .seconds(1))
    // Exactly one persist tick lands (the prior two were cancelled in flight).
    await store.receive(\.persistSnapshotTick)

    let saved = snapshotClient.loadSnapshot("stored123")
    #expect(saved?.rows.last?.copyText == "abc")

    await store.send(.onDisappear)
  }

  // MARK: Task 6 — turn-start anchor + timer continuity

  /// Build an activate-shaped response with the given `running` flag, empty messages and no
  /// inflight, so the only row applyActivate adds is the reconciled live thinking row.
  nonisolated private static func activateResponse(running: Bool) -> JSONValue {
    .object([
      "session_id": .string("live123"),
      "stored_session_id": .string("stored123"),
      "messages": .array([]),
      "running": .bool(running),
      "info": .object([
        "model": .string("claude-opus-4-8"),
        "usage": .object(["context_used": .number(1), "context_max": .number(200_000), "context_percent": .number(0)]),
      ]),
    ])
  }

  @Test func hydrateResumesTimerSeededAtElapsedAndTicksOn() async {
    // running == true with a persisted anchor at `now − 7s` → the live thinking row resumes
    // seeded at 7s and keeps ticking (8s, 9s, …) rather than restarting at 0.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 1_000)
    snapshotClient.setTurnAnchor("stored123", nowDate.addingTimeInterval(-7))

    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(nowDate)
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in Self.activateResponse(running: true) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success) {
      $0.isSending = true
      // Live thinking row recreated, seeded at 7s elapsed, still in flight.
      $0.thinkingSeconds = 7
      $0.thinkingRowID = self.uuid(0)
      $0.transcript = [ChatRow(
        id: self.uuid(0),
        kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 7, isComplete: false)
      )]
    }
    // The resumed tick continues from 7 (not 0): two more seconds → 8, 9.
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 8 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 9 }

    await store.send(.onDisappear)
  }

  @Test func hydrateRunningWithNoAnchorTicksFromZero() async {
    // running == true but no persisted anchor → the timer anchors at `now`, seeding the row
    // at 0s and ticking 1, 2 from there.
    let snapshotClient = ChatSnapshotClient.inMemory() // no anchor seeded
    let clock = TestClock()

    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in Self.activateResponse(running: true) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success) {
      $0.isSending = true
      $0.thinkingSeconds = 0
      $0.thinkingRowID = self.uuid(0)
      $0.transcript = [ChatRow(
        id: self.uuid(0),
        kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
      )]
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }

    await store.send(.onDisappear)
  }

  @Test func hydrateNotRunningWithStaleAnchorFreezesAndDiscardsAnchor() async {
    // The phantom-timer bug: running == false but a stale anchor lingers. The timer must NOT
    // resume (no live thinking row, no tick); the stale anchor is discarded from the cache so
    // a later hydrate can't resurrect it.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 1_000)
    snapshotClient.setTurnAnchor("stored123", nowDate.addingTimeInterval(-30)) // stale

    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(nowDate)
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in Self.activateResponse(running: false) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success) {
      $0.isSending = false
      $0.thinkingSeconds = 0
    }
    // No live thinking row was created and no tick fires (a leaked tick loop would fail here).
    #expect(store.state.thinkingRowID == nil)
    #expect(store.state.transcript.isEmpty)
    await clock.advance(by: .seconds(5))
    // The stale anchor was discarded from the cache.
    #expect(snapshotClient.turnAnchor("stored123") == nil)

    await store.send(.onDisappear)
  }

  @Test func submitWritesAnchorAndCompleteClearsIt() async {
    // The anchor is persisted on prompt.submit (so a hydrate mid-turn resumes the timer) and
    // dropped on message.complete (so a stopped turn leaves no stale anchor).
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 5_000)
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.storedSessionID = "stored123"
    initial.composerText = "hello"

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(nowDate)
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in .object(["status": .string("streaming")]) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    // Anchor written at `now`.
    #expect(snapshotClient.turnAnchor("stored123") == nowDate)

    // The turn ends → the anchor is cleared.
    await store.send(.gatewayEvent(.messageComplete(text: "done", usage: nil)))
    #expect(snapshotClient.turnAnchor("stored123") == nil)

    await store.send(.onDisappear)
  }

  // MARK: Task 8 — background flush (`persistNow`)

  // `.persistNow` (dispatched on background) writes the snapshot SYNCHRONOUSLY — no debounce
  // wait — so a kill right after backgrounding keeps the latest paint.
  @Test func persistNowWritesSnapshotImmediatelyWithoutDebounce() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.model = "claude-opus-4-8"
    initial.transcript = [ChatRow(id: uuid(1), kind: .message(role: .user, text: "hi", isComplete: true))]

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 321))
      $0.chatSnapshot = snapshotClient
    }

    // Not in flight → no anchor write, just the immediate snapshot.
    await store.send(.persistNow)
    let saved = snapshotClient.loadSnapshot("stored123")
    #expect(saved?.model == "claude-opus-4-8")
    #expect(saved?.updatedAt == Date(timeIntervalSince1970: 321))
    #expect(saved?.rows == [ChatRow(id: uuid(1), kind: .message(role: .user, text: "hi", isComplete: true))])
    // No anchor written (turn not in flight).
    #expect(snapshotClient.turnAnchor("stored123") == nil)
  }

  // `.persistNow` mid-turn (`isSending`) also reaffirms the anchor at `now`.
  @Test func persistNowMidTurnReaffirmsAnchor() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.isSending = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 654))
      $0.chatSnapshot = snapshotClient
    }

    await store.send(.persistNow)
    #expect(snapshotClient.turnAnchor("stored123") == Date(timeIntervalSince1970: 654))
    #expect(snapshotClient.loadSnapshot("stored123")?.updatedAt == Date(timeIntervalSince1970: 654))
  }

  // MARK: Foreground genuinely re-hydrates

  // Acceptance #2: background→foreground mid-turn must re-read the authoritative state, NOT just
  // reconnect. A fast foreground may leave `hasRequestedSession == true` (the prior socket's
  // `.gatewayClosed` reset is dropped when its task is cancelled), so `.foreground` resets the
  // flag before reconnecting. This test starts with the flag already true, sends `.foreground`,
  // drives the reconnect→`.ready`→`hydrate` chain, and asserts the activate payload genuinely
  // lands (runtime info + inflight streaming row + resumed timer), proving foreground re-hydrates.
  @Test func foregroundResetsRequestedFlagAndReHydrates() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    // Simulate the post-reconnect state where the flag is stale-true (the dropped-reset bug).
    initial.hasRequestedSession = true
    initial.status = .reconnecting

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
      // Reconnect yields a single `.ready`, then idles.
      $0.hermesGateway.connect = { @Sendable _, _ in
        AsyncStream { continuation in
          continuation.yield(.ready)
          // keep the stream open so the socket effect doesn't send `.gatewayClosed`
        }
      }
      $0.hermesGateway.send = { @Sendable method, _ in
        .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("user"), "content": .string("prior question")]),
          ]),
          "running": .bool(true),
          "info": .object(["model": .string("claude-opus-4-8")]),
          "inflight": .object(["assistant": .string("partial answer"), "streaming": .bool(true)]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.foreground) {
      // The flag is reset so the fresh `.ready` won't short-circuit `hydrate`.
      $0.hasRequestedSession = false
    }
    // Reconnect fires `.ready` → hydrate runs (flag was reset).
    await store.receive(\.gatewayEvent)
    await store.receive(\.activateResult.success)

    // Foreground genuinely re-hydrated: server runtime info + inflight streaming row applied,
    // and the working indicator reflects the authoritative `running: true`.
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.isSending == true)
    #expect(store.state.hasRequestedSession == true)
    // The inflight streaming assistant row was seeded.
    #expect(store.state.transcript.contains { row in
      if case let .message(role, text, isComplete) = row.kind {
        return role == .assistant && text == "partial answer" && !isComplete
      }
      return false
    })

    await store.send(.onDisappear)
  }

  // MARK: Instant-paint + delta-before-activate race

  // Painting from cache leaves `streamingRowID == nil`; a `.messageDelta` could arrive while
  // still reconnecting (before activate). The lazy delta appends a transient assistant row to
  // the cached tail, but the wholesale rebuild on activate discards both the cached rows AND the
  // transient delta row — so the transcript ends up exactly the server's history (no duplicate /
  // corrupt cached tail).
  @Test func deltaBeforeActivateIsDiscardedByWholesaleRebuild() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    let cachedRows = [
      ChatRow(id: uuid(10), kind: .message(role: .user, text: "cached q", isComplete: true)),
      ChatRow(id: uuid(11), kind: .message(role: .assistant, text: "cached a", isComplete: true)),
    ]
    snapshotClient.saveSnapshot("stored123", ChatSnapshot(model: "cached-model", rows: cachedRows))

    let initial = withDependencies {
      $0.chatSnapshot = snapshotClient
    } operation: {
      ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    }
    #expect(Array(initial.transcript) == cachedRows)

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
            .object(["id": .number(1), "role": .string("user"), "content": .string("server q")]),
            .object(["id": .number(2), "role": .string("assistant"), "content": .string("server a")]),
          ]),
          "running": .bool(false),
          "info": .object(["model": .string("server-model")]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // A stray delta arrives before activate (still reconnecting, painted from cache).
    await store.send(.gatewayEvent(.messageDelta(text: "stray streamed text")))
    // It lazily appended a transient assistant row onto the cached tail.
    #expect(store.state.transcript.count == 3)

    // Activate lands → wholesale rebuild discards cached + stray rows, leaving server history.
    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    #expect(store.state.model == "server-model")
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "server q", isComplete: true),
      .message(role: .assistant, text: "server a", isComplete: true),
    ])
    // No trace of the cached or stray rows.
    #expect(!store.state.transcript.contains { if case let .message(_, t, _) = $0.kind { return t.contains("stray") || t.contains("cached") }; return false })

    await store.send(.onDisappear)
  }
}
