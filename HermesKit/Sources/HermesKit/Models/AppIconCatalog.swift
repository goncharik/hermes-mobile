import Foundation

/// One selectable app icon: the asset-catalog `.appiconset` name iOS knows it by, the label
/// the picker shows, and the plain image set the picker renders as its preview (an app
/// icon set cannot be loaded with `Image(_:)`).
public struct AppIconOption: Equatable, Hashable, Sendable {
  /// The `.appiconset` name — the value `setAlternateIconName` takes.
  public let name: String
  /// User-facing label shown under the tile and as the Settings row value.
  public let label: String
  /// Name of the `AppIconPreview-<SetName>` image set the picker draws.
  public var previewAsset: String { "AppIconPreview-\(name)" }

  init(name: String, label: String) {
    self.name = name
    self.label = label
  }

  /// Every icon the app ships, in picker display order. The names must match the
  /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` list in `Project.swift`; a name the
  /// bundle does not advertise is simply not offered (see `AppIconCatalog.parse`).
  public static let all: [AppIconOption] = [
    AppIconOption(name: "AppIcon", label: "Gold"),
    AppIconOption(name: "AppIconDev", label: "Blueprint"),
    AppIconOption(name: "AppIconHermesNeo", label: "Hermes Neo"),
    AppIconOption(name: "AppIconHermesNeoDark", label: "Hermes Neo Dark"),
    AppIconOption(name: "AppIconHermesNeoBlueprint", label: "Hermes Neo Blueprint"),
    AppIconOption(name: "AppIconHermesClassic", label: "Hermes Classic"),
    AppIconOption(name: "AppIconHermesClassicDark", label: "Hermes Classic Dark"),
    AppIconOption(name: "AppIconHermesClassicBlueprint", label: "Hermes Classic Blueprint"),
  ]

  /// The table entry for a set name, or `nil` for a name the app does not know.
  public static func named(_ name: String) -> AppIconOption? {
    all.first { $0.name == name }
  }
}

/// The icons this build can switch between, derived from the bundle's `Info.plist`.
///
/// The primary icon differs per build configuration (gold for Release, blueprint for Debug
/// and TestFlight), so `Project.swift` lists every set as an alternate and any build can
/// reach any icon. actool drops the primary from the built `CFBundleAlternateIcons`; the
/// parser filters it out of `alternates` as a safeguard all the same: choosing the primary is
/// `setAlternateIconName(nil)`, never its alternate twin.
public struct AppIconCatalog: Equatable, Sendable {
  /// The build's primary icon (selected when `alternateIconName == nil`), if it is a known set.
  public var primary: AppIconOption?
  /// Known alternate icons other than the primary, in table order.
  public var alternates: [AppIconOption]

  public init(primary: AppIconOption?, alternates: [AppIconOption]) {
    self.primary = primary
    self.alternates = alternates
  }

  public static let empty = AppIconCatalog(primary: nil, alternates: [])

  /// The catalog a Release build advertises: `AppIcon` primary, the other five alternates.
  public static let testCatalog = AppIconCatalog(
    primary: AppIconOption.named("AppIcon")!,
    alternates: AppIconOption.all.filter { $0.name != "AppIcon" }
  )

  /// Every selectable icon (primary + alternates) in table display order.
  public var options: [AppIconOption] {
    let names = Set(([primary].compactMap { $0 } + alternates).map(\.name))
    return AppIconOption.all.filter { names.contains($0.name) }
  }

  /// The option for an `alternateIconName` value: `nil` means the primary icon; an unknown
  /// name (not in the table) yields `nil`.
  public func option(for name: String?) -> AppIconOption? {
    guard let name else { return primary }
    return AppIconOption.named(name)
  }

  /// Label for an `alternateIconName` value; see `option(for:)`.
  public func label(for name: String?) -> String? {
    option(for: name)?.label
  }

  /// Builds the catalog from an `Info.plist` dictionary (`Bundle.main.infoDictionary`).
  /// Reads `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName` and the keys of
  /// `CFBundleIcons.CFBundleAlternateIcons`. Names not in `AppIconOption.all` are dropped, the
  /// primary is filtered out of the alternates, and the alternates keep table order. A missing
  /// or malformed dictionary yields `.empty`.
  public static func parse(infoDictionary: [String: Any]) -> AppIconCatalog {
    guard let icons = infoDictionary["CFBundleIcons"] as? [String: Any] else { return .empty }

    let primaryName = (icons["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconName"]
      as? String
    let primary = primaryName.flatMap(AppIconOption.named)

    let alternateDict = icons["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
    let alternateNames = Set(alternateDict.keys)
    let alternates = AppIconOption.all.filter {
      alternateNames.contains($0.name) && $0.name != primaryName
    }
    return AppIconCatalog(primary: primary, alternates: alternates)
  }
}
