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
  /// Which destructive action the session list's trailing swipe defaults to
  /// (archive vs permanent delete). Device-local UI pref; reset on logout.
  public var loadDefaultSessionSwipeAction: @Sendable () -> SessionSwipeAction = { .default }
  public var saveDefaultSessionSwipeAction: @Sendable (_ action: SessionSwipeAction) -> Void
  /// Whether the session list shows the always-on "Cron Jobs" section. Device-local UI
  /// pref; defaults to `true` (shown) so the section stays visible until the user opts out.
  public var loadShowCronSection: @Sendable () -> Bool = { true }
  public var saveShowCronSection: @Sendable (_ show: Bool) -> Void
  /// Whether the transcript renders tool/skill activity rows. Device-local UI pref;
  /// defaults to `true` (shown) so existing users see no change. Hiding them keeps the
  /// conversation readable while the agent works (#55) — the rows are pure activity
  /// reporting, never the answer itself.
  public var loadShowToolRows: @Sendable () -> Bool = { true }
  public var saveShowToolRows: @Sendable (_ show: Bool) -> Void
  /// Whether the transcript renders the live/frozen "Thinking" disclosure rows.
  /// Device-local UI pref; defaults to `true` (shown).
  public var loadShowThinkingRows: @Sendable () -> Bool = { true }
  public var saveShowThinkingRows: @Sendable (_ show: Bool) -> Void
  /// Whether the transcript follows new rows to the bottom while a turn streams, i.e.
  /// whether arriving content may move the viewport. Device-local UI pref; defaults to
  /// `true` (follow) — the pre-feature behavior. Turning it off freezes the viewport
  /// where the user left it, so a long-running turn can't scroll the text away from
  /// under someone reading an earlier reply.
  public var loadAutoFollowEnabled: @Sendable () -> Bool = { true }
  public var saveAutoFollowEnabled: @Sendable (_ enabled: Bool) -> Void
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
    let swipeActionKey = "hermes.default-session-swipe-action"
    let showCronSectionKey = "hermes.show-cron-section"
    let showToolRowsKey = "hermes.show-tool-rows"
    let showThinkingRowsKey = "hermes.show-thinking-rows"
    let autoFollowEnabledKey = "hermes.auto-follow-enabled"
    let selectedProfileKey = "hermes.selected-profile-id"
    let pushTokenKey = "hermes.push-device-token"
    let pushSnoozeCountKey = "hermes.push-prompt-snooze-count"
    let pushSnoozeUntilKey = "hermes.push-prompt-snooze-until"
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
      loadDefaultSessionSwipeAction: {
        store.string(forKey: swipeActionKey).flatMap(SessionSwipeAction.init(rawValue:)) ?? .default
      },
      saveDefaultSessionSwipeAction: { store.set($0.rawValue, forKey: swipeActionKey) },
      loadShowCronSection: {
        // Absent key (never toggled) means shown — the section is on by default.
        store.object(forKey: showCronSectionKey) == nil
          ? true
          : store.bool(forKey: showCronSectionKey)
      },
      saveShowCronSection: { store.set($0, forKey: showCronSectionKey) },
      // Every display pref below follows the same rule as the cron-section toggle: an
      // absent key means the pre-feature behavior (rows shown, following on), so an
      // upgrade never silently changes what a user sees.
      loadShowToolRows: { store.object(forKey: showToolRowsKey) == nil ? true : store.bool(forKey: showToolRowsKey) },
      saveShowToolRows: { store.set($0, forKey: showToolRowsKey) },
      loadShowThinkingRows: {
        store.object(forKey: showThinkingRowsKey) == nil ? true : store.bool(forKey: showThinkingRowsKey)
      },
      saveShowThinkingRows: { store.set($0, forKey: showThinkingRowsKey) },
      loadAutoFollowEnabled: {
        store.object(forKey: autoFollowEnabledKey) == nil ? true : store.bool(forKey: autoFollowEnabledKey)
      },
      saveAutoFollowEnabled: { store.set($0, forKey: autoFollowEnabledKey) },
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
      }
    )
  }

  /// Deterministic in-memory store for previews and tests.
  static func inMemory() -> PreferencesClient {
    let box = LockIsolated<String?>(nil)
    let seen = LockIsolated<[String: Int]>([:])
    let pinned = LockIsolated<[String]>([])
    let grouping = LockIsolated<SessionGroupingMode>(.default)
    let swipeAction = LockIsolated<SessionSwipeAction>(.default)
    let showCronSection = LockIsolated<Bool>(true)
    let showToolRows = LockIsolated<Bool>(true)
    let showThinkingRows = LockIsolated<Bool>(true)
    let autoFollowEnabled = LockIsolated<Bool>(true)
    let selectedProfile = LockIsolated<String?>(nil)
    let pushToken = LockIsolated<String?>(nil)
    let pushSnooze = LockIsolated<(count: Int, until: Date)?>(nil)
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
      loadDefaultSessionSwipeAction: { swipeAction.value },
      saveDefaultSessionSwipeAction: { swipeAction.setValue($0) },
      loadShowCronSection: { showCronSection.value },
      saveShowCronSection: { showCronSection.setValue($0) },
      loadShowToolRows: { showToolRows.value },
      saveShowToolRows: { showToolRows.setValue($0) },
      loadShowThinkingRows: { showThinkingRows.value },
      saveShowThinkingRows: { showThinkingRows.setValue($0) },
      loadAutoFollowEnabled: { autoFollowEnabled.value },
      saveAutoFollowEnabled: { autoFollowEnabled.setValue($0) },
      loadSelectedProfileID: { selectedProfile.value },
      saveSelectedProfileID: { selectedProfile.setValue($0) },
      clearSelectedProfileID: { selectedProfile.setValue(nil) },
      loadPushDeviceToken: { pushToken.value },
      savePushDeviceToken: { pushToken.setValue($0) },
      clearPushDeviceToken: { pushToken.setValue(nil) },
      loadPushPromptSnooze: { pushSnooze.value },
      savePushPromptSnooze: { count, until in pushSnooze.setValue((count: count, until: until)) },
      clearPushPromptSnooze: { pushSnooze.setValue(nil) }
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
