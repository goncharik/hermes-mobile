import SwiftUI

/// A Form row that pushes a sub-screen. A `Button` rather than a `NavigationLink`: the push is
/// a reducer append onto `SettingsFeature.State.path`, so the row only sends the action and
/// draws the disclosure chevron itself.
struct SettingsNavigationRow: View {
  let title: String
  var value: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
          .foregroundStyle(.primary)
        Spacer()
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
