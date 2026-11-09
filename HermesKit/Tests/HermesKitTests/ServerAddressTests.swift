import Foundation
import Testing

@testable import HermesKit

struct ServerAddressTests {
  // MARK: - Parsing

  @Test func defaultsToHTTPAndKeepsTypedPort() throws {
    let address = try #require(ServerAddress("mac-studio:8642"))
    #expect(address.url == URL(string: "http://mac-studio:8642"))
    #expect(address.host == "mac-studio")
    #expect(address.portWasGiven)
    #expect(address.typed == "mac-studio:8642")
  }

  @Test func keepsExplicitScheme() throws {
    let address = try #require(ServerAddress("https://hermes.example.com"))
    #expect(address.url == URL(string: "https://hermes.example.com"))
    #expect(!address.portWasGiven)
  }

  @Test func trimsSurroundingWhitespace() throws {
    let address = try #require(ServerAddress("  \t192.168.1.20:9119  "))
    #expect(address.typed == "192.168.1.20:9119")
    #expect(address.url == URL(string: "http://192.168.1.20:9119"))
    #expect(address.kind == .localNetwork)
  }

  @Test func normalizesHostCaseAndTrailingDot() throws {
    let address = try #require(ServerAddress("HTTPS://Box.Tail1234.TS.NET."))
    #expect(address.host == "box.tail1234.ts.net")
    #expect(address.kind == .tailnet)
  }

  @Test func parsesBracketedIPv6Literal() throws {
    let address = try #require(ServerAddress("http://[::1]:8080"))
    #expect(address.host == "::1")
    #expect(address.portWasGiven)
    #expect(address.kind == .loopback)
  }

  @Test(arguments: ["", "   ", "\t", "http://", "http:// ", "http://a b", "://"])
  func rejectsInvalidInput(_ text: String) {
    #expect(ServerAddress(text) == nil)
  }

  @Test(arguments: ["", "   ", "http://", "mac-studio:8642", "https://h.example.com", "a b"])
  func acceptsExactlyWhatParseServerURLAccepts(_ text: String) {
    #expect(ServerAddress(text)?.url == parseServerURL(text))
  }

  // MARK: - Kind

  @Test(arguments: [
    // Single-label names (MagicDNS short names) and *.ts.net.
    ("mac-studio", ServerAddress.Kind.tailnet),
    ("hermes:8642", .tailnet),
    ("box.tail1234.ts.net", .tailnet),
    ("https://box.tail1234.ts.net", .tailnet),
    // 100.64.0.0/10 edges.
    ("100.64.0.1", .tailnet),
    ("100.127.255.254", .tailnet),
    ("100.63.255.255", .publicHost),
    ("100.128.0.1", .publicHost),
    // RFC 1918 edges.
    ("10.0.0.5", .localNetwork),
    ("10.255.255.255", .localNetwork),
    ("172.16.0.1", .localNetwork),
    ("172.31.255.255", .localNetwork),
    ("172.15.0.1", .publicHost),
    ("172.32.0.1", .publicHost),
    ("192.168.1.20", .localNetwork),
    ("192.169.1.20", .publicHost),
    ("169.254.10.10", .localNetwork),
    // Bonjour.
    ("mac-studio.local", .localNetwork),
    ("http://mac-studio.local:9119", .localNetwork),
    // Loopback.
    ("localhost", .loopback),
    ("localhost:9119", .loopback),
    ("hermes.localhost", .loopback),
    ("127.0.0.1", .loopback),
    ("127.10.20.30:8000", .loopback),
    // Public.
    ("hermes.example.com", .publicHost),
    ("https://hermes.example.com:8443", .publicHost),
    ("8.8.8.8", .publicHost),
    // IPv6 literals.
    ("http://[::1]", .loopback),
    ("http://[fd7a:115c:a1e0::1234]:9119", .tailnet),
    ("http://[fd12:3456::1]", .localNetwork),
    ("http://[fe80::1]", .localNetwork),
    ("http://[::ffff:192.168.1.2]", .localNetwork),
    ("http://[2001:db8::1]", .publicHost),
  ])
  func classifiesKind(_ text: String, _ expected: ServerAddress.Kind) throws {
    let address = try #require(ServerAddress(text))
    #expect(address.kind == expected)
  }

  // MARK: - Candidates

  @Test func httpWithoutPortAddsFallbackPort() throws {
    let address = try #require(ServerAddress("mac-studio"))
    #expect(
      address.candidates == [
        URL(string: "http://mac-studio")!,
        URL(string: "http://mac-studio:9119")!,
      ]
    )
  }

  @Test func fallbackKeepsPath() throws {
    let address = try #require(ServerAddress("http://box.local/hermes"))
    #expect(
      address.candidates == [
        URL(string: "http://box.local/hermes")!,
        URL(string: "http://box.local:9119/hermes")!,
      ]
    )
  }

  @Test func fallbackOnIPv6Literal() throws {
    let address = try #require(ServerAddress("http://[fd7a:115c:a1e0::1]"))
    #expect(address.candidates.last == URL(string: "http://[fd7a:115c:a1e0::1]:9119"))
  }

  @Test(arguments: [
    "mac-studio:8642",
    "http://mac-studio:80",
    "https://hermes.example.com",
    "https://hermes.example.com:8443",
  ])
  func noFallbackWithPortOrHTTPS(_ text: String) throws {
    let address = try #require(ServerAddress(text))
    #expect(address.candidates == [address.url])
  }

  // MARK: - Public cleartext

  @Test(arguments: [
    ("hermes.example.com", true),
    ("http://hermes.example.com:9119", true),
    ("HTTP://8.8.8.8", true),
    ("https://hermes.example.com", false),
    ("192.168.1.20", false),
    ("mac-studio", false),
    ("100.100.1.1", false),
    ("localhost", false),
    ("mac-studio.local", false),
  ])
  func publicCleartextOnlyForHTTPToPublicHost(_ text: String, _ expected: Bool) throws {
    let address = try #require(ServerAddress(text))
    #expect(address.isPublicCleartext == expected)
  }
}
