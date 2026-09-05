# Native Hermes Projects: project-first session list and verified create/resume (#99)

## Overview

Surface the server's first-class Projects in the session list, drill into a Project's
sessions from the server's own grouping, and bind a chat opened or created from a Project to
that Project's identity so the phone can prove that its `session.create` / `session.resume`
/ `prompt.submit` targets the Project the user selected.

- **Problem.** The list groups by the `cwd` string (`SessionGroup`), a display-only guess.
  Hermes has had Projects since v2026.7.1 (`projects.db` per profile; `projects.list`,
  `projects.tree`, `projects.project_sessions`, `projects.for_cwd`), and both `session.create`
  and `session.resume` return `info.project` / `info.cwd` / `info.profile_name`. The app reads
  none of it: a chat "in" a workspace is whatever the path string looked like, a new chat
  never carries a `cwd`, and nothing checks that the session the server handed back is the
  one the row promised.
- **Benefit.** The list mirrors the desktop sidebar: a Projects section (Home bucket,
  explicit projects, auto projects from git roots, discovered repos) with counts and recency,
  a drill-in per Project with repo and branch lanes, and a Recents list below it that
  excludes every session a Project claims. A chat opened from a Project is locked until the
  server confirms profile + Project + cwd (+ stored id on resume); "New chat" inside a
  Project creates the session in that Project's primary folder. Older agents keep today's
  list and today's unverified open, byte-for-byte.
- **Integration.** Project RPCs are JSON-RPC only (no REST router), and the session list is
  pure REST with no socket, so a new read-only `HermesProjectClient` dependency owns a second
  WebSocket while the list is on screen. The chat slot's socket, the #33 keep-alive policy, and
  the #80 `isChatDetached` predicate are untouched: the drill-in is list-local state, not a
  navigation push. Identity verification hangs off the existing `hydrate` / `session.create`
  result handlers and gates the existing `canSend` / `canBranch` / queue / card actions.

Split out of #96 with #97 (request-bound approval/clarify cards) and #98 (event replay).
Lands after #95 and #97. Project CRUD from the phone (create / rename / archive / folders /
`set_active`) is out of scope. Multi-slot stays #90.

## Context (from discovery)

Verified against upstream Hermes `main` `63279301bc` (2026-09-03) via
`git show upstream/main:<path>` in the sibling clone
`/Users/eugene/Documents/Development/Personal/hermes-agent` (the checked-out tree is stale).

**Server wire — Projects** (`tui_gateway/server.py` `_projects_method`,
`tui_gateway/methods_config.py`, `tui_gateway/methods_projects.py`, `tui_gateway/project_tree.py`,
`hermes_cli/projects_db.py`; since `4e023f5bc9`, v2026.7.1):
- All handlers are `@_profile_scoped`: `params.profile` binds that profile's `projects.db`
  (same `profile` param the app already threads into session RPCs; omitted = default).
- `projects.list` → `{projects: [Project], active_id}`. `Project.to_dict()`: `id` (`p_<hex>`),
  `slug`, `name`, `description`, `icon`, `color`, `board_slug`, `primary_path`, `archived`,
  `created_at`, `folders: [{path, label, is_primary, added_at}]`.
- `projects.tree {preview_limit?=3, session_limit?=2000}` → `{projects: [ProjectNode],
  active_id, scoped_session_ids: [String]}`. Lanes carry **no** session rows here (counts +
  structure + `previewSessions` only).
- `projects.project_sessions {project_id, session_limit?=5000}` → `{project: ProjectNode |
  null}` fully hydrated (lane `sessions` filled), built from the same grouping so ids and
  membership match the tree exactly. The discovery tier is skipped, so a zero-session
  discovered repo returns `project: null`.
- `ProjectNode` (key order = wire): `id`, `label`, `path`, `color`, `icon`, `isAuto`,
  `isNoProject`, `sessionCount`, `lastActive` (epoch seconds), `totalTokens`, `totalCostUsd`,
  `repos: [RepoNode]`, `previewSessions: [row]`. Tiers: Home bucket first when non-empty
  (`id: "__no_project__"`, `label: "Home"`, `path: null`, `isNoProject: true`, one repo with
  one lane), then explicit projects (`id: "p_…"`, `path = primary_path`), then auto projects
  (`id = path = repo root`, `isAuto: true`), then discovered repos (`isAuto`, 0 sessions,
  `repos: [one empty node]`).
- `RepoNode`: `id` (= repo root or `__no_project__`), `label`, `path`, `sessionCount`,
  `groups: [LaneNode]`. `LaneNode`: `id` (`<root>::branch::<name>` / `<root>::kanban` /
  worktree path), `label`, `path`, `isMain`, `isKanban`, `sessions: [row]`.
- Session row (`_project_tree_row` + `stamp_profile`): `id`, `_lineage_root_id`,
  `_lineage_ids`, `parent_session_id`, `title`, `preview`, `started_at`, `ended_at`,
  `last_active`, `source`, `archived`, `message_count`, `tool_call_count`, `input_tokens`,
  `output_tokens`, `actual_cost_usd`, `estimated_cost_usd`, `model`, `is_active` (always
  false here), `cwd`, `git_branch`, `git_repo_root`, `profile` (stamped with the request
  profile). Same keys the REST list decodes (`SessionListDTO`) plus a few extras. Cron and
  other excluded sources are not in the tree (`_PROJECT_TREE_EXCLUDED_SOURCES`).
- Errors: `5061` generic, `5062` no such project, `5063` bad argument. An absent method is
  the standard `-32601`.

**Server wire — identity** (`tui_gateway/methods_session.py`, `server.py`):
- `session.create` accepts `cwd`; it is honored only when the directory exists on the server
  (`os.path.isdir(abspath(expanduser(raw)))`), otherwise the session falls back to "No
  workspace". No `project_id` param exists — membership derives from `cwd`. Returns
  `{session_id, stored_session_id, message_count, messages, info}` with `info = {model,
  provider?, tools, skills, cwd, branch, project, lazy, desktop_contract, profile_name}`;
  `project` is `{id, slug, name, primary_path}` or `null` (`_project_info_for_cwd`: only
  explicit named projects resolve).
- `session.resume` returns the same `info` shape (`_fallback_session_info`: `cwd`, `branch`,
  `project`, `profile_name`, …) plus `resumed` / `session_key` (stored id).
- No per-device socket limit in `tui_gateway/ws.py`; each connect gets its own
  `gateway.ready`. Cookie mode mints one ws-ticket per connect.

**Desktop reference** (`apps/desktop/src/store/projects.ts`,
`apps/desktop/src/app/chat/sidebar/projects/workspace-groups.ts`): thin renderer over
`projects.tree` (overview) + `projects.project_sessions` (drill-in); `scoped_session_ids`
excludes claimed rows from the flat Recents; ids and lane keys are what pins/ordering key on.

**App today**
- `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift` (1649 lines): REST
  `sessions` fetch (`fetchSessions`, `CancelID.fetch`, 10 s `pollTick`), cron jobs fetched
  sequentially inside the same effect and capability-gated on 404, `SessionGroupingMode`
  pref, pins, unread `seenCounts`, search (flat), `Delegate.openSession(Session)` /
  `.createSession(initialComposerText:)`; `scopedProfileName` (nil for default).
- `HermesMobile/Sources/Features/SessionListView.swift` (616 lines): flat `List`, Pinned /
  groups / chronological / Cron sections, bottom "New chat" bar, top-trailing menu.
  `SessionRowView.swift` is the shared row.
- `HermesKit/Sources/HermesKit/Models/Session.swift` — `Session`, `SessionHandle`
  (`session_id`, `stored_session_id`, `message_count`; **no `info`**), `ActivateResponse`.
  `SessionInfo` (`GatewayEvent.swift`) decodes `cwd` and `profile_name` but not `project`
  or `branch`. `SessionListDTO` (internal, `HermesRESTClient.swift`) decodes the REST row.
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — `make(...)` builds an
  independent client (own `ConnectionStore`) per call; `live()` wires the URLSession
  transport + ticket mint. `GatewayError.isUnknownMethod` / `isSessionNotFound` match on the
  **message** because `InboundFrame.failure` drops the code.
- `HermesKit/Sources/HermesKit/Clients/HermesProfileClient.swift` — the template for a
  secondary dependency (`@DependencyClient`, `liveValue = .live()`, empty `testValue`).
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `State.init(connection:,
  resumeStoredID:, profileName:, title:, transcript:, composerText:, status:)`;
  `createSession(profile:)` → `createSessionRPC(fields: [:])`; the #17 self-heal recreates
  via the same path; `applyActivate`; `canSend`, `canBranch`, `drainQueueIfReady`,
  `respondTo*`, slash exec gates.
- `HermesKit/Sources/HermesKit/AppFeature.swift` — `path: StackState<ChatScreen.State>`
  (chat markers only; `isChatDetached = layout == .compact && path.isEmpty` is load-bearing,
  #80), `newChat(for:)`, `detailRefill`, `ProfileReseatSignal {profileName,
  composerInputInFlight, layout}` + `reduceProfileReseat`, `isReusableNewChat`,
  `openSession` / `createSession` delegate handlers, logout clears prefs.
- Tests: `SessionListFeatureTests`, `SessionListCronTests`, `SessionDecodingTests`,
  `SessionGroupTests`, `AppFeatureTests`, `HydrateTests`, `HermesGatewayClientTests`,
  `GatewayErrorTests`; `HermesMobileTests/SessionListSnapshotTests` (list snapshots use
  `deviceImage()`), `ChatSnapshotTests`.
- Docs to update: `docs/features/session-list.md`, `docs/features/ipad-layout.md`,
  `docs/architecture.md`, `CLAUDE.md` (Session list + Gateway bullets), `README.md`.

## Development Approach

- **testing approach**: Regular (code first, then tests) — user preference for this plan.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility: an agent without Projects (`-32601` on `projects.tree`)
  gets today's list, today's `session.create` fields, and no identity lock; a chat opened
  from Pinned / Recents / Cron / push tap / search carries no identity and behaves as today
- commit per task, capitalized verb, no conventional-commit prefix

## Testing Strategy

- **unit tests** (HermesKit, `swift test`): decoding tests for every Project payload and the
  structured error code; `TestStore` tests for the list (tree fetch, gating, drill-in,
  Recents exclusion, poll refresh, search), the chat (identity verification on create and
  resume, the lock on every gated action, heal re-verification), and the app (identity
  threading through open/create/seat/reseat, logout closing the project socket); client
  tests with `FakeTransport` for the project socket lifecycle.
- **snapshot tests** (`HermesMobileTests`, `make snapshot` twice per new test,
  `deviceImage()` for anything containing a `List`): Projects section, drill-in screen,
  locked composer. Judge by render size first (baseline drift is known).
- no e2e suite. Run with `script -q /dev/null swift test --package-path HermesKit` (or
  `make test`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

1. **Structured RPC errors.** `InboundFrame.failure` keeps the numeric `code`; `GatewayError`
   gains `.rpc(code:message:)`. `isUnknownMethod` answers true for code `-32601` first and
   falls back to today's message match for `.server` (older fixtures keep passing).
   `isSessionNotFound` gets the same two-step. Project handlers' `5061/5062/5063` become
   `GatewayError.rpc` with a `projectCode` accessor.
2. **Pure models.** `Project`, `ProjectTree`, `ProjectNode`, `RepoNode`, `LaneNode` decode
   leniently (unknown keys ignored; `lastActive` epoch → `Date?`; session rows through the
   existing `SessionListDTO`, moved to `Models/` as `SessionRowDTO`). `SessionInfo` gains
   `project: SessionProjectRef?` (`{id, slug, name, primary_path}`) and `branch`.
   `SessionHandle` gains `info: SessionInfo?`. `ProjectIdentity` is the expected-identity
   tuple a chat is bound to.
3. **`HermesProjectClient` — one read-only socket, request/response only.** Built on
   `HermesGatewayClient.make` with its own connection store. `tree(connection, profile)`,
   `projectSessions(connection, profile, projectID)`, `list(connection, profile)`,
   `disconnect()`. The live value opens lazily on the first call (waits for `.ready`,
   `.authExpired` → throws `GatewayError.authExpired`), reuses the socket for later calls,
   redials on the next call after a drop, and closes on `disconnect()`. **This client
   consumes no events**, so "reconnect lives in the reducer" does not apply — it is a
   request channel like REST, and the list reducer treats a thrown error exactly like a
   REST failure. Documented as the deliberate exception.
4. **Projects section + drill-in, list-local.** `SessionListFeature` fetches `projects.tree`
   sequentially inside the existing load effect (after sessions and cron, same `CancelID.fetch`
   → deterministic order), profile-scoped like sessions; `-32601` flips `projectsSupported`
   off silently; a transient failure keeps the previous tree (no flapping). `selectedProject`
   holds the drill-in (`ProjectNode` from the overview, replaced by the hydrated node from
   `projects.project_sessions`); Back clears it. The drill-in is **not** a `path` element —
   `isChatDetached` reads `path.isEmpty`, and a non-chat screen on the path would break #80's
   one predicate; the sidebar column simply swaps content. Recents = the REST
   `interactiveSessions` minus `scopedSessionIDs`; Pinned stays global (pins are
   device-local); cron, branch nesting, grouping, unread, swipe actions are unchanged and
   apply inside the drill-in too (same `row(_:)`). Search hides the Projects section and
   searches the whole flat list (search stays flat and unscoped, as today). Poll refreshes
   the overview and, when open, the drill-in.
5. **Identity threading.** Tapping a session inside a drill-in emits
   `openSession(session, identity)`; "New chat" inside a drill-in emits
   `createSession(initialComposerText: nil, identity)`. Identity per tier: explicit project →
   `{profile, projectID, primaryPath = node.path}`; auto project → `{profile, projectID: nil,
   primaryPath = node.path}`; Home bucket → **no identity** (nothing to verify). Top-level
   New chat, Pinned/Recents/Cron rows, search results, push taps → no identity (today's
   behaviour).
6. **The verified-session lock.** `ChatFeature.State.expectedIdentity` is set once at init and
   never mutated; `identityVerified` starts false and is set by the create/resume result
   handlers; `isIdentityLocked = expectedIdentity != nil && !identityVerified`. Gated:
   `canSend`, `canBranch`, `drainQueueIfReady`, slash exec, attachment upload, and the
   approval / clarify / secret responds (reducer guards + disabled buttons). Verification
   rule: `info.profile_name` must equal the expected profile (default ↔ `"default"`/empty);
   explicit project → `info.project?.id == projectID`; auto project → normalized
   `info.cwd == primaryPath` (expand `~`, strip trailing separators, case-sensitive); resume
   additionally → returned stored id == `expectedIdentity.storedSessionID`. A mismatch keeps
   the lock, sets `errorBanner` ("This chat isn't in <name> — the server put it in <cwd>") and
   offers Retry (= `.foreground` re-hydrate). Malformed required identity (no `info` at all
   on a server that advertises Projects) fails closed the same way; unknown extra fields stay
   lenient.
7. **Create carries the Project's folder.** When `expectedIdentity` is set,
   `createSession` sends `cwd: primaryPath` and `messages: []`; otherwise the fields stay
   `[:]` (byte-identical). The #17 self-heal recreate goes through the same function, so a
   healed session is re-verified and the lock re-engages on mismatch.
8. **iPad follows the selection.** `newChat(for:)` reads `home.selectedProjectIdentity`, so a
   regular-width seat created while a drill-in is open is bound to that Project (its
   `session.create` carries the cwd). `ProfileReseatSignal` gains `projectKey`;
   `reduceProfileReseat` and `isReusableNewChat` compare it alongside the profile, with the
   same deferral rules. Narrowing/widening rules are unchanged.
9. **Logout / disconnect** call `projectClient.disconnect()`; the list's `.onDisappear`
   does too (the socket lives only while the list is on screen; in regular width that is
   always, and that is fine — one idle read-only socket).

Key decisions:
- **A second socket rather than a shared one.** The chat slot is nil whenever no chat is
  open in compact, and #33 forbids touching a live slot's socket for unrelated traffic.
- **Drill-in as list state, not navigation.** Keeps `isChatDetached` and every #80 invariant
  intact; costs a custom Back button in the sidebar toolbar.
- **Verify by project id, not by path, whenever the server can name the Project.** Path
  normalization is a fallback for auto projects only; explicit projects compare ids.
- **`messages: []` on project creates only.** Harmless server-side, but adding it to every
  create would break the byte-identity guard for non-project chats.
- **No optimistic Project state.** The tree is server-authoritative; nothing on the phone
  edits it (CRUD out of scope).

## Technical Details

### Models (`HermesKit/Sources/HermesKit/Models/Project.swift`, `Session.swift`, `GatewayEvent.swift`)

```swift
public struct Project: Equatable, Sendable, Decodable, Identifiable {
  public var id, slug, name: String
  public var description, icon, color, primaryPath: String?
  public var archived: Bool
  public var folders: [Folder]            // {path, label?, isPrimary}
}
public struct ProjectTree: Equatable, Sendable, Decodable {
  public var projects: [ProjectNode]; public var activeID: String?; public var scopedSessionIDs: Set<String>
}
public struct ProjectNode: Equatable, Sendable, Decodable, Identifiable {
  public var id, label: String; public var path, color, icon: String?
  public var isAuto, isNoProject: Bool; public var sessionCount: Int; public var lastActive: Date?
  public var repos: [RepoNode]; public var previewSessions: [Session]
  public var isHome: Bool { isNoProject }
  public var isExplicit: Bool { !isAuto && !isNoProject }
}
public struct RepoNode: … { id, label, path?, sessionCount, groups: [LaneNode] }
public struct LaneNode: … { id, label, path?, isMain, isKanban, sessions: [Session] }

public struct SessionProjectRef: Equatable, Sendable, Decodable { id, slug, name: String; primaryPath: String? }
// SessionInfo += project: SessionProjectRef?, branch: String?
// SessionHandle += info: SessionInfo?

public struct ProjectIdentity: Equatable, Sendable {
  public var profileName: String?        // nil = default
  public var projectID: String?          // nil for auto projects
  public var projectLabel: String
  public var primaryPath: String
  public var storedSessionID: String?    // set for resume, nil for create
  public var projectKey: String { projectID ?? primaryPath }
  public static func normalizedPath(_ p: String) -> String
}
```

Decoding: `Session` rows in `previewSessions` / lane `sessions` go through `SessionRowDTO`
(the moved `SessionListDTO`; `profile`, `git_branch`, `git_repo_root` ignored for now).
`lastActive` `0` → nil. Lenient throughout: a malformed node is dropped, never fails the tree.

### Errors (`JSONRPC.swift`, `HermesGatewayClient.swift`)

```swift
case failure(id: Int?, code: Int?, message: String)          // InboundFrame
case rpc(code: Int, message: String)                           // GatewayError (new)
public var isUnknownMethod: Bool   // .rpc(-32601, _) || legacy .server(message) match
public var isSessionNotFound: Bool // .rpc(4001|4007, _) || legacy match
public var projectCode: ProjectErrorCode? // 5061 generic, 5062 noSuchProject, 5063 badArgument
```

### `HermesProjectClient` (`Clients/HermesProjectClient.swift`)

```swift
@DependencyClient
public struct HermesProjectClient: Sendable {
  public var tree: @Sendable (_ connection: ServerConnection, _ profile: String?) async throws -> ProjectTree
  public var projectSessions: @Sendable (_ connection: ServerConnection, _ profile: String?, _ projectID: String) async throws -> ProjectNode?
  public var list: @Sendable (_ connection: ServerConnection, _ profile: String?) async throws -> [Project]
  public var disconnect: @Sendable () -> Void
}
```
Live: an actor `ProjectSocket` holding a `HermesGatewayClient` from `make(...)` (same ticket
mint + transport as `live()`), keyed on the `ServerConnection`; `ensureReady(connection)`
connects if needed and awaits the first frame (`.ready` → ok; `.authExpired` → throw
`.authExpired`; stream end → `.disconnected`); a changed connection (different base URL or
auth) tears the old socket down first. `tree`/`projectSessions`/`list` = `ensureReady` +
`send`; `profile` omitted when nil (byte-identical to the default-profile session calls).
Request budget: the client's default 30 s. `testValue`: the macro's unimplemented closures.

### List reducer (`SessionListFeature`)

State: `projectsSupported = true`, `projectTree: ProjectTree?`, `selectedProject:
ProjectDrillIn?` (`node`, `isLoading`, `loadError`), `projectsLoadFailed: Bool` (for a quiet
inline hint, not a banner). Computed: `projectNodes` (tree order; discovered repos shown, 0
sessions), `scopedSessionIDs`, `recentsSessions = interactiveSessions.filter { !scoped }`,
`selectedProjectIdentity: ProjectIdentity?` (nil for Home / no drill-in), and the existing
`pinnedSessions` / `groups` / `chronologicalSessions` re-based on `recentsSessions`.

Actions: `projectTreeResponse(Result<ProjectTree, GatewayError>)`, `projectTapped(ProjectNode.ID)`,
`projectSessionsResponse(id:, Result<ProjectNode?, GatewayError>)`, `projectBackTapped`,
`projectSessionTapped(Session.ID)`. Delegate: `openSession(Session, identity: ProjectIdentity?)`
(default nil at the call sites that exist today), `createSession(initialComposerText: String?,
identity: ProjectIdentity?)`.

Fetch order inside the one effect: sessions → cron jobs → `projects.tree` (skipped when
`!projectsSupported` or while searching). Drill-in refresh: after the tree, if
`selectedProject != nil`, `projects.project_sessions` for it. `-32601` anywhere → latch off,
clear `projectTree` and `selectedProject`. `.onDisappear` → cancel + `projectClient.disconnect()`.
Profile switch → tree cleared, drill-in cleared, refetch (the tree is per profile).

### Chat reducer (`ChatFeature`)

State: `expectedIdentity: ProjectIdentity?` (init param, `public internal(set)`),
`identityVerified: Bool = false`, `isIdentityLocked` computed. Init: `identityVerified = true`
when `expectedIdentity == nil` (no lock).

`verifyIdentity(info: SessionInfo?, storedID: String?, into: &state)` — applied in
`.sessionResult(.success(handle))` (create; `handle.info`), `applyActivate` (resume;
`response.info` + `storedSessionID`), and the heal's `.liveSessionIDRefreshed` path. On
success: `identityVerified = true`, banner cleared. On failure: `identityVerified = false`,
`errorBanner = mismatchMessage`, and a `.status(kind: "project", …)` row is **not** appended
(nothing in the transcript). `createSession(profile:)` → `createSessionRPC(fields:
expectedIdentity.map { ["cwd": $0.primaryPath, "messages": []] } ?? [:], …)`. Branch creates
(`branchSeedFields`) carry `cwd` too when the parent chat is bound.

Gates: `canSend`, `canBranch`, `drainQueueIfReady`, `submitDraft`, `slashExec`,
attachment `stage/upload`, `respondToApproval/Clarify/Secret` all early-return on
`isIdentityLocked`. The view shows a compact "Verifying project…" / mismatch state over the
composer (disabled controls, not hidden).

### App reducer (`AppFeature`)

- `openSession(session, identity)` → `ChatFeature.State(resumeStoredID:, profileName:
  identity?.profileName ?? home.scopedProfileName, expectedIdentity: identity?.with(storedSessionID: session.id))`.
- `createSession(text, identity)` → `newChat(for: home, identity: identity, composerText:)`.
- `newChat(for:)` default identity = `home.selectedProjectIdentity` (regular seats follow the
  drill-in).
- `ProfileReseatSignal += projectKey: String?`; `reduceProfileReseat` reseats when
  `chat.expectedIdentity?.projectKey != home.selectedProjectIdentity?.projectKey` (same
  discardable / deferral rules); `isReusableNewChat` compares `projectKey` too.
- Logout and `.disconnect` → `projectClient.disconnect()`.

### Views (`HermesMobile`)

- `ProjectRowView`: color dot or icon, label, `sessionCount`, relative `lastActive`; a
  "discovered" (0 sessions) row is dimmed. Home bucket uses a house icon.
- `SessionListView`: `projectsSection` (hidden while searching or when unsupported/empty);
  drill-in mode replaces the body: leading Back button, title = project label, sections per
  lane (`repo.label · lane.label` when a project has more than one repo, else lane label),
  rows via the existing `row(_:)`, empty lanes hidden, "New chat in <label>" bottom bar.
  Overview rows tap → `projectTapped`; a preview session row is not shown in the overview
  (counts only — keeps the list short; desktop shows previews, accepted deviation).
- `ChatView`: composer lock state and Retry.

## Implementation Steps

### Task 1: Structured JSON-RPC error codes

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/JSONRPC.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/JSONRPCTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/GatewayErrorTests.swift`

- [ ] `InboundFrame.failure` carries `code: Int?` (decoded from `error.code`)
- [ ] add `GatewayError.rpc(code:message:)`; the connection maps a coded failure to it and an
      uncoded one to `.server(message)`; `message` covers both
- [ ] `isUnknownMethod` / `isSessionNotFound` check the code first, then the legacy message
      match; add `projectCode`
- [ ] write tests: coded frame → `.rpc`; `-32601` by code with a non-matching message →
      `isUnknownMethod`; legacy `.server("Method not found")` still true; `4007` by code →
      `isSessionNotFound`; `5062` → `.noSuchProject`
- [ ] run tests - must pass before next task

### Task 2: Project models and session-info identity fields

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/Project.swift`
- Create: `HermesKit/Sources/HermesKit/Models/SessionRowDTO.swift` (moved from `HermesRESTClient.swift`)
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift` (`SessionHandle.info`)
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` (`SessionInfo.project`, `.branch`)
- Create: `HermesKit/Tests/HermesKitTests/ProjectDecodingTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionDecodingTests.swift`

- [ ] move `SessionListDTO` → `SessionRowDTO` (same keys; REST keeps using it)
- [ ] add `Project`, `ProjectTree`, `ProjectNode`, `RepoNode`, `LaneNode`, `ProjectIdentity`
      (+ `normalizedPath`) with lenient decoders
- [ ] add `SessionProjectRef`, `SessionInfo.project` / `.branch`, `SessionHandle.info`
- [ ] write decoding tests from the wire fixtures: full tree with Home + explicit + auto +
      discovered tiers; `scoped_session_ids`; hydrated drill-in with two repos and a kanban
      lane; `project: null` drill-in; a malformed node dropped; `projects.list` payload;
      `session.create` result with `info.project`; `session.resume` `info` with
      `project: null`; `normalizedPath` cases (`~`, trailing slash, unchanged case)
- [ ] run tests - must pass before next task

### Task 3: `HermesProjectClient` read-only socket

**Files:**
- Create: `HermesKit/Sources/HermesKit/Clients/HermesProjectClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` (expose the pieces `live()` composes so the project socket reuses the transport + ticket mint)
- Create: `HermesKit/Tests/HermesKitTests/HermesProjectClientTests.swift`

- [ ] implement the `ProjectSocket` actor (lazy connect, `ensureReady`, connection-change
      teardown, `disconnect`) and the `@DependencyClient` struct with `liveValue` / `testValue`
- [ ] `tree` / `projectSessions` / `list` send the exact params (`profile` omitted when nil;
      `project_id` for drill-in) and decode leniently (malformed → `.server("Malformed …")`)
- [ ] write tests with `FakeTransport`: first call connects and waits for `.ready`; second
      call reuses the socket (one connect); a closed socket redials on the next call;
      `.authExpired` throws `authExpired`; `-32601` surfaces as `isUnknownMethod`;
      `disconnect` closes and the next call reconnects; a changed connection reconnects
- [ ] run tests - must pass before next task

### Task 4: Projects overview in the session list reducer

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListFeatureTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/SessionListProjectsTests.swift`

- [ ] add state (`projectsSupported`, `projectTree`, `projectsLoadFailed`), the computed
      `projectNodes` / `scopedSessionIDs` / `recentsSessions`, and rebase Pinned/groups/
      chronological on `recentsSessions`
- [ ] fetch `projects.tree` sequentially after cron inside the load effect (skipped while
      searching or unsupported); `projectTreeResponse` handling with the `-32601` latch and
      keep-previous-on-transient-failure; profile switch clears + refetches
- [ ] `.onDisappear` → `projectClient.disconnect()`
- [ ] write tests: tree fetched after sessions + cron with the literal profile; Recents
      excludes scoped ids while Pinned keeps a scoped pinned row; `-32601` hides the section
      and stops fetching; transient failure keeps the old tree; search skips the fetch and
      the section; poll refetches; older-agent flow (no tree) leaves every existing
      `SessionListFeatureTests` fixture byte-identical
- [ ] run tests - must pass before next task

### Task 5: Project drill-in and identity-carrying delegates

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListProjectsTests.swift`

- [ ] add `selectedProject` (`ProjectDrillIn`), `projectTapped` / `projectSessionsResponse` /
      `projectBackTapped` / `projectSessionTapped`, `selectedProjectIdentity`, drill-in
      refresh on poll, clear on profile switch
- [ ] extend `Delegate.openSession` / `.createSession` with `identity: ProjectIdentity?`
      (existing emitters pass nil); drill-in rows and "New chat" emit the tier-specific
      identity (explicit → id + path; auto → path only; Home → nil)
- [ ] pins / unread / rename / archive / delete inside the drill-in reuse the existing
      actions (rows are the same `Session` ids); an archived/deleted row is removed from the
      drill-in node too
- [ ] write tests: tap → loading drill-in → hydrated node; `project: null` → error hint +
      Back; identity for each tier; Back clears; poll refreshes the open drill-in; profile
      switch clears it; archive inside a drill-in removes the row from the lane; a
      `5062` on drill-in shows the hint without latching support off
- [ ] run tests - must pass before next task

### Task 6: Session list views: Projects section, drill-in, row

**Files:**
- Create: `HermesMobile/Sources/Features/ProjectRowView.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobileTests/SessionListSnapshotTests.swift`

- [ ] `ProjectRowView` (dot/icon, label, count, relative time; dimmed discovered rows)
- [ ] `projectsSection` in the overview (hidden while searching / unsupported / empty);
      drill-in body with Back, lane sections, existing rows, "New chat in <label>" bar
- [ ] `tuist generate` for the new file; VoiceOver labels on project rows and Back
- [ ] add snapshots (`deviceImage()`, light + dark): `testSessionList_projectsSection`,
      `testSessionList_projectDrillIn`, `testSessionList_projectDrillIn_multiRepo`;
      `make snapshot` twice each
- [ ] run tests + `make snapshot` - must pass before next task

### Task 7: Verified-session lock in `ChatFeature`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ChatIdentityLockTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`

- [ ] add `expectedIdentity` (init param), `identityVerified`, `isIdentityLocked`,
      `verifyIdentity(info:storedID:into:)` with the tier rules and the mismatch banner
- [ ] `createSession` / branch create carry `cwd` + `messages: []` only when bound;
      `sessionResult(.success)` and `applyActivate` verify; the heal path re-verifies
- [ ] gate `canSend`, `canBranch`, `drainQueueIfReady`, `submitDraft`, slash exec,
      attachment upload, and the three responds on `isIdentityLocked`; Retry = `.foreground`
- [ ] write tests: unbound chat → `identityVerified` true from init and create fields `[:]`
      (byte-identical); bound create sends `cwd` + `messages: []`; explicit-project create
      whose `info.project.id` matches → unlocked; wrong project id → locked + banner + no
      send; auto-project match by normalized path; profile mismatch → locked; resume with
      matching stored id + project → unlocked; resume returning a different stored id →
      locked; `info` missing on a bound chat → locked; heal recreate that lands in the wrong
      cwd re-locks; every gated action is a no-op while locked (approval respond included);
      Retry re-hydrates and unlocks on a good answer
- [ ] run tests - must pass before next task

### Task 8: Identity through `AppFeature`: open, create, seat, reseat, logout

**Files:**
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`

- [ ] thread `identity` from both delegates into `ChatFeature.State`; `newChat(for:)` reads
      `home.selectedProjectIdentity` by default
- [ ] `ProfileReseatSignal.projectKey`; `reduceProfileReseat` and `isReusableNewChat` compare
      it; logout / `.disconnect` call `projectClient.disconnect()`
- [ ] write tests: open from a drill-in seats a bound chat with the stored id; top-level open
      is unbound (existing fixtures unchanged); regular-width refill while a drill-in is open
      seats a bound chat whose create carries the cwd; entering / leaving a drill-in in
      regular reseats a discardable seat (deferred while composer input is in flight, no-op
      in compact); "New session" over a reusable seat with the same project key is a no-op,
      with a different key refills; logout disconnects the project socket
- [ ] run tests - must pass before next task

### Task 9: Chat composer lock state (view)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`

- [ ] render the locked state above the composer ("Verifying project…" with a spinner while
      unverified and no banner; the mismatch banner with Retry otherwise); send/mic/attach
      disabled, cards' buttons disabled while locked
- [ ] add snapshots `testChat_projectVerifying` and `testChat_projectMismatch`; `make snapshot`
      twice each
- [ ] run `make snapshot` - must pass before next task

### Task 10: Verify acceptance criteria
- [ ] verify all requirements from Overview: Projects section + drill-in, Recents exclusion,
      bound open/create with verification, lock on every gated action, older-agent
      byte-identity (list, create fields, no lock)
- [ ] verify edge cases: Home bucket opens unbound; discovered repo (0 sessions) drill-in
      returns null → hint; server-side project deletion between tree and drill-in (`5062`);
      profile switch mid-drill-in; regular-width seat inside a drill-in; cookie-mode ticket
      mint for the second socket; `-32601` mid-session (older agent behind a proxy) latches
      quietly
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot`; judge by render size
- [ ] manual pass against a live v2026.7.1+ agent on iPhone and iPad: browse, drill in, open
      a session, create in a project (folder exists / folder missing → mismatch), rotate
      with a bound seat, logout

### Task 11: [Final] Update documentation
- [ ] `docs/features/session-list.md`: new "Projects" section (tiers, drill-in as list
      state, Recents exclusion, gating, the second socket)
- [ ] `docs/features/ipad-layout.md`: seat identity + `projectKey` in the reseat signal
- [ ] `docs/architecture.md`: `HermesProjectClient` (the request-channel exception to
      "reconnect lives in the reducer"), identity verification, structured error codes
- [ ] `CLAUDE.md`: Session list bullet (Projects, drill-in is not a path element), Gateway
      bullet (coded errors, project socket), Core rules (`-32601` by code)
- [ ] `README.md`: feature list entry
- [ ] comment on #99 with the server floor (v2026.7.1) and the tier → identity rules
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**
- Real-device check of the drill-in with a large project (2000+ sessions: `session_limit`
  default) for list performance; consider paging via `session_limit` if scrolling stutters.
- Cookie-mode server: confirm the second socket's ticket mint and the `.sessionExpired`
  path when the cookie dies while only the list is open.

**External**
- Server floor v2026.7.1 for Projects; identity fields in `info` exist on the same floor.
- #90 (multi-slot) will need per-slot `expectedIdentity` — already per slot here.
- Project CRUD from the phone is a follow-up; the models and client already expose
  `projects.list` for it.
- If upstream ever adds a `project_id` param to `session.create`, switch the bound create to
  it and keep `cwd` as the fallback.
