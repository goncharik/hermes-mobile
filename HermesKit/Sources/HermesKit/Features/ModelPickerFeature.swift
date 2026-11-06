import ComposableArchitecture
import Foundation

/// The model + reasoning-effort picker sheet (#81, redesigned for #130), presented by
/// `ChatFeature` as an `@Presents` / `.ifLet` child (`ChatFeature.State.modelPicker`).
///
/// Owns only what is the sheet's own: the session-scoped `model.options` load (sent with
/// `explicit_only: true` — configured providers only, desktop `model-options.ts` parity; older
/// gateways read the param via `params.get` and ignore it), the inline `config.set` failure
/// text (`applyError`, written by the parent), and the two device-local display prefs —
/// collapsed provider cards and starred models — persisted through `PreferencesClient`.
///
/// Selection is a PARENT concern: it mutates the chat's `model` / `reasoningEffort` /
/// `pendingConfigRollback` and runs `config.set` inside the #17 heal, so row and effort taps
/// are forwarded as `Delegate` actions and the parent's guards (`!isSending`, a live id)
/// decide. The display inputs the parent owns (current model + effort, busy, the max/ultra
/// latch) are handed to the view as plain parameters — one source of truth, no syncing.
@Reducer
public struct ModelPickerFeature {
  @ObservableState
  public struct State: Equatable {
    /// The chat's live session id at open — the `model.options` scope.
    public var sessionID: String
    public var options: ModelOptions?
    /// The `model.options` LOAD failure — the sheet has no list to show at all.
    public var error: String?
    /// The last `config.set` rejection while this sheet was up (`ChatFeature` writes it).
    /// Rendered inline over a still-usable list (the rollback happens in the rows behind it);
    /// cleared by the next selection.
    public var applyError: String?
    /// Provider ids (`ModelOptions.Provider.id`) whose cards are collapsed. Loaded on `.task`.
    public var collapsedProviders: Set<String>
    /// Starred models, star order. Loaded on `.task`.
    public var favorites: [FavoriteModel]
    /// The server-reported `options.currentProvider` captured before the FIRST optimistic
    /// model pick of a run — the rollback target the parent carries through its `config.set`
    /// effect (`ChatFeature.pendingConfigRollback` semantics). Nil = no pick in flight.
    /// Internal bookkeeping.
    var pendingProviderPick: PendingProviderPick?

    public var isLoading: Bool { options == nil && error == nil }

    public init(
      sessionID: String,
      options: ModelOptions? = nil,
      error: String? = nil,
      applyError: String? = nil,
      collapsedProviders: Set<String> = [],
      favorites: [FavoriteModel] = []
    ) {
      self.sessionID = sessionID
      self.options = options
      self.error = error
      self.applyError = applyError
      self.collapsedProviders = collapsedProviders
      self.favorites = favorites
      self.pendingProviderPick = nil
    }

    /// The provider rollback target of an in-flight model pick.
    struct PendingProviderPick: Equatable {
      var rollbackProvider: String?
    }

    /// The chat optimistically switched to a model under `providerSlug`: move the current
    /// provider with it so the layout's `(provider, model)` match follows the pick (else a
    /// cross-provider pick would check no row until the sheet reopens). A nil slug clears it —
    /// the model-only fallback, the same as an older gateway. Returns the provider a rejection
    /// restores (the last server-reported one).
    mutating func applyOptimisticModelPick(providerSlug: String?) -> String? {
      guard options != nil else { return nil }
      if pendingProviderPick == nil {
        pendingProviderPick = PendingProviderPick(rollbackProvider: options?.currentProvider)
      }
      options?.currentProvider = providerSlug
      return pendingProviderPick?.rollbackProvider
    }

    /// The pick was rejected: restore `provider`, the value `applyOptimisticModelPick`
    /// returned (carried through the effect, so an intervening `session.info` can't lose it).
    mutating func rollBackModelPick(to provider: String?) {
      guard options != nil else { return }
      options?.currentProvider = provider
      pendingProviderPick = nil
    }

    /// An authoritative `session.info` / hydrate reported the model: drop the rollback stash
    /// and, when it names the provider (`SessionInfo.provider`), take the server's.
    mutating func confirmModelPick(provider: String?) {
      pendingProviderPick = nil
      if let provider, options != nil { options?.currentProvider = provider }
    }
  }

  public enum Action {
    case delegate(Delegate)
    case doneButtonTapped
    case effortRowTapped(String)
    case modelOptionsResponse(Result<ModelOptions, GatewayError>)
    /// `providerSlug` is the row's `ModelOptions.Provider.selectionSlug` — the `--provider`
    /// value the parent appends to the `config.set` wire value.
    case modelRowTapped(model: String, providerSlug: String?)
    /// Toggles the card's collapse; the argument is the `ModelOptions.Provider.id`.
    case providerHeaderTapped(String)
    case starButtonTapped(FavoriteModel)
    /// The sheet appeared: load the prefs and fetch `model.options` (once per presentation).
    case task

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case modelSelected(model: String, provider: String?)
      case reasoningSelected(String)
    }
  }

  enum CancelID: Hashable {
    case load
  }

  @Dependency(\.dismiss) var dismiss
  @Dependency(\.hermesGateway) var gateway
  @Dependency(\.preferences) var preferences

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .delegate:
        return .none

      case .doneButtonTapped:
        return .run { [dismiss] _ in await dismiss() }

      case let .effortRowTapped(effort):
        return .send(.delegate(.reasoningSelected(effort)))

      case let .modelOptionsResponse(.success(options)):
        state.options = options
        return .none

      case let .modelOptionsResponse(.failure(error)):
        state.error = error.message
        return .none

      case let .modelRowTapped(model, providerSlug):
        return .send(.delegate(.modelSelected(model: model, provider: providerSlug)))

      case let .providerHeaderTapped(providerID):
        // Display-only, so allowed mid-turn too.
        if state.collapsedProviders.contains(providerID) {
          state.collapsedProviders.remove(providerID)
        } else {
          state.collapsedProviders.insert(providerID)
        }
        preferences.saveCollapsedModelProviders(state.collapsedProviders)
        return .none

      case let .starButtonTapped(favorite):
        if let index = state.favorites.firstIndex(of: favorite) {
          state.favorites.remove(at: index)
        } else {
          state.favorites.append(favorite)
        }
        preferences.saveFavoriteModels(state.favorites)
        return .none

      case .task:
        // A re-appearance (the sheet's `.task` can fire again) never refetches a loaded list
        // or discards a shown load failure.
        guard state.options == nil, state.error == nil else { return .none }
        state.collapsedProviders = preferences.loadCollapsedModelProviders()
        state.favorites = preferences.loadFavoriteModels()
        let sessionID = state.sessionID
        return .run { [gateway] send in
          do {
            let result = try await gateway.send("model.options", .object([
              "session_id": .string(sessionID),
              "explicit_only": .bool(true),
            ]))
            if let options = result.decoded(ModelOptions.self) {
              await send(.modelOptionsResponse(.success(options)))
            } else {
              await send(.modelOptionsResponse(.failure(.server("Malformed model.options result"))))
            }
          } catch let error as GatewayError {
            await send(.modelOptionsResponse(.failure(error)))
          } catch {
            await send(.modelOptionsResponse(.failure(.disconnected)))
          }
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)
      }
    }
  }
}
