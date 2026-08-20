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
  /// Number of skills configured for this profile.
  public var skillCount: Int
  /// Whether the profile has an `.env` (env overrides) configured.
  public var hasEnv: Bool
  /// The desktop Bot Mode plugin's `ui_meta['hermes-bots']` block, when present
  /// (`GET /api/profiles` — NOT YET VERIFIED to forward `ui_meta`; the gateway RPC
  /// `profiles.list` does per `tui_gateway/methods_profiles.py`, but the REST route's
  /// `_profile_to_dict` needs confirming against a live Bot-Mode agent before this is
  /// relied on for anything beyond a best-effort roster hint — see
  /// `docs/plans/YYYYMMDD-bot-mode-support.md` Task 1). `nil` for a plain profile,
  /// which is the overwhelming majority of installs and every non-Bot-Mode agent.
  public var botMeta: BotMeta?

  public var id: String { name }

  /// Whether this profile is Bot-Mode-managed (has a `ui_meta['hermes-bots']` block).
  /// Mirrors `tools/bot_mode_probe.py::_is_bot_managed`'s definition on the backend.
  public var isBotManaged: Bool { botMeta != nil }

  enum CodingKeys: String, CodingKey {
    case name
    case isDefault = "is_default"
    case model
    case provider
    case skillCount = "skill_count"
    case hasEnv = "has_env"
    case uiMeta = "ui_meta"
  }

  /// The `ui_meta` object is NOT flat — the Bot Mode block sits under its own key,
  /// mirroring `profile.yaml`'s `ui_meta: { 'hermes-bots': {...} }` shape used by
  /// `profiles.configure` on the backend.
  enum UIMetaKeys: String, CodingKey {
    case hermesBots = "hermes-bots"
  }

  public init(
    name: String,
    isDefault: Bool = false,
    model: String? = nil,
    provider: String? = nil,
    skillCount: Int = 0,
    hasEnv: Bool = false,
    botMeta: BotMeta? = nil
  ) {
    self.name = name
    self.isDefault = isDefault
    self.model = model
    self.provider = provider
    self.skillCount = skillCount
    self.hasEnv = hasEnv
    self.botMeta = botMeta
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = (try? c.decode(String.self, forKey: .name)) ?? ""
    isDefault = (try? c.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
    model = try? c.decodeIfPresent(String.self, forKey: .model)
    provider = try? c.decodeIfPresent(String.self, forKey: .provider)
    skillCount = (try? c.decodeIfPresent(Int.self, forKey: .skillCount)) ?? 0
    hasEnv = (try? c.decodeIfPresent(Bool.self, forKey: .hasEnv)) ?? false
    if let uiMeta = try? c.nestedContainer(keyedBy: UIMetaKeys.self, forKey: .uiMeta) {
      botMeta = try? uiMeta.decodeIfPresent(BotMeta.self, forKey: .hermesBots)
    } else {
      botMeta = nil
    }
  }
}
