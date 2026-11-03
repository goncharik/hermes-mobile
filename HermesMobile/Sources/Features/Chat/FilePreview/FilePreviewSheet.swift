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
/// switches on `content`; text, image and PDF renderers arrive in Tasks 7–8 and replace the
/// placeholders here.
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

  /// The region under the navigation bar. Internal (not `private`) so the snapshot suite can
  /// render it at a pinned size without the navigation chrome.
  @ViewBuilder
  var content: some View {
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

    // Placeholders until the real renderers land (Task 7: text, Task 8: image + PDF).
    case .text:
      placeholder("Text preview")
    case .image:
      placeholder("Image preview")
    case .pdf:
      placeholder("PDF preview")
    }
  }

  private func placeholder(_ title: String) -> some View {
    Text(title)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
