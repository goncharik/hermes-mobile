import Foundation

/// Payload for an `approval.request` event — the agent is blocked waiting for the
/// user to approve/deny a dangerous action (e.g. a destructive shell command).
/// Newer gateways bind responses to `request_id`; older gateways use the session FIFO.
///
/// Every field is decoded leniently so a partial approval payload still yields a prompt
/// rather than silently degrading to `.unknown` and leaving the turn blocked.
/// Deliberately only `Equatable`: the card's view identity comes from the reducer's monotonic
/// `pendingInteractionToken`, never from the request's value — two back-to-back approvals can
/// be *equal* (an agent retrying the same command), which is exactly the pair a value-derived
/// id cannot tell apart.
public struct ApprovalRequest: Equatable, Sendable, Decodable {
  /// Exact server-side approval identity on newer gateways. Nil on older gateways.
  public var requestID: String?
  /// JSON-RPC request id when this approval arrived as a server→client request.
  /// This is transport metadata, not part of the approval payload.
  public var serverRequestID: String?
  /// The server-advertised choices. Empty means an older gateway with the legacy choice set.
  public var choices: [String]
  /// The command awaiting approval (shown verbatim in the card).
  public var command: String?
  /// Human-readable summary of what will happen (server's `description`).
  public var detail: String?
  /// The danger pattern that matched (server's `pattern_key`).
  public var patternKey: String?
  /// All matched danger patterns when several commands are batched together.
  public var patternKeys: [String]

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case choices
    case command
    case detail = "description"
    case patternKey = "pattern_key"
    case patternKeys = "pattern_keys"
  }

  public init(
    requestID: String? = nil,
    serverRequestID: String? = nil,
    command: String? = nil,
    detail: String? = nil,
    patternKey: String? = nil,
    patternKeys: [String] = [],
    choices: [String] = []
  ) {
    self.requestID = requestID
    self.serverRequestID = serverRequestID
    self.command = command
    self.detail = detail
    self.patternKey = patternKey
    self.patternKeys = patternKeys
    self.choices = choices
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
    serverRequestID = nil
    choices = (try? c.decodeIfPresent([String].self, forKey: .choices)) ?? []
    command = try c.decodeIfPresent(String.self, forKey: .command)
    detail = try c.decodeIfPresent(String.self, forKey: .detail)
    patternKey = try c.decodeIfPresent(String.self, forKey: .patternKey)
    patternKeys = try c.decodeIfPresent([String].self, forKey: .patternKeys) ?? []
  }

  /// Whether the server permits a session-wide approval. Empty means an older gateway
  /// with the legacy choice set and is treated as permissive for compatibility.
  public var allowsSessionChoice: Bool {
    choices.isEmpty || choices.contains("session")
  }

  /// Whether the server permits approving only this command.
  public var allowsOnce: Bool {
    choices.isEmpty || choices.contains("once")
  }

  /// Whether the card may offer the session-wide "Approve all in this session"
  /// escalation (`choice: "session"`, which persists the matched danger pattern for the
  /// rest of the session). A recovered request carries no command or pattern, so it never
  /// offers the toggle even on a legacy gateway.
  public var offersSessionApproval: Bool {
    (command?.isEmpty == false || patternKey?.isEmpty == false || !patternKeys.isEmpty)
      && allowsOnce
      && allowsSessionChoice
  }
}

/// Payload for a `clarify.request` event. `choices` is empty when the agent expects
/// free-text. Responded to via `clarify.respond`.
/// Shape not yet verified against a live request — to confirm in M2 (Task 10).
public struct ClarifyRequest: Equatable, Sendable, Decodable {
  public var requestID: String
  public var question: String
  public var choices: [String]

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case question
    case choices
  }

  public init(requestID: String, question: String, choices: [String] = []) {
    self.requestID = requestID
    self.question = question
    self.choices = choices
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try c.decode(String.self, forKey: .requestID)
    question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
    choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
  }
}
