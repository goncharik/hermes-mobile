import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Chat display prefs (#55) at the reducer level: the toggles persist immediately, are
/// no-ops when the value is unchanged, and the slot seeds them from `PreferencesClient`
/// exactly once — on the first appearance, never on a re-appearance over a live slot.
@MainActor
struct ChatDisplayPrefsReductionTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")

  private func makeStore(
    prefs: PreferencesClient = .inMemory()
  ) -> TestStore<ChatFeature.State, ChatFeature.Action> {
    TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesGateway.connect = { @Sendable _, _ in AsyncStream { _ in } }
    }
  }

  @Test func togglesPersistImmediately() async {
    let prefs = PreferencesClient.inMemory()
    let store = makeStore(prefs: prefs)

    await store.send(.showToolRowsToggled(false)) {
      $0.displayPrefs.showToolRows = false
    }
    await store.send(.showThinkingRowsToggled(false)) {
      $0.displayPrefs.showThinkingRows = false
    }
    await store.send(.autoFollowToggled(false)) {
      $0.displayPrefs.autoFollowEnabled = false
    }

    // Each toggle reached the persistence layer — the pref survives the slot.
    #expect(prefs.loadShowToolRows() == false)
    #expect(prefs.loadShowThinkingRows() == false)
    #expect(prefs.loadAutoFollowEnabled() == false)
  }

  /// Setting a pref to the value it already holds must not emit a state change (the panel's
  /// toggle can re-fire on a re-render) — and must not rewrite the stored value either.
  @Test func redundantToggleIsANoOp() async {
    let store = makeStore()
    let before = store.state.displayPrefs

    await store.send(.autoFollowToggled(true)) // already true
    #expect(store.state.displayPrefs == before)
  }

  @Test func togglesAreIndependentOfEachOther() async {
    let store = makeStore()

    await store.send(.showToolRowsToggled(false)) {
      $0.displayPrefs.showToolRows = false
    }
    // The other two are untouched.
    #expect(store.state.displayPrefs.showThinkingRows == true)
    #expect(store.state.displayPrefs.autoFollowEnabled == true)
  }

  /// The slot seeds from the persistence layer on its first appearance, so a pref set in an
  /// earlier session is honoured on open.
  @Test func firstAppearanceSeedsPrefsFromPersistence() async {
    let prefs = PreferencesClient.inMemory()
    prefs.saveShowToolRows(false)
    prefs.saveShowThinkingRows(false)
    prefs.saveAutoFollowEnabled(false)

    let store = makeStore(prefs: prefs)
    // The default before `.task` is the pre-feature behavior — seeding is what applies the
    // user's actual choice.
    #expect(store.state.displayPrefs == .default)

    await store.send(.task) {
      $0.hasStarted = true
      $0.displayPrefs = ChatDisplayPrefs(
        showToolRows: false, showThinkingRows: false, autoFollowEnabled: false
      )
    }
    // The guard opens the socket effect, which is long-lived by design — this test asserts
    // the SEED, not the connection, so dismiss it (repo convention for `.task` tests).
    await store.skipInFlightEffects()
  }

  /// A re-appearance over a LIVE slot must not reload the prefs: the slot outlives nav pops,
  /// so reloading would fight a toggle the user made while the chat was open.
  @Test func reappearanceDoesNotReseedPrefs() async {
    let prefs = PreferencesClient.inMemory()
    let store = makeStore(prefs: prefs)

    await store.send(.task) {
      $0.hasStarted = true
    }
    // The guard opens the socket effect; this test asserts pref seeding, not the socket.
    await store.skipInFlightEffects()
    // User turns following off inside the chat.
    await store.send(.autoFollowToggled(false)) {
      $0.displayPrefs.autoFollowEnabled = false
    }
    // A stale value lands in the store (as if another surface wrote it).
    prefs.saveAutoFollowEnabled(true)

    // Second `.task` (the view re-appearing) is a guarded no-op: it returns NO effect and
    // changes no state — which is exactly what is asserted here. No drain is needed (and
    // asking to drain would fail: a no-op leaves nothing in flight).
    await store.send(.task)
    #expect(store.state.displayPrefs.autoFollowEnabled == false)
  }

  @Test func reloadActionAppliesAnExplicitPrefsValue() async {
    let store = makeStore()
    await store.send(.displayPrefsReloaded(ChatDisplayPrefs(
      showToolRows: false, showThinkingRows: true, autoFollowEnabled: false
    ))) {
      $0.displayPrefs = ChatDisplayPrefs(
        showToolRows: false, showThinkingRows: true, autoFollowEnabled: false
      )
    }
  }
}