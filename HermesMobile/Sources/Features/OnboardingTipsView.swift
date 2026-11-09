import HermesKit
import SwiftUI

/// The dismissible tips row under the push card on the Sessions tab (#136): a "Tips" header
/// with Hide, then a horizontally paging row of small cards — each about three quarters of the
/// width, so the next one peeks in from the trailing edge. Presentation-only: which tips show
/// comes from `SessionListFeature.State.onboardingTips`, and Hide is a closure the list routes
/// to `onboardingTipsHideButtonTapped`.
///
/// Paging is the user's own scroll, so there is no motion to reduce here; the list animates
/// the row away on Hide only when reduce motion is off.
struct OnboardingTipsView: View {
  let tips: [SessionListFeature.OnboardingTip]
  /// The list's effective trailing-swipe default, so the swipe tip names what a swipe offers.
  let swipeAction: SessionSwipeAction
  let hideButtonTapped: () -> Void

  /// The horizontal inset shared by the header and the first card, matching the session cards.
  static let sideInset: CGFloat = 16

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
        .padding(.horizontal, Self.sideInset)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 10) {
          ForEach(tips, id: \.self) { tip in
            TipCard(tip: tip, swipeAction: swipeAction)
              .containerRelativeFrame(.horizontal) { length, _ in length * 0.78 }
          }
        }
        // Every card takes the tallest card's height, so the row reads as one band.
        .fixedSize(horizontal: false, vertical: true)
        .scrollTargetLayout()
      }
      .contentMargins(.horizontal, Self.sideInset, for: .scrollContent)
      .scrollIndicators(.hidden)
      .scrollTargetBehavior(.viewAligned)
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Tips")
        .font(.footnote.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Button("Hide", action: hideButtonTapped)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.hermesAccentInk)
        // Borderless, so only the label (not the whole list row) is the tap target.
        .buttonStyle(.borderless)
        .accessibilityLabel("Hide tips")
    }
  }

  /// One tip: an amber icon tile, a bold title and a line of detail. VoiceOver reads it as one
  /// element.
  private struct TipCard: View {
    let tip: SessionListFeature.OnboardingTip
    let swipeAction: SessionSwipeAction

    var body: some View {
      HStack(alignment: .top, spacing: 10) {
        OnboardingIconTile(systemImage: systemImage)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.subheadline.weight(.semibold))
          Text(detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(14)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(
        Color(.secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .accessibilityElement(children: .combine)
    }

    private var systemImage: String {
      switch tip {
      case .profiles: "person.crop.circle"
      case .swipeActions: "hand.draw"
      case .voice: "mic.fill"
      }
    }

    private var title: String {
      switch tip {
      case .profiles: "Switch profiles"
      case .swipeActions: "Swipe to tidy up"
      case .voice: "Talk instead of typing"
      }
    }

    private var detail: String {
      switch tip {
      case .profiles:
        "Tap the pill at the top to move between your agent’s profiles."
      case .swipeActions:
        switch swipeAction {
        case .archive: "Swipe a session left to archive or rename it."
        case .delete: "Swipe a session left to delete or rename it."
        }
      case .voice:
        "Tap the mic in a chat. Your agent transcribes it."
      }
    }
  }
}

#Preview {
  OnboardingTipsView(
    tips: [.profiles, .voice, .swipeActions],
    swipeAction: .archive,
    hideButtonTapped: {}
  )
}
