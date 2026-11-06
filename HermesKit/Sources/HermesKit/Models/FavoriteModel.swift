import Foundation

/// A starred model in the model picker (#130): the provider row it was starred under plus the
/// model id. Mirrors the desktop's `provider::model` favorites key — the same model id offered
/// by two providers is two distinct favorites. `providerID` is the catalog row's
/// `ModelOptions.Provider.id` (its `slug`, else its display name).
/// Persisted device-locally (`PreferencesClient.saveFavoriteModels`), order = star order.
public struct FavoriteModel: Codable, Hashable, Sendable {
  public var providerID: String
  public var model: String

  public init(providerID: String, model: String) {
    self.providerID = providerID
    self.model = model
  }
}
