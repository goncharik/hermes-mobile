import Foundation

/// Why the onboarding Server step's `/api/status` probe failed (#136), classified from the RAW
/// `URLError` / HTTP response before anything is flattened to `RESTError`, so each failure card
/// can say what actually went wrong (and what to try next).
///
/// Only the onboarding probe uses this; the launch path (#62) keeps `RESTError`.
public enum ProbeFailure: Error, Equatable, Sendable {
  /// The device has no usable network (`.notConnectedToInternet` / `.dataNotAllowed` /
  /// `.internationalRoamingOff`).
  case offline
  /// DNS could not resolve the host (`.cannotFindHost` / `.dnsLookupFailed`).
  case hostNotFound
  /// Nothing listens on that port (`.cannotConnectToHost`).
  case refused
  /// The host never answered (`.timedOut` / `.networkConnectionLost`).
  case timedOut
  /// TLS failed (`.serverCertificate*` / `.secureConnectionFailed` / `.clientCertificate*`).
  case untrustedCertificate
  /// Something answered, but not a Hermes dashboard: a 404, a non-JSON 2xx, or a 2xx body
  /// that is not Hermes `/api/status` JSON.
  case notHermes(httpStatus: Int)
  /// Hermes rejected the `Host` header (dashboard bound to a specific address and reached by
  /// another name): a 400 whose detail starts "Invalid Host header". Carries the server copy.
  case hostRejected(detail: String)
  /// Any other HTTP answer — the server's copy verbatim, or "HTTP <status>".
  case httpError(String)
  /// The request failed before any HTTP answer for a reason not listed above (an unsupported
  /// scheme, a malformed response, …) — the system's description.
  case requestFailed(String)

  /// The server's 400 `detail` prefix for a Host header that is neither the bound hostname nor
  /// `dashboard.public_url` (`hermes_cli/web_server.py`, `host_header_middleware`).
  static let invalidHostDetailPrefix = "Invalid Host header"

  /// Nothing answered at all: DNS, a refused connection, or silence.
  public var isTransport: Bool {
    switch self {
    case .hostNotFound, .refused, .timedOut: true
    case .offline, .untrustedCertificate, .notHermes, .hostRejected, .httpError, .requestFailed: false
    }
  }

  /// Whether the probe moves on to the next candidate URL (the `:9119` fallback): nothing
  /// answered, or something that is not Hermes answered (a NAS or web server on port 80).
  /// A Hermes answer (`.hostRejected`, `.httpError`) is the server's verdict and stops the probe.
  public var triesNextCandidate: Bool {
    if case .notHermes = self { return true }
    return isTransport
  }

  /// Whether the failure card for `address` adds the Local Network hint line ("If iOS asked
  /// about Local Network access, allow it and try again…"): a same-network address that
  /// nothing answered, or that iOS reported as offline (a denied Local Network permission
  /// fails as "not connected"). No device-only detection (TN3179).
  public func showsLocalNetworkHint(for address: ServerAddress) -> Bool {
    address.kind == .localNetwork && (isTransport || self == .offline)
  }

  /// Which onboarding probe check this failure fails: no HTTP answer fails "Reaching", an
  /// HTTP answer that is not a usable `/api/status` fails "Checking it's a Hermes agent".
  public var failedCheck: ServerStep.State.Check {
    switch self {
    case .offline, .hostNotFound, .refused, .timedOut, .untrustedCertificate, .requestFailed:
      .reaching
    case .notHermes, .hostRejected, .httpError:
      .hermes
    }
  }

  /// Classifies a transport failure thrown by `URLSession`; a code not listed (or a
  /// non-`URLError`) is `.requestFailed`.
  public static func classify(_ error: any Error) -> ProbeFailure {
    guard let urlError = error as? URLError else { return .requestFailed(error.localizedDescription) }
    switch urlError.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
      return .offline
    case .cannotFindHost, .dnsLookupFailed:
      return .hostNotFound
    case .cannotConnectToHost:
      return .refused
    case .timedOut, .networkConnectionLost:
      return .timedOut
    case .serverCertificateHasBadDate, .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
      .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
      return .untrustedCertificate
    default:
      return .requestFailed(urlError.localizedDescription)
    }
  }

  /// Classifies an HTTP answer to `GET /api/status` that did not yield a `ServerStatus`: a
  /// non-2xx, or a 2xx whose body was not Hermes status JSON (callers only hand a 2xx here
  /// then). `detail` is the server's error text (JSON `detail` or plain body).
  ///
  /// An HTML `contentType` drops `detail` (a reverse proxy's error page is markup, not copy).
  public static func classify(httpStatus: Int, contentType: String?, detail: String?) -> ProbeFailure {
    let isHTML = contentType?.lowercased().contains("text/html") ?? false
    let detail = detail.flatMap { isHTML || $0.isEmpty ? nil : $0 }
    switch httpStatus {
    case 200..<300, 404:
      return .notHermes(httpStatus: httpStatus)
    case 400:
      if let detail, detail.hasPrefix(invalidHostDetailPrefix) {
        return .hostRejected(detail: detail)
      }
      return .httpError(detail ?? "HTTP \(httpStatus)")
    default:
      return .httpError(detail ?? "HTTP \(httpStatus)")
    }
  }

  /// The card-sized form of server or system copy: its first non-empty line, cut to `limit`
  /// characters with an ellipsis. The card's Details keeps the full text.
  public static func headline(of text: String, limit: Int = 200) -> String {
    let line = text.split(whereSeparator: \.isNewline)
      .lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    guard line.count > limit else { return line }
    return line.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
  }
}
