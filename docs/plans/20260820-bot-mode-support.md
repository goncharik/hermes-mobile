# Bot Mode support (Phase 1 shipped as draft code, Phase 2 as scoped skeleton)

GitHub issue: #76 — "Support Hermes Agent's new Bot Mode (roster, group chats,
bot-to-bot messaging)"

## ⚠️ Status: DRAFT — NOT compiled, NOT tested, NOT verified against a live agent

This plan and its accompanying code were written in an environment with **no Xcode/
macOS available** — `swift test`, `make snapshot`, and `tuist generate` have not been
run. Every claim about the server contract (in particular `Profile.botMeta` / the
`ui_meta` shape) is inferred from reading the `hermes-agent` source, not confirmed
against a live Bot-Mode-managed agent. Treat everything here as a starting point that
needs a real macOS pass — compile, `swift test --package-path HermesKit`, and a
manual on-device check against a Bot-Mode agent — before merge. See "Post-Completion"
at the bottom for the exact verification checklist.

## Overview

Hermes Agent (desktop) shipped **Bot Mode**: profiles become named "Bots" with a
roster UI, a canonical per-bot chat, group-chat rooms, bot-to-bot messaging, and
routines. Investigation (GitHub issue #76, comments) found there is **no dedicated
server API** for any of this — it's ~10,900 lines of client-side JS in the desktop's
bundled plugin (`apps/desktop/src/plugins/hermes-bots/plugin.js`), built on generic
gateway primitives mobile already speaks:

| Bot Mode piece | Backend reality |
|---|---|
| Bot metadata (avatar/title/description) | `ui_meta['hermes-bots']` block on `profile.yaml`, read via `profiles.list` RPC / `GET /api/profiles` |
| Canonical "Bot Chat" | A plain session titled exactly `"Bot Chat"`; backend (`tools/bot_mode_probe.py`) auto-injects a messaging-protocol system-prompt section whenever ANY profile on the install is bot-managed |
| Group chat rooms | N ordinary hidden sessions titled `"Group: <name>"`; orchestration (turn-taking, @mentions, round caps) is 100% client-side JS, no server concept |
| Bot-to-bot messaging | Not an API — the backend teaches the AGENT (via injected prompt) to shell out to `hermes -p <bot> chat --query-file ...`; the LLM decides to do this as an ordinary tool call |

This splits the work naturally:

- **Phase 1** (this PR, draft code included): surface bot profiles + open/create their
  canonical "Bot Chat". Reuses existing profile/session plumbing almost entirely.
- **Phase 2** (this PR, skeleton only): group chat rooms. Genuine feature build — no
  API to wire up, needs a from-scratch port of the desktop's turn-taking logic. NOT
  attempted as working code here; see `GroupChatFeature.swift`'s header comment for
  the full scope breakdown.

## Phase 1 — what shipped in this PR

### `HermesKit/Sources/HermesKit/Models/BotMeta.swift` (new)

`BotMeta`: decodes the `ui_meta['hermes-bots']` block (`title`, `description`,
`avatar` as opaque `JSONValue`, `hidden`, `groups`). Every field optional, decoding
maximally lenient (mirrors the rest of the codebase's leniency convention — see
`CLAUDE.md`'s "Decode leniently" rule). **Field names are a best-effort guess** from
reading the plugin.js source, not a confirmed wire contract — see Task 1 below.

### `HermesKit/Sources/HermesKit/Models/Profile.swift` (modified)

- Added `botMeta: BotMeta?` (decoded from the nested `ui_meta.hermes-bots` key) and
  `isBotManaged: Bool` (mirrors the backend's own `tools/bot_mode_probe.py::
  _is_bot_managed` definition: non-nil `hermes-bots` block under `ui_meta`).
- Decode path added a nested-container read guarded by `try?` at every level, so a
  profile with no `ui_meta`, a `ui_meta` with no `hermes-bots` key, or a malformed
  `hermes-bots` value all decode to `botMeta == nil` rather than failing the whole
  `Profile` decode (tested — see below).

### `HermesKit/Sources/HermesKit/Features/BotRosterFeature.swift` (new)

A self-contained TCA reducer, NOT wired into `AppFeature`/`SessionListFeature` yet
(see Task 4 below — deliberately left as a follow-up so this PR's diff stays reviewable
and isolated):

- `.task` → `profiles.list` (existing `HermesProfileClient`, unchanged) → filters to
  `isBotManaged` for the `bots` computed roster.
- `.botTapped(name:)` → resolve-or-create the bot's canonical "Bot Chat":
  1. `session.list` with `title:"Bot Chat", profile:<name>` — the EXACT lookup path
     the backend's own comment calls out as existing for this purpose
     (`tui_gateway/methods_session.py`, `title_lookup` branch: *"callers that treat a
     title as an identity key (Bot Mode's canonical 'Bot Chat' — Profile → Named
     Session) get a window-free O(1) answer"*).
  2. If found → delegate `.openBotChat(session:profileName:)`.
  3. If not found → `session.create profile:<name> title:"Bot Chat"`, then delegate
     the same way.
- 404 from `profiles.list` flips `profilesSupported = false` silently (mirrors
  `SessionListFeature`'s existing capability-gating convention) rather than banner-ing
  an error — an agent without `/api/profiles` simply can't have Bot Mode either.
- In-flight guard on `resolvingBotName` prevents a double-tap from firing two
  `session.create`s for the same bot.

Deliberately does NOT attempt: rendering the roster (no SwiftUI view yet), replaying
the bot's introduction message, avatar rendering, hide/unhide, or anything from the
"Advanced" bot-creation surface. Scope is the minimum useful slice: list bots, open
their canonical chat.

### `HermesKit/Tests/HermesKitTests/ProfileTests.swift` (extended)

5 new `@Test` cases: full `ui_meta.hermes-bots` decode, plain profile stays
`isBotManaged == false`, an unrelated plugin's `ui_meta` key doesn't false-positive,
a malformed (non-object) `hermes-bots` value decodes to `nil` without crashing the
whole `Profile`, and partial-field leniency.

### `HermesKit/Tests/HermesKitTests/BotRosterFeatureTests.swift` (new)

7 `@Test` cases covering: roster filtering, 404→capability-gate, other-error→banner,
existing-chat-found path, no-chat-found→create path, double-tap guard, and RPC-failure
→ `loadFailed` delegate. Written against the `TestStore` + `@Dependency` override
pattern used throughout the existing suite (see `ArchivedSessionsFeatureTests.swift`
for the reference this was modeled on) — **not run**, no macOS available in this
environment.

## Phase 2 — what's in this PR (skeleton only, NOT functional)

### `HermesKit/Sources/HermesKit/Features/GroupChatFeature.swift` (new, skeleton)

- `GroupChatRoom`: placeholder domain type, explicitly marked as an unverified sketch
  (there's no server object to decode this from — see file header).
- `GroupChatFeature`: a `@Reducer` whose only action (`.task`) does nothing but leave
  a `TODO` pointing at the actual work. No round-orchestration action, no
  turn-taking state machine, no transcript merging — adding those without having
  validated the approach against a real client-side port would just be more
  unverified surface area.
- The file's header comment is the actual deliverable here: a concrete breakdown of
  every piece of desktop logic (membership model, turn-taking policy, hard caps,
  merged transcript rendering, cross-machine rooms) that would need a from-scratch
  Swift port, with pointers to the exact desktop source lines that would need porting.

**This is intentionally not a working feature.** It exists so Phase 2's scope is
legible in code, not just prose in the GitHub issue.

## Open questions to resolve before Phase 1 ships for real

1. **Confirm `ui_meta` on `GET /api/profiles`.** The gateway RPC `profiles.list`
   forwards `ui_meta` per `tui_gateway/methods_profiles.py` (`row["ui_meta"] =
   ui_meta`), but the REST route's `_profile_to_dict` (`hermes_cli/web_routers/
   profiles.py`) was not confirmed to do the same. If it doesn't, `BotRosterFeature`
   needs to call the `profiles.list` gateway RPC directly instead of (or in addition
   to) `HermesProfileClient.list` (REST). This is a same-session fix once confirmed —
   the reducer's dependency surface makes swapping the data source a one-line change.
2. **Confirm the exact `BotMeta` field names.** `title`/`description`/`avatar`/
   `hidden`/`groups` are inferred from reading `plugin.js`, not from a captured
   payload. A live agent + `curl GET /api/profiles` (or `hermes profile list --json`
   if that exists) against a Bot-Mode-managed install would settle this in minutes.
3. **`session.list` response shape assumption.** `BotRosterFeature` reads
   `result["sessions"]` as an array of objects with `id`/`resolved_id`/`title`/
   `preview`/`message_count`/`source` keys, based on the `title_lookup` branch's
   Python dict literal in `methods_session.py`. Not decoded through a proper
   `Decodable` DTO yet (the JSONValue subscript reads are a stopgap) — worth
   promoting to a typed response once confirmed, matching the rest of the codebase's
   convention (`ActivateResponse`, `SessionHandle`, etc. are all typed).

## Implementation Steps (for the eventual macOS-side finishing pass)

### Task 1: Verify `ui_meta` REST forwarding (blocking)

- [ ] Point a `curl GET /api/profiles` at a real Bot-Mode-managed Hermes install (or
      inspect `hermes_cli/web_routers/profiles.py::_profile_to_dict` directly) and
      confirm `ui_meta` round-trips.
- [ ] If it does NOT: switch `BotRosterFeature.task`'s effect from
      `profiles.list(connection)` (REST) to a new `HermesGatewayClient.send("profiles.list", ...)`
      call, decoding the RPC's `ui_meta` field the same way.
- [ ] Confirm/correct `BotMeta`'s field names against the real payload; update
      `ProfileTests` fixtures to match exactly.

### Task 2: Compile + test on macOS (blocking — nothing below this line has run)

- [ ] `tuist generate` (new source files need this before any build picks them up —
      see `CLAUDE.md` gotchas)
- [ ] `script -q /dev/null swift test --package-path HermesKit` — fix whatever the
      Swift compiler flags that a Linux read-through couldn't catch (access control,
      `@Sendable` capture issues, `@CasePathable`/`@Reducer` macro expansion errors,
      etc.)
- [ ] Confirm all `BotRosterFeatureTests` + the 5 new `ProfileTests` cases pass

### Task 3: `BotRosterView` (SwiftUI, not started)

- [ ] A roster list view over `BotRosterFeature.State.bots` — row per bot (name +
      `botMeta?.title` + `botMeta?.description`), tap → `.botTapped(name:)`
- [ ] Loading/error/empty states (`isLoading`, `loadError`, empty `bots` with
      `profilesSupported == true` → "No Bots yet" — do NOT treat this as an error)
- [ ] `profilesSupported == false` → hide the entire Bots entry point (capability gate,
      matches the rest of the app's convention)
- [ ] Snapshot tests once the view exists (`make snapshot` / `make snapshot-record`)

### Task 4: Wire into navigation (not started)

- [ ] Add a `Bots` tab/entry point in `AppFeature` (or wherever the session list root
      lives) presenting `BotRosterFeature`
- [ ] Handle `.delegate(.openBotChat(session:profileName:))` by pushing a
      `ChatFeature.State(connection:resumeStoredID:profileName:title:)` exactly like
      `AppFeature`'s existing `openSession` delegate handler does (same construction,
      just a different trigger)
- [ ] Handle `.delegate(.loadFailed(message:))` — surface as a banner/alert

### Task 5: Final verification pass

- [ ] Manual on-device test against a real Bot-Mode-managed agent: confirm the
      roster shows the same bots as desktop, tapping one opens (or creates) the exact
      same canonical chat desktop would resume, and a message sent from mobile gets
      the bot's messaging-protocol-aware system prompt (verifiable by asking the bot
      "who are your teammates" and comparing to `hermes profile list`)
- [ ] Move this plan to `docs/plans/completed/` once shipped

## Post-Completion — manual verification checklist (no checkboxes; requires macOS + a live agent)

- Build on a real Mac: `tuist generate && swift test --package-path HermesKit` green.
- Point the app at a Bot-Mode-managed agent (desktop's Settings → Plugins → Bots
  turned on, at least one Bot created there). Confirm the roster in mobile shows the
  same bots, with matching names.
- Tap a bot that already has messages on desktop — confirm mobile resumes the SAME
  "Bot Chat" session (not a duplicate) and the full history is there.
- Tap a bot with NO existing chat — confirm mobile creates one, and that the SAME
  session then shows up as that bot's canonical chat on desktop too (same `title`,
  no duplicate created there).
- Send a message from mobile asking the bot to message a teammate (e.g. "ask
  <other-bot> what model they're running") — confirm the messaging protocol is
  active (the bot attempts the `hermes -p <bot> chat` handoff) exactly as it would
  from a desktop-opened chat.
- Point the app at an agent WITHOUT Bot Mode (no profile has `ui_meta['hermes-bots']`)
  — confirm the Bots entry point is either hidden or shows a clean empty state, never
  an error.
- Point the app at an agent without `/api/profiles` at all (pre-#1 agent) — confirm
  `profilesSupported` gates the whole feature off cleanly, matching today's
  single-profile fallback behavior.
