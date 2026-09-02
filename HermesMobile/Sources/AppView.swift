import ComposableArchitecture
import HermesKit
import SwiftUI

/// Root view: the onboarding screen until connected, then a `NavigationSplitView` whose
/// sidebar is the session list (inside the navigation stack that pushes chat screens in
/// compact width) and whose detail column is the live chat (regular width, #80).
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.scenePhase) private var scenePhase
  // Read at the ROOT, outside the split view: inside a sidebar column the environment
  // reports `.compact` even on a 13" iPad, which would flip the reducer into the stack
  // layout for the whole window.
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  /// Presentation only — which split-view columns are showing (the sidebar toggle in
  /// portrait, the overlay's dismissal). Deliberately view-local `@State`, not reducer
  /// state: it affects nothing the reducer decides (`layout` does that), and mirroring it
  /// would only add a binding round-trip for the system's own toggle button.
  @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

  var body: some View {
    content
      .task { store.send(.task) }
      .sheet(item: $store.scope(state: \.reauth, action: \.reauth)) { reauthStore in
        ReauthView(store: reauthStore)
      }
      // Observe lifecycle here (view stays thin) and dispatch into the reducer, which fans
      // foreground out to reconnect/re-hydrate + list refresh and background out to an
      // immediate snapshot/anchor flush. Behaviour is unit-tested via `scenePhaseChanged`.
      .onChange(of: scenePhase) { _, newPhase in
        store.send(.scenePhaseChanged(newPhase.appPhase))
      }
      // Same pattern for the layout regime (#80): the size class — NOT the device idiom, so
      // Slide Over and narrow iPadOS windows get the stack — is reported to the reducer,
      // which owns every consequence (marker push/clear, the regular-width new-chat seat).
      // `initial: true` so the layout is known BEFORE the home screen lands: the landing
      // fills and the cold-launch push replay read `state.layout` at that moment. Attached
      // to `content` (every root branch) rather than the split view for the same reason.
      .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
        store.send(.layoutChanged(sizeClass.appLayout))
      }
  }

  /// Which root branch wins is decided ONCE, by `AppFeature.State.rootScreen` in HermesKit
  /// (where its precedence is unit-tested by `swift test`) — this `switch` only renders the
  /// verdict. Deliberately NOT `if rootScreen == .home, let homeStore = …`: re-deriving the
  /// same optional the resolver already consulted means a disagreement falls silently through
  /// to onboarding, which is the exact failure the enum exists to prevent.
  @ViewBuilder
  private var content: some View {
    switch store.rootScreen {
    case .home:
      if let homeStore = store.scope(state: \.home, action: \.home) {
        // ONE split view for both widths. In compact the split collapses to its sidebar
        // column, so the stack below is the whole screen — the iPhone layout, byte-identical
        // to the pre-#80 root. In regular the sidebar shows the list and the detail column
        // shows the live-chat slot directly: the path holds no marker there
        // (`AppFeature.isChatDetached`), so the chat is never rendered twice.
        NavigationSplitView(columnVisibility: $columnVisibility) {
          NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
            SessionListView(store: homeStore)
          } destination: { _ in
            // The path holds only thin session-key markers — the REAL chat state lives in
            // the app-level live-chat slot, so a running turn's socket survives pops.
            chatDetail
          }
          .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
          chatDetail
        }
        .navigationSplitViewStyle(.automatic)
      }
    case .connecting:
      ProgressView("Connecting…")
    case .connectionFailed:
      // Launch auto-connect failed for a reason that isn't a verdict on the credentials
      // (no network, or a proxy reporting the agent down): the stored credentials are fine,
      // so keep them and offer a retry instead of dropping to onboarding. Auth failures never
      // populate this slot — they land on the onboarding branch below.
      if let failedStore = store.scope(state: \.connectionFailed, action: \.connectionFailed) {
        ConnectionFailedView(store: failedStore)
      }
    case .onboarding:
      NavigationStack {
        ConnectionView(store: store.scope(state: \.onboarding, action: \.onboarding))
          .navigationTitle("Connect to Hermes")
          .navigationBarTitleDisplayMode(.inline)
      }
    }
  }

  /// The live-chat slot's screen, rendered by BOTH columns: the sidebar stack's pushed
  /// destination in compact, the detail column in regular. Defensive empty view if the slot
  /// is missing (e.g. after logout mid-pop; in regular the reducer keeps the slot seated).
  @ViewBuilder
  private var chatDetail: some View {
    if let chatStore = store.scope(state: \.liveChat, action: \.liveChat) {
      ChatView(store: chatStore)
        // The view's disappearance routes through the PARENT (never the scoped child
        // store): `AppFeature.chatViewDisappeared` guards a nil slot (logout/quit may
        // have cleared it while the screen was still animating away) and owns the
        // idle-pop teardown policy — deferred here until the pop animation finished,
        // so the outgoing screen stays rendered and no action hits an absent child.
        // The same event fires when the chat moves between columns on a size-class
        // change; the reducer records the new layout first, so that one is a no-op.
        .onDisappear { store.send(.chatViewDisappeared) }
    }
  }
}

private extension ScenePhase {
  /// Map SwiftUI's `ScenePhase` onto HermesKit's SwiftUI-free `AppFeature.ScenePhase`.
  var appPhase: AppFeature.ScenePhase {
    switch self {
    case .active: return .active
    case .inactive: return .inactive
    case .background: return .background
    @unknown default: return .inactive
    }
  }
}

private extension Optional where Wrapped == UserInterfaceSizeClass {
  /// Map the horizontal size class onto HermesKit's `AppFeature.Layout`. Only `.regular`
  /// is the split layout; `.compact` and an unresolved (`nil`) class both mean the stack —
  /// the reducer's default, so an early `nil` never flips anything.
  var appLayout: AppFeature.Layout {
    self == .regular ? .regular : .compact
  }
}

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
