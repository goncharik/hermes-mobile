import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct SettingsFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  @Test func clearTokenDeletesAndEmitsDisconnect() async {
    let deleted = LockIsolated(false)
    let preferences = PreferencesClient.inMemory()
    preferences.saveServerURL("http://mac.tailnet:9119")
    preferences.savePinnedIDs(["s1"])
    preferences.saveSeenCounts(["s1": 4])
    preferences.saveGroupingMode(.chronological)
    preferences.saveDefaultSessionSwipeAction(.delete)
    preferences.saveSelectedProfileID("staging")
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      // Logout deletes the full session (token + any gated cookies), not just the token.
      $0.keychain.deleteSession = { @Sendable in deleted.setValue(true) }
      $0.preferences = preferences
      $0.dismiss = DismissEffect {}
    }

    await store.send(.clearTokenTapped)
    await store.receive(\.delegate.disconnect)
    #expect(deleted.value)
    #expect(preferences.loadServerURL() == nil) // logout forgets the server URL too
    #expect(preferences.loadPinnedIDs() == []) // pins are per-server — cleared on logout
    #expect(preferences.loadSeenCounts() == [:]) // unread state cleared too
    #expect(preferences.loadGroupingMode() == .workspace) // grouping pref reset on logout
    #expect(preferences.loadDefaultSessionSwipeAction() == .archive) // swipe pref reset on logout
    #expect(preferences.loadShowCronSection() == true) // cron-section visibility reset on logout
    #expect(preferences.loadSelectedProfileID() == nil) // selected profile cleared on logout
  }

  @Test func clearTokenWipesChatSnapshotStore() async {
    // Logout must clear the non-authoritative chat cache (snapshots + turn anchors) too —
    // they are per-server, like the prefs cleared above.
    let chatSnapshot = ChatSnapshotClient.inMemory()
    let now = Date(timeIntervalSince1970: 1_000)
    chatSnapshot.saveSnapshot("s1", ChatSnapshot(model: "claude-opus-4-8", updatedAt: now))
    chatSnapshot.setTurnAnchor("s1", now)
    // Seeded state is present before logout.
    #expect(chatSnapshot.loadSnapshot("s1") != nil)
    #expect(chatSnapshot.turnAnchor("s1") == now)

    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.keychain.deleteToken = { @Sendable in }
      $0.preferences = PreferencesClient.inMemory()
      $0.chatSnapshot = chatSnapshot
      $0.dismiss = DismissEffect {}
    }

    await store.send(.clearTokenTapped)
    await store.receive(\.delegate.disconnect)
    // The snapshot store is empty after logout.
    #expect(chatSnapshot.loadSnapshot("s1") == nil)
    #expect(chatSnapshot.turnAnchor("s1") == nil)
  }

  @Test func reconnectEmitsReconnectDelegate() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect {}
    }

    await store.send(.reconnectTapped)
    await store.receive(\.delegate.reconnect)
  }

  @Test func saveTokenPersistsAndEmitsTokenSaved() async {
    let saved = LockIsolated<String?>(nil)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.keychain.saveToken = { @Sendable token in saved.setValue(token) }
    }

    // Edit the token so it differs from the stored one.
    await store.send(\.binding.token, "newtok") {
      $0.token = "newtok"
      $0.savedConfirmation = false
    }
    await store.send(.saveTokenTapped) {
      $0.connection.token = "newtok"
      $0.savedConfirmation = true
    }
    await store.receive(\.delegate.tokenSaved)
    #expect(saved.value == "newtok")
  }

  @Test func saveTokenNoOpWhenUnchanged() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    }
    // token == connection.token → canSaveToken is false → no effect.
    #expect(!store.state.canSaveToken)
    await store.send(.saveTokenTapped)
  }

  @Test func taskStreamsDebugLogEntries() async {
    let entries = [
      GatewayLogEntry(id: 0, type: "gateway.ready", summary: ""),
      GatewayLogEntry(id: 1, type: "message.delta", summary: "Hello"),
    ]
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.debugLog.stream = { @Sendable in
        AsyncStream { continuation in
          continuation.yield(entries)
          continuation.finish()
        }
      }
      // `.task` also probes the plugin hub for the version. `.unknown` offers no update.
      $0.hermesREST.pushPluginInfo = { @Sendable _ in PushPluginInfo(status: .unknown) }
    }

    await store.send(.task)
    // `.task` merges three concurrent effects (log stream, OS authorization status, plugin
    // hub probe); their completion order isn't guaranteed, so assert only this test's
    // subject rather than pinning an incidental interleaving.
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.receive(\.logUpdated) {
      $0.log = entries
    }
    await store.send(.doneTapped)
  }

  // MARK: Notifications (C6)

  @Test func taskLoadsAuthorizationStatusIntoToggle() async {
    let push = PushClient.inMemory(granted: true, status: .authorized)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.debugLog.stream = { @Sendable in AsyncStream { $0.finish() } }
      $0.push = push.client
      $0.hermesREST.pushPluginInfo = { @Sendable _ in PushPluginInfo(status: .unknown) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task)
    await store.receive(\.authorizationStatusLoaded) {
      $0.notificationsEnabled = true
      $0.notificationsDenied = false
    }
    await store.send(.doneTapped)
  }

  @Test func toggleOnWhenGrantedEnablesAndRegisters() async {
    let registered = LockIsolated<[String]>([])
    let push = PushClient.inMemory(granted: true, status: .notDetermined)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = .inMemory()
      // A non-advancing TestClock: the token arrives first, so the timeout never fires.
      $0.continuousClock = TestClock()
      $0.hermesREST.registerPush = { @Sendable _, token, _, _ in
        registered.withValue { $0.append(token) }
      }
    }

    await store.send(.notificationsToggled(true))
    // The register effect subscribes to the token stream; drive a token in.
    push.emit(token: "tok-1")
    await store.receive(\.authorizationResult) {
      $0.notificationsEnabled = true
      $0.notificationsDenied = false
    }
    #expect(registered.value == ["tok-1"])
  }

  @Test func toggleOnWhenDeniedShowsGuidance() async {
    let push = PushClient.inMemory(granted: false, status: .notDetermined)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.push = push.client
    }

    await store.send(.notificationsToggled(true))
    await store.receive(\.authorizationResult) {
      $0.notificationsEnabled = false
      $0.notificationsDenied = true
    }
  }

  @Test func toggleOffJustReflectsIntent() async {
    let store = TestStore(
      initialState: SettingsFeature.State(connection: connection, notificationsEnabled: true)
    ) { SettingsFeature() }
    await store.send(.notificationsToggled(false)) {
      $0.notificationsEnabled = false
    }
  }

  @Test func sendTestPushTransitionsToSent() async {
    let sent = LockIsolated(false)
    let push = PushClient.inMemory(granted: true, status: .authorized)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesREST.registerPush = { @Sendable _, _, _, _ in }
      $0.hermesREST.sendTestPush = { @Sendable _ in sent.setValue(true) }
    }

    await store.send(.sendTestPushTapped) {
      $0.testPushStatus = .sending
    }
    // The register step subscribes to the token stream first.
    push.emit(token: "tok-1")
    await store.receive(\.testPushResult) {
      $0.testPushStatus = .sent
    }
    #expect(sent.value)
  }

  @Test func sendTestPushFailureTransitionsToFailed() async {
    let push = PushClient.inMemory(granted: true, status: .authorized)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = .inMemory()
      $0.continuousClock = TestClock()
      $0.hermesREST.registerPush = { @Sendable _, _, _, _ in }
      $0.hermesREST.sendTestPush = { @Sendable _ in throw RESTError.notFound }
    }

    await store.send(.sendTestPushTapped) {
      $0.testPushStatus = .sending
    }
    push.emit(token: "tok-1")
    await store.receive(\.testPushResult) {
      $0.testPushStatus = .failed
    }
  }

  @Test func sendTestPushTimesOutWhenNoTokenAndFailsFast() async {
    // No token is ever emitted (no entitlement / offline / simulator) and nothing is persisted.
    // The bounded wait must expire and the test-send must fail rather than hang on `.sending`.
    let clock = TestClock()
    let sent = LockIsolated(false)
    let push = PushClient.inMemory(granted: true, status: .authorized)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = .inMemory() // no persisted token to fall back to
      $0.continuousClock = clock
      $0.hermesREST.registerPush = { @Sendable _, _, _, _ in }
      $0.hermesREST.sendTestPush = { @Sendable _ in sent.setValue(true) }
    }

    await store.send(.sendTestPushTapped) {
      $0.testPushStatus = .sending
    }
    // Advance past the bounded wait → the timeout wins, no token, registration fails.
    await clock.advance(by: .seconds(5))
    await store.receive(\.testPushResult) {
      $0.testPushStatus = .failed
    }
    #expect(sent.value == false) // never reached the test-send
  }

  @Test func sendTestPushFallsBackToPersistedTokenWhenNoneArrives() async {
    // No live token arrives, but a token was persisted on a prior registration — fall back to it.
    let clock = TestClock()
    let sent = LockIsolated(false)
    let registeredToken = LockIsolated<String?>(nil)
    let push = PushClient.inMemory(granted: true, status: .authorized)
    var prefs = PreferencesClient.inMemory()
    prefs.savePushDeviceToken("persisted-tok")
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.push = push.client
      $0.preferences = prefs
      $0.continuousClock = clock
      $0.hermesREST.registerPush = { @Sendable _, token, _, _ in registeredToken.setValue(token) }
      $0.hermesREST.sendTestPush = { @Sendable _ in sent.setValue(true) }
    }

    await store.send(.sendTestPushTapped) {
      $0.testPushStatus = .sending
    }
    await clock.advance(by: .seconds(5))
    await store.receive(\.testPushResult) {
      $0.testPushStatus = .sent
    }
    #expect(registeredToken.value == "persisted-tok")
    #expect(sent.value)
  }

  // MARK: - Plugin update (hermes-push 0.2.0 subagent filtering)

  /// An outdated, git-updatable plugin offers the one-tap update.
  @Test func outdatedGitPluginOffersTheUpdate() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.pushPluginInfo = { @Sendable _ in
        PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
      }
    }
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\.pushPluginInfoLoaded) {
      $0.pushPlugin = PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
    }
    #expect(store.state.pluginUpdateAvailable)
    #expect(!store.state.pluginUpdateNeedsManualSteps)
    await store.send(.doneTapped)
  }

  /// Outdated but NOT a git checkout → no button (it would only 400); route to the guide.
  @Test func outdatedNonGitPluginAsksForManualSteps() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.pushPluginInfo = { @Sendable _ in
        PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: false)
      }
    }
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\.pushPluginInfoLoaded)
    #expect(!store.state.pluginUpdateAvailable)
    #expect(store.state.pluginUpdateNeedsManualSteps)
    await store.send(.doneTapped)
  }

  /// A current plugin — and an agent that reports no version at all — offer nothing.
  @Test func currentOrUnknownPluginOffersNoUpdate() async {
    for info in [
      PushPluginInfo(status: .ready, version: PushSetup.minimumPluginVersion, canUpdateGit: true),
      PushPluginInfo(status: .ready, version: nil, canUpdateGit: true),
      PushPluginInfo(status: .unknown),
    ] {
      let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
        SettingsFeature()
      } withDependencies: {
        $0.hermesREST.pushPluginInfo = { @Sendable _ in info }
      }
      store.exhaustivity = .off

      await store.send(.task)
      await store.receive(\.pushPluginInfoLoaded)
      #expect(!store.state.pluginUpdateAvailable)
      #expect(!store.state.pluginUpdateNeedsManualSteps)
      await store.send(.doneTapped)
    }
  }

  /// A successful pull lands on `.updated` — the state the view renders the RESTART notice
  /// from. It must not read as a plain success: the new code isn't running yet.
  @Test func successfulUpdateRequiresARestart() async {
    let called = LockIsolated(false)
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection,
        pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
      )
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.updatePushPlugin = { @Sendable _ in
        called.setValue(true)
        return PushPluginUpdateResult(unchanged: false)
      }
    }

    await store.send(.updatePluginTapped) { $0.pluginUpdate = .updating }
    await store.receive(\.pluginUpdateResult) { $0.pluginUpdate = .updated }
    #expect(called.value)
    // The offer is withdrawn once acted on — the outstanding action is a restart, and the hub
    // would report the NEW version off disk while the old code is still loaded.
    #expect(!store.state.pluginUpdateAvailable)
  }

  /// "Already up to date" is a distinct state — there is nothing to restart for.
  @Test func unchangedPullDoesNotAskForARestart() async {
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection,
        pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
      )
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.updatePushPlugin = { @Sendable _ in PushPluginUpdateResult(unchanged: true) }
    }

    await store.send(.updatePluginTapped) { $0.pluginUpdate = .updating }
    await store.receive(\.pluginUpdateResult) { $0.pluginUpdate = .alreadyCurrent }
  }

  /// The agent's own reason reaches the UI verbatim — the user has to act on it on their host.
  @Test func failedUpdateSurfacesTheServerReason() async {
    let detail = "Plugin 'hermes-push' is not a git checkout; cannot pull updates."
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection,
        pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
      )
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.updatePushPlugin = { @Sendable _ in
        throw RESTError.server(status: 400, detail: detail)
      }
    }

    await store.send(.updatePluginTapped) { $0.pluginUpdate = .updating }
    await store.receive(\.pluginUpdateResult) { $0.pluginUpdate = .failed(detail) }
  }

  /// A non-`RESTError` failure still resolves the button rather than leaving it spinning.
  @Test func unexpectedUpdateFailureStillResolves() async {
    struct Boom: Error {}
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection,
        pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
      )
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.updatePushPlugin = { @Sendable _ in throw Boom() }
    }

    await store.send(.updatePluginTapped) { $0.pluginUpdate = .updating }
    await store.receive(\.pluginUpdateResult) {
      $0.pluginUpdate = .failed(RESTError.unreachable.message)
    }
  }

  /// A second tap while a pull is in flight is a no-op — no duplicate request.
  @Test func updateTapIsIgnoredWhileInFlight() async {
    let calls = LockIsolated(0)
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection,
        pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true),
        pluginUpdate: .updating
      )
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.updatePushPlugin = { @Sendable _ in
        calls.withValue { $0 += 1 }
        return PushPluginUpdateResult(unchanged: false)
      }
    }

    await store.send(.updatePluginTapped) // already `.updating` → no state change, no effect
    #expect(calls.value == 0)
  }

  // MARK: Default swipe action (issue #73)

  /// Picking a new default persists it via `PreferencesClient` and bubbles a delegate so
  /// the session list mirrors it before the sheet even dismisses.
  @Test func swipeActionChangePersistsAndBubbles() async {
    let preferences = PreferencesClient.inMemory()
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.preferences = preferences
    }

    await store.send(.defaultSwipeActionChanged(.delete)) {
      $0.defaultSwipeAction = .delete
    }
    await store.receive(\.delegate.defaultSwipeActionChanged)
    #expect(preferences.loadDefaultSessionSwipeAction() == .delete)

    // And back — the picker is a toggle both ways, not a one-shot.
    await store.send(.defaultSwipeActionChanged(.archive)) {
      $0.defaultSwipeAction = .archive
    }
    await store.receive(\.delegate.defaultSwipeActionChanged)
    #expect(preferences.loadDefaultSessionSwipeAction() == .archive)
  }
}
