import HermesKit
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

  func makeCoordinator() -> Coordinator { Coordinator() }

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
    view.delegate = context.coordinator
    context.coordinator.openURL = context.environment.openURL
    // Hug content tightly so the cell measures the text's natural height.
    view.setContentCompressionResistancePriority(.required, for: .vertical)
    view.setContentHuggingPriority(.required, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    // Re-captured on every update: the `openURL` handler installed by the transcript cell
    // builder is part of the environment and may change between renders.
    context.coordinator.openURL = context.environment.openURL
    view.attributedText = attributed
  }

  /// Routes a tap on a `hermes-file:` link (attached by `MarkdownText.inline`) into
  /// SwiftUI's `openURL`, so both prose renderers end in the same `OpenURLAction` and one
  /// hook in `ChatView` can turn it into `ChatFeature.fileReferenceTapped`. Every other
  /// link keeps the system default (an `https:` link still opens Safari and still gets its
  /// long-press preview menu); our private scheme gets no menu — there is nothing the
  /// system could preview or share for it.
  final class Coordinator: NSObject, UITextViewDelegate {
    var openURL: OpenURLAction?

    func textView(
      _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? {
      guard let url = Self.fileReferenceURL(in: textItem), let openURL else { return defaultAction }
      return UIAction { _ in openURL(url) }
    }

    func textView(
      _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
      guard Self.fileReferenceURL(in: textItem) == nil else { return nil }
      return UITextItem.MenuConfiguration(menu: defaultMenu)
    }

    private static func fileReferenceURL(in textItem: UITextItem) -> URL? {
      guard case let .link(url) = textItem.content, FileReference.path(from: url) != nil else { return nil }
      return url
    }
  }

  /// A real (finite) proposed width is taken whole — the block wraps to the row — and the
  /// height is the text's at that width. Every answer is finite and non-negative (#191):
  ///
  /// - `nil` or an infinite width (SwiftUI's ideal-size and maximum-size probes) answers the
  ///   text's natural, unwrapped size, as `Text` does — never `0`, and never an infinite width
  ///   echoed back into the stacks above;
  /// - a negative width answers `0` wide.
  ///
  /// A narrow-but-positive width still answers a tall block (one glyph per line at 1pt); the
  /// transcript cell's `TranscriptCellLayout` is what keeps that out of a self-sizing pass.
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let proposed = proposal.width, proposed.isFinite else {
      let natural = uiView.sizeThatFits(
        CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
      )
      return CGSize(width: Self.finite(ceil(natural.width)), height: Self.finite(ceil(natural.height)))
    }
    let width = max(proposed, 0)
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: Self.finite(ceil(fitted.height)))
  }

  /// `value` when finite and positive, else 0.
  private static func finite(_ value: CGFloat) -> CGFloat {
    value.isFinite ? max(value, 0) : 0
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
  ///
  /// The parse is `MarkdownText.inline`, which has already attached the `hermes-file:`
  /// links for file references (markdown file links, bare paths, `MEDIA:` tags), so a path
  /// renders in the tint colour like any other link — in the code-span font when it was
  /// backticked — and `SelectableText.Coordinator` can route its tap.
  private static func inlineRuns(_ line: String) -> NSAttributedString {
    let parsed = MarkdownText.inline(line)
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
