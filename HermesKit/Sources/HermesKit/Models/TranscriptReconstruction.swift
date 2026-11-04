import Foundation

/// Pure, server-authoritative re-hydration of a chat transcript from the `session.resume`
/// `messages` array. The gateway returns the server's **cooked** history shape (built by
/// `_history_to_messages`), NOT the raw DB rows — each entry is one of:
///   - a text row: `{role: "user" | "assistant" | "system", text, ...}` (an assistant row
///     may also carry `reasoning` / `reasoning_content` / `reasoning_details`);
///   - a tool row: `{role: "tool", name, context}` — the server has already matched the
///     tool call to its result and flattened it into a single row with a display `name` and
///     a short args/preview `context`. There are **no** `tool_calls` arrays or
///     `tool_call_id` back-matching in this payload.
///
/// Mirrors the desktop TUI's `toTranscriptMessages` (`ui-tui/src/domain/messages.ts`).
/// For each message, in order:
///   1. an assistant **reasoning** row (from `reasoningText`), emitted as a completed
///      `.reasoning` burst;
///   2. an assistant / user **text** row from `displayText` (skipped when empty);
///   3. a completed **tool** row for each `role: "tool"` entry (title = `context`, else `name`; detail =
///      `context` preview + structured `args` + stored `content` + `inline_diff`, whichever
///      the agent sent — `cookedToolDetail`).
///
/// Every row carries the message's server `timestamp` (when present) — display data for turn
/// durations, never part of the id.
///
/// Identity is **deterministic and content-derived**: each row's `id` is a stable UUID
/// hashed from its `(sequenceIndex, role, kindDiscriminator)` — NOT a fresh random UUID per
/// call. So the same history in always yields byte-identical ids out (lets a diffing engine
/// preserve scroll / animate inserts across a hydrate), identical consecutive rows stay
/// distinct (sequence index), and a message and its reasoning row get distinct ids (distinct
/// indices + discriminators). Mutable streaming text is excluded from the id so a live
/// `message.delta` append later reconciles to the same id on the next hydrate.
public func reconstructTranscript(_ messages: [SessionMessage]) -> [ChatRow] {
  var rows: [ChatRow] = []

  // Append a row, assigning its id deterministically from its ordinal position in the output
  // transcript. Building the `Kind` first lets us read the role/discriminator the id derives
  // from before the row exists.
  func append(_ kind: ChatRow.Kind, timestamp: Date?) {
    // Single source for role/discriminator: read them off the `Kind` so this never drifts from
    // `ChatRow.kindDiscriminator` / `ChatRow.rowRole`. The timestamp is display data only —
    // never part of the id.
    let id = ChatRow.deterministicID(
      sequenceIndex: rows.count, role: kind.role, kindDiscriminator: kind.discriminator
    )
    rows.append(ChatRow(id: id, kind: kind, timestamp: timestamp))
  }

  for message in messages {
    // The server's authoring time (Unix seconds); a non-positive value is no time at all.
    let timestamp = message.timestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    switch message.role {
    case "tool":
      // The server already resolved the call → result into one cooked row. The title is the
      // `context` preview, else the name — the live `tool.start` shape, so the presentation
      // reads a reloaded call's target the same way (an older agent's ONLY target).
      let toolName = message.toolDisplayName ?? "tool"
      append(.tool(
        name: toolName, title: message.context?.trimmedNonEmpty ?? toolName, state: .complete,
        detail: cookedToolDetail(message), durationS: nil
      ), timestamp: timestamp)

    case "assistant":
      // 1. Reasoning row (one completed burst per assistant message).
      if let reasoning = message.reasoningText {
        append(.reasoning(text: reasoning, isComplete: true), timestamp: timestamp)
      }
      // 2. Assistant text row (the server omits empty/tool-only assistant turns, so a
      //    missing body here just means there's nothing to render for it).
      if let text = message.displayText {
        append(.message(role: .assistant, text: text, isComplete: true), timestamp: timestamp)
      }

    case "user":
      if let text = message.displayText {
        append(.message(role: .user, text: text, isComplete: true), timestamp: timestamp)
      }

    default:
      // Unknown / `system` role — mobile has no bubble for it; skip, never crash.
      continue
    }
  }

  return rows
}

/// The detail of a cooked `role:"tool"` history row: the `context` preview (as `argsText`),
/// the structured `args` (newer agents), the stored result `content` (edit tools only), and
/// the persisted `inline_diff`. The content mirrors the live `tool.complete` shape: always the
/// raw text as `resultText`, plus the parsed JSON as `result` when it is a JSON object/array.
/// An older agent's `{name, context}` row yields just the preview; nothing at all → `nil`.
func cookedToolDetail(_ message: SessionMessage) -> ToolDetail? {
  let content = message.content?.nonEmpty
  let detail = ToolDetail(
    argsText: message.context?.nonEmpty,
    args: message.args?.nonNull,
    result: content.flatMap(structuredJSON),
    resultText: content,
    inlineDiff: message.inlineDiff?.nonEmpty
  )
  return detail.isEmpty ? nil : detail
}

/// `text` parsed as JSON when it is a JSON object or array; `nil` for anything else (plain
/// text, a bare scalar, malformed JSON) — the caller keeps the raw text either way.
private func structuredJSON(_ text: String) -> JSONValue? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let first = trimmed.first, first == "{" || first == "[",
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
  else { return nil }
  switch value {
  case .object, .array: return value
  default: return nil
  }
}
