import SwiftUI
import UIKit

/// A non-editable, fully selectable text view for assistant prose.
///
/// SwiftUI's `.textSelection(.enabled)` is unreliable inside the `UICollectionView`
/// transcript renderer (the cell/scroll gestures pre-empt it) and, because `MarkdownText`
/// renders prose line-by-line, only ever lets you select a single line. A `UITextView`
/// owns its own text-interaction gestures (which take priority over the collection view's
/// scroll/tap), so a long-press starts a real drag-selection that spans the whole block —
/// the behaviour the Claude iOS app has (#27b). Sizes itself for the proposed width so it
/// lays out correctly inside a self-sizing `UIHostingConfiguration` cell.
struct SelectableText: UIViewRepresentable {
  let attributed: NSAttributedString

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = true
    view.dataDetectorTypes = []
    // Hug content tightly so the cell measures the text's natural height.
    view.setContentCompressionResistancePriority(.required, for: .vertical)
    view.setContentHuggingPriority(.required, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    view.attributedText = attributed
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: ceil(fitted.height))
  }
}

/// Builds a UIKit attributed string for a prose block, resolving inline Markdown
/// (bold/italic/inline-code/links) to concrete fonts and inlining list bullets. Kept here
/// (not in HermesKit) because it bridges to `UIFont`/`UIColor`.
enum ProseAttributedBuilder {
  static func make(_ value: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        // Preserve paragraph breaks.
      } else if let bullet = MarkdownText.listMarker(trimmed) {
        result.append(plainRun(bullet.marker + "  ", color: .secondaryLabel))
        result.append(inlineRuns(bullet.content))
      } else {
        result.append(inlineRuns(trimmed))
      }
      if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
    }
    return result
  }

  private static func plainRun(_ text: String, color: UIColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
      .font: UIFont.preferredFont(forTextStyle: .body),
      .foregroundColor: color,
    ])
  }

  /// Parse one line of inline Markdown and resolve each run's presentation intent to a
  /// concrete `UIFont`, so bold/italic/code render in a `UITextView` (which, unlike
  /// SwiftUI's `Text`, does not interpret `inlinePresentationIntent` on its own).
  private static func inlineRuns(_ line: String) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let parsed = try? AttributedString(markdown: line, options: options) else {
      return plainRun(line, color: .label)
    }
    let output = NSMutableAttributedString()
    for run in parsed.runs {
      let text = String(parsed[run.range].characters)
      let intent = run.inlinePresentationIntent ?? []
      var attrs: [NSAttributedString.Key: Any] = [
        .font: font(for: intent),
        .foregroundColor: UIColor.label,
      ]
      if let link = run.link {
        attrs[.link] = link
        attrs[.foregroundColor] = UIColor.tintColor
      }
      output.append(NSAttributedString(string: text, attributes: attrs))
    }
    return output
  }

  private static func font(for intent: InlinePresentationIntent) -> UIFont {
    let base = UIFont.preferredFont(forTextStyle: .body)
    if intent.contains(.code) {
      return UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
    }
    var traits: UIFontDescriptor.SymbolicTraits = []
    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
    guard !traits.isEmpty,
          let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
    return UIFont(descriptor: descriptor, size: base.pointSize)
  }
}
