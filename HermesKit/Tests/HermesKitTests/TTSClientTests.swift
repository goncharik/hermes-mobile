import Foundation
import Testing

@testable import HermesKit

struct TTSClientTests {
  // MARK: data: URL parsing (`/api/audio/speak` response)

  /// The four mime types the server's `_SPEAK_MIME_BY_EXT` can emit.
  @Test(arguments: ["audio/mpeg", "audio/ogg", "audio/wav", "audio/flac"])
  func parsesEveryServerMimeType(mimeType: String) throws {
    let audio = try TTSAudio.parse(dataURL: "data:\(mimeType);base64,3q0=")
    #expect(audio == TTSAudio(data: Data([0xDE, 0xAD]), mimeType: mimeType))
  }

  @Test func payloadRoundTripsThroughTheRecorderDataURLBuilder() throws {
    let bytes = Data((0...255).map { UInt8($0) })
    let dataURL = RecordedAudio(data: bytes, mimeType: "audio/mpeg").dataURL
    let audio = try TTSAudio.parse(dataURL: dataURL)
    #expect(audio.data == bytes)
    #expect(audio.mimeType == "audio/mpeg")
  }

  @Test func mediaTypeParametersAreDroppedFromTheMimeType() throws {
    let audio = try TTSAudio.parse(dataURL: "data:audio/ogg;codecs=opus;base64,3q0=")
    #expect(audio.mimeType == "audio/ogg")
    #expect(audio.data == Data([0xDE, 0xAD]))
  }

  @Test func missingDataPrefixIsMalformed() {
    #expect(throws: TTSAudioError.malformedDataURL) {
      try TTSAudio.parse(dataURL: "audio/mpeg;base64,3q0=")
    }
    #expect(throws: TTSAudioError.malformedDataURL) {
      try TTSAudio.parse(dataURL: "")
    }
  }

  @Test func missingBase64MarkerIsMalformed() {
    #expect(throws: TTSAudioError.malformedDataURL) {
      try TTSAudio.parse(dataURL: "data:audio/mpeg,3q0=")
    }
    #expect(throws: TTSAudioError.malformedDataURL) {
      try TTSAudio.parse(dataURL: "data:audio/mpeg;3q0=")
    }
  }

  @Test func emptyMimeOrPayloadIsMalformed() {
    #expect(throws: TTSAudioError.malformedDataURL) {
      try TTSAudio.parse(dataURL: "data:;base64,3q0=")
    }
    #expect(throws: TTSAudioError.malformedDataURL) {
      try TTSAudio.parse(dataURL: "data:audio/mpeg;base64,")
    }
  }

  @Test func invalidBase64Throws() {
    #expect(throws: TTSAudioError.invalidBase64) {
      try TTSAudio.parse(dataURL: "data:audio/mpeg;base64,!!not base64!!")
    }
    #expect(throws: TTSAudioError.invalidBase64) {
      // Wrong length (not padded to a multiple of 4).
      try TTSAudio.parse(dataURL: "data:audio/mpeg;base64,3q0")
    }
  }

  // MARK: Temp-file extension (AVAudioPlayer's container hint)

  @Test func fileExtensionFollowsTheMimeType() {
    #expect(TTSAudio.fileExtension(forMimeType: "audio/mpeg") == "mp3")
    #expect(TTSAudio.fileExtension(forMimeType: "audio/ogg") == "ogg")
    #expect(TTSAudio.fileExtension(forMimeType: "audio/wav") == "wav")
    #expect(TTSAudio.fileExtension(forMimeType: "audio/flac") == "flac")
    #expect(TTSAudio.fileExtension(forMimeType: "Audio/OGG; codecs=opus") == "ogg")
    #expect(TTSAudio.fileExtension(forMimeType: "audio/unknown") == "mp3")
  }

  // MARK: Test double contract (relied on by ChatFeature tests)

  @Test func testValuePlayReturnsInstantlyAndStopIsCallable() async throws {
    let client = TTSClient.testValue
    try await client.play(Data([0x00]), "audio/mpeg")
    await client.stop()
    await client.stop()
  }

  @Test func stallTimeoutMatchesTheDesktopWatchdog() {
    #expect(TTSClient.stallTimeout == .seconds(15))
  }
}
