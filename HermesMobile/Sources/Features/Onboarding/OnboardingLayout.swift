import SwiftUI
import UIKit

/// Shared measurements and building blocks for the onboarding screens (#136): Welcome, Server
/// and Sign in.
enum OnboardingLayout {
  /// The readable column cap, applied on each screen's OUTER container only (the capped-width
  /// rule: never on rows or cells). Phone widths sit below it, so compact rendering is
  /// unchanged; on an iPad the column is centred. Measured in `OnboardingColumnLayoutTests`.
  static let maxWidth: CGFloat = 480

  /// Side gutter of every onboarding screen.
  static let gutter: CGFloat = 20

  /// Corner radius of the cards.
  static let cardCornerRadius: CGFloat = 16

  /// Corner radius of the field groups and notices.
  static let fieldCornerRadius: CGFloat = 12
}

/// One onboarding screen: a scrolling body over a pinned call-to-action footer.
///
/// The column cap and the full-width background sit on this OUTER container, so the scroll
/// view itself is the capped column (what `OnboardingColumnLayoutTests` measures). The body
/// scrolls at every Dynamic Type size; the footer rides above the keyboard.
///
/// At an accessibility text size the footer is NOT pinned: the buttons alone would fill most
/// of a phone screen and squeeze the body to a sliver, so they scroll as the content's last
/// block instead.
struct OnboardingScreen<Content: View, Footer: View>: View {
  private let content: Content
  private let footer: Footer?

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.content = content()
    self.footer = footer()
  }

  private var pinsFooter: Bool { !dynamicTypeSize.isAccessibilitySize }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        content
        if !pinsFooter, let footer {
          footerStack(footer)
            .padding(.top, 24)
        }
      }
      .padding(.horizontal, OnboardingLayout.gutter)
      .padding(.top, 8)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if pinsFooter, let footer {
        footerStack(footer)
          .padding(.horizontal, OnboardingLayout.gutter)
          .padding(.top, 12)
          .padding(.bottom, 8)
          .background(Color(.systemGroupedBackground))
      }
    }
    .frame(maxWidth: OnboardingLayout.maxWidth)
    .frame(maxWidth: .infinity)
    .background(Color(.systemGroupedBackground))
  }

  private func footerStack(_ footer: Footer) -> some View {
    VStack(spacing: 4) {
      footer
    }
  }
}

extension OnboardingScreen where Footer == EmptyView {
  /// A screen with no pinned footer (Sign in for an OAuth-only agent: the provider buttons
  /// ARE the call to action).
  init(@ViewBuilder content: () -> Content) {
    self.content = content()
    self.footer = nil
  }
}

extension View {
  /// The screen's main call to action: a full-width amber button with dark text.
  func onboardingPrimaryButton() -> some View {
    buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(.hermesAccent)
      .foregroundStyle(Color.hermesOnAccent)
  }

  /// A secondary action inside the content (provider buttons under "or", "Sign in with
  /// token", a failure card's "Setup guide"): a soft amber fill.
  func onboardingTonalButton() -> some View {
    buttonStyle(.bordered)
      .tint(.hermesAccentInk)
  }

  /// A text-only footer action ("I don't have an agent yet", "Where do I find the address?").
  func onboardingPlainButton() -> some View {
    buttonStyle(.borderless)
      .font(.body.weight(.semibold))
      .foregroundStyle(Color.hermesAccentInk)
      .frame(minHeight: 44)
  }
}

/// An amber glyph on a tinted rounded square: the Welcome value rows (`.large`), the session
/// list's push card and tips (`.regular`).
struct OnboardingIconTile: View {
  enum Size {
    case regular, large
  }

  let systemImage: String
  var size: Size = .regular

  var body: some View {
    Image(systemName: systemImage)
      .font(size == .large ? .title3 : .body)
      .foregroundStyle(Color.hermesAccentInk)
      .frame(width: side, height: side)
      .background(
        Color.hermesAccent.opacity(0.16),
        in: RoundedRectangle(cornerRadius: size == .large ? 12 : 10, style: .continuous)
      )
      .accessibilityHidden(true)
  }

  private var side: CGFloat { size == .large ? 40 : 34 }
}

/// Grouped input fields on the card surface, outlined red when `hasError` (the agent rejected
/// what was typed, or the address doesn't parse).
struct OnboardingFieldGroup<Content: View>: View {
  let hasError: Bool
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .background(
      Color(.secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: OnboardingLayout.fieldCornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: OnboardingLayout.fieldCornerRadius, style: .continuous)
        .strokeBorder(hasError ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
    }
  }
}

/// A rounded card surface on the grouped background.
struct OnboardingCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(.secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: OnboardingLayout.cardCornerRadius, style: .continuous)
    )
  }
}

/// A one-line notice with a leading glyph: the informational lines on Sign in, the Local
/// Network hint on a failure card, the cleartext warning (tinted).
struct OnboardingNotice<Message: View>: View {
  var systemImage = "info.circle"
  var tint: Color = .hermesAccentInk
  /// A warning gets a `tint`-tinted background instead of the plain card surface.
  var isWarning = false
  @ViewBuilder var message: Message

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      message
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isWarning
        ? AnyShapeStyle(tint.opacity(0.14))
        : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
      in: RoundedRectangle(cornerRadius: OnboardingLayout.fieldCornerRadius, style: .continuous)
    )
    .accessibilityElement(children: .combine)
  }
}

/// A screen's heading and subtitle.
struct OnboardingHeading: View {
  let title: String
  var subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.title.weight(.bold))
        .accessibilityAddTraits(.isHeader)
      if let subtitle {
        Text(subtitle)
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A divider with a centred caption ("or", "session token").
struct OnboardingLabeledDivider: View {
  let label: String

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    HStack(spacing: 12) {
      line
      Text(label)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .layoutPriority(1)
      line
    }
    .accessibilityHidden(true)
  }

  private var line: some View {
    Rectangle()
      .fill(Color(.separator))
      .frame(height: 1 / displayScale)
      .frame(maxWidth: .infinity)
  }
}

/// Lays its subviews out left to right, wrapping onto a new line when the next one would not
/// fit — the Server step's example chips, which do not fit one line at phone width.
///
/// A subview wider than the whole line (a chip at an accessibility text size) is re-measured
/// at the line width so its label wraps; the layout never reports more width than it was
/// offered, or the onboarding column would grow past the screen and clip on both sides.
struct OnboardingFlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lineWidth = proposal.width ?? .infinity
    let rows = rows(for: subviews, width: lineWidth)
    let width = min(rows.map(\.width).max() ?? 0, lineWidth)
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(for: subviews, width: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        let size = size(of: subviews[index], lineWidth: bounds.width)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  /// The subview's ideal size, or — when that is wider than the line — its size at the line
  /// width (the label wraps).
  private func size(of subview: LayoutSubview, lineWidth: CGFloat) -> CGSize {
    let ideal = subview.sizeThatFits(.unspecified)
    guard ideal.width > lineWidth, lineWidth.isFinite else { return ideal }
    let fitted = subview.sizeThatFits(ProposedViewSize(width: lineWidth, height: nil))
    return CGSize(width: min(fitted.width, lineWidth), height: fitted.height)
  }

  private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = size(of: subviews[index], lineWidth: width)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
