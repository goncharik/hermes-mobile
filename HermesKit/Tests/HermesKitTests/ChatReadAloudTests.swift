import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Read replies aloud (#74): the device-local toggle, the auto-speak anchor (arming on
/// toggle-on / pref load / first hydrate, re-basing on every later hydrate), and the dropped
/// partial consumed by `finalizeInFlight`.
@MainActor
struct ChatReadAloudTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  private func user(_ n: Int, _ text: String) -> ChatRow {
    ChatRow(id: uuid(n), kind: .message(role: .user, text: text, isComplete: true))
  }

  private func assistant(_ n: Int, _ text: String, complete: Bool = true) -> ChatRow {
    ChatRow(id: uuid(n), kind: .message(role: .assistant, text: text, isComplete: complete))
  }

  /// Two completed replies and one still streaming — the anchor counts only the two.
  private var twoRepliesAndAStream: IdentifiedArrayOf<ChatRow> {
    [
      user(0, "q1"), assistant(1, "a1"),
      user(2, "q2"), assistant(3, "a2"),
      user(4, "q3"), assistant(5, "streaming…", complete: false),
    ]
  }

  /// A socket that stays open until cancelled (the `.task` connect), so no `.gatewayClosed`.
  private nonisolated static let idleSocket: @Sendable (URL, AuthSession) -> AsyncStream<GatewayFrame> = { _, _ in
    AsyncStream { _ in }
  }

  // MARK: Pure helpers

  @Test func completedAssistantCountIgnoresStreamingUserAndNonMessageRows() {
    var state = ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    state.transcript.append(ChatRow(
      id: uuid(6), kind: .tool(name: "t", title: "t", state: .complete, detail: nil, durationS: nil)
    ))
    state.transcript.append(ChatRow(
      id: uuid(7), kind: .thinking(reasoning: "r", status: nil, elapsedSeconds: 1, isComplete: true)
    ))
    #expect(state.completedAssistantCount == 2)
    #expect(state.lastCompletedAssistantRow?.id == uuid(3)) // the streaming row never counts
  }

  @Test func helpersOnAnEmptyOrUserOnlyTranscript() {
    #expect(ChatFeature.State(connection: conn).completedAssistantCount == 0)
    #expect(ChatFeature.State(connection: conn).lastCompletedAssistantRow == nil)
    let userOnly = ChatFeature.State(connection: conn, transcript: [user(0, "hi")])
    #expect(userOnly.completedAssistantCount == 0)
    #expect(userOnly.lastCompletedAssistantRow == nil)
  }

  @Test func playbackIsActiveOnlyWhenNotIdle() {
    #expect(ChatFeature.State.TTSPlayback.idle.isActive == false)
    #expect(ChatFeature.State.TTSPlayback.preparing(uuid(1)).isActive)
    #expect(ChatFeature.State.TTSPlayback.speaking(uuid(1)).isActive)
  }

  @Test func freshStateDefaults() {
    let state = ChatFeature.State(connection: conn)
    #expect(state.autoSpeakReplies == false)
    #expect(state.ttsSupported)
    #expect(state.ttsPlayback == .idle)
    #expect(state.spokenAssistantCount == 0)
    #expect(state.replayConsumedReply == false)
    #expect(state.ttsInterruptedAt == nil)
    #expect(state.isSceneBackgrounded == false)
    #expect(state.isOnScreen == false)
  }

  // MARK: Pref load on the first `.task`

  @Test func taskWithPrefOnSetsTheFlagAndArmsToTheCompletedCount() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveAutoSpeakReplies(true)
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    ) {
      ChatFeature()
    } withDependencies: {
      $0.preferences = preferences
      $0.hermesGateway.connect = Self.idleSocket
    }

    await store.send(.task) {
      $0.hasStarted = true
      $0.autoSpeakReplies = true
      $0.spokenAssistantCount = 2 // the painted replies are never read
    }
    await store.send(.teardown)
  }

  @Test func taskWithPrefOffLeavesTheAnchor() async {
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    ) {
      ChatFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesGateway.connect = Self.idleSocket
    }

    await store.send(.task) { $0.hasStarted = true }
    await store.send(.teardown)
  }

  @Test func reappearanceDoesNotRereadThePref() async {
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    ) {
      ChatFeature()
    } withDependencies: {
      $0.preferences = preferences
      $0.hermesGateway.connect = Self.idleSocket
    }

    await store.send(.task) { $0.hasStarted = true }
    // Flipped elsewhere (another slot) — a re-appearance of THIS slot does not pick it up.
    preferences.saveAutoSpeakReplies(true)
    await store.send(.task)
    await store.send(.teardown)
  }

  // MARK: Toggle

  @Test func toggleOnSavesTrueAndArms() async {
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    ) {
      ChatFeature()
    } withDependencies: {
      $0.preferences = preferences
    }

    await store.send(.autoSpeakToggled) {
      $0.autoSpeakReplies = true
      $0.spokenAssistantCount = 2
    }
    #expect(preferences.loadAutoSpeakReplies() == true)
  }

  @Test func toggleOffSavesFalseAndKeepsTheAnchor() async {
    let preferences = PreferencesClient.inMemory()
    preferences.saveAutoSpeakReplies(true)
    var initial = ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    initial.autoSpeakReplies = true
    initial.spokenAssistantCount = 1 // one reply pending
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.preferences = preferences
    }

    await store.send(.autoSpeakToggled) {
      $0.autoSpeakReplies = false // anchor untouched
    }
    #expect(preferences.loadAutoSpeakReplies() == false)
  }

  // MARK: Arming on the first hydrate

  @Test func firstHydrateArmsWhateverTheToggleSays() async {
    // Instant-paint left one cached reply; the server's history holds two. The first hydrate
    // consumes every reply it brings in — opening a chat never reads its history.
    let store = TestStore(
      initialState: ChatFeature.State(
        connection: conn, transcript: [user(0, "q1"), assistant(1, "cached")]
      )
    ) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off

    await store.send(.activateResult(.success(ActivateResponse(
      sessionID: "live1", storedSessionID: "stored1",
      messages: [
        SessionMessage(id: 1, role: "user", content: "q1"),
        SessionMessage(id: 2, role: "assistant", content: "a1"),
        SessionMessage(id: 3, role: "user", content: "q2"),
        SessionMessage(id: 4, role: "assistant", content: "a2"),
      ],
      running: false
    )))) {
      $0.hasHydrated = true
      $0.spokenAssistantCount = 2
    }
  }

  @Test func sessionCreateHandshakeArmsOnTheFirstHandshake() async {
    let store = TestStore(
      initialState: ChatFeature.State(connection: conn, transcript: [user(0, "q"), assistant(1, "a")])
    ) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off

    await store.send(.sessionResult(.success(SessionHandle(sessionID: "live1")))) {
      $0.hasHydrated = true
      $0.spokenAssistantCount = 1
    }
  }

  @Test func laterSessionCreateKeepsAPendingReply() async {
    // A create on an already-hydrated slot (e.g. the #17 heal re-create) is not a first
    // handshake: the reply the user is waiting on stays pending.
    var initial = ChatFeature.State(
      connection: conn, transcript: [user(0, "q"), assistant(1, "a"), user(2, "q2"), assistant(3, "a2")]
    )
    initial.hasHydrated = true
    initial.spokenAssistantCount = 1
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in .object([:]) }
    }
    store.exhaustivity = .off

    await store.send(.sessionResult(.success(SessionHandle(sessionID: "live2"))))
    #expect(store.state.spokenAssistantCount == 1)
  }

  // MARK: Re-basing on later hydrates

  /// A slot that already hydrated once and folded one tool-using turn LIVE: the live fold
  /// keeps ONE assistant row for the whole turn (progress text + final answer).
  private func liveFoldedToolTurn(anchor: Int) -> ChatFeature.State {
    var state = ChatFeature.State(
      connection: conn, resumeStoredID: "stored1",
      transcript: [user(0, "list files"), assistant(1, "Let me check.Found 3 files.")]
    )
    state.liveSessionID = "live1"
    state.status = .ready
    state.hasStarted = true
    state.hasHydrated = true
    state.autoSpeakReplies = true
    state.spokenAssistantCount = anchor
    return state
  }

  /// The same turn as server history: the progress text and the final answer are two
  /// assistant messages around the tool row.
  private nonisolated static let toolTurnHistory: JSONValue = .object([
    "session_id": .string("live1"),
    "stored_session_id": .string("stored1"),
    "running": .bool(false),
    "messages": .array([
      .object(["id": .number(1), "role": .string("user"), "text": .string("list files")]),
      .object(["id": .number(2), "role": .string("assistant"), "text": .string("Let me check.")]),
      .object(["id": .number(3), "role": .string("tool"), "name": .string("terminal"), "context": .string("ls")]),
      .object(["id": .number(4), "role": .string("assistant"), "text": .string("Found 3 files.")]),
    ]),
  ])

  private func foregroundRehydrate(_ initial: ChatFeature.State) async -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        method == "session.resume" ? Self.toolTurnHistory : .object([:])
      }
    }
    store.exhaustivity = .off
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    return store
  }

  @Test func rehydrateSplittingASpokenTurnIntoTwoRowsLeavesNothingPending() async {
    // The live reply was already spoken (anchor 1 of 1). History now has TWO completed
    // assistant rows for that turn; keeping the old count would make the final answer look
    // pending and re-read it at the next speak edge.
    let store = await foregroundRehydrate(liveFoldedToolTurn(anchor: 1))
    #expect(store.state.completedAssistantCount == 2)
    #expect(store.state.spokenAssistantCount == 2)
  }

  @Test func rehydrateKeepsExactlyThePendingReplyPending() async {
    // The reply completed LIVE while backgrounded (anchor 0 of 1 — held for `.foreground`).
    // The re-hydrate keeps exactly one reply pending: the turn's final answer.
    let store = await foregroundRehydrate(liveFoldedToolTurn(anchor: 0))
    #expect(store.state.completedAssistantCount == 2)
    #expect(store.state.spokenAssistantCount == 1)
    #expect(store.state.lastCompletedAssistantRow?.kind
      == .message(role: .assistant, text: "Found 3 files.", isComplete: true))
  }

  @Test func rehydrateAfterAReplayFoldConsumesThePendingReply() async {
    // A #98 replay fold delivered the completion (`replayConsumedReply`): a past turn
    // boundary is never read, so the trailing hydrate consumes it and clears the flag.
    var initial = liveFoldedToolTurn(anchor: 0)
    initial.replayConsumedReply = true
    let store = await foregroundRehydrate(initial)
    #expect(store.state.spokenAssistantCount == 2)
    #expect(store.state.replayConsumedReply == false)
  }

  @Test func rehydrateNeverCreatesAPendingReply() async {
    // Nothing was pending before (anchor 1 of 1) and the server brings a reply the client
    // never saw complete live — it arrives consumed.
    var initial = liveFoldedToolTurn(anchor: 1)
    initial.transcript = [user(0, "list files")]
    initial.spokenAssistantCount = 0
    let store = await foregroundRehydrate(initial)
    #expect(store.state.spokenAssistantCount == store.state.completedAssistantCount)
  }

  // MARK: A dropped partial is consumed

  @Test func gatewayClosedMidStreamConsumesTheFinalizedPartial() async {
    var initial = ChatFeature.State(
      connection: conn, transcript: [user(0, "q"), assistant(1, "Half", complete: false)]
    )
    initial.streamingRowID = uuid(1)
    initial.isSending = true
    initial.status = .ready
    initial.autoSpeakReplies = true
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }

    await store.send(.gatewayClosed) {
      $0.transcript[id: self.uuid(1)]?.kind = .message(role: .assistant, text: "Half", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
      $0.status = .reconnecting
      $0.reconnectAttempt = 1
      $0.spokenAssistantCount = 1 // never read aloud — the replay/hydrate decides the turn
    }
    await store.send(.teardown)
  }

  @Test func gatewayClosedWithNothingStreamingKeepsAPendingReply() async {
    var initial = ChatFeature.State(connection: conn, transcript: [user(0, "q"), assistant(1, "done")])
    initial.status = .ready
    initial.autoSpeakReplies = true
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }

    await store.send(.gatewayClosed) {
      $0.status = .reconnecting
      $0.reconnectAttempt = 1 // anchor stays 0: the completed reply is still pending
    }
    await store.send(.teardown)
  }
}
