import Foundation
import Testing

@testable import HermesKit

struct AcknowledgementTests {
  /// Resolved packages that are never linked into the app: `swift-syntax` only builds the
  /// macro plugins, `swift-snapshot-testing` only the app's snapshot test target.
  private static let buildOrTestOnly: Set<String> = ["swift-syntax", "swift-snapshot-testing"]

  private static let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // HermesKitTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // HermesKit

  /// Every linked package in `Package.resolved` is acknowledged, and nothing else.
  @Test func listMatchesPackageResolvedMinusBuildAndTestOnly() throws {
    let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent("Package.resolved"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let pins = try #require(json["pins"] as? [[String: Any]])
    let resolved = Set(pins.compactMap { $0["identity"] as? String })
    #expect(!resolved.isEmpty)
    #expect(Set(Acknowledgement.all.map(\.id)) == resolved.subtracting(Self.buildOrTestOnly))
  }

  @Test func listIsAlphabeticalWithUniqueIDs() {
    let names = Acknowledgement.all.map(\.name)
    #expect(names == names.sorted { $0.lowercased() < $1.lowercased() })
    #expect(Set(Acknowledgement.all.map(\.id)).count == names.count)
  }

  private static let checkouts = packageRoot.appendingPathComponent(".build/checkouts")

  /// Each shipped text is the package's LICENSE verbatim, checked against the SwiftPM
  /// checkout `swift test` resolved (`.build/checkouts/<repo>/LICENSE[.txt]`; an Xcode-hosted
  /// run has no such directory and skips).
  @Test(.enabled(if: FileManager.default.fileExists(atPath: checkouts.path)))
  func licenseTextsMatchTheCheckouts() throws {
    var compared = 0
    for acknowledgement in Acknowledgement.all {
      let directory = Self.checkouts.appendingPathComponent(acknowledgement.name)
      guard
        let file = ["LICENSE", "LICENSE.txt", "LICENSE.md"]
          .map({ directory.appendingPathComponent($0) })
          .first(where: { FileManager.default.fileExists(atPath: $0.path) })
      else { continue }
      var text = try String(contentsOf: file, encoding: .utf8)
      while text.hasSuffix("\n") { text.removeLast() }
      #expect(acknowledgement.licenseText == text, "\(acknowledgement.name) license drifted")
      compared += 1
    }
    #expect(compared == Acknowledgement.all.count, "checkouts missing under \(Self.checkouts.path)")
  }
}
