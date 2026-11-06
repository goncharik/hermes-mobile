import Foundation

/// The app's App Store identity. `appID` stays `nil` until the app is live on the App Store;
/// while it is `nil` the Settings "Rate" row is hidden (`FeedbackLinks.rateApp`).
public enum AppStoreIdentity {
  public static let appID: String? = nil
}

/// Every external link the Settings Feedback and About groups open. Pure: the new-issue
/// URLs embed the caller's `BundleInfo` so a report arrives with the build facts prefilled.
public enum FeedbackLinks {
  /// The app's GitHub repository.
  public static let repository = URL(string: "https://github.com/goncharik/hermes-mobile")!
  /// The repository's issue list.
  public static let allIssues = URL(string: "https://github.com/goncharik/hermes-mobile/issues")!
  /// The Hermes Agent project this app is a client for.
  public static let hermesAgent = URL(string: "https://github.com/NousResearch/hermes-agent")!
  /// `PRIVACY.md` rendered on GitHub.
  public static let privacyPolicy = URL(
    string: "https://github.com/goncharik/hermes-mobile/blob/main/PRIVACY.md"
  )!

  /// A new GitHub issue prefilled with a "Bug: " title and the build facts.
  public static func reportBug(_ info: BundleInfo) -> URL {
    newIssue(
      title: "Bug: ",
      body: """
        **What happened?**


        **Steps to reproduce**


        \(environmentBlock(info))
        """
    )
  }

  /// A new GitHub issue prefilled with a "Feature request: " title and the build facts.
  public static func requestFeature(_ info: BundleInfo) -> URL {
    newIssue(
      title: "Feature request: ",
      body: """
        **What would you like Hermes Mobile to do?**


        \(environmentBlock(info))
        """
    )
  }

  /// The App Store write-review page for `appID`.
  public static func writeReview(appID: String) -> URL {
    URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!
  }

  /// The "Rate Hermes Mobile" destination: this app's write-review page, `nil` (row hidden)
  /// until `AppStoreIdentity.appID` is set.
  public static var rateApp: URL? { AppStoreIdentity.appID.map { writeReview(appID: $0) } }

  /// The facts every issue body ends with: app version and build, iOS version, device model.
  static func environmentBlock(_ info: BundleInfo) -> String {
    (["---"] + info.environmentLines).joined(separator: "\n")
  }

  static func newIssue(title: String, body: String) -> URL {
    let query = "title=\(percentEncoded(title))&body=\(percentEncoded(body))"
    return URL(string: "\(allIssues.absoluteString)/new?\(query)")!
  }

  /// Strict query-value encoding: only RFC 3986 unreserved ASCII stays literal, so `&`, `=`,
  /// `+`, `#`, newlines and non-ASCII are all escaped (`URLComponents` would leave `+`, which
  /// GitHub reads as a space).
  static func percentEncoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )
}
