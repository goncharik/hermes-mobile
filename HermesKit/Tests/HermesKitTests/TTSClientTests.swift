import Clocks
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
    #expect(TTSAudio.fileExtension(forMimeType: "audio/unknown") == "mp3")
  }

  @Test func theParsedMimeTypePicksTheExtension() throws {
    // `fileExtension` takes `parse(dataURL:)`'s output, which already dropped the parameters.
    let audio = try TTSAudio.parse(dataURL: "data:audio/ogg;codecs=opus;base64,3q0=")
    #expect(TTSAudio.fileExtension(forMimeType: audio.mimeType) == "ogg")
  }

  @Test func onlyOggIsUnplayable() {
    #expect(!TTSAudio(data: Data(), mimeType: "audio/ogg").isPlayable)
    for mime in ["audio/mpeg", "audio/wav", "audio/flac"] {
      #expect(TTSAudio(data: Data(), mimeType: mime).isPlayable)
    }
  }

  // MARK: Stall watchdog decision

  private typealias Detector = TTSStallDetector<TestClock<Duration>.Instant>

  /// Advance `clock` by `elapsed`, then poll `position` (`#expect` can't call a mutating method).
  private func poll(
    _ detector: inout Detector, _ position: TimeInterval,
    after elapsed: Duration, on clock: TestClock<Duration>
  ) async -> Bool {
    await clock.advance(by: elapsed)
    return detector.isStalled(position: position, at: clock.now)
  }

  @Test func aStuckPositionStallsExactlyAtTheTimeout() async {
    let clock = TestClock()
    var detector = Detector(position: 0, at: clock.now)
    let early = await poll(&detector, 0, after: TTSClient.stallTimeout - .milliseconds(500), on: clock)
    #expect(!early)
    let atTimeout = await poll(&detector, 0, after: .milliseconds(500), on: clock)
    #expect(atTimeout) // a clip that never starts stalls too
  }

  @Test func everyAdvanceReArmsTheTimeout() async {
    let clock = TestClock()
    var detector = Detector(position: 0, at: clock.now)
    let advanced = await poll(&detector, 1.0, after: .seconds(14), on: clock) // re-armed here
    #expect(!advanced)
    let fourteenSecondsLater = await poll(&detector, 1.0, after: .seconds(14), on: clock)
    #expect(!fourteenSecondsLater)
    let fifteenSecondsLater = await poll(&detector, 1.0, after: .seconds(1), on: clock)
    #expect(fifteenSecondsLater)
  }

  @Test func aPositionThatMovesBackwardsIsNotProgress() async {
    let clock = TestClock()
    var detector = Detector(position: 5.0, at: clock.now)
    let back = await poll(&detector, 2.0, after: .seconds(10), on: clock)
    #expect(!back)
    let stillBelow = await poll(&detector, 4.0, after: .seconds(5), on: clock)
    #expect(stillBelow) // 15 s without passing 5.0
  }
}
