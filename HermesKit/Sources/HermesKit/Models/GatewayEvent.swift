import Foundation

/// A decoded server→client event from the gateway. Shapes verified against the M0
/// probe (`docs/plans/...` → "M0 findings"): streaming message events carry **no
/// message id**, and `session_id` lives on the event frame, not the payload.
public enum GatewayEvent: Equatable, Sendable {
  case ready
  case sessionInfo(SessionInfo)
  case messageStart
  case messageDelta(text: String)
  case messageComplete(text: String, usage: Usage?)
  case thinkingDelta(text: String)
  case reasoningAvailable(text: String)
  case statusUpdate(kind: String, text: String)
  case toolStart(toolID: String?, name: String, title: String?, argsText: String?)
  case toolComplete(
    toolID: String?, name: String?, title: String?,
    args: JSONValue?, resultText: String?, inlineDiff: String?, durationS: Double?
  )
  case approvalRequest(ApprovalRequest)
  /// A rendered v7 server→client request (`{"id":"srq-…","method":…}`), decoded by the
  /// gateway client and answered through `request.answer {id, result}`. Distinct from the
  /// legacy `*.request` notifications. Never carries an answer value.
  case serverRequest(PendingServerRequest)
  /// `request.cancel`: the server withdrew an open server request (timeout, interrupt, …).
  case requestCancel(RequestCancel)
  case clarifyRequest(ClarifyRequest)
  case sudoRequest(SecretPrompt)
  case secretRequest(SecretPrompt)
  case error(message: String)
  /// Local protocol-operation failure, not a turn-ending agent error.
  case serverRequestFailed(message: String)
  /// Synthetic (client-side, never on the wire): this connection's `client.capabilities`
  /// advertisement failed (anything but `-32601`), so the server will not route prompts
  /// to the phone until the next connect re-advertises. Yielded at most once per
  /// connection and always AFTER that connection's `.ready` — the reducer keeps it standing
  /// across the ready/hydrate banner clears. Not a turn-ending error.
  case serverRequestsUnavailable(message: String)
  /// Live-only event from the agent's background self-improvement review
  /// (`review.summary`, issue #47), emitted to the session's own transport (not a
  /// global broadcast). Never written to session history, so a hydrate
  /// (`session.resume`) cannot return it — the rendered row is ephemeral by design.
  case reviewSummary(text: String)
  /// Synthetic (client-side, never on the wire): the gated `ws-ticket` mint returned `401`,
  /// meaning the cookie session is fully dead. The reducer routes this to re-auth instead of
  /// reconnect backoff. Distinct from `.error` (recoverable) and a socket drop (transient).
  case authExpired
  /// Any event type we don't model (incl. ones ignored for MVP like `tool.progress`,
  /// `tool.generating`, `background.complete`, `skin.changed`). Never throws.
  case unknown(type: String, raw: JSONValue)

  /// Map an event `type` + `payload` to a case. Unknown types fall through to `.unknown`.
  init(type: String, payload: JSONValue?) {
    let p = payload ?? .object([:])
    switch type {
    case "gateway.ready":
      self = .ready
    case "session.info":
      self = .sessionInfo(payload?.decoded(SessionInfo.self) ?? SessionInfo())
    case "message.start":
      self = .messageStart
    case "message.delta":
      self = .messageDelta(text: p["text"]?.stringValue ?? "")
    case "message.complete":
      self = .messageComplete(text: p["text"]?.stringValue ?? "", usage: p["usage"]?.decoded(Usage.self))
    case "thinking.delta":
      self = .thinkingDelta(text: p["text"]?.stringValue ?? "")
    case "reasoning.delta":
      // Incremental reasoning folds into the same collapsible "thinking" row.
      self = .thinkingDelta(text: p["text"]?.stringValue ?? "")
    case "reasoning.available":
      self = .reasoningAvailable(text: p["text"]?.stringValue ?? "")
    case "status.update":
      self = .statusUpdate(kind: p["kind"]?.stringValue ?? "", text: p["text"]?.stringValue ?? "")
    case "tool.start":
      self = .toolStart(
        toolID: p["tool_id"]?.stringValue,
        name: p["name"]?.stringValue ?? "",
        title: p["context"]?.stringValue,       // human description shown as the row title
        argsText: p["args_text"]?.stringValue   // present only in verbose runs
      )
    case "tool.complete":
      self = .toolComplete(
        toolID: p["tool_id"]?.stringValue,
        name: p["name"]?.stringValue,
        title: p["summary"]?.stringValue,        // human one-line summary
        args: p["args"],
        resultText: p["result_text"]?.stringValue ?? p["result"]?.displayString,
        inlineDiff: p["inline_diff"]?.stringValue,
        durationS: p["duration_s"]?.doubleValue
      )
    case "approval.request":
      if let req = p.decoded(ApprovalRequest.self) { self = .approvalRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    case "clarify.request":
      if let req = ClarifyRequest(legacyEvent: p) { self = .clarifyRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    // The legacy events stay `request_id`-bound (`sudo.respond` / `secret.respond` need it),
    // exactly as before `SecretPrompt.requestID` became optional for the v7 requests.
    case "sudo.request":
      if let req = p.decoded(SecretPrompt.self), req.requestID != nil { self = .sudoRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    case "secret.request":
      if let req = p.decoded(SecretPrompt.self), req.requestID != nil { self = .secretRequest(req) }
      else { self = .unknown(type: type, raw: p) }
    case "request.cancel":
      if let cancel = p.decoded(RequestCancel.self) { self = .requestCancel(cancel) }
      else { self = .unknown(type: type, raw: p) }
    case "error":
      self = .error(message: p["message"]?.stringValue ?? "")
    case "review.summary":
      self = .reviewSummary(text: p["text"]?.stringValue ?? "")
    default:
      self = .unknown(type: type, raw: p)
    }
  }
}

// MARK: - Payload helper types

/// Token / context / cost accounting attached to `message.complete` and `session.info`.
/// Lenient: every field is optional. Verified shape from the M0 probe. `Encodable` too so
/// the non-authoritative snapshot cache (`ChatSnapshotClient`) can round-trip it as JSON.
public struct Usage: Equatable, Sendable, Codable {
  public var model: String?
  public var input: Int?
  public var output: Int?
  public var total: Int?
  public var contextUsed: Int?
  public var contextMax: Int?
  public var contextPercent: Int?
  public var costUSD: Double?
  /// Number of context compactions ("compressions") so far this session. The
  /// gateway sends this as `compressions` (verified in `tui_gateway/server.py`
  /// `_get_usage`); only present once a context compressor is attached.
  public var compressions: Int?

  enum CodingKeys: String, CodingKey {
    case model, input, output, total, compressions
    case contextUsed = "context_used"
    case contextMax = "context_max"
    case contextPercent = "context_percent"
    case costUSD = "cost_usd"
  }

  public init(
    model: String? = nil, input: Int? = nil, output: Int? = nil, total: Int? = nil,
    contextUsed: Int? = nil, contextMax: Int? = nil, contextPercent: Int? = nil,
    costUSD: Double? = nil, compressions: Int? = nil
  ) {
    self.model = model
    self.input = input
    self.output = output
    self.total = total
    self.contextUsed = contextUsed
    self.contextMax = contextMax
    self.contextPercent = contextPercent
    self.costUSD = costUSD
    self.compressions = compressions
  }
}

// MARK: - Context-usage display model

/// Severity buckets for the context-window gauge, mirroring the Hermes TUI status-bar
/// thresholds: `<50` normal, `≥50` moderate, `>80` high, `≥95` critical.
public enum ContextSeverity: String, Equatable, Sendable, CaseIterable {
  case normal
  case moderate
  case high
  case critical

  /// Map a context-usage percent (`0...100+`) to its severity bucket.
  /// Thresholds: `<50` normal, `[50, 80]` moderate, `(80, 95)` high, `≥95` critical.
  public init(percent: Double) {
    if percent >= 95 {
      self = .critical
    } else if percent > 80 {
      self = .high
    } else if percent >= 50 {
      self = .moderate
    } else {
      self = .normal
    }
  }
}

extension Usage {
  /// Whether this usage carries an actual consumption signal (tokens used / context used).
  /// A freshly **resumed** agent reports an all-zero usage until its first turn re-counts the
  /// loaded history, so `session.resume` can hand back a placeholder zero even for a session
  /// with real prior usage. Used to avoid clobbering a real (cached) usage with that zero.
  public var hasUsageSignal: Bool {
    (contextUsed ?? 0) > 0 || (total ?? 0) > 0 || (input ?? 0) > 0 || (output ?? 0) > 0
  }

  /// Compact `k`/`M` token formatting mirroring the TUI's compact display.
  /// Examples: `999 → "999"`, `1_250 → "1k"`, `125_000 → "125k"`, `1_500_000 → "1.5M"`.
  /// The `k` range rounds to a whole thousand; the `M` range keeps one decimal. A value that
  /// rounds up to a full 1000k (e.g. `999_500`) rolls over to `"1M"`.
  public static func formatTokens(_ n: Int) -> String {
    let value = max(0, n)
    if value < 1_000 {
      return "\(value)"
    }
    if value < 1_000_000 {
      let k = Int((Double(value) / 1_000).rounded())
      // Rounding can push the boundary (e.g. 999_500) up to a full 1000k — roll over to "1M".
      if k < 1_000 {
        return "\(k)k"
      }
    }
    let m = (Double(value) / 1_000_000 * 10).rounded() / 10
    if m == m.rounded() {
      return "\(Int(m))M"
    }
    return "\(String(format: "%.1f", m))M"
  }

  /// Short label for the gauge:
  /// - `"125k/200k"` when `contextMax` is known,
  /// - `"125k tok"` when only used/total tokens are known,
  /// - `nil` when nothing usable is known.
  public var tokenLabel: String? {
    let used = contextUsed ?? total
    if let maxTokens = contextMax, maxTokens > 0 {
      let usedValue = used ?? 0
      return "\(Self.formatTokens(usedValue))/\(Self.formatTokens(maxTokens))"
    }
    if let used, used > 0 {
      return "\(Self.formatTokens(used)) tok"
    }
    return nil
  }

  /// Fill fraction `0...1` for the bar:
  /// - `contextPercent/100` (clamped) when present,
  /// - else `contextUsed/contextMax` when both known,
  /// - `nil` when the max is unknown (caller renders text-only, no bar).
  public var contextFraction: Double? {
    if let percent = contextPercent {
      return min(1, max(0, Double(percent) / 100))
    }
    if let used = contextUsed, let maxTokens = contextMax, maxTokens > 0 {
      return min(1, max(0, Double(used) / Double(maxTokens)))
    }
    return nil
  }

  /// Whole-percent label shown inside the composer ring (e.g. `"69%"`), or `nil` when the
  /// max is unknown (no fraction) so the ring renders without a centered number.
  public var contextPercentLabel: String? {
    guard let fraction = contextFraction else { return nil }
    return "\(Int((fraction * 100).rounded()))%"
  }

  /// Severity bucket derived from `contextPercent` (falling back to `contextFraction * 100`).
  /// Defaults to `.normal` when nothing is known.
  public var severity: ContextSeverity {
    if let percent = contextPercent {
      return ContextSeverity(percent: Double(percent))
    }
    if let fraction = contextFraction {
      return ContextSeverity(percent: fraction * 100)
    }
    return .normal
  }
}

/// `session.info` runtime metadata. Large and volatile on the wire — we decode only
/// the few fields the UI needs and ignore the rest (Codable skips unknown keys).
public struct SessionInfo: Equatable, Sendable, Decodable {
  public var model: String?
  public var reasoningEffort: String?
  public var running: Bool?
  public var version: String?
  public var cwd: String?
  public var profileName: String?
  /// Raw wire value so a future policy does not break decoding the entire session.
  public var approvalMode: String?
  public var usage: Usage?
  /// The session's live title. Deliberately read in ONE place: the post-slash
  /// server-authoritative refresh (`.slashHistoryRefreshed`) applies it on top of
  /// `applyActivate`'s runtime info so `/title x` updates the open chat's nav title
  /// immediately. Normal hydrates intentionally leave the title untouched (#36).
  public var title: String?
  /// The server's prompt-wire generation (`desktop_contract`): `>= 7` speaks server→client
  /// requests (v7), 6 is the legacy `*.request` / `*.respond` wire (≤ v2026.9.11). Upstream
  /// types it `int | str | None`, so it is decoded by hand — an Int, or a String that parses
  /// as one, else nil. It must NEVER throw: `ActivateResponse` decodes `info` with `try?`,
  /// so a throw here would drop the model/usage fields along with it.
  public var desktopContract: Int?

  enum CodingKeys: String, CodingKey {
    case model, running, version, cwd, usage, title
    case reasoningEffort = "reasoning_effort"
    case profileName = "profile_name"
    case desktopContract = "desktop_contract"
    case approvalMode = "approval_mode"
  }

  public init(
    model: String? = nil, reasoningEffort: String? = nil, running: Bool? = nil,
    version: String? = nil, cwd: String? = nil, profileName: String? = nil, usage: Usage? = nil,
    title: String? = nil, desktopContract: Int? = nil, approvalMode: String? = nil
  ) {
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.running = running
    self.version = version
    self.cwd = cwd
    self.profileName = profileName
    self.usage = usage
    self.title = title
    self.desktopContract = desktopContract
    self.approvalMode = approvalMode
  }

  /// Hand-written only for `desktopContract`'s lenient decode; every other field keeps the
  /// synthesized semantics (absent → nil, wrong type → throw).
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    model = try c.decodeIfPresent(String.self, forKey: .model)
    reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    running = try c.decodeIfPresent(Bool.self, forKey: .running)
    version = try c.decodeIfPresent(String.self, forKey: .version)
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
    usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    desktopContract = Self.lenientContract(c)
    approvalMode = try c.decodeIfPresent(String.self, forKey: .approvalMode)
  }

  private static func lenientContract(_ c: KeyedDecodingContainer<CodingKeys>) -> Int? {
    if let value = try? c.decodeIfPresent(Int.self, forKey: .desktopContract) { return value }
    if let text = try? c.decodeIfPresent(String.self, forKey: .desktopContract) {
      return text.trimmedNonEmpty.flatMap { Int($0) }
    }
    return nil
  }

}

/// Payload of a sudo / secret prompt: the legacy `sudo.request` / `secret.request` events
/// (keyed by `request_id`, answered through `sudo.respond` / `secret.respond`) and the v7
/// `sudo` / `secret` server requests (no `request_id` — the `srq-…` id on
/// `PendingServerRequest` identifies them; answered through `request.answer {value}`).
///
/// Holds the PROMPT only — never the typed value, which goes straight from the card to the
/// answer RPC and is never stored, logged or echoed.
public struct SecretPrompt: Equatable, Sendable, Decodable {
  /// Legacy event id (`request_id`); `nil` on a v7 server request.
  public var requestID: String?
  public var prompt: String?
  /// v7 `sudo`, v2026.9.21+: the command needing the password (redacted server-side).
  public var command: String?
  /// v7 `secret`: the environment variable the value is stored under (`env_var`).
  public var envVar: String?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case prompt
    case command
    case envVar = "env_var"
  }

  public init(requestID: String? = nil, prompt: String? = nil, command: String? = nil, envVar: String? = nil) {
    self.requestID = requestID
    self.prompt = prompt
    self.command = command
    self.envVar = envVar
  }

  /// Whether a `secret` request names anything to enter (a non-blank `prompt` or `env_var`).
  /// A v7 `secret` without either would render a blind "Secret required" field, so it
  /// does not decode (`PendingServerRequest`). Not applied to `sudo`: its v2026.9.14 params are
  /// legitimately empty (the card says "Password required").
  var namesASecret: Bool {
    [prompt, envVar].contains { $0?.trimmedNonEmpty != nil }
  }

  /// The prompt text the card shows, `nil` when blank.
  public var displayPrompt: String? { prompt?.trimmedNonEmpty }

  /// The card's detail line, `nil` when the request carries none: the sudo `command`
  /// (`$ command`) or the secret's `env_var` (`Saved as ENV_VAR`).
  public func displayDetail(for kind: SecretKind) -> String? {
    switch kind {
    case .sudo: command?.trimmedNonEmpty.map { "$ \($0)" }
    case .secret: envVar?.trimmedNonEmpty.map { "Saved as \($0)" }
    }
  }
}
