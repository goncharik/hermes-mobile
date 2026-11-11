import ComposableArchitecture
import DependenciesMacros
import Foundation

/// A file the user picked from the photo library, camera, or Files app (#8), before it's
/// turned into a `ComposerAttachment` (the reducer assigns the id).
public struct PickedItem: Equatable, Sendable {
  public var data: Data
  public var filename: String
  public var mimeType: String
  public var kind: ComposerAttachment.Kind

  public init(data: Data, filename: String, mimeType: String, kind: ComposerAttachment.Kind) {
    self.data = data
    self.filename = filename
    self.mimeType = mimeType
    self.kind = kind
  }

  /// Promote a picked file to a staged attachment (the reducer supplies the id).
  public func attachment(id: UUID) -> ComposerAttachment {
    ComposerAttachment(id: id, kind: kind, filename: filename, mimeType: mimeType, data: data)
  }
}

/// What one picker presentation produced: the files that loaded, plus how many of the user's
/// selections were lost on the way (a provider that failed, an iCloud original that never
/// downloaded, a type that could not be re-encoded).
///
/// The count is what lets the reducer tell **"chose nothing"** from **"chose and lost it"**: a
/// cancel is the empty batch (no items *and* no drops) and stays silent, while a selection
/// that produced nothing gets said out loud instead of dismissing the sheet onto an unchanged
/// composer.
public struct PickedBatch: Equatable, Sendable {
  public var items: [PickedItem]
  public var droppedCount: Int

  public init(items: [PickedItem] = [], droppedCount: Int = 0) {
    self.items = items
    self.droppedCount = droppedCount
  }
}

/// Presents the native photo / camera / document pickers and returns the selected files.
/// UIKit/PhotosUI live behind this dependency so reducers stay testable and platform-free.
@DependencyClient
public struct AttachmentPickerClient: Sendable {
  public var pickPhotos: @Sendable () async -> PickedBatch = { PickedBatch() }
  public var capturePhoto: @Sendable () async -> PickedBatch = { PickedBatch() }
  public var pickFiles: @Sendable () async -> PickedBatch = { PickedBatch() }
}

extension AttachmentPickerClient: DependencyKey {
  /// Tests get empty pickers by default; override a closure to return canned `PickedItem`s.
  public static var testValue: AttachmentPickerClient { AttachmentPickerClient() }
}

public extension DependencyValues {
  var attachmentPicker: AttachmentPickerClient {
    get { self[AttachmentPickerClient.self] }
    set { self[AttachmentPickerClient.self] = newValue }
  }
}

// MARK: - Presenter lifetime (#170)

/// The delegate half of one picker presentation, shared by the three live presenters. It lives
/// **exactly as long as its picker**: `attach(to:)` hangs it off the picker, and nothing else
/// keeps it, except a delegate callback's loading `Task`, which must capture it strongly until it
/// calls `finish` (the picker is already dismissed by then; a `[weak self]` there drops the pick).
///
/// UIKit presents the photos and Files pickers (remote view controllers) *late*:
/// `presentingViewController` is still `nil` when `present` returns (measured: shown 1–3 s later
/// on the iOS 26.5 and 27.0 simulators), so no check right after `present` can tell a delayed
/// presentation from a refused one. Guessing "refused" and releasing the presenter left the
/// picker on screen with a `nil` weak delegate, so Done and Cancel did nothing. Instead UIKit
/// decides: it keeps a picker it will show until that picker is dismissed, and drops one it
/// refused within a runloop turn.
///
/// `report` fires exactly once: from `finish(_:)`, or from `deinit` as the silent empty batch
/// when the picker went away without a delegate callback (refused, no host to present on), so
/// the caller never waits forever.
@MainActor
class PickerPresenter: NSObject {
  private var report: (@Sendable (PickedBatch) -> Void)?
  private static var ownerKey: UInt8 = 0

  init(report: @escaping @Sendable (PickedBatch) -> Void) {
    self.report = report
  }

  /// Makes `picker` the presenter's only owner.
  func attach(to picker: NSObject) {
    objc_setAssociatedObject(picker, &Self.ownerKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  func finish(_ batch: PickedBatch) {
    report?(batch)
    report = nil
  }

  deinit {
    report?(PickedBatch())
  }
}

// MARK: - Live (iOS only)

#if canImport(UIKit)
  import PhotosUI
  import UIKit
  import UniformTypeIdentifiers

  extension AttachmentPickerClient {
    public static var liveValue: AttachmentPickerClient {
      AttachmentPickerClient(
        pickPhotos: { await PhotoPickerPresenter.present() },
        capturePhoto: { await CameraPresenter.present() },
        pickFiles: { await DocumentPickerPresenter.present() }
      )
    }
  }

  /// Walk to the top-most presented view controller of the active foreground scene, stopping
  /// below one that is being dismissed (it can't host a presentation).
  @MainActor
  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  /// How long `settlePresentation` waits for a transition at most, and how often it checks.
  private let settleTimeout: Duration = .seconds(2)
  private let settleInterval: Duration = .milliseconds(50)

  /// Waits (up to `settleTimeout`) for the top view controller to finish a transition. A
  /// picker raised by a widget's launch action runs at the chat's first `.task` — during the
  /// push, or right after the launch dismissed a sheet — when UIKit would refuse the
  /// presentation.
  @MainActor
  private func settlePresentation() async {
    for _ in 0..<Int(settleTimeout / settleInterval) {
      guard let top = topViewController() else { return }
      if top.transitionCoordinator == nil, !top.isBeingPresented, !top.isBeingDismissed { return }
      try? await Task.sleep(for: settleInterval)
    }
  }

  /// Hands `picker` its presenter and presents it on the top view controller. There is nothing
  /// to check afterwards: whether UIKit shows the picker now, later or never, its presenter
  /// reports exactly once (see `PickerPresenter`).
  @MainActor
  private func presentOnTop(_ picker: UIViewController, owner presenter: PickerPresenter) {
    presenter.attach(to: picker)
    topViewController()?.present(picker, animated: true)
  }

  private func mimeType(for url: URL) -> String {
    (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) ?? "application/octet-stream"
  }

  /// Bridges `PHPickerViewController` (multi-select images) to an async result.
  private final class PhotoPickerPresenter: PickerPresenter, PHPickerViewControllerDelegate {
    static func present() async -> PickedBatch {
      await settlePresentation()
      return await withCheckedContinuation { continuation in
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0 // multiple
        let picker = PHPickerViewController(configuration: config)
        let presenter = PhotoPickerPresenter { continuation.resume(returning: $0) }
        picker.delegate = presenter
        presentOnTop(picker, owner: presenter)
      }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picker.dismiss(animated: true)
      // A cancel: nothing chosen, so nothing to report.
      guard !results.isEmpty else { finish(PickedBatch()); return }

      Task {
        // Shared with the composer's clipboard paste (#54) so the two image sources cannot
        // drift: same type-identifier choice, same `suggestedName ?? fallbackName` naming,
        // same original-bytes load. `fallbackName: "photo"` preserves today's picker naming.
        //
        // The **timeout is the picker's own**, not the clipboard's: a `PHPickerResult`'s
        // provider downloads a non-resident iCloud original inside `loadDataRepresentation`,
        // which the clipboard's 15 s budget would abort on a weak connection (see
        // `PickedImageLoader.pickerLoadTimeout`).
        finish(await PickedImageLoader.pickedItems(
          from: results.map(\.itemProvider),
          fallbackName: "photo",
          timeout: PickedImageLoader.pickerLoadTimeout
        ))
      }
    }
  }

  /// Bridges `UIImagePickerController` (camera capture) to an async result.
  private final class CameraPresenter: PickerPresenter, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// JPEG quality for a fresh camera capture. Lower than
    /// `PickedImageLoader.jpegCompressionQuality` on purpose: that path re-encodes bytes that
    /// could not be sent at all (fidelity traded against a certain rejection), whereas this one
    /// compresses a raw full-resolution capture, where the last few points of quality cost
    /// megabytes on the wire for no visible gain.
    private static let jpegQuality: CGFloat = 0.85

    static func present() async -> PickedBatch {
      guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return PickedBatch() }
      await settlePresentation()
      return await withCheckedContinuation { continuation in
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        let presenter = CameraPresenter { continuation.resume(returning: $0) }
        picker.delegate = presenter
        presentOnTop(picker, owner: presenter)
      }
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      picker.dismiss(animated: true)
      guard let image = info[.originalImage] as? UIImage,
            let data = image.jpegData(compressionQuality: Self.jpegQuality)
      else {
        // A shot was taken and then lost — reported, unlike a cancel.
        finish(PickedBatch(droppedCount: 1)); return
      }
      let captured = PickedItem(
        data: data, filename: "photo.jpg", mimeType: "image/jpeg", kind: .image
      )
      Task {
        // A compression *quality* bounds no byte count: a high-detail capture at 48 MP still
        // encodes past the transport budget, and staging it would produce a chip that can never
        // upload on any retry. Normally a no-op that reads the JPEG header and hands the same
        // bytes straight back.
        guard let item = await PickedImageLoader.rescuedImageItem(captured) else {
          finish(PickedBatch(droppedCount: 1)); return
        }
        finish(PickedBatch(items: [item]))
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
      finish(PickedBatch())
    }
  }

  /// Bridges `UIDocumentPickerViewController` (multi-select any file) to an async result.
  private final class DocumentPickerPresenter: PickerPresenter, UIDocumentPickerDelegate {
    static func present() async -> PickedBatch {
      await settlePresentation()
      return await withCheckedContinuation { continuation in
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        let presenter = DocumentPickerPresenter { continuation.resume(returning: $0) }
        picker.delegate = presenter
        presentOnTop(picker, owner: presenter)
      }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      Task {
        var items: [PickedItem] = []
        for url in urls {
          // asCopy: true delivers files into a temp dir we can read directly.
          guard let data = try? Data(contentsOf: url) else { continue }
          let mime = mimeType(for: url)
          let item = PickedItem(
            data: data,
            filename: url.lastPathComponent,
            mimeType: mime,
            kind: .infer(mimeType: mime, filename: url.lastPathComponent)
          )
          guard item.kind == .image else { items.append(item); continue }
          // Images take the same rescue the photo picker and the clipboard do. Files hands
          // over the on-disk original, which on iOS is routinely a HEIC (the agent answers
          // 4016) and from a Mac's iCloud Drive an uncompressed TIFF past the frame budget —
          // so the *same picture* used to attach fine from Photos and fail forever from Files.
          guard let rescued = await PickedImageLoader.rescuedImageItem(item) else { continue }
          items.append(rescued)
        }
        // An unreadable pick (an iCloud Drive file that never materialised) or an image that
        // could not be rescued is a loss, not a cancel — the reducer says so rather than
        // dismissing onto an unchanged composer.
        finish(PickedBatch(items: items, droppedCount: urls.count - items.count))
      }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finish(PickedBatch())
    }
  }
#else
  extension AttachmentPickerClient {
    public static var liveValue: AttachmentPickerClient { testValue }
  }
#endif
