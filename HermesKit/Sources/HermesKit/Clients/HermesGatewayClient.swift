import ComposableArchitecture
import DependenciesMacros
import Foundation

// MARK: - Client

/// The live wire to the Hermes gateway: a single WebSocket carrying newline-delimited
/// JSON-RPC 2.0. `connect` opens the socket and yields decoded server events; `send`
/// issues a request and awaits its `{id,result}` via an internal pending-request map.
@DependencyClient
public struct HermesGatewayClient: Sendable {
  /// Open a connection to the server (base URL + auth regime) and stream decoded events.
  /// The stream finishes when the socket closes or the consumer stops iterating.
  ///
  /// The transport branches on `AuthSession`:
  /// - `.token` → `…/api/ws?token=<token>` (byte-identical to the legacy path).
  /// - `.cookie` → mint a fresh single-use `?ticket=` via `POST /api/auth/ws-ticket`
  ///   (cookie-authed) per connect, then `…/api/ws?ticket=<ticket>`. A `401` from the
  ///   ticket mint means the session is fully dead → the stream yields `.authExpired` and
  ///   finishes (a non-retryable signal the reducer turns into re-auth, not backoff).
  public var connect: @Sendable (_ baseURL: URL, _ auth: AuthSession) -> AsyncStream<GatewayEvent> = { _, _ in
    AsyncStream { $0.finish() }
  }
  /// Send a JSON-RPC request on the current connection and await its result.
  public var send: @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
  /// Tear down the current connection.
  public var disconnect: @Sendable () -> Void
}

public enum GatewayError: Error, Equatable, Sendable {
  case notConnected
  case disconnected
  case server(String)
  case timedOut(method: String)
  /// The gated `ws-ticket` mint returned `401` — the cookie session is fully dead and
  /// reconnecting won't help. Surfaced as `GatewayEvent.authExpired` on the stream.
  case authExpired
  /// The `ws-ticket` mint failed transiently (network/5xx/non-401): the consumer should
  /// fall back to the existing reconnect backoff, exactly as for a dropped socket.
  case ticketUnavailable

  public var message: String {
    switch self {
    case .notConnected: "Not connected."
    case .disconnected: "Connection lost."
    case let .server(message): message
    case let .timedOut(method): "request timed out: \(method)"
    case .authExpired: "Your session expired. Sign in again."
    case .ticketUnavailable: "Couldn’t obtain a connection ticket."
    }
  }

  /// True when the server rejected the request as an unknown JSON-RPC method (`-32601`).
  /// `InboundFrame` keeps only the error message, not the code, so we match the server's
  /// stable `"unknown method: <name>"` text — used to gate attachment uploads (#8).
  public var isUnknownMethod: Bool {
    if case let .server(message) = self {
      return message.lowercased().hasPrefix("unknown method")
    }
    return false
  }

  /// True when the socket dropped (no transport) — distinct from a server-side protocol
  /// error. A dropped socket is already surfaced by the reducer's `.reconnecting` status, so
  /// callers can avoid raising a redundant "Connection lost." banner that would linger past
  /// the reconnect.
  public var isDisconnected: Bool {
    if case .disconnected = self { return true }
    return false
  }

  /// True when the server rejected the request because the live runtime session id is stale
  /// (e.g. after a background→foreground the agent rebuilt/invalidated the in-memory session).
  /// `InboundFrame` keeps only the error message, so we match the server's stable
  /// `"session not found"` text (case-insensitive) — used to self-heal outbound RPCs by
  /// transparently re-resuming for a fresh live id and replaying the call (#17). Mirrors
  /// `isUnknownMethod`.
  public var isSessionNotFound: Bool {
    if case let .server(message) = self {
      return message.lowercased().contains("session not found")
    }
    return false
  }
}

// MARK: - Live / factory

public extension HermesGatewayClient {
  static func live(
    session: URLSession = URLSession(configuration: .default),
    requestTimeout: Duration = .seconds(30)
  ) -> HermesGatewayClient {
    .make(
      requestTimeout: requestTimeout,
      mintTicket: { baseURL, cookieSession in
        try await wsTicket(baseURL: baseURL, cookieSession: cookieSession, session: session)
      },
      makeTransport: { wsURL in
        URLSessionWebSocketTransport(url: wsURL, session: session)
      }
    )
  }

  /// Core factory parameterized by a transport-maker (keyed on the **resolved** WS URL) and
  /// a ticket-minter so tests can inject both a fake socket and a fake ticket endpoint. The
  /// connection state (id counter, pending map) lives in a per-connect `GatewayConnection`
  /// actor; `store` holds the current one for `send`/`disconnect`.
  ///
  /// `clock` drives the per-request timeout — injectable so tests can use a `TestClock`
  /// and fire/hold the timeout deterministically instead of racing real wall-clock time.
  ///
  /// For `.cookie` auth, `connect` mints a fresh ws-ticket **per connect** (never cached) and
  /// connects with `?ticket=`. `.token` auth skips the mint entirely and uses `?token=`,
  /// byte-identical to the legacy path. A `401` from the mint (`GatewayError.authExpired`)
  /// yields `.authExpired` and finishes the stream; any other mint failure finishes the
  /// stream like a dropped socket so the reducer's existing backoff retries.
  static func make(
    requestTimeout: Duration = .seconds(30),
    clock: any Clock<Duration> = ContinuousClock(),
    mintTicket: @escaping @Sendable (_ baseURL: URL, _ cookieSession: CookieSession) async throws -> String = { _, _ in
      throw GatewayError.ticketUnavailable
    },
    makeTransport: @escaping @Sendable (_ wsURL: URL) -> any WebSocketTransport
  ) -> HermesGatewayClient {
    let store = ConnectionStore()
    return HermesGatewayClient(
      connect: { baseURL, auth in
        let (stream, continuation) = AsyncStream<GatewayEvent>.makeStream()
        // The connection opened by this `connect` (set once the transport is built). Held in
        // a box so the single `onTermination` handler can shut it down — `onTermination` is
        // last-writer-wins, so we must NOT overwrite it per-open (that clobbers cleanup).
        let opened = LockIsolated<GatewayConnection?>(nil)
        // Open a connection over the resolved WS URL: build the transport + connection
        // actor, register it for `send`/`disconnect`, and start the receive loop.
        @Sendable func open(_ wsURL: URL) {
          let connection = GatewayConnection(
            transport: makeTransport(wsURL),
            events: continuation,
            requestTimeout: requestTimeout,
            clock: clock
          )
          store.set(connection)
          opened.setValue(connection)
          Task { await connection.start() }
        }
        switch auth {
        case let .token(token):
          // Token mode: no async work — open synchronously so an immediate `send` finds the
          // connection (byte-identical to the legacy path). No setup task to cancel.
          open(webSocketURL(base: baseURL, token: token))
          // Single termination handler: shut down the opened connection on consumer cancel.
          continuation.onTermination = { _ in
            if let connection = opened.value { Task { await connection.shutdown() } }
          }
        case let .cookie(cookieSession):
          // Cookie mode: mint a fresh single-use ticket first. Done in a Task because
          // `connect` returns the stream synchronously; mint failures surface on the stream.
          let setupTask = Task {
            do {
              let ticket = try await mintTicket(baseURL, cookieSession)
              // The mint awaited above; if the consumer cancelled meanwhile, the termination
              // handler already ran (and saw no `opened` connection). Bail before `open()` so
              // we don't spawn an orphan connection nothing will ever shut down.
              try Task.checkCancellation()
              open(webSocketURL(base: baseURL, ticket: ticket))
            } catch is CancellationError {
              continuation.finish()
            } catch GatewayError.authExpired {
              // Session fully dead → non-retryable. Signal re-auth and finish.
              continuation.yield(.authExpired)
              continuation.finish()
            } catch {
              // Transient mint failure → finish like a dropped socket; the reducer's
              // backoff re-calls `connect` (which re-mints the ticket).
              continuation.finish()
            }
          }
          // Single termination handler composing BOTH cleanups (last-writer-wins, so we can
          // only register one): cancel the in-flight mint AND shut down a connection that has
          // already opened. Either may be the live one depending on the cancel timing.
          continuation.onTermination = { _ in
            setupTask.cancel()
            if let connection = opened.value { Task { await connection.shutdown() } }
          }
        }
        return stream
      },
      send: { method, params in
        guard let connection = store.get() else { throw GatewayError.notConnected }
        return try await connection.send(method: method, params: params)
      },
      disconnect: {
        let connection = store.get()
        store.set(nil)
        Task { await connection?.shutdown() }
      }
    )
  }
}

extension HermesGatewayClient: DependencyKey {
  public static var liveValue: HermesGatewayClient { .live() }
  public static var testValue: HermesGatewayClient { HermesGatewayClient() }
}

public extension DependencyValues {
  var hermesGateway: HermesGatewayClient {
    get { self[HermesGatewayClient.self] }
    set { self[HermesGatewayClient.self] = newValue }
  }
}

// MARK: - Connection actor

/// Owns one socket's lifecycle: the JSON-RPC id counter, the pending-request map, and
/// the receive loop that routes frames to either the event stream or a waiting `send`.
actor GatewayConnection {
  private let transport: any WebSocketTransport
  private let events: AsyncStream<GatewayEvent>.Continuation
  private let requestTimeout: Duration
  private let clock: any Clock<Duration>
  private var idCounter = 0
  private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
  private var timeoutTasks: [Int: Task<Void, Never>] = [:]
  private var receiveTask: Task<Void, Never>?
  private var isFinished = false

  init(
    transport: any WebSocketTransport,
    events: AsyncStream<GatewayEvent>.Continuation,
    requestTimeout: Duration = .seconds(30),
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.transport = transport
    self.events = events
    self.requestTimeout = requestTimeout
    self.clock = clock
  }

  func start() {
    guard receiveTask == nil else { return }
    receiveTask = Task { [weak self] in await self?.receiveLoop() }
  }

  func send(method: String, params: JSONValue) async throws -> JSONValue {
    // Never register against a torn-down connection — that continuation would
    // never be resumed (the receive loop is gone), hanging the caller forever.
    guard !isFinished else { throw GatewayError.disconnected }
    idCounter += 1
    let id = idCounter
    let request = JSONRPCRequest(id: id, method: method, params: params)
    let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    return try await withCheckedThrowingContinuation { continuation in
      // Register before transmitting so a fast response can't race ahead of us.
      pending[id] = continuation
      // Per-id timeout: if the server never acks (`prompt.submit` acks fast, so this
      // only catches a stuck server), reject with `.timedOut` rather than hang forever.
      timeoutTasks[id] = Task { [requestTimeout, clock] in
        do { try await clock.sleep(for: requestTimeout) } catch { return }
        await fireTimeout(id: id, method: method)
      }
      Task { await transmit(id: id, text: text) }
    }
  }

  /// Called from the per-id timeout task after the sleep elapses. Resumes the waiter
  /// with `.timedOut` only if it removes the pending entry itself; if another path
  /// (response/failure/finish) already won, the entry is gone and this is a no-op.
  private func fireTimeout(id: Int, method: String) {
    timeoutTasks.removeValue(forKey: id)
    pending.removeValue(forKey: id)?.resume(throwing: GatewayError.timedOut(method: method))
  }

  func shutdown() {
    guard !isFinished else { return }
    receiveTask?.cancel()
    transport.cancel()
    finish(error: .disconnected)
  }

  private func transmit(id: Int, text: String) async {
    do {
      try await transport.send(text)
    } catch {
      cancelTimeout(id)
      pending.removeValue(forKey: id)?.resume(throwing: error)
    }
  }

  /// Cancel and drop the timeout task for `id` so it can't fire a spurious `.timedOut`
  /// after the request has already resolved (and doesn't leak).
  private func cancelTimeout(_ id: Int) {
    timeoutTasks.removeValue(forKey: id)?.cancel()
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      let text: String
      do {
        text = try await transport.receive()
      } catch {
        break // socket closed or errored
      }
      // A single WS message may carry multiple newline-delimited frames.
      for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        handle(frame: String(line))
      }
    }
    finish(error: .disconnected)
  }

  private func handle(frame: String) {
    guard let parsed = try? InboundFrame(data: Data(frame.utf8)) else { return }
    switch parsed {
    case let .event(_, event):
      events.yield(event)
    case let .response(id, result):
      cancelTimeout(id)
      pending.removeValue(forKey: id)?.resume(returning: result)
    case let .failure(id, message):
      if let id {
        cancelTimeout(id)
        pending.removeValue(forKey: id)?.resume(throwing: GatewayError.server(message))
      }
    case .ignored:
      break
    }
  }

  private func finish(error: GatewayError) {
    guard !isFinished else { return }
    isFinished = true
    events.finish()
    for (_, task) in timeoutTasks { task.cancel() }
    timeoutTasks.removeAll()
    let outstanding = pending
    pending.removeAll()
    for (_, continuation) in outstanding { continuation.resume(throwing: error) }
  }
}

/// Holds the current connection so the stateless client closures can reach it.
private final class ConnectionStore: @unchecked Sendable {
  private let lock = NSLock()
  private var current: GatewayConnection?
  func set(_ connection: GatewayConnection?) { lock.withLock { current = connection } }
  func get() -> GatewayConnection? { lock.withLock { current } }
}

// MARK: - Transport

/// The minimal socket surface the connection needs. Abstracted so tests can swap in a
/// fake without a real network.
public protocol WebSocketTransport: Sendable {
  func send(_ text: String) async throws
  func receive() async throws -> String
  func cancel()
}

final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
  private let task: URLSessionWebSocketTask

  init(url: URL, session: URLSession) {
    task = session.webSocketTask(with: url)
    task.resume()
  }

  func send(_ text: String) async throws {
    try await task.send(.string(text))
  }

  func receive() async throws -> String {
    switch try await task.receive() {
    case let .string(text): return text
    case let .data(data): return String(decoding: data, as: UTF8.self)
    @unknown default: return ""
    }
  }

  func cancel() {
    task.cancel(with: .goingAway, reason: nil)
  }
}

/// Token-mode WS URL — **byte-identical to the legacy path** (`…/api/ws?token=<token>`).
/// A `nil` token omits the query entirely (the unauthenticated probe case).
func webSocketURL(base: URL, token: String?) -> URL {
  webSocketURL(base: base, query: token.map { [URLQueryItem(name: "token", value: $0)] })
}

/// Gated-mode WS URL — `…/api/ws?ticket=<ticket>` from a freshly minted single-use ticket.
func webSocketURL(base: URL, ticket: String) -> URL {
  webSocketURL(base: base, query: [URLQueryItem(name: "ticket", value: ticket)])
}

private func webSocketURL(base: URL, query: [URLQueryItem]?) -> URL {
  var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
  comps.scheme = (comps.scheme == "https" || comps.scheme == "wss") ? "wss" : "ws"
  comps.path = "/api/ws"
  comps.queryItems = query
  return comps.url ?? base
}

// MARK: - ws-ticket mint

/// Decoded `POST /api/auth/ws-ticket` response — the gateway returns the single-use ticket
/// under `ticket` (verified against the Hermes web server). Lenient: nothing else is read.
private struct WSTicketResponse: Decodable { let ticket: String }

/// Mint a single-use WS ticket for a gated (cookie) session via `POST /api/auth/ws-ticket`.
/// The cookie jar authenticates the request; we rehydrate the persisted `CookieSession`
/// into the live session's storage first so a fresh launch authenticates. A `401` (session
/// fully dead) maps to `GatewayError.authExpired` (non-retryable); any other failure maps
/// to `GatewayError.ticketUnavailable` (transient → reducer backoff retries).
func wsTicket(baseURL: URL, cookieSession: CookieSession, session: URLSession) async throws -> String {
  // Rehydrate cookies so a relaunched app (empty jar) still authenticates the mint.
  if let storage = session.configuration.httpCookieStorage {
    for cookie in cookieSession.cookies.compactMap(\.httpCookie) { storage.setCookie(cookie) }
  }
  var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
  comps.path = "/api/auth/ws-ticket"
  guard let url = comps.url else { throw GatewayError.ticketUnavailable }
  var request = URLRequest(url: url)
  request.httpMethod = "POST"

  let data: Data
  let response: URLResponse
  do {
    (data, response) = try await session.data(for: request)
  } catch {
    throw GatewayError.ticketUnavailable
  }
  guard let http = response as? HTTPURLResponse else { throw GatewayError.ticketUnavailable }
  if http.statusCode == 401 { throw GatewayError.authExpired }
  guard (200..<300).contains(http.statusCode) else { throw GatewayError.ticketUnavailable }
  guard let decoded = try? JSONDecoder().decode(WSTicketResponse.self, from: data) else {
    throw GatewayError.ticketUnavailable
  }
  return decoded.ticket
}
