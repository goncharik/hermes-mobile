import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshots for the file preview sheet (file preview in chat): the generic card for each
/// `Reason`, the failure state with Retry, the loading spinner, the monospaced text preview
/// (with its language caption, its truncation banner, and the "Path copied" toast), the
/// zoomable image preview, the PDF preview, the view-side fallback for image bytes UIKit
/// can't decode, and the Share status strip (determinate and indeterminate download, the
/// download-failed banner). The image and PDF fixtures are generated in-test
/// (`UIGraphicsImageRenderer` / `UIGraphicsPDFRenderer`) so no binary fixture is checked in.
///
/// The content region is rendered on its own (`FilePreviewSheet.content`) at a pinned width
/// AND height: every state fills the greedy region the sheet gives it, the text preview is a
/// scrolling `UITextView`, and `componentImage()` offers a greedy view nothing along either
/// axis. Two whole-sheet `deviceImage()` captures pin the chrome around it — the file-name
/// title, `Done`, and the Copy path / Share bottom bar. `.dynamicTypeSize(.large)` is pinned
/// so renders don't follow the simulator's text size.
///
/// Every store swallows `.task`: the sheet's `.task` would otherwise hit the unimplemented
/// `filePreview` test dependency during a key-window render (see `Reducer.ignoring`).
final class FilePreviewSnapshotTests: SnapshotTestCase {
  private let regionHeight: CGFloat = 600
  private var phoneWidth: CGFloat { device.size?.width ?? 390 }

  private func store(
    path: String,
    content: FilePreviewFeature.Content,
    share: FilePreviewFeature.ShareState = .idle,
    shareError: String? = nil,
    copiedToken: Int? = nil
  ) -> StoreOf<FilePreviewFeature> {
    Store(
      initialState: FilePreviewFeature.State(
        path: path, sessionID: "snapshot-session", profile: nil, connection: connection, content: content,
        share: share, shareError: shareError, copiedToken: copiedToken
      )
    ) {
      FilePreviewFeature().ignoring(\.task)
    }
  }

  /// The sheet's content region alone, pinned to a phone-wide 600pt slot.
  private func content(
    path: String,
    _ content: FilePreviewFeature.Content,
    share: FilePreviewFeature.ShareState = .idle,
    shareError: String? = nil,
    copiedToken: Int? = nil
  ) -> some View {
    FilePreviewSheet(
      store: store(
        path: path, content: content, share: share, shareError: shareError, copiedToken: copiedToken
      )
    ).content
      .frame(width: phoneWidth, height: regionHeight)
      .background(Color(uiColor: .systemBackground))
      .dynamicTypeSize(.large)
  }

  /// The whole sheet — navigation title, `Done`, bottom bar — as the user sees it.
  private func sheet(
    path: String,
    _ content: FilePreviewFeature.Content,
    share: FilePreviewFeature.ShareState = .idle,
    shareError: String? = nil,
    copiedToken: Int? = nil
  ) -> some View {
    FilePreviewSheet(
      store: store(
        path: path, content: content, share: share, shareError: shareError, copiedToken: copiedToken
      )
    )
    .dynamicTypeSize(.large)
  }

  // MARK: Generic card

  /// A binary the server won't render as text: archive glyph, name, path, size and the
  /// "No preview available" line.
  func testContent_genericUnsupported_withSize() {
    let view = content(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592))
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// Same card over a light background — the secondary tints are what's under test.
  func testContent_genericUnsupported_withSize_light() {
    let view = content(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592))
    )
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  /// 404 with the server's sandbox hint under the reason line; no size (the server never
  /// saw the file).
  func testContent_genericNotFound_withServerDetail() {
    let view = content(
      path: "/workspace/out/report.pdf",
      .generic(.init(
        reason: .notFound,
        serverDetail: "File not found. Paths under /workspace live inside the session sandbox."
      ))
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// 403 on a sensitive file: the dotfile keeps the plain document glyph (`.env` has no
  /// extension) and the "protected" line.
  func testContent_genericProtected() {
    let view = content(path: "/home/eugene/project/.env", .generic(.init(reason: .protected)))
    assertSnapshot(of: view, as: componentImage())
  }

  /// 413 from the data-URL route on an image: photo glyph and the "too large" line (Share
  /// still works from the bottom bar, which the sheet capture covers).
  func testContent_genericTooLarge() {
    let view = content(
      path: "/home/eugene/screenshots/full-page.png", .generic(.init(reason: .tooLarge))
    )
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Failure and loading

  /// A transport failure: the unavailable-content layout with the message and a prominent
  /// Retry.
  func testContent_failed_withRetry() {
    let view = content(
      path: "/home/eugene/out/report.pdf",
      .failed(message: "The agent is offline. Check the connection and try again.")
    )
    assertSnapshot(of: view, as: componentImage())
  }

  func testContent_failed_withRetry_light() {
    let view = content(
      path: "/home/eugene/out/report.pdf",
      .failed(message: "The agent is offline. Check the connection and try again.")
    )
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  /// The spinner centred in the region while the first read is in flight. A layer render
  /// (`componentImage`) draws the indicator's model layer, so the capture is deterministic —
  /// unlike a key-window capture of the same spinner (`SnapshotTestSupport`).
  func testContent_loading() {
    let view = content(path: "/home/eugene/out/report.pdf", .loading)
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Text preview

  /// A short source file: the `swift` caption row over the monospaced text, which fills the
  /// region (the empty space under the last line is still the text view).
  func testContent_text_withLanguage() {
    let view = content(path: "/home/eugene/project/Sources/App.swift", .text(Self.shortSwift))
    assertSnapshot(of: view, as: componentImage())
  }

  func testContent_text_withLanguage_light() {
    let view = content(path: "/home/eugene/project/Sources/App.swift", .text(Self.shortSwift))
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  /// A log the server cut at its 512 KB limit: the "Showing first 512 KB" banner under the
  /// caption, then the (long) text scrolling inside the region — only the first screenful
  /// renders, the rest is proven scrollable by `FilePreviewTextLayoutTests`.
  func testContent_text_truncated() {
    let read = FileTextRead(
      byteSize: 3_145_728,
      language: "log",
      text: (1...80).map { "2026-11-03T09:\(String(format: "%02d", $0 % 60)):00Z INFO worker-\($0 % 4) processed batch \($0)" }
        .joined(separator: "\n"),
      truncated: true
    )
    let view = content(path: "/home/eugene/logs/agent.log", .text(read))
    assertSnapshot(of: view, as: componentImage())
  }

  /// No language from the server and nothing truncated: just the text, no caption rows.
  func testContent_text_plain() {
    let read = FileTextRead(byteSize: 112, text: "name = \"hermes\"\nport = 9119\nverbose = true\n")
    let view = content(path: "/home/eugene/.hermes/settings.toml", .text(read))
    assertSnapshot(of: view, as: componentImage())
  }

  private static let shortSwift = FileTextRead(
    byteSize: 180,
    language: "swift",
    text: """
      import Foundation

      struct Greeting {
        let name: String

        var text: String { "Hello, \\(name)!" }
      }

      print(Greeting(name: "Hermes").text)
      """
  )

  // MARK: Image and PDF previews

  /// A 64×64 two-tone PNG aspect-fitted (scaled up, like the system viewers) into the
  /// region at 1×: a 390pt square, the two halves visibly an image, centered vertically on
  /// the sheet background.
  func testContent_image() {
    let view = content(path: "/home/eugene/screenshots/swatch.png", .image(Self.twoTonePNG()))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A one-page PDF (title, body line, a filled rounded rectangle) in `PDFKitView`: the page
  /// scaled to the region's width by `autoScales`, continuous vertical layout, the sheet
  /// background as the gutter under the page.
  func testContent_pdf() {
    let view = content(path: "/home/eugene/out/report.pdf", .pdf(Self.onePagePDF()))
    assertSnapshot(of: view, as: componentImage())
  }

  /// `.image` bytes UIKit can't decode (the reducer never looks at them): the view falls back
  /// to the generic card with the photo glyph (by extension), the byte count it does know,
  /// and "No preview available".
  func testContent_image_undecodable() {
    let view = content(
      path: "/home/eugene/screenshots/corrupt.png", .image(Data("not an image".utf8))
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// Fixed (non-dynamic) colours so the PNG bytes don't depend on the runner's appearance.
  private static func twoTonePNG() -> Data {
    let side: CGFloat = 64
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).pngData { ctx in
      UIColor(red: 0.16, green: 0.50, blue: 0.73, alpha: 1).setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
      UIColor(red: 0.95, green: 0.61, blue: 0.07, alpha: 1).setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
    }
  }

  /// A US-Letter page with a heading, one line of body text and a filled rounded rectangle.
  private static func onePagePDF() -> Data {
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
      ctx.beginPage()
      let title: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: UIColor.black,
      ]
      let body: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.darkGray,
      ]
      "Quarterly report".draw(at: CGPoint(x: 72, y: 72), withAttributes: title)
      "Generated by Hermes Agent on 2026-11-03.".draw(at: CGPoint(x: 72, y: 124), withAttributes: body)
      UIColor(red: 0.16, green: 0.50, blue: 0.73, alpha: 1).setFill()
      UIBezierPath(roundedRect: CGRect(x: 72, y: 180, width: 468, height: 240), cornerRadius: 16).fill()
    }
  }

  // MARK: Share status strip

  /// Share in flight with a known size: the strip inset at the bottom of the region (the
  /// generic card re-centres above it) with "Downloading… 45%", Cancel, and the linear bar
  /// filled to 45 %.
  func testContent_downloading_determinate() {
    let view = content(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592)),
      share: .downloading(fraction: 0.45)
    )
    assertSnapshot(of: view, as: componentImage())
  }

  func testContent_downloading_determinate_light() {
    let view = content(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592)),
      share: .downloading(fraction: 0.45)
    )
    assertSnapshot(of: view, as: componentImage(appearance: .light))
  }

  /// No `Content-Length` from the server: a small spinner leads the "Downloading…" label, no
  /// percentage, no bar — Cancel still offered. A layer render draws the spinner's model
  /// layer, so the capture is deterministic (as for `testContent_loading`).
  func testContent_downloading_indeterminate() {
    let view = content(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592)),
      share: .downloading(fraction: nil)
    )
    assertSnapshot(of: view, as: componentImage())
  }

  /// The download failed: Share is back to idle (the bottom bar re-enables it — see the
  /// sheet capture) and the error strip shows the message in the chat's red banner idiom.
  func testContent_shareError() {
    let view = content(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592)),
      shareError: "The agent is offline. Check the connection and try again."
    )
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Whole sheet

  /// The chrome around the generic card: the file name as the inline title, `Done`, and the
  /// Copy path / Share bottom bar with Share enabled (nothing is downloading).
  func testSheet_genericUnsupported() {
    let view = sheet(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592))
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Copy path just fired on a text preview: the "Path copied" toast floats over the text,
  /// ABOVE the Copy path / Share bar — the content region's safe area ends at the bar, which
  /// is what `.safeAreaPadding(.bottom)` in `CopiedToastView` adds. Built from state
  /// (`copiedToken` set), no clock involved. A whole-sheet key-window capture, like the other
  /// toast baselines: the toast's glass capsule (and the label it composites) does not draw
  /// in a `componentImage()` layer render — only the SF Symbol survives.
  func testSheet_text_copiedToast() {
    let view = sheet(
      path: "/home/eugene/project/Sources/App.swift", .text(Self.shortSwift), copiedToken: 1
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// The failure state inside the sheet: Retry sits in the content, Copy path and Share stay
  /// offered in the bar (the path is still worth copying when the read failed).
  func testSheet_failed() {
    let view = sheet(
      path: "/home/eugene/out/report.pdf",
      .failed(message: "The agent is offline. Check the connection and try again.")
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  /// A determinate download inside the sheet: the strip sits directly ABOVE the Copy path /
  /// Share bottom bar (the content region's safe area ends at the bar), and Share itself is
  /// disabled while the bytes are in flight. Determinate on purpose — a whole-sheet capture
  /// of the indeterminate spinner would catch it at an arbitrary rotation.
  func testSheet_downloading() {
    let view = sheet(
      path: "/home/eugene/out/export-2026-11-03.zip",
      .generic(.init(reason: .unsupported, byteSize: 4_718_592)),
      share: .downloading(fraction: 0.45)
    )
    assertSnapshot(of: view, as: deviceImage())
  }
}
