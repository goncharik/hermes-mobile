# OAuth sign-in (native PKCE) (#19)

The short rules live in `CLAUDE.md` → "Gateway & session lifecycle"; the regime summary is in
`docs/architecture.md` → "Auth regimes". This doc is the full contract. Design history:
`docs/plans/completed/`.

A third sign-in method beside Password and Token, using the RFC 8252 native-app flow the
Hermes gateway already exposes for the desktop (`/auth/native/authorize|token|refresh`). The
browser leg runs in an `ASWebAuthenticationSession`; the app holds bearer tokens it refreshes
itself, and no web view ever sees a token.

Issue #19 predates the native flow and assumed a cookie-harvesting `WKWebView`. That framing
is superseded — the gateway hands out tokens, so the app never scrapes cookies out of a web
view.

## The three auth regimes

`AuthSession` is the one place a regime is named; everything downstream adapts transport off
it instead of scattering regime checks.

| Regime | REST auth | WS auth | Refresh |
| --- | --- | --- | --- |
| `.token(String)` | `X-Hermes-Session-Token` | `?token=` (opened synchronously) | never expires |
| `.cookie(CookieSession)` | URLSession cookie jar | per-connect `?ticket=` mint | transparent, server-side |
| `.bearer(BearerSession)` | `Authorization: Bearer` | per-connect `?ticket=` mint | explicit, client-side |

```swift
public struct BearerSession: Equatable, Sendable, Codable {
  public var accessToken: String
  public var refreshToken: String
  public var expiresAt: Double   // unix seconds, the server's `expires_at`
  public var provider: String
  public var userID: String
}
```

`ServerConnection.token` stays `nil` for `.bearer` exactly as it does for `.cookie`, so **token
mode is byte-identical to the legacy single-token client** — the backward-compat guard that
predates this feature is untouched, and pinned by `tokenModeSendsOnlyTheSessionTokenHeader` /
`tokenModeBuildsByteIdenticalWSURL`.

The `.bearer` payload is a NEW Keychain shape. A downgrade to a build without it fails to
decode the stored session and lands on onboarding — accepted.

## Protocol summary

Verified against upstream Hermes `main` (2026-09-05), mirroring the desktop's
`apps/desktop/electron/native-oauth*.ts` rather than inventing a client.

- `GET /api/status` (public) carries `auth_flows`. Gated servers list `"cookie"`, plus
  `"native_pkce"` when an interactive session provider is registered. Absent on older
  gateways.
- `GET /api/auth/providers` → `[{name, display_name, supports_password}]`. `basic` is the
  password provider; `nous` / `self_hosted` are the OAuth ones. **Display names come from the
  server** — the app never hard-codes a provider label.
- `GET /auth/native/authorize?provider=&code_challenge=&code_challenge_method=S256&redirect_uri=&state=`
  — an empty `provider` lets the gateway auto-select its single non-password provider. A
  password provider is redirected to the `/login` form instead, so we never send one.
- `redirect_uri` MUST be loopback (`http://127.0.0.1[:port]/…` or `http://[::1][:port]/…`).
  `localhost` and custom schemes are rejected with a 400 by
  `_validate_loopback_redirect_uri`. Pending authorization TTL 600 s, issued code TTL 120 s.
- `POST /auth/native/token {code, code_verifier}` →
  `{access_token, refresh_token, token_type, expires_at, provider, user_id}`. Every failure is
  a generic 400, surfaced verbatim as `RESTError.server(status: 400, detail:)`.
- `POST /auth/native/refresh {refresh_token, provider}` → the same payload. `401` means every
  provider rejected the refresh token (session dead); `503` means a provider is unreachable
  (keep the tokens, retry). An empty stored `provider` is **omitted** rather than sent as
  `""`, so a partial payload lets the gateway try every provider.
- The gate middleware accepts `Authorization: Bearer <access_token>` on every `/api/*` route
  including `POST /api/auth/ws-ticket`. **There is no server-side refresh on the bearer path**
  — unlike the cookie regime, the client owns rotation.
- `POST /auth/logout` is a courtesy call; with a bearer it is close to a no-op and we still
  fire it.

## The capability gate

`ServerAuthCapability` is a struct (it used to be a three-case enum), built by one pure mapper
over `/api/status` + `/api/auth/providers`:

```swift
passwordProvider: AuthProvider?   // first supports_password == true
oauthProviders:   [AuthProvider]  // supports_password == false, in server order
supportsNativeFlow: Bool          // auth_flows contains "native_pkce"
isGated: Bool                     // gated AND advertising providers
```

Two rules carry the weight:

- **`isOAuthAvailable` needs BOTH halves** — an OAuth provider *and* `native_pkce`. A gateway
  that lists `nous` but doesn't advertise the flow is too old to serve
  `/auth/native/authorize`, so the segment stays hidden. This is the project's usual
  gate-by-capability idiom inverted on purpose: `?? true` is right for a field that describes
  an *existing* affordance, but a NEW one appears only on positive evidence (the desktop
  does the same).
- **`isGated` is NOT a bare `authRequired == true`.** A gated server whose providers endpoint
  404s (or answers `[]`) still maps to `.tokenOnly`, because token is then the user's only way
  in and must not be nudged away from. Defining `isGated` off the raw flag would have flipped
  `isTokenDeemphasized` on and changed the footer copy for those servers. Guarded by
  `gatedServerWithNoProvidersKeepsTokenUndeemphasized`.

Older gateways (no `auth_flows`, providers 404) therefore render **exactly** today's UI.

### The Password segment is omitted, not disabled

The pre-existing rule expressed "you may not pick Password" by disabling the WHOLE segmented
control — SwiftUI cannot disable one segment. With a third segment that becomes a trap: on a
gated OAuth-only server the user lands on `.oauth`, taps Token, and the control locks with no
way back to the provider. So the `.disabled` condition gained `&& !isOAuthEnabled`
(byte-identical for every server without OAuth) and the Password segment is dropped from the
picker in exactly the case the lock no longer covers.

Segment order and preselection: **password → oauth → token**. The OAuth segment renders one
`Button("Continue with <displayName>")` per provider — plain text, default tint, **no logos and
no brand colours** (App Store guideline 5.2.1: shipping a provider's mark is a trademark claim
we have no licence for). The provider button IS the connect action, so the primary Connect
button is hidden for that segment. Its footnote reads "Opens your identity provider in Safari.
Nothing is stored until sign-in completes." The reauth sheet deliberately omits that footnote:
a user who reaches it has already completed this browser leg at least once.

**`canConnect` has a `.failed where method == .oauth` arm.** Password and Token reach `.failed`
only on wait-it-out verdicts and each has a field whose edit is the obvious next move; the
OAuth segment has nothing to type, so without the arm a failed sign-in disabled the provider
button permanently under a footer that said "Try again." A failed *probe* still blocks
everything (it nils `capability`, so `isOAuthEnabled` is false). Pinned by
`onlyTheOAuthSegmentRetriesFromAFailedStatus`.

## Sign-in flow

`OAuthLoginClient.signIn(baseURL, provider)` is one call, one sign-in — every transport- and
UI-shaped step lives behind it so `ConnectionFeature`/`ReauthFeature` stay pure reducers.

1. `PKCEPair.generate()` (32 random bytes → 43-char base64url verifier; challenge =
   base64url(SHA256(ascii(verifier))), method `S256`) and `generateOAuthState()`.
2. `LoopbackCallbackListener` binds an `NWListener` on **IPv4 `127.0.0.1`**, ephemeral port,
   and advertises `http://127.0.0.1:<port>/callback` as the `redirect_uri`.
3. `ASWebAuthenticationSession` (`callbackURLScheme: nil`,
   `prefersEphemeralWebBrowserSession = false` so portal cookies and passkeys are shared)
   opens `/auth/native/authorize`.
4. The gateway redirects the sheet to the loopback URL. The listener answers *every* request
   with a small "Signed in to Hermes — you can close this window" page and publishes the
   request target.
5. The driver settles on the first target `isLoopbackCallback` accepts, verifies `state`,
   cancels the sheet, stops the listener, and calls `rest.nativeTokenExchange` (15 s).
6. The caller seeds `BearerTokenStore` **without a Keychain hook**, validates with
   `GET /api/sessions?limit=1`, and only then arms persistence (`attachPersistence`, which
   writes the pair the store holds — a rotation during the validating call included) and saves
   the server URL in prefs. An unproven pair never reaches disk, so a sign-in that fails at
   validation leaves nothing restorable behind.

Budgets: **300 s** for the whole browser leg (the gateway's pending authorization expires at
600 s, so ours always fires first) and **15 s** for the token exchange.

### `runNativeLogin` and the three-way race

The orchestration is extracted behind an injected `NativeLoginDriver`
(`makePKCE`/`makeState`/`startListener`/`openBrowser`/`exchange`/`clock`/`timeout`), mirroring
the desktop's injected driver, so the whole flow is testable on macOS without a browser. It
races three legs: the callback, the browser outcome, and the timeout.

- **`OAuthBrowserOutcome` has no success case** — `.cancelledByUser | .dismissed |
  .failed(reason)`. With `callbackURLScheme: nil` the session can never match a callback
  itself; it only ever reports how the sheet went away. That is the spike finding turned into
  a type.
- **`openBrowser` must be cancellation-safe.** A task group awaits its children at scope exit,
  so a browser leg parked on a continuation that never fires would hang the flow *after* the
  callback already won. The live implementation wraps presentation in
  `withTaskCancellationHandler` and dismisses + resumes on cancel.
- **The listener is not behind the UIKit guard.** `Network` builds on macOS, so
  `LoopbackCallbackListener` is exercised for real by `swift test` — the socket tests bind an
  ephemeral loopback port and drive it with `URLSession`. Only `ASWebAuthenticationSession` is
  iOS-only.
- **`isLoopbackCallback` is a separate predicate from `parseLoopbackCallback`.** The parser
  must treat a missing `code` as `.gatewayRejected` (the gateway answered wrong), while a
  blank or parameter-less target — a speculative zero-byte connection, a favicon probe — must
  be "not a callback" and NOT an error. Collapsing both into a `String?` would have merged the
  two verdicts. The listener stays a dumb HTTP responder; the driver decides what settles.
- The listener's stream is **non-throwing and finishes** when the socket dies, which the
  driver reads as `.listenerFailed` instead of sitting out the full 300 s budget.

## The `BearerTokenStore` invariant

**The store is the single owner of the token pair and the only refresh path.** Every REST call
and every WS ticket mint asks it for a token via `validAccessToken(refresh:)`; nothing else
reads the Keychain or inspects `expiresAt`. Three reasons it is a dedicated type:

1. **Single-flight refresh.** The portal runs refresh-token **reuse detection**: two concurrent
   refreshes with the same refresh token revoke the whole session and sign the user out.
   Concurrent callers at expiry join ONE in-flight `Task`. Guarded by
   `concurrentCallersAtExpiryShareExactlyOneRefresh`, whose assertion is taken *while* the fake
   refresh is still parked, so a broken join cannot hide behind timing.
2. **Persist before publish.** The rotated pair is written through the `persist` hook from
   inside the store BEFORE any caller sees the new token, so a crash between "server rotated"
   and "app saved" can't strand the app holding a retired refresh token. A persist failure is
   `reportIssue`d but never drops the in-memory pair — losing it would trip reuse detection on
   relaunch.
3. **One expiry verdict.** A refresh 401 clears the store and throws `GatewayError.authExpired`
   → the existing `.sessionExpired` → `ReauthFeature` route. **Anything else (503, transport)
   rethrows with the tokens intact** so ordinary reconnect backoff can retry.

`refreshLeeway` is 120 s and the boundary is strict: exactly `leeway` seconds left is still
fresh. A missing or zero `expires_at` counts as needing a refresh — one wasted round trip
beats a 401 storm.

**A superseded rotation returns the CURRENT session rather than throwing.** `seed`/`clear` bump
a generation counter; a refresh completing under an older generation never persists or
publishes its pair — doing so would resurrect credentials the app deliberately moved off (a
different account, or a logout). Callers parked on it get whatever is live: the freshly seeded
token after a `seed`, `authExpired` after a `clear`. Throwing `CancellationError` at them would
have manufactured a failure at the moment the app holds a perfectly good token.

**One synchronization domain.** Every mutable field the store owns — pair, server, persist
hook, ownership, in-flight refresh handle, generation — lives behind ONE lock, and every entry
point takes its verdict, its mutations and its write-through in a SINGLE critical section, so a
concurrent `detachPersistence()`/`clear()`/newer claim cannot land between a check and the
mutation it approved. That is why the type is a `Sendable` class rather than an actor: with no
isolation domain of its own it cannot hold mutable state outside the lock, which is the thing
that kept regressing while ownership sat in a lock and the pair sat in actor storage. The
normative statement, and the two disciplines it needs (never `await` under the lock; never run
re-entrant caller code — including `Task.cancel()` — under it), live on the type.

`BearerTokenStore.shared` is the process-wide instance the live REST and gateway clients share
— the "single owner" invariant is only true if there is one store. It is exposed as
`\.bearerTokens` so reducers and tests inject their own, and `testValue` is a fresh empty
store, never the shared one.

## Transport wiring

- **`RequestAuth` (`.none | .sessionToken | .bearer`) is the one place either auth header is
  written.** `resolveAuth(for:session:tokenStore:)` maps `.token` → `.sessionToken`, `.cookie`
  → `.none` (the jar carries it), `.bearer` → `await tokenStore.validAccessToken(refresh:)`,
  translating `GatewayError.authExpired` into `RESTError.unauthorized` so the existing 401
  routing holds unchanged.
- **`HermesProfileClient` shares it.** It reuses `HermesRESTClient`'s transport helpers by
  design, and `conn.token` is `nil` for `.bearer` — leaving it on the old parameter would have
  sent every profile call unauthenticated.
- **The refresh 503 is mapped explicitly, not through `validate`'s `loginSpecific` flag.** That
  flag also remaps 429 to "Too many login attempts", which is password-login copy and wrong
  mid-session.
- **`rest.logout` is THE deliberate exception to "never swallow RPC failures."** By the time it
  fires the app has discarded its own credentials and is on its way to the login screen, so a
  failure changes nothing the user could see or act on. It is logged, never surfaced, and the
  closure is non-throwing so no call site can depend on the result.
- **Gateway: `.cookie` and `.bearer` SHARE the connect branch** (`case .cookie, .bearer:`).
  Once `mintTicket` takes the whole `AuthSession`, the two gated regimes differ ONLY inside the
  minter (cookie jar vs `Authorization: Bearer`); the setup task, the `Task.checkCancellation()`
  between mint and `open()`, the `authExpired`/transient split, and the composed
  `onTermination` are the same code. A copied branch would be a copy of the app's subtlest
  cancellation choreography — i.e. a copy that can drift. Every cookie test has a `bearerMode…`
  twin. `.token` still opens `?token=` synchronously and never touches the minter.

### Ordering contract

**`rest.logout` and `rest.unregisterPush` both resolve auth through the store, so both MUST
fire BEFORE `bearerTokens.clear()`.** A drained store makes either request a silent no-op —
which for the unregister means this device quietly keeps receiving pushes for an account it
just left. All three logout paths (`connectionFailed.logoutConfirmed`, `reauth.quit`,
`.disconnect`) share one `serverSideLogout(connection:)` helper that **concatenates** unregister
→ logout → drain. Non-bearer connections return the unregister effect unchanged, so token and
cookie logout requests stay byte-identical (`tokenAndCookieLogoutSendNoLogoutRequest` asserts
`/auth/logout` fires zero times for both).

**Every logout path calls `BearerTokenStore.detachPersistence()` synchronously, immediately
before its `keychain.deleteSession()`** (`AppFeature` for `logoutConfirmed`/`reauth.quit`,
`SettingsFeature` for `.disconnect`). Both logout hops authenticate through the store, so a
pair inside its refresh leeway rotates mid-logout; with the hook still armed that rotation
rewrites the entry the reducer just deleted and the dead pair is restored on the next launch.
The detach is `nonisolated` for exactly this reason — an `await`ed one runs after the delete —
and it also revokes store ownership, so an in-flight sign-in cannot re-arm the hook afterwards
(`BearerStoreClaim`).

**`AppFeature` does NOT reseed the store on `.reauthenticated`.** The sign-in leg already put
the fresh pair there (it is what the sheet's validating call authenticated with) and may have
rotated it since; re-seeding the connection's captured pair would put a retired refresh token
back in play, which is what the portal's reuse detection revokes sessions for.

`fallBackToOnboarding` also drains the store — it is the shared "the stored credentials are
dead" verdict for both the launch auth failure and the retry screen's `.credentialsRejected`.
The Keychain entry is deliberately left alone (#62's "stored credentials stay untouched" rule
still holds; a re-login overwrites it).

## Failure routing

`OAuthFlowError` splits the two legs — `.login(OAuthLoginError) | .validation(RESTError)` —
because flattening them would lose information either way: into `RESTError` the browser leg's
silent `.cancelled` disappears; into `OAuthLoginError` a 401 from the validating call becomes
indistinguishable from a token-exchange 401.

| Failure | Verdict |
| --- | --- |
| User dismissed the sheet | `.login(.cancelled)` → back to `.reachable` / `.idle`, **silently** — no banner |
| Gateway `error=` on the callback | `.gatewayRejected(reason)` → `.failed(reason)` |
| `state` mismatch | `.stateMismatch`, thrown **before** the code is ever redeemed |
| Authorization code expired (120 s TTL) | token exchange 400 → `.failed` with the server's copy |
| Listener died mid-flow | `.listenerFailed` |
| 300 s elapsed | `.timedOut` |
| Validating call 401 | `.validation(.unauthorized)` → `.invalidCredentials` |
| Refresh 401, later | store cleared + `authExpired` → `.sessionExpired` → `ReauthFeature`, **once** |
| Refresh 503 / transport | rethrown, tokens kept, reconnect backoff retries |

Every failure path clears the seeded store, so a half-finished sign-in never leaves credentials
behind — with ONE deliberate exception: an **abandoned** attempt (superseded by a second
provider tap, dropped by an edited server URL, or torn down by a logout) touches neither the
store nor the Keychain — it does not seed, drain or persist. Cancellation is not a verdict on
the credentials, and both are process-wide: writing there would write over whatever superseded
it, or drain the store the logout's own hops still need. That is enforced by ownership, not by
cancellation checks at the call site — each attempt claims the store up front and the store
itself drops every late arrival; `BearerStoreClaim` is the normative statement of the rule.

**Re-auth identity routing is `user_id`**, not a username: same user → resume in place;
different user → pop to the session list and clear identity-scoped prefs. That compare is
`isSameBearerUser`, which compares the two ids **exactly** — `user_id` is the OIDC `sub` claim,
an opaque case-sensitive identifier, so `alice`, `ALICE` and ` alice ` are different accounts;
the only normalization is the blank check that routes an unknown id as a switch. The cookie regime's
`isSameUser` compares a typed username and does fold case; the two are deliberately separate. The display
name on the reauth button comes from `State.providerLabel`, which falls back to the wire
provider name — after a launch auto-restore nothing was probed, so the display name is
genuinely unavailable and "Continue with " would be worse than "Continue with nous".

## Spike outcome

**Verdict: loopback works.** `ASWebAuthenticationSession` + an in-app `NWListener`; no
`WKWebView` browser-leg fallback is needed.

### What was tested

A standalone harness (`Probe/LoopbackSpike/`, built by `swiftc` into a hand-assembled `.app` —
never referenced by `Project.swift`, so it cannot leak into a shipped target) binds an
ephemeral-port `NWListener` on loopback, answers every request with a tiny "Signed in to
Hermes — you can close this window" page, and opens an `ASWebAuthenticationSession`
(`callbackURLScheme: nil`, `prefersEphemeralWebBrowserSession = false`) against a throwaway
HTTP server (`Probe/LoopbackSpike/redirect_server.py`) that stands in for
`/auth/native/authorize` by answering `302 Location: <redirect_uri>?code=…&state=…`.

| Leg | Runtime | Result |
| --- | --- | --- |
| IPv4 `127.0.0.1` | iOS 18.4 simulator (iPhone SE 2nd gen) | ✅ listener reached, page rendered |
| IPv6 `[::1]` | iOS 18.4 simulator | ✅ listener reached, page rendered |
| IPv4 `127.0.0.1` | iOS 26.5 simulator (iPhone 17) | ✅ listener reached, page rendered |
| Physical device | — | ⏸ deferred to manual verification |
| Real gateway (`nous` provider) | — | ⏸ deferred to manual verification |

Xcode 26.6 (17F113); harness deployment target iOS 18.0.

### Findings that shape the implementation

1. **The Safari view service reaches the app's own loopback listener.** The redirect navigates,
   the listener receives `GET /callback?code=…&state=…` from a `127.0.0.1` (resp. `::1`) peer,
   and the served HTML renders inside the sheet. The page title bar reads `127.0.0.1`.
2. **ATS does not block the `http://127.0.0.1` navigation.** Browser content is not subject to
   the app's ATS policy; the harness set `NSAllowsArbitraryLoads` anyway, matching the shipping
   app's Info.plist (it already allows cleartext for self-hosted servers).
3. **`session.cancel()` does NOT invoke the completion handler** (both iOS 18.4 and 26.5). It
   dismisses the sheet silently. The flow must be settled by the *listener*, never by awaiting
   the completion handler after a programmatic cancel — a race that waited on it to confirm
   teardown would hang. This is the single most load-bearing finding in the file.
4. **A user dismissal DOES deliver `canceledLogin`** (domain
   `com.apple.AuthenticationServices.WebAuthenticationSession`, code `1`). Combined with (3):
   a completion carrying `canceledLogin` **before** the listener settled →
   `OAuthLoginError.cancelled`; **after** it settled → ignored (and in practice it never
   arrives).
5. **The one-time consent alert is unavoidable and expected.** The first `start()` shows
   `"<App>" Wants to Use "<authorize-host>" to Sign In` (Cancel / Continue) because
   `prefersEphemeralWebBrowserSession = false` shares the browser session. Cancelling there
   also surfaces as `canceledLogin`, i.e. the same silent `.cancelled` path. The host named in
   the alert is the **authorize** URL's host (the gateway), not the loopback callback.
6. **The listener must tolerate zero-byte connections.** The IPv6 leg produced four speculative
   TCP connections that delivered no request line at all before the real `GET /callback`. They
   must be answered/closed and treated as "not a callback" — not an error, not a settle. The
   IPv4 leg produced none, and no `/favicon.ico` probe was observed on any runtime, but
   "answer every request, settle only on `code=`/`error=`" makes both harmless.
7. **IPv4 and IPv6 both work, but a listener is bound to one family.** With
   `requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)` only `127.0.0.1` is
   served; the `[::1]` literal needs `.ipv6(.loopback)`. The implementation binds IPv4 and
   advertises `http://127.0.0.1:<port>/callback` — what the desktop does, and what the
   gateway's `_validate_loopback_redirect_uri` accepts first. (`URLComponents` percent-encodes
   the brackets of `[::1]` inside the `redirect_uri` value — a non-issue for IPv4.)
8. **No Local Network permission prompt appeared** on either simulator runtime. Loopback is not
   a local-network address, so none is expected on device either — but the simulator does not
   enforce local-network privacy at all, so this is the one claim it cannot prove.

### Reproducing the spike

```sh
python3 Probe/LoopbackSpike/redirect_server.py 8099 &   # stand-in for /auth/native/authorize
Probe/LoopbackSpike/run.sh <simulator-udid>             # build + install + launch
# tap "Run IPv4" / "Run IPv6" / "No cancel"; results are in the on-screen log and in
# $(xcrun simctl get_app_container <udid> me.honcharenko.LoopbackSpike data)/Documents/spike.log
```

## Known limitations

- **The gateway must advertise `native_pkce`.** No `auth_flows` entry, no OAuth segment — the
  app cannot probe for the endpoints and will not guess. Users on older gateways see exactly
  today's Password | Token UI.
- **Loopback-only redirect.** The gateway rejects custom URL schemes, so the app must bind its
  own `NWListener` for every sign-in. If upstream later accepts a private-use URI scheme
  (RFC 8252 §7.1), the listener can be deleted and
  `ASWebAuthenticationSession(callbackURLScheme:)` used directly — a follow-up, not this
  feature.
- **No `WKWebView` fallback.** A failed native login does not silently degrade to anything
  (the desktop behaves the same); the user retries or picks another segment.
- **Per-provider branding is deliberately absent.** Plain text labels only — see the segment
  section above.
- **These legs are deferred to manual verification**, not covered by any automated suite: a
  physical device on iOS 18 and 26 (listener reached, page renders, `cancel()` dismisses
  without a completion callback), the Local Network prompt on device, and a real Nous-configured
  gateway end to end (sign in, background past the access-token lifetime and foreground,
  revoke the dashboard in the portal → one re-auth sheet).
