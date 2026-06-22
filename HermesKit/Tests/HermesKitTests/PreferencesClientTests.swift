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

  @Test func inMemoryChatRendererRoundTripAndDefault() {
    let prefs = PreferencesClient.inMemory()
    #expect(prefs.loadChatRenderer() == .collectionView) // default when unset

    prefs.saveChatRenderer(.swiftUI)
    #expect(prefs.loadChatRenderer() == .swiftUI)

    prefs.saveChatRenderer(.collectionView)
    #expect(prefs.loadChatRenderer() == .collectionView)
  }

  @Test func liveChatRendererBacksOntoProvidedDefaults() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.renderer")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.renderer")
    let prefs = PreferencesClient.live(defaults: suite)

    #expect(prefs.loadChatRenderer() == .collectionView) // default when unset
    prefs.saveChatRenderer(.swiftUI)
    #expect(suite.string(forKey: "hermes.chat-renderer") == "swiftUI")
    #expect(prefs.loadChatRenderer() == .swiftUI)
  }

  @Test func liveChatRendererDefaultsWhenValueIsGarbage() {
    let suite = UserDefaults(suiteName: "hermes.prefs.test.renderer.garbage")!
    suite.removePersistentDomain(forName: "hermes.prefs.test.renderer.garbage")
    suite.set("not-a-renderer", forKey: "hermes.chat-renderer")
    let prefs = PreferencesClient.live(defaults: suite)
    #expect(prefs.loadChatRenderer() == .collectionView) // unknown raw value → default
  }

  @Test func clearIdentityScopedPrefsKeepsChatRenderer() {
    // chatRenderer is a device-local A/B pref — a user-switch must not wipe it.
    let prefs = PreferencesClient.inMemory()
    prefs.saveChatRenderer(.swiftUI)
    prefs.clearIdentityScopedPrefs()
    #expect(prefs.loadChatRenderer() == .swiftUI)
  }
}
