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

  @Test func liveClientDropsRetiredListPrefKeys() {
    // The grouping mode and the cron-section hide / collapse toggles are retired (the list
    // is always date-sectioned and cron runs have their own tab). A build that persisted any
    // of them leaves the key behind; building the live client clears them, untranslated,
    // and leaves the prefs that are still in use alone.
    let suite = UserDefaults(suiteName: "hermes.prefs.test.retired.list.prefs")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.retired.list.prefs")
    let retired = ["hermes.session-grouping-mode", "hermes.show-cron-section", "hermes.cron-section-collapsed"]
    for key in retired { suite.set(true, forKey: key) }
    suite.set("delete", forKey: "hermes.default-session-swipe-action")
    let prefs = PreferencesClient.live(defaults: suite)

    for key in retired { #expect(suite.object(forKey: key) == nil, "\(key) is cleared") }
    #expect(prefs.loadDefaultSessionSwipeAction() == .delete)
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

  // MARK: Read replies aloud (#74)

  @Test func inMemoryAutoSpeakRepliesRoundTripAndClear() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadAutoSpeakReplies() == false) // default off

    prefs.saveAutoSpeakReplies(true)
    #expect(prefs.loadAutoSpeakReplies() == true)

    prefs.saveAutoSpeakReplies(false)
    #expect(prefs.loadAutoSpeakReplies() == false)

    prefs.saveAutoSpeakReplies(true)
    prefs.clearAutoSpeakReplies()
    #expect(prefs.loadAutoSpeakReplies() == false)
  }

  @Test func liveAutoSpeakRepliesBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.autospeak")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.autospeak")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadAutoSpeakReplies() == false) // unset → off
    prefs.saveAutoSpeakReplies(true)
    #expect(suite.object(forKey: "hermes.auto-speak-replies") as? Bool == true)
    #expect(prefs.loadAutoSpeakReplies() == true)

    prefs.clearAutoSpeakReplies()
    #expect(suite.object(forKey: "hermes.auto-speak-replies") == nil) // removed, not set false
    #expect(prefs.loadAutoSpeakReplies() == false)
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
}
