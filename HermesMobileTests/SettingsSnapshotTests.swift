import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class SettingsSnapshotTests: SnapshotTestCase {
  /// The six-group Form runs well past one phone screen; every Form fixture renders at this
  /// height so the whole Form — Sign out included — is in frame and the groups below the fold
  /// (Feedback, About) are proven too, not just the Server block.
  private let formHeight: CGFloat = 1_800

  /// A fully loaded token-regime Settings: the post-`.task` facts (bundle info, icon catalog,
  /// agent version) are SEEDED, because the fixtures swallow `.task` (see `ignoring`).
  private func loadedState(
    auth: AuthSession? = nil,
    profileName: String? = nil,
    pushAvailable: Bool = true,
    notificationsEnabled: Bool = false,
    testPushStatus: SettingsFeature.State.TestPushStatus = .idle,
    pushPlugin: PushPluginInfo? = nil,
    pluginUpdate: SettingsFeature.State.PluginUpdateStatus = .idle,
    deleteSupported: Bool = true
  ) -> SettingsFeature.State {
    SettingsFeature.State(
      connection: auth.map { ServerConnection(baseURL: connection.baseURL, auth: $0) } ?? connection,
      pushAvailable: pushAvailable,
      notificationsEnabled: notificationsEnabled,
      testPushStatus: testPushStatus,
      pushPlugin: pushPlugin,
      pluginUpdate: pluginUpdate,
      deleteSupported: deleteSupported,
      profileName: profileName,
      agentVersion: "0.12.0",
      bundleInfo: .test,
      appIconCatalog: .testCatalog,
      selectedAppIcon: nil
    )
  }

  private func settingsView(_ state: SettingsFeature.State) -> some View {
    SettingsView(
      store: Store(initialState: state) { SettingsFeature().ignoring(\.task) }
    )
  }

  private let cookieAuth = AuthSession.cookie(
    CookieSession(cookies: [], username: "alice", provider: "basic")
  )
  private let bearerAuth = AuthSession.bearer(
    BearerSession(
      accessToken: "at", refreshToken: "rt", expiresAt: 1, provider: "nous", userID: "user-42"
    )
  )

  // MARK: Auth regimes (#137)

  /// Token regime: Auth row reads "Token" and the re-paste field + Save button are present.
  func testSettingsView() {
    assertSnapshot(of: settingsView(loadedState()), as: deviceImage(height: formHeight))
  }

  func testSettingsView_light() {
    assertSnapshot(
      of: settingsView(loadedState()),
      as: deviceImage(appearance: .light, height: formHeight)
    )
  }

  /// Password (cookie) regime: "Password · alice", and NO token field — a gated session has
  /// no token to re-paste.
  func testSettingsView_cookie() {
    assertSnapshot(of: settingsView(loadedState(auth: cookieAuth)), as: deviceImage())
  }

  func testSettingsView_cookie_light() {
    assertSnapshot(
      of: settingsView(loadedState(auth: cookieAuth)),
      as: deviceImage(appearance: .light)
    )
  }

  /// OAuth (bearer) regime: "nous · user-42", no token field.
  func testSettingsView_bearer() {
    assertSnapshot(of: settingsView(loadedState(auth: bearerAuth)), as: deviceImage())
  }

  func testSettingsView_bearer_light() {
    assertSnapshot(
      of: settingsView(loadedState(auth: bearerAuth)),
      as: deviceImage(appearance: .light)
    )
  }

  /// An agent with the profiles API: the Profile row appears between Auth and Agent.
  func testSettingsView_profile() {
    assertSnapshot(of: settingsView(loadedState(profileName: "work")), as: deviceImage())
  }

  func testSettingsView_profile_light() {
    assertSnapshot(
      of: settingsView(loadedState(profileName: "work")),
      as: deviceImage(appearance: .light)
    )
  }

  /// Nothing loaded yet (the first frame before `.task` lands, or a failed status probe):
  /// the Agent row and the About version row are hidden, and the App Icon row has no value.
  func testSettingsView_unloaded() {
    let state = SettingsFeature.State(connection: connection)
    assertSnapshot(of: settingsView(state), as: deviceImage())
  }

  /// Older agent without `DELETE /api/sessions/{id}` — the "Default swipe action" picker
  /// must be hidden entirely (Archive is the only destructive action, so the choice would be
  /// meaningless). `testSettingsView` shows it.
  func testSettingsView_deleteUnsupported() {
    assertSnapshot(
      of: settingsView(loadedState(deleteSupported: false)),
      as: deviceImage()
    )
  }

  // MARK: Notifications

  /// Notifications enabled: toggle on, push available, no test sent yet.
  func testSettingsNotificationsEnabled() {
    assertSnapshot(
      of: settingsView(loadedState(notificationsEnabled: true)),
      as: deviceImage(height: formHeight)
    )
  }

  /// Push not available on this server (plugin missing) → "not available" note, no controls.
  func testSettingsNotificationsUnavailable() {
    assertSnapshot(
      of: settingsView(loadedState(pushAvailable: false)),
      as: deviceImage(height: formHeight)
    )
  }

  /// Test notification just sent → confirmation label.
  func testSettingsNotificationsTestSent() {
    assertSnapshot(
      of: settingsView(loadedState(notificationsEnabled: true, testPushStatus: .sent)),
      as: deviceImage(height: formHeight)
    )
  }

  /// An outdated, git-updatable plugin → the update row with the one-tap button.
  func testSettingsPluginUpdateAvailable() {
    let state = loadedState(
      notificationsEnabled: true,
      pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true)
    )
    assertSnapshot(of: settingsView(state), as: deviceImage(height: formHeight))
  }

  /// After a successful pull — the RESTART notice, which is the whole point of that state.
  func testSettingsPluginUpdatedNeedsRestart() {
    let state = loadedState(
      notificationsEnabled: true,
      pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: true),
      pluginUpdate: .updated
    )
    assertSnapshot(of: settingsView(state), as: deviceImage(height: formHeight))
  }

  /// Outdated but not a git checkout → no button, pointer to the guide instead.
  func testSettingsPluginUpdateNeedsManualSteps() {
    let state = loadedState(
      notificationsEnabled: true,
      pushPlugin: PushPluginInfo(status: .ready, version: "0.1.0", canUpdateGit: false)
    )
    assertSnapshot(of: settingsView(state), as: deviceImage(height: formHeight))
  }

  // MARK: Live Activity (#138)

  /// Live Activity on with titles off: "Show session titles" nested under "Live Activity",
  /// with the Lock Screen / Dynamic Island footer. (Both on — the defaults — is every other
  /// Form fixture, e.g. `testSettingsNotificationsEnabled`.)
  func testSettingsLiveActivityOn() {
    var state = loadedState(notificationsEnabled: true)
    state.liveActivityShowsTitles = false
    assertSnapshot(of: settingsView(state), as: deviceImage(height: formHeight))
  }

  /// Live Activity off: the nested "Show session titles" row is gone.
  func testSettingsLiveActivityOff() {
    var state = loadedState(notificationsEnabled: true)
    state.liveActivityEnabled = false
    assertSnapshot(of: settingsView(state), as: deviceImage(height: formHeight))
  }

  /// iOS has Live Activities turned off for the app: the footer says so (the toggles stay).
  /// Shown with push unavailable too — the rows are local and don't depend on the plugin.
  func testSettingsLiveActivityDisabledByIOS() {
    var state = loadedState(pushAvailable: false)
    state.liveActivitiesAllowedBySystem = false
    assertSnapshot(of: settingsView(state), as: deviceImage(height: formHeight))
  }

  // MARK: Push guide

  /// The "how push works" info sheet, plugin NOT installed — the install action.
  func testPushSetupGuideView() {
    let view = PushSetupGuideView(pluginInstalled: false, onAskAgent: {})
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Plugin already installed — the action becomes "update".
  func testPushSetupGuideView_installed() {
    let view = PushSetupGuideView(pluginInstalled: true, onAskAgent: {})
    assertSnapshot(of: view, as: deviceImage())
  }

  // MARK: Acknowledgements

  /// Settings → Acknowledgements: every runtime package with its license and an external-link
  /// arrow. (The gateway log moved under Diagnostics — `DiagnosticsSnapshotTests`.)
  func testAcknowledgementsView() {
    assertSnapshot(of: NavigationStack { AcknowledgementsView() }, as: deviceImage())
  }

  func testAcknowledgementsView_light() {
    assertSnapshot(
      of: NavigationStack { AcknowledgementsView() },
      as: deviceImage(appearance: .light)
    )
  }
}
