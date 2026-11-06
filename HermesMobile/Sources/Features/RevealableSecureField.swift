import SwiftUI
import UIKit

/// A credential field with an eye button that toggles between masked and plain text (#129),
/// so a typed password or a long pasted token can be checked before connecting.
///
/// Both fields stay mounted in a `ZStack` and only the visible one takes hits, focus and
/// accessibility. Swapping `SecureField` for `TextField` with `if`/`else` would drop the
/// keyboard on every toggle; keeping both lets the button move focus to the new field.
/// Autocorrection and capitalization are always off, since both would corrupt a credential.
///
/// Whether the text is revealed is view-local `@State`, never reducer state: it changes
/// nothing about what gets sent, and a fresh screen always starts masked.
/// `initiallyRevealed` exists for the snapshot suite, which can't tap the button.
struct RevealableSecureField: View {
  let title: String
  @Binding var text: String
  let contentType: UITextContentType?

  @State private var isRevealed: Bool
  @FocusState private var focusedField: Field?

  private enum Field {
    case masked
    case plain
  }

  init(
    _ title: String,
    text: Binding<String>,
    textContentType: UITextContentType? = nil,
    initiallyRevealed: Bool = false
  ) {
    self.title = title
    _text = text
    self.contentType = textContentType
    _isRevealed = State(initialValue: initiallyRevealed)
  }

  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        SecureField(title, text: $text)
          .focused($focusedField, equals: .masked)
          .opacity(isRevealed ? 0 : 1)
          .allowsHitTesting(!isRevealed)
          .accessibilityHidden(isRevealed)
        TextField(title, text: $text)
          .focused($focusedField, equals: .plain)
          .opacity(isRevealed ? 1 : 0)
          .allowsHitTesting(isRevealed)
          .accessibilityHidden(!isRevealed)
      }
      .textContentType(contentType)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()

      Button {
        let hadFocus = focusedField != nil
        isRevealed.toggle()
        if hadFocus { focusedField = isRevealed ? .plain : .masked }
      } label: {
        Image(systemName: isRevealed ? "eye.slash" : "eye")
          .foregroundStyle(.secondary)
          .contentTransition(.symbolEffect(.replace))
      }
      // Borderless, or a tap anywhere on the Form row would fire the toggle.
      .buttonStyle(.borderless)
      .accessibilityLabel(isRevealed ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
  }
}

#Preview {
  Form {
    RevealableSecureField("Password", text: .constant("hunter2"), textContentType: .password)
    RevealableSecureField("Session token", text: .constant("tok_abc123"), initiallyRevealed: true)
  }
}
