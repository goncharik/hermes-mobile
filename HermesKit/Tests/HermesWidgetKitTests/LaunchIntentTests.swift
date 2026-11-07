import Foundation
import HermesWidgetKit
import Testing

/// The quick-action mapping, exercised against `HermesWidgetKit` alone — the module the widget
/// extension links — so a dependency creeping back into HermesKit would fail to compile here.
struct LaunchIntentTests {
  /// The literals are pinned on purpose: `Project.swift` repeats them in
  /// `UIApplicationShortcutItems`, so renaming one here must fail a test.
  @Test func shortcutTypesArePinned() {
    #expect(LaunchIntent.newChatShortcutType == "me.honcharenko.HermesMobile.new-chat")
    #expect(LaunchIntent.dictateShortcutType == "me.honcharenko.HermesMobile.dictate")
    #expect(LaunchIntent.newChat.shortcutItemType == LaunchIntent.newChatShortcutType)
    #expect(LaunchIntent.newChatWithDictation.shortcutItemType == LaunchIntent.dictateShortcutType)
  }

  @Test(arguments: [LaunchIntent.newChat, .newChatWithDictation])
  func shortcutTypeRoundTrips(_ intent: LaunchIntent) {
    #expect(LaunchIntent(shortcutItemType: intent.shortcutItemType) == intent)
  }

  @Test(arguments: ["", "me.honcharenko.HermesMobile.unknown", "new-chat", "NEW-CHAT"])
  func unknownShortcutTypeIsNil(_ type: String) {
    #expect(LaunchIntent(shortcutItemType: type) == nil)
  }

  @Test func quickActionsKeepMenuOrderTitlesAndSymbols() {
    #expect(LaunchIntent.quickActions == [.newChat, .newChatWithDictation])
    #expect(LaunchIntent.quickActions.map(\.shortcutTitle) == ["New Chat", "Dictate"])
    #expect(LaunchIntent.quickActions.map(\.shortcutSymbolName) == ["plus.message", "mic.badge.plus"])
  }
}
