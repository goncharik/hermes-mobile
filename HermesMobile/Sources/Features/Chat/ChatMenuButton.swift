import ComposableArchitecture
import HermesKit
import SwiftUI

/// The chat screen's nav-bar ellipsis menu (Rename / Copy ID / display toggles), split out of
/// `ChatView` so it observes ONLY the fields it renders (#82).
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
/// when the observed state actually changes, i.e. at session creation, a display toggle, and
/// never mid-turn.
///
/// Deliberately takes the STORE rather than `canRename:` / `onRename:` parameters: closure
/// fields are not comparable, so SwiftUI would have to re-run the body on every parent
/// update anyway and the fix would evaporate.
///
/// The display section lives here rather than in the Settings sheet on purpose: these are
/// per-glance reading controls, and the chat's own menu is where a user looks while a turn
/// is burying the reply they're trying to read (#55). The prefs remain device-local and
/// persist immediately.
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

      Divider()

      // A `Section` header would be redundant next to three self-describing toggles; the
      // divider is enough to separate "about this session" from "how this chat displays".
      Toggle(isOn: Binding(
        get: { store.displayPrefs.showThinkingRows },
        set: { store.send(.showThinkingRowsToggled($0)) }
      )) {
        Label("Show thinking", systemImage: "brain")
      }

      Toggle(isOn: Binding(
        get: { store.displayPrefs.showToolRows },
        set: { store.send(.showToolRowsToggled($0)) }
      )) {
        Label("Show tool calls", systemImage: "wrench.and.screwdriver")
      }

      Toggle(isOn: Binding(
        get: { store.displayPrefs.autoFollowEnabled },
        set: { store.send(.autoFollowToggled($0)) }
      )) {
        Label("Follow new output", systemImage: "arrow.down.to.line")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
  }
}
