import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Serializes the owned-update slot's read-modify-write (compare-and-clear) across threads.
private let ownedUpdateLock = NSLock()

/// Legacy pins not yet reconciled with server membership.
/// Server-keyed pending IDs survive incomplete lists, profile switches, and failed
/// writes. Retire them only on explicit server true or an acknowledged upload.
public struct PinMigration: Codable, Equatable, Sendable {
  public var pendingIDs: [String]

  public init(pendingIDs: [String]) { self.pendingIDs = pendingIDs }
}

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
  /// Legacy pin migration snapshots keyed by stable server URL, never by bearer token.
  public var loadPinMigration: @Sendable (_ server: String) -> PinMigration? = { _ in nil }
  public var savePinMigration: @Sendable (_ server: String, _ migration: PinMigration) -> Void
  public var clearPinMigrations: @Sendable () -> Void
  /// Which destructive action the session list's trailing swipe defaults to
  /// (archive vs permanent delete). Device-local UI pref; reset on logout.
  public var loadDefaultSessionSwipeAction: @Sendable () -> SessionSwipeAction = { .default }
  public var saveDefaultSessionSwipeAction: @Sendable (_ action: SessionSwipeAction) -> Void
  /// Currently selected Hermes profile name. Device-local — we never change the server's
  /// sticky active profile. Also carries the profiles capability verdict — read it through
  /// `SessionListFeature.State.persistedProfileName` / `persistedProfilesSupported`.
  public var loadSelectedProfileID: @Sendable () -> String? = { nil }
  public var saveSelectedProfileID: @Sendable (_ id: String) -> Void
  public var clearSelectedProfileID: @Sendable () -> Void
  /// Last APNs device token we registered with the agent (lowercase hex). Non-secret — it's
  /// just the routing address. Persisted so logout can `unregisterPush` with the right token
  /// even if the live `register()` stream isn't currently producing one. Cleared on logout.
  public var loadPushDeviceToken: @Sendable () -> String? = { nil }
  public var savePushDeviceToken: @Sendable (_ token: String) -> Void
  public var clearPushDeviceToken: @Sendable () -> Void
  /// Push info-sheet snooze: the number of "Later" taps so far (drives the Fibonacci backoff)
  /// and the Date until which the sheet stays suppressed. `nil` count/date means never snoozed.
  /// Cleared on logout (and when the plugin becomes ready, so a later uninstall re-prompts fresh).
  public var loadPushPromptSnooze: @Sendable () -> (count: Int, until: Date)? = { nil }
  public var savePushPromptSnooze: @Sendable (_ count: Int, _ until: Date) -> Void
  public var clearPushPromptSnooze: @Sendable () -> Void
  /// "Read replies aloud" (#74). Device-local, default off — deliberately NOT the server's
  /// `voice.auto_tts` (the messaging gateway's voice-reply default; desktop decoupled the two
  /// upstream). Never touches `/api/config`. Cleared on logout.
  public var loadAutoSpeakReplies: @Sendable () -> Bool = { false }
  public var saveAutoSpeakReplies: @Sendable (_ enabled: Bool) -> Void
  public var clearAutoSpeakReplies: @Sendable () -> Void
  /// Model picker (#130): the provider ids (`ModelOptions.Provider.id`) whose cards are
  /// collapsed. Default empty = every card expanded (desktop parity). Device-global, cleared
  /// on logout via `clearModelPickerPrefs()`.
  public var loadCollapsedModelProviders: @Sendable () -> Set<String> = { [] }
  public var saveCollapsedModelProviders: @Sendable (_ providerIDs: Set<String>) -> Void
  /// Model picker (#130): starred models, order = star order (the Favorites card's order).
  /// Device-global, cleared on logout via `clearModelPickerPrefs()`.
  public var loadFavoriteModels: @Sendable () -> [FavoriteModel] = { [] }
  public var saveFavoriteModels: @Sendable (_ favorites: [FavoriteModel]) -> Void
  /// The aggregate "running agents" Live Activity (#138). Device-local, default ON.
  public var loadLiveActivityEnabled: @Sendable () -> Bool = { true }
  public var saveLiveActivityEnabled: @Sendable (_ enabled: Bool) -> Void
  /// Whether the Live Activity shows the headline session's title (off = workspace only).
  /// Device-local, default ON.
  public var loadLiveActivityShowsTitles: @Sendable () -> Bool = { true }
  public var saveLiveActivityShowsTitles: @Sendable (_ shows: Bool) -> Void
  /// Resets both Live Activity prefs to their defaults (on). Called on logout.
  public var clearLiveActivityPrefs: @Sendable () -> Void
  /// The agent update THIS phone started (`OwnedAgentUpdate`: action id + POST time, no
  /// secret), so reopening Settings or relaunching re-observes it instead of losing it. One
  /// slot: loading under a different `scope` (server + account) drops it. Cleared on logout.
  public var loadOwnedAgentUpdate: @Sendable (_ scope: String) -> OwnedAgentUpdate? = { _ in nil }
  public var saveOwnedAgentUpdate: @Sendable (_ owned: OwnedAgentUpdate) -> Void
  /// Compare-and-clear: drops the slot only while it still names `actionID`, so settling an
  /// old run can't erase a newer one; `nil` clears whatever is stored (logout).
  public var clearOwnedAgentUpdate: @Sendable (_ actionID: String?) -> Void
  /// Whether the user hid the session list's onboarding tips row (#136). Device-local UI pref,
  /// default `false` (tips shown). Cleared on logout, so the next sign-in shows them again;
  /// deliberately NOT identity-scoped — a re-auth user switch keeps it.
  public var loadOnboardingTipsDismissed: @Sendable () -> Bool = { false }
  public var saveOnboardingTipsDismissed: @Sendable (_ dismissed: Bool) -> Void
  public var clearOnboardingTipsDismissed: @Sendable () -> Void
}

public extension PreferencesClient {
  /// Drop the model picker's collapse + favorites prefs. Part of every logout ("logout clears
  /// every prefs entry"); deliberately NOT in `clearIdentityScopedPrefs` — like the read-aloud
  /// toggle they are device-global UI prefs, not tied to an account.
  func clearModelPickerPrefs() {
    saveCollapsedModelProviders([])
    saveFavoriteModels([])
  }
}

public extension PreferencesClient {
  /// Drop the prefs that are scoped to a *specific user/account* — pins, per-session unread
  /// counts, and the selected profile. Used on a re-auth **user-switch** (different account
  /// signs in mid-session) where the prior user's device-local state must not leak across.
  /// The server URL (and the list's UI prefs) survive — the user stays on the same server.
  func clearIdentityScopedPrefs() {
    savePinnedIDs([])
    clearPinMigrations()
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
    let migrationKey = "hermes.pin-migrations-v1"
    let swipeActionKey = "hermes.default-session-swipe-action"
    let selectedProfileKey = "hermes.selected-profile-id"
    let pushTokenKey = "hermes.push-device-token"
    let pushSnoozeCountKey = "hermes.push-prompt-snooze-count"
    let pushSnoozeUntilKey = "hermes.push-prompt-snooze-until"
    let autoSpeakKey = "hermes.auto-speak-replies"
    let collapsedProvidersKey = "hermes.model-picker.collapsed-providers"
    let favoriteModelsKey = "hermes.model-picker.favorite-models"
    let liveActivityKey = "hermes.live-activity-enabled"
    let liveActivityTitlesKey = "hermes.live-activity-shows-titles"
    let ownedUpdateKey = "hermes.agent-update-owned"
    let onboardingTipsDismissedKey = "hermes.onboarding-tips-dismissed"
    // UserDefaults is documented thread-safe but not Sendable.
    nonisolated(unsafe) let store = defaults

    // Retired prefs, dropped once when the client is built so an upgrade leaves no orphaned
    // default behind: the workspace/chronological grouping mode (the list is always
    // date-sectioned now) and the cron-section hide and collapse toggles (cron runs live in
    // their own tab now). Not migrated.
    for retired in ["hermes.session-grouping-mode", "hermes.show-cron-section", "hermes.cron-section-collapsed"] {
      store.removeObject(forKey: retired)
    }

    return PreferencesClient(
      loadServerURL: { store.string(forKey: key) },
      saveServerURL: { store.set($0, forKey: key) },
      clearServerURL: { store.removeObject(forKey: key) },
      loadSeenCounts: { (store.dictionary(forKey: seenKey) as? [String: Int]) ?? [:] },
      saveSeenCounts: { store.set($0, forKey: seenKey) },
      loadPinnedIDs: { (store.array(forKey: pinnedKey) as? [String]) ?? [] },
      savePinnedIDs: { store.set($0, forKey: pinnedKey) },
      loadPinMigration: { server in
        guard let data = store.dictionary(forKey: migrationKey)?[server] as? Data else { return nil }
        return try? JSONDecoder().decode(PinMigration.self, from: data)
      },
      savePinMigration: { server, migration in
        guard let data = try? JSONEncoder().encode(migration) else { return }
        var migrations = store.dictionary(forKey: migrationKey) ?? [:]
        migrations[server] = data
        store.set(migrations, forKey: migrationKey)
      },
      clearPinMigrations: { store.removeObject(forKey: migrationKey) },
      loadDefaultSessionSwipeAction: {
        store.string(forKey: swipeActionKey).flatMap(SessionSwipeAction.init(rawValue:)) ?? .default
      },
      saveDefaultSessionSwipeAction: { store.set($0.rawValue, forKey: swipeActionKey) },
      loadSelectedProfileID: { store.string(forKey: selectedProfileKey) },
      saveSelectedProfileID: { store.set($0, forKey: selectedProfileKey) },
      clearSelectedProfileID: { store.removeObject(forKey: selectedProfileKey) },
      loadPushDeviceToken: { store.string(forKey: pushTokenKey) },
      savePushDeviceToken: { store.set($0, forKey: pushTokenKey) },
      clearPushDeviceToken: { store.removeObject(forKey: pushTokenKey) },
      loadPushPromptSnooze: {
        // A missing `until` (never snoozed) returns nil; the count defaults to 0 otherwise.
        guard store.object(forKey: pushSnoozeUntilKey) != nil else { return nil }
        let until = Date(timeIntervalSince1970: store.double(forKey: pushSnoozeUntilKey))
        return (count: store.integer(forKey: pushSnoozeCountKey), until: until)
      },
      savePushPromptSnooze: { count, until in
        store.set(count, forKey: pushSnoozeCountKey)
        store.set(until.timeIntervalSince1970, forKey: pushSnoozeUntilKey)
      },
      clearPushPromptSnooze: {
        store.removeObject(forKey: pushSnoozeCountKey)
        store.removeObject(forKey: pushSnoozeUntilKey)
      },
      loadAutoSpeakReplies: { store.bool(forKey: autoSpeakKey) }, // unset → false
      saveAutoSpeakReplies: { store.set($0, forKey: autoSpeakKey) },
      clearAutoSpeakReplies: { store.removeObject(forKey: autoSpeakKey) },
      loadCollapsedModelProviders: {
        Set((store.array(forKey: collapsedProvidersKey) as? [String]) ?? [])
      },
      saveCollapsedModelProviders: { ids in
        // An empty set removes the key, so a logout leaves no default behind.
        if ids.isEmpty {
          store.removeObject(forKey: collapsedProvidersKey)
        } else {
          store.set(ids.sorted(), forKey: collapsedProvidersKey)
        }
      },
      loadFavoriteModels: {
        // Missing or undecodable data → no favorites (a corrupt blob must not crash the picker).
        guard let data = store.data(forKey: favoriteModelsKey) else { return [] }
        return (try? JSONDecoder().decode([FavoriteModel].self, from: data)) ?? []
      },
      saveFavoriteModels: { favorites in
        if favorites.isEmpty {
          store.removeObject(forKey: favoriteModelsKey)
        } else if let data = try? JSONEncoder().encode(favorites) {
          store.set(data, forKey: favoriteModelsKey)
        }
      },
      // Default ON: an unset key reads true (`bool(forKey:)` would read false).
      loadLiveActivityEnabled: { store.object(forKey: liveActivityKey) as? Bool ?? true },
      saveLiveActivityEnabled: { store.set($0, forKey: liveActivityKey) },
      loadLiveActivityShowsTitles: { store.object(forKey: liveActivityTitlesKey) as? Bool ?? true },
      saveLiveActivityShowsTitles: { store.set($0, forKey: liveActivityTitlesKey) },
      clearLiveActivityPrefs: {
        store.removeObject(forKey: liveActivityKey)
        store.removeObject(forKey: liveActivityTitlesKey)
      },
      loadOwnedAgentUpdate: { scope in
        ownedUpdateLock.withLock {
          guard let data = store.data(forKey: ownedUpdateKey) else { return nil }
          guard let owned = try? JSONDecoder().decode(OwnedAgentUpdate.self, from: data),
                owned.scope == scope
          else {
            store.removeObject(forKey: ownedUpdateKey)
            return nil
          }
          return owned
        }
      },
      saveOwnedAgentUpdate: { owned in
        ownedUpdateLock.withLock {
          store.set(try? JSONEncoder().encode(owned), forKey: ownedUpdateKey)
        }
      },
      clearOwnedAgentUpdate: { actionID in
        ownedUpdateLock.withLock {
          if let actionID {
            guard let data = store.data(forKey: ownedUpdateKey),
                  let owned = try? JSONDecoder().decode(OwnedAgentUpdate.self, from: data),
                  owned.actionID == actionID
            else { return }
          }
          store.removeObject(forKey: ownedUpdateKey)
        }
      },
      loadOnboardingTipsDismissed: { store.bool(forKey: onboardingTipsDismissedKey) }, // unset → false
      saveOnboardingTipsDismissed: { store.set($0, forKey: onboardingTipsDismissedKey) },
      clearOnboardingTipsDismissed: { store.removeObject(forKey: onboardingTipsDismissedKey) }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> PreferencesClient {
    let box = LockIsolated<String?>(nil)
    let seen = LockIsolated<[String: Int]>([:])
    let pinned = LockIsolated<[String]>([])
    let migrations = LockIsolated<[String: PinMigration]>([:])
    let swipeAction = LockIsolated<SessionSwipeAction>(.default)
    let selectedProfile = LockIsolated<String?>(nil)
    let pushToken = LockIsolated<String?>(nil)
    let pushSnooze = LockIsolated<(count: Int, until: Date)?>(nil)
    let autoSpeak = LockIsolated(false)
    let collapsedProviders = LockIsolated<Set<String>>([])
    let favoriteModels = LockIsolated<[FavoriteModel]>([])
    let liveActivity = LockIsolated(true)
    let liveActivityTitles = LockIsolated(true)
    let ownedUpdate = LockIsolated<OwnedAgentUpdate?>(nil)
    let onboardingTipsDismissed = LockIsolated(false)
    return PreferencesClient(
      loadServerURL: { box.value },
      saveServerURL: { url in box.setValue(url) },
      clearServerURL: { box.setValue(nil) },
      loadSeenCounts: { seen.value },
      saveSeenCounts: { seen.setValue($0) },
      loadPinnedIDs: { pinned.value },
      savePinnedIDs: { pinned.setValue($0) },
      loadPinMigration: { migrations.value[$0] },
      savePinMigration: { server, migration in migrations.withValue { $0[server] = migration } },
      clearPinMigrations: { migrations.setValue([:]) },
      loadDefaultSessionSwipeAction: { swipeAction.value },
      saveDefaultSessionSwipeAction: { swipeAction.setValue($0) },
      loadSelectedProfileID: { selectedProfile.value },
      saveSelectedProfileID: { selectedProfile.setValue($0) },
      clearSelectedProfileID: { selectedProfile.setValue(nil) },
      loadPushDeviceToken: { pushToken.value },
      savePushDeviceToken: { pushToken.setValue($0) },
      clearPushDeviceToken: { pushToken.setValue(nil) },
      loadPushPromptSnooze: { pushSnooze.value },
      savePushPromptSnooze: { count, until in pushSnooze.setValue((count: count, until: until)) },
      clearPushPromptSnooze: { pushSnooze.setValue(nil) },
      loadAutoSpeakReplies: { autoSpeak.value },
      saveAutoSpeakReplies: { autoSpeak.setValue($0) },
      clearAutoSpeakReplies: { autoSpeak.setValue(false) },
      loadCollapsedModelProviders: { collapsedProviders.value },
      saveCollapsedModelProviders: { collapsedProviders.setValue($0) },
      loadFavoriteModels: { favoriteModels.value },
      saveFavoriteModels: { favoriteModels.setValue($0) },
      loadLiveActivityEnabled: { liveActivity.value },
      saveLiveActivityEnabled: { liveActivity.setValue($0) },
      loadLiveActivityShowsTitles: { liveActivityTitles.value },
      saveLiveActivityShowsTitles: { liveActivityTitles.setValue($0) },
      clearLiveActivityPrefs: {
        liveActivity.setValue(true)
        liveActivityTitles.setValue(true)
      },
      loadOwnedAgentUpdate: { scope in
        ownedUpdate.withValue { value in
          guard let owned = value else { return nil }
          guard owned.scope == scope else { value = nil; return nil }
          return owned
        }
      },
      saveOwnedAgentUpdate: { ownedUpdate.setValue($0) },
      clearOwnedAgentUpdate: { actionID in
        ownedUpdate.withValue { value in
          if actionID == nil || value?.actionID == actionID { value = nil }
        }
      },
      loadOnboardingTipsDismissed: { onboardingTipsDismissed.value },
      saveOnboardingTipsDismissed: { onboardingTipsDismissed.setValue($0) },
      clearOnboardingTipsDismissed: { onboardingTipsDismissed.setValue(false) }
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
