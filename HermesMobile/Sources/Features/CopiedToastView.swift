import SwiftUI

/// A small transient confirmation toast ("Session ID copied", "Path copied"), shown as a
/// bottom-aligned overlay after a copy action. Presentation is driven purely by the
/// feature's copy token — the reducer owns the 1.5s dwell timer, this view only renders
/// (and animates) the state.
///
/// Non-interactive by design (`allowsHitTesting(false)`) so it never eats a tap on the
/// list row or composer beneath it.
struct CopiedToastView: View {
  /// The feature's copy token (`copiedIDToastToken`, `FilePreviewFeature.copiedToken`):
  /// `nil` while hidden, otherwise a per-copy counter. Owning the conditional here keeps
  /// every call site to a single `.overlay(alignment: .bottom) { CopiedToastView(token:) }`.
  var token: Int?
  /// What the toast says — also what VoiceOver announces. Defaults to the session-list /
  /// chat copy; the file preview sheet passes its own.
  var message: String = "Session ID copied"

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isPresented: Bool { token != nil }

  var body: some View {
    ZStack {
      if isPresented {
        Label(message, systemImage: "checkmark.circle.fill")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          // Not `.interactive()` — the toast isn't a control.
          .modifier(GlassBackground(shape: Capsule(), fallbackShadowRadius: 6, fallbackShadowY: 3))
          .padding(.bottom, 24)
          // No reduce-motion branch needed: when reduce-motion nils the animation below,
          // nothing drives the insertion, so the transition never runs and the toast
          // simply appears.
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    // Overlay hosts (a `List`, the transcript) extend under the home indicator, so the
    // 24pt padding alone would drop the toast into that band on a screen with no bottom
    // bar. This adds the host's own bottom inset — 0 when the host already excludes it.
    .safeAreaPadding(.bottom)
    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isPresented)
    .allowsHitTesting(false)
    // VoiceOver focus never moves to a transient overlay — it stays on the row whose
    // context menu just closed — and the toast is gone 1.5s later, so rendering alone
    // gives a VoiceOver user NO confirmation that the copy happened. Announce it.
    //
    // Keyed on the token, not on `isPresented`: a re-copy while the toast is still up
    // leaves it visible (the flag never flips), and this is the only confirmation channel
    // a VoiceOver user has — every copy has to speak, so every copy bumps the token.
    .onChange(of: token) { _, token in
      guard token != nil else { return }
      AccessibilityNotification.Announcement(message).post()
    }
  }
}
