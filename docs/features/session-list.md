# Session list: date sections, inbox cards, cron jobs, branch nesting, delete & swipe polish (#24, #34, #73)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Session list"; this doc is the full contract. Design history:
`docs/plans/completed/`.

## Date sections and inbox cards

The list is the desktop's **Inbox style**, always on and the only list UI — there is no
grouping pref or picker (the workspace/chronological `SessionGroupingMode` was removed; the
card header names the workspace instead). The Sessions tab, top to bottom: the "Sessions"
header, the push card and the tips row (`docs/features/onboarding.md`), a **Pinned** section
(pin order), then the **update-date sections**. Cron jobs and
their runs live in the **Cron Jobs tab** (below). All of it
is display-only over the one `sessions` array. The list is a flat `.listStyle(.plain)` with no
row or section separators, compact section headers (leading title + a hairline to the
trailing edge, centred on the title; `defaultMinListHeaderHeight` 0, `listSectionSpacing(0)`,
the header's own top inset as the only gap), and tighter card row insets than the plain
default.

**The bottom bar** (`HomeTabBar`, a `.safeAreaInset(edge: .bottom)` — a `.bottomBar` toolbar
renders blank in the snapshot host) holds a glass tab pill filling the leading space —
`availableTabs`: Sessions, Cron Jobs only with cron content (`hasCronContent`), then Settings
(icon over label, equal widths; the selected tab on an inner capsule in the accent, slid by
`matchedGeometryEffect`; no unread badge on any tab) — and the round glass New session button
trailing (`GlassBackground`, material fallback below iOS 26), offered on every tab. The pill
shows while `showsTabBar` holds — the search field is closed and no query is active (search is
a Sessions-only mode) — else the bar is just New session. `selectedTab` is in-memory (a launch
starts on Sessions); views render `effectiveTab`, which falls back to Sessions whenever the
selected tab is unavailable, so a poll or profile switch that drops every cron row never
strands an empty tab.

**The Settings tab** (`docs/features/settings.md`) is its own `NavigationStack`
(`SettingsView` owns the `SettingsPath` pushes), so `AppView` LAYERS it over the WHOLE
`NavigationSplitView` — never inside the sidebar column, whose navigation controller would nest
it (tried: on device the list's bar covered Settings and its root title vanished). On iPad it
therefore spans the window, like any tab. The split stays mounted underneath (opacity 0, no hit
testing, `.accessibilityHidden`; the Settings layer also carries the `.isModal` trait, since the
hidden modifier does not reach the list's UIKit-backed rows — and toggling it on the `List`
itself broke the tab switch on device) so the list's `.task` poll, its sheets and the live chat are not
torn down per switch. `selectTab(.settings)` seeds `settings` fresh (the
old `settingsButtonTapped` seeding); re-tapping keeps it; any other tab, a child `dismiss()`
(Reconnect, Sign out, "Ask agent") and the disconnect / install delegates all go through
`closeSettingsTab()` (state dropped → child effects cancelled, tab back to Sessions). While the
tab is open, a trailing reducer (`syncSettingsSeed()`) mirrors the list-owned seed facts —
`connection`, `pushAvailable`, `deleteSupported`, the scoped profile — so a long-lived tab
never shows a stale capability or a deleted profile. `dismissPresentations()` (App Intents)
deliberately leaves the tab alone: it runs in `AppFeature`, outside the list's `ifLet`, so a
nil-out there would orphan Settings' effects. Instead `AppFeature` leaves the tab
(`.home(.selectTab(.sessions))`, an action so the `ifLet` cancels) on every chat route —
`pushTapped`, `launchIntentReceived` (widgets too), the list's `openSession` / `createSession`
delegates — in both layouts, since the chat (compact marker or regular seat, even an in-place
hydrate) would otherwise land hidden under the Settings layer. Under the Settings layer the
list keeps rendering the Sessions rows (the tab Settings always returns to), so their scroll
position survives.

**The nav bar**: Archive on the leading side; the profile pill as the centered title (when
`profilesSupported`); trailing, in one `ToolbarItemGroup` (one glass pill on iOS 26), Search
(Sessions tab only) and the profile Edit menu. **The pill's menu selects in ONE tap**: every
profile as a plain button (no checkmarks, Safari-style — a house for the default, a person
glyph for custom ones; the pill title names the active one), a divider, then Add profile. No
nested per-profile submenu. **Rename and Delete live in the trailing pencil menu**,
for the SELECTED profile only, shown while `canEditSelectedProfile` — a known custom profile
(never the default one, never a selection the profiles list hasn't loaded, never without the
profiles API). Both route through the existing rename alert and `.bottomActionSheet` delete
confirmation.

**Search is opened from the toolbar** (Sessions tab only). `searchButtonTapped` sets
`isSearchPresented`, which hides the nav bar row (Archive, profile pill, Search, Edit) and shows a
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

**The compact `SessionRowView` stays only on dense surfaces**: the flat cron fallback
(`cronRunRow(_:)`, agents without the jobs API) and the archived sheet. Cards (`row(_:)`) and
compact rows share one affordance funnel, `sessionRow(_:content:)` — tap, highlight +
`isSelected` trait, swipes, context menu are identical for both. The run rows under an
expanded cron job are neither: timestamp-only, tap-only (see below).

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
never appear in Pinned or the date sections. The tab exists whenever `hasCronContent` holds:
with the jobs API, any fetched job (a job with no runs stays reachable; runs alone, incl. a
deleted job's, never bring the tab back); without it, any cron run (the flat fallback). It
renders a "Cron Jobs" title row and the jobs, and is never searched. The "No sessions"
placeholder follows `showsEmptyPlaceholder`: the Sessions tab with no search hit (or, outside
search, no interactive session), not loading or failed; under the push card or tips row it
flows as a row (`showsInlineEmptyPlaceholder`, `docs/features/onboarding.md`). A non-search list with no interactive
session and no jobs known holds `isLoading` until the load's cron-jobs response lands
(`awaitsCronJobs`), so the placeholder and the Cron Jobs tab appear together; a transient cron
failure there settles on the placeholder.

**The Cron Jobs tab lists *jobs* only, desktop-style** (`State.sortedCronJobs`: soonest next
run first, no-next-run last, then title). `GET /api/cron/jobs` is fetched sequentially INSIDE
the session-load effect (after `.sessionsResponse`, same CancelID — deterministic TestStore
order, no racy merge), with the LITERAL selected profile name when `profilesSupported`,
unscoped otherwise. **Capability-gated**: a jobs 404 flips `cronJobsSupported` off → the flat
run list (`cronSessions` via the compact `cronRunRow(_:)`), fetch skipped thereafter; transient
failures keep the previous jobs (no flapping). Agents without the jobs API therefore keep the
flat list exactly as before.

**Never group cron runs by session id.** The old client bound a run session to its job via the
id-embedded prefix (`cron_{job_id}_{ts}`); upstream hermes-agent `e2042c84` (2026-10-15) moved
cron onto the unified runtime, whose runs get `local-*` session ids, and `/api/sessions` rows
carry no `cron_job_id` — so every new run fell out of its job into an "unmatched" pile. The id
parser, the job↔run grouping, the unmatched list and the per-job unread rollup were removed;
a job's runs come only from the server's own job↔run join:

- **Runs load per expanded job** from `GET /api/cron/jobs/{id}/runs?limit=5` (`cronPeekLimit`;
  profile-scoped like the jobs fetch) into ONE slot, `expandedCronRuns` (`nil` = spinner, `[]`
  = "No runs yet"). The fetch runs on its own `CancelID.cronRuns` with `cancelInFlight`, so a
  refresh or a job switch supersedes it without touching the list load, and a late response
  for a job that is no longer expanded is dropped (`cronRunsResponse(jobID:)` guard). Tap is
  single-open (`expandedCronJobID`); every collapse — re-tap, the jobs-API 404 flip, a profile
  switch, deleting the expanded job, a jobs refetch that no longer lists it — goes through
  `collapseExpandedCronJob` (clears id + slot, cancels the fetch), so one job's runs never
  show under another; `onDisappear` cancels the fetch too.
- **Refresh**: a `load` (the 10 s poll, pull-to-refresh, the Run now success) refetches the
  expanded job's runs alongside — never inside — the shared-`fetch` list effect, only while
  the Cron Jobs tab is on screen (`effectiveTab == .cron`; never on the Sessions tab or while
  searching); `selectTab(.cron)` refetches them on return.
- **Failure**: any `/runs` failure, 404 included, is a load failure — "Couldn't load runs" on
  the FIRST load only (a failed refresh keeps the runs on screen; the next poll retries). It
  flips NO capability: upstream ships `/runs` with the jobs API, and a 404 there can also mean
  the job is gone.
- **Run rows are timestamp-only** (sibling runs share the job's title): `CronJob.runTimestampLabel`
  over `updatedAt ?? startedAt` (desktop `last_active || started_at`), "Jun 10, 07:00",
  a `Date.VerbatimFormatStyle` with a POSIX locale in the list calendar's time zone, so
  snapshots are locale-deterministic. A session run (`isCron`) is tap-only — no swipe or
  context menu — and `cronRunTapped` looks it up in `expandedCronRuns`, NOT `state.sessions`
  (an older run may sit outside the list's 50-row cron slice), then opens it. A script-only
  `cron_output` row (synthetic `cron_output:…` id, no backing session) is plain secondary text —
  never a tap; `/runs` rows that don't decode (incl. a row with no `id`) are dropped, not fatal.

**Job rows**: a state pip (**green live / amber paused** — deliberately NOT the accent, which is
orange and would be indistinguishable from amber; red error, gray inactive), the title, and a
status caption from `CronJob.statusCaption(now:)` off `state.now` (poll-refreshed — no
per-second ticker). Inactive states (`paused` / `error` / `completed` / `disabled`, incl.
`enabled == false`) show their word, so a paused job never reads "Next in 1 hr."; an active job
shows "Next …", or an orange "Overdue · … ago" once `next_run_at` is more than
`CronJob.overdueGrace` (15 min, hermes-agent `_OVERDUE_GRACE_SECONDS` / desktop
`NEXT_RUN_OVERDUE_GRACE_MS`; strictly greater, so the boundary stays "Next") in the past — a
parked past slot is the only visible trace of a dead scheduler; with no next run the schedule
stands in. The caption is part of the row's accessibility label, so the state word is
announced.

**Job actions** (context menu): Run now / Pause / Resume / Delete, all through
`performCronAction` (`cronActionInFlightIDs` double-fire guard; **no optimistic job-state
mutation**). Success reconciles by kind (`CronJobActionKind`): Run now → full `load` (sessions +
jobs + the expanded job's runs, so the new run appears); pause/resume → jobs-only refetch.
**Delete** raises a `ConfirmationDialogState` (title names the job; presented via
`.bottomActionSheet`) and is NOT optimistic: the row stays until `DELETE /api/cron/jobs/{id}`
returns. A confirm that hits the in-flight guard is never dropped silently: it banners
`cronJobBusyMessage`. Success — or a **404, read as already gone** — drops the job locally
(collapsing it if expanded), then `cancelOrRestartFetch`: a pending list load or an active
search is restarted (so a pre-DELETE jobs response can't bring the row back; the restarted
load refetches the jobs, a search load skips them until its clear reloads), otherwise the
in-flight fetch is cancelled and a jobs-only refetch runs. Any other failure banners the
server's copy. The job's past runs stay on the server but are no longer listed in the tab.

**No cron unread tracking**: no tab badge, no job-row dot (desktop parity). A run row still
shows the shared unread dot when that run is in the list's cron slice and unread
(`unreadSessionIDs`); the flat fallback keeps the regular row dot.

## Shared pin membership, local order

**Pin membership syncs with the server; pin order stays device-local.**

- Server sync requires `profilesSupported` and pin capability discovered from a list response.
  Otherwise pins stay local-only. Writes use the selected literal profile, including `"default"`.
  After discovery, search rows support Pin/Unpin even without a `pinned` field; search responses
  never reconcile membership or initiate migration.
- Explicit list membership is authoritative except for pending writes and legacy migration.
  Nil fields and absent rows preserve cached membership; local ordering is never server-owned.
- Legacy pins remain pending per server across pages, profiles, failed uploads, and normal
  relaunches until acknowledged or observed pinned. Failed uploads retry silently on a later
  capable list; retired pins follow server membership. Logout clears migration state.
  Only ids still pinned locally are uploaded: a pin change made while server writes are off
  (e.g. a failed profiles probe) stays local, and the next capable list decides membership.
- Pin writes are single-flight per ID. Failure restores only that ID at its bounded prior index
  and shows an error that survives the completion-triggered refetch. Stale pre-write fetches
  cannot overwrite completed writes; profile switches clear old rows.
- Pin and archive/delete do not exclude each other, including archived-sheet deletes.
  Confirmed removal prevents a later pin failure from restoring removed membership.

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
empty `isSearching` no longer covers the window). Delete is offered on every session row
variant (pinned, flat-fallback cron runs, branch children) — cards and compact rows alike
funnel through the one `sessionRow(_:content:)` builder. The run rows under an expanded cron
job are tap-only (no swipe or context menu, as on the desktop); deleting a cron *job* is its
own flow (see "Cron sessions & the Cron Jobs tab").

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

## Archive & Delete from the open chat's ⋯ menu

The chat screen's ⋯ menu (`ChatMenuButton`) offers Archive and Delete next to Rename / Copy ID,
over the SAME REST calls as the list (`rest.archive` / `rest.deleteSession`) and the same
`ConfirmationDialogState` copy, presented with `.bottomActionSheet`. Differences from the list,
all deliberate:

- **Scoped to the chat's own `profileName`**, never the list's `scopedProfileName`: the slot
  survives a sidebar profile switch, so the list's scope could hit another profile's `state.db`.
- **Not optimistic, and run by the parent**: the chat only confirms and hands the call to
  `AppFeature` (`ChatFeature.Delegate.removeSession`, carrying the chat's connection and
  profile). A slot effect would die with the slot (`.ifLet`) when the user goes back or picks
  another chat before the reply — the archived sheet's reason for running its DELETE in the list.
  `isRemovingSession` disables both items while the call is in flight.
- On success (`sessionRemovalFinished`) `AppFeature` applies the list contract through the
  SAME helpers the list's own archive/delete use (`closeRemovedSession`,
  `clearDeletedSessionBadge`), so the two paths can't drift. A slot that STILL holds the
  session is torn down FIRST, synchronously, before any awaited effect (the badge update awaits
  the notification center — a chat opened in that gap must never be the one torn down):
  archive → `teardownSlot(thenFill: detailRefill)`; delete → `teardownSlot(flushSnapshot:
  false)`, then the snapshot wipe, and the approval-badge entry drops at once (already
  confirmed). **In compact the on-screen marker is popped with the slot** — otherwise the stack
  keeps a `ChatScreen` destination with no chat behind it (blank screen under a Back button).
  The list drops the row and its pin/seen entries via `sessionRemovedElsewhere`, which persists
  them BEFORE restarting an in-flight fetch (the restart's `reloadPrefs` would otherwise read
  the stale pins/seen back).
- A failure goes back to the chat that asked while the slot still holds it (banner "Couldn’t
  archive/delete the session.", items re-enabled); with the chat gone it lands on the list's
  `loadError` instead. Routing keys on the chat's in-flight `removingSessionID`, not its
  `sessionKey`, so a #17 heal that recreated the session mid-call can't strand the items
  disabled.
- **The removal effect dies with the identity**: every logout / different-user re-auth cancels
  it (`CancelID.sessionRemovals`), and a reply whose `removal.connection` isn't the current
  list's server is dropped — no stale banner, no 404/405 verdict on the wrong server.
- **Delete follows the list's `deleteSupported`**, mirrored both ways: `AppFeature` seeds it on
  every seat and copies list changes onto the slot; a 404/405 from the chat's delete flips the
  list's flag silently (and so the slot's). Archive has no capability flag (neither does the
  list's).
- **Hidden until the session has a server row** (`canArchiveOrDelete`): a new chat before its
  first prompt (`awaitsFirstPersist`) and an unpersisted branch offer neither action.
- Known limitation: a chat opened from the archived sheet still offers Archive (the chat
  doesn't know the row's archived state); left as is.

## Swipe default, row polish & confirmation presentation (#73)

**The default swipe action is a device-local pref**: `SessionSwipeAction` (`archive` |
`delete`, `.archive` default) persisted via `PreferencesClient`, reset in **all three logout
recipes** (Settings → Sign out, retry-screen logout, reauth quit). Views must read the
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
