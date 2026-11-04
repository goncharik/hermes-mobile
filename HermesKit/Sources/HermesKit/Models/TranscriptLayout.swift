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

  /// A header tap: flip what the turn currently shows and RECORD it as the user's last
  /// choice — so expanding a running turn keeps it open past its finish, and collapsing it
  /// (or never touching it) lets the finish fold it.
  public mutating func toggleTurn(ordinal: Int, isRunning: Bool) {
    turnOverride[ordinal] = isTurnExpanded(ordinal: ordinal, isRunning: isRunning)
      ? .collapsed : .expanded
  }

  /// A run-summary tap: list the run's calls, or fold them back.
  public mutating func toggleRun(_ key: RunKey) {
    if expandedRuns.remove(key) == nil { expandedRuns.insert(key) }
  }

  /// A call-line tap: expand the call's body in place below its line, or fold it back.
  public mutating func toggleCall(_ key: CallKey) {
    if expandedCalls.remove(key) == nil { expandedCalls.insert(key) }
  }

  /// Drop every choice keyed on a turn that no longer exists (ordinal ≥ `turnCount`) — after
  /// a hydrate that removed turns (`/undo`), so a stale choice can't latch onto the NEXT turn
  /// that reuses the ordinal.
  public mutating func prune(turnCount: Int) {
    turnOverride = turnOverride.filter { $0.key < turnCount }
    expandedRuns = expandedRuns.filter { $0.turnOrdinal < turnCount }
    expandedCalls = expandedCalls.filter { $0.turnOrdinal < turnCount }
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
      return "\(Self.liveLabel(activityLabel)) · \(formatElapsed(elapsedSeconds))"
    }
    guard let duration else { return "Worked" }
    return "Worked for \(formatElapsed(Int(duration)))"
  }

  /// A running turn's label without its timer: the spinner line (trimmed), else "Working".
  /// The view lays the timer beside it so a long provider-wait line truncates, not the timer.
  public static func liveLabel(_ activityLabel: String?) -> String {
    activityLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Working"
  }
}

/// A tool call's line in the transcript.
public struct ToolCallItem: Equatable, Sendable, Identifiable {
  /// The `.tool` row.
  public var row: ChatRow
  /// What a call-line tap reports.
  public var key: CallKey
  /// Whether the call's body is expanded in place — a ``TranscriptItem/toolBody(_:)`` item
  /// follows the line.
  public var isExpanded: Bool
  /// The call is in flight: running in the RUNNING turn — its line reads in the present
  /// tense. A call a stopped turn left `running` reads settled.
  public var isLive: Bool

  public var id: UUID { row.id }

  public init(row: ChatRow, key: CallKey, isExpanded: Bool, isLive: Bool = false) {
    self.row = row
    self.key = key
    self.isExpanded = isExpanded
    self.isLive = isLive
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
  /// An expanded call's body (the `.tool` row), right after its line: the capped,
  /// purpose-built view of what the call did (`ToolPresentation.Body`). Its own item — not part
  /// of the line's cell — so the body's selectable text never competes with the line's tap.
  case toolBody(ChatRow)
  /// A message, reasoning, status or command-output row, rendered as itself.
  case row(ChatRow)
  /// The live label + timer for a running turn that has NO header — one with no user row of
  /// ours (the preamble: a branch seed's turn, or a turn another client started in an empty
  /// session). Always the last item; never stored, never persisted.
  case liveIndicator

  /// Deterministic: row-backed items use their row's id; a header / summary derives its id
  /// from the row it hangs off, so a re-layout of the same rows yields the same ids.
  public var id: UUID {
    switch self {
    case let .turnHeader(header): return header.id
    case let .runSummary(summary): return summary.id
    case let .toolCall(item): return item.id
    case let .toolBody(row): return Self.toolBodyID(callRowID: row.id)
    case let .row(row): return row.id
    case .liveIndicator: return Self.liveIndicatorID
    }
  }

  /// The fixed id of ``liveIndicator``.
  public static let liveIndicatorID = UUID.deterministic(from: "liveTurnIndicator")

  /// The derived id of the header hanging off the user row `userRowID`.
  public static func turnHeaderID(userRowID: UUID) -> UUID {
    UUID.deterministic(from: "turn|\(userRowID.uuidString)")
  }

  /// The derived id of the summary for the run starting at tool row `firstToolRowID`.
  public static func runSummaryID(firstToolRowID: UUID) -> UUID {
    UUID.deterministic(from: "run|\(firstToolRowID.uuidString)")
  }

  /// The derived id of the expanded body under the call line of tool row `callRowID`.
  public static func toolBodyID(callRowID: UUID) -> UUID {
    UUID.deterministic(from: "body|\(callRowID.uuidString)")
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
  /// when the user expanded it; a run of one shows the call line directly. A showing call line
  /// the user expanded (`expandedCalls`) is followed by its ``TranscriptItem/toolBody(_:)``.
  /// Rows before the
  /// first user row (the preamble) are never folded. A running turn that gets no header (the
  /// running preamble) ends the items with ``TranscriptItem/liveIndicator`` instead, so a live
  /// turn always shows its label and timer.
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
    var hasRunningHeader = false

    for span in turnSpans(rows, runningTurnOrdinal: localRunning) {
      let ordinal = span.ordinal + ordinalOffset
      guard let userIndex = span.userRowIndex else {
        // Preamble (or a window cut mid-turn): plain, never folded.
        var callOrdinal = 0
        for index in span.rowRange {
          appendPlain(rows[index], turnOrdinal: ordinal, callOrdinal: &callOrdinal,
                      expansion: expansion, isTurnRunning: span.isRunning, into: &items)
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
      if span.isRunning { hasRunningHeader = true }
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
        appendExpandedBody(rows, body: body, turnOrdinal: ordinal, isRunning: span.isRunning,
                           expansion: expansion, into: &items)
      } else {
        for index in body where !isFolded(index) { items.append(.row(rows[index])) }
      }
    }
    if runningTurnOrdinal != nil, !hasRunningHeader { items.append(.liveIndicator) }
    return items
  }

  /// A reasoning burst's one-line preview: its first sentence (or first line), with markdown
  /// bold markers dropped — "**Planning the fix**\n\nI need to…" previews as "Planning the
  /// fix". The view truncates whatever is left to one line; the full text is a tap away.
  public static func reasoningPreview(_ text: String) -> String {
    var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let newline = line.firstIndex(where: \.isNewline) {
      line = String(line[..<newline])
    }
    line = line.replacingOccurrences(of: "**", with: "")
    // Cut after the first sentence terminator that is followed by whitespace (so "3.5" and
    // "e.g.x" don't end a sentence).
    var index = line.startIndex
    while index < line.endIndex {
      let next = line.index(after: index)
      if ".!?".contains(line[index]), next < line.endIndex, line[next].isWhitespace {
        line = String(line[...index])
        break
      }
      index = next
    }
    return line.trimmingCharacters(in: .whitespaces)
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

  /// A collapsed running turn's live line: the newest running call's present-tense title
  /// ("Running pytest -q"), else `fallback` (the spinner label), else nothing.
  static func liveLine(_ rows: ArraySlice<ChatRow>, fallback: String?) -> String? {
    for row in rows.reversed() {
      if case let .tool(call) = row.kind, call.state == .running {
        return ToolPresentation(call: call).liveTitle
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

  private static func isRunningCall(_ row: ChatRow) -> Bool {
    if case let .tool(call) = row.kind { return call.state == .running }
    return false
  }

  /// Append `row` as itself, or — a tool row — as its call line, followed by its body when the
  /// user expanded the call. `shows == false` only counts the call (a collapsed run), so call
  /// ordinals never depend on what is showing.
  private static func appendPlain(
    _ row: ChatRow, turnOrdinal: Int, callOrdinal: inout Int, expansion: FoldExpansion,
    isTurnRunning: Bool, shows: Bool = true, into items: inout [TranscriptItem]
  ) {
    guard isTool(row) else {
      if shows { items.append(.row(row)) }
      return
    }
    let key = CallKey(turnOrdinal: turnOrdinal, callOrdinal: callOrdinal)
    callOrdinal += 1
    guard shows else { return }
    let isExpanded = expansion.expandedCalls.contains(key)
    items.append(.toolCall(ToolCallItem(
      row: row, key: key, isExpanded: isExpanded, isLive: isTurnRunning && isRunningCall(row)
    )))
    if isExpanded { items.append(.toolBody(row)) }
  }

  /// An expanded turn's body, grouping tool calls into runs.
  private static func appendExpandedBody(
    _ rows: [ChatRow], body: Range<Int>, turnOrdinal: Int, isRunning: Bool,
    expansion: FoldExpansion, into items: inout [TranscriptItem]
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
          key: key, calls: calls, isExpanded: isExpanded,
          isLive: isRunning && calls.contains { $0.state == .running }
        )))
        showsCalls = isExpanded
      } else {
        showsCalls = true
      }
      for runIndex in run {
        // Count every call so call ordinals don't depend on what's showing.
        appendPlain(rows[runIndex], turnOrdinal: turnOrdinal, callOrdinal: &callOrdinal,
                    expansion: expansion, isTurnRunning: isRunning, shows: showsCalls, into: &items)
      }
      index = lastCall + 1
    }
  }
}
