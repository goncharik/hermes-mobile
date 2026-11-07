import HermesWidgetKit
import SwiftUI
import WidgetKit

/// The Lock Screen `accessoryCircular` widget (#138): opens a new chat.
struct NewChatAccessoryWidget: Widget {
  static let kind = "me.honcharenko.HermesMobile.Widgets.NewChatAccessory"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: StaticEntryProvider()) { _ in
      NewChatAccessoryView()
        .containerBackground(for: .widget) {}
        .widgetURL(WidgetDeepLink.url(for: .newChat))
    }
    .configurationDisplayName("New Chat")
    .description("Start a new Hermes chat from the Lock Screen.")
    .supportedFamilies([.accessoryCircular])
  }
}
