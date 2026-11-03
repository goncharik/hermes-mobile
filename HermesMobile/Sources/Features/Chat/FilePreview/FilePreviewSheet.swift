import ComposableArchitecture
import HermesKit
import SwiftUI

/// The modal file preview raised by a `hermes-file:` tap in the transcript
/// (`ChatFeature.filePreview`, presented from `ChatView` via `.sheet(item:)`).
///
/// A thin shell over `FilePreviewFeature`: the title is the file name, `Done` dismisses
/// through the presentation binding (SwiftUI's `dismiss` nils the `.sheet(item:)` binding,
/// which TCA turns into `.filePreview(.dismiss)` — the reducer's cleanup hook), and the
/// bottom bar carries the two actions every kind offers, Copy path and Share. The body
/// switches on `content`: text renders in `MonospacedFileTextView`, images in
/// `ZoomableImageView`, PDFs in `PDFKitView`, and anything the reducer resolved to `.generic`
/// in `GenericFileCardView`.
///
/// Image and PDF bytes are decoded HERE, not in the reducer (HermesKit is platform-free):
/// `ZoomableImageView.image(from:)` / `PDFKitView.document(from:)` are synchronous static
/// checks, and a nil result falls back to the generic card with reason `.unsupported`. The
/// two branches are `Equatable` sub-views keyed on the bytes, so a re-render for the copy
/// toast or the share bar does not decode a multi-megabyte image again or reset its zoom.
///
/// The "Path copied" toast is the shared `CopiedToastView` off `copiedToken`, overlaid on the
/// content region INSIDE the navigation stack: the region's safe area already excludes the
/// bottom bar, so the toast floats just above Copy path / Share instead of under them, and
/// nothing between it and the sheet can swallow it.
///
/// Share: while `share` is `.downloading` a thin status strip sits at the bottom of the content
/// region (a `safeAreaInset`, so the toast still floats above it): a determinate bar with the
/// percentage when the server sent a `Content-Length`, a small spinner otherwise, and Cancel
/// (`.cancelDownload`). A failed download shows `shareError` in the same strip until the next
/// Share clears it (the reducer's job). Once the bytes are on disk (`.ready(url)`) the system
/// share sheet is presented through `.sheet(item:)` over a `ShareItem` derived from that state;
/// both ways out — the activity controller's completion and a swipe-down on the sheet — end in
/// ONE `.shareDismissed`, guarded here by checking that the share is still `.ready`.
struct FilePreviewSheet: View {
  let store: StoreOf<FilePreviewFeature>

  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(store.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
          ToolbarItemGroup(placement: .bottomBar) {
            Button {
              store.send(.copyPath)
            } label: {
              Label("Copy path", systemImage: "doc.on.doc")
            }
            Spacer()
            Button {
              store.send(.shareTapped)
            } label: {
              Label("Share", systemImage: "square.and.arrow.up")
            }
            // One download at a time: the button comes back when the bytes are on disk
            // (or the download failed / was cancelled).
            .disabled(isDownloading)
          }
        }
    }
    .task { store.send(.task) }
    // The system share sheet, over the preview. A SwiftUI sheet (not a popover) so the iPad
    // popover-anchor requirement never applies — see `ActivityShareSheet`.
    .sheet(item: shareItem) { item in
      ActivityShareSheet(url: item.url, onComplete: sendShareDismissed)
        .presentationDetents([.medium, .large])
    }
  }

  private var isDownloading: Bool {
    if case .downloading = store.share { return true }
    return false
  }

  /// `.ready(url)` as an `Identifiable` item for `.sheet(item:)`. Setting it to nil (swipe-down)
  /// is the dismissal; the activity controller's own completion takes the same route.
  private var shareItem: Binding<ShareItem?> {
    Binding(
      get: {
        if case let .ready(url) = store.share { return ShareItem(url: url) }
        return nil
      },
      set: { item in
        if item == nil { sendShareDismissed() }
      }
    )
  }

  /// One `.shareDismissed` per presentation: the completion handler and the binding reset can
  /// both fire for the same dismissal, and the second finds the share already `.idle`.
  private func sendShareDismissed() {
    guard case .ready = store.share else { return }
    store.send(.shareDismissed)
  }

  /// What the toast says here (and announces to VoiceOver) — one constant for the view and
  /// its snapshot.
  static let copiedMessage = "Path copied"

  /// The region under the navigation bar, with the copy toast overlaid and the share status
  /// strip inset at the bottom. Internal (not `private`) so the snapshot suite can render it
  /// at a pinned size without the navigation chrome — toast and strip included.
  ///
  /// Order matters: the toast overlay is attached BEFORE the bottom `safeAreaInset`, so the
  /// strip can't swallow it and the toast's `.safeAreaPadding(.bottom)` lifts it above the
  /// strip while one is showing.
  var content: some View {
    contentBody
      .overlay(alignment: .bottom) {
        CopiedToastView(token: store.copiedToken, message: Self.copiedMessage)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        shareStatus
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: shareStatusKind)
  }

  /// What the strip shows — the animation key, so only appearance / disappearance / a swap
  /// between the two animates, never each progress tick.
  private enum ShareStatusKind: Equatable {
    case none, downloading, error
  }

  private var shareStatusKind: ShareStatusKind {
    if case .downloading = store.share { return .downloading }
    return store.shareError == nil ? .none : .error
  }

  @ViewBuilder
  private var shareStatus: some View {
    switch store.share {
    case let .downloading(fraction):
      ShareDownloadStrip(fraction: fraction) { store.send(.cancelDownload) }
    case .idle, .ready:
      if let message = store.shareError {
        ShareErrorStrip(message: message)
      }
    }
  }

  @ViewBuilder
  private var contentBody: some View {
    switch store.content {
    case .loading:
      ProgressView("Loading…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    case let .generic(info):
      GenericFileCardView(path: store.path, info: info)

    case let .failed(message):
      ContentUnavailableView {
        Label("Couldn't load file", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Retry") { store.send(.retry) }
          .buttonStyle(.borderedProminent)
      }

    case let .text(read):
      MonospacedFileTextView(read: read)

    case let .image(data):
      ImagePreviewBody(path: store.path, fileName: store.fileName, data: data)
        .equatable()

    case let .pdf(data):
      PDFPreviewBody(path: store.path, data: data)
        .equatable()
    }
  }
}

/// The `.image` branch: decodes once per distinct `data` (see `Equatable`) and falls back to
/// the generic card — with the byte count, which is known — when UIKit can't make an image
/// out of the bytes.
private struct ImagePreviewBody: View, Equatable {
  let path: String
  let fileName: String
  let data: Data

  var body: some View {
    if let image = ZoomableImageView.image(from: data) {
      ZoomableImageView(image: image, accessibilityLabel: fileName)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      GenericFileCardView(path: path, info: .init(reason: .unsupported, byteSize: data.count))
    }
  }
}

/// The `.pdf` branch: same shape as `ImagePreviewBody`, with PDFKit as the decoder.
private struct PDFPreviewBody: View, Equatable {
  let path: String
  let data: Data

  var body: some View {
    if let document = PDFKitView.document(from: data) {
      PDFKitView(document: document)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      GenericFileCardView(path: path, info: .init(reason: .unsupported, byteSize: data.count))
    }
  }
}

/// `ShareState.ready(url)` as the `.sheet(item:)` payload. Identified by the URL string: a
/// second Share re-presents the same temp file, and a new download gets a new `<UUID>` folder.
private struct ShareItem: Identifiable {
  let url: URL
  var id: String { url.absoluteString }
}

/// The in-flight Share download: label with the percentage (when `Content-Length` was
/// announced), Cancel, and a determinate linear bar under them — or a small spinner in the
/// label row when the size is unknown (no `Content-Length`: a bar with nothing to fill would
/// read as stuck at zero).
private struct ShareDownloadStrip: View {
  let fraction: Double?
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 8) {
        if fraction == nil {
          ProgressView()
            .controlSize(.small)
        }
        Text(label)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", action: onCancel)
          .font(.caption.weight(.semibold))
      }
      if let fraction {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(Color(uiColor: .secondarySystemBackground))
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }

  private var label: String {
    guard let fraction else { return "Downloading…" }
    return "Downloading… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
  }
}

/// A failed Share download, in the chat's error-banner idiom (red caption over a faint tint).
/// Stays until the next Share, which the reducer clears `shareError` on.
private struct ShareErrorStrip: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.caption.weight(.medium))
      .foregroundStyle(.red)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(Color.red.opacity(0.12))
      .overlay(alignment: .top) { Divider() }
  }
}
