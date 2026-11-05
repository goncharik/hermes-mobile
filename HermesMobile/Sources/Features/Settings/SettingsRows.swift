import SwiftUI

/// A Form row that pushes a sub-screen. A `Button` rather than a `NavigationLink`: the push is
/// a reducer append onto `SettingsFeature.State.path`, so the row only sends the action and
/// draws the disclosure chevron itself.
struct SettingsNavigationRow: View {
  let title: String
  var value: String?
  /// Optional image-set name drawn as a small app-icon thumbnail before the value.
  var thumbnail: String?
  let action: () -> Void

  /// Thumbnail side, scaled with Dynamic Type like the row's text.
  @ScaledMetric(relativeTo: .body) private var thumbnailSide: CGFloat = 29

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
          .foregroundStyle(.primary)
        Spacer()
        if let thumbnail {
          Image(thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: thumbnailSide, height: thumbnailSide)
            // Home-screen squircle ratio (≈ 0.225 × side), matching the picker's tiles.
            .clipShape(.rect(cornerRadius: thumbnailSide * 0.225, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: thumbnailSide * 0.225, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityHidden(true) // the value text already names the icon
        }
        if let value {
          Text(value)
            .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    // A Form button resolves `.primary` in its label to the TINT; re-tinting to `.primary`
    // keeps the row reading like a `NavigationLink` (label colour, secondary value).
    .tint(.primary)
  }
}

/// A Form row that leaves the app (Safari / the App Store): primary-coloured title with a
/// trailing arrow so it reads as external rather than as a push.
struct ExternalLinkRow: View {
  let title: String
  let destination: URL

  var body: some View {
    Link(destination: destination) {
      HStack {
        Text(title)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .tint(.primary) // see `SettingsNavigationRow`
  }
}
