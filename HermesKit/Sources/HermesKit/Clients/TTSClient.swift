import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Synthesized speech returned by the agent's `POST /api/audio/speak` (#74): the decoded
/// bytes of the response's `data_url` plus its mime type (`audio/mpeg`, `audio/ogg`,
/// `audio/wav` or `audio/flac` — the server's `_SPEAK_MIME_BY_EXT`).
public struct TTSAudio: Equatable, Sendable {
  public let data: Data
  public let mimeType: String

  public init(data: Data, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }

  /// Parse a `data:<mime>;base64,<payload>` URL. Pure, so it is unit-tested on every
  /// platform. Media-type parameters before `;base64` (`audio/ogg;codecs=opus`) are dropped
  /// from `mimeType`; an empty mime or an empty payload is malformed (nothing to play).
  public static func parse(dataURL: String) throws -> TTSAudio {
    let prefix = "data:"
    let marker = ";base64,"
    guard dataURL.hasPrefix(prefix),
          let markerRange = dataURL.range(of: marker)
    else { throw TTSAudioError.malformedDataURL }
    let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: prefix.count)..<markerRange.lowerBound]
    let mimeType = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    let payload = dataURL[markerRange.upperBound...]
    guard !mimeType.isEmpty, !payload.isEmpty else { throw TTSAudioError.malformedDataURL }
    guard let data = Data(base64Encoded: String(payload)) else { throw TTSAudioError.invalidBase64 }
    return TTSAudio(data: data, mimeType: mimeType)
  }

  /// File extension for the playback temp file. `AVAudioPlayer(contentsOf:)` takes the
  /// container hint from the extension, so it must match the bytes; unknown types fall back
  /// to `mp3` (the server's default extension).
  public static func fileExtension(forMimeType mimeType: String) -> String {
    let base = mimeType.split(separator: ";").first
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    switch base {
    case "audio/ogg", "audio/opus": return "ogg"
    case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
    case "audio/flac", "audio/x-flac": return "flac"
    default: return "mp3"
    }
  }
}

public enum TTSAudioError: Error, Equatable, Sendable {
  /// Not a `data:<mime>;base64,<payload>` URL (missing prefix/marker, empty mime or payload).
  case malformedDataURL
  /// The payload after `;base64,` does not decode.
  case invalidBase64
}

public enum TTSPlaybackError: Error, Equatable, Sendable {
  /// The clip could not be decoded, prepared or started (or the decoder failed mid-clip).
  case failed
  /// Playback stopped advancing for `TTSClient.stallTimeout` (the desktop's watchdog).
  case stalled
}

/// Plays one synthesized clip at a time for "Read replies aloud" (#74). A dumb player: the
/// playback state machine (which row, auto-speak, interruption latch) lives in
/// `ChatFeature`; this client only owns `AVAudioSession`/`AVAudioPlayer` so reducers never
/// touch AVFoundation directly.
@DependencyClient
public struct TTSClient: Sendable {
  /// Play `data` (of `mimeType`) to the end. Returns normally when the clip finishes, when
  /// `stop()` is called, on an audio-session interruption, or when the calling task is
  /// cancelled; throws `TTSPlaybackError` on a decode/start failure or a stall. A new `play`
  /// supersedes (stops) any clip already playing.
  public var play: @Sendable (_ data: Data, _ mimeType: String) async throws -> Void
  /// Stop playback. Idempotent; returns only after the audio session is deactivated, so a
  /// caller can start recording right after it (the mic path relies on that ordering).
  public var stop: @Sendable () async -> Void

  /// The desktop's `PLAYBACK_STALL_MS`: playback whose position has not advanced for this
  /// long (armed before `play()`) fails with `TTSPlaybackError.stalled`.
  public static let stallTimeout: Duration = .seconds(15)
}

extension TTSClient: DependencyKey {
  /// No-op double: `play` returns instantly (a clip that "finished"), `stop` does nothing.
  /// Override closures in tests to record calls or hold playback open. (Spelled out so the
  /// `@DependencyClient` macro's unimplemented closures don't leak into the default.)
  public static var testValue: TTSClient {
    TTSClient(
      play: { _, _ in },
      stop: {}
    )
  }
}

public extension DependencyValues {
  var tts: TTSClient {
    get { self[TTSClient.self] }
    set { self[TTSClient.self] = newValue }
  }
}

// MARK: - Live (iOS only)

// AVAudioSession is iOS-only; the package is also built/tested on macOS via `swift test`,
// so the live player is compiled in only where UIKit exists. Elsewhere `liveValue` falls
// back to the no-op test double (no speaker).
#if canImport(UIKit)
  import AVFoundation

  /// Bridges the `AVAudioPlayerDelegate` callbacks into the engine actor. Everything is
  /// `nonisolated` (the SDK's main-actor delegate protocol would otherwise isolate the class,
  /// and the engine actor creates it); the only state is an immutable `@Sendable` closure.
  private final class TTSPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable (_ successfully: Bool) -> Void

    nonisolated init(onFinish: @escaping @Sendable (_ successfully: Bool) -> Void) {
      self.onFinish = onFinish
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully flag: Bool) {
      onFinish(flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_: AVAudioPlayer, error _: (any Error)?) {
      onFinish(false)
    }
  }

  /// Serializes access to the non-Sendable `AVAudioPlayer` and owns the temp file, the
  /// stall watchdog, the interruption observer and the suspended `play` continuation.
  /// Every exit funnels through `finish(_:)`, which tears everything down exactly once.
  private actor TTSPlaybackEngine {
    private var player: AVAudioPlayer?
    private var delegate: TTSPlayerDelegate?
    private var fileURL: URL?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var watchdog: Task<Void, Never>?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var sessionActive = false
    /// Bumped per clip so a late delegate/watchdog/notification callback from a superseded
    /// clip is ignored.
    private var generation = 0

    func play(data: Data, mimeType: String) async throws {
      // Single playback: a new clip supersedes the old one (which returns normally).
      finish(.success(()))
      generation += 1
      let token = generation
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
          self.continuation = continuation
          do {
            try start(data: data, mimeType: mimeType, token: token)
          } catch {
            finish(.failure(TTSPlaybackError.failed))
          }
        }
      } onCancel: {
        Task { await self.stop(token: token) }
      }
    }

    /// Public stop: ends whatever is playing. Idempotent.
    func stop() {
      finish(.success(()))
    }

    private func stop(token: Int) {
      guard token == generation else { return }
      finish(.success(()))
    }

    private func start(data: Data, mimeType: String, token: Int) throws {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hermes-tts-\(UUID().uuidString).\(TTSAudio.fileExtension(forMimeType: mimeType))")
      try data.write(to: url)
      fileURL = url

      let session = AVAudioSession.sharedInstance()
      // `.playback` plays through the silent switch — the user explicitly asked to hear it.
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
      sessionActive = true

      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session,
        queue: nil
      ) { [weak self] notification in
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
        // An interruption (call, Siri, another app's audio) ends the clip — not an error.
        Task { await self?.stop(token: token) }
      }

      let player = try AVAudioPlayer(contentsOf: url)
      let delegate = TTSPlayerDelegate { [weak self] successfully in
        Task { await self?.playerFinished(token: token, successfully: successfully) }
      }
      player.delegate = delegate
      self.player = player
      self.delegate = delegate
      guard player.prepareToPlay() else { throw TTSPlaybackError.failed }

      // Armed before `play()`, like the desktop: a clip that never starts also stalls.
      armWatchdog(token: token, startTime: player.currentTime)
      guard player.play() else { throw TTSPlaybackError.failed }
    }

    /// Polls the playback position; every advance re-arms the timeout, and a position
    /// stuck for `TTSClient.stallTimeout` fails the clip with `.stalled`.
    private func armWatchdog(token: Int, startTime: TimeInterval) {
      watchdog?.cancel()
      watchdog = Task { [weak self] in
        let clock = ContinuousClock()
        var lastTime = startTime
        var lastProgress = clock.now
        while !Task.isCancelled {
          try? await clock.sleep(for: .milliseconds(500))
          guard !Task.isCancelled, let self,
                let time = await self.currentTime(token: token)
          else { return }
          if time > lastTime {
            lastTime = time
            lastProgress = clock.now
          } else if clock.now - lastProgress >= TTSClient.stallTimeout {
            await self.stalled(token: token)
            return
          }
        }
      }
    }

    private func currentTime(token: Int) -> TimeInterval? {
      guard token == generation, let player else { return nil }
      return player.currentTime
    }

    private func stalled(token: Int) {
      guard token == generation else { return }
      finish(.failure(TTSPlaybackError.stalled))
    }

    private func playerFinished(token: Int, successfully: Bool) {
      guard token == generation else { return }
      finish(successfully ? .success(()) : .failure(TTSPlaybackError.failed))
    }

    /// The one teardown: stop the player, drop the watchdog and observer, delete the temp
    /// file, deactivate the session (once — `sessionActive` guards a second stop), then
    /// resume the suspended `play` (once). Synchronous on the actor, so `stop()` returns
    /// only after the deactivation.
    private func finish(_ result: Result<Void, any Error>) {
      watchdog?.cancel()
      watchdog = nil
      if let interruptionObserver {
        NotificationCenter.default.removeObserver(interruptionObserver)
      }
      interruptionObserver = nil
      player?.delegate = nil
      player?.stop()
      player = nil
      delegate = nil
      if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
      fileURL = nil
      if sessionActive {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
      }
      let continuation = continuation
      self.continuation = nil
      continuation?.resume(with: result)
    }
  }

  extension TTSClient {
    public static var liveValue: TTSClient {
      let engine = TTSPlaybackEngine()
      return TTSClient(
        play: { data, mimeType in try await engine.play(data: data, mimeType: mimeType) },
        stop: { await engine.stop() }
      )
    }
  }
#else
  extension TTSClient {
    /// No speaker off-device (macOS `swift test`): fall back to the no-op double.
    public static var liveValue: TTSClient { testValue }
  }
#endif
