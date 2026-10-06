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
  `session.create`/`session.resume`/`messages` all hit `work`'s `state.db`. The symptoms are
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
- Identity comparisons that use the same nil-for-default value, and must keep treating
  "default" and "unknown yet" as the same profile:
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
Two concepts are currently conflated in one nil-for-default value. Split them:

1. **Wire profile**: what goes on the request. `scopedProfileName` becomes
   `profilesSupported ? selectedProfileName : nil`, so the literal `"default"` is sent when
   the API exists. `ChatFeature.scopedProfile` stops stripping `"default"` and passes
   `profileName` through. Every existing mutation call site then sends the right value
   without being touched.
2. **Profile identity**: how two values compare. A new `SessionListFeature.State.profileKey(_:)`
   maps `nil` and `"default"` to the same key. Comparisons use it, so a chat seated before
   the profiles probe (`nil`) and the list after it (`"default"`) still count as the same
   profile. Without this, every launch would trigger a spurious regular-width reseat, which
   tears down and redials a healthy seat, and the glow/unread patches would be skipped.

Rejected alternative: a separate `requestProfileName` used only by REST mutations. It
leaves the gateway create/resume asymmetry in place, which is the worst symptom (a resume
miss silently self-heals into a new session in the wrong profile), and it needs two
parallel properties.

Known limitation (pre-existing, out of scope): a chat seated before `profilesSupported`
resolves keeps `profileName == nil` and stays unscoped, i.e. on the launch profile. Today
that already happens for non-default selections; this plan doesn't widen it.

## Technical Details
- `SessionListFeature.State`:
  - `public var scopedProfileName: String? { profilesSupported ? selectedProfileName : nil }`
    (doc comment rewritten: an omitted profile means the server's LAUNCH profile, not
    `"default"`).
  - `public static func profileKey(_ name: String?) -> String?`: returns `nil` for `nil` or
    `defaultProfileName`, otherwise the name.
  - `isDefaultProfileSelected` stays; it still drives rename/delete-profile gating.
- `ChatFeature.State.scopedProfile`: returns `profileName`. Inline it at the call sites
  only if that stays a mechanical rename; otherwise keep the property with a corrected doc.
- `ArchivedSessionsFeature`: no logic change. A non-nil `"default"` now takes the existing
  profile-scoped branch (`profiles.sessions(…, "default", .only, …)`) and the scoped restore.
  Update the doc comment.
- Comparisons → `profileKey(a) == profileKey(b)`: `AppFeature.swift:811`, `:941`, `:1030`,
  `:1056`, `SessionListFeature.swift:1548`. `profileReseatSignal.profileName` is fed
  `profileKey(home?.scopedProfileName)`.

## What Goes Where
- **Implementation Steps**: code, tests, and docs in this repo.
- **Post-Completion**: manual verification against a non-default launch profile, and the
  follow-up note for PR #113.

## Implementation Steps

### Task 1: Make `scopedProfileName` literal and add `profileKey`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`

- [ ] Change `scopedProfileName` to `profilesSupported ? selectedProfileName : nil` and rewrite its doc comment (omitted = server launch profile).
- [ ] Add `static func profileKey(_:)` and use it in the rollback re-insert comparison (`:1548`).
- [ ] Update the comment at `:1650` (no more "legacy endpoints use default→nil").
- [ ] Write tests: with the default profile selected and profiles supported, archive, rename and delete send `"default"`. With profiles unsupported they send `nil`. Non-default still sends the name.
- [ ] Write tests: an archive/delete failure rollback still re-inserts the row when the capture was `nil` and the current value is `"default"` (`profileKey` equality). Update any existing tests that expected `nil` for the default profile.
- [ ] Run tests (`make test`); they must pass before Task 2.

### Task 2: Scope the archived sheet to the literal default profile

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ArchivedSessionsFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ArchivedSessionsFeatureTests.swift`

- [ ] Update the `profileName` doc comment: `nil` now means only that the profiles API is unsupported.
- [ ] Verify the sheet seeded from the list with the default profile gets `"default"`, lists via `profiles.sessions(…, "default", .only, …)`, and restores with `profile: "default"`.
- [ ] Write tests for the default-profile scoped list and restore, and for the unscoped path when `profileName == nil`.
- [ ] Write a test confirming that the sheet's delete delegate reaches the parent and the parent sends `"default"`.
- [ ] Run tests; they must pass before Task 3.

### Task 3: Send the literal profile from `ChatFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatBranchTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift` (only where a test expects the default profile to be omitted)

- [ ] Make `scopedProfile` return `profileName` unchanged, and update the `profileName` doc comment (`:35-38`) and `scopedProfile` doc (`:680-683`).
- [ ] Write tests: with `profileName == "default"`, `session.create`, `session.resume`, the #17 heal re-resume/create, and the REST `messages` fetch all carry `profile: "default"`.
- [ ] Write tests: with `profileName == nil`, none of them carry `profile` (byte-identical for agents without the profiles API). Update existing tests that seeded `"default"` and expected omission.
- [ ] Run tests; they must pass before Task 4.

### Task 4: Compare profiles by identity in `AppFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [ ] Feed `profileReseatSignal` with `profileKey(home?.scopedProfileName)`.
- [ ] Switch `canPatchVisibleRow` (`:811`), the unread row patch (`:941`), `reduceProfileReseat` (`:1030`) and `isReusableNewChat` (`:1056`) to `profileKey` equality.
- [ ] Write tests: a chat seated with `profileName == nil` before profiles load, then the list flips to `profilesSupported` with `"default"`:
  - no reseat in regular layout,
  - the working glow still patches the row,
  - the unread row patch still applies.
- [ ] Write tests: an open default-profile chat calls `rest.setUnread(…, "default")`, and a genuine profile switch (`"default"` → `"work"`) still reseats a pristine regular-width chat.
- [ ] Run tests; they must pass before Task 5.

### Task 5: Verify acceptance criteria
- [ ] With profiles supported, every session-scoped REST mutation, the archived sheet, and chat create/resume/messages send the literal selected profile, including `"default"`.
- [ ] Agents without the profiles API send no `profile` anywhere (grep the tests for the unsupported-path assertions).
- [ ] No spurious reseat or glow/unread miss across the nil→`"default"` launch transition.
- [ ] Run the full suite: `make test`.

### Task 6: [Final] Update documentation
- [ ] `CLAUDE.md` Multi-profile bullet: replace "omitted for `"default"` so single-profile agents get byte-identical requests" with "the literal name, including `"default"`, whenever the profiles API exists; omitted only without it (an omitted profile means the server's launch profile, #114)". Keep the bullet the same length.
- [ ] `docs/architecture.md`: update the profile-omission wording at lines ~83, ~160 and ~265-269.
- [ ] Move this plan to `docs/plans/completed/`.

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
