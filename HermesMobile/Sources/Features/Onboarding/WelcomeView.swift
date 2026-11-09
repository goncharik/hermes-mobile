import SwiftUI

/// Onboarding step 0 (#136): what this app is and what you need, before any form. The stack
/// root `ConnectionView` renders; it has no reducer of its own — its primary action is
/// `ConnectionFeature.connectButtonTapped`, and the secondary one opens the setup guide sheet
/// (view-local `@State` in `ConnectionView`).
struct WelcomeView: View {
  let connectButtonTapped: () -> Void
  let setupGuideButtonTapped: () -> Void

  /// The app icon tile at the top: large enough to read as the brand, small enough that the
  /// three value rows stay above the fold on a phone.
  private static let iconSide: CGFloat = 72

  var body: some View {
    OnboardingScreen {
      VStack(alignment: .leading, spacing: 28) {
        header
        values
      }
      .padding(.top, 24)
    } footer: {
      needNote
        .padding(.bottom, 8)
      Button(action: connectButtonTapped) {
        Text("Connect to my agent")
          .frame(maxWidth: .infinity)
      }
      .onboardingPrimaryButton()
      Button("I don’t have an agent yet", action: setupGuideButtonTapped)
        .onboardingPlainButton()
    }
    .toolbar(.hidden, for: .navigationBar)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image("AppIconPreview-AppIcon")
        .resizable()
        .scaledToFit()
        .frame(width: Self.iconSide, height: Self.iconSide)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 8) {
        Text("HERMES AGENT")
          .font(.system(.footnote, design: .serif).weight(.semibold))
          .tracking(2.8)
          .foregroundStyle(Color.hermesAccentInk)
          .accessibilityLabel("Hermes Agent")
        Text("Your agent, from anywhere.")
          .font(.largeTitle.weight(.bold))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Text("""
        This app is a remote for the Hermes agent you run on your own computer or in Hermes \
        Cloud. Chats, tools and memory stay with the agent.
        """)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var values: some View {
    VStack(alignment: .leading, spacing: 18) {
      ValueRow(
        systemImage: "bubble.left.and.text.bubble.right",
        title: "Chat and watch it work",
        detail: "Follow live replies and tool calls, and pick up sessions you started on desktop."
      )
      ValueRow(
        systemImage: "checkmark.shield",
        title: "Approve from your lock screen",
        detail: "When the agent needs permission to run something, answer from a notification."
      )
      ValueRow(
        systemImage: "lock",
        title: "No account with us",
        detail: "The app talks only to your agent and signs in the way your agent asks."
      )
    }
  }

  private var needNote: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "info.circle")
        .accessibilityHidden(true)
      Text("""
      You need a Hermes agent this phone can reach: on the same Wi-Fi, over Tailscale, or in \
      Hermes Cloud.
      """)
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
  }

  private struct ValueRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
      HStack(alignment: .top, spacing: 14) {
        OnboardingIconTile(systemImage: systemImage, size: .large)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

#Preview {
  NavigationStack {
    WelcomeView(connectButtonTapped: {}, setupGuideButtonTapped: {})
  }
}
