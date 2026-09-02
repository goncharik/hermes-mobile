import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

// Launch-intent plumbing (#93): the IntentBridge cold-launch buffer, the AppFeature
// stash-and-replay (mirroring the push-tap behavior of #46), and the ChatFeature
// voice-action arming/consumption.
@MainActor
struct LaunchIntentTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  // MARK: IntentBridge (cold-launch buffer)

  /// An intent fired with no live subscriber is buffered and drained consume-once by the
  /// first subscriber (the launch-from-intent race — mirrors the push-tap buffer #46).
  @Test func bridgeBuffersIntentBeforeSubscriberAndReplaysConsumeOnce() async {
    let bridge = IntentBridge()
    bridge.received(.startNewSession)

    var first = bridge.intentStream().makeAsyncIterator()
    #expect(await first.next() == .startNewSession)

    // Consume-once: the next subscriber receives only a NEW event, not the stale buffered
    // one. Stream construction registers synchronously, so no sleeps or scheduler races.
    var second = bridge.intentStream().makeAsyncIterator()
    bridge.received(.startNewSessionWithDictation)
    #expect(await second.next() == .startNewSessionWithDictation)
  }

  /// An intent delivered to a LIVE subscriber is not buffered (buffering exists only for
  /// the launch race).
  @Test func bridgeDeliversLiveIntentWithoutBuffering() async {
    let bridge = IntentBridge()
    var iterator = bridge.intentStream().makeAsyncIterator()
    bridge.received(.startNewSessionWithDictation)
    #expect(await iterator.next() == .startNewSessionWithDictation)
  }

  /// Recreating the root view can resend `.task`; the process-lifetime observers must not
  /// be cancelled and replaced, which would create a bridge-to-reducer event-loss window.
  @Test func repeatedTaskDoesNotRestartExternalObservers() async {
    let pushSubscriptions = LockIsolated(0)
    let intentSubscriptions = LockIsolated(0)
    var push = PushClient.testValue
    push.incomingTaps = {
      pushSubscriptions.withValue { $0 += 1 }
      return AsyncStream { $0.finish() }
    }
    var intents = IntentClient.testValue
    intents.incomingIntents = {
      intentSubscriptions.withValue { $0 += 1 }
      return AsyncStream { $0.finish() }
    }
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in nil }
      $0.preferences.loadServerURL = { nil }
      $0.push = push
      $0.launchIntent = intents
    }

    await store.send(.task) {
      $0.didStartExternalObservers = true
    }
    await store.finish()
    await store.send(.task)
    await store.finish()

    #expect(pushSubscriptions.value == 1)
    #expect(intentSubscriptions.value == 1)
  }

  // MARK: AppFeature routing

  /// A warm launch: the intent routes through the same `createSession` flow the "+"
  /// button uses — a fresh chat fills the slot with the path set to its marker.
  @Test func warmStartNewSessionCreatesFreshChat() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.launchIntentReceived(.startNewSession))
    await store.receive(\.launchIntentConfirmed)
    await store.receive(\.home.delegate.createSession)
    #expect(store.state.liveChat?.storedSessionID == nil)
    #expect(store.state.liveChat?.pendingInitialVoiceAction == nil)
    #expect(store.state.path.count == 1)
  }

  /// The dictation variant arms the new chat's initial voice action.
  @Test func warmStartDictationArmsInitialVoiceAction() async {
    let store = TestStore(
      initialState: AppFeature.State(home: SessionListFeature.State(connection: connection))
    ) {
      AppFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.launchIntentReceived(.startNewSessionWithDictation))
    await store.receive(\.launchIntentConfirmed)
    await store.receive(\.home.delegate.createSession)
    #expect(store.state.liveChat?.pendingInitialVoiceAction == .startDictation)
    #expect(store.state.path.count == 1)
  }

  /// A cold launch (no `home` yet): the intent is stashed, then replayed through the same
  /// routing once auto-connect creates the list — the new chat fills the slot.
  @Test func coldLaunchIntentIsStashedAndReplayedOnAutoConnect() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.keychain.loadSession = { @Sendable _ in .token("tok") }
      $0.preferences.loadServerURL = { "http://mac.tailnet:9119" }
      $0.hermesREST.sessions = { @Sendable _, _, _, _ in [] }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // The intent lands while still onboarding/auto-connecting → stashed, no navigation.
    await store.send(.launchIntentReceived(.startNewSession)) {
      $0.pendingLaunchIntent = .startNewSession
    }
    // Launch auto-connect completes → the stash replays into a fresh chat.
    await store.send(.task) {
      $0.didStartExternalObservers = true
      $0.didRunLaunchProbe = true
      $0.autoConnecting = true
    }
    await store.receive(\.autoConnectSucceeded)
    await store.receive(\.launchIntentReceived)
    await store.receive(\.launchIntentConfirmed)
    await store.receive(\.home.delegate.createSession)
    #expect(store.state.pendingLaunchIntent == nil)
    #expect(store.state.liveChat != nil)
    #expect(store.state.path.count == 1)
  }

  /// The stash is last-wins: a second intent before `home` replaces the first.
  @Test func coldLaunchIntentStashIsLastWins() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.launchIntentReceived(.startNewSession)) {
      $0.pendingLaunchIntent = .startNewSession
    }
    await store.send(.launchIntentReceived(.startNewSessionWithDictation)) {
      $0.pendingLaunchIntent = .startNewSessionWithDictation
    }
    // No replay while `home` is nil — the stash simply holds the newest intent.
  }

  /// A direct local Quick Action/App Intent has deterministic priority over a deferred push
  /// navigation when both cold-launch stashes exist at login. The push route is dropped;
  /// otherwise two merged effects race to decide which chat occupies the single slot.
  @Test func launchIntentWinsWhenBothColdRoutesArePending() async {
    var initial = AppFeature.State()
    initial.pendingPushTap = PushTap(sessionID: "notification-session")
    initial.pendingPushTapServerURL = URL(string: "http://hermes.test")
    initial.pendingLaunchIntent = .startNewSession
    let store = TestStore(initialState: initial) {
      AppFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.onboarding(.delegate(.connected(connection))))
    await store.receive(\.launchIntentReceived)
    await store.receive(\.launchIntentConfirmed)
    await store.receive(\.home.delegate.createSession)
    await store.finish()
    #expect(store.state.liveChat?.storedSessionID == nil)
    #expect(store.state.path.count == 1)
    #expect(store.state.pendingPushTap == nil)
  }

  /// A launch intent must not silently tear down a running turn. The slot and navigation
  /// remain untouched until the user explicitly chooses replacement.
  @Test func runningChatRaisesSlotConflictAndCancelKeepsIt() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "running")
    chat.isSending = true
    var path = StackState<ChatScreen.State>()
    path.append(ChatScreen.State(sessionKey: "running"))
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        path: path,
        liveChat: chat
      )
    ) {
      AppFeature()
    }

    await store.send(.launchIntentReceived(.startNewSession)) {
      $0.pendingConflictingLaunchIntent = .startNewSession
      $0.launchIntentConflict = ConfirmationDialogState {
        TextState("Start a new chat?")
      } actions: {
        ButtonState(role: .destructive, action: .replace) {
          TextState("Open New Chat")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "The current chat is still working or has queued prompts. Opening a new chat will leave it and discard any queued prompts on this device."
        )
      }
    }
    await store.send(.launchIntentConflict(.dismiss)) {
      $0.pendingConflictingLaunchIntent = nil
      $0.launchIntentConflict = nil
    }
    #expect(store.state.liveChat?.storedSessionID == "running")
    #expect(store.state.liveChat?.isRunning == true)
    #expect(store.state.path.count == 1)
  }

  /// A parked in-memory queue is just as loss-sensitive as an active turn.
  @Test func queuedChatRaisesSlotConflict() async {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: "queued")
    chat.queuedPrompts = [QueuedPrompt(id: UUID(0), text: "keep me")]
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection),
        liveChat: chat
      )
    ) {
      AppFeature()
    }

    await store.send(.launchIntentReceived(.startNewSessionWithDictation)) {
      $0.pendingConflictingLaunchIntent = .startNewSessionWithDictation
      $0.launchIntentConflict = ConfirmationDialogState {
        TextState("Start a new chat?")
      } actions: {
        ButtonState(role: .destructive, action: .replace) {
          TextState("Open New Chat")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "The current chat is still working or has queued prompts. Opening a new chat will leave it and discard any queued prompts on this device."
        )
      }
    }
    #expect(store.state.liveChat?.hasQueuedWork == true)
  }

  /// Explicit replacement from the conflict sheet tears the busy slot down in order, then
  /// ignores the outgoing destination's delayed disappearance so it cannot stop dictation
  /// in the replacement chat.
  @Test func confirmingSlotConflictReplacesBusyChat() async {
    var oldChat = ChatFeature.State(connection: connection, resumeStoredID: "old")
    oldChat.isSending = true
    var path = StackState<ChatScreen.State>()
    path.append(ChatScreen.State(sessionKey: "old", generation: 0))
    var initial = AppFeature.State(
      home: SessionListFeature.State(connection: connection),
      path: path,
      liveChat: oldChat
    )
    initial.pendingConflictingLaunchIntent = .startNewSessionWithDictation
    initial.launchIntentConflict = ConfirmationDialogState {
      TextState("Start a new chat?")
    } actions: {
      ButtonState(role: .destructive, action: .replace) { TextState("Open New Chat") }
    }
    let clock = TestClock()
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = clock
      $0.audioRecorder.levels = { AsyncStream { $0.finish() } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.launchIntentConflict(.presented(.replace))) {
      $0.pendingConflictingLaunchIntent = nil
      $0.launchIntentConflict = nil
    }
    await store.receive(\.launchIntentConfirmed)
    await store.receive(\.home.delegate.createSession)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
      $0.liveChatGeneration = 1
    }
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.pendingInitialVoiceAction == .startDictation)
    #expect(store.state.liveChatGeneration == 1)
    #expect(store.state.path.count == 1)
    #expect(store.state.path.last?.generation == 1)

    // Model dictation already running in the new slot before the old SwiftUI destination's
    // delayed `onDisappear` arrives. Generation 0 no longer owns generation 1, so cleanup
    // must not be forwarded to the replacement chat.
    await store.send(.liveChat(.recordingStarted)) {
      $0.liveChat?.recording = .recording
      $0.liveChat?.waveformLevels = []
      $0.liveChat?.recordingSeconds = 0
    }
    await store.send(.chatViewDisappeared(generation: 0))
    #expect(store.state.liveChat?.recording == .recording)
    #expect(store.state.liveChat?.pendingInitialVoiceAction == .startDictation)

    // The current destination still owns normal voice cleanup.
    await store.send(.chatViewDisappeared(generation: 1))
    await store.receive(\.liveChat.viewDisappeared) {
      $0.liveChat?.recording = .idle
      $0.liveChat?.waveformLevels = []
      $0.liveChat?.recordingSeconds = 0
    }
    await store.finish()
  }

  /// Logout clears the identity-scoped stash: an intent stashed before login must not
  /// replay into a later login.
  @Test func disconnectClearsPendingLaunchIntent() async {
    var initial = AppFeature.State(
      home: SessionListFeature.State(connection: connection)
    )
    // Structurally this stash normally exists only while `home == nil`; seed it directly
    // to test the logout path's defensive identity cleanup without first replaying it.
    initial.pendingLaunchIntent = .startNewSession
    let store = TestStore(
      initialState: initial
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.home(.delegate(.disconnect))) {
      $0.pendingLaunchIntent = nil
    }
    #expect(store.state.pendingLaunchIntent == nil)
    #expect(store.state.home == nil)
  }

  // MARK: ChatFeature voice-action consumption

  /// The armed dictation fires exactly once when the chat's slot reaches `.ready` —
  /// driven here through a RECONNECT `.ready` (`hasRequestedSession` already true), which
  /// flips the status with no bootstrap RPC, so the consumption is fully deterministic.
  /// The voice flow proceeds exactly as a mic-button tap: permission → recording.
  @Test func armedDictationFiresVoiceTapWhenReady() async {
    var chat = ChatFeature.State(connection: connection, composerText: "")
    chat.pendingInitialVoiceAction = .startDictation
    chat.status = .reconnecting
    chat.hasRequestedSession = true
    let store = TestStore(initialState: chat) {
      ChatFeature()
    } withDependencies: {
      $0.continuousClock = TestClock() // unadvanced → the recording timer never ticks
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
      // The `.ready` transition consumed the armed action: the voice tap fired.
      $0.pendingInitialVoiceAction = nil
    }
    // The voice flow proceeds exactly as a manual tap: permission granted → recording
    // starts (the test recorder grants + yields its 3 canned level samples).
    await store.receive(\.voiceButtonTapped) { $0.recording = .requestingPermission }
    await store.receive(\.recordingPermission)
    await store.receive(\.recordingStarted) {
      $0.recording = .recording
      $0.waveformLevels = []
      $0.recordingSeconds = 0
    }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2] }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2, 0.6] }
    await store.receive(\.recordingLevel) { $0.waveformLevels = [0.2, 0.6, 0.4] }
    // The real view owns the recording timer's lifetime. Simulate leaving so the test also
    // proves the intent-triggered recording cleans up through the normal voice path.
    await store.send(.viewDisappeared) {
      $0.recording = .idle
      $0.waveformLevels = []
      $0.recordingSeconds = 0
    }
    await store.finish()
  }

  /// A chat with NO armed action is unaffected by `.ready` (no stray recording).
  @Test func noArmedActionStaysIdleOnReady() async {
    var chat = ChatFeature.State(connection: connection)
    chat.status = .reconnecting
    chat.hasRequestedSession = true
    let store = TestStore(initialState: chat) {
      ChatFeature()
    }

    await store.send(.gatewayEvent(.ready)) {
      $0.status = .ready
    }
    #expect(store.state.recording == .idle)
    #expect(store.state.pendingInitialVoiceAction == nil)
  }
}