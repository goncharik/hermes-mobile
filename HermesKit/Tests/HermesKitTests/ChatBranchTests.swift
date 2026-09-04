import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Branch-in-new-chat (#34): `.branchFromMessage(id:)` fires a one-shot desktop-parity
/// `session.create` seeded with ONLY that assistant message + `parent_session_id`, then
/// emits `Delegate.branchCreated` for `AppFeature`'s slot-replacement open. Guards:
/// completed assistant row with text, no running turn, a session to parent to, and a
/// double-fire in-flight flag.
@MainActor
struct ChatBranchTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// A ready chat holding one completed assistant message to branch from.
  private func branchableState(text: String = "# The answer\n\nUse *plan B*.") -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn, status: .ready)
    state.liveSessionID = "live"
    state.storedSessionID = "stored123"
    state.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: text, isComplete: true))
    ]
    return state
  }

  // MARK: Success

  @Test func branchSendsSeededCreateAndEmitsDelegate() async {
    let sent = LockIsolated<(method: String, params: JSONValue)?>(nil)
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        sent.setValue((method, params))
        return .object([
          "session_id": .string("branch-live"),
          "stored_session_id": .string("branch-stored"),
        ])
      }
    }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.isBranching = true
      $0.pendingBranchSeed = .init(
        text: "# The answer\n\nUse *plan B*.", parentSessionID: "stored123"
      )
    }
    await store.receive(\.branchResult.success) {
      $0.isBranching = false
      $0.pendingBranchSeed = nil
    }
    // The delegate carries the FULL handle — the stored id is the branch's list/marker
    // identity, and the live id is what the replacement chat attaches to (the branch has
    // no DB row until its first prompt, so it can't be resumed by stored id) — plus the
    // SEED the replacement chat keeps so an orphan-reaped branch can be rebuilt.
    await store.receive(
      \.delegate.branchCreated,
      ChatFeature.Action.Delegate.BranchCreation(
        handle: SessionHandle(sessionID: "branch-live", storedSessionID: "branch-stored"),
        seed: .init(text: "# The answer\n\nUse *plan B*.", parentSessionID: "stored123")
      )
    )

    #expect(sent.value?.method == "session.create")
    let params = sent.value?.params
    // Single-message seed: only the tapped assistant message, raw Markdown intact.
    guard case let .array(messages)? = params?["messages"] else {
      Issue.record("missing messages seed")
      return
    }
    #expect(messages.count == 1)
    #expect(messages.first?["role"]?.stringValue == "assistant")
    #expect(messages.first?["content"]?.stringValue == "# The answer\n\nUse *plan B*.")
    #expect(params?["parent_session_id"]?.stringValue == "stored123")
    // No title (server auto-names on first submit), no source, and the default/nil
    // profile is OMITTED — byte-identical to the plain create otherwise.
    #expect(params?["title"] == nil)
    #expect(params?["source"] == nil)
    #expect(params?["profile"] == nil)
    #expect(store.state.errorBanner == nil)
  }

  @Test func branchThreadsSelectedProfile() async {
    let sent = LockIsolated<JSONValue?>(nil)
    var initial = ChatFeature.State(connection: conn, profileName: "work", status: .ready)
    initial.liveSessionID = "live"
    initial.storedSessionID = "stored123"
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, params in
        sent.setValue(params)
        return .object([
          "session_id": .string("branch-live"),
          "stored_session_id": .string("branch-stored"),
        ])
      }
    }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.isBranching = true
      $0.pendingBranchSeed = .init(text: "answer", parentSessionID: "stored123")
    }
    await store.receive(\.branchResult.success) {
      $0.isBranching = false
      $0.pendingBranchSeed = nil
    }
    await store.receive(
      \.delegate.branchCreated,
      ChatFeature.Action.Delegate.BranchCreation(
        handle: SessionHandle(sessionID: "branch-live", storedSessionID: "branch-stored"),
        seed: .init(text: "answer", parentSessionID: "stored123")
      )
    )

    // A non-default profile is threaded (same convention as create/resume), and the
    // parent link is the PERSISTED id (the one REST list rows carry, so nesting works).
    #expect(sent.value?["profile"]?.stringValue == "work")
    #expect(sent.value?["parent_session_id"]?.stringValue == "stored123")
  }

  // MARK: Failure

  @Test func branchFailureSetsErrorBanner() async {
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        throw GatewayError.server("boom")
      }
    }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.isBranching = true
      $0.pendingBranchSeed = .init(
        text: "# The answer\n\nUse *plan B*.", parentSessionID: "stored123"
      )
    }
    // Failure surfaces — never a swallowed `try?` — and clears the in-flight flag (and
    // the stashed seed) so the user can retry.
    await store.receive(\.branchResult.failure) {
      $0.isBranching = false
      $0.pendingBranchSeed = nil
      $0.errorBanner = "Couldn’t branch the chat: boom"
    }
  }

  @Test func malformedCreateResultIsAFailure() async {
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in .string("not an object") }
    }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.isBranching = true
      $0.pendingBranchSeed = .init(
        text: "# The answer\n\nUse *plan B*.", parentSessionID: "stored123"
      )
    }
    await store.receive(\.branchResult.failure) {
      $0.isBranching = false
      $0.pendingBranchSeed = nil
      $0.errorBanner = "Couldn’t branch the chat: Malformed session.create result"
    }
  }

  @Test func nonGatewayErrorSurfacesAsDisconnected() async {
    // A throw that isn't a `GatewayError` (e.g. a transport-layer Cocoa error) maps to
    // the generic `.disconnected` failure — surfaced, never swallowed.
    let store = TestStore(initialState: branchableState()) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in throw CocoaError(.fileNoSuchFile) }
    }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.isBranching = true
      $0.pendingBranchSeed = .init(
        text: "# The answer\n\nUse *plan B*.", parentSessionID: "stored123"
      )
    }
    await store.receive(\.branchResult.failure) {
      $0.isBranching = false
      $0.pendingBranchSeed = nil
      $0.errorBanner = "Couldn’t branch the chat: \(GatewayError.disconnected.message)"
    }
  }

  // MARK: Guards

  @Test func runningTurnBlocksBranchWithBanner() async {
    var initial = branchableState()
    initial.isSending = true
    let store = TestStore(initialState: initial) { ChatFeature() }
    // No dependency override needed — the guard must fire BEFORE any RPC.

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "Stop the current turn before branching."
    }
  }

  @Test func emptyTextRowIsANoOp() async {
    let store = TestStore(initialState: branchableState(text: "   \n  ")) { ChatFeature() }
    await store.send(.branchFromMessage(id: uuid(0))) // whitespace-only → no RPC, no state change
  }

  @Test func streamingUserAndUnknownRowsAreNoOps() async {
    var initial = branchableState()
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "half an ans", isComplete: false)),
      ChatRow(id: uuid(1), kind: .message(role: .user, text: "my prompt", isComplete: true)),
      ChatRow(id: uuid(2), kind: .status(kind: "approval", text: "Approved")),
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.branchFromMessage(id: uuid(0))) // still streaming
    await store.send(.branchFromMessage(id: uuid(1))) // user message
    await store.send(.branchFromMessage(id: uuid(2))) // not a message row
    await store.send(.branchFromMessage(id: uuid(9))) // no such row
  }

  @Test func secondTapWhileBranchInFlightIsANoOp() async {
    var initial = branchableState()
    initial.isBranching = true // first tap's RPC still outstanding
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.branchFromMessage(id: uuid(0))) // double-fire guard → no second RPC
  }

  @Test func missingStoredIDShowsBannerNotSilentNoOp() async {
    var initial = ChatFeature.State(connection: conn) // no stored id yet
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() }

    // Nothing persisted to parent to → no RPC, but honest feedback (the view normally
    // disables the button via `canBranch`; a race must not be a silent no-op).
    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
  }

  @Test func liveOnlySessionCannotBranch() async {
    // Old-agent shape: `session.create` returned no stored id. A live-only handle would
    // stamp a `parent_session_id` no REST list row ever matches (the branch could never
    // nest), so branching requires the persisted id — banner, no RPC.
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "answer", isComplete: true))
    ]
    #expect(initial.canBranch == false)
    let store = TestStore(initialState: initial) { ChatFeature() }

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
  }

  // MARK: Opening the branch (attach by live id — no DB row until the first prompt)

  /// A chat primed from the branch create response (`attachLiveSessionID`) must hydrate
  /// via `session.activate` with the LIVE id — `session.resume` by stored id would 4007
  /// (the server creates the branch's DB row lazily on the first prompt) and the
  /// not-found self-heal would strand the user in an unrelated fresh session.
  @Test func branchPrimedChatAttachesByLiveIDOnReady() async {
    let sent = LockIsolated<(method: String, params: JSONValue)?>(nil)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored")
    initial.attachLiveSessionID = "branch-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        // The slash catalog fetch (#36) fires on every hydrate; it is orthogonal to the
        // branch RPC under test — answer it benignly and don't record it.
        if method == "commands.catalog" { return .object([:]) }
        sent.setValue((method, params))
        // `session.activate` live payload: stored id under `session_key`, seeded history.
        return .object([
          "session_id": .string("branch-live"),
          "session_key": .string("branch-stored"),
          "messages": .array([.object([
            "id": .number(1), "role": .string("assistant"), "text": .string("seeded answer"),
          ])]),
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
      $0.liveSessionID = "branch-live"
      $0.storedSessionID = "branch-stored"
      $0.status = .ready
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
      $0.transcript = [ChatRow(
        id: ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"),
        kind: .message(role: .assistant, text: "seeded answer", isComplete: true)
      )]
      // The branch is still unpersisted — a later foreground must attach again.
    }
    #expect(sent.value?.method == "session.activate")
    #expect(sent.value?.params == .object(["session_id": .string("branch-live")]))
    #expect(store.state.attachLiveSessionID == "branch-live")
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
  }

  /// A foreground re-hydrate of a still-unpersisted branch re-attaches by live id over
  /// the healthy socket (never `session.resume` by the row-less stored id).
  @Test func foregroundRehydratesUnpersistedBranchViaActivate() async {
    let methods = LockIsolated<[String]>([])
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.liveSessionID = "branch-live"
    initial.hasStarted = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        // Orthogonal slash catalog fetch (#36) — answer benignly, don't record.
        if method == "commands.catalog" { return .object([:]) }
        methods.withValue { $0.append(method) }
        return .object([
          "session_id": .string("branch-live"),
          "session_key": .string("branch-stored"),
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

    await store.send(.foreground) {
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.success) {
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
    }
    #expect(methods.value == ["session.activate"])
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
  }

  /// The first `message.start` means the first prompt landed — the server persisted the
  /// branch's DB row, so the attach bookkeeping (live-id redirect, client-held seed, and
  /// the replay budget) clears and subsequent hydrates use the standard `session.resume`
  /// by stored id.
  @Test func messageStartClearsUnpersistedBranchBookkeeping() async {
    let clock = TestClock()
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.hasReplayedBranchSeed = true
    initial.liveSessionID = "branch-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.date = .constant(.init(timeIntervalSince1970: 0))
    }

    await store.send(.gatewayEvent(.messageStart)) {
      $0.isSending = true
      $0.attachLiveSessionID = nil
      $0.branchSeed = nil
      $0.hasReplayedBranchSeed = false
      $0.transcript = [ChatRow(
        id: uuid(0), kind: .thinking(reasoning: "", status: nil, elapsedSeconds: 0, isComplete: false)
      )]
      $0.thinkingRowID = uuid(0)
    }
    await store.receive(\.delegate.runningChanged)
    await store.send(.teardown)
  }

  // MARK: Orphan-reap recovery (the server reaps a detached, never-prompted branch ~20s
  // after its socket drops — the client-held seed rebuilds it)

  /// "Session not found" on the attach while the client still holds the seed replays the
  /// SEEDED `session.create` (same messages + parent_session_id wire shape as the
  /// original branch), then re-attaches to the fresh live session — the branch's context
  /// AND nesting survive the reap, with no banner because nothing was lost.
  @Test func attachNotFoundReplaysSeededCreateAndReattaches() async {
    let calls = LockIsolated<[(method: String, params: JSONValue)]>([])
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        // Orthogonal slash catalog fetch (#36) — answer benignly, don't record.
        if method == "commands.catalog" { return .object([:]) }
        calls.withValue { $0.append((method, params)) }
        switch method {
        case "session.resume":
          // Finding-1 recovery probe: the branch truly has no DB row (the reap this
          // test exercises — the probe confirms it before any seed replay happens).
          throw GatewayError.server("session not found")
        case "session.create":
          return .object([
            "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
          ])
        default: // the re-attach
          return .object([
            "session_id": .string("fresh-live"),
            "session_key": .string("fresh-stored"),
            "messages": .array([.object([
              "id": .number(1), "role": .string("assistant"), "text": .string("seeded answer"),
            ])]),
            "running": .bool(false),
            "info": .object([
              "model": .string("claude-opus-4-8"),
              "usage": .object([
                "context_used": .number(0), "context_max": .number(200_000),
                "context_percent": .number(0),
              ]),
            ]),
          ])
        }
      }
    }

    // Finding-1 probe first — `session.resume` by the branch's STORED id (never the
    // live `attachLiveSessionID` `session.activate` just 404'd on — review iteration 2
    // finding a), before ever discarding real history. `liveSessionID` was already nil
    // (a fresh unpersisted branch never attached yet), so the recovery-start nil is a
    // no-op here; `sendBlockedWhileBranchRecoveryProbeOutstanding` covers the case where
    // it actually changes.
    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.status = .reconnecting
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
      $0.hasReplayedBranchSeed = true
    }
    // The replayed create rebinds the fresh handle and RE-ARMS the attach bookkeeping —
    // the rebuilt session is again unpersisted, and the seed stays for a further reap.
    await store.receive(\.branchReplayResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.attachLiveSessionID = "fresh-live"
    }
    await store.receive(\.activateResult.success) {
      $0.status = .ready
      $0.hasHydrated = true
      $0.hasReplayedBranchSeed = false // attach landed: the replay budget resets
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
      $0.transcript = [ChatRow(
        id: ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"),
        kind: .message(role: .assistant, text: "seeded answer", isComplete: true)
      )]
    }
    await store.receive(\.delegate.runningChanged)

    // Probe first (finding 1, confirms no DB row), THEN the replay carries the SEED —
    // identical wire shape to the original branch create.
    #expect(calls.value.map(\.method) == ["session.resume", "session.create", "session.activate"])
    // The probe must be issued with the STORED id, not the live one `session.activate`
    // 404'd on (review iteration 2 finding a — probing with the live id always 404s).
    #expect(calls.value[0].params["session_id"]?.stringValue == "branch-stored")
    let createParams = calls.value[1].params
    guard case let .array(messages)? = createParams["messages"] else {
      Issue.record("replayed create missing the seed messages")
      return
    }
    #expect(messages.first?["content"]?.stringValue == "seeded answer")
    #expect(createParams["parent_session_id"]?.stringValue == "parent-1")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
    await store.send(.teardown)
  }

  /// A failed replay (the seeded recreate itself errors) degrades to a fresh session so
  /// the chat still works — but NEVER silently: the on-screen seed is no longer in the
  /// session's context, so a banner says so before the user asks follow-ups about it.
  @Test func replayFailureDegradesToFreshCreateWithBanner() async {
    let createCount = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.resume" {
          // Finding-1 probe: the branch truly has no DB row.
          throw GatewayError.server("session not found")
        }
        if method == "session.create" {
          let n = createCount.withValue { $0 += 1; return $0 }
          if n == 1 { throw GatewayError.server("boom") } // the seeded replay
        }
        return .object([
          "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
        ])
      }
    }

    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.status = .reconnecting
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
      $0.hasReplayedBranchSeed = true
    }
    await store.receive(\.branchReplayResult.failure) {
      $0.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
      $0.branchSeed = nil
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.status = .ready
      $0.hasHydrated = true
    }
    // The banner survives the fresh create — the degrade is honest, never silent.
    #expect(store.state.errorBanner == "Couldn’t restore the branch — starting a fresh chat.")
  }

  /// A second "not found" after the one replay (the rebuilt session vanished again
  /// before its attach) must NOT loop — the one-shot budget degrades it to the bannered
  /// fresh create, clearing every piece of branch bookkeeping.
  @Test func secondNotFoundAfterReplayDegradesInsteadOfLooping() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "fresh-stored", status: .ready)
    initial.attachLiveSessionID = "fresh-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.hasReplayedBranchSeed = true // the one replay already ran this hydrate
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in
        .object(["session_id": .string("plain-live"), "stored_session_id": .string("plain-stored")])
      }
    }

    await store.send(.activateResult(.failure(.server("session not found")))) {
      $0.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
      $0.branchSeed = nil
      $0.status = .reconnecting
      $0.liveSessionID = nil
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "plain-live"
      $0.storedSessionID = "plain-stored"
      $0.status = .ready
      $0.hasHydrated = true
    }
  }

  /// An unpersisted branch primed WITHOUT a seed (defensive — the parent always carries
  /// one) still degrades to the fresh create, but now with the honest banner instead of
  /// the old silent swap.
  @Test func attachNotFoundWithoutSeedDegradesWithBanner() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.resume" {
          // Finding-1 probe: no seed to rebuild anyway, and the probe finds nothing.
          throw GatewayError.server("session not found")
        }
        return .object(["session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored")])
      }
    }

    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
      $0.status = .reconnecting
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.status = .ready
      $0.hasHydrated = true
    }
  }

  /// An old agent without `session.activate` (`-32601`) can't attach the seeded session
  /// at all (it ignored the seed params anyway) — degrade to the fresh create with the
  /// same honest banner, never a seed replay (the create would change nothing).
  @Test func attachUnknownMethodDegradesWithBannerNotReplay() async {
    let methods = LockIsolated<[String]>([])
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        // Orthogonal slash catalog fetch (#36) — answer benignly, don't record.
        if method == "commands.catalog" { return .object([:]) }
        methods.withValue { $0.append(method) }
        // The degrade create is BARE — no seed fields against an agent this old.
        #expect(params["messages"] == nil)
        #expect(params["parent_session_id"] == nil)
        return .object([
          "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
        ])
      }
    }

    await store.send(.activateResult(.failure(.server("unknown method: session.activate")))) {
      $0.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
      $0.branchSeed = nil
      $0.status = .reconnecting
      $0.liveSessionID = nil
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.status = .ready
      $0.hasHydrated = true
    }
    #expect(methods.value == ["session.create"])
  }

  // MARK: Reap recovery on the submit path (heal recreates the SEEDED session)

  /// A prompt submitted into a reaped unpersisted branch heals by recreating the SEEDED
  /// session (messages + parent_session_id — not a bare create), then replays the
  /// submit — the on-screen seeded context and the parent nesting both survive, and the
  /// healed session stays in attach-by-live-id mode until `message.start` persists it.
  @Test func submitHealRecreatesSeededSessionAndKeepsAttachMode() async {
    let calls = LockIsolated<[(method: String, params: JSONValue)]>([])
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.liveSessionID = "branch-live"
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.composerText = "follow-up"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append((method, params)) }
        switch method {
        case "prompt.submit" where params["session_id"]?.stringValue == "branch-live":
          throw GatewayError.server("session not found") // the reaped live id
        case "session.create":
          return .object([
            "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
          ])
        default:
          return .object(["status": .string("streaming")])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [ChatRow(
        id: self.uuid(0), kind: .message(role: .user, text: "follow-up", isComplete: true)
      )]
      $0.composerText = ""
      $0.isSending = true
    }
    // The heal's fresh ids KEEP the attach-by-live-id bookkeeping — the recreated
    // session has no DB row until the replayed submit's `message.start` — and the seed.
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.attachLiveSessionID = "fresh-live"
    }
    await store.finish()

    // The heal's create carried the seed + parent link, and the submit was replayed
    // against the fresh live id.
    #expect(calls.value.map(\.method) == ["prompt.submit", "session.create", "prompt.submit"])
    let createParams = calls.value[1].params
    guard case let .array(messages)? = createParams["messages"] else {
      Issue.record("heal create missing the seed messages")
      return
    }
    #expect(messages.first?["content"]?.stringValue == "seeded answer")
    #expect(createParams["parent_session_id"]?.stringValue == "parent-1")
    #expect(calls.value[2].params["session_id"]?.stringValue == "fresh-live")
    #expect(calls.value[2].params["text"]?.stringValue == "follow-up")
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
  }

  // MARK: Branching from an unpersisted branch (blocked — the parent link would dangle)

  /// An unpersisted branch's `session_key` has no DB row: a grandchild stamped with it
  /// would never nest, and the slot replacement would tear the middle branch down for
  /// the server to reap (its row never lands). `canBranch` gates the button off and the
  /// reducer re-guards with the honest banner.
  @Test func unpersistedBranchCannotBranchAgain() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.liveSessionID = "branch-live"
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "seeded answer", isComplete: true))
    ]
    #expect(initial.canBranch == false)
    let store = TestStore(initialState: initial) { ChatFeature() }
    // No dependency override — the guard must fire BEFORE any RPC.

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
  }

  // MARK: Interrupted replay (transport failure mid-replay — the seed must survive)

  /// A socket drop while the seeded replay create is in flight is NOT a server verdict:
  /// the client-held seed is the only copy of the branch, so the transient failure KEEPS
  /// it (and refunds the one-shot replay budget) instead of destroying it — and never
  /// fires a `createSession` into the dead socket (which would fail `.notConnected` and
  /// overwrite the banner). Mirrors `.sessionResult(.failure(.disconnected))`:
  /// status-only.
  @Test func transientReplayFailureKeepsSeedAndFiresNoDeadSocketCreate() async {
    let calls = LockIsolated<[String]>([])
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "seeded answer", isComplete: true))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        throw GatewayError.disconnected // socket died under the finding-1 probe
      }
    }

    // Finding-1 probe first — `session.resume` by the STORED id — and the dead socket
    // takes THAT down instead of ever reaching a seeded replay create.
    await store.send(.activateResult(.failure(.server("session not found"))))
    // Structural fix: there is no budget to refund — a transient probe failure simply
    // re-arms status-only, so a later not-found re-probes, never skipping straight to a
    // seed replay over a possibly-persisted turn.
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.status = .reconnecting
    }
    // ONLY the interrupted probe hit the wire — no replay AND no bare create chased the
    // dead socket, and the seed survives for the post-reconnect hydrate to rebuild from.
    #expect(calls.value == ["session.resume"])
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
    #expect(store.state.errorBanner == nil)
    // `storedSessionID` is still standing (from the OLD, now-dead pre-reap session)
    // throughout this window — a standing `branchSeed` (and the still-set
    // `attachLiveSessionID`, since the probe never got far enough to touch it) must
    // still block branching, or a grandchild would stamp the dead id as its parent and
    // dangle forever once a later replay's fresh `session.create` lands (the finding
    // this test guards against).
    #expect(store.state.storedSessionID == "branch-stored")
    #expect(store.state.canBranch == false)
    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
    // The guard fired before any RPC — no stray branch create chased the dead socket.
    #expect(calls.value == ["session.resume"])
  }

  /// The full interrupted-replay sequence: replay create dies with the socket, the
  /// stream closes, and the reconnected `.ready` hydrates by the row-less stored id —
  /// whose "session not found" must REPLAY the kept seed (keyed on the durable
  /// `branchSeed`, not the already-consumed `attachLiveSessionID`), never silently swap
  /// in a bare session under the still-painted seed.
  @Test func interruptedReplayRecoversSeedAfterReconnect() async {
    let calls = LockIsolated<[(method: String, params: JSONValue)]>([])
    let createCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.liveSessionID = "branch-live"
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        // Orthogonal slash catalog fetch (#36) — answer benignly, don't record.
        if method == "commands.catalog" { return .object([:]) }
        calls.withValue { $0.append((method, params)) }
        switch method {
        case "session.resume":
          // The finding-1 probe (by the STORED id) and later the row-less stored-id
          // hydrate after reconnect — both genuinely 404: the branch has no DB row.
          throw GatewayError.server("session not found")
        case "session.create":
          let n = createCalls.withValue { $0 += 1; return $0 }
          if n == 1 { throw GatewayError.disconnected } // the first replay dies with the socket
          return .object([
            "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
          ])
        default: // the re-attach
          return .object([
            "session_id": .string("fresh-live"),
            "session_key": .string("fresh-stored"),
            "messages": .array([.object([
              "id": .number(1), "role": .string("assistant"), "text": .string("seeded answer"),
            ])]),
            "running": .bool(false),
            "info": .object([
              "model": .string("claude-opus-4-8"),
              "usage": .object([
                "context_used": .number(0), "context_max": .number(200_000),
                "context_percent": .number(0),
              ]),
            ]),
          ])
        }
      }
    }

    // Finding-1 probe first — `session.resume` by the branch's STORED id `storedSessionID`
    // (never the live id `session.activate` 404'd on) — confirms the branch truly has no
    // row before the seed replay ever fires. `liveSessionID` was already live-bound
    // ("branch-live") before this — the recovery-start nil (finding 1) fires here.
    await store.send(.activateResult(.failure(.server("session not found")))) {
      $0.liveSessionID = nil
    }
    // The probe's own not-found triggers the replay; the socket dies under IT.
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.status = .reconnecting
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
      $0.hasReplayedBranchSeed = true
    }
    await store.receive(\.branchReplayResult.failure) {
      $0.hasReplayedBranchSeed = false // refunded: the replay reached no server verdict
    }
    // The stream closes (companion of the drop) and schedules the backoff redial.
    await store.send(.gatewayClosed) {
      $0.hasRequestedSession = false
      $0.reconnectAttempt = 1
    }
    // Reconnected: `attachLiveSessionID` is nil (the probe already consumed it), so the
    // fresh `.ready` hydrates by the row-less stored id, which 4007s too — and recovery,
    // keyed on the DURABLE seed with the attach redirect long gone, replays the seeded
    // create (no re-probe: attachLiveSessionID is nil, so the probe gate doesn't apply).
    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.reconnectAttempt = 0
      $0.hasRequestedSession = true
    }
    await store.receive(\.activateResult.failure) {
      $0.status = .reconnecting
      $0.hasReplayedBranchSeed = true
    }
    await store.receive(\.branchReplayResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.attachLiveSessionID = "fresh-live"
    }
    await store.receive(\.activateResult.success) {
      $0.status = .ready
      $0.hasHydrated = true
      $0.hasReplayedBranchSeed = false
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
      $0.transcript = [ChatRow(
        id: ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"),
        kind: .message(role: .assistant, text: "seeded answer", isComplete: true)
      )]
    }
    await store.receive(\.delegate.runningChanged)

    // Probe → interrupted replay → resume-not-found (the row-less hydrate) → SEEDED
    // replay → attach: never a bare create.
    #expect(calls.value.map(\.method) == [
      "session.resume", "session.create", "session.resume", "session.create", "session.activate",
    ])
    #expect(calls.value[0].params["session_id"]?.stringValue == "branch-stored")
    let replayParams = calls.value[3].params
    guard case let .array(messages)? = replayParams["messages"] else {
      Issue.record("post-reconnect replay missing the seed messages")
      return
    }
    #expect(messages.first?["content"]?.stringValue == "seeded answer")
    #expect(replayParams["parent_session_id"]?.stringValue == "parent-1")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
    await store.send(.teardown)
  }

  /// A replay `.timedOut` may be the ONLY symptom of a half-open socket (no
  /// `.gatewayClosed` for minutes) — keep the seed, refund the budget, and redial
  /// ourselves so the chat isn't stranded in `.reconnecting` with the seed parked.
  @Test func replayTimeoutKeepsSeedAndRedials() async {
    let continuation = LockIsolated<AsyncStream<GatewayEvent>.Continuation?>(nil)
    let dialed = LockIsolated(false)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "session.resume" {
          throw GatewayError.server("session not found") // finding-1 probe: no DB row
        }
        throw GatewayError.timedOut(method: "session.create") // the seeded replay itself
      }
      $0.hermesGateway.connect = { @Sendable _, _ in
        dialed.setValue(true)
        let (stream, cont) = AsyncStream<GatewayEvent>.makeStream()
        continuation.setValue(cont) // hold the socket open — the fresh `.ready` is live's
        return stream
      }
    }

    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.status = .reconnecting
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
      $0.hasReplayedBranchSeed = true
    }
    await store.receive(\.branchReplayResult.failure) {
      $0.hasReplayedBranchSeed = false
      $0.hasRequestedSession = false // the fresh `.ready` must re-run the recovery
    }
    #expect(dialed.value)
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
    #expect(store.state.errorBanner == nil)
    await store.send(.teardown)
  }

  /// The stale-seed degrade with the attach redirect already consumed (interrupted
  /// replay whose budget was genuinely spent): a not-found must still banner + drop the
  /// seed — never the old silent bare create — so the seed can't dangle on the plain
  /// session and later mis-arm attach-by-live-id through `liveSessionIDRefreshed`.
  @Test func spentBudgetNotFoundWithoutAttachModeDegradesHonestly() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.hasReplayedBranchSeed = true // budget spent; attachLiveSessionID already nil
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, params in
        // The degrade create is BARE — the seed must not leak into the plain session.
        #expect(params["messages"] == nil)
        #expect(params["parent_session_id"] == nil)
        return .object([
          "session_id": .string("plain-live"), "stored_session_id": .string("plain-stored"),
        ])
      }
    }

    await store.send(.activateResult(.failure(.server("session not found")))) {
      $0.errorBanner = "Couldn’t restore the branch — starting a fresh chat."
      $0.branchSeed = nil
      $0.status = .reconnecting
      $0.liveSessionID = nil
      $0.hasRequestedSession = true
    }
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "plain-live"
      $0.storedSessionID = "plain-stored"
      $0.status = .ready
      $0.hasHydrated = true
    }
    // With the seed gone, a later heal CANNOT mis-arm attach-by-live-id mode.
    await store.send(.liveSessionIDRefreshed(liveSessionID: "healed-live", storedSessionID: nil)) {
      $0.liveSessionID = "healed-live"
    }
    #expect(store.state.attachLiveSessionID == nil)
  }

  /// The `.ready` bare-create fallback is seed-aware too: a standing seed with NO stored
  /// id (an interrupted replay on a branch whose create returned no session_key) replays
  /// the seeded create instead of silently minting a bare session under the painted seed.
  @Test func readyWithSeedAndNoStoredIDReplaysInsteadOfBareCreate() async {
    let calls = LockIsolated<[(method: String, params: JSONValue)]>([])
    var initial = ChatFeature.State(connection: conn, status: .reconnecting)
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        // Orthogonal slash catalog fetch (#36) — answer benignly, don't record.
        if method == "commands.catalog" { return .object([:]) }
        calls.withValue { $0.append((method, params)) }
        switch method {
        case "session.create":
          return .object([
            "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
          ])
        default: // the attach
          return .object([
            "session_id": .string("fresh-live"),
            "session_key": .string("fresh-stored"),
            "messages": .array([]),
            "running": .bool(false),
            "info": .object([
              "model": .string("claude-opus-4-8"),
              "usage": .object([
                "context_used": .number(0), "context_max": .number(200_000),
                "context_percent": .number(0),
              ]),
            ]),
          ])
        }
      }
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      $0.hasRequestedSession = true
      $0.hasReplayedBranchSeed = true
    }
    await store.receive(\.branchReplayResult.success) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.attachLiveSessionID = "fresh-live"
    }
    await store.receive(\.activateResult.success) {
      $0.hasHydrated = true
      $0.hasReplayedBranchSeed = false
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
    }
    await store.receive(\.delegate.runningChanged)

    #expect(calls.value.map(\.method) == ["session.create", "session.activate"])
    let createParams = calls.value.first?.params
    guard case let .array(messages)? = createParams?["messages"] else {
      Issue.record("`.ready` replay missing the seed messages")
      return
    }
    #expect(messages.first?["content"]?.stringValue == "seeded answer")
    #expect(createParams?["parent_session_id"]?.stringValue == "parent-1")
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
    await store.send(.teardown)
  }

  // MARK: Finding-1 resume probe — a persisted branch is recovered, never discarded

  /// The probe's happy path: `session.activate` 404s (e.g. a server restart wiped the
  /// in-memory session), but `session.resume` by the branch's STORED id — the server's
  /// `session_key`, the SAME key `_ensure_session_db_row` persisted under, and a
  /// DIFFERENT value from the live `attachLiveSessionID` `session.activate` just 404'd
  /// on (review iteration 2 finding a) — finds the REAL persisted history: a first
  /// prompt had already landed and `_ensure_session_db_row` ran before `message.start`
  /// reached the client. The branch recovers via the standard hydrate path; a
  /// bare/seeded `session.create` never fires and never discards the real follow-up
  /// turn the seed alone doesn't carry.
  @Test func probeRecoversPersistedBranchInsteadOfReplayingSeed() async {
    let calls = LockIsolated<[(method: String, params: JSONValue)]>([])
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        // Orthogonal slash catalog fetch (#36) — answer benignly, don't record.
        if method == "commands.catalog" { return .object([:]) }
        calls.withValue { $0.append((method, params)) }
        // Real, persisted history — including a follow-up turn the seed alone (just the
        // original assistant message) does not carry, and a seed replay would discard.
        return .object([
          "session_id": .string("branch-live-2"),
          "session_key": .string("branch-stored"),
          "messages": .array([
            .object(["id": .number(1), "role": .string("assistant"), "text": .string("seeded answer")]),
            .object(["id": .number(2), "role": .string("user"), "text": .string("a real follow-up")]),
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

    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.success) {
      // Treated exactly like `message.start` clearing the unpersisted-branch bookkeeping.
      $0.attachLiveSessionID = nil
      $0.branchSeed = nil
      $0.hasReplayedBranchSeed = false
      $0.liveSessionID = "branch-live-2"
      $0.storedSessionID = "branch-stored"
      $0.status = .ready
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
      $0.transcript = [
        ChatRow(
          id: ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"),
          kind: .message(role: .assistant, text: "seeded answer", isComplete: true)
        ),
        ChatRow(
          id: ChatRow.deterministicID(sequenceIndex: 1, role: .user, kindDiscriminator: "message"),
          kind: .message(role: .user, text: "a real follow-up", isComplete: true)
        ),
      ]
    }
    await store.receive(\.delegate.runningChanged)

    // ONLY the probe hit the wire — no bare/seeded `session.create` ever ran, so the
    // real follow-up turn was never at risk of being discarded.
    #expect(calls.value.map(\.method) == ["session.resume"])
    // The probe must be issued with the STORED id, never the live one — probing with
    // the live id always 404s (review iteration 2 finding a), defeating this recovery.
    #expect(calls.value[0].params["session_id"]?.stringValue == "branch-stored")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.canBranch == true) // fully recovered: persisted, connected, idle
    await store.send(.teardown)
  }

  /// Structural fix (2026-07-24 review, finding 2): a transport-shaped probe failure (the
  /// probe itself dies mid-flight, never reaching a server verdict) must NOT let a LATER
  /// not-found skip straight to a bare/seeded `session.create` — exactly the history-loss
  /// bug the probe exists to prevent. Unlike the old spend/refund `hasProbedBranchResume`
  /// flag (which needed an explicit refund line the cancellation case skipped entirely),
  /// there is now no budget to leak: the probe is simply re-issued on every not-found.
  /// Drives a full disconnect → reconnect → second not-found sequence and asserts the
  /// second not-found RE-PROBES (never jumps straight to `session.create`).
  @Test func transientProbeFailureReArmsForReProbe() async {
    let calls = LockIsolated<[(method: String, params: JSONValue)]>([])
    let probeCount = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, params in
        // Orthogonal slash catalog fetch (#36) — answer benignly, don't record.
        if method == "commands.catalog" { return .object([:]) }
        calls.withValue { $0.append((method, params)) }
        guard method == "session.resume" else {
          Issue.record("unexpected \(method) — a re-armed probe must re-probe, never replay")
          return .object([:])
        }
        let n = probeCount.withValue { $0 += 1; return $0 }
        if n == 1 {
          throw GatewayError.disconnected // the probe itself is interrupted, no verdict
        }
        // The RE-probe finds the real persisted row — a first prompt landed server-side
        // while the socket was down.
        return .object([
          "session_id": .string("branch-live-2"),
          "session_key": .string("branch-stored"),
          "messages": .array([.object([
            "id": .number(1), "role": .string("assistant"), "text": .string("seeded answer"),
          ])]),
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

    // First not-found: the probe fires (by the STORED id) and dies transiently.
    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.status = .reconnecting
    }
    #expect(calls.value.map(\.method) == ["session.resume"])
    #expect(calls.value[0].params["session_id"]?.stringValue == "branch-stored")
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))

    // A second not-found (post-reconnect) — re-probes instead of skipping straight to a
    // bare/seeded `session.create` and risking discarded history.
    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.success) {
      $0.attachLiveSessionID = nil
      $0.branchSeed = nil
      $0.hasReplayedBranchSeed = false
      $0.liveSessionID = "branch-live-2"
      $0.storedSessionID = "branch-stored"
      $0.status = .ready
      $0.hasHydrated = true
      $0.model = "claude-opus-4-8"
      $0.usage = Usage(contextUsed: 0, contextMax: 200_000, contextPercent: 0)
      $0.transcript = [
        ChatRow(
          id: ChatRow.deterministicID(sequenceIndex: 0, role: .assistant, kindDiscriminator: "message"),
          kind: .message(role: .assistant, text: "seeded answer", isComplete: true)
        ),
      ]
    }
    await store.receive(\.delegate.runningChanged)

    // Never once a bare/seeded `session.create` — only the two probes, both by the
    // STORED id.
    #expect(calls.value.map(\.method) == ["session.resume", "session.resume"])
    #expect(calls.value[1].params["session_id"]?.stringValue == "branch-stored")
    await store.send(.teardown)
  }

  /// Structural fix (finding 3): a probe failure that is NOT a genuine "session not
  /// found" — a session cap (4090), an internal error (5000), a malformed payload — is
  /// NOT proof the branch's DB row is absent, so it must never replay the seed (only
  /// `handleActivateFailure`'s `error.isSessionNotFound` branch ever replays). It falls
  /// through to the generic error-banner path instead, leaving every piece of branch
  /// bookkeeping standing so a LATER not-found still re-probes rather than ever assuming
  /// absence from a non-not-found rejection.
  @Test func probeNonNotFoundServerErrorNeverReplaysAndReProbesLater() async {
    let probeCount = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(.init(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { @Sendable method, _ in
        guard method == "session.resume" else {
          // The eventual replay after the SECOND (genuine) not-found — not the focus of
          // this test, just needs to resolve so the store doesn't hang.
          return .object([
            "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
          ])
        }
        let n = probeCount.withValue { $0 += 1; return $0 }
        if n == 1 {
          // A real server rejection that is NOT proof of absence — e.g. the session cap
          // or an internal error. Neither confirms the branch's DB row is gone.
          throw GatewayError.server("4090 session cap exceeded")
        }
        throw GatewayError.server("session not found") // the later re-probe's genuine verdict
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.failure) {
      // Falls through to the generic error-banner path in `handleActivateFailure` — NOT
      // the seed-replay branch (gated on `error.isSessionNotFound`, and 4090 isn't).
      $0.status = .reconnecting
      $0.errorBanner = "4090 session cap exceeded"
    }
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
    #expect(store.state.hasReplayedBranchSeed == false) // never replayed
    #expect(probeCount.value == 1)

    // A LATER not-found must still re-probe — no leftover "spent" state from the earlier
    // non-not-found failure to skip it. (This second not-found happens to be genuine and
    // triggers the normal seed replay — already covered end-to-end elsewhere; the point
    // here is only that the re-probe itself fires.)
    await store.send(.activateResult(.failure(.server("session not found"))))
    await store.receive(\.branchResumeProbeResult.failure) {
      $0.status = .reconnecting
      $0.attachLiveSessionID = nil
      $0.hasRequestedSession = true
      $0.hasReplayedBranchSeed = true
    }
    #expect(probeCount.value == 2) // re-probed, never skipped straight to replay
    await store.send(.teardown)
  }

  /// Structural fix (finding 2): a probe CANCELLED by a superseding hydrate
  /// (`.foreground`/`.reattached`/`.teardownSocketOnly` all share `CancelID.hydrate` —
  /// TCA drops a cancelled task's trailing `send`, so no `.branchResumeProbeResult` ever
  /// arrives for the cancelled attempt) must not leave any "spent" state behind either —
  /// the next not-found still re-probes rather than skipping straight to a destructive
  /// seed replay over what could be persisted history.
  @Test func cancelledProbeReProbesInsteadOfReplayingSeed() async {
    let activateCalls = LockIsolated(0)
    let probeCalls = LockIsolated(0)
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, _ in
        switch method {
        case "session.activate":
          activateCalls.withValue { $0 += 1 }
          throw GatewayError.server("session not found") // reaped again on every attach
        case "session.resume":
          let n = probeCalls.withValue { $0 += 1; return $0 }
          if n == 1 {
            // Never reaches a server verdict — about to be cancelled by a superseding
            // `.teardownSocketOnly` (mirrors `.foreground`/`.reattached` superseding the
            // same `CancelID.hydrate`).
            try await Task.sleep(for: .seconds(3600))
            return .object([:])
          }
          throw GatewayError.server("session not found") // the RE-probe's genuine verdict
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.activateResult(.failure(.server("session not found"))))
    // The probe (call 1) is asleep, outstanding. Cancel it via a superseding
    // teardownSocketOnly — no `.branchResumeProbeResult` for it will ever arrive.
    await store.send(.teardownSocketOnly)
    // Reconnect and hit not-found again (the attach 404s on every call in this mock).
    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.failure)
    // STRUCTURAL PROOF: even though the first probe's result was silently dropped by
    // cancellation (no flag to protect), the recovery re-probes — it does NOT skip
    // straight to a destructive seed replay. Had it skipped, `probeCalls` would still
    // read 1 and the next receive would be `.branchReplayResult`, not another probe.
    await store.receive(\.branchResumeProbeResult.failure)
    #expect(probeCalls.value == 2)
    #expect(store.state.branchSeed != nil) // not yet destructively replayed
    await store.send(.teardown)
  }

  /// Structural fix (finding 1): `canSend` must be false for the ENTIRE probe/replay
  /// window, not just before the first attach — a stale `liveSessionID` from a PRIOR
  /// successful attach must be nilled the instant recovery starts, or a concurrent submit
  /// would race the reducer's own recovery with its own independent self-heal
  /// `session.create` (composerSubmitted's `withSessionHeal`), producing two live
  /// sessions from one seed with the typed message landing in the untracked one.
  @Test func sendBlockedWhileBranchRecoveryProbeOutstanding() async {
    var initial = ChatFeature.State(connection: conn, resumeStoredID: "branch-stored", status: .ready)
    initial.liveSessionID = "branch-live" // a PRIOR successful attach, not the fresh-branch nil case
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.composerText = "are you still there"
    let submitFired = LockIsolated(false)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "prompt.submit" { submitFired.setValue(true) }
        throw GatewayError.server("session not found")
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.activateResult(.failure(.server("session not found")))) {
      $0.liveSessionID = nil
    }
    // canSend is false the instant recovery starts — even though the probe hasn't
    // resolved yet — because the stale live id was nilled synchronously.
    #expect(store.state.canSend == false)
    await store.send(.composerSubmitted) // must no-op: canSend gates it
    #expect(submitFired.value == false) // no independent self-heal RPC ever raced the probe
    await store.send(.teardown)
  }

  // MARK: Review finding 2 — branching requires a connected socket

  /// `canBranch` and the reducer guard both require `status == .ready`, so a chat
  /// that's mid-reconnect can't be branched even if every other condition (persisted
  /// id, no attach redirect, no standing seed, idle) is satisfied.
  @Test func disconnectedChatCannotBranch() async {
    var initial = branchableState()
    initial.status = .reconnecting
    #expect(initial.canBranch == false)
    let store = TestStore(initialState: initial) { ChatFeature() }
    // No dependency override — the guard must fire BEFORE any RPC.

    await store.send(.branchFromMessage(id: uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
  }

  /// The exact scenario the finding describes: a socket drop mid-stream finalizes the
  /// in-flight row as `isComplete` and clears `isSending` — without the connected-status
  /// gate that row would look branchable (as a normal completed reply) while the socket
  /// is still `.reconnecting`, letting the user branch a possibly-truncated answer or
  /// fire the RPC at a dead socket.
  @Test func gatewayClosedMidStreamCannotBranchUntilReconnected() async {
    var initial = ChatFeature.State(connection: conn, status: .ready)
    initial.liveSessionID = "live"
    initial.storedSessionID = "stored123"
    initial.streamingRowID = uuid(0)
    initial.isSending = true
    initial.transcript = [
      ChatRow(id: uuid(0), kind: .message(role: .assistant, text: "truncated rep", isComplete: false))
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = TestClock()
    }

    await store.send(.gatewayClosed) {
      $0.hasRequestedSession = false
      $0.streamingRowID = nil
      $0.transcript[id: self.uuid(0)]?.kind = .message(
        role: .assistant, text: "truncated rep", isComplete: true
      )
      $0.isSending = false
      $0.status = .reconnecting
      $0.reconnectAttempt = 1
    }
    // The row now LOOKS like a normal completed reply, but the socket is down — must
    // not be branchable until reconnect.
    #expect(store.state.canBranch == false)
    await store.send(.branchFromMessage(id: self.uuid(0))) {
      $0.errorBanner = "This chat can’t be branched yet."
    }
    await store.send(.teardown)
  }

  // MARK: Review finding 3 — sending is blocked while a branch is in flight

  /// A branch `session.create` in flight must block a NEW parent turn: when
  /// `branchResult` lands, `AppFeature` tears down this whole slot to open the
  /// replacement chat, and a just-submitted turn would be silently lost (its
  /// socket/effects cancelled with no server response ever observed).
  @Test func isBranchingBlocksSend() async {
    var initial = branchableState()
    initial.isBranching = true
    initial.composerText = "a follow-up while branching"
    #expect(initial.canSend == false)
    let store = TestStore(initialState: initial) { ChatFeature() }
    // No dependency override — `composerSubmitted` must no-op before any RPC.

    await store.send(.composerSubmitted)
  }
}
