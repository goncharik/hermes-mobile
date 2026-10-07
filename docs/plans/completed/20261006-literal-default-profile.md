# Send the literal default profile on session-scoped calls (#114)

## Overview
- When the selected profile is `"default"`, every session-scoped call drops `profile`
  (`SessionListFeature.State.scopedProfileName` and `ChatFeature.State.scopedProfile`, both
  default→nil). The server does not read an omitted profile as `"default"`; it reads it as the
  dashboard process's **launch** profile:
  - REST: `_session_db_path_for_profile(None)` → `_default_db_path()` = the process's own
    `HERMES_HOME` (`hermes_cli/web_server_sessions.py:192-200`). An explicit `"default"` →
    `_cron_profile_home` → `get_profile_dir("default")` (`web_server_cron.py:113-124`,
    `profiles.py:430-434`). `profile_exists("default")` is always true (`profiles.py:445-454`).
  - Gateway: `_profile_home(None)` → launch profile; `_profile_home("default")` → the default
    dir, or `None` when that already IS the launch home (`tui_gateway/server.py:567-588`).
    Single-profile installs therefore see no behaviour change from an explicit `"default"`.
- The main list already reads the literal name (`profiles.sessions(connection, profileName, …)`,
  `SessionListFeature.swift:1650` → `/api/profiles/sessions?profile=default` →
  `get_profile_dir("default")`). So when the dashboard runs under a non-default launch profile
  (`hermes -p work dashboard`, a desktop pool backend), the list shows `default`'s sessions
  while archive/rename/delete/unread, the archived sheet, and chat
  `session.create`/`session.resume` all hit `work`'s `state.db`. The symptoms are
  the wrong row changing, a 404 or silent no-op, or a resume that misses and #17-self-heals
  into a brand-new session in the wrong profile.
- Fix: whenever the agent has the profiles API, send the literal selected name (including
  `"default"`) on every session-scoped call. Keep omitting it only when the agent lacks
  the profiles API, so those agents stay byte-identical.

## Context (from discovery)
- Wire value sources:
  - `SessionListFeature.State.scopedProfileName` (`SessionListFeature.swift:223-228`) feeds
    archive (`:957`), delete (`:1019`), rename (`:1134`), archived-sheet seeding (`:1188`), and
    every `ChatFeature.State.profileName` seeded by `AppFeature` (`:536`, `:794`, `:1174`).
  - `ChatFeature.State.scopedProfile` (`ChatFeature.swift:680-687`) strips `"default"` a
    second time. It feeds every create/resume/branch/hydrate/messages/slash-refresh call
    (~18 sites).
  - `ArchivedSessionsFeature.State.profileName` (`ArchivedSessionsFeature.swift:15-19`,
    `:159-161`, `:255-265`): nil → the unscoped `rest.archivedSessions` list and an unscoped
    restore.
  - Unread (#104): `AppFeature.swift:947` passes the chat's `profileName` to `rest.setUnread`.
- Identity comparisons that use the same nil-for-default value:
  - `AppFeature.swift:144` (`profileReseatSignal`)
  - `:811` (`canPatchVisibleRow`)
  - `:941` (unread row patch)
  - `:1030` (`reduceProfileReseat`)
  - `:1056` (`isReusableNewChat`)
  - `SessionListFeature.swift:1548` (rollback re-insert)
- Already literal, no change: the cron fetch (`SessionListFeature.swift:719`) and the
  profile-scoped list fetch (`:1650`).
- `profilesSupported` starts `false` and flips `true` when `GET /api/profiles` answers
  (`SessionListFeature.swift:1275`). So on every launch the wire value moves from nil to
  `"default"`. A chat seated before then (cold-launch push tap, first regular-width fill)
  keeps `profileName == nil`.

## Development Approach
- **testing approach**: Regular (code first, then tests), with TCA `TestStore` and
  `@Dependency` overrides capturing the `profile` argument.
- Complete each task fully before moving to the next, with small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task.
  - Write unit tests for new and modified functions.
  - Add test cases for new code paths, and update existing ones whose expectation changes
    from `nil` to `"default"`.
  - Cover both success and error scenarios.
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Backward compatibility: agents without the profiles API must send byte-identical
  requests (no `profile` anywhere).

## Testing Strategy
- **Unit tests**: HermesKit `swift test` (`make test`) for every task. Use reducer tests that
  record the `profile` passed to `rest.archive`/`rename`/`deleteSession`/`setUnread`/
  `archivedSessions`/`profiles.sessions` and to the gateway `session.create`/`session.resume`
  params.
- **Snapshot tests**: none. No view changes.
- No UI e2e suite in this project.

## Progress Tracking
- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with a ➕ prefix.
- Document issues and blockers with a ⚠️ prefix.
- Keep the plan in sync with the work actually done.

## Solution Overview
As shipped (see "Review-driven changes" below):

1. **Wire profile**: `scopedProfileName` becomes `profilesSupported ? selectedProfileName : nil`,
   so the literal `"default"` is sent when the API exists. `ChatFeature` threads its
   `profileName` verbatim (`scopedProfile` is deleted). Search, cron, archive/rename/delete,
   the archived sheet, unread and chat create/resume all take this value. The reseat,
   reusable-seat and rollback checks compare wire values, so a seat dialled `nil` before the
   profiles probe is reseated once the list moves to `"default"`.
2. **Persisted capability verdict**: the selection is saved on every successful profiles
   probe and cleared on its 404 (and on logout).
   `SessionListFeature.State.persistedProfilesSupported` seeds `profilesSupported` in
   `AppFeature.makeHomeState`, so chats opened before the probe answers (cold-launch push
   replay, the regular-width landing seat) are already scoped.
3. **Row-patch identity**: only the glow/unread patches, which match by session id, treat
   `nil` and `"default"` as the same profile (private `AppFeature.isSameProfile`).

Rejected alternative: a separate `requestProfileName` used only by REST mutations. It
leaves the gateway create/resume asymmetry in place, which is the worst symptom (a resume
miss silently self-heals into a new session in the wrong profile), and it needs two
parallel properties.

Known limitation: with nothing persisted yet (the very first launch after login), a chat
opened before the probe answers stays unscoped, i.e. on the launch profile. The
regular-width seat is reseated; nothing else is.

Review-driven changes: the first cut (Tasks 1 and 4) added `profileKey` (`nil` ≡
`"default"`) for every comparison and kept the old non-default-only capability seeding.
Review showed that left a pre-probe `nil` seat unscoped and uncorrectable, so `profileKey`
was replaced by wire equality plus the persisted verdict, identity was kept only for the
row patches, search was scoped (as on desktop), `isDefaultProfileSelected` was deleted as
dead, and a profiles 404 withdraws the persisted verdict.

## Technical Details
- `SessionListFeature.State`:
  - `public var scopedProfileName: String? { profilesSupported ? selectedProfileName : nil }`
    (doc comment rewritten: an omitted profile means the server's LAUNCH profile, not
    `"default"`).
  - `static func persistedProfilesSupported(_:)` (`loadSelectedProfileID() != nil`) next to
    `persistedProfileName`; `.profilesResponse(.success)` saves the selection every time,
    `.profilesResponse(.failure(.notFound))` clears it.
  - List, search and cron fetches take one `profile: scopedProfileName`; `rest.search` gains
    a `profile` parameter. The rollback re-insert compares wire values.
- `ChatFeature.State.scopedProfile` is deleted; its call sites pass `profileName`.
- `ArchivedSessionsFeature`: no logic change. A non-nil `"default"` now takes the existing
  profile-scoped branch (`profiles.sessions(…, "default", .only, …)`) and the scoped restore.
  Update the doc comment.
- `AppFeature`: `makeHomeState` seeds `profilesSupported` from `persistedProfilesSupported`;
  `profileReseatSignal`, `reduceProfileReseat` and `isReusableNewChat` compare wire values;
  `canPatchVisibleRow` and the unread row patch go through `isSameProfile`.

## What Goes Where
- **Implementation Steps**: code, tests, and docs in this repo.
- **Post-Completion**: manual verification against a non-default launch profile, and the
  follow-up note for PR #113.

## Implementation Steps

### Task 1: Make `scopedProfileName` literal and add `profileKey`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [x] Change `scopedProfileName` to `profilesSupported ? selectedProfileName : nil` and rewrite its doc comment (omitted = server launch profile).
- [x] Add `static func profileKey(_:)` and use it in the rollback re-insert comparison (`:1548`).
- [x] Update the comment at `:1650` (no more "legacy endpoints use default→nil").
- [x] Write tests: with the default profile selected and profiles supported, archive, rename and delete send `"default"`. With profiles unsupported they send `nil`. Non-default still sends the name.
- [x] Write tests: an archive/delete failure rollback still re-inserts the row when the capture was `nil` and the current value is `"default"` (`profileKey` equality). Update any existing tests that expected `nil` for the default profile.
- [x] Run tests (`make test`); they must pass before Task 2.

### Task 2: Scope the archived sheet to the literal default profile

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ArchivedSessionsFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ArchivedSessionsFeatureTests.swift`

- [x] Update the `profileName` doc comment: `nil` now means only that the profiles API is unsupported.
- [x] Verify the sheet seeded from the list with the default profile gets `"default"`, lists via `profiles.sessions(…, "default", .only, …)`, and restores with `profile: "default"`.
- [x] Write tests for the default-profile scoped list and restore, and for the unscoped path when `profileName == nil`.
- [x] Write a test confirming that the sheet's delete delegate reaches the parent and the parent sends `"default"` (lives in `SessionListFeatureTests`, which owns the parent round-trip).
- [x] Run tests; they must pass before Task 3.

### Task 3: Send the literal profile from `ChatFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatBranchTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift` (only where a test expects the default profile to be omitted)

- [x] Make `scopedProfile` return `profileName` unchanged, and update the `profileName` doc comment (`:35-38`) and `scopedProfile` doc (`:680-683`). (Kept the property — inlining ~18 sites adds churn for no gain; also fixed the "default/nil omitted" wording on `createSession`, `branchSession`, `healLiveSessionID`, `createSessionRPC`.)
- [x] Write tests: with `profileName == "default"`, `session.create`, `session.resume`, the #17 heal re-resume/create, and the REST `messages` fetch all carry `profile: "default"`. (ChatFeature has no REST `messages` fetch — history arrives via `session.resume`, covered by the `.ready` and foreground hydrate tests. Heal tests live in `SelfHealTests`; branch create in `ChatBranchTests`.)
- [x] Write tests: with `profileName == nil`, none of them carry `profile` (byte-identical for agents without the profiles API). Update existing tests that seeded `"default"` and expected omission.
- [x] Run tests; they must pass before Task 4.

### Task 4: Compare profiles by identity in `AppFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [x] Feed `profileReseatSignal` with `profileKey(home?.scopedProfileName)`.
- [x] Switch `canPatchVisibleRow` (`:811`), the unread row patch (`:941`), `reduceProfileReseat` (`:1030`) and `isReusableNewChat` (`:1056`) to `profileKey` equality. (Through one private `AppFeature.isSameProfile(_:_:)` helper; a grep of `HermesKit/Sources` found no other nil-vs-`"default"` profile comparison.)
- [x] Write tests: a chat seated with `profileName == nil` before profiles load, then the list flips to `profilesSupported` with `"default"`:
  - no reseat in regular layout,
  - the working glow still patches the row,
  - the unread row patch still applies.
- [x] Write tests: an open default-profile chat calls `rest.setUnread(…, "default")`, and a genuine profile switch (`"default"` → `"work"`) still reseats a pristine regular-width chat.
- [x] Run tests; they must pass before Task 5.

### Task 5: Verify acceptance criteria
- [x] With profiles supported, every session-scoped REST mutation, the archived sheet, and chat create/resume/messages send the literal selected profile, including `"default"`. (Grep of `HermesKit/Sources`: archive/rename/delete/archived-sheet seed → `scopedProfileName`; archived restore/delete → the sheet's seeded `profileName`; `setUnread` → the chat's `profileName` seeded from `scopedProfileName`; every gateway `profile` param → `ChatFeature.scopedProfile`; cron + list fetch already literal. No remaining default-dropping site.)
- [x] Agents without the profiles API send no `profile` anywhere (grep the tests for the unsupported-path assertions). (`wireProfileCases` archive/rename/delete, archived-sheet nil seed/list/restore, chat create `params == {}`, resume/foreground-hydrate/heal `nil` arguments, unread `nil`.)
- [x] No spurious reseat or glow/unread miss across the nil→`"default"` launch transition. (`profilesProbeAnsweringDefaultDoesNotReseatAPreProbeSeat`, `preProbeChatStillPatchesGlowAndUnreadUnderLiteralDefault`, rollback `profileKey` tests.)
- [x] Run the full suite: `make test`. (`swift test --package-path HermesKit`: 1485 tests passed, 1 known issue.)

### Task 6: [Final] Update documentation
- [x] `CLAUDE.md` Multi-profile bullet: replace "omitted for `"default"` so single-profile agents get byte-identical requests" with "the literal name, including `"default"`, whenever the profiles API exists; omitted only without it (an omitted profile means the server's launch profile, #114)". Keep the bullet the same length. (Still 6 lines; the `profileKey` identity rule didn't fit and lives in `docs/architecture.md`.)
- [x] `docs/architecture.md`: update the profile-omission wording at lines ~83, ~160 and ~265-269. (Also `docs/features/ipad-layout.md`: reseat / reusable-seat comparisons now name `profileKey` identity.)
- [x] Move this plan to docs/plans/completed/ (deferred — orchestrator moves it after reviews)

## Post-Completion
*Items requiring manual intervention or external systems; informational only.*

**Manual verification:**
- Run a dashboard under a non-default launch profile (`hermes -p work dashboard`), select
  `default` in the app, then archive, rename, delete, restore from the archived sheet, open
  a chat (it must resume, not self-heal into a new session), and send a prompt. Confirm each
  change lands in the default profile's `state.db`.
- Repeat against a plain single-profile dashboard and confirm nothing changes.

**External:**
- PR #113 (server-synced pins): once this lands, its `setPinned` can take
  `scopedProfileName` like the other mutations instead of special-casing the literal
  `"default"`.
- Close #114 from the implementing PR.
