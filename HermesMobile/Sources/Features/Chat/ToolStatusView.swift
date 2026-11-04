import HermesKit
import SwiftUI

/// A tool call's line inside a turn's fold (the T3 Code look): the tool's icon and its parsed
/// one-line title (`ToolPresentation` — "Ran pytest -q", "Read ChatView.swift L10-40"; the
/// present tense while the call is live) in secondary grey, with a disclosure chevron. A failed
/// call turns its icon red. No status seal and no spinner — the turn header carries the live
/// state. A tap expands the call's body in place below the line (`ToolBodyView`), or folds it
/// back.
struct ToolStatusView: View {
  let call: ToolCall
  /// The call is in flight in the running turn (`ToolCallItem.isLive`).
  var isLive: Bool = false
  /// Whether the body shows below the line (`ToolCallItem.isExpanded`): `›` folded, `⌄` open.
  var isExpanded = false
  let onTap: () -> Void

  var body: some View {
    let presentation = ToolPresentation(call: call)
    let title = presentation.title(live: isLive)
    let failed = presentation.outcome.isFailure
    FoldLine(
      systemImage: presentation.icon.systemImage,
      text: title,
      chevron: isExpanded ? "chevron.down" : "chevron.right",
      iconTint: failed ? .red : .secondary
    )
    .foldTap(isExpanded: isExpanded, action: onTap)
    .accessibilityLabel(failed ? "\(title), failed" : title)
  }
}

extension ToolPresentation.Icon {
  /// The SF Symbol for a call line / uniform run summary.
  var systemImage: String {
    switch self {
    case .terminal: "apple.terminal"
    case .file: "doc.text"
    case .edit: "pencil"
    case .search: "magnifyingglass"
    case .web: "globe"
    case .eye: "eye"
    case .skill: "wrench.adjustable"
    case .delegate: "person.2"
    case .memory: "memorychip"
    case .generic: "wrench.and.screwdriver"
    }
  }
}

extension RunSummary.Icon {
  /// A run of one kind of work shows that kind's icon (a terminal for commands); a mixed run
  /// shows a hammer (the T3 reference).
  var systemImage: String {
    switch self {
    case let .uniform(icon): icon.systemImage
    case .mixed: "hammer"
    }
  }
}
