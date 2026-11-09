# Onboarding redesign (#136)

## Overview
- Replace the one-screen `ConnectionView` form with a three-step first-run flow: **Welcome → Server → Sign in**, then land on the session list with an inline notification card and dismissible tips.
- Problems solved (from #136): no "what is this / what do I need" step; URL and auth method asked at once although the server decides the method; every failure looks the same (raw text in `.failed(String)`); the push permission prompt fires on list appearance with no context.
- Source of truth for behaviour and copy:
  - prototype: https://claude.ai/artifact/U8WXaWyHyxJdaVCLiAui1b (version 3)
  - gap analysis: https://github.com/goncharik/hermes-mobile/issues/136#issuecomment-6736035059
  - the decisions recorded in this plan where they differ from that comment (no starter prompts, no Local Network explainer, desktop-based Hermes Cloud copy)
- Integrates with the existing auth stack unchanged: `.connected(ServerConnection)` still goes up to `AppFeature`; the token/password/OAuth effects, the OAuth positive-evidence rule, #62 retry routing, Keychain ordering and `BearerTokenStore` rules are not changed, only moved.

## Context (from discovery)
- **Flow today:**
  - `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift` is one reducer holding URL, all three credential sets, a segmented `method`, `capability` and one `Status` enum.
  - `HermesMobile/Sources/Features/ConnectionView.swift` is one `Form`.
  - `AppView.swift:96` wraps it in a bare `NavigationStack`.
- **`AppFeature` coupling:**
  - `fallBackToOnboarding` (`AppFeature.swift:2080`) prefills the URL and token after a credentials verdict.
  - Logout, "Quit to start", the retry screen's "Log Out" and Settings "disconnect" set `state.onboarding = .init()`. These are fresh, with nothing prefilled, because the server URL pref is cleared.
  - The re-sign-in modal reads `state.onboarding.capability?.oauthProviders` (`AppFeature.swift:923`).
- **Errors:** `RESTError(transport:)` (`HermesRESTClient.swift:155`) folds timeout, DNS, refused and TLS into `.unreachable`, and a 404 on `/api/status` reaches `.failed(String)`. There are about 115 references to `.unreachable` across Sources and Tests, so the enum case must not change shape.
- **Push:** `SessionListFeature.setupPush` (`:809`) probes the plugin. `.ready` calls `.requestPushAuthorization` immediately. `.notReady` raises `PushSetupGuideView` unless snoozed by the Fibonacci backoff (`pushPromptSnoozeDays`, `PreferencesClient.load/save/clearPushPromptSnooze`). `PushClient.authorizationStatus` already exists.
- **Help sheet:** `AgentSetupGuideView` is presented by view-local `@State` (CLAUDE.md rule: presentation stays out of the reducer), and the README quick-start must stay verbatim-identical to it.
- **Demo mode:** `DemoMode.swift` "connect" scenario builds `ConnectionFeature.State(serverURL:token:status:)`.
- **Tests:**
  - `ConnectionFeatureTests.swift` (1,340 lines, Swift Testing + `TestStore`).
  - `ConnectionSnapshotTests.swift`.
  - `ConnectionColumnLayoutTests.swift` (measured readable-width cap).
  - `HermesRESTClientTests.swift` (`URLProtocol` stubs).
- **Upstream facts the copy relies on:** `hermes_cli/web_server_boundary.py`.
  - `should_require_auth` depends only on the bind host.
  - `_is_accepted_host` accepts any Host on a `0.0.0.0`/`::` bind, else the bind host or the `dashboard.public_url` host.
- **Apple TN3179:** a local network is a broadcast-capable interface, "not cellular (WWAN) or VPN". iOS shows its own Local Network alert the first time the app reaches a same-Wi-Fi address; Tailscale never triggers it. The first request can fail while that alert is on screen.
- **Hermes Desktop parity:**
  - desktop has no starter prompts in an empty chat;
  - its Hermes Cloud copy is "Hermes Cloud" plus "Nous portal" (`apps/desktop/src/i18n/en.ts`, `cloud*` keys), with the portal at `https://portal.nousresearch.com`;
  - account sign-in + agent discovery is deferred to #160.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task), matching the project.
- complete each task fully before moving to the next; commit at each task completion (no conventional prefixes, capitalized verb).
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - reducers: exhaustive `TestStore` + `@Dependency` overrides + `TestClock` (Swift Testing, as in the existing suites)
  - pure models: plain `@Test` functions with table-driven cases
  - views: snapshot tests (`make snapshot` twice for each new test: record, then assert); measured `UIWindow` XCTest for layout facts a snapshot cannot prove
- **CRITICAL: all tests must pass before starting next task** — `make test` (HermesKit) and `make snapshot` (app) as relevant
- **CRITICAL: update this plan file when scope changes during implementation**
- backward compatibility: token mode stays byte-identical to the legacy path; `AppFeature`'s `.onboarding(.delegate(.connected))` contract is unchanged.

## Testing Strategy
- **unit tests** (HermesKit, `make test`): every new model, reducer and client endpoint; existing `ConnectionFeatureTests` cases are ported to the step reducer that now owns the behaviour, not deleted.
- **snapshot tests** (HermesMobileTests, `make snapshot`): one baseline per visible state (light; dark where the step introduces new colours). Existing `ConnectionView` baselines are replaced in the same PR.
- **measured layout test**: the onboarding column cap on iPad (replaces `ConnectionColumnLayoutTests`).
- no UI e2e suite exists in this project; manual device checks are listed under Post-Completion.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

**Navigation: a stack of small features (TCA stack navigation).** `ConnectionFeature` becomes the flow parent:

```swift
@Reducer enum ConnectionPath {   // top-level, not nested (TCA convention)
  case server(ServerStep)
  case signIn(SignInStep)
}

@Reducer struct ConnectionFeature {
  @ObservableState struct State {
    var lastProbedCapability: ServerAuthCapability?   // for AppFeature's re-sign-in label
    var path = StackState<ConnectionPath.State>()
    var prefilledToken: String?                       // credentials-verdict recovery only
  }
  enum Action {
    case connectButtonTapped                          // Welcome primary CTA
    case delegate(Delegate)                           // .connected(ServerConnection), unchanged
    case path(StackActionOf<ConnectionPath>)
  }
  // body: Reduce { … }.forEach(\.path, action: \.path) { ConnectionPath.body }
}
```

- **Welcome** is the stack root rendered by `ConnectionView`. It has no reducer of its own; its one action lives on the parent.
- `ServerStep` probes and reports `.delegate(.probeSucceeded(ServerProbe))`. The parent appends `.signIn(SignInStep.State(probe:prefilledToken:))`.
- `SignInStep` owns the three auth effects (moved verbatim from today's `ConnectionFeature`) and reports `.delegate(.connected)`. The parent re-emits it as its own delegate, so `AppFeature` is untouched apart from state construction.
- Popping Sign in (swipe-back or "Change") removes the stack element. TCA cancels that element's effects, which replaces today's hand-written "URL edit cancels the OAuth attempt" `onChange`. `performNativeOAuthLogin` already treats cancellation as a silent verdict and never drains the store.
- A Sign in step cannot exist without a `ServerProbe`, so "sign-in UI with no capability" is unrepresentable.

**Entry points:**

| Landing | State | Shows |
|---|---|---|
| First launch, logout, "Quit to start", retry-screen Log Out, Settings disconnect | `ConnectionFeature.State()` | Welcome |
| Credentials verdict (`fallBackToOnboarding`) | `.init(recovering: url, token:)`, path = `[.server(addressText: url, autoProbe: true)]`, `prefilledToken = token` | Server auto-probes, then pushes Sign in with the token prefilled |

Every logout clears the server URL pref, so a real logout lands on Welcome. The prefilled path is only the credentials-verdict fallback. The prototype's "After logout" button shows this fallback.

**Errors are typed end to end.**
- A pure `ProbeFailure` classifier works on the raw `URLError` / HTTP response, before anything is flattened to `RESTError`.
- It is exposed through a new `HermesRESTClient.probeStatus` endpoint, so `RESTError` and its about 115 references stay untouched.
- The launch path (#62) keeps using `rest.status`/`RESTError` unchanged.

**The address is a value type.** `ServerAddress` parses the typed text once and answers every policy question:
- the candidate URLs (as typed, then `:9119` for http without a port)
- the network kind (loopback, local network, tailnet, public)
- whether a failure card adds the Local Network hint
- whether to warn about public cleartext

It is pure, has no `#if canImport(UIKit)` and is fully unit-tested.

**Local network addresses are treated like any other address.**
- No explainer before the iOS alert, and no attempt to detect a denial; the iOS Local Network alert itself is the system's and appears on its own.
- When a probe to a local-network address fails with a transport error (`hostNotFound`, `refused`, `timedOut`), the failure card adds one line: "If iOS asked about Local Network access, allow it and try again. You can change it in Settings › Privacy & Security › Local Network."
- This covers both the first request failing while the alert is up and a user who tapped Don't Allow, without device-only detection code.

**Push permission moves behind a card.**
- `SessionListFeature` stops calling `requestAuthorization()` from `setupPush` and sets `pushCard: PushCard?`:
  - `.enableNotifications` when the plugin is ready, the status is `.notDetermined` and the prompt isn't snoozed;
  - `.installPlugin` when the plugin isn't ready and the prompt isn't snoozed.
- Already authorized: register silently, as today. Denied: nothing.
- "Not now"/"Later" uses the existing Fibonacci snooze. `PushSetupGuideView` stays as the Settings destination and is no longer auto-raised.

**Explicitly out of scope:**
- The 0.5 s "Connected" beat. It's an open question in #136, so the app lands on home directly as today.
- Starter prompts in an empty chat. Desktop has none (desktop parity).
- Hermes Cloud account sign-in + agent picker: #160. 1.0 keeps paste-the-address + Nous sign-in.
- Redesigning `ReauthView` and `ConnectionFailedView`. They keep their own UI; reusing the new cards there is a follow-up.

## Technical Details

**`ServerAddress`** (`Models/ServerAddress.swift`):

```swift
public struct ServerAddress: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case loopback, localNetwork, tailnet, publicHost }
  public let typed: String
  public let url: URL              // scheme defaulted to http://, port as typed
  public let host: String
  public let portWasGiven: Bool
  public let kind: Kind
  public init?(_ text: String)     // nil = invalid (same leniency as parseServerURL)
  public var candidates: [URL]     // [url] or [url, url:9119] (http && !portWasGiven)
  public var isPublicCleartext: Bool { url.scheme == "http" && kind == .publicHost }
}
```

- `localNetwork` covers RFC 1918 and `*.local`.
- `tailnet` covers 100.64/10, `*.ts.net` and single-label names.
- This is a heuristic. The only effect of a wrong guess is whether the Local Network hint line appears on a failure card.

**`ProbeFailure`** (`Models/ProbeFailure.swift`):

```swift
public enum ProbeFailure: Error, Equatable, Sendable {
  case offline                      // .notConnectedToInternet / .dataNotAllowed / .internationalRoamingOff
  case hostNotFound(tailnetName: Bool)  // .cannotFindHost / .dnsLookupFailed
  case refused                      // .cannotConnectToHost
  case timedOut                     // .timedOut / .networkConnectionLost
  case untrustedCertificate         // .serverCertificate* / .secureConnectionFailed / .clientCertificate*
  case notHermes(httpStatus: Int?)  // 404, non-JSON 2xx, or decoding failure on /api/status
  case hostRejected(detail: String) // 400 whose detail starts "Invalid Host header"
  case other(String)                // anything else, server copy verbatim
  public var isTransport: Bool      // hostNotFound / refused / timedOut: fallback-port and Local Network hint gate
  public static func classify(_ error: any Error, address: ServerAddress) -> ProbeFailure
  public static func classify(httpStatus: Int, contentType: String?, detail: String?) -> ProbeFailure
}
```

**`ServerProbe`** (`Models/ServerProbe.swift`):

```swift
public struct ServerProbe: Equatable, Sendable {
  public let address: ServerAddress
  public let baseURL: URL           // the candidate that answered (may carry :9119)
  public let capability: ServerAuthCapability
  public let version: String?
}
```

**`SignInStep.State.Layout`** is derived and pure, computed from `capability` (mirrors today's `methodHint` / `showsPasswordSegment` rules):

| Capability | Layout |
|---|---|
| password available, OAuth available | `.password(oauthProviders: [...])`: fields first, provider buttons under "or" |
| password available, OAuth too old | `.password(oauthProviders: [])` + `needsNewerAgentFor: names` |
| password available, no OAuth | `.password(oauthProviders: [])` |
| no password, OAuth available | `.oauthOnly(providers)` |
| no password, OAuth too old | `.token(reason: .oauthNeedsNewerAgent(names))` |
| not gated (token-only server) | `.token(reason: .tokenOnlyServer)` |

The token field is also reachable under "Other ways to sign in" (`isShowingOtherWays`) in the two non-token layouts.

**`ServerStep`:**

```swift
@ObservableState struct State {
  var addressText: String
  var autoProbe: Bool               // credentials-verdict entry: probe on appear
  var phase: Phase                  // .idle | .probing(Stage) | .failed(ProbeFailure, ServerAddress)
  enum Stage { case reaching, readingSignInOptions }
}
enum Action: BindableAction {
  case binding(BindingAction<State>)            // editing resets phase to .idle + cancels the probe
  case continueButtonTapped
  case delegate(Delegate)                       // .probeSucceeded(ServerProbe)
  case onAppear
  case probeResponse(Result<ServerProbe, ProbeFailure>)
  case statusReceived                           // advances .reaching → .readingSignInOptions
}
```

Probe effect (one cancellable `CancelID.probe`):
1. For each candidate, call `rest.probeStatus(candidate)`. Move to the next candidate only on `failure.isTransport`. An HTTP answer, including 404 or 400, stops the loop.
2. On success, send `.statusReceived`. If `authRequired == true`, fetch `rest.authProviders`; a failure is swallowed as nil, same as today.
3. Build `ServerAuthCapability(from:providers:)` and send `.probeResponse(.success(ServerProbe))`.
4. The failure card derives the Local Network hint from `address.kind == .localNetwork && failure.isTransport`. It's a view decision, so no reducer state is involved.

**`SignInStep`:**

```swift
@ObservableState struct State {
  let probe: ServerProbe
  var isShowingOtherWays = false
  var password = ""
  var selectedOAuthProviderName: String?
  var status: Status = .idle        // .idle | .validating | .invalidCredentials | .invalidToken | .failed(String)
  var token: String
  var username = ""
}
enum Action: BindableAction {
  case binding(BindingAction<State>)
  case changeServerButtonTapped     // @Dependency(\.dismiss) → pops back to Server
  case delegate(Delegate)           // .connected(ServerConnection)
  case oauthLoginResponse(Result<ServerConnection, OAuthFlowError>)
  case oauthProviderButtonTapped(AuthProvider)
  case otherWaysButtonTapped
  case passwordLoginResponse(Result<ServerConnection, RESTError>)
  case passwordSignInButtonTapped
  case tokenSignInButtonTapped
  case tokenValidationResponse(Result<ServerConnection, RESTError>)
}
```

The effects are moved verbatim from `ConnectionFeature.connectTapped`, with `baseURL = probe.baseURL`. The connection is built from the URL that answered, so the `:9119` fallback is what gets saved.

**New dependencies:**
- `HermesRESTClient.probeStatus: @Sendable (URL) async -> Result<ServerStatus, ProbeFailure>`. The live client uses the same session as `status` but classifies the raw `URLError`/HTTP response with `ProbeFailure.classify`. `testValue` is unimplemented.
- `PreferencesClient.load/saveOnboardingTipsDismissed`, cleared by the logout recipe (`clearIdentityScopedPrefs` or an explicit call in each logout branch, whichever the existing code uses).

**Session list (`SessionListFeature`):**
- `pushCard: PushCard?`, with `enum PushCard { case enableNotifications, installPlugin }`
- actions: `pushCardEnableButtonTapped` (→ existing `.requestPushAuthorization`), `pushCardAskAgentButtonTapped` (→ existing `.delegate(.createSession(initialComposerText: PushSetup.installPrompt))`), `pushCardNotNowButtonTapped` (→ existing snooze save)
- `showsOnboardingTips: Bool` (from prefs) and `onboardingTipsHideButtonTapped`
- the profiles tip shows only when `profilesSupported`

**Setup guide — Hermes Cloud tab copy** (desktop terms, paste-the-address flow):

> **Hermes Cloud runs your agent for you.** Open your agent in the Nous portal, copy its address, and paste it on the next screen. You'll sign in with your Nous Research account.
> No agent yet? Create one in the Nous portal.

The link goes to `https://portal.nousresearch.com`, desktop's `FALLBACK_PORTAL_URL`.

**Views (thin, `HermesMobile/Sources/Features/Onboarding/`):**
- `ConnectionView` owns `NavigationStack(path: $store.scope(state: \.path, action: \.path)) { WelcomeView } destination: { … }`
- `ServerStepView`, `SignInStepView`, `ProbeFailureCard`, `ServerCard`
- column cap `OnboardingLayout.maxWidth = 480` on the outer container only (CLAUDE.md capped-width rule)
- `AppView` drops its own `NavigationStack` wrapper around `ConnectionView`
- the setup guide stays a view-local `@State` sheet, opened from Welcome's secondary CTA, Server's "Where do I find the address?", and each failure card's "Setup guide", plus `ConnectionFailedView` (unchanged)

## What Goes Where
- **Implementation Steps**: everything in HermesKit, HermesMobile, tests, README, docs and CLAUDE.md.
- **Post-Completion**: device-only checks (iOS Local Network alert behaviour, the OAuth browser leg against a real Nous agent), App Store screenshot re-capture and upload, and a TestFlight build.

## Implementation Steps

### Task 1: Add `ServerAddress` parsing and network classification

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/ServerAddress.swift`
- Create: `HermesKit/Tests/HermesKitTests/ServerAddressTests.swift`

- [x] implement `ServerAddress.init?(_:)` with the same leniency as `parseServerURL` (http default, host required) and keep `parseServerURL` for its existing callers
- [x] implement `kind`, `candidates`, `isPublicCleartext`
- [x] table-driven tests: bare name, `*.ts.net`, 100.64/10 edges (100.63.x and 100.128.x are public), RFC 1918 edges (172.15 and 172.32 are public), `.local`, localhost/127.x, https with and without a port, explicit port, IPv6 literal, whitespace, invalid input
- [x] tests: candidates add `:9119` only for http with no port; public cleartext only for http + public host
- [x] run `make test` and confirm it passes before task 2

### Task 2: Add `ProbeFailure` classification and the `ServerProbe` model

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/ProbeFailure.swift`
- Create: `HermesKit/Sources/HermesKit/Models/ServerProbe.swift`
- Create: `HermesKit/Tests/HermesKitTests/ProbeFailureTests.swift`

- [x] implement `ProbeFailure.classify(_:address:)` for `URLError` codes (table in Technical Details); a non-`URLError` maps to `.other`
- [x] implement `classify(httpStatus:contentType:detail:)`: 404 → `.notHermes`, 400 + "Invalid Host header" → `.hostRejected(detail)`, others → `.other(detail ?? "HTTP \(status)")`
- [x] implement `isTransport`; add `ServerProbe` (Equatable, Sendable, public init for snapshot/demo targets)
- [x] tests for every `URLError` row, including `hostNotFound(tailnetName:)` for a `.ts.net` versus a public name, and `isTransport` per case
- [x] tests for the HTTP rows, including a 400 whose detail is something other than the Host message
- [x] run `make test` and confirm it passes before task 3

### Task 3: Add the `probeStatus` REST endpoint

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [x] add `probeStatus` to the `@DependencyClient`. The live implementation calls `GET /api/status` on the injected session, decodes `ServerStatus` on 2xx (decode failure → `.notHermes(httpStatus: 200)`), and classifies non-2xx and transport errors with `ProbeFailure.classify`
- [x] leave `status`, `RESTError` and `RESTError(transport:)` untouched; the launch path keeps using them
- [x] `URLProtocol`-stub tests: 2xx decode, 2xx HTML, 404, 400 Host detail, transport errors (`.cannotFindHost`, `.cannotConnectToHost`, `.timedOut`, `.serverCertificateUntrusted`)
- [x] run `make test` and confirm it passes before task 4

### Task 4: Build `SignInStep` (layout + auth effects moved from `ConnectionFeature`)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/Onboarding/SignInStep.swift`
- Create: `HermesKit/Tests/HermesKitTests/SignInStepTests.swift`

- [x] implement `State` and `Layout` derivation (table in Technical Details); `token` initialised from `prefilledToken ?? ""`
- [x] move the token, password and OAuth effects from `ConnectionFeature.connectTapped` verbatim, using `probe.baseURL`. Token persistence stays byte-identical. Keep `CancelID.oauthLogin` with `cancelInFlight: true` for a second provider tap.
- [x] move the response handling verbatim (`.invalidToken`, `.invalidCredentials`, OAuth `.login(.cancelled)` → back to `.idle` with no copy, `.validation(.unauthorized)` → `.invalidCredentials`, else `.failed(message)`)
- [x] `changeServerButtonTapped` → `await dismiss()`; `otherWaysButtonTapped` toggles the token disclosure
- [x] port the relevant `ConnectionFeatureTests` cases: token success and 401, password success, 401 and 429, OAuth success, cancel, validation 401, superseding provider tap, Keychain/prefs writes
- [x] new tests: layout per capability row, prefilled token, `canSubmit` gating per layout, `dismiss` on Change
- [x] run `make test` and confirm it passes before task 5

### Task 5: Build `ServerStep` (address, probe stages, fallback port, failures)

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/Onboarding/ServerStep.swift`
- Create: `HermesKit/Tests/HermesKitTests/ServerStepTests.swift`

- [x] implement `State`/`Action` as specified; `continueButtonTapped` parses `addressText` (invalid → stays `.idle`, view shows the inline hint) and starts the probe
- [x] probe effect: candidate loop (fallback only on `isTransport`), `.statusReceived` stage advance, providers fetch; `.failed` carries the `ServerAddress` the card needs for its copy and the Local Network hint
- [x] binding on `addressText` → phase `.idle`, `.cancel(id: CancelID.probe)`; `onAppear` probes only when `autoProbe && phase == .idle`
- [x] `TestStore` tests (mocked `probeStatus`/`authProviders`):
  - [x] success on the first candidate
  - [x] fallback to `:9119` after a refused, and the success carries the `:9119` URL
  - [x] no fallback after a 404 or a 400
  - [x] each failure lands in `.failed` with its address
  - [x] editing cancels an in-flight probe
  - [x] auto-probe on appear and no re-probe on re-appear
- [x] run `make test` and confirm it passes before task 6

### Task 6: Turn `ConnectionFeature` into the flow parent with `ConnectionPath`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ConnectionFeature.swift`
- Create: `HermesKit/Sources/HermesKit/Features/Onboarding/ConnectionPath.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ConnectionFeatureTests.swift` (reduce to flow tests; per-step cases moved in tasks 4–5)

- [x] `@Reducer enum ConnectionPath { case server(ServerStep); case signIn(SignInStep) }` at top level
- [x] parent `State` (`path`, `prefilledToken`, `lastProbedCapability`), `init()` (Welcome) and `init(recovering url: URL, token: String?)` (path `[.server(autoProbe: true)]`)
- [x] `connectButtonTapped` → append `.server`; `.path(.element(_, .server(.delegate(.probeSucceeded(probe)))))` → record `lastProbedCapability`, append `.signIn(probe:, prefilledToken:)`; `.signIn(.delegate(.connected))` → `.delegate(.connected)`
- [x] keep `performNativeOAuthLogin`, `isCancellation`, `OAuthFlowError`, `asRESTError` where `ReauthFeature` and `AppFeature` import them; delete `AuthMethod`, `Status`, `MethodHint` and the URL `onChange` once nothing references them (`AuthMethod` kept: `ReauthFeature` still uses it)
- [x] flow tests:
  - [x] Welcome → Server → probe → Sign in → connected delegate
  - [x] popping Sign in mid-OAuth cancels the effect (no delegate, store not drained, verified via `BearerTokenStore` test double)
  - [x] the recovering initializer auto-probes and passes the token
  - [x] `lastProbedCapability` survives a pop
- [x] run `make test` and confirm it passes before task 7
- ⚠️ the HermesMobile app target (`ConnectionView`, `DemoMode`, `ConnectionSnapshotTests`, `AuthSnapshotTests`, `ConnectionColumnLayoutTests`) still uses the removed one-screen API and does not compile until task 8 (views) / task 12 (demo mode) — resolved in task 8

### Task 7: Wire `AppFeature` to the new onboarding state

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift` (and any other suite constructing `ConnectionFeature.State`)

- [x] `fallBackToOnboarding` builds `ConnectionFeature.State(recovering:token:)`; the bearer drain stays as is
- [x] the re-sign-in provider label reads `state.onboarding.lastProbedCapability?.oauthProviders ?? []`
- [x] every logout/disconnect branch keeps `state.onboarding = .init()` (Welcome) and clears the new tips pref
- [x] update tests: credentials-verdict landing (path shape + token), logout landing on Welcome, logout clears the new pref, the re-sign-in label from the last probe
- [x] run `make test` and confirm it passes before task 8
- ➕ `PreferencesClient.load/save/clearOnboardingTipsDismissed` added here (live + in-memory) so the logout clearing is testable now; task 11 only reads/saves it

### Task 8: Build the onboarding views and replace `ConnectionView`

**Files:**
- Modify: `HermesMobile/Sources/Features/ConnectionView.swift` (stack host + Welcome root)
- Create: `HermesMobile/Sources/Features/Onboarding/WelcomeView.swift`
- Create: `HermesMobile/Sources/Features/Onboarding/ServerStepView.swift`
- Create: `HermesMobile/Sources/Features/Onboarding/SignInStepView.swift`
- Create: `HermesMobile/Sources/Features/Onboarding/ProbeFailureCard.swift`
- Create: `HermesMobile/Sources/Features/Onboarding/OnboardingLayout.swift`
- Modify: `HermesMobile/Sources/AppView.swift`
- Modify: `HermesMobileTests/ConnectionSnapshotTests.swift`, replace `HermesMobileTests/ConnectionColumnLayoutTests.swift`

- [x] `ConnectionView`: `NavigationStack(path:)` + `destination` switch over `ConnectionPath` cases; `AppView` drops its wrapper; run `tuist generate`
- [x] Welcome copy, three value rows and two CTAs from the prototype; the guide sheet stays view-local `@State`
- [x] Server step:
  - [x] field with `.keyboardType(.URL)` and the live "Connects to …" line from `ServerAddress` (with "then :9119 if nothing answers")
  - [x] a checklist driven by `phase`
  - [x] a `ProbeFailureCard` per `ProbeFailure`: copy from the prototype, `--host`/`dashboard.public_url` wording, the Local Network hint line for local-network addresses on transport failures, a Details disclosure
- [x] Sign in step: `ServerCard` (host, version, method summary, Change), the layout from `SignInStep.State.Layout`, plain-text provider buttons (5.2.1 rule kept), the cleartext warning, error copy naming `HERMES_DASHBOARD_BASIC_AUTH_*` / `HERMES_DASHBOARD_SESSION_TOKEN`
- [x] respect Dynamic Type (scrolls), VoiceOver labels on checklist rows and cards, reduce motion (no custom transitions beyond the stack's), `OnboardingLayout.maxWidth = 480` on the outer container only
- [x] snapshots: Welcome; Server idle, probing and each failure card (plus one with the Local Network hint); Sign in for each layout row, the cleartext warning, invalid credentials, invalid token; dark variants for Welcome and one failure card
- [x] measured test: the column is capped at 480 and centred in a wide window, and is uncapped on a phone
- [x] run `make snapshot` (twice for new tests) and `make test`, both clean, before task 9
- ➕ pure view-support logic added to HermesKit (unit-tested): `ServerStep.State.status(of:)` checklist, `ProbeFailure.failedCheck` / `showsLocalNetworkHint(for:)`, `SignInStep.State.methodSummary` / `oauthProviderNames`; `SignInStep` clears `selectedOAuthProviderName` on a password/token attempt so the view can attribute an `.invalidCredentials` verdict
- ➕ `DemoMode` "connect" minimally fixed to compile (Server step prefilled); task 12 reshapes it to the Sign in step

### Task 9: Add the Hermes Cloud tab to the setup guide and sync the README

**Files:**
- Modify: `HermesMobile/Sources/Features/AgentSetupGuideView.swift`
- Modify: `README.md`
- Modify: `HermesMobileTests/` setup-guide snapshot suite

- [x] add a local-`@State` segmented control: "On my computer" (existing cards unchanged) / "Hermes Cloud" (copy and portal link from Technical Details)
- [x] add the matching Hermes Cloud line to the README quick-start, keeping it verbatim with the sheet
- [x] snapshots for the Cloud tab; re-record the existing guide snapshots only if their render size changed
- [x] run `make snapshot` and confirm it is clean before task 10
- ➕ the two existing guide baselines were re-recorded: the picker above the scroll shifts their content (the canvas size is fixed, so "render size" never changes); the collapsed canvas grew 2050 → 2100pt so the docs link isn't clipped

### Task 10: Replace the immediate push prompt with the session-list card

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Create: `HermesMobile/Sources/Features/PushCardView.swift`
- Modify: `HermesMobileTests/` session-list snapshot suite

- [x] `.pushPluginStatusLoaded(.ready)`: read `push.authorizationStatus()`. `.notDetermined` + not snoozed → `pushCard = .enableNotifications`; `.authorized` → `.requestPushAuthorization` (silent register, as today); denied → nothing.
- [x] `.notReady` + not snoozed → `pushCard = .installPlugin` instead of `showPushSetupSheet = true`. Keep the sheet for its Settings entry point.
- [x] card actions reuse the existing `.requestPushAuthorization`, `.delegate(.createSession(initialComposerText: PushSetup.installPrompt))` and snooze save; each clears `pushCard`
- [x] the card is the first list row (above the date sections), with the generic notification preview (privacy rule: no content), and is hidden while searching
- [x] tests: each `(plugin status × authorization status × snoozed)` combination; the snooze count increments; Ask Agent emits the create-session delegate; no `requestAuthorization` call before the Enable tap
- [x] snapshots: both card variants, light + dark (device image, since this is a `List`)
- [x] run `make test` and `make snapshot` and confirm both are clean before task 11
- ➕ the list's `showPushSetupSheet` + `pushSetupAskAgentTapped`/`pushSetupLaterTapped` are removed (Settings presents `PushSetupGuideView` from its own view-local `@State`); new `pushAuthorizationStatusLoaded` action carries the permission read; the snooze is cleared on an authorized/provisional verdict instead of on every `.ready`
- ➕ `State.showsPushCard` (Sessions tab, no query): while the card shows, the "No sessions" placeholder is a row under it instead of the centred overlay (snapshot `pushCard_emptyList`)

### Task 11: Add the dismissible onboarding tips to the session list

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Create: `HermesMobile/Sources/Features/OnboardingTipsView.swift`
- Modify: tests as above

- [x] `showsOnboardingTips` seeded from `preferences.loadOnboardingTipsDismissed()`; `onboardingTipsHideButtonTapped` saves and hides; cleared by logout
- [x] three tips (profiles only when `profilesSupported`, voice, swipe actions) in a horizontal paging row under the push card; respect reduce motion
- [x] tests: hide persists; profiles tip gating; logout clears the flag (AppFeature logout test)
- [x] snapshots: tips row with and without the profiles tip
- [x] run `make test` and `make snapshot` and confirm both are clean before task 12
- ➕ `PreferencesClient` needed no change (task 7 added the pref); seeded both in `AppFeature.makeHomeState` (no flash of hidden tips) and the list's `reloadPrefs`; `State.showsOnboardingTipsRow` / `onboardingTips` / `showsInlineEmptyPlaceholder` (the "No sessions" placeholder flows under the tips like under the push card); demo mode keeps its captures tip-free

### Task 12: Update demo mode and the Local Network plist comment

**Files:**
- Modify: `HermesMobile/Sources/DemoMode.swift`
- Modify: `Project.swift`

- [x] the "connect" scenario builds a path of `[.server, .signIn(probe: password + Nous capability)]` so the screenshot shows the new Sign in step; other scenarios still land signed in
- [x] fix the `NSLocalNetworkUsageDescription` comment: Tailscale/VPN traffic does not trigger the prompt (TN3179); the user-facing string is unchanged
- [x] build the app (`make run` or `xcodebuild`) and launch the demo "connect" scenario once to confirm it renders
- [x] run `make test` and `make snapshot` and confirm both are clean before task 13
- ➕ the demo address is the tailnet name `mac-mini.tail4c2e.ts.net` (answered on the `:9119` fallback), not the scenarios' `mac.tailnet`, which classifies as a public host and would show the cleartext warning in the capture

### Task 13: Verify acceptance criteria
- [x] every row of the #136 gap-analysis table marked "adjust app" is implemented, except the rows this plan defers or drops: the connected beat, the Local Network explainer/detection, starter prompts
- [x] token mode is byte-identical: the token tests ported in task 4 assert the same Keychain/prefs writes as before
- [x] OAuth: provider button only with positive evidence; cancel is silent; popping Sign in cancels the attempt
- [x] iPad regular width, Dynamic Type (accessibility sizes scroll), VoiceOver order, reduce motion checked in the simulator (VoiceOver listening order partly skipped: the AXe element order was read top to bottom, but listening needs a human; reduce motion verified by reading the code: the onboarding screens have no custom animations, and the push card and tips animate only with reduce motion off)
- [x] run the full suite: `make test`
- [x] run snapshots: `make snapshot` (expect the new total; zero failures)
- ➕ fixed three layout bugs found at accessibility text sizes (AX5 on the iPhone simulator): `OnboardingFlowLayout` reported a chip's ideal width past its proposal, so the Server step's column grew past the screen and clipped both edges; the pinned footer filled most of the phone and squeezed the Welcome body to a sliver (it now scrolls as the content's last block at accessibility sizes); `ServerCard` kept one row, breaking words mid-word (it now stacks). Covered by a measured flow-layout test and three AX3 snapshots
- ➕ the earlier `ac7e42d` re-record is legitimate drift: same 1170×8100 size, one pixel differing by 1/255

### Task 14: [Final] Update documentation
- [x] create `docs/features/onboarding.md`: flow, entry points table, `ProbeFailure` table, the Local Network rule (TN3179, hint line instead of an explainer), port fallback, push card, tips, pointer to #160
- [x] update `docs/architecture.md` (onboarding section) and `docs/features/push-notifications.md` (permission now behind the card)
- [x] update CLAUDE.md, staying near ~200 lines with bullets as rule + pointer:
  - [x] the Login help bullet: entry points changed
  - [x] the push bullet: "permission requested on sessions-list appearance" → card
  - [x] a new onboarding bullet pointing to `docs/features/onboarding.md`
  - [x] note the `ConnectionPath` stack
- [x] move this plan to `docs/plans/completed/` (done by the orchestrator after reviews)
- ➕ `docs/features/oauth-sign-in.md` rewritten where it described the removed segmented toggle (now the Sign in layout); the snapshot count in CLAUDE.md and `docs/development.md` updated to 397

## Post-Completion
*Items requiring manual intervention or external systems. Informational only.*

**Manual verification on a real device:**
- Same-Wi-Fi IP on a fresh install: iOS Local Network alert appears. If the first probe fails behind it, the card shows the Local Network hint, and Try again after Allow connects. Don't Allow shows the same hint.
- Tailscale `*.ts.net` with Tailscale off → "Is Tailscale on?"; with Tailscale on → no Local Network alert.
- Dashboard stopped → "refused" card. Dashboard bound to a specific IP and reached by name → "address rejected" card.
- Bare host without a port → connects via the `:9119` fallback, and the saved URL carries `:9119`.
- Real Nous agent: password-first layout, provider button below, OAuth round trip, cancel, swipe back mid-sheet.
- First list appearance: card shown, no system prompt until "Turn on".

**External:**
- Re-capture and upload the App Store "connect" screenshot (screenshot re-capture recipe).
- Remaining #136 open question: whether to add the "Connected" beat later.
- Hermes Cloud sign-in + agent picker: #160 (waiting on whether Nous plans a native-app portal flow).
- Internal TestFlight build after merge.
