import SwiftUI
import UIKit

/// The image face of the file preview sheet: a `UIScrollView` zooming a `UIImageView`
/// between 1× (aspect-fit in the region) and 4×, with a double-tap that toggles 1× ↔ 2× at
/// the tap point. The image is always centered — in the region while it is smaller than it,
/// at the scroll view's origin once zoomed past it.
///
/// Display-only. Whether the bytes decode is decided by the sheet through `image(from:)`
/// (the reducer is platform-free and hands over raw `Data`); a nil image is the sheet's cue
/// to show `GenericFileCardView` instead. The whole scroll view is ONE accessibility element
/// labelled with the file name, so VoiceOver reads "report.png, image" rather than an
/// anonymous scroll area.
struct ZoomableImageView: UIViewRepresentable {
  let image: UIImage
  /// The file name — what VoiceOver announces for the image.
  let accessibilityLabel: String

  /// View-side decodability check: UIKit's verdict on the bytes the data-URL route
  /// returned. Static and synchronous so the sheet can branch on it inside `body`.
  static func image(from data: Data) -> UIImage? {
    UIImage(data: data)
  }

  func makeUIView(context: Context) -> ZoomableImageScrollView {
    let view = ZoomableImageScrollView(image: image)
    view.accessibilityLabel = accessibilityLabel
    return view
  }

  func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
    view.accessibilityLabel = accessibilityLabel
    // Only a genuinely new image resets the zoom; the sheet's `.equatable()` wrapper keeps
    // the same `UIImage` across unrelated re-renders (the copy toast, the share bar).
    if view.image !== image { view.image = image }
  }
}

/// The scroll view behind `ZoomableImageView`. Owns the image view, the zoom bounds, the
/// double-tap gesture and the centering math; `layoutSubviews` re-fits the image when the
/// region changes size (rotation, a split-view resize) and re-centers it after every zoom.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
  static let minimumZoom: CGFloat = 1
  static let maximumZoom: CGFloat = 4
  /// Where a double-tap on an unzoomed image lands.
  static let doubleTapZoom: CGFloat = 2

  private let imageView = UIImageView()
  /// The bounds the image was last fitted to, so a zoom-driven `layoutSubviews` (the
  /// content offset changes on every pan) does not re-fit and reset the zoom.
  private var fittedBoundsSize: CGSize = .zero

  var image: UIImage? {
    get { imageView.image }
    set {
      imageView.image = newValue
      fittedBoundsSize = .zero
      setNeedsLayout()
    }
  }

  init(image: UIImage) {
    super.init(frame: .zero)
    delegate = self
    minimumZoomScale = Self.minimumZoom
    maximumZoomScale = Self.maximumZoom
    bouncesZoom = true
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    contentInsetAdjustmentBehavior = .never
    // Neutral in both appearances: the sheet's own background, so letterboxing is invisible.
    backgroundColor = .systemBackground

    imageView.contentMode = .scaleAspectFit
    imageView.image = image
    addSubview(imageView)

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
    doubleTap.numberOfTapsRequired = 2
    addGestureRecognizer(doubleTap)

    isAccessibilityElement = true
    accessibilityTraits = .image
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.size != fittedBoundsSize {
      fittedBoundsSize = bounds.size
      fitImage()
    }
    centerImage()
  }

  /// Sizes the image view to the image's aspect-fit rect inside the bounds at 1× (an image
  /// smaller than the region scales up to fit, like the system viewers), and resets the zoom
  /// so the fitted size IS the 1× content size.
  private func fitImage() {
    zoomScale = Self.minimumZoom
    let fitted = Self.fittedSize(of: imageView.image?.size ?? .zero, in: bounds.size)
    imageView.frame = CGRect(origin: .zero, size: fitted)
    contentSize = fitted
  }

  /// Keeps the (possibly zoomed) image view centered along each axis where it is smaller
  /// than the region; along an axis where it is larger, the scroll view's own offset rules.
  private func centerImage() {
    var frame = imageView.frame
    frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
    frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
    imageView.frame = frame
  }

  /// The largest size with `image`'s aspect ratio that fits `container` (zero for a degenerate
  /// image or container). Pure so it can be reasoned about without a view.
  static func fittedSize(of image: CGSize, in container: CGSize) -> CGSize {
    guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else {
      return .zero
    }
    let scale = min(container.width / image.width, container.height / image.height)
    return CGSize(width: image.width * scale, height: image.height * scale)
  }

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    if zoomScale > Self.minimumZoom + 0.01 {
      setZoomScale(Self.minimumZoom, animated: true)
    } else {
      // Zoom to a rect (in the image view's coordinates) centered on the tap, sized so the
      // result is `doubleTapZoom`×.
      let point = gesture.location(in: imageView)
      let size = CGSize(width: bounds.width / Self.doubleTapZoom, height: bounds.height / Self.doubleTapZoom)
      let rect = CGRect(
        x: point.x - size.width / 2, y: point.y - size.height / 2,
        width: size.width, height: size.height
      )
      zoom(to: rect, animated: true)
    }
  }

  // MARK: UIScrollViewDelegate

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
}
