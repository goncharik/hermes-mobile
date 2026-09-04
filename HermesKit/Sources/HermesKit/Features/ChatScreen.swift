import ComposableArchitecture

/// A thin navigation marker for a pushed chat screen. The REAL chat state lives in
/// `AppFeature.State.liveChat` (the app-owned "live chat slot"), so a running turn's
/// socket and streaming effects survive navigation pops — the path holds only this
/// session-key marker and carries no behavior of its own.
///
/// COMPACT-ONLY (#80): in regular width the slot IS the split view's detail column and the
/// path stays empty — see `docs/features/ipad-layout.md`.
@Reducer
public struct ChatScreen {
  @ObservableState
  public struct State: Equatable {
    /// The session key this marker points at (`storedSessionID ?? liveSessionID` at push
    /// time). `nil` for a brand-new chat whose id hasn't resolved yet — and NOT updated
    /// when it does. Diagnostic/test-observability only: production routing always derives
    /// the on-screen session from the slot (`AppFeature.State.currentViewingSessionID`),
    /// never from this marker.
    public var sessionKey: String?

    public init(sessionKey: String? = nil) {
      self.sessionKey = sessionKey
    }
  }

  public enum Action: Equatable, Sendable {}

  public init() {}

  public var body: some ReducerOf<Self> {
    EmptyReducer()
  }
}
