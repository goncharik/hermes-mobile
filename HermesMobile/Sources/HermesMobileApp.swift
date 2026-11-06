import ComposableArchitecture
import HermesKit
import SwiftUI

@main
struct HermesMobileApp: App {
  // Bridges APNs / notification callbacks into `PushClient` streams (#push C2).
  @UIApplicationDelegateAdaptor(PushAppDelegate.self) var pushDelegate

  @MainActor
  static let store: StoreOf<AppFeature> = {
    #if DEBUG
    if DemoMode.isActive { return DemoMode.makeStore() }
    #endif
    return Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  }()

  var body: some Scene {
    WindowGroup {
      AppView(store: HermesMobileApp.store)
        // Widget, Control Center and Live Activity taps arrive as `hermesmobile://` URLs.
        // They only route: the mapped intent goes through the same cold-launch buffer as an
        // App Intent (#93). Anything `WidgetDeepLink` doesn't recognise is ignored.
        .onOpenURL { url in
          LaunchIntentBridge.shared.received(url: url)
        }
    }
  }
}
