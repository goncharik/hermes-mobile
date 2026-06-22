import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Non-secret, persisted app preferences. Currently just the last server URL, kept so
/// the app can auto-reconnect on launch without re-running onboarding (the token lives
/// in `KeychainClient`). Live implementation backs onto `UserDefaults`; an in-memory
/// variant is used for previews and tests.
@DependencyClient
public struct PreferencesClient: Sendable {
  public var loadServerURL: @Sendable () -> String? = { nil }
  public var saveServerURL: @Sendable (_ url: String) -> Void
  public var clearServerURL: @Sendable () -> Void
  /// Last-seen message count per session id — used to flag unread activity.
  public var loadSeenCounts: @Sendable () -> [String: Int] = { [:] }
  public var saveSeenCounts: @Sendable (_ counts: [String: Int]) -> Void
  /// Pinned session ids, ordered = display order in the top "Pinned" section.
  public var loadPinnedIDs: @Sendable () -> [String] = { [] }
  public var savePinnedIDs: @Sendable (_ ids: [String]) -> Void
  /// How the session list groups its rows (workspace vs chronological). Device-local UI pref.
  public var loadGroupingMode: @Sendable () -> SessionGroupingMode = { .default }
  public var saveGroupingMode: @Sendable (_ mode: SessionGroupingMode) -> Void
  /// Currently selected Hermes profile name. Device-local — we never change the server's
  /// sticky active profile. `nil` means the default profile.
  public var loadSelectedProfileID: @Sendable () -> String? = { nil }
  public var saveSelectedProfileID: @Sendable (_ id: String) -> Void
  public var clearSelectedProfileID: @Sendable () -> Void
  /// Which transcript rendering engine the chat screen uses. Device-local A/B preference;
  /// **not** identity-scoped, so it survives logout.
  public var loadChatRenderer: @Sendable () -> ChatRendererKind = { .default }
  public var saveChatRenderer: @Sendable (_ kind: ChatRendererKind) -> Void
}

public extension PreferencesClient {
  /// Drop the prefs that are scoped to a *specific user/account* — pins, per-session unread
  /// counts, and the selected profile. Used on a re-auth **user-switch** (different account
  /// signs in mid-session) where the prior user's device-local state must not leak across.
  /// The server URL (and grouping mode) survive — the user stays on the same server.
  func clearIdentityScopedPrefs() {
    savePinnedIDs([])
    saveSeenCounts([:])
    clearSelectedProfileID()
  }
}

public extension PreferencesClient {
  /// `UserDefaults`-backed implementation.
  static func live(defaults: UserDefaults = .standard) -> PreferencesClient {
    let key = "hermes.server-url"
    let seenKey = "hermes.seen-message-counts"
    let pinnedKey = "hermes.pinned-session-ids"
    let groupingKey = "hermes.session-grouping-mode"
    let selectedProfileKey = "hermes.selected-profile-id"
    let chatRendererKey = "hermes.chat-renderer"
    // UserDefaults is documented thread-safe but not Sendable.
    nonisolated(unsafe) let store = defaults
    return PreferencesClient(
      loadServerURL: { store.string(forKey: key) },
      saveServerURL: { store.set($0, forKey: key) },
      clearServerURL: { store.removeObject(forKey: key) },
      loadSeenCounts: { (store.dictionary(forKey: seenKey) as? [String: Int]) ?? [:] },
      saveSeenCounts: { store.set($0, forKey: seenKey) },
      loadPinnedIDs: { (store.array(forKey: pinnedKey) as? [String]) ?? [] },
      savePinnedIDs: { store.set($0, forKey: pinnedKey) },
      loadGroupingMode: {
        store.string(forKey: groupingKey).flatMap(SessionGroupingMode.init(rawValue:)) ?? .default
      },
      saveGroupingMode: { store.set($0.rawValue, forKey: groupingKey) },
      loadSelectedProfileID: { store.string(forKey: selectedProfileKey) },
      saveSelectedProfileID: { store.set($0, forKey: selectedProfileKey) },
      clearSelectedProfileID: { store.removeObject(forKey: selectedProfileKey) },
      loadChatRenderer: {
        store.string(forKey: chatRendererKey).flatMap(ChatRendererKind.init(rawValue:)) ?? .default
      },
      saveChatRenderer: { store.set($0.rawValue, forKey: chatRendererKey) }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> PreferencesClient {
    let box = LockIsolated<String?>(nil)
    let seen = LockIsolated<[String: Int]>([:])
    let pinned = LockIsolated<[String]>([])
    let grouping = LockIsolated<SessionGroupingMode>(.default)
    let selectedProfile = LockIsolated<String?>(nil)
    let chatRenderer = LockIsolated<ChatRendererKind>(.default)
    return PreferencesClient(
      loadServerURL: { box.value },
      saveServerURL: { url in box.setValue(url) },
      clearServerURL: { box.setValue(nil) },
      loadSeenCounts: { seen.value },
      saveSeenCounts: { seen.setValue($0) },
      loadPinnedIDs: { pinned.value },
      savePinnedIDs: { pinned.setValue($0) },
      loadGroupingMode: { grouping.value },
      saveGroupingMode: { grouping.setValue($0) },
      loadSelectedProfileID: { selectedProfile.value },
      saveSelectedProfileID: { selectedProfile.setValue($0) },
      clearSelectedProfileID: { selectedProfile.setValue(nil) },
      loadChatRenderer: { chatRenderer.value },
      saveChatRenderer: { chatRenderer.setValue($0) }
    )
  }
}

extension PreferencesClient: DependencyKey {
  public static var liveValue: PreferencesClient { .live() }
  public static var testValue: PreferencesClient { .inMemory() }
}

public extension DependencyValues {
  var preferences: PreferencesClient {
    get { self[PreferencesClient.self] }
    set { self[PreferencesClient.self] = newValue }
  }
}
