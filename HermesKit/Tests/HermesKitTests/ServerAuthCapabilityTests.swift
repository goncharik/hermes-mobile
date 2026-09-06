import Foundation
import Testing

@testable import HermesKit

struct ServerAuthCapabilityTests {
  private func status(authRequired: Bool?, authFlows: [String]? = nil) -> ServerStatus {
    var s = ServerStatus()
    s.authRequired = authRequired
    s.authFlows = authFlows
    return s
  }

  private static let basic = AuthProvider(name: "basic", displayName: "Username & password", supportsPassword: true)
  private static let nous = AuthProvider(name: "nous", displayName: "Nous Research", supportsPassword: false)
  private static let selfHosted = AuthProvider(name: "self_hosted", displayName: "SSO", supportsPassword: false)

  // MARK: Table-driven mapper cases

  @Test func authNotRequiredIsTokenOnly() {
    // Loopback/--insecure: auth_required false → token-only, even if providers are present
    // and even when the gateway advertises the native flow.
    let capability = ServerAuthCapability(
      from: status(authRequired: false, authFlows: ["cookie", "native_pkce"]),
      providers: [Self.basic, Self.nous]
    )
    #expect(capability == .tokenOnly)
    #expect(!capability.isGated)
    #expect(!capability.isPasswordAvailable)
    #expect(!capability.isOAuthAvailable)
  }

  @Test func authRequiredAbsentIsTokenOnly() {
    // Older server: no auth_required field at all → token-only.
    #expect(ServerAuthCapability(from: status(authRequired: nil), providers: nil) == .tokenOnly)
  }

  @Test func gatedWithBasicIsPasswordAvailable() {
    let capability = ServerAuthCapability(
      from: status(authRequired: true, authFlows: ["cookie"]),
      providers: [Self.basic]
    )
    #expect(capability.passwordProvider == Self.basic)
    #expect(capability.passwordProviderName == "basic")
    #expect(capability.oauthProviders.isEmpty)
    #expect(capability.isPasswordAvailable)
    #expect(!capability.isOAuthAvailable)
    #expect(capability.isGated)
  }

  @Test func gatedWithOAuthOnlyPopulatesOAuthProviders() {
    let capability = ServerAuthCapability(
      from: status(authRequired: true, authFlows: ["cookie", "native_pkce"]),
      providers: [Self.nous, Self.selfHosted]
    )
    #expect(capability.passwordProvider == nil)
    #expect(capability.passwordProviderName == nil)
    #expect(capability.oauthProviders == [Self.nous, Self.selfHosted]) // server order preserved
    #expect(!capability.isPasswordAvailable)
    #expect(capability.isOAuthAvailable)
    #expect(capability.isGated)
  }

  @Test func gatedMixedOffersBothWithPasswordPreferred() {
    // OAuth listed first, but a password-capable provider exists → password still preferred
    // for preselection, and the OAuth providers stay available for their own segment.
    let capability = ServerAuthCapability(
      from: status(authRequired: true, authFlows: ["cookie", "native_pkce"]),
      providers: [Self.nous, Self.basic]
    )
    #expect(capability.passwordProvider == Self.basic)
    #expect(capability.oauthProviders == [Self.nous])
    #expect(capability.isPasswordAvailable)
    #expect(capability.isOAuthAvailable)
  }

  @Test func gatedMixedPicksFirstPasswordCapableProvider() {
    let other = AuthProvider(name: "ldap", displayName: "LDAP", supportsPassword: true)
    let capability = ServerAuthCapability(
      from: status(authRequired: true),
      providers: [Self.basic, other]
    )
    #expect(capability.passwordProviderName == "basic")
  }

  @Test func gatedWithNoProvidersFallsBackToTokenOnly() {
    // Gated but providers endpoint 404'd (nil) — give the user a way in via token, and
    // don't de-emphasize it (`isGated` stays false): it's the only path there is.
    let missing = ServerAuthCapability(from: status(authRequired: true), providers: nil)
    let empty = ServerAuthCapability(from: status(authRequired: true, authFlows: ["native_pkce"]), providers: [])
    #expect(missing == .tokenOnly)
    #expect(empty == .tokenOnly)
    #expect(!missing.isGated)
    #expect(!empty.isGated)
  }

  // MARK: Native-flow gate

  @Test func nativeFlowFlagFollowsAuthFlows() {
    #expect(
      ServerAuthCapability(from: status(authRequired: true, authFlows: ["cookie", "native_pkce"]),
                           providers: [Self.nous]).supportsNativeFlow
    )
    #expect(
      !ServerAuthCapability(from: status(authRequired: true, authFlows: ["cookie"]),
                            providers: [Self.nous]).supportsNativeFlow
    )
    // Absent `auth_flows` (older gateway) → no native flow. A NEW affordance needs
    // positive evidence, so this is the one place we do NOT apply the `?? true` rule.
    #expect(
      !ServerAuthCapability(from: status(authRequired: true, authFlows: nil),
                            providers: [Self.nous]).supportsNativeFlow
    )
  }

  @Test func oauthUnavailableWithoutNativeFlow() {
    // Providers exist but the gateway is too old to serve /auth/native/authorize.
    let capability = ServerAuthCapability(
      from: status(authRequired: true, authFlows: ["cookie"]),
      providers: [Self.nous]
    )
    #expect(!capability.oauthProviders.isEmpty)
    #expect(!capability.isOAuthAvailable)
  }

  @Test func oauthUnavailableWithNativeFlowButNoOAuthProviders() {
    // Password-only gated server that still advertises the flow → nothing to offer.
    let capability = ServerAuthCapability(
      from: status(authRequired: true, authFlows: ["cookie", "native_pkce"]),
      providers: [Self.basic]
    )
    #expect(capability.supportsNativeFlow)
    #expect(!capability.isOAuthAvailable)
  }

  @Test func tokenOnlyIsTheEmptyCapability() {
    let tokenOnly = ServerAuthCapability.tokenOnly
    #expect(tokenOnly.passwordProvider == nil)
    #expect(tokenOnly.oauthProviders.isEmpty)
    #expect(!tokenOnly.supportsNativeFlow)
    #expect(!tokenOnly.isGated)
  }

  // MARK: AuthProvider decoding leniency

  @Test func authProviderDecodesFullPayload() throws {
    let json = #"{"name":"basic","display_name":"Username & password","supports_password":true}"#
    let provider = try JSONDecoder().decode(AuthProvider.self, from: Data(json.utf8))
    #expect(provider == AuthProvider(name: "basic", displayName: "Username & password", supportsPassword: true))
  }

  @Test func authProviderDecodesMissingFieldsLeniently() throws {
    // Missing display_name → falls back to name; missing supports_password → false.
    let json = #"{"name":"basic"}"#
    let provider = try JSONDecoder().decode(AuthProvider.self, from: Data(json.utf8))
    #expect(provider == AuthProvider(name: "basic", displayName: "basic", supportsPassword: false))
  }
}
