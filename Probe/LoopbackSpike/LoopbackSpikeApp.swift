// Task 1 spike (plan: docs/plans/20260905-oauth-native-pkce-sign-in.md).
//
// Question: can an `ASWebAuthenticationSession` browser redirect reach an `NWListener`
// the app itself holds on loopback? This harness is NOT part of any shipped target — it
// is built standalone by `run.sh` (swiftc + a hand-rolled .app bundle), never by Tuist.
//
// Flow: bind an ephemeral-port listener on loopback → open ASWebAuthenticationSession on
// a throwaway HTTP server (`redirect_server.py`) that 302s to the listener's callback URL
// → the listener answers every request with a tiny HTML page → on the first request that
// carries `code=` we `cancel()` the session and record what the completion handler gets.
//
// Everything interesting is appended to `Documents/spike.log` inside the app container so
// the driver script can read it back without parsing os_log.

import AuthenticationServices
import Network
import SwiftUI
import UIKit

// MARK: - Logging

private let logURL: URL = {
  let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  return dir.appendingPathComponent("spike.log")
}()

private let startedAt = Date()

func spikeLog(_ message: String) {
  let stamp = String(format: "%7.3f", Date().timeIntervalSince(startedAt))
  let line = "[\(stamp)] \(message)\n"
  print("SPIKE \(line)", terminator: "")
  guard let data = line.data(using: .utf8) else { return }
  if let handle = try? FileHandle(forWritingTo: logURL) {
    handle.seekToEndOfFile()
    handle.write(data)
    try? handle.close()
  } else {
    try? data.write(to: logURL)
  }
}

// MARK: - Loopback listener

enum LoopbackFamily: String {
  case ipv4
  case ipv6

  var host: NWEndpoint.Host {
    switch self {
    case .ipv4: .ipv4(.loopback)
    case .ipv6: .ipv6(.loopback)
    }
  }

  /// How the redirect URI spells the host (RFC 8252 §7.3 allows both literals).
  var uriHost: String {
    switch self {
    case .ipv4: "127.0.0.1"
    case .ipv6: "[::1]"
    }
  }
}

/// Minimal HTTP/1.1 server: answers EVERY request with the same page (favicon probes
/// included) and reports the request target of each one.
final class LoopbackListener {
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "spike.loopback")

  /// Called on `queue` with the raw request target (e.g. `/callback?code=…`).
  var onRequest: ((String) -> Void)?

  private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Hermes</title></head>\
    <body style="font: -apple-system-body; padding: 2rem"><h1>Signed in to Hermes</h1>\
    <p>You can close this window.</p></body></html>
    """

  func start(family: LoopbackFamily, completion: @escaping (Result<UInt16, Error>) -> Void) {
    do {
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: family.host, port: .any)
      let listener = try NWListener(using: params)
      self.listener = listener
      var settled = false
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          guard !settled else { return }
          settled = true
          completion(.success(listener.port?.rawValue ?? 0))
        case let .failed(error):
          guard !settled else { return }
          settled = true
          completion(.failure(error))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
      listener.start(queue: queue)
    } catch {
      completion(.failure(error))
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
      if let error {
        spikeLog("listener receive error: \(error)")
        connection.cancel()
        return
      }
      let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      let requestLine = text.components(separatedBy: "\r\n").first ?? ""
      let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
      spikeLog("listener request-line: \(requestLine.isEmpty ? "<empty>" : requestLine)")
      if case let .hostPort(host, port) = connection.endpoint {
        spikeLog("listener peer: \(host):\(port)")
      }
      let body = Self.page
      let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
      connection.send(
        content: response.data(using: .utf8),
        completion: .contentProcessed { _ in connection.cancel() }
      )
      self?.onRequest?(target)
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }
}

// MARK: - Presentation anchor

final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }
}

// MARK: - Spike driver

@MainActor
final class Spike: ObservableObject {
  @Published var lines: [String] = []

  private let presenter = Presenter()
  private var listener: LoopbackListener?
  private var session: ASWebAuthenticationSession?
  private var settled = false
  /// Seconds to leave the loopback page on screen before `cancel()` — long enough to
  /// screenshot the rendered HTML. `nil` = never auto-cancel (user-dismissal test).
  private var cancelDelay: TimeInterval? = 0

  /// Host:port of the throwaway redirect server on the developer machine.
  private let authorizeHost = ProcessInfo.processInfo.environment["SPIKE_AUTH_HOST"] ?? "127.0.0.1:8099"

  func note(_ message: String) {
    spikeLog(message)
    lines.append(message)
  }

  func run(family: LoopbackFamily, cancelDelay: TimeInterval? = 0) {
    self.cancelDelay = cancelDelay
    note("=== run \(family.rawValue) cancelDelay=\(cancelDelay.map { "\($0)s" } ?? "never") ===")
    note("device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) model=\(UIDevice.current.model)")
    settled = false
    listener?.stop()
    let listener = LoopbackListener()
    self.listener = listener
    listener.onRequest = { [weak self] target in
      Task { @MainActor in self?.handleCallback(target: target) }
    }
    listener.start(family: family) { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case let .success(port):
          self.note("listener bound \(family.uriHost):\(port)")
          self.openBrowser(family: family, port: port)
        case let .failure(error):
          self.note("listener FAILED: \(error)")
        }
      }
    }
  }

  private func openBrowser(family: LoopbackFamily, port: UInt16) {
    let redirect = "http://\(family.uriHost):\(port)/callback"
    let state = "spike-state-\(family.rawValue)"
    var components = URLComponents(string: "http://\(authorizeHost)/authorize")!
    components.queryItems = [
      .init(name: "redirect_uri", value: redirect),
      .init(name: "state", value: state),
      .init(name: "code", value: "spike-code"),
    ]
    let url = components.url!
    note("authorize url: \(url.absoluteString)")
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] callback, error in
      Task { @MainActor in
        guard let self else { return }
        let code = (error as? ASWebAuthenticationSessionError)?.code
        self.note(
          "ASWebAuth completion: url=\(callback?.absoluteString ?? "nil") "
            + "error=\(error.map { String(describing: $0) } ?? "nil") "
            + "asWebAuthCode=\(code.map { "\($0.rawValue)" } ?? "n/a") "
            + "settledBeforeCompletion=\(self.settled)"
        )
      }
    }
    session.prefersEphemeralWebBrowserSession = false
    session.presentationContextProvider = presenter
    self.session = session
    let started = session.start()
    note("session.start() -> \(started)")
  }

  private func handleCallback(target: String) {
    note("callback target: \(target)")
    guard target.contains("code=") else {
      note("… not a callback (answered anyway, flow still open)")
      return
    }
    guard !settled else {
      note("… duplicate callback ignored")
      return
    }
    settled = true
    guard let cancelDelay else {
      note("settled — leaving the sheet open (user-dismissal test)")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + cancelDelay) { [weak self] in
      self?.note("cancelling ASWebAuthenticationSession")
      self?.session?.cancel()
    }
    // Keep the listener alive briefly so we can observe follow-up probes (favicon etc.).
    DispatchQueue.main.asyncAfter(deadline: .now() + cancelDelay + 8) { [weak self] in
      self?.listener?.stop()
      self?.note("listener stopped")
    }
  }
}

// MARK: - UI

struct ContentView: View {
  @StateObject private var spike = Spike()

  var body: some View {
    VStack(spacing: 12) {
      Text("Loopback OAuth spike").font(.headline)
      HStack {
        Button("Run IPv4") { spike.run(family: .ipv4, cancelDelay: 6) }
          .accessibilityIdentifier("run-ipv4")
          .buttonStyle(.borderedProminent)
        Button("Run IPv6") { spike.run(family: .ipv6, cancelDelay: 6) }
          .accessibilityIdentifier("run-ipv6")
          .buttonStyle(.bordered)
        Button("No cancel") { spike.run(family: .ipv4, cancelDelay: nil) }
          .accessibilityIdentifier("run-no-cancel")
          .buttonStyle(.bordered)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(spike.lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 10, design: .monospaced))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding()
    .task {
      guard ProcessInfo.processInfo.environment["SPIKE_AUTORUN"] == "1" else { return }
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      spike.run(family: .ipv4)
    }
  }
}

@main
struct LoopbackSpikeApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}
