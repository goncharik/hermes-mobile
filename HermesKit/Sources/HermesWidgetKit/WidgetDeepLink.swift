import Foundation

/// The `hermesmobile://` URLs every widget, control and Live Activity tap opens. The app's one
/// `.onOpenURL` maps them back through `intent(from:)` into `LaunchIntentBridge`, so all the
/// #93 machinery (cold-launch buffer, stash, last-wins, logout clear) applies unchanged.
///
/// | URL                                          | Intent                                 |
/// |----------------------------------------------|----------------------------------------|
/// | `hermesmobile://new`                         | `.newChat`                             |
/// | `hermesmobile://new?with=dictation`          | `.newChatWithDictation`                |
/// | `hermesmobile://new?with=camera`             | `.newChatWithCamera`                   |
/// | `hermesmobile://new?with=photos`             | `.newChatWithPhotos`                   |
/// | `hermesmobile://session/<id>[?profile=<p>]`  | `.openSession(id:profile:)`            |
///
/// The id and the profile are percent-encoded (a `/`, `&`, `+` or space survives the round
/// trip). Anything else — another scheme or host, an empty id, an unknown `with=` value — is
/// `nil`, and a `nil` is ignored by the app.
public enum WidgetDeepLink {
  public static let scheme = "hermesmobile"

  static let newChatHost = "new"
  static let sessionHost = "session"
  static let actionQueryName = "with"
  static let profileQueryName = "profile"

  /// The URL a surface opens to request `intent`.
  public static func url(for intent: LaunchIntent) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    switch intent {
    case .newChat, .newChatWithDictation, .newChatWithCamera, .newChatWithPhotos:
      components.host = newChatHost
      if let action = intent.launchAction {
        components.percentEncodedQueryItems = [
          URLQueryItem(name: actionQueryName, value: action.rawValue)
        ]
      }
    case let .openSession(id, profile):
      components.host = sessionHost
      components.percentEncodedPath = "/" + encode(id, allowed: pathSegmentAllowed)
      if let profile {
        components.percentEncodedQueryItems = [
          URLQueryItem(name: profileQueryName, value: encode(profile, allowed: queryValueAllowed))
        ]
      }
    }
    // Every part above is either a fixed literal or strictly percent-encoded, so the
    // components always form a valid URL.
    guard let url = components.url else {
      preconditionFailure("WidgetDeepLink built an invalid URL for \(intent)")
    }
    return url
  }

  /// The intent `url` requests; `nil` for anything that isn't a well-formed Hermes deep link.
  public static func intent(from url: URL) -> LaunchIntent? {
    guard
      url.scheme?.lowercased() == scheme,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = components.host?.lowercased()
    else { return nil }
    let queryItems = components.queryItems ?? []

    switch host {
    case newChatHost:
      guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
      else { return nil }
      guard let item = queryItems.first(where: { $0.name == actionQueryName }) else {
        return .newChat
      }
      switch item.value.flatMap(LaunchAction.init(rawValue:)) {
      case .dictation: return .newChatWithDictation
      case .camera: return .newChatWithCamera
      case .photos: return .newChatWithPhotos
      case nil: return nil
      }

    case sessionHost:
      // Exactly one non-empty path segment: an encoded id never contains a raw `/`.
      let path = components.percentEncodedPath
      guard path.hasPrefix("/") else { return nil }
      let segment = path.dropFirst()
      guard !segment.isEmpty, !segment.contains("/"),
        let id = segment.removingPercentEncoding, !id.isEmpty
      else { return nil }
      let profile = queryItems.first(where: { $0.name == profileQueryName })?.value
      return .openSession(id: id, profile: profile?.isEmpty == false ? profile : nil)

    default:
      return nil
    }
  }

  // MARK: Encoding

  /// A single path segment: no `/`, `?`, `#` or `%` left raw.
  private static let pathSegmentAllowed: CharacterSet = {
    var set = CharacterSet.urlPathAllowed
    set.remove(charactersIn: "/%;")
    return set
  }()

  /// A query value: also escapes the separators (`&`, `=`) and `+` (which some parsers read as
  /// a space), so a profile name round-trips byte for byte.
  private static let queryValueAllowed: CharacterSet = {
    var set = CharacterSet.urlQueryAllowed
    set.remove(charactersIn: "&=+?#%/")
    return set
  }()

  private static func encode(_ value: String, allowed: CharacterSet) -> String {
    value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}
