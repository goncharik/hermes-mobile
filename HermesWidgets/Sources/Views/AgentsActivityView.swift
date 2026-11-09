import HermesWidgetKit
import SwiftUI
import WidgetKit

/// The aggregate Live Activity's lock-screen banner (#138), after T3 Code's: the Hermes mark and
/// name on the left and a centred header ("1 active agent", "· Needs input", "Agent work completed");
/// below it the headline session's title (truncated) and its tinted status. No workspace label.
/// With "Show session titles" off the row shows only the status. The expanded Dynamic Island
/// shows the same layout.
///
/// Small fixed sizes (13 / 11 pt, as T3) and hierarchical `.primary` / `.secondary` styles, so
/// the text takes the system's vibrancy over the iOS 26 glass the configuration reveals
/// (`AgentsLiveActivity`).
///
/// Plain values only (no `ActivityViewContext`), so the snapshot tests can render it:
/// `isStale` is ActivityKit's `context.isStale` — past the stale date working / needs input
/// read "Outdated".
struct AgentsActivityView: View {
  enum Style {
    /// The Lock Screen banner: the system draws the background, the view pads itself.
    case lockScreen
    /// The expanded Dynamic Island's bottom region: the island supplies the margins.
    case expanded
  }

  let content: AgentActivityContent
  let isStale: Bool
  var style: Style = .lockScreen

  private var status: AgentActivityContent.DisplayStatus {
    content.displayStatus(isStale: isStale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      headline
    }
    .padding(style == .lockScreen ? 14 : 0)
  }

  private var header: some View {
    // The brand leads. The status header is centred on the banner — balanced against an
    // invisible copy of the brand, so it never runs under "Hermes" — when it fits there;
    // a longer one ("Agent status out of date", "2 active agents · Needs input") trails
    // instead, with the whole width after the brand.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        brand
        Spacer(minLength: 0)
        headerStatus
        Spacer(minLength: 0)
        brand
          .hidden()
          .accessibilityHidden(true)
      }
      HStack(spacing: 8) {
        brand
        Spacer(minLength: 0)
        headerStatus
      }
    }
    .font(.system(size: 13, weight: .semibold))
    .accessibilityElement(children: .combine)
  }

  /// The header's status text: the count or outcome, plus the tinted attention suffix.
  private var headerStatus: some View {
    HStack(spacing: 6) {
      Text(content.headerTitle(isStale: isStale))
        .foregroundStyle(status == .done ? statusTint : AnyShapeStyle(.primary))
      if let attention = content.headerAttention(isStale: isStale) {
        Text(verbatim: "·")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(attention)
          .foregroundStyle(statusTint)
      }
    }
    .lineLimit(1)
  }

  /// The Hermes mark with its name, top leading.
  private var brand: some View {
    HStack(spacing: 5) {
      HermesGlyph()
        .frame(width: 20, height: 13)
      Text("Hermes")
        .fixedSize()
    }
    .foregroundStyle(.primary)
  }

  private var headline: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      if let title = content.headlineTitle {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 8)
      }
      AgentsActivityStatusLabel(status: status)
        .layoutPriority(1)
      if content.headlineTitle == nil {
        Spacer(minLength: 0)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var statusTint: AnyShapeStyle {
    AgentsActivityStatusLabel.tint(for: status, scheme: colorScheme, dimmed: isLuminanceReduced)
  }

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
}

/// The row's trailing status ("Working", "Needs input", "Done", "Outdated"), tinted with
/// T3 Code's palette: light on the dark Live Activity material, deeper on a light one.
struct AgentsActivityStatusLabel: View {
  let status: AgentActivityContent.DisplayStatus

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced

  var body: some View {
    Text(status.label)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Self.tint(for: status, scheme: colorScheme, dimmed: isLuminanceReduced))
      .lineLimit(1)
      .fixedSize()
  }

  /// The status tint: sky (working), amber (needs input), emerald (done), secondary once
  /// outdated — and secondary for every status on the dimmed Always-On display.
  static func tint(
    for status: AgentActivityContent.DisplayStatus, scheme: ColorScheme, dimmed: Bool
  ) -> AnyShapeStyle {
    if dimmed { return AnyShapeStyle(.secondary) }
    let dark = scheme == .dark
    switch status {
    case .working: return AnyShapeStyle(dark ? Color(hex: 0x7DD3FC) : Color(hex: 0x0284C7))
    case .needsInput: return AnyShapeStyle(dark ? Color(hex: 0xFCD34D) : Color(hex: 0xD97706))
    case .done: return AnyShapeStyle(dark ? Color(hex: 0x6EE7B7) : Color(hex: 0x059669))
    case .outdated: return AnyShapeStyle(.secondary)
    }
  }
}

/// The compact Dynamic Island's trailing side: how many agents are active, a "?" while the
/// headline needs input, a checkmark once done; secondary once stale. The island is always dark.
struct AgentsActivityCompactTrailing: View {
  let content: AgentActivityContent
  let isStale: Bool

  private var status: AgentActivityContent.DisplayStatus {
    content.displayStatus(isStale: isStale)
  }

  var body: some View {
    label
      .font(.system(size: 13, weight: .bold))
      .foregroundStyle(AgentsActivityStatusLabel.tint(for: status, scheme: .dark, dimmed: false))
      .fixedSize()
      .accessibilityLabel("\(content.countLabel), \(status.label)")
  }

  private var label: Text {
    switch status {
    case .done: Text(Image(systemName: "checkmark"))
    case .needsInput: Text(verbatim: "?")
    case .working, .outdated: Text(verbatim: "\(content.activeCount)")
    }
  }
}

extension AgentActivityContent.DisplayStatus {
  /// The sessions widget's row-glyph colours (the session list's status dots).
  var color: Color {
    switch self {
    case .working: .blue
    case .needsInput: .yellow
    case .done: .green
    case .outdated: .secondary
    }
  }
}

private extension Color {
  /// An sRGB colour from a 0xRRGGBB literal.
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}
