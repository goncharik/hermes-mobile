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
    preferences.saveDefaultSessionSwipeAction(.delete)
    preferences.saveSelectedProfileID("staging")
    preferences.saveAutoSpeakReplies(true)
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
    #expect(preferences.loadDefaultSessionSwipeAction() == .archive) // swipe pref reset on logout
    #expect(preferences.loadSelectedProfileID() == nil) // selected profile cleared on logout
    #expect(preferences.loadAutoSpeakReplies() == false) // read-aloud toggle off after logout
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

  // MARK: Appearance seeding (#137)

  /// `.task` reads bundle info + the icon catalog synchronously, then lands the agent version
  /// and the current icon. Every other `.task` effect is stubbed to a no-change outcome.
  @Test func taskSeedsBundleInfoAgentVersionAndCurrentIcon() async {
    let probedURL = LockIsolated<URL?>(nil)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.appIcon = .inMemory(current: "AppIconHermes")
      $0.hermesREST.status = { @Sendable url in
        probedURL.setValue(url)
        return ServerStatus(version: "0.17.2")
      }
      $0.hermesREST.pushPluginInfo = { @Sendable _ in PushPluginInfo(status: .unknown) }
      $0.push = PushClient.inMemory(granted: false, status: .notDetermined).client
    }
    // `.task` merges concurrent effects whose completion order isn't guaranteed.
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task) {
      $0.bundleInfo = .test
      $0.appIconCatalog = .testCatalog
    }
    await store.receive(\.agentStatusLoaded) { $0.agentVersion = "0.17.2" }
    await store.receive(\.currentAppIconLoaded) { $0.selectedAppIcon = "AppIconHermes" }
    #expect(probedURL.value == connection.baseURL)
    #expect(store.state.versionLabel == "Version 1.0 (79)")
    #expect(store.state.selectedAppIconLabel == "Hermes")
    await store.send(.doneTapped)
  }

  /// A failed `/api/status` probe leaves the version `nil` (Agent row hidden) — no banner.
  @Test func statusFailureLeavesAgentVersionNil() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in throw RESTError.unreachable }
      $0.hermesREST.pushPluginInfo = { @Sendable _ in PushPluginInfo(status: .unknown) }
      $0.push = PushClient.inMemory(granted: false, status: .notDetermined).client
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task)
    await store.receive(\.agentStatusLoaded, nil)
    #expect(store.state.agentVersion == nil)
    await store.send(.doneTapped)
  }

  /// An agent that answers `/api/status` without a version also leaves the row hidden.
  @Test func statusWithoutVersionLeavesAgentVersionNil() async {
    let store = TestStore(
      initialState: SettingsFeature.State(connection: connection, agentVersion: "stale")
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.hermesREST.status = { @Sendable _ in ServerStatus() }
      $0.hermesREST.pushPluginInfo = { @Sendable _ in PushPluginInfo(status: .unknown) }
      $0.push = PushClient.inMemory(granted: false, status: .notDetermined).client
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.task)
    await store.receive(\.agentStatusLoaded) { $0.agentVersion = nil }
    await store.send(.doneTapped)
  }

  // MARK: Derived labels (#137)

  @Test func authLabelAndTokenFieldFollowTheRegime() {
    let base = connection.baseURL
    let token = SettingsFeature.State(connection: connection)
    #expect(token.authLabel == "Token")
    #expect(token.showsTokenField)
    #expect(token.authSession == .token("tok"))

    let cookie = SettingsFeature.State(
      connection: ServerConnection(
        baseURL: base,
        auth: .cookie(CookieSession(cookies: [], username: "alice", provider: "basic"))
      )
    )
    #expect(cookie.authLabel == "Password · alice")
    #expect(!cookie.showsTokenField)

    let bearer = SettingsFeature.State(
      connection: ServerConnection(
        baseURL: base,
        auth: .bearer(
          BearerSession(
            accessToken: "at", refreshToken: "rt", expiresAt: 1, provider: "nous",
            userID: "user-42"
          )
        )
      )
    )
    #expect(bearer.authLabel == "nous · user-42")
    #expect(!bearer.showsTokenField)
  }

  @Test func labelsAreNilUntilLoaded() {
    let state = SettingsFeature.State(connection: connection)
    #expect(state.versionLabel == nil)
    #expect(state.selectedAppIconLabel == nil)
    #expect(state.agentVersion == nil)
    #expect(state.profileName == nil)
  }

  @Test func feedbackLinksCarryBundleInfoOnceLoaded() {
    var state = SettingsFeature.State(connection: connection)
    #expect(state.reportBugURL == FeedbackLinks.allIssues)
    #expect(state.requestFeatureURL == FeedbackLinks.allIssues)
    state.bundleInfo = .test
    #expect(state.reportBugURL == FeedbackLinks.reportBug(.test))
    #expect(state.requestFeatureURL == FeedbackLinks.requestFeature(.test))
  }

  @Test func selectedAppIconLabelNilMeansPrimary() {
    var state = SettingsFeature.State(connection: connection, appIconCatalog: .testCatalog)
    #expect(state.selectedAppIconLabel == "Gold")
    state.selectedAppIcon = "AppIconHermesClassicBlueprint"
    #expect(state.selectedAppIconLabel == "Hermes Classic Blueprint")
  }

  // MARK: Sub-screen pushes (#137)

  @Test func appIconRowPushesPickerSeededFromParent() async {
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection, appIconCatalog: .testCatalog, selectedAppIcon: "AppIconHermes"
      )
    ) {
      SettingsFeature()
    }

    await store.send(.appIconRowTapped) {
      $0.path[id: 0] = .appIcon(
        AppIconPickerFeature.State(catalog: .testCatalog, selected: "AppIconHermes")
      )
    }
  }

  @Test func diagnosticsRowPushesDiagnosticsSeededFromParent() async {
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection, agentVersion: "0.17.2", bundleInfo: .test
      )
    ) {
      SettingsFeature()
    }

    await store.send(.diagnosticsRowTapped) {
      $0.path[id: 0] = .diagnostics(
        DiagnosticsFeature.State(
          bundleInfo: .test,
          serverURL: self.connection.baseURL,
          authLabel: "Token",
          agentVersion: "0.17.2"
        )
      )
    }
  }

  @Test func acknowledgementsRowPushesAcknowledgements() async {
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    }

    await store.send(.acknowledgementsRowTapped) {
      $0.path[id: 0] = .acknowledgements(AcknowledgementsFeature.State())
    }
    #expect(Acknowledgement.all.map(\.name) == [
      "GRDB.swift", "swift-composable-architecture", "swift-dependencies",
    ])
  }

  /// A confirmed change in the pushed picker updates the App Icon row value.
  @Test func iconChangedDelegateUpdatesSelectedIcon() async {
    let setNames = LockIsolated<[String?]>([])
    let store = TestStore(
      initialState: SettingsFeature.State(connection: connection, appIconCatalog: .testCatalog)
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.appIcon.set = { @Sendable name in setNames.withValue { $0.append(name) } }
    }

    await store.send(.appIconRowTapped) {
      $0.path[id: 0] = .appIcon(AppIconPickerFeature.State(catalog: .testCatalog, selected: nil))
    }
    await store.send(\.path[id: 0].appIcon.iconTapped, "AppIconHermesClassic") {
      $0.path[id: 0, case: \.appIcon]?.selected = "AppIconHermesClassic"
    }
    await store.receive(\.path[id: 0].appIcon.delegate.iconChanged) {
      $0.selectedAppIcon = "AppIconHermesClassic"
    }
    #expect(setNames.value == ["AppIconHermesClassic"])
    #expect(store.state.selectedAppIconLabel == "Hermes Classic")
  }

  /// A refused change never reaches the parent — the row keeps the previous icon.
  @Test func refusedIconChangeLeavesSelectedIcon() async {
    struct Refused: Error {}
    let store = TestStore(
      initialState: SettingsFeature.State(connection: connection, appIconCatalog: .testCatalog)
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.appIcon.set = { @Sendable _ in throw Refused() }
    }

    await store.send(.appIconRowTapped) {
      $0.path[id: 0] = .appIcon(AppIconPickerFeature.State(catalog: .testCatalog, selected: nil))
    }
    await store.send(\.path[id: 0].appIcon.iconTapped, "AppIconHermes") {
      $0.path[id: 0, case: \.appIcon]?.selected = "AppIconHermes"
    }
    await store.receive(\.path[id: 0].appIcon.setFailed) {
      $0.path[id: 0, case: \.appIcon]?.selected = nil
      $0.path[id: 0, case: \.appIcon]?.errorBanner = AppIconPickerFeature.setFailedBanner
    }
    #expect(store.state.selectedAppIcon == nil)
  }

  /// Sign out leaves the home-screen icon alone (iOS owns that choice, not the account).
  @Test func clearTokenNeverTouchesTheAppIcon() async {
    let setCalled = LockIsolated(false)
    let store = TestStore(
      initialState: SettingsFeature.State(
        connection: connection, appIconCatalog: .testCatalog, selectedAppIcon: "AppIconHermes"
      )
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.keychain.deleteSession = { @Sendable in }
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.appIcon.set = { @Sendable _ in setCalled.setValue(true) }
      $0.dismiss = DismissEffect {}
    }

    await store.send(.clearTokenTapped)
    await store.receive(\.delegate.disconnect)
    #expect(!setCalled.value)
  }

  // MARK: Notifications (C6)

  @Test func taskLoadsAuthorizationStatusIntoToggle() async {
    let push = PushClient.inMemory(granted: true, status: .authorized)
    let store = TestStore(initialState: SettingsFeature.State(connection: connection)) {
      SettingsFeature()
    } withDependencies: {
      $0.push = push.client
      $0.hermesREST.status = { @Sendable _ in ServerStatus() }
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
      $0.hermesREST.status = { @Sendable _ in ServerStatus() }
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
      $0.hermesREST.status = { @Sendable _ in ServerStatus() }
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
        $0.hermesREST.status = { @Sendable _ in ServerStatus() }
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
