import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HermesKit

/// Whether ImageIO on this host can *encode* HEIC. The decoder is everywhere; the encoder is
/// hardware-dependent, so the HEIC cases gate on it — as a **skip**, not an early `return`,
/// which reported green while asserting nothing.
private let hasHEICEncoder =
  (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)

@MainActor
struct PickedImageLoaderTests {
  // MARK: - Helpers

  /// A provider that hands back `data` for `type` (and optionally a plain-text
  /// representation registered *first*, to prove the image identifier still wins).
  private func imageProvider(
    _ data: Data,
    type: UTType,
    suggestedName: String? = nil,
    withLeadingText text: String? = nil
  ) -> NSItemProvider {
    let provider = NSItemProvider()
    if let text {
      let textData = Data(text.utf8)
      provider.registerDataRepresentation(for: .plainText, visibility: .all) { completion in
        completion(textData, nil)
        return nil
      }
    }
    provider.registerDataRepresentation(for: type, visibility: .all) { completion in
      completion(data, nil)
      return nil
    }
    provider.suggestedName = suggestedName
    return provider
  }

  private func textProvider(_ text: String) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = Data(text.utf8)
    provider.registerDataRepresentation(for: .plainText, visibility: .all) { completion in
      completion(data, nil)
      return nil
    }
    return provider
  }

  /// Real, ImageIO-decodable bytes — the re-encode path needs an actual image, not the
  /// magic-byte stubs the loading tests use.
  private func encodedImage(as type: UTType, opaque: Bool, side: Int = 8) throws -> Data {
    let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let context = try #require(
      CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alphaInfo.rawValue
      )
    )
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: opaque ? 1 : 0.5))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let image = try #require(context.makeImage())

    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  /// Genuine HEIC bytes. Only callable under `.enabled(if: hasHEICEncoder)` — see that flag.
  ///
  /// This matters because HEIC is the only format the transcode exists for and it is the one
  /// ImageIO lies about: a thumbnail decoded from a HEIC source reports
  /// `alphaInfo == .premultipliedLast` even when the image is fully opaque. A test that
  /// declares `.heic` while handing over PNG bytes never exercises that.
  private func heicEncodedImage(opaque: Bool) throws -> Data {
    try encodedImage(as: .heic, opaque: opaque, side: 64)
  }

  /// A provider whose load handler always fails — the "dropped item" path.
  private func failingImageProvider() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(for: .png, visibility: .all) { completion in
      completion(nil, CocoaError(.fileReadUnknown))
      return nil
    }
    return provider
  }

  // MARK: - imageTypeIdentifier

  @Test func imageTypeIdentifierPicksTheImageConformingIdentifier() {
    #expect(PickedImageLoader.imageTypeIdentifier(in: [UTType.png.identifier]) == UTType.png.identifier)
    #expect(PickedImageLoader.imageTypeIdentifier(in: [UTType.jpeg.identifier]) == UTType.jpeg.identifier)
    // `public.image` conforms to itself.
    #expect(PickedImageLoader.imageTypeIdentifier(in: [UTType.image.identifier]) == UTType.image.identifier)
  }

  @Test func imageTypeIdentifierIsNilWithoutAnImage() {
    #expect(PickedImageLoader.imageTypeIdentifier(in: []) == nil)
    #expect(PickedImageLoader.imageTypeIdentifier(in: [UTType.plainText.identifier]) == nil)
    #expect(PickedImageLoader.imageTypeIdentifier(in: ["com.example.not-a-real-type"]) == nil)
  }

  @Test func imageTypeIdentifierPrefersTheImageAmongMixedIdentifiers() {
    let mixed = [UTType.plainText.identifier, UTType.utf8PlainText.identifier, UTType.jpeg.identifier]
    #expect(PickedImageLoader.imageTypeIdentifier(in: mixed) == UTType.jpeg.identifier)
  }

  /// The agent's `_IMAGE_EXTENSIONS` allowlist has no `.heic`, and `image.attach_bytes`
  /// derives the extension from the filename we send — so a "first image-conforming
  /// identifier" pick would stage a chip that fails hard (4016) at send time. A provider that
  /// also offers JPEG/PNG must be loaded as that instead.
  @Test func imageTypeIdentifierSkipsPastATypeTheAgentRejects() {
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: [UTType.heic.identifier, UTType.jpeg.identifier])
        == UTType.jpeg.identifier
    )
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: ["public.heic", "public.png", "public.jpeg"])
        == "public.png"
    )
    // Nothing supported on offer → the exotic type is still returned; `pickedItem` re-encodes
    // those bytes rather than staging a doomed chip.
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: [UTType.heic.identifier]) == UTType.heic.identifier
    )
  }

  /// Among *supported* types the provider's own order wins — it is fidelity order, and
  /// overriding it with a global preference flattens an animated GIF into its PNG still and
  /// re-encodes a JPEG into a much larger PNG.
  @Test func imageTypeIdentifierRespectsTheProvidersFidelityOrder() {
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: [UTType.jpeg.identifier, UTType.png.identifier])
        == UTType.jpeg.identifier
    )
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: [UTType.png.identifier, UTType.jpeg.identifier])
        == UTType.png.identifier
    )
    // Safari's *Copy Image* on an animated GIF registers the GIF plus the rendered still.
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: [UTType.gif.identifier, UTType.png.identifier])
        == UTType.gif.identifier
    )
  }

  /// …but an *uncompressed* supported type never outranks a compressed one, whatever the
  /// provider's order says. macOS lists `public.tiff` first (it is `NSPasteboardTypeTIFF`) and
  /// Universal Clipboard bridges that to iOS verbatim, so a plain "first supported" scan
  /// staged a Mac-copied image as a ~36 MB TIFF — past the agent's 25 MB cap (4018) — with a
  /// perfectly good PNG registered right beside it.
  @Test func imageTypeIdentifierPrefersACompressedTypeOverAnUncompressedOne() {
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: ["public.tiff", "public.png"])
        == "public.png"
    )
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: [UTType.bmp.identifier, UTType.jpeg.identifier])
        == UTType.jpeg.identifier
    )
    // Within the uncompressed tier the provider's order is still the tie-break…
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: ["public.tiff", UTType.bmp.identifier])
        == "public.tiff"
    )
    // …and an uncompressed type still beats one the agent rejects outright.
    #expect(
      PickedImageLoader.imageTypeIdentifier(in: [UTType.heic.identifier, "public.tiff"])
        == "public.tiff"
    )
    // Alone, it is still what gets sent — no needless re-encode of a supported type.
    #expect(PickedImageLoader.imageTypeIdentifier(in: ["public.tiff"]) == "public.tiff")
  }

  /// The tier split is a property of the extension set, not a hand-maintained second list.
  @Test func compressedExtensionsAreASubsetOfTheSupportedOnes() {
    #expect(
      PickedImageLoader.compressedImageExtensions
        .isSubset(of: PickedImageLoader.serverSupportedImageExtensions)
    )
    for ext in ["tiff", "tif", "bmp"] {
      #expect(!PickedImageLoader.compressedImageExtensions.contains(ext), "\(ext) is uncompressed")
    }
  }

  /// The supported set is a mirror of the agent's `cli.py:_IMAGE_EXTENSIONS`; drift there is
  /// what produces a 4016 at send time.
  @Test func serverSupportSpansExactlyTheAgentsImageExtensions() {
    for type: UTType in [.png, .jpeg, .gif, .webP, .bmp, .tiff, .svg, .ico] {
      #expect(PickedImageLoader.isServerSupported(type.identifier), "\(type.identifier)")
    }
    #expect(!PickedImageLoader.isServerSupported(UTType.heic.identifier))
    #expect(!PickedImageLoader.isServerSupported(UTType.image.identifier), "no extension to send")
    #expect(!PickedImageLoader.isServerSupported(UTType.pdf.identifier), "not an image")
    #expect(!PickedImageLoader.isServerSupported("com.example.not-a-real-type"))
  }

  // MARK: - filename

  @Test func filenameUsesTheSuggestedNameAndTypeExtension() {
    let name = PickedImageLoader.filename(
      suggestedName: "IMG_0042", fallbackName: "photo", typeIdentifier: UTType.jpeg.identifier, index: 0
    )
    #expect(name == "IMG_0042.jpeg")
  }

  @Test func filenameFallsBackWhenNoNameIsSuggested() {
    #expect(
      PickedImageLoader.filename(
        suggestedName: nil, fallbackName: "photo", typeIdentifier: UTType.png.identifier, index: 0
      ) == "photo.png"
    )
    // An empty / whitespace-only suggestion must not produce a bare ".png".
    #expect(
      PickedImageLoader.filename(
        suggestedName: "   ", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "pasted-image.png"
    )
  }

  @Test func filenameSuffixesEveryItemAfterTheFirst() {
    #expect(
      PickedImageLoader.filename(
        suggestedName: nil, fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 1
      ) == "pasted-image-2.png"
    )
    #expect(
      PickedImageLoader.filename(
        suggestedName: nil, fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 2
      ) == "pasted-image-3.png"
    )
  }

  @Test func filenameNeverSuffixesASuggestedName() {
    // A provider that names itself is already distinct — suffixing would rename picked photos.
    #expect(
      PickedImageLoader.filename(
        suggestedName: "IMG_0042", fallbackName: "photo", typeIdentifier: UTType.jpeg.identifier, index: 1
      ) == "IMG_0042.jpeg"
    )
  }

  @Test func filenameFallsBackToImgForATypeWithoutAnExtension() {
    let name = PickedImageLoader.filename(
      suggestedName: "clip", fallbackName: "pasted-image", typeIdentifier: "com.example.not-a-real-type", index: 0
    )
    #expect(name == "clip.img")
  }

  /// A whitespace-only suggestion falls back *and* still takes the disambiguating suffix —
  /// the two rules have to compose, or the second such item would collide with the first.
  @Test func filenameFallsBackAndStillSuffixesForAWhitespaceSuggestion() {
    #expect(
      PickedImageLoader.filename(
        suggestedName: " \n ", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 1
      ) == "pasted-image-2.png"
    )
  }

  /// A pasteboard `suggestedName` routinely already carries the extension (PHPicker's does
  /// not), which used to produce `screenshot.png.png` in the chip.
  @Test func filenameDoesNotDoubleAnExtensionTheSuggestionAlreadyHas() {
    #expect(
      PickedImageLoader.filename(
        suggestedName: "screenshot.png", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "screenshot.png"
    )
    // Case-insensitively, and only the extension we are about to append.
    #expect(
      PickedImageLoader.filename(
        suggestedName: "Screenshot.PNG", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "Screenshot.png"
    )
    #expect(
      PickedImageLoader.filename(
        suggestedName: "archive.tar", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "archive.tar.png",
      "only image extensions are dropped"
    )
    // A re-encoded provider is named for what it became: `photo.heic` + JPEG must not produce
    // `photo.heic.jpeg`, whose suffix the agent would read as `.jpeg` but whose label lies.
    #expect(
      PickedImageLoader.filename(
        suggestedName: "photo.heic", fallbackName: "pasted-image", typeIdentifier: UTType.jpeg.identifier, index: 0
      ) == "photo.jpeg"
    )
    #expect(
      PickedImageLoader.filename(
        suggestedName: "photo.jpg", fallbackName: "pasted-image", typeIdentifier: UTType.jpeg.identifier, index: 0
      ) == "photo.jpeg"
    )
  }

  /// Defence in depth: the suggested name is chosen by whatever app owns the clipboard and
  /// travels verbatim to the agent as `image.attach_bytes`'s `filename`.
  @Test func filenameSanitisesAProviderSuppliedName() {
    #expect(
      PickedImageLoader.filename(
        suggestedName: "../../etc/passwd", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "passwd.png"
    )
    #expect(
      PickedImageLoader.filename(
        suggestedName: "..\\..\\windows", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "windows.png"
    )
    // A leading dot would hide the file and make the whole name an extension.
    #expect(
      PickedImageLoader.filename(
        suggestedName: ".hidden", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "hidden.png"
    )
    // Nothing usable left → the caller's fallback, not a bare ".png".
    #expect(
      PickedImageLoader.filename(
        suggestedName: ".png", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "pasted-image.png"
    )
    #expect(
      PickedImageLoader.filename(
        suggestedName: "/", fallbackName: "pasted-image", typeIdentifier: UTType.png.identifier, index: 0
      ) == "pasted-image.png"
    )
  }

  /// …and it is *bounded*. The name shares its WebSocket frame with the base64 payload, whose
  /// budget (`maxAttachmentBytes`) leaves only ~1.33 MiB under
  /// `JSONRPCRequest.maxWebSocketFrameBytes` — an unbounded, app-chosen name could spend that
  /// headroom and put the frame back over uvicorn's ceiling, closing the socket mid-upload. The extension survives the cut.
  @Test func filenameTruncatesAnOverlongSuggestedName() {
    let limit = PickedImageLoader.maxFilenameBaseCharacters
    let produced = PickedImageLoader.filename(
      suggestedName: String(repeating: "a", count: 5_000),
      fallbackName: "pasted-image",
      typeIdentifier: UTType.png.identifier,
      index: 0
    )
    #expect(produced == String(repeating: "a", count: limit) + ".png")

    // Stripping still sees the real suffix — the cut happens last, not before it.
    let withExtension = PickedImageLoader.filename(
      suggestedName: String(repeating: "b", count: 5_000) + ".png",
      fallbackName: "pasted-image",
      typeIdentifier: UTType.png.identifier,
      index: 0
    )
    #expect(withExtension == String(repeating: "b", count: limit) + ".png")

    // A cut that lands on a dot (or whitespace) must not leave `name..png`.
    let trailingDots = PickedImageLoader.filename(
      suggestedName: String(repeating: "c", count: limit - 1) + "..............",
      fallbackName: "pasted-image",
      typeIdentifier: UTType.png.identifier,
      index: 0
    )
    #expect(trailingDots == String(repeating: "c", count: limit - 1) + ".png")

    // A name exactly at the limit is left alone.
    let atLimit = PickedImageLoader.filename(
      suggestedName: String(repeating: "d", count: limit),
      fallbackName: "pasted-image",
      typeIdentifier: UTType.png.identifier,
      index: 0
    )
    #expect(atLimit == String(repeating: "d", count: limit) + ".png")
  }

  // MARK: - transcode

  /// The agent has no magic-byte fallback for a *named* file (`_sniff_image_ext` returns the
  /// suffix whenever there is one), so bytes it would reject have to be re-encoded here or the
  /// chip dies at send time with a 4016 no retry can fix.
  @Test func transcodingAnOpaqueImageProducesAnAcceptedJPEG() throws {
    let source = try encodedImage(as: .png, opaque: true)
    let transcoded = try #require(PickedImageLoader.transcodedImage(from: source))

    #expect(transcoded.typeIdentifier == UTType.jpeg.identifier)
    #expect(PickedImageLoader.isServerSupported(transcoded.typeIdentifier))
    // Really JPEG, not just labelled as one — a photo re-encoded as PNG runs several times
    // larger and the agent caps `image.attach_bytes` at 25 MB.
    let decoded = try #require(CGImageSourceCreateWithData(transcoded.data as CFData, nil))
    #expect(CGImageSourceGetType(decoded) as String? == UTType.jpeg.identifier)
  }

  /// …but transparency must survive, so an image with an alpha channel goes to PNG instead.
  @Test func transcodingAnImageWithAlphaKeepsPNG() throws {
    let source = try encodedImage(as: .png, opaque: false)
    let transcoded = try #require(PickedImageLoader.transcodedImage(from: source))

    #expect(transcoded.typeIdentifier == UTType.png.identifier)
    let decoded = try #require(CGImageSourceCreateWithData(transcoded.data as CFData, nil))
    #expect(CGImageSourceGetType(decoded) as String? == UTType.png.identifier)
  }

  /// The case the PNG-fed tests could not see: a **genuine HEIC**, which is the only format
  /// this path ever runs on in production. `CGImageSourceCreateThumbnailAtIndex` reports
  /// `alphaInfo == .premultipliedLast` for an opaque HEIC source, so an opacity verdict taken
  /// from the decoded thumbnail always chose PNG — measured at 39 MB for a 12 MP photo JPEG
  /// encodes in 7 MB, i.e. straight through the agent's 25 MB cap into a 4018 the user cannot
  /// retry away. The verdict has to come from the source's own properties.
  @Test(.enabled(if: hasHEICEncoder))
  func transcodingARealOpaqueHEICProducesJPEGNotPNG() throws {
    let source = try heicEncodedImage(opaque: true)
    let transcoded = try #require(PickedImageLoader.transcodedImage(from: source))

    #expect(transcoded.typeIdentifier == UTType.jpeg.identifier)
    let decoded = try #require(CGImageSourceCreateWithData(transcoded.data as CFData, nil))
    #expect(CGImageSourceGetType(decoded) as String? == UTType.jpeg.identifier)
  }

  /// …and a HEIC that really does carry alpha still goes to PNG, so the fix is a genuine
  /// opacity read rather than a blanket "HEIC → JPEG".
  @Test(.enabled(if: hasHEICEncoder))
  func transcodingARealHEICWithAlphaKeepsPNG() throws {
    let source = try heicEncodedImage(opaque: false)
    let transcoded = try #require(PickedImageLoader.transcodedImage(from: source))

    #expect(transcoded.typeIdentifier == UTType.png.identifier)
    let decoded = try #require(CGImageSourceCreateWithData(transcoded.data as CFData, nil))
    #expect(CGImageSourceGetType(decoded) as String? == UTType.png.identifier)
  }

  /// Whatever it re-encodes to has to fit the budget the agent enforces (25 MB → 4018).
  @Test func transcodingStaysUnderTheAgentsAttachmentCap() throws {
    let source = try encodedImage(as: .png, opaque: true, side: 512)
    let transcoded = try #require(PickedImageLoader.transcodedImage(from: source))
    #expect(transcoded.data.count <= PickedImageLoader.maxAttachmentBytes)
  }

  @Test func transcodingRefusesBytesThatAreNotAnImage() {
    #expect(PickedImageLoader.transcodedImage(from: Data("not an image".utf8))?.data == nil)
    #expect(PickedImageLoader.transcodedImage(from: Data())?.data == nil)
  }

  /// End to end: a HEIC-only provider (no `public.jpeg` registered — the case the identifier
  /// preference cannot rescue) is re-encoded, named for its new type, and staged.
  @Test func pickedItemReEncodesATypeTheAgentWouldReject() async throws {
    let bytes = try encodedImage(as: .png, opaque: true)
    // The declared identifier is HEIC; ImageIO sniffs the actual bytes, which keeps the test
    // free of a hardware-dependent HEIC encoder.
    let provider = imageProvider(bytes, type: .heic, suggestedName: "IMG_1234.HEIC")

    let item = try #require(
      await PickedImageLoader.pickedItem(from: provider, fallbackName: "pasted-image", index: 0)
    )

    #expect(item.filename == "IMG_1234.jpeg", "named for what it now is, not what it was")
    #expect(item.mimeType == "image/jpeg")
    #expect(item.data != bytes, "the bytes are the re-encoded ones")
    #expect(item.kind == .image)
  }

  /// The same end-to-end path on **real** HEIC bytes, where the thumbnail's alpha channel
  /// lies about the source's opacity: this is what a HEIC-only clipboard actually stages, and
  /// with the PNG verdict it produced `IMG_1234.png` and a payload several times the size.
  @Test(.enabled(if: hasHEICEncoder))
  func pickedItemReEncodesARealOpaqueHEICToJPEG() async throws {
    let bytes = try heicEncodedImage(opaque: true)
    let provider = imageProvider(bytes, type: .heic, suggestedName: "IMG_1234.HEIC")

    let item = try #require(
      await PickedImageLoader.pickedItem(from: provider, fallbackName: "pasted-image", index: 0)
    )

    #expect(item.filename == "IMG_1234.jpeg")
    #expect(item.mimeType == "image/jpeg")
    #expect(item.data != bytes)
  }

  /// Only the types the agent rejects reach the re-encode, and they are exactly the ones a
  /// decompression bomb would be crafted in — so a source whose *declared* dimensions are
  /// absurd is refused before `kCGImageSourceCreateThumbnailFromImageAlways` decodes it.
  @Test func transcodingRefusesASourceLargerThanThePixelLimit() throws {
    let source = try encodedImage(as: .png, opaque: true, side: 64)
    #expect(PickedImageLoader.transcodedImage(from: source, pixelLimit: 64 * 64 - 1) == nil)
    // …and the same bytes go through at the limit, so the guard is what refused them.
    #expect(PickedImageLoader.transcodedImage(from: source, pixelLimit: 64 * 64) != nil)
    // The shipped limit refuses a 30000² bomb and passes a 48 MP iPhone original.
    #expect(PickedImageLoader.maxSourcePixels < 30000 * 30000)
    #expect(PickedImageLoader.maxSourcePixels > 8064 * 6048)
  }

  /// A missing declaration is a refusal, not a pass. Defaulting an absent
  /// `kCGImagePropertyPixelWidth`/`Height` to `0` made `0 * 0 <= pixelLimit` true, so the one
  /// input a crafted source fully controls — whether to declare a size at all — was also the
  /// one that skipped the guard and got decoded anyway.
  @Test func theBombGuardRefusesASourceWithNoDeclaredDimensions() {
    let sized: [CFString: Any] = [kCGImagePropertyPixelWidth: 10, kCGImagePropertyPixelHeight: 10]
    #expect(PickedImageLoader.isWithinPixelLimit(sized, pixelLimit: 100))
    #expect(!PickedImageLoader.isWithinPixelLimit(sized, pixelLimit: 99))

    #expect(!PickedImageLoader.isWithinPixelLimit([:], pixelLimit: .max))
    #expect(!PickedImageLoader.isWithinPixelLimit([kCGImagePropertyPixelWidth: 10], pixelLimit: .max))
    #expect(!PickedImageLoader.isWithinPixelLimit([kCGImagePropertyPixelHeight: 10], pixelLimit: .max))
    #expect(
      !PickedImageLoader.isWithinPixelLimit(
        [kCGImagePropertyPixelWidth: 0, kCGImagePropertyPixelHeight: 0], pixelLimit: .max
      )
    )
  }

  /// The guard multiplies two numbers a hostile file header chose. `width * height` traps on
  /// overflow, so a container with 64-bit dimension fields (BigTIFF, PSB) could **crash** the
  /// app on paste instead of being rejected — the guard turning into the denial of service it
  /// was added to prevent. Saturating at `Int.max` refuses it instead.
  @Test func theBombGuardRefusesRatherThanTrappingOnAnOverflowingDeclaration() {
    let overflowing: [CFString: Any] = [
      kCGImagePropertyPixelWidth: Int.max, kCGImagePropertyPixelHeight: 2,
    ]
    #expect(PickedImageLoader.declaredPixelCount(overflowing) == .max)
    #expect(!PickedImageLoader.isWithinPixelLimit(overflowing, pixelLimit: PickedImageLoader.maxSourcePixels))
    // Even an absurd caller-supplied limit cannot let it through.
    #expect(!PickedImageLoader.isWithinPixelLimit(overflowing, pixelLimit: .max - 1))
    // …while an ordinary declaration is still the plain product.
    #expect(
      PickedImageLoader.declaredPixelCount(
        [kCGImagePropertyPixelWidth: 4032, kCGImagePropertyPixelHeight: 3024]
      ) == 4032 * 3024
    )
  }

  /// The pixel guard used to run **only** inside the re-encode, which only runs on the two
  /// doomed shapes — so a decompression bomb wearing a supported, under-budget container (a
  /// few KB of PNG declaring 40000×40000) took neither branch, was staged untouched, and was
  /// then handed to `UIImage(data:)` by the composer's attachment chip.
  @Test func pickedItemRefusesABombEvenWhenItsTypeAndSizeAreFine() async throws {
    let png = try encodedImage(as: .png, opaque: true, side: 64)

    let refused = await PickedImageLoader.pickedItem(
      from: imageProvider(png, type: .png), fallbackName: "pasted-image", index: 0,
      pixelLimit: 64 * 64 - 1
    )
    #expect(refused == nil, "a supported, small, but absurdly-sized source must not be staged")

    // Positive control: the very same bytes at the limit are staged untouched, so it is the
    // pixel guard that refused them and not the type or the byte budget.
    let staged = try #require(
      await PickedImageLoader.pickedItem(
        from: imageProvider(png, type: .png), fallbackName: "pasted-image", index: 0,
        pixelLimit: 64 * 64
      )
    )
    #expect(staged.data == png)
  }

  /// …but a container ImageIO cannot read a header for is *not* refused here. `.svg` is in the
  /// agent's accepted set and has no `kCGImagePropertyPixelWidth`; refusing it would drop a
  /// valid attachment to guard against a decode that can never happen (`UIImage(data:)` will
  /// not decode it either). The two guards deliberately answer differently.
  @Test func thePassThroughGuardAllowsASourceItCannotRead() {
    #expect(PickedImageLoader.declaresDecodableSize(Data("<svg/>".utf8)))
    #expect(PickedImageLoader.declaresDecodableSize(Data()))
  }

  /// …and when even that fails, the provider is dropped rather than staged as a chip whose
  /// only possible outcome is a hard 4016 the user can't retry away.
  @Test func pickedItemDropsAnUnsupportedTypeItCannotReEncode() async {
    let provider = imageProvider(Data([0x00, 0x01, 0x02]), type: .heic)
    let item = await PickedImageLoader.pickedItem(
      from: provider, fallbackName: "pasted-image", index: 0
    )
    #expect(item == nil)
  }

  /// The common path must stay a straight byte copy — no re-encode, no fidelity loss.
  @Test func pickedItemNeverReEncodesASupportedType() async throws {
    let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0xFF])  // not decodable on purpose
    let item = try #require(
      await PickedImageLoader.pickedItem(
        from: imageProvider(gif, type: .gif), fallbackName: "pasted-image", index: 0
      )
    )
    #expect(item.data == gif, "an animated GIF must reach the agent as-is")
    #expect(item.filename == "pasted-image.gif")
    #expect(item.mimeType == "image/gif")
  }

  /// Size is the *second* trigger for the same re-encode. The type scan only prefers a
  /// **co-registered** compressed type, so it cannot help when `public.tiff` is the sole
  /// identifier on offer — a real Universal Clipboard shape, since `NSPasteboardTypeTIFF` is
  /// the canonical macOS image type. The agent accepts the `.tiff` extension, so the chip
  /// looked fine and then pushed a 50-80 MB base64 string over the socket for a 4018 no retry
  /// can fix: the same unretryable dead end the transcode exists to remove.
  @Test func pickedItemReEncodesSupportedBytesThatAreTooLargeToSend() async throws {
    let tiff = try encodedImage(as: .tiff, opaque: true, side: 64)

    let item = try #require(
      await PickedImageLoader.pickedItem(
        from: imageProvider(tiff, type: .tiff, suggestedName: "Screenshot.tiff"),
        fallbackName: "pasted-image",
        index: 0,
        byteLimit: tiff.count - 1
      )
    )
    #expect(item.filename == "Screenshot.jpeg", "named for what it now is, not what it was")
    #expect(item.mimeType == "image/jpeg")
    #expect(item.data != tiff, "the bytes are the re-encoded ones")

    // …and the very same supported bytes are untouched when they fit, so it is the size that
    // decided and nothing that works today regressed.
    let untouched = try #require(
      await PickedImageLoader.pickedItem(
        from: imageProvider(tiff, type: .tiff, suggestedName: "Screenshot.tiff"),
        fallbackName: "pasted-image",
        index: 0,
        byteLimit: tiff.count
      )
    )
    #expect(untouched.data == tiff)
    #expect(untouched.filename == "Screenshot.tiff")
    #expect(untouched.mimeType == "image/tiff")
  }

  // MARK: - mimeType

  @Test func mimeTypeComesFromTheUTTypeAndDefaultsToPNG() {
    #expect(PickedImageLoader.mimeType(for: UTType.png.identifier) == "image/png")
    #expect(PickedImageLoader.mimeType(for: UTType.jpeg.identifier) == "image/jpeg")
    // An unmapped identifier must still produce a usable MIME for the upload.
    #expect(PickedImageLoader.mimeType(for: "com.example.not-a-real-type") == "image/png")
  }

  // MARK: - pickedItems

  @Test func pickedItemsLoadsImagesInOrderWithExactBytes() async {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    let items = await PickedImageLoader.pickedItems(
      from: [imageProvider(png, type: .png), imageProvider(jpeg, type: .jpeg)],
      fallbackName: "pasted-image"
    ).items

    #expect(items.count == 2)
    #expect(items[0].data == png)
    #expect(items[0].mimeType == "image/png")
    #expect(items[0].filename == "pasted-image.png")
    #expect(items[0].kind == .image)
    #expect(items[1].data == jpeg)
    #expect(items[1].mimeType == "image/jpeg")
    #expect(items[1].filename == "pasted-image-2.jpeg")
    #expect(items[1].kind == .image)
  }

  @Test func pickedItemsFiltersOutNonImageProviders() async {
    let png = Data([0x01, 0x02, 0x03])
    let items = await PickedImageLoader.pickedItems(
      from: [textProvider("just text"), imageProvider(png, type: .png)],
      fallbackName: "pasted-image"
    ).items

    // The text provider is dropped, so the image is still item #1 (no `-2` gap).
    #expect(items.count == 1)
    #expect(items[0].data == png)
    #expect(items[0].filename == "pasted-image.png")
  }

  @Test func pickedItemsDropsProvidersThatFailToLoad() async {
    let png = Data([0x0A, 0x0B])
    let items = await PickedImageLoader.pickedItems(
      from: [failingImageProvider(), imageProvider(png, type: .png)],
      fallbackName: "pasted-image"
    ).items

    #expect(items.count == 1)
    #expect(items[0].data == png)
    #expect(items[0].filename == "pasted-image.png")
  }

  @Test func pickedItemsReturnsEmptyForNoProviders() async {
    let batch = await PickedImageLoader.pickedItems(from: [], fallbackName: "pasted-image")
    #expect(batch.items.isEmpty)
    // No providers, nothing lost — the shape a picker cancel produces, which must stay silent.
    #expect(batch.droppedCount == 0)
  }

  @Test func pickedItemsPrefersTheImageOnAMixedProvider() async {
    let png = Data([0xAA, 0xBB, 0xCC])
    let items = await PickedImageLoader.pickedItems(
      from: [imageProvider(png, type: .png, suggestedName: "screenshot", withLeadingText: "caption")],
      fallbackName: "pasted-image"
    ).items

    #expect(items.count == 1)
    #expect(items[0].data == png)
    #expect(items[0].mimeType == "image/png")
    #expect(items[0].filename == "screenshot.png")
  }

  @Test func pickedItemHonoursTheFallbackNameOfEachSource() async {
    let png = Data([0x11])
    let picked = await PickedImageLoader.pickedItem(
      from: imageProvider(png, type: .png), fallbackName: "photo", index: 0
    )
    #expect(picked?.filename == "photo.png")

    let pasted = await PickedImageLoader.pickedItem(
      from: imageProvider(png, type: .png), fallbackName: "pasted-image", index: 0
    )
    #expect(pasted?.filename == "pasted-image.png")
  }

  // MARK: - load deadline

  /// A provider that never calls its completion handler is abandoned at the deadline rather
  /// than suspending the paste queue for the lifetime of the process.
  @Test func pickedItemGivesUpOnAProviderThatNeverCallsBack() async {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(for: .png, visibility: .all) { _ in nil } // never completes

    let item = await PickedImageLoader.pickedItem(
      from: provider, fallbackName: "pasted-image", index: 0, timeout: .milliseconds(50)
    )
    #expect(item == nil)
  }

  /// The deadline is **per source**, not one global budget. A `PHPickerResult`'s provider
  /// downloads a non-resident iCloud original inside `loadDataRepresentation`, which the
  /// clipboard's 15 s aborts over a weak connection — the picker then dismissed onto an
  /// unchanged composer. The two budgets have to stay distinct, and the picker's the larger.
  @Test func thePickerGetsALongerLoadBudgetThanTheClipboard() {
    #expect(PickedImageLoader.pickerLoadTimeout > PickedImageLoader.clipboardLoadTimeout)
  }

  @Test func pickedItemIsNilForANonImageProvider() async {
    let picked = await PickedImageLoader.pickedItem(
      from: textProvider("hello"), fallbackName: "pasted-image", index: 0
    )
    #expect(picked == nil)
  }

  // MARK: - photo-picker naming contract

  /// `PhotoPickerPresenter` now goes through this exact call, so pin its naming contract here:
  /// an unnamed pick stays `photo.<ext>` and a provider-suggested name is still honoured.
  /// (The picker itself is UIKit-only and private, so this is the closest testable seam.)
  @Test func photoPickerNamingContractIsPreserved() async {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let jpeg = Data([0xFF, 0xD8, 0xFF])
    let items = await PickedImageLoader.pickedItems(
      from: [
        imageProvider(png, type: .png),
        imageProvider(jpeg, type: .jpeg, suggestedName: "IMG_0042"),
      ],
      fallbackName: "photo"
    ).items

    #expect(items.count == 2)
    #expect(items[0].filename == "photo.png")
    #expect(items[0].mimeType == "image/png")
    #expect(items[0].data == png)
    #expect(items[0].kind == .image)
    #expect(items[1].filename == "IMG_0042.jpeg")
    #expect(items[1].mimeType == "image/jpeg")
    #expect(items[1].data == jpeg)
    #expect(items[1].kind == .image)
  }

  /// Several unnamed picks used to collide on `photo.png`; the shared loader disambiguates
  /// them with the same `-<n>` suffix the paste path uses.
  @Test func photoPickerDisambiguatesRepeatedUnnamedPicks() async {
    let items = await PickedImageLoader.pickedItems(
      from: [imageProvider(Data([0x01]), type: .png), imageProvider(Data([0x02]), type: .png)],
      fallbackName: "photo"
    ).items

    #expect(items.map(\.filename) == ["photo.png", "photo-2.png"])
  }

  // MARK: - budgets

  /// The **transport**, not the handler, is what an upload actually has to fit. The agent's
  /// `_ATTACH_BYTES_MAX_BYTES` is 25 MiB of decoded bytes, but the payload travels base64'd
  /// inside a single WebSocket frame and `hermes_cli/web_server.py` builds its `uvicorn.Config`
  /// without `ws_max_size`, so uvicorn's 16 MiB default kills the frame (close 1009) before the
  /// handler is ever entered. Aiming at the handler's cap staged 12-24 MiB images as valid and
  /// then dropped the socket on send.
  ///
  /// Measured **on the wire**, not from 4/3 arithmetic. Raw base64 length is a lower bound on
  /// the frame, not the frame: the JSON envelope adds to it, and JSON *string escaping* can
  /// multiply it. That gap was real — the encoder used to escape every `/` as `\/`, and `/` is
  /// part of the base64 alphabet, so the budget guaranteed nothing about what actually left the
  /// socket.
  @Test func theAttachmentBudgetFitsAWebSocketFrameOnceEncodedAsARequest() throws {
    // `0xFF 0xFF 0xFF` base64s to `////`, so this payload is 100 % the one character escaping
    // would have doubled — the worst input that exists, rather than the ~1.6 % a photograph
    // averages. Passing here means the budget holds for *any* bytes, not just realistic ones.
    let payload = Data(repeating: 0xFF, count: PickedImageLoader.maxAttachmentBytes)
    let base64 = payload.base64EncodedString()
    // All but the final, padded group (`//8=` — 11 MiB is not a multiple of 3).
    #expect(
      base64.utf8.dropLast(4).allSatisfy { $0 == UInt8(ascii: "/") },
      "otherwise this is not the worst case"
    )

    // The real `image.attach_bytes` shape (`ChatFeature.uploadAttachment`), with the envelope
    // fields at implausible extremes so no headroom is being borrowed from short values.
    let request = JSONRPCRequest(
      id: .max,
      method: "image.attach_bytes",
      params: .object([
        "session_id": .string(String(repeating: "s", count: 128)),
        "content_base64": .string(base64),
        "filename": .string(String(repeating: "f", count: 255) + ".jpeg"),
      ])
    )
    let frame = try request.wireText().utf8.count

    #expect(frame < JSONRPCRequest.maxWebSocketFrameBytes)
    #expect(
      JSONRPCRequest.maxWebSocketFrameBytes - frame > 1024 * 1024,
      "leave the envelope real headroom rather than sitting on the edge"
    )
    // Still generous enough for an ordinary photo, or the guard is its own bug report.
    #expect(PickedImageLoader.maxAttachmentBytes > 8 * 1024 * 1024)
  }

  /// `loadDataRepresentation` materialises a whole payload with no way to see its size first,
  /// and the batch then retains every survivor — so a 100-photo pick could hold hundreds of
  /// megabytes before the first upload even starts. The batch budget stops loading instead of
  /// accumulating, and the remainder is *reported*, not silently missing.
  @Test func pickedBatchStopsLoadingOnceTheBatchBudgetIsSpent() async {
    let first = Data(repeating: 0xAB, count: 512)
    let providers = [
      imageProvider(first, type: .png),
      imageProvider(Data(repeating: 0xCD, count: 512), type: .png),
      imageProvider(Data(repeating: 0xEF, count: 512), type: .png),
    ]

    let batch = await PickedImageLoader.pickedBatch(
      from: providers, fallbackName: "photo", batchLimit: 512
    )

    #expect(batch.items.map(\.data) == [first], "the budget is checked before the next load")
    #expect(batch.droppedCount == 2, "and what was never loaded is still reported")
    // The shipped budget is nowhere near a realistic multi-photo pick.
    #expect(PickedImageLoader.maxBatchBytes > 20 * PickedImageLoader.maxAttachmentBytes / 4)
  }

  /// A batch that loses some of its images has to say so. Only the count of the *survivors*
  /// used to come back, so a paste of three that yielded two was indistinguishable from a
  /// paste of two — and the user sent an incomplete set believing it complete.
  @Test func pickedBatchReportsAPartialLoss() async {
    let good = Data([0x89, 0x50, 0x4E, 0x47])
    let batch = await PickedImageLoader.pickedItems(
      from: [imageProvider(good, type: .png), failingImageProvider(), failingImageProvider()],
      fallbackName: "pasted-image"
    )

    #expect(batch.items.map(\.data) == [good])
    #expect(batch.droppedCount == 2)
  }

  // MARK: - rescuedImageItem (Files / camera)

  /// Files hands over the on-disk original, which on iOS is routinely a HEIC — an extension
  /// `image.attach_bytes` rejects outright (4016), on every retry. That path bypassed the
  /// loader entirely, so the same picture attached fine from Photos and never from Files.
  @Test func rescuedImageItemReEncodesATypeTheAgentWouldReject() async throws {
    let bytes = try encodedImage(as: .png, opaque: true, side: 32)
    let picked = PickedItem(
      data: bytes, filename: "IMG_0001.HEIC", mimeType: "image/heic", kind: .image
    )

    let rescued = try #require(await PickedImageLoader.rescuedImageItem(picked))

    #expect(rescued.filename == "IMG_0001.jpeg", "named for what it now is")
    #expect(rescued.mimeType == "image/jpeg")
    #expect(rescued.data != bytes)
    #expect(rescued.kind == .image)
  }

  /// The ordinary case must stay a byte-for-byte pass-through: no re-encode, no fidelity loss,
  /// no cost for the overwhelming majority of picks (and camera captures).
  @Test func rescuedImageItemLeavesAnAcceptableFileUntouched() async throws {
    let bytes = try encodedImage(as: .jpeg, opaque: true, side: 32)
    let picked = PickedItem(
      data: bytes, filename: "photo.jpg", mimeType: "image/jpeg", kind: .image
    )

    let rescued = try #require(await PickedImageLoader.rescuedImageItem(picked))

    #expect(rescued == picked, "same bytes, same name, same mime")
  }

  /// The second trigger, shared with the provider path: an uncompressed TIFF off a Mac's
  /// iCloud Drive (or a big enough camera JPEG — quality bounds no byte count) is re-encoded
  /// rather than staged into a frame the socket will refuse.
  @Test func rescuedImageItemReEncodesAcceptableBytesThatAreTooLargeToSend() async throws {
    let tiff = try encodedImage(as: .tiff, opaque: true, side: 64)
    let picked = PickedItem(
      data: tiff, filename: "Scan.tiff", mimeType: "image/tiff", kind: .image
    )

    let rescued = try #require(
      await PickedImageLoader.rescuedImageItem(picked, byteLimit: tiff.count - 1)
    )

    #expect(rescued.filename == "Scan.jpeg")
    #expect(rescued.data.count <= tiff.count - 1)
  }

  /// …and bytes nothing can rescue are dropped, not staged: the caller counts them as a loss
  /// and banners it, instead of leaving a chip that can only ever fail.
  @Test func rescuedImageItemDropsWhatItCannotReEncode() async {
    let picked = PickedItem(
      data: Data([0x00, 0x01, 0x02]), filename: "broken.heic", mimeType: "image/heic", kind: .image
    )
    #expect(await PickedImageLoader.rescuedImageItem(picked) == nil)
  }

  /// The bomb guard reaches this path too — a Files-picked PNG declaring absurd dimensions is
  /// refused rather than passed through to `UIImage(data:)`.
  @Test func rescuedImageItemRefusesABomb() async throws {
    let png = try encodedImage(as: .png, opaque: true, side: 64)
    let picked = PickedItem(data: png, filename: "bomb.png", mimeType: "image/png", kind: .image)

    #expect(await PickedImageLoader.rescuedImageItem(picked, pixelLimit: 64 * 64 - 1) == nil)
    #expect(await PickedImageLoader.rescuedImageItem(picked, pixelLimit: 64 * 64) != nil)
  }
}
