import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Turns `NSItemProvider`s carrying image data into `PickedItem`s.
///
/// Shared by every image source so they cannot drift: the photo picker
/// (`PhotoPickerPresenter`, hence the `Picked` name and the `Clients/` home) and a clipboard
/// paste into the composer (#54). Deliberately free of UIKit/PhotosUI —
/// `NSItemProvider`/`UniformTypeIdentifiers`/ImageIO are Foundation-level, so `swift test`
/// covers this on macOS.
///
/// Bytes are loaded in their **original** representation (no re-encode) whenever the provider
/// offers one the agent accepts, so a pasted JPEG stays a JPEG, a screenshot PNG stays a PNG
/// and an animated GIF stays animated. Only two cases reach `transcodedImage(from:)`: a
/// provider with *nothing* acceptable on offer (a HEIC-only clipboard), and bytes that would
/// blow the transport budget — both of which would otherwise stage a chip whose only possible
/// outcome is an unretryable rejection. `rescuedImageItem(_:)` applies the same contract to the
/// sources that hand over bytes directly (Files, camera) rather than through a provider.
public enum PickedImageLoader {
  private static let log = Logger(subsystem: "me.honcharenko.HermesKit", category: "attachments")

  // MARK: - Limits

  /// How long a single **clipboard** provider gets to hand over its bytes, and the default for
  /// `pickedItem`/`pickedItems` — every other source must pass its own budget explicitly (see
  /// `pickerLoadTimeout`; inheriting this one silently is exactly how the picker regressed).
  /// A local clipboard load is instant; a Universal Clipboard item is fetched from the other
  /// device, hence seconds rather than milliseconds.
  public static let clipboardLoadTimeout: Duration = .seconds(15)

  /// The budget for a **photo-picker** provider, which is a different animal: a
  /// `PHPickerResult`'s provider performs the iCloud download *inside*
  /// `loadDataRepresentation`, so with "Optimize iPhone Storage" (the default) a
  /// non-resident original is fetched over the network — routinely more than the clipboard's
  /// 15 s on a weak connection. The picker used to wait indefinitely and succeed; this keeps
  /// that in practice while still bounding a provider that never calls back at all.
  static let pickerLoadTimeout: Duration = .seconds(120)

  /// Source dimensions past which the re-encode refuses to decode at all.
  ///
  /// 50 MP still clears every real photograph (the largest iPhone original is 8064×6048 =
  /// 48.8 MP) while bounding the transient decode: an RGBA bitmap costs 4 bytes a pixel, so
  /// this is a ~200 MB spike — the old 100 MP allowance was ~400 MB, close enough to jetsam
  /// territory on an older device to be its own denial of service.
  static let maxSourcePixels = 50_000_000

  /// The byte budget for one attachment — both the trigger for a re-encode (`pickedItem`,
  /// `rescuedImageItem`) and the target `transcodedImage` steps down towards.
  ///
  /// An upload is one JSON-RPC WebSocket *text* frame carrying the whole base64 payload, so
  /// it is bounded by the transport's frame ceiling (`JSONRPCRequest.maxWebSocketFrameBytes`).
  /// **The transport binds long before the handler does.** The agent's own
  /// `_ATTACH_BYTES_MAX_BYTES` is 25 MiB of *decoded* bytes, but base64 inflates by 4/3, so a
  /// 16 MiB frame is reached at ~12 MiB decoded — well under the handler's cap, which is
  /// therefore never the limit that fires. Anything between the two used to stage as a valid
  /// chip and then take the socket down with it (worse than a clean 4018: the reducer sees a
  /// disconnect, not a rejection). 11 MiB base64s to ~14.7 MiB, leaving the JSON envelope
  /// (method, session id, filename, mime) room to spare.
  ///
  /// That arithmetic only holds because `JSONRPCRequest.wireEncoder` has slash escaping
  /// **off**: base64's alphabet includes `/`, and a default `JSONEncoder` writes each one as
  /// `\/`, so the frame would depend on the *content* of the bytes rather than their length
  /// (all-`0xFF` bytes base64 to all-`/`, which would double the payload outright). The budget
  /// is pinned against a fully encoded worst-case request in `PickedImageLoaderTests`.
  static let maxAttachmentBytes = 11 * 1024 * 1024

  /// Ceiling on the bytes **one batch** may stage before the rest of the selection is dropped.
  ///
  /// `loadDataRepresentation` materialises a provider's entire payload in memory with no way to
  /// see its size first, and the batch then retains every survivor — so a 100-photo pick (the
  /// picker's `selectionLimit = 0`) can hold hundreds of megabytes before a single upload
  /// starts. This bounds the accumulation instead: ~30 typical library photos, or 11 at the
  /// per-item maximum, with the remainder reported through `PickedBatch.droppedCount` rather
  /// than silently missing. A streaming loader would be the real fix; this is the cheap one.
  static let maxBatchBytes = 128 * 1024 * 1024

  /// Thumbnail edge lengths tried in order. 4096 leaves a 12 MP photo untouched.
  private static let thumbnailPixelSizes = [4096, 2048, 1024]

  /// Quality for the JPEG branch of the re-encode. High enough that a rescued photo is not
  /// visibly degraded — this path only ever runs on bytes that could not be sent at all, so
  /// the trade is fidelity against a certain rejection, not against a smaller upload.
  /// (`AttachmentPickerClient`'s camera capture encodes at a slightly lower 0.85: that is a
  /// fresh, uncompressed capture, where the same quality would cost megabytes for no gain.)
  private static let jpegCompressionQuality = 0.9

  // MARK: - Type selection

  /// Filename extensions `image.attach_bytes` accepts — a verbatim mirror of the agent's
  /// `cli.py:_IMAGE_EXTENSIONS`.
  ///
  /// The agent derives the stored extension from the **filename we send**: its
  /// `_sniff_image_ext` (`tui_gateway/server.py`) returns `Path(filename).suffix` whenever the
  /// name has *any* suffix and only falls through to its magic-byte table for a suffix-less
  /// name — and we always append one. So the extension we choose is the whole check, and
  /// anything outside this set is rejected with error 4016 no matter what the bytes are.
  /// `.heic` is not in it, which is exactly the identifier an iOS provider often registers.
  static let serverSupportedImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico",
  ]

  /// The subset of `serverSupportedImageExtensions` whose containers are **compressed**, and
  /// which `imageTypeIdentifier(in:)` therefore scans for first.
  ///
  /// `tiff`/`tif`/`bmp` are supported but uncompressed: a 12 MP RGB TIFF is ~36 MB, several
  /// times `maxAttachmentBytes` — and macOS pasteboards register
  /// `public.tiff` *first* (it is `NSPasteboardTypeTIFF`, the canonical image type there),
  /// with Universal Clipboard bridging those identifiers to iOS verbatim. Preferring a
  /// co-registered PNG/JPEG is not a fidelity loss — the same pixels, a smaller container.
  /// `svg`/`ico` sit in the second tier for the same reason: never the best pick when a
  /// photographic format is also on offer.
  static let compressedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

  /// The (lowercased) filename extension `typeIdentifier` would be sent under, or `nil` when
  /// the agent would reject it.
  static func serverSupportedExtension(of typeIdentifier: String) -> String? {
    guard
      let type = UTType(typeIdentifier),
      type.conforms(to: .image),
      let ext = type.preferredFilenameExtension?.lowercased(),
      serverSupportedImageExtensions.contains(ext)
    else { return nil }
    return ext
  }

  /// Whether bytes loaded as `typeIdentifier` can be sent as-is (`false` → transcode).
  static func isServerSupported(_ typeIdentifier: String) -> Bool {
    serverSupportedExtension(of: typeIdentifier) != nil
  }

  /// The best registered identifier to load image bytes as, or `nil` when the provider
  /// carries no image at all (the caller skips it).
  ///
  /// **Within a tier the provider's own order decides.** `NSItemProvider.registeredTypeIdentifiers`
  /// is ordered by fidelity (the native representation first), and overriding it with a global
  /// preference list silently degrades real clipboards: Safari's *Copy Image* on an animated
  /// GIF registers `com.compuserve.gif` **and** the rendered `public.png` still, so a
  /// PNG-first rule flattens the animation; a photo registering `public.jpeg` then
  /// `public.png` would be re-encoded into a PNG several times the size, base64'd over the
  /// socket.
  ///
  /// The scan runs in three passes, each honouring the provider's order:
  ///
  /// 1. supported **and compressed** (`png`/`jpg`/`jpeg`/`gif`/`webp`),
  /// 2. anything else the agent supports (`tiff`/`tif`/`bmp`/`svg`/`ico`),
  /// 3. the first image-conforming identifier at all.
  ///
  /// Pass 1 before 2 is what keeps a Mac-copied image — whose pasteboard lists `public.tiff`
  /// first — from being staged as a ~36 MB uncompressed TIFF when a co-registered
  /// `public.png` was on offer (see `compressedImageExtensions`). Pass 2 before 3 is what
  /// turns the common `["public.heic", "public.jpeg"]` into a working JPEG attachment instead
  /// of a chip the agent rejects with 4016.
  ///
  /// When nothing supported is registered the first image-conforming identifier is returned
  /// and `pickedItem` re-encodes those bytes (the agent has no magic-byte fallback for a
  /// named file — see `serverSupportedImageExtensions`).
  ///
  /// The picker used to fall back to `UTType.image.identifier` when nothing conformed;
  /// loading an unregistered identifier always fails, so skipping is the same outcome
  /// without the wasted round-trip.
  public static func imageTypeIdentifier(in registeredTypeIdentifiers: [String]) -> String? {
    let compressed = registeredTypeIdentifiers.first {
      guard let ext = serverSupportedExtension(of: $0) else { return false }
      return compressedImageExtensions.contains(ext)
    }
    if let compressed { return compressed }
    if let supported = registeredTypeIdentifiers.first(where: isServerSupported) { return supported }
    return registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
  }

  /// `<suggestedName>.<ext>`, or `<fallbackName>[-<n>].<ext>` when nothing was suggested.
  ///
  /// The `-<n>` suffix (1-based, omitted for the first item) keeps a multi-image paste from
  /// producing several identically-labelled chips. It is applied **only** to the fallback
  /// name: a provider that names itself is already distinct, and suffixing it would rename
  /// the photo picker's files (`IMG_0042.jpeg` → `IMG_0042-2.jpeg`), which the shared loader
  /// must not do. The extension comes from the type identifier, falling back to `img` for an
  /// exotic UTType with no preferred extension.
  ///
  /// A suggested name is **sanitised** before use: any app on the clipboard chooses it, and it
  /// travels verbatim to the agent as `image.attach_bytes`'s `filename`. Only the last path
  /// component survives, leading dots are stripped, and a name that already ends in an image
  /// extension loses it rather than doubling up (a pasteboard `suggestedName` routinely
  /// carries one, unlike PHPicker's, which produced `screenshot.png.png` — and a transcoded
  /// HEIC would otherwise become `photo.heic.jpeg`). Only *image* extensions are stripped:
  /// `archive.tar` stays `archive.tar.png`. It is finally **truncated** to
  /// `maxFilenameBaseCharacters` — the name shares a frame with the base64 payload, and the
  /// budget's headroom is not something an app-chosen string may spend.
  static func filename(
    suggestedName: String?,
    fallbackName: String,
    typeIdentifier: String,
    index: Int
  ) -> String {
    let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "img"
    var base: String
    if let suggested = sanitizedBaseName(suggestedName, droppingExtension: ext) {
      base = suggested
    } else {
      base = fallbackName
      if index > 0 { base += "-\(index + 1)" }
    }
    return base + "." + ext
  }

  /// Extensions stripped from a suggested name before ours is appended: the one we are about
  /// to add, plus the image formats a provider might have named itself after (including the
  /// ones we re-encode away from).
  private static let droppableImageExtensions: Set<String> =
    serverSupportedImageExtensions.union(["heic", "heif", "avif", "jp2", "jpe", "jfif"])

  /// Ceiling on a *provider-supplied* base name, in characters.
  ///
  /// `NSItemProvider.suggestedName` is chosen by whatever app filled the pasteboard and rides
  /// verbatim into `image.attach_bytes`'s `filename` — i.e. straight into the same frame the
  /// byte budget is sized against. `maxAttachmentBytes` leaves ~1.33 MiB of headroom under
  /// `JSONRPCRequest.maxWebSocketFrameBytes`, so an unbounded name is one more way to put the
  /// frame back over uvicorn's ceiling and have the socket closed mid-upload, which is exactly
  /// the failure that budget exists to prevent. 128 characters is longer than any real filename (and well short
  /// of the 255 bytes every filesystem in the path allows anyway) while capping the name's
  /// contribution at under a kilobyte even for 4-byte scalars.
  static let maxFilenameBaseCharacters = 128

  /// A provider-supplied name reduced to a safe, non-empty base name, or `nil` when nothing
  /// usable is left (the caller then falls back to its own name).
  private static func sanitizedBaseName(_ suggested: String?, droppingExtension ext: String) -> String? {
    guard let suggested else { return nil }
    // Path separators can never be part of a filename we hand to the agent (`lastPathComponent`
    // alone leaves both a Windows-style `\` and the degenerate `"/"`).
    var name = (suggested as NSString).lastPathComponent
      .components(separatedBy: CharacterSet(charactersIn: "/\\")).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Compared as trailing strings rather than via `pathExtension`, which reports none for a
    // leading-dot name — `".png"` has to reduce to nothing (→ the caller's fallback), not to
    // the base name `"png"`. No two candidates can match the same name, so set order is moot.
    let lowercased = name.lowercased()
    if let matched = droppableImageExtensions.union([ext.lowercased()])
      .first(where: { lowercased.hasSuffix("." + $0) })
    {
      name.removeLast(matched.count + 1)
    }
    // A leading dot would make the whole thing an extension (and hide the file).
    while name.hasPrefix(".") { name.removeFirst() }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    // Truncated LAST, so the extension-stripping above still sees the real suffix. Trailing
    // dots/whitespace the cut may have exposed come off again — `name..png` and a name ending
    // in a space are both worse than the shorter name.
    if name.count > maxFilenameBaseCharacters {
      name = String(name.prefix(maxFilenameBaseCharacters))
      while name.hasSuffix(".") { name.removeLast() }
      name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return name.isEmpty ? nil : name
  }

  /// The MIME type advertised for `typeIdentifier`, defaulting to PNG for an unmapped UTType.
  static func mimeType(for typeIdentifier: String) -> String {
    UTType(typeIdentifier)?.preferredMIMEType ?? "image/png"
  }

  /// Load one provider's image bytes, or `nil` when it carries no image, fails to load, or is
  /// a doomed payload that cannot be re-encoded.
  ///
  /// `@MainActor` because `NSItemProvider` is not `Sendable` and both call sites (the photo
  /// picker delegate and the composer's paste coordinator) are already main-actor bound.
  ///
  /// `byteLimit`/`pixelLimit` are parameters only so a test can drive the oversize trigger and
  /// the bomb guard without allocating a pathological image; production always takes the
  /// defaults.
  @MainActor
  static func pickedItem(
    from provider: NSItemProvider,
    fallbackName: String,
    index: Int,
    timeout: Duration = clipboardLoadTimeout,
    byteLimit: Int = maxAttachmentBytes,
    pixelLimit: Int = maxSourcePixels
  ) async -> PickedItem? {
    guard var identifier = imageTypeIdentifier(in: provider.registeredTypeIdentifiers) else {
      return nil
    }
    guard var data = await loadData(from: provider, typeIdentifier: identifier, timeout: timeout)
    else { return nil }
    // Before anything else, and **whether or not these bytes are about to be re-encoded**: a
    // decompression bomb is small and well-formed, so a supported, under-budget PNG declaring
    // 40000×40000 took neither of the branches below and was staged untouched — then decoded
    // by `UIImage(data:)` the moment the composer rendered its chip. The transcode's own guard
    // only ever saw the doomed shapes.
    guard declaresDecodableSize(data, pixelLimit: pixelLimit) else {
      log.error(
        "image provider \(identifier, privacy: .public) declares more pixels than the decode budget; dropping it"
      )
      return nil
    }
    if !isServerSupported(identifier) || data.count > byteLimit {
      // Two doomed shapes, one rescue. Either nothing the agent accepts was registered (a
      // HEIC-only clipboard → 4016), or the bytes are past `maxAttachmentBytes` — which the
      // type scan cannot always avoid: it only prefers a *co-registered* compressed type, and
      // `public.tiff` is routinely the **sole** identifier a Mac pasteboard bridges over
      // (`NSPasteboardTypeTIFF`), at ~36 MB for a 12 MP screenshot. Either way the chip looks
      // fine, base64s into a 50-80 MB string, and dies without ever reaching the handler (the
      // frame exceeds `JSONRPCRequest.maxWebSocketFrameBytes`, so the socket closes); re-encoding is a
      // fidelity cost paid only where the alternative is certain failure (an oversize animated
      // GIF does lose its animation — it could not have been sent at all). Off the main actor:
      // a 12MP decode is not a frame's work.
      let source = data
      guard let transcoded = await Task.detached(priority: .userInitiated, operation: {
        transcodedImage(from: source, pixelLimit: pixelLimit, byteLimit: byteLimit)
      }).value else {
        log.error(
          "image provider \(identifier, privacy: .public) (\(data.count) bytes) is not something the agent would accept and could not be re-encoded"
        )
        return nil
      }
      data = transcoded.data
      identifier = transcoded.typeIdentifier
    }
    return PickedItem(
      data: data,
      filename: filename(
        suggestedName: provider.suggestedName,
        fallbackName: fallbackName,
        typeIdentifier: identifier,
        index: index
      ),
      mimeType: mimeType(for: identifier),
      kind: .image
    )
  }

  /// Load every image-bearing provider, in order, reporting what was lost.
  ///
  /// Non-image providers, providers that fail to load, decompression bombs and unsupported
  /// types that cannot be re-encoded are dropped; the `-<n>` filename suffix counts only the
  /// items that survived, so a dropped provider leaves no gap. **The count of the drops rides
  /// along** (`PickedBatch.droppedCount`): a batch that loses two of three images used to be
  /// indistinguishable from one that only ever had one, which is how a partly-failed paste
  /// could be sent as an incomplete set without the user ever being told.
  ///
  /// An **empty** batch is itself a meaningful outcome for a paste — the caller claimed a
  /// clipboard that advertised an image and has to say so.
  ///
  /// Deliberately narrower than `pickedBatch`: the byte/pixel/batch budgets are *test* seams,
  /// not caller choices (every real caller wants the transport's), so they live on the internal
  /// entry point. `timeout` is not — it genuinely differs per source.
  @MainActor
  public static func pickedItems(
    from providers: [NSItemProvider],
    fallbackName: String,
    timeout: Duration = clipboardLoadTimeout
  ) async -> PickedBatch {
    await pickedBatch(from: providers, fallbackName: fallbackName, timeout: timeout)
  }

  @MainActor
  static func pickedBatch(
    from providers: [NSItemProvider],
    fallbackName: String,
    timeout: Duration = clipboardLoadTimeout,
    byteLimit: Int = maxAttachmentBytes,
    pixelLimit: Int = maxSourcePixels,
    batchLimit: Int = maxBatchBytes
  ) async -> PickedBatch {
    var items: [PickedItem] = []
    var stagedBytes = 0
    for provider in providers {
      // Checked *before* the next load rather than after it, so the peak is the budget plus one
      // item — the whole point being not to materialise the rest of a 100-photo selection.
      guard stagedBytes < batchLimit else {
        log.error(
          "batch budget spent at \(stagedBytes) bytes after \(items.count) item(s); dropping the rest"
        )
        break
      }
      guard
        let item = await pickedItem(
          from: provider, fallbackName: fallbackName, index: items.count, timeout: timeout,
          byteLimit: byteLimit, pixelLimit: pixelLimit
        )
      else { continue }
      stagedBytes += item.data.count
      items.append(item)
    }
    // Every provider yields at most one item, so the shortfall is exactly what was lost —
    // whether it failed, was refused, or never got loaded at all.
    return PickedBatch(items: items, droppedCount: providers.count - items.count)
  }

  /// Bring image bytes that arrived **without** an `NSItemProvider` — a Files pick, a camera
  /// capture — up to the same contract `pickedItem` enforces: a filename extension
  /// `image.attach_bytes` accepts, a declared size worth decoding, and bytes inside the
  /// transport budget. Returns the item untouched when it already qualifies, a re-encoded one
  /// when it does not, and `nil` when nothing can be salvaged (the caller counts it as a drop).
  ///
  /// Those two sources used to stage whatever they were handed, so the *same picture* attached
  /// from Photos and from Files behaved differently: Files delivers the on-disk original, which
  /// on iOS is routinely a HEIC (the agent answers 4016 — see `serverSupportedImageExtensions`)
  /// or, from a Mac's iCloud Drive, an uncompressed TIFF far past the frame budget. Neither
  /// chip could ever upload, on any retry.
  static func rescuedImageItem(
    _ item: PickedItem,
    byteLimit: Int = maxAttachmentBytes,
    pixelLimit: Int = maxSourcePixels
  ) async -> PickedItem? {
    let ext = (item.filename as NSString).pathExtension.lowercased()
    if serverSupportedImageExtensions.contains(ext), item.data.count <= byteLimit,
       declaresDecodableSize(item.data, pixelLimit: pixelLimit)
    {
      return item
    }
    let source = item.data
    guard let transcoded = await Task.detached(priority: .userInitiated, operation: {
      transcodedImage(from: source, pixelLimit: pixelLimit, byteLimit: byteLimit)
    }).value else {
      log.error(
        "picked file \(ext, privacy: .public) (\(item.data.count) bytes) is not something the agent would accept and could not be re-encoded"
      )
      return nil
    }
    return PickedItem(
      data: transcoded.data,
      // The original name survives the re-encode with its stale extension swapped out
      // (`scan.heic` → `scan.jpeg`), exactly as a provider's `suggestedName` does.
      filename: filename(
        suggestedName: item.filename,
        fallbackName: "image",
        typeIdentifier: transcoded.typeIdentifier,
        index: 0
      ),
      mimeType: mimeType(for: transcoded.typeIdentifier),
      kind: .image
    )
  }

  @MainActor
  private static func loadData(
    from provider: NSItemProvider,
    typeIdentifier: String,
    timeout: Duration
  ) async -> Data? {
    let box = ContinuationBox()
    var deadline: Task<Void, Never>?
    let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
      box.attach(continuation)
      let progress = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
        // A dropped provider is otherwise invisible (the paste just does nothing), and the
        // usual causes — an expired Universal Clipboard item, a remote provider that never
        // materialises — are only diagnosable from the error itself.
        if data == nil {
          log.error(
            "image provider \(typeIdentifier, privacy: .public) failed to load: \(error?.localizedDescription ?? "no data", privacy: .public)"
          )
        }
        box.resume(with: data)
      }
      // Nothing obliges a provider to *ever* invoke that completion handler — the same expired
      // / never-materialising remote items above can simply hang. Without a deadline this
      // continuation (and every paste queued behind it) would stay suspended for the lifetime
      // of the process.
      //
      // A raw `Task.sleep`, not the project's usual injected `continuousClock`: the thing being
      // waited on is `NSItemProvider`'s own callback, which no clock controls, so a `TestClock`
      // would only fake half the race and still need a real suspension to lose it. The one test
      // that exercises this passes a 50 ms `timeout` and waits it out for real.
      deadline = Task { @MainActor in
        do { try await Task.sleep(for: timeout) } catch { return }
        guard box.resume(with: nil) else { return }
        progress.cancel()
        log.error("image provider \(typeIdentifier, privacy: .public) timed out")
      }
    }
    deadline?.cancel()
    return data
  }

  /// Re-encodes bytes the agent would reject into a format it accepts, or `nil` when ImageIO
  /// cannot decode them at all.
  ///
  /// ImageIO (not UIKit) so the whole loader still builds and is tested on macOS. The decode
  /// goes through the *thumbnail* API because it is the only one that applies the source's
  /// EXIF orientation — a camera HEIC is stored landscape with a rotation flag, and
  /// `CGImageSourceCreateImageAtIndex` would attach it sideways. The pixel cap leaves a normal
  /// photo untouched (12MP is 4032 wide) and bounds a pathological one; JPEG is the target for
  /// an opaque image because a re-encoded photo as PNG runs several times larger and the whole
  /// base64 payload has to fit one WebSocket frame (`maxAttachmentBytes`), PNG when there is
  /// transparency to keep.
  ///
  /// `pixelLimit`/`byteLimit` are parameters only so a test can drive the bomb guard and the
  /// step-down without allocating a pathological image; production always takes the defaults.
  static func transcodedImage(
    from data: Data,
    pixelLimit: Int = maxSourcePixels,
    byteLimit: Int = maxAttachmentBytes
  ) -> (data: Data, typeIdentifier: String)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

    // Read the declared dimensions *before* decoding anything: this path exists for the types
    // the agent rejects (HEIC/AVIF/PSD), which is exactly where a crafted decompression bomb
    // would live, and `kCGImageSourceCreateThumbnailFromImageAlways` will happily decode a
    // 30000×30000 source to produce its 4096px thumbnail.
    guard isWithinPixelLimit(properties, pixelLimit: pixelLimit) else {
      // `-1` for a dimension the source never declared — itself a refusal (see the guard).
      let width = properties[kCGImagePropertyPixelWidth] as? Int ?? -1
      let height = properties[kCGImagePropertyPixelHeight] as? Int ?? -1
      log.error("image source is \(width)x\(height); refusing to decode it")
      return nil
    }

    // **Opacity comes from the source, not from the decoded thumbnail.**
    // `CGImageSourceCreateThumbnailAtIndex` reports `alphaInfo == .premultipliedLast` for a
    // HEIC source even when the image is fully opaque — and HEIC is the *only* case this
    // function exists for, so trusting the thumbnail meant always choosing PNG: measured at
    // 39 MB for a 12 MP opaque HEIC that JPEG encodes in 7 MB, i.e. straight past the agent's
    // 25 MB cap (4018) — the same dead end the transcode was added to remove.
    // `kCGImagePropertyHasAlpha` is absent for an opaque source and `true` for one with an
    // alpha channel, across heic/png/jpeg alike.
    let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    let type: UTType = hasAlpha ? .png : .jpeg

    // Belt and braces: neither branch is inherently bounded (a photographic 4096² PNG can
    // clear 24 MB on its own), so step the thumbnail down until the encoded bytes fit under
    // the agent's cap. In practice the first size always wins; the loop only pays for itself
    // on the pathological input, and the last attempt is still returned rather than dropping
    // the attachment outright.
    var encoded: Data?
    for maxPixelSize in thumbnailPixelSizes {
      // `continue`, not `break`: a failure at one size is no reason to give the attachment up
      // without trying the smaller ones (a decoder that ran out of room for the 4096px
      // thumbnail is exactly the case a 2048px retry rescues).
      guard let image = thumbnail(from: source, maxPixelSize: maxPixelSize),
            let candidate = encodedData(from: image, as: type)
      else { continue }
      encoded = candidate
      if candidate.count <= byteLimit { break }
      log.error(
        "re-encoded image is \(candidate.count) bytes at \(maxPixelSize)px; retrying smaller"
      )
    }
    guard let encoded, !encoded.isEmpty else { return nil }
    return (encoded, type.identifier)
  }

  /// Whether a source declaring `properties` may be **decoded**.
  ///
  /// **Absent or zero dimensions are a refusal, not a pass.** Defaulting a missing
  /// `kCGImagePropertyPixelWidth`/`Height` to `0` made `0 * 0 <= pixelLimit` true, so a source
  /// that simply declined to declare its size skipped the guard entirely and got decoded
  /// anyway — the one input a crafted bomb controls. Refusing costs nothing real: every
  /// format ImageIO can decode reports its dimensions.
  static func isWithinPixelLimit(_ properties: [CFString: Any], pixelLimit: Int) -> Bool {
    guard let pixels = declaredPixelCount(properties) else { return false }
    return pixels <= pixelLimit
  }

  /// The pixel count a source declares in its header, or `nil` when it declares no usable one.
  ///
  /// **Saturating, not trapping.** Both operands come straight out of an untrusted file header
  /// (this whole guard exists because a hostile clipboard can choose them), and a container
  /// with 64-bit dimension fields — BigTIFF, PSB — can declare a width × height that overflows
  /// `Int`. `width * height` would then crash the app on a paste instead of rejecting it, which
  /// is a worse outcome than the bomb the guard was added to stop. An overflowing product is
  /// past every limit anyone could pass, so `Int.max` is the honest answer.
  static func declaredPixelCount(_ properties: [CFString: Any]) -> Int? {
    guard
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { return nil }
    let (pixels, overflowed) = width.multipliedReportingOverflow(by: height)
    return overflowed ? .max : pixels
  }

  /// Whether bytes about to be staged **untouched** declare an image worth decoding.
  ///
  /// Unlike `isWithinPixelLimit`, a source that declares *nothing* passes here. The two guards
  /// answer different questions: that one gates a decode we are about to perform, so an
  /// undeclared size is a refusal; this one gates bytes nobody is decoding on our behalf, and a
  /// container ImageIO cannot even read a header for (`.svg`, which the agent accepts) is one
  /// `UIImage(data:)` will not decode either. Refusing those would drop valid attachments to
  /// guard against nothing.
  static func declaresDecodableSize(_ data: Data, pixelLimit: Int = maxSourcePixels) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return true }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    guard let pixels = declaredPixelCount(properties) else { return true }
    return pixels <= pixelLimit
  }

  private static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func encodedData(from image: CGImage, as type: UTType) -> Data? {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: jpegCompressionQuality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
    return output as Data
  }
}

/// A one-shot continuation that can be resumed from either the provider's completion handler
/// or the deadline, whichever gets there first.
private final class ContinuationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data?, Never>?

  func attach(_ continuation: CheckedContinuation<Data?, Never>) {
    lock.lock()
    defer { lock.unlock() }
    self.continuation = continuation
  }

  /// `true` when this call is the one that resumed it.
  @discardableResult
  func resume(with data: Data?) -> Bool {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: data)
    return continuation != nil
  }
}
