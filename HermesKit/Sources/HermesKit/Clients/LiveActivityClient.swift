import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Starts, updates and ends the aggregate "running agents" Live Activity (#138). A dumb
/// pass-through to ActivityKit: `AppFeature` owns the state machine (when to start, what to
/// show, when to end) off the single `agentStatus` edge. Local updates only — no push token,
/// no ActivityKit pushes; the activity's `staleDate` is how it turns "Outdated" once the app
/// can no longer observe.
@DependencyClient
public struct LiveActivityClient: Sendable {
  /// Whether iOS lets this app show Live Activities (the user can turn them off per app).
  public var areActivitiesEnabled: @Sendable () -> Bool = { false }
  /// Requests a new activity showing `content` until `staleDate`; returns its id. Throws when
  /// iOS refuses (disabled, too many activities, not in the foreground).
  public var start: @Sendable (
    _ content: AgentActivityContent, _ staleDate: Date
  ) async throws -> String
  /// Replaces the activity's content and stale date. An unknown id is a no-op.
  public var update: @Sendable (
    _ id: String, _ content: AgentActivityContent, _ staleDate: Date
  ) async -> Void
  /// Ends the activity, optionally with `final` content left on screen until `dismissAfter`
  /// (`nil` = dismissed at once). An unknown id is a no-op.
  public var end: @Sendable (
    _ id: String, _ final: AgentActivityContent?, _ dismissAfter: Date?
  ) async -> Void
  /// Ends every activity of this app at once (the toggle going off, a logout, before a start).
  public var endAll: @Sendable () async -> Void
  /// Whether the activity is still up (active or stale) — `false` once the user swiped it away
  /// or iOS ended it at its time limit.
  public var isActive: @Sendable (_ id: String) -> Bool = { _ in false }
}

/// Thrown by the no-op client's `start`: no Live Activities off-device.
public struct LiveActivitiesUnavailable: Error, Equatable, Sendable {
  public init() {}
}

extension LiveActivityClient: DependencyKey {
  /// Shows nothing: activities report as disabled and a start throws, so the reducer never
  /// starts one, and every logout's `endAll` is harmless. The off-device live value, demo
  /// mode's, and the test double.
  public static var noop: LiveActivityClient {
    LiveActivityClient(
      areActivitiesEnabled: { false },
      start: { _, _ in throw LiveActivitiesUnavailable() },
      update: { _, _, _ in },
      end: { _, _, _ in },
      endAll: {},
      isActive: { _ in false }
    )
  }

  /// `noop` (like `WidgetMirrorClient`). Override `areActivitiesEnabled` and `start` with a
  /// recorder to drive the lifecycle.
  public static var testValue: LiveActivityClient { .noop }
}

public extension DependencyValues {
  var liveActivity: LiveActivityClient {
    get { self[LiveActivityClient.self] }
    set { self[LiveActivityClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

#if os(iOS) && canImport(ActivityKit)
  import ActivityKit

  extension LiveActivityClient {
    public static var liveValue: LiveActivityClient {
      @Sendable func activity(_ id: String) -> Activity<HermesActivityAttributes>? {
        Activity<HermesActivityAttributes>.activities.first { $0.id == id }
      }
      return LiveActivityClient(
        areActivitiesEnabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
        start: { content, staleDate in
          try Activity.request(
            attributes: HermesActivityAttributes(),
            content: ActivityContent(state: content, staleDate: staleDate),
            pushType: nil
          ).id
        },
        update: { id, content, staleDate in
          await activity(id)?.update(ActivityContent(state: content, staleDate: staleDate))
        },
        end: { id, final, dismissAfter in
          await activity(id)?.end(
            final.map { ActivityContent(state: $0, staleDate: nil) },
            dismissalPolicy: dismissAfter.map { .after($0) } ?? .immediate
          )
        },
        endAll: {
          for activity in Activity<HermesActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
        },
        isActive: { id in
          guard let state = activity(id)?.activityState else { return false }
          return state == .active || state == .stale
        }
      )
    }
  }
#else
  extension LiveActivityClient {
    /// No Live Activities off-device (macOS `swift test`).
    public static var liveValue: LiveActivityClient { .noop }
  }
#endif
