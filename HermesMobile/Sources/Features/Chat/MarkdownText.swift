import HermesKit
import SwiftUI

/// Renders assistant Markdown with support for fenced code blocks and lists.
///
/// SwiftUI's `Text` does not lay out block-level Markdown (lists collapse onto one
/// line, newlines vanish), so we render structure ourselves: split ``` fences via
/// `MarkdownSegment.parse`, then render prose line-by-line — list items get an explicit
/// bullet/number, and each line keeps inline Markdown (bold, code, links).
struct MarkdownText: View {
  let text: String
  /// Token of the code block currently showing the "copied" checkmark (#9). Compared
  /// against each block's per-instance token.
  var copiedToken: String?
  /// Disambiguates this message's code blocks from other messages' (typically the row id).
  var tokenPrefix: String = ""
  /// Invoked with the block's raw text and its token when its copy button is tapped.
  /// When `nil`, no copy button is shown (e.g. previews/snapshots without a store).
  var onCopyCode: ((_ text: String, _ token: String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownSegment.parse(text).enumerated()), id: \.offset) { index, segment in
        switch segment {
        case let .prose(value):
          prose(value)
        case let .heading(level, value):
          heading(level: level, text: value)
        case let .blockquote(value):
          blockquote(value)
        case let .table(headers, rows):
          tableView(headers: headers, rows: rows)
        case let .code(value, language):
          let token = "\(tokenPrefix)#\(index)"
          CodeBlockView(
            code: value,
            language: language,
            isCopied: copiedToken == token,
            onCopy: onCopyCode.map { copy in { copy(value, token) } }
          )
        }
      }
    }
  }

  private func prose(_ value: String) -> some View {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return VStack(alignment: .leading, spacing: 3) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        lineView(line)
      }
    }
  }

  /// An ATX header: scaled bold text, level 1–6 mapping to decreasing font sizes.
  private func heading(level: Int, text: String) -> some View {
    Text(inline(text))
      .font(Self.headingFont(level: level))
      .fontWeight(.bold)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static func headingFont(level: Int) -> Font {
    switch level {
    case 1: return .title
    case 2: return .title2
    case 3: return .title3
    case 4: return .headline
    case 5: return .subheadline
    default: return .callout
    }
  }

  /// A blockquote: an indented secondary-styled block with a leading vertical bar.
  private func blockquote(_ value: String) -> some View {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return HStack(alignment: .top, spacing: 8) {
      Rectangle()
        .fill(Color.secondary.opacity(0.4))
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(inline(line))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// A pipe table rendered as a `Grid`: an emphasized header row, a divider, then body
  /// rows. Cells are left-aligned, inline Markdown applied, and allowed to wrap.
  private func tableView(headers: [String], rows: [[String]]) -> some View {
    let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
    return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
      GridRow {
        ForEach(0..<columnCount, id: \.self) { col in
          Text(inline(col < headers.count ? headers[col] : ""))
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Divider()
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(0..<columnCount, id: \.self) { col in
            Text(inline(col < row.count ? row[col] : ""))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func lineView(_ line: String) -> some View {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      // Paragraph break: a small gap, no empty Text (which would collapse).
      Spacer().frame(height: 2)
    } else if let bullet = Self.listMarker(trimmed) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(bullet.marker).foregroundStyle(.secondary)
        Text(inline(bullet.content)).frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      Text(inline(trimmed)).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Inline-only Markdown so bold/code/links render but block layout (which `Text`
  /// can't show) is avoided; whitespace is preserved.
  private func inline(_ value: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
  }

  /// Classify a line as a list item, returning the marker to show and the content
  /// after it. Handles `-`/`*`/`+` bullets and `N.` ordered items.
  static func listMarker(_ trimmed: String) -> (marker: String, content: String)? {
    for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
      return ("•", String(trimmed.dropFirst(prefix.count)))
    }
    // Ordered list: leading digits followed by ". ".
    let digits = trimmed.prefix { $0.isNumber }
    if !digits.isEmpty {
      let rest = trimmed[digits.endIndex...]
      if rest.hasPrefix(". ") {
        return ("\(digits).", String(rest.dropFirst(2)))
      }
    }
    return nil
  }
}

/// A fenced code block rendered in a monospaced box with an optional per-block copy
/// button (#9). Tapping copy flips the icon to a green checkmark; the parent reducer
/// owns the transient feedback so the checkmark clears on a timer.
struct CodeBlockView: View {
  let code: String
  let language: String?
  let isCopied: Bool
  /// `nil` hides the copy button (previews/snapshots without a store).
  let onCopy: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text(code)
      .font(.callout.monospaced())
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
      .overlay(alignment: .topTrailing) {
        if let onCopy {
          Button(action: onCopy) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
              .font(.caption.weight(.medium))
              .foregroundStyle(isCopied ? Color.green : Color.secondary)
              .padding(6)
              .background(.thinMaterial, in: .circle)
          }
          .buttonStyle(.plain)
          .padding(6)
          .accessibilityLabel(isCopied ? "Copied" : "Copy code")
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isCopied)
        }
      }
  }
}
