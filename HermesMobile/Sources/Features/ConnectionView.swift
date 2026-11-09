import ComposableArchitecture
import HermesKit
import SwiftUI

/// Onboarding (#136): the stack host of the three-step first-run flow —
/// **Welcome → Server → Sign in** — over `ConnectionFeature`'s `ConnectionPath` stack.
///
/// Welcome is the root (no reducer of its own); every push and pop is a `ConnectionFeature`
/// state change, so popping Sign in (swipe-back or "Change") cancels that step's effects.
///
/// The "Set Up Your Agent" guide sheet is pure view state (display-only), deliberately kept
/// out of the reducers: one local `@State` flag, opened from Welcome's secondary button, the
/// Server step's "Where do I find the address?" and each failure card's "Setup guide".
struct ConnectionView: View {
  @Bindable var store: StoreOf<ConnectionFeature>
  @State private var showsSetupGuide = false

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      WelcomeView(
        connectButtonTapped: { store.send(.connectButtonTapped) },
        setupGuideButtonTapped: { showsSetupGuide = true }
      )
    } destination: { pathStore in
      switch pathStore.case {
      case let .server(serverStore):
        ServerStepView(store: serverStore, setupGuideButtonTapped: { showsSetupGuide = true })
      case let .signIn(signInStore):
        SignInStepView(store: signInStore)
      }
    }
    // The amber ink, not `hermesAccent` itself: the tint also colours the back button and
    // links, which need text contrast on the grouped background. Applied to the stack only,
    // so the guide sheet below keeps its own styling.
    .tint(.hermesAccentInk)
    .sheet(isPresented: $showsSetupGuide) {
      AgentSetupGuideView()
    }
  }
}

#Preview {
  ConnectionView(
    store: Store(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    }
  )
}
