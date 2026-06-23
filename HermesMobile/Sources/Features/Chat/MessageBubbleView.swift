import HermesKit
import SwiftUI

/// A user or assistant message. Assistant text renders as native Markdown.
struct MessageBubbleView: View {
  let role: ChatRow.Role
  let text: String
  let isComplete: Bool
  /// Code-block copy plumbing (#9), forwarded to `MarkdownText` for assistant messages.
  var copiedToken: String?
  var tokenPrefix: String = ""
  var onCopyCode: ((_ text: String, _ token: String) -> Void)?
  /// Raw bytes of images the user attached to this message (#8), shown as thumbnails.
  var attachmentImages: [Data] = []

  var body: some View {
    HStack(alignment: .top) {
      if role == .user { Spacer(minLength: 32) }
      VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
        if !attachmentImages.isEmpty { imageThumbnails }
        if !text.isEmpty {
          if role == .assistant {
            // Assistant text renders as bubble-less, leading-aligned, full-width plain
            // content (Claude-app style) — only user messages keep a bubble.
            MarkdownText(
              text: text,
              copiedToken: copiedToken,
              tokenPrefix: tokenPrefix,
              onCopyCode: onCopyCode
            )
            .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(text)
              .textSelection(.enabled)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(bubbleColor, in: .rect(cornerRadius: 14))
          }
        }
        if !isComplete {
          ProgressView().controlSize(.mini)
        }
      }
    }
  }

  private var imageThumbnails: some View {
    VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
      ForEach(Array(attachmentImages.enumerated()), id: \.offset) { _, data in
        if let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 220, maxHeight: 220)
            .clipShape(.rect(cornerRadius: 12))
        }
      }
    }
  }

  /// The user bubble fill; assistant text is bubble-less so this is only read for `.user`.
  private var bubbleColor: Color {
    Color.accentColor.opacity(0.18)
  }
}
