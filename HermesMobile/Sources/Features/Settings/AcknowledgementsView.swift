import HermesKit
import SwiftUI

/// Settings → Acknowledgements: the open-source packages the app ships, each linking to its
/// repository. Static — renders `Acknowledgement.all`, so it takes no store
/// (`AcknowledgementsFeature` has nothing to reduce).
struct AcknowledgementsView: View {
  var body: some View {
    List {
      Section {
        ForEach(Acknowledgement.all) { acknowledgement in
          Link(destination: acknowledgement.url) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(acknowledgement.name)
                  .foregroundStyle(.primary)
                Text("\(acknowledgement.license) License")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          // A list `Link` resolves `.primary` to the tint; keep the name label-coloured.
          .tint(.primary)
        }
      } footer: {
        Text("Hermes Mobile is built on these open-source packages.")
      }
    }
    .navigationTitle("Acknowledgements")
    .navigationBarTitleDisplayMode(.inline)
  }
}
