import ComposableArchitecture
import Foundation

/// The Settings → Diagnostics screen: the live gateway event log plus a "Copy diagnostics"
/// button that puts a plain-text `DiagnosticsReport` on the pasteboard for a bug report.
///
/// Seeded by `SettingsFeature` with the facts it already holds (server URL, the pre-rendered
/// auth label, the agent version — kept current by the parent while pushed) — never an
/// `AuthSession`, so no credential can reach the report (`DiagnosticsReport`'s no-secrets
/// invariant). Build facts come from `bundleInfo` at copy time.
///
/// Lifecycle: `.task` subscribes to `debugLog.stream()`; popping the screen cancels it (the
/// stack cancels a removed element's effects). The copied toast is the reducer-owned token +
/// `cancelInFlight` dwell, duplicated per feature.
@Reducer
public struct DiagnosticsFeature {
  @ObservableState
  public struct State: Equatable {
    public var serverURL: URL
    /// `AuthSession.settingsLabel` — identity only, never a secret.
    public var authLabel: String
    /// `/api/status` version; nil renders as "unknown" in the report.
    public var agentVersion: String?
    /// Live debug log, newest last; fed by `DebugLogClient`.
    public var log: [GatewayLogEntry]
    /// Bumped on every copy (never a `Bool` — a re-copy inside the dwell must restart the
    /// toast); nil once the dwell elapses.
    public var copiedToken: Int?

    public init(
      serverURL: URL,
      authLabel: String,
      agentVersion: String?,
      log: [GatewayLogEntry] = [],
      copiedToken: Int? = nil
    ) {
      self.serverURL = serverURL
      self.authLabel = authLabel
      self.agentVersion = agentVersion
      self.log = log
      self.copiedToken = copiedToken
    }
  }

  public enum Action: Equatable, Sendable {
    /// The screen appeared — subscribe to the debug log.
    case task
    case logUpdated([GatewayLogEntry])
    case copyTapped
    case copiedFeedbackElapsed
  }

  private enum CancelID: Hashable {
    case logStream, copyFeedback
  }

  /// How long the "Copied" toast stays up — duplicated per feature (the toast idiom) rather
  /// than shared, so a tweak elsewhere can't silently restyle this screen.
  static let copiedFeedbackDuration: Duration = .seconds(1.5)

  @Dependency(\.bundleInfo) var bundleInfo
  @Dependency(\.continuousClock) var clock
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.pasteboard) var pasteboard

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { [debugLog] send in
          for await entries in debugLog.stream() {
            await send(.logUpdated(entries))
          }
        }
        .cancellable(id: CancelID.logStream, cancelInFlight: true)

      case let .logUpdated(entries):
        state.log = entries
        return .none

      case .copyTapped:
        state.copiedToken = (state.copiedToken ?? 0) + 1
        let report = DiagnosticsReport.render(
          bundleInfo: bundleInfo.info(),
          serverURL: state.serverURL,
          authLabel: state.authLabel,
          agentVersion: state.agentVersion,
          log: state.log
        )
        return .merge(
          .run { [pasteboard] _ in pasteboard.copy(report) },
          .run { [clock] send in
            try await clock.sleep(for: Self.copiedFeedbackDuration)
            await send(.copiedFeedbackElapsed)
          }
          .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
        )

      case .copiedFeedbackElapsed:
        state.copiedToken = nil
        return .none
      }
    }
  }
}
