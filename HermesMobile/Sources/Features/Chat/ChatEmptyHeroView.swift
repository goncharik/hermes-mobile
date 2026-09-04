import SwiftUI

/// The empty-chat hero (#80): shown in place of the transcript while
/// `ChatFeature.State.showsEmptyHero` is true — a brand-new chat on any device, or a
/// resumed session whose hydrated history is genuinely empty. Mirrors the Hermes desktop
/// app's empty state: a wordmark over one tagline, centered in the transcript's region.
///
/// Display-only — no store, no state. The predicate lives in HermesKit (unit-tested) and
/// `ChatView` swaps the REGION; `CollectionTranscriptView` stays the only transcript renderer.
///
/// Type: the wordmark uses the system serif design with wide tracking rather than the
/// desktop's licensed face (not shipped here); it scales with Dynamic Type and wraps rather
/// than truncating at accessibility sizes. Colour: the wordmark is the brand accent
/// (`Color.hermesAccent`, one fixed value that reads on both appearances); the tagline is
/// the semantic secondary, so light/dark come for free.
///
/// The hero is greedy in both axes (`maxWidth`/`maxHeight: .infinity`) so it occupies exactly
/// the slot the transcript would — the composer stays pinned to the bottom and the
/// approval-card `layoutPriority` rule in `ChatView` keeps working unchanged.
struct ChatEmptyHeroView: View {
  /// The one tagline. Kept as a constant so changing the copy is a one-line edit + re-record.
  static let tagline = "Start a conversation with your agent."

  /// The wordmark, spelled once. Rendered with tracking, so the spaces are real characters
  /// and VoiceOver reads two words.
  static let wordmark = "HERMES AGENT"

  var body: some View {
    VStack(spacing: 12) {
      Text(Self.wordmark)
        .font(.system(.largeTitle, design: .serif).weight(.semibold))
        .tracking(4)
        .foregroundStyle(Color.hermesAccent)
      Text(Self.tagline)
        .font(.body)
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    // Wrap, never truncate, when accessibility sizes outgrow the column.
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // One VoiceOver element: "HERMES AGENT, Start a conversation with your agent."
    .accessibilityElement(children: .combine)
  }
}

#Preview("Hero") {
  ChatEmptyHeroView()
}
