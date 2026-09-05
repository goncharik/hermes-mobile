# OAuth (Nous Portal) sign-in via the gateway's native PKCE flow (#19)

## Overview

Add a third sign-in method to Hermes Mobile: OAuth against the gateway's identity provider
(Nous Research portal, or a self-hosted OIDC server), using the RFC 8252 native-app flow the
Hermes gateway already exposes for the desktop (`/auth/native/authorize|token|refresh`).

- **Problem.** A gateway configured with only an OAuth provider (the recommended setup for
  anything internet-facing) is unreachable from mobile today: the login screen disables
  Password and leaves only the static-token path, which a gated server rejects. Mixed
  deployments (password + Nous) never surface the OAuth option at all.
- **Benefit.** Users sign in with the same account the desktop uses, through a Safari-class
  browser sheet (`ASWebAuthenticationSession`) with shared portal cookies and passkeys. The
  app holds bearer tokens it refreshes itself; no web view ever sees a token.
- **Integration.** A third `AuthSession` regime (`.bearer`) slots beside `.token` and
  `.cookie`. REST authenticates with `Authorization: Bearer`; the WebSocket keeps the
  existing per-connect `ws-ticket` mint, which the gateway accepts with a bearer. The
  existing `.sessionExpired` → `ReauthFeature` path handles a dead refresh token.

Issue #19 was written before the native flow existed and assumed a cookie-harvesting web
view. This plan supersedes that framing; the issue is updated in the final task.

## Context (from discovery)

Verified against upstream Hermes `main` on 2026-09-05 (sibling clone
`/Users/eugene/Documents/Development/Personal/hermes-agent`, read via
`git show upstream/main:<path>` — the checked-out tree is stale).

**Server protocol**
- `GET /api/status` (public) carries `auth_flows`: gated → `["cookie"]`, plus
  `"native_pkce"` when any interactive session provider is registered
  (`hermes_cli/web_routers/status.py` `_auth_gate_status`). Absent on older gateways.
- `GET /auth/native/authorize?provider=&code_challenge=&code_challenge_method=S256&redirect_uri=&state=`
  — empty `provider` auto-selects the single non-password session provider. Password
  providers are redirected to the `/login` form instead (we never send one).
- `redirect_uri` MUST be `http://127.0.0.1[:port]/…` or `http://[::1][:port]/…`
  (`_validate_loopback_redirect_uri`); `localhost` and custom schemes → 400. Pending
  authorization TTL 600 s, issued code TTL 120 s (`hermes_cli/dashboard_auth/native_flow.py`).
- `POST /auth/native/token {code, code_verifier}` →
  `{access_token, refresh_token, token_type:"Bearer", expires_at (unix seconds), provider, user_id}`;
  any failure is a generic 400.
- `POST /auth/native/refresh {refresh_token, provider}` → same payload; 401
  `{"error":"session_expired"}` when every provider rejects the RT; 503 when a provider is
  unreachable (keep tokens, retry). The rotated RT MUST be persisted before reuse — the
  portal runs reuse detection and revokes the whole session on a replay.
- Gate middleware (`hermes_cli/dashboard_auth/middleware.py`) accepts
  `Authorization: Bearer <access_token>` on every `/api/*` route including
  `POST /api/auth/ws-ticket`; a presented-but-invalid bearer → structured 401. No
  server-side refresh on the bearer path.
- `POST /auth/logout` is best-effort (cookie path); with a bearer it's a no-op we still call.
- Providers via `GET /api/auth/providers`: `basic` (password), `nous` ("Nous Research"),
  `self_hosted` (generic OIDC). Display names come from the server.

**Desktop reference (mirror, don't invent)**
- `apps/desktop/electron/native-oauth.ts` — pure PKCE/URL/callback/token-parse helpers.
- `apps/desktop/electron/native-oauth-login.ts` — loopback listener driver: 5-minute
  browser-leg timeout, 15 s token POST, "signed in, close this window" HTML for every
  loopback request, state verified before redeeming.
- `apps/desktop/electron/main.ts` `ensureNativeAccessToken` — refresh-before-use; 401 clears
  tokens, anything else keeps them. Native chosen when `native_pkce` advertised AND a
  non-password provider exists. A failed native login does NOT auto-fall back.

**Mobile files involved**
- `HermesKit/Sources/HermesKit/Models/AuthSession.swift` — `.token | .cookie`; add `.bearer`.
- `HermesKit/Sources/HermesKit/Models/ServerAuthCapability.swift` — 3-case enum → struct.
- `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` — `ServerStatus`,
  `ServerConnection`, `get/postJSON/send` helpers keyed on `token: String?`.
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — `connect` switches on
  `AuthSession`; `mintTicket(baseURL, cookieSession)` closure; `wsTicket(...)`.
- `HermesKit/Sources/HermesKit/Clients/KeychainClient.swift` — `saveSession/loadSession`
  round-trip the whole `AuthSession` (JSON in one generic-password item).
- `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift` — `AuthMethod`,
  capability probe, `connectTapped` per method.
- `HermesKit/Sources/HermesKit/Features/ReauthFeature.swift` — per-method re-login,
  `isSameUser` identity compare.
- `HermesKit/Sources/HermesKit/AppFeature.swift` — launch restore (`keychain.loadSession`
  → `rest.sessions` probe), `.sessionExpired` → `makeReauthState`, reauth outcome routing,
  logout paths (`connectionFailed.logoutConfirmed`, `reauth.quit`, `.disconnect`).
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `.authExpired` →
  `delegate(.sessionExpired)` (unchanged; the bearer path feeds the same event).
- `HermesMobile/Sources/Features/ConnectionView.swift` — segmented Password | Token picker.
- `HermesMobile/Sources/Features/ReauthView.swift` — per-method form.
- Tests: `HermesKit/Tests/HermesKitTests/{AuthSessionTests, ServerAuthCapabilityTests,
  ConnectionFeatureTests, ReauthFeatureTests, HermesRESTClientTests,
  HermesGatewayClientTests, KeychainClientTests, PasswordLoginClientTests (MockURLProtocol
  pattern), AppFeatureTests}.swift`; `HermesMobileTests/{AuthSnapshotTests,
  ConnectionSnapshotTests}.swift`.
- Docs: `docs/architecture.md` → "Auth regimes"; `CLAUDE.md` → "Gateway & session
  lifecycle" auth bullet; new `docs/features/oauth-sign-in.md`.

**Patterns to follow**
- `@DependencyClient` structs with `liveValue` + `testValue`; iOS-only live values behind
  `#if canImport(UIKit)` with non-iOS `liveValue = testValue`; pure logic OUTSIDE the guard
  so `swift test` on macOS covers it.
- Capability gating: `?? true` on unknown fields, but a NEW affordance (the OAuth segment) is
  shown only on positive evidence (`native_pkce` present) — same as the desktop.
- Token mode must stay byte-identical (`ServerConnection.token` non-nil only for `.token`).
- Every `rest.*` failure normalized through `asRESTError`; surfaced, never swallowed.
- Destructive/expiry routing already exists: `GatewayError.authExpired` →
  `GatewayEvent.authExpired` → `ChatFeature` pauses reconnect → `.sessionExpired`.

## Development Approach

- **testing approach**: Regular (code first, then tests, per task) — consistent with every
  prior plan.
- complete each task fully before moving to the next; commit at each task completion.
- make small, focused changes; keep token-mode call sites untouched.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task:
  unit tests for new/modified functions, success + error scenarios, updated cases when
  behaviour changes. Tests are a required deliverable, not optional.
- **CRITICAL: all tests must pass before starting the next task** —
  `script -q /dev/null swift test --package-path HermesKit` (or `make test`).
- **CRITICAL: update this plan file when scope changes during implementation.**
- maintain backward compatibility: older gateways (no `auth_flows`, providers 404) behave
  exactly as today.

## Testing Strategy

- **unit tests (`swift test`, macOS)**: required for every task — pure PKCE/URL/parse
  helpers, capability mapper, `BearerSession` codable round-trip, `BearerTokenStore` actor
  (concurrency + failure semantics), REST/gateway clients over `MockURLProtocol`, TCA
  reducers via `TestStore` + dependency overrides + `TestClock`.
- **snapshot tests (`make snapshot`, simulator)**: the login screen's OAuth segment and the
  reauth sheet's OAuth variant, light + dark. To add ONE new snapshot test run
  `make snapshot` twice (first records + fails by design, second asserts clean). Judge the
  pre-existing broad drift by render-size mismatch first (see `CLAUDE.md` → Testing).
- **no e2e suite** in this project; the browser leg is verified by the Task 1 spike and the
  manual scenarios under Post-Completion.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

**Option A (chosen in the brainstorm): native PKCE + `ASWebAuthenticationSession` + an
in-app loopback listener.** No `WKWebView` cookie fallback; the OAuth segment is gated on
`native_pkce`, so older gateways simply keep showing Password | Token.

Key decisions and rationale:

1. **Bearer, not cookies.** The native flow returns tokens the app owns. Safari-class
   browser (IDPs that block embedded web views still work; portal cookies/passkeys shared),
   tokens never transit a web view, and refresh is explicit and testable. It is exactly the
   desktop's protocol, so we mirror a known-good client.
2. **Loopback redirect from the app.** The gateway only accepts `http://127.0.0.1:<port>/…`,
   so the live client binds an ephemeral-port `NWListener` on 127.0.0.1 and hands that URL
   as `redirect_uri`. `ASWebAuthenticationSession` cannot be told "done", so on callback we
   `cancel()` it and treat the resulting cancel error as success-already-handled. **Task 1
   is a spike that proves the Safari view service reaches the app's loopback listener on
   device and simulator before any other code is written.** Fallback if it fails: a
   `WKWebView` for the browser leg only, keeping the bearer token model (documented in the
   spike outcome; no other task changes).
3. **`BearerTokenStore` actor is the single owner of the token set.** Every REST call and
   every WS ticket mint go through `validAccessToken()`, which returns a fresh token, joins an
   in-flight refresh, or starts one. The rotated pair is persisted (Keychain) from inside the
   actor before any caller sees it, so concurrent requests at expiry produce exactly one
   refresh and no RT replay. Launch restore seeds the actor; reauth success reseeds it before
   reconnect; logout drains it. Nothing reads the Keychain or the expiry directly after
   seeding.
4. **Capability model becomes a struct.** Password provider (optional), OAuth providers
   (session providers with `supports_password == false`), `supportsNativeFlow`. A gated
   server with `basic` + `nous` now shows all three segments, password preselected.
5. **Identity for reauth routing is `user_id`** from the token payload (same-user → resume
   in place; different user → pop + clear identity-scoped prefs), reusing `isSameUser`.
6. **UI**: a third segment in the existing Sign-in picker labelled with the server's
   provider `display_name` (plain text — no logo/brand colours, App Store 5.2.1), whose
   content is one "Continue with <display_name>" button and a short note; one button per
   provider when several. Reauth sheet gets the same single button.

## Technical Details

### Data structures

```swift
// AuthSession.swift
public enum AuthSession { case token(String); case cookie(CookieSession); case bearer(BearerSession) }

public struct BearerSession: Equatable, Sendable, Codable {
  public var accessToken: String
  public var refreshToken: String
  /// Unix seconds (server `expires_at`).
  public var expiresAt: Double
  public var provider: String
  public var userID: String
}
```

`ServerConnection.token` stays `nil` for `.bearer` (as for `.cookie`) — the token-mode REST/WS
paths remain byte-identical.

```swift
// ServerStatus (HermesRESTClient.swift)
public var authFlows: [String]?          // CodingKeys "auth_flows"; lenient optional

// ServerAuthCapability.swift — struct replaces the enum
public struct ServerAuthCapability: Equatable, Sendable {
  public var passwordProvider: AuthProvider?     // first supports_password == true
  public var oauthProviders: [AuthProvider]      // supports_password == false, in server order
  public var supportsNativeFlow: Bool            // authFlows contains "native_pkce"
  public init(from status: ServerStatus, providers: [AuthProvider]?)
  public var isPasswordAvailable: Bool
  public var isOAuthAvailable: Bool              // !oauthProviders.isEmpty && supportsNativeFlow
  public var isGated: Bool                       // status.authRequired == true (token de-emphasis)
  public static let tokenOnly: ServerAuthCapability
}
```

Mapper rules (all preserved from today): `authRequired != true` → token only; providers
`nil`/empty → token only; otherwise fill both lists.

```swift
// ConnectionFeature.swift / ReauthFeature.swift
public enum AuthMethod: String { case password, token, oauth }
```

### OAuth login client

```swift
// Clients/OAuthLoginClient.swift
@DependencyClient
public struct OAuthLoginClient: Sendable {
  /// Run the full RFC 8252 leg against `baseURL` for `provider` (nil → gateway auto-select).
  /// Throws `OAuthLoginError.cancelled` when the user dismissed the sheet.
  public var signIn: @Sendable (_ baseURL: URL, _ provider: String?) async throws -> BearerSession
}
public enum OAuthLoginError: Error, Equatable { case cancelled, timedOut, stateMismatch,
  gatewayRejected(String), listenerFailed, tokenExchange(RESTError) }
```

Pure helpers (outside `#if canImport(UIKit)`, file `Models/NativeOAuth.swift`):
- `PKCEPair.generate(random:)` — 32 random bytes → base64url-no-pad verifier (43 chars);
  challenge = base64url(SHA256(ascii(verifier))) via CryptoKit; method `S256`.
- `generateState(random:)` — 24 random bytes base64url.
- `nativeAuthorizeURL(base:, challenge:, redirectURI:, state:, provider:)`,
  `nativeTokenURL(base:)`, `nativeRefreshURL(base:)` — preserve a path prefix on the base URL.
- `parseLoopbackCallback(requestTarget:, expectedState:) throws -> String` (the code):
  `error[_description]` → `.gatewayRejected`; missing code → `.gatewayRejected`;
  state mismatch → `.stateMismatch` (never redeem).
- `BearerSession(tokenResponse:)` lenient decode of the token/refresh payload (`expires_at`
  int or double; missing `access_token` → throw).

Live implementation (iOS only):
1. `NWListener(using: .tcp, on: .any)` bound to `127.0.0.1` (`NWEndpoint.Host.ipv4(.loopback)`
   via `requiredLocalEndpoint`); read the assigned `port`; redirect URI
   `http://127.0.0.1:<port>/callback`.
2. Accept connections; read the request line; respond `200 text/html` with the minimal
   "Signed in to Hermes — you can close this window" page for EVERY request (favicon probes
   too); only a target containing `code=` or `error=` settles the flow.
3. `ASWebAuthenticationSession(url:, callbackURLScheme: nil)` with
   `prefersEphemeralWebBrowserSession = false`, presentation context = key window. Its
   completion delivering `canceledLogin` BEFORE the listener settled → `.cancelled`; after →
   ignored.
4. On code: cancel the session, close the listener, `POST /auth/native/token` (15 s
   timeout, dedicated request — no auth), decode → `BearerSession`.
5. Whole-flow timeout 300 s (`OAuthLoginError.timedOut`). Listener/session always torn down.

### `BearerTokenStore` actor

```swift
// Clients/BearerTokenStore.swift
public actor BearerTokenStore {
  public init(now: @Sendable () -> Date = { Date() }, refreshLeeway: TimeInterval = 120)
  /// Replace the current token set + the persistence hook (Keychain save). Cancels any in-flight refresh.
  public func seed(_ session: BearerSession, baseURL: URL, persist: @Sendable (BearerSession) throws -> Void)
  public func clear()
  public var current: BearerSession? { get }
  /// Fresh access token; joins/starts ONE refresh when `expiresAt - now < leeway`.
  /// Throws `GatewayError.authExpired` on a refresh 401 (store cleared), rethrows anything else (tokens kept).
  public func validAccessToken(refresh: @Sendable (URL, BearerSession) async throws -> BearerSession) async throws -> String
}
/// Pure: does this token set need a refresh at `now`? (unit-tested with fixed dates)
public func bearerNeedsRefresh(_ s: BearerSession, now: Date, leeway: TimeInterval) -> Bool
```

- One process-level instance (`BearerTokenStore.shared`) referenced by the live REST and
  gateway clients, exactly like the shared cookie jar today; exposed as a dependency
  (`\.bearerTokens`) so reducers and tests inject their own.
- In-flight refresh = a stored `Task<BearerSession, Error>`; concurrent callers `await` the
  same task; on success `persist` runs inside the actor before the task value is published.
- Refresh transport: `POST /auth/native/refresh {refresh_token, provider}`; 401 →
  `GatewayError.authExpired` + `clear()`; 503/transport/other → rethrow, tokens intact.

### REST / gateway wiring

- `HermesRESTClient`: replace the `token: String?` parameter of `get/postJSON/send/upload`
  helpers with an `RequestAuth` enum (`.none | .sessionToken(String) | .bearer(String)`) that
  sets either `X-Hermes-Session-Token` or `Authorization: Bearer`. A private
  `auth(for connection:)` resolves `.token` → `.sessionToken`, `.cookie` → `.none` (jar),
  `.bearer` → `await tokenStore.validAccessToken(refresh:)`. Add `nativeTokenExchange`
  and `nativeRefresh` endpoints, plus `logout(connection)` (best-effort).
- `HermesGatewayClient`: widen `mintTicket` to `(baseURL, AuthSession) async throws -> String`
  (cookie branch unchanged; bearer branch: `validAccessToken` → mint with
  `Authorization: Bearer`); add a `.bearer` case to `connect` mirroring the cookie branch
  (async setup task, same cancellation/termination handling, `authExpired` → `.authExpired`
  event).
- `KeychainClient.saveSession/loadSession` need no change (JSON round-trip of the enum);
  `loadSession` skips cookie rehydration for `.bearer`.

### Reducers

- `ConnectionFeature`: `capability` becomes the struct; `isPasswordEnabled`/`isOAuthEnabled`
  /`isTokenDeemphasized` computed off it; preselect password → oauth → token; `.oauth`
  connect: `oauthLogin.signIn(url, provider)` → seed token store → validate with
  `rest.sessions(connection, 1, 0, .recent)` → `keychain.saveSession(.bearer(...))` +
  `preferences.saveServerURL` → `.delegate(.connected)`. New action
  `oauthLoginResponse(Result<ServerConnection, OAuthFlowError>)` where `.cancelled` returns
  to `.reachable` silently and everything else → `.failed(message)` / `.invalidCredentials`
  on a 401 from the validating call.
- `ReauthFeature`: `method == .oauth` → one `continueTapped`-style path reusing `signInTapped`;
  `previousUserID` seeded from the dead `BearerSession.userID`; `sameUser =
  isSameUser(previousUserID, fresh.userID)`. `canSubmit` is `status != .validating` for
  `.oauth`.
- `AppFeature`: launch restore seeds the token store when the loaded session is `.bearer`
  (BEFORE the probe); `makeReauthState` gains the `.bearer` case; all three logout paths call
  `tokenStore.clear()` + best-effort `rest.logout` alongside `keychain.deleteSession()`;
  reauth success with a `.bearer` connection reseeds before `.resumeAfterReauth` / home
  rebuild.

### Processing flow (happy path)

1. User types URL → `/api/status` + `/api/auth/providers` → capability
   `{password: basic?, oauth: [nous], native: true}` → segments Password | Token | Nous Research.
2. User picks the OAuth segment → "Continue with Nous Research" → listener binds → Safari
   sheet opens `/auth/native/authorize` → portal login → gateway redirects the sheet to
   `http://127.0.0.1:<port>/callback?code=…&state=…` → listener answers, app cancels sheet →
   `POST /auth/native/token` → `BearerSession`.
3. Seed `BearerTokenStore` → `GET /api/sessions?limit=1` with `Authorization: Bearer` →
   persist `.bearer` in Keychain + server URL → `.connected` → sessions list.
4. Chat open → `connect(.bearer)` → `validAccessToken()` (refresh if < 120 s left) →
   `POST /api/auth/ws-ticket` with bearer → `…/api/ws?ticket=` (unchanged).
5. Days later the RT dies → refresh 401 → `authExpired` → `ChatFeature.sessionExpired` →
   `ReauthFeature(.oauth)` → one button → same flow → reseed → resume in place.

## Implementation Steps

### Task 1: Spike — loopback callback from `ASWebAuthenticationSession`

**Files:**
- Create: `Probe/LoopbackSpike/` (throwaway; `Probe/` is gitignored fixtures — keep the
  spike out of the shipped targets)
- Create: `docs/features/oauth-sign-in.md` (spike outcome section only, filled further in
  Task 15)

- [ ] build a minimal iOS harness (SwiftUI button) that binds an `NWListener` on 127.0.0.1
      ephemeral port, responds to any HTTP request with a tiny HTML page, and opens
      `ASWebAuthenticationSession` (`prefersEphemeralWebBrowserSession = false`,
      `callbackURLScheme: nil`) on a public URL that redirects to
      `http://127.0.0.1:<port>/callback?code=x&state=y` (e.g. a local Python
      `http.server` handler or the real gateway's `/auth/native/authorize`)
- [ ] verify on the iOS 18 simulator AND a physical device that the listener receives the
      request, the page renders, and `session.cancel()` dismisses the sheet with
      `ASWebAuthenticationSessionError.canceledLogin` delivered to the completion handler
- [ ] verify no Local Network permission prompt appears and ATS does not block the
      `http://127.0.0.1` navigation inside the Safari view
- [ ] verify against the REAL gateway (Tailscale-bound, `nous` provider configured) that
      `/auth/native/authorize` accepts the `127.0.0.1:<port>` redirect and the token exchange
      returns the payload shape documented above
- [ ] record the outcome (works / needs the `WKWebView` browser-leg fallback), iOS versions
      tested, and any quirks (e.g. IPv4 vs IPv6 literal, favicon probes) in
      `docs/features/oauth-sign-in.md` → "Spike outcome"
- [ ] ⚠️ if the loopback leg FAILS: amend Tasks 6 and 7 in this plan to use a `WKWebView`
      sheet for the browser leg (same PKCE/token model) before continuing

### Task 2: `BearerSession` model and `AuthSession.bearer`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/AuthSession.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (`ServerConnection` doc
  comment only)
- Modify: `HermesKit/Tests/HermesKitTests/AuthSessionTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/KeychainClientTests.swift`

- [ ] add `BearerSession` (`accessToken`, `refreshToken`, `expiresAt: Double`, `provider`,
      `userID`) with a public init, `Codable` keys `access_token`/`refresh_token`/
      `expires_at`/`provider`/`user_id`, and a lenient `init(tokenResponse: Data)` that
      accepts `expires_at` as Int or Double and throws on a missing/empty `access_token`
- [ ] add `case bearer(BearerSession)` to `AuthSession`; `token` returns `nil` for it; fix
      every exhaustive `switch` the compiler flags (`KeychainClient.rehydrate`,
      `AppFeature.makeReauthState`, gateway `connect`) with a minimal placeholder that keeps
      behaviour identical until later tasks (`.bearer` → treated like `.cookie` where a
      branch is required; note ➕ in this plan if any new site appears)
- [ ] write tests: `BearerSession` JSON round-trip through `AuthSession` encoding, token
      response decode (Int and Double `expires_at`, missing `access_token` throws,
      unknown extra fields ignored), and `AuthSession.token == nil` for `.bearer`
- [ ] write tests: `KeychainClient.inMemory()` and `.live` save/load round-trip a `.bearer`
      session and `deleteSession` removes it
- [ ] run tests — must pass before Task 3

### Task 3: Capability struct with OAuth providers and native-flow flag

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift` (`ServerStatus.authFlows`)
- Modify: `HermesKit/Sources/HermesKit/Models/ServerAuthCapability.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift` (compile-only adaptation)
- Modify: `HermesKit/Tests/HermesKitTests/ServerAuthCapabilityTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ConnectionFeatureTests.swift` (capability literals)
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [ ] add lenient `authFlows: [String]?` (`auth_flows`) to `ServerStatus`
- [ ] replace the `ServerAuthCapability` enum with the struct (`passwordProvider`,
      `oauthProviders`, `supportsNativeFlow`, `isGated`, `isPasswordAvailable`,
      `isOAuthAvailable`, `passwordProviderName`, `static tokenOnly`); keep the
      `init(from:providers:)` signature and every older-server fallback
- [ ] adapt `ConnectionFeature.State` computed properties (`isPasswordEnabled`,
      `isTokenDeemphasized`, preselect switch) to the struct WITHOUT adding OAuth behaviour
      yet (that is Task 8), so this task is a pure refactor with identical UI
- [ ] write tests (table-driven): auth not required → token only; gated + basic → password;
      gated + nous only → OAuth list populated, password nil; gated + basic + nous → both;
      `native_pkce` present/absent/`auth_flows` missing → `supportsNativeFlow`; providers
      nil/empty → token only; `isOAuthAvailable` false when providers exist but no native flow
- [ ] write tests: `ServerStatus` decodes `auth_flows` and tolerates its absence
- [ ] update existing `ConnectionFeatureTests` literals (`.tokenOnly`, `.passwordAvailable`)
      to the struct equivalents; run tests — must pass before Task 4

### Task 4: Pure native-OAuth helpers (PKCE, URLs, callback parsing)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/NativeOAuth.swift`
- Create: `HermesKit/Tests/HermesKitTests/NativeOAuthTests.swift`

- [ ] implement `PKCEPair.generate(random:)` (S256 via CryptoKit, base64url no-pad, 43-char
      verifier) and `generateState(random:)` with an injectable random source
- [ ] implement `nativeAuthorizeURL(base:challenge:redirectURI:state:provider:)`,
      `nativeTokenURL(base:)`, `nativeRefreshURL(base:)` preserving any base path prefix and
      omitting `provider` when nil
- [ ] implement `parseLoopbackCallback(requestTarget:expectedState:) throws -> String` and
      `OAuthLoginError` (`cancelled`, `timedOut`, `stateMismatch`, `gatewayRejected(String)`,
      `listenerFailed`, `tokenExchange(RESTError)`) with user-facing `message`
- [ ] write tests: PKCE against the RFC 7636 appendix B vector (fixed random →
      known verifier/challenge), verifier length/charset, state length; URL builders with and
      without a path prefix and provider; callback parsing success, `error` param, missing
      code, state mismatch (must throw before returning a code), non-callback targets (favicon)
      rejected as "not a callback"
- [ ] run tests — must pass before Task 5

### Task 5: `BearerTokenStore` actor and refresh semantics

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/BearerTokenStore.swift`
- Create: `HermesKit/Tests/HermesKitTests/BearerTokenStoreTests.swift`

- [ ] implement `bearerNeedsRefresh(_:now:leeway:)` (pure) and the `BearerTokenStore` actor
      per Technical Details: `seed`, `clear`, `current`, `validAccessToken(refresh:)` with a
      single shared in-flight `Task`, persistence hook invoked inside the actor before the
      new token is published
- [ ] map failures: refresh throws `RESTError.unauthorized` → `clear()` + throw
      `GatewayError.authExpired`; any other error → rethrow, tokens intact; a persist failure
      is reported (`reportIssue`) but does not lose the rotated pair in memory
- [ ] add the `\.bearerTokens` dependency key (`liveValue = BearerTokenStore.shared`,
      `testValue` a fresh instance)
- [ ] write tests: fresh token returned without refresh; near-expiry triggers exactly ONE
      refresh with 10 concurrent callers awaiting a slow fake refresh (all receive the same
      new token, persist called once, refresh body carries the OLD refresh token); expired +
      401 → store cleared + `authExpired`; expired + 503 → rethrown, `current` unchanged;
      `seed` during an in-flight refresh cancels/ignores the stale result; `clear` then
      `validAccessToken` throws `authExpired`
- [ ] write tests: `bearerNeedsRefresh` at fixed dates around the leeway boundary
- [ ] run tests — must pass before Task 6

### Task 6: REST client bearer authentication, token exchange, refresh, logout

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/NativeOAuthClientTests.swift`

- [ ] introduce `RequestAuth` (`.none | .sessionToken(String) | .bearer(String)`) and thread
      it through `get/postJSON/send` and the upload/download helpers; `.token` connections
      map to `.sessionToken` (header byte-identical), `.cookie` to `.none`
- [ ] add `resolveAuth(for connection:)` that, for `.bearer`, awaits
      `tokenStore.validAccessToken(refresh:)` using the new `nativeRefresh` transport;
      surface `GatewayError.authExpired` as `RESTError.unauthorized` so existing
      `asRESTError` routing (401 → re-auth) holds
- [ ] add endpoints `nativeTokenExchange(baseURL, code, verifier) -> BearerSession` (15 s
      timeout, 400 → `RESTError.server(400, detail)`), `nativeRefresh(baseURL, session) ->
      BearerSession` (401 → `.unauthorized`, 503 → `.serviceUnavailable`), and
      `logout(connection)` (`POST /auth/logout`, best-effort, errors swallowed AND logged —
      the one deliberate exception to "never swallow", documented inline)
- [ ] write tests over `MockURLProtocol`: `.token` request header unchanged (regression
      guard: exact header name/value, no `Authorization`); `.bearer` sends
      `Authorization: Bearer <token>` and no session-token header; a near-expiry bearer
      triggers ONE refresh POST before the API call with body `{refresh_token, provider}`;
      refresh 401 → `.unauthorized` and store cleared; token exchange success decode + 400
      mapping; refresh 503 mapping; logout swallows a 500
- [ ] run tests — must pass before Task 7

### Task 7: `OAuthLoginClient` (loopback listener + `ASWebAuthenticationSession`)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/OAuthLoginClient.swift`
- Create: `HermesKit/Sources/HermesKit/Clients/LoopbackCallbackListener.swift`
- Create: `HermesKit/Tests/HermesKitTests/OAuthLoginClientTests.swift`

- [ ] define the `@DependencyClient` (`signIn(baseURL, provider) -> BearerSession`),
      `testValue` (unimplemented default), `previewValue` returning a fixture, and the
      `\.oauthLogin` key
- [ ] implement `LoopbackCallbackListener` with Network.framework: bind 127.0.0.1 ephemeral
      port, expose `redirectURI`, answer every request with the minimal HTML page, deliver the
      first callback target via an `AsyncThrowingStream`/continuation, `stop()` idempotent.
      Keep the HTTP request-line parsing pure (`parseRequestTarget(_ bytes:)`) OUTSIDE the
      UIKit guard
- [ ] implement the live `signIn` under `#if canImport(UIKit)`: PKCE + state → listener →
      `ASWebAuthenticationSession` (shared browser session, key-window presentation context
      provider) → race {callback, session cancel, 300 s timeout} → cancel session + stop
      listener → `rest.nativeTokenExchange`; map cancel-before-callback to
      `OAuthLoginError.cancelled`; non-iOS `liveValue = testValue`
- [ ] write tests (macOS-runnable): request-target parsing (GET line, query, favicon,
      malformed); the listener binds on 127.0.0.1 and serves the HTML to a raw `URLSession`
      request while delivering the target once; second request after settle is answered but
      ignored; `stop()` twice is safe
- [ ] write a test for the orchestration seam by extracting `runNativeLogin(deps:)` with
      injected `openBrowser`/`listenerFactory`/`exchange`/`clock` (mirrors the desktop's
      injected driver): success, gateway `error` param, state mismatch, timeout, cancel
- [ ] run tests — must pass before Task 8

### Task 8: `ConnectionFeature` OAuth segment and connect path

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ConnectionFeatureTests.swift`

- [ ] add `AuthMethod.oauth`; `isOAuthEnabled` (capability `isOAuthAvailable`, `nil` → false
      — a NEW affordance needs positive evidence), `oauthProviders` passthrough for the view,
      preselect order password → oauth → token, `canConnect` true for `.oauth` whenever
      `.reachable`
- [ ] add `connectTapped` `.oauth` branch: `oauthLogin.signIn(url, provider.name)` → seed
      `bearerTokens` with a Keychain persist hook → `rest.sessions(connection, 1, 0, .recent)`
      → `keychain.saveSession(.bearer)` + `preferences.saveServerURL` →
      `oauthLoginResponse(.success)` → `.delegate(.connected)`
- [ ] add `oauthLoginResponse(.failure)`: `.cancelled` → back to `.reachable(version)`
      silently; validating-call 401 → `.invalidCredentials`; everything else →
      `.failed(message)`; clear the seeded store on any failure
- [ ] write `TestStore` tests: gated nous-only server preselects `.oauth` and enables the
      segment; mixed basic+nous preselects `.password` with OAuth enabled; providers present
      but no `native_pkce` → OAuth disabled; OAuth connect success persists `.bearer` +
      URL and emits `.connected`; cancel returns to `.reachable` with no status text; gateway
      rejection → `.failed`; validating 401 → `.invalidCredentials` and store cleared
- [ ] run tests — must pass before Task 9

### Task 9: `ConnectionView` third segment

**Files:**
- Modify: `HermesMobile/Sources/Features/ConnectionView.swift`
- Modify: `HermesMobileTests/AuthSnapshotTests.swift`

- [ ] add the third `Picker` segment tagged `.oauth`, labelled with the single provider's
      `displayName` (or "OAuth" when several), shown only when `isOAuthEnabled`; keep the
      existing disabled-state rules for Password
- [ ] render the `.oauth` content: one `Button("Continue with <displayName>")` per provider
      (plain text, default tint — no logos/brand colours), a footnote "Opens your identity
      provider in Safari. Nothing is stored until sign-in completes.", and reuse the
      `.validating` spinner state; the primary Connect button is hidden for this segment
      (the provider button IS the connect action)
- [ ] `methodHint` footer copy for the OAuth segment and for "providers exist but this
      gateway is too old for native sign-in" (OAuth segment hidden, token-only hint amended)
- [ ] add snapshot tests: OAuth segment idle (light + dark), OAuth segment with two
      providers, mixed server showing three segments; run `make snapshot` twice per the
      record-then-assert recipe
- [ ] run `swift test` + the new snapshots — must pass before Task 10

### Task 10: Gateway client bearer connect and ticket mint

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesGatewayClientTests.swift`

- [ ] widen `mintTicket` to `(URL, AuthSession) async throws -> String`; cookie branch calls
      the existing `wsTicket(baseURL:cookieSession:session:)` unchanged; bearer branch awaits
      `BearerTokenStore.shared.validAccessToken(refresh:)` then POSTs `/api/auth/ws-ticket`
      with `Authorization: Bearer`; 401 → `authExpired`, other → `ticketUnavailable`
- [ ] add the `.bearer` case to `connect` mirroring the `.cookie` setup task
      (cancellation check before `open`, `authExpired` → yield `.authExpired` + finish,
      transient → finish, composed `onTermination`)
- [ ] `.token` branch untouched — add an inline comment that the bearer path must never
      touch it
- [ ] write tests with the fake transport + injected `mintTicket`: `.bearer` connect mints
      then opens `?ticket=`; mint `authExpired` yields `.authExpired` and finishes; mint
      transient finishes without events; consumer cancel during mint opens nothing; `.token`
      connect still opens `?token=` synchronously with no mint call
- [ ] write a `MockURLProtocol` test for the bearer `wsTicket` request headers and the
      refresh-before-mint ordering
- [ ] run tests — must pass before Task 11

### Task 11: `ReauthFeature` OAuth method

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ReauthFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ReauthFeatureTests.swift`

- [ ] add `previousUserID` and `providerDisplayName` to `State`; `canSubmit` for `.oauth`
      is `status != .validating`
- [ ] add the `.oauth` `signInTapped` branch: `oauthLogin.signIn(url, provider)` → seed store
      → validate with `rest.sessions` → `keychain.saveSession(.bearer)` → `sameUser =
      isSameUser(previousUserID, fresh.userID)` → `reauthResponse(.success)`
- [ ] map `.cancelled` to `.idle` silently; validating 401 → `.invalidCredentials` (copy:
      "Sign-in was rejected by the server."); else `.failed(message)`
- [ ] write `TestStore` tests: same user → `reauthenticated(sameUser: true)`; different
      `user_id` → `sameUser: false`; cancel → `.idle`, no delegate; gateway rejection →
      `.failed`; validating 401 → `.invalidCredentials`
- [ ] run tests — must pass before Task 12

### Task 12: `ReauthView` OAuth variant

**Files:**
- Modify: `HermesMobile/Sources/Features/ReauthView.swift`
- Modify: `HermesMobileTests/AuthSnapshotTests.swift`

- [ ] render the `.oauth` case: no fields, one `Button("Continue with <providerDisplayName>")`
      (the "Sign in" button is replaced, not duplicated), same status footer; keep "Quit to
      start"
- [ ] `invalidCredentials` footer copy branches on `.oauth`
- [ ] add snapshot tests `testReauthSheet_oauth` (light + dark) via the record-then-assert
      recipe
- [ ] run snapshots + `swift test` — must pass before Task 13

### Task 13: `AppFeature` restore, reauth routing, and logout for the bearer regime

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [ ] launch restore: when `keychain.loadSession` yields `.bearer`, seed `bearerTokens`
      (persist hook = `keychain.saveSession(.bearer(_:))`) BEFORE the `rest.sessions` probe;
      a refresh 401 during the probe surfaces as `.unauthorized` and follows the existing
      401/403 → prefilled-onboarding rule (#62) unchanged
- [ ] `makeReauthState` `.bearer` case → `ReauthFeature.State(method: .oauth, provider:,
      providerDisplayName:, previousUserID:)`; look the display name up from the last probed
      providers if available, else fall back to the provider name
- [ ] reauth success with a `.bearer` connection reseeds the store before
      `.resumeAfterReauth` / `makeHomeState`
- [ ] every logout path (`connectionFailed.logoutConfirmed`, `reauth.quit`, `.disconnect`)
      calls `bearerTokens.clear()` and fires best-effort `rest.logout(connection)` alongside
      `keychain.deleteSession()`; token-mode and cookie-mode logout requests remain unchanged
      (logout only fires for `.bearer`)
- [ ] write `TestStore` tests: launch with a stored `.bearer` seeds the store and probes with
      it; probe 401 → onboarding prefilled and store cleared; `.sessionExpired` on a bearer
      chat raises `ReauthFeature(.oauth)` with the previous `user_id`; same-user reauth
      reseeds and resumes; different-user reauth clears identity prefs; logout clears store +
      Keychain and posts `/auth/logout` exactly once
- [ ] run tests — must pass before Task 14

### Task 14: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented: OAuth-only gateway is
      sign-in-able; mixed basic+nous shows three segments with password preselected; older
      gateway (no `auth_flows` / providers 404) renders exactly today's UI; token mode
      requests are byte-identical (header regression tests green)
- [ ] verify edge cases: user dismisses the Safari sheet (silent); gateway `error` on
      callback; state mismatch never redeems; 120 s code TTL exceeded → `.failed` with server
      copy; refresh 503 keeps tokens and the chat reconnects via backoff; refresh 401 raises
      re-auth once (no loop); two concurrent requests at expiry perform one refresh
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run snapshots: `make snapshot` — new tests clean; pre-existing drift judged by
      render-size rule
- [ ] `tuist generate` + `xcodebuild` app build succeeds (new source files are globbed)
- [ ] manual pass against the real gateway on device: sign in, open a chat, background >
      access-token lifetime, foreground → reconnect refreshes; revoke the dashboard in the
      portal → re-auth sheet appears once

### Task 15: [Final] Update documentation

- [ ] complete `docs/features/oauth-sign-in.md`: protocol summary, the three regimes, the
      actor invariant, capability gate, spike outcome, known limitations (no WKWebView
      fallback; gateway must advertise `native_pkce`; loopback-only redirect)
- [ ] update `docs/architecture.md` → "Auth regimes" (third regime, `RequestAuth`,
      `BearerTokenStore`, refresh semantics) and the component list (`OAuthLoginClient`)
- [ ] update `CLAUDE.md`: auth bullet gains the bearer regime + "all bearer reads go through
      `BearerTokenStore.validAccessToken()`" rule + `native_pkce` gate; add the feature doc
      to the "Per-feature invariants" pointer list
- [ ] update `README.md` feature overview (OAuth sign-in) and the setup guide/README
      quick-start ONLY if operator commands change (they shouldn't — `hermes dashboard
      register` is server-side); keep sheet and README verbatim-identical
- [ ] update GitHub issue #19 with the native-flow findings and close it on merge
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification**
- Sign in on a physical device against a Tailscale-bound gateway with the `nous` provider;
  repeat with `self_hosted` OIDC if available (Keycloak/Authentik) to confirm the flow is
  provider-agnostic.
- Passkey / already-signed-in portal session: the Safari sheet should complete without
  re-entering credentials (shared browser session).
- Accessibility: VoiceOver reads the provider button label and the status footer; Dynamic
  Type at accessibility sizes keeps the three-segment picker legible (falls back to the
  iOS menu-style picker if it overflows).
- App Store review notes: state that OAuth requires a self-hosted gateway and that Password
  and Token remain reviewable paths; demo mode unchanged.

**External system updates**
- None required in the gateway or the push plugin. If the upstream project later accepts a
  private-use URI scheme redirect (RFC 8252 §7.1), the loopback listener can be removed and
  `ASWebAuthenticationSession(callbackURLScheme:)` used directly — a follow-up, not part of
  this plan.
- TestFlight build after merge; the `.bearer` Keychain payload is a new shape, so a
  downgrade to a build without it would fail to decode the session and land on onboarding
  (acceptable; note in What to Test).
