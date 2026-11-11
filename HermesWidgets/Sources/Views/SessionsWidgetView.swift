import HermesWidgetKit
import SwiftUI
import WidgetKit

/// Which sessions the sessions widget lists under its "Hermes" header.
enum SessionsWidgetLayout {
  /// `systemMedium`: the headline session (the mirror's first row: needs input, else working,
  /// else the most recent).
  case medium
  /// `systemLarge`: up to `WidgetSessionSnapshot.maxRows` rows.
  case large

  var maxRows: Int {
    switch self {
    case .medium: 1
    case .large: WidgetSessionSnapshot.maxRows
    }
  }
}

/// The sessions widget (#138), Codex-task style: a "Hermes" header over the mirror's rows,
/// each a `Link` to `hermesmobile://session/<id>`, plus a round New session `Link` bottom
/// trailing. Signed out → "Sign in to Hermes" (the
/// widget's default tap opens the app); signed in with no sessions → "No sessions yet" plus a
/// New chat link.
///
/// Plain values only, so the snapshot tests can render it: `date` is the timeline entry's
/// date, which decides whether working / needs-input rows read "outdated"
/// (`WidgetStaleness`); `relativeTime` decides how the updated times render.
struct SessionsWidgetView: View {
  let layout: SessionsWidgetLayout
  let snapshot: WidgetSessionSnapshot
  let date: Date
  var relativeTime: WidgetRelativeTime = .live

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if !snapshot.isSignedIn {
        signedOut
      } else if snapshot.rows.isEmpty {
        empty
      } else {
        rows
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay(alignment: .bottomTrailing) {
      if snapshot.isSignedIn, !snapshot.rows.isEmpty {
        newSessionButton
      }
    }
  }

  /// The round New session button, bottom trailing, over the rows (the empty state has its
  /// own New Chat link; signed out has nothing to start). The app's tab-bar glyph.
  private var newSessionButton: some View {
    Link(destination: WidgetDeepLink.url(for: .newChat)) {
      Image(systemName: "square.and.pencil")
        .font(.body.weight(.semibold))
        .foregroundStyle(Color.primary)  // not the link tint
        .widgetAccentable()
        // The pencil pokes above the square, so the glyph's box centres it ~2 pt low; lift it
        // so the SQUARE sits in the circle's centre (measured on the snapshot).
        .offset(y: -2)
        .frame(width: 40, height: 40)
        .background(Circle().fill(Color.primary.opacity(0.12)))
        .contentShape(Circle())
    }
    .accessibilityLabel("New session")
  }

  private var header: some View {
    HStack(spacing: 6) {
      HermesGlyph()
        .frame(width: 18, height: 18)
      Text("Hermes")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(snapshot.rows.prefix(layout.maxRows)) { row in
        Link(destination: WidgetDeepLink.url(for: .openSession(id: row.id, profile: row.profile))) {
          SessionsWidgetRowView(
            row: row,
            status: WidgetStaleness.glyph(for: row, snapshot: snapshot, at: date),
            relativeTime: relativeTime
          )
        }
      }
    }
  }

  private var signedOut: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Sign in to Hermes")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
      Text("Open the app to connect to your agent.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxHeight: .infinity, alignment: .center)
  }

  private var empty: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No sessions yet")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
      Link(destination: WidgetDeepLink.url(for: .newChat)) {
        Label(LaunchIntent.newChat.shortcutTitle, systemImage: LaunchIntent.newChat.shortcutSymbolName)
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.primary)  // not the link tint
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Capsule().fill(Color.primary.opacity(0.12)))
      }
    }
    .frame(maxHeight: .infinity, alignment: .center)
  }
}
