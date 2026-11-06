import Foundation
import HermesWidgetKit
import Testing

struct WidgetDeepLinkTests {
  static let everyIntent: [LaunchIntent] = [
    .newChat,
    .newChatWithDictation,
    .newChatWithCamera,
    .newChatWithPhotos,
    .openSession(id: "20261106_abc123", profile: nil),
    .openSession(id: "20261106_abc123", profile: "default"),
    .openSession(id: "20261106_abc123", profile: "work stuff"),
    .openSession(id: "a/b c?d#e%f&g", profile: "p&q=r+s/t?u#v%w"),
    .openSession(id: "セッション", profile: "профиль"),
  ]

  @Test(arguments: everyIntent)
  func roundTrips(_ intent: LaunchIntent) {
    let url = WidgetDeepLink.url(for: intent)
    #expect(url.scheme == "hermesmobile")
    #expect(WidgetDeepLink.intent(from: url) == intent)
  }

  /// The URLs are a contract with already-installed widgets and Live Activities: pinned.
  @Test func urlsArePinned() {
    #expect(WidgetDeepLink.url(for: .newChat).absoluteString == "hermesmobile://new")
    #expect(
      WidgetDeepLink.url(for: .newChatWithDictation).absoluteString
        == "hermesmobile://new?with=dictation"
    )
    #expect(
      WidgetDeepLink.url(for: .newChatWithCamera).absoluteString == "hermesmobile://new?with=camera"
    )
    #expect(
      WidgetDeepLink.url(for: .newChatWithPhotos).absoluteString == "hermesmobile://new?with=photos"
    )
    #expect(
      WidgetDeepLink.url(for: .openSession(id: "abc", profile: nil)).absoluteString
        == "hermesmobile://session/abc"
    )
    #expect(
      WidgetDeepLink.url(for: .openSession(id: "abc", profile: "default")).absoluteString
        == "hermesmobile://session/abc?profile=default"
    )
  }

  @Test func idAndProfileArePercentEncoded() {
    let url = WidgetDeepLink.url(for: .openSession(id: "a/b c", profile: "my profile+1"))
    #expect(url.absoluteString == "hermesmobile://session/a%2Fb%20c?profile=my%20profile%2B1")
  }

  @Test func acceptsHandWrittenVariants() {
    #expect(WidgetDeepLink.intent(from: URL(string: "HermesMobile://NEW")!) == .newChat)
    #expect(WidgetDeepLink.intent(from: URL(string: "hermesmobile://new/")!) == .newChat)
    #expect(
      WidgetDeepLink.intent(from: URL(string: "hermesmobile://new?with=camera&utm=x")!)
        == .newChatWithCamera
    )
    #expect(
      WidgetDeepLink.intent(from: URL(string: "hermesmobile://session/abc?profile=")!)
        == .openSession(id: "abc", profile: nil)
    )
  }

  @Test(arguments: [
    "https://new",
    "hermes-file://preview?path=/tmp/a.txt",
    "hermesmobile://",
    "hermesmobile:new",
    "hermesmobile://unknown",
    "hermesmobile://unknown/abc",
    "hermesmobile://new?with=video",
    "hermesmobile://new?with=",
    "hermesmobile://new?with",
    "hermesmobile://new/extra",
    "hermesmobile://session",
    "hermesmobile://session/",
    "hermesmobile://session/a/b",
    "hermesmobile://session?profile=default",
  ])
  func unknownOrMalformedIsNil(_ string: String) throws {
    let url = try #require(URL(string: string))
    #expect(WidgetDeepLink.intent(from: url) == nil)
  }

  @Test func launchActionAccessor() {
    #expect(LaunchIntent.newChat.launchAction == nil)
    #expect(LaunchIntent.newChatWithDictation.launchAction == .dictation)
    #expect(LaunchIntent.newChatWithCamera.launchAction == .camera)
    #expect(LaunchIntent.newChatWithPhotos.launchAction == .photos)
    #expect(LaunchIntent.openSession(id: "x", profile: nil).launchAction == nil)
  }

  /// The widget-only intents never become quick actions and never parse from one.
  @Test func widgetOnlyIntentsAreNotQuickActions() {
    #expect(LaunchIntent.quickActions == [.newChat, .newChatWithDictation])
    let widgetOnly: [LaunchIntent] = [
      .newChatWithCamera, .newChatWithPhotos, .openSession(id: "x", profile: nil),
    ]
    for intent in widgetOnly {
      #expect(LaunchIntent(shortcutItemType: intent.shortcutItemType) == nil)
    }
    let types = Set((widgetOnly + LaunchIntent.quickActions).map(\.shortcutItemType))
    #expect(types.count == 5)
  }
}
