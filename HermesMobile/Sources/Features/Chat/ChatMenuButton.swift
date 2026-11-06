import ComposableArchitecture
import HermesKit
import SwiftUI

/// The chat screen's nav-bar ellipsis menu (Rename / Copy ID / Archive / Delete), split out
/// of `ChatView` so it observes ONLY the few fields it renders (#82).
///
/// `ChatView.body` re-evaluates on every streaming change — each `message.delta`, tool
/// start/complete, status update, and thinking tick — because it reads `visibleRows`,
/// `isSending`, and friends. While this menu lived inline in `ChatView`'s `.toolbar { }`,
/// every one of those re-evaluations rebuilt the `Menu` and its label, and the toolbar
/// button replayed its appearance each time; with back-to-back tool calls that is the
/// visible flicker loop the tester reported on the icon.
///
/// As a child view holding the store — a reference, which SwiftUI diffs by identity, so the
/// parent's re-render alone does not re-run this body — Observation re-evaluates it only
/// when `canRename` / `sessionKey` / the Archive-Delete gates change — at session creation,
/// first persist, or a destructive action, never on a streaming delta.
///
/// Deliberately takes the STORE rather than `canRename:` / `onRename:` parameters: closure
/// fields are not comparable, so SwiftUI would have to re-run the body on every parent
/// update anyway and the fix would evaporate.
struct ChatMenuButton: View {
  let store: StoreOf<ChatFeature>

  var body: some View {
    Menu {
      // Icons on every item — a `Menu` reserves the glyph gutter as soon as one item has
      // an image, so a bare "Rename" would sit in a blank column.
      Button("Rename", systemImage: "pencil") { store.send(.renameButtonTapped) }
        .disabled(!store.canRename)
      // `sessionKey` is `storedSessionID ?? liveSessionID` — nil only before a session
      // exists at all (a brand-new chat that hasn't been created yet).
      Button("Copy ID", systemImage: "doc.on.doc") { store.send(.copySessionIDTapped) }
        .disabled(store.sessionKey == nil)
      // Archive / Delete mirror the session list's context menu: hidden for a chat with no
      // saved session yet (nothing to archive), Delete also behind the list's capability.
      if store.canArchiveOrDelete {
        Divider()
        Button("Archive", systemImage: "archivebox", role: .destructive) {
          store.send(.archiveButtonTapped)
        }
        .disabled(store.isRemovingSession)
        if store.deleteSupported {
          Button("Delete", systemImage: "trash", role: .destructive) {
            store.send(.deleteButtonTapped)
          }
          .disabled(store.isRemovingSession)
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
  }
}
