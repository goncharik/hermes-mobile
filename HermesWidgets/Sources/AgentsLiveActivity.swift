import ActivityKit
import HermesWidgetKit
import SwiftUI
import WidgetKit

/// The aggregate "running agents" Live Activity (#138): the Lock Screen banner and the Dynamic
/// Island. The app starts, updates and ends it locally (`LiveActivityClient`); the stale date
/// is the app's `freshUntil`, so past it the status reads "Outdated". A tap opens the headline
/// session (`hermesmobile://session/<id>`), or just the app when there is none.
struct AgentsLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: HermesActivityAttributes.self) { context in
      AgentsActivityView(content: context.state, isStale: context.isStale)
        .activityBackgroundTint(Self.backgroundTint)
        .widgetURL(tapURL(context.state))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          AgentsActivityView(content: context.state, isStale: context.isStale, style: .expanded)
        }
      } compactLeading: {
        HermesGlyph()
          .frame(width: 18, height: 18)
      } compactTrailing: {
        AgentsActivityCompactTrailing(content: context.state, isStale: context.isStale)
      } minimal: {
        HermesGlyph()
          .frame(width: 18, height: 18)
      }
      .widgetURL(tapURL(context.state))
    }
  }

  /// A clear tint reveals iOS 26's Liquid Glass platter (T3 Code does the same); earlier iOS
  /// keeps the system's standard surface (`nil`).
  private static var backgroundTint: Color? {
    if #available(iOS 26, *) { return .clear }
    return nil
  }

  private func tapURL(_ content: AgentActivityContent) -> URL? {
    content.tapIntent.map(WidgetDeepLink.url(for:))
  }
}
