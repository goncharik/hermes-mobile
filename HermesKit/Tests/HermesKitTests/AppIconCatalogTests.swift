import Dependencies
import Foundation
import Testing

@testable import HermesKit

struct AppIconCatalogTests {
  /// Shape of the `Info.plist` Xcode writes for a Debug build: the primary (`AppIconDev`)
  /// is ALSO listed as an alternate, plus one name the table doesn't know.
  private static var debugInfo: [String: Any] {[
    "CFBundleIcons": [
      "CFBundlePrimaryIcon": [
        "CFBundleIconName": "AppIconDev",
        "CFBundleIconFiles": ["AppIconDev60x60"],
      ],
      "CFBundleAlternateIcons": [
        "AppIconHermesClassicBlueprint": ["CFBundleIconName": "AppIconHermesClassicBlueprint"],
        "AppIconHermes": ["CFBundleIconName": "AppIconHermes"],
        "AppIconDev": ["CFBundleIconName": "AppIconDev"],
        "AppIcon": ["CFBundleIconName": "AppIcon"],
        "AppIconRetired": ["CFBundleIconName": "AppIconRetired"],
        "AppIconHermesBlueprint": ["CFBundleIconName": "AppIconHermesBlueprint"],
        "AppIconHermesClassic": ["CFBundleIconName": "AppIconHermesClassic"],
      ],
    ] as [String: Any],
  ]}

  @Test func tableIsSixIconsInDisplayOrder() {
    #expect(AppIconOption.all.map(\.label) == [
      "Gold", "Blueprint", "Hermes", "Hermes Blueprint", "Hermes Classic",
      "Hermes Classic Blueprint",
    ])
    #expect(AppIconOption.all.map(\.previewAsset) == AppIconOption.all.map { "AppIconPreview-\($0.name)" })
  }

  @Test func parsesPrimaryAndFiltersItOutOfAlternates() {
    let catalog = AppIconCatalog.parse(infoDictionary: Self.debugInfo)
    #expect(catalog.primary?.name == "AppIconDev")
    #expect(catalog.alternates.map(\.name) == [
      "AppIcon", "AppIconHermes", "AppIconHermesBlueprint", "AppIconHermesClassic",
      "AppIconHermesClassicBlueprint",
    ])
  }

  @Test func optionsListEverySelectableIconInTableOrder() {
    let catalog = AppIconCatalog.parse(infoDictionary: Self.debugInfo)
    #expect(catalog.options == AppIconOption.all)
  }

  @Test func unknownPrimaryIsDropped() {
    let info: [String: Any] = [
      "CFBundleIcons": [
        "CFBundlePrimaryIcon": ["CFBundleIconName": "SomethingElse"],
        "CFBundleAlternateIcons": ["AppIconHermes": [String: Any]()],
      ] as [String: Any],
    ]
    let catalog = AppIconCatalog.parse(infoDictionary: info)
    #expect(catalog.primary == nil)
    #expect(catalog.alternates.map(\.name) == ["AppIconHermes"])
  }

  @Test func fallsBackToIpadIconsKey() {
    let info: [String: Any] = [
      "CFBundleIcons~ipad": [
        "CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"],
        "CFBundleAlternateIcons": ["AppIconDev": [String: Any]()],
      ] as [String: Any],
    ]
    let catalog = AppIconCatalog.parse(infoDictionary: info)
    #expect(catalog.primary?.name == "AppIcon")
    #expect(catalog.alternates.map(\.name) == ["AppIconDev"])
  }

  @Test func emptyDictionaryYieldsEmptyCatalog() {
    #expect(AppIconCatalog.parse(infoDictionary: [:]) == .empty)
  }

  @Test func malformedDictionaryYieldsEmptyCatalog() {
    #expect(AppIconCatalog.parse(infoDictionary: ["CFBundleIcons": "nope"]) == .empty)
    let wrongShapes: [String: Any] = [
      "CFBundleIcons": [
        "CFBundlePrimaryIcon": 42,
        "CFBundleAlternateIcons": ["AppIcon", "AppIconDev"],
      ] as [String: Any],
    ]
    #expect(AppIconCatalog.parse(infoDictionary: wrongShapes) == .empty)
  }

  @Test func labelForNilIsThePrimaryLabel() {
    let catalog = AppIconCatalog.parse(infoDictionary: Self.debugInfo)
    #expect(catalog.label(for: nil) == "Blueprint")
    #expect(AppIconCatalog.empty.label(for: nil) == nil)
  }

  @Test func labelForKnownAndUnknownNames() {
    let catalog = AppIconCatalog.parse(infoDictionary: Self.debugInfo)
    #expect(catalog.label(for: "AppIconHermesClassic") == "Hermes Classic")
    #expect(catalog.label(for: "AppIconRetired") == nil)
  }

  @Test func testValueIsInMemoryWithFullCatalog() async throws {
    let client = AppIconClient.testValue
    #expect(client.catalog().primary?.name == "AppIcon")
    #expect(client.catalog().options.count == 6)
    #expect(await client.current() == nil)
    try await client.set("AppIconHermes")
    #expect(await client.current() == "AppIconHermes")
    try await client.set(nil)
    #expect(await client.current() == nil)
  }
}
