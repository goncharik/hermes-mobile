import HermesKit
import SwiftUI

/// Settings → Acknowledgements: every open-source package the app links, each expanding to
/// its full license text and a link to its repository. Static — renders `Acknowledgement.all`,
/// so it takes no store (`AcknowledgementsFeature` has nothing to reduce).
struct AcknowledgementsView: View {
  var body: some View {
    List {
      Section {
        ForEach(Acknowledgement.all) { acknowledgement in
          DisclosureGroup {
            Text(acknowledgement.licenseText)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            Link(destination: acknowledgement.url) {
              HStack {
                Text("Source on GitHub")
                Spacer()
                Image(systemName: "arrow.up.right")
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(acknowledgement.name)
                .foregroundStyle(.primary)
              Text("\(acknowledgement.license) License")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }
      } footer: {
        Text("Hermes Mobile is built on these open-source packages.")
      }
    }
    .navigationTitle("Acknowledgements")
    .navigationBarTitleDisplayMode(.inline)
  }
}
