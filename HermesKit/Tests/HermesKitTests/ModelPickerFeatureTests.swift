import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// `ModelPickerFeature` (#130) in isolation: the `model.options` load (scope + `explicit_only`,
/// every outcome), the two persisted display toggles, the delegate forwarding of row and effort
/// taps, and self-dismissal. Selection itself is the parent's — see `ChatInteractionTests`.
@MainActor
struct ModelPickerFeatureTests {
  private let payload: JSONValue = .object([
    "providers": .array([.object([
      "name": .string("Anthropic"), "slug": .string("anthropic"),
      "models": .array([.string("claude-opus-4-8"), .string("claude-sonnet-4-6")]),
      "authenticated": .bool(true),
    ])]),
    "model": .string("claude-opus-4-8"),
    "provider": .string("anthropic"),
  ])

  private var decodedOptions: ModelOptions {
    ModelOptions(
      providers: [.init(name: "Anthropic", slug: "anthropic", models: ["claude-opus-4-8", "claude-sonnet-4-6"], authenticated: true)],
      currentModel: "claude-opus-4-8",
      currentProvider: "anthropic"
    )
  }

  // MARK: - Load

  @Test func taskLoadsPrefsAndFetchesConfiguredOnlyOptions() async {
    let sent = LockIsolated<[(method: String, params: JSONValue)]>([])
    let prefs = PreferencesClient.inMemory()
    prefs.saveCollapsedModelProviders(["openrouter"])
    prefs.saveFavoriteModels([FavoriteModel(providerID: "anthropic", model: "claude-sonnet-4-6")])
    let payload = payload
    let store = TestStore(initialState: ModelPickerFeature.State(sessionID: "live")) {
      ModelPickerFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.hermesGateway.send = { @Sendable method, params in
        sent.withValue { $0.append((method, params)) }
        return payload
      }
    }

    await store.send(.task) {
      $0.collapsedProviders = ["openrouter"]
      $0.favorites = [FavoriteModel(providerID: "anthropic", model: "claude-sonnet-4-6")]
    }
    await store.receive(\.modelOptionsResponse.success) {
      $0.isLoading = false
      $0.options = self.decodedOptions
    }

    #expect(sent.value.map(\.method) == ["model.options"])
    #expect(sent.value.first?.params == .object([
      "session_id": .string("live"),
      "explicit_only": .bool(true),
    ]))
  }

  /// The sheet's `.task` can fire again on a re-appearance: a loaded list is never refetched.
  @Test func taskAfterALoadIsANoOp() async {
    let store = TestStore(
      initialState: ModelPickerFeature.State(sessionID: "live", isLoading: false, options: decodedOptions)
    ) {
      ModelPickerFeature()
    }
    await store.send(.task)
  }

  @Test func malformedResultIsALoadError() async {
    let store = TestStore(initialState: ModelPickerFeature.State(sessionID: "live")) {
      ModelPickerFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in .string("nope") }
    }

    await store.send(.task)
    await store.receive(\.modelOptionsResponse.failure) {
      $0.isLoading = false
      $0.error = GatewayError.server("Malformed model.options result").message
    }
  }

  @Test func gatewayErrorIsALoadError() async {
    let store = TestStore(initialState: ModelPickerFeature.State(sessionID: "live")) {
      ModelPickerFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in throw GatewayError.server("boom") }
    }

    await store.send(.task)
    await store.receive(\.modelOptionsResponse.failure) {
      $0.isLoading = false
      $0.error = "boom"
    }
  }

  private struct UnexpectedFailure: Error {}

  @Test func nonGatewayErrorMapsToDisconnected() async {
    let store = TestStore(initialState: ModelPickerFeature.State(sessionID: "live")) {
      ModelPickerFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.hermesGateway.send = { @Sendable _, _ in throw UnexpectedFailure() }
    }

    await store.send(.task)
    await store.receive(\.modelOptionsResponse.failure) {
      $0.isLoading = false
      $0.error = GatewayError.disconnected.message
    }
  }

  // MARK: - Persisted toggles

  @Test func providerHeaderTogglesCollapseAndPersists() async {
    let prefs = PreferencesClient.inMemory()
    let store = TestStore(
      initialState: ModelPickerFeature.State(sessionID: "live", isLoading: false, options: decodedOptions)
    ) {
      ModelPickerFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    await store.send(.providerHeaderTapped("anthropic")) {
      $0.collapsedProviders = ["anthropic"]
    }
    #expect(prefs.loadCollapsedModelProviders() == ["anthropic"])

    await store.send(.providerHeaderTapped("openrouter")) {
      $0.collapsedProviders = ["anthropic", "openrouter"]
    }
    #expect(prefs.loadCollapsedModelProviders() == ["anthropic", "openrouter"])

    await store.send(.providerHeaderTapped("anthropic")) {
      $0.collapsedProviders = ["openrouter"]
    }
    #expect(prefs.loadCollapsedModelProviders() == ["openrouter"])
  }

  @Test func starAppendsInStarOrderAndUnstarRemovesAndPersists() async {
    let prefs = PreferencesClient.inMemory()
    let sonnet = FavoriteModel(providerID: "anthropic", model: "claude-sonnet-4-6")
    let opus = FavoriteModel(providerID: "anthropic", model: "claude-opus-4-8")
    let routed = FavoriteModel(providerID: "openrouter", model: "claude-opus-4-8")
    let store = TestStore(
      initialState: ModelPickerFeature.State(sessionID: "live", isLoading: false, options: decodedOptions)
    ) {
      ModelPickerFeature()
    } withDependencies: {
      $0.preferences = prefs
    }

    await store.send(.starButtonTapped(sonnet)) { $0.favorites = [sonnet] }
    await store.send(.starButtonTapped(opus)) { $0.favorites = [sonnet, opus] }
    // The same model under another provider is a distinct favorite.
    await store.send(.starButtonTapped(routed)) { $0.favorites = [sonnet, opus, routed] }
    #expect(prefs.loadFavoriteModels() == [sonnet, opus, routed])

    await store.send(.starButtonTapped(opus)) { $0.favorites = [sonnet, routed] }
    #expect(prefs.loadFavoriteModels() == [sonnet, routed])
  }

  // MARK: - Delegates + dismissal

  @Test func rowAndEffortTapsAreForwardedToTheParent() async {
    let store = TestStore(
      initialState: ModelPickerFeature.State(sessionID: "live", isLoading: false, options: decodedOptions)
    ) {
      ModelPickerFeature()
    }

    await store.send(.modelRowTapped(model: "claude-sonnet-4-6", providerSlug: "anthropic"))
    await store.receive(\.delegate, .modelSelected(model: "claude-sonnet-4-6", provider: "anthropic"))

    await store.send(.modelRowTapped(model: "claude-sonnet-4-6", providerSlug: nil))
    await store.receive(\.delegate, .modelSelected(model: "claude-sonnet-4-6", provider: nil))

    await store.send(.effortRowTapped("high"))
    await store.receive(\.delegate, .reasoningSelected("high"))
  }

  @Test func doneDismisses() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(
      initialState: ModelPickerFeature.State(sessionID: "live", isLoading: false, options: decodedOptions)
    ) {
      ModelPickerFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.doneButtonTapped)
    #expect(dismissed.value)
  }

  // MARK: - Optimistic provider bookkeeping (driven by ChatFeature)

  @Test func optimisticPickMovesTheProviderAndRollsBackToTheFirstCapturedValue() {
    var state = ModelPickerFeature.State(sessionID: "live", isLoading: false, options: decodedOptions)

    state.applyOptimisticModelPick(providerSlug: "openrouter")
    #expect(state.options?.currentProvider == "openrouter")
    // A second pick of the run keeps the SERVER's value as the rollback target.
    state.applyOptimisticModelPick(providerSlug: nil)
    #expect(state.options?.currentProvider == nil)

    state.rollBackModelPick()
    #expect(state.options?.currentProvider == "anthropic")
    #expect(state.pendingProviderPick == nil)

    // Confirmed: the picked provider stands and a later rollback has nothing to restore.
    state.applyOptimisticModelPick(providerSlug: "openrouter")
    state.confirmModelPick()
    state.rollBackModelPick()
    #expect(state.options?.currentProvider == "openrouter")
  }

  @Test func optimisticPickBeforeALoadIsIgnored() {
    var state = ModelPickerFeature.State(sessionID: "live")
    state.applyOptimisticModelPick(providerSlug: "openrouter")
    #expect(state.options == nil)
    #expect(state.pendingProviderPick == nil)
  }
}
