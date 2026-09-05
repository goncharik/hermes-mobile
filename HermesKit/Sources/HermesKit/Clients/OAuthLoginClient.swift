import ComposableArchitecture
import DependenciesMacros
import Foundation

/// The browser leg of the native OAuth flow, end to end: PKCE → loopback listener →
/// `ASWebAuthenticationSession` → `POST /auth/native/token` → a `BearerSession` the caller
/// seeds into `BearerTokenStore`.
///
/// One call, one sign-in. Everything transport- and UI-shaped lives behind this client so
/// `ConnectionFeature`/`ReauthFeature` stay pure reducers (CLAUDE.md → Core rules).
@DependencyClient
public struct OAuthLoginClient: Sendable {
  /// Run the full RFC 8252 leg against `baseURL`. `provider` is the gateway's provider
  /// `name`; `nil` lets the gateway auto-select its single non-password session provider.
  ///
  /// Throws `OAuthLoginError` — notably `.cancelled` when the user dismissed the sheet,
  /// which callers handle SILENTLY (back to idle, no banner).
  public var signIn: @Sendable (_ baseURL: URL, _ provider: String?) async throws -> BearerSession
}

extension OAuthLoginClient: DependencyKey {
  /// Unimplemented by default: a reducer test that reaches the browser leg must say what
  /// the browser did.
  public static var testValue: OAuthLoginClient { OAuthLoginClient() }

  public static var previewValue: OAuthLoginClient {
    OAuthLoginClient(signIn: { _, _ in
      BearerSession(
        accessToken: "preview-access-token",
        refreshToken: "preview-refresh-token",
        expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
        provider: "nous",
        userID: "preview-user"
      )
    })
  }
}

public extension DependencyValues {
  var oauthLogin: OAuthLoginClient {
    get { self[OAuthLoginClient.self] }
    set { self[OAuthLoginClient.self] = newValue }
  }
}

// MARK: - Browser outcome

/// What the browser sheet reported. There is no success case: the session is started with
/// `callbackURLScheme: nil`, so it can never match a callback itself — the loopback listener
/// is what settles the flow, and the sheet only ever reports how it went away.
enum OAuthBrowserOutcome: Equatable, Sendable {
  /// The user closed the sheet (`ASWebAuthenticationSessionError.canceledLogin`).
  case cancelledByUser
  /// We tore it down (the flow settled elsewhere), or it vanished without a verdict.
  case dismissed
  /// The session refused to present or failed with something else, carrying its reason.
  case failed(String)
}

// MARK: - Orchestration seam

/// Everything the login flow needs from the outside world, injected so the whole
/// orchestration is testable on macOS without a browser (mirrors the desktop's injected
/// driver in `apps/desktop/electron/native-oauth-login.ts`).
struct NativeLoginDriver: Sendable {
  var makePKCE: @Sendable () -> PKCEPair
  var makeState: @Sendable () -> String
  var startListener: @Sendable () async throws -> LoopbackCallbackSession
  var openBrowser: @Sendable (URL) async -> OAuthBrowserOutcome
  var exchange: @Sendable (_ code: String, _ verifier: String) async throws -> BearerSession
  var clock: any Clock<Duration>
  /// Whole-flow budget. The desktop uses the same 5 minutes; the gateway's pending
  /// authorization expires at 600 s, so this always fires first.
  var timeout: Duration

  init(
    makePKCE: @escaping @Sendable () -> PKCEPair = { PKCEPair.generate() },
    makeState: @escaping @Sendable () -> String = { generateOAuthState() },
    startListener: @escaping @Sendable () async throws -> LoopbackCallbackSession = {
      try await LoopbackCallbackListener().start()
    },
    openBrowser: @escaping @Sendable (URL) async -> OAuthBrowserOutcome,
    exchange: @escaping @Sendable (String, String) async throws -> BearerSession,
    clock: any Clock<Duration> = ContinuousClock(),
    timeout: Duration = .seconds(300)
  ) {
    self.makePKCE = makePKCE
    self.makeState = makeState
    self.startListener = startListener
    self.openBrowser = openBrowser
    self.exchange = exchange
    self.clock = clock
    self.timeout = timeout
  }
}

/// Whichever of the three racing legs finished first.
private enum NativeLoginSettlement: Sendable {
  case callback(String)
  case browser(OAuthBrowserOutcome)
  case timedOut
}

/// The full flow, transport- and UI-free.
///
/// The race is the load-bearing part. Per the Task 1 spike, `session.cancel()` delivers NO
/// completion callback, so the browser leg can never confirm its own teardown: the LISTENER
/// settles the flow, and the sheet's completion only matters when it arrives FIRST (a user
/// dismissal → `.cancelled`). After the callback wins, the browser child is cancelled and
/// whatever it would have said is discarded.
func runNativeLogin(
  baseURL: URL,
  provider: String?,
  driver: NativeLoginDriver
) async throws -> BearerSession {
  let pkce = driver.makePKCE()
  let state = driver.makeState()

  let listener: LoopbackCallbackSession
  do {
    listener = try await driver.startListener()
  } catch {
    throw error as? OAuthLoginError ?? OAuthLoginError.listenerFailed
  }
  // Idempotent with the explicit stop below; this is the error-path teardown.
  defer { listener.stop() }

  guard let authorizeURL = nativeAuthorizeURL(
    base: baseURL,
    challenge: pkce.challenge,
    redirectURI: listener.redirectURI,
    state: state,
    provider: provider
  ) else {
    // Unreachable for a server URL that already answered `/api/status`; kept in the
    // OAuth error domain rather than forcing a shared one into the pure helpers.
    throw OAuthLoginError.gatewayRejected("The server address couldn’t be used to start sign-in.")
  }

  let target = try await awaitCallback(listener: listener, authorizeURL: authorizeURL, driver: driver)
  // Close the loopback socket before the token hop: the code is already in hand and the
  // browser has been dismissed, so nothing else may arrive on it.
  listener.stop()

  // State is verified before the code is redeemed (RFC 6749 §10.12) — inside the parser.
  let code = try parseLoopbackCallback(requestTarget: target, expectedState: state)
  do {
    return try await driver.exchange(code, pkce.verifier)
  } catch let error as OAuthLoginError {
    throw error
  } catch {
    throw OAuthLoginError.tokenExchange(asRESTError(error))
  }
}

/// Race the loopback callback against the browser sheet and the whole-flow timeout.
private func awaitCallback(
  listener: LoopbackCallbackSession,
  authorizeURL: URL,
  driver: NativeLoginDriver
) async throws -> String {
  let settlement = await withTaskGroup(of: NativeLoginSettlement?.self) { group in
    group.addTask {
      // Probes and zero-byte opens are answered by the listener but never settle the flow.
      for await target in listener.targets where isLoopbackCallback(requestTarget: target) {
        return .callback(target)
      }
      return nil // the listener finished without ever seeing a callback
    }
    group.addTask {
      .browser(await driver.openBrowser(authorizeURL))
    }
    group.addTask {
      // A cancelled sleep is not a timeout — it means another leg already won.
      do { try await driver.clock.sleep(for: driver.timeout) } catch { return nil }
      return .timedOut
    }
    let first = await group.next() ?? nil
    // Cancelling dismisses the sheet (the live `openBrowser` cancels its session on
    // cancellation) and unblocks the other children so the group can be torn down.
    group.cancelAll()
    return first
  }

  switch settlement {
  case let .callback(target):
    return target
  case .browser(.cancelledByUser), .browser(.dismissed):
    throw OAuthLoginError.cancelled
  case let .browser(.failed(reason)):
    throw OAuthLoginError.gatewayRejected(reason)
  case .timedOut:
    throw OAuthLoginError.timedOut
  case .none:
    throw OAuthLoginError.listenerFailed
  }
}

// MARK: - Live (iOS only)

// `ASWebAuthenticationSession` needs a UIKit presentation anchor, so the live client is
// compiled only where UIKit exists; on macOS (`swift test`) `liveValue` falls back to the
// unimplemented double. Everything above this line stays covered by the macOS suite.
#if canImport(UIKit)
  import AuthenticationServices
  import UIKit

  extension OAuthLoginClient {
    public static var liveValue: OAuthLoginClient {
      OAuthLoginClient(signIn: { baseURL, provider in
        @Dependency(\.hermesREST) var rest
        let driver = NativeLoginDriver(
          openBrowser: { url in await presentAuthenticationBrowser(url: url) },
          exchange: { code, verifier in
            try await rest.nativeTokenExchange(baseURL, code, verifier)
          }
        )
        return try await runNativeLogin(baseURL: baseURL, provider: provider, driver: driver)
      })
    }
  }

  /// Present the sheet and report how it went away. Returns `.dismissed` when the enclosing
  /// task is cancelled — which is the normal path: the listener won the race and we are
  /// tearing the sheet down ourselves.
  private func presentAuthenticationBrowser(url: URL) async -> OAuthBrowserOutcome {
    let host = await BrowserSessionHost()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        Task { @MainActor in host.start(url: url, continuation: continuation) }
      }
    } onCancel: {
      // `cancel()` must happen on the main actor, and (per the spike) delivers no
      // completion — the host resumes the continuation itself.
      Task { @MainActor in host.dismiss() }
    }
  }

  /// Owns the `ASWebAuthenticationSession` and its (weakly-held) context provider, and
  /// resumes the continuation exactly once. `@MainActor` isolation is the whole
  /// synchronisation story — no locks needed.
  @MainActor
  private final class BrowserSessionHost {
    private var session: ASWebAuthenticationSession?
    private var presenter: BrowserPresenter?
    private var continuation: CheckedContinuation<OAuthBrowserOutcome, Never>?
    private var settled = false

    func start(url: URL, continuation: CheckedContinuation<OAuthBrowserOutcome, Never>) {
      // Cancellation can beat presentation; never open a sheet nobody is waiting on.
      guard !settled else {
        continuation.resume(returning: .dismissed)
        return
      }
      self.continuation = continuation

      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
        // Only ever a failure verdict: with a nil callback scheme the session cannot
        // complete with a URL.
        let outcome: OAuthBrowserOutcome
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          outcome = .cancelledByUser
        } else if let error {
          outcome = .failed(error.localizedDescription)
        } else {
          outcome = .dismissed
        }
        Task { @MainActor in self?.settle(outcome) }
      }
      // Share the system browser's cookies/passkeys so an already-signed-in portal session
      // completes without re-entering credentials.
      session.prefersEphemeralWebBrowserSession = false
      let presenter = BrowserPresenter(anchor: BrowserPresenter.keyWindowAnchor())
      self.presenter = presenter // the session holds it WEAKLY
      session.presentationContextProvider = presenter
      self.session = session

      guard session.start() else {
        settle(.failed("Couldn’t open the sign-in browser."))
        return
      }
    }

    /// Tear the sheet down from our side (the flow settled elsewhere, or was cancelled).
    func dismiss() {
      session?.cancel()
      settle(.dismissed)
    }

    private func settle(_ outcome: OAuthBrowserOutcome) {
      guard !settled else { return }
      settled = true
      session = nil
      presenter = nil
      let continuation = self.continuation
      self.continuation = nil
      continuation?.resume(returning: outcome)
    }
  }

  /// Supplies the presentation anchor. The anchor is captured on the main actor at
  /// session-creation time so the (non-isolated) protocol callback just hands it back.
  private final class BrowserPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private nonisolated(unsafe) let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
      self.anchor = anchor
      super.init()
    }

    @MainActor
    static func keyWindowAnchor() -> ASPresentationAnchor {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
  }
#else
  extension OAuthLoginClient {
    /// No `ASWebAuthenticationSession` off-device (macOS `swift test`): the browser leg is
    /// unimplemented, while `runNativeLogin` itself stays fully covered by injected fakes.
    public static var liveValue: OAuthLoginClient { testValue }
  }
#endif
