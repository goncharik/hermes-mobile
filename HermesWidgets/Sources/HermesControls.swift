import AppIntents
import HermesWidgetKit
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action button control: start a new chat (#138). Title and
/// symbol are the #93 quick action's, from `LaunchIntent`.
struct NewChatControl: ControlWidget {
  static let kind = "me.honcharenko.HermesMobile.Widgets.NewChatControl"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      LaunchControlButton(intent: .newChat)
    }
    .displayName("New Chat")
    .description("Start a new Hermes chat.")
  }
}

/// Control Center / Lock Screen / Action button control: start a new chat with the mic on.
struct DictateControl: ControlWidget {
  static let kind = "me.honcharenko.HermesMobile.Widgets.DictateControl"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      LaunchControlButton(intent: .newChatWithDictation)
    }
    .displayName("Dictate")
    .description("Start a new Hermes chat and dictate your message.")
  }
}

/// A control button that opens the app on `intent`'s deep link.
private struct LaunchControlButton: ControlWidgetTemplate {
  let intent: LaunchIntent

  var body: some ControlWidgetTemplate {
    ControlWidgetButton(action: OpenHermesURLIntent(intent)) {
      Label(intent.shortcutTitle, systemImage: intent.shortcutSymbolName)
    }
  }
}
