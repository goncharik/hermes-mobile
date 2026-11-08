# Cron Jobs tab: desktop parity (run grouping, job status, delete)

## Overview
- Rework the Cron Jobs tab to match the desktop sidebar's cron section
  (`apps/desktop/src/app/chat/sidebar/cron-jobs-section.tsx` + `apps/desktop/src/app/cron/job-state.ts`
  on upstream `main`). It fixes three user-reported problems:
  1. **Runs not grouped under their job (bug).** The client works out a run's job from its session id
     (`CronJob.jobID(fromSessionID:)`, which expects `cron_{job_id}_{YYYYMMDD}_{HHMMSS}`). Upstream
     hermes-agent `e2042c84` (2026-10-15, "find unified-runtime cron runs by their scheduler
     admission") gives new runs `local-*` session ids. The job binding (`cron_job_id`) lives only in
     the SessionDB and is exposed by `GET /api/cron/jobs/{id}/runs` and the single-session detail
     endpoint, NOT by the `/api/sessions` list. So every run since an agent update lands in the
     flat `unmatchedCronSessions` list.
  2. **Job status not legible.** The 8 pt state dot is the only status signal. A paused job still
     reads "Next in 1 hr.", and the amber paused dot looks like the orange accent's unread dot.
  3. **No way to delete a job.** The context menu offers only Run now and Pause/Resume, even though
     `DELETE /api/cron/jobs/{id}` exists upstream.
- Desktop parity is a deliberate product decision from the brainstorm: the tab shows job rows only,
  an expanded job loads its runs from the server, and there is no cron unread tracking.

## Context (from discovery)
- **Files/components involved:**
  - `HermesKit/Sources/HermesKit/Models/CronJob.swift`: the job model, `jobID(fromSessionID:)`,
    `relativeRunLabel`
  - `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`: `cronJobs`, `triggerCronJob`,
    `pauseCronJob`, `resumeCronJob` (~L282–293 / L526–551), the shared POST helper `cronJobAction`
    (~L641), and `SessionListDTO` (~L978, internal, reusable)
  - `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`: `CronJobGroup` (top of file),
    `cronPeekLimit` / `cronJobGroups` / `unmatchedCronSessions` / `hasCronContent` /
    `cronUnreadCount` (~L291–372), `.pollTick` (~L717), the cron actions (~L756–807),
    `sessionTapped` (~L964, requires the id to be in `state.sessions`), `Dialog` (~L609),
    `performCronAction` (~L1676), and the profile-switch resets of `expandedCronJobID`
    (~L771/1405/1508)
  - `HermesMobile/Sources/Features/SessionListView.swift`: `cronTabContent` (~L231), `cronJobRow`
    (~L265), `cronStateColor` (~L323), the accessibility label (~L332), the tab badge (~L497/553),
    and `cronRunRow` (~L592)
  - `HermesMobile/Sources/DemoMode.swift`: the seeded cron jobs and runs, and `expandedCronJobID`
  - Tests: `HermesKit/Tests/HermesKitTests/{CronJobTests,SessionListCronTests,HermesRESTClientTests}.swift`,
    `HermesMobileTests/SessionSnapshotTests.swift` (cron tab ~L511)
- **Related patterns:** capability gating through `cronJobsSupported` (404); `cronActionInFlightIDs`
  as a double-fire guard; no optimistic changes to job state (refetch instead);
  `ConfirmationDialogState` + `.bottomActionSheet` for destructive actions; the 10 s
  `continuousClock` poll; `RESTError.notFound` for 404.
- **Upstream facts (verified on `upstream/main`):**
  - `GET /api/cron/jobs/{job_id}/runs?profile=&limit=` returns `{"runs": [...], "limit": n}`,
    newest first, with limit clamped to 1–100.
  - Session rows in that response have the `/api/sessions` row shape with `source: "cron"`.
  - Script-only rows have `source: "cron_output"` and no backing session. Their `id` is a synthetic
    `cron_output:…`, and a row may lack an `id` entirely.
  - `DELETE /api/cron/jobs/{id}?profile=` → `{"ok": true}`. Unknown job → 404; a bad id → 400 with
    `detail`.
  - Server-side `effective_job_state` makes `state` authoritative: `scheduled` / `running` / `paused`
    / `error` / `completed` / `disabled`.
  - Overdue grace is 15 min (`_OVERDUE_GRACE_SECONDS`, desktop `NEXT_RUN_OVERDUE_GRACE_MS`).

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task), consistent with prior plans
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
- run tests after each change (`make test`, or `script -q /dev/null swift test --package-path HermesKit`)
- maintain backward compatibility: agents without the jobs API (404) keep today's flat run list unchanged
- commit at each task completion; commit messages start with a capital verb, no conventional prefixes

## Testing Strategy
- **unit tests**: `swift test` (HermesKit) covers decoding, the pure status helper, the REST client
  (URL/method/query via the existing mock-protocol pattern in `HermesRESTClientTests`), and the
  reducer through `TestStore` + `TestClock` + `@Dependency` overrides.
- **snapshot tests**: `make snapshot`. The cron tab is a `List`, so use `deviceImage()`
  (`componentImage()` paints no `List` rows). Re-record the existing cron baselines in the same PR.
  To add one new snapshot, run `make snapshot` twice: the first run records it and fails by design,
  the second asserts it clean.
- no UI e2e suite in this project; no hosted behaviour-probe tests.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Job rows only.** With the jobs API, the Cron Jobs tab lists the fetched jobs (sorted as today
  by `cronJobOrder`) and nothing else. The id-prefix grouping, the unmatched flat list and the
  cron unread badge are removed. Runs of deleted jobs no longer appear in the tab, as on the
  desktop. The `source=cron` sessions slice of the list load stays: it still feeds `hasCronContent`
  and the agents-without-jobs-API flat fallback.
- **Runs for the expanded job come from the server.** Expanding a job (`expandedCronJobID`, one at a
  time as today) fires a cancellable `GET /api/cron/jobs/{id}/runs?limit=5`. The result lives in
  one state slot for that job. It refreshes on each poll tick that reloads the list and after a
  successful Run now; collapsing the job or switching to another cancels the request and clears the
  slot.
- **Run rows reuse `Session`.** `/runs` session rows have the `/api/sessions` shape, so they decode
  through the existing `SessionListDTO.asSession`. This is a deliberate simplification of the
  brainstorm's "new `CronRun` model": no parallel type. `isCron` (`source == "cron"`) decides
  whether a row opens a chat; `cron_output` rows render as plain text. Each row shows only its
  timestamp, as on the desktop.
- **Status in words.** A pure `CronJob.statusCaption(now:)` replaces the next-run caption for
  inactive states (Paused / Error / Completed / Disabled), and flags active jobs whose `next_run_at`
  is more than 15 min in the past ("Overdue · 2 hr. ago"). The state dot keeps its colours; the
  trailing unread dot on the job row goes away.
- **Delete with confirmation.** The context menu gains a destructive Delete, confirmed through the
  existing `confirmationDialog` (`.bottomActionSheet`). The request runs through the
  `cronActionInFlightIDs` guard and is not optimistic. A 404 means the job is already gone and is
  treated as success.

## Technical Details
- **REST client** (`HermesRESTClient`):
  - `cronJobRuns: (connection, id, profile, limit) async throws -> [Session]`. It sends
    `GET /api/cron/jobs/{id}/runs` with `limit` and an optional `profile` query item. A private
    `CronRunsResponse` decodes `runs` element by element: each row goes through `SessionListDTO`,
    and a row that fails to decode (e.g. a script row without `id`) is DROPPED rather than failing
    the array. A missing `runs` key yields `[]`.
  - `deleteCronJob: (connection, id, profile) async throws -> Void` sends
    `DELETE /api/cron/jobs/{id}`. The private helper `cronJobAction` becomes method-aware: POST
    with `{}` for trigger/pause/resume, DELETE with no path suffix and no body. Both keep the raw-id
    interpolation (`makeURL` percent-encodes).
  - `testValue`s follow the `@DependencyClient` defaults.
- **State** (`SessionListFeature.State`):
  - `expandedCronRuns: [Session]?`: nil means not loaded yet (spinner); `[]` means "No runs yet".
  - `expandedCronRunsFailed: Bool`: set when the FIRST load fails ("Couldn't load runs"); a failed
    refresh keeps the existing `expandedCronRuns`.
  - Remove `cronUnreadCount` and `unmatchedCronSessions`. `CronJobGroup` collapses to the bare
    `CronJob`: `cronJobGroups` becomes `sortedCronJobs: [CronJob]`, and the struct is deleted.
  - `hasCronContent = !cronSessions.isEmpty || (cronJobsSupported && !cronJobs.isEmpty)`.
  - Every existing `expandedCronJobID = nil` site (404 flip, profile switches) also clears
    `expandedCronRuns` / `expandedCronRunsFailed`.
- **Actions:**
  - `cronJobTapped(id)` toggles `expandedCronJobID`. Expanding clears the slot and fires
    `fetchExpandedCronRuns`; collapsing clears the slot and `.cancel(id: CancelID.cronRuns)`.
  - `cronRunsResponse(jobID:, Result<[Session], RESTError>)` is ignored when
    `jobID != expandedCronJobID` (a stale response after a switch).
  - `cronRunTapped(id)` looks the run up in `expandedCronRuns`, requires `isCron`, and then does the
    same thing as `sessionTapped`: `markLocallyRead` + `.delegate(.openSession(run))`. It cannot reuse
    `sessionTapped`, which requires the id to be in `state.sessions`, and an older run may not be in
    the 50-row cron slice.
  - `deleteCronJobTapped(id)` presents the confirmation dialog (new `Dialog.confirmDeleteCronJob(id:)`).
    Confirming sends `deleteCronJob(id)` through `performCronAction` with a completion kind for
    delete.
  - `cronJobActionFinished` gains a kind (trigger / pauseResume / delete) instead of the
    `refetchSessions: Bool`:
    - delete success, or delete `.notFound` → remove the job from `cronJobs`; if it was the expanded
      job, clear `expandedCronJobID` and the slot; then run a jobs-only refetch.
    - any other delete error → `loadError = error.message`, with no state change.
    - trigger success → today's full `load` PLUS a refetch of the expanded job's runs.
    - pause/resume → unchanged.
- **Poll:** `.pollTick` → `.pulledToRefresh` → `load`. Merge in `fetchExpandedCronRuns` whenever
  `expandedCronJobID != nil && cronJobsSupported`, so pull-to-refresh refreshes the open job's runs
  too. Use its own `CancelID.cronRuns` with `cancelInFlight: true`, NOT `CancelID.fetch`, so it
  never cancels the list load.
- **Status caption** (`CronJob`, pure, outside any UIKit guard):
  ```swift
  public enum StatusCaptionKind: Equatable, Sendable { case inactive, next, overdue, schedule, none }
  public func statusCaption(now: Date) -> (text: String, kind: StatusCaptionKind)
  public static let overdueGrace: TimeInterval = 15 * 60
  ```
  - `paused` / `error` / `completed` / `disabled` → `("Paused" | "Error" | "Completed" | "Disabled", .inactive)`
  - otherwise, with `nextRunAt`:
    - `now - next > overdueGrace` → `("Overdue · \(relativeRunLabel)", .overdue)`
    - else → `("Next \(relativeRunLabel)", .next)`. This keeps today's "Next in 1 hr." and
      "Next 5 min. ago" within the grace window.
  - else `scheduleDisplay` → `(schedule, .schedule)`; else `("", .none)`
- **View:**
  - the job row shows the caption from `statusCaption`, and the `.overdue` kind is tinted orange.
  - the trailing unread dot on the job row is removed.
  - the expanded job shows `ProgressView` / "Couldn't load runs" / "No runs yet", or one timestamp
    row per run. Session runs are a `Button` (unread dot when `unreadSessionIDs` contains the id,
    tap only: no swipe or context menu, as on the desktop); `cron_output` runs are plain secondary
    text.
  - the timestamp format is a fixed-locale "MMM d, HH:mm" helper, deterministic for snapshots.
  - the context menu gets a `Divider` and `Button("Delete", systemImage: "trash", role: .destructive)`.
  - the tab badge and its "N unread cron run(s)" accessibility text are removed.
  - the accessibility label includes the caption text.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests and docs in this repo.
- **Post-Completion** (no checkboxes): device check against a real agent with `local-*` runs.

## Implementation Steps

### Task 1: Add `cronJobRuns` and `deleteCronJob` to the REST client

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesRESTClient.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HermesRESTClientTests.swift`

- [x] add `cronJobRuns(connection, id, profile, limit) -> [Session]` to the client struct (doc
      comment: upstream `/runs`, session rows + `cron_output` rows) and its live implementation
      (`GET /api/cron/jobs/{id}/runs`, `limit` + optional `profile` query)
- [x] add a private `CronRunsResponse` that decodes `runs` per element through `SessionListDTO`,
      dropping rows that fail, with a missing `runs` key → `[]`
- [x] make `cronJobAction` method-aware and add `deleteCronJob(connection, id, profile)` →
      `DELETE /api/cron/jobs/{id}` (no body)
- [x] write tests: the `/runs` URL, method and query (with and without profile, limit); decoding of
      session rows plus a `cron_output` row; a row without `id` is skipped; an empty or missing
      `runs` key
- [x] write tests: the `deleteCronJob` URL, method and profile query; 404 → `RESTError.notFound`;
      400 `detail` surfaced; trigger/pause/resume still POST to their paths (regression)
- [x] run tests - must pass before next task

### Task 2: Add `CronJob.statusCaption(now:)`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/CronJob.swift`
- Modify: `HermesKit/Tests/HermesKitTests/CronJobTests.swift`

- [x] add `StatusCaptionKind`, `overdueGrace` and `statusCaption(now:)` per Technical Details, next to
      `relativeRunLabel`, with a doc comment citing desktop `job-state.ts` / `nextRunOverdueMs`
- [x] write tests: each inactive state → its word (Paused / Error / Completed / Disabled), including
      `enabled == false` without `state` → Disabled
- [x] write tests: active with future next → "Next in …"; past within the grace → "Next … ago";
      just past the grace → "Overdue · … ago"; no next → schedule; neither → `.none`;
      `running` / `enabled` / an unknown state count as active
- [x] run tests - must pass before next task

### Task 3: Load the expanded job's runs from `/runs`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListCronTests.swift`

- [x] add `expandedCronRuns` / `expandedCronRunsFailed` state, `CancelID.cronRuns`, and the
      `cronRunsResponse(jobID:_:)` / `cronRunTapped(id:)` actions
- [x] `cronJobTapped`: expand → clear the slot and fetch (`limit = cronPeekLimit`, `scopedProfileName`);
      collapse/switch → clear the slot and cancel; drop stale responses for another job; a first
      failure sets the failed flag; a refresh failure keeps the runs
- [x] merge the expanded-runs fetch into `load` (poll and pull-to-refresh) and into the trigger
      success path; clear the slot at every existing `expandedCronJobID = nil` site
- [x] `cronRunTapped`: `isCron` only → `markLocallyRead` + `.delegate(.openSession(run))`; a
      `cron_output` or unknown id → no-op
- [x] write tests: expanding fetches with the profile and shows the runs; collapsing and switching
      cancel and clear; a stale response is ignored; first-load failure vs refresh failure
- [x] write tests: a poll tick refetches only while a job is expanded; Run now success refetches the
      runs; a profile switch and the 404 flip clear the slot; `cronRunTapped` opens a session run and
      ignores a `cron_output` row
- [x] run tests - must pass before next task

### Task 4: Remove id-based grouping, unmatched runs and the cron unread count

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/CronJob.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListCronTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/CronJobTests.swift`
- Modify: `HermesMobile/Sources/Features/SessionListView.swift` (compile only: switch to
  `sortedCronJobs`, drop the badge reference; the visual rework is Task 6)

- [x] delete `CronJobGroup`, `unmatchedCronSessions` and `cronUnreadCount`; replace `cronJobGroups`
      with `sortedCronJobs: [CronJob]` (`cronJobsSupported` gate, `cronJobOrder` sort); update
      `hasCronContent`
- [x] delete `CronJob.jobID(fromSessionID:)` and its tests; grep the whole repo (including
      `HermesWidgets`, `DemoMode`, the snapshot tests) to confirm no remaining callers
- [x] update the view's references so the app target compiles
- [x] update tests: replace the grouping, unmatched and unread-count tests with `sortedCronJobs`
      ordering + `hasCronContent` (jobs-only, runs-only, neither, jobs present but unsupported)
- [x] run tests - must pass before next task

### Task 5: Add delete-job to the reducer

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/SessionListFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/SessionListCronTests.swift`

- [x] add `Dialog.confirmDeleteCronJob(id:)`, the `deleteCronJobTapped(id:)` action that presents
      `ConfirmationDialogState` (title "Delete “<job title>”?", the message from Overview #3,
      destructive Delete + Cancel), and its confirm handling
- [x] replace `cronJobActionFinished`'s `refetchSessions: Bool` with a kind enum; route delete
      through `performCronAction` (in-flight guard)
- [x] delete success or `.notFound` → remove the job, collapse and clear the slot if it was
      expanded, jobs-only refetch; other errors → `loadError`, no mutation
- [x] write tests: tap → dialog; cancel → nothing sent; confirm → DELETE with the profile; a double
      confirm is guarded; success removes the job, collapses it and refetches
- [x] write tests: 404 treated as success; 400 → banner and the job kept; deleting the last job
      (no cron runs) → `hasCronContent` false and `effectiveTab == .sessions`; trigger and
      pause/resume behaviour unchanged after the kind refactor
- [x] run tests - must pass before next task

### Task 6: Rework the Cron Jobs tab view

**Files:**
- Modify: `HermesMobile/Sources/Features/SessionListView.swift`
- Modify: `HermesMobile/Sources/DemoMode.swift`

- [x] `cronTabContent`: with jobs → `sortedCronJobs` rows; the expanded job renders
      spinner / "Couldn't load runs" / "No runs yet" / run rows (indented as today); without the jobs
      API the flat `cronSessions` fallback is unchanged
- [x] `cronJobRow`: the caption comes from `statusCaption(now: store.now)` (`.overdue` tinted orange);
      remove the trailing unread dot; the accessibility label includes the caption text
- [x] add a timestamp-only run row: session runs are a `Button` → `.cronRunTapped` with an unread dot;
      `cron_output` runs are plain secondary text; fixed-format timestamp helper
- [x] context menu: Divider + destructive Delete → `.deleteCronJobTapped`; remove the tab badge and
      its unread accessibility strings
- [x] `DemoMode`: seed `rest.cronJobRuns` from the seeded runs (by job id), make one seeded job
      paused, and drop the reliance on `cron_{job}_…` grouping
- [x] build the app (`tuist generate` if needed, then an `xcodebuild` build) to confirm it compiles
- [x] run tests - must pass before next task
- ➕ restored the user-approved delete-dialog message ("The job and its schedule are removed from
      the agent. Its past runs are kept on the server but won't be listed here."); Task 5 had
      invented one

### Task 7: Update and add the cron snapshot tests

**Files:**
- Modify: `HermesMobileTests/SessionSnapshotTests.swift`
- Modify: `HermesMobileTests/__Snapshots__/SessionSnapshotTests/*` (re-recorded cron baselines only)

- [x] update the existing Cron Jobs tab snapshot fixtures to the new state (`expandedCronRuns`
      instead of id-grouped runs; no badge)
- [x] add snapshots (`deviceImage()`): job rows covering active / paused / error / overdue; an
      expanded job with session runs and one `cron_output` row; an expanded job still loading
- [x] re-record only the affected cron baselines (delete the specific reference images and run
      `make snapshot` twice, NOT `make snapshot-record`)
- [x] run `make snapshot` - must be fully clean before next task

### Task 8: Verify acceptance criteria
- [x] verify: with `local-*` run ids, an expanded job shows its runs (from `/runs`) and no flat
      unmatched list appears (`cronJobTapped` → `fetchExpandedCronRuns`; tests
      `expandingFetchesTheJobsRunsScopedToTheProfile`, `sortedCronJobsListsJobsOnlyNotRuns`,
      `cronJobRunsDecodesSessionAndScriptRows`; snapshot `testSessionList_cronJobs_expandedRuns`;
      `unmatchedCronSessions` / `CronJobGroup` / `jobID(fromSessionID:)` have no references left)
- [x] verify: paused jobs read "Paused", overdue jobs read "Overdue · …", active ones read "Next in …"
      (`CronJob.statusCaption(now:)`, used by `cronJobRow`; tests `statusCaptionNamesInactiveStates`,
      `statusCaptionFlagsOverdueJustPastGrace`, `statusCaptionShowsUpcomingNextRun`; snapshot
      `testSessionList_cronJobs_statuses` shows all three, overdue tinted orange)
- [x] verify: Delete asks for confirmation, removes the job, and leaves the tab cleanly when it was
      the last job (`deleteCronJobTapped` → `Dialog.confirmDeleteCronJob` via `.bottomActionSheet`;
      tests `deleteTapPresentsTheConfirmationAndCancelSendsNothing`,
      `confirmDeletesWithTheProfileRemovesTheJobCollapsesAndRefetches`, `aDelete404IsTreatedAsAlreadyGone`,
      `deletingTheLastJobWithNoRunsLeavesTheCronTab`)
- [x] verify: an agent without the jobs API (404) still shows the flat run list (`cronJobsResponse`
      `.notFound` → `cronJobsSupported = false`, `sortedCronJobs` empty → view's `cronSessions`
      fallback; tests `notFoundDisablesCronJobsAndSkipsLaterFetches`,
      `sortedCronJobsEmptyWhenUnsupportedOrNoJobs`, `theJobsAPI404ClearsTheExpandedJobAndItsRuns`;
      snapshot `testSessionList_cronJobs_fallbackFlat`)
- [x] run full test suite: `make test` (2696 tests in 107 suites passed, 2 known issues)
- [x] run snapshot suite: `make snapshot` (365/365, 0 failures)

### Task 9: [Final] Update documentation
- [x] rewrite the "Cron sessions & the Cron Jobs tab (#24)" section of `docs/features/session-list.md`
      to the desktop-parity model: job rows only, runs from `/runs` while expanded, the poll and
      Run now refresh, timestamp-only rows, `cron_output` rows, status captions + overdue grace,
      delete flow + 404-as-success, no cron unread tracking, why id-grouping was dropped
      (upstream `e2042c84` `local-*` ids)
- [x] update the `CLAUDE.md` "Date sections, inbox cards, cron jobs…" bullet (remove the
      id-grouping and tab-badge mentions; keep it within the existing line budget)
- [x] update `README.md` if it mentions cron grouping or the badge
- [x] move this plan to `docs/plans/completed/` (done by the orchestrator at completion)

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- on a device against Eugene's agent (`family-nutrition` profile, jobs with `local-*` runs):
  - expand each nutrition job; its recent runs appear and open the right chat
  - the paused jobs read "Paused"
  - Run now adds a run to the open job's list on the next refresh
  - delete a throwaway job (create one from the desktop or CLI first)
- check VoiceOver on a job row (the state word is announced) and on a run row.

**Known trade-offs (accepted in the brainstorm):**
- runs of deleted jobs are no longer visible in the app (they stay on the server)
- cron runs carry no unread badge
- run rows lose their swipe and context-menu actions (tap-only, as on the desktop); individual run
  sessions can still be managed from the desktop
