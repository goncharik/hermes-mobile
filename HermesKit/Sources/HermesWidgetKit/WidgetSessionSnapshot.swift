import Foundation

/// One session as the widgets show it: what the app projected from the session list, already
/// filtered (interactive only), sorted and capped.
public struct WidgetSessionRow: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var workspace: String?
  public var status: SessionStatus
  public var updatedAt: Date?
  /// The profile the session belongs to, for the `openSession` deep link; `nil` when the
  /// server has no profiles API.
  public var profile: String?

  public init(
    id: String,
    title: String,
    workspace: String? = nil,
    status: SessionStatus,
    updatedAt: Date? = nil,
    profile: String? = nil
  ) {
    self.id = id
    self.title = title
    self.workspace = workspace
    self.status = status
    self.updatedAt = updatedAt
    self.profile = profile
  }
}

/// The App Group mirror the app writes and the sessions widget reads — the widget's ONLY data
/// source (it never touches the network or the Keychain). Non-authoritative: the app rewrites
/// it from the single `agentStatus` edge, and past `freshUntil` the widget says "Outdated"
/// instead of guessing.
public struct WidgetSessionSnapshot: Codable, Equatable, Sendable {
  /// Bumped on an incompatible format change. An older extension reading a newer file treats
  /// it as missing rather than misreading it.
  public static let currentVersion = 1
  /// The most rows a widget shows (the large family).
  public static let maxRows = 5

  public var version: Int
  /// Until when the app vouches for the rows' working / needs-input states.
  public var freshUntil: Date
  public var isSignedIn: Bool
  /// At most `maxRows`, in display order.
  public var rows: [WidgetSessionRow]

  public init(
    version: Int = Self.currentVersion,
    freshUntil: Date,
    isSignedIn: Bool,
    rows: [WidgetSessionRow]
  ) {
    self.version = version
    self.freshUntil = freshUntil
    self.isSignedIn = isSignedIn
    self.rows = Array(rows.prefix(Self.maxRows))
  }

  /// What the mirror holds after a logout: no rows, nothing fresh to vouch for.
  public static let signedOut = WidgetSessionSnapshot(
    freshUntil: Date(timeIntervalSinceReferenceDate: 0),
    isSignedIn: false,
    rows: []
  )

  /// The bytes the app writes into the App Group container.
  public func encoded() throws -> Data {
    try Self.encoder.encode(self)
  }

  /// The mirror read back, or `nil` when there is none, it is corrupt, or it was written by a
  /// newer format (`version > currentVersion`). Never throws: a widget shows its signed-out
  /// / placeholder state instead.
  public static func decodeLeniently(_ data: Data?) -> WidgetSessionSnapshot? {
    guard let data,
      let header = try? JSONDecoder().decode(VersionHeader.self, from: data),
      header.version <= currentVersion,
      let snapshot = try? JSONDecoder().decode(WidgetSessionSnapshot.self, from: data)
    else { return nil }
    return snapshot
  }

  /// The mirror at `url` (the extension passes `AppGroup.snapshotFileURL()`), or `nil` when
  /// there is no container, no file, or `decodeLeniently` rejects it.
  public static func read(from url: URL?) -> WidgetSessionSnapshot? {
    decodeLeniently(url.flatMap { try? Data(contentsOf: $0) })
  }

  private struct VersionHeader: Decodable {
    var version: Int
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
}
