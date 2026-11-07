import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Writes the App Group mirror the sessions widget reads (`WidgetSessionSnapshot`) and asks
/// WidgetKit to reload it. The widget extension never touches the network or the Keychain, so
/// this file is its ONLY data source; `AppFeature` writes it from the single `agentStatus` edge
/// (plus the scene edges, which only restamp `freshUntil`) and clears it on every logout.
@DependencyClient
public struct WidgetMirrorClient: Sendable {
  /// Atomically replaces the mirror with `snapshot`. Throws when the App Group container is
  /// unavailable or the write fails; the caller logs it (the mirror is non-authoritative).
  public var write: @Sendable (_ snapshot: WidgetSessionSnapshot) throws -> Void
  /// Replaces the mirror with the signed-out snapshot (`WidgetSessionSnapshot.signedOut`), so a
  /// widget shows "Sign in to Hermes" instead of the previous identity's sessions.
  public var clear: @Sendable () throws -> Void
  /// Reloads the sessions widget's timelines so it re-reads the mirror.
  public var reloadTimelines: @Sendable () -> Void
}

/// Thrown by the file-backed client when the process has no App Group container (a build
/// missing the entitlement).
public struct WidgetMirrorUnavailable: Error, Equatable, Sendable {
  public init() {}
}

extension WidgetMirrorClient: DependencyKey {
  /// No-op double (the project convention for fire-and-forget surface clients, like
  /// `QuickActionsClient`): every logout and every list fetch reaches this client, so an
  /// unimplemented default would fail every test that crosses one. Override with a recorder to
  /// assert the writes.
  public static var testValue: WidgetMirrorClient {
    WidgetMirrorClient(write: { _ in }, clear: {}, reloadTimelines: {})
  }

  /// The mirror as a JSON file at `fileURL` (`nil` → every write throws
  /// `WidgetMirrorUnavailable`). Atomic writes, so the widget never reads a torn file. The
  /// live value points this at the App Group container; tests point it at a temp directory.
  public static func fileBacked(
    at fileURL: URL?,
    reloadTimelines: @escaping @Sendable () -> Void
  ) -> WidgetMirrorClient {
    @Sendable func store(_ snapshot: WidgetSessionSnapshot) throws {
      guard let fileURL else { throw WidgetMirrorUnavailable() }
      try snapshot.encoded().write(to: fileURL, options: .atomic)
    }
    return WidgetMirrorClient(
      write: { try store($0) },
      clear: { try store(.signedOut) },
      reloadTimelines: reloadTimelines
    )
  }
}

public extension DependencyValues {
  var widgetMirror: WidgetMirrorClient {
    get { self[WidgetMirrorClient.self] }
    set { self[WidgetMirrorClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

#if os(iOS) && canImport(WidgetKit)
  import WidgetKit

  extension WidgetMirrorClient {
    public static var liveValue: WidgetMirrorClient {
      .fileBacked(at: AppGroup.snapshotFileURL()) {
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.sessionsWidgetKind)
      }
    }
  }
#else
  extension WidgetMirrorClient {
    /// No widgets off-device (macOS `swift test`): the no-op double.
    public static var liveValue: WidgetMirrorClient { testValue }
  }
#endif
