import Foundation

/// The aggregate Live Activity's content (its ActivityKit `ContentState`): how many agents are
/// active and the headline session. Pure and Foundation-only so the app's reducer can build it
/// and the macOS test build can assert on it; the ActivityKit attributes wrap it.
public struct AgentActivityContent: Codable, Hashable, Sendable {
  public enum Status: String, Codable, Hashable, Sendable {
    case working
    case needsInput
    /// The final content an ended activity shows before it is dismissed.
    case done
  }

  /// Sessions that are working or need input.
  public var activeCount: Int
  /// The headline session's title; `nil` when "Show session titles" is off.
  public var headlineTitle: String?
  public var headlineWorkspace: String?
  /// The session a tap on the activity opens.
  public var headlineSessionID: String?
  public var headlineProfile: String?
  public var status: Status

  public init(
    activeCount: Int,
    headlineTitle: String? = nil,
    headlineWorkspace: String? = nil,
    headlineSessionID: String? = nil,
    headlineProfile: String? = nil,
    status: Status
  ) {
    self.activeCount = activeCount
    self.headlineTitle = headlineTitle
    self.headlineWorkspace = headlineWorkspace
    self.headlineSessionID = headlineSessionID
    self.headlineProfile = headlineProfile
    self.status = status
  }
}
