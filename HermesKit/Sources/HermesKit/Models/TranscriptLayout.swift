import Foundation

// MARK: - Fold expansion (ordinal-keyed)

/// Identifies a tool RUN within a turn: the turn's ordinal plus the run's ordinal among the
/// turn's runs (every run counts, single-call runs included, so a run that grows from one call
/// to two keeps its key). Ordinals — not row ids — so the key survives a hydrate's
/// live → deterministic id rewrite.
public struct RunKey: Hashable, Sendable {
  public var turnOrdinal: Int
  public var runOrdinal: Int

  public init(turnOrdinal: Int, runOrdinal: Int) {
    self.turnOrdinal = turnOrdinal
    self.runOrdinal = runOrdinal
  }
}

/// Identifies one tool call within a turn: the turn's ordinal plus the call's ordinal among the
/// turn's tool rows (in transcript order). Ordinal-keyed for the same reason as ``RunKey``.
public struct CallKey: Hashable, Sendable {
  public var turnOrdinal: Int
  public var callOrdinal: Int

  public init(turnOrdinal: Int, callOrdinal: Int) {
    self.turnOrdinal = turnOrdinal
    self.callOrdinal = callOrdinal
  }
}

/// The user's fold choices for one chat slot — in memory only, keyed by ordinals so a hydrate
/// (which rewrites every row id) leaves them intact.
public struct FoldExpansion: Equatable, Sendable {
  /// A user's explicit choice on a turn header. Absent = the default for the turn's state.
  public enum Override: Equatable, Sendable {
    case expanded
    case collapsed
  }

  /// Turn ordinal → the user's last choice on that header.
  public var turnOverride: [Int: Override]
  /// Runs of ≥ 2 calls the user opened (runs default collapsed).
  public var expandedRuns: Set<RunKey>
  /// Calls whose body the user expanded in place (tool-call display plan, Phase C).
  public var expandedCalls: Set<CallKey>

  public init(
    turnOverride: [Int: Override] = [:],
    expandedRuns: Set<RunKey> = [],
    expandedCalls: Set<CallKey> = []
  ) {
    self.turnOverride = turnOverride
    self.expandedRuns = expandedRuns
    self.expandedCalls = expandedCalls
  }

  /// Whether the turn's folded content shows. A RUNNING turn is expanded unless the user
  /// collapsed it; a FINISHED turn is collapsed unless the user's last action was expand — so
  /// a turn the user left expanded while it ran stays expanded when it finishes.
  public func isTurnExpanded(ordinal: Int, isRunning: Bool) -> Bool {
    let choice = turnOverride[ordinal]
    return isRunning ? choice != .collapsed : choice == .expanded
  }
}

// MARK: - Display items

/// The turn fold's header line: `Working · 19s` while running, `Worked for 4m 31s` once done.
public struct TurnHeader: Equatable, Sendable, Identifiable {
  /// Derived from the turn's user row id (`"turn|<id>"`).
  public var id: UUID
  /// The turn's ordinal (see ``TurnSpan/ordinal``) — what a header tap reports.
  public var ordinal: Int
  public var isRunning: Bool
  /// Whether the turn's folded content is showing below the header.
  public var isExpanded: Bool
  /// Finished turns only: the turn's duration from row timestamps; `nil` → "Worked".
  public var duration: TimeInterval?
  /// A COLLAPSED running turn only: one line naming what the agent is doing right now (the
  /// running call's title, else the turn's spinner label); `nil` otherwise.
  public var liveLine: String?

  public init(
    id: UUID, ordinal: Int, isRunning: Bool, isExpanded: Bool,
    duration: TimeInterval? = nil, liveLine: String? = nil
  ) {
    self.id = id
    self.ordinal = ordinal
    self.isRunning = isRunning
    self.isExpanded = isExpanded
    self.duration = duration
    self.liveLine = liveLine
  }

  /// The header's label. Running: the spinner label (else "Working") and the turn timer;
  /// finished: "Worked for <duration>", or a bare "Worked" when the duration is unknown.
  public func title(activityLabel: String?, elapsedSeconds: Int) -> String {
    if isRunning {
      let label = activityLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Working"
      return "\(label) · \(formatElapsed(elapsedSeconds))"
    }
    guard let duration else { return "Worked" }
    return "Worked for \(formatElapsed(Int(duration)))"
  }
}

/// A run of ≥ 2 consecutive tool calls folded into one summary line.
public struct RunSummary: Equatable, Sendable, Identifiable {
  /// Derived from the run's FIRST tool row id (`"run|<id>"`), so it holds while the run grows.
  public var id: UUID
  /// What a summary tap reports.
  public var key: RunKey
  /// The run's calls, in order.
  public var calls: [ToolCall]
  /// Whether the run's call lines are listed below the summary.
  public var isExpanded: Bool

  public init(id: UUID, key: RunKey, calls: [ToolCall], isExpanded: Bool) {
    self.id = id
    self.key = key
    self.calls = calls
    self.isExpanded = isExpanded
  }

  /// A call in the run is still running — the summary reads in the present tense.
  public var isLive: Bool { calls.contains { $0.state == .running } }

  /// The summary line.
  public var text: String { Self.text(calls: calls, live: isLive) }

  /// Placeholder summary naming the run's tools by wire name — "Used 4 tools: terminal,
  /// read_file" / "Using 2 tools: …" while live. The categorized desktop vocabulary
  /// ("Read 1 file, ran 4 commands, …") replaces it (tool-call display plan, Task 11).
  public static func text(calls: [ToolCall], live: Bool) -> String {
    var names: [String] = []
    for call in calls where !names.contains(call.name) { names.append(call.name) }
    let shown = names.prefix(3).joined(separator: ", ")
    let more = names.count > 3 ? ", and \(names.count - 3) more" : ""
    let verb = live ? "Using" : "Used"
    let noun = calls.count == 1 ? "tool" : "tools"
    return "\(verb) \(calls.count) \(noun): \(shown)\(more)"
  }
}

/// A tool call's line in the transcript.
public struct ToolCallItem: Equatable, Sendable, Identifiable {
  /// The `.tool` row.
  public var row: ChatRow
  /// What a call-line tap reports.
  public var key: CallKey
  /// Whether the call's body is expanded in place (Phase C; always `false` until then).
  public var isExpanded: Bool

  public var id: UUID { row.id }

  public init(row: ChatRow, key: CallKey, isExpanded: Bool) {
    self.row = row
    self.key = key
    self.isExpanded = isExpanded
  }
}

/// One rendered line of the transcript: what `CollectionTranscriptView` diffs over. Built from
/// the windowed rows by ``TranscriptFold/items(rows:expansion:runningTurnOrdinal:liveLine:ordinalOffset:)``.
public enum TranscriptItem: Equatable, Sendable, Identifiable {
  /// A turn's fold header (after its user row).
  case turnHeader(TurnHeader)
  /// A run of ≥ 2 tool calls.
  case runSummary(RunSummary)
  /// A single tool call line.
  case toolCall(ToolCallItem)
  /// A message, reasoning, status or command-output row, rendered as itself.
  case row(ChatRow)

  /// Deterministic: row-backed items use their row's id; a header / summary derives its id
  /// from the row it hangs off, so a re-layout of the same rows yields the same ids.
  public var id: UUID {
    switch self {
    case let .turnHeader(header): return header.id
    case let .runSummary(summary): return summary.id
    case let .toolCall(item): return item.id
    case let .row(row): return row.id
    }
  }

  /// The derived id of the header hanging off the user row `userRowID`.
  public static func turnHeaderID(userRowID: UUID) -> UUID {
    UUID.deterministic(from: "turn|\(userRowID.uuidString)")
  }

  /// The derived id of the summary for the run starting at tool row `firstToolRowID`.
  public static func runSummaryID(firstToolRowID: UUID) -> UUID {
    UUID.deterministic(from: "run|\(firstToolRowID.uuidString)")
  }
}

// MARK: - Layout

/// Flattens transcript rows into display items — the turn fold and run summaries
/// (tool-call display plan, Phase B). Pure: same rows + expansion → same items, same ids.
///
/// Named `TranscriptFold`, not `TranscriptLayout`: the app target already has a
/// `TranscriptLayout` (the collection view's layout metrics), which would shadow this one.
public enum TranscriptFold {
  /// Lay out `rows` (typically the chat's window) as display items.
  ///
  /// Per turn (see ``turnSpans(_:runningTurnOrdinal:)``): its user row, then a header when the
  /// turn is running or has anything to fold, then its rows. A turn's FOLDABLE rows are
  /// everything except the final reply, the running turn's streaming assistant row, and
  /// status / command-output rows (never folded) — a collapsed turn hides exactly those, so
  /// what stays keeps its transcript order. Inside an expanded turn, consecutive tool calls
  /// form RUNS (broken only by assistant text or a never-folded row; reasoning between two
  /// calls stays in the run): a run of ≥ 2 calls shows a summary line, listing its calls only
  /// when the user expanded it; a run of one shows the call line directly. Rows before the
  /// first user row (the preamble) are never folded.
  ///
  /// - Parameters:
  ///   - expansion: the slot's fold choices.
  ///   - runningTurnOrdinal: the turn the agent is working on (absolute ordinal), or `nil`.
  ///   - liveLine: the fallback live line for a collapsed running turn (its spinner label)
  ///     when no call is running.
  ///   - ordinalOffset: user rows BEFORE `rows` (a window over a longer transcript), so turn
  ///     ordinals — the expansion keys — are absolute.
  public static func items(
    rows: some Collection<ChatRow>,
    expansion: FoldExpansion,
    runningTurnOrdinal: Int?,
    liveLine: String?,
    ordinalOffset: Int = 0
  ) -> [TranscriptItem] {
    let rows = Array(rows)
    var items: [TranscriptItem] = []
    let localRunning = runningTurnOrdinal.map { $0 - ordinalOffset }

    for span in turnSpans(rows, runningTurnOrdinal: localRunning) {
      let ordinal = span.ordinal + ordinalOffset
      guard let userIndex = span.userRowIndex else {
        // Preamble (or a window cut mid-turn): plain, never folded.
        var callOrdinal = 0
        for index in span.rowRange {
          items.append(plainItem(rows[index], turnOrdinal: ordinal, callOrdinal: &callOrdinal,
                                 expansion: expansion))
        }
        continue
      }

      items.append(.row(rows[userIndex]))
      let body = (userIndex + 1)..<span.rowRange.upperBound
      let isFolded: (Int) -> Bool = { index in
        Self.isFoldable(rows[index], isFinalReply: index == span.finalReplyIndex, isRunning: span.isRunning)
      }
      let hasFoldable = body.contains(where: isFolded)
      guard span.isRunning || hasFoldable else {
        // Nothing to fold (a plain question and answer): no header.
        for index in body { items.append(.row(rows[index])) }
        continue
      }

      let isExpanded = expansion.isTurnExpanded(ordinal: ordinal, isRunning: span.isRunning)
      items.append(.turnHeader(TurnHeader(
        id: TranscriptItem.turnHeaderID(userRowID: rows[userIndex].id),
        ordinal: ordinal,
        isRunning: span.isRunning,
        isExpanded: isExpanded,
        duration: span.isRunning ? nil : span.duration,
        liveLine: span.isRunning && !isExpanded
          ? Self.liveLine(rows[body], fallback: liveLine) : nil
      )))

      if isExpanded {
        appendExpandedBody(rows, body: body, turnOrdinal: ordinal, expansion: expansion, into: &items)
      } else {
        for index in body where !isFolded(index) { items.append(.row(rows[index])) }
      }
    }
    return items
  }

  /// Whether `row` folds behind its turn's header.
  static func isFoldable(_ row: ChatRow, isFinalReply: Bool, isRunning: Bool) -> Bool {
    switch row.kind {
    case .status, .commandOutput: return false
    case .tool, .reasoning: return true
    case let .message(_, _, isComplete):
      if isFinalReply { return false }
      // The running turn's streaming row may turn out to be the answer: it stays visible.
      if isRunning, !isComplete { return false }
      return true
    }
  }

  /// A collapsed running turn's live line: the newest running call's title, else `fallback`
  /// (the spinner label), else nothing.
  static func liveLine(_ rows: ArraySlice<ChatRow>, fallback: String?) -> String? {
    for row in rows.reversed() {
      if case let .tool(call) = row.kind, call.state == .running {
        return call.title.nonEmpty ?? call.name
      }
    }
    return fallback?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
  }

  private static func isTool(_ row: ChatRow) -> Bool {
    if case .tool = row.kind { return true }
    return false
  }

  private static func isReasoning(_ row: ChatRow) -> Bool {
    if case .reasoning = row.kind { return true }
    return false
  }

  private static func plainItem(
    _ row: ChatRow, turnOrdinal: Int, callOrdinal: inout Int, expansion: FoldExpansion
  ) -> TranscriptItem {
    guard isTool(row) else { return .row(row) }
    let key = CallKey(turnOrdinal: turnOrdinal, callOrdinal: callOrdinal)
    callOrdinal += 1
    return .toolCall(ToolCallItem(row: row, key: key, isExpanded: expansion.expandedCalls.contains(key)))
  }

  /// An expanded turn's body, grouping tool calls into runs.
  private static func appendExpandedBody(
    _ rows: [ChatRow], body: Range<Int>, turnOrdinal: Int, expansion: FoldExpansion,
    into items: inout [TranscriptItem]
  ) {
    var runOrdinal = 0
    var callOrdinal = 0
    var index = body.lowerBound
    while index < body.upperBound {
      guard isTool(rows[index]) else {
        items.append(.row(rows[index]))
        index += 1
        continue
      }
      // The run spans its first to its last call; reasoning BETWEEN calls stays inside it,
      // reasoning after the last call (before text) renders after the run.
      var lastCall = index
      var scan = index
      while scan < body.upperBound, isTool(rows[scan]) || isReasoning(rows[scan]) {
        if isTool(rows[scan]) { lastCall = scan }
        scan += 1
      }
      let run = index...lastCall
      let key = RunKey(turnOrdinal: turnOrdinal, runOrdinal: runOrdinal)
      runOrdinal += 1
      let calls: [ToolCall] = run.compactMap {
        if case let .tool(call) = rows[$0].kind { return call }
        return nil
      }
      let showsCalls: Bool
      if calls.count >= 2 {
        let isExpanded = expansion.expandedRuns.contains(key)
        items.append(.runSummary(RunSummary(
          id: TranscriptItem.runSummaryID(firstToolRowID: rows[index].id),
          key: key, calls: calls, isExpanded: isExpanded
        )))
        showsCalls = isExpanded
      } else {
        showsCalls = true
      }
      for runIndex in run {
        // Count every call so call ordinals don't depend on what's showing.
        let item = plainItem(rows[runIndex], turnOrdinal: turnOrdinal, callOrdinal: &callOrdinal,
                             expansion: expansion)
        if showsCalls { items.append(item) }
      }
      index = lastCall + 1
    }
  }
}
