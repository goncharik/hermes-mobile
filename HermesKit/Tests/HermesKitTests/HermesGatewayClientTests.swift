import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// A fake `WebSocketTransport`: records sent frames, lets the test inject inbound
/// frames, and can auto-respond to sends via the `onSend` hook.
final class FakeTransport: WebSocketTransport, @unchecked Sendable {
  let inboundContinuation: AsyncStream<String>.Continuation
  private var iterator: AsyncStream<String>.AsyncIterator
  private let lock = NSLock()
  private var _sent: [String] = []
  private let onSend: @Sendable (_ frame: String, _ inbound: AsyncStream<String>.Continuation) -> Void

  init(onSend: @escaping @Sendable (String, AsyncStream<String>.Continuation) -> Void = { _, _ in }) {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    inboundContinuation = continuation
    iterator = stream.makeAsyncIterator()
    self.onSend = onSend
  }

  private var _cancelled = false
  /// True once `cancel()` has run — lets a test assert the connection actor actually shut the
  /// transport down (e.g. on consumer cancel / stream termination).
  var cancelled: Bool { lock.withLock { _cancelled } }

  var sent: [String] { lock.withLock { _sent } }

  func send(_ text: String) async throws {
    lock.withLock { _sent.append(text) }
    onSend(text, inboundContinuation)
  }

  func receive() async throws -> String {
    guard let next = await iterator.next() else { throw GatewayError.disconnected }
    return next
  }

  func cancel() {
    lock.withLock { _cancelled = true }
    inboundContinuation.finish()
  }
  func inject(_ frame: String) { inboundContinuation.yield(frame) }
}

private func requestID(_ frame: String) -> Int? {
  (try? JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8)))?["id"]?.intValue
}

@Suite struct HermesGatewayClientTests {
  private let url = URL(string: "http://test.local:9119")!

  @Test func sendResolvesOnMatchingResult() async throws {
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"streaming"}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} } // the connection lives as long as the stream

    let result = try await client.send("prompt.submit", .object(["text": .string("hi")]))
    #expect(result == .object(["status": .string("streaming")]))

    // The outbound frame is a well-formed JSON-RPC request.
    let sent = try #require(transport.sent.first)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(sent.utf8))
    #expect(decoded["method"]?.stringValue == "prompt.submit")
    #expect(decoded["jsonrpc"]?.stringValue == "2.0")
  }

  @Test func eventsAreYieldedOnStream() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))

    transport.inject(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s","payload":{"text":"hi"}}}"#)

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .messageDelta(text: "hi"))
  }

  @Test func multipleNewlineDelimitedFramesInOneMessage() async throws {
    let transport = FakeTransport()
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))

    transport.inject(
      #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","payload":{"text":"a"}}}"#
      + "\n"
      + #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","payload":{"text":"b"}}}"#
    )

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .messageDelta(text: "a"))
    #expect(await iterator.next() == .messageDelta(text: "b"))
  }

  @Test func errorResponseThrows() async throws {
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"error":{"message":"bad session"}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    await #expect(throws: GatewayError.server("bad session")) {
      _ = try await client.send("session.resume", .object(["session_id": .string("nope")]))
    }
  }

  @Test func concurrentSendsCorrelateByID() async throws {
    // Echo each request's id back in its result — proves the pending map routes
    // each response to the correct waiter.
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"echo":\#(id)}}"#)
      }
    }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    async let first = client.send("m", .object(["k": .string("a")]))
    async let second = client.send("m", .object(["k": .string("b")]))
    let (a, b) = try await (first, second)

    let ea = try #require(a["echo"]?.intValue)
    let eb = try #require(b["echo"]?.intValue)
    #expect(ea != eb)
  }

  @Test func sendBeforeConnectThrowsNotConnected() async {
    let client = HermesGatewayClient.make { _ in FakeTransport() }
    await #expect(throws: GatewayError.notConnected) {
      _ = try await client.send("session.create", .object([:]))
    }
  }

  @Test func sendTimesOutWhenServerNeverResponds() async throws {
    // The transport accepts the send but never yields a matching response; advancing the
    // injected TestClock past the timeout must reject `send` with `.timedOut(method:)`.
    // Deterministic: no wall-clock racing — the timeout fires only when WE advance.
    let clock = TestClock()
    let transport = FakeTransport() // no onSend → no inbound frame ever
    let client = HermesGatewayClient.make(requestTimeout: .seconds(30), clock: clock) { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    // Run `send` in a detached task so we can advance the clock while it's suspended on
    // its pending continuation; capture whatever it throws.
    let thrown = LockIsolated<(any Error)?>(nil)
    let task = Task {
      do { _ = try await client.send("prompt.submit", .object(["text": .string("hi")])) }
      catch { thrown.setValue(error) }
    }
    // Yield enough for `send` to register its pending continuation and the timeout task to
    // reach `clock.sleep`, then fire the timeout deterministically by advancing the clock.
    for _ in 0..<20 { await Task.yield() }
    await clock.advance(by: .seconds(30))
    await task.value

    #expect(thrown.value as? GatewayError == .timedOut(method: "prompt.submit"))
  }

  @Test func slashPipelineGetsTheLongPerRequestBudget() async throws {
    // `slash.exec` blocks the gateway dispatcher "for seconds to minutes": worker-routed
    // commands have a 45s pipe budget of their own and `/compress` runs an UNBOUNDED inline
    // LLM summarisation. Under the 30s default it reliably timed out on exactly the sessions
    // big enough to warrant compressing — while the compression SUCCEEDED server-side, so the
    // user saw a flat failure and a stale context pill. The slash methods therefore get the
    // long budget (desktop budgets 120s for its equivalent `session.compress` call).
    let clock = TestClock()
    let transport = FakeTransport() // never answers
    let client = HermesGatewayClient.make(
      requestTimeout: .seconds(30), longRequestTimeout: .seconds(120), clock: clock
    ) { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    let thrown = LockIsolated<(any Error)?>(nil)
    let task = Task {
      do { _ = try await client.send("slash.exec", .object(["command": .string("compress")])) }
      catch { thrown.setValue(error) }
    }
    for _ in 0..<20 { await Task.yield() }
    // Well past the default budget: the slash call must still be waiting.
    await clock.advance(by: .seconds(45))
    for _ in 0..<20 { await Task.yield() }
    #expect(thrown.value == nil)

    // …and it does still time out eventually, at the long budget.
    await clock.advance(by: .seconds(75))
    await task.value
    #expect(thrown.value as? GatewayError == .timedOut(method: "slash.exec"))
    // The long budget is scoped to the slash pipeline + the dedicated compress RPC — the
    // method list is the contract. `session.compress` runs the same unbounded inline LLM
    // summarisation and MUST get the 120s budget (`/compress`/`/compact` now call it directly).
    #expect(HermesGatewayClient.longRunningMethods == ["slash.exec", "command.dispatch", "session.compress"])
  }

  @Test func sessionCompressGetsTheLongPerRequestBudget() async throws {
    // `/compress`/`/compact` now call the dedicated `session.compress` RPC, whose handler runs
    // the same UNBOUNDED inline LLM summarisation. Under the 30s default it would time out on
    // exactly the large sessions worth compressing — so it must ride the 120s long budget.
    let clock = TestClock()
    let transport = FakeTransport() // never answers
    let client = HermesGatewayClient.make(
      requestTimeout: .seconds(30), longRequestTimeout: .seconds(120), clock: clock
    ) { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    let thrown = LockIsolated<(any Error)?>(nil)
    let task = Task {
      do { _ = try await client.send("session.compress", .object(["session_id": .string("s1")])) }
      catch { thrown.setValue(error) }
    }
    for _ in 0..<20 { await Task.yield() }
    // Well past the default budget: the compress call must still be waiting.
    await clock.advance(by: .seconds(45))
    for _ in 0..<20 { await Task.yield() }
    #expect(thrown.value == nil)

    // …and it does still time out eventually, at the long budget.
    await clock.advance(by: .seconds(75))
    await task.value
    #expect(thrown.value as? GatewayError == .timedOut(method: "session.compress"))
  }

  @Test func normalResponseResolvesAndTimeoutDoesNotFire() async throws {
    // A fast response resolves `send` and cancels its timer. Advancing the TestClock well
    // past the timeout afterwards must produce no spurious late throw — the result stands.
    let clock = TestClock()
    let transport = FakeTransport { frame, inbound in
      if let id = requestID(frame) {
        inbound.yield(#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"streaming"}}"#)
      }
    }
    let client = HermesGatewayClient.make(requestTimeout: .seconds(30), clock: clock) { _ in transport }
    let stream = client.connect(url, .token("t"))
    defer { withExtendedLifetime(stream) {} }

    let result = try await client.send("prompt.submit", .object(["text": .string("hi")]))
    #expect(result == .object(["status": .string("streaming")]))

    // Advance past the (now-cancelled) timeout window; the resolved value must be unaffected
    // and no late `.timedOut` can fire.
    await clock.advance(by: .seconds(60))
    #expect(result == .object(["status": .string("streaming")]))
  }

  @Test func socketCloseFailsPendingAndFinishesStream() async throws {
    // Close the socket the moment the first request is transmitted (pending is
    // already registered by then, so this is deterministic).
    let transport = FakeTransport { _, inbound in inbound.finish() }
    let client = HermesGatewayClient.make { _ in transport }
    let stream = client.connect(url, .token("t"))

    await #expect(throws: GatewayError.disconnected) {
      _ = try await client.send("session.create", .object([:]))
    }
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil) // stream finished
  }

  // MARK: - Auth-regime URL branching

  /// Regression guard (hard requirement): a `.token` session must build the *exact* legacy
  /// WS URL `…/api/ws?token=<token>` — byte-identical, never minting a ticket.
  @Test func tokenModeBuildsByteIdenticalWSURL() async throws {
    let captured = LockIsolated<URL?>(nil)
    let minted = LockIsolated(false)
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in minted.setValue(true); return "should-not-mint" },
      makeTransport: { wsURL in captured.setValue(wsURL); return FakeTransport() }
    )
    let stream = client.connect(url, .token("sekret"))
    defer { withExtendedLifetime(stream) {} }

    // SYNCHRONOUS by contract: no `await`/yield between `connect` and the open, so an
    // immediate `send` finds the connection. The gated regimes' async mint must never
    // leak into this branch — asserted before any suspension point.
    #expect(captured.value?.absoluteString == "ws://test.local:9119/api/ws?token=sekret")
    #expect(minted.value == false) // token mode never mints a ticket
  }

  /// A `.cookie` session mints a fresh ws-ticket then connects with `…/api/ws?ticket=<t>`.
  @Test func cookieModeMintsTicketThenConnectsWithTicket() async throws {
    let captured = LockIsolated<URL?>(nil)
    let mintArgs = LockIsolated<(URL, AuthSession)?>(nil)
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "test.local", path: "/")],
      username: "alice", provider: "basic"
    )
    let client = HermesGatewayClient.make(
      mintTicket: { base, cs in mintArgs.setValue((base, cs)); return "T1CKET" },
      makeTransport: { wsURL in captured.setValue(wsURL); return FakeTransport() }
    )
    let stream = client.connect(url, .cookie(cookieSession))
    defer { withExtendedLifetime(stream) {} }

    for _ in 0..<50 where captured.value == nil { await Task.yield() }

    #expect(captured.value?.absoluteString == "ws://test.local:9119/api/ws?ticket=T1CKET")
    #expect(mintArgs.value?.0 == url)                     // minted against the base URL
    #expect(mintArgs.value?.1 == .cookie(cookieSession))  // with the persisted cookie session
  }

  /// A `401` from the ticket mint (`authExpired`) yields `.authExpired` on the stream and
  /// finishes — never building a transport (non-retryable; the reducer routes to re-auth).
  @Test func cookieModeMintAuthExpiredYieldsAuthExpiredAndFinishes() async throws {
    let built = LockIsolated(false)
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in throw GatewayError.authExpired },
      makeTransport: { _ in built.setValue(true); return FakeTransport() }
    )
    let stream = client.connect(url, .cookie(CookieSession(cookies: [], username: "u", provider: "basic")))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .authExpired)
    #expect(await iterator.next() == nil) // then finished
    #expect(built.value == false)         // no socket was opened
  }

  /// A transient mint failure finishes the stream like a dropped socket (no `.authExpired`)
  /// so the reducer's existing backoff re-calls `connect` and re-mints.
  @Test func cookieModeTransientMintFinishesStreamWithoutAuthExpired() async throws {
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in throw GatewayError.ticketUnavailable },
      makeTransport: { _ in FakeTransport() }
    )
    let stream = client.connect(url, .cookie(CookieSession(cookies: [], username: "u", provider: "basic")))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil) // finished, no .authExpired emitted
  }

  /// After a successful **cookie** connect, terminating the stream (consumer cancels →
  /// `onTermination`) must shut the opened transport down. Guards the lost-shutdown leak
  /// where the cookie-path `onTermination` clobbered the connection's shutdown handler.
  @Test func cookieModeStreamTerminationShutsDownOpenedConnection() async throws {
    let captured = LockIsolated<URL?>(nil)
    let transport = FakeTransport()
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in "T1CKET" },
      makeTransport: { wsURL in captured.setValue(wsURL); return transport }
    )
    // Scope the stream so it's fully released (its `onTermination` then fires) after connect.
    do {
      let stream = client.connect(url, .cookie(CookieSession(cookies: [], username: "u", provider: "basic")))
      // Wait for the async mint+open to build the transport before dropping the stream.
      for _ in 0..<100 where captured.value == nil { await Task.yield() }
      #expect(captured.value != nil) // connection opened
      _ = stream
    }
    // The dropped stream's termination handler shuts the opened connection down (async).
    for _ in 0..<100 where !transport.cancelled { await Task.yield() }
    #expect(transport.cancelled) // socket was torn down, not leaked
  }

  /// Cancel *during* the mint (stream released while `mintTicket` is still awaiting): the
  /// resumed setup task must observe cancellation and NOT open an orphan connection that
  /// nothing would ever shut down. Guards the narrow mint-race the prior fix left open.
  @Test func cookieModeCancelDuringMintDoesNotOpenOrphanConnection() async throws {
    let built = LockIsolated(false)
    let mintEntered = LockIsolated(false)
    let (gate, release) = AsyncStream<Void>.makeStream()
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in
        mintEntered.setValue(true)
        var it = gate.makeAsyncIterator()
        _ = await it.next() // block until the test releases the gate
        return "T1CKET"
      },
      makeTransport: { _ in built.setValue(true); return FakeTransport() }
    )
    do {
      let stream = client.connect(url, .cookie(CookieSession(cookies: [], username: "u", provider: "basic")))
      for _ in 0..<200 where !mintEntered.value { await Task.yield() } // wait until mint is in-flight
      #expect(mintEntered.value)
      _ = stream // drop the stream here → onTermination cancels the setup task mid-mint
    }
    release.yield(()) // let the mint return; the task should bail on cancellation, not open()
    for _ in 0..<200 { await Task.yield() }
    #expect(built.value == false) // no orphan connection was opened
  }

  // MARK: - Bearer (native OAuth) regime
  //
  // `.bearer` rides the same gated branch as `.cookie` — the regimes differ only in how the
  // minter authenticates — so these mirror the cookie cases one for one. They are the guard
  // that the shared branch keeps behaving identically for BOTH payloads.

  private var bearerSession: BearerSession {
    BearerSession(
      accessToken: "AT1", refreshToken: "RT1", expiresAt: 4_000_000_000,
      provider: "nous", userID: "u-1"
    )
  }

  /// A `.bearer` session mints a fresh ws-ticket then connects with `…/api/ws?ticket=<t>` —
  /// the same WS URL shape as the cookie regime (the gateway doesn't care how it was minted).
  @Test func bearerModeMintsTicketThenConnectsWithTicket() async throws {
    let captured = LockIsolated<URL?>(nil)
    let mintArgs = LockIsolated<(URL, AuthSession)?>(nil)
    let client = HermesGatewayClient.make(
      mintTicket: { base, auth in mintArgs.setValue((base, auth)); return "B34RER" },
      makeTransport: { wsURL in captured.setValue(wsURL); return FakeTransport() }
    )
    let stream = client.connect(url, .bearer(bearerSession))
    defer { withExtendedLifetime(stream) {} }

    for _ in 0..<50 where captured.value == nil { await Task.yield() }

    #expect(captured.value?.absoluteString == "ws://test.local:9119/api/ws?ticket=B34RER")
    #expect(mintArgs.value?.0 == url)
    // The whole `AuthSession` reaches the minter, which is what lets ONE minter resolve
    // the regime (cookie jar vs `Authorization: Bearer`).
    #expect(mintArgs.value?.1 == .bearer(bearerSession))
  }

  /// A dead refresh token (`authExpired` out of `BearerTokenStore`) yields `.authExpired` and
  /// finishes without opening a socket — non-retryable, routed to re-auth, never backoff.
  @Test func bearerModeMintAuthExpiredYieldsAuthExpiredAndFinishes() async throws {
    let built = LockIsolated(false)
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in throw GatewayError.authExpired },
      makeTransport: { _ in built.setValue(true); return FakeTransport() }
    )
    let stream = client.connect(url, .bearer(bearerSession))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == .authExpired)
    #expect(await iterator.next() == nil) // then finished
    #expect(built.value == false)         // no socket was opened
  }

  /// A transient bearer mint failure (503 / transport) finishes the stream like a dropped
  /// socket so the reducer's backoff re-dials — never `.authExpired`, which would sign the
  /// user out over a momentarily unreachable provider.
  @Test func bearerModeTransientMintFinishesStreamWithoutAuthExpired() async throws {
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in throw GatewayError.ticketUnavailable },
      makeTransport: { _ in FakeTransport() }
    )
    let stream = client.connect(url, .bearer(bearerSession))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil) // finished, no .authExpired emitted
  }

  /// Terminating a successful bearer connect shuts the opened transport down (the composed
  /// `onTermination` reaches the connection, not just the setup task).
  @Test func bearerModeStreamTerminationShutsDownOpenedConnection() async throws {
    let captured = LockIsolated<URL?>(nil)
    let transport = FakeTransport()
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in "B34RER" },
      makeTransport: { wsURL in captured.setValue(wsURL); return transport }
    )
    do {
      let stream = client.connect(url, .bearer(bearerSession))
      for _ in 0..<100 where captured.value == nil { await Task.yield() }
      #expect(captured.value != nil) // connection opened
      _ = stream
    }
    for _ in 0..<100 where !transport.cancelled { await Task.yield() }
    #expect(transport.cancelled) // socket was torn down, not leaked
  }

  /// Consumer cancel *during* the bearer mint must not open an orphan connection — the
  /// `Task.checkCancellation()` between mint and `open()` is what makes that true.
  @Test func bearerModeCancelDuringMintDoesNotOpenOrphanConnection() async throws {
    let built = LockIsolated(false)
    let mintEntered = LockIsolated(false)
    let (gate, release) = AsyncStream<Void>.makeStream()
    let client = HermesGatewayClient.make(
      mintTicket: { _, _ in
        mintEntered.setValue(true)
        var it = gate.makeAsyncIterator()
        _ = await it.next() // block until the test releases the gate
        return "B34RER"
      },
      makeTransport: { _ in built.setValue(true); return FakeTransport() }
    )
    do {
      let stream = client.connect(url, .bearer(bearerSession))
      for _ in 0..<200 where !mintEntered.value { await Task.yield() }
      #expect(mintEntered.value)
      _ = stream // drop the stream → onTermination cancels the setup task mid-mint
    }
    release.yield(())
    for _ in 0..<200 { await Task.yield() }
    #expect(built.value == false) // no orphan connection was opened
  }
}

/// Wire-level coverage of `POST /api/auth/ws-ticket` for both gated regimes: the header the
/// bearer mint sends, the refresh hop that must precede it, and the status→verdict mapping.
///
/// Nested in `RESTTransportSuite` so it serializes against the other suites driving the
/// process-global `MockURLProtocol` stub.
extension RESTTransportSuite {
struct GatewayTicketMintTests {
  private let baseURL = URL(string: "http://test.local:9119")!

  private var mockSession: URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func stored(expiresAt: Double) -> BearerSession {
    BearerSession(
      accessToken: "AT1", refreshToken: "RT1", expiresAt: expiresAt,
      provider: "nous", userID: "u-1"
    )
  }

  /// A rotated pair as the gateway returns it from `/auth/native/refresh`.
  private let rotatedJSON = #"""
  {"access_token":"AT2","refresh_token":"RT2","token_type":"Bearer","expires_at":4000000000,"provider":"nous","user_id":"u-1"}
  """#

  private func freshStore(expiresAt: Double) async -> BearerTokenStore {
    let store = BearerTokenStore(now: { Date(timeIntervalSince1970: 1_000_000) }, refreshLeeway: 120)
    store.seed(stored(expiresAt: expiresAt), baseURL: baseURL, persist: { _ in })
    return store
  }

  @Test func bearerMintSendsTheAuthorizationHeaderAndReturnsTheTicket() async throws {
    let store = await freshStore(expiresAt: 1_000_600) // comfortably fresh → no refresh
    MockURLProtocol.set(json: #"{"ticket":"T1CKET"}"#)

    let ticket = try await wsTicket(baseURL: baseURL, tokenStore: store, session: mockSession)
    #expect(ticket == "T1CKET")

    #expect(MockURLProtocol.requests.count == 1) // no refresh hop
    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/auth/ws-ticket")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer AT1")
    // The bearer regime must never touch the legacy token header.
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
  }

  @Test func bearerMintRefreshesBeforeMintingWhenNearExpiry() async throws {
    // 10 s left, inside the 120 s leeway: the rotation MUST land before the mint, or the
    // ticket would be minted with a token the gateway is about to reject.
    let store = await freshStore(expiresAt: 1_000_010)
    MockURLProtocol.setSequence([
      .init(statusCode: 200, body: Data(rotatedJSON.utf8)),
      .init(statusCode: 200, body: Data(#"{"ticket":"T1CKET"}"#.utf8)),
    ])

    let ticket = try await wsTicket(baseURL: baseURL, tokenStore: store, session: mockSession)
    #expect(ticket == "T1CKET")

    #expect(MockURLProtocol.requests.count == 2)
    #expect(MockURLProtocol.requests.first?.url?.path == "/auth/native/refresh")
    let mint = try #require(MockURLProtocol.requests.last)
    #expect(mint.url?.path == "/api/auth/ws-ticket")
    #expect(mint.value(forHTTPHeaderField: "Authorization") == "Bearer AT2") // the ROTATED token
    #expect(store.current?.refreshToken == "RT2")
  }

  @Test func aDeadRefreshTokenIsAuthExpiredAndNeverMints() async throws {
    let store = await freshStore(expiresAt: 1_000_010)
    MockURLProtocol.set(status: 401, json: #"{"error":"session_expired"}"#)

    await #expect(throws: GatewayError.authExpired) {
      _ = try await wsTicket(baseURL: baseURL, tokenStore: store, session: mockSession)
    }
    #expect(MockURLProtocol.requests.count == 1) // the mint never went out
    #expect(store.current == nil)          // store drained by the expiry verdict
  }

  @Test func aRefreshOutageIsTransientAndKeepsTheTokens() async throws {
    // 503 = a provider is momentarily unreachable. `.ticketUnavailable` sends the reducer to
    // backoff instead of signing the user out, and the pair must survive for the retry.
    let store = await freshStore(expiresAt: 1_000_010)
    MockURLProtocol.set(status: 503)

    await #expect(throws: GatewayError.ticketUnavailable) {
      _ = try await wsTicket(baseURL: baseURL, tokenStore: store, session: mockSession)
    }
    #expect(store.current?.accessToken == "AT1")
  }

  @Test func aDrainedStoreIsAuthExpired() async throws {
    // Post-logout / pre-seed: nothing to authenticate with is the same verdict as a dead
    // refresh token, and no request is attempted.
    MockURLProtocol.set(json: #"{"ticket":"T1CKET"}"#)
    await #expect(throws: GatewayError.authExpired) {
      _ = try await wsTicket(baseURL: baseURL, tokenStore: BearerTokenStore(), session: mockSession)
    }
    #expect(MockURLProtocol.requests.isEmpty)
  }

  @Test func bearerMintMapsTheTicketEndpointsVerdicts() async throws {
    let store = await freshStore(expiresAt: 1_000_600)

    // A 401 on the mint itself (the gateway rejected a token we believed fresh) is the
    // non-retryable verdict, same as the cookie regime's dead-session 401.
    MockURLProtocol.set(status: 401)
    await #expect(throws: GatewayError.authExpired) {
      _ = try await wsTicket(baseURL: baseURL, tokenStore: store, session: mockSession)
    }

    // Anything else is transient → backoff re-dials and re-mints.
    MockURLProtocol.set(status: 500)
    await #expect(throws: GatewayError.ticketUnavailable) {
      _ = try await wsTicket(baseURL: baseURL, tokenStore: store, session: mockSession)
    }

    // A 2xx whose body isn't a ticket is transient too, never a silent empty ticket.
    MockURLProtocol.set(json: #"{"nope":1}"#)
    await #expect(throws: GatewayError.ticketUnavailable) {
      _ = try await wsTicket(baseURL: baseURL, tokenStore: store, session: mockSession)
    }
  }

  /// Regression guard: the cookie mint is unchanged by the bearer split — same POST, and
  /// still NO auth header (the jar carries it).
  @Test func theCookieMintStillSendsNoAuthHeader() async throws {
    MockURLProtocol.set(json: #"{"ticket":"C00KIE"}"#)
    let cookieSession = CookieSession(
      cookies: [SerializedCookie(name: "hermes_session_at", value: "abc", domain: "test.local", path: "/")],
      username: "alice", provider: "basic"
    )

    let ticket = try await wsTicket(
      baseURL: baseURL, cookieSession: cookieSession, session: mockSession
    )
    #expect(ticket == "C00KIE")

    let req = try #require(MockURLProtocol.lastRequest)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.path == "/api/auth/ws-ticket")
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
  }
}
} // extension RESTTransportSuite
