import SwiftUI

extension Color {
  /// The Hermes brand yellow-orange (sampled from the app icon). Used for the send button.
  static let hermesAccent = Color("HermesAccent")

  /// Text and glyph colour drawn in the brand amber, darkened in light mode and lightened in
  /// dark mode so it keeps its contrast against the grouped backgrounds (`hermesAccent` itself
  /// is too light for text on white). Also the onboarding stack's tint: links, the back button.
  static let hermesAccentInk = Color("HermesAccentInk")

  /// Label colour on an amber fill: white on `hermesAccent` falls well short of legible.
  static let hermesOnAccent = Color("HermesOnAccent")
}
