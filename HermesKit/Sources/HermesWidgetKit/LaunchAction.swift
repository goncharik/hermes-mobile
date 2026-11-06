import Foundation

/// The one-shot action a fresh chat runs as soon as it opens, requested by a `LaunchIntent`
/// (Dictate, or a widget's Camera / Photos button). `ChatFeature` consumes it once; the mic
/// starts only from idle.
public enum LaunchAction: String, Codable, Equatable, Sendable {
  /// Start the mic.
  case dictation
  /// Raise the camera picker.
  case camera
  /// Raise the photo picker.
  case photos
}
