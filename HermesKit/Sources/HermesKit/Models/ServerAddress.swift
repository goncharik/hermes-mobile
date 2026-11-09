import Foundation

/// The server address the user typed on the onboarding Server step, parsed once (#136).
///
/// Pure value type answering every address policy question the flow asks:
/// - the candidate URLs to probe (as typed, then `:9119` for http without a port — Hermes'
///   default dashboard port, for a user who typed only the host);
/// - the network kind, which picks some failure-card copy and the Local Network hint line;
/// - whether the address is public cleartext (warn before sending credentials over http).
///
/// The kind is a HEURISTIC: a wrong guess only changes copy (`docs/features/onboarding.md`).
public struct ServerAddress: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// `localhost`, `*.localhost`, 127.0.0.0/8, `::1`.
    case loopback
    /// RFC 1918 (10/8, 172.16/12, 192.168/16), link-local, IPv6 unique-local/link-local,
    /// and `*.local` (Bonjour).
    case localNetwork
    /// Tailscale: 100.64.0.0/10 (CGNAT), `fd7a:115c:a1e0::/48`, `*.ts.net`, and single-label
    /// names (MagicDNS short names).
    case tailnet
    /// Everything else.
    case publicHost
  }

  /// Hermes' default dashboard port, tried after the as-typed URL for an http address with
  /// no explicit port.
  public static let fallbackPort = 9119

  /// The trimmed text the address was parsed from.
  public let typed: String
  /// The parsed URL: scheme defaulted to `http://`, port as typed.
  public let url: URL
  /// The lowercased host, without IPv6 brackets or a trailing root dot.
  public let host: String
  public let portWasGiven: Bool
  public let kind: Kind

  /// Parses `text` with the same leniency as `parseServerURL` (`host:port` defaults to
  /// `http://`, a host is required). `nil` means the text is not a usable address.
  public init?(_ text: String) {
    guard let url = parseServerURL(text), let rawHost = url.host(percentEncoded: false)
    else { return nil }
    var host = rawHost.lowercased()
    if host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty else { return nil }
    self.typed = text.trimmingCharacters(in: .whitespaces)
    self.url = url
    self.host = host
    self.portWasGiven = url.port != nil
    self.kind = Self.classify(host: host)
  }

  /// The URLs to probe, in order: the URL as typed, then the same URL on `:9119` when the
  /// scheme is http and no port was given.
  public var candidates: [URL] {
    guard isHTTP, !portWasGiven,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return [url] }
    components.port = Self.fallbackPort
    guard let fallback = components.url else { return [url] }
    return [url, fallback]
  }

  /// Plain http to a public host: credentials would cross the internet unencrypted.
  public var isPublicCleartext: Bool { isHTTP && kind == .publicHost }

  private var isHTTP: Bool { url.scheme?.lowercased() == "http" }
}

extension ServerAddress {
  /// Classifies a lowercased host (no brackets, no trailing dot).
  static func classify(host: String) -> Kind {
    if let octets = ipv4Octets(host) { return classify(ipv4: octets) }
    if let bytes = ipv6Bytes(host) { return classify(ipv6: bytes) }
    if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
    if host.hasSuffix(".local") { return .localNetwork }
    if host.hasSuffix(".ts.net") || !host.contains(".") { return .tailnet }
    return .publicHost
  }

  private static func classify(ipv4 o: [UInt8]) -> Kind {
    switch (o[0], o[1]) {
    case (127, _): .loopback
    case (10, _), (172, 16...31), (192, 168), (169, 254): .localNetwork
    case (100, 64...127): .tailnet
    default: .publicHost
    }
  }

  private static func classify(ipv6 b: [UInt8]) -> Kind {
    if b == [UInt8](repeating: 0, count: 15) + [1] { return .loopback }
    // IPv4-mapped (::ffff:a.b.c.d) classifies as its IPv4 address.
    if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
      return classify(ipv4: Array(b[12..<16]))
    }
    // Tailscale's ULA prefix, checked before the general unique-local range it sits in.
    if b[0..<6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return .tailnet }
    if b[0] & 0xfe == 0xfc { return .localNetwork }  // fc00::/7 unique local
    if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return .localNetwork }  // fe80::/10 link local
    return .publicHost
  }

  /// Strict dotted-quad parse (exactly four decimal octets, 0–255).
  private static func ipv4Octets(_ host: String) -> [UInt8]? {
    var address = in_addr()
    guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
  }

  private static func ipv6Bytes(_ host: String) -> [UInt8]? {
    guard host.contains(":") else { return nil }
    // A link-local literal may carry a zone (`fe80::1%en0`), which `inet_pton` rejects.
    let literal = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
    var address = in6_addr()
    guard inet_pton(AF_INET6, literal, &address) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
  }
}

/// Lenient URL parsing: accept `host:port` by defaulting to `http://`.
func parseServerURL(_ string: String) -> URL? {
  let trimmed = string.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty else { return nil }
  let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
  guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
  return url
}
