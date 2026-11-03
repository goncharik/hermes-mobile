import SwiftUI
import UIKit

/// The system share sheet for a downloaded preview file (`FilePreviewFeature.ShareState.ready`),
/// wrapped so `FilePreviewSheet` can present it with `.sheet(item:)`.
///
/// Presented as a SwiftUI sheet on purpose, not as a popover: SwiftUI hosts the activity
/// controller inside its own presented container, so the iPad "popover needs a source
/// view" crash does not apply and the share UI gets the same detented sheet on every
/// device. The activity controller is therefore a CHILD of the sheet's hosting controller,
/// and dismissing it (its close button, or finishing an activity) does not take the SwiftUI
/// sheet down on its own — `completionWithItemsHandler` reports it through `onComplete`, and
/// the owner nils the item binding (`.shareDismissed`). A swipe-down on the sheet goes the
/// other way round (binding first, then possibly the completion handler), so the owner
/// guards against sending the dismissal twice.
struct ActivityShareSheet: UIViewControllerRepresentable {
  /// The temp file to share; its last path component is the name every target sees.
  let url: URL
  /// Fires once the share flow ends — shared, saved or cancelled alike.
  let onComplete: () -> Void

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
    return controller
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
