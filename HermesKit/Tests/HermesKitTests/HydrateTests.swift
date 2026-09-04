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
  /// The deterministic id the hydrate path assigns to the recreated live thinking row when it is
  /// the only seeded in-flight row (transcript index 0, role nil, "thinking" discriminator).
  private let resumedThinkingID = ChatRow.deterministicID(
    sequenceIndex: 0, role: nil, kindDiscriminator: "thinking"
  )

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
      $0.hasHydrated = true
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
    await store.send(.teardown)
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
    await store.send(.teardown)
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
    await store.send(.teardown)
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

    let connectCalls = LockIsolated(0)
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
      $0.hermesGateway.send = { @Sendable _, _ in throw GatewayError.disconnected }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.failure) {
      // A dropped socket is conveyed by the reconnecting status alone — no banner is raised
      // for `.disconnected` (it would otherwise linger after reconnect; see the lock/unlock
      // regression). The cached paint stays put. STATUS-ONLY: the teardown that resumed the
      // RPC with `.disconnected` also finishes the event stream, so the companion
      // `.gatewayClosed` owns the redial (with backoff) — an immediate redial here would
      // defeat it (zero-backoff storm against a crash-looping server).
      $0.status = .reconnecting
    }
    // Cache still on screen — never blanked.
    #expect(Array(store.state.transcript) == cachedRows)
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.usage == Usage(contextUsed: 7, contextMax: 200_000, contextPercent: 0))
    // No immediate redial — `.gatewayClosed`'s backoff owns reconnecting after a drop.
    #expect(connectCalls.value == 0)
    await store.send(.teardown)
  }

  // A `.disconnected` hydrate failure must not disturb the reconnect machinery: the
  // companion `.gatewayClosed` (the same teardown finishes the event stream) schedules the
  // escalating backoff, and the failure reducing alongside it must neither cancel that
  // pending tick nor dial its own zero-delay connect (ordering race on an ordinary drop:
  // the failure can land after `.gatewayClosed`).
  @Test func disconnectedHydrateFailureKeepsPendingReconnectBackoff() async {
    let connectCalls = LockIsolated(0)
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .ready
    initial.liveSessionID = "live123"
    initial.hasRequestedSession = true
    initial.hasStarted = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
    }

    // The socket died: the stream finished (backoff scheduled) AND the pending hydrate
    // resumed `.disconnected` — in that order here (the racy interleaving from a real drop).
    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.hasRequestedSession = false
      $0.reconnectAttempt = 1
    }
    await store.send(.activateResult(.failure(.disconnected)))
    #expect(connectCalls.value == 0) // no zero-delay dial from the failure

    // The backoff tick scheduled by `.gatewayClosed` survives and performs the one redial.
    await clock.advance(by: .seconds(1))
    await store.receive(\.reconnectTick)
    await waitUntil { connectCalls.value == 1 }

    await store.send(.teardown)
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

    await store.send(.teardown)
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

    await store.send(.teardown)
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
      $0.thinkingRowID = self.resumedThinkingID
      $0.transcript = [ChatRow(
        id: self.resumedThinkingID,
        kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 7, isComplete: false)
      )]
    }
    // The resumed tick continues from 7 (not 0): two more seconds → 8, 9.
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 8 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 9 }

    await store.send(.teardown)
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
      $0.thinkingRowID = self.resumedThinkingID
      $0.transcript = [ChatRow(
        id: self.resumedThinkingID,
        kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
      )]
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 1 }
    await store.receive(\.thinkingTick) { $0.thinkingSeconds = 2 }

    await store.send(.teardown)
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

    await store.send(.teardown)
  }

  // MARK: #26 — preserve in-flight thinking + tool rows across foreground hydrate

  @Test func hydrateRunningPreservesLiveThinkingAndToolRows() async {
    // Bug #26: the agent is mid-turn (thinking + streaming tool calls) when the app is
    // backgrounded. On foreground, the hydrate reports `running == true` but its payload carries
    // no reasoning/tools (SessionInflight has none). The client's own live thinking row (with
    // accumulated reasoning) and tool rows must SURVIVE the wholesale transcript replace — same
    // ids + content — and their tracking maps must still point at them so the next
    // `thinking.delta`/`tool.complete` reconciles in place. Thinking row stays last.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 1_000)
    snapshotClient.setTurnAnchor("stored123", nowDate.addingTimeInterval(-7))

    let tool1ID = uuid(101)
    let tool2ID = uuid(102)
    let thinkingID = uuid(103)
    let thinkingRow = ChatRow(
      id: thinkingID,
      kind: .thinking(reasoning: "weighing options", status: "compacting", elapsedSeconds: 4, isComplete: false)
    )
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.transcript = [
      ChatRow(id: tool1ID, kind: .tool(name: "grep", title: "Search", state: .running, detail: nil, durationS: nil)),
      ChatRow(id: tool2ID, kind: .tool(name: "read", title: "Read", state: .running, detail: nil, durationS: nil)),
      thinkingRow,
    ]
    initial.toolRowIDs = ["t1": tool1ID, "t2": tool2ID]
    initial.thinkingRowID = thinkingID

    let store = TestStore(initialState: initial) {
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
    await store.receive(\.activateResult.success)

    // The two running tool rows survived (same ids + content, original order), the thinking row
    // survived with its accumulated reasoning intact and renders LAST.
    #expect(store.state.transcript.count == 3)
    #expect(store.state.transcript[0].id == tool1ID)
    #expect(store.state.transcript[1].id == tool2ID)
    #expect(store.state.transcript.last?.id == thinkingID)
    #expect(store.state.transcript[id: thinkingID]?.kind
      == .thinking(reasoning: "weighing options", status: "compacting", elapsedSeconds: 4, isComplete: false))
    // The tracking maps still point at the preserved rows so later events reconcile in place.
    #expect(store.state.thinkingRowID == thinkingID)
    #expect(store.state.toolRowIDs == ["t1": tool1ID, "t2": tool2ID])
    // Timer continuity: the preserved row's elapsed/reasoning did NOT reset; the tick resumes at 7.
    #expect(store.state.thinkingSeconds == 7)

    await store.send(.teardown)
  }

  @Test func hydrateRunningDropsLiveReviewRowButPreservesToolAndThinkingRows() async {
    // Pins the ACCEPTED #47 limitation (and its asymmetry with #26): the running-turn
    // preservation re-appends only TOOL + THINKING rows, and `review.summary` is never
    // written to session history, so a review row that arrived mid-turn is dropped by a
    // foreground re-hydrate even while the turn still runs — while the tool/thinking rows
    // survive. If a future change starts preserving it (e.g. once the upstream
    // hermes-agent persist lands and `reconstructTranscript` maps it), update this test
    // deliberately — it exists so the behavior can't change silently.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()
    let nowDate = Date(timeIntervalSince1970: 1_000)
    snapshotClient.setTurnAnchor("stored123", nowDate.addingTimeInterval(-7))

    let toolID = uuid(301)
    let reviewID = uuid(302)
    let thinkingID = uuid(303)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.transcript = [
      ChatRow(id: toolID, kind: .tool(name: "grep", title: "Search", state: .running, detail: nil, durationS: nil)),
      ChatRow(id: reviewID, kind: .status(kind: "review", text: "💾 Self-improvement review: noted.")),
      ChatRow(id: thinkingID, kind: .thinking(reasoning: "weighing", status: nil, elapsedSeconds: 4, isComplete: false)),
    ]
    initial.toolRowIDs = ["t1": toolID]
    initial.thinkingRowID = thinkingID

    let store = TestStore(initialState: initial) {
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
    await store.receive(\.activateResult.success)

    // Tool + thinking rows survived (#26); the ephemeral review row is gone.
    #expect(store.state.transcript.map(\.id) == [toolID, thinkingID])
    #expect(store.state.transcript[id: reviewID] == nil)
    #expect(store.state.toolRowIDs == ["t1": toolID])
    #expect(store.state.thinkingRowID == thinkingID)

    await store.send(.teardown)
  }

  @Test func hydrateNotRunningWipesLiveThinkingAndToolRows() async {
    // A COMPLETED turn (`running == false`) keeps the strict server-wins behavior: the prior
    // live thinking/tool rows are GONE and their tracking ids reset — no live rows leak into a
    // finished transcript.
    let snapshotClient = ChatSnapshotClient.inMemory()
    let clock = TestClock()

    let tool1ID = uuid(201)
    let thinkingID = uuid(202)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.transcript = [
      ChatRow(id: tool1ID, kind: .tool(name: "grep", title: "Search", state: .running, detail: nil, durationS: nil)),
      ChatRow(id: thinkingID, kind: .thinking(reasoning: "still thinking", status: nil, elapsedSeconds: 2, isComplete: false)),
    ]
    initial.toolRowIDs = ["t1": tool1ID]
    initial.thinkingRowID = thinkingID
    initial.streamingRowID = uuid(203)

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0.chatSnapshot = snapshotClient
      $0.hermesGateway.send = { @Sendable _, _ in Self.activateResponse(running: false) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)

    // Wholesale replace: empty server history → empty transcript; live rows discarded.
    #expect(store.state.transcript.isEmpty)
    #expect(store.state.thinkingRowID == nil)
    #expect(store.state.toolRowIDs.isEmpty)
    #expect(store.state.streamingRowID == nil)

    await store.send(.teardown)
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

    await store.send(.teardown)
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

  // A connected-but-never-prompted chat (the regular-width detail seat, #80) has a key from
  // its `session.create` handshake and nothing to cache — the server creates the DB row on
  // the first prompt, so a flush of the teardown chain would leave an empty entry for a
  // session the list never shows.
  @Test func persistNowSkipsAnUnpromptedNewChat() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    var initial = ChatFeature.State(connection: conn, composerText: "half-typed", status: .ready)
    initial.liveSessionID = "live-new"
    initial.storedSessionID = "stored-new"

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 321))
      $0.chatSnapshot = snapshotClient
    }

    await store.send(.persistNow)
    #expect(snapshotClient.loadSnapshot("stored-new") == nil)

    // The first prompt's row makes it a real session — the same flush now writes.
    var prompted = initial
    prompted.transcript = [
      ChatRow(id: uuid(1), kind: .message(role: .user, text: "hi", isComplete: true))
    ]
    let promptedStore = TestStore(initialState: prompted) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 321))
      $0.chatSnapshot = snapshotClient
    }
    await promptedStore.send(.persistNow)
    #expect(snapshotClient.loadSnapshot("stored-new")?.rows == prompted.transcript.elements)
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

    await store.send(.teardown)
  }

  // MARK: Re-attach connect guard (keep-alive plan, Task 3)

  // Re-opening a live slot must NOT cancel-and-redial a healthy socket — the dial gap would
  // drop streamed events. `.reattached` with `status == .ready` hydrates directly against the
  // live socket (zero `connect` calls) and the socket keeps folding deltas throughout.
  @Test func reattachWithLiveSocketHydratesWithoutRedial() async {
    let connectCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .ready
    initial.liveSessionID = "live123"
    initial.hasRequestedSession = true
    initial.hasStarted = true
    initial.isSending = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
      $0.hermesGateway.send = { @Sendable method, _ in
        // The hydrate may fan out a follow-up (e.g. `session.usage`); only `session.resume`
        // matters here — and crucially, NO `connect` redial happens (asserted below).
        guard method == "session.resume" else { return .object([:]) }
        return .object([
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

    await store.send(.reattached)
    await store.receive(\.activateResult.success)

    // Hydrate landed (server authority) — but the healthy socket was never redialed.
    #expect(connectCalls.value == 0)
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.isSending == true)
    #expect(store.state.status == .ready)

    // The live socket keeps streaming: the next delta appends to the seeded in-flight row
    // (proof the fold never went through a `.gatewayClosed`/reconnect cycle).
    await store.send(.gatewayEvent(.messageDelta(text: " continues")))
    #expect(store.state.transcript.contains { row in
      if case let .message(role, text, isComplete) = row.kind {
        return role == .assistant && text == "partial answer continues" && !isComplete
      }
      return false
    })

    await store.send(.teardown)
  }

  // `.reattached` with a DEAD socket recovers exactly like `.foreground`: reset the hydrate
  // guard and reconnect — the fresh `.ready` re-hydrates.
  @Test func reattachWithDeadSocketReconnectsAndRehydrates() async {
    let connectCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .reconnecting
    // Stale-true (the dropped `.gatewayClosed` reset, same as the fast-foreground case) —
    // reattach must reset it so the fresh `.ready` actually hydrates.
    initial.hasRequestedSession = true
    initial.hasStarted = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { continuation in continuation.yield(.ready) }
      }
      $0.hermesGateway.send = { @Sendable _, _ in
        .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([]),
          "running": .bool(false),
          "info": .object(["model": .string("claude-opus-4-8")]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reattached) {
      $0.hasRequestedSession = false
    }
    await store.receive(\.gatewayEvent) {
      $0.status = .ready
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success)
    #expect(connectCalls.value == 1)
    #expect(store.state.model == "claude-opus-4-8")

    await store.send(.teardown)
  }

  // `.foreground` shares `.reattached`'s connect guard: returning to the foreground INSIDE
  // the background grace window (the socket kept streaming, `status == .ready`) must
  // hydrate directly against the live socket — NOT cancel-and-redial the healthy
  // connection the grace window just paid to keep alive (the dial gap drops events).
  @Test func foregroundWithHealthySocketHydratesWithoutRedial() async {
    let connectCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .ready
    initial.liveSessionID = "live123"
    initial.hasRequestedSession = true
    initial.hasStarted = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([]),
          "running": .bool(false),
          "info": .object(["model": .string("claude-opus-4-8")]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.foreground)
    await store.receive(\.activateResult.success)

    // Hydrate landed (server authority) — but the healthy socket was never redialed.
    #expect(connectCalls.value == 0)
    #expect(store.state.model == "claude-opus-4-8")
    #expect(store.state.status == .ready)

    await store.send(.teardown)
  }

  // Foregrounding an IDLE chat starts no background grace window, so after a suspension the
  // status can be a stale `.ready` over a HALF-OPEN socket (NAT rebind): the hydrate RPC
  // times out while `.gatewayClosed` may not fire for minutes. A single timeout is
  // indistinguishable from a live-but-slow socket, so the first one retries the hydrate over
  // the SAME socket; the SECOND consecutive timeout concludes half-open and the failure must
  // schedule the redial ITSELF — not strand the chat in `.reconnecting` with no reconnect
  // pending — and stays banner-less (transport-shaped, matching `.disconnected`).
  @Test func hydrateTimeoutOverStaleReadySocketRedials() async {
    let connectCalls = LockIsolated(0)
    let resumeCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .ready // stale: the transport underneath is half-open
    initial.liveSessionID = "live123"
    initial.hasRequestedSession = true
    initial.hasStarted = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.resume" { resumeCalls.withValue { $0 += 1 } }
        throw GatewayError.timedOut(method: method)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.foreground)
    // First timeout: retry once over the same (possibly just slow) socket — no redial yet.
    await store.receive(\.activateResult.failure) {
      $0.status = .reconnecting
      $0.hydrateRetriedAfterTimeout = true
    }
    // Second consecutive silent timeout: half-open confirmed — redial ourselves.
    await store.receive(\.activateResult.failure) {
      $0.hydrateRetriedAfterTimeout = false
      $0.hasRequestedSession = false // the fresh `.ready` must re-hydrate
    }
    await waitUntil { connectCalls.value == 1 }
    #expect(resumeCalls.value == 2) // the original hydrate + one same-socket retry
    #expect(store.state.errorBanner == nil) // transport-shaped: status conveys it, no banner

    await store.send(.teardown)
  }

  // A `session.resume` that merely responds SLOWLY (>30s: huge history, busy gateway) over a
  // socket that is alive must NOT be treated as half-open on the first timeout: the retry
  // lands over the SAME socket (no redial), so a mid-turn stream is never killed by a slow
  // hydrate.
  @Test func slowHydrateTimeoutRetriesOverSameSocketWithoutRedial() async {
    let connectCalls = LockIsolated(0)
    let resumeCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .ready
    initial.liveSessionID = "live123"
    initial.hasRequestedSession = true
    initial.hasStarted = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else { return .object([:]) }
        let attempt = resumeCalls.withValue { $0 += 1; return $0 }
        // The first attempt "takes too long" (per-request timeout fires); the retry lands.
        guard attempt > 1 else { throw GatewayError.timedOut(method: method) }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([]),
          "running": .bool(false),
          "info": .object(["model": .string("claude-opus-4-8")]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.foreground)
    await store.receive(\.activateResult.failure) {
      $0.status = .reconnecting
      $0.hydrateRetriedAfterTimeout = true
    }
    // The same-socket retry succeeds — server authority applied, retry budget reset.
    await store.receive(\.activateResult.success) {
      $0.status = .ready
      $0.hydrateRetriedAfterTimeout = false
    }
    #expect(store.state.model == "claude-opus-4-8")
    #expect(connectCalls.value == 0) // the live socket was never redialed
    #expect(store.state.errorBanner == nil)

    await store.send(.teardown)
  }

  // A hydrate failing `.timedOut` while the re-auth pause is up must do NOTHING: a redial
  // would mint (and waste) a single-use ws-ticket against a dead gated session —
  // `.resumeAfterReauth` owns the reconnect. Exhaustive: any effect fails this.
  @Test func hydrateTimeoutDuringReauthPauseDoesNotRedial() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .reconnecting // `.authExpired` already flipped it
    initial.liveSessionID = "live123"
    initial.hasStarted = true
    initial.awaitingReauth = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    }

    await store.send(.activateResult(.failure(.timedOut(method: "session.resume"))))
  }

  // A pending hydrate must die with a DELIBERATE socket-only teardown (background grace
  // expiry): the socket cancellation resumes the RPC, and its stale `.activateResult` must
  // NOT reduce afterwards — it would redial while the app is backgrounded, undoing the clean
  // disconnect (and wasting a single-use ws-ticket in gated mode).
  @Test func teardownSocketOnlyCancelsPendingHydrate() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .ready
    initial.liveSessionID = "live123"
    initial.hasRequestedSession = true
    initial.hasStarted = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in
        // Hang until cancelled (the empty stream never yields; cancellation ends the
        // iteration), then surface the drop the way the live client would.
        for await _ in AsyncStream<Never> { _ in } {}
        throw GatewayError.disconnected
      }
    }

    await store.send(.foreground) // hydrate now in flight, hanging
    await store.send(.teardownSocketOnly) {
      $0.status = .reconnecting
      $0.hasRequestedSession = false
    }
    // Exhaustive: if the cancelled hydrate's `.activateResult` still reduced (or the effect
    // outlived the teardown), `finish()` would fail.
    await store.finish()
  }

  // `.reattached` / `.foreground` with a healthy socket but a STILL-UNRESOLVED session id
  // (`session.create` in flight on that same socket) is a strict no-op — the pending
  // create lands on its own; hydrating (or redialing) here would race it. Exhaustive: any
  // effect or state change fails this.
  @Test func reattachReadyWithUnresolvedSessionIsNoOp() async {
    var initial = ChatFeature.State(connection: conn)
    initial.status = .ready
    initial.hasStarted = true
    initial.hasRequestedSession = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    }

    await store.send(.reattached)
    await store.send(.foreground)
  }

  // The view's `.task` fires on every appearance; once the slot has started (initial
  // connect done), a re-appearance must be a strict no-op — `AppFeature`'s `.reattached`
  // owns the re-open flow. Exhaustive: any effect or state change fails this.
  @Test func taskAfterInitialConnectIsNoOp() async {
    let connectCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "stored123")
    initial.status = .ready
    initial.hasStarted = true

    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.connect = { @Sendable _, _ in
        connectCalls.withValue { $0 += 1 }
        return AsyncStream { _ in }
      }
    }

    await store.send(.task)
    #expect(connectCalls.value == 0)
  }

  // MARK: Stable in-flight row identity across repeated hydrates (review finding #4)

  // A running turn's seeded in-flight rows (echoed user, eager streaming assistant, recreated
  // live thinking row) must carry DETERMINISTIC, position-derived ids — not fresh `uuid()` —
  // so repeated hydrates of the SAME running turn yield byte-identical ids. Otherwise the
  // unchanged in-flight content diffs as delete/insert (identity churn) instead of a stable
  // update, defeating the deterministic-identity goal. This hydrates twice and asserts the row
  // ids are identical across both hydrates.
  @Test func repeatedHydrateOfRunningTurnKeepsStableInflightIDs() async {
    let snapshotClient = ChatSnapshotClient.inMemory()
    // `.incrementing` would hand out a fresh uuid on every seeded row — the very churn this
    // test guards against. With the deterministic fix the ids must NOT depend on it.
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = snapshotClient
      // Reconnect yields a single `.ready` then idles, so `.foreground` drives a second hydrate.
      $0.hermesGateway.connect = { @Sendable _, _ in
        AsyncStream { continuation in continuation.yield(.ready) }
      }
      $0.hermesGateway.send = { @Sendable _, _ in
        .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("user"), "content": .string("prior question")]),
            .object(["id": .number(2), "role": .string("assistant"), "content": .string("prior answer")]),
          ]),
          "running": .bool(true),
          "info": .object(["model": .string("claude-opus-4-8")]),
          "inflight": .object([
            "user": .string("the live question"),
            "assistant": .string("partial answer"),
            "streaming": .bool(true),
          ]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // First hydrate.
    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    let firstIDs = store.state.transcript.ids
    let firstStreamingID = store.state.streamingRowID

    // Second hydrate of the SAME running turn (a foreground re-resume; the socket is
    // healthy — `status == .ready` — so `.foreground` hydrates directly, no redial).
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    let secondIDs = store.state.transcript.ids

    // Byte-identical row ids across both hydrates — no identity churn.
    #expect(Array(firstIDs) == Array(secondIDs))
    // The streaming row id is stable too, so a delta still reuses the same seeded row.
    #expect(store.state.streamingRowID == firstStreamingID)
    #expect(store.state.streamingRowID != nil)
    // Sanity: the seeded in-flight rows are present (echoed user + eager streaming assistant).
    #expect(store.state.transcript.contains { row in
      if case let .message(role, text, isComplete) = row.kind {
        return role == .user && text == "the live question" && isComplete
      }
      return false
    })
    #expect(store.state.transcript.contains { row in
      if case let .message(role, text, isComplete) = row.kind {
        return role == .assistant && text == "partial answer" && !isComplete
      }
      return false
    })

    await store.send(.teardown)
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

    await store.send(.teardown)
  }
}
