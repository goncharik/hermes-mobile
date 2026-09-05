# OAuth sign-in (native PKCE) (#19)

> **Status: in progress.** This doc currently records only the Task 1 spike outcome. The
> full contract (protocol summary, the three auth regimes, the `BearerTokenStore`
> invariant, capability gating, known limitations) lands in Task 15 of
> `docs/plans/20260905-oauth-native-pkce-sign-in.md`.

The plan: a third sign-in method beside Password and Token, using the RFC 8252 native-app
flow the Hermes gateway exposes for the desktop (`/auth/native/authorize|token|refresh`).
The browser leg runs in an `ASWebAuthenticationSession`; the gateway only accepts a
loopback `redirect_uri` (`http://127.0.0.1[:port]/…` or `http://[::1][:port]/…`), so the
app binds its own ephemeral-port `NWListener` and hands that URL over as the redirect
target.

## Spike outcome

**Verdict: loopback works. Proceed with Option A** — `ASWebAuthenticationSession` +
in-app `NWListener`. No `WKWebView` browser-leg fallback is needed, so Tasks 6 and 7 of the
plan stand as written.

### What was tested

A standalone harness (`Probe/LoopbackSpike/`, built by `swiftc` into a hand-assembled
`.app` — never referenced by `Project.swift`, so it cannot leak into a shipped target)
binds an ephemeral-port `NWListener` on loopback, answers every request with a tiny
"Signed in to Hermes — you can close this window" page, and opens an
`ASWebAuthenticationSession` (`callbackURLScheme: nil`,
`prefersEphemeralWebBrowserSession = false`) against a throwaway HTTP server
(`Probe/LoopbackSpike/redirect_server.py`) that stands in for
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

1. **The Safari view service reaches the app's own loopback listener.** The redirect
   navigates, the app's listener receives `GET /callback?code=…&state=…` from a
   `127.0.0.1` (resp. `::1`) peer, and the served HTML renders inside the sheet. The page
   title bar reads `127.0.0.1`.
2. **ATS does not block the `http://127.0.0.1` navigation.** Browser content is not
   subject to the app's ATS policy; the harness set `NSAllowsArbitraryLoads` anyway,
   matching the shipping app's Info.plist (it already allows cleartext for self-hosted
   servers).
3. **`session.cancel()` does NOT invoke the completion handler** (both iOS 18.4 and
   26.5). It dismisses the sheet silently. So the flow must be settled by the *listener*,
   never by awaiting the completion handler after a programmatic cancel — a `race` that
   waits on the completion handler to confirm teardown would hang.
4. **A user dismissal DOES deliver `canceledLogin`.** Tapping the sheet's Cancel gives
   `ASWebAuthenticationSessionError.canceledLogin` (domain
   `com.apple.AuthenticationServices.WebAuthenticationSession`, code `1`). Combined with
   (3) this validates the planned rule verbatim: a completion carrying `canceledLogin`
   **before** the listener settled → `OAuthLoginError.cancelled`; **after** it settled →
   ignored (and in practice it never arrives).
5. **The one-time consent alert is unavoidable and expected.** The first `start()` shows
   the system sheet `"<App>" Wants to Use "<authorize-host>" to Sign In` (Cancel /
   Continue) because `prefersEphemeralWebBrowserSession = false` shares the browser
   session. Tapping Cancel there also surfaces as `canceledLogin`, i.e. the same silent
   `.cancelled` path. The host named in the alert is the **authorize** URL's host (the
   gateway), not the loopback callback.
6. **The listener must tolerate zero-byte connections.** The IPv6 leg produced four
   speculative TCP connections that delivered no request line at all before the real
   `GET /callback`. They must be answered/closed and treated as "not a callback" — not as
   an error and not as a settle. The IPv4 leg produced none, and **no `/favicon.ico`
   probe was observed** on any runtime (the served page declares no favicon), but the
   "answer every request, settle only on `code=`/`error=`" rule from the plan is what
   makes both cases harmless.
7. **IPv4 and IPv6 both work, but a listener is bound to one family.** With
   `requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)` only
   `127.0.0.1` is served; the `[::1]` literal needs `.ipv6(.loopback)`. The
   implementation should bind IPv4 and advertise `http://127.0.0.1:<port>/callback` (what
   the desktop does, and what the gateway's `_validate_loopback_redirect_uri` accepts
   first). Note `URLComponents` percent-encodes the brackets of `[::1]` inside the
   `redirect_uri` query value (`%5B::1%5D`) — a non-issue for IPv4.
8. **No Local Network permission prompt appeared** on either simulator runtime. Loopback
   is not a local-network address, so no prompt is expected on device either — but the
   simulator does not enforce local-network privacy at all, so this is the one claim the
   simulator cannot prove. See the deferred item below.

### Deferred to manual verification

No physical device and no Nous-configured gateway were available in the execution
environment. These are the Post-Completion manual items in the plan and must be run
before the feature ships:

- **Physical device**, iOS 18 and iOS 26: same three legs (listener reached, page
  renders, `cancel()` dismisses without a completion callback).
- **Local Network prompt on device**: confirm none appears when the listener binds and
  when the Safari view connects to it. The app already carries an
  `NSLocalNetworkUsageDescription` string (needed for tailnet/LAN gateways), so even if
  one did appear it would be answerable — but the expectation is that loopback is exempt.
- **Real gateway** (Tailscale-bound, `nous` provider): `/auth/native/authorize` accepts
  the `127.0.0.1:<port>` redirect, and `POST /auth/native/token` returns
  `{access_token, refresh_token, token_type, expires_at, provider, user_id}` as
  documented in the plan's Context section.

### Reproducing the spike

```sh
python3 Probe/LoopbackSpike/redirect_server.py 8099 &   # stand-in for /auth/native/authorize
Probe/LoopbackSpike/run.sh <simulator-udid>             # build + install + launch
# tap "Run IPv4" / "Run IPv6" / "No cancel"; results are in the on-screen log and in
# $(xcrun simctl get_app_container <udid> me.honcharenko.LoopbackSpike data)/Documents/spike.log
```
