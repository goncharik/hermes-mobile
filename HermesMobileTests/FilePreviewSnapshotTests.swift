import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshots for the file preview sheet (file preview in chat) in the states the skeleton
/// renders today: the generic card for each `Reason`, the failure state with Retry, and the
/// loading spinner. Text / image / PDF renderers get their own cases in Tasks 7–8.
///
/// The content region is rendered on its own (`FilePreviewSheet.content`) at a pinned width
/// AND height: every state fills the greedy region the sheet gives it, and `componentImage()`
/// offers a greedy view nothing along either axis. Two whole-sheet `deviceImage()` captures
/// pin the chrome around it — the file-name title, `Done`, and the Copy path / Share bottom
/// bar. `.dynamicTypeSize(.large)` is pinned so renders don't follow the simulator's text size.
///
/// Every store swallows `.task`: the sheet's `.task` would otherwise hit the unimplemented
/// `filePreview` test dependency during a key-window render (see `Reducer.ignoring`).
final class FilePreviewSnapshotTests: SnapshotTestCase {
  private let regionHeight: CGFloat = 600
  private var phoneWidth: CGFloat { device.size?.width ?? 390 }

  private func store(
    path: String, content: FilePreviewFeature.Content
  ) -> StoreOf<FilePreviewFeature> {
    Store(
      initialState: FilePreviewFeature.State(
        path: path, sessionID: "snapshot-session", connection: connection, content: content
      )
    ) {
      FilePreviewFeature().ignoring(\.task)
    }
  }

  /// The sheet's content region alone, pinned to a phone-wide 600pt slot.
  private func content(path: String, _ content: FilePreviewFeature.Content) -> some View {
    FilePreviewSheet(store: store(path: path, content: content)).content
      .frame(width: phoneWidth, height: regionHeight)
      .background(Color(uiColor: .systemBackground))
      .dynamicTypeSize(.large)
  }

  /// The whole sheet — navigation title, `Done`, bottom bar — as the user sees it.
  private func sheet(path: String, _ content: FilePreviewFeature.Content) -> some View {
    FilePreviewSheet(store: store(path: path, content: content))
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

  /// The failure state inside the sheet: Retry sits in the content, Copy path and Share stay
  /// offered in the bar (the path is still worth copying when the read failed).
  func testSheet_failed() {
    let view = sheet(
      path: "/home/eugene/out/report.pdf",
      .failed(message: "The agent is offline. Check the connection and try again.")
    )
    assertSnapshot(of: view, as: deviceImage())
  }
}
