import Foundation

/// One row in the chat transcript. Built by `ChatFeature`'s reducer by folding
/// `GatewayEvent`s (Task 8) — not decoded directly from the wire. Identified by a
/// generated UUID (there is no message id in the stream; see "M0 findings").
public struct ChatRow: Equatable, Sendable, Identifiable, Codable {
  public let id: UUID
  public var kind: Kind
  /// Raw bytes of any images the user attached to this message (#8), rendered as
  /// thumbnails in the bubble. Only set on the user's just-sent row — reloaded history
  /// has no local bytes.
  public var attachmentImages: [Data]

  public init(id: UUID, kind: Kind, attachmentImages: [Data] = []) {
    self.id = id
    self.kind = kind
    self.attachmentImages = attachmentImages
  }

  /// `attachmentImages` is intentionally omitted from `CodingKeys`, so attachment BYTES
  /// never round-trip through the snapshot cache — base64 blobs would bloat it and they
  /// can't be re-hydrated from the server anyway (`reconstructTranscript` never sets them).
  /// The rule lives in the type: decode defaults it to `[]`. (See `ChatSnapshotStore`.)
  private enum CodingKeys: String, CodingKey {
    case id
    case kind
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.kind = try c.decode(Kind.self, forKey: .kind)
    self.attachmentImages = []
  }

  public enum Kind: Equatable, Sendable, Codable {
    /// A user or assistant message. `isComplete` is false while it streams.
    case message(role: Role, text: String, isComplete: Bool)
    /// A tool/skill invocation. `title` is the human label (server summary/context →
    /// fallback to `name`); `detail` (args/result/diff) fills in over `tool.complete`.
    case tool(name: String, title: String, state: ToolState, detail: ToolDetail?, durationS: Double?)
    /// Live/collapsible "Thinking" indicator that owns the turn's reasoning plus the
    /// latest `status.update` line. `reasoning` accumulates over deltas; `status` is the
    /// latest context-size/compaction message (shown only in the disclosed area);
    /// `elapsedSeconds` is the frozen final elapsed (written at completion, ignored while
    /// active — the view reads the live `thinkingSeconds`); `isComplete` is false while
    /// the turn runs (live timer + shimmer) and true once frozen.
    case thinking(reasoning: String, status: String?, elapsedSeconds: Int, isComplete: Bool)
    /// A transient status line (e.g. "searching…"); `kind` is an open string.
    case status(kind: String, text: String)

    /// A stable, role-agnostic token per case (NOT its mutable payload). The **single source**
    /// for the row-identity discriminator — `ChatRow.kindDiscriminator` and
    /// `reconstructTranscript` both read this so the value can never drift between them.
    public var discriminator: String {
      switch self {
      case .message: return "message"
      case .tool: return "tool"
      case .thinking: return "thinking"
      case .status: return "status"
      }
    }

    /// The message role for `.message` cases; `nil` for non-message kinds. Single source for
    /// role extraction used by `ChatRow.rowRole` and `reconstructTranscript`.
    public var role: Role? {
      if case let .message(role, _, _) = self { return role }
      return nil
    }
  }

  /// Text put on the pasteboard when the user copies this row (Task 11). Tool rows
  /// prefer their result, then title, then name.
  public var copyText: String {
    switch kind {
    case let .message(_, text, _): return text
    case let .tool(name, title, _, detail, _):
      return detail?.resultText?.nonEmpty ?? title.nonEmpty ?? name
    case let .thinking(reasoning, status, _, _):
      guard let status, !status.isEmpty else { return reasoning }
      return reasoning.isEmpty ? status : reasoning + "\n\n" + status
    case let .status(_, text): return text
    }
  }

  public enum Role: Equatable, Sendable, Codable {
    case user
    case assistant
  }

  /// A stable, role-agnostic token per `Kind` *case* (NOT its mutable payload), used to
  /// derive a deterministic, content-derived `ChatRow.ID`. Excludes streaming text so a
  /// `message.delta` append (which mutates `text`/`reasoning`) keeps the same discriminator —
  /// and therefore the same row id. This is why message #7's reasoning row and its text row
  /// get distinct-but-reproducible ids: they live at distinct sequence indices with distinct
  /// discriminators.
  public var kindDiscriminator: String { kind.discriminator }

  /// The message role for `.message` rows (used as a stable id component); `nil` for
  /// non-message kinds.
  var rowRole: Role? { kind.role }

  /// Build a deterministic `ChatRow.ID` from `(sequenceIndex, role, kindDiscriminator)`,
  /// excluding any mutable text so streaming deltas preserve identity. The same logical row
  /// (same ordinal + role + kind) always hashes to the same UUID, so re-running
  /// `reconstructTranscript` over identical history yields byte-identical ids — which is what
  /// lets a diffing engine preserve scroll/animate inserts across a hydrate.
  public static func deterministicID(
    sequenceIndex: Int,
    role: Role?,
    kindDiscriminator: String
  ) -> UUID {
    let roleToken: String
    switch role {
    case .some(.user): roleToken = "user"
    case .some(.assistant): roleToken = "assistant"
    case .none: roleToken = "_"
    }
    let seed = "\(sequenceIndex)|\(roleToken)|\(kindDiscriminator)"
    return UUID.deterministic(from: seed)
  }

  public enum ToolState: Equatable, Sendable, Codable {
    case running
    case complete
  }
}

/// Expanded detail for a tool/skill row, shown in the detail sheet. Populated from the
/// richer `tool.start`/`tool.complete` payloads (args, result, edit diff).
public struct ToolDetail: Equatable, Sendable, Codable {
  /// Human-readable args (from `tool.start` `args_text`, verbose runs).
  public var argsText: String?
  /// Structured call args (from `tool.complete`), rendered as pretty JSON.
  public var args: JSONValue?
  /// Result text (`result_text`, or a stringified `result`).
  public var resultText: String?
  /// Unified edit diff for file-editing tools (`inline_diff`).
  public var inlineDiff: String?

  public init(
    argsText: String? = nil,
    args: JSONValue? = nil,
    resultText: String? = nil,
    inlineDiff: String? = nil
  ) {
    self.argsText = argsText
    self.args = args
    self.resultText = resultText
    self.inlineDiff = inlineDiff
  }

  public var isEmpty: Bool {
    argsText == nil && (args == nil || args == .null) && resultText == nil && inlineDiff == nil
  }
}

extension UUID {
  /// A reproducible UUID derived from an arbitrary seed string via two independent FNV-1a
  /// 64-bit hashes (one over the seed, one over a salted seed) packed into the 16 UUID bytes.
  /// Pure and platform-independent (no `Foundation` randomness / crypto), so the same seed
  /// always yields the same UUID across runs and OSes — the property `reconstructTranscript`
  /// relies on for stable row identity.
  static func deterministic(from seed: String) -> UUID {
    func fnv1a(_ string: String) -> UInt64 {
      var hash: UInt64 = 0xcbf2_9ce4_8422_2325
      for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
      }
      return hash
    }
    let hi = fnv1a(seed)
    let lo = fnv1a("salt:" + seed)
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: hi >> (UInt64(i) * 8)) }
    for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: lo >> (UInt64(i) * 8)) }
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }
}

/// Format an elapsed duration in `1h 1m 1s` style for the Thinking indicator. Omits
/// higher-order zero units but always keeps the seconds unit (so `5 → "5s"`,
/// `61 → "1m 1s"`, `3600 → "1h 0m 0s"`, `3661 → "1h 1m 1s"`). Negative inputs floor to
/// `"0s"`.
public func formatElapsed(_ seconds: Int) -> String {
  let total = max(0, seconds)
  let h = total / 3600
  let m = (total % 3600) / 60
  let s = total % 60
  if h > 0 { return "\(h)h \(m)m \(s)s" }
  if m > 0 { return "\(m)m \(s)s" }
  return "\(s)s"
}
