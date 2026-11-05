import ComposableArchitecture
import Foundation

/// Settings → Acknowledgements: a static list of the open-source packages the app ships.
/// Nothing to reduce — the screen renders `Acknowledgement.all`.
@Reducer
public struct AcknowledgementsFeature {
  @ObservableState
  public struct State: Equatable {
    public init() {}
  }

  public enum Action: Equatable, Sendable {}

  public init() {}

  public var body: some ReducerOf<Self> {
    EmptyReducer()
  }
}
