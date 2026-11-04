import Foundation

/// A run of ≥ 2 consecutive tool calls folded into one summary line — "Read 1 file, ran 4
/// commands, and performed 1 other action" (tool-call display plan, Task 11).
///
/// The vocabulary is the desktop's (`apps/desktop/src/components/assistant-ui/tool/
/// run-summary.ts`) with the T3 Code reference's reading of it: one clause per kind of work,
/// counted ("ran 6 commands"), except that a single edit / web search / page names what it
/// acted on ("Edited foo.swift", `Searched “query”`); clauses in the order their kind FIRST
/// appeared in the run, "other actions" last; an Oxford-style join; failures appended. While
/// the run is live the clause holding the running call reads in the present tense — naming
/// the call itself when it is its clause's only one ("Running pytest -q").
public struct RunSummary: Equatable, Sendable, Identifiable {
  /// The run's leading glyph: the shared tool icon when every call is the same kind of work
  /// (T3: a terminal for a command-only run), else a hammer.
  public enum Icon: Equatable, Sendable {
    case uniform(ToolPresentation.Icon)
    case mixed
  }

  /// Derived from the run's FIRST tool row id (`"run|<id>"`), so it holds while the run grows.
  public var id: UUID
  /// What a summary tap reports.
  public var key: RunKey
  /// The run's calls, in order.
  public var calls: [ToolCall]
  /// Whether the run's call lines are listed below the summary.
  public var isExpanded: Bool
  /// The run is still going: its turn is running AND one of its calls is. The caller decides
  /// (a call left `running` by a stopped turn must not narrate work that stopped happening).
  public var isLive: Bool

  public init(id: UUID, key: RunKey, calls: [ToolCall], isExpanded: Bool, isLive: Bool) {
    self.id = id
    self.key = key
    self.calls = calls
    self.isExpanded = isExpanded
    self.isLive = isLive
  }

  /// The summary line.
  public var text: String { Self.text(calls: calls, live: isLive) }

  /// The summary's glyph.
  public var icon: Icon { Self.icon(calls: calls) }

  /// The summary line for `calls`. `live`: the run is still going — the clause holding its
  /// (first) running call, else its newest call, reads in the present tense.
  public static func text(calls: [ToolCall], live: Bool) -> String {
    let presentations = calls.map(ToolPresentation.init(call:))
    let narrating: Int? = live
      ? (calls.firstIndex { $0.state == .running } ?? (calls.isEmpty ? nil : calls.count - 1))
      : nil
    let liveKind = narrating.map { Clause(presentations[$0]) }

    // Group by clause kind in first-appearance order; "other" always last.
    var order: [Clause] = []
    var groups: [Clause: [Int]] = [:]
    for (index, presentation) in presentations.enumerated() {
      let kind = Clause(presentation)
      if groups[kind] == nil { order.append(kind) }
      groups[kind, default: []].append(index)
    }
    order.sort { ($0 == .other ? 1 : 0) < ($1 == .other ? 1 : 0) }

    let clauses = order.map { kind -> String in
      let members = groups[kind] ?? []
      let units = members.reduce(0) { $0 + unitCount(calls[$1]) }
      return clause(kind, presentations: members.map { presentations[$0] }, units: units,
                    live: kind == liveKind)
    }
    var text = joined(clauses)
    let failed = presentations.count { $0.outcome.isFailure }
    if failed > 0 {
      text += "; \(failed) tool \(failed == 1 ? "call" : "calls") failed"
    }
    return text
  }

  /// `.uniform` when every call shares a run category — the calls' common icon, else the
  /// category's; `.mixed` (a hammer) otherwise.
  public static func icon(calls: [ToolCall]) -> Icon {
    let presentations = calls.map(ToolPresentation.init(call:))
    guard let first = presentations.first,
          presentations.allSatisfy({ $0.category == first.category })
    else { return .mixed }
    if presentations.allSatisfy({ $0.icon == first.icon }) { return .uniform(first.icon) }
    return .uniform(categoryIcon(first.category))
  }

  // MARK: Clauses

  /// One kind of work a clause counts. Finer than ``ToolPresentation/RunCategory`` in one
  /// place: a file READ ("read 5 files", the T3 wording) is split from listing / searching
  /// files ("explored").
  enum Clause: Hashable {
    case edit, readFile, explore, search, readPage, browse, interact, analyze, run, delegate, other

    init(_ presentation: ToolPresentation) {
      switch presentation.category {
      case .edit: self = .edit
      case .explore: self = presentation.name == "read_file" ? .readFile : .explore
      case .search: self = .search
      case .read: self = .readPage
      case .browse: self = .browse
      case .interact: self = .interact
      case .analyze: self = .analyze
      case .run: self = .run
      case .delegate: self = .delegate
      case .other: self = .other
      }
    }

    /// (past, present, singular noun, plural noun)
    var copy: (past: String, present: String, one: String, many: String) {
      switch self {
      case .edit: ("Edited", "Editing", "file", "files")
      case .readFile: ("Read", "Reading", "file", "files")
      case .explore: ("Explored", "Exploring", "file", "files")
      case .search: ("Searched", "Searching", "query", "queries")
      case .readPage: ("Read", "Reading", "page", "pages")
      case .browse: ("Opened", "Opening", "page", "pages")
      case .interact: ("Performed", "Performing", "browser action", "browser actions")
      case .analyze: ("Analyzed", "Analyzing", "image", "images")
      case .run: ("Ran", "Running", "command", "commands")
      case .delegate: ("Delegated", "Delegating", "task", "tasks")
      case .other: ("Performed", "Performing", "other action", "other actions")
      }
    }

    /// A settled clause holding one item names it for these kinds — the target says more
    /// than "1 file" there. Commands, file reads and "other" count even then (the T3 reading:
    /// "Read 1 file, ran 4 commands, and performed 1 other action").
    var namesSettledTarget: Bool {
      switch self {
      case .edit, .search, .readPage, .browse: true
      case .readFile, .explore, .interact, .analyze, .run, .delegate, .other: false
      }
    }

    /// The live clause holding one item names it with the call's own present-tense title —
    /// except for the kinds whose title says nothing a count doesn't.
    var namesLiveTarget: Bool {
      switch self {
      case .interact, .other: false
      default: true
      }
    }
  }

  private static func clause(
    _ kind: Clause, presentations: [ToolPresentation], units: Int, live: Bool
  ) -> String {
    let copy = kind.copy
    if units == 1, presentations.count == 1, let only = presentations.first, only.target != nil {
      if live, kind.namesLiveTarget { return only.liveTitle }
      if !live, kind.namesSettledTarget { return only.settledTitle }
    }
    return "\(live ? copy.present : copy.past) \(units) \(units == 1 ? copy.one : copy.many)"
  }

  /// How many things one call acted on: one, except `web_extract`, which takes several URLs
  /// (desktop `unitCount`).
  private static func unitCount(_ call: ToolCall) -> Int {
    guard call.name == "web_extract",
          case let .array(urls)? = ToolPresentation.object(call.detail?.args)?["urls"],
          !urls.isEmpty
    else { return 1 }
    return urls.count
  }

  /// "A", "A and B", "A, B, and C" — first clause capitalized, the rest lowercased at the
  /// first letter.
  static func joined(_ clauses: [String]) -> String {
    let parts = clauses.enumerated().map { index, text in index == 0 ? text : lowerFirst(text) }
    switch parts.count {
    case 0: return ""
    case 1: return parts[0]
    case 2: return "\(parts[0]) and \(parts[1])"
    default: return parts.dropLast().joined(separator: ", ") + ", and \(parts[parts.count - 1])"
    }
  }

  private static func lowerFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.lowercased() + text.dropFirst()
  }

  private static func categoryIcon(_ category: ToolPresentation.RunCategory) -> ToolPresentation.Icon {
    switch category {
    case .edit: .edit
    case .explore: .file
    case .search: .search
    case .read, .browse, .interact: .web
    case .analyze: .eye
    case .run: .terminal
    case .delegate: .delegate
    case .other: .generic
    }
  }
}
