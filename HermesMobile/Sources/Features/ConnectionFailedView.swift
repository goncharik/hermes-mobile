import ComposableArchitecture
import HermesKit
import SwiftUI

/// Shown instead of onboarding when **launch auto-connect** fails for a reason unrelated to
/// the stored credentials. They're still good, so the screen never asks for them again — it
/// names the server it couldn't reach, says why, and offers a Retry. **Log Out** — behind a
/// confirmation — abandons the session via the logout recipe in `AppFeature`.
///
/// It also carries a tertiary link to `AgentSetupGuideView`, the app's single connection-help
/// surface: launch transport failures no longer pass through onboarding at all, and this
/// screen shows exactly the failures the guide explains (a host-header 400, a 404 from a route
/// that moved, a `.decoding` reply that "doesn't look like Hermes"). Presentation is view-local
/// `@State` — the same way onboarding's `ConnectionView` does it — so nothing about a sheet
/// reaches the reducer.
struct ConnectionFailedView: View {
  @Bindable var store: StoreOf<ConnectionFailedFeature>

  @State private var showsSetupGuide = false

  /// The hero glyph, sized well above any text style: this is a full-screen failure state, and
  /// the icon is what identifies it before a word is read. Deliberately larger than
  /// `.largeTitle`, which is why it is a point size rather than a semantic `Font`.
  private static let iconPointSize: CGFloat = 56

  /// Floor for the retry button's label, so swapping "Retry" for a `ProgressView` (which
  /// measures shorter than a line of text) doesn't shrink the button and jolt everything above
  /// it.
  private static let buttonLabelMinHeight: CGFloat = 22

  var body: some View {
    // Scrolls so the buttons stay reachable at accessibility Dynamic Type sizes; the
    // `minHeight` keeps the default-size layout (title centred, buttons at the bottom)
    // pixel-identical to a plain `VStack`.
    GeometryReader { proxy in
      ScrollView {
        content
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    // `.bottomActionSheet`, not `.confirmationDialog` — on iOS 26 the system dialog
    // renders as a title-less floating popover (FB20644893; see `BottomActionSheet.swift`).
    .bottomActionSheet($store.scope(state: \.confirmationDialog, action: \.confirmationDialog))
    .sheet(isPresented: $showsSetupGuide) {
      AgentSetupGuideView()
    }
  }

  /// Hand-rolled rather than `ContentUnavailableView` (which every other empty/failure state in
  /// the app uses): that view stacks label → description → `actions` as one centred block, and
  /// this screen needs the message centred with its escape routes pinned to the BOTTOM —
  /// a split it has no API for. Its `actions:` slot would also put "Log Out" mid-screen, next
  /// to Retry, which is the opposite of the weighting a destructive action wants.
  private var content: some View {
    VStack(spacing: 24) {
      Spacer(minLength: 0)

      Image(systemName: "wifi.exclamationmark")
        .font(.system(size: Self.iconPointSize, weight: .light))
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(spacing: 12) {
        Text("Can’t reach the server")
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)

        // Monospaced and deliberately UNCAPPED (no `lineLimit`): a long tailnet host with no
        // break opportunities must wrap rather than truncate — the URL is the whole point of
        // the screen ("which server?"), so an ellipsis would drop the only fact it carries.
        Text(store.serverURLText)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        // Capped, unlike the URL above: this line can quote a server-supplied `detail`, and
        // the escape routes sit BELOW it inside the `ScrollView`. The reducer already
        // clamps the quote (`ConnectionFailedFeature.State.sanitizedServerDetail`); this is
        // the belt-and-braces half, so no reason string can ever push Retry off the screen.
        Text(store.reasonText)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(6)
      }
      .padding(.horizontal, 8)

      Spacer(minLength: 0)

      VStack(spacing: 12) {
        Button {
          store.send(.retryTapped)
        } label: {
          // Fixed-height container so swapping the label for a spinner doesn't make the
          // button (and everything above it) jump.
          Group {
            if store.isRetrying {
              ProgressView()
                .progressViewStyle(.circular)
            } else {
              Text("Retry")
            }
          }
          .frame(maxWidth: .infinity, minHeight: Self.buttonLabelMinHeight)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(store.isRetrying)
        .accessibilityLabel(store.isRetrying ? "Retrying" : "Retry")

        // Tertiary, above the destructive one: the failures this screen reports are the
        // ones the guide answers (host-header 400, a moved route's 404, a reply that
        // doesn't look like Hermes). Deliberately NOT disabled while retrying — a probe can
        // run up to URLSession's 60s default, and the foreground auto-retry arms it without
        // the user asking, so the ways off this screen must never be greyed out by it.
        Button("Need help setting up your agent?") {
          showsSetupGuide = true
        }
        .buttonStyle(.borderless)
        .font(.footnote)

        // `role: .destructive` like every other destructive control in the app (and like this
        // feature's own confirm button) — the role carries the semantics and the accessibility
        // trait, and the style has to be one that HONOURS it: `.plain` draws its label with no
        // role decoration at all, so pairing the two would have claimed the semantics while
        // rendering an ordinary-looking control. De-emphasis comes from the smaller font, not
        // from dropping the role.
        Button("Log Out", role: .destructive) {
          store.send(.logoutButtonTapped)
        }
        .buttonStyle(.borderless)
        .font(.callout)
      }
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 40)
  }
}

#Preview {
  ConnectionFailedView(
    store: Store(
      initialState: ConnectionFailedFeature.State(
        connection: ServerConnection(
          baseURL: URL(string: "http://mac.tailnet:9119")!,
          token: "t"
        ),
        reason: .unreachable
      )
    ) {
      ConnectionFailedFeature()
    }
  )
}
