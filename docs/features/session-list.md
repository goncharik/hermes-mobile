# Session list: date sections, inbox cards, cron jobs, branch nesting, delete & swipe polish (#24, #34, #73)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Session list"; this doc is the full contract. Design history:
`docs/plans/completed/`.

## Date sections and inbox cards

The list is the desktop's **Inbox style**, always on and the only list UI — there is no
grouping pref or picker (the workspace/chronological `SessionGroupingMode` was removed; the
card header names the workspace instead). The Sessions tab, top to bottom: the "Sessions"
header, a **Pinned** section (pin order), then the **update-date sections**. Cron runs live in
the **Cron Jobs tab** (below). All of it
is display-only over the one `sessions` array. The list is a flat `.listStyle(.plain)` with no
row or section separators, compact section headers (leading title + a hairline to the
trailing edge, centred on the title; `defaultMinListHeaderHeight` 0, `listSectionSpacing(0)`,
the header's own top inset as the only gap), and tighter card row insets than the plain
default.

**The bottom bar** (`.safeAreaInset(edge: .bottom)` — a `.bottomBar` toolbar renders blank in
the snapshot host) holds a glass `Sessions | Cron Jobs` tab pill on the leading side (icon over
label; the selected tab on an inner capsule in the accent, slid by `matchedGeometryEffect`;
the Cron Jobs tab carries the `cronUnreadCount` badge) and the round glass New chat button
trailing (`GlassBackground`, material fallback below iOS 26). The pill shows only while
`showsTabBar` holds — cron content exists (`hasCronContent`), the search field is closed, and
no query is active (search is a Sessions-only mode) — else the bar is just New chat.
`selectedTab` is in-memory (a launch
starts on Sessions); views render `effectiveTab`, which falls back to Sessions whenever the pill
is hidden, so a poll or profile switch that drops every cron row never strands an empty tab.

**Search is opened from the toolbar** (Sessions tab only): a search button sits beside Archive
in one trailing `ToolbarItemGroup` (one glass pill on iOS 26). `searchButtonTapped` sets
`isSearchPresented`, which hides the nav bar row (settings, profile pill, Archive) and shows a
glass capsule field — focused on open — beside a round glass close button in a top
`safeAreaInset`. `searchCloseTapped` hides it and clears the query, reloading the normal list
at once when a query was live (the same immediate `load` a cleared query gets through the
binding). Typing still drives the 300 ms debounced search via the `searchQuery` binding.

**The load fetches two source-scoped slices, never one shared page** (desktop parity): the
interactive list with `exclude_sources=cron`, then up to 50 cron runs with `source=cron`
(`SessionSourceFilter`, both endpoints), merged by id into `sessions` (`mergeSessionSlices`).
Cron runs are always the newest rows, so in one 50-row page a busy job crowded real
conversations out of the window — the list showed a handful while desktop showed dozens. An
agent that predates the parameters returns the same unscoped page twice, which merges back to
that page. A failed cron slice fails the load like any other (banner, previous rows kept).

**Bucketing is pure HermesKit** (`SessionDateBucket`, unit-tested on macOS), a port of desktop
`calendarBucket` (`apps/desktop/src/lib/time.ts`). Every date is mapped to its **nominal day**
= its local calendar day, or the day before when the local hour is under `dayRolloverHour`
(4: a 1 AM session still counts as the previous day; judged on the local hour, so a DST jump
never moves the boundary), and buckets are judged on the injected `Calendar` (time zone,
locale, `firstWeekday`):

| Kind | Rule (nominal days) | Key | Label |
|---|---|---|---|
| `today` | day diff `<= 0` | `today` | Today |
| `yesterday` | day diff `== 1` | `yesterday` | Yesterday |
| `thisWeek` | on/after this calendar week's start | `this-week` | Earlier this week |
| `lastWeek` | on/after the previous week's start | `last-week` | Last week |
| `thisMonth` | same year + month | `this-month` | Earlier this month |
| `month` | same year | `m-YYYY-M` | `MMMM` ("September") |
| `monthYear` | prior year | `my-YYYY-M` | `MMMM yyyy` ("December 2025") |

Month keys use the Calendar's **1-based** months (`m-2026-2` = February; desktop's JS keys are
0-based — the key is a local section identity only, never shared); a leap month appends `L`
and an era other than today's appends `-e<era>`, and the month/year rules compare calendar
intervals, so non-Gregorian calendars never merge distinct months (Gregorian keys carry no
suffix). Month labels come from `Date.FormatStyle` (wide month, + year) on the calendar's
locale + time zone. "Today" is the top label (desktop's "Earlier today" only exists because
of its unlabelled recent-head run, which is deliberately **not ported** — mobile labels every
section).

**Sections** (`SessionDateSection`, built by pure `groupEntriesByDate`) walk the
branch-flattened `chronologicalEntries` in order and never re-sort:
- a section opens only on a **top-level** entry whose key changes; branch children append to
  the current section, so a parent + branches cluster never splits across a header;
- a top-level entry buckets on its **cluster's freshest `updatedAt`** (itself + the branch
  children beneath it) — the same key `flattenSessionsWithBranches` sorts clusters by, so a
  stale parent lifted by a fresh branch lands in the fresh section;
- **a key never repeats**: on a non-monotonic input the rows append to the current section
  (desktop's `emitted` guard), so `ForEach` section ids stay unique; no empty section exists;
- a cluster with no `updatedAt` goes to a trailing **"Older"** section (id `older`).

`State.dateSections` is computed from `state.now` (poll-refreshed for the age labels and the
cron countdown — headers re-bucket on the same cadence, no new ticker) and `State.calendar`,
captured alongside `now` on load from the dedicated `\.sessionListCalendar` dependency (the
library `\.calendar` has no test value), so TestStores and snapshots pin it.

**Cards** (`SessionCardView`) render every interactive row — Pinned, date sections, AND search
— so one column never mixes card and one-line geometry (desktop parity). What a card shows is
derived in HermesKit by `SessionCardContent` (unit-tested); the view only lays it out.
Anatomy:
1. **Header**: the status dot (below), the branch elbow stem (`└─`/`├─`) when nested, the
   workspace label (`Session.workspaceLabel`: `cwd` last path component; a root path verbatim; else
   "No workspace"), pin glyph, then the relative age on the trailing edge. Search passes
   `showsWorkspace: false` — a search hit carries no `cwd`, so the slot is left out rather
   than claim "No workspace".
2. **Title**: `displayName` (`resolvedTitle ?? resolvedPreview ?? id`), headline, semibold —
   bold when unread — up to two lines.
3. **Preview**: one line, shown **only under a real title**. An untitled session promotes its
   preview into the title slot and drops this line, so the text never shows twice. Search
   results (no title, snippet as preview) therefore show the match snippet as the title.
4. **Footer**: the raw `Session.model` id (verbatim like the chat chip; decoded from the list
   DTO, nil on older agents) and "1 message" / "N messages" (plain English plural; hidden for
   nil or 0). The whole line is omitted when both are absent.

Cards are natural-height (no min-height floor — see "Rows are natural-height" below), carry
their own working glow (`CardActiveGlow`, separate pulse state from the row's), and expose one
combined accessibility label (`SessionCardContent.accessibilityLabel`: workspace, title,
preview, model, count, age, then the status and Pinned). Nested branch cards keep a 16pt
leading indent on top of the header stem, so the whole card reads as belonging to the parent.

**The status dot** mirrors desktop's `SessionStatusDot` for the states mobile can know, one
state resolved by `SessionStatus` (needs-input over working over unread): **amber** when an
approval / clarify waits on the user (`AppFeature.State.needsInputSessionIDs` — unopened
approval pushes plus the live chat while its card is up, passed in by `AppView`), the
**accent** while a turn runs, **green** for unread, and a smaller faint dot when idle, always
in a fixed-width slot so header text keeps one left edge. Desktop's stalled / background /
draft states need live events for every session and are not shown. The compact row's unread
dot keeps the accent.

**The compact `SessionRowView` stays only on dense surfaces**: cron run peeks, the flat cron
fallback, unmatched cron runs (`cronRunRow(_:)`), and the archived sheet. Cards (`row(_:)`) and
compact rows share one affordance funnel, `sessionRow(_:content:)` — tap, highlight +
`isSelected` trait, swipes, context menu are identical for both.

**Archived** is a direct top-trailing **"Archived sessions" toolbar button** (`archivebox`;
the former organize `Menu` — grouping picker, cron toggle, Archived — is gone) presenting a
sheet backed by a server query (`?archived=only`, `ArchivedSessionsFeature`); restore =
`archive(id, false)`; tap-to-open bubbles up the existing `openSession` delegate.

**Stale prefs**: `PreferencesClient.live(defaults:)` removes the retired
`hermes.session-grouping-mode`, `hermes.show-cron-section` and `hermes.cron-section-collapsed`
keys once, when it is built (no migration — cron runs have their own tab now).

## Cron sessions & the Cron Jobs tab (#24)

**Cron sessions** (`source == "cron"`, decoded onto `Session` via `SessionListDTO`) are pulled
into the **Cron Jobs tab**. The partition lives in the reducer's computed state
(`cronSessions` vs the non-cron `interactiveSessions` that feeds
`pinnedSessions`/`unpinnedSessions` → `chronologicalSessions` → `dateSections`), so cron rows
never appear in Pinned or the date sections. The tab exists whenever `hasCronContent` holds
(any cron run OR any fetched job, so a job with no runs in the fetched window stays
reachable); it renders a "Cron Jobs" title row and the jobs, and is never searched. The "No
sessions" placeholder follows `showsEmptyPlaceholder`: the Sessions tab with no search hit (or,
outside search, no interactive session), not loading or failed. An empty non-search list with
no jobs known holds `isLoading` until the load's cron-jobs response lands (`awaitsCronJobs`),
so the placeholder and the tab pill appear together; a transient cron failure there settles on
the placeholder.

**The Cron Jobs tab groups runs under their *jobs*, desktop-style**: `GET /api/cron/jobs` is
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
inline peek (`expandedCronJobID`) of the newest `cronPeekLimit` runs via the compact
`cronRunRow(_:)`; runs matching no fetched job render flat below (`unmatchedCronSessions` —
never hide output).
The tab carries the aggregate `cronUnreadCount` badge; cron sessions use the same shared
server-backed unread state as interactive rows (with the legacy device-local `seenCounts`
fallback below). **Capability-gated**: a 404 flips
`cronJobsSupported` off → flat run list, fetch skipped thereafter; transient failures keep the
previous jobs (no flapping). Jobs are fetched with the LITERAL selected profile name when
`profilesSupported` (matching the scoped session list, so a job's runs are actually present),
unscoped otherwise.

## Shared pin membership, local order

`Session.pinned` is an optional server membership flag shared with Desktop; pin order remains
**device-local** in `PreferencesClient.pinnedIDs`. A capable profile-list response establishes
server-level pin support through a checkpoint keyed by normalized server URL. After discovery,
Pin/Unpin also PATCHes search rows whose `pinned` field is absent or null. Requests carry the
selected literal profile, including `"default"`. Before discovery, search pins stay local.
Search responses never reconcile membership or create migration checkpoints.

The first capable list snapshots legacy local pins into the checkpoint's pending IDs. These
survive later pages, profile switches, absent/null rows, failed uploads, and normal relaunches.
An explicit server `true` retires a pending ID; an explicit `false` uploads it, even on a later
page or profile. IDs remain pending until success, so silent failures retry on the next capable
list. The per-ID in-flight mutation prevents duplicate concurrent writes. Once retired, a later
server `false` removes membership normally. Successful explicit user writes also retire their
pending migration ID. Logout clears every migration checkpoint.

Persistence uses the existing `PreferencesClient` storage contract; crash-durable flushing
and atomic persistence with network dispatch are not guaranteed. Nil and absent list rows
preserve cached membership. Server reconciliation skips IDs with a pending pin write.

Fetches use the existing cancellable `CancelID.fetch` effect. Starting a pin does not cancel an
in-flight fetch. Completion uses `cancelOrRestartFetch` to invalidate pre-write results and
restart a pending list/search; user failures restore only that ID at its bounded previous index
and surface the error. Switching profiles clears old rows before loading the new scope.

Archive/Delete remain available while a pin is pending, including in the archived sheet.
Pending pins retain their own rollback until removal succeeds; confirmed removal clears their
prior pin index so a late failed pin cannot restore removed membership. A pending removal still
guards new pin actions for that ID. Search and list share the same Pin/Unpin affordances.

## Shared unread state

On agents that return the optional `unread` field, the backend owns read state: its
`last_read_at` watermark is shared with Desktop, so opening a row on either client clears the
other client's dot on its next poll, and later server activity raises it everywhere. Mobile
PATCHes `{"unread": false}` on **every** open—even when the row already says false—because false
also represents an untracked legacy row (`last_read_at == NULL`); the first acknowledgement is
what makes later activity observable. A completion received while the chat remains visible
acknowledges again after the new activity, so the reply being watched is not rediscovered as
unread on Desktop. The write is optimistic and best-effort: a failed PATCH is reconciled by the
next authoritative list poll.

Older agents omit `unread`. For those rows only, mobile preserves its existing device-local
`seenCounts` behavior (`message_count > last seen`), including first-sight seeding. This is a
per-row fallback—not a server-wide capability latch—so mixed/transitional responses stay safe.

## Branch nesting is display-only (#34)

`parent_session_id` decodes leniently from REST onto `Session.parentSessionID`
(`trimmedNonEmpty`); pure `flattenSessionsWithBranches` (desktop algorithm — sibling recency
sort, group-recency lift, recursion, cycle-safe, trailing sweep, **`byVisibleID` lineage
aliasing**: `_lineage_root_id` → `Session.lineageRootID` keeps a branch nested after its parent
auto-compresses and the row id rotates to the continuation tip) runs per rendered lane (pinned /
chronological — the latter then split into date sections without breaking a cluster) after the
cron partition, emitting `└─`/`├─` stems. Recency is
`updatedAt ?? .distantPast` — deliberately the SAME rule the lanes sort by (no desktop
`started_at` fallback), so nesting never reorders flat rows. Orphans (parent absent from the
lane) de-nest — never hidden; the Pinned lane keeps pin order (`sortTopLevelByRecency: false`; a
pinned branch nests only when its parent is also pinned, otherwise it de-nests); search /
archived / cron stay flat. Row identity and swipe/context affordances are unchanged.

## Session delete (#73)

**Delete is permanent and server-side**: REST `DELETE /api/sessions/{id}` (+`?profile=` per
the per-call scoping rule in `docs/architecture.md`, same as archive), idempotent upstream (`already_absent`
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
(pinned, cron runs, branch children) — cards and compact rows alike funnel through the one
`sessionRow(_:content:)` builder.

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

**Rows are natural-height — no min-height floor** (inbox cards included): a one-line row
lands around ~44pt total, and its trailing swipe buttons render as iOS's compact text capsules
(the icon-over-label style needs a taller row). A content floor was tried twice for #73 — 48pt (~70pt cells) and
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
