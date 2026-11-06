import SwiftUI
import WidgetKit

/// Every Hermes widget, control and Live Activity (#138). The extension links only
/// `HermesWidgetKit`, reads the App Group mirror the app writes, and opens `hermesmobile://`
/// URLs for every tap — it never touches the network or the Keychain.
@main
struct HermesWidgetsBundle: WidgetBundle {
  var body: some Widget {
    QuickActionsWidget()
    SessionsWidget()
    NewChatAccessoryWidget()
    NewChatControl()
    DictateControl()
  }
}
