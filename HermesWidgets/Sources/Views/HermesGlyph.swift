import SwiftUI
import WidgetKit

/// The monochrome Hermes "HA" mark, a template image derived from the App Store icon's
/// letterforms. Being a template it takes the surrounding foreground style, and it is
/// `widgetAccentable()` so the tinted and clear Home Screen modes paint it with the accent.
struct HermesGlyph: View {
  var body: some View {
    Image("HermesGlyph", bundle: .widgetResources)
      .resizable()
      .scaledToFit()
      .widgetAccentable()
      .accessibilityHidden(true)
  }
}

private final class WidgetResourcesBundleToken {}

extension Bundle {
  /// The bundle holding `HermesWidgets/Resources`: the extension itself in production, and the
  /// snapshot-test bundle, which compiles these views and their asset catalog directly.
  static var widgetResources: Bundle { Bundle(for: WidgetResourcesBundleToken.self) }
}
