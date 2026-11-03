import HermesKit
import SwiftUI

/// The "no preview" face of the file preview sheet: a type glyph, the file name, the full
/// host path (centered and selectable — the user may want to grab a piece of it), the byte
/// size when the server reported one, and ONE line saying why there is no preview, with the
/// server's own `detail` under it when it sent one (the sandbox hint on a 404).
///
/// Display-only: the reason is `FilePreviewFeature.Reason` as decided by the reducer; this
/// view just maps it to copy. Also the view-side fallback for an image the device can't
/// decode (Task 8), so it takes the bare `GenericInfo`, not the whole preview state.
struct GenericFileCardView: View {
  let path: String
  let info: FilePreviewFeature.GenericInfo

  /// The glyph scales with the body text, so a larger text size doesn't leave a tiny icon
  /// over a large name.
  @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 56

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: FilePreviewKind.symbolName(for: path))
        .font(.system(size: symbolSize, weight: .light))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(FilePreviewKind.displayName(for: path))
        .font(.headline)
        .multilineTextAlignment(.center)
      Text(path)
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
      if let byteSize = info.byteSize {
        Text(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Text(Self.reasonText(info.reason))
        .font(.subheadline.weight(.medium))
        .multilineTextAlignment(.center)
        .padding(.top, 8)
      if let detail = info.serverDetail, !detail.isEmpty {
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// One line per reason. The too-large copy deliberately points at Share: the download
  /// route has no cap, so the file is still reachable from this very sheet.
  static func reasonText(_ reason: FilePreviewFeature.Reason) -> String {
    switch reason {
    case .unsupported: "No preview available"
    case .tooLarge: "Too large to preview"
    case .notFound: "Not found on the agent"
    case .protected: "This file is protected"
    }
  }
}
