import Foundation

/// The `ui_meta['hermes-bots']` block the desktop's Bot Mode plugin writes onto a
/// profile's `profile.yaml`. Surfaced here so mobile can render the same avatar/title/
/// description a Bot shows on desktop, without owning any Bot Mode business logic.
///
/// NOT verified against a live payload yet — the desktop plugin defines this shape
/// (`apps/desktop/src/plugins/hermes-bots/plugin.js`) but only via `profiles.configure`
/// (gateway RPC), not a documented REST contract. Every field is optional and decoding
/// is maximally lenient (unknown/missing keys never fail the whole `Profile` decode) —
/// see the TODO on `Profile.botMeta` before shipping.
///
/// Field names are BEST-EFFORT guesses from the plugin.js `ui_meta` shape
/// (`title`, `description`, `avatar`, `pinned`, `hidden`, `groups`) and MUST be
/// confirmed against a live `GET /api/profiles` / `profiles.list` response from a
/// Bot-Mode-managed agent before this ships. Treat as a draft contract.
public struct BotMeta: Equatable, Sendable, Decodable {
  /// Friendly display title (distinct from the raw profile `name` slug).
  public var title: String?
  /// One-line description shown under the bot's name in the roster.
  public var description: String?
  /// Avatar descriptor — kept as an opaque JSONValue for now since the desktop supports
  /// several avatar kinds (blob face seed, geometric shape+color, uploaded image ref,
  /// AI-generated portrait ref, pixel pet id) and mobile doesn't need to interpret the
  /// kind to do the Phase 1 minimum (name + description only). Revisit once the exact
  /// avatar payload shape is confirmed.
  public var avatar: JSONValue?
  /// Whether the bot is hidden from the roster (desktop's "Hide Bot").
  public var hidden: Bool?
  /// Group-chat room names this bot is a member of (Phase 2 — unused by Phase 1 UI).
  public var groups: [String]?

  enum CodingKeys: String, CodingKey {
    case title, description, avatar, hidden, groups
  }

  public init(
    title: String? = nil,
    description: String? = nil,
    avatar: JSONValue? = nil,
    hidden: Bool? = nil,
    groups: [String]? = nil
  ) {
    self.title = title
    self.description = description
    self.avatar = avatar
    self.hidden = hidden
    self.groups = groups
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try? c.decodeIfPresent(String.self, forKey: .title)
    description = try? c.decodeIfPresent(String.self, forKey: .description)
    avatar = try? c.decodeIfPresent(JSONValue.self, forKey: .avatar)
    hidden = try? c.decodeIfPresent(Bool.self, forKey: .hidden)
    groups = try? c.decodeIfPresent([String].self, forKey: .groups)
  }

  /// Whether this profile is Bot-Mode-managed at all — mirrors the backend's own
  /// cheap check in `tools/bot_mode_probe.py::_is_bot_managed` (any non-empty
  /// `ui_meta['hermes-bots']` block, decodable or not).
  public var isBotManaged: Bool { true }
}
