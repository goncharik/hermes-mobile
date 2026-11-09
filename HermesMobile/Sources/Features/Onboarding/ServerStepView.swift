import ComposableArchitecture
import HermesKit
import SwiftUI

/// Onboarding step 1 (#136): the agent's address. Thin over `ServerStep` — the live
/// "Connects to …" line reads the parsed `ServerAddress`, the checklist reads
/// `ServerStep.State.status(of:)`, and a failure renders as a `ProbeFailureCard`.
struct ServerStepView: View {
  @Bindable var store: StoreOf<ServerStep>
  let setupGuideButtonTapped: () -> Void

  @FocusState private var isAddressFocused: Bool

  /// The example shapes under the field; tapping one fills it in.
  private static let examples: [(label: String, systemImage: String, address: String)] = [
    ("Tailscale name", "network", "mac-mini.tail4c2e.ts.net"),
    ("Local IP", "wifi", "192.168.1.20"),
    ("https:// address", "cloud", "https://agent.example.com"),
  ]

  var body: some View {
    OnboardingScreen {
      VStack(alignment: .leading, spacing: 20) {
        OnboardingHeading(
          title: "Where’s your agent?",
          subtitle: "Enter the address you use to open the Hermes dashboard."
        )
        addressField
        if store.phase == .idle {
          examples
        } else {
          checklist
        }
        if case let .failed(failed) = store.phase {
          ProbeFailureCard(failed: failed, setupGuideButtonTapped: setupGuideButtonTapped)
        }
      }
    } footer: {
      Button(action: continueButtonTapped) {
        Text(continueTitle)
          .frame(maxWidth: .infinity)
      }
      .onboardingPrimaryButton()
      .disabled(!store.canContinue)
      Button("Where do I find the address?", action: setupGuideButtonTapped)
        .onboardingPlainButton()
    }
    .navigationTitle("Step 1 of 2")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { store.send(.onAppear) }
  }

  private var continueTitle: String {
    switch store.phase {
    case .idle: "Continue"
    case .probing: "Checking…"
    case .failed: "Try again"
    }
  }

  private func continueButtonTapped() {
    isAddressFocused = false
    store.send(.continueButtonTapped)
  }

  // MARK: - Address

  private var addressField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Agent address")
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      OnboardingFieldGroup(hasError: store.showsInvalidAddressHint) {
        HStack(spacing: 8) {
          TextField("mac-mini.tail4c2e.ts.net", text: $store.addressText)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .focused($isAddressFocused)
            .onSubmit(continueButtonTapped)
            .accessibilityLabel("Agent address")
          if !store.addressText.isEmpty {
            Button {
              store.addressText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Clear address")
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
      }

      resolvedLine
    }
  }

  /// Where Continue will knock, or why it can't.
  @ViewBuilder
  private var resolvedLine: some View {
    if store.showsInvalidAddressHint {
      Text("That doesn’t look like an address yet.")
        .font(.footnote)
        .foregroundStyle(.red)
    } else if let address = store.address {
      Group {
        if address.candidates.count > 1 {
          Text("""
          Connects to \(code(address.url.absoluteString)), then \
          \(code(":\(ServerAddress.fallbackPort)")) if no agent answers
          """)
        } else {
          Text("Connects to \(code(address.url.absoluteString))")
        }
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func code(_ text: String) -> Text {
    Text(verbatim: text).font(.footnote.monospaced())
  }

  // MARK: - Examples

  private var examples: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Try one of these shapes")
        .font(.footnote)
        .foregroundStyle(.secondary)
      OnboardingFlowLayout(spacing: 8) {
        ForEach(Self.examples, id: \.address) { example in
          Button {
            store.addressText = example.address
          } label: {
            Label(example.label, systemImage: example.systemImage)
              .font(.subheadline)
          }
          .buttonStyle(.bordered)
          .buttonBorderShape(.capsule)
          .tint(.secondary)
          .accessibilityHint("Fills in \(example.address)")
        }
      }
    }
  }

  // MARK: - Checklist

  private var checklist: some View {
    OnboardingCard {
      ForEach(ServerStep.State.Check.allCases, id: \.self) { check in
        if let status = store.state.status(of: check) {
          ChecklistRow(label: label(for: check), status: status)
        }
      }
    }
  }

  private func label(for check: ServerStep.State.Check) -> String {
    switch check {
    case .reaching: "Reaching \(store.address?.host ?? store.addressText)"
    case .hermes: "Checking it’s a Hermes agent"
    case .signInOptions: "Reading sign-in options"
    }
  }

  private struct ChecklistRow: View {
    let label: String
    let status: ServerStep.State.CheckStatus

    var body: some View {
      HStack(spacing: 12) {
        mark
          .frame(width: 22, height: 22)
        Text(verbatim: label)
          .font(.body)
          .foregroundStyle(status == .pending ? .tertiary : .primary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(label), \(statusDescription)")
    }

    @ViewBuilder
    private var mark: some View {
      switch status {
      case .pending:
        Circle()
          .fill(.tertiary)
          .frame(width: 8, height: 8)
      case .running:
        ProgressView()
          .controlSize(.small)
      case .passed:
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
      case .failed:
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.red)
      }
    }

    private var statusDescription: String {
      switch status {
      case .pending: "waiting"
      case .running: "in progress"
      case .passed: "done"
      case .failed: "failed"
      }
    }
  }
}

#Preview {
  NavigationStack {
    ServerStepView(
      store: Store(initialState: ServerStep.State(addressText: "mac-mini.tail4c2e.ts.net")) {
        ServerStep()
      },
      setupGuideButtonTapped: {}
    )
  }
}
