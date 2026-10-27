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

  // MARK: Action-bar button state

  @Test func readAloudStateIsIdleWithNoActiveClip() {
    let state = ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    #expect(state.readAloudState(for: uuid(1)) == .idle)
    #expect(state.readAloudState(for: uuid(3)) == .idle)
  }

  @Test func readAloudStateIsHiddenWhenUnsupportedWhateverThePlayback() {
    var state = ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    state.ttsSupported = false
    #expect(state.readAloudState(for: uuid(1)) == .hidden)
    state.ttsPlayback = .speaking(uuid(1))
    #expect(state.readAloudState(for: uuid(1)) == .hidden)
    #expect(state.readAloudState(for: uuid(3)) == .hidden)
  }

  @Test func readAloudStateIsPreparingForTheTargetAndDisabledForOthers() {
    var state = ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    state.ttsPlayback = .preparing(uuid(3))
    #expect(state.readAloudState(for: uuid(3)) == .preparing)
    #expect(state.readAloudState(for: uuid(1)) == .disabled)
  }

  @Test func readAloudStateIsSpeakingForTheTargetAndDisabledForOthers() {
    var state = ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    state.ttsPlayback = .speaking(uuid(1))
    #expect(state.readAloudState(for: uuid(1)) == .speaking)
    #expect(state.readAloudState(for: uuid(3)) == .disabled)
  }

  @Test(arguments: [
    ChatFeature.State.RecordingState.requestingPermission, .recording, .transcribing,
  ])
  func readAloudStateIsDisabledWhileTheMicIsBusy(_ recording: ChatFeature.State.RecordingState) {
    var state = ChatFeature.State(connection: conn, transcript: twoRepliesAndAStream)
    state.recording = recording
    #expect(state.readAloudState(for: uuid(1)) == .disabled)
    #expect(state.readAloudState(for: uuid(3)) == .disabled)
  }

  @Test func freshStateDefaults() {
    let state = ChatFeature.State(connection: conn)
    #expect(state.autoSpeakReplies == false)
    #expect(state.ttsSupported)
    #expect(state.ttsPlayback == .idle)
    #expect(state.spokenAssistantCount == 0)
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
      $0.isOnScreen = true
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

    await store.send(.task) {
      $0.isOnScreen = true
      $0.hasStarted = true
    }
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

    await store.send(.task) {
      $0.isOnScreen = true
      $0.hasStarted = true
    }
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

  private func foregroundRehydrate(
    _ initial: ChatFeature.State, recorder: TTSRecorder? = nil
  ) async -> TestStoreOf<ChatFeature> {
    let store = TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        method == "session.resume" ? Self.toolTurnHistory : .object([:])
      }
      recorder?.install(into: &$0)
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

  @Test func foregroundRehydrateAfterASpokenToolTurnNeverRereadsItsReply() async {
    // Acceptance (#74): the same split, driven through the speak edges themselves with the
    // chat on screen and auto-speak on. Neither the playback-idle edge nor the next return to
    // the app (which re-hydrates again) reads the turn's final answer a second time.
    let recorder = TTSRecorder()
    var initial = liveFoldedToolTurn(anchor: 1)
    initial.isOnScreen = true
    let store = await foregroundRehydrate(initial, recorder: recorder)
    #expect(store.state.completedAssistantCount == 2)

    await store.send(.ttsFinished)
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    #expect(store.state.ttsPlayback == .idle)
    #expect(recorder.speaks.value.isEmpty)
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

  // MARK: - Playback flow (Task 6)

  /// Records the read-aloud I/O: every `speak` request and every clip played/stopped.
  final class TTSRecorder: Sendable {
    struct Speak: Equatable, Sendable {
      var text: String
      var profile: String?
    }

    static let clip = TTSAudio(data: Data([0x49, 0x44, 0x33]), mimeType: "audio/mpeg")
    static let clipLength: Duration = .seconds(10)

    let speaks = LockIsolated<[Speak]>([])
    let plays = LockIsolated<[Data]>([])
    let stops = LockIsolated(0)
    /// When set, `speak` fails with it.
    let speakError = LockIsolated<RESTError?>(nil)
    /// When set, `play` fails with it.
    let playError = LockIsolated<TTSPlaybackError?>(nil)
    /// When set, each clip plays until this clock advances `clipLength` (a cancelled effect
    /// returns normally, like the live player); otherwise it finishes instantly.
    let playClock: TestClock<Duration>?

    init(holdingPlaybackOn clock: TestClock<Duration>? = nil) {
      playClock = clock
    }

    var spokenTexts: [String] { speaks.value.map(\.text) }

    func install(into deps: inout DependencyValues) {
      deps.hermesREST.speak = { @Sendable [self] _, text, profile in
        speaks.withValue { $0.append(Speak(text: text, profile: profile)) }
        if let error = speakError.value { throw error }
        return Self.clip
      }
      deps.tts.play = { @Sendable [self] data, _ in
        plays.withValue { $0.append(data) }
        if let error = playError.value { throw error }
        if let playClock { try? await playClock.sleep(for: Self.clipLength) }
      }
      deps.tts.stop = { @Sendable [self] in stops.withValue { $0 += 1 } }
    }
  }

  /// A ready, on-screen slot with auto-speak on, streaming its first reply (row 101).
  private func streamingSlot(autoSpeak: Bool = true, onScreen: Bool = true) -> ChatFeature.State {
    var state = ChatFeature.State(
      connection: conn, transcript: [user(100, "q"), assistant(101, "Hel", complete: false)]
    )
    state.streamingRowID = uuid(101)
    state.isSending = true
    state.status = .ready
    state.autoSpeakReplies = autoSpeak
    state.isOnScreen = onScreen
    return state
  }

  private func makeStore(
    _ initial: ChatFeature.State, _ recorder: TTSRecorder
  ) -> TestStoreOf<ChatFeature> {
    TestStore(initialState: initial) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.preferences = .inMemory()
      recorder.install(into: &$0)
    }
  }

  @Test func liveCompletionIsReadPreparingSpeakingFinished() async {
    let recorder = TTSRecorder()
    var initial = streamingSlot()
    initial.profileName = "work"
    let store = makeStore(initial, recorder)

    await store.send(.gatewayEvent(.messageComplete(text: "**Hello** there", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind =
        .message(role: .assistant, text: "**Hello** there", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
      $0.spokenAssistantCount = 1
      $0.ttsPlayback = .preparing(self.uuid(101))
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(101)) }
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }

    // The SANITIZED text is synthesized, under the slot's profile verbatim (#114).
    #expect(recorder.speaks.value == [.init(text: "Hello there", profile: "work")])
    #expect(recorder.plays.value == [TTSRecorder.clip.data])
  }

  @Test func toggleOnLeavesTheReplyOnScreenUnreadAndReadsTheNextOne() async {
    // Acceptance (#74): the reply already on screen when the toggle flips on is never read;
    // the next completed reply goes preparing → speaking → idle (the pill's whole lifetime).
    let recorder = TTSRecorder()
    var initial = ChatFeature.State(
      connection: conn, transcript: [user(100, "q1"), assistant(101, "Already here")]
    )
    initial.status = .ready
    initial.isOnScreen = true
    let store = makeStore(initial, recorder)

    await store.send(.autoSpeakToggled) {
      $0.autoSpeakReplies = true
      $0.spokenAssistantCount = 1
    }
    // A speak edge right after the toggle finds nothing pending.
    await store.send(.ttsFinished)
    #expect(recorder.speaks.value.isEmpty)

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.messageDelta(text: "Next")))
    await store.send(.gatewayEvent(.messageComplete(text: "Next", usage: nil)))
    let next = store.state.lastCompletedAssistantRow?.id
    #expect(next != nil && next != uuid(101))
    #expect(store.state.ttsPlayback == next.map(ChatFeature.State.TTSPlayback.preparing))
    await store.receive(\.ttsSpeaking)
    #expect(store.state.ttsPlayback == next.map(ChatFeature.State.TTSPlayback.speaking))
    await store.receive(\.ttsFinished)
    #expect(store.state.ttsPlayback == .idle)
    #expect(recorder.spokenTexts == ["Next"])
  }

  @Test func autoSpeakOffNeverReads() async {
    let recorder = TTSRecorder()
    let store = makeStore(streamingSlot(autoSpeak: false), recorder)

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
    }
    #expect(recorder.speaks.value.isEmpty)
  }

  @Test func toggledOffNeverReads() async {
    let recorder = TTSRecorder()
    let store = makeStore(streamingSlot(autoSpeak: false), recorder)

    await store.send(.autoSpeakToggled) { $0.autoSpeakReplies = true }
    await store.send(.autoSpeakToggled) { $0.autoSpeakReplies = false }
    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
    }
    #expect(recorder.speaks.value.isEmpty)
  }

  @Test func offScreenSlotNeverReads() async {
    // A detached compact slot keeps its socket and folds the turn — silently.
    let recorder = TTSRecorder()
    let store = makeStore(streamingSlot(onScreen: false), recorder)

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false // the anchor stays 0: the reply is still pending
    }
    #expect(recorder.speaks.value.isEmpty)
  }

  @Test func completionsDuringPlaybackWaitAndTheIdleEdgeReadsOnlyTheNewest() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let store = makeStore(streamingSlot(), recorder)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.messageComplete(text: "First", usage: nil)))
    await store.receive(\.ttsSpeaking)
    // Two more turns complete while "First" is still playing: neither starts a clip.
    for reply in ["Second", "Third"] {
      await store.send(.gatewayEvent(.messageStart))
      await store.send(.gatewayEvent(.messageDelta(text: reply)))
      await store.send(.gatewayEvent(.messageComplete(text: reply, usage: nil)))
      #expect(store.state.ttsPlayback == .speaking(uuid(101)))
    }
    #expect(recorder.spokenTexts == ["First"])
    #expect(store.state.spokenAssistantCount == 1)

    // "First" ends — the idle edge reads the newest reply only; the backlog collapses.
    await playClock.advance(by: TTSRecorder.clipLength)
    await store.receive(\.ttsFinished)
    await store.receive(\.ttsSpeaking)
    #expect(recorder.spokenTexts == ["First", "Third"])
    #expect(store.state.spokenAssistantCount == 3)
    await playClock.advance(by: TTSRecorder.clipLength)
    await store.receive(\.ttsFinished)
    #expect(store.state.ttsPlayback == .idle)
    #expect(recorder.spokenTexts == ["First", "Third"]) // "Second" is never read
  }

  @Test func emptyAfterSanitizingIsSkippedAndConsumed() async {
    let recorder = TTSRecorder()
    let store = makeStore(streamingSlot(), recorder)
    let codeOnly = "```\nls -la\n```"

    await store.send(.gatewayEvent(.messageComplete(text: codeOnly, usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: codeOnly, isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
      $0.spokenAssistantCount = 1
      $0.ttsPlayback = .preparing(self.uuid(101))
    }
    // Nothing to say: no synthesis, straight back to idle — and the reply stays consumed.
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
    #expect(recorder.speaks.value.isEmpty)
    #expect(recorder.plays.value.isEmpty)
  }

  @Test func aTurnEndingInErrorIsNeverRead() async {
    let recorder = TTSRecorder()
    let store = makeStore(streamingSlot(), recorder)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.error(message: "boom")))
    #expect(store.state.ttsPlayback == .idle)
    // A later idle edge does not pick the half-written row up either (it is not complete).
    await store.send(.ttsFinished)
    #expect(store.state.ttsPlayback == .idle)
    #expect(recorder.speaks.value.isEmpty)
  }

  @Test func aStreamingNewestReplyHoldsTheIdleEdge() async {
    // A reply completed during playback, then the next turn started streaming: the idle edge
    // waits for the newest reply instead of reading the stale one under it.
    let recorder = TTSRecorder()
    var initial = ChatFeature.State(connection: conn, transcript: [
      user(100, "q1"), assistant(101, "One"), user(102, "q2"), assistant(103, "Two…", complete: false),
    ])
    initial.streamingRowID = uuid(103)
    initial.isSending = true
    initial.autoSpeakReplies = true
    initial.isOnScreen = true
    initial.ttsPlayback = .speaking(uuid(42))
    let store = makeStore(initial, recorder)

    await store.send(.ttsFinished) { $0.ttsPlayback = .idle } // anchor 0 < 1, but row 103 streams
    #expect(recorder.speaks.value.isEmpty)
  }

  @Test func foregroundReadsAHeldReplyBeforeRedialing() async {
    // Dead socket on return: the pending reply is read whatever the socket is doing.
    let recorder = TTSRecorder()
    var initial = ChatFeature.State(connection: conn, transcript: [user(100, "q"), assistant(101, "Done")])
    initial.status = .reconnecting
    initial.autoSpeakReplies = true
    initial.isOnScreen = true
    let store = makeStore(initial, recorder)
    store.exhaustivity = .off(showSkippedAssertions: false)
    let connects = LockIsolated(0)
    store.dependencies.hermesGateway.connect = { @Sendable url, auth in
      connects.withValue { $0 += 1 }
      return Self.idleSocket(url, auth)
    }

    await store.send(.foreground) {
      $0.spokenAssistantCount = 1
      $0.ttsPlayback = .preparing(self.uuid(101))
    }
    await store.receive(\.ttsFinished)
    #expect(recorder.spokenTexts == ["Done"])
    // The speak did not swallow the redial of the dead socket.
    await waitUntil { connects.value == 1 }
    #expect(connects.value == 1)
    await store.send(.teardown)
  }

  @Test func reattachedNeverReads() async {
    let recorder = TTSRecorder()
    var initial = ChatFeature.State(connection: conn, transcript: [user(100, "q"), assistant(101, "Done")])
    initial.status = .ready // no session key yet: the re-attach itself is a no-op
    initial.autoSpeakReplies = true
    initial.isOnScreen = true
    let store = makeStore(initial, recorder)

    await store.send(.reattached)
    #expect(recorder.speaks.value.isEmpty)
  }

  // MARK: The mic owns the audio session

  /// How a dictation ends — each puts the mic back to `.idle`, a speak edge.
  enum MicEnd: CaseIterable, Sendable {
    case transcript, failure, cancelled, denied
  }

  @Test(arguments: MicEnd.allCases)
  func aReplyCompletingWhileTheMicIsBusyWaitsForTheMicToGoIdle(_ end: MicEnd) async {
    // The hands-off loop: the user starts dictating the next prompt while the agent finishes.
    // Reading now would switch the shared session to `.playback` under the live recorder.
    let recorder = TTSRecorder()
    var initial = streamingSlot()
    initial.recording = end == .denied ? .requestingPermission : .recording
    let store = makeStore(initial, recorder)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil)))
    #expect(store.state.ttsPlayback == .idle)
    #expect(store.state.spokenAssistantCount == 0) // held, still pending
    // A foreground return while dictating holds it too.
    await store.send(.foreground)
    #expect(store.state.ttsPlayback == .idle)

    switch end {
    case .transcript: await store.send(.transcriptionSucceeded("next prompt"))
    case .failure: await store.send(.voiceInputFailed(message: "Couldn’t transcribe the audio."))
    case .cancelled: await store.send(.recordingCancelled)
    case .denied: await store.send(.recordingPermission(false))
    }
    #expect(store.state.recording == .idle)
    #expect(store.state.ttsPlayback == .preparing(uuid(101)))
    await store.receive(\.ttsFinished)
    #expect(recorder.spokenTexts == ["Hello"])
  }

  @Test func readAloudTappedWhileTheMicIsBusyIsANoOp() async {
    let recorder = TTSRecorder()
    var initial = twoReplies(anchor: 2)
    initial.recording = .recording
    let store = makeStore(initial, recorder)

    await store.send(.readAloudTapped(id: uuid(103))) // exhaustive: no state change
    #expect(recorder.speaks.value.isEmpty)
  }

  // MARK: Per-message "Read aloud"

  /// Two completed replies, nothing streaming, auto-speak off.
  private func twoReplies(anchor: Int) -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn, transcript: [
      user(100, "q1"), assistant(101, "One"), user(102, "q2"), assistant(103, "Two"),
    ])
    state.status = .ready
    state.isOnScreen = true
    state.spokenAssistantCount = anchor
    return state
  }

  @Test func readAloudTappedReadsThatRowAndBumpsTheAnchor() async {
    // Auto-speak on with the newest reply pending: reading it by hand consumes it, so the
    // playback-idle edge does not read it a second time.
    let recorder = TTSRecorder()
    var initial = twoReplies(anchor: 1)
    initial.autoSpeakReplies = true
    let store = makeStore(initial, recorder)

    await store.send(.readAloudTapped(id: uuid(103))) {
      $0.spokenAssistantCount = 2
      $0.ttsPlayback = .preparing(self.uuid(103))
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
    #expect(recorder.spokenTexts == ["Two"])
  }

  @Test func readingAnOlderRowNeverLowersTheAnchorAndKeepsANewerReplyPending() async {
    let recorder = TTSRecorder()
    var initial = twoReplies(anchor: 0)
    initial.autoSpeakReplies = true
    let store = makeStore(initial, recorder)

    await store.send(.readAloudTapped(id: uuid(101))) {
      $0.spokenAssistantCount = 1 // "One" is read; "Two" stays pending
      $0.ttsPlayback = .preparing(self.uuid(101))
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(101)) }
    // The idle edge reads the pending newest reply.
    await store.receive(\.ttsFinished) {
      $0.spokenAssistantCount = 2
      $0.ttsPlayback = .preparing(self.uuid(103))
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
    #expect(recorder.spokenTexts == ["One", "Two"])

    // With everything consumed, re-reading the older row leaves the anchor where it is.
    await store.send(.readAloudTapped(id: uuid(101))) { $0.ttsPlayback = .preparing(self.uuid(101)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(101)) }
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
  }

  @Test func readAloudWorksWithAutoSpeakOff() async {
    let recorder = TTSRecorder()
    let store = makeStore(twoReplies(anchor: 0), recorder)

    await store.send(.readAloudTapped(id: uuid(101))) {
      $0.spokenAssistantCount = 1
      $0.ttsPlayback = .preparing(self.uuid(101))
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(101)) }
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle } // auto-speak off: nothing more
    #expect(recorder.spokenTexts == ["One"])
  }

  @Test func readAloudTappedIgnoresNonRepliesAndAnActiveClip() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    var initial = twoReplies(anchor: 2)
    initial.transcript.append(assistant(104, "streaming", complete: false))
    let store = makeStore(initial, recorder)

    await store.send(.readAloudTapped(id: uuid(100))) // a user row
    await store.send(.readAloudTapped(id: uuid(104))) // still streaming
    await store.send(.readAloudTapped(id: uuid(999))) // unknown row
    #expect(recorder.speaks.value.isEmpty)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    // Another row's tap while this one plays is a no-op.
    await store.send(.readAloudTapped(id: uuid(101)))
    #expect(recorder.spokenTexts == ["Two"])
    await playClock.advance(by: TTSRecorder.clipLength)
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
  }

  @Test func stopReadAloudCancelsTheClipAndStopsThePlayer() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let store = makeStore(twoReplies(anchor: 2), recorder)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    await store.send(.stopReadAloud) { $0.ttsPlayback = .idle }
    await store.finish() // the cancelled clip never reports `.ttsFinished`
    #expect(recorder.stops.value == 1)

    // Stop while idle is a no-op (no player call).
    await store.send(.stopReadAloud)
    #expect(recorder.stops.value == 1)
  }

  // MARK: Failures

  @Test(arguments: [RESTError.notFound, .server(status: 405, detail: nil)])
  func missingEndpointHidesReadAloudSilently(_ error: RESTError) async {
    let recorder = TTSRecorder()
    recorder.speakError.setValue(error)
    let store = makeStore(twoReplies(anchor: 2), recorder)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsFailed) {
      $0.ttsPlayback = .idle
      $0.ttsSupported = false // no banner
    }
    // Hidden from now on: a tap (e.g. a stale button) does nothing.
    await store.send(.readAloudTapped(id: uuid(101)))
    #expect(recorder.speaks.value.count == 1)
  }

  @Test func unsupportedSlotNeverAutoSpeaks() async {
    let recorder = TTSRecorder()
    var initial = streamingSlot()
    initial.ttsSupported = false
    let store = makeStore(initial, recorder)

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
    }
    #expect(recorder.speaks.value.isEmpty)
  }

  /// A 400 (no provider) and a handler 404 (unknown `?profile=`) both keep the controls.
  @Test(arguments: [
    RESTError.server(status: 400, detail: "No TTS provider configured"),
    .server(status: 404, detail: "Profile 'gone' does not exist."),
  ])
  func serverDetailLandsInTheBanner(_ error: RESTError) async {
    let recorder = TTSRecorder()
    recorder.speakError.setValue(error)
    let store = makeStore(twoReplies(anchor: 2), recorder)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsFailed) {
      $0.ttsPlayback = .idle
      $0.errorBanner = error.message // `ttsSupported` stays true
    }
  }

  @Test func aTransportFailureBannersThroughAsRESTError() async {
    let recorder = TTSRecorder()
    let store = makeStore(twoReplies(anchor: 2), recorder)
    store.dependencies.hermesREST.speak = { @Sendable _, _, _ in
      throw URLError(.notConnectedToInternet)
    }

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsFailed) {
      $0.ttsPlayback = .idle
      $0.errorBanner = RESTError.offline.message
    }
  }

  @Test func theFailureEdgeReadsANewerPendingReply() async {
    // A manual read of the older reply fails; its idle edge still reads the pending newest one.
    let recorder = TTSRecorder()
    recorder.playError.setValue(.failed)
    var initial = twoReplies(anchor: 0)
    initial.autoSpeakReplies = true
    let store = makeStore(initial, recorder)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.readAloudTapped(id: uuid(101)))
    await store.receive(\.ttsSpeaking)
    await store.receive(\.ttsFailed)
    #expect(store.state.ttsPlayback == .preparing(uuid(103)))
    #expect(store.state.spokenAssistantCount == 2)
    await store.receive(\.ttsSpeaking)
    await store.receive(\.ttsFailed)
    #expect(store.state.ttsPlayback == .idle)
    #expect(recorder.spokenTexts == ["One", "Two"])
  }

  @Test func synthesisLandingAfterAStopNeverStartsTheClip() async {
    // `speak` finishes decoding even though the effect was cancelled meanwhile (here: it
    // swallows the cancellation): the clip must not start — the mic may own the session.
    let recorder = TTSRecorder()
    let speakClock = TestClock()
    let store = makeStore(twoReplies(anchor: 2), recorder)
    store.dependencies.hermesREST.speak = { @Sendable _, _, _ in
      try? await speakClock.sleep(for: .seconds(1))
      return TTSRecorder.clip
    }

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.send(.stopReadAloud) { $0.ttsPlayback = .idle }
    await store.finish()
    #expect(recorder.plays.value.isEmpty)
  }

  @Test(arguments: [
    (TTSPlaybackError.stalled, "Playback stalled."),
    (.failed, "Couldn’t play the audio."),
  ])
  func playbackFailureBanners(_ error: TTSPlaybackError, _ banner: String) async {
    let recorder = TTSRecorder()
    recorder.playError.setValue(error)
    let store = makeStore(twoReplies(anchor: 2), recorder)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    await store.receive(\.ttsFailed) {
      $0.ttsPlayback = .idle
      $0.errorBanner = banner
    }
  }

  @Test func aFailedAutoReadStaysConsumed() async {
    // The failure edge is itself a speak edge: the failed reply must not be retried.
    let recorder = TTSRecorder()
    recorder.speakError.setValue(.server(status: 500, detail: "Synthesis failed"))
    let store = makeStore(streamingSlot(), recorder)
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil)))
    await store.receive(\.ttsFailed)
    await store.skipReceivedActions(strict: false) // no retry of the failed reply
    #expect(recorder.speaks.value.count == 1)
    #expect(store.state.ttsPlayback == .idle)
    #expect(store.state.spokenAssistantCount == 1)
    #expect(store.state.errorBanner == "Synthesis failed")
  }

  // MARK: Hydrate mid-playback

  @Test(arguments: [false, true])
  func hydrateMidPlaybackRepointsToTheRebuiltRow(_ preparing: Bool) async throws {
    var initial = ChatFeature.State(
      connection: conn, resumeStoredID: "stored1", transcript: [user(100, "q"), assistant(101, "Hello")]
    )
    initial.liveSessionID = "live1"
    initial.status = .ready
    initial.hasHydrated = true
    initial.spokenAssistantCount = 1
    initial.ttsPlayback = preparing ? .preparing(uuid(101)) : .speaking(uuid(101))
    let store = TestStore(initialState: initial) {
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
        SessionMessage(id: 1, role: "user", content: "q"),
        SessionMessage(id: 2, role: "assistant", content: "Hello"),
      ],
      running: false
    ))))
    let rebuilt = try #require(store.state.lastCompletedAssistantRow?.id)
    #expect(rebuilt != uuid(101)) // the live id was rewritten to the history id
    #expect(store.state.ttsPlayback == (preparing ? .preparing(rebuilt) : .speaking(rebuilt)))

    // The clip's own `.ttsSpeaking` keeps the re-pointed row.
    if preparing {
      await store.send(.ttsSpeaking)
      #expect(store.state.ttsPlayback == .speaking(rebuilt))
    }
  }

  @Test func hydrateMidPlaybackRepointsAnOlderReplyToItsOwnTurn() async throws {
    // Two turns completed live since the last hydrate; the OLDER reply is being read when a
    // re-hydrate rewrites every id (and splits that turn's reply around its progress text).
    var initial = ChatFeature.State(
      connection: conn, resumeStoredID: "stored1",
      transcript: [user(100, "q1"), assistant(101, "Let me check.One"), user(102, "q2"), assistant(103, "Two")]
    )
    initial.liveSessionID = "live1"
    initial.status = .ready
    initial.hasHydrated = true
    initial.spokenAssistantCount = 2
    initial.ttsPlayback = .speaking(uuid(101))
    let store = TestStore(initialState: initial) {
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
        SessionMessage(id: 2, role: "assistant", content: "Let me check."),
        SessionMessage(id: 3, role: "assistant", content: "One"),
        SessionMessage(id: 4, role: "user", content: "q2"),
        SessionMessage(id: 5, role: "assistant", content: "Two"),
      ],
      running: false
    ))))
    let one = try #require(store.state.transcript.first {
      $0.kind == .message(role: .assistant, text: "One", isComplete: true)
    })
    let two = try #require(store.state.lastCompletedAssistantRow)
    #expect(store.state.ttsPlayback == .speaking(one.id))
    #expect(store.state.readAloudState(for: one.id) == .speaking)
    #expect(store.state.readAloudState(for: two.id) == .disabled)
  }

  // MARK: The #98 replay rule

  enum Drop: CaseIterable, Sendable {
    /// `.gatewayClosed`: the drop finalizes (and consumes) the streaming partial.
    case socketClosed
    /// `.teardownSocketOnly`: nothing is finalized — the fold completes the live row.
    case graceExpired
  }

  /// A ready, on-screen, auto-speak slot of the replay harness: "Old" (spoken) and a reply
  /// streaming as row 903 when the socket goes away; replay watermark at 41.
  private func replaySlot() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn, resumeStoredID: "stored1")
    state.liveSessionID = "live1"
    state.status = .ready
    state.hasStarted = true
    state.hasHydrated = true
    state.hasRequestedSession = true
    state.replayEpoch = "e1"
    state.replayCursor = .init(sessionID: "live1", seq: 41)
    state.autoSpeakReplies = true
    state.isOnScreen = true
    state.transcript = [user(900, "q1"), assistant(901, "Old"), user(902, "q2"), assistant(903, "Hel", complete: false)]
    state.streamingRowID = uuid(903)
    state.isSending = true
    state.spokenAssistantCount = 1
    return state
  }

  private nonisolated static let replayHistory: [JSONValue] = [
    ReplayTests.message(1, "user", "q1"), ReplayTests.message(2, "assistant", "Old"),
    ReplayTests.message(3, "user", "q2"), ReplayTests.message(4, "assistant", "Hello"),
  ]

  /// Drop the socket, then reconnect: `.ready` → replay read → fold → trailing hydrate.
  private func dropAndReplay(
    _ drop: Drop, _ store: TestStoreOf<ChatFeature>
  ) async {
    switch drop {
    case .socketClosed: await store.send(.gatewayClosed)
    case .graceExpired: await store.send(.teardownSocketOnly)
    }
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1")))
    await store.receive(\.eventReplayResult.success)
  }

  @Test(arguments: Drop.allCases)
  func aReplayedCompletionIsNeverRead(_ drop: Drop) async throws {
    let gateway = ReplayTests.ReplayHarness()
    gateway.since.setValue(.success(ReplayTests.since([
      ReplayTests.event("message.delta", 42, ["text": .string("lo")]),
      ReplayTests.event("message.complete", 43, ["text": .string("Hello")]),
    ])))
    gateway.resume.setValue(ReplayTests.resume(running: false, messages: Self.replayHistory))
    let recorder = TTSRecorder()
    let store = gateway.makeStore(replaySlot())
    recorder.install(into: &store.dependencies)

    await dropAndReplay(drop, store)
    if drop == .graceExpired {
      // The fold itself completed the still-live row — and consumed it.
      #expect(store.state.transcript[id: uuid(903)]?.kind
        == .message(role: .assistant, text: "Hello", isComplete: true))
    }
    #expect(store.state.ttsPlayback == .idle) // never `.preparing`
    #expect(store.state.spokenAssistantCount == store.state.completedAssistantCount)
    await store.receive(\.activateResult.success)
    #expect(store.state.ttsPlayback == .idle)
    #expect(store.state.spokenAssistantCount == store.state.completedAssistantCount)
    #expect(recorder.speaks.value.isEmpty)

    // Later speak edges do not pick the replayed reply up: returning to the app (healthy
    // socket → a plain re-hydrate) …
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    #expect(recorder.speaks.value.isEmpty)
    // … nor the idle edge after a manual read of the OLDER reply.
    let old = try #require(store.state.transcript.first(where: {
      $0.kind == .message(role: .assistant, text: "Old", isComplete: true)
    }))
    await store.send(.readAloudTapped(id: old.id))
    await store.receive(\.ttsFinished)
    await store.skipReceivedActions(strict: false) // the idle edge starts no second clip
    #expect(recorder.spokenTexts == ["Old"])
    #expect(store.state.ttsPlayback == .idle)

    // The NEXT live completion is read.
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.messageDelta(text: "Next")))
    await store.send(.gatewayEvent(.messageComplete(text: "Next", usage: nil)))
    await store.receive(\.ttsFinished)
    #expect(recorder.spokenTexts == ["Old", "Next"])
    await store.send(.teardown)
  }

  @Test func aReplayWithoutACompletionKeepsALivePendingReplyPending() async {
    // "Done" completed LIVE while "Old" was being read by hand, so it waits for the clip's
    // idle edge. The socket drops; the gap holds no `message.complete` — the reply is still
    // the one the user is waiting on, and the idle edge reads it after the reconnect.
    let gateway = ReplayTests.ReplayHarness()
    gateway.since.setValue(.success(ReplayTests.since([
      ReplayTests.event("status.update", 42, ["kind": .string("compress"), "text": .string("Compressing")]),
    ])))
    gateway.resume.setValue(ReplayTests.resume(running: false, messages: [
      ReplayTests.message(1, "user", "q1"), ReplayTests.message(2, "assistant", "Old"),
      ReplayTests.message(3, "user", "q2"), ReplayTests.message(4, "assistant", "Done"),
    ]))
    var initial = replaySlot()
    initial.transcript[id: uuid(903)]?.kind = .message(role: .assistant, text: "Done", isComplete: true)
    initial.streamingRowID = nil
    initial.isSending = false
    initial.ttsPlayback = .speaking(uuid(901))
    let recorder = TTSRecorder()
    let store = gateway.makeStore(initial)
    recorder.install(into: &store.dependencies)

    await dropAndReplay(.socketClosed, store)
    await store.receive(\.activateResult.success)
    #expect(store.state.completedAssistantCount == 2)
    #expect(store.state.spokenAssistantCount == 1) // "Done" still pending
    #expect(recorder.speaks.value.isEmpty)

    // The manual clip ends: the idle edge reads the pending reply.
    await store.send(.ttsFinished)
    await store.receive(\.ttsFinished)
    #expect(recorder.spokenTexts == ["Done"])
    #expect(store.state.spokenAssistantCount == 2)
    await store.send(.teardown)
  }

  /// How a reconnect falls back to the plain hydrate instead of folding the gap.
  enum PlainHydrate: CaseIterable, Sendable {
    /// The replay read fails (timeout) → hydrate.
    case readFailed
    /// The gap fell out of the server's ring (`truncated`) → fold nothing, hydrate.
    case truncated
  }

  @Test(arguments: Drop.allCases, PlainHydrate.allCases)
  func aReplyDeliveredOnlyByAPlainReconnectHydrateIsNeverRead(
    _ drop: Drop, _ fallback: PlainHydrate
  ) async {
    // Acceptance (#74): the reply completed during the drop / after the grace, but the
    // reconnect could not replay the gap — the hydrate alone brings it in, and it arrives
    // consumed (a hydrate never creates a pending reply), at the hydrate and at the next return.
    let gateway = ReplayTests.ReplayHarness()
    switch fallback {
    case .readFailed:
      gateway.since.setValue(.failure(.timedOut(method: "session.events.since")))
    case .truncated:
      gateway.since.setValue(.success(ReplayTests.since([], latest: 90, truncated: true)))
    }
    gateway.resume.setValue(ReplayTests.resume(running: false, messages: Self.replayHistory))
    let recorder = TTSRecorder()
    let store = gateway.makeStore(replaySlot())
    recorder.install(into: &store.dependencies)

    switch drop {
    case .socketClosed: await store.send(.gatewayClosed)
    case .graceExpired: await store.send(.teardownSocketOnly)
    }
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1")))
    await store.receive(\.eventReplayResult)
    await store.receive(\.activateResult.success)
    #expect(store.state.lastCompletedAssistantRow?.kind
      == .message(role: .assistant, text: "Hello", isComplete: true))
    #expect(store.state.spokenAssistantCount == store.state.completedAssistantCount)
    #expect(store.state.ttsPlayback == .idle)

    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    #expect(store.state.ttsPlayback == .idle)
    #expect(recorder.speaks.value.isEmpty)
    await store.send(.teardown)
  }

  // MARK: - Barge-in latch (Task 7)

  private static let now = Date(timeIntervalSince1970: 1_000_000)

  /// `makeStore` plus what a submit needs: a pinned clock for the latch, the snapshot cache
  /// for the turn anchor, and a gateway that records every `prompt.submit` params payload.
  private func submitStore(
    _ initial: ChatFeature.State, _ recorder: TTSRecorder, submits: LockIsolated<[JSONValue]>
  ) -> TestStoreOf<ChatFeature> {
    let store = makeStore(initial, recorder)
    store.dependencies.date = .constant(Self.now)
    store.dependencies.chatSnapshot = .inMemory()
    store.dependencies.hermesGateway.send = { @Sendable method, params in
      if method == "prompt.submit" { submits.withValue { $0.append(params) } }
      return .object([:])
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  /// `twoReplies` on a live session with a typed draft.
  private func idleSlotWithDraft(_ draft: String) -> ChatFeature.State {
    var state = twoReplies(anchor: 2)
    state.liveSessionID = "live1"
    state.composerText = draft
    return state
  }

  private func submitParams(_ text: String, interrupted: Bool = false) -> JSONValue {
    var params: [String: JSONValue] = ["session_id": .string("live1"), "text": .string(text)]
    if interrupted { params["interrupted"] = .bool(true) }
    return .object(params)
  }

  @Test func submitMidPlaybackStopsTheClipAndFlagsThePrompt() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let submits = LockIsolated<[JSONValue]>([])
    let store = submitStore(idleSlotWithDraft("next"), recorder, submits: submits)

    await store.send(.readAloudTapped(id: uuid(103)))
    await store.receive(\.ttsSpeaking)
    await store.send(.composerSubmitted) {
      $0.ttsPlayback = .idle
      $0.ttsInterruptedAt = nil // stamped, then taken by this very submit
      $0.isSending = true
    }
    await store.finish() // the cancelled clip never reports `.ttsFinished`
    #expect(recorder.stops.value == 1)
    #expect(submits.value == [submitParams("next", interrupted: true)])
  }

  @Test func aSubmitWithoutAStampSendsTheLegacyFrame() async {
    let recorder = TTSRecorder()
    let submits = LockIsolated<[JSONValue]>([])
    let store = submitStore(idleSlotWithDraft("hello"), recorder, submits: submits)

    await store.send(.composerSubmitted)
    await store.finish()
    // Byte-identical to the pre-#74 frame: no `interrupted` key at all, and no player call.
    #expect(submits.value == [.object(["session_id": .string("live1"), "text": .string("hello")])])
    #expect(recorder.stops.value == 0)
  }

  @Test(arguments: [(119.0, true), (120.0, false), (121.0, false)])
  func theLatchExpiresAfter120Seconds(_ age: TimeInterval, _ flagged: Bool) async {
    let recorder = TTSRecorder()
    let submits = LockIsolated<[JSONValue]>([])
    var initial = idleSlotWithDraft("later")
    initial.ttsInterruptedAt = Self.now.addingTimeInterval(-age)
    let store = submitStore(initial, recorder, submits: submits)

    await store.send(.composerSubmitted) { $0.ttsInterruptedAt = nil } // taken either way
    await store.finish()
    #expect(submits.value == [submitParams("later", interrupted: flagged)])
  }

  @Test(arguments: [false, true], [false, true])
  func bothBuildersAndTheHealReplayCarryTheFlag(withAttachment: Bool, heal: Bool) async {
    // The upload+submit builder as well as the plain one; with `heal`, the first
    // `prompt.submit` hits a stale live id (#17) and the replayed frame must carry it too.
    let recorder = TTSRecorder()
    let submits = LockIsolated<[JSONValue]>([])
    var initial = idleSlotWithDraft("look")
    initial.storedSessionID = "stored1"
    initial.ttsPlayback = .speaking(uuid(103))
    if heal { initial.liveSessionID = "stale-live" }
    if withAttachment {
      initial.attachments = [ComposerAttachment(
        id: uuid(50), kind: .image, filename: "p.png", mimeType: "image/png", data: Data([1])
      )]
    }
    let store = submitStore(initial, recorder, submits: submits)
    store.dependencies.hermesGateway.send = { @Sendable method, params in
      switch method {
      case "prompt.submit":
        submits.withValue { $0.append(params) }
        if params["session_id"]?.stringValue == "stale-live" {
          throw GatewayError.server("session not found")
        }
        return .object([:])
      case "session.resume":
        return .object([
          "session_id": .string("live1"), "stored_session_id": .string("stored1"),
          "messages": .array([]), "running": .bool(false),
        ])
      default:
        return .object([:])
      }
    }

    await store.send(.composerSubmitted)
    await store.finish()
    let flagged: (String) -> JSONValue = { sessionID in
      .object(["session_id": .string(sessionID), "text": .string("look"), "interrupted": .bool(true)])
    }
    #expect(submits.value == (heal ? [flagged("stale-live"), flagged("live1")] : [flagged("live1")]))
  }

  @Test func aFailedSubmitDropsTheLatch() async {
    // The latch is taken when the submit is built: a submit that then fails does not hand it
    // back, so the user's re-send goes out unflagged.
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let submits = LockIsolated<[JSONValue]>([])
    let store = submitStore(idleSlotWithDraft("next"), recorder, submits: submits)
    store.dependencies.hermesGateway.send = { @Sendable method, params in
      guard method == "prompt.submit" else { return .object([:]) }
      submits.withValue { $0.append(params) }
      if submits.value.count == 1 { throw GatewayError.server("boom") }
      return .object([:])
    }

    await store.send(.readAloudTapped(id: uuid(103)))
    await store.receive(\.ttsSpeaking)
    await store.send(.composerSubmitted)
    await store.receive(\.promptSubmitFailed)
    #expect(store.state.ttsInterruptedAt == nil)
    await store.send(.binding(.set(\.composerText, "next")))
    await store.send(.composerSubmitted)
    await store.finish()
    #expect(submits.value == [submitParams("next", interrupted: true), submitParams("next")])
  }

  @Test func aQueuedSubmitMidPlaybackStampsAndTheDrainedPromptCarriesTheFlag() async {
    // A turn runs while an older reply is read by hand: the typed draft queues (#66), the
    // clip stops, and the drain at the turn's `message.complete` carries the flag.
    let recorder = TTSRecorder()
    let submits = LockIsolated<[JSONValue]>([])
    var initial = streamingSlot(autoSpeak: false)
    initial.transcript.insert(contentsOf: [user(98, "q0"), assistant(99, "Old")], at: 0)
    initial.liveSessionID = "live1"
    initial.composerText = "queued"
    initial.ttsPlayback = .speaking(uuid(99))
    let store = submitStore(initial, recorder, submits: submits)

    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "queued", attachments: [])]
      $0.composerText = ""
      $0.ttsPlayback = .idle
      $0.ttsInterruptedAt = Self.now
    }
    #expect(recorder.stops.value == 1)
    #expect(submits.value.isEmpty) // never submitted against the running turn

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.queuedPrompts = []
      $0.ttsInterruptedAt = nil
    }
    await store.finish()
    #expect(submits.value == [submitParams("queued", interrupted: true)])
  }

  @Test func aQueueDrainAtMessageCompleteDoesNotStopTheAutoSpeakItTriggers() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let submits = LockIsolated<[JSONValue]>([])
    var initial = streamingSlot()
    initial.liveSessionID = "live1"
    initial.queuedPrompts = [QueuedPrompt(id: uuid(7), text: "queued", attachments: [])]
    let store = submitStore(initial, recorder, submits: submits)

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.ttsPlayback = .preparing(self.uuid(101))
      $0.queuedPrompts = []
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(101)) }
    // The drained prompt went out unflagged, and the reply it raced keeps playing.
    await waitUntil { submits.value.count == 1 }
    #expect(submits.value == [submitParams("queued")])
    #expect(recorder.stops.value == 0)
    #expect(store.state.ttsInterruptedAt == nil)
    await playClock.advance(by: TTSRecorder.clipLength)
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
  }

  @Test func micTapMidPlaybackStopsBeforeThePermissionPromptAndStamps() async {
    let recorder = TTSRecorder()
    let submits = LockIsolated<[JSONValue]>([])
    let order = LockIsolated<[String]>([])
    var initial = idleSlotWithDraft("")
    initial.ttsPlayback = .speaking(uuid(103))
    let store = submitStore(initial, recorder, submits: submits)
    store.dependencies.tts.stop = { @Sendable in order.withValue { $0.append("tts.stop") } }
    store.dependencies.audioRecorder.requestPermission = { @Sendable in
      order.withValue { $0.append("requestPermission") }
      return false
    }

    await store.send(.voiceButtonTapped) {
      $0.recording = .requestingPermission
      $0.ttsPlayback = .idle
      $0.ttsInterruptedAt = Self.now
    }
    await store.receive(\.recordingPermission) { $0.recording = .idle }
    // The player released the session BEFORE the recorder's `.playAndRecord` could start.
    #expect(order.value == ["tts.stop", "requestPermission"])

    // The dictated (here: typed) follow-up carries the flag.
    await store.send(.binding(.set(\.composerText, "follow-up")))
    await store.send(.composerSubmitted) { $0.ttsInterruptedAt = nil }
    await store.finish()
    #expect(submits.value == [submitParams("follow-up", interrupted: true)])
  }

  @Test func micTapWhileIdleStampsNothing() async {
    let recorder = TTSRecorder()
    let store = makeStore(twoReplies(anchor: 2), recorder)
    store.dependencies.audioRecorder.requestPermission = { @Sendable in false }

    // Exhaustive: no latch when nothing was playing (the idempotent `tts.stop()` still runs).
    await store.send(.voiceButtonTapped) { $0.recording = .requestingPermission }
    await store.receive(\.recordingPermission) {
      $0.recording = .idle
      $0.errorBanner = "Microphone access is off. Enable it in Settings to use voice input."
    }
    #expect(recorder.stops.value == 1)
  }

  // MARK: - Lifecycle (Task 7)

  @Test func sceneBackgroundedStopsPlaybackWithoutALatch() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let store = makeStore(twoReplies(anchor: 2), recorder)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    await store.send(.sceneBackgrounded) {
      $0.isSceneBackgrounded = true
      $0.ttsPlayback = .idle // not a barge-in: `ttsInterruptedAt` stays nil
    }
    await store.finish()
    #expect(recorder.stops.value == 1)
  }

  @Test func aReplyCompletingWhileBackgroundedIsReadOnForeground() async {
    let recorder = TTSRecorder()
    let store = makeStore(streamingSlot(), recorder)

    await store.send(.sceneBackgrounded) { $0.isSceneBackgrounded = true }
    // The grace socket keeps streaming: the reply completes LIVE, but is held.
    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false // anchor stays 0: pending
    }
    #expect(recorder.speaks.value.isEmpty)
    #expect(recorder.stops.value == 0) // nothing was playing

    await store.send(.foreground) {
      $0.isSceneBackgrounded = false
      $0.spokenAssistantCount = 1
      $0.ttsPlayback = .preparing(self.uuid(101))
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(101)) }
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
    #expect(recorder.spokenTexts == ["Hello"])
  }

  /// How a detached chat comes back on screen: `AppFeature`'s re-push, or the view's `.task`.
  enum Return: CaseIterable, Sendable {
    case reattached, task
  }

  @Test(arguments: Return.allCases)
  func aReplyCompletedOffScreenIsConsumedWhenTheChatComesBack(_ comeBack: Return) async {
    let recorder = TTSRecorder()
    var initial = streamingSlot()
    initial.hasStarted = true // a re-appearance, not the first `.task`
    let store = makeStore(initial, recorder)

    await store.send(.viewDisappeared) { $0.isOnScreen = false }
    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
    }
    // Back on screen: not read, and consumed — the user is looking at it.
    await store.send(comeBack == .reattached ? .reattached : .task) {
      $0.isOnScreen = true
      $0.spokenAssistantCount = 1
    }
    // So no later speak edge reads it either: a lock/unlock, or a clip's idle edge.
    await store.send(.foreground)
    await store.send(.ttsFinished)
    #expect(recorder.speaks.value.isEmpty)
  }

  enum StopWhilePreparing: CaseIterable, Sendable {
    case submit, sceneBackgrounded, viewDisappeared, teardown
  }

  @Test(arguments: StopWhilePreparing.allCases)
  func aSynthesisInFlightIsCancelledByEveryStop(_ stop: StopWhilePreparing) async {
    // `.preparing`: the speak request is still out when the clip is silenced.
    let recorder = TTSRecorder()
    let speakClock = TestClock()
    let submits = LockIsolated<[JSONValue]>([])
    let store = submitStore(idleSlotWithDraft("next"), recorder, submits: submits)
    store.dependencies.hermesREST.speak = { @Sendable _, _, _ in
      try await speakClock.sleep(for: .seconds(1))
      return TTSRecorder.clip
    }

    await store.send(.readAloudTapped(id: uuid(103)))
    #expect(store.state.ttsPlayback == .preparing(uuid(103)))
    switch stop {
    case .submit: await store.send(.composerSubmitted)
    case .sceneBackgrounded: await store.send(.sceneBackgrounded)
    case .viewDisappeared: await store.send(.viewDisappeared)
    case .teardown: await store.send(.teardown)
    }
    #expect(store.state.ttsPlayback == .idle)
    await speakClock.advance(by: .seconds(1))
    await store.finish()
    #expect(recorder.plays.value.isEmpty)
    #expect(recorder.stops.value == 1)
    if stop == .submit {
      #expect(submits.value == [submitParams("next", interrupted: true)]) // a barge-in all the same
    }
  }

  enum Leave: CaseIterable, Sendable {
    case viewDisappeared, teardown, teardownSocketOnly
  }

  @Test(arguments: Leave.allCases)
  func leavingStopsAnActiveClip(_ leave: Leave) async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let store = makeStore(twoReplies(anchor: 2), recorder)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    switch leave {
    case .viewDisappeared:
      await store.send(.viewDisappeared) {
        $0.isOnScreen = false
        $0.ttsPlayback = .idle
      }
    case .teardown:
      await store.send(.teardown) { $0.ttsPlayback = .idle }
    case .teardownSocketOnly:
      await store.send(.teardownSocketOnly) {
        $0.status = .reconnecting
        $0.ttsPlayback = .idle
      }
    }
    await store.finish() // the clip effect was cancelled — no `.ttsFinished`
    #expect(recorder.stops.value == 1)
    #expect(recorder.plays.value.count == 1)
  }

  // MARK: - Keep-awake (Task 8)

  /// `makeStore` with the recording `IdleTimerClient` (every `setDisabled` value, in order).
  private func keepAwakeStore(
    _ initial: ChatFeature.State, _ recorder: TTSRecorder, idleCalls: LockIsolated<[Bool]>
  ) -> TestStoreOf<ChatFeature> {
    let store = makeStore(initial, recorder)
    store.dependencies.idleTimer = .recording(into: idleCalls)
    return store
  }

  @Test func wantsScreenAwakeNeedsAnOnScreenChatAndOneTrigger() {
    var state = ChatFeature.State(connection: conn)
    state.isOnScreen = true
    #expect(!state.wantsScreenAwake) // on screen alone

    // Each trigger alone keeps the screen awake.
    for playback in [ChatFeature.State.TTSPlayback.preparing(uuid(1)), .speaking(uuid(1))] {
      state.ttsPlayback = playback
      #expect(state.wantsScreenAwake)
    }
    state.ttsPlayback = .idle
    state.isSending = true
    #expect(!state.wantsScreenAwake) // a running turn needs auto-speak on
    state.autoSpeakReplies = true
    #expect(state.wantsScreenAwake)
    state.ttsSupported = false
    #expect(!state.wantsScreenAwake) // an agent without TTS will never read that reply
    state.ttsSupported = true
    state.isSending = false
    #expect(!state.wantsScreenAwake) // auto-speak on with nothing running
    state.autoSpeakReplies = false
    for recording in [ChatFeature.State.RecordingState.requestingPermission, .recording, .transcribing] {
      state.recording = recording
      #expect(state.wantsScreenAwake)
    }

    // Off screen (a detached slot) never keeps it awake, whatever runs.
    state.ttsPlayback = .speaking(uuid(1))
    state.autoSpeakReplies = true
    state.isSending = true
    state.isOnScreen = false
    #expect(!state.wantsScreenAwake)
  }

  @Test func playbackStartAndFinishToggleTheIdleTimer() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(twoReplies(anchor: 2), recorder, idleCalls: calls)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await waitUntil { calls.value == [true] }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) } // no edge
    await playClock.advance(by: TTSRecorder.clipLength)
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
    await store.finish()
    #expect(calls.value == [true, false])
  }

  @Test func autoSpeakOnWhileATurnRunsKeepsTheScreenAwake() async {
    // The toggle flips the running-turn trigger both ways; the read of the turn's reply
    // carries it to the clip's end, which releases it.
    let recorder = TTSRecorder()
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(streamingSlot(autoSpeak: false), recorder, idleCalls: calls)

    await store.send(.autoSpeakToggled) { $0.autoSpeakReplies = true }
    #expect(calls.value == [true])
    await store.send(.autoSpeakToggled) { $0.autoSpeakReplies = false }
    #expect(calls.value == [true, false])
    await store.send(.autoSpeakToggled) { $0.autoSpeakReplies = true }
    #expect(calls.value == [true, false, true])
    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
      $0.spokenAssistantCount = 1
      $0.ttsPlayback = .preparing(self.uuid(101))
    }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(101)) }
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
    #expect(calls.value == [true, false, true, false])
  }

  @Test func aTurnWithAutoSpeakOnStaysAwakeThroughTheReadOfItsReply() async {
    // Turn start wakes the screen; `messageComplete` hands straight over to the clip (no
    // edge in between, so no auto-lock flicker); the clip's end releases it.
    let recorder = TTSRecorder()
    let calls = LockIsolated<[Bool]>([])
    let submits = LockIsolated<[JSONValue]>([])
    var initial = idleSlotWithDraft("hi")
    initial.autoSpeakReplies = true
    let store = submitStore(initial, recorder, submits: submits)
    store.dependencies.idleTimer = .recording(into: calls)

    await store.send(.composerSubmitted) { $0.isSending = true }
    await waitUntil { calls.value == [true] }
    await store.send(.gatewayEvent(.messageStart))
    await store.send(.gatewayEvent(.messageDelta(text: "Hello")))
    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.isSending = false
    }
    #expect(store.state.ttsPlayback.isActive)
    await store.receive(\.ttsSpeaking)
    await store.receive(\.ttsFinished) { $0.ttsPlayback = .idle }
    await waitUntil { calls.value.count == 2 }
    #expect(calls.value == [true, false])
    #expect(recorder.spokenTexts == ["Hello"])
  }

  @Test func aTurnWithAutoSpeakOffNeverTouchesTheIdleTimer() async {
    let recorder = TTSRecorder()
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(streamingSlot(autoSpeak: false), recorder, idleCalls: calls)

    await store.send(.gatewayEvent(.messageComplete(text: "Hello", usage: nil))) {
      $0.transcript[id: self.uuid(101)]?.kind = .message(role: .assistant, text: "Hello", isComplete: true)
      $0.streamingRowID = nil
      $0.isSending = false
    }
    await store.finish()
    #expect(calls.value.isEmpty)
  }

  @Test func recordingKeepsTheScreenAwakeFromPermissionUntilTheTranscript() async {
    let recorder = TTSRecorder()
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(twoReplies(anchor: 2), recorder, idleCalls: calls)
    store.exhaustivity = .off(showSkippedAssertions: false)
    store.dependencies.audioRecorder.requestPermission = { @Sendable in true }
    store.dependencies.audioRecorder.startRecording = { @Sendable in }
    store.dependencies.audioRecorder.levels = { @Sendable in AsyncStream { $0.finish() } }
    store.dependencies.audioRecorder.stopRecording = { @Sendable in
      RecordedAudio(data: Data([1, 2, 3]), mimeType: "audio/m4a")
    }
    store.dependencies.hermesREST.transcribe = { @Sendable _, _, _ in "dictated" }

    await store.send(.voiceButtonTapped) { $0.recording = .requestingPermission }
    await waitUntil { calls.value == [true] }
    await store.receive(\.recordingPermission)
    await store.receive(\.recordingStarted) { $0.recording = .recording } // still awake: no edge
    await store.send(.voiceButtonTapped) { $0.recording = .transcribing }
    await store.receive(\.recordingStopped)
    await store.receive(\.transcriptionSucceeded) {
      $0.recording = .idle
      $0.composerText = "dictated"
    }
    await waitUntil { calls.value.count == 2 }
    #expect(calls.value == [true, false])
  }

  @Test func recordingDeniedReleasesTheScreen() async {
    let recorder = TTSRecorder()
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(twoReplies(anchor: 2), recorder, idleCalls: calls)
    store.dependencies.audioRecorder.requestPermission = { @Sendable in false }

    await store.send(.voiceButtonTapped) { $0.recording = .requestingPermission }
    await store.receive(\.recordingPermission) {
      $0.recording = .idle
      $0.errorBanner = "Microphone access is off. Enable it in Settings to use voice input."
    }
    await store.finish()
    #expect(calls.value == [true, false])
  }

  @Test func viewDisappearedWhilePlayingReleasesTheScreen() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(twoReplies(anchor: 2), recorder, idleCalls: calls)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    await store.send(.viewDisappeared) {
      $0.isOnScreen = false
      $0.ttsPlayback = .idle
    }
    await store.finish()
    #expect(calls.value == [true, false])
  }

  @Test func viewDisappearedReleasesARunningAutoSpeakTurnAndReappearingWakesItAgain() async {
    // The turn keeps running on the detached slot; only the on-screen gate flips.
    let recorder = TTSRecorder()
    let calls = LockIsolated<[Bool]>([])
    var initial = streamingSlot()
    initial.isOnScreen = false
    let store = keepAwakeStore(initial, recorder, idleCalls: calls)

    await store.send(.reattached) { $0.isOnScreen = true }
    await waitUntil { calls.value == [true] }
    await store.send(.viewDisappeared) { $0.isOnScreen = false }
    await store.finish()
    #expect(calls.value == [true, false])
  }

  @Test func teardownOfAnIdleSlotNeverTouchesTheIdleTimer() async {
    let recorder = TTSRecorder()
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(twoReplies(anchor: 2), recorder, idleCalls: calls)

    await store.send(.teardown)
    await store.finish()
    #expect(calls.value.isEmpty)
  }

  @Test func teardownWhilePlayingReleasesTheScreenOnce() async {
    let playClock = TestClock()
    let recorder = TTSRecorder(holdingPlaybackOn: playClock)
    let calls = LockIsolated<[Bool]>([])
    let store = keepAwakeStore(twoReplies(anchor: 2), recorder, idleCalls: calls)

    await store.send(.readAloudTapped(id: uuid(103))) { $0.ttsPlayback = .preparing(self.uuid(103)) }
    await store.receive(\.ttsSpeaking) { $0.ttsPlayback = .speaking(self.uuid(103)) }
    await store.send(.teardown) { $0.ttsPlayback = .idle }
    await store.finish()
    // The stop's `.onChange` edge. (A slot still awake after `.teardown` — a running auto-speak
    // turn — is released by `AppFeature` when it drops the slot.)
    #expect(calls.value == [true, false])
  }
}
