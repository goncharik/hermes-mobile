# Lossless reconnect: event `seq` watermark and `session.events.since` replay (#98)

## Overview

Track the server's per-session event sequence number on every frame and, after a socket
drop, replay the events the phone missed through the same fold as live events before the
ordinary `session.resume` hydrate runs.

- **Problem.** A socket drop mid-turn loses every event emitted while the phone was
  disconnected. The reducer reconnects with backoff and re-hydrates via `session.resume`,
  which rebuilds the transcript from history plus `inflight` — but `inflight` carries only
  the user prompt and the assistant text so far, never reasoning or tool rows (#26 preserves
  the client's own live rows for exactly that reason). Tool calls, thinking, status updates,
  and blocking prompts that fired during the gap are simply gone until the turn ends.
- **Benefit.** After a reconnect the in-flight turn shows the tool and thinking rows that
  happened during the gap, an `approval.request` / `clarify.request` emitted in the gap is
  presented (the exact-state hydration in #97 covers the same case from the resume side),
  and a `review.summary` fired in the gap renders instead of vanishing. Behaviour on an agent
  older than v2026.8.27 is byte-identical to today.
- **Integration.** The connect stream carries a small `GatewayFrame` envelope (event +
  `session_id` + `seq` + the ready `replay_epoch`). The reducer keeps the watermark per live
  slot in memory and decides whether to replay; the gateway client stays a dumb pipe
  (reconnect/backoff/replay policy lives in the reducer, per `CLAUDE.md`). Replay runs on
  `.ready` **before** `hydrate`, so the existing `applyActivate` rules (server wins, #26 live
  row preservation, `inflight` re-seed) are untouched and remain the authority.

Split out of #96 with #97 (request-bound approval/clarify cards) and #99 (native Projects).

## Context (from discovery)

Verified against upstream Hermes `main` `63279301bc` (2026-09-03) via
`git show upstream/main:<path>` in the sibling clone
`/Users/eugene/Documents/Development/Personal/hermes-agent` (the checked-out tree is stale).

**Server wire** — `tui_gateway/event_replay.py`, `tui_gateway/server.py` `write_json`,
`tui_gateway/ws.py`, `tui_gateway/methods_session.py` (all since `87631bd8ae`, v2026.8.27):
- Every outgoing `{"method":"event","params":{type, session_id, payload}}` frame with a
  non-empty `session_id` is stamped `params.seq` (per-session, monotonic from 1, in-process)
  and appended to a ring of **512 events per session**, at most **64 sessions** (oldest
  session evicted). Session-less globals (`skin.changed`, `sessions.changed`) carry no `seq`.
- `gateway.ready` payload: `{skin, change_events: true, heartbeat: true, replay_epoch}`.
  `replay_epoch` is a per-process uuid; a gateway restart changes it (and resets every
  counter to 1).
- `session.events.since {session_id, last_seen: Int}` → `{events: [eventObject...],
  latest_seq, truncated, count, epoch}`. Each element is the frame's `params` dict —
  `{type, session_id, seq, payload}` — exactly what the client's event dispatch consumes.
  `truncated` is true when `last_seen + 1 <` the ring's oldest retained seq. A non-integer
  `last_seen` → `-32602`; an older agent → `-32601`.
- The desktop (`apps/shared/src/json-rpc-gateway.ts`): per-session `lastSeenSeq` map;
  `recordSeq` ignores non-increasing seqs and seq-less frames; `fetchReplay` on reconnect
  (one RPC per known session, 10 s budget), dispatches only newer seqs, adopts a changed
  epoch by clearing the watermarks, parks live frames while a replay is in flight, and
  swallows every replay failure ("an optimization over lossy reconnect").

**App today**
- `HermesKit/Sources/HermesKit/Models/JSONRPC.swift` — `InboundFrame.event(sessionID:,
  GatewayEvent)`: reads `params.session_id`, discards it downstream; never reads `seq`.
- `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` — `case "gateway.ready": .ready`
  drops the payload.
- `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift` — `connect` returns
  `AsyncStream<GatewayEvent>`; `GatewayConnection.handle(frame:)` yields the bare event;
  `HermesGatewayClientTests` with `FakeTransport`.
- `HermesKit/Sources/HermesKit/Clients/DebugLogClient.swift` — `append(GatewayEvent)`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `connect(_:)` (~2572) forwards
  each event as `.gatewayEvent`; `.gatewayEvent` (~1043) snapshots the window, calls
  `reduce(event:into:)`, persists; `.gatewayClosed` (~1058) finalizes in-flight rows and
  schedules the backoff redial; `reduce(event: .ready)` sets `.ready`, then (guarded by
  `hasRequestedSession`) branches to `attachLive` / `hydrate(sessionID:profile:)` /
  branch-seed replay / `createSession`; `hydrate` is `CancelID.hydrate`,
  `cancelInFlight`; `.teardown` cancels socket/reconnect/hydrate; `.teardownSocketOnly`
  keeps the state in memory for the foreground catch-up.
- `HermesMobile/Sources/DemoMode.swift:48` stubs `hermesGateway.connect` with a never-yielding
  stream (element type inferred — compiles unchanged).
- Tests to touch: 7 `yield(.ready)` stubs and 5 `receive(\.gatewayEvent)` asserts in
  `HermesKit/Tests/HermesKitTests/` (`HydrateTests`, `AppFeatureTests`, others — grep); the
  145 `send(.gatewayEvent(...))` sites are unaffected because the action stays.
- Docs to update: `docs/architecture.md` "Session re-hydration" and the gateway socket
  section; `CLAUDE.md` gateway bullet; `README.md` reliability note if one exists.

**Relationship to #97.** #97 hydrates `pending_approval` / `pending_clarify` from the resume
response and presents them unless a card with the same `request_id` already stands. With
replay first, a gap `approval.request` presents the card, and the following hydrate is a
no-op for it. If #97 has not landed, the replayed request still presents a real card (today's
generic hint path stays as is). No ordering dependency between the two plans.

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
- maintain backward compatibility: frames without `seq` (agent < v2026.8.27) never advance
  a watermark, so no replay RPC is ever sent to an older agent; the reconnect path is
  byte-identical to today for them
- commit per task, capitalized verb, no conventional-commit prefix

## Testing Strategy

- **unit tests** (HermesKit, `swift test`): `JSONRPCTests` for the envelope decoding
  (`seq`, `session_id`, `replay_epoch`, event objects from `events.since`);
  `HermesGatewayClientTests` with `FakeTransport` for frames reaching the stream intact;
  `TestStore` reduction tests for the watermark (advance / ignore non-monotonic / seq-less),
  epoch adoption and reset, and the reconnect flow (replay-then-hydrate ordering, fold
  order, seq gate on replayed events, every fallback). Event-reduction tests are the
  highest-value suite here — the replay path is entirely reducer logic.
- no UI change → no snapshot work. No e2e suite in this project.
- run with `script -q /dev/null swift test --package-path HermesKit` (or `make test`) —
  piped output buffers.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

1. **Envelope, not a new event.** `GatewayFrame { event, sessionID, seq, replayEpoch }` is
   what the connect stream yields. `GatewayEvent` is unchanged (`.ready` stays payload-less;
   the epoch rides on the frame). `InboundFrame` builds it, and a second initializer builds it
   from a bare event object (the `events.since` element shape) so replayed and live events
   decode through one path.
2. **The reducer owns the cursor.** `ChatFeature.State` gains `replayCursor:
   ReplayCursor?` (`sessionID` + `seq`), `replayEpoch: String?`, and `replaySupported: Bool`
   (per slot, unpersisted, reset in `init`). A new `.gatewayFrame(GatewayFrame)` action is
   what the socket effect sends: it records the cursor/epoch and then reduces exactly as
   `.gatewayEvent` does (shared helper — one code path). `.gatewayEvent` remains for tests
   and for replayed events.
3. **Replay before hydrate.** In `reduce(event: .ready)`, when the slot has a cursor for its
   live session and `replaySupported`, and the branch is the ordinary stored-session resume
   (not `attachLive`, not a branch-seed replay, not `createSession`), return a replay effect
   instead of `hydrate`. The effect calls `session.events.since` and feeds
   `.replayResult(Result<ReplayBatch, GatewayError>)`. The reducer folds `batch.events` in
   order through the seq gate (only `seq > cursor.seq`, advancing the cursor per event), then
   returns `hydrate(...)`. Every fallback — `truncated`, epoch mismatch, `-32601` (latches
   `replaySupported = false`), any other failure, malformed result — folds nothing and
   returns `hydrate(...)`. The failure is recorded through `debugLog` only; **deliberate
   carve-out** from the surface-every-RPC-failure rule (documented at the call site): the
   user-visible outcome is today's hydrate, and a banner would fire on every reconnect
   against an agent that lacks the ring.
4. **Why before, not after.** Before `session.resume` the new socket is not attached to the
   session, so no live session frame can race the replay — the desktop's park-and-flush
   buffer is unnecessary. Folding the gap first also composes with `applyActivate` as is: a
   running hydrate preserves the thinking/tool rows the replay just built (#26), and the
   streaming assistant row is re-seeded from `inflight.assistant` (server wins), so replayed
   `message.delta`s never double the text. A completed turn is replaced wholesale by history.
   The one-RTT window between the replay read and the resume attach is accepted (today the
   whole gap is lost).
5. **Epoch rules.** The epoch learned on a `.ready` frame is compared to the stored one: a
   change (gateway restart) clears the cursor before the branch above runs, so no replay is
   attempted against numbering that no longer exists; the new epoch is adopted. An
   `events.since` reply whose `epoch` differs from the stored one is treated the same way
   (drop, adopt, hydrate). A frame or reply with no epoch (older agent) leaves the stored
   value untouched.
6. **Cursor lifetime.** In memory only, per slot: survives `.gatewayClosed`, the backoff
   redial, `.teardownSocketOnly` (grace expiry — the exact case a replay pays for) and
   `.foreground` / `.reattached` re-hydrates; dies with the slot on `.teardown`. Never
   persisted (a cold launch always hydrates). A `session.resume` that returns a different live
   `session_id` than the cursor's simply starts a fresh cursor on the first stamped frame.

Key decisions:
- **Reducer-owned over a client-side recorder.** A watermark hidden in the gateway client
  would need rules about which disconnects clear it and would put reconnect knowledge in
  the client; the frame envelope costs ~15 mechanical test edits and keeps every decision in
  `TestStore` reach.
- **`.gatewayEvent` action kept.** The 145 existing reduction tests and the replay fold both
  use it; only the socket effect switches to `.gatewayFrame`.
- **No parking buffer** (see 4). If a later change attaches the socket before hydrate, revisit.
- **One RPC, the slot's own session only.** The phone has one live session per socket (#90
  is where multi-session replay would go).

## Technical Details

### Models (`JSONRPC.swift` / new `GatewayFrame.swift`)

```swift
/// One inbound event as delivered by the socket or replayed by `session.events.since`.
public struct GatewayFrame: Equatable, Sendable {
  public var event: GatewayEvent
  public var sessionID: String?
  /// Server per-session monotonic sequence (v2026.8.27+); nil on older agents and on
  /// session-less global events.
  public var seq: Int?
  /// `gateway.ready` only: the server process's replay epoch.
  public var replayEpoch: String?

  public init(_ event: GatewayEvent, sessionID: String? = nil, seq: Int? = nil, replayEpoch: String? = nil)
  /// Decode a bare event object `{type, session_id, seq?, payload?}` — the shape shared by a
  /// frame's `params` and each `events.since` element. Missing/invalid `type` → nil.
  public init?(eventObject: JSONValue)
}

// InboundFrame
case event(GatewayFrame)     // was event(sessionID: String?, GatewayEvent)

public struct ReplayBatch: Equatable, Sendable, Decodable {
  public var events: [GatewayFrame]   // decoded via GatewayFrame(eventObject:), undecodable elements dropped
  public var latestSeq: Int?          // "latest_seq"
  public var truncated: Bool          // default false
  public var epoch: String?
}
```

`seq` decodes from a JSON number (`intValue`); a non-integer or negative value is treated as
absent. `replay_epoch` is read from the `gateway.ready` payload only.

### Client (`HermesGatewayClient.swift`)

- `connect: (URL, AuthSession) -> AsyncStream<GatewayFrame>`; `GatewayConnection.handle`
  yields `frame` for `.event(frame)`; the cookie-mode `.authExpired` yield becomes
  `GatewayFrame(.authExpired)`. `testValue` unchanged in spirit (finishes immediately).
- No replay logic in the client.

### Reducer (`ChatFeature`)

State (per slot, unpersisted, reset in `init`):
```swift
public struct ReplayCursor: Equatable, Sendable { public var sessionID: String; public var seq: Int }
var replayCursor: ReplayCursor?
var replayEpoch: String?
var replaySupported: Bool = true
```

Actions:
- `gatewayFrame(GatewayFrame)` — sent by the socket effect (`connect(_:)` loop; `debugLog`
  still receives `frame.event`).
- `replayResult(Result<ReplayBatch, GatewayError>)`.

`gatewayFrame` reduction:
```
if let epoch = frame.replayEpoch {              // .ready frames
  if let known = state.replayEpoch, known != epoch { state.replayCursor = nil }
  state.replayEpoch = epoch
}
advanceCursor(frame, into: &state)               // sid + seq present && seq > cursor.seq (or no cursor / other sid)
return reduceGatewayEvent(frame.event, into: &state)   // the existing `.gatewayEvent` body, extracted
```
`advanceCursor`: a frame for a different `sessionID` than the cursor's replaces the cursor
(the slot follows one session; a re-minted live id starts over). A seq-less frame is a no-op.

`reduce(event: .ready)` insertion point — after the `attachLiveSessionID` branch, inside the
`if let stored = state.storedSessionID` branch:
```
if state.replaySupported, let cursor = state.replayCursor, cursor.sessionID == state.liveSessionID {
  state.hydrateRetriedAfterTimeout = false
  return replay(cursor: cursor, thenHydrate: (stored, state.scopedProfile))
}
```
`replay(cursor:)` effect (`CancelID.replay`, `cancelInFlight`): `session.events.since
{session_id: cursor.sessionID, last_seen: cursor.seq}` → `.replayResult`. Uses the default
30 s per-request budget (the desktop uses 10 s; the reducer's hydrate timeout handling is
downstream and unaffected — a slow replay only delays the hydrate, it never redials).

`replayResult` reduction:
```
switch result {
case .success(let batch):
  if let epoch = batch.epoch, let known = state.replayEpoch, epoch != known {
      state.replayCursor = nil; state.replayEpoch = epoch          // restart: skip
  } else if batch.truncated {
      // gap fell off the ring — history refetch (the hydrate) is the only honest source
  } else {
      var effects: [Effect<Action>] = []
      for frame in batch.events where frame.seq passes the gate {
          advanceCursor(frame, into: &state)
          effects.append(reduceGatewayEvent(frame.event, into: &state))
      }
      // effects from the fold (thinking timer start, runningChanged, persist) are merged
  }
case .failure(let error):
  if error.isUnknownMethod { state.replaySupported = false }
  debugLog.note(...)      // carve-out, see Solution Overview 3
}
return .merge(effects + [hydrate(sessionID: stored, profile: state.scopedProfile)])
```
`stored`/profile are captured on the action (`replayResult(_, thenHydrate:)`) or re-read from
state at reduction time (`storedSessionID` is stable across the RTT; a `.teardown` cancels
`CancelID.replay` so no late result reduces).

Guards on the fold: a replayed `.ready`/`.authExpired` never appears (server never records
them); a replayed `.unknown` is harmless. `persistRelevant` applies per folded event as
today (debounced — one write).

Cancellation: `.teardown` and `.teardownSocketOnly` add `.cancel(id: CancelID.replay)`; a
`.gatewayClosed` during the replay RTT cancels it too (the next `.ready` re-runs it from the
same cursor — the RPC threw `.disconnected`, which is the failure path, and its hydrate is
also moot: guard `replayResult` on `status != .reconnecting` to avoid a hydrate over a dead
socket).

### Wire examples (test fixtures)

```json
// live frame
{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"live1","seq":42,"payload":{"name":"terminal"}}}
// ready
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"e1"}}}
// session.events.since reply
{"events":[{"type":"tool.start","session_id":"live1","seq":43,"payload":{"name":"terminal"}},{"type":"tool.complete","session_id":"live1","seq":44,"payload":{"name":"terminal","result_text":"ok"}}],"latest_seq":44,"truncated":false,"count":2,"epoch":"e1"}
```

## Implementation Steps

### Task 1: `GatewayFrame` envelope and `InboundFrame` sequencing fields

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/GatewayFrame.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/JSONRPC.swift`
- Modify: `HermesKit/Tests/HermesKitTests/JSONRPCTests.swift`

- [ ] add `GatewayFrame` with the memberwise init and `init?(eventObject:)` (type required,
      `session_id` / `seq` / `payload` optional; `seq` only when a non-negative integer)
- [ ] add `ReplayBatch` (lenient: `events` elements that fail `GatewayFrame(eventObject:)`
      are dropped; `truncated` defaults `false`)
- [ ] change `InboundFrame.event` to carry a `GatewayFrame`; parse `replay_epoch` from the
      `gateway.ready` payload onto the frame; `session_id` and `seq` from `params`
- [ ] write decoding tests: live frame with `seq`; frame without `seq` (older agent) → nil;
      non-integer `seq` → nil; `gateway.ready` with/without `replay_epoch`; session-less
      global event; `events.since` reply with two events + one malformed element dropped;
      `truncated` absent → false
- [ ] run tests - must pass before next task

### Task 2: Gateway client yields frames

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Clients/HermesGatewayClient.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`connect(_:)` loop only — compile fix, forwards `frame.event` for now)
- Modify: `HermesKit/Tests/HermesKitTests/HermesGatewayClientTests.swift`
- Modify: every test stub yielding `.ready` / other events on `hermesGateway.connect` (grep `yield(.` in `HermesKit/Tests`)

- [ ] `connect` returns `AsyncStream<GatewayFrame>`; `GatewayConnection.handle` yields the
      frame; the cookie-mode `.authExpired` path yields `GatewayFrame(.authExpired)`
- [ ] update `ChatFeature.connect(_:)` to iterate frames and send `.gatewayEvent(frame.event)`
      (temporary — Task 3 switches it to `.gatewayFrame`), `debugLog.append(frame.event)`
- [ ] update the test stubs to yield `GatewayFrame(.ready)` etc.; `DemoMode.swift` compiles
      unchanged (verify with an app build)
- [ ] write client tests: a stamped event reaches the stream with `sessionID` + `seq`; the
      ready frame carries the epoch; multiple newline-delimited frames keep their seqs
- [ ] run tests - must pass before next task

### Task 3: Reducer cursor and epoch tracking (`.gatewayFrame`)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ReplayCursorTests.swift`
- Modify: the 5 `receive(\.gatewayEvent)` asserts that follow a stubbed connect (→ `\.gatewayFrame`)

- [ ] add `ReplayCursor`, `replayCursor`, `replayEpoch`, `replaySupported` to `State` (init
      defaults; `Equatable` as the rest)
- [ ] add `Action.gatewayFrame(GatewayFrame)`; extract the `.gatewayEvent` body into
      `reduceGatewayEvent(_:into:)`; `.gatewayEvent` and `.gatewayFrame` both call it;
      `.gatewayFrame` first applies the epoch rule and `advanceCursor`
- [ ] switch `connect(_:)` to send `.gatewayFrame(frame)`
- [ ] write tests: seq 1,2,3 advances the cursor; seq 2 after 3 is ignored (event still
      reduces); seq-less frame leaves the cursor; a frame for another session id replaces
      the cursor; `.ready` with epoch "e1" adopts it; a later `.ready` with "e2" clears the
      cursor and adopts "e2"; `.ready` without an epoch keeps both; `.gatewayFrame` reduces
      identically to `.gatewayEvent` for a `message.delta` (transcript + persist effect)
- [ ] update the affected `HydrateTests` / `AppFeatureTests` asserts to `\.gatewayFrame`
- [ ] run tests - must pass before next task

### Task 4: Replay-then-hydrate on `.ready`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/ReplayTests.swift`

- [ ] add `CancelID.replay`, `Action.replayResult(Result<ReplayBatch, GatewayError>)`, the
      `replay(cursor:)` effect (`session.events.since {session_id, last_seen}`; malformed
      result → `.failure(.server("Malformed session.events.since result"))`)
- [ ] insert the replay branch in `reduce(event: .ready)` (stored-session path only, cursor
      must match `liveSessionID`, `replaySupported`)
- [ ] implement `replayResult`: epoch mismatch → drop cursor, adopt; `truncated` → skip;
      otherwise fold gated events in order via `reduceGatewayEvent` + `advanceCursor`,
      merging the fold's effects; `-32601` → `replaySupported = false`; any failure → log
      via `debugLog` with the call-site carve-out comment; always finish with `hydrate`;
      guard on `status != .reconnecting`
- [ ] cancel `CancelID.replay` on `.teardown`, `.teardownSocketOnly`, and `.gatewayClosed`
- [ ] write reduction tests (`TestStore`, `TestClock`, in-memory snapshot):
      - reconnect with cursor (live1, 41) sends `session.events.since {session_id: live1,
        last_seen: 41}` BEFORE `session.resume` (record the RPC order)
      - reply with tool.start 42 / tool.complete 43 folds two tool rows, cursor → 43, then
        the running hydrate preserves them (#26) alongside the rebuilt history
      - reply containing seq 41 (already seen) is skipped; 42 applied
      - `truncated: true` → nothing folded, hydrate runs
      - reply `epoch` "e2" ≠ stored "e1" → cursor nil, epoch e2, hydrate runs
      - `-32601` → `replaySupported` false, hydrate runs; next reconnect sends no
        `events.since`
      - `.disconnected` failure → no hydrate over a reconnecting socket; the next `.ready`
        replays from the same cursor
      - no cursor (first connect / older agent) → `session.resume` only, byte-identical
        params to the existing fixture
      - `attachLiveSessionID` path and `createSession` path never replay
      - `.teardown` during the RTT cancels the replay (no late `replayResult`)
      - replayed `approval.request` presents a card (token 1) and the following hydrate
        with `running: true` leaves it standing
      - replayed `message.complete` with `running: false` hydrate → wholesale replace, no
        preserved rows
- [ ] run tests - must pass before next task

### Task 5: Cursor lifetime across background grace and re-hydrates

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (only if a path resets the cursor unintentionally)
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`

- [ ] audit every state reset in `ChatFeature` (`.teardownSocketOnly`, `.foreground`,
      `.reattached`, `.resumeAfterReauth`, branch create, `applyActivate`) — the cursor
      must survive all but `.teardown`; `applyActivate` returning a different live
      `session_id` leaves the cursor to be replaced by the next stamped frame
- [ ] write tests: grace-expiry `.teardownSocketOnly` → `.foreground` redial replays from
      the pre-expiry cursor; `.resumeAfterReauth` replays (same session, fresh cookies);
      `.foreground` over a healthy socket does NOT call `events.since` (no drop happened —
      `hasRequestedSession` is still true, the `.ready` branch never runs)
- [ ] run tests - must pass before next task

### Task 6: Verify acceptance criteria
- [ ] verify all requirements from Overview: gap tool/thinking/status/prompt events appear
      after a reconnect; older agents unchanged; every fallback hydrates
- [ ] verify edge cases: epoch change mid-session, ring truncation on a long gap, replay
      cancelled by teardown, two reconnects in a row (cursor advances through the first
      replay), re-minted live id
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] build the app target (`make run` on a simulator) — `DemoMode` and the debug log view
      compile against the frame stream
- [ ] manual pass against a live v2026.8.27+ agent: start a long tool-heavy turn, toggle
      airplane mode for ~20 s, return — the tool rows from the gap are present before the
      turn ends; repeat with the gateway restarted during the gap — plain hydrate, no
      banner, no duplicate rows

### Task 7: [Final] Update documentation
- [ ] `docs/architecture.md`: gateway socket section (frame envelope, cursor, epoch) and
      "Session re-hydration" (replay-then-hydrate ordering, fallbacks, why no parking
      buffer, the carve-out)
- [ ] `CLAUDE.md` gateway bullet: one line on the cursor and the replay-before-hydrate rule
- [ ] `README.md`: reliability note if the feature list mentions reconnect
- [ ] comment on #98 with the server floor (v2026.8.27) and the fallback behaviour
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**
- Real-device airplane-mode test above, plus a lock/unlock cycle longer than the ~30 s
  background grace (the `.teardownSocketOnly` → foreground path).
- Watch the debug log for `events.since` failures against the production agent to confirm
  the carve-out is quiet in practice.

**External**
- Server floor v2026.8.27 for replay; nothing changes for older agents.
- #90 (multi-slot live chat) will need one cursor per slot — the per-slot state here already
  fits that shape; the replay effect would run per slot on its own socket.
- #97's exact-state hydration and this replay overlap on gap `approval.request`s; once both
  land, the `approval.pending` probe in #97 is still needed for agents between v2026.8.16
  and v2026.8.27 (request ids but no ring).
