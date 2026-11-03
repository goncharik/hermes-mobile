import HermesKit
import SwiftUI
import UIKit

/// The text face of the file preview sheet: the server's `read-text` result in a scrolling,
/// selectable, monospaced `UITextView`, under a caption row naming the server-guessed
/// `language` (when it sent one) and a "Showing first 512 KB" banner when the server stopped
/// at its read limit (`truncated`).
///
/// Display-only — the reducer already decided this is text (the server's `binary` verdict);
/// this view never inspects the bytes. The text view fills whatever region the sheet offers:
/// a `UITextView` handed a concrete height swallows it and scrolls inside it (the
/// `ScrollView` gotcha), which is exactly what a full-sheet preview wants. The measured
/// `FilePreviewTextLayoutTests` pin that it fills the slot and that a long file scrolls.
struct MonospacedFileTextView: View {
  let read: FileTextRead

  /// What the banner says — one constant so the snapshot and the view can't disagree on it.
  static let truncatedBanner = "Showing first 512 KB"

  var body: some View {
    VStack(spacing: 0) {
      if let language = read.language, !language.isEmpty {
        Text(language)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 6)
          .background(Color(uiColor: .secondarySystemBackground))
          .accessibilityLabel("Language: \(language)")
      }
      if read.truncated {
        Label(Self.truncatedBanner, systemImage: "info.circle")
          .font(.footnote.weight(.medium))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Color.yellow.opacity(0.18))
      }
      MonospacedTextView(text: read.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A read-only, selectable, *scrolling* `UITextView` in the monospaced body font.
///
/// Distinct from `SelectableText` (the transcript's hugging, non-scrolling prose view): this
/// one takes the whole proposal and scrolls its content inside it, so it has no
/// `sizeThatFits` override and low hugging/compression priorities on both axes.
///
/// The font is the body text style's *default* (unscaled) monospaced size run through
/// `UIFontMetrics(forTextStyle: .body)`: that gives a font `adjustsFontForContentSizeCategory`
/// knows how to rescale when Dynamic Type changes, without scaling twice (an already
/// preferred-sized font fed to `UIFontMetrics` would compound the category's scale).
struct MonospacedTextView: UIViewRepresentable {
  let text: String

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = true
    view.alwaysBounceVertical = true
    view.dataDetectorTypes = []
    view.adjustsFontForContentSizeCategory = true
    view.font = Self.font
    view.textColor = .label
    view.backgroundColor = .clear
    view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    // Fill the offered region rather than hugging the text: the sheet gives this view the
    // whole area under the caption rows, and the content scrolls inside it.
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.text = text
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    // Only on a real change — re-assigning the same text resets the scroll position.
    if view.text != text { view.text = text }
  }

  /// Monospaced body, scaled by Dynamic Type via `UIFontMetrics` (see the type comment for
  /// why the base is the unscaled body size and not `preferredFont(forTextStyle:)`).
  static var font: UIFont {
    let baseSize = UIFontDescriptor.preferredFontDescriptor(
      withTextStyle: .body,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize
    let mono = UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
    return UIFontMetrics(forTextStyle: .body).scaledFont(for: mono)
  }
}
