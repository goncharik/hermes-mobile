import Foundation
import Testing

@testable import HermesKit

struct PreferencesClientTests {
  @Test func inMemoryRoundTripAndClear() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadServerURL() == nil)

    prefs.saveServerURL("http://mac.tailnet:9119")
    #expect(prefs.loadServerURL() == "http://mac.tailnet:9119")

    prefs.clearServerURL()
    #expect(prefs.loadServerURL() == nil)
  }

  @Test func liveBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test")!
    suite.removePersistentDomain(forName: "hermes.prefs.test")
    let prefs = PreferencesClient.live(defaults: suite)

    prefs.saveServerURL("http://example:9119")
    #expect(suite.string(forKey: "hermes.server-url") == "http://example:9119")
    #expect(prefs.loadServerURL() == "http://example:9119")

    prefs.clearServerURL()
    #expect(prefs.loadServerURL() == nil)
  }

  @Test func inMemoryPinnedIDsRoundTrip() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadPinnedIDs() == [])

    prefs.savePinnedIDs(["s1", "s2"])
    #expect(prefs.loadPinnedIDs() == ["s1", "s2"]) // order preserved

    prefs.savePinnedIDs([])
    #expect(prefs.loadPinnedIDs() == [])
  }

  @Test func livePinnedIDsBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.pinned")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.pinned")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadPinnedIDs() == [])
    prefs.savePinnedIDs(["a", "b"])
    #expect(suite.array(forKey: "hermes.pinned-session-ids") as? [String] == ["a", "b"])
    #expect(prefs.loadPinnedIDs() == ["a", "b"])
  }

  @Test func inMemoryGroupingModeRoundTripAndDefault() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadGroupingMode() == .workspace) // default when unset

    prefs.saveGroupingMode(.chronological)
    #expect(prefs.loadGroupingMode() == .chronological)

    prefs.saveGroupingMode(.workspace)
    #expect(prefs.loadGroupingMode() == .workspace)
  }

  @Test func liveGroupingModeBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.grouping")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.grouping")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadGroupingMode() == .workspace) // default when unset
    prefs.saveGroupingMode(.chronological)
    #expect(suite.string(forKey: "hermes.session-grouping-mode") == "chronological")
    #expect(prefs.loadGroupingMode() == .chronological)
  }

  @Test func liveGroupingModeDefaultsWhenValueIsGarbage() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.grouping.garbage")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.grouping.garbage")
    suite.set("not-a-mode", forKey: "hermes.session-grouping-mode")
    let prefs = PreferencesClient.live(defaults: suite)
    #expect(prefs.loadGroupingMode() == .workspace) // unknown raw value → default
  }

  @Test func inMemoryDefaultSwipeActionRoundTripAndDefault() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadDefaultSessionSwipeAction() == .archive) // default when unset

    prefs.saveDefaultSessionSwipeAction(.delete)
    #expect(prefs.loadDefaultSessionSwipeAction() == .delete)

    prefs.saveDefaultSessionSwipeAction(.archive)
    #expect(prefs.loadDefaultSessionSwipeAction() == .archive)
  }

  @Test func liveDefaultSwipeActionBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.swipe")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.swipe")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadDefaultSessionSwipeAction() == .archive) // default when unset
    prefs.saveDefaultSessionSwipeAction(.delete)
    #expect(suite.string(forKey: "hermes.default-session-swipe-action") == "delete")
    #expect(prefs.loadDefaultSessionSwipeAction() == .delete)
  }

  @Test func liveDefaultSwipeActionDefaultsWhenValueIsGarbage() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.swipe.garbage")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.swipe.garbage")
    suite.set("shred", forKey: "hermes.default-session-swipe-action")
    let prefs = PreferencesClient.live(defaults: suite)
    #expect(prefs.loadDefaultSessionSwipeAction() == .archive) // unknown raw value → default
  }

  @Test func inMemoryShowCronSectionRoundTripAndDefault() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadShowCronSection() == true) // default when unset: shown

    prefs.saveShowCronSection(false)
    #expect(prefs.loadShowCronSection() == false)

    prefs.saveShowCronSection(true)
    #expect(prefs.loadShowCronSection() == true)
  }

  @Test func liveShowCronSectionBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.showcron")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.showcron")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadShowCronSection() == true) // default when unset: shown
    prefs.saveShowCronSection(false)
    #expect(suite.bool(forKey: "hermes.show-cron-section") == false)
    #expect(prefs.loadShowCronSection() == false)
  }

  @Test func inMemorySelectedProfileRoundTripAndClear() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadSelectedProfileID() == nil)

    prefs.saveSelectedProfileID("work")
    #expect(prefs.loadSelectedProfileID() == "work")

    prefs.clearSelectedProfileID()
    #expect(prefs.loadSelectedProfileID() == nil)
  }

  @Test func liveSelectedProfileBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.profile")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.profile")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadSelectedProfileID() == nil)
    prefs.saveSelectedProfileID("work")
    #expect(suite.string(forKey: "hermes.selected-profile-id") == "work")
    #expect(prefs.loadSelectedProfileID() == "work")

    prefs.clearSelectedProfileID()
    #expect(suite.string(forKey: "hermes.selected-profile-id") == nil)
    #expect(prefs.loadSelectedProfileID() == nil)
  }

  // MARK: Push prompt snooze

  @Test func inMemoryPushPromptSnoozeRoundTripAndClear() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadPushPromptSnooze() == nil) // never snoozed

    let until = Date(timeIntervalSince1970: 1_750_000_000)
    prefs.savePushPromptSnooze(3, until)
    let snooze = prefs.loadPushPromptSnooze()
    #expect(snooze?.count == 3)
    #expect(snooze?.until == until)

    prefs.clearPushPromptSnooze()
    #expect(prefs.loadPushPromptSnooze() == nil)
  }

  @Test func livePushPromptSnoozeBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.pushsnooze")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.pushsnooze")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadPushPromptSnooze() == nil) // no `until` persisted yet
    let until = Date(timeIntervalSince1970: 1_750_000_000)
    prefs.savePushPromptSnooze(2, until)
    #expect(suite.integer(forKey: "hermes.push-prompt-snooze-count") == 2)
    let snooze = prefs.loadPushPromptSnooze()
    #expect(snooze?.count == 2)
    #expect(snooze?.until == until)

    prefs.clearPushPromptSnooze()
    #expect(prefs.loadPushPromptSnooze() == nil)
  }

  // MARK: Display prefs (#55)

  @Test func inMemoryDisplayPrefsDefaultToPreFeatureBehavior() {
    let prefs = PreferencesClient.inMemory()
    // Every one of these must default to what the app did before the feature existed —
    // absent-and-unset has to mean "rows shown, following on", or an upgrade silently
    // changes what a user sees.
    #expect(prefs.loadShowToolRows() == true)
    #expect(prefs.loadShowThinkingRows() == true)
    #expect(prefs.loadAutoFollowEnabled() == true)
  }

  @Test func inMemoryDisplayPrefsRoundTrip() {
    let prefs = PreferencesClient.inMemory()

    prefs.saveShowToolRows(false)
    prefs.saveShowThinkingRows(false)
    prefs.saveAutoFollowEnabled(false)
    #expect(prefs.loadShowToolRows() == false)
    #expect(prefs.loadShowThinkingRows() == false)
    #expect(prefs.loadAutoFollowEnabled() == false)

    prefs.saveShowToolRows(true)
    prefs.saveShowThinkingRows(true)
    prefs.saveAutoFollowEnabled(true)
    #expect(prefs.loadShowToolRows() == true)
    #expect(prefs.loadShowThinkingRows() == true)
    #expect(prefs.loadAutoFollowEnabled() == true)
  }

  @Test func liveDisplayPrefsBackOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.display")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.display")
    let prefs = PreferencesClient.live(defaults: suite)

    // Absent keys → the pre-feature behavior.
    #expect(prefs.loadShowToolRows() == true)
    #expect(prefs.loadShowThinkingRows() == true)
    #expect(prefs.loadAutoFollowEnabled() == true)

    prefs.saveShowToolRows(false)
    prefs.saveShowThinkingRows(false)
    prefs.saveAutoFollowEnabled(false)
    #expect(suite.bool(forKey: "hermes.show-tool-rows") == false)
    #expect(suite.bool(forKey: "hermes.show-thinking-rows") == false)
    #expect(suite.bool(forKey: "hermes.auto-follow-enabled") == false)
    #expect(prefs.loadShowToolRows() == false)
    #expect(prefs.loadShowThinkingRows() == false)
    #expect(prefs.loadAutoFollowEnabled() == false)
  }

  /// The prefs are independent: turning one off must not disturb the others (each `Menu`
  /// toggle writes only its own key).
  @Test func displayPrefsAreIndependent() {
    let prefs = PreferencesClient.inMemory()

    prefs.saveShowToolRows(false)
    #expect(prefs.loadShowToolRows() == false)
    #expect(prefs.loadShowThinkingRows() == true)
    #expect(prefs.loadAutoFollowEnabled() == true)
  }
}
