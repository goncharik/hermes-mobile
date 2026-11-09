# Onboarding: Welcome → Server → Sign in (#136)

The short rules live in `CLAUDE.md` → "Gateway & session lifecycle" (the onboarding and Login
help bullets) and "Push notifications"; this doc is the full contract. The auth effects the
flow runs are unchanged and documented in `docs/features/oauth-sign-in.md` and
`docs/architecture.md` → "Auth regimes". Design history:
`docs/plans/completed/20261109-onboarding-redesign.md`.

The first-run flow replaced the one-screen `ConnectionView` form (URL, a segmented
Password | Token | \<provider\> toggle, and one status footer). It asks one thing per screen,
lets the server decide the sign-in method, and gives every probe failure its own card. After
sign-in the session list shows an inline notification card and a dismissible tips row instead
of firing the system permission prompt on appearance.

## The flow is a TCA stack (`ConnectionPath`)

```swift
@Reducer enum ConnectionPath { case server(ServerStep); case signIn(SignInStep) }

ConnectionFeature.State {
  lastProbedCapability: ServerAuthCapability?   // AppFeature's re-sign-in provider label
  path: StackState<ConnectionPath.State>
  prefilledToken: String?                       // credentials-verdict recovery only
  prefilledTokenHost: String?                   // the stored URL's host
}
```

- **Welcome** is the stack root. It has no reducer; its one action (`connectButtonTapped`) is
  on `ConnectionFeature`, and it only pushes onto an EMPTY stack, so a double tap before the
  push animation can't stack two Server steps.
- **Server** (`ServerStep`) probes the typed address and reports `.probeSucceeded(ServerProbe)`.
  The parent records `lastProbedCapability`, pops to the sending Server element, then appends
  Sign in, so Sign in always sits directly above the step that probed for it.
- **Sign in** (`SignInStep`) owns the token, password and OAuth effects and reports
  `.connected(ServerConnection)`, which the parent re-emits as its own delegate. `AppFeature`'s
  `.onboarding(.delegate(.connected))` contract is unchanged.
- **A Sign in step can't exist without a `ServerProbe`**, so "sign-in UI with no capability" is
  unrepresentable.
- **Popping Sign in (swipe-back or Change) cancels its effects.** TCA cancels a removed stack
  element's effects, which replaced the old URL-edit `onChange` that abandoned an OAuth attempt.
  Cancellation never drains the shared bearer store (`performNativeOAuthLogin`, rule 4 in
  `docs/features/oauth-sign-in.md`).
- `prefilledToken` goes only to a Sign in whose probed host equals `prefilledTokenHost`, so an
  edited address never receives another server's token (another port on the stored host still
  does). It is not consumed when Sign in is pushed: popping back and probing that host again
  prefills it again. `lastProbedCapability` survives the pop.
- `ConnectionView` owns `NavigationStack(path:)` with a `destination` switch over the two cases;
  `AppView` no longer wraps it in its own stack. The steps are titled "Step 1 of 2" / "Step 2 of
  2"; Welcome hides the navigation bar.
- `AuthMethod` stays in `ConnectionFeature.swift`: `ReauthFeature` uses it and
  `SignInStep.State.Status` tags each attempt with it, but onboarding derives its layout from
  the probed capability. The old `ConnectionFeature` `Status`, `MethodHint` and the URL
  `onChange` are gone.

## Entry points

| Landing | State | Shows |
|---|---|---|
| First launch, logout, "Quit to start", retry-screen Log Out, Settings disconnect | `ConnectionFeature.State()` | Welcome |
| Credentials verdict (`fallBackToOnboarding`, #62: a 401/403 at launch or from the retry screen) | `.init(recovering: url, token:)`: path = `[.server(addressText: url, autoProbe: true)]`, `prefilledToken = token` | Server auto-probes, then pushes Sign in with the token prefilled |

Every logout clears the server URL pref, so a real logout lands on Welcome with nothing
prefilled. The prefilled path is only the credentials-verdict fallback. A cookie or bearer
connection has no persistable credential, so its `prefilledToken` is `nil`. The fallback shows
no "You signed out" notice: it isn't a sign-out, and `SignInStep` has no recovering flag.

## Server step

### `ServerAddress`

The typed text is parsed once into a pure `ServerAddress` (`Models/ServerAddress.swift`, no
`#if canImport(UIKit)`, fully unit-tested). Parsing reuses `parseServerURL`, so the leniency is
identical: whitespace is trimmed, `host:port` defaults to `http://`, and a host is required. The
host is lowercased, with IPv6 brackets and a trailing root dot removed.

| Kind | Hosts |
|---|---|
| `loopback` | `localhost`, `*.localhost`, 127.0.0.0/8, `::1` |
| `localNetwork` | RFC 1918 (10/8, 172.16/12, 192.168/16), 169.254/16, `fc00::/7`, `fe80::/10` (zone id stripped), `*.local` |
| `tailnet` | 100.64.0.0/10, `fd7a:115c:a1e0::/48` (checked before the ULA range), `*.ts.net`, single-label names (MagicDNS) |
| `publicHost` | everything else |

An IPv4-mapped IPv6 literal classifies as its IPv4 address. The kind is a heuristic: a wrong
guess only changes copy — the Local Network hint, the kind-specific `hostNotFound`, `timedOut`
and `offline` cards (table below) and, for `publicHost`, the cleartext warning on Sign in.

- `candidates`: the URL as typed, then the same URL on `:9119` (`ServerAddress.fallbackPort`,
  the dashboard's default) when the scheme is http and no port was given. The fallback keeps
  the typed path.
- `isPublicCleartext`: http to a `publicHost`. Sign in warns before sending a password or token.

### The probe

One cancellable effect (`CancelID.probe`):

1. Walk `candidates`, calling `rest.probeStatus(candidate)`. Move to the next candidate ONLY on
   `failure.triesNextCandidate`: nothing answered (`isTransport`), or something that isn't
   Hermes answered (`notHermes`, e.g. a NAS or web server on port 80). Every other failure
   stops the loop. When the walk ends in failure, it reports a `FailedServerProbe`: the address,
   the candidates `tried`, and the LAST one's failure (for a bare host, the `:9119` verdict).
2. On a status, send `.statusReceived` (`.reaching` → `.readingSignInOptions`). When
   `authRequired == true`, fetch `rest.authProviders`; a failure is swallowed as no providers,
   as the launch probe does.
3. Build `ServerAuthCapability(from:providers:)` and report a `ServerProbe` whose `baseURL` is
   the candidate that answered. Sign in connects to and saves that URL, so a `:9119` fallback is
   what gets persisted.

The phase is `.idle | .probing(Stage) | .failed(FailedServerProbe)`. A success returns
the phase to `.idle`, so Continue is usable after popping back from Sign in.

- **Editing the address** resets the phase to `.idle` and cancels an in-flight probe.
- **Continue** is enabled for any non-empty text while no probe runs. An unparseable address
  doesn't probe; the view shows the inline "That doesn't look like an address yet." hint
  (`showsInvalidAddressHint`, also live while typing).
- **`autoProbe`** (credentials-verdict entry) probes on the first `onAppear` and is consumed by
  it, so popping back from Sign in never re-probes.
- **The checklist** (Reaching → Checking it's a Hermes agent → Reading sign-in options) is
  derived by `ServerStep.State.status(of:)`. `ProbeFailure.failedCheck` names the row a failure
  fails: no answer fails Reaching, an HTTP answer that isn't a usable status fails the Hermes
  check.

### `ProbeFailure` and `probeStatus`

`HermesRESTClient.probeStatus(URL) async -> Result<ServerStatus, ProbeFailure>` calls
`GET /api/status` on the same session as `status`, but classifies the RAW `URLError` or HTTP
response with `ProbeFailure.classify` before anything is flattened to `RESTError`. `RESTError`,
`RESTError(transport:)` and their many references are untouched, and the launch path (#62)
keeps `rest.status`. Each request times out after `probeStatusTimeout` (10 s), so a host that
drops packets fails within seconds per candidate. A 2xx counts only when it decodes as
`ServerStatus` WITH a `version` (every Hermes `/api/status` reports one, signed out included);
any other 2xx is `.notHermes(httpStatus:)` with the real status. An unparseable base URL or a
non-HTTP response is `.requestFailed`.

| Case | Source | `isTransport` | Fails | Card |
|---|---|---|---|---|
| `offline` | `.notConnectedToInternet`, `.dataNotAllowed`, `.internationalRoamingOff` | no | Reaching | "This phone is offline" ("Can't reach \<host\>", same-Wi-Fi / Airplane Mode fixes, on a `localNetwork` address) |
| `hostNotFound` | `.cannotFindHost`, `.dnsLookupFailed` | yes | Reaching | "Is Tailscale on?" on a `tailnet` address, else "Can't find \<host\>" |
| `refused` | `.cannotConnectToHost` | yes | Reaching | "The computer is there, but the dashboard isn't" (`--host 0.0.0.0`, port 9119) |
| `timedOut` | `.timedOut`, `.networkConnectionLost` | yes | Reaching | "No answer from \<host\>" (same-Wi-Fi fixes for a `localNetwork` address, Tailscale/VPN fixes otherwise) |
| `untrustedCertificate` | `.serverCertificate*`, `.secureConnectionFailed`, `.clientCertificate*` | no | Reaching | "The certificate isn't trusted" |
| `notHermes(httpStatus:)` | 404, or a 2xx that isn't Hermes status JSON | no | Hermes | "This isn't a Hermes agent" |
| `hostRejected(detail:)` | 400 whose detail starts "Invalid Host header" | no | Hermes | "Your agent rejected this address" (`--host`, `dashboard.public_url` / `HERMES_DASHBOARD_PUBLIC_URL`) |
| `httpError(String)` | any other HTTP status | no | Hermes | "Couldn't connect to \<host\>", the server copy's first line (`headline(of:)`) |
| `requestFailed(String)` | any other `URLError`, or a non-`URLError` | no | Reaching | "Couldn't connect to \<host\>", the system copy's first line (`headline(of:)`) |

- The Host-rejection text was checked against upstream `host_header_middleware`
  (`hermes_cli/web_server.py`). Hermes rejects a Host header that is neither the bound host nor
  the `dashboard.public_url` host; a `0.0.0.0`/`::` bind accepts any.
- An HTML `Content-Type` drops the detail (a reverse proxy's error page is markup, not copy), so
  the card falls back to "HTTP \<status\>". An empty detail is treated as none.
- Each card has a "Setup guide" button and a Details disclosure. Details opens with
  `FailedServerProbe.triedDetail` (every `/api/status` URL probed, in order) and then the raw
  reason; `httpError` and `requestFailed` show `reportedURL` and the full text instead. The
  `refused` and `timedOut` copy names `reportedURL`, the candidate whose failure the card
  reports. The `offline` and `httpError` copy isn't in the prototype and follows its voice;
  `timedOut` doesn't promise a time limit.

### The Local Network rule (TN3179)

iOS shows its own Local Network alert the first time the app reaches a same-network address.
Per Apple TN3179 a local network is a broadcast-capable interface, "not cellular (WWAN) or
VPN", so a Tailscale address never triggers it. The first request can fail while the alert is
on screen.

The app shows **no explainer before the alert and doesn't try to detect a denial**. Instead,
when a probe to a `localNetwork` address fails with nothing answering, or as `offline` (a
denied Local Network permission fails as "not connected") —
`ProbeFailure.showsLocalNetworkHint(for:)` = `address.kind == .localNetwork && (isTransport ||
self == .offline)` — the failure card adds one line: "If iOS asked about Local Network access,
allow it and try again. You can change it in Settings › Privacy & Security › Local Network."
That covers both
the first request failing behind the alert and a user who tapped Don't Allow, without
device-only code. It's a view decision with no reducer state. The `NSLocalNetworkUsageDescription`
comment in `Project.swift` records that Tailscale/VPN traffic doesn't trigger the prompt; the
user-facing string is unchanged.

## Sign in step

`SignInStep.State.Layout` is derived purely from `probe.capability`, with the same
password → OAuth → token preference and the same OAuth positive-evidence rule (an OAuth
provider AND `native_pkce`) as the old segmented toggle:

| Capability | Layout |
|---|---|
| password, OAuth available | `.password(oauthProviders: [...])`: fields first, provider buttons under "or" |
| password, OAuth too old (providers without `native_pkce`) | `.password(oauthProviders: [])` + a "\<names\> sign-in needs a newer Hermes agent" notice |
| password, no OAuth | `.password(oauthProviders: [])` |
| no password, OAuth available | `.oauthOnly(providers)` |
| no password, OAuth too old | `.token(reason: .oauthNeedsNewerAgent)` |
| not gated, or gated with no providers (`.tokenOnly`) | `.token(reason: .tokenOnlyServer)` |

- Under the two non-token layouts the token field sits behind "Other ways to sign in"
  (`isShowingOtherWays`).
- The reducer also enforces positive evidence: `oauthProviderButtonTapped` ignores a provider
  that isn't in the offered list.
- **The effects moved verbatim** from the old `ConnectionFeature.connectTapped`, against
  `probe.baseURL`. Token persistence is byte-identical to the legacy path; a second provider
  tap supersedes the first (`CancelID.oauthLogin`, `cancelInFlight: true`); an OAuth
  `.login(.cancelled)` returns to `.idle` with no copy; `.validation(.unauthorized)` is
  `.invalidCredentials(.oauth)`; anything else is `.failed(message)`.
- **Only an attempt in flight blocks a retry**: `canSignInWithPassword` / `canSignInWithToken` /
  `canSignInWithOAuth` reject `.validating` but not `.failed`, and each action checks its own
  rule. The old screen's URL edit cleared a `.failed` status; this step has no URL field, so
  keeping that block would trap the user behind Change.
- Verdicts are method-tagged (`.validating(AuthMethod)`, `.invalidCredentials(AuthMethod)`), so
  the view tells an OAuth rejection ("The agent rejected that sign-in…") from a password or
  token one. `.failed(message)` renders as one notice above the methods.
- Error copy names the server-side setting: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD`
  in `~/.hermes/.env` for a password, `HERMES_DASHBOARD_SESSION_TOKEN` for a token.
- `ServerCard` (host, version, `methodSummary`, Change) heads the step; Change is
  `changeServerButtonTapped` → `dismiss()`.
- Provider buttons are plain text ("Continue with \<display name\>", no logo, no brand colour;
  App Store 5.2.1), with the note "Opens \<provider\> in a secure browser. Nothing is saved
  until sign-in completes."

## Help sheet entry points

`AgentSetupGuideView` stays the single connection-help surface, presented from view-local
`@State` (presentation stays out of the reducers). `ConnectionView` holds one flag for the
onboarding entry points, and `ConnectionFailedView` keeps its own:

- Welcome's secondary button, "I don't have an agent yet";
- the Server step's "Where do I find the address?";
- every failure card's "Setup guide";
- the retry screen's help link (`ConnectionFailedView`, unchanged).

The guide has two tabs (local `@State` segmented picker, fixed above the scroll): **On my
computer** (the existing cards) and **Hermes Cloud** ("Hermes Cloud runs your agent for you.
Open your agent in the Nous portal, copy its address, and paste it into Hermes Mobile's agent
address field…", with
a link to `https://portal.nousresearch.com`, desktop's `FALLBACK_PORTAL_URL`). The README
quick-start carries the same Cloud copy verbatim and maps the two tabs to its steps.

## Views and layout

The views live in `HermesMobile/Sources/Features/Onboarding/` (`WelcomeView`,
`ServerStepView`, `SignInStepView`, `ProbeFailureCard`, `OnboardingLayout`) and stay
declarative; the copy-deciding logic they need is in HermesKit (`status(of:)`,
`failedCheck`, `showsLocalNetworkHint(for:)`, `methodSummary`, `oauthProviderNames`).

- **The column is capped at `OnboardingLayout.maxWidth` (480) on the outer container only**
  (`OnboardingScreen`: `.frame(maxWidth:)` then `.frame(maxWidth: .infinity)`), centred on iPad
  and uncapped on a phone. Measured in `OnboardingColumnLayoutTests` (Welcome through the real
  stack host, plus the pushed Server step).
- **Colours**: `Color.hermesAccentInk` (#9A5B00 light / #F7B549 dark) tints the stack, the
  back button and links; primary buttons are `.borderedProminent` in `hermesAccent` with dark
  text (white on amber is illegible). No Liquid Glass, so no iOS 26 gate.
- **Accessibility text sizes** (`dynamicTypeSize.isAccessibilitySize`):
  - the footer CTAs stop being pinned and scroll as the content's last block (pinned, they
    filled most of the phone and left a sliver of body);
  - `ServerCard` stacks (details full width, then Change) instead of breaking words mid-word;
  - `OnboardingFlowLayout` re-measures a chip wider than the line at the line width and caps
    its reported width at the proposal (it used to push the column past the screen).

  Covered by the AX3 snapshots (`testWelcome_accessibilitySize`, `testServer_accessibilitySize`,
  `testSignIn_accessibilitySize`) and a measured flow-layout test.
- No custom transitions beyond the stack's own; checklist rows and cards carry VoiceOver
  labels.
- **Snapshots** render `ServerStepView` / `SignInStepView` in their own `NavigationStack` with
  the back button hidden: the pushed Liquid Glass back button composited inconsistently in light
  mode and blew the diff budget. Welcome still goes through the real `ConnectionView`.

## After sign-in: the push card

`SessionListFeature` no longer calls `requestAuthorization()` on appearance. `setupPush` probes
the plugin, then sets `pushCard: PushCard?`:

| Plugin | Permission | Snoozed | Result |
|---|---|---|---|
| `.ready` | `.authorized` / `.provisional` | any | silent register (`.requestPushAuthorization`, no prompt), snooze cleared |
| `.ready` | `.notDetermined` | no | `.enableNotifications` card |
| `.ready` | `.notDetermined` | yes | nothing |
| `.ready` | `.denied` | any | nothing (Settings has the toggle) |
| `.notReady` | not read | no | `.installPlugin` card, `pushAvailable = false` |
| `.notReady` | not read | yes | nothing, `pushAvailable = false` |
| `.unknown` | not read | any | nothing (can't tell, don't nag) |

The permission read is its own action (`pushAuthorizationStatusLoaded`), which runs on the
`pushTokens` cancel id.

- **Turn on** (`pushCardEnableButtonTapped`) is the ONLY path to the system permission prompt.
- **Ask my agent to install it** (`pushCardAskAgentButtonTapped`) opens a new chat with
  `PushSetup.installPrompt` prefilled (not sent). It doesn't snooze, so the card comes back on
  the next appearance while the plugin is still missing.
- **Not now / Later** (`pushCardNotNowButtonTapped`) uses the existing Fibonacci snooze
  (`pushPromptSnoozeDays`). **Both variants share the one snooze**, so a Later on the install
  card also delays the enable card after the plugin is installed. The snooze is cleared on an
  authorized/provisional verdict, not on every `.ready` (that would make the enable card's
  snooze a no-op).
- Every button clears the card. The preview shows only the generic alert a push can carry
  ("Approval needed", "Your agent is waiting for a decision."), following the privacy rule.
- The card is the first row under the "Sessions" title, above Pinned and the date sections,
  only on the Sessions tab and never while searching (`showsPushCard`).
- `showPushSetupSheet` and the old sheet actions are gone. `PushSetupGuideView` is presented
  only from Settings, from its own view-local `@State`.

## After sign-in: the tips row

A dismissible "Tips" row under the push card: a horizontally paging row of cards, each about
three quarters of the width so the next one peeks in.

- Tips, in order: profiles (only when `profilesSupported`, since the pill it points at is
  hidden without it), voice, swipe actions. The swipe tip's copy follows `effectiveSwipeAction`
  ("archive or rename" / "delete or rename").
- **Hide** (`onboardingTipsHideButtonTapped`) hides the row and saves
  `PreferencesClient.saveOnboardingTipsDismissed(true)`.
- The pref is cleared by an explicit call in each logout branch (`AppFeature` retry-screen
  logout and re-auth Quit, `SettingsFeature` disconnect), so the next sign-in shows the tips
  again. It's deliberately NOT in `clearIdentityScopedPrefs`: it's a device-wide UI pref, and a
  re-auth user switch keeps it.
- `showsOnboardingTips` is seeded in `AppFeature.makeHomeState` as well as the list's
  `reloadPrefs`, so a dismissed row never flashes before `.task`. The State default is `true`
  (matches the unset pref).
- `showsOnboardingTipsRow` hides it while searching and off the Sessions tab.
- While the push card or tips show, the "No sessions" placeholder flows as a row under them
  (`showsInlineEmptyPlaceholder`) instead of floating centred, where a tall card would collide
  with it.
- The card and the row animate away only with reduce motion off; paging is the user's own
  scroll.

## Demo mode

The "connect" scenario seeds `[.server, .signIn(probe:)]` with no live probe: a password +
Nous Research capability (`native_pkce` advertised), answered on the `:9119` fallback of
`mac-mini.tail4c2e.ts.net`. The address is a tailnet name on purpose: the other scenarios'
`mac.tailnet` classifies as a public host and would put the cleartext warning in the App Store
capture. The Server step beneath it is idle with no `autoProbe`, so popping back never fires a
REST call. Demo mode pins the tips dismissed, so the list captures are unchanged.

## Out of scope and follow-ups

- **Hermes Cloud account sign-in + agent picker: #160.** 1.0 keeps paste-the-address + Nous
  sign-in.
- No "Connected" beat before landing on home (an open question in #136), no starter prompts in
  an empty chat (desktop has none), no Local Network explainer or denial detection.
- `ReauthView` and `ConnectionFailedView` keep their own UI; reusing the new cards there is a
  follow-up.
- Device-only checks (not automatable): the iOS Local Network alert on a fresh install, Tailscale
  on/off, the dashboard stopped / bound to a specific IP, the `:9119` fallback being saved, a
  real Nous agent's OAuth round trip with cancel and swipe-back, and no system prompt before
  Turn on.
