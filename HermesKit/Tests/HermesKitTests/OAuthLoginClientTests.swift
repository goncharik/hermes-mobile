import ComposableArchitecture
import Foundation
import Network
import Testing

@testable import HermesKit

// Coverage for the native OAuth browser leg, all of it macOS-runnable:
//
// - the pure HTTP request-line parser (`parseRequestTarget`),
// - the real `NWListener` on 127.0.0.1 (bind, serve, report, stop),
// - and `runNativeLogin`, the orchestration seam, driven through injected fakes so
//   success / gateway rejection / state mismatch / timeout / cancel are all deterministic
//   without a browser.

// MARK: - Request-line parsing

struct LoopbackRequestParsingTests {
  private func target(_ raw: String) -> String? {
    parseRequestTarget(Data(raw.utf8))
  }

  @Test func parsesTheTargetOfAWellFormedRequestLine() {
    #expect(target("GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      == "/callback?code=abc&state=xyz")
    #expect(target("GET /callback HTTP/1.1\r\n\r\n") == "/callback")
    // A favicon probe parses fine — it is simply not a callback (that verdict is
    // `isLoopbackCallback`'s, not the parser's).
    #expect(target("GET /favicon.ico HTTP/1.1\r\n\r\n") == "/favicon.ico")
    // Bare LF line endings and other methods still parse.
    #expect(target("HEAD /callback?code=1 HTTP/1.0\n") == "/callback?code=1")
  }

  /// The Task 1 spike saw speculative TCP opens that sent NOTHING before the real
  /// `GET /callback`. Those must read as "not a request", never as an error.
  @Test func rejectsEverythingThatIsNotARequestLine() {
    #expect(parseRequestTarget(Data()) == nil)
    #expect(target("") == nil)
    #expect(target("\r\n\r\n") == nil)
    #expect(target("hello") == nil)
    #expect(target("GET /callback") == nil) // no version
    #expect(target("GET /callback HTTP/1.1 extra") == nil) // four components
    #expect(target("GET callback HTTP/1.1") == nil) // target isn't a path
    #expect(target("get /callback HTTP/1.1") == nil) // methods are uppercase
    #expect(target("GET /callback SPDY/3.1") == nil) // not HTTP
    // Raw TLS bytes (a browser that tried https:// on the loopback port).
    #expect(parseRequestTarget(Data([0x16, 0x03, 0x01, 0x00, 0x91])) == nil)
  }

  @Test func theResponseIsAWellFormedHTMLPage() {
    let response = String(decoding: loopbackHTTPResponse(html: "hi"), as: UTF8.self)
    #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(response.contains("Content-Type: text/html; charset=utf-8\r\n"))
    #expect(response.contains("Content-Length: 2\r\n"))
    #expect(response.contains("Connection: close\r\n"))
    #expect(response.hasSuffix("\r\n\r\nhi"))
  }
}

// MARK: - The real listener

/// These bind an actual ephemeral TCP port on 127.0.0.1 and drive it with `URLSession`.
/// Serialized: several sockets at once in a parallel suite is needless flakiness.
@Suite(.serialized)
struct LoopbackCallbackListenerTests {
  private func get(_ url: URL) async throws -> (Int, String) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    let (data, response) = try await URLSession(configuration: configuration).data(from: url)
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
  }

  @Test func bindsOnLoopbackServesThePageAndReportsEveryTarget() async throws {
    let listener = LoopbackCallbackListener()
    let session = try await listener.start()
    defer { session.stop() }

    #expect(session.redirectURI.hasPrefix("http://127.0.0.1:"))
    #expect(session.redirectURI.hasSuffix("/callback"))
    let port = URL(string: session.redirectURI)?.port ?? 0
    #expect(port > 0)

    var targets = session.targets.makeAsyncIterator()

    let callback = try #require(URL(string: session.redirectURI + "?code=abc&state=s-1"))
    let (status, body) = try await get(callback)
    #expect(status == 200)
    #expect(body.contains("Signed in to Hermes"))
    #expect(await targets.next() == "/callback?code=abc&state=s-1")

    // A second request (a probe, or the user reloading the tab) is answered exactly the
    // same way — the flow having settled is the DRIVER's business, not the listener's.
    let probe = try #require(URL(string: "http://127.0.0.1:\(port)/favicon.ico"))
    let (probeStatus, probeBody) = try await get(probe)
    #expect(probeStatus == 200)
    #expect(probeBody.contains("Signed in to Hermes"))
    #expect(await targets.next() == "/favicon.ico")
  }

  /// TCP does not promise the request head arrives in one segment. A lone `receive` that
  /// landed mid-request-line parsed to `nil`: the connection was answered, closed, and the
  /// callback never reported — the driver then sat out its entire 300 s budget waiting for a
  /// code that had already arrived, with no diagnostic.
  @Test(.timeLimit(.minutes(1)))
  func aRequestHeadSplitAcrossTwoWritesIsStillReported() async throws {
    let listener = LoopbackCallbackListener()
    let session = try await listener.start()
    defer { session.stop() }
    let port = try #require(URL(string: session.redirectURI)?.port)

    var targets = session.targets.makeAsyncIterator()
    let client = NWConnection(
      host: .ipv4(.loopback),
      port: try #require(NWEndpoint.Port(rawValue: UInt16(port))),
      using: .tcp
    )
    defer { client.cancel() }
    client.start(queue: .global())

    try await write(client, "GET /callback?code=split&stat")
    // Long enough for the listener to have consumed the partial head before the rest lands.
    try await Task.sleep(for: .milliseconds(200))
    try await write(client, "e=s-2 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

    #expect(await targets.next() == "/callback?code=split&state=s-2")
  }

  private func write(_ connection: NWConnection, _ text: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  @Test func stoppingIsIdempotentAndFinishesTheTargetStream() async throws {
    let listener = LoopbackCallbackListener()
    let session = try await listener.start()

    session.stop()
    session.stop() // the driver stops on the happy path AND in its `defer`

    var targets = session.targets.makeAsyncIterator()
    #expect(await targets.next() == nil)
  }
}

// MARK: - Orchestration

struct NativeLoginDriverTests {
  private let baseURL = URL(string: "https://agent.example.com")!
  private let redirectURI = "http://127.0.0.1:54321/callback"

  private var issued: BearerSession {
    BearerSession(
      accessToken: "AT", refreshToken: "RT", expiresAt: 4_000_000_000,
      provider: "nous", userID: "u-1"
    )
  }

  /// A stand-in for the loopback listener: the test yields request targets itself, so the
  /// browser "redirect" happens exactly when it wants it to.
  private struct FakeListener {
    var session: LoopbackCallbackSession
    var targets: AsyncStream<String>.Continuation
    var stops: LockIsolated<Int>
  }

  private func fakeListener(redirectURI: String) -> FakeListener {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    let stops = LockIsolated(0)
    return FakeListener(
      session: LoopbackCallbackSession(redirectURI: redirectURI, targets: stream, stop: {
        stops.withValue { $0 += 1 }
        continuation.finish()
      }),
      targets: continuation,
      stops: stops
    )
  }

  /// A sheet that stays open until the flow is settled elsewhere and the driver cancels it
  /// — the shape of the real one, which (per the spike) never reports its own teardown.
  private let parkedBrowser: @Sendable (URL) async -> OAuthBrowserOutcome = { _ in
    try? await Task.sleep(for: .seconds(30))
    return .cancelled
  }

  // MARK: Success

  @Test func aCallbackWinsTheRaceAndIsRedeemedForTokens() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let opened = LockIsolated<URL?>(nil)
    let redeemed = LockIsolated<[String]>([])

    let driver = NativeLoginDriver(
      makePKCE: { PKCEPair(verifier: "VERIFIER", challenge: "CHALLENGE") },
      makeState: { "STATE-1" },
      startListener: { listener.session },
      openBrowser: { url in
        opened.setValue(url)
        // Two things the listener answers but must NOT settle on (spike finding): a
        // zero-byte connection and a favicon probe.
        listener.targets.yield("")
        listener.targets.yield("/favicon.ico")
        listener.targets.yield("/callback?code=CODE-1&state=STATE-1")
        try? await Task.sleep(for: .seconds(30))
        return .cancelled
      },
      exchange: { code, verifier in
        // Taken HERE, not after the flow: the loopback socket must already be closed when
        // the code is redeemed — nothing else may arrive on it once the code is in hand.
        // Asserting after the return would be satisfied by the error-path `defer` alone.
        #expect(listener.stops.value >= 1, "the listener must be stopped before the token hop")
        redeemed.withValue { $0.append("\(code)|\(verifier)") }
        return self.issued
      },
      clock: TestClock()
    )

    let session = try await runNativeLogin(baseURL: baseURL, provider: "nous", driver: driver)

    #expect(session == issued)
    #expect(redeemed.value == ["CODE-1|VERIFIER"])
    // Torn down on the happy path (and idempotently again by the `defer`).
    #expect(listener.stops.value >= 1)

    let authorize = try #require(opened.value)
    #expect(authorize.path == "/auth/native/authorize")
    let query = try #require(authorize.query)
    #expect(query.contains("code_challenge=CHALLENGE"))
    #expect(query.contains("code_challenge_method=S256"))
    #expect(query.contains("state=STATE-1"))
    #expect(query.contains("provider=nous"))
    // The loopback URI is percent-encoded down to the unreserved set (mirrors the desktop).
    #expect(query.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fcallback"))
  }

  @Test func omitsTheProviderWhenTheGatewayShouldAutoSelect() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let opened = LockIsolated<URL?>(nil)
    let driver = NativeLoginDriver(
      makeState: { "S" },
      startListener: { listener.session },
      openBrowser: { url in
        opened.setValue(url)
        listener.targets.yield("/callback?code=C&state=S")
        try? await Task.sleep(for: .seconds(30))
        return .cancelled
      },
      exchange: { _, _ in self.issued },
      clock: TestClock()
    )

    _ = try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    #expect(opened.value?.query?.contains("provider=") == false)
  }

  // MARK: Failure verdicts

  @Test func aGatewayErrorOnTheCallbackCarriesItsReason() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let redeemed = LockIsolated(0)
    let driver = NativeLoginDriver(
      makeState: { "S" },
      startListener: { listener.session },
      openBrowser: { _ in
        listener.targets.yield("/callback?error=access_denied&error_description=User%20said%20no&state=S")
        try? await Task.sleep(for: .seconds(30))
        return .cancelled
      },
      exchange: { _, _ in
        redeemed.withValue { $0 += 1 }
        return self.issued
      },
      clock: TestClock()
    )

    await #expect(throws: OAuthLoginError.gatewayRejected("access_denied (User said no)")) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
    #expect(redeemed.value == 0)
  }

  /// A forged callback must never have its code redeemed (RFC 6749 §10.12).
  @Test func aStateMismatchNeverReachesTheTokenEndpoint() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let redeemed = LockIsolated(0)
    let driver = NativeLoginDriver(
      makeState: { "STATE-1" },
      startListener: { listener.session },
      openBrowser: { _ in
        listener.targets.yield("/callback?code=CODE-1&state=FORGED")
        try? await Task.sleep(for: .seconds(30))
        return .cancelled
      },
      exchange: { _, _ in
        redeemed.withValue { $0 += 1 }
        return self.issued
      },
      clock: TestClock()
    )

    await #expect(throws: OAuthLoginError.stateMismatch) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
    #expect(redeemed.value == 0)
  }

  /// The one verdict the browser sheet is allowed to deliver: a USER dismissal arriving
  /// before the listener settled.
  @Test func aUserDismissalBeforeTheCallbackIsACancellation() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let redeemed = LockIsolated(0)
    let driver = NativeLoginDriver(
      startListener: { listener.session },
      openBrowser: { _ in .cancelled },
      exchange: { _, _ in
        redeemed.withValue { $0 += 1 }
        return self.issued
      },
      clock: TestClock()
    )

    await #expect(throws: OAuthLoginError.cancelled) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
    #expect(redeemed.value == 0)
    #expect(listener.stops.value >= 1)
  }

  @Test func aBrowserThatCannotPresentSurfacesItsReason() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let driver = NativeLoginDriver(
      startListener: { listener.session },
      openBrowser: { _ in .failed("Couldn’t open the sign-in browser.") },
      exchange: { _, _ in self.issued },
      clock: TestClock()
    )

    await #expect(throws: OAuthLoginError.gatewayRejected("Couldn’t open the sign-in browser.")) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
  }

  /// An `ImmediateClock` makes the whole-flow budget elapse the moment it is awaited, so
  /// the timeout leg wins deterministically against a parked browser and a silent listener.
  @Test func anAbandonedSheetTimesOut() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let driver = NativeLoginDriver(
      startListener: { listener.session },
      openBrowser: parkedBrowser,
      exchange: { _, _ in self.issued },
      clock: ImmediateClock()
    )

    await #expect(throws: OAuthLoginError.timedOut) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
    #expect(listener.stops.value >= 1)
  }

  @Test func aListenerThatCannotBindFails() async throws {
    let driver = NativeLoginDriver(
      startListener: { throw OAuthLoginError.listenerFailed },
      openBrowser: parkedBrowser,
      exchange: { _, _ in self.issued },
      clock: TestClock()
    )
    await #expect(throws: OAuthLoginError.listenerFailed) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }

    // Anything else the socket layer throws is normalized into the same verdict — no
    // `Network` error type reaches the UI.
    let raw = NativeLoginDriver(
      startListener: { throw URLError(.cannotFindHost) },
      openBrowser: parkedBrowser,
      exchange: { _, _ in self.issued },
      clock: TestClock()
    )
    await #expect(throws: OAuthLoginError.listenerFailed) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: raw)
    }
  }

  /// The socket dying mid-flow ends the target stream: fail immediately rather than sit out
  /// the five-minute budget waiting for a callback that can never arrive.
  @Test func aListenerThatDiesBeforeTheCallbackFails() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let driver = NativeLoginDriver(
      startListener: { listener.session },
      openBrowser: { _ in
        listener.targets.finish()
        try? await Task.sleep(for: .seconds(30))
        return .cancelled
      },
      exchange: { _, _ in self.issued },
      clock: TestClock()
    )

    await #expect(throws: OAuthLoginError.listenerFailed) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
  }

  @Test func aRejectedTokenExchangeKeepsTheServersDetail() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let driver = NativeLoginDriver(
      makeState: { "S" },
      startListener: { listener.session },
      openBrowser: { _ in
        listener.targets.yield("/callback?code=EXPIRED&state=S")
        try? await Task.sleep(for: .seconds(30))
        return .cancelled
      },
      exchange: { _, _ in throw RESTError.server(status: 400, detail: "invalid or expired code") },
      clock: TestClock()
    )

    await #expect(
      throws: OAuthLoginError.tokenExchange(.server(status: 400, detail: "invalid or expired code"))
    ) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
  }

  @Test func aTransportFailureOnTheTokenLegIsNormalized() async throws {
    let listener = fakeListener(redirectURI: redirectURI)
    let driver = NativeLoginDriver(
      makeState: { "S" },
      startListener: { listener.session },
      openBrowser: { _ in
        listener.targets.yield("/callback?code=C&state=S")
        try? await Task.sleep(for: .seconds(30))
        return .cancelled
      },
      exchange: { _, _ in throw URLError(.notConnectedToInternet) },
      clock: TestClock()
    )

    await #expect(throws: OAuthLoginError.tokenExchange(.offline)) {
      try await runNativeLogin(baseURL: baseURL, provider: nil, driver: driver)
    }
  }
}
