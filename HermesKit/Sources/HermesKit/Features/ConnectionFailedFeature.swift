import ComposableArchitecture
import Foundation

/// Shown instead of onboarding when **launch auto-connect** fails for a reason that isn't a
/// verdict on the stored credentials — the phone couldn't reach the server at all (`.offline`
/// / `.unreachable`), or it reached *something* that answered badly (a proxy's 502, the
/// agent's own 500, a captive portal's HTML, a 404 from a route that moved). Dropping to
/// onboarding there would force a password-mode user to re-type credentials that never
/// expired, so this screen keeps the session and offers a Retry.
///
/// A genuine auth rejection never lands here — `AppFeature` routes those to onboarding as
/// before, and if a *retry* from this screen comes back with a credentials verdict the
/// reducer bubbles `.credentialsRejected` so the user ends up in the same place.
///
/// Two ways out, only one of them destructive: **Retry** (plus a foreground auto-retry) and
/// **Log Out**, behind a confirmation, which abandons the session. The view additionally links
/// the `AgentSetupGuideView` sheet directly (view-local `@State`, as in onboarding's
/// `ConnectionView`), so connection help is one tap away.
///
/// The reducer is pure routing + the retry probe: clearing the keychain/prefs on
/// `.logoutConfirmed` lives in `AppFeature`, next to the other full-logout recipe.
///
/// **Where the pure statics live** — one rule, so a reader never has to guess which type to
/// look on: the **routing** rule (which failures earn this screen at all) sits on the
/// *reducer*, because it is shared with `AppFeature`'s launch routing; everything that only
/// decides **what the screen says** sits on *`State`*, next to `reasonText`.
@Reducer
public struct ConnectionFailedFeature {
  /// The HTTP statuses that ARE a verdict on the stored credentials: `401` (which `validate`
  /// already surfaces as `.unauthorized`, but a raw `.server(401)` from any other path means
  /// the same thing) and `403`. Only these send the user back to a credentials form.
  ///
  /// Deliberately not API: `isRetryable` is the ONE rule callers ask, and exposing the set
  /// would invite a second, drifting copy of that decision.
  private static let credentialsRejectionStatuses: Set<Int> = [401, 403]

  /// The ONE rule deciding "worth a Retry" vs "back to onboarding", shared by `AppFeature`'s
  /// launch routing and this reducer's retry-failure branch so the two can't drift.
  ///
  /// The rule is deliberately inverted from the obvious one: **only a credentials rejection
  /// (401/403) goes to onboarding; everything else gets the retry screen.** A stored
  /// connection was, by construction, a working Hermes agent at some point — onboarding
  /// validates before persisting — so a launch failure that isn't a 401/403 says something
  /// changed on the *network or server* side, not that the saved sign-in went bad. Making
  /// such a user re-type a password is issue #62's exact symptom, and it buys nothing: the
  /// retry screen states the real failure (`HTTP 500`, `HTTP 404`, a captive-portal reply)
  /// where prefilled onboarding shows a blank field and no explanation.
  public static func isRetryable(_ error: RESTError) -> Bool {
    switch error {
    case .unauthorized:
      false
    case let .server(status, _):
      !credentialsRejectionStatuses.contains(status)
    case .offline, .unreachable, .serviceUnavailable, .notFound, .rateLimited, .decoding,
         .transcriptionFailed:
      true
    }
  }

  @ObservableState
  public struct State: Equatable {
    /// The connection that failed to validate — retried verbatim, and its `baseURL` is what
    /// the screen names so the user can tell *which* server is unreachable.
    public var connection: ServerConnection
    /// Why the last attempt failed. Always a retryable error (see `isRetryable`); anything
    /// else routes away from this screen.
    public var reason: RESTError
    /// A probe is in flight — drives the spinner and guards against double-firing (two fast
    /// Retry taps).
    public var isRetrying: Bool
    /// Log Out wipes the keychain session, every pref and the snapshot cache, and it sits one
    /// tap away on a launch screen a frustrated user is poking at — so it confirms first
    /// (project convention: destructive actions are state-driven dialogs).
    @Presents public var confirmationDialog: ConfirmationDialogState<Action.Dialog>?

    public init(connection: ServerConnection, reason: RESTError, isRetrying: Bool = false) {
      self.connection = connection
      self.reason = reason
      self.isRetrying = isRetrying
    }

    /// The server the app failed to reach, as typed by the user during onboarding.
    public var serverURLText: String { connection.baseURL.absoluteString }

    /// One-line explanation of the failure, split so "you're offline" doesn't send the user
    /// hunting for a dead server (and vice-versa). Exhaustive on purpose: the day a new
    /// `RESTError` case appears, the compiler asks where it belongs rather than silently
    /// rendering VPN advice for it.
    public var reasonText: String {
      switch reason {
      case .offline:
        "You appear to be offline. Check Wi-Fi or cellular data and try again."
      case .unreachable:
        "The server didn’t respond. If it’s on a private network (VPN/Tailscale), make sure that connection is on."
      case .serviceUnavailable:
        "The server is reachable but isn’t answering right now. It may be starting up — try again in a moment."
      case let .server(status, detail):
        Self.serverReasonText(status: status, detail: detail)
      case .notFound:
        "The server answered, but there’s no Hermes agent at this address (HTTP 404)."
      case .rateLimited:
        "The server is turning requests away right now (HTTP 429). Try again in a moment."
      case .decoding:
        "The reply didn’t look like a Hermes agent. You may be behind a Wi-Fi sign-in page, or this address may now point somewhere else."
      case .unauthorized, .transcriptionFailed:
        // Unreachable by construction (`.unauthorized` is the one thing `isRetryable` keeps
        // off this screen; `.transcriptionFailed` can't come from the sessions probe). Render
        // the honest message rather than misleading VPN advice if routing ever changes.
        reason.message
      }
    }

    /// The 4xx statuses that are a *transient* refusal — the request was well-formed, the
    /// server just isn't taking it right now — so they belong with the 5xx "try again"
    /// advice, not with the permanent-refusal copy.
    ///
    /// These really do reach this screen as a bare `.server(status:)`: `validate` only maps
    /// `429`/`503` onto `.rateLimited`/`.serviceUnavailable` when `loginSpecific` is set, and
    /// the launch/retry probe is a plain authenticated `get`. A reverse proxy in front of the
    /// agent (nginx `limit_req`, Cloudflare) answering 429 is the realistic trigger; 408
    /// (Request Timeout) and 425 (Too Early) are the same shape.
    static let transientRefusalStatuses: Set<Int> = [408, 425, 429]

    /// Longest server-supplied `detail` the reason line will quote. The reason `Text` sits
    /// ABOVE this screen's two escape routes inside a `ScrollView`, so an unbounded body
    /// pushes Retry / Log Out below the fold.
    static let maxServerDetailLength = 200

    /// Make a server-supplied `detail` safe to quote on the reason line: drop an HTML/XML
    /// document outright, keep only the first line, and cap the length.
    ///
    /// `serverDetail(from:)` falls back to the **entire trimmed response body** when there's
    /// no JSON `detail`, and a 4xx from an intermediary (nginx, Cloudflare, a captive portal)
    /// is a full HTML page — never an actionable sentence, frequently kilobytes, and often
    /// carrying internal hostnames or proxy diagnostics onto a screen a stuck user is likely
    /// to screenshot. `nil` here means "quote nothing" and the caller falls back to the
    /// generic line. (Injection is not a hazard: `Text(store.reasonText)` binds the
    /// `StringProtocol` overload, so no Markdown/link parsing happens — size and content are.)
    static func sanitizedServerDetail(_ detail: String?) -> String? {
      let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
      guard let firstLine = trimmed.split(whereSeparator: \.isNewline).first else { return nil }
      let line = firstLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { return nil }
      guard line.count > maxServerDetailLength else { return line }
      return line.prefix(maxServerDetailLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Copy for a `.server` status `RESTError` doesn't model on its own (401/403 never reach
    /// this screen; 404 / 429 / 503 have their own cases *when the call was login-specific*),
    /// split three ways because a permanent refusal and a transient one mean opposite things
    /// here — and an out-of-band status means neither.
    ///
    /// A **5xx**, or one of the `transientRefusalStatuses`, is the server faulting or
    /// throttling a request it otherwise accepts — restarting, a DB blip, a proxy's 502, a
    /// rate limiter — and a retry genuinely may clear it, so "try again in a moment" is
    /// honest advice.
    ///
    /// Any **other 4xx** is the server *refusing* the request, and it will refuse the next
    /// identical one exactly the same way: waiting is the one thing that cannot help. The
    /// motivating case is the agent's own host-header 400 ("Invalid Host header. Dashboard
    /// requests must use the hostname the server was bound to."), which fires on EVERY
    /// request once the agent is restarted without `--host 0.0.0.0` — the likeliest operator
    /// misconfiguration for this app, and one that needs an agent restart, not a retry and
    /// not a new URL.
    ///
    /// So the server's own `detail` is surfaced when it sent one (sanitized — see
    /// `sanitizedServerDetail`): it is the only actionable sentence available, it is exactly
    /// what the onboarding probe used to show (`RESTError.message` → `.failed(message)`)
    /// before launch failures stopped landing there, and discarding it left the user with
    /// nothing to act on.
    ///
    /// Anything outside both bands (an unfollowed 3xx, a bogus code) gets **neutral** copy —
    /// inheriting the 5xx "it may be down" line for a 302 would be a guess stated as fact.
    static func serverReasonText(status: Int, detail: String?) -> String {
      if transientRefusalStatuses.contains(status) {
        return
          "The server is turning requests away right now (HTTP \(status)). Try again in a moment."
      }
      if (500..<600).contains(status) {
        return
          "The server is reachable but returned an error (HTTP \(status)). It may be down or restarting — try again in a moment."
      }
      guard (400..<500).contains(status) else {
        return
          "The server answered unexpectedly (HTTP \(status)). Try again in a moment."
      }
      guard let explanation = sanitizedServerDetail(detail) else {
        return
          "The server refused the request (HTTP \(status)) — retrying won’t change that. Check the agent’s setup."
      }
      return
        "The server refused the request (HTTP \(status)) — retrying won’t change that. It said: “\(explanation)”"
    }
  }

  public enum Action: Equatable, Sendable {
    case retryTapped
    /// The app came back to the foreground — re-probe (the user very likely just turned the
    /// VPN back on, which is exactly the moment a manual tap is most annoying).
    case sceneBecameActive
    /// Log Out button — raises the confirmation; only `.confirmLogout` actually logs out.
    case logoutButtonTapped
    case confirmationDialog(PresentationAction<Dialog>)
    /// The probe validated the stored session.
    case retrySucceeded
    /// The probe failed — the payload decides "stay and retry" vs "back to onboarding".
    case retryFailed(RESTError)
    case delegate(Delegate)

    @CasePathable
    public enum Dialog: Equatable, Sendable {
      case confirmLogout
    }

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// The stored credentials validated — `AppFeature` builds home exactly as it does for
      /// a successful launch auto-connect.
      case connected(ServerConnection)
      /// The retry reached the server and it rejected us (401 and friends) — retrying can't
      /// fix that, so fall back to onboarding for re-entry.
      case credentialsRejected(ServerConnection)
      /// The user confirmed the Log Out dialog — abandon the stored session, and `AppFeature`
      /// runs the full-logout recipe. Named for the *outcome*, like its siblings: the bare
      /// button tap is `Action.logoutButtonTapped` and only raises the confirmation.
      case logoutConfirmed
    }
  }

  /// The retry probe. Cancellable so a foreground can supersede a stalled one — `URLSession`'s
  /// default request timeout is 60s, and without this a probe that never resolves would leave
  /// `isRetrying` latched and both the spinner and the guard stuck forever.
  ///
  /// **Cancelling it cannot cost a cookie-mode user their session**, even though a probe *is*
  /// the kind of gated request that can trigger the agent's transparent server-side refresh
  /// (expired `hermes_session_at` + live `hermes_session_rt` → the gate rotates and replays the
  /// new pair in `Set-Cookie`). Two measured facts, both needed:
  ///
  /// 1. A cancelled `data(for:)` really does drop that `Set-Cookie` — measured against a local
  ///    server that emits the headers immediately and stalls the body: the jar is still empty
  ///    1.4s after the header bytes are on the wire, so a buffered data task stores cookies at
  ///    *completion*, not at header receipt, and cancelling loses the rotation outright.
  ///    (`bytes(for:)` differs — it stores at header receipt — but no transport here uses it.)
  /// 2. That loss is harmless, because the rotation it discards is not destructive. A mobile
  ///    cookie session can only be minted by `POST /auth/password-login`, which 404s any
  ///    provider without `supports_password` — and the agent's ONE such provider is
  ///    `BasicAuthProvider`, whose sessions are stateless HMAC-signed blobs: `refresh_session`
  ///    just checks the signature/`exp` and mints a fresh pair, `revoke_session` is a documented
  ///    no-op, and there is no server-side rotation record to consume. Verified against the real
  ///    provider: the ORIGINAL refresh token still refreshes after repeated rotations and after
  ///    a revoke, for its full 30-day `exp`. So a discarded rotation just means the next request
  ///    refreshes again.
  ///
  /// The rotating, single-use, reuse-detected refresh token — where dropping the successor
  /// really would revoke the family — belongs to the Nous Portal (`nous`) provider, which is
  /// OAuth-only (`supports_password = False`) and therefore unreachable from this app.
  private enum CancelID { case probe }

  @Dependency(\.hermesREST) var rest

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .retryTapped:
        // Two fast taps must not fan out into parallel probes. (A foreground deliberately
        // does NOT take this path — see `.sceneBecameActive`.)
        guard !state.isRetrying else { return .none }
        return probe(&state)

      case .sceneBecameActive:
        // A foreground always re-probes, superseding whatever is in flight (`cancelInFlight`
        // keeps it to exactly one probe at a time). Swallowing it under an `isRetrying` guard
        // would make a probe whose result never lands brick the screen permanently; the user
        // returning to the app is precisely the signal that the network just changed.
        return probe(&state)

      case .retrySucceeded:
        state.isRetrying = false
        return .send(.delegate(.connected(state.connection)))

      case let .retryFailed(error):
        state.isRetrying = false
        guard Self.isRetryable(error) else {
          // The server rejected the stored credentials (401/403) — this screen can't help.
          return .send(.delegate(.credentialsRejected(state.connection)))
        }
        // Still retryable — stay put, but refresh the reason (offline ⇄ unreachable ⇄ a
        // proxy's 502 can flip between attempts).
        state.reason = error
        return .none

      case .logoutButtonTapped:
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Log out?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmLogout) {
            TextState("Log Out")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "This deletes the saved sign-in for this server along with pins, unread state and cached chats."
          )
        }
        return .none

      case .confirmationDialog(.presented(.confirmLogout)):
        return .send(.delegate(.logoutConfirmed))

      case .confirmationDialog:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$confirmationDialog, action: \.confirmationDialog)
  }

  /// Start (or restart) the retry probe. Shared by the manual tap and the foreground so both
  /// use the same connection, the same page shape as launch auto-connect, and the same
  /// cancellation id.
  private func probe(_ state: inout State) -> Effect<Action> {
    state.isRetrying = true
    let connection = state.connection
    return .run { [rest] send in
      do {
        _ = try await rest.sessions(connection, 1, 0, .recent, .all)
        await send(.retrySucceeded)
      } catch {
        await send(.retryFailed(asRESTError(error)))
      }
    }
    .cancellable(id: CancelID.probe, cancelInFlight: true)
  }
}
