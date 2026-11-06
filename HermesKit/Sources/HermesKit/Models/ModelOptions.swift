import Foundation

/// Result of the `model.options` gateway call — the available providers/models plus the
/// currently-selected model. Decoded leniently (the live payload carries far more).
public struct ModelOptions: Equatable, Sendable, Decodable {
  public var providers: [Provider]
  /// Currently-selected model id.
  public var currentModel: String?
  /// The provider the current model runs on: the payload's top-level `provider`, which
  /// upstream `hermes_cli/inventory.py::build_models_payload` fills with
  /// `ctx.current_provider` — a provider ID (`coerce_provider_id(model.provider)`, overlaid
  /// with the live agent's provider by `model.options`), i.e. a row's `slug`, never its
  /// display name. Custom providers are the exception: it reads the canonical
  /// `custom:<key>` while the row's `slug` is the bare key, so rows carry `aliases`
  /// (see `Provider.matches(providerID:)`). Decoded leniently; blank → nil. Absent on
  /// older gateways, where `isCurrent(model:in:currentModel:)` falls back to model-only.
  public var currentProvider: String?

  enum CodingKeys: String, CodingKey {
    case providers
    case currentModel = "model"
    case currentProvider = "provider"
  }

  public init(providers: [Provider] = [], currentModel: String? = nil, currentProvider: String? = nil) {
    self.providers = providers
    self.currentModel = currentModel
    self.currentProvider = currentProvider
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    providers = (try? c.decode([Provider].self, forKey: .providers)) ?? []
    currentModel = try c.decodeIfPresent(String.self, forKey: .currentModel)
    currentProvider = ((try? c.decodeIfPresent(String.self, forKey: .currentProvider)) ?? nil)?
      .trimmedNonEmpty
  }

  /// Whether `model` listed under `provider` is the current selection. With a
  /// `currentProvider` the match is on `(provider, model)` — desktop parity
  /// (`model-catalog-menu.tsx` `rowIsCurrent`: `catalogProviderMatches && model ==`), so the
  /// same model id offered by two providers (e.g. `openai/gpt-5.6` direct and via
  /// OpenRouter) checks only the active one. Without it (an older gateway) the match is on
  /// the model name alone, the pre-#130 behaviour. `currentModel` is a parameter, not
  /// `self.currentModel`, because the chat's optimistic pick is the display truth.
  public func isCurrent(model: String, in provider: Provider, currentModel: String?) -> Bool {
    guard let currentModel, model == currentModel else { return false }
    guard let currentProvider else { return true }
    return provider.matches(providerID: currentProvider)
  }

  public struct Provider: Equatable, Sendable, Decodable, Identifiable {
    public var name: String
    public var slug: String?
    public var models: [String]
    public var authenticated: Bool?
    /// Hint for unconfigured providers, e.g. "paste ANTHROPIC_API_KEY to activate".
    public var warning: String?
    /// Per-model capabilities (`{model: {fast, reasoning}}`). Used to gate the reasoning
    /// control — a model that doesn't support reasoning hides the effort picker.
    public var capabilities: [String: Capability]
    /// Every accepted spelling of a user-defined provider's ID (upstream
    /// `inventory.py::_apply_custom_aliases`, #87035) — `model.options` reports the current
    /// provider as `custom:<key>` while the row's `slug` is the bare key. Empty elsewhere.
    public var aliases: [String]

    public var id: String { slug ?? name }

    /// Whether `providerID` (the payload's top-level `provider`) names this row: its slug,
    /// display name, or one of its aliases — desktop `catalogProviderMatches` verbatim.
    public func matches(providerID: String) -> Bool {
      guard !providerID.isEmpty else { return false }
      return slug == providerID || name == providerID || aliases.contains(providerID)
    }

    /// The identifier to send as `--provider` on a model switch. The SLUG only — desktop
    /// parity (`use-model-controls.ts` sends `provider.slug`, no fallback). The gateway's
    /// `parse_model_flags_detailed` splits the value on whitespace and
    /// `resolve_provider_full` never matches display names, so a name fallback (e.g.
    /// "Ollama Cloud") would parse as provider `Ollama`, model `… Cloud` — worse than a
    /// bare id. Nil (no slug) sends the model out bare and the gateway's own detection
    /// ladder routes it; today every gateway row builder passes a slug, so nil is rare.
    public var selectionSlug: String? {
      let slugValue = (slug ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return slugValue.isEmpty ? nil : slugValue
    }

    /// Configured + usable: authenticated with at least one model. Unconfigured providers
    /// come back authenticated=false with an empty model list and a `warning`.
    public var isConfigured: Bool { (authenticated ?? false) && !models.isEmpty }

    enum CodingKeys: String, CodingKey {
      case name, slug, models, authenticated, warning, capabilities, aliases
    }

    public init(
      name: String, slug: String? = nil, models: [String] = [],
      authenticated: Bool? = nil, warning: String? = nil, capabilities: [String: Capability] = [:],
      aliases: [String] = []
    ) {
      self.name = name
      self.slug = slug
      self.models = models
      self.authenticated = authenticated
      self.warning = warning
      self.capabilities = capabilities
      self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      name = (try? c.decode(String.self, forKey: .name)) ?? ""
      slug = try c.decodeIfPresent(String.self, forKey: .slug)
      models = (try? c.decode([String].self, forKey: .models)) ?? []
      authenticated = try c.decodeIfPresent(Bool.self, forKey: .authenticated)
      warning = try c.decodeIfPresent(String.self, forKey: .warning)
      capabilities = (try? c.decode([String: Capability].self, forKey: .capabilities)) ?? [:]
      aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
    }
  }

  public struct Capability: Equatable, Sendable, Decodable {
    public var reasoning: Bool?
    public var fast: Bool?

    public init(reasoning: Bool? = nil, fast: Bool? = nil) {
      self.reasoning = reasoning
      self.fast = fast
    }
  }

  /// Providers ordered for the picker: configured (selectable) first in server order,
  /// then unconfigured ones (shown disabled, with a configure hint). Providers that are
  /// neither configured nor offer a hint are dropped.
  public var orderedProviders: [Provider] {
    let configured = providers.filter(\.isConfigured)
    let unconfigured = providers.filter { !$0.isConfigured && ($0.warning?.isEmpty == false) }
    return configured + unconfigured
  }

  /// Filters `orderedProviders` against a free-text query while preserving the picker's
  /// provider grouping. A provider whose NAME matches the query keeps all of its models;
  /// otherwise only models whose name matches are kept, and a provider left with no
  /// matching models is dropped. An empty or whitespace-only query returns the full
  /// ordered list unchanged. Matching is a case- and diacritic-insensitive substring
  /// (`"dee"` matches `deepseek-…`, `"cafe"` matches `café-…`).
  public func filteredProviders(matching query: String) -> [Provider] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return orderedProviders }
    let needle = ModelOptions.normalizedForSearch(trimmed)

    return orderedProviders.compactMap { provider in
      if ModelOptions.normalizedForSearch(provider.name).contains(needle) {
        return provider
      }
      let matchingModels = provider.models.filter {
        ModelOptions.normalizedForSearch($0).contains(needle)
      }
      guard !matchingModels.isEmpty else { return nil }
      return Provider(
        name: provider.name,
        slug: provider.slug,
        models: matchingModels,
        authenticated: provider.authenticated,
        warning: provider.warning,
        capabilities: provider.capabilities,
        aliases: provider.aliases
      )
    }
  }

  /// Case- and diacritic-insensitive form used for search comparison.
  private static func normalizedForSearch(_ string: String) -> String {
    string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  /// Whether `model` supports reasoning, per the provider capabilities map. Defaults to
  /// `true` when the model isn't found or has no capability entry (matches the desktop's
  /// `caps?.reasoning ?? true`), so the effort control isn't hidden on unknown models.
  public func supportsReasoning(_ model: String?) -> Bool {
    guard let model else { return true }
    for provider in providers {
      if let capability = provider.capabilities[model] {
        return capability.reasoning ?? true
      }
    }
    return true
  }

  /// Valid reasoning-effort levels: `hermes_constants.VALID_REASONING_EFFORTS` verbatim,
  /// with "none" first (`parse_reasoning_effort` accepts it too). `max`/`ultra` were added
  /// upstream on 2026-07-12 (#62650). Sent via `config.set {key:"reasoning", value}`.
  ///
  /// The client offers the FULL scale on every model and never filters by model: the
  /// transports clamp per provider on the wire (gpt-5.6 maps `ultra`→`max`, xAI tops out
  /// at `high`, OpenAI-compatible tops out at `max`), and `hermes_cli/inventory.py`
  /// `_apply_capabilities` deliberately does not forward per-model `supported_efforts`
  /// (it under-reports), so there is no server-published list to filter against.
  public static let reasoningEfforts = [
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
  ]

  /// Levels a pre-#62650 gateway rejects with server error 4002
  /// ("unknown reasoning value: <v>"); one such verdict latches them out of the picker
  /// for that chat slot. See `GatewayError.isUnknownReasoningValue`.
  public static let extendedReasoningEfforts: Set<String> = ["max", "ultra"]

  /// The levels the picker should offer: the full ladder, or — once an agent has rejected
  /// an extended level — the ladder minus `max`/`ultra`. Order is preserved either way.
  public static func offeredEfforts(extendedSupported: Bool) -> [String] {
    guard !extendedSupported else { return reasoningEfforts }
    return reasoningEfforts.filter { !extendedReasoningEfforts.contains($0) }
  }
}
