import CustomDump
import Foundation
import Testing

@testable import HermesKit

struct ModelPickerLayoutTests {
  // MARK: Fixtures

  private let anthropic = ModelOptions.Provider(
    name: "Anthropic", slug: "anthropic", models: ["opus", "haiku"], authenticated: true,
    capabilities: ["opus": .init(reasoning: true), "haiku": .init(reasoning: false)]
  )
  private let openRouter = ModelOptions.Provider(
    name: "OpenRouter", slug: "openrouter", models: ["openai/gpt-5.6", "deepseek/v4", "opus"],
    authenticated: true
  )
  private let openAI = ModelOptions.Provider(
    name: "OpenAI", slug: "openai", models: [], authenticated: false,
    warning: "paste OPENAI_API_KEY to activate"
  )

  private func options(
    _ providers: [ModelOptions.Provider]? = nil, currentProvider: String? = "anthropic"
  ) -> ModelOptions {
    ModelOptions(
      providers: providers ?? [openAI, anthropic, openRouter],
      currentModel: "opus", currentProvider: currentProvider
    )
  }

  private func layout(
    _ options: ModelOptions? = nil,
    favorites: [FavoriteModel] = [],
    collapsed: Set<String> = [],
    query: String = "",
    currentModel: String? = "opus"
  ) -> ModelPickerLayout {
    ModelPickerLayout(
      options: options ?? self.options(), favorites: favorites, collapsedProviders: collapsed,
      query: query, currentModel: currentModel
    )
  }

  private func providerSection(_ layout: ModelPickerLayout, _ id: String) -> ModelPickerLayout.ProviderSection? {
    for case let .provider(section) in layout.sections where section.provider.id == id { return section }
    return nil
  }

  private func favoriteRows(_ layout: ModelPickerLayout) -> [ModelPickerLayout.Row] {
    for case let .favorites(rows) in layout.sections { return rows }
    return []
  }

  // MARK: Sections

  @Test func sectionOrderIsOptionsFavoritesThenProvidersConfiguredFirst() {
    let result = layout(favorites: [.init(providerID: "openrouter", model: "deepseek/v4")])
    expectNoDifference(
      result.sections.map(\.id),
      ["options", "favorites", "header::anthropic", "header::openrouter", "header::openai"]
    )
  }

  @Test func providerCardRowsCarryIdsSlugsAndCurrentFlag() throws {
    let result = layout()
    let section = try #require(providerSection(result, "anthropic"))
    expectNoDifference(section.rows, [
      .init(id: "anthropic::opus", model: "opus", providerID: "anthropic", providerSlug: "anthropic",
            providerName: "Anthropic", isFavorite: false, isCurrent: true),
      .init(id: "anthropic::haiku", model: "haiku", providerID: "anthropic", providerSlug: "anthropic",
            providerName: "Anthropic", isFavorite: false, isCurrent: false),
    ])
    #expect(section.modelCount == 2)
    #expect(section.isCollapsed == false)
    #expect(section.currentModelName == nil)
    #expect(section.isSelectable)
    #expect(section.rows.map(\.isSelectable) == [true, true])
    // The same model id under OpenRouter is NOT current — the payload's provider is anthropic.
    let openRouterSection = try #require(providerSection(result, "openrouter"))
    #expect(openRouterSection.rows.first(where: { $0.model == "opus" })?.isCurrent == false)
  }

  @Test func optionsHiddenWhenCurrentModelDoesNotReason() {
    let result = layout(currentModel: "haiku")
    #expect(!result.sections.map(\.id).contains("options"))
    // Unknown capability defaults to reasoning-capable (`?? true`).
    #expect(layout(currentModel: "deepseek/v4").sections.first?.id == "options")
  }

  @Test func noFavoritesSectionWithoutFavorites() {
    #expect(!layout().sections.map(\.id).contains("favorites"))
  }

  // MARK: Favorites

  @Test func favoritesKeepStarOrderAndLeaveTheirProviderCard() throws {
    let result = layout(favorites: [
      .init(providerID: "anthropic", model: "haiku"),
      .init(providerID: "anthropic", model: "opus"),
    ])
    expectNoDifference(favoriteRows(result), [
      .init(id: "fav::anthropic::haiku", model: "haiku", providerID: "anthropic", providerSlug: "anthropic",
            providerName: "Anthropic", isFavorite: true, isCurrent: false),
      .init(id: "fav::anthropic::opus", model: "opus", providerID: "anthropic", providerSlug: "anthropic",
            providerName: "Anthropic", isFavorite: true, isCurrent: true),
    ])
    // Every Anthropic model is favorited → its card is dropped (desktop `groupModels` parity).
    #expect(providerSection(result, "anthropic") == nil)
    // OpenRouter's "opus" is a different favorite key and stays in its card.
    #expect(try #require(providerSection(result, "openrouter")).rows.map(\.model).contains("opus"))
  }

  @Test func favoritedModelRemovedFromItsCardOnly() throws {
    let result = layout(favorites: [.init(providerID: "openrouter", model: "deepseek/v4")])
    let section = try #require(providerSection(result, "openrouter"))
    #expect(section.rows.map(\.model) == ["openai/gpt-5.6", "opus"])
    #expect(section.modelCount == 2)
    #expect(try #require(providerSection(result, "anthropic")).rows.count == 2)
  }

  @Test func staleAndDuplicateFavoritesAreSkipped() {
    let result = layout(favorites: [
      .init(providerID: "gone", model: "opus"), // provider not offered
      .init(providerID: "anthropic", model: "retired"), // model retired
      .init(providerID: "openai", model: "gpt-5.6"), // provider unconfigured
      .init(providerID: "anthropic", model: "haiku"),
      .init(providerID: "anthropic", model: "haiku"), // duplicate
    ])
    #expect(favoriteRows(result).map(\.id) == ["fav::anthropic::haiku"])
  }

  @Test func onlyStaleFavoritesYieldNoFavoritesSection() {
    let result = layout(favorites: [.init(providerID: "gone", model: "opus")])
    #expect(!result.sections.map(\.id).contains("favorites"))
  }

  @Test func providerCaptionOnlyWhenFavoritesSpanProviders() {
    let single = layout(favorites: [
      .init(providerID: "anthropic", model: "haiku"),
      .init(providerID: "anthropic", model: "opus"),
    ])
    #expect(favoriteRows(single).map(\.showsProviderCaption) == [false, false])

    let mixed = layout(favorites: [
      .init(providerID: "openrouter", model: "deepseek/v4"),
      .init(providerID: "anthropic", model: "haiku"),
    ])
    #expect(favoriteRows(mixed).map(\.showsProviderCaption) == [true, true])
    #expect(favoriteRows(mixed).map(\.providerName) == ["OpenRouter", "Anthropic"])
  }

  // MARK: Collapse

  @Test func collapsedProviderKeepsHeaderCountAndCurrentModelName() throws {
    let result = layout(collapsed: ["anthropic"])
    let section = try #require(providerSection(result, "anthropic"))
    #expect(section.isCollapsed)
    #expect(section.rows.isEmpty)
    #expect(section.modelCount == 2)
    #expect(section.currentModelName == "opus")
    // A collapsed card without the current model names none.
    let other = try #require(providerSection(layout(collapsed: ["openrouter"]), "openrouter"))
    #expect(other.isCollapsed)
    #expect(other.currentModelName == nil)
    #expect(other.modelCount == 3)
  }

  @Test func collapsedCardDoesNotClaimAFavoritedCurrentModel() throws {
    let result = layout(favorites: [.init(providerID: "anthropic", model: "opus")], collapsed: ["anthropic"])
    let section = try #require(providerSection(result, "anthropic"))
    #expect(section.modelCount == 1)
    #expect(section.currentModelName == nil)
  }

  @Test func staleCollapsedIdsAreIgnored() {
    let result = layout(collapsed: ["gone", "header::anthropic"])
    let collapsedFlags = result.sections.compactMap { section -> Bool? in
      guard case let .provider(provider) = section else { return nil }
      return provider.isCollapsed
    }
    #expect(collapsedFlags == [false, false, false])
  }

  // MARK: Unconfigured / lost credentials

  @Test func unconfiguredProviderIsANonSelectableCardWithNoRows() throws {
    let section = try #require(providerSection(layout(), "openai"))
    #expect(!section.isSelectable)
    #expect(section.rows.isEmpty)
    #expect(section.modelCount == 0)
    #expect(section.provider.warning == "paste OPENAI_API_KEY to activate")
  }

  /// inventory.py `_append_unconfigured_rows(current_only=True)` keeps the current provider with
  /// its saved model, `authenticated: false` + a warning: the card lists that model as the
  /// (non-selectable, star-less) checked row — desktop `pickerProviders` parity.
  @Test func lostCredentialCurrentProviderListsItsSavedModelAsTheCenteredCurrentRow() throws {
    let lost = ModelOptions.Provider(
      name: "Anthropic", slug: "anthropic", models: ["opus"], authenticated: false,
      warning: "ANTHROPIC_API_KEY is no longer valid"
    )
    // Even a stale favorite naming it doesn't pull the row out of its card.
    let result = layout(
      options([lost, openRouter], currentProvider: "anthropic"),
      favorites: [.init(providerID: "anthropic", model: "opus")]
    )
    let section = try #require(providerSection(result, "anthropic"))
    #expect(!section.isSelectable)
    expectNoDifference(section.rows, [
      .init(id: "anthropic::opus", model: "opus", providerID: "anthropic", providerSlug: "anthropic",
            providerName: "Anthropic", isFavorite: false, isCurrent: true, isSelectable: false),
    ])
    #expect(section.modelCount == 1)
    #expect(result.sections.map(\.id).last == "header::anthropic")
    #expect(!result.sections.map(\.id).contains("favorites"))
    #expect(result.scrollTarget == "anthropic::opus")

    let collapsed = layout(options([lost, openRouter], currentProvider: "anthropic"), collapsed: ["anthropic"])
    let collapsedSection = try #require(providerSection(collapsed, "anthropic"))
    #expect(collapsedSection.rows.isEmpty)
    #expect(collapsedSection.modelCount == 1)
    #expect(collapsedSection.currentModelName == "opus")
    #expect(collapsed.scrollTarget == "header::anthropic")
  }

  /// A lost-credential current provider reported without models still centers its header.
  @Test func lostCredentialCurrentProviderWithoutModelsCentersItsHeader() {
    let lost = ModelOptions.Provider(
      name: "Anthropic", slug: "anthropic", models: [], authenticated: false,
      warning: "ANTHROPIC_API_KEY is no longer valid"
    )
    #expect(layout(options([lost, openRouter], currentProvider: "anthropic")).scrollTarget == "header::anthropic")
  }

  // MARK: Duplicates

  @Test func repeatedModelIdsInAProviderAreListedOnce() throws {
    let doubled = ModelOptions.Provider(
      name: "Anthropic", slug: "anthropic", models: ["opus", "opus", "haiku"], authenticated: true
    )
    let expanded = try #require(providerSection(layout(options([doubled])), "anthropic"))
    #expect(expanded.rows.map(\.id) == ["anthropic::opus", "anthropic::haiku"])
    #expect(expanded.modelCount == 2)

    let collapsed = try #require(providerSection(layout(options([doubled]), collapsed: ["anthropic"]), "anthropic"))
    #expect(collapsed.rows.isEmpty)
    #expect(collapsed.modelCount == 2)
    #expect(collapsed.currentModelName == "opus")
  }

  // MARK: Search

  @Test func searchDropsOptionsAndFavoritesExpandsAllAndKeepsStarsInPlace() throws {
    let result = layout(
      favorites: [.init(providerID: "anthropic", model: "opus")],
      collapsed: ["anthropic", "openrouter"],
      query: "opus"
    )
    expectNoDifference(result.sections.map(\.id), ["header::anthropic", "header::openrouter"])
    let anthropicSection = try #require(providerSection(result, "anthropic"))
    #expect(!anthropicSection.isCollapsed)
    // The header is no toggle while searching: a tap would flip a pref the user can't see.
    #expect(!anthropicSection.isCollapsible)
    #expect(anthropicSection.currentModelName == nil)
    expectNoDifference(anthropicSection.rows, [
      .init(id: "anthropic::opus", model: "opus", providerID: "anthropic", providerSlug: "anthropic",
            providerName: "Anthropic", isFavorite: true, isCurrent: true),
    ])
    let openRouterSection = try #require(providerSection(result, "openrouter"))
    #expect(!openRouterSection.isCollapsed)
    #expect(openRouterSection.rows.map(\.model) == ["opus"])
    #expect(openRouterSection.rows.map(\.isFavorite) == [false])
    #expect(result.scrollTarget == nil)
  }

  @Test func whitespaceQueryIsNotSearching() {
    let result = layout(favorites: [.init(providerID: "anthropic", model: "haiku")], query: " \n ")
    #expect(!result.isSearching)
    #expect(result.sections.map(\.id).prefix(2) == ["options", "favorites"])
    #expect(providerSection(result, "anthropic")?.isCollapsible == true)
  }

  @Test func searchWithNoMatchesYieldsNothing() {
    let result = layout(favorites: [.init(providerID: "anthropic", model: "haiku")], query: "zzz")
    #expect(result.sections.isEmpty)
    #expect(result.isSearching) // the sheet's no-matches overlay
    #expect(result.scrollTarget == nil)
  }

  @Test func searchMatchingProviderNameKeepsItsModels() throws {
    let result = layout(query: "router")
    expectNoDifference(result.sections.map(\.id), ["header::openrouter"])
    #expect(try #require(providerSection(result, "openrouter")).rows.count == 3)
  }

  // MARK: Scroll target

  @Test func scrollTargetPrefersTheFavoriteRow() {
    let result = layout(favorites: [.init(providerID: "anthropic", model: "opus")])
    #expect(result.scrollTarget == "fav::anthropic::opus")
  }

  @Test func scrollTargetIsTheRowInAnExpandedCard() {
    #expect(layout().scrollTarget == "anthropic::opus")
    #expect(layout(options(currentProvider: "openrouter")).scrollTarget == "openrouter::opus")
  }

  @Test func scrollTargetIsTheHeaderOfACollapsedCard() {
    #expect(layout(collapsed: ["anthropic"]).scrollTarget == "header::anthropic")
  }

  @Test func scrollTargetIsNilWhenCurrentIsNotListed() {
    #expect(layout(currentModel: "mystery").scrollTarget == nil)
    #expect(layout(currentModel: nil).scrollTarget == nil)
    // A current provider naming no row marks nothing current.
    #expect(layout(options(currentProvider: "elsewhere")).scrollTarget == nil)
  }

  /// The chat's model isn't offered by any configured provider (retired, or set outside the
  /// picker): the sheet still lists every card with nothing checked, and the Options card
  /// stays (unknown capability → reasoning-capable).
  @Test func currentModelMissingListsEverythingWithNothingChecked() throws {
    let result = layout(
      favorites: [.init(providerID: "anthropic", model: "haiku")],
      collapsed: ["openrouter"],
      currentModel: "mystery"
    )
    expectNoDifference(
      result.sections.map(\.id),
      ["options", "favorites", "header::anthropic", "header::openrouter", "header::openai"]
    )
    #expect(favoriteRows(result).map(\.isCurrent) == [false])
    #expect(try #require(providerSection(result, "anthropic")).rows.map(\.isCurrent) == [false])
    #expect(try #require(providerSection(result, "openrouter")).currentModelName == nil)
    #expect(result.scrollTarget == nil)
  }

  @Test func olderGatewayWithoutProviderFallsBackToModelOnlyMatch() throws {
    let result = layout(options(currentProvider: nil))
    // Both providers' "opus" rows read as current; the first in display order is centered.
    #expect(try #require(providerSection(result, "anthropic")).rows.first?.isCurrent == true)
    #expect(try #require(providerSection(result, "openrouter")).rows.last?.isCurrent == true)
    #expect(result.scrollTarget == "anthropic::opus")
  }
}
