import ComposableArchitecture
import Foundation
import Network

// The loopback half of the RFC 8252 native-app flow: the gateway only accepts a
// `http://127.0.0.1[:port]/…` `redirect_uri`, so the app itself serves that URL for the
// duration of one sign-in. `Network` is available on macOS too, so this whole file is
// OUTSIDE any `#if canImport(UIKit)` guard and its behaviour is covered by `swift test`.
//
// Constraints come from the Task 1 spike (docs/features/oauth-sign-in.md → "Spike outcome"):
// bind IPv4 (a listener bound to one address family does not serve the other), answer EVERY
// connection — the IPv6 leg produced four speculative TCP opens with no request line before
// the real `GET /callback` — and never treat a blank/unparseable request as an error.

// MARK: - Pure request parsing

/// How far into a connection's bytes the request line is looked for. `parseRequestTarget`
/// scans no further, so the accumulate loop in `receiveRequestHead` must stop here too:
/// reading past it would only buffer bytes the parser will never see.
private let maxRequestLineBytes = 8 * 1024

/// How much one `NWConnection.receive` may take at a time.
private let receiveChunkBytes = 16 * 1024

/// The request target of an HTTP/1.1 request head — `/callback?code=…&state=…` — or `nil`
/// when these bytes aren't a request line at all.
///
/// `nil` covers every incidental connection the spike saw: a zero-byte speculative open, a
/// truncated head, anything that isn't `<METHOD> <target> HTTP/x.y`. Callers answer those
/// with the same page and simply don't settle the flow on them. Pure (no `Network` types)
/// so it is unit-tested on macOS.
func parseRequestTarget(_ bytes: Data) -> String? {
  guard !bytes.isEmpty else { return nil }
  // Split on the raw CR/LF OCTETS, not on `Character`s: Swift treats "\r\n" as a single
  // grapheme cluster that equals neither "\r" nor "\n", so a character-based split would
  // never find the end of a CRLF request line. Capped so a hostile client can't hand us a
  // multi-megabyte "line" to scan.
  let lineBytes = bytes.prefix(maxRequestLineBytes).prefix { $0 != 0x0D && $0 != 0x0A }
  guard !lineBytes.isEmpty else { return nil }
  let line = String(decoding: lineBytes, as: UTF8.self)
  let parts = line.split(separator: " ", omittingEmptySubsequences: true)
  guard parts.count == 3 else { return nil }
  let method = parts[0], target = parts[1], version = parts[2]
  guard !method.isEmpty, method.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return nil }
  guard version.hasPrefix("HTTP/"), target.hasPrefix("/") else { return nil }
  return String(target)
}

/// The page every loopback request is answered with — including the ones that aren't the
/// callback, so a stray probe never leaves a hung tab. Deliberately tiny, self-contained,
/// and free of anything the browser would have to fetch (no favicon, no CSS file).
let loopbackSignedInPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Hermes</title>\
<meta name="viewport" content="width=device-width, initial-scale=1"></head>\
<body style="font: -apple-system-body, system-ui; padding: 2rem; text-align: center">\
<h1>Signed in to Hermes</h1><p>You can close this window and return to the app.</p>\
</body></html>
"""

/// A complete `200 OK` HTTP/1.1 response carrying `html`. `Connection: close` because each
/// loopback connection serves exactly one request.
func loopbackHTTPResponse(html: String) -> Data {
  let body = Data(html.utf8)
  let head = "HTTP/1.1 200 OK\r\n"
    + "Content-Type: text/html; charset=utf-8\r\n"
    + "Content-Length: \(body.count)\r\n"
    + "Connection: close\r\n"
    + "\r\n"
  return Data(head.utf8) + body
}

// MARK: - Session handle

/// A bound loopback listener, reduced to the three things the login driver needs. A value
/// type (not a protocol) so tests substitute it with a plain fake — same seam style as the
/// `@DependencyClient` structs elsewhere in this package.
struct LoopbackCallbackSession: Sendable {
  /// `http://127.0.0.1:<port>/callback` — what goes on the wire as `redirect_uri`.
  var redirectURI: String
  /// Every request target the listener saw, in arrival order (callbacks AND probes — the
  /// driver decides which one settles via `isLoopbackCallback`). Finishes when the
  /// listener stops or dies, which the driver reads as "no callback is coming".
  var targets: AsyncStream<String>
  /// Idempotent teardown.
  var stop: @Sendable () -> Void
}

// MARK: - Listener

/// A single-use HTTP listener on `127.0.0.1` for the OAuth callback.
final class LoopbackCallbackListener: @unchecked Sendable {
  private struct State {
    var listener: NWListener?
    var connections: [NWConnection] = []
    var continuation: AsyncStream<String>.Continuation?
    var isStopped = false
  }

  /// `NWListener`/`NWConnection` are not `Sendable`; the lock (not the callback queue) is
  /// what makes the state safe, since `stop()` can arrive from any task.
  private let state = LockIsolated(State())
  private let queue = DispatchQueue(label: "me.honcharenko.HermesKit.loopback-callback")
  private static let responseData = loopbackHTTPResponse(html: loopbackSignedInPage)

  init() {}

  deinit { stop() }

  /// Bind an ephemeral port on `127.0.0.1` and start serving.
  ///
  /// Throws `OAuthLoginError.listenerFailed` when the socket can't be bound — the login
  /// driver turns that into user-facing copy, so no `Network` error type escapes this file.
  func start() async throws -> LoopbackCallbackSession {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    state.withValue { $0.continuation = continuation }
    let port = try await bind()
    return LoopbackCallbackSession(
      redirectURI: "http://127.0.0.1:\(port)/callback",
      targets: stream,
      // Strong capture BY DESIGN: the session handle is the only thing the driver holds, so
      // it has to keep the listener alive for the length of the flow.
      stop: { [self] in stop() }
    )
  }

  /// Cancel the socket, drop every in-flight connection, and finish the target stream.
  /// Safe to call twice (the driver stops on the happy path and again in a `defer`).
  func stop() {
    let torn = state.withValue { current -> (NWListener?, [NWConnection], AsyncStream<String>.Continuation?)? in
      guard !current.isStopped else { return nil }
      current.isStopped = true
      defer {
        current.listener = nil
        current.connections = []
        current.continuation = nil
      }
      return (current.listener, current.connections, current.continuation)
    }
    guard let torn else { return }
    torn.0?.cancel()
    for connection in torn.1 { connection.cancel() }
    torn.2?.finish()
  }

  // MARK: - Internals

  private func bind() async throws -> UInt16 {
    let resumed = LockIsolated(false)
    return try await withCheckedThrowingContinuation { continuation in
      // `NWListener` reports readiness and failure through the same handler and can report
      // more than once; resume exactly once.
      let settle: @Sendable (Result<UInt16, any Error>) -> Void = { result in
        let alreadyResumed = resumed.withValue { flag -> Bool in
          defer { flag = true }
          return flag
        }
        guard !alreadyResumed else { return }
        continuation.resume(with: result)
      }
      do {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // IPv4 ONLY, matching the advertised `127.0.0.1` redirect URI: the spike confirmed
        // a listener bound to one family does not serve the other.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        state.withValue { $0.listener = listener }
        listener.stateUpdateHandler = { [weak self] newState in
          switch newState {
          case .ready:
            guard let port = listener.port?.rawValue, port != 0 else {
              settle(.failure(OAuthLoginError.listenerFailed))
              return
            }
            settle(.success(port))
          case .failed, .cancelled:
            settle(.failure(OAuthLoginError.listenerFailed))
            // A socket that dies mid-flow must end the stream, or the driver would wait out
            // its whole timeout for a callback that can never arrive.
            self?.stop()
          default:
            break
          }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
      } catch {
        settle(.failure(OAuthLoginError.listenerFailed))
      }
    }
  }

  private func handle(_ connection: NWConnection) {
    let accepted = state.withValue { current -> Bool in
      guard !current.isStopped else { return false }
      current.connections.append(connection)
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    receiveRequestHead(connection, accumulated: Data())
  }

  /// Read until the request LINE is complete, then answer and report it.
  ///
  /// TCP does not promise the head arrives in one segment: a single `receive` that lands
  /// mid-request-line parses to `nil`, and the connection would then be answered, closed and
  /// never reported — the driver would wait out its whole 300 s budget for a callback that
  /// already arrived. So keep reading until a CR/LF terminates the line (or
  /// `maxRequestLineBytes` is reached, or the peer closes/errors).
  private func receiveRequestHead(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkBytes) {
      [weak self] data, _, isComplete, error in
      var buffer = accumulated
      if let data { buffer.append(data) }
      let sawLineEnd = buffer.contains { $0 == 0x0D || $0 == 0x0A }
      if !sawLineEnd, buffer.count < maxRequestLineBytes, !isComplete, error == nil {
        self?.receiveRequestHead(connection, accumulated: buffer)
        return
      }
      // Answer EVERY connection — callback, favicon probe, or a speculative open that sent
      // nothing at all — then close it. Only a parseable request line is reported onward.
      connection.send(
        content: Self.responseData,
        completion: .contentProcessed { _ in connection.cancel() }
      )
      guard let self, let target = parseRequestTarget(buffer) else { return }
      yield(target)
    }
  }

  private func yield(_ target: String) {
    let continuation = state.withValue { $0.isStopped ? nil : $0.continuation }
    continuation?.yield(target)
  }
}
