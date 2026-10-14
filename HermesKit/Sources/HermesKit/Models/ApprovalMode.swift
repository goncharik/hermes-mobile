import Foundation

/// Profile-scoped policy controlling when the agent asks for approval.
public enum ApprovalMode: String, CaseIterable, Codable, Equatable, Sendable {
  case manual
  case smart
  case off

  public var title: String {
    switch self {
    case .manual: "Manual"
    case .smart: "Smart"
    case .off: "Off"
    }
  }

  public var detail: String {
    switch self {
    case .manual: "Ask before actions that require approval"
    case .smart: "Automatically assess actions and ask when needed"
    case .off: "Run without approval prompts"
    }
  }
}
