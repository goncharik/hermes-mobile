import SwiftUI
import WidgetKit

/// The Lock Screen `accessoryCircular` widget (#138): the Hermes glyph on the system accessory
/// backdrop. The whole widget is one `widgetURL` to a new chat.
struct NewChatAccessoryView: View {
  var body: some View {
    ZStack {
      AccessoryWidgetBackground()
      HermesGlyph()
        .padding(18)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("New Hermes chat")
  }
}
