import CryptoKit
import Foundation

// Wire models for the dashboard updater (`docs/features/agent-update.md`):
// `GET /api/hermes/update/check`, `POST /api/hermes/update`,
// `GET /api/actions/hermes-update/status`. Decoded leniently: every field but the status's
// `running` is optional, and an unknown shape never turns into a success.

/// `GET /api/hermes/update/check?force=true` — whether the connected install can be updated.
public struct AgentUpdateCheck: Decodable, Equatable, Sendable {
  /// `git`, `docker`, `apt`, `nix`, … (`desktop-app` / `managed-runtime` for builds the
  /// built-in updater refuses). Informational; `canApply` is the gate.
  public var installMethod: String?
  public var currentVersion: String?
  /// Commits behind: `0` up to date, `-1` unknown count, `nil` the check couldn't run.
  public var behind: Int?
  public var updateAvailable: Bool
  /// `true` only for git installs — the server can apply the update in place.
  public var canApply: Bool
  /// Server guidance: how a non-git install updates, why a check failed, rollback notes.
  public var message: String?
  public var updateCommand: String?

  public init(
    installMethod: String? = "git", currentVersion: String? = nil, behind: Int? = nil,
    updateAvailable: Bool, canApply: Bool, message: String? = nil, updateCommand: String? = nil
  ) {
    self.installMethod = installMethod
    self.currentVersion = currentVersion
    self.behind = behind
    self.updateAvailable = updateAvailable
    self.canApply = canApply
    self.message = message
    self.updateCommand = updateCommand
  }

  enum CodingKeys: String, CodingKey {
    case installMethod = "install_method", currentVersion = "current_version", behind
    case updateAvailable = "update_available", canApply = "can_apply"
    case message, updateCommand = "update_command"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    installMethod = try c.decodeIfPresent(String.self, forKey: .installMethod)
    currentVersion = try c.decodeIfPresent(String.self, forKey: .currentVersion)
    behind = try c.decodeIfPresent(Int.self, forKey: .behind)
    // Absent flags mean "nothing to offer", never "go ahead".
    updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
    canApply = try c.decodeIfPresent(Bool.self, forKey: .canApply) ?? false
    message = try c.decodeIfPresent(String.self, forKey: .message).flatMap(\.trimmedNonEmpty)
    updateCommand = try c.decodeIfPresent(String.self, forKey: .updateCommand).flatMap(\.trimmedNonEmpty)
  }
}

/// What the server said to the single `POST /api/hermes/update`.
public enum AgentUpdateStart: Equatable, Sendable {
  /// Spawned by this request. `nil` id: an older agent that doesn't return one, so the run
  /// can't be tracked as this phone's.
  case started(actionID: String?)
  /// Another update was already running (`already_running`); this request started nothing.
  case alreadyRunning
}

/// `GET /api/actions/hermes-update/status?lines=1`.
public struct AgentUpdateActionStatus: Decodable, Equatable, Sendable {
  public var running: Bool
  /// Present only once the server has seen this run's success marker in the update log.
  public var actionID: String?
  public var exitCode: Int?
  /// The newest receipt — this dashboard action's when one exists, otherwise the latest of
  /// ANY run (other profiles, CLI runs). Never trusted without correlation.
  public var receipt: AgentUpdateReceipt?

  public init(running: Bool, actionID: String? = nil, exitCode: Int? = nil, receipt: AgentUpdateReceipt? = nil) {
    self.running = running
    self.actionID = actionID
    self.exitCode = exitCode
    self.receipt = receipt
  }

  enum CodingKeys: String, CodingKey {
    case running, receipt, actionID = "action_id", exitCode = "exit_code"
  }
}

/// The status endpoint's compact receipt summary.
public struct AgentUpdateReceipt: Decodable, Equatable, Sendable {
  /// `success`, `partial`, `failed`, `refused`, … (unknown values settle as unknown).
  public var outcome: String?
  public var postVersion: String?
  public var startedAt: String?
  /// Set only when the run is finalized; an unfinished receipt never settles anything.
  public var finishedAt: String?
  /// The dashboard action that wrote it (`HERMES_ACTION_ID`); absent on older agents.
  public var actionID: String?

  public init(
    outcome: String?, postVersion: String? = nil, startedAt: String? = nil,
    finishedAt: String? = nil, actionID: String? = nil
  ) {
    self.outcome = outcome
    self.postVersion = postVersion
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.actionID = actionID
  }

  enum CodingKeys: String, CodingKey {
    case outcome, postVersion = "post_version", startedAt = "started_at"
    case finishedAt = "finished_at", actionID = "action_id"
  }
}

/// The update THIS phone started: its action id and when the POST went out. Persisted (no
/// secret in it) so dismissing Settings or relaunching never loses track of it, scoped to
/// one server + account so ownership can't cross either.
public struct OwnedAgentUpdate: Codable, Equatable, Sendable {
  public var scope: String
  public var actionID: String
  /// Lower bound for the run's receipt `started_at` (older agents' receipts carry no
  /// action id, so time is the only correlation there).
  public var requestedAt: Date

  public init(scope: String, actionID: String, requestedAt: Date) {
    self.scope = scope
    self.actionID = actionID
    self.requestedAt = requestedAt
  }

  /// Whether a finished-or-not receipt belongs to this run. A receipt naming an action id
  /// must name ours; one without (older agent) must have started at/after our POST, at
  /// whole-second resolution. Anything unparseable is not ours.
  public func owns(_ receipt: AgentUpdateReceipt) -> Bool {
    if let id = receipt.actionID { return id == actionID }
    guard let startedAt = receipt.startedAt.flatMap(parseServerTimestamp) else { return false }
    return startedAt >= Date(timeIntervalSince1970: requestedAt.timeIntervalSince1970.rounded(.down))
  }
}

public extension ServerConnection {
  /// Stable server-origin + account identity for `OwnedAgentUpdate.scope`: never a
  /// credential (token mode has no account, so it is server-scoped). Hashed so the stored
  /// value carries no username.
  var agentUpdateScope: String {
    var origin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    origin.scheme = origin.scheme?.lowercased()
    origin.host = origin.host?.lowercased()
    if (origin.scheme == "https" && origin.port == 443) || (origin.scheme == "http" && origin.port == 80) {
      origin.port = nil
    }
    origin.user = nil
    origin.password = nil
    origin.path = ""
    origin.query = nil
    origin.fragment = nil
    let identity: [String] = switch auth {
    case .token: ["token"]
    case let .cookie(session): ["cookie", session.provider, session.username]
    case let .bearer(session): ["bearer", session.provider, session.userID]
    }
    // Length-prefixed so no two part lists encode the same.
    let encoded = ([origin.string ?? ""] + identity).map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Server receipts use Python `datetime.isoformat()` (UTC offset, optional microseconds).
/// Fractions are dropped, so comparisons are whole-second.
func parseServerTimestamp(_ text: String) -> Date? {
  let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: trimmed)
}
