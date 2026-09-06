import Foundation
import Testing

@testable import HermesKit

// Serialized: several cases touch the process-global `HTTPCookieStorage.shared`, and
// `deleteSession` now flushes it — running them concurrently would let one test wipe
// another's cookies.
@Suite(.serialized) struct KeychainClientTests {
  // MARK: Token-mode (byte-identical to before)

  @Test func inMemoryTokenRoundTrip() throws {
    let kc = KeychainClient.inMemory()
    #expect(kc.loadToken() == nil)
    try kc.saveToken("abc")
    #expect(kc.loadToken() == "abc")
    try kc.saveToken("def") // overwrite
    #expect(kc.loadToken() == "def")
    try kc.deleteToken()
    #expect(kc.loadToken() == nil)
  }

  @Test func tokenSessionRoundTripsAsAuthSession() throws {
    let kc = KeychainClient.inMemory()
    try kc.saveSession(.token("xyz"))
    #expect(kc.loadSession(HTTPCookieStorage()) == .token("xyz"))
    #expect(kc.loadToken() == "xyz")
  }

  // MARK: Cookie-mode

  @Test func cookieSessionSerializeStoreLoad() throws {
    let kc = KeychainClient.inMemory()
    let cookieSession = CookieSession(
      cookies: [
        SerializedCookie(name: "hermes_session_at", value: "ACCESS", domain: "test.local", path: "/"),
        SerializedCookie(name: "hermes_session_rt", value: "REFRESH", domain: "test.local", path: "/"),
      ],
      username: "alice",
      provider: "basic"
    )
    try kc.saveSession(.cookie(cookieSession))

    let loaded = kc.loadSession(HTTPCookieStorage())
    #expect(loaded == .cookie(cookieSession))
    // The token shim is nil for a cookie session.
    #expect(loaded?.token == nil)
  }

  @Test func loadRehydratesCookiesIntoStorage() throws {
    // Apple's `HTTPCookieStorage()` (freshly allocated) silently drops `setCookie`; only
    // `.shared` (and named group containers) actually persist. Use `.shared` and clean up.
    let kc = KeychainClient.inMemory()
    let storage = HTTPCookieStorage.shared
    let unique = "hermes_session_at_\(UUID().uuidString)"
    defer {
      storage.cookies?.filter { $0.name == unique }.forEach(storage.deleteCookie)
    }
    let cookieSession = CookieSession(
      cookies: [
        SerializedCookie(name: unique, value: "ACCESS", domain: "test.local", path: "/"),
      ],
      username: "alice",
      provider: "basic"
    )
    try kc.saveSession(.cookie(cookieSession))

    _ = kc.loadSession(storage)

    let names = (storage.cookies ?? []).map(\.name)
    #expect(names.contains(unique))
    let value = storage.cookies?.first { $0.name == unique }?.value
    #expect(value == "ACCESS")
  }

  @Test func deleteClearsCookieSession() throws {
    let kc = KeychainClient.inMemory()
    try kc.saveSession(.cookie(CookieSession(cookies: [], username: "a", provider: "basic")))
    #expect(kc.loadSession(HTTPCookieStorage()) != nil)
    try kc.deleteSession()
    #expect(kc.loadSession(HTTPCookieStorage()) == nil)
  }

  /// Logout must flush gated cookies out of the shared jar the live transports read — not
  /// just clear the Keychain item. `clearSharedCookies()` is what the live `deleteSession`
  /// runs (review finding #6). Without this, stale gated-session cookies linger after logout.
  @Test func clearSharedCookiesFlushesTheSharedJar() throws {
    let storage = HTTPCookieStorage.shared
    let unique = "hermes_session_at_\(UUID().uuidString)"
    defer { storage.cookies?.filter { $0.name == unique }.forEach(storage.deleteCookie) }
    if let cookie = SerializedCookie(name: unique, value: "ACCESS", domain: "test.local", path: "/").httpCookie {
      storage.setCookie(cookie)
    }
    #expect((storage.cookies ?? []).contains { $0.name == unique })

    clearSharedCookies()
    #expect(!(storage.cookies ?? []).contains { $0.name == unique })
  }

  /// A fresh in-app login must push its captured cookies into the shared jar immediately
  /// (not just on next launch) so the live REST/WS transports authenticate — and must flush
  /// any prior cookies first so a user-switch can't mix jars (review recheck finding). This
  /// is the standalone op the live keychain's `activateCookieSession` runs.
  @Test func activateCookieSessionRehydratesAndFlushesSharedJar() throws {
    let storage = HTTPCookieStorage.shared
    let staleName = "hermes_stale_\(UUID().uuidString)"
    let freshName = "hermes_session_at_\(UUID().uuidString)"
    defer {
      storage.cookies?
        .filter { $0.name == staleName || $0.name == freshName }
        .forEach(storage.deleteCookie)
    }
    // Seed a stale cookie as if a prior session left it behind.
    if let stale = SerializedCookie(name: staleName, value: "OLD", domain: "test.local", path: "/").httpCookie {
      storage.setCookie(stale)
    }
    #expect((storage.cookies ?? []).contains { $0.name == staleName })

    activateSharedCookieSession(CookieSession(
      cookies: [SerializedCookie(name: freshName, value: "NEW", domain: "test.local", path: "/")],
      username: "alice", provider: "basic"
    ))

    let names = (storage.cookies ?? []).map(\.name)
    #expect(names.contains(freshName))      // fresh cookie is now live
    #expect(!names.contains(staleName))     // prior cookies flushed
  }

  // MARK: Bearer-mode (native OAuth)

  @Test func bearerSessionRoundTripsAndDeletes() throws {
    let kc = KeychainClient.inMemory()
    let bearer = BearerSession(
      accessToken: "AT",
      refreshToken: "RT",
      expiresAt: 1_800_000_000,
      provider: "nous",
      userID: "user-42"
    )
    try kc.saveSession(.bearer(bearer))

    let loaded = kc.loadSession(HTTPCookieStorage())
    #expect(loaded == .bearer(bearer))
    // The token shim is nil for a bearer session (no `X-Hermes-Session-Token` path).
    #expect(loaded?.token == nil)

    try kc.deleteSession()
    #expect(kc.loadSession(HTTPCookieStorage()) == nil)
  }

  @Test func bearerSessionLoadDoesNotTouchTheCookieJar() throws {
    // A `.bearer` session carries no cookies; loading it must not add any to the jar.
    let kc = KeychainClient.inMemory()
    let storage = HTTPCookieStorage.shared
    let before = Set((storage.cookies ?? []).map(\.name))
    try kc.saveSession(
      .bearer(
        BearerSession(
          accessToken: "AT", refreshToken: "RT", expiresAt: 0, provider: "nous", userID: "u"
        )
      )
    )
    _ = kc.loadSession(storage)
    #expect(Set((storage.cookies ?? []).map(\.name)) == before)
  }

  @Test func liveKeychainRoundTripsBearerSession() throws {
    // Isolated service/account so this never collides with a real install or another test.
    let kc = KeychainClient.live(
      service: "dev.honcharenko.HermesMobile.tests.\(UUID().uuidString)",
      account: "session-token"
    )
    let bearer = BearerSession(
      accessToken: "AT",
      refreshToken: "RT",
      expiresAt: 1_800_000_000,
      provider: "nous",
      userID: "user-42"
    )
    do {
      try kc.saveSession(.bearer(bearer))
    } catch KeychainError.unhandled(errSecMissingEntitlement) {
      // The macOS `swift test` host runs unsigned, so the data-protection keychain refuses
      // writes. The encoding path is covered by the in-memory + Codable tests above.
      return
    }
    defer { try? kc.deleteSession() }

    #expect(kc.loadSession(HTTPCookieStorage()) == .bearer(bearer))
    try kc.deleteSession()
    #expect(kc.loadSession(HTTPCookieStorage()) == nil)
  }

  @Test func savingTokenThenCookieReplacesSession() throws {
    let kc = KeychainClient.inMemory()
    try kc.saveToken("tok")
    #expect(kc.loadSession(HTTPCookieStorage()) == .token("tok"))
    let cookieSession = CookieSession(cookies: [], username: "bob", provider: "basic")
    try kc.saveSession(.cookie(cookieSession))
    #expect(kc.loadSession(HTTPCookieStorage()) == .cookie(cookieSession))
    #expect(kc.loadToken() == nil)
  }
}
