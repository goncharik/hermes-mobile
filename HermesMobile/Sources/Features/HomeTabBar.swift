import ComposableArchitecture
import HermesKit
import SwiftUI

/// The home screen's bottom bar: a glass tab pill (Sessions, Cron Jobs while there is cron
/// content, Settings) filling the leading space, and the round glass New session button
/// trailing. Rendered at the root of BOTH home stacks — the session list and the Settings tab
/// (`AppView`) — through a `safeAreaInset`, so a pushed screen covers it. Capped at
/// `maxBarWidth` and centred: on iPad the Settings tab spans the whole window. The pill hides while
/// searching (`showsTabBar`: search is a Sessions-only mode), leaving just New session.
struct HomeTabBar: View {
  let store: StoreOf<SessionListFeature>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Slides the selected-tab capsule between the tabs.
  @Namespace private var tabSelection

  /// The bar's shared height: the tab pill and the New session circle line up.
  static let barHeight: CGFloat = 64

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      if store.showsTabBar {
        tabPill
      }
      Spacer(minLength: 0)
      newSessionButton
    }
    .frame(maxWidth: Self.maxBarWidth)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
  }

  /// Wider than any sidebar column (≤ 400 pt) and a phone, so only a full-window iPad
  /// Settings tab is capped.
  private static let maxBarWidth: CGFloat = 560

  /// The pill fills the width the New session button leaves, its tabs sharing it equally —
  /// so three tabs fit a 320 pt iPad sidebar as well as a phone.
  private var tabPill: some View {
    HStack(spacing: 0) {
      ForEach(store.availableTabs, id: \.self) { tab in
        tabButton(tab)
      }
    }
    .padding(4)
    .frame(maxWidth: .infinity)
    .frame(height: Self.barHeight)
    .modifier(GlassBackground(shape: Capsule(), fallbackShadowRadius: 6, fallbackShadowY: 3))
  }

  /// One tab: icon over label, the selected one on an inner capsule in the accent color. No
  /// unread badge: unread shows only on an expanded job's run rows (desktop parity).
  private func tabButton(_ tab: SessionListTab) -> some View {
    let isSelected = store.effectiveTab == tab
    return Button {
      store.send(.selectTab(tab), animation: reduceMotion ? nil : .snappy)
    } label: {
      VStack(spacing: 2) {
        Image(systemName: tab.systemImage)
          .font(.title3)
        Text(tab.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .foregroundStyle(isSelected ? Color.hermesAccent : Color.primary)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        if isSelected {
          Capsule()
            .fill(Color(.systemBackground).opacity(0.55))
            .matchedGeometryEffect(id: "selectedTab", in: tabSelection)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  /// The round glass New session button (icon-only: it starts a new session, not a chat).
  /// Offered on every tab, so the bar never changes shape: a new session opened from Settings
  /// lands on the Sessions tab (`AppFeature` leaves Settings on every chat route).
  private var newSessionButton: some View {
    Button {
      store.send(.newSessionButtonTapped)
    } label: {
      Image(systemName: "square.and.pencil")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(width: Self.barHeight, height: Self.barHeight)
        .contentShape(Circle())
        .modifier(GlassBackground(
          shape: Circle(), isInteractive: true, fallbackShadowRadius: 6, fallbackShadowY: 3
        ))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("New session")
  }
}

private extension SessionListTab {
  var title: String {
    switch self {
    case .sessions: "Sessions"
    case .cron: "Cron Jobs"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .sessions: "text.bubble.fill"
    case .cron: "clock.fill"
    case .settings: "gearshape.fill"
    }
  }
}
