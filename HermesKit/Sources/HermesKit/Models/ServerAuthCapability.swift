import Foundation

/// One auth provider advertised by `GET /api/auth/providers`
/// (`[{name, display_name, supports_password}]`). `name` is the wire identifier passed to
/// `POST /auth/password-login` (usually `"basic"`) or to `/auth/native/authorize`;
/// `displayName` is for the UI.
public struct AuthProvider: Equatable, Sendable, Decodable {
  public var name: String
  public var displayName: String
  public var supportsPassword: Bool

  public init(name: String, displayName: String, supportsPassword: Bool) {
    self.name = name
    self.displayName = displayName
    self.supportsPassword = supportsPassword
  }

  enum CodingKeys: String, CodingKey {
    case name
    case displayName = "display_name"
    case supportsPassword = "supports_password"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    // Lenient: fall back to the wire name when the server omits a display name.
    displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? name
    supportsPassword = try c.decodeIfPresent(Bool.self, forKey: .supportsPassword) ?? false
  }
}

/// What auth UI the onboarding screen should offer for a given server. Derived purely from
/// the capability probe (`/api/status` + `/api/auth/providers`) so it stays unit-testable
/// and free of regime checks scattered across the reducer.
///
/// The three regimes it describes:
/// - **token only** — old/loopback servers (`auth_required` absent/`false`) or a gated
///   server that advertises no providers at all: only the static-token path is offered.
///   That's `.tokenOnly` — `isGated == false`, both provider lists empty.
/// - **password** — a gated server with a password-capable provider (`passwordProvider`).
///   Preferred segment whenever it exists.
/// - **OAuth** — a gated server with non-password (session) providers AND the
///   `native_pkce` auth flow advertised. Both halves are required: a provider list without
///   the flow means the gateway is too old for the RFC 8252 native login (#19), so the
///   segment must stay hidden — a NEW affordance needs positive evidence.
public struct ServerAuthCapability: Equatable, Sendable {
  /// The `auth_flows` entry that means "this gateway serves `/auth/native/authorize`".
  public static let nativePKCEFlow = "native_pkce"

  /// First provider with `supports_password == true`, or `nil` when the server has none.
  public var passwordProvider: AuthProvider?
  /// Providers with `supports_password == false`, in server order (the OAuth/session ones).
  public var oauthProviders: [AuthProvider]
  /// `auth_flows` contains `native_pkce` — the gateway serves the native PKCE endpoints.
  public var supportsNativeFlow: Bool
  /// The server is in the gated regime AND advertises providers, i.e. the static-token path
  /// is a poor fit here (the UI de-emphasizes it). A gated server that advertises nothing
  /// stays `.tokenOnly` — token is then the user's only way in, so it isn't de-emphasized.
  public var isGated: Bool

  public init(
    passwordProvider: AuthProvider? = nil,
    oauthProviders: [AuthProvider] = [],
    supportsNativeFlow: Bool = false,
    isGated: Bool = false
  ) {
    self.passwordProvider = passwordProvider
    self.oauthProviders = oauthProviders
    self.supportsNativeFlow = supportsNativeFlow
    self.isGated = isGated
  }

  /// Pure mapper. `providers` is the decoded `/api/auth/providers` payload, or `nil` when
  /// that endpoint 404s / is unreachable (older servers) — treated as no providers.
  public init(from status: ServerStatus, providers: [AuthProvider]?) {
    // Absent/false `auth_required` → today's token-only behaviour (loopback/`--insecure`).
    guard status.authRequired == true else {
      self = .tokenOnly
      return
    }
    let providers = providers ?? []
    // Gated yet no providers advertised (older server / providers 404): fall back to the
    // token path so the user still has a way in.
    guard !providers.isEmpty else {
      self = .tokenOnly
      return
    }
    self.init(
      // Mixed → password preferred: pick the first password-capable provider.
      passwordProvider: providers.first(where: \.supportsPassword),
      oauthProviders: providers.filter { !$0.supportsPassword },
      supportsNativeFlow: status.authFlows?.contains(Self.nativePKCEFlow) ?? false,
      isGated: true
    )
  }

  /// Nothing but the static-token path — old servers, `--insecure` loopback, or a gated
  /// server that advertised no providers.
  public static let tokenOnly = ServerAuthCapability()

  /// The server offers a password regime (`POST /auth/password-login`).
  public var isPasswordAvailable: Bool { passwordProvider != nil }

  /// The server offers the native OAuth regime. Needs BOTH an OAuth provider and the
  /// `native_pkce` flow — see the type doc.
  public var isOAuthAvailable: Bool { !oauthProviders.isEmpty && supportsNativeFlow }

  /// The wire provider name to pass to `POST /auth/password-login`, when this capability
  /// offers a password regime; `nil` otherwise.
  public var passwordProviderName: String? { passwordProvider?.name }
}
