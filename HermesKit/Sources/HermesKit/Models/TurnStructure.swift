import Foundation

/// One turn of a transcript: a user row and everything after it up to the next user row.
///
/// Turns are delimited by user message rows only. Rows before the first user row (a branch's
/// seeded reply, a compressed history's summary) form a preamble span with ordinal `-1`; the
/// turn fold never folds it.
public struct TurnSpan: Equatable, Sendable {
  /// How many user rows precede this turn's user row: `0` for the first turn, `-1` for the
  /// preamble (no user row). Stable across a hydrate's id rewrite, so fold state keys on it.
  public var ordinal: Int
  /// Offset of the user row that opens the turn; `nil` for the preamble.
  public var userRowIndex: Int?
  /// Offsets of every row in the turn (the user row included), from the collection's start.
  public var rowRange: Range<Int>
  /// Offset of the turn's FINAL reply — its last assistant `.message` row. `nil` while the
  /// turn is running (any segment so far may turn out to be interim commentary) and for a
  /// turn with no assistant message (tool-only, errored before any text).
  public var finalReplyIndex: Int?
  /// The agent is still working on this turn.
  public var isRunning: Bool
  /// Finished turns only: the latest row timestamp in the turn minus the user row's
  /// timestamp (clamped at 0). `nil` while running, for the preamble, or when either
  /// timestamp is missing (older agents, legacy cached rows) — the header then says "Worked".
  public var duration: TimeInterval?

  public init(
    ordinal: Int,
    userRowIndex: Int?,
    rowRange: Range<Int>,
    finalReplyIndex: Int?,
    isRunning: Bool,
    duration: TimeInterval?
  ) {
    self.ordinal = ordinal
    self.userRowIndex = userRowIndex
    self.rowRange = rowRange
    self.finalReplyIndex = finalReplyIndex
    self.isRunning = isRunning
    self.duration = duration
  }
}

/// Split `rows` into turns (see ``TurnSpan``). Indexes are OFFSETS from the collection's start
/// (`rows.dropFirst(n)` → offset 0 is its first element), so a windowed slice works too —
/// ordinals then count user rows within the slice.
///
/// - Parameter runningTurnOrdinal: the turn the agent is still working on (the newest turn
///   while a turn is live), or `nil` when nothing runs. A running turn has no final reply and
///   no duration.
public func turnSpans(_ rows: some Collection<ChatRow>, runningTurnOrdinal: Int? = nil) -> [TurnSpan] {
  let rows = Array(rows)
  var spans: [TurnSpan] = []
  var start = 0
  var ordinal = -1
  var userIndex: Int?

  func close(at end: Int) {
    // An empty preamble is no span; a user row always makes one.
    guard end > start else { return }
    let range = start..<end
    let isRunning = ordinal == runningTurnOrdinal
    var finalReply: Int?
    var duration: TimeInterval?
    if !isRunning {
      finalReply = range.last { index in
        if case .message(.assistant, _, _) = rows[index].kind { return true }
        return false
      }
      if let userIndex, let started = rows[userIndex].timestamp {
        let latest = rows[(userIndex + 1)..<end].compactMap(\.timestamp).max()
        duration = latest.map { max(0, $0.timeIntervalSince(started)) }
      }
    }
    spans.append(TurnSpan(
      ordinal: ordinal, userRowIndex: userIndex, rowRange: range,
      finalReplyIndex: finalReply, isRunning: isRunning, duration: duration
    ))
  }

  for (index, row) in rows.enumerated() {
    guard case .message(.user, _, _) = row.kind else { continue }
    close(at: index)
    start = index
    ordinal += 1
    userIndex = index
  }
  close(at: rows.count)
  return spans
}
