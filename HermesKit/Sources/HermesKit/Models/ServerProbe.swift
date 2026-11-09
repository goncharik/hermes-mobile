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

/// A failed onboarding Server-step probe (#136): the address the user typed, the candidate
/// URLs the probe walked, and the failure the last of them reported.
public struct FailedServerProbe: Error, Equatable, Sendable {
  public let address: ServerAddress
  /// The last candidate's failure — the one the card reports.
  public let failure: ProbeFailure
  /// The candidates probed, in order: a non-empty prefix of `address.candidates`.
  public let tried: [URL]

  public init(address: ServerAddress, failure: ProbeFailure, tried: [URL]) {
    self.address = address
    self.failure = failure
    self.tried = tried
  }

  /// The candidate whose failure is reported.
  public var reportedURL: URL { tried.last ?? address.url }

  /// The card's "Tried …" detail line: every `/api/status` URL probed, in order.
  public var triedDetail: String {
    "Tried " + tried.map { $0.appending(path: "api/status").absoluteString }.joined(separator: ", then ")
  }
}
