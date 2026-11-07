#if os(iOS) && canImport(ActivityKit)
  import ActivityKit

  /// The aggregate Live Activity's ActivityKit type (#138). ActivityKit matches an activity to
  /// its UI by this type, so the app (which requests it, through HermesKit's re-export) and the
  /// widget extension (which renders it) must share ONE definition — hence it lives here.
  /// No static attributes: everything the activity shows is the `AgentActivityContent` state.
  /// iOS-only; the macOS test build compiles it out and keeps the pure content type.
  public struct HermesActivityAttributes: ActivityAttributes {
    public typealias ContentState = AgentActivityContent

    public init() {}
  }
#endif
