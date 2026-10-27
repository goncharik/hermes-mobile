# Message action bar & branching (#34)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Transcript & chat UI"; this doc is the full contract — **read it before touching
`canBranch`, `branchSeed`, or the branch recovery paths**. Session-list branch *nesting* is in
`docs/features/session-list.md`. Design history: `docs/plans/completed/`.

## Action bar & copy

Completed assistant messages get a `MessageActionBar`: **copy** reuses `.copyRow` with checkmark
feedback via the shared `copyWithFeedback`/`rowCopyToken` mechanism (row-scoped token, 1.5s clock
expiry, `cancelInFlight`). The third **Read aloud** button (#74) is specified in
`docs/features/read-aloud.md` → "UI".

## Branch creation

**Branch** is desktop parity — no branch RPC exists, so `.branchFromMessage` fires a one-shot
`session.create` seeded with ONLY the selected assistant message (`messages`) +
`parent_session_id` (**no `title`** — server auto-titles on first submit), gated by `canBranch`
(**requires `storedSessionID` AND `attachLiveSessionID == nil` AND `branchSeed == nil`** — a
live-only handle, or an unpersisted branch's row-less `session_key`, would stamp a parent link no
list row ever matches; a standing `branchSeed` covers the window where an interrupted replay has
already nilled `attachLiveSessionID` but `storedSessionID` still points at the OLD dead session;
turn not running; `isBranching` double-fire; **AND `status == .ready`** — a `.gatewayClosed`
finalizes a mid-stream row as `isComplete` and clears `isSending` the instant the socket drops, so
without the connected-status gate a truncated reply would look branchable while `.reconnecting`
and the RPC would just fail against the dead socket).

**`canSend` also requires `!isBranching`** — a branch `session.create` in flight must block a NEW
parent turn, since `AppFeature` tears down this whole slot on `branchCreated` and a just-submitted
turn would be silently lost (cancelled effects, no server response ever observed).

## The primed slot

**A fresh branch has NO DB row until its first prompt** (server-lazy), so `Delegate.branchCreated`
carries the `SessionHandle` **plus the `BranchSeed`** (text + parent id) and `AppFeature` fills
the slot with a chat PRIMED from the create response (`resumeStoredID` + `attachLiveSessionID` +
`branchSeed`) + a list refetch — **never** the resume-by-stored-id `openSession` flow
(`session.resume` 4007s row-less ids and the self-heal would strand the user in an unrelated
empty session). The primed chat hydrates via **`session.activate` by LIVE id** (re-binds the new
socket's transport, returns the seeded history) until the first `message.start` clears
`attachLiveSessionID`/`branchSeed`.

## Reap recovery: probe before seed replay

**The server reaps a detached never-prompted branch after ~20s** (`_WS_ORPHAN_REAP_GRACE_S`) — a
"session not found" (hydrate OR the submit heal) **replays the SEEDED create from the client-held
`branchSeed`** (one replay per hydrate via `hasReplayedBranchSeed`; the heal keeps
attach-by-live-id mode), rebuilding context + nesting.

**Before ever replaying the seed, a hydrate not-found from `session.activate` probes
`session.resume`, by the branch's PERSISTED `storedSessionID`**: the server persists the branch's
DB row in `prompt.submit` (`_ensure_session_db_row`/`_persist_branch_seed`) **before**
`message.start` reaches the client, under the row's primary key `session_key` (`session.create`'s
`stored_session_id`, i.e. mobile's `storedSessionID`) — a **DIFFERENT** value from the live
runtime `session_id` (`attachLiveSessionID`) `session.activate` just 404'd on (probing with the
live id always 404s even when the row exists, fully defeating the probe — fixed by probing with
`storedSessionID`). A socket drop/server restart landing in that window would otherwise land
straight in the seed-replay path and DISCARD a real, already-persisted turn. `session.activate`
is live-only (no DB fallback) and 404s regardless of a persisted row; `session.resume` DOES fall
back to the DB by `session_key`. A probe success is treated exactly like `message.start` (clears
`attachLiveSessionID`/`branchSeed`, hydrates wholesale via the normal path).

**STRUCTURAL INVARIANT (2026-07-24 review — replaced a one-shot spend/refund
`hasProbedBranchResume` flag that leaked its "spent" bit both on effect cancellation and on
non-not-found probe failures, either of which let a LATER not-found skip the probe entirely and
replay the bare seed over possibly-persisted history): there is no probe budget to spend or
refund.** The probe is read-only and safe to re-issue on EVERY not-found as long as this hydrate
hasn't already replayed the seed (`!hasReplayedBranchSeed` alone gates it). ONLY a genuine
not-found returned **by the probe itself** is positive evidence the row is absent and falls
through to the seed-replay branch; a probe **cancelled** by a superseding
`.foreground`/`.reattached`/`.teardownSocketOnly` (all share `CancelID.hydrate`; TCA drops a
cancelled task's trailing `send`, so no result ever lands for that attempt), a **transient**
failure (`.disconnected`/`.notConnected`/`.timedOut`, self-redialing on timeout), or **any other
non-not-found server error** (session cap, internal error, malformed payload — none of which
prove absence) all simply re-arm status-only, so the next `.ready`/`.foreground`/`.reattached`
retries the probe from scratch — never assuming absence without the probe's own affirmative
verdict.

The companion half of the fix is in `canSend`: **the stale `liveSessionID` a hydrate just 404'd
on is nilled the INSTANT the probe decision is made** — before the probe's result is even
awaited — so a prompt submitted mid-recovery can't race the reducer's own recovery with its own
independent self-heal `session.create` (`withSessionHeal`), which would otherwise birth two live
sessions from one seed with the typed message landing in the untracked one.

## Recovery keys on the durable seed

**Recovery keys on the DURABLE `branchSeed`, never the transient `attachLiveSessionID`** (the
replay trigger consumes the attach redirect before its create resolves, so an interrupted replay
must still recover on the next hydrate/`.ready`); a **transport-interrupted replay
(`.disconnected`/`.notConnected`/`.timedOut`) KEEPS the seed + refunds the budget** (status-only,
mirroring `.sessionResult(.failure(.disconnected))`; timeout redials itself — half-open socket),
never firing a create into a dead socket. Only a genuine server rejection (or `-32601`, or a
spent budget) degrades to a fresh create **with an honest "Couldn’t restore the branch" banner —
never silently** (the cached paint still shows the seed), always **clearing the seed** so it
can't dangle on the plain session and mis-arm attach mode via `liveSessionIDRefreshed`.

Old agents silently ignore the seed params (no `-32601` on create) → plain empty chat; no
capability gate. No optimistic list row — an abandoned branch never appears.
