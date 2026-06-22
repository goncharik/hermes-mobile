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
    /// The selected chat transcript rendering engine (device-local A/B preference).
    public var chatRenderer: ChatRendererKind

    public init(connection: ServerConnection) {
      self.connection = connection
      self.token = connection.token ?? ""
      self.savedConfirmation = false
      self.log = []
      self.chatRenderer = .default
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
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case disconnect             // token cleared → back to onboarding
      case reconnect              // reload the session list
      case tokenSaved(String)     // re-pasted token persisted
    }
  }

  private enum CancelID { case logStream }

  @Dependency(\.keychain) var keychain
  @Dependency(\.preferences) var preferences
  @Dependency(\.chatSnapshot) var chatSnapshot
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        state.chatRenderer = preferences.loadChatRenderer()
        return .run { [debugLog] send in
          for await entries in debugLog.stream() {
            await send(.logUpdated(entries))
          }
        }
        .cancellable(id: CancelID.logStream, cancelInFlight: true)

      case let .logUpdated(entries):
        state.log = entries
        return .none

      case .binding(\.token):
        state.savedConfirmation = false
        return .none

      case .binding(\.chatRenderer):
        preferences.saveChatRenderer(state.chatRenderer)
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
