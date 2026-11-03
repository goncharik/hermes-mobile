import Foundation
import Testing

@testable import HermesKit

struct DataURLTests {
  /// A 1×1 transparent PNG — what `/api/fs/read-data-url` returns for a tiny image.
  static let pngBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

  @Test func parsesABase64ImageDataURL() throws {
    let parsed = try #require(DataURL.parse("data:image/png;base64,\(Self.pngBase64)"))
    #expect(parsed.mimeType == "image/png")
    #expect(parsed.data == Data(base64Encoded: Self.pngBase64))
    // PNG magic bytes — the payload really was decoded, not copied through.
    #expect(Array(parsed.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
  }

  @Test func mediaTypeParametersAreDroppedFromTheMimeType() throws {
    let parsed = try #require(DataURL.parse("data:text/plain;charset=utf-8;base64,aGk="))
    #expect(parsed.mimeType == "text/plain")
    #expect(String(decoding: parsed.data, as: UTF8.self) == "hi")
  }

  @Test func missingMediaTypeYieldsNilMime() throws {
    let parsed = try #require(DataURL.parse("data:;base64,aGk="))
    #expect(parsed.mimeType == nil)
    #expect(parsed.data == Data("hi".utf8))
  }

  @Test func schemeIsCaseInsensitive() throws {
    let parsed = try #require(DataURL.parse("DATA:image/png;BASE64,aGk="))
    #expect(parsed.mimeType == "image/png")
  }

  @Test func emptyPayloadIsAnEmptyFile() throws {
    // A 0-byte file is a real file; the preview falls back to the generic card view-side.
    let parsed = try #require(DataURL.parse("data:application/octet-stream;base64,"))
    #expect(parsed.data.isEmpty)
    #expect(parsed.mimeType == "application/octet-stream")
  }

  @Test(arguments: [
    "data:text/plain,hello",                 // percent-encoded form — not base64
    "data:text/plain;base64",                // no separator
    "data:image/png;base64,not*base64!",     // invalid alphabet
    "data:image/png;base64,aGk",             // unpadded — strict decode rejects it
    "data:image/png;base64;charset=x,aGk=",  // base64 not the last parameter
    "https://host/a.png",                    // wrong scheme
    "image/png;base64,aGk=",                 // no scheme
    "",
    "data:",
  ])
  func rejectsMalformedInput(_ input: String) {
    #expect(DataURL.parse(input) == nil)
  }
}
