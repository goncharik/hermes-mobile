import Foundation

/// The App Group the app and the widget extension share. The app writes the widget mirror
/// (`WidgetSessionSnapshot`) into its container; the extension only reads it — it never
/// touches the network or the Keychain.
public enum AppGroup {
  public static let identifier = "group.me.honcharenko.HermesMobile"
  public static let snapshotFileName = "widget-sessions.json"
  /// The `kind` of the sessions widget — the one widget fed by the mirror, so the app reloads
  /// just its timelines after a write.
  public static let sessionsWidgetKind = "me.honcharenko.HermesMobile.Widgets.Sessions"

  /// Where the widget mirror lives; `nil` when the process lacks the App Group entitlement.
  public static func snapshotFileURL(fileManager: FileManager = .default) -> URL? {
    fileManager
      .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
      .appendingPathComponent(snapshotFileName, isDirectory: false)
  }
}
