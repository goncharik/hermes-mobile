import HermesKit
import SwiftUI

/// A tool call's line inside a turn's fold (the T3 Code look): a tool icon and the call's
/// one-line title in secondary grey, with a chevron when there is detail to open. No status
/// seal and no spinner — the turn header carries the live state. A tap opens the detail sheet.
struct ToolStatusView: View {
  let name: String
  let title: String
  let hasDetail: Bool
  let onTap: () -> Void

  var body: some View {
    FoldLine(
      systemImage: "wrench.and.screwdriver",
      text: title.isEmpty ? name : title,
      chevron: hasDetail ? "chevron.right" : nil
    )
    .foldTap(isExpanded: nil, action: hasDetail ? onTap : nil)
  }
}
