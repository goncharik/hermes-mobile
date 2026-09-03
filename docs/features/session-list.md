# Session list: grouping, cron jobs, branch nesting, delete & swipe polish (#24, #34, #73)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Session list"; this doc is the full contract. Design history:
`docs/plans/completed/`.

## Grouping & archived

Session-list grouping is a persisted UI pref (`SessionGroupingMode`: `.workspace` /
`.chronological`) in `PreferencesClient` — display-only over the one fetched `sessions` array
(no fetch/order change), reset on logout. The list is a flat `.listStyle(.plain)`; grouping
options + the **Archived sessions** entry live in a top-trailing `Menu`; "New chat" is a bottom
bar via **`.safeAreaInset(edge: .bottom)`** (a `.bottomBar` toolbar renders blank in the
snapshot host). **Archived** is a server query (`?archived=only`) shown in a sheet
(`ArchivedSessionsFeature`); restore = `archive(id, false)`; tap-to-open bubbles up the existing
`openSession` delegate.

## Cron sessions & the Cron Jobs section (#24)

**Cron sessions** (`source == "cron"`, decoded onto `Session` via `SessionListDTO`) are pulled
into an **always-on, separate "Cron Jobs" section** — orthogonal to the grouping mode (no new
`SessionGroupingMode` case). The partition lives in the reducer's computed state (`cronSessions`
vs the non-cron `interactiveSessions` that feeds
`pinnedSessions`/`groups`/`chronologicalSessions`), so cron rows never appear in
Pinned/workspace/chronological. Rendered with a `clock`-icon header below the interactive
sections, and **not shown during search** (search stays flat).

**The Cron Jobs section groups runs under their *jobs*, desktop-style**: `GET /api/cron/jobs` is
fetched sequentially INSIDE the session-load effect (after `.sessionsResponse`, same CancelID —
deterministic TestStore order, no racy merge); a run session binds to its job via the
id-embedded prefix (`cron_{job_id}_{ts}` → `CronJob.jobID(fromSessionID:)`) — upstream has a
`/runs` endpoint, but the client groups from the already-fetched sessions so **older agents work
too**. Job rows: state pip (**green live / amber paused** — deliberately NOT the accent, which
is orange and would be indistinguishable from amber; red error, gray inactive),
`relativeRunLabel` next-run countdown off `state.now` (poll-refreshed — no per-second ticker),
unread dot judged over ALL the job's runs (not just the peeked 5), and a context menu (Run now /
Pause / Resume → `cronActionInFlightIDs` double-fire guard; success refetches — full load after
trigger, jobs-only for pause/resume; **no optimistic job-state mutation**). Tap = single-open
inline peek (`expandedCronJobID`) of the newest `cronPeekLimit` runs via the standard `row(_:)`;
runs matching no fetched job render flat below (`unmatchedCronSessions` — never hide output).
The header carries the aggregate `cronUnreadCount` badge; cron sessions ride the same
`seenCounts` unread pipeline as interactive rows. **Capability-gated**: a 404 flips
`cronJobsSupported` off → flat run list, fetch skipped thereafter; transient failures keep the
previous jobs (no flapping). Jobs are fetched with the LITERAL selected profile name when
`profilesSupported` (matching the scoped session list, so a job's runs are actually present),
unscoped otherwise.

## Branch nesting is display-only (#34)

`parent_session_id` decodes leniently from REST onto `Session.parentSessionID`
(`trimmedNonEmpty`); pure `flattenSessionsWithBranches` (desktop algorithm — sibling recency
sort, group-recency lift, recursion, cycle-safe, trailing sweep, **`byVisibleID` lineage
aliasing**: `_lineage_root_id` → `Session.lineageRootID` keeps a branch nested after its parent
auto-compresses and the row id rotates to the continuation tip) runs per rendered lane (pinned /
workspace / chronological) after the cron partition, emitting `└─`/`├─` stems. Recency is
`updatedAt ?? .distantPast` — deliberately the SAME rule the lanes sort by (no desktop
`started_at` fallback), so nesting never reorders flat rows. Orphans (parent absent from the
lane) de-nest — never hidden; the Pinned lane keeps pin order (`sortTopLevelByRecency: false`; a
pinned branch nests only when its parent is also pinned, otherwise it de-nests); search /
archived / cron stay flat. Row identity and swipe/context affordances are unchanged.

## Session delete (#73)

**Delete is permanent and server-side**: REST `DELETE /api/sessions/{id}` (+`?profile=` only
when non-default — same per-call scoping rule as archive), idempotent upstream (`already_absent`
is success by contract; a ghost row never 404s). The main-list flow **mirrors archive exactly**:
`deleteButtonTapped` raises a `ConfirmationDialogState` ("This permanently deletes the session
and its history."), `confirmDelete` captures a full rollback payload (session + index + pin
index + seen count), removes optimistically, inserts into the **`deletingIDs` in-flight guard**
(fetch/poll results filter out `archivingIDs ∪ deletingIDs` — either window can resurrect a
removed row), sends `delegate.sessionDeleted` FIRST, and cancels the in-flight fetch before
running the RPC. A transient failure rolls back per **`rollBackFailedRemoval`** (the ONE
rollback rule, shared with archive) and sets the "Couldn't delete the session." banner. The
rule is deliberately asymmetric: the **pin + seen metadata is ALWAYS restored and
persisted** (both live under device-global prefs keys keyed by session id — not
profile-scoped — so skipping them would lose the pin/unread baseline for a session the
server kept), while the **row re-insert applies only when the list still shows the same
context the RPC was issued under** — same profile scope AND same raw search query (the
failure action carries both). A profile mismatch means a cross-profile row that opens under
the wrong scope; a query mismatch means the saved index points into a different result set,
and the poll is paused while searching so the wrong-query row would stick. A skipped
re-insert self-heals: the original context's next fetch returns the still-existing row. On
success the list emits `delegate.sessionDeleteSucceeded` — the confirmation delegate,
distinct from the optimistic `sessionDeleted`. Success also **cancels-or-restarts** the
shared fetch (`cancelOrRestartFetch`, shared with archive/rename success): a bare cancel of
a fetch that was actually pending (`isLoading`, or an active search — the poll is paused
while searching) would strand a stuck spinner / stale search results, so the current-context
fetch restarts instead and lands an authoritative post-RPC response. A **cleared search**
(trimmed-empty `searchQuery` binding) reloads immediately via `load` rather than the 300ms
search debounce — `load` raises `isLoading`, which is what keeps that pending reload visible
to `cancelOrRestartFetch` (the debounced search effect raises no flag, and with the query
empty `isSearching` no longer covers the window). Delete is offered on every row variant
(pinned, cron runs, branch children) — all sections funnel through the one `row(_:)` builder.

**Capability gate — the 405 wrinkle**: `deleteSupported` defaults `true` and flips off lazily
on a definitive verdict from an actual delete (no pre-probe). The verdict is `.notFound` **or**
`.server(status: 405)` — on older agents the path `/api/sessions/{id}` already exists for
`PATCH`/`GET`, so an unsupported `DELETE` returns **405 Method Not Allowed**, not the usual
404. Both flip the flag **silently** (row restored, NO banner — mirror the other silent
capability flips) and hide every Delete affordance plus the Settings row from then on. The flag
mirrors **both ways** with the archived sheet: the sheet's `deleteSupported` is seeded from the
list's flag on present, and a verdict inside the sheet mirrors back via
`ArchivedSessionsFeature.Delegate.deleteUnsupported`.

**`AppFeature` on `sessionDeleted`**: ALWAYS wipe the session's cached snapshot + turn anchor
(`ChatSnapshotClient.deleteSnapshot(sessionID:)`) — a deleted session must never repaint from
the non-authoritative cache. When the deleted id matches the live-chat slot, tear it down too
with **`teardownSlot(flushSnapshot: false)`** — skipping the `persistNow` flush is the point:
the flush would re-save the very snapshot the wipe deletes. Every other teardown keeps the
flush. Archive and delete both pass `thenFill: detailRefill(state)`, which reseats the
regular-width detail column and is `nil` in compact (`docs/features/ipad-layout.md`).
Same deliberate asymmetry as archive: if the DELETE later fails, the list restores the
row but the slot and cache stay cleared — re-opening simply resumes the session fresh.
The **pending-approval badge entry is the exception**: it's dropped on
`sessionDeleteSucceeded` (server-confirmed), NOT at initiation — a failed delete leaves the
approval pending on the server, and nothing short of a fresh approval push would repopulate
a prematurely-cleared entry.

**Archived-sheet delete is immediate — no confirmation (deliberate)**: those sessions are
already tucked away and the sheet is the bulk-cleanup surface. Same optimistic shape as
restore (`deletingIDs` guard, rollback + banner on transient failure, refresh-during-delete
exclusion). **The DELETE round-trip runs in the PARENT list, not the sheet**: a presented
child's effects are cancelled when the sheet is dismissed (`ifLet` semantics), so a
sheet-run DELETE racing Done/swipe-down would be silently dropped after the cache and badge
were already updated. The sheet bubbles `Delegate.deleted(id:session:index:)` FIRST (with
the rollback payload); the list forwards it as its own `sessionDeleted` (so `AppFeature`
applies the same snapshot wipe + slot teardown as a main-list delete — an archived session
CAN be the live slot: opening one from the sheet resumes it without un-archiving, and
another client can archive the slot's session out from under this device; the wipe stays
even if the DELETE later fails), threads the sheet's `profileName` into the RPC, and
**re-injects `deleteSucceeded`/`deleteFailed` only while the SAME sheet presentation still
owns the delete**: the round-trip is stamped with `archivedSheetGeneration` (bumped on
every present) and the outcome must match the current generation AND find the id in the
sheet's `deletingIDs` guard. The id alone is ambiguous — after a dismiss-and-reopen the
same session can be deleted AGAIN, and re-injecting the first request's late failure would
clear the new operation's guard and resurrect its row while the second request's real
outcome then has nowhere to land. A dismissed sheet, a re-opened one's fresh fetch, and a
stale-generation outcome all route to the list instead. With the sheet gone, a verdict
still flips the list's `deleteSupported` (server-wide) and a transient failure surfaces the
list's banner; success always emits `sessionDeleteSucceeded`. Inside the sheet, a completed
delete restarts (not bare-cancels) a listing fetch still in flight — same stale-response
resurrection window as the main list, and the sheet has no poll to self-heal a stranded
spinner.

## Swipe default, row polish & confirmation presentation (#73)

**The default swipe action is a device-local pref**: `SessionSwipeAction` (`archive` |
`delete`, `.archive` default) persisted via `PreferencesClient`, reset in **all three logout
recipes** (Settings clear-token, retry-screen logout, reauth quit). Views must read the
computed **`effectiveSwipeAction`**, which clamps back to `.archive` while
`!deleteSupported` — the stored pref survives the clamp, so it re-activates if a capable agent
returns. Settings exposes a "Default swipe action" `Picker`, rendered only when
`deleteSupported` (the flag is passed in when presenting the sheet); a change persists and
bubbles a delegate so the list mirrors the value immediately.

**Trailing swipe order is destructive-first**: [default action (Archive or Delete per
`effectiveSwipeAction`, destructive, listed FIRST), Rename]. SwiftUI places the first listed
button nearest the edge and makes it the **full-swipe target** — a full swipe must trigger the
destructive default (which still confirms via the dialog), never Rename (Mail-style layout).
Leading swipe (Pin) unchanged. The context menu always offers BOTH Archive and Delete
(Delete capability-gated) regardless of the swipe pref. In the archived sheet Delete is
likewise listed first (full-swipe deletes, immediately).

**Rows are natural-height — no min-height floor**: a one-line row lands around ~44pt total,
and its trailing swipe buttons render as iOS's compact text capsules (the icon-over-label
style needs a taller row). A content floor was tried twice for #73 — 48pt (~70pt cells) and
then 44pt (+20pt over natural, shipped to TestFlight in `df56ca0`) — and **reverted both
times** (#79: testers reported the list "way too high"). The compact list is worth more than
the fuller swipe-button style; the swipe buttons are plain `Button`s, so nothing else keys off
the row height. Don't reintroduce a floor (or a density setting — considered and declined in
#79) for the swipe-button rendering without revisiting that trade-off.

**Confirmations present via `BottomActionSheet`, not `.confirmationDialog`**: on iOS 26 no
system presentation docks at the bottom any more — SwiftUI's `confirmationDialog` renders as a
floating popover anchored to whatever view carries the modifier, **dropping the title and the
Cancel button** (FB20644893); UIKit's `UIAlertController(.actionSheet)` anchors to any popover
`sourceView` the same way and presents CENTERED without one. So `BottomActionSheet.swift`
renders the same reducer-owned `ConfirmationDialogState` in a height-fitted SwiftUI sheet
(content-measured detent, destructive button styled red) — **the state model and every reducer
test against it are untouched**; only the presentation layer differs, and it behaves
identically on iOS 18. Keep raising dialogs through `ConfirmationDialogState`; present them
with `.bottomActionSheet($store.scope(...))`.
