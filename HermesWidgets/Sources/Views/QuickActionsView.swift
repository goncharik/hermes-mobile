import HermesWidgetKit
import SwiftUI
import WidgetKit

/// Which buttons the quick-actions widget shows under its "Ask Hermes" pill.
enum QuickActionsLayout {
  /// `systemSmall`: Camera + Mic.
  case small
  /// `systemMedium`: Camera + Photos + Mic.
  case medium

  var buttons: [LaunchIntent] {
    switch self {
    case .small: [.newChatWithCamera, .newChatWithDictation]
    case .medium: [.newChatWithCamera, .newChatWithPhotos, .newChatWithDictation]
    }
  }
}

/// The quick-actions widget (#138): an "Ask Hermes" pill that opens a new chat over a row of
/// round buttons that open a new chat AND run a one-shot action (camera, photos, mic).
///
/// Plain values only, so the snapshot tests can render it. How a tap is wired is the caller's
/// call (`tap` wraps each label): the small family has no `Link` support and uses
/// `Button(intent:)`, the medium family uses `Link`, the tests use the bare label.
struct QuickActionsView<Tap: View>: View {
  let layout: QuickActionsLayout
  @ViewBuilder let tap: (LaunchIntent, QuickActionLabel) -> Tap

  var body: some View {
    VStack(spacing: 8) {
      tap(.newChat, QuickActionLabel(intent: .newChat, layout: layout))
      HStack(spacing: 8) {
        ForEach(layout.buttons, id: \.shortcutItemType) { intent in
          tap(intent, QuickActionLabel(intent: intent, layout: layout))
        }
      }
    }
  }
}

extension QuickActionsView where Tap == QuickActionLabel {
  /// The bare labels, no tap wiring (snapshot tests).
  init(layout: QuickActionsLayout) {
    self.init(layout: layout) { _, label in label }
  }
}

/// One tappable surface of the quick-actions widget: the "Ask Hermes" pill for `.newChat`, a
/// round symbol button for every other intent. Fills the space it is offered.
struct QuickActionLabel: View {
  let intent: LaunchIntent
  let layout: QuickActionsLayout

  var body: some View {
    if intent == .newChat {
      pill
    } else {
      circle
    }
  }

  /// The small pill has room for "Ask" only (as the ChatGPT widget it mirrors); VoiceOver
  /// reads "Ask Hermes" either way.
  private var pillTitle: String {
    switch layout {
    case .small: "Ask"
    case .medium: "Ask Hermes"
    }
  }

  private var pill: some View {
    HStack(spacing: 10) {
      HermesGlyph()
        .frame(width: 26, height: 26)
      Text(pillTitle)
        .font(.headline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Capsule().fill(Self.fill))
    .contentShape(Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Ask Hermes")
  }

  private var circle: some View {
    Circle()
      .fill(Self.fill)
      .overlay {
        Image(systemName: Self.symbolName(for: intent))
          .font(.title2.weight(.medium))
          .foregroundStyle(.secondary)
          .widgetAccentable()
      }
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Circle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(intent.shortcutTitle)
  }

  /// The pill and button fill: a translucent neutral that reads over the widget background in
  /// light and dark alike.
  private static let fill = Color.primary.opacity(0.12)

  /// The widget's own glyphs: a plain mic (the quick action's `mic.badge.plus` reads as
  /// "add", which the round button doesn't need).
  private static func symbolName(for intent: LaunchIntent) -> String {
    switch intent {
    case .newChatWithCamera: "camera"
    case .newChatWithPhotos: "photo"
    case .newChatWithDictation: "mic"
    case .newChat, .openSession: intent.shortcutSymbolName
    }
  }
}
