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
struct FilePreviewSheet: View {
  let store: StoreOf<FilePreviewFeature>

  @Environment(\.dismiss) private var dismiss

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
  }

  private var isDownloading: Bool {
    if case .downloading = store.share { return true }
    return false
  }

  /// What the toast says here (and announces to VoiceOver) — one constant for the view and
  /// its snapshot.
  static let copiedMessage = "Path copied"

  /// The region under the navigation bar, with the copy toast overlaid. Internal (not
  /// `private`) so the snapshot suite can render it at a pinned size without the navigation
  /// chrome — toast included.
  var content: some View {
    contentBody
      .overlay(alignment: .bottom) {
        CopiedToastView(token: store.copiedToken, message: Self.copiedMessage)
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
