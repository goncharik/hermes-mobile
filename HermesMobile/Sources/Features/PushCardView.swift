import HermesKit
import SwiftUI

/// The inline push card at the top of the Sessions tab (#136), replacing the permission prompt
/// that used to fire on list appearance. Presentation-only: the variant comes from
/// `SessionListFeature.State.pushCard` and every button is a closure the list routes to a
/// reducer action.
///
/// - `.enableNotifications`: the plugin is ready, permission was never asked. A generic
///   notification preview, then "Turn on" (the only path to the system prompt).
/// - `.installPlugin`: the plugin isn't installed. "Ask my agent to install it" pre-fills a new
///   chat with the install prompt.
///
/// Privacy rule: the preview shows only the generic alert a push can carry — never message
/// content, arguments or commands.
struct PushCardView: View {
  let card: SessionListFeature.PushCard
  let askAgentButtonTapped: () -> Void
  let enableButtonTapped: () -> Void
  let notNowButtonTapped: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Text(detail)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if card == .enableNotifications {
        NotificationPreview()
      }
      actions
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(.secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
  }

  private var header: some View {
    HStack(spacing: 10) {
      OnboardingIconTile(systemImage: "bell.fill")
      Text(title)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
  }

  /// Side by side — the dismiss button hugs its label and the call to action takes the rest —
  /// or, when that row would truncate (large text), stacked full width.
  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) { buttons(stacked: false) }
      VStack(spacing: 8) { buttons(stacked: true) }
    }
  }

  @ViewBuilder
  private func buttons(stacked: Bool) -> some View {
    Button(action: notNowButtonTapped) {
      Text(notNowTitle)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(maxWidth: stacked ? .infinity : nil)
    }
    .buttonStyle(.bordered)
    .tint(.secondary)
    .foregroundStyle(.primary)
    .fixedSize(horizontal: !stacked, vertical: false)
    switch card {
    case .enableNotifications:
      primaryButton("Turn on", action: enableButtonTapped)
    case .installPlugin:
      primaryButton("Ask my agent to install it", action: askAgentButtonTapped)
    }
  }

  /// The onboarding amber fill at the regular control size, so it matches the dismiss button's
  /// height (`onboardingPrimaryButton` pins `.large` for the full-width footers).
  private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .tint(.hermesAccent)
    .foregroundStyle(Color.hermesOnAccent)
  }

  private var title: String {
    switch card {
    case .enableNotifications: "Know when your agent needs you"
    case .installPlugin: "Get approval requests on your phone"
    }
  }

  private var detail: String {
    switch card {
    case .enableNotifications:
      """
      Get a notification when a tool call needs your approval or a long task finishes. \
      Notifications never include message content.
      """
    case .installPlugin:
      """
      Notifications come from the small hermes-push plugin on your own agent, and it isn’t \
      installed yet. Your agent can install it for you. Only a generic alert like “Approval \
      needed” ever leaves your server.
      """
    }
  }

  private var notNowTitle: String {
    switch card {
    case .enableNotifications: "Not now"
    case .installPlugin: "Later"
    }
  }

  /// A mock lock-screen banner showing what a push looks like: the generic copy only.
  /// Decorative, so VoiceOver skips it (the card's text already says what it shows).
  private struct NotificationPreview: View {
    var body: some View {
      HStack(alignment: .center, spacing: 10) {
        Image("AppIconPreview-AppIcon")
          .resizable()
          .scaledToFit()
          .frame(width: 34, height: 34)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          Text("Approval needed")
            .font(.subheadline.weight(.semibold))
          Text("Your agent is waiting for a decision.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Text("now")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxHeight: .infinity, alignment: .top)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        Color(.tertiarySystemFill),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .accessibilityHidden(true)
    }
  }
}

#Preview("Enable") {
  PushCardView(
    card: .enableNotifications,
    askAgentButtonTapped: {},
    enableButtonTapped: {},
    notNowButtonTapped: {}
  )
  .padding()
}

#Preview("Install") {
  PushCardView(
    card: .installPlugin,
    askAgentButtonTapped: {},
    enableButtonTapped: {},
    notNowButtonTapped: {}
  )
  .padding()
}
