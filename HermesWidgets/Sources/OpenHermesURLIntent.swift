import AppIntents
import Foundation
import HermesWidgetKit

/// Opens the app on a `hermesmobile://` deep link. The small widget (which can't host a
/// `Link`) and the Control Center controls run this; it only hands the URL back to the system,
/// which opens the app and delivers it to the app's one `.onOpenURL` (`WidgetDeepLink`). It
/// never routes anything itself — the thin-client rule.
struct OpenHermesURLIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Hermes"
  /// An implementation detail of the widgets and controls, not a Shortcuts action.
  static let isDiscoverable = false

  /// The deep link, as a string (`URL` isn't an intent parameter type).
  @Parameter(title: "Target")
  var target: String

  init() {}

  init(_ intent: LaunchIntent) {
    target = WidgetDeepLink.url(for: intent).absoluteString
  }

  func perform() async throws -> some IntentResult & OpensIntent {
    .result(opensIntent: OpenURLIntent(WidgetDeepLink.destination(for: target)))
  }
}
