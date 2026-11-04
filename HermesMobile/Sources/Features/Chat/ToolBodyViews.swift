import HermesKit
import SwiftUI

/// An expanded call's body in the transcript (tool-call display plan, Phase C): a tinted card
/// under the call line, indented to the line's text, holding the call's outcome message (red
/// for a failure), its purpose-built body cut to the inline caps (`Body.inline()`), and a link
/// to the detail sheet — "Show all" when the caps cut something, "Details" otherwise (the sheet
/// is where the raw args and result live).
///
/// Its own transcript item (`TranscriptItem.toolBody`), so the selectable text here never
/// competes with the call line's tap. No scroll views inside: long lines wrap, so the card's
/// height is its content's.
struct ToolBodyView: View {
  let call: ToolCall
  let onShowAll: () -> Void

  var body: some View {
    let presentation = ToolPresentation(call: call)
    let inline = presentation.body.inline()
    VStack(alignment: .leading, spacing: 8) {
      OutcomeMessageView(outcome: presentation.outcome)
      ToolBodyContent(inline.body, isRunning: call.state == .running)
      Text(inline.isTruncated ? "Show all" : "Details")
        .font(.footnote.weight(.medium))
        .foregroundStyle(.tint)
        .contentShape(Rectangle())
        // `onTapGesture` + button traits, not a `Button`: a `Button` inside the transcript's
        // scroll view lost taps.
        .onTapGesture(perform: onShowAll)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the call's full output")
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
    // Under the call line's text, past its 20pt icon column and 10pt gap (`FoldLine`).
    .padding(.leading, 30)
  }
}

/// A failed call's error (red), or a routine notice (a missing file, `exit 1`) in grey; nothing
/// when the outcome carries no message. Shared with the detail sheet.
struct OutcomeMessageView: View {
  let outcome: ToolPresentation.Outcome

  var body: some View {
    if let message = outcome.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
      Label {
        Text(message)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: outcome.isFailure ? "exclamationmark.triangle.fill" : "info.circle")
      }
      .font(.footnote)
      .foregroundStyle(outcome.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
  }
}

/// Renders one `ToolPresentation.Body` as is — the transcript passes the capped head
/// (`Body.inline()`), the detail sheet the full body. Pure display.
struct ToolBodyContent: View {
  let toolBody: ToolPresentation.Body
  /// The call is still running: an empty output reads "Waiting for output…", not "No output".
  var isRunning = false

  init(_ toolBody: ToolPresentation.Body, isRunning: Bool = false) {
    self.toolBody = toolBody
    self.isRunning = isRunning
  }

  var body: some View {
    switch toolBody {
    case let .terminal(command, exitCode, stdout, stderr):
      TerminalBodyView(command: command, exitCode: exitCode, stdout: stdout, stderr: stderr, isRunning: isRunning)
    case let .diff(path, lines):
      DiffBodyView(path: path, lines: lines)
    case let .fileRead(path, range, content):
      VStack(alignment: .leading, spacing: 6) {
        BodyHeading(systemImage: "doc.text", text: path, detail: range)
        if let content {
          CodeText(content)
        } else {
          EmptyNote(isRunning ? "Reading…" : "No content")
        }
      }
    case let .search(query, hits, totalCount):
      SearchBodyView(query: query, hits: hits, totalCount: totalCount, isRunning: isRunning)
    case let .webPage(url, content):
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
          LinkText(title: url, url: url)
        }
        .font(.footnote)
        if let content {
          ProseText(content)
        } else {
          EmptyNote(isRunning ? "Loading…" : "No content")
        }
      }
    case let .skill(name, file, description):
      VStack(alignment: .leading, spacing: 4) {
        BodyHeading(systemImage: "wrench.adjustable", text: name, detail: file)
        if let description { ProseText(description) }
      }
    case let .delegate(goals):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(goals.enumerated()), id: \.offset) { index, goal in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(goals.count > 1 ? "\(index + 1)." : "•")
              .foregroundStyle(.secondary)
              .monospacedDigit()
            Text(goal)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .font(.footnote)
        }
      }
    case let .generic(summary, raw):
      VStack(alignment: .leading, spacing: 6) {
        if let summary { ProseText(summary) }
        if let raw { CodeText(raw) }
        if summary == nil, raw == nil { EmptyNote(isRunning ? "Running…" : "No details") }
      }
    case let .unavailable(note):
      Label(note, systemImage: "clock.arrow.circlepath")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Terminal

/// `$ command` with its exit badge (green for 0, amber otherwise), then the monospaced output —
/// stdout and stderr labelled when both came back (desktop parity).
private struct TerminalBodyView: View {
  let command: String?
  let exitCode: Int?
  let stdout: String?
  let stderr: String?
  let isRunning: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if command != nil || exitCode != nil {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if let command {
            Text("\(Text("$").foregroundStyle(.secondary)) \(command)")
              .font(.system(.caption, design: .monospaced).weight(.medium))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Spacer(minLength: 0)
          }
          if let exitCode { ExitBadge(code: exitCode) }
        }
      }
      switch (stdout, stderr) {
      case let (out?, err?):
        StreamBlock(label: "stdout", text: out)
        StreamBlock(label: "stderr", text: err)
      case let (out?, nil):
        CodeText(out)
      case let (nil, err?):
        CodeText(err)
      case (nil, nil):
        EmptyNote(isRunning ? "Waiting for output…" : "No output")
      }
    }
  }
}

/// `exit N`: green for success, amber for anything else (the desktop's `TerminalTranscript`).
private struct ExitBadge: View {
  let code: Int

  var body: some View {
    let tint: Color = code == 0 ? .green : .orange
    Text("exit \(code)")
      .font(.system(.caption2, design: .monospaced).weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.15), in: .capsule)
      .fixedSize()
      .accessibilityLabel(code == 0 ? "Exit code 0, success" : "Exit code \(code)")
  }
}

/// One labelled output stream.
private struct StreamBlock: View {
  let label: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      CodeText(text)
    }
  }
}

// MARK: - Diff

/// An edit diff: the file header(s), then each line tinted by kind — green additions, red
/// removals, grey context, the hunk headers and notes dimmed. Lines wrap (no horizontal pan).
private struct DiffBodyView: View {
  let path: String?
  let lines: [DiffLine]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let path, !lines.contains(where: { $0.kind == .file }) {
        BodyHeading(systemImage: "pencil", text: path, detail: nil)
          .padding(.bottom, 4)
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        if line.kind == .file {
          BodyHeading(systemImage: "pencil", text: line.text, detail: nil)
            .padding(.top, index == 0 ? 0 : 6)
            .padding(.bottom, 4)
        } else {
          DiffLineView(line: line)
        }
      }
      if lines.isEmpty { EmptyNote("No changes") }
    }
  }
}

private struct DiffLineView: View {
  let line: DiffLine

  var body: some View {
    Text(marker + line.text)
      .font(.system(.caption, design: .monospaced))
      .italic(line.kind == .note)
      .foregroundStyle(foreground)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(background)
      .accessibilityLabel(accessibilityPrefix + line.text)
  }

  private var marker: String {
    switch line.kind {
    case .added: "+ "
    case .removed: "- "
    case .context: "  "
    case .file, .hunk, .note: ""
    }
  }

  private var foreground: AnyShapeStyle {
    switch line.kind {
    case .added, .removed: AnyShapeStyle(.primary)
    case .context: AnyShapeStyle(.secondary)
    case .hunk, .note, .file: AnyShapeStyle(.tertiary)
    }
  }

  private var background: Color {
    switch line.kind {
    case .added: .green.opacity(0.18)
    case .removed: .red.opacity(0.18)
    default: .clear
    }
  }

  private var accessibilityPrefix: String {
    switch line.kind {
    case .added: "Added: "
    case .removed: "Removed: "
    default: ""
    }
  }
}

// MARK: - Search

/// The query and how many results came back, then each hit: a web hit's title as a link with
/// its snippet, a file match's `path:line` with the matched line.
private struct SearchBodyView: View {
  let query: String?
  let hits: [ToolPresentation.SearchHit]
  let totalCount: Int?
  let isRunning: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let query {
        BodyHeading(systemImage: "magnifyingglass", text: "“\(query)”", detail: countLabel)
      }
      ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
        VStack(alignment: .leading, spacing: 2) {
          if let url = hit.url {
            LinkText(title: hit.title, url: url)
              .font(.footnote.weight(.medium))
          } else {
            Text(hit.title)
              .font(.system(.caption, design: .monospaced).weight(.medium))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let snippet = hit.snippet {
            Text(snippet)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .textSelection(.enabled)
          }
        }
      }
      if hits.isEmpty { EmptyNote(isRunning ? "Searching…" : "No results") }
    }
  }

  private var countLabel: String? {
    let count = max(totalCount ?? 0, hits.count)
    guard count > 0 else { return nil }
    let shown = count > hits.count && !hits.isEmpty ? "\(hits.count) of \(count)" : "\(count)"
    return "\(shown) \(count == 1 ? "result" : "results")"
  }
}

// MARK: - Shared pieces

/// A body's leading line: an icon, the subject (a path, a query, a skill), and an optional
/// trailing detail (`L10-40`, a result count, a skill file).
private struct BodyHeading: View {
  let systemImage: String
  let text: String
  let detail: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text)
        .fontWeight(.medium)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if let detail {
        Text(detail).foregroundStyle(.secondary)
      }
    }
    .font(.footnote)
  }
}

/// Monospaced tool output, selectable, wrapping.
private struct CodeText: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(.caption, design: .monospaced))
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Prose from a tool (a page's text, a summary), selectable, wrapping.
private struct ProseText: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.footnote)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A link inside a body: an attributed `Text`, so the tap goes through the cell's `openURL`
/// hook (`ChatView.openFileReference` hands an `https` link back to the system) instead of a
/// `Button` that would fight the transcript's scroll view. Plain text when `url` doesn't parse.
private struct LinkText: View {
  let title: String
  let url: String

  var body: some View {
    Text(attributed)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var attributed: AttributedString {
    var attributed = AttributedString(title)
    if let link = URL(string: url), link.scheme != nil { attributed.link = link }
    return attributed
  }
}

/// "No output" / "Waiting for output…" — what an empty section says instead of nothing.
private struct EmptyNote: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.tertiary)
  }
}
