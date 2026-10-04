import Foundation

/// The `ui_meta['hermes-bots']` block the desktop Bot Mode plugin writes to a
/// profile's `profile.yaml`.
///
/// The wire shape is deliberately kept separate from the profile's `description` and
/// avatar asset: description is a top-level profile field, while the avatar is exposed
/// by `profiles.list` as `has_avatar` and fetched with `profiles.get_asset`. All fields
/// are optional so newer desktop-only metadata does not break profile decoding.
public struct BotMeta: Equatable, Sendable, Decodable {
  /// Friendly display title (distinct from the raw profile `name` slug).
  public var title: String?
  public var shape: String?
  public var color: String?
  public var imageKind: String?
  public var custom: Bool?
  public var created: Int?
  public var pinned: Bool?
  public var hidden: Bool?
  public var groups: [String]?
  /// Legacy single-group value still read by the desktop plugin.
  public var group: String?

  private var hasPayload: Bool

  /// Whether the `hermes-bots` object contained at least one key. The backend uses
  /// non-empty metadata as the Bot Mode marker; an empty object is not a bot.
  public var isManaged: Bool { hasPayload }

  enum CodingKeys: String, CodingKey {
    case title, shape, color, imageKind, custom, created, pinned, hidden, groups, group
  }

  public init(
    title: String? = nil,
    shape: String? = nil,
    color: String? = nil,
    imageKind: String? = nil,
    custom: Bool? = nil,
    created: Int? = nil,
    pinned: Bool? = nil,
    hidden: Bool? = nil,
    groups: [String]? = nil,
    group: String? = nil
  ) {
    self.title = title
    self.shape = shape
    self.color = color
    self.imageKind = imageKind
    self.custom = custom
    self.created = created
    self.pinned = pinned
    self.hidden = hidden
    self.groups = groups
    self.group = group
    self.hasPayload = title != nil || shape != nil || color != nil || imageKind != nil || custom != nil || created != nil || pinned != nil || hidden != nil || groups != nil || group != nil
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try? c.decodeIfPresent(String.self, forKey: .title)
    shape = try? c.decodeIfPresent(String.self, forKey: .shape)
    color = try? c.decodeIfPresent(String.self, forKey: .color)
    imageKind = try? c.decodeIfPresent(String.self, forKey: .imageKind)
    custom = try? c.decodeIfPresent(Bool.self, forKey: .custom)
    created = try? c.decodeIfPresent(Int.self, forKey: .created)
    pinned = try? c.decodeIfPresent(Bool.self, forKey: .pinned)
    hidden = try? c.decodeIfPresent(Bool.self, forKey: .hidden)
    groups = try? c.decodeIfPresent([String].self, forKey: .groups)
    group = try? c.decodeIfPresent(String.self, forKey: .group)
    hasPayload = !c.allKeys.isEmpty
  }
}
