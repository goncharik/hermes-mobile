import Dependencies
import Foundation
import Testing

@testable import HermesKit

struct FeedbackLinksTests {
  private static let info = BundleInfo.test

  /// The decoded `title` / `body` query values of a new-issue URL.
  private static func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  @Test func reportBugExactURL() {
    #expect(
      FeedbackLinks.reportBug(Self.info).absoluteString
        == "https://github.com/goncharik/hermes-mobile/issues/new"
        + "?title=Bug%3A%20"
        + "&body=%2A%2AWhat%20happened%3F%2A%2A%0A%0A%0A%2A%2ASteps%20to%20reproduce%2A%2A%0A%0A%0A"
        + "---%0AApp%3A%201.0%20%2879%29%0AiOS%3A%2018.0%0ADevice%3A%20iPhone"
    )
  }

  @Test func requestFeatureExactURL() {
    #expect(
      FeedbackLinks.requestFeature(Self.info).absoluteString
        == "https://github.com/goncharik/hermes-mobile/issues/new"
        + "?title=Feature%20request%3A%20"
        + "&body=%2A%2AWhat%20would%20you%20like%20Hermes%20Mobile%20to%20do%3F%2A%2A%0A%0A%0A"
        + "---%0AApp%3A%201.0%20%2879%29%0AiOS%3A%2018.0%0ADevice%3A%20iPhone"
    )
  }

  @Test func issueBodiesCarryAllFourFacts() {
    let info = BundleInfo(
      marketingVersion: "2.3", build: "104", osVersion: "26.1.2", deviceModel: "iPad16,3"
    )
    for url in [FeedbackLinks.reportBug(info), FeedbackLinks.requestFeature(info)] {
      let body = Self.query(url)["body"] ?? ""
      #expect(body.hasSuffix("---\nApp: 2.3 (104)\niOS: 26.1.2\nDevice: iPad16,3"))
    }
  }

  @Test func queryValuesEscapeReservedCharacters() {
    // `&`, `=`, `+` and `#` in a fact must not split or truncate the query.
    let info = BundleInfo(
      marketingVersion: "1.0+beta", build: "7&8", osVersion: "18=0", deviceModel: "iPhone#é"
    )
    let url = FeedbackLinks.reportBug(info)
    #expect(!url.absoluteString.contains("+"))
    #expect(url.fragment == nil)
    let query = Self.query(url)
    #expect(query.keys.sorted() == ["body", "title"])
    #expect(query["title"] == "Bug: ")
    #expect(query["body"]?.hasSuffix("App: 1.0+beta (7&8)\niOS: 18=0\nDevice: iPhone#é") == true)
  }

  @Test func constantURLs() {
    #expect(FeedbackLinks.repository.absoluteString == "https://github.com/goncharik/hermes-mobile")
    #expect(
      FeedbackLinks.allIssues.absoluteString == "https://github.com/goncharik/hermes-mobile/issues"
    )
    #expect(
      FeedbackLinks.hermesAgent.absoluteString == "https://github.com/NousResearch/hermes-agent"
    )
    #expect(
      FeedbackLinks.privacyPolicy.absoluteString
        == "https://github.com/goncharik/hermes-mobile/blob/main/PRIVACY.md"
    )
  }

  @Test func writeReviewFormat() {
    #expect(
      FeedbackLinks.writeReview(appID: "1234567890").absoluteString
        == "https://apps.apple.com/app/id1234567890?action=write-review"
    )
  }
}

struct BundleInfoClientTests {
  @Test func testValueReturnsFixedFacts() {
    let info = withDependencies {
      $0.bundleInfo = .testValue
    } operation: {
      @Dependency(\.bundleInfo) var bundleInfo
      return bundleInfo.info()
    }
    #expect(info == BundleInfo(marketingVersion: "1.0", build: "79", osVersion: "18.0", deviceModel: "iPhone"))
  }

  @Test func osVersionFormatsLikeUIDevice() {
    #expect(
      BundleInfoClient.formatOSVersion(.init(majorVersion: 18, minorVersion: 0, patchVersion: 0))
        == "18.0"
    )
    #expect(
      BundleInfoClient.formatOSVersion(.init(majorVersion: 26, minorVersion: 1, patchVersion: 2))
        == "26.1.2"
    )
  }

  @Test func simulatorModelWinsOverHostMachine() {
    #expect(
      BundleInfoClient.machineIdentifier(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone17,1"])
        == "iPhone17,1"
    )
  }

  @Test func machineIdentifierFallsBackToUname() {
    let machine = BundleInfoClient.machineIdentifier(environment: [:])
    #expect(!machine.isEmpty)
    #expect(!machine.contains("\0"))
  }
}
