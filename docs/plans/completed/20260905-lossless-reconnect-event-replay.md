# Lossless reconnect: event `seq` watermark and `session.events.since` replay (#98)

## Overview

Track the server's per-session event sequence number on every frame. After a socket drop,
replay the events the phone missed through the same fold as live events, before the
ordinary `session.resume` hydrate runs.

- **Problem.** A socket drop mid-turn loses every event emitted while the phone was
  disconnected. The reducer reconnects with backoff and re-hydrates via `session.resume`,
  which rebuilds the transcript from history plus `inflight`. `inflight` carries only the
  user prompt and the assistant text so far, never reasoning or tool rows (#26 keeps the
  client's own live rows for exactly that reason). Tool calls, thinking and status updates
  that fired during the gap are gone until the turn ends.
- **Benefit.** After a reconnect into a **still-running** turn, the tool rows and the
  thinking/status row from the gap are present (the running hydrate keeps them under #26).
  Nothing else changes for the user:
  - A completed turn is rebuilt wholesale from history, as today.
  - v7 prompts never ride the ring. The `open_requests` reconcile in the hydrate already
    restores them (#97), so replay adds nothing for prompts.
  - Status rows (`review.summary`, a replayed "Timed out") are wiped by the hydrate that
    follows (accepted, #47).
  - Behaviour on an agent older than v2026.8.27, or on a session-authority host, is
    byte-identical to today.
- **Integration.** The connect stream carries a small `GatewayFrame` envelope (event +
  `session_id` + `seq` + the ready frame's `replay_epoch` / `session_authority`). The reducer
  keeps the watermark per live slot in memory and decides whether to replay. The gateway
  client stays a dumb pipe (reconnect/backoff/replay policy lives in the reducer, per
  `CLAUDE.md`). Replay runs on the reducer's `.ready`, which `GatewayConnection` releases only
  after the `client.capabilities` advertisement settles (5 s cap, #97), and **before**
  `hydrate`. The existing `applyActivate` rules (server wins, #26 row preservation,
  `inflight` re-seed, `open_requests` reconcile) stay untouched and remain the authority.

Split out of #96 with #97 (request-bound prompts, merged as PR #120) and #99 (native Projects).

**Server floor.** Replay needs v2026.8.27, the first tag with the ring (`87631bd8ae`,
2026-08-25). Every later tag has it, including the current `v0.21.x` / `v0.22.x` scheme (latest
`v0.22.5`, 2026-10-22). The app never gates on a version string: a frame without `seq` never
starts a cursor, and a `-32601` latches replay off. The combination this plan is built against
(v7 prompts + ring) starts at v2026.9.14. Since then the `events.since` reply also carries
`open_requests`.

## Context (from discovery)

Verified against upstream Hermes `main` `d778246c84` (2026-10-25) via `git show upstream/main:<path>`
in the sibling clone `/Users/eugene/Documents/Development/Personal/hermes-agent` (the checked-out
tree is stale). The replay files (`event_replay.py`, `server_requests.py`, `methods_session.py`,
`contracts/sessions.py`, `apps/shared/src/json-rpc-{gateway,channel}.ts`) are byte-identical to
release `v0.22.5`. `ws.py` differs only in unrelated lines.

**Release timeline (replay-relevant).**

| Releases | Ring |
|---|---|
| ≤ v2026.8.19 | none: `events.since` → `-32601`, frames carry no `seq` |
| v2026.8.27 – v2026.9.7 | 512 events/session, 64 sessions. A FIFO-evicted session restarted at seq 1 in the same epoch (fixed in #100122). Legacy `*.request` prompt events are in the ring. |
| v2026.9.11 | adds byte caps and the eviction/oversize truncation watermark. Legacy prompts still in the ring. |
| v2026.9.14+ | v7 prompts (server→client requests, not in the ring). `events.since` adds `open_requests`. |
| v0.22.3+ | `forget_session` frees a torn-down session's ring (raises its truncation watermark). Optional session-authority hosts (`gateway.ready.session_authority: true`). |

**Server wire** (`tui_gateway/`):
- **Stamping** (`event_replay.py:72-122`, called first thing in `server.py:697-704`
  `write_json`). Only `{"method":"event"}` frames are stamped (`:74`), and only with a
  non-empty `params.session_id` (`:79-82`; session-less globals such as `skin.changed` /
  `sessions.changed` / `gateway.ready` carry no `seq`). Each stamped frame gets a per-session
  `params.seq`, monotonic from 1 and in-process. Caps: **512 events and 4 MiB per session,
  64 sessions, 64 MiB per process** (`:30-36`). Eviction or an oversize frame raises a
  truncation watermark (`:102-112`) instead of leaving a silent hole.
- **Server→client requests are NOT stamped.** A v7 prompt frame is `{"jsonrpc","id":"srq-…",
  "method":"approval"|…}` (`server_requests.py:89-91`), so `method != "event"` and
  `_stamp_event` returns at `:74`. It is routed to the session's transport by `write_json`
  (`server.py:706-713`). The upstream design says so: "the notification replay ring never has to
  carry 'a question still waiting for an answer'" (`server_requests.py:15-18`).
- **`request.cancel` IS stamped.** `_emit_cancel` → `_emit("request.cancel", sid, {id, method,
  reason})` (`server_requests.py:164-165`) → `write_json` (`server.py:723-727`). So a cancel is
  a normal ring event with a `seq` and is replayable.
- **Detached sessions.** On WS disconnect the session's transport becomes `_DropTransport`
  (`server.py:218-234`, `ws.py:640-647`). Frames are still stamped into the ring and then
  dropped. A running turn with fresh activity is never reaped (`session_lifecycle.py:1021-1036`).
  An idle one is reaped after `ws_orphan_reap_grace_s` (default 20 s, `server.py:139-146`), and
  on v0.22.3+ its ring is freed (`session_lifecycle.py:665-668`).
- **Attachment.** Only a reattaching RPC (`session.resume` / `session.activate` / `prompt.submit`)
  rebinds the session to the new socket (`session_lifecycle.py:914-932`).
  `client.capabilities` only records the transport's advertisement (`methods_voice.py:521-539`),
  and `session.events.since` only reads the ring. Until the resume, no session frame (event or
  request) can reach the new socket.
- **Open requests on reconnect.** `session.resume` / `session.activate` carry `open_requests`
  when non-empty (`session_registry.py:824-829`). `session.events.since` always carries them
  (`methods_session.py:2320-2323`). With no client attached, a request is still raised and waits
  in `open_requests` for the reconnect (`session_transports.py:59-68`). The server never re-sends
  request frames on its own.
- **`gateway.ready`** (`ws.py:553-559`): `{skin, change_events: true, heartbeat: true,
  replay_epoch, session_authority?: true}`. `replay_epoch` is a per-process uuid, so a restart
  changes it and resets every counter. `session_authority` appears only when the socket is
  served by a canonical session authority (v0.22.3+, a gateway runner mounting the dashboard).
- **`session.events.since {session_id, last_seen: Int}`** (`methods_session.py:2308-2323`) →
  `{events, latest_seq, truncated, count, epoch, open_requests}`. Each element is the frame's
  `params` dict, `{type, session_id, seq, payload}`.
  - `truncated` is `last_seen < evicted_through` (`event_replay.py:163-167`).
  - Params are `SessionParams` + `last_seen` + an ignored `replay_epoch`
    (`contracts/sessions.py:724-742`, `contracts/common.py:234-238`: `session_id`,
    `profile?`). An unknown key → `4000` (`extra="forbid"`, `rpc_dispatch.py:25-29`).
  - A pre-ring agent → `-32601` (`rpc_dispatch.py:20-22`).
  - Wire change since `63279301bc`: only the added `open_requests` key and the tighter
    truncation rule. The request shape the app sends is unchanged.
- **Canonical session authority** (`gateway/session_events.py:77-89`). On such a host the
  same method takes a per-session `replay_epoch`, numbers frames per session, and answers
  `snapshot_required` / `truncated: true` with no events when the epoch is missing. The app's
  request (no `replay_epoch`) would always fall back. ⚠️ The app's overall compatibility with
  session-authority hosts (canonical prompts, `approval.settled`) is unverified and out of
  scope here.
- **Desktop** (`apps/shared/src/json-rpc-gateway.ts`, `json-rpc-channel.ts`):
  - Watermarks: a per-session `lastSeenSeq` map, at most 256 cursors (`:132`). `recordSeq`
    ignores non-increasing and seq-less frames (`:480-493`).
  - Ordering: `fetchReplay` fires at socket **open**, before `gateway.ready` and before the
    capability advertisement (`:279-291`). The advertisement is sent on `gateway.ready` and
    never awaited (`json-rpc-channel.ts:513-516,532-542`). History reads (resume) wait on a
    per-session replay barrier (`:527-541`).
  - The fetch: one RPC per known session with a 10 s budget (`:54`, `:579-657`). Live seq'd
    frames are parked while it is in flight (`:462-468`) and dispatched only when newer
    (`:715-733`).
  - Epochs: a changed epoch on ready or on the reply clears the watermarks (`:687-691`,
    `:740-772`).
  - `truncated` advances the cursor to `latest_seq` without dispatching (`:616-627`,
    `:700-709`). Every failure is swallowed (`:643-651`).
  - Prompts: `open_requests` on the reply are re-delivered to the request handlers before the
    caller sees the result (`json-rpc-channel.ts:499-506`). Replayed events go through the
    normal handlers. A replayed `request.cancel` for an unknown id is a no-op
    (`apps/desktop/.../gateway-event/input-requests.ts:160-174`).

**App today** (HermesKit, `main` at `2b9f39c`):
- `Models/JSONRPC.swift:136-180`: `InboundFrame.event(sessionID: String?, GatewayEvent)`
  (`:138`, built at `:152-156`) reads `params.session_id`, which `GatewayConnection` then
  discards. `seq` is never read. `.serverRequest(id:method:params:)` (`:141`) carries v7
  prompts.
- `Models/GatewayEvent.swift`: `case "gateway.ready": .ready` drops the payload (`:56`).
  `request.cancel` → `.requestCancel(RequestCancel)` (`:106`). Client-synthesized cases:
  `.serverRequest`, `.serverRequestFailed`, `.serverRequestsUnavailable`, `.authExpired`.
- `Clients/HermesGatewayClient.swift`:
  - `connect` returns `AsyncStream<GatewayEvent>` (`:25`, live `:198-268`).
  - `GatewayConnection` (`:300-572`). `handle(frame:)` (`:537-556`) yields bare events. It holds
    `gateway.ready` in `receivedReady` / `openReadyGate` (`:508-529`) until the one
    `client.capabilities` attempt settles or `advertisementReadyCap` (5 s) fires; other frames
    are yielded meanwhile.
  - `handleServerRequest` (`:437-449`) yields `.serverRequest(PendingServerRequest)`.
- `Clients/DebugLogClient.swift:11`: `append(GatewayEvent)` only. There is no free-text
  `note` entry point (the plan's earlier `debugLog.note` did not exist).
- `Features/ChatFeature.swift`:
  - Socket effect: `connect(_:)` (`:3003-3014`) forwards each event as `.gatewayEvent` and
    mirrors it into `debugLog`. `.gatewayEvent` (`:1127-1140`) snapshots the window, calls
    `reduce(event:into:)`, and persists.
  - `.gatewayClosed` (`:1142-1160`) runs `finalizeInFlight` (`:2882-2890`: completes the
    streaming row, freezes the thinking row and nils `thinkingRowID`, sets
    `isSending = false`; `toolRowIDs` survive) and schedules the backoff redial.
  - `reduce(event: .ready)` (`:2289-2324`) sets `.ready`, then (guarded by
    `hasRequestedSession`) branches to `attachLive` / `hydrate(sessionID:profile:
    state.profileName)` / branch-seed replay / `createSession`. `hydrate` (`:3090-3114`) is
    `CancelID.hydrate`, `cancelInFlight`.
  - `CancelID` is at `:1026`. `.teardown` (`:1087`) cancels socket/reconnect/hydrate.
    `.teardownSocketOnly` (`:1097`) keeps the state in memory (no finalize) for the foreground
    catch-up. `.foreground` / `.reattached` (`:1299`) redial only when `status != .ready`.
  - v7 queue: `.serverRequest` (`:2504-2518`). `.requestCancel` (`:2520-2528`): an unknown id
    is a no-op; a match is removed (a `timeout` on the presented card appends "Timed out") and
    the next head is presented; then `drainQueueIfReady`.
  - Turn end: `message.complete` / `.error` → `clearStalePrompts` (`:2619`, clears the whole
    queue).
  - `applyActivate` (`:3164`): v7 `reconcileServerRequests` (`:3198-3205`, `:2649-2677`;
    absence authoritative whatever `running` says). #26 keeps only `toolRowIDs` rows and the
    `thinkingRowID` row (`:3240-3298`); status rows are wiped. It drains the queue at the end
    (`:3335`).
  - `drainQueueIfReady` (`:3852-3882`) needs `!isSending`, `pendingInteraction == nil`,
    `status == .ready`.
- `HermesMobile/Sources/DemoMode.swift:58` stubs `hermesGateway.connect` with a never-yielding
  stream (element type inferred, so it compiles unchanged).
- Tests to touch (grep `HermesKit/Tests/HermesKitTests/`, counts as of `2b9f39c`):
  - **7** `yield(.ready)` connect stubs: `AppFeatureTests` 1, `ChatReductionTests` 3,
    `HydrateTests` 3.
  - **8** `receive(\.gatewayEvent)` after a real/stubbed connect: `ChatReductionTests` 3,
    `HydrateTests` 2, `ServerRequestTests` 3.
  - **4** `AsyncStream<GatewayEvent>` stream sites: `ServerRequestTests:486,541`,
    `ChatBranchTests:908,922`.
  - **35** `InboundFrame.event(…)` patterns: `GatewayEventDecodingTests` 34 (through its
    private `frame(_:)` helper), `ChatInteractionTests:784` 1.
  - The **175** `send(.gatewayEvent(...))` sites are unaffected because the action stays.
- Docs to update: `docs/architecture.md` (Wire protocol section; "Server→client requests"
  `:301`; "Session re-hydration" `:421`), `docs/features/approvals.md` ("Reconnect replay
  (v7)", one line), the `CLAUDE.md` gateway bullet, and the `README.md` "Stays connected"
  bullet (`:92-97`).

**Relationship to #97 (merged, PR #120).**
- *v7 prompts are not replayed.* Request frames never enter the ring (see Server wire). Their
  recovery is the hydrate's `open_requests` reconcile, which runs right after every replay and
  stays authoritative. The `open_requests` copy in the `events.since` reply is ignored on
  purpose: the hydrate carries the same list moments later. Feeding both would present a card
  twice (two tokens) for no gain.
- *A replayed `request.cancel` reaches `.requestCancel`.* For an unknown id (raised and
  withdrawn in the gap, or already answered) it is a no-op. For a queued non-head id the entry
  is removed silently. For the presented head the entry is removed and the next head presented
  (a `timeout` adds a "Timed out" row, which the hydrate then wipes).
  - The final state equals what the hydrate alone produces: absence in `open_requests` drops
    the same ids. A still-open next head is refreshed in place by `reconcileServerRequests` (no
    token bump).
  - The one hazard is its trailing `drainQueueIfReady`. After `finalizeInFlight`, `isSending`
    is false and `status` is already `.ready`, so a replayed cancel (or `message.complete`, or
    a Send-now-armed `.error`) would fire a queued prompt (#66) against a turn the server may
    still be running, before the hydrate says so. The fold therefore suppresses the drain (see
    Solution Overview 3). The hydrate's own idle edge (`:3335`) drains as today.
- *Legacy prompt events on ring agents (v2026.8.27 – v2026.9.11).* `approval.request` /
  `clarify.request` / `sudo.request` / `secret.request` (and their `*.expire`) are ordinary
  `_emit`ted events (`v2026.9.11:tui_gateway/server.py:694,1281,1293`), so they are in the
  ring. The app decodes no `*.expire`, so a replayed clarify/sudo/secret that already expired
  in the gap would stand forever (legacy non-approval cards are not cleared at turn end,
  `clearStalePrompts`). **Replay skips the four legacy prompt events**, consistent with #97's
  "legacy stays as today". Push-tap recovery (approvals) is unchanged.
- *Ordering against the advertisement.* `.ready` reaches the reducer only after
  `client.capabilities` settles (or the 5 s cap). Replay therefore runs strictly after the
  advertisement, strictly before `session.resume`. Replay does not need the advertisement:
  nothing it folds is a server request.

## Development Approach

- **testing approach**: Regular (code first, then tests), the user's preference for this plan.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions; "all" means the
  full `swift test --package-path HermesKit` run
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility: frames without `seq` (agent < v2026.8.27) never advance
  a watermark, so no replay RPC is ever sent to an older agent, and the reconnect path is
  byte-identical to today for them. Same for a `session_authority` host.
- commit per task, capitalized verb, no conventional-commit prefix

## Testing Strategy

- **unit tests** (HermesKit, `swift test`):
  - `JSONRPCTests` for the envelope decoding (`seq`, `session_id`, `replay_epoch`,
    `session_authority`, event objects from `events.since`).
  - `HermesGatewayClientTests` with `FakeTransport`: frames reach the stream intact, and the
    held ready frame keeps its epoch through the advertisement gate.
  - `TestStore` reduction tests:
    - the watermark: advance, ignore non-monotonic, ignore seq-less;
    - epoch adoption and reset;
    - the reconnect flow: replay-then-hydrate ordering, fold order, seq gate, every fallback;
    - #97 interplay: replayed `request.cancel` cases, no queue drain during the fold,
      skipped legacy prompts, ignored `open_requests`.
  - Event-reduction tests are the highest-value suite here: the replay path is entirely
    reducer logic.
- no UI change → no snapshot work. No e2e suite in this project.
- run with `script -q /dev/null swift test --package-path HermesKit` (or `make test`), since
  piped output buffers.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

1. **Envelope, not a new event.** `GatewayFrame { event, sessionID, seq, replayEpoch,
   sessionAuthority }` is what the connect stream yields. `GatewayEvent` is unchanged (`.ready`
   stays payload-less; the ready fields ride on the frame). `InboundFrame.event` carries it. A
   second initializer builds it from a bare event object (the `events.since` element shape),
   so replayed and live events decode through one path. Client-synthesized events
   (`.serverRequest`, `.serverRequestFailed`, `.serverRequestsUnavailable`, `.authExpired`) are
   wrapped with no envelope data. `GatewayConnection` keeps the held `gateway.ready` frame (not
   just a flag) so the `.ready` released by the advertisement gate still carries its epoch and
   authority flag.
2. **The reducer owns the cursor.** `ChatFeature.State` gains `replayCursor: ReplayCursor?`
   (`sessionID` + `seq`), `replayEpoch: String?`, `replaySupported: Bool` and
   `isFoldingReplay: Bool` (per slot, unpersisted, reset in `init`). A new
   `.gatewayFrame(GatewayFrame)` action is what the socket effect sends: it applies the ready
   rules, records the cursor, then reduces exactly as `.gatewayEvent` does (shared helper, one
   code path). `.gatewayEvent` remains for tests; the replay fold calls `reduceGatewayEvent`
   directly.
3. **Replay before hydrate, on the gated `.ready`.**
   - **When.** In `reduce(event: .ready)`, the slot replays when all of these hold:
     - it has a cursor for its live session and `replaySupported`;
     - the connection is not a session-authority one;
     - the branch is the ordinary stored-session resume (not `attachLive`, not a branch-seed
       replay, not `createSession`).
     It then returns a replay effect instead of `hydrate`.
   - **The effect.** It calls `session.events.since {session_id, last_seen}` (no `profile`, no
     `replay_epoch`; the legacy ring is process-global by live sid) and feeds `.replayResult`.
   - **The fold.** The reducer folds `batch.events` in order through the seq gate (only
     `seq > cursor.seq`, advancing the cursor per event) with `isFoldingReplay = true`, then
     returns `hydrate(...)`. During the fold:
     - legacy `approval.request` / `clarify.request` / `sudo.request` / `secret.request` are
       skipped;
     - `drainQueueIfReady` is a no-op, because the hydrate's `running` is the only trustworthy
       idle edge after a drop.
     `open_requests` on the reply is ignored (the hydrate reconciles).
   - **Fallbacks.** Each of these folds nothing and returns `hydrate(...)`:
     - `truncated`: the cursor advances to `latest_seq`, as desktop does;
     - epoch mismatch;
     - `-32601`: latches `replaySupported = false`;
     - any other failure, or a malformed result.
     The failure is recorded through `debugLog` only. This is a **deliberate carve-out** from
     the surface-every-RPC-failure rule (documented at the call site): the user-visible outcome
     is today's hydrate, and a banner would fire on every reconnect against an agent that lacks
     the ring.
4. **Why before, not after.** Before `session.resume` the new socket is not attached to the
   session. `client.capabilities` and `events.since` attach nothing, and the server routes
   both events and request frames by the session's transport, which is still the drop sink. So
   no live session frame can race the replay, and the desktop's park-and-flush buffer is
   unnecessary.

   Folding the gap first also composes with `applyActivate` as is:
   - a running hydrate keeps the tool rows and the thinking row the replay just built or
     extended (#26);
   - the streaming assistant row is re-seeded from `inflight.assistant` (server wins), so
     replayed `message.delta`s never double the text;
   - a completed turn is replaced wholesale by history.

   After a `.gatewayClosed` drop `finalizeInFlight` has already frozen the pre-drop thinking
   row. Replayed reasoning starts a fresh live thinking row; the frozen one is wiped by the
   hydrate, as today. After a `.teardownSocketOnly` (grace expiry) nothing was finalized, so
   replayed reasoning extends the live row.

   The one-RTT window between the replay read and the resume attach is accepted. Frames in it
   are stamped but dropped by the detached sink. Today the whole gap is lost, and the desktop
   has the same window.
5. **Epoch rules.** The epoch on a `.ready` frame is compared to the stored one. A change
   (gateway restart) clears the cursor before the branch above runs, so no replay is attempted
   against numbering that no longer exists, and the new epoch is adopted. An `events.since`
   reply whose `epoch` differs from the stored one is treated the same way (drop, adopt,
   hydrate). A frame or reply with no epoch (older agent) leaves the stored value untouched.
6. **Cursor lifetime.** In memory only, per slot. It survives `.gatewayClosed`, the backoff
   redial, `.teardownSocketOnly` (grace expiry, the exact case a replay pays for) and
   `.foreground` / `.reattached` re-hydrates. It dies with the slot on `.teardown`. It is never
   persisted (a cold launch always hydrates). A `session.resume` that returns a different live
   `session_id` (an idle session reaped in the gap gets a fresh runtime id) simply starts a
   fresh cursor on the first stamped frame.

Key decisions:
- **Reducer-owned over a client-side recorder.** A watermark hidden in the gateway client
  would need rules about which disconnects clear it, and would put reconnect knowledge in the
  client. The frame envelope costs ~55 mechanical test edits (counts in Context) and keeps
  every decision in `TestStore` reach.
- **`.gatewayEvent` action kept.** The 175 existing reduction sends use it (the replay fold
  calls `reduceGatewayEvent` directly); only the socket effect switches to `.gatewayFrame`.
- **No parking buffer** (see 4). If a later change attaches the socket before the replay,
  revisit.
- **Replay after the advertisement, not at socket open as desktop does.** The reducer only
  sees `.ready` after the gate, and replaying earlier would need a second pre-ready path. The
  cost is up to the advertisement RTT (worst case the 5 s cap) more of the gap in the
  dropped-frames window. Accepted.
- **No queue drain during the fold** (see Relationship to #97). Turn-ending events in a
  replay batch describe the past. The hydrate's `running` is the present.
- **Legacy prompt events skipped in replay** (see Relationship to #97): no `*.expire`
  handling means a stale card could stand forever on a three-release-old wire.
- **`open_requests` from `events.since` ignored.** The hydrate that always follows carries the
  same authoritative list.
- **Session-authority hosts never replay.** Their `events.since` needs a per-session epoch the
  app does not track, and would always answer `snapshot_required`. Skipping saves an RTT and
  keeps a session-local epoch out of `replayEpoch`.
- **`truncated` adopts `latest_seq`** (desktop parity), so the next drop does not re-ask for
  the same evicted window.
- **One RPC, the slot's own session only.** The phone has one live session per socket (#90
  is where multi-session replay would go).

## Technical Details

**As built** (normative: `docs/architecture.md` → "Event frames and the replay cursor" and
"Reconnect event replay"). The sketches below predate review; the shipped code differs:
- names: `.eventReplayResult`, `CancelID.eventReplay`, `replayEventGap(cursor:)`,
  `applyEventReplayResult` / `foldReplayedEvents`;
- the fold also suppresses `runningChanged` and per-event anchor writes (one write for the last
  boundary), skips `message.delta`s and materialises no `message.complete` row, never starts the
  thinking timer (the hydrate's `running` does), and keeps the push-tap approval hint;
- `isReplayReadPending` holds sends, drains, prompt answers and healthy-socket
  `.foreground` / `.reattached` during the read;
- a read timeout spends the hydrate's same-socket timeout retry;
- the WebSocket accepts messages up to the 16 MiB frame ceiling
  (`JSONRPCRequest.maxWebSocketFrameBytes`).

### Models (`JSONRPC.swift` / new `GatewayFrame.swift`)

```swift
/// One inbound event as delivered by the socket or replayed by `session.events.since`.
public struct GatewayFrame: Equatable, Sendable {
  public var event: GatewayEvent
  public var sessionID: String?
  /// Server per-session monotonic sequence (v2026.8.27+); nil on older agents, on
  /// session-less global events, and on client-synthesized events.
  public var seq: Int?
  /// `gateway.ready` only: the server process's replay epoch.
  public var replayEpoch: String?
  /// `gateway.ready` only: `session_authority: true` (canonical authority host, v0.22.3+).
  public var sessionAuthority: Bool

  public init(_ event: GatewayEvent, sessionID: String? = nil, seq: Int? = nil,
              replayEpoch: String? = nil, sessionAuthority: Bool = false)
  /// Decode a bare event object `{type, session_id, seq?, payload?}`: the shape shared by a
  /// frame's `params` and each `events.since` element. Missing/invalid `type` → nil.
  public init?(eventObject: JSONValue)
}

// InboundFrame
case event(GatewayFrame)     // was event(sessionID: String?, GatewayEvent)

public struct ReplayBatch: Equatable, Sendable, Decodable {
  public var events: [GatewayFrame]   // via GatewayFrame(eventObject:), undecodable elements dropped
  public var latestSeq: Int?          // "latest_seq"
  public var truncated: Bool          // default false
  public var epoch: String?
  // `open_requests`, `count` (and canonical extras) deliberately not decoded.
}
```

`seq` and `latest_seq` decode from a JSON number (`sequenceNumber`, `Int(exactly:)`); a
non-integer or negative value is treated as absent. `replay_epoch` and `session_authority` are
read from the `gateway.ready` payload only (any other frame's `replay_epoch`, as on a canonical
host, is ignored).

### Client (`HermesGatewayClient.swift`)

- `connect: (URL, AuthSession) -> AsyncStream<GatewayFrame>`. `GatewayConnection.handle` yields
  `frame` for `.event(frame)`. Synthesized yields (`.serverRequest`, `.serverRequestFailed`,
  `.serverRequestsUnavailable`, the cookie-mode `.authExpired`) become `GatewayFrame(event)`.
  `testValue` is unchanged in spirit (finishes immediately).
- The ready gate keeps the held frame: `readyHeld: Bool` becomes `heldReady: GatewayFrame?`.
  `openReadyGate` yields that frame. A `gateway.ready` arriving with the gate open is yielded
  as its own frame.
- No replay logic in the client.

### Reducer (`ChatFeature`)

State (per slot, unpersisted, reset in `init`):
```swift
public struct ReplayCursor: Equatable, Sendable { public var sessionID: String; public var seq: Int }
var replayCursor: ReplayCursor?
var replayEpoch: String?
var replaySupported: Bool = true
/// This connection's ready said `session_authority: true` (reset by every ready frame).
var isSessionAuthority: Bool = false
/// True only while `replayResult` folds a batch: suppresses `drainQueueIfReady`.
var isFoldingReplay: Bool = false
```

Actions:
- `gatewayFrame(GatewayFrame)`: sent by the socket effect (the `connect(_:)` loop; `debugLog`
  still receives `frame.event`).
- `replayResult(Result<ReplayBatch, GatewayError>)`.

`gatewayFrame` reduction:
```
if case .ready = frame.event {
  state.isSessionAuthority = frame.sessionAuthority
  if let epoch = frame.replayEpoch {
    if let known = state.replayEpoch, known != epoch { state.replayCursor = nil }
    state.replayEpoch = epoch
  }
}
advanceCursor(frame, into: &state)               // sid + seq present && seq > cursor.seq (or no cursor / other sid)
return reduceGatewayEvent(frame.event, into: &state)   // the existing `.gatewayEvent` body, extracted
```
`advanceCursor`: a frame for a different `sessionID` than the cursor's replaces the cursor
(the slot follows one session; a re-minted live id starts over). A seq-less frame is a no-op.

`reduce(event: .ready)` insertion point (`:2308`, inside `if let stored =
state.storedSessionID`, after the `attachLiveSessionID` branch):
```
if state.replaySupported, !state.isSessionAuthority,
   let cursor = state.replayCursor, cursor.sessionID == state.liveSessionID {
  state.hydrateRetriedAfterTimeout = false
  return replay(cursor: cursor)
}
```
`replay(cursor:)` effect (`CancelID.replay`, `cancelInFlight`): `session.events.since
{session_id: cursor.sessionID, last_seen: cursor.seq}` → `.replayResult`. It uses the default
30 s per-request budget (desktop uses 10 s). A read timeout spends the hydrate's same-socket
timeout retry, so a half-open socket redials after one more.

`replayResult` reduction:
```
guard state.status == .ready, let stored = state.storedSessionID else { return .none }  // dead socket: next .ready re-runs
var effects: [Effect<Action>] = []
switch result {
case .success(let batch):
  if let epoch = batch.epoch, let known = state.replayEpoch, epoch != known {
      state.replayCursor = nil; state.replayEpoch = epoch          // restart: skip
  } else if batch.truncated {
      // gap fell off the ring: the hydrate (history) is the only honest source
      if let latest = batch.latestSeq, let c = state.replayCursor, latest > c.seq { state.replayCursor?.seq = latest }
  } else {
      state.isFoldingReplay = true
      for frame in batch.events where frame.sessionID == cursor.sessionID && frame.seq > cursor.seq
                                      && !frame.event.isLegacyPrompt {
          advanceCursor(frame, into: &state)
          effects.append(reduceGatewayEvent(frame.event, into: &state))
      }
      state.isFoldingReplay = false
  }
case .failure(let error):
  if error.isUnknownMethod { state.replaySupported = false }
  if error.isTimedOut { state.hydrateRetriedAfterTimeout = true }
  // the effect already wrote debugLog.note (carve-out, see Solution Overview 3)
}
return .merge(effects + [hydrate(sessionID: stored, profile: state.profileName)])
```
- `drainQueueIfReady` gains `guard !state.isFoldingReplay`.
- `GatewayEvent.isLegacyPrompt` is true for `.approvalRequest` / `.clarifyRequest` /
  `.sudoRequest` / `.secretRequest`.
- `DebugLogClient` gains `note: (_ type: String, _ summary: String) -> Void`, backed by the
  existing `GatewayLogEntry(id:type:summary:)` (no-op `testValue`).

Guards on the fold:
- A replayed `.ready` / `.authExpired` / `.serverRequest*` never appears: the server never
  records them, and the client synthesizes the rest.
- A replayed `.unknown` (e.g. a legacy `clarify.expire`) is harmless.
- `persistRelevant` applies per folded event as today (debounced, one write).
- Replayed `.error` / `review.summary` / "Timed out" rows are overwritten by the hydrate's
  banner reset and wholesale rebuild (accepted).

Cancellation: `.teardown` and `.teardownSocketOnly` add `.cancel(id: CancelID.replay)`. A
`.gatewayClosed` during the replay RTT cancels it too. The next `.ready` re-runs it from the same
cursor, and the guard on `status == .ready` keeps a late result from hydrating over a
reconnecting socket.

### Wire examples (test fixtures)

```json
// live frame
{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"live1","seq":42,"payload":{"name":"terminal"}}}
// ready (a session-authority host adds "session_authority":true)
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"e1"}}}
// replayable request.cancel (v7; the srq request frame itself has no seq and is never replayed)
{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","session_id":"live1","seq":45,"payload":{"id":"srq-0123456789ab","method":"approval","reason":"timeout"}}}
// session.events.since reply (v2026.9.14+ adds open_requests, ignored by the app)
{"events":[{"type":"tool.start","session_id":"live1","seq":43,"payload":{"name":"terminal"}},{"type":"tool.complete","session_id":"live1","seq":44,"payload":{"name":"terminal","result_text":"ok"}}],"latest_seq":44,"truncated":false,"count":2,"epoch":"e1","open_requests":[]}
```

## Implementation Steps

### Task 1: `GatewayFrame` envelope and `InboundFrame` sequencing fields

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/GatewayFrame.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/JSONRPC.swift`
- Modify: `HermesKit/Tests/HermesKitTests/JSONRPCTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/GatewayEventDecodingTests.swift` (34 `.event(` patterns; adapt the private `frame(_:)` helper), `ChatInteractionTests.swift:784`

- [x] add `GatewayFrame` with the memberwise init and `init?(eventObject:)` (type required;
      `session_id` / `seq` / `payload` optional; `seq` only when a non-negative integer)
- [x] add `ReplayBatch` (lenient: `events` elements that fail `GatewayFrame(eventObject:)`
      are dropped; `truncated` defaults `false`; `open_requests` / unknown keys ignored)
      (a missing / non-array `events` throws: the one "malformed" verdict Task 4 maps to
      `.failure`)
- [x] change `InboundFrame.event` to carry a `GatewayFrame`; parse `replay_epoch` and
      `session_authority` from the `gateway.ready` payload onto the frame; `session_id` and
      `seq` from `params`
      (➕ `GatewayConnection.handle` gets a one-line compile fix yielding `frame.event`;
      Task 2 does the real client change)
- [x] add `GatewayEvent.isLegacyPrompt`
- [x] write decoding tests: live frame with `seq`; frame without `seq` (older agent) → nil;
      non-integer `seq` → nil; `gateway.ready` with/without `replay_epoch` and with
      `session_authority: true`; session-less global event; stamped `request.cancel` decodes to
      `.requestCancel` with its `seq`; `events.since` reply with two events + one malformed
      element dropped + `open_requests` present (ignored); `truncated` absent → false
- [x] update the 35 `InboundFrame.event` pattern sites
- [x] run tests - must pass before next task

### Task 2: Gateway client yields frames

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`connect(_:)` loop only, as a compile fix; it forwards `frame.event` for now)
- Modify: `HermesKit/Tests/HermesKitTests/HermesGatewayClientTests.swift`
- Modify: the 7 `yield(.ready)` connect stubs (`AppFeatureTests`, `ChatReductionTests`, `HydrateTests`) and the 4 `AsyncStream<GatewayEvent>` sites (`ServerRequestTests:486,541`, `ChatBranchTests:908,922`)

- [x] `connect` returns `AsyncStream<GatewayFrame>`; `GatewayConnection` takes an
      `AsyncStream<GatewayFrame>.Continuation`; `handle` yields the frame; every synthesized
      yield (`.serverRequest`, `.serverRequestFailed`, `.serverRequestsUnavailable`,
      `.authExpired`) wraps in `GatewayFrame(_:)`
- [x] the ready gate stores the held ready frame (`heldReady: GatewayFrame?`) and
      `openReadyGate` releases that frame, so the epoch / authority flag survive the
      advertisement wait
- [x] update `ChatFeature.connect(_:)` to iterate frames and send `.gatewayEvent(frame.event)`
      (temporary, Task 3 switches it to `.gatewayFrame`), `debugLog.append(frame.event)`
- [x] update the test stubs to yield `GatewayFrame(.ready)` etc.; `DemoMode.swift` compiles
      unchanged (verify with an app build)
      (➕ a `nextEvent()` iterator helper in `TestSupport.swift` keeps the ~45 event-level
      `iterator.next()` asserts in `HermesGatewayClientTests` / `ServerRequestTests` unchanged
      in meaning)
- [x] write client tests: a stamped event reaches the stream with `sessionID` + `seq`; a ready
      frame held by the advertisement gate is released carrying its `replay_epoch` (both on
      the acknowledgement and on the 5 s cap); a server-request frame still yields
      `.serverRequest` with nil `seq`; multiple newline-delimited frames keep their seqs
- [x] run tests - must pass before next task

### Task 3: Reducer cursor and epoch tracking (`.gatewayFrame`)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ReplayCursorTests.swift`
- Modify: the 8 `receive(\.gatewayEvent)` asserts that follow a stubbed or real connect (`ChatReductionTests` 3, `HydrateTests` 2, `ServerRequestTests` 3 → `\.gatewayFrame`)

- [x] add `ReplayCursor`, `replayCursor`, `replayEpoch`, `replaySupported`,
      `isSessionAuthority`, `isFoldingReplay` to `State` (init defaults; `Equatable` as the rest)
- [x] add `Action.gatewayFrame(GatewayFrame)`; extract the `.gatewayEvent` body (`:1127-1140`)
      into `reduceGatewayEvent(_:into:)`; `.gatewayEvent` and `.gatewayFrame` both call it;
      `.gatewayFrame` first applies the ready rules (epoch + authority) and `advanceCursor`
      (helpers: `applyReadyReplayRules`, `advanceReplayCursor`)
- [x] switch `connect(_:)` to send `.gatewayFrame(frame)`
- [x] write tests: seq 1,2,3 advances the cursor; seq 2 after 3 is ignored (event still
      reduces); seq-less frame leaves the cursor; a frame for another session id replaces
      the cursor; `.ready` with epoch "e1" adopts it; a later `.ready` with "e2" clears the
      cursor and adopts "e2"; `.ready` without an epoch keeps both; `.ready` with
      `session_authority` sets `isSessionAuthority` and a later plain ready clears it;
      `.gatewayFrame` reduces identically to `.gatewayEvent` for a `message.delta`
      (transcript + persist effect)
- [x] update the 8 affected asserts to `\.gatewayFrame`
      (➕ a 9th: `AppFeatureTests` `\.liveChat.gatewayEvent` after the regular-seat dial)
- [x] run tests - must pass before next task

### Task 4: Replay-then-hydrate on `.ready`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/DebugLogClient.swift` (`note`)
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`, `DebugLogClientTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/ReplayTests.swift`

- [x] add `CancelID.replay`, `Action.replayResult(Result<ReplayBatch, GatewayError>)`, the
      `replay(cursor:)` effect (`session.events.since {session_id, last_seen}`, nothing else;
      malformed result → `.failure(.server("Malformed session.events.since result"))`)
      (➕ the failure `debugLog.note` is written by this effect, before it sends `.replayResult`)
- [x] add `DebugLogClient.note(type:summary:)` (ring buffer + no-op `testValue`)
- [x] insert the replay branch in `reduce(event: .ready)` (stored-session path only, cursor
      must match `liveSessionID`, `replaySupported`, `!isSessionAuthority`)
- [x] implement `replayResult`: guard `status == .ready`; epoch mismatch → drop cursor, adopt;
      `truncated` → advance cursor to `latest_seq`, fold nothing; otherwise fold gated events in
      order via `reduceGatewayEvent` + `advanceCursor` under `isFoldingReplay`, skipping
      `isLegacyPrompt`, merging the fold's effects; `-32601` → `replaySupported = false`; any
      failure → `debugLog.note` with the call-site carve-out comment; always finish with
      `hydrate(sessionID: stored, profile: state.profileName)`
      (➕ the seq gate also requires the element's `session_id` to equal the cursor's)
- [x] `drainQueueIfReady` returns `.none` while `isFoldingReplay`
- [x] cancel `CancelID.replay` on `.teardown`, `.teardownSocketOnly`, and `.gatewayClosed`
- [x] write reduction tests (`TestStore`, `TestClock`, in-memory snapshot):
      (➕ all in `ReplayTests.swift`; `HydrateTests.swift` is untouched here, Task 5 extends it)
      - reconnect with cursor (live1, 41) sends `session.events.since {session_id: live1,
        last_seen: 41}` (exact params, no `profile`) BEFORE `session.resume` (record the RPC
        order)
      - reply with tool.start 42 / tool.complete 43 folds two tool rows, cursor → 43, then
        the running hydrate preserves them (#26) alongside the rebuilt history
      - replayed `thinking.delta` after a `.gatewayClosed` drop lands in a fresh live thinking
        row that the running hydrate keeps; after `.teardownSocketOnly` it extends the existing
        row
      - reply containing seq 41 (already seen) is skipped; 42 applied
      - `truncated: true, latest_seq: 90` → nothing folded, cursor → 90, hydrate runs
      - reply `epoch` "e2" ≠ stored "e1" → cursor nil, epoch e2, hydrate runs
      - `-32601` → `replaySupported` false, hydrate runs; next reconnect sends no
        `events.since`
      - `.disconnected` failure → no hydrate over a reconnecting socket; the next `.ready`
        replays from the same cursor
      - no cursor (first connect / older agent) → `session.resume` only, byte-identical
        params to the existing fixture
      - ready with `session_authority: true` → `session.resume` only, no `events.since`
      - `attachLiveSessionID` path and `createSession` path never replay
      - `.teardown` during the RTT cancels the replay (no late `replayResult`)
      - #97 interplay (v7 hydrate, `desktop_contract: 7`):
        - replayed `request.cancel` (timeout) for the presented head removes it and presents
          the queued next; the hydrate listing only that next id refreshes it in place (same
          token); the "Timed out" row does not survive the hydrate
        - replayed `request.cancel` for an unknown id is a no-op; for a queued non-head id it
          removes it silently
        - replayed `request.cancel` / `message.complete` with a queued prompt (#66) sends no
          `prompt.submit` during the fold; a `running: true` hydrate then drains nothing, a
          `running: false` hydrate drains exactly once
        - an `events.since` reply with a non-empty `open_requests` presents nothing; only
          the following hydrate's `open_requests` raises the card (token 1)
      - legacy `approval.request` / `clarify.request` in a replay batch are skipped (no card,
        cursor still advances past them); the same events live still present
      - replayed `message.complete` with a `running: false` hydrate → wholesale replace, no
        preserved rows; replayed `review.summary` is wiped by the hydrate (pins the accepted
        behaviour)
- [x] run tests - must pass before next task

### Task 5: Cursor lifetime across background grace and re-hydrates

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (only if a path resets the cursor unintentionally)
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`

- [x] audit every state reset in `ChatFeature` (`.teardownSocketOnly`, `.foreground`,
      `.reattached`, `.resumeAfterReauth`, branch create, `applyActivate`,
      `reconcileServerRequests`). The cursor must survive all but `.teardown`.
      `applyActivate` returning a different live `session_id` leaves the cursor to be
      replaced by the next stamped frame
      (audit result: no source change needed. Only `init`, the ready/reply epoch rules and
      `advanceReplayCursor` write the cursor; a branch is a new slot, so a fresh `init`;
      `.liveSessionIDRefreshed` / `.branchReplayResult` re-mint the live id like
      `applyActivate` does)
- [x] write tests: grace-expiry `.teardownSocketOnly` → `.foreground` redial replays from
      the pre-expiry cursor; `.resumeAfterReauth` replays (same session, fresh cookies);
      `.foreground` over a healthy socket does NOT call `events.since` (no drop happened:
      `status == .ready`, so it hydrates directly and the `.ready` branch never runs)
      (➕ `.reattached` variants of the grace-expiry and healthy-socket tests; a re-minted
      live id test)
- [x] run tests - must pass before next task

### Task 6: Verify acceptance criteria
- [x] verify all requirements from Overview: gap tool/thinking/status events appear after a
      reconnect into a running turn; v7 prompts come only from the hydrate's `open_requests`;
      no queued prompt fires before the hydrate; older agents and session-authority hosts
      unchanged; every fallback hydrates
      (➕ added `replayedStatusUpdateRidesTheLiveThinkingRowThroughTheRunningHydrate`; the
      requirement-to-test map is in the progress log)
- [x] verify edge cases: epoch change mid-session, ring truncation on a long gap, replay
      cancelled by teardown, two reconnects in a row (cursor advances through the first
      replay), re-minted live id (an idle session reaped after the 20 s orphan grace)
      (➕ added `gatewayRestartDuringTheGapSkipsTheReadAndHydrates` and
      `consecutiveReconnectsReadFromTheCursorTheFirstReplayAdvanced`; no code change needed)
- [x] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [x] build the app target (`make run` on a simulator): `DemoMode` and the debug log view
      compile against the frame stream (built with `tuist generate` + `make build`; not
      launched)
- [x] manual pass (skipped - not automatable; needs a live agent, steps kept for the user)
      against a live agent at v0.22.5 or current `main` (the v7 + ring combination):
      - start a long tool-heavy turn, toggle airplane mode for ~20 s, return: the tool rows
        from the gap are present before the turn ends;
      - repeat with an approval raised during the gap: the card comes back exactly once (from
        the hydrate);
      - repeat with the gateway restarted during the gap: plain hydrate, no banner, no
        duplicate rows

### Task 7: [Final] Update documentation
- [x] `docs/architecture.md`:
      - Wire protocol section: frame envelope, cursor, epoch, the held-ready epoch;
      - "Session re-hydration" (`:421`): replay-then-hydrate ordering after the advertisement
        gate, fallbacks, why no parking buffer, the carve-out, no drain during the fold;
      - "Server→client requests" (`:301`): one line that requests never replay and
        `request.cancel` may
      (➕ new "Event frames and the replay cursor" and "Reconnect replay" subsections; the
      gateway-client and debug-log client bullets and the grace-expiry paragraph updated; the
      lifecycle paragraphs now sit under an "App lifecycle and navigation" heading)
- [x] `docs/features/approvals.md` "Reconnect replay (v7)": a replayed `request.cancel` runs
      before the hydrate; `open_requests` from `events.since` is ignored; legacy prompt events
      are not replayed
      (➕ `docs/features/prompt-queue.md`: the fold is not a drain edge)
- [x] `CLAUDE.md` gateway bullet: one line on the cursor and the replay-before-hydrate rule
      (after the `.ready` gate, no queue drain during the fold)
- [x] `README.md` "Stays connected" bullet (`:92-97`): mention that a running turn's gap is
      replayed
- [x] comment on #98 with the server floor (v2026.8.27 for the ring; v7 combination
      v2026.9.14+, current v0.22.x) and the fallback behaviour (drafted at
      /tmp/issue-98-comment.md; posting left to the user)
- [x] move this plan to `docs/plans/completed/` (done by the orchestrator at completion)

## Post-Completion

**Manual verification**
- Real-device airplane-mode test above, plus a lock/unlock cycle longer than the ~30 s
  background grace (the `.teardownSocketOnly` → foreground path).
- Watch the debug log for `events.since` notes against the production agent to confirm the
  carve-out is quiet in practice.

**External**
- Server floor v2026.8.27 for replay. Nothing changes for older agents or session-authority
  hosts.
- ⚠️ Session-authority hosts (v0.22.3+, `gateway.ready.session_authority: true`) are skipped,
  not supported. Supporting them needs the per-session `replay_epoch` cursor and
  `snapshot_required`, and is only worth it once the app is verified against the canonical
  protocol at all.
- ⚠️ v2026.8.27 – v2026.9.7 could restart a FIFO-evicted session's seq at 1 in the same epoch
  (#100122). The cursor then sticks high, live events still reduce, and each replay folds
  nothing and hydrates (today's behaviour). Not worked around.
- #90 (multi-slot live chat) will need one cursor per slot. The per-slot state here already
  fits that shape; the replay effect would run per slot on its own socket.
