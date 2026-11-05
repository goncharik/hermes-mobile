import Dependencies
import Foundation
import Testing

@testable import HermesKit

struct AppIconCatalogTests {
  /// A Debug-build `Info.plist` with the primary (`AppIconDev`) ALSO listed as an alternate,
  /// plus one name the table doesn't know. actool currently omits the primary from
  /// `CFBundleAlternateIcons` (see `actoolOutputWithoutPrimaryAlternate`); the parser must
  /// still hold if a toolchain starts listing it.
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
    #expect(AppIconOption.named("AppIconHermes")?.previewAsset == "AppIconPreview-AppIconHermes")
  }

  /// The table must match `Project.swift`'s `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`,
  /// read from the checkout, and every set needs its `.appiconset` and preview image set.
  @Test func tableNamesMatchProjectAlternateIconNames() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // HermesKitTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // HermesKit
      .deletingLastPathComponent()
    let project = try String(
      contentsOf: repoRoot.appendingPathComponent("Project.swift"), encoding: .utf8
    )
    let key = "\"ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES\": \""
    let value = try #require(
      project.components(separatedBy: key).dropFirst().first?.components(separatedBy: "\"").first
    )
    #expect(AppIconOption.all.map(\.name) == value.split(separator: " ").map(String.init))

    let assets = repoRoot.appendingPathComponent("HermesMobile/Resources/Assets.xcassets")
    for option in AppIconOption.all {
      for set in ["\(option.name).appiconset", "\(option.previewAsset).imageset"] {
        #expect(
          FileManager.default.fileExists(atPath: assets.appendingPathComponent(set).path),
          "missing \(set)"
        )
      }
    }
  }

  /// The real Debug-build `Info.plist` (dumped from the built app): actool drops the primary
  /// from `CFBundleAlternateIcons` even though `Project.swift` lists it, so five alternates.
  @Test func actoolOutputWithoutPrimaryAlternate() {
    let info: [String: Any] = [
      "CFBundleIcons": [
        "CFBundlePrimaryIcon": ["CFBundleIconName": "AppIconDev"],
        "CFBundleAlternateIcons": [
          "AppIcon": ["CFBundleIconName": "AppIcon"],
          "AppIconHermes": ["CFBundleIconName": "AppIconHermes"],
          "AppIconHermesBlueprint": ["CFBundleIconName": "AppIconHermesBlueprint"],
          "AppIconHermesClassic": ["CFBundleIconName": "AppIconHermesClassic"],
          "AppIconHermesClassicBlueprint": ["CFBundleIconName": "AppIconHermesClassicBlueprint"],
        ],
      ] as [String: Any],
    ]
    let catalog = AppIconCatalog.parse(infoDictionary: info)
    #expect(catalog.primary?.name == "AppIconDev")
    #expect(catalog.options == AppIconOption.all)
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
