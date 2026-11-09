import Foundation

/// A successful onboarding Server-step probe (#136): the address the user typed, the candidate
/// URL that actually answered (it may carry the `:9119` fallback — that URL is what sign-in
/// connects to and what gets saved), and what the server offers for sign-in.
public struct ServerProbe: Equatable, Sendable {
  public let address: ServerAddress
  /// The candidate URL that answered `/api/status`.
  public let baseURL: URL
  public let capability: ServerAuthCapability
  /// `/api/status` `version`, when the server reports one.
  public let version: String?

  public init(
    address: ServerAddress,
    baseURL: URL,
    capability: ServerAuthCapability,
    version: String?
  ) {
    self.address = address
    self.baseURL = baseURL
    self.capability = capability
    self.version = version
  }
}
