import Foundation

/// A session as shown in the list (domain model). REST decoding (the exact
/// `/api/sessions` JSON keys) is handled in `HermesRESTClient` (Task 4), where it's
/// verified against the live endpoint — kept out of this domain type to avoid
/// speculative `CodingKeys`.
public struct Session: Equatable, Sendable, Identifiable {
  /// The persisted id (`stored_session_id`) used by REST endpoints.
  public var id: String
  public var title: String?
  public var updatedAt: Date?
  public var preview: String?
  /// Working directory of the session — the workspace it belongs to; the session card's
  /// header label (`workspaceLabel`). Search hits carry none.
  public var cwd: String?
  /// Original start time (decoded for parity with the desktop row; the list orders by
  /// `updatedAt`).
  public var startedAt: Date?
  /// Number of messages — the session card footer's count (`SessionCardContent`), and the
  /// unread fallback for older agents that omit the server-backed `unread` field.
  public var messageCount: Int?
  /// Server-backed read state (`last_read_at` vs activity), shared by Desktop and every
  /// mobile client. Nil means an older agent omitted the field; the list then falls back
  /// to this device's message-count watermark.
  public var unread: Bool?
  /// Server-backed pin state shared with Desktop. Nil means the server omitted the field;
  /// callers must not infer unpinned from an absent value or an absent row.
  public var pinned: Bool?
  /// Whether the session is currently active (a turn ran recently).
  public var isActive: Bool?
  /// Where the session originated (`cron`, `cli`, `telegram`, `discord`, `slack`,
  /// `whatsapp`), or `nil` for local interactive sessions / older agents that omit it.
  /// Kept as a raw string (not enum-ified) so we stay lenient about unknown sources and
  /// only special-case `"cron"` (see `isCron`).
  public var source: String?
  /// The stored id of the session this one was branched from (`parent_session_id` on
  /// REST `GET /api/sessions`). Drives the desktop-style nested rendering in the list;
  /// `nil` for regular sessions and on older agents that omit the field.
  public var parentSessionID: String?
  /// When a session auto-compresses, the server projects its list row forward to the
  /// continuation tip: the row's `id` becomes the TIP id while `_lineage_root_id` keeps
  /// the ORIGINAL id — the one a branch's `parent_session_id` still points at. Needed by
  /// `flattenSessionsWithBranches` so branches keep nesting under a compressed parent
  /// (desktop `byVisibleId` aliasing). `nil` for un-compressed sessions and old agents.
  public var lineageRootID: String?
  /// The raw server model id (`model` on REST `GET /api/sessions`), shown verbatim in the
  /// session card footer exactly as the chat's model chip shows it. `nil` on older agents
  /// that omit the field (or send it blank).
  public var model: String?

  public init(
    id: String,
    title: String? = nil,
    updatedAt: Date? = nil,
    preview: String? = nil,
    cwd: String? = nil,
    startedAt: Date? = nil,
    messageCount: Int? = nil,
    unread: Bool? = nil,
    pinned: Bool? = nil,
    isActive: Bool? = nil,
    source: String? = nil,
    parentSessionID: String? = nil,
    lineageRootID: String? = nil,
    model: String? = nil
  ) {
    self.id = id
    self.title = title
    self.updatedAt = updatedAt
    self.preview = preview
    self.cwd = cwd
    self.startedAt = startedAt
    self.messageCount = messageCount
    self.unread = unread
    self.pinned = pinned
    self.isActive = isActive
    self.source = source
    self.parentSessionID = parentSessionID
    self.lineageRootID = lineageRootID
    self.model = model
  }

  /// Whether this is a cron-scheduled session — the single source of truth for the
  /// Cron Jobs list partition (mirrors the desktop's `source === "cron"` special-case).
  public var isCron: Bool { source == Self.cronSource }

  /// The `source` value of a cron-scheduled run.
  public static let cronSource = "cron"

  /// A real, user-facing title: non-empty and not the server's `"Untitled"` placeholder
  /// (the agent sends that for auto-named/cron sessions before a real title exists).
  /// Mirrors the web app's `session.title && session.title !== "Untitled"` check.
  public var resolvedTitle: String? {
    guard let title = title?.trimmedNonEmpty, title != "Untitled" else { return nil }
    return title
  }

  /// The first-message preview, trimmed, or `nil` when blank.
  public var resolvedPreview: String? { preview?.trimmedNonEmpty }

  /// The human-readable name for the session: a real title, else the first-message
  /// preview, else the raw `id` as an absolute last resort (a real session almost always
  /// has a preview, so the id should rarely surface). One shared rule for the list rows,
  /// search, and the chat header so they never diverge.
  public var displayName: String { resolvedTitle ?? resolvedPreview ?? id }
}

/// Result of `session.create` / `session.resume` over the WebSocket. Verified shape
/// from the M0 probe: the runtime exposes **two** ids — the short live `session_id`
/// used for all subsequent WS calls, and the persisted `stored_session_id` that REST
/// lists. `messages` is present inline (empty for a new session); whether resume
/// returns full history here is resolved in Task 8.
public struct SessionHandle: Equatable, Sendable, Decodable {
  /// Short live/runtime handle (e.g. `8680ce37`); used in all subsequent WS calls.
  public var sessionID: String
  /// Persisted id (e.g. `20260610_120231_afcca6`); the id REST lists.
  public var storedSessionID: String?
  public var messageCount: Int?
  /// Lazy create carries capability info before the agent is built.
  public var info: SessionInfo?

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case storedSessionID = "stored_session_id"
    case messageCount = "message_count"
    case info
  }

  public init(
    sessionID: String, storedSessionID: String? = nil, messageCount: Int? = nil,
    info: SessionInfo? = nil
  ) {
    self.sessionID = sessionID
    self.storedSessionID = storedSessionID
    self.messageCount = messageCount
    self.info = info
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try c.decode(String.self, forKey: .sessionID)
    storedSessionID = try c.decodeIfPresent(String.self, forKey: .storedSessionID)
    messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount)
    info = try? c.decodeIfPresent(SessionInfo.self, forKey: .info)
  }
}

/// The in-flight turn snapshot returned by `session.resume` for a live session: the
/// user's prompt, any assistant text streamed so far, and whether the
/// turn is still streaming. Lost when the agent process restarts (acceptable — no replay
/// buffer). Lenient: every field optional. Mirrors the desktop `SessionInflightTurn`.
public struct SessionInflight: Equatable, Sendable, Decodable {
  public var user: String?
  public var assistant: String?
  public var streaming: Bool?
  /// When the turn started (`started_at`, Unix seconds); `nil` when absent, non-numeric or ≤ 0.
  public var startedAt: Date?
  /// The live turn's starting row type when Hermes started it, not the user — e.g.
  /// `process_complete` (see ``SessionMessage/displayKind``). `user` is then that notice's
  /// model-facing text, so the seed must not paint it as the user's bubble.
  public var displayKind: String?
  public var displayMetadata: JSONValue?
  /// Steers accepted into this turn (`corrections`), in arrival order, trimmed, blanks dropped.
  /// Their own user bubbles, never written over `user` (gateway `_record_inflight_correction`).
  public var corrections: [String]
  /// Per correction, how much of `assistant` (in Unicode scalars, Python `len`) had streamed
  /// when it arrived (`correction_offsets`): where its bubble sits. `nil` unless every
  /// correction has a usable offset (desktop `correctionOffsetsUsable`).
  public var correctionOffsets: [Int]?

  enum CodingKeys: String, CodingKey {
    case user, assistant, streaming, corrections
    case startedAt = "started_at"
    case displayKind = "display_kind"
    case displayMetadata = "display_metadata"
    case correctionOffsets = "correction_offsets"
  }

  public init(
    user: String? = nil, assistant: String? = nil, streaming: Bool? = nil, startedAt: Date? = nil,
    displayKind: String? = nil, displayMetadata: JSONValue? = nil,
    corrections: [String] = [], correctionOffsets: [Int]? = nil
  ) {
    self.user = user
    self.assistant = assistant
    self.streaming = streaming
    self.startedAt = startedAt
    self.displayKind = displayKind
    self.displayMetadata = displayMetadata
    self.corrections = corrections
    self.correctionOffsets = correctionOffsets
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.user = try c.decodeIfPresent(String.self, forKey: .user)
    self.assistant = try c.decodeIfPresent(String.self, forKey: .assistant)
    self.streaming = try c.decodeIfPresent(Bool.self, forKey: .streaming)
    let seconds = (try? c.decodeIfPresent(Double.self, forKey: .startedAt)) ?? nil
    self.startedAt = seconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    self.displayKind = (try? c.decodeIfPresent(String.self, forKey: .displayKind))?.trimmedNonEmpty
    self.displayMetadata = decodeDisplayMetadata(c, forKey: .displayMetadata)
    // Lenient: a malformed list reads as none, never failing the whole hydrate.
    let rawCorrections = (try? c.decodeIfPresent([JSONValue].self, forKey: .corrections)) ?? nil
    let rawOffsets = (try? c.decodeIfPresent([JSONValue].self, forKey: .correctionOffsets)) ?? nil
    var corrections: [String] = []
    var offsets: [Int?] = []
    for (index, raw) in (rawCorrections ?? []).enumerated() {
      guard let text = raw.stringValue?.trimmedNonEmpty else { continue }
      corrections.append(text)
      offsets.append(rawOffsets.flatMap { index < $0.count ? $0[index].intValue : nil }.flatMap { $0 >= 0 ? $0 : nil })
    }
    self.corrections = corrections
    let usable = offsets.compactMap { $0 }
    self.correctionOffsets = !corrections.isEmpty && usable.count == corrections.count ? usable : nil
  }
}

/// `display_metadata` as an object: an older agent sends it as JSON TEXT, which is parsed;
/// anything that is not an object (or fails to parse) is `nil`. Desktop `parseDisplayMetadata`.
func decodeDisplayMetadata<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> JSONValue? {
  let value = (try? c.decodeIfPresent(JSONValue.self, forKey: key)) ?? nil
  let parsed = value?.stringValue.flatMap(JSONValue.init(parsing:)) ?? value
  return parsed?.isObject == true ? parsed : nil
}

/// Result of the `session.resume` hydration call (which serves both stored and live
/// sessions). The type keeps the `Activate` name for continuity; the gateway RPC used is
/// `session.resume` — `session.activate` is live-only and unused by the mobile client.
/// Server-authoritative re-hydration payload: the full transcript `messages`, the runtime
/// `info` (model/reasoning/usage), the authoritative `running` flag, and the `inflight`
/// turn snapshot. The iOS client previously called only `session.resume` and ignored
/// `info`/`running`/`inflight` — the core state-sync bug. Decoded leniently (every field
/// but `sessionID` optional) so an old/odd response never crashes hydration.
public struct ActivateResponse: Equatable, Sendable, Decodable {
  public var sessionID: String
  public var storedSessionID: String?
  public var messages: [SessionMessage]
  public var info: SessionInfo?
  public var running: Bool?
  public var inflight: SessionInflight?
  /// The session's still-open server→client requests (`open_requests`, v7), oldest first.
  /// Present on a live reattach (`session.resume` / `session.activate`) when non-empty;
  /// absent → `[]`. Decoded per entry: a malformed entry is dropped, the rest kept.
  public var openRequests: [OpenRequest]
  /// The canonical snapshot's CAS fences (session-authority hosts, #157); nil on legacy hosts.
  public var fences: SessionFences?

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case storedSessionID = "stored_session_id"
    // `session.resume` returns the stored/persisted id under `resumed` (the live `session_id`
    // it returns is the freshly-reattached in-memory id, used for subsequent RPCs).
    case resumed
    // `session.activate` (the branch-attach path, #34) returns the live-session payload,
    // whose stored/persisted id key is `session_key`.
    case sessionKey = "session_key"
    case messages, info, running, inflight
    case openRequests = "open_requests"
    case revision
    case executionGeneration = "execution_generation"
  }

  public init(
    sessionID: String, storedSessionID: String? = nil, messages: [SessionMessage] = [],
    info: SessionInfo? = nil, running: Bool? = nil, inflight: SessionInflight? = nil,
    openRequests: [OpenRequest] = [], fences: SessionFences? = nil
  ) {
    self.sessionID = sessionID
    self.storedSessionID = storedSessionID
    self.messages = messages
    self.info = info
    self.running = running
    self.inflight = inflight
    self.openRequests = openRequests
    self.fences = fences
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = (try? c.decode(String.self, forKey: .sessionID)) ?? ""
    // Flatten the `try? decodeIfPresent` double-optionals so an absent `stored_session_id`
    // key actually falls through to `resumed` (`session.resume`'s stored-id key) and then
    // to `session_key` (`session.activate`'s live-payload stored-id key, #34).
    let storedKey = (try? c.decodeIfPresent(String.self, forKey: .storedSessionID)) ?? nil
    let resumedKey = (try? c.decodeIfPresent(String.self, forKey: .resumed)) ?? nil
    let liveKey = (try? c.decodeIfPresent(String.self, forKey: .sessionKey)) ?? nil
    storedSessionID = storedKey ?? resumedKey ?? liveKey
    messages = (try? c.decodeIfPresent([SessionMessage].self, forKey: .messages)) ?? []
    info = try? c.decodeIfPresent(SessionInfo.self, forKey: .info)
    running = try? c.decodeIfPresent(Bool.self, forKey: .running)
    inflight = try? c.decodeIfPresent(SessionInflight.self, forKey: .inflight)
    let rawOpenRequests = (try? c.decodeIfPresent([JSONValue].self, forKey: .openRequests)) ?? nil
    openRequests = (rawOpenRequests ?? []).compactMap { $0.decoded(OpenRequest.self) }
    let revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? nil
    let generation = (try? c.decodeIfPresent(Int.self, forKey: .executionGeneration)) ?? nil
    fences = SessionFences(revision: revision, generation: generation)
  }
}

/// A session-authority host's compare-and-swap fences for `session.mutate` (#157):
/// `expected_revision` / `expected_generation`. Built only when both are present.
public struct SessionFences: Equatable, Sendable {
  public var revision: Int
  public var generation: Int

  public init(revision: Int, generation: Int) {
    self.revision = revision
    self.generation = generation
  }

  public init?(revision: Int?, generation: Int?) {
    guard let revision, let generation else { return nil }
    self.init(revision: revision, generation: generation)
  }
}

/// One entry of `open_requests` (v7): a server→client request still waiting on an answer,
/// in the same `{id, method, params}` shape as the live request frame. `params` stays raw —
/// the reconcile decodes it per `method`, exactly as a live frame is. A missing `params`
/// decodes as `.null` (the per-kind decode then rejects it).
public struct OpenRequest: Equatable, Sendable, Decodable {
  public var id: String
  public var method: String
  public var params: JSONValue

  enum CodingKeys: String, CodingKey { case id, method, params }

  public init(id: String, method: String, params: JSONValue = .null) {
    self.id = id
    self.method = method
    self.params = params
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    method = try c.decode(String.self, forKey: .method)
    params = (try? c.decodeIfPresent(JSONValue.self, forKey: .params)) ?? .null
  }
}

/// A stored message from the session-history payload (the `messages` array on
/// `ActivateResponse`). Columns verified against the `messages` table schema. Mapped to
/// `ChatRow` during resume hydration by `reconstructTranscript`.
public struct SessionMessage: Equatable, Sendable, Decodable, Identifiable {
  public var id: Int
  public var role: String
  public var content: String?
  /// `session.resume` carries the message body under `text` (the cooked gateway shape from
  /// the server's `_history_to_messages`); the raw DB/REST schema used `content`. We read
  /// both so reconstruction works regardless of source — `displayText` prefers `text`.
  public var text: String?
  /// Cooked `role:"tool"` row fields (`{role:"tool", name, context}`): the tool's display
  /// `name` and the short args/preview string the server already built (`_tool_ctx`). The
  /// gateway flattens each tool call+result into one such row — there are no `tool_calls`
  /// arrays or `tool_call_id` back-matching in the resume payload.
  public var name: String?
  public var context: String?
  public var timestamp: Double?
  public var toolName: String?
  /// Links a `tool` result message to the assistant `tool_calls` entry that requested it.
  public var toolCallID: String?
  /// On an assistant message: the tool calls it made (name + arguments) — used to
  /// recover the *command* shown in a tool's detail sheet on resume.
  public var toolCalls: [ToolCallRef]?
  /// Reasoning/thinking text recorded on an assistant message. The server may send it
  /// under any of `reasoning` / `reasoning_content` / `reasoning_details` (string form);
  /// `reasoningText` collapses them, mirroring the desktop's `toChatMessages()`.
  public var reasoning: String?
  public var reasoningContent: String?
  /// `reasoning_details` is provider-shaped (often an array). We only surface it when it
  /// arrives as a plain string, matching the desktop fallback.
  public var reasoningDetails: String?
  /// Cooked `role:"tool"` row: the call's full structured arguments (`args`, newer agents;
  /// the server omits it when empty). Kept in whatever JSON shape arrives — the presentation
  /// layer decides what it can read, nothing is dropped here.
  public var args: JSONValue?
  /// Cooked `role:"tool"` row: the edit preview the server persisted with the result
  /// (`display_metadata.tool_result_metadata.inline_diff`), or nil.
  public var inlineDiff: String?
  /// Display-only row type the gateway stamps on rows Hermes wrote itself (`display_kind`):
  /// `async_delegation_complete`, `process_complete`, `model_switch`, `auto_continue`,
  /// `personality_switch`, `failed_turn`, `hidden`, and the user-authored `steer` /
  /// `skill_invocation`. The notices are stored as `role:"user"` (or `"assistant"` for
  /// `failed_turn`) rows so providers accept them; ``reconstructTranscript(_:)`` must not paint
  /// them as the user's (or the model's) bubble. `nil` on ordinary rows.
  public var displayKind: String?
  /// The row's `display_metadata` object (`display_text`, `task_count`, `model_only`, …), or nil.
  public var displayMetadata: JSONValue?
  /// The durable stored-row id a canonical session-authority host projects (`row_id`): the
  /// `through_message_id` boundary of a `session.mutate` branch (#159). Nil on older hosts.
  public var rowID: Int?

  /// The single reasoning string for this message, first-non-empty of the three variants
  /// (`reasoning ?? reasoning_content ?? reasoning_details`), or `nil`.
  public var reasoningText: String? {
    reasoning?.nonEmpty ?? reasoningContent?.nonEmpty ?? reasoningDetails?.nonEmpty
  }

  /// The message body, preferring the cooked `text` field over the raw `content`.
  public var displayText: String? { text?.nonEmpty ?? content?.nonEmpty }

  /// The tool display name for a cooked `role:"tool"` row (`name`), falling back to the raw
  /// `tool_name` from the DB/REST shape.
  public var toolDisplayName: String? { name?.nonEmpty ?? toolName?.nonEmpty }

  enum CodingKeys: String, CodingKey {
    case id, role, content, text, name, context, timestamp, reasoning, args
    case toolName = "tool_name"
    case toolCallID = "tool_call_id"
    case toolCalls = "tool_calls"
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
    case displayKind = "display_kind"
    case displayMetadata = "display_metadata"
    case rowID = "row_id"
  }

  public init(
    id: Int, role: String, content: String? = nil,
    text: String? = nil, name: String? = nil, context: String? = nil,
    timestamp: Double? = nil,
    toolName: String? = nil, toolCallID: String? = nil, toolCalls: [ToolCallRef]? = nil,
    reasoning: String? = nil, reasoningContent: String? = nil, reasoningDetails: String? = nil,
    args: JSONValue? = nil, inlineDiff: String? = nil,
    displayKind: String? = nil, displayMetadata: JSONValue? = nil, rowID: Int? = nil
  ) {
    self.rowID = rowID
    self.id = id
    self.role = role
    self.content = content
    self.text = text
    self.name = name
    self.context = context
    self.timestamp = timestamp
    self.toolName = toolName
    self.toolCallID = toolCallID
    self.toolCalls = toolCalls
    self.reasoning = reasoning
    self.reasoningContent = reasoningContent
    self.reasoningDetails = reasoningDetails
    self.args = args
    self.inlineDiff = inlineDiff
    self.displayKind = displayKind
    self.displayMetadata = displayMetadata
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(Int.self, forKey: .id)) ?? 0
    role = (try? c.decode(String.self, forKey: .role)) ?? ""
    // A cooked tool row carries the RAW stored result (`write_file` / `patch` /
    // `skill_manage` only), which is not always a string (multimodal parts) — keep a
    // non-string value as its display rendering rather than dropping it. Other roles keep
    // the string-only read (their body is the cooked `text`).
    let stringContent = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? nil
    content = stringContent ?? (role == "tool"
      ? ((try? c.decodeIfPresent(JSONValue.self, forKey: .content)) ?? nil)?.displayString
      : nil)
    text = try? c.decodeIfPresent(String.self, forKey: .text)
    name = try? c.decodeIfPresent(String.self, forKey: .name)
    context = try? c.decodeIfPresent(String.self, forKey: .context)
    timestamp = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
    toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
    toolCallID = try? c.decodeIfPresent(String.self, forKey: .toolCallID)
    // tool_calls is OpenAI-shaped; tolerate absence / odd shapes.
    toolCalls = try? c.decodeIfPresent([ToolCallRef].self, forKey: .toolCalls)
    reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
    reasoningContent = try? c.decodeIfPresent(String.self, forKey: .reasoningContent)
    // `reasoning_details` is usually an array of provider blocks; surface only string form.
    reasoningDetails = try? c.decodeIfPresent(String.self, forKey: .reasoningDetails)
    args = ((try? c.decodeIfPresent(JSONValue.self, forKey: .args)) ?? nil)?.nonNull
    displayKind = (try? c.decodeIfPresent(String.self, forKey: .displayKind))?.trimmedNonEmpty
    displayMetadata = decodeDisplayMetadata(c, forKey: .displayMetadata)
    inlineDiff = displayMetadata?["tool_result_metadata"]?["inline_diff"]?.stringValue?.nonEmpty
    rowID = (try? c.decodeIfPresent(Int.self, forKey: .rowID)) ?? nil
  }
}

/// A tool call recorded on an assistant message (`tool_calls`): which tool was invoked
/// and with what arguments. OpenAI-shaped (`{id, function:{name, arguments}}`).
public struct ToolCallRef: Equatable, Sendable, Decodable, Identifiable {
  public var id: String?
  public var name: String?
  /// Raw arguments — a JSON string for OpenAI-style providers.
  public var arguments: String?

  enum CodingKeys: String, CodingKey { case id, function }
  enum FunctionKeys: String, CodingKey { case name, arguments }

  public init(id: String? = nil, name: String? = nil, arguments: String? = nil) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try? c.decodeIfPresent(String.self, forKey: .id)
    if let fn = try? c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function) {
      name = try? fn.decodeIfPresent(String.self, forKey: .name)
      arguments = try? fn.decodeIfPresent(String.self, forKey: .arguments)
    }
  }
}
