import PDFKit
import SwiftUI

/// The PDF face of the file preview sheet: a `PDFKit.PDFView` scrolling all pages
/// continuously top to bottom, each scaled to fit the region's width (`autoScales`), with
/// PDFKit's own pinch-to-zoom.
///
/// Display-only. The sheet turns the reducer's raw `Data` into a `PDFDocument` through
/// `document(from:)`; a nil result (bytes PDFKit can't open, or a document with no pages) is
/// its cue to show `GenericFileCardView` instead. `PDFKit` is imported in the app target only
/// — HermesKit stays platform-free.
struct PDFKitView: UIViewRepresentable {
  let document: PDFDocument

  /// View-side decodability check: PDFKit's verdict on the bytes the data-URL route
  /// returned. A document PDFKit opens but finds no pages in is treated as undecodable too —
  /// an empty `PDFView` would look like a broken load. Static and synchronous so the sheet can
  /// branch on it inside `body`.
  static func document(from data: Data) -> PDFDocument? {
    guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
    return document
  }

  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    // Neutral gutter around the (usually white) pages in both appearances.
    view.backgroundColor = .systemBackground
    view.document = document
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    // Only a genuinely new document resets the view (page position, zoom); the sheet's
    // `.equatable()` wrapper keeps the same instance across unrelated re-renders.
    if view.document !== document { view.document = document }
  }
}
