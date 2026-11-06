import Foundation

/// A Hermes profile (an independent environment: separate config, skills, SOUL.md, and
/// its own sessions). Decoded from `ProfileInfo` in `GET /api/profiles`
/// (`{ profiles: [...] }`). The default profile (`isDefault`) can't be renamed/deleted.
///
/// Decodes leniently — missing optional fields (`model`/`provider`) and absent
/// `skill_count`/`has_env` never crash. `Identifiable` by `name`.
public struct Profile: Equatable, Sendable, Identifiable, Decodable {
  /// Profile name — the identifier used in `?profile=` scoping. Also the `id`.
  public var name: String
  /// Whether this is the default/primary profile (can't be renamed/deleted).
  public var isDefault: Bool
  public var model: String?
  public var provider: String?
  /// Optional server-provided display label for the profile.
  public var displayName: String?
  /// Number of skills configured for this profile.
  public var skillCount: Int
  /// Whether the profile has an `.env` (env overrides) configured.
  public var hasEnv: Bool
  /// The desktop Bot Mode plugin's `ui_meta['hermes-bots']` block, when present.
  public var botMeta: BotMeta?
  /// Profile description. Bot Mode uses this top-level field rather than storing it in
  /// `ui_meta['hermes-bots']`.
  public var description: String?
  /// Whether the profile has a server-side avatar asset. Fetch it with
  /// `profiles.get_asset`; the metadata block does not contain an `avatar` value.
  public var hasAvatar: Bool

  public var id: String { name }

  /// Whether this profile is Bot-Mode-managed (has a non-empty
  /// `ui_meta['hermes-bots']` block).
  public var isBotManaged: Bool { botMeta?.isManaged == true }

  enum CodingKeys: String, CodingKey {
    case name
    case isDefault = "is_default"
    case model
    case provider
    case description
    case displayName = "display_name"
    case skillCount = "skill_count"
    case hasEnv = "has_env"
    case hasAvatar = "has_avatar"
    case uiMeta = "ui_meta"
  }

  /// The `ui_meta` object is not flat — the Bot Mode block sits under its own key.
  enum UIMetaKeys: String, CodingKey {
    case hermesBots = "hermes-bots"
  }

  public init(
    name: String,
    isDefault: Bool = false,
    model: String? = nil,
    provider: String? = nil,
    displayName: String? = nil,
    description: String? = nil,
    skillCount: Int = 0,
    hasEnv: Bool = false,
    hasAvatar: Bool = false,
    botMeta: BotMeta? = nil
  ) {
    self.name = name
    self.isDefault = isDefault
    self.model = model
    self.provider = provider
    self.displayName = displayName
    self.description = description
    self.skillCount = skillCount
    self.hasEnv = hasEnv
    self.hasAvatar = hasAvatar
    self.botMeta = botMeta
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = (try? c.decode(String.self, forKey: .name)) ?? ""
    isDefault = (try? c.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
    model = try? c.decodeIfPresent(String.self, forKey: .model)
    provider = try? c.decodeIfPresent(String.self, forKey: .provider)
    displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
    description = try? c.decodeIfPresent(String.self, forKey: .description)
    skillCount = (try? c.decodeIfPresent(Int.self, forKey: .skillCount)) ?? 0
    hasEnv = (try? c.decodeIfPresent(Bool.self, forKey: .hasEnv)) ?? false
    hasAvatar = (try? c.decodeIfPresent(Bool.self, forKey: .hasAvatar)) ?? false
    if let uiMeta = try? c.nestedContainer(keyedBy: UIMetaKeys.self, forKey: .uiMeta) {
      botMeta = try? uiMeta.decodeIfPresent(BotMeta.self, forKey: .hermesBots)
    } else {
      botMeta = nil
    }
  }
}
