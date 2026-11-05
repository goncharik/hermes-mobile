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
  public let previewAsset: String

  public init(name: String, label: String, previewAsset: String) {
    self.name = name
    self.label = label
    self.previewAsset = previewAsset
  }

  private init(name: String, label: String) {
    self.init(name: name, label: label, previewAsset: "AppIconPreview-\(name)")
  }

  /// Every icon the app ships, in picker display order. The names must match the
  /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` list in `Project.swift`; a name the
  /// bundle does not advertise is simply not offered (see `AppIconCatalog.parse`).
  public static let all: [AppIconOption] = [
    AppIconOption(name: "AppIcon", label: "Gold"),
    AppIconOption(name: "AppIconDev", label: "Blueprint"),
    AppIconOption(name: "AppIconHermes", label: "Hermes"),
    AppIconOption(name: "AppIconHermesBlueprint", label: "Hermes Blueprint"),
    AppIconOption(name: "AppIconHermesClassic", label: "Hermes Classic"),
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
/// and TestFlight), and every set — the primary included — is listed as an alternate so any
/// build can reach any icon. The parser therefore filters the primary out of `alternates`:
/// choosing the primary is `setAlternateIconName(nil)`, never its alternate twin.
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

  /// Every selectable icon (primary + alternates) in table display order.
  public var options: [AppIconOption] {
    let names = Set(([primary].compactMap { $0 } + alternates).map(\.name))
    return AppIconOption.all.filter { names.contains($0.name) }
  }

  /// Label for an `alternateIconName` value: `nil` means the primary icon; an unknown name
  /// (not in the table) yields `nil`.
  public func label(for name: String?) -> String? {
    guard let name else { return primary?.label }
    return AppIconOption.named(name)?.label
  }

  /// Builds the catalog from an `Info.plist` dictionary (`Bundle.main.infoDictionary`).
  /// Reads `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName` and the keys of
  /// `CFBundleIcons.CFBundleAlternateIcons`; falls back to `CFBundleIcons~ipad` when the
  /// universal key is absent. Names not in `AppIconOption.all` are dropped, the primary is
  /// filtered out of the alternates, and the alternates keep table order. A missing or
  /// malformed dictionary yields `.empty`.
  public static func parse(infoDictionary: [String: Any]) -> AppIconCatalog {
    guard
      let icons = (infoDictionary["CFBundleIcons"] ?? infoDictionary["CFBundleIcons~ipad"])
        as? [String: Any]
    else { return .empty }

    let primaryName: String? = {
      if let dict = icons["CFBundlePrimaryIcon"] as? [String: Any] {
        return dict["CFBundleIconName"] as? String
      }
      return icons["CFBundlePrimaryIcon"] as? String
    }()
    let primary = primaryName.flatMap(AppIconOption.named)

    let alternateDict = icons["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
    let alternateNames = Set(alternateDict.keys)
    let alternates = AppIconOption.all.filter {
      alternateNames.contains($0.name) && $0.name != primaryName
    }
    return AppIconCatalog(primary: primary, alternates: alternates)
  }
}
