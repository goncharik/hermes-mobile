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

  @Test func lostCredentialCurrentProviderIsNonSelectableAndCentered() throws {
    // inventory.py keeps the current provider with its models but authenticated=false.
    let lost = ModelOptions.Provider(
      name: "Anthropic", slug: "anthropic", models: ["opus"], authenticated: false,
      warning: "ANTHROPIC_API_KEY is no longer valid"
    )
    let result = layout(options([lost, openRouter], currentProvider: "anthropic"))
    let section = try #require(providerSection(result, "anthropic"))
    #expect(!section.isSelectable)
    #expect(section.rows.isEmpty)
    #expect(result.sections.map(\.id).last == "header::anthropic")
    #expect(result.scrollTarget == "header::anthropic")
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
    let result = layout(favorites: [.init(providerID: "anthropic", model: "haiku")], query: "   ")
    #expect(result.sections.map(\.id).prefix(2) == ["options", "favorites"])
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

  @Test func olderGatewayWithoutProviderFallsBackToModelOnlyMatch() throws {
    let result = layout(options(currentProvider: nil))
    // Both providers' "opus" rows read as current; the first in display order is centered.
    #expect(try #require(providerSection(result, "anthropic")).rows.first?.isCurrent == true)
    #expect(try #require(providerSection(result, "openrouter")).rows.last?.isCurrent == true)
    #expect(result.scrollTarget == "anthropic::opus")
  }
}
