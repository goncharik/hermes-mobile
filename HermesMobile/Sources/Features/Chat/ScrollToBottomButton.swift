import SwiftUI

/// A circular "jump to latest" button shown over the transcript when the user has
/// scrolled up. Uses Liquid Glass on iOS 26+, falling back to a material on earlier OSes.
struct ScrollToBottomButton: View {
  let action: () -> Void

  var body: some View {
    // Uses `.onTapGesture`, NOT `Button`: inside the SwiftUI transcript engine a `Button` here
    // never received taps (a sibling `.onTapGesture` in the same container did — verified on
    // device), while the UICollectionView engine hosts this view in its own controller where
    // either works. An explicit tap gesture is reliable in both contexts; button semantics are
    // restored for VoiceOver via accessibility traits/action.
    Image(systemName: "chevron.down")
      .font(.body.weight(.semibold))
      .foregroundStyle(.primary)
      .frame(width: 44, height: 44)
      .modifier(GlassCircle())
      .contentShape(Circle())
      .onTapGesture(perform: action)
      .accessibilityElement()
      .accessibilityLabel("Scroll to latest")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, action)
  }
}

/// Liquid-glass circular background on iOS 26+, material + hairline fallback below.
private struct GlassCircle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      // `.interactive()` gives the Liquid Glass press highlight (the glass reacts to the touch on
      // its own — it doesn't require a `Button`), so it coexists with our `.onTapGesture` which
      // owns the actual tap action.
      content.glassEffect(.regular.interactive(), in: .circle)
    } else {
      content
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
  }
}
