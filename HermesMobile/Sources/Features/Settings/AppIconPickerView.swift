import ComposableArchitecture
import HermesKit
import SwiftUI

/// Settings → App Icon: a three-column grid of the icons this build can switch between, the
/// current one checked. Display only — the optimistic tap, the rollback and the banner all
/// live in `AppIconPickerFeature`.
struct AppIconPickerView: View {
  let store: StoreOf<AppIconPickerFeature>

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        LazyVGrid(columns: columns, spacing: 20) {
          ForEach(store.catalog.options, id: \.name) { option in
            AppIconTile(option: option, isSelected: store.state.isSelected(option)) {
              store.send(.iconTapped(store.state.iconName(for: option)))
            }
          }
        }
        if let errorBanner = store.errorBanner {
          Label(errorBanner, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
      .padding()
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("App Icon")
    .navigationBarTitleDisplayMode(.inline)
    .task { store.send(.task) }
  }
}

/// One icon tile: the preview clipped to the home-screen squircle, its label below, and a
/// checkmark badge when it is the current icon.
private struct AppIconTile: View {
  let option: AppIconOption
  let isSelected: Bool
  let action: () -> Void

  /// Fixed so the grid lays out identically on every width the sheet gets; the corner
  /// radius is the home-screen ratio (~22.5% of the side).
  private static let side: CGFloat = 76
  private static let cornerRadius: CGFloat = 17

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        Image(option.previewAsset)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: Self.side, height: Self.side)
          .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
              .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                            lineWidth: isSelected ? 3 : 0.5)
          }
          .overlay(alignment: .bottomTrailing) {
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .tint)
                .background(Circle().fill(Color(.systemGroupedBackground)).padding(2))
                .offset(x: 6, y: 6)
            }
          }
        Text(option.label)
          .font(.footnote)
          .foregroundStyle(isSelected ? .primary : .secondary)
          .multilineTextAlignment(.center)
          .lineLimit(2, reservesSpace: true)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(option.label)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
