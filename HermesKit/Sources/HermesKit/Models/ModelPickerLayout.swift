import Foundation

/// What the model picker sheet renders (#130), derived purely from the `model.options`
/// payload plus the device-local picker prefs. The view only iterates `sections` and scrolls
/// to `scrollTarget` once per presentation; every rule lives here so it stays unit-tested.
///
/// Not searching:
/// - `.options` first, iff the current model supports reasoning (`supportsReasoning`).
/// - `.favorites` next, iff any starred `(provider, model)` resolves to a model a CONFIGURED
///   provider offers. Star order; a stale favorite (provider gone / unconfigured, model
///   retired) yields no row but stays persisted for when it returns — desktop
///   `resolveFavoriteRows`. Rows carry a provider caption iff they span >1 provider.
/// - one `.provider` card per `orderedProviders` entry, favorited models removed from it so
///   no model is listed twice. A configured provider whose every model is favorited drops
///   its card entirely (desktop `groupModels`: `families.length > 0`). A collapsed card keeps
///   its header (count + the current model's name when it lives in the card) and no rows.
///
/// Searching (non-blank query): no options, no favorites, every card expanded, rows from
/// `filteredProviders(matching:)` with favorited models kept in their card (filled star).
///
/// Unconfigured / lost-credential providers (upstream `inventory.py` keeps the CURRENT
/// provider with `authenticated: false` + `warning` + its saved model once its credentials are
/// gone) are a non-selectable card: the view renders their `warning`, then their models (if
/// any) as disabled rows without stars — desktop `pickerProviders` lists the saved model as
/// the checked current row.
public struct ModelPickerLayout: Equatable, Sendable {
  public var sections: [Section]
  /// The id to center on when the sheet opens: the current model's favorite row, else its
  /// row in an expanded card, else its collapsed card's header (or a lost-credential current
  /// provider's header). Nil while searching or when the current model isn't listed.
  public var scrollTarget: String?
  /// The query is non-blank — the sheet's no-matches overlay keys on this with empty `sections`.
  public var isSearching: Bool

  public enum Section: Equatable, Sendable, Identifiable {
    case options
    case favorites([Row])
    case provider(ProviderSection)

    public var id: String {
      switch self {
      case .options: "options"
      case .favorites: "favorites"
      case let .provider(section): section.headerID
      }
    }
  }

  public struct ProviderSection: Equatable, Sendable {
    public var provider: ModelOptions.Provider
    public var isCollapsed: Bool
    /// False while searching (every card is forced open): the header is not a toggle then.
    public var isCollapsible: Bool
    /// The rows to render: empty when collapsed or for a provider with no models.
    public var rows: [Row]
    /// How many models the card holds, collapsed or not (favorited ones excluded).
    public var modelCount: Int
    /// The current model's name when it lives in this card AND the card is collapsed — the
    /// header shows it so a collapsed card never hides where the selection is.
    public var currentModelName: String?

    public var headerID: String { ModelPickerLayout.headerID(providerID: provider.id) }
    /// Configured providers list selectable rows; the rest render their `warning` above
    /// disabled rows.
    public var isSelectable: Bool { provider.isConfigured }

    init(
      provider: ModelOptions.Provider, isCollapsed: Bool, isCollapsible: Bool, rows: [Row],
      modelCount: Int, currentModelName: String? = nil
    ) {
      self.provider = provider
      self.isCollapsed = isCollapsed
      self.isCollapsible = isCollapsible
      self.rows = rows
      self.modelCount = modelCount
      self.currentModelName = currentModelName
    }
  }

  public struct Row: Equatable, Sendable, Identifiable {
    /// `fav::<providerID>::<model>` in Favorites, `<providerID>::<model>` in a provider card.
    public var id: String
    public var model: String
    /// `ModelOptions.Provider.id` — the `FavoriteModel.providerID` a star toggles.
    public var providerID: String
    /// `Provider.selectionSlug` — the `--provider` value a tap applies with.
    public var providerSlug: String?
    public var providerName: String
    public var isFavorite: Bool
    public var isCurrent: Bool
    /// Favorites rows only: name the provider under the model when favorites span providers.
    public var showsProviderCaption: Bool
    /// False for a non-configured card's row (the lost-credential saved model): disabled, no star.
    public var isSelectable: Bool

    public var favorite: FavoriteModel { FavoriteModel(providerID: providerID, model: model) }

    init(
      id: String, model: String, providerID: String, providerSlug: String?, providerName: String,
      isFavorite: Bool, isCurrent: Bool, showsProviderCaption: Bool = false, isSelectable: Bool = true
    ) {
      self.id = id
      self.model = model
      self.providerID = providerID
      self.providerSlug = providerSlug
      self.providerName = providerName
      self.isFavorite = isFavorite
      self.isCurrent = isCurrent
      self.showsProviderCaption = showsProviderCaption
      self.isSelectable = isSelectable
    }
  }

  private static func headerID(providerID: String) -> String { "header::\(providerID)" }
  private static func rowID(providerID: String, model: String) -> String { "\(providerID)::\(model)" }
  private static func favoriteRowID(providerID: String, model: String) -> String {
    "fav::\(providerID)::\(model)"
  }

  /// - Parameters:
  ///   - currentModel: the chat's model (its optimistic pick is the display truth); the
  ///     provider half of the current-row match is `options.currentProvider`.
  ///   - collapsedProviders: `Provider.id`s; ids naming no listed provider are ignored.
  public init(
    options: ModelOptions,
    favorites: [FavoriteModel],
    collapsedProviders: Set<String>,
    query: String,
    currentModel: String?
  ) {
    let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    func row(_ model: String, _ provider: ModelOptions.Provider, isFavorite: Bool, inFavorites: Bool) -> Row {
      Row(
        id: inFavorites
          ? Self.favoriteRowID(providerID: provider.id, model: model)
          : Self.rowID(providerID: provider.id, model: model),
        model: model,
        providerID: provider.id,
        providerSlug: provider.selectionSlug,
        providerName: provider.name,
        isFavorite: isFavorite,
        isCurrent: options.isCurrent(model: model, in: provider, currentModel: currentModel),
        isSelectable: provider.isConfigured
      )
    }

    var sections: [Section] = []
    var favoriteRows: [Row] = []
    if !isSearching {
      if options.supportsReasoning(currentModel) { sections.append(.options) }
      favoriteRows = Self.resolveFavorites(favorites, in: options.orderedProviders).map {
        row($0.model, $0.provider, isFavorite: true, inFavorites: true)
      }
      if Set(favoriteRows.map(\.providerID)).count > 1 {
        for index in favoriteRows.indices { favoriteRows[index].showsProviderCaption = true }
      }
      if !favoriteRows.isEmpty { sections.append(.favorites(favoriteRows)) }
    }

    let favoriteSet = Set(favorites)
    var providerSections: [ProviderSection] = []
    for provider in options.filteredProviders(matching: query) {
      let isCollapsed = !isSearching && collapsedProviders.contains(provider.id)
      var seen = Set<String>()
      let cardRows = provider.models.compactMap { model -> Row? in
        guard seen.insert(model).inserted else { return nil }
        // Favorites resolve against configured providers only, so a non-configured card keeps
        // every model and shows no star.
        let isFavorite = provider.isConfigured
          && favoriteSet.contains(FavoriteModel(providerID: provider.id, model: model))
        // Favorites already render above (not while searching): never list a model twice.
        if isFavorite && !isSearching { return nil }
        return row(model, provider, isFavorite: isFavorite, inFavorites: false)
      }
      // A non-configured card always shows (its warning is the point).
      guard !cardRows.isEmpty || !provider.isConfigured else { continue }
      providerSections.append(.init(
        provider: provider,
        isCollapsed: isCollapsed,
        isCollapsible: !isSearching,
        rows: isCollapsed ? [] : cardRows,
        modelCount: cardRows.count,
        currentModelName: isCollapsed ? cardRows.first(where: \.isCurrent)?.model : nil
      ))
    }
    sections += providerSections.map(Section.provider)

    self.sections = sections
    self.isSearching = isSearching
    self.scrollTarget = isSearching ? nil : Self.scrollTarget(
      favoriteRows: favoriteRows, providerSections: providerSections,
      currentProvider: options.currentProvider
    )
  }

  /// Starred `(provider, model)` pairs a configured provider still offers, in star order,
  /// duplicates dropped. Stale ones are skipped, never deleted (the caller keeps the prefs).
  private static func resolveFavorites(
    _ favorites: [FavoriteModel], in providers: [ModelOptions.Provider]
  ) -> [(model: String, provider: ModelOptions.Provider)] {
    var seen = Set<FavoriteModel>()
    return favorites.compactMap { favorite in
      guard seen.insert(favorite).inserted,
            let provider = providers.first(where: {
              $0.isConfigured && $0.id == favorite.providerID && $0.models.contains(favorite.model)
            })
      else { return nil }
      return (favorite.model, provider)
    }
  }

  private static func scrollTarget(
    favoriteRows: [Row], providerSections: [ProviderSection], currentProvider: String?
  ) -> String? {
    if let favorite = favoriteRows.first(where: \.isCurrent) { return favorite.id }
    if let current = providerSections.lazy.flatMap(\.rows).first(where: \.isCurrent) {
      return current.id
    }
    if let collapsed = providerSections.first(where: { $0.currentModelName != nil }) {
      return collapsed.headerID
    }
    // A lost-credential current provider without models: center its header (and its warning
    // row, when expanded) so the reason is visible.
    if let currentProvider,
       let lost = providerSections.first(where: {
         !$0.isSelectable && $0.provider.matches(providerID: currentProvider)
       }) {
      return lost.headerID
    }
    return nil
  }
}
