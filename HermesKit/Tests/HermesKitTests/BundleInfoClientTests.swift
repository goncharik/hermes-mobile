import Dependencies
import Foundation
import Testing

@testable import HermesKit

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
