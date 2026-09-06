# Architecture

Hermes Mobile is a **remote-control surface only** — no agent logic runs on the
phone. It talks to a self-hosted
[Hermes Agent](https://github.com/NousResearch/hermes-agent) over REST (session lists
and history)
and a WebSocket JSON-RPC gateway (the live turn: streaming, tool/status events,
approval/clarify requests).

## Repository layout

- **`HermesMobile/`** — the app target: a thin SwiftUI shell (views only). The
  project is defined by Tuist; the `.xcodeproj`/`.xcworkspace` are generated and
  gitignored.
- **`HermesKit/`** — a local Swift package holding the engine: models, dependency
  clients, and TCA reducers. This is where the logic lives. Built and tested
  independently with `swift test` (no simulator needed), which keeps the
  reducer/event-reduction test loop fast.
- **`HermesMobileTests/`** — an iOS XCTest target for SwiftUI snapshot tests
  (separate from the SPM suite).
- **`Probe/`** — non-shipping harnesses, never referenced by `Project.swift`: a Swift script
  that verifies the Hermes wire protocol against a real server (its `Probe/fixtures/` output is
  gitignored), and the committed `Probe/LoopbackSpike/` OAuth loopback spike. See
  [`../Probe/README.md`](../Probe/README.md).

## Feature tree (TCA reducers, in `HermesKit`)

```
AppFeature                 // root nav + launch auto-connect; onboarding until connected
│                          //   (a RETRYABLE launch failure raises ConnectionFailedFeature instead);
│                          //   presents ReauthFeature on .sessionExpired (identity-aware routing);
│                          //   owns the LIVE-CHAT SLOT (liveChat: ChatFeature.State? via .ifLet)
│                          //   and a nav path of thin ChatScreen markers — slot teardown (idle
│                          //   pop, detached turn end, replacement, archive, delete, logout) is
│                          //   AppFeature policy, never a view event; owns the layout regime
│                          //   (.compact stack | .regular split view, reported by the shell)
│                          //   and isChatDetached = compact && empty path (#80)
├─ ConnectionFeature       // auto-validating URL + capability-aware auth toggle
│                          //   (Password | Token | <OAuth provider>)
├─ ConnectionFailedFeature // launch-only "can't reach the server" retry screen (ifLet slot):
│                          //   raised when the launch probe fails for a reason that isn't a
│                          //   verdict on the credentials — i.e. EVERYTHING except 401/403
│                          //   (see ConnectionFailedFeature.isRetryable) — keeping the
│                          //   stored session; manual Retry + foreground auto-retry (the
│                          //   foreground supersedes an in-flight probe rather than being
│                          //   swallowed); delegates connected / credentialsRejected /
│                          //   logoutConfirmed (the logout clearing lives in AppFeature)
├─ ReauthFeature           // re-auth modal: fixed URL, prefilled identity, password/token field
│                          //   or (.oauth) a single "Continue with …" button;
│                          //   same-user resume vs different-user switch vs Quit→onboarding
├─ SessionListFeature      // flat list, grouped by workspace OR chronological (persisted) /
│  │                       //   search / create; pin (client-side) + archive/rename/delete (server) +
│  │                       //   working-glow auto-poll; profile pill/switcher (per-call scoped) +
│  │                       //   presents Settings + Archived + AddProfile sheets
│  ├─ SettingsFeature      // token mgmt, manual reconnect, debug log
│  ├─ ArchivedSessionsFeature // archived list (?archived=only); restore + open delegate +
│  │                       //   immediate delete — the `deleted` delegate carries the rollback
│  │                       //   payload and the PARENT list runs the DELETE round-trip (a
│  │                       //   presented sheet's effects die on dismissal); `deleteUnsupported`
│  │                       //   mirrors the capability flag
│  └─ AddProfileFeature    // create-then-PUT-soul; inline name validation + server-400 banner
├─ ChatScreen              // navigation-path marker ONLY (session key, no behavior) — pushing/
│                          //   popping it never creates or destroys chat state; COMPACT-ONLY
│                          //   (in regular the slot is the detail column, the path stays empty)
└─ ChatFeature             // SLOT-rooted (composed via .ifLet, NOT a path element), so a running
                           //   turn's socket + streaming effects survive nav pops; owns the WS
                           //   lifecycle + streaming reduction; also folds in approvals,
                           //   clarify/sudo/secret, the tool-detail sheet, the model/reasoning
                           //   picker, reconnect
```

## Dependency clients

All side effects go through `@DependencyClient` structs (each with a `liveValue` and
a `testValue`/`.inMemory()` variant):

- **`HermesRESTClient`** — status, sessions, archived sessions (`?archived=only`), search,
  archive/rename (`PATCH /api/sessions/{id}`), delete (`DELETE /api/sessions/{id}`), plus the
  auth endpoints: `passwordLogin`, `nativeTokenExchange`/`nativeRefresh` (`/auth/native/…`),
  and a best-effort `logout` — this client's one deliberate exception to "surface RPC failures",
  since it fires after the app has already discarded its credentials (the logout's push
  unregister swallows on the same reasoning). Session-scoped
  reads/mutations take an optional `profile` (omitted for default).
- **`HermesProfileClient`** — profile CRUD + SOUL.md (`PUT /api/profiles/{name}/soul`) +
  profile-scoped session lists (`GET /api/profiles/sessions?profile=`). Capability-gated: a
  404 from `GET /api/profiles` hides the selector.
- **`HermesGatewayClient`** — WebSocket JSON-RPC connect/send. The socket is one
  long-running cancellable effect; reconnect/backoff lives in the reducer (testable
  with `TestClock`). Each `send` enforces a per-request timeout (default 30s) so a
  stuck/never-acking RPC throws `GatewayError.timedOut` instead of hanging forever.
  `connect` branches on the `AuthSession`: `.token` → `?token=` (byte-identical to the
  legacy path); `.cookie` and `.bearer` SHARE one branch → mint a fresh single-use `?ticket=`
  via `POST /api/auth/ws-ticket` per connect (never cached), the regimes differing only inside
  `mintTicket` (cookie jar vs `Authorization: Bearer`). A `401` from the mint surfaces as
  `GatewayEvent.authExpired` (non-retryable → `.sessionExpired`); other mint failures are
  `.ticketUnavailable` (transient → reducer backoff).
- **`OAuthLoginClient`** — the whole browser leg of the native PKCE flow behind one
  `signIn(baseURL, provider)` call: PKCE + state → a `LoopbackCallbackListener` (`NWListener`
  on IPv4 `127.0.0.1`, ephemeral port) → `ASWebAuthenticationSession` → the loopback callback →
  `POST /auth/native/token` → a `BearerSession`. The orchestration is extracted behind an
  injected `NativeLoginDriver` so it is testable on macOS without a browser; only
  `ASWebAuthenticationSession` sits behind `#if canImport(UIKit)` (the listener builds and is
  socket-tested on macOS). Details: `docs/features/oauth-sign-in.md`.
- **`BearerTokenStore`** — not a `@DependencyClient` but a lock-isolated `Sendable` **class**
  exposed as `\.bearerTokens`: the single owner of the `.bearer` token pair and the only
  refresh path (single-flight, persist-before-publish, generation-superseded rotations).
  `liveValue` is the process-wide `.shared`; `testValue` is a fresh empty store.
- **`KeychainClient`** — the persisted `AuthSession` (the only secret): a static `.token`, a
  `.cookie(CookieSession)` carrying the rotating session cookies + username + provider, or a
  `.bearer(BearerSession)` carrying the access/refresh pair + expiry + provider + `user_id`.
  `saveSession`/`loadSession` round-trip the whole session (cookies rehydrate into
  `HTTPCookieStorage` on launch); the legacy `…Token` helpers remain for token-mode.
- **`ChatSnapshotClient`** — a **non-authoritative** instant-paint cache + turn-start anchor,
  backed by GRDB (the store uses a private `DatabaseQueue` directly,
  not a shared `defaultDatabase`) and kept entirely behind the client boundary (read
  once, no reactive `@FetchAll`). It persists each session's latest transcript tail, model, reasoning,
  usage, and a per-session turn-start timestamp so a cold open can paint immediately before the
  server responds. The cache can only make the UI appear *faster*, never *differ* from the
  server: on hydrate the server wins, cached rows are replaced wholesale (no merge/dedup), and
  the whole store is wiped on logout. `.inMemory()` test variant.
- **`PreferencesClient`** — non-secret prefs: server URL (for auto-login), per-session
  seen counts, client-side pinned session ids, the session-list grouping mode
  (`SessionGroupingMode`), and the selected profile name (`hermes.selected-profile-id`). All
  cleared/reset on logout.
- **`PushClient`** — push notifications: `requestAuthorization`/`authorizationStatus`,
  device-token registration as an `AsyncStream<String>` (lowercase-hex, re-emits on OS token
  rotation), an `incomingTaps()` stream of `PushTap` values (carrying `session_id` + optional
  `type`; a tap that fires before any subscriber — launch-from-push, #46 — is buffered in
  `PushBridge`, last-wins, and drained consume-once by the first subscriber), and badge
  control (`setBadgeCount`). The `liveValue` is iOS-only-guarded
  (`#if canImport(UIKit)` over `UNUserNotificationCenter` + `registerForRemoteNotifications`,
  fed by the process-wide `PushBridge` from the app-delegate adapter); the non-iOS fallback is
  `testValue`, plus an `.inMemory()` variant. Pure helpers (hex encoding, the compile-time
  `apnsEnv`, payload parsing, foreground-suppression decision) **and `PushBridge` itself**
  (Foundation-only: `NSLock` + `AsyncStream`, with `onTermination`-pruned subscriber lists so
  a cancelled observer can't strand a dead continuation and defeat the tap buffer) live
  outside the guard so they are unit-tested on macOS.
- **`BackgroundTaskClient`** — a finite background-execution window (~30s) wrapping
  `UIApplication.beginBackgroundTask`/`endBackgroundTask`: `begin(name) → AsyncStream<Void>`
  yields exactly once if iOS expires the window early (then finishes; a normal end finishes
  without a yield), `end()` is idempotent. The client owns the mandatory end-on-expiry
  bookkeeping (every begun task is ended exactly once — explicitly, by replacement, or inside
  the generation-scoped expiration handler). `liveValue` is `#if canImport(UIKit)`-guarded
  (no-op elsewhere); `.inMemory()` exposes a test-drivable `expire()` plus begin/end spies.
- **`PasteboardClient`** — copy.
- **`DebugLogClient`** — an event ring buffer for the in-app debug log.

## Wire protocol

### Auth regimes

The server has **three distinct auth regimes**, modeled by `AuthSession`
(`.token` | `.cookie(CookieSession)` | `.bearer(BearerSession)`) so downstream clients adapt
transport without scattering regime checks. `/api/status` is public (used to validate a server
URL and to probe capability before login).

- **Token mode** (`.token`) — loopback/`--insecure` servers (`auth_required` absent/false).
  REST authenticates via the `X-Hermes-Session-Token` header; WS via `…/api/ws?token=<token>`.
  The token never expires. **This path is byte-identical to the legacy single-token client**
  (a hard backward-compat requirement) — the `profile`-style omissions and request shapes are
  unchanged so old servers behave exactly as before.
- **Gated mode** (`.cookie`) — public-bind servers with `auth_required=true` and a
  password-capable provider. Login is `POST /auth/password-login` `{provider, username,
  password}`; the server returns rotating session cookies via `Set-Cookie` (`hermes_session_at`
  ~12h, `hermes_session_rt` 30d, HttpOnly). REST then authenticates via the cookie jar; the
  WebSocket rejects `?token=`, so each connect mints a fresh single-use `?ticket=` via
  `POST /api/auth/ws-ticket` (cookie-authed, 30s TTL) — **never cached**. Token refresh is
  **transparent**: the server middleware re-mints the access cookie whenever a valid refresh
  cookie is presented, so there is no client refresh endpoint — we persist + resend the jar and
  capture refreshed `Set-Cookie`.
- **Gated mode** (`.bearer`, #19) — the same gated servers, signed into with OAuth through the
  gateway's RFC 8252 native-app flow (`/auth/native/authorize|token|refresh`). The browser leg
  runs in an `ASWebAuthenticationSession` against a loopback `redirect_uri` the app serves
  itself; the token exchange yields a `BearerSession` (`accessToken`, `refreshToken`,
  `expiresAt`, `provider`, `userID`). REST authenticates via `Authorization: Bearer`; the WS
  uses the same per-connect `?ticket=` mint as the cookie regime (the two SHARE the `connect`
  branch). Refresh is **explicit and client-side** — there is no server-side re-mint on this
  path — and is owned entirely by `BearerTokenStore`.

**`RequestAuth` is the one place an auth header is written.** `.none | .sessionToken | .bearer`,
resolved per request by `resolveAuth(for:session:tokenStore:)`: `.token` →
`X-Hermes-Session-Token`, `.cookie` → `.none` (the jar carries it), `.bearer` → a token from
`BearerTokenStore.validAccessToken(refresh:)`, whose `authExpired` becomes `RESTError
.unauthorized` so the existing 401 routing holds. `HermesProfileClient` shares the same
resolver.

**`BearerTokenStore` is the single owner of the bearer pair** and the only refresh path:
single-flight (the portal's refresh-token reuse detection revokes the session on a concurrent
double-refresh), persists the rotated pair *before* publishing it, and supersedes in-flight
rotations via a generation counter on `seed`/`clear`. It has exactly one synchronization
domain — see the rule stated on the type itself. A refresh 401
clears the store and throws `GatewayError.authExpired`; anything else (503, transport) rethrows
with the tokens intact so backoff can retry. **Ordering contract:** `rest.logout` and
`rest.unregisterPush` both authenticate through the store, so both must fire BEFORE
`bearerTokens.clear()`.

**Capability probe.** `ServerAuthCapability(from: status, providers:)` is a pure mapper over
`/api/status` (`auth_required` / `auth_flows`) + `GET /api/auth/providers` into a struct:
`passwordProvider`, `oauthProviders`, `supportsNativeFlow`, `isGated`. It drives the onboarding
screen's capability-aware **Password | Token | \<provider\>** segmented toggle. A providers 404 /
unreachable endpoint (older servers) falls back to `.tokenOnly`. The OAuth segment needs
positive evidence on BOTH halves — an OAuth provider *and* `native_pkce` in `auth_flows`. Full
contract, including the footer hint a provider-advertising gateway without `native_pkce` now
gets: `docs/features/oauth-sign-in.md`.

**Persistence + re-auth.** The `AuthSession` (cookies + username + provider, the bearer pair, or
the bare token) is stored in `KeychainClient` and rehydrated on launch — a `.bearer` restore
seeds `BearerTokenStore` BEFORE the probe. When the gated WS ticket mint returns `401`, or a
bearer refresh does, the session is fully dead → `ChatFeature` raises `.sessionExpired`;
`AppFeature` pauses reconnect and presents `ReauthFeature`. Outcome routing uses a pure identity
compare (normalized username for `.cookie`, `user_id` for `.bearer`): **same user** → dismiss +
reconnect in place; **different user** → pop to the session list, force a reload, and clear
identity-scoped prefs; **Quit** → full logout → onboarding. Token mode reuses the same modal
with a token field (identity compare skipped); the OAuth variant is a single
"Continue with <provider>" button.
The gated foreground-reconnect flow shares the same `connect` (which re-mints the ticket) — see
backlog **#18** (session state-sync).

**Launch-probe failures split by kind (#62).** The auto-connect probe's error decides the
landing. `RESTError.init(transport:)` — the single funnel every request helper's transport
`catch` uses, and the one `asRESTError` defers to for a raw error — maps the
device-has-no-network `URLError` codes (`.notConnectedToInternet` / `.dataNotAllowed` /
`.internationalRoamingOff`) to `.offline` and every other transport failure to `.unreachable`.
`ConnectionFailedFeature.isRetryable` is then the ONE routing rule, shared by `AppFeature`'s
launch handler and the retry screen's own failure branch, and it is inverted from the obvious
one: **only a credentials verdict — 401 (`.unauthorized`) or 403 — keeps the pre-existing
prefilled-onboarding fallback; everything else raises `ConnectionFailedFeature` with the stored
`AuthSession` untouched.** A stored connection was a working Hermes agent when onboarding
persisted it, so a launch failure that isn't 401/403 — a proxy's `502`/`503`/`504`, the agent's
own `500`, a vanished route's `404`, a `429`, a captive portal's HTML (`.decoding`) — means the
network or the server changed, not the saved sign-in. The screen offers Retry, a foreground
auto-retry (`.sceneBecameActive`, which SUPERSEDES an in-flight probe rather than being
swallowed by `isRetrying` — a probe whose result never lands would latch the spinner), the
`AgentSetupGuideView` help sheet (a tertiary link, view-local `@State` as on the login screen)
and a confirmed Log Out (the clearing itself lives in `AppFeature`). Its reason line splits a
`.server` status three ways — a 5xx (`500..<600`) and the transient refusals 408/425/429 may
clear on their own, every *other* 4xx repeats identically and so surfaces the server's own
`detail` (sanitized: markup dropped, first line, ~200 chars, since `serverDetail(from:)` falls
back to the whole body), which is what makes the agent's host-header `400` actionable instead
of a futile retry loop. The launch probe is **once per process**
(`AppFeature.State.didRunLaunchProbe`), and scope is the launch path only: manual login keeps
`ConnectionFeature`'s inline footer (where `.offline` shares `.unreachable`'s status so the
help link still shows) and a post-login drop keeps the chat reconnect banner.

A few protocol facts that shape the reducer (verified against the real Hermes source,
not assumed):

- **Streaming has no message id.** The fold tracks a single in-flight assistant row,
  created lazily on the first delta — a `message.start` with no text would otherwise
  render as an empty bubble. The `session_id` lives on the event *frame*.
- **Decode leniently.** Unknown event `type`s decode to `.unknown` and never crash.
- **`review.summary` is live-only** (#47). The background self-improvement review emits it
  to the session's own socket but never writes it to session history, so the chat renders
  it as an ephemeral system row — the next hydrate (`session.resume`) replaces the
  transcript wholesale and the row disappears, until an upstream hermes-agent change
  persists it.
- **Pins are device-local** (Hermes has no pin API) — an ordered `[String]` of session
  ids in `PreferencesClient`. **Archive is server-side**
  (`PATCH /api/sessions/{id}` `{"archived": …}`), done optimistically.
- **Rename is server-side**, optimistic with rollback (mirrors archive): the session
  list uses `PATCH /api/sessions/{id}` `{"title": …}` over REST; the chat screen uses
  the `session.title` gateway method. Delete is server-side too
  (`DELETE /api/sessions/{id}`, capability-gated); the full contract lives in
  `docs/features/session-list.md`.
- **Profiles are device-local with per-call scoping** — the selected profile *name* lives
  in `PreferencesClient`; we never call `POST /api/profiles/active`. Instead the scoped list
  comes from `GET /api/profiles/sessions?profile=`, and an optional `profile` param threads
  into `session.create`/`session.resume` (gateway) and session-scoped archive/rename/delete
  (REST) — omitted for `"default"` so single-profile agents are byte-identical to today.
  **Search is not profile-scoped** (mirrors the desktop). The desktop's per-profile color is
  intentionally omitted.
- **Slash commands have their own pipeline** — `commands.catalog` (discovery,
  capability-gated like attachments) → `slash.exec` → `command.dispatch` fallback. A
  *successful* `slash.exec` can itself answer a typed dispatch directive (the server routes
  `/retry`-style pending-input commands and skill bundles through `command.dispatch`
  internally), so the exec result is parsed as a directive first — desktop parity. The
  dispatch fallback is skipped whenever re-issuing it could execute the command twice: a
  `-32601`, a transport-shaped failure, or a name the server routes internally. Exec output
  is **ephemeral** (never in `session.resume` history), but slash commands DO mutate history
  (`/undo` rewinds, `/compress` rewrites, `/retry` truncates), so a completed command runs
  the full server-authoritative hydrate and carries the ephemeral output rows across the
  wholesale replace. The pipeline's RPCs get a 120s budget (vs the 30s default): `slash.exec`
  can block the gateway for minutes.

## Push notifications

Push lets the agent reach the phone when its WebSocket is gone (app backgrounded/closed).
Because the app is a *publishable, multi-user* product and the APNs auth key (`.p8`, tied to
the publisher's Team ID + bundle id) can't be safely distributed to self-hosters' machines,
the feature is split across **three artifacts** — only the iOS app lives in this repo:

```
┌─ User's machine ──────────┐    ┌─ Publisher ──────┐    ┌─ Apple ─┐    ┌ Phone ┐
│ Hermes Agent              │    │ Push gateway     │    │  APNs   │    │  App  │
│  └─ hermes-push (plugin)  │──► │ (serverless fn,  │──► │         │──► │       │
│     hooks + REST route    │POST│  holds .p8/JWT)  │HTTP│         │    │       │
└───────────────────────────┘    └──────────────────┘    └─────────┘    └───────┘
      ▲ device token + apns_env registered by app over private net ───────────┘
```

- **`hermes-push`** — a standalone pip-installable Hermes plugin (uses the public plugin
  entry-point API; **hermes-agent itself is not modified**). It triggers notifications and
  exposes the device-token registration REST route. Lives in its own **public** repo:
  `git@github.com:goncharik/hermes-mobile-push-plugin.git` — self-hoster infra, not in this repo.
- **Push gateway** — a tiny *stateless* serverless function (Cloudflare Workers) the
  publisher operates; the only place the `.p8` / ES256 JWT lives. Lives in its own **private**
  repo: `git@github.com:goncharik/hermes-mobile-push-gateway.git` (it holds the Apple secret).
- **iOS app** (this repo) — `PushClient` + reducer wiring; registers its device token with
  the user's own agent over the private network and handles incoming pushes.

This is the Home Assistant push model. **Privacy:** only a generic title/body + `session_id`
ever transit the gateway; real message content is fetched in-app over the private network.

**Protocol.** The app registers via `POST /api/plugins/hermes-push/register`
`{device_token, apns_env, app_version}` (auth as for any `/api/` route) and tears down via
`/unregister`. **The app never signs pushes**, so registration returns nothing the app must
persist (no secret). A `404` from the register route means the plugin isn't installed → the app
sets `pushAvailable = false` and hides the toggle (same capability-gating as attach/profiles).
The plugin POSTs `{device_token, apns_env, type, session_id, title, body, thread_id, capability}`
to the gateway's `POST /push`; the gateway mints an ES256 JWT from the `.p8`, picks the APNs host
from `apns_env` (`api.push.apple.com` vs `api.sandbox.push.apple.com`), and forwards.
**Authorization is a gateway-issued, device-scoped `capability`, not a shared secret** (the old
`hmac`-over-a-canonical-string / `HERMES_PUSH_HMAC_SECRET` scheme is gone — a single hosted
gateway serves all App Store users, so a plugin-held shared secret would be world-readable).
The plugin `POST`s `{device_token}` to the gateway's `/register` once per device, caches the
returned opaque `capability` in its token store, and presents it on every push; a `403
invalid_capability` drops the cached value, re-registers once, and retries the push once. The
plugin never computes the capability, and a leaked one can only push to its own device. The
app's compile-time `apns_env` (`#if DEBUG` → `sandbox`, else `production`) must match the
`aps-environment` entitlement, which is driven per-build-configuration (`$(APS_ENVIRONMENT)`:
`development` for Debug, `production` for Release) so distribution builds ship the right value.
When APNs returns `410 Unregistered` the gateway relays it (HTTP 410) so the plugin drops the
dead token from its store.

**Triggers.** The plugin fires notifications from real Hermes plugin hooks, working in both
CLI and gateway sessions:
- **approval** — `pre_approval_request`
- **turn-complete** — `post_llm_call`, gated to longer turns via a `pre_llm_call` turn-start
  anchor + the ~>10s duration gate, so quick turns stay quiet
- **error** — `on_session_end`, genuine failures only (not successful or user-interrupted turns)
- **clarify** — `pre_tool_call` filtered to the `clarify` tool, fired before the user is
  prompted; not duration-gated (an input-needed pause, like approval)
- **internal agent forks never push** (#64, **plugin-side only** — no iOS or gateway change) —
  a `delegate_task` child is a full `AIAgent` with
  `platform == "subagent"` and its own `session_id`, so it fires this same hook set mid-parent-
  turn; the curator fork does the same with `"curator"`. The plugin maps a fork's
  `post_llm_call` / `on_session_end` to no push and keeps its id out of the approval
  turn-tracker — a lock-guarded fork-session registry covers the `platform`-less
  `pre_tool_call` and any terminal event that omits `platform`, FIFO-capped because a fork's
  `on_session_end` is not guaranteed to fire (abandoned/timed-out children leak an entry).
  Every drop is logged at DEBUG with the session id. **Approvals are never filtered**
  (they block and need the user), but they do **not** carry the parent chat's id: a child runs
  on its own worker thread and the tracker is per-thread, so a child-raised approval falls back
  to `session_key`, never the parent's id. Today's agent gives each child a fresh one-worker
  executor, so that tracker is simply empty; the documented guarantee is deliberately weaker
  ("empty, or another fork's id — never the parent's") because the plugin does not control the
  agent's threading — a recycled worker carrying a stale *sibling*'s id is characterised by a
  test, not a shape upstream produces. That same threading fact makes the tracker guard and the teardown skip
  defence-in-depth (a child cannot reach the parent's tracker), not the live mechanism.
  Only the exact `"subagent"`/`"curator"` values are filtered — a missing or
  other `platform` fails open (old agents unchanged). **Still unfiltered:**
  `agent/background_review.py` forks an agent that inherits the parent's `platform` *and*
  `session_id`, so it looks like a real turn at the hook boundary and keeps producing a
  spurious extra "Turn complete"; that needs a hermes-agent-side change — a `fork=True` hook
  kwarg or its own `session_id`, **not** just a distinct `platform`. Widening the deny-list is
  only safe for a fork with its OWN `session_id`: the registry is fed by the platform-carrying
  hooks and suppresses every event bearing a registered id, so deny-listing a fork that shares
  the parent's id would silence the user's own pushes.

All payloads stay generic/content-free. (When a clarify push fires during a turn, the
trailing "turn complete" for that same turn is suppressed as redundant.)

## Session re-hydration (`session.resume`)

In-flight turn state (model, context usage, running status, tool/thinking history, the
elapsed "Thinking" timer) is **server-authoritative** and is reconstructed every time a chat
appears — there is no durable client-side mirror of it. This is what keeps navigating
**chat → list → chat**, backgrounding, or a cold restart from blanking the model, zeroing the
context gauge, dropping tool/thinking rows, or stranding a phantom "working" glow.

**One unified `hydrate(sessionID)` effect** serves open, foreground, and cold launch. Opening a
session with a stored id, foregrounding it (`.foreground`), and a cold-launch socket connect all
funnel through the same `.ready` → `hydrate` path (`ChatFeature`), so there is one code path to
reason about. `hydrate` calls the gateway's **`session.resume`** RPC, which returns
`{messages, session_id, resumed, info, running, inflight}` and serves **both** a stored session
(rebuilt from the DB) and an already-live one (the transport is reattached, in-flight turn
included). We deliberately do **not** use `session.activate` — that is live-only and answers
"session not found" for any stored session opened from the list (every common case). On the
response (`applyActivate`), in order:

1. **Instant paint first.** `ChatFeature.init` reads `ChatSnapshotClient.loadSnapshot`
   synchronously and paints the cached transcript tail + model + usage, so the screen is never
   blank while the socket connects. On an offline `resume` failure the cached paint is kept
   with a subtle "reconnecting" status (never blanked).
2. **`applyRuntimeInfo(info)`** overwrites model / reasoning effort / usage directly from the
   response (partial info only overwrites present fields) — fixing the blank-model and
   context-0 regressions.
3. **`reconstructTranscript(messages)`** rebuilds the transcript wholesale from the
   authoritative history — reasoning rows, assistant text, and tool-call rows (with
   backward-matched `role:"tool"` results), keyed identically to the live fold's `toolRowIDs`.
   The cached tail is replaced, never merged.
4. **Working indicator + inflight seed.** `isSending` is set from the authoritative `running`
   flag; `inflight.user`/`inflight.assistant` rows are appended and, when `inflight.streaming`
   is set, an assistant streaming row is seeded eagerly with `streamingRowID` pointed at it so
   the next `message.delta` reuses it instead of lazily creating a duplicate.
5. **`reconcileTimer(running, anchor, now)`** restarts the elapsed "Thinking" timer from a
   client-persisted turn-start anchor. **`running` decides *whether* the timer runs; the anchor
   only supplies the *start instant*.** A running turn resumes ticking seeded at `now − anchor`;
   a stopped turn with a stale anchor **discards** the anchor (no phantom timer) and leaves a
   static `Thought · <elapsed>` disclosure. The anchor is written on `prompt.submit` /
   `message.start` and cleared on `message.complete` / error / interrupt.
6. **Write-back.** A fresh server-authoritative snapshot is persisted (debounced; flushed
   immediately on `.background`/`.inactive` via `persistNow`) so the next cold open paints from
   it.

App lifecycle (`scenePhase`, observed in the SwiftUI shell and dispatched as
`AppFeature.scenePhaseChanged`): `.active` ends any background grace task, then routes the live
chat's `.foreground` (re-hydrate via `session.resume`; the socket reconnects **only if it isn't
`.ready`** — a healthy one is never cancel-and-redialed) plus an immediate session-list refresh.
`.inactive` (transient occlusion) is an immediate snapshot/anchor flush only. `.background`
flushes too, and — when a turn is RUNNING — additionally begins a finite ~30s
`BackgroundTaskClient` window so the socket simply keeps streaming past suspension. If iOS
expires that window while still backgrounded: one final flush, then a clean socket-only
disconnect (`.teardownSocketOnly`) that keeps the chat state in memory, so the next foreground
hydrate re-attaches with the #26 live-row preservation; catch-up beyond that is the existing
push + reconnect path. An idle chat backgrounds with no task (no battery burn), and a stale
expiry that races `.active` is guarded to a no-op. The nav stack is **not** auto-restored on
cold launch — opening a session is enough.

Navigation shares the same keep-alive policy (#33): the open chat's state lives in the
`AppFeature`-owned slot (`liveChat`), and the navigation path holds only thin `ChatScreen`
session-key markers — popping to the list destroys nothing while a turn runs (the socket
streams on detached, and re-opening re-attaches via `.reattached` without redialing a healthy
socket); an idle chat is torn down only after the pop animation finishes (the destination's
disappearance routes through `AppFeature.chatViewDisappeared`).

The root is ONE `NavigationSplitView` for both widths (#80): its sidebar column hosts the
`NavigationStack(path:)` (list root, chat destination), its detail column renders the slot's
`ChatView` directly. `AppFeature.State.layout` (`.compact` | `.regular`) is `.regular` only for a
regular size class on the pad idiom — Slide Over and every iPhone get the phone layout — and
**"detached" means compact AND empty path** (`isChatDetached`): in compact the split collapses
to the stack and an empty path means the chat was popped; in regular the slot IS the visible
detail, the path stays empty (the marker is compact-only — one there would render the chat
twice), and a chat is never detached, so the pop-teardown and detached-turn-end policies never
fire. A layout change sets `layout` first, then reconciles the path (regular→compact pushes the
slot's marker, or drops a pristine seat; compact→regular clears it) and keeps the socket.
Regular never shows a blank detail: a fresh new chat is seated on home appearance / widening /
archive-delete refill / profile switch / different-user re-auth, and "New session" over that
empty seat only resets the composer. Full contract, the empty-chat hero, the readable-width
cap, and the known limitations: `docs/features/ipad-layout.md`.

The session-list **working glow** is driven event-driven by `ChatFeature.Delegate.runningChanged`
(emitted on `message.start`/`complete`/`error` and from the `session.resume` `running` flag),
routed by `AppFeature` to `SessionListFeature` so the row's glow clears/lights instantly. The
existing poll stays the backstop for not-open sessions; a cached `running-guess` **never** starts
a glow on its own — only one the server confirms.
