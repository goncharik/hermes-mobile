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

// MARK: - Presentation (the Live Activity's wording, kept pure so it is unit-tested)

extension AgentActivityContent {
  /// The trailing status label the activity shows.
  public enum DisplayStatus: Equatable, Sendable {
    case working
    case needsInput
    case done
    /// Was working or needed input when the app last looked; past the activity's stale date
    /// nothing observes the agents any more.
    case outdated

    public var label: String {
      switch self {
      case .working: "Working"
      case .needsInput: "Needs input"
      case .done: "Done"
      case .outdated: "Outdated"
      }
    }
  }

  /// The status to show given ActivityKit's `isStale`: working / needs input read "Outdated"
  /// once stale; the final "Done" content carries no stale date and never does.
  public func displayStatus(isStale: Bool) -> DisplayStatus {
    switch status {
    case .done: .done
    case .working: isStale ? .outdated : .working
    case .needsInput: isStale ? .outdated : .needsInput
    }
  }

  /// The header: "1 active agent", "3 active agents", or "No active agents" (the final
  /// "Done" content).
  public var countLabel: String {
    switch activeCount {
    case ...0: "No active agents"
    case 1: "1 active agent"
    default: "\(activeCount) active agents"
    }
  }

  /// The headline line's leading text: the session title, or — with "Show session titles"
  /// off — the workspace in its place. `nil` when neither is known (the line shows only the
  /// status).
  public var headlineText: String? {
    headlineTitle ?? headlineWorkspace
  }

  /// The secondary text after the headline: the workspace, unless it already took the
  /// title's place.
  public var secondaryText: String? {
    headlineTitle == nil ? nil : headlineWorkspace
  }

  /// What a tap on the activity opens: the headline session (in its own profile), or `nil`
  /// (the app opens as is) when there is no headline.
  public var tapIntent: LaunchIntent? {
    headlineSessionID.map { .openSession(id: $0, profile: headlineProfile) }
  }
}
