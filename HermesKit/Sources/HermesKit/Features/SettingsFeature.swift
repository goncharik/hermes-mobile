import ComposableArchitecture
import Foundation

/// Settings sheet (Task 12): server info, token management (re-paste / clear), a manual
/// reconnect trigger, and a live feed of decoded gateway events for debugging.
///
/// Token-clear and reconnect are surfaced to the parent via delegates: clearing returns
/// the app to onboarding, reconnect reloads the session list.
@Reducer
public struct SettingsFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var token: String
    /// Transient confirmation after saving the token.
    public var savedConfirmation: Bool
    /// Live debug log, newest last; fed by `DebugLogClient`.
    public var log: [GatewayLogEntry]
    /// Whether the connected agent exposes the `hermes-push` plugin (passed down from the
    /// session list's capability probe). When false the notifications UI (C6) shows a
    /// "not available on this server" note instead of the toggle.
    public var pushAvailable: Bool
    /// The "Notify me about approvals" toggle, reflecting the OS authorization status:
    /// `true` when notifications are authorized (or provisional), `false` otherwise. Read
    /// on appearance from `PushClient.authorizationStatus()`; turning it ON triggers the
    /// contextual permission prompt.
    public var notificationsEnabled: Bool
    /// `true` when notifications were denied at the OS level — the view shows guidance to
    /// enable them in iOS Settings (opening the URL is a thin view concern). Set when the
    /// authorization request is declined or status reads `.denied`.
    public var notificationsDenied: Bool
    /// Drives the "Send test notification" button + result label.
    public var testPushStatus: TestPushStatus
    /// What the agent's plugin hub reports about `hermes-push` — read on appearance. `nil`
    /// until the probe lands (and left `nil` if it fails), which reads as "offer nothing".
    public var pushPlugin: PushPluginInfo?
    /// Drives the plugin-update row: button state and the result label under it.
    public var pluginUpdate: PluginUpdateStatus
    /// The session list's default trailing-swipe action, edited via the picker below and
    /// persisted immediately (seeded from the list's current value when presenting).
    public var defaultSwipeAction: SessionSwipeAction
    /// Whether the connected agent supports `DELETE /api/sessions/{id}` (seeded from the
    /// session list's capability flag). When false the swipe-action picker is hidden —
    /// Delete isn't offered anywhere, so the choice would be meaningless.
    public var deleteSupported: Bool

    /// The outcome of a "send test notification" attempt, surfaced in the view/snapshots.
    public enum TestPushStatus: Equatable, Sendable {
      case idle
      case sending
      case sent
      case failed
    }

    /// State of the in-app "update the plugin" action.
    public enum PluginUpdateStatus: Equatable, Sendable {
      case idle
      case updating
      /// Pulled new commits — the agent MUST be restarted before the new code runs.
      case updated
      /// The pull succeeded but changed nothing ("Already up to date").
      case alreadyCurrent
      /// The agent refused or the request failed; carries the server's reason verbatim.
      case failed(String)
    }

    public init(
      connection: ServerConnection,
      pushAvailable: Bool = true,
      notificationsEnabled: Bool = false,
      notificationsDenied: Bool = false,
      testPushStatus: TestPushStatus = .idle,
      pushPlugin: PushPluginInfo? = nil,
      pluginUpdate: PluginUpdateStatus = .idle,
      defaultSwipeAction: SessionSwipeAction = .default,
      deleteSupported: Bool = true
    ) {
      self.connection = connection
      self.token = connection.token ?? ""
      self.savedConfirmation = false
      self.log = []
      self.pushAvailable = pushAvailable
      self.notificationsEnabled = notificationsEnabled
      self.notificationsDenied = notificationsDenied
      self.testPushStatus = testPushStatus
      self.pushPlugin = pushPlugin
      self.pluginUpdate = pluginUpdate
      self.defaultSwipeAction = defaultSwipeAction
      self.deleteSupported = deleteSupported
    }

    /// The installed plugin is behind `PushSetup.minimumPluginVersion` AND the agent can pull
    /// it in place → offer the one-tap update.
    ///
    /// Stays `false` once an update has been attempted: after a successful pull the hub reports
    /// the NEW version off disk while the running agent still has the old code loaded, so
    /// re-offering the button would be misleading — the outstanding action is a restart, which
    /// only the user can do.
    public var pluginUpdateAvailable: Bool {
      guard pluginUpdate == .idle, let pushPlugin else { return false }
      return pushPlugin.isOutdated && pushPlugin.canUpdateGit
    }

    /// The plugin is behind but the agent can't pull it (pip install, hand-copied directory,
    /// or an agent too old to report `can_update_git`) → point the user at the chat prompt
    /// instead of a button that would only 400.
    public var pluginUpdateNeedsManualSteps: Bool {
      guard pluginUpdate == .idle, let pushPlugin else { return false }
      return pushPlugin.isOutdated && !pushPlugin.canUpdateGit
    }

    public var serverURLString: String { connection.baseURL.absoluteString }
    public var canSaveToken: Bool {
      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && token != connection.token
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case logUpdated([GatewayLogEntry])
    case saveTokenTapped
    case clearTokenTapped
    case reconnectTapped
    case doneTapped
    /// The current OS authorization status, read on appearance (drives the toggle).
    case authorizationStatusLoaded(PushAuthorizationStatus)
    /// User flipped the "Notify me about approvals" toggle.
    case notificationsToggled(Bool)
    /// Result of the contextual permission prompt (`true` ⇒ granted).
    case authorizationResult(Bool)
    /// User tapped "Send test notification".
    case sendTestPushTapped
    /// Result of the test-push request.
    case testPushResult(Bool)
    /// The push guide's "Ask agent to install" button — dismiss Settings and bubble up so the
    /// app opens a new chat with the install prompt pre-filled.
    case askAgentToInstallTapped
    /// What the plugin hub reports about `hermes-push`, read on appearance.
    case pushPluginInfoLoaded(PushPluginInfo)
    /// User tapped "Update plugin" — asks the agent to `git pull` it in place.
    case updatePluginTapped
    /// Outcome of that pull.
    case pluginUpdateResult(PluginUpdateOutcome)
    /// User picked a different default swipe action for session rows.
    case defaultSwipeActionChanged(SessionSwipeAction)
    case delegate(Delegate)

    /// Result of the in-app plugin update, flattened to an `Equatable` shape (the failure
    /// carries the server's message rather than the error value, matching `testPushResult`).
    @CasePathable
    public enum PluginUpdateOutcome: Equatable, Sendable {
      /// Pulled new commits — restart required before the new code runs.
      case updated
      /// "Already up to date" — nothing changed, so nothing to restart for.
      case alreadyCurrent
      case failed(String)
    }

    @CasePathable
    public enum Delegate {
      case disconnect             // token cleared → back to onboarding
      case reconnect              // reload the session list
      case tokenSaved(String)     // re-pasted token persisted
      /// The push guide's "Ask agent to install" — dismiss Settings and open a new chat with
      /// the install prompt pre-filled (handled up the chain by `AppFeature`).
      case installPushPlugin
      /// The default swipe action changed — the session list mirrors it immediately so the
      /// rows are right the moment the sheet dismisses.
      case defaultSwipeActionChanged(SessionSwipeAction)
    }
  }

  private enum CancelID { case logStream }

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.chatSnapshot) var chatSnapshot
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.hermesREST) var rest
  @Dependency(\.push) var push
  @Dependency(\.continuousClock) var clock
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .run { [debugLog] send in
            for await entries in debugLog.stream() {
              await send(.logUpdated(entries))
            }
          }
          .cancellable(id: CancelID.logStream, cancelInFlight: true),
          // Reflect the real OS authorization status in the toggle on appearance.
          .run { [push] send in
            await send(.authorizationStatusLoaded(push.authorizationStatus()))
          },
          // Read the installed plugin's version so we can offer an update. Never throws —
          // an unreachable/old agent maps to `.unknown`, which offers nothing.
          .run { [rest, connection = state.connection] send in
            await send(.pushPluginInfoLoaded(rest.pushPluginInfo(connection)))
          }
        )

      case let .pushPluginInfoLoaded(info):
        state.pushPlugin = info
        return .none

      case .updatePluginTapped:
        guard state.pluginUpdate != .updating else { return .none }
        state.pluginUpdate = .updating
        return .run { [rest, connection = state.connection] send in
          do {
            let result = try await rest.updatePushPlugin(connection)
            await send(.pluginUpdateResult(result.unchanged ? .alreadyCurrent : .updated))
          } catch let error as RESTError {
            // Surface the agent's own reason (not a git checkout, non-fast-forward, git
            // missing) verbatim — the user has to act on it on their host.
            await send(.pluginUpdateResult(.failed(error.message)))
          } catch {
            await send(.pluginUpdateResult(.failed(RESTError.unreachable.message)))
          }
        }

      case let .pluginUpdateResult(outcome):
        switch outcome {
        case .updated: state.pluginUpdate = .updated
        case .alreadyCurrent: state.pluginUpdate = .alreadyCurrent
        case let .failed(reason): state.pluginUpdate = .failed(reason)
        }
        return .none

      case let .authorizationStatusLoaded(status):
        switch status {
        case .authorized, .provisional:
          state.notificationsEnabled = true
          state.notificationsDenied = false
        case .denied:
          state.notificationsEnabled = false
          state.notificationsDenied = true
        case .notDetermined:
          state.notificationsEnabled = false
          state.notificationsDenied = false
        }
        return .none

      case let .notificationsToggled(isOn):
        guard isOn else {
          // Turning OFF in-app can't revoke OS permission (only iOS Settings can); just
          // reflect the user's intent on the toggle.
          state.notificationsEnabled = false
          return .none
        }
        // Turning ON: trigger the contextual permission prompt. The result decides whether
        // the toggle stays on (granted → register) or flips back with denial guidance.
        return .run { [push] send in
          await send(.authorizationResult(push.requestAuthorization()))
        }

      case let .authorizationResult(granted):
        if granted {
          state.notificationsEnabled = true
          state.notificationsDenied = false
          // Granted → ensure this device is registered (reuse the C4 register path: obtain a
          // device token within a bounded wait, then register it). Best-effort.
          return .run { [rest, push, preferences, clock, connection = state.connection] _ in
            _ = await ensurePushRegistered(
              rest: rest, push: push, preferences: preferences,
              connection: connection, clock: clock
            )
          }
        } else {
          state.notificationsEnabled = false
          state.notificationsDenied = true
          return .none
        }

      case .sendTestPushTapped:
        state.testPushStatus = .sending
        // Register if needed, then ask the plugin to deliver a sample push. The token wait is
        // bounded inside `ensurePushRegistered` — if no token is ever obtained we fail fast
        // rather than leaving `testPushStatus` stuck on `.sending`.
        return .run { [rest, push, preferences, clock, connection = state.connection] send in
          guard await ensurePushRegistered(
            rest: rest, push: push, preferences: preferences,
            connection: connection, clock: clock
          ) else {
            await send(.testPushResult(false))
            return
          }
          do {
            try await rest.sendTestPush(connection)
            await send(.testPushResult(true))
          } catch {
            await send(.testPushResult(false))
          }
        }

      case let .testPushResult(ok):
        state.testPushStatus = ok ? .sent : .failed
        return .none

      case let .defaultSwipeActionChanged(action):
        state.defaultSwipeAction = action
        preferences.saveDefaultSessionSwipeAction(action)
        // Bubble up so the session list reflects the new default immediately on dismissal.
        return .send(.delegate(.defaultSwipeActionChanged(action)))

      case .askAgentToInstallTapped:
        // Dismiss Settings and bubble up — `AppFeature` opens a new chat with the install
        // prompt pre-filled (the user reviews and sends).
        return .merge(
          .send(.delegate(.installPushPlugin)),
          .run { [dismiss] _ in await dismiss() }
        )

      case let .logUpdated(entries):
        state.log = entries
        return .none

      case .binding(\.token):
        state.savedConfirmation = false
        return .none

      case .binding:
        return .none

      case .saveTokenTapped:
        guard state.canSaveToken else { return .none }
        let token = state.token
        state.connection.token = token
        state.savedConfirmation = true
        try? keychain.saveToken(token)
        return .send(.delegate(.tokenSaved(token)))

      case .clearTokenTapped:
        // Clear the full session (token + any gated cookies in the shared jar), not just the
        // token — a gated logout must leave no cookie behind.
        try? keychain.deleteSession()
        preferences.clearServerURL()
        preferences.savePinnedIDs([]) // pins are per-server; drop them on logout
        preferences.saveSeenCounts([:]) // unread state is per-server; drop it too
        preferences.saveGroupingMode(.default) // reset the list grouping pref on logout
        preferences.saveDefaultSessionSwipeAction(.default) // reset the swipe-action pref too
        preferences.saveShowCronSection(true) // reset the cron-section visibility pref too
        preferences.clearSelectedProfileID() // selected profile is per-server — clear on logout
        chatSnapshot.wipeAll() // snapshots + turn anchors are per-server — wipe on logout
        return .merge(
          .send(.delegate(.disconnect)),
          .run { [dismiss] _ in await dismiss() }
        )

      case .reconnectTapped:
        return .merge(
          .send(.delegate(.reconnect)),
          .run { [dismiss] _ in await dismiss() }
        )

      case .doneTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }
}

/// Seconds to wait for a fresh device token before falling back to the persisted one. A
/// token may never arrive (no entitlement / offline / simulator), so the wait MUST be bounded
/// — otherwise `testPushStatus` would stay `.sending` forever.
private let pushTokenWaitSeconds: UInt64 = 5

/// Ensure this device is registered with the agent's push plugin — mirrors the C4
/// `SessionListFeature` register path (obtain a device token, `registerPush` it threading the
/// compile-time APNs env + app version). The app never signs pushes (the plugin signs with a
/// shared secret), so there is nothing to persist on success.
///
/// Shared by the toggle-grant and "send test notification" paths. The wait for a device token
/// is **bounded** (`pushTokenWaitSeconds`): the first emitted token wins, but if none arrives
/// in time we fall back to the last persisted token. Returns `true` when registration
/// succeeded so the caller can surface a failure instead of hanging.
@Sendable
private func ensurePushRegistered(
  rest: HermesRESTClient,
  push: PushClient,
  preferences: PreferencesClient,
  connection: ServerConnection,
  clock: any Clock<Duration>
) async -> Bool {
  // Race the live token stream against a timeout; fall back to the persisted token.
  let token: String? = await withTaskGroup(of: String?.self) { group in
    group.addTask {
      for await token in push.register() { return token }
      return nil
    }
    group.addTask {
      try? await clock.sleep(for: .seconds(pushTokenWaitSeconds))
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  } ?? preferences.loadPushDeviceToken()

  guard let token else { return false }
  preferences.savePushDeviceToken(token)
  do {
    try await rest.registerPush(connection, token, PushClient.apnsEnv, push.appVersion())
    return true
  } catch {
    return false
  }
}
