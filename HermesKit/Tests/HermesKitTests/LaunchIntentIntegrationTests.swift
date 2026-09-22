import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct LaunchIntentIntegrationTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://hermes.test")!, token: "tok")

  @Test func bridgeBuffersOnlyLatestIntent() async {
    let bridge = IntentBridge()
    bridge.received(.startNewSession)
    bridge.received(.startNewSessionWithDictation)
    var events = bridge.intentStream().makeAsyncIterator()
    #expect(await events.next() == .startNewSessionWithDictation)
  }

  @Test(arguments: [AppFeature.Layout.compact, .regular])
  func retryReplaysDictationUnderSelectedProfile(layout: AppFeature.Layout) async {
    var initial = AppFeature.State(layout: layout)
    initial.connectionFailed = .init(connection: connection, reason: .offline)
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.preferences.loadSelectedProfileID = { "work" }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.launchIntentReceived(.startNewSessionWithDictation))
    await store.send(.connectionFailed(.delegate(.connected(connection))))
    await store.receive(\.launchIntentReceived)
    await store.receive(\.launchIntentConfirmed)
    await store.receive(\.home.delegate.createSession)
    await store.finish()
    #expect(store.state.liveChat?.profileName == "work")
    #expect(store.state.liveChat?.pendingInitialVoiceAction == .startDictation)
    #expect(store.state.path.count == (layout == .compact ? 1 : 0))
  }

  @Test(arguments: [ChatFeature.State.Status.ready, .connecting])
  func reusableRegularSeatStartsOrArmsDictation(status: ChatFeature.State.Status) async {
    var chat = ChatFeature.State(connection: connection)
    chat.status = status
    chat.hasRequestedSession = true
    chat.composerText = "old draft"
    let store = TestStore(initialState: AppFeature.State(
      home: SessionListFeature.State(connection: connection), liveChat: chat, layout: .regular
    )) { AppFeature() } withDependencies: {
      // A denied permission is a bounded way to verify the normal voice flow, not a
      // shortcut-specific error. No socket or recording timer should be started.
      $0.audioRecorder.requestPermission = { false }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.launchIntentReceived(.startNewSessionWithDictation))
    await store.receive(\.launchIntentConfirmed)
    await store.receive(\.home.delegate.createSession)
    #expect(store.state.slotGeneration == 0, "reuse must not replace the seat or redial")
    #expect(store.state.liveChat?.composerText == "")
    if status != .ready {
      #expect(store.state.liveChat?.pendingInitialVoiceAction == .startDictation)
      await store.send(.liveChat(.gatewayEvent(.ready)))
    }
    await store.receive(\.liveChat.voiceButtonTapped)
    await store.receive(\.liveChat.recordingPermission)
    await store.finish()
    #expect(store.state.liveChat?.pendingInitialVoiceAction == nil)
    #expect(store.state.liveChat?.recording == .idle)
    #expect(store.state.liveChat?.errorBanner != nil)
    #expect(store.state.path.isEmpty)
  }

  @Test func consumedDictationDoesNotRearmOnReconnect() async {
    var chat = ChatFeature.State(connection: connection)
    chat.pendingInitialVoiceAction = .startDictation
    chat.hasRequestedSession = true
    let permissions = LockIsolated(0)
    let store = TestStore(initialState: chat) { ChatFeature() } withDependencies: {
      $0.audioRecorder.requestPermission = {
        permissions.withValue { $0 += 1 }
        return false
      }
      $0.continuousClock = TestClock()
      $0.hermesGateway.send = { _, _ in
        .object(["session_id": .string("live"), "stored_session_id": .string("stored")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.gatewayEvent(.ready))
    await store.receive(\.voiceButtonTapped)
    await store.receive(\.recordingPermission)
    await store.send(.gatewayClosed)
    await store.send(.gatewayEvent(.ready))
    #expect(store.state.pendingInitialVoiceAction == nil)
    #expect(permissions.value == 1)
    await store.send(.teardown)
    await store.finish()
  }
}
