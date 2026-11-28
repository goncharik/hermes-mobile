import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ConnectionFailedFeatureTests {
  private let url = URL(string: "http://mac.tailnet:9119")!

  private var connection: ServerConnection {
    ServerConnection(baseURL: url, token: "tok")
  }

  private var cookieConnection: ServerConnection {
    ServerConnection(
      baseURL: url,
      auth: .cookie(
        CookieSession(
          cookies: [SerializedCookie(name: "hermes_session", value: "abc", domain: "mac.tailnet", path: "/")],
          username: "eugene",
          provider: "basic"
        )
      )
    )
  }

  private func state(
    connection: ServerConnection? = nil,
    reason: RESTError = .unreachable,
    isRetrying: Bool = false
  ) -> ConnectionFailedFeature.State {
    ConnectionFailedFeature.State(
      connection: connection ?? self.connection, reason: reason, isRetrying: isRetrying
    )
  }

  // MARK: - Display

  @Test func displayStringsNameTheServerAndTheReason() {
    let offline = state(reason: .offline)
    #expect(offline.serverURLText == "http://mac.tailnet:9119")
    #expect(
      offline.reasonText
        == "You appear to be offline. Check Wi-Fi or cellular data and try again."
    )

    let unreachable = state(reason: .unreachable)
    #expect(
      unreachable.reasonText
        == "The server didn’t respond. If it’s on a private network (VPN/Tailscale), make sure that connection is on."
    )
  }

  /// Every non-transport reason that can reach the screen gets its OWN copy — telling a user
  /// whose reverse proxy answered 502 (or whose captive portal answered HTML) to check their
  /// VPN would send them hunting in the wrong place.
  @Test func serverSideReasonsGetTheirOwnCopy() {
    #expect(state(reason: .server(status: 502)).reasonText.contains("HTTP 502"))
    #expect(state(reason: .server(status: 500)).reasonText.contains("HTTP 500"))
    #expect(state(reason: .serviceUnavailable).reasonText.contains("isn’t answering"))
    #expect(state(reason: .notFound).reasonText.contains("HTTP 404"))
    #expect(state(reason: .rateLimited).reasonText.contains("HTTP 429"))
    #expect(state(reason: .decoding).reasonText.contains("Wi-Fi sign-in page"))
    // Copy must never inherit the VPN advice by accident.
    for reason: RESTError in [.server(status: 500), .notFound, .rateLimited, .decoding] {
      #expect(!state(reason: reason).reasonText.contains("VPN"))
    }
    // The one reason that can't be routed here still renders honestly if routing changes.
    #expect(state(reason: .unauthorized).reasonText == RESTError.unauthorized.message)
  }

  /// A 5xx and a 4xx mean opposite things, so they must not share copy. A 5xx is the server
  /// faulting on a request it accepted — a retry may genuinely clear it. A 4xx is the server
  /// REFUSING, identically, forever: telling that user to "try again in a moment" is the one
  /// piece of advice guaranteed not to work.
  @Test func serverStatusCopySplits4xxFrom5xx() {
    for status in [500, 502, 503, 504, 599] {
      let text = state(reason: .server(status: status)).reasonText
      #expect(text.contains("HTTP \(status)"))
      #expect(text.contains("try again in a moment"))
      #expect(!text.contains("refused"))
    }
    for status in [400, 405, 407, 418, 451] {
      let text = state(reason: .server(status: status)).reasonText
      #expect(text.contains("HTTP \(status)"))
      #expect(text.contains("refused the request"))
      #expect(text.contains("retrying won’t change that"))
      #expect(!text.contains("try again in a moment"))
    }
  }

  /// The motivating case: the agent's own `host_header_middleware` answers **every** request
  /// with a 400 when it was restarted without `--host 0.0.0.0`, and its `detail` is the only
  /// actionable sentence in the whole failure. Discarding it (as the first cut did) left the
  /// user with generic "may be down or restarting" copy and nothing to act on.
  @Test func fourXXSurfacesTheServersOwnDetail() {
    let hostHeader =
      "Invalid Host header. Dashboard requests must use the hostname the server was bound to."
    let text = state(reason: .server(status: 400, detail: hostHeader)).reasonText
    #expect(text.contains(hostHeader))
    #expect(text.contains("HTTP 400"))

    // Whitespace-only / empty details fall back to the generic 4xx line rather than
    // rendering empty quotes.
    for detail: String? in [nil, "", "   \n "] {
      let fallback = state(reason: .server(status: 400, detail: detail)).reasonText
      #expect(fallback.contains("Check the agent’s setup"))
      #expect(!fallback.contains("“"))
    }

    // A 5xx detail is NOT surfaced — proxies put HTML error pages in there, and the 5xx
    // advice ("wait") is already correct without it.
    let fiveXX = state(reason: .server(status: 502, detail: "<html>Bad Gateway</html>"))
    #expect(!fiveXX.reasonText.contains("<html>"))
  }

  /// The transient 4xx statuses genuinely reach this screen as a bare `.server(status:)` —
  /// `validate` only maps 429/503 onto their own cases for the login-specific call, and the
  /// launch/retry probe is a plain `get`. A reverse proxy's `limit_req` 429 is retry-fixable,
  /// so telling that user "retrying won’t change that" is the one piece of advice guaranteed
  /// to be wrong on the one screen whose job is to advise correctly.
  @Test func transientFourXXStatusesGetTryAgainCopy() {
    for status in [408, 425, 429] {
      let text = state(reason: .server(status: status, detail: "slow down")).reasonText
      #expect(text.contains("HTTP \(status)"))
      #expect(text.contains("Try again in a moment"))
      #expect(!text.contains("refused the request"))
      #expect(!text.contains("retrying won’t change that"))
      // The detail is irrelevant when the advice is "wait" — don't quote a rate limiter.
      #expect(!text.contains("slow down"))
    }
  }

  /// A status in neither band (an unfollowed 3xx, a bogus code) must not inherit either
  /// band's copy: "it may be down or restarting" for a 302 is a guess stated as fact.
  @Test func outOfBandStatusesGetNeutralCopy() {
    for status in [302, 307, 100, 600] {
      let text = state(reason: .server(status: status, detail: "moved")).reasonText
      #expect(text.contains("HTTP \(status)"))
      #expect(!text.contains("refused the request"))
      #expect(!text.contains("down or restarting"))
      #expect(text.contains("Try again in a moment"))
    }
  }

  /// `serverDetail(from:)` falls back to the ENTIRE trimmed response body when a non-2xx
  /// carries no JSON `detail`, and a 4xx from an nginx/Cloudflare/captive-portal intermediary
  /// is a whole HTML document. The reason line sits ABOVE this screen's escape routes
  /// inside a `ScrollView`, so quoting that verbatim pushes Retry / Log Out far below the fold — and dumps whatever the proxy put in its body (internal hostnames,
  /// stack traces) onto a screen a stuck user is likely to screenshot.
  @Test func fourXXDetailIsClampedAndMarkupIsDropped() {
    // An HTML page is never an actionable sentence — drop it and use the generic line.
    for html in [
      "<html><body><h1>400 Bad Request</h1><hr><center>nginx/1.24.0</center></body></html>",
      "<!DOCTYPE html>\n<html>The plain HTTP request was sent to HTTPS port</html>",
      "  \n <?xml version=\"1.0\"?><error/>",
    ] {
      let text = state(reason: .server(status: 400, detail: html)).reasonText
      #expect(text.contains("Check the agent’s setup"))
      #expect(!text.contains("<"))
      #expect(!text.contains("nginx"))
    }

    // Only the first line survives — a multi-line body is a log, not a sentence.
    let multiline = state(
      reason: .server(status: 400, detail: "Invalid Host header.\nTraceback:\n  at line 12")
    ).reasonText
    #expect(multiline.contains("“Invalid Host header.”"))
    #expect(!multiline.contains("Traceback"))

    // A single very long line is truncated with an ellipsis, well inside a screenful.
    let long = String(repeating: "x", count: 5_000)
    let clamped = state(reason: .server(status: 400, detail: long)).reasonText
    #expect(clamped.count < 400)
    #expect(clamped.contains("x…”"))
    #expect(!clamped.contains(long))

    // The good case still passes through untouched (the motivating host-header 400).
    let hostHeader =
      "Invalid Host header. Dashboard requests must use the hostname the server was bound to."
    #expect(hostHeader.count <= ConnectionFailedFeature.State.maxServerDetailLength)
    #expect(state(reason: .server(status: 400, detail: hostHeader)).reasonText.contains(hostHeader))
  }

  /// The single routing rule, pinned: ONLY a credentials verdict (401/403) leaves the screen.
  /// A stored connection was a working agent when it was saved, so anything else — a 500, a
  /// 404, a captive portal's HTML — says the network or the server changed, not the password.
  @Test func isRetryablePinsTheRoutingRule() {
    #expect(ConnectionFailedFeature.isRetryable(.offline))
    #expect(ConnectionFailedFeature.isRetryable(.unreachable))
    #expect(ConnectionFailedFeature.isRetryable(.serviceUnavailable))
    #expect(ConnectionFailedFeature.isRetryable(.server(status: 502)))
    #expect(ConnectionFailedFeature.isRetryable(.server(status: 503)))
    #expect(ConnectionFailedFeature.isRetryable(.server(status: 504)))
    #expect(ConnectionFailedFeature.isRetryable(.server(status: 500)))
    #expect(ConnectionFailedFeature.isRetryable(.notFound))
    #expect(ConnectionFailedFeature.isRetryable(.rateLimited))
    #expect(ConnectionFailedFeature.isRetryable(.decoding))
    #expect(ConnectionFailedFeature.isRetryable(.transcriptionFailed("x")))
    // The credentials verdicts — and ONLY those.
    #expect(!ConnectionFailedFeature.isRetryable(.unauthorized))
    #expect(!ConnectionFailedFeature.isRetryable(.server(status: 401)))
    #expect(!ConnectionFailedFeature.isRetryable(.server(status: 403)))
  }

  // MARK: - Retry

  @Test func retrySuccessDelegatesConnected() async {
    let probed = LockIsolated<[ServerConnection]>([])
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable connection in
        probed.withValue { $0.append(connection) }
      }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retrySucceeded) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
    // The probe must use the STORED connection (not a rebuilt/blank one) and the same probe
    // launch auto-connect uses — the delegate payload is built independently of it, so
    // nothing else would catch a probe against the wrong server.
    #expect(probed.value == [connection])
  }

  /// The headline #62 story is a PASSWORD-mode user: the cookie session must ride through the
  /// retry verbatim, never be rebuilt token-first.
  @Test func cookieSessionIsProbedAndDelegatedVerbatim() async {
    let probed = LockIsolated<ServerConnection?>(nil)
    let store = TestStore(initialState: state(connection: cookieConnection)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable connection in
        probed.setValue(connection)
      }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retrySucceeded) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(cookieConnection))
    #expect(probed.value == cookieConnection)
    #expect(probed.value?.auth.token == nil)
  }

  @Test func retryTransportFailureUpdatesReasonInPlace() async {
    let store = TestStore(initialState: state(reason: .unreachable)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in throw RESTError.offline }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryFailed) {
      $0.isRetrying = false
      $0.reason = .offline
      $0.details = "GET /api/sessions: device offline"
    }
  }

  /// The live probe's `ConnectionFailure` reaches Details verbatim (#193): the raw URLError
  /// code a Tailscale report needs, which `.unreachable` alone would have flattened away. The
  /// same line goes to the diagnostics log.
  @Test func retryFailureShowsTheRawCauseAndLogsIt() async {
    let logged = LockIsolated<[String]>([])
    let failure = ConnectionFailure(reason: .unreachable, detail: "GET /api/sessions: URLError -1001 timedOut")
    let store = TestStore(initialState: state(reason: .offline)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in throw failure }
      $0.debugLog.note = { @Sendable type, summary in logged.withValue { $0.append("\(type) \(summary)") } }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryFailed, failure) {
      $0.isRetrying = false
      $0.reason = .unreachable
      $0.details = "GET /api/sessions: URLError -1001 timedOut"
    }
    #expect(logged.value == ["connect.failed GET /api/sessions: URLError -1001 timedOut"])
  }

  /// A retry that reaches *something* which answers badly stays on the screen and just
  /// refreshes the reason — a proxy's "backend down", the agent's own 500, a vanished route,
  /// a rate limit and a captive portal's HTML are all server/network conditions, never a
  /// verdict on the saved sign-in.
  @Test(
    arguments: [
      RESTError.server(status: 502, detail: "no upstream"),
      .server(status: 500, detail: "boom"),
      .notFound,
      .rateLimited,
      .decoding,
    ]
  )
  func serverSideFailuresStayOnTheScreen(error: RESTError) async {
    let store = TestStore(initialState: state(reason: .unreachable)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in throw error }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryFailed) {
      $0.isRetrying = false
      $0.reason = error
      $0.details = "GET /api/sessions: \(ConnectionDiagnostics.cause(of: error))"
    }
  }

  @Test func retryAuthRejectionDelegatesCredentialsRejected() async {
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in throw RESTError.unauthorized }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryFailed) { $0.isRetrying = false }
    await store.receive(\.delegate, .credentialsRejected(connection))
  }

  /// A 403 is a credentials verdict too (`validate` only special-cases 401), so it leaves the
  /// screen exactly like `.unauthorized` — pinned so the routing decision stays deliberate.
  @Test(arguments: [RESTError.server(status: 403, detail: "forbidden"), .server(status: 401)])
  func credentialsVerdictsLeaveTheScreen(error: RESTError) async {
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in throw error }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryFailed) { $0.isRetrying = false }
    await store.receive(\.delegate, .credentialsRejected(connection))
  }

  @Test func retryNonRESTErrorIsTreatedAsUnreachable() async {
    struct Boom: Error {}
    let store = TestStore(initialState: state(reason: .offline)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in throw Boom() }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryFailed) {
      $0.isRetrying = false
      $0.reason = .unreachable
      $0.details = "GET /api/sessions: Boom" // the type name only, never its description
    }
  }

  /// A raw `URLError` from a client that didn't classify (a wrapper / a test double) must
  /// still reach `.offline` — `asRESTError` defers to the same `RESTError(transport:)` funnel
  /// the live client uses, so offline detection isn't tied to one implementation.
  @Test func retryRawOfflineURLErrorIsClassifiedOffline() async {
    let store = TestStore(initialState: state(reason: .unreachable)) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in
        throw URLError(.notConnectedToInternet)
      }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.receive(\.retryFailed) {
      $0.isRetrying = false
      $0.reason = .offline
      $0.details = "GET /api/sessions: URLError -1009 notConnectedToInternet"
    }
  }

  // MARK: - Foreground auto-retry

  @Test func sceneBecameActiveRetries() async {
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in }
    }

    await store.send(.sceneBecameActive) { $0.isRetrying = true }
    await store.receive(\.retrySucceeded) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
  }

  @Test func rapidTapsAreGuardedWhileOneIsInFlight() async {
    // Hold the probe open so the later sends genuinely land *mid-flight*.
    let (gate, release) = AsyncStream<Void>.makeStream()
    let probes = LockIsolated(0)
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in
        probes.withValue { $0 += 1 }
        for await _ in gate { break }
      }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    // A second tap landing mid-probe must change nothing and must not fan out a parallel probe.
    await store.send(.retryTapped)
    release.yield()
    release.finish()
    await store.receive(\.retrySucceeded) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
    #expect(probes.value == 1)
  }

  /// A foreground deliberately SUPERSEDES an in-flight probe rather than being swallowed:
  /// still exactly one probe at a time (one result lands, not two), but a probe whose result
  /// never arrives — `URLSession`'s default request timeout is 60s — can never brick the
  /// screen with a latched `isRetrying`.
  @Test func foregroundSupersedesAStalledProbe() async {
    let (stall, releaseStall) = AsyncStream<Void>.makeStream()
    let probes = LockIsolated(0)
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in
        let attempt = probes.withValue { value -> Int in
          value += 1
          return value
        }
        // The first probe never resolves; the foreground's probe answers immediately.
        if attempt == 1 { for await _ in stall { break } }
      }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.send(.sceneBecameActive)
    await store.receive(\.retrySucceeded) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
    #expect(probes.value == 2)
    // The stalled probe was cancelled, so nothing further ever lands (TestStore fails on an
    // unasserted trailing action).
    releaseStall.finish()
  }

  // MARK: - Logout

  /// Log Out wipes the keychain session, every pref and the chat cache — it confirms first,
  /// and only the confirmation delegates up.
  @Test func logoutConfirmsBeforeDelegatingUp() async {
    let store = TestStore(initialState: state()) { ConnectionFailedFeature() }

    await store.send(.logoutButtonTapped) { $0.confirmationDialog = anyLogoutDialog }
    await store.send(.confirmationDialog(.presented(.confirmLogout))) {
      $0.confirmationDialog = nil
    }
    await store.receive(\.delegate, .logoutConfirmed)
  }

  /// Dismissing the dialog abandons nothing.
  @Test func logoutCanBeCancelled() async {
    let store = TestStore(initialState: state()) { ConnectionFailedFeature() }

    await store.send(.logoutButtonTapped) { $0.confirmationDialog = anyLogoutDialog }
    await store.send(.confirmationDialog(.dismiss)) { $0.confirmationDialog = nil }
  }

  /// Log Out stays available while a probe is in flight — the view never disables it, and the
  /// reducer must honour it (a 60s probe must not trap the user on this screen).
  @Test func logoutWorksWhileAProbeIsInFlight() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: state()) {
      ConnectionFailedFeature()
    } withDependencies: {
      $0.hermesREST.validateConnection = { @Sendable _ in
        for await _ in gate { break }
      }
    }

    await store.send(.retryTapped) { $0.isRetrying = true }
    await store.send(.logoutButtonTapped) { $0.confirmationDialog = anyLogoutDialog }
    await store.send(.confirmationDialog(.presented(.confirmLogout))) {
      $0.confirmationDialog = nil
    }
    await store.receive(\.delegate, .logoutConfirmed)
    release.yield()
    release.finish()
    await store.receive(\.retrySucceeded) { $0.isRetrying = false }
    await store.receive(\.delegate, .connected(connection))
  }

  /// The dialog the reducer raises, spelled out ONCE for every test that asserts it — a copy
  /// edit is a one-line change here, not three.
  private var anyLogoutDialog: ConfirmationDialogState<ConnectionFailedFeature.Action.Dialog> {
    ConfirmationDialogState {
      TextState("Log out?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmLogout) {
        TextState("Log Out")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "This deletes the saved sign-in for this server along with pins, unread state and cached chats."
      )
    }
  }
}
