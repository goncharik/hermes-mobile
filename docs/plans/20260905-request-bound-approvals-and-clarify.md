# Request-bound approval and clarify cards (#97)

## Overview

Bind the approval and clarify cards to the server's exact request identity, honor the
server-advertised approval choices, add the multi-select and batch clarify forms, and hydrate
a pending approval or clarify prompt straight from the `session.resume` response instead of
synthesizing a generic card from a push-tap hint.

- **Problem.** `ApprovalRequest` still documents approvals as a per-session FIFO with no
  `request_id`, and `approval.respond` is sent with `session_id` + `choice` + `all` only. That
  has been false since Hermes v2026.8.16: every gateway approval carries a `request_id`,
  `approval.respond` accepts it, `approval.pending` / `approval.received` exist, and
  `session.resume` returns `pending_approval` and `pending_clarify` (the latter with the batch
  `answers` locked so far). The app reads none of it, so after a reconnect it shows a generic
  "couldn't be recovered" card and answers whatever sits at the head of the queue — possibly a
  different request than the one the user saw. Clarify supports only single-select and free
  text; a `multi_select` or batch `questions` request renders as a single question (batch:
  an empty one), the answer never unblocks the agent, and the composer stays locked until the
  clarify timeout (which can be configured to *never*).
- **Benefit.** The card the user answers is the request the server resolves. A reconnect
  restores the real command, the real question, and the batch answers already locked. Every
  clarify form the desktop renders works on the phone. The phone never widens the server's
  choice set (no "session" whitelist when the server withheld it).
- **Integration.** Everything rides the existing `pendingInteraction` / `present(_:)` /
  `pendingInteractionToken` contract and the single `hydrate` → `applyActivate` funnel. The
  push-tap hint (`expectsPendingApproval`) stays as the trigger, but its consumer becomes an
  exact `approval.pending` read-back; the generic recovered card survives only as the
  old-server fallback, gated on `-32601`. No `AppFeature` routing changes.

Sibling issues split out of #96: #98 (event replay) and #99 (native Projects). Out of scope
here. Multi-slot fan-out stays #90.

## Context (from discovery)

Verified against upstream Hermes `main` `63279301bc` (2026-09-03) via
`git show upstream/main:<path>` in the sibling clone
`/Users/eugene/Documents/Development/Personal/hermes-agent` (the checked-out tree is stale).

**Server wire (approval)** — `tui_gateway/server.py` `_approval_request_payload`,
`tui_gateway/methods_prompt.py`, `tools/approval.py`:
- `approval.request` payload: `{request_id, command, description, pattern_key, pattern_keys,
  choices, ...}`. `request_id` is a uuid hex set on every queue entry since `f703e70618`
  (v2026.8.16). `choices` is `["once","session","always","deny"]` narrowed by
  `allow_session` / `allow_permanent`, or `["once","deny"]` when `smart_denied`. `command` is
  credential-redacted server-side.
- `approval.respond {session_id, choice, all, request_id?}` → `{resolved: n}`. **With a
  `request_id` the `resolve_all` flag is ignored** (`resolve_gateway_approval`: the
  `request_id` branch runs first); without one it is FIFO / all. A `session` choice still
  whitelists the matched pattern for the rest of the session either way. On a 4001
  session-not-found the server also resolves the target by `request_id` across live sessions
  (`_approval_respond_session_fallback`).
- `approval.pending {session_id}` → `{approvals: [payload...]}` (oldest first, replay-safe
  snapshots). `approval.received {session_id, request_id}` → `{acknowledged: bool}`.
- The desktop (`apps/desktop/src/components/assistant-ui/tool/approval.tsx`) sends
  `{choice, request_id}` only.

**Server wire (clarify)** — `tui_gateway/server.py` `_block` / `_clarify_block` / `_respond`,
`tools/clarify_tool.py`:
- Single: `{request_id, question, choices: [..] | null}` plus `multi_select: true` only when
  set (older renderers never see the key). Batch: `{request_id, questions: [{qid, question,
  choices, multi_select}]}`; `qid` is `q0..qN` (server-minted, stable). Max 5 questions.
- The first choice of a multi-choice list arrives suffixed `" (Recommended)"`
  (`mark_recommended`; a lone choice is not suffixed). The server strips the label from the
  answer (`strip_recommended`) — presentation only, no preselection anywhere.
- `clarify.respond {session_id, request_id, answer}` for single; multi-select `answer` is a
  JSON array string or comma-separated (`_parse_multi_select_response`). Batch: **one respond
  per question** with `question_id: qid`, sent sequentially (the last lock releases the
  agent; `_respond` returns `{status: "ok", remaining: [qid...]}`); answers are
  update-in-place until every qid is locked. Cancel/skip: `{request_id, answer: ""}` with no
  `question_id`. `allow_expired=True`: a late answer returns `{status: "expired"}`, never 4009.
- `clarify.expire {request_id}` is emitted when the wait times out (`_EXPIRING_REQUESTS`); the
  desktop dismisses the card on it (`input-requests.ts`). No approval expire event exists.
- Timeout defaults to 300 s; `clarify_timeout <= 0` waits forever.

**Server wire (resume)** — `session.resume` payload adds `pending_approval` (oldest
unresolved, same shape as the event; since `38b9005b95`) and `pending_clarify` (the
`clarify.request` payload plus `answers: {qid: answer}` for a batch with locks; since
`73bcfddb3d`). Both v2026.8.16. Absent when nothing is pending.

**App today**
- `HermesKit/Sources/HermesKit/Models/ApprovalRequest.swift` — `ApprovalRequest`
  (`command`, `detail`, `patternKey`, `patternKeys`; stale "no request_id" doc), `ClarifyRequest`
  (`requestID`, `question`, `choices`).
- `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift` — `.approvalRequest` /
  `.clarifyRequest` / `.sudoRequest` / `.secretRequest` decoded via `p.decoded(_:)`; no
  `clarify.expire`.
- `HermesKit/Sources/HermesKit/Models/Session.swift` — `ActivateResponse` (`messages`, `info`,
  `running`, `inflight`; every field `try?`-lenient).
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `PendingInteraction`,
  `present(_:)`, `expectsPendingApproval`, `recoveredApprovalRequest`, `applyActivate` (the
  single synthesis point, ~2733), `respondToApproval` (~1402), `respondToClarify` (~1460,
  `try?`-swallowed), `clearStaleApproval` (~2440), `commandsUnsupported` as the per-slot
  `-32601` flag precedent (`commandsUnsupportedDetected`).
- `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift` — bounded scroll region
  (`BoundedHeightLayout`), "Approve all in this session" toggle gated on
  `offersSessionApproval`. `ClarifyCardView.swift` (105 lines) — single-select button list or
  free-text field; rigid stacked content. Wired in `ChatView.pendingCard` (~330).
- Tests: `GatewayEventDecodingTests`, `ChatInteractionTests`, `ClarifyFeatureTests`,
  `HydrateTests` (HermesKit); `ChatSnapshotTests` (`testApprovalCard*`,
  `testClarifyCard_choices`, `testClarifyCard_freeText`) and `ApprovalCardLayoutTests`
  (hosted `UIWindow` measurements) in `HermesMobileTests`.
- Docs to update: `docs/features/approvals.md` (push-tap recovery section is written around
  "approvals have no request_id"), `docs/features/push-notifications.md`,
  `docs/architecture.md` "Session re-hydration", `CLAUDE.md` approval bullet.

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
- maintain backward compatibility: an agent older than v2026.8.16 (no `request_id`, no
  `pending_*`, no `approval.pending`/`received`) must behave byte-for-byte as today on the
  wire, including the generic recovered card
- commit per task, capitalized verb, no conventional-commit prefix

## Testing Strategy

- **unit tests** (HermesKit, `swift test`): decoding tests for every new wire field and shape;
  `TestStore` reduction tests for every new reducer path (request-bound respond, ack, batch
  sequencing, skip, expire, pending hydration, the `approval.pending` probe and its `-32601`
  fallback). Event-reduction tests are the highest-value suite here.
- **snapshot tests** (`HermesMobileTests`, `make snapshot` twice per new test): new clarify
  forms (multi-select, batch, recommended badge), approval card without the session toggle.
  Judge by render size first (baselines predate the current runtime; small pixel residual is
  drift).
- **hosted layout test** for the clarify card's new bounded region: a 5-question batch at
  keyboard-up window size keeps the Confirm/Skip row inside the window and the region
  scrollable (same pattern as `ApprovalCardLayoutTests`, assert on accessibility frames).
- no e2e suite in this project.
- run HermesKit tests with `script -q /dev/null swift test --package-path HermesKit` (or
  `make test`) — piped output buffers.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

1. **Models carry identity and the server's choice set.** `ApprovalRequest` gains an optional
   `requestID` and a `choices` array (lenient, default empty = "server predates choices").
   `ClarifyRequest` becomes a list of `ClarifyQuestion`s (single form = one question with no
   `qid`), each with `multiSelect`, plus `lockedAnswers` for hydration replay. A pure
   `ClarifyChoice` helper splits the `(Recommended)` label off a choice for display and returns
   the bare value for the answer. `clarify.expire` becomes a decoded event.
2. **Responses target one request.** `approval.respond` sends `request_id` when the request
   has one and then always `all: false` (the server ignores `resolve_all` with a `request_id`
   anyway; sending `true` would misdescribe intent on any server that changes that). Without a
   `request_id` (old server) the wire stays exactly as today. Clarify: single → `answer`;
   multi-select → `answer` as a JSON array string; batch → one `clarify.respond` per question
   with `question_id`, sequential, in question order; Skip → empty `answer` with no
   `question_id`. A failed respond surfaces `errorBanner` (no more `try?`).
3. **The phone narrows, never widens.** The "Approve all in this session" toggle shows only
   when `offersSessionApproval` (content) AND `allowsSessionChoice` (server `choices` empty or
   containing `"session"`). `always` is never offered. A `choices` list without `"once"` still
   renders Approve as `once` only if present; otherwise the card degrades to Deny-only with a
   note (defensive; the server always includes `once` today).
4. **Acknowledge receipt.** After a real `approval.request` (or a hydrated pending one) is
   presented, fire `approval.received {session_id, request_id}` once as a one-shot effect.
   `-32601` flips a per-slot, unpersisted `approvalAckSupported = false`; any other failure is
   silent by design (the ack is telemetry for the server's routing, nothing the user can act
   on) — the deliberate carve-out is documented at the call site like the catalog fetch.
5. **Hydration restores the exact prompt.** `ActivateResponse` decodes `pendingApproval` and
   `pendingClarify`. In `applyActivate`, when `running`: a `pendingApproval` is presented
   unless the standing card already shows that `requestID` (a re-hydrate of the same turn must
   not bump the token and reset the toggle/scroll); likewise `pendingClarify` (its
   `lockedAnswers` prefill the batch form). Approval wins if both arrive. A `running == false`
   hydrate clears **any** standing card (approval, clarify, secret — the server never ends a
   turn with a blocked prompt), generalizing `clearStaleApproval`.
6. **The push-tap hint reads back instead of guessing.** When `applyActivate` consumes an
   armed `expectsPendingApproval` with `running == true` and no `pendingApproval` in the
   payload and no card standing, it no longer synthesizes: it fires `approval.pending`. Result
   non-empty → present the oldest (with ack); empty → drop silently (server says nothing is
   pending); `-32601` → old server → present `recoveredApprovalRequest` exactly as today. A
   payload that *does* carry `pendingApproval` moots the hint outright.
7. **Clarify card grows a bounded region.** Multi-select rows toggle checkmarks with an
   explicit Submit; a batch renders each question as a section (single-select rows,
   multi-select rows, or a text field) over one `BoundedHeightLayout` scroll with a pinned
   Confirm/Skip row — the same shape as the approval card, because five questions with
   choices overflow the non-scrolling region exactly as a long command did (#65). Confirm is
   enabled only when every unlocked question has an answer. Recommended choices show a small
   badge, never a preselection.

Key decisions:
- **`approval.pending` as the recovery probe, not a "server supports pending state" flag.**
  An absent `pending_approval` key is indistinguishable between "old server" and "nothing
  pending"; the RPC's `-32601` is the only honest capability signal, and it costs one
  round-trip only on the rare hint-armed hydrate.
- **Batch answers are all re-sent on Confirm**, locked ones included — `_respond` is
  update-in-place, so re-sending is harmless and avoids tracking which locks the server
  already holds across a reconnect.
- **No approval expiry handling** — the server emits none; the not-running hydrate rule
  already covers a timed-out approval.
- **`ClarifyRequest` keeps `init(requestID:question:choices:)`** as a convenience so existing
  tests and the single form read the same.

## Technical Details

### Models

```swift
public struct ApprovalRequest: Equatable, Sendable, Decodable {
  public var requestID: String?      // "request_id" — nil on agents < v2026.8.16
  public var command: String?
  public var detail: String?         // "description"
  public var patternKey: String?
  public var patternKeys: [String]
  public var choices: [String]       // "choices" — [] when absent (old server)
  public var offersSessionApproval: Bool   // unchanged, content-derived
  public var allowsSessionChoice: Bool     // choices.isEmpty || choices.contains("session")
  public var allowsOnce: Bool              // choices.isEmpty || choices.contains("once")
}

public struct ClarifyQuestion: Equatable, Sendable {
  public var qid: String?            // nil for the single form
  public var question: String
  public var choices: [String]       // raw, may carry the "(Recommended)" suffix
  public var multiSelect: Bool
  public var isFreeText: Bool { choices.isEmpty }
}

public struct ClarifyRequest: Equatable, Sendable, Decodable {
  public var requestID: String
  public var questions: [ClarifyQuestion]     // >= 1 after decoding; batch form when qids present
  public var lockedAnswers: [String: String]  // "answers" from pending_clarify, keyed by qid
  public var isBatch: Bool { questions.first?.qid != nil }
  // convenience for the single form (keeps existing call sites/tests)
  public init(requestID: String, question: String, choices: [String] = [], multiSelect: Bool = false)
}

public enum ClarifyChoice {
  /// ("Use SwiftUI", isRecommended: true) for "Use SwiftUI (Recommended)"; case-insensitive
  /// suffix match, mirrors `strip_recommended`.
  public static func split(_ raw: String) -> (label: String, isRecommended: Bool)
}

public struct ClarifyExpire: Equatable, Sendable, Decodable { public var requestID: String }
// GatewayEvent: case clarifyExpire(ClarifyExpire)   ← "clarify.expire"
```

Decoding rules: `ApprovalRequest` stays fully lenient (every field optional; a payload with
only `request_id` still yields a card). `ClarifyRequest` requires `request_id` (fail-closed:
without it no answer could ever target the prompt) and either a non-empty `question` or a
non-empty `questions` array with each entry carrying `qid` + `question`; anything else fails
decoding and the event lands in `.unknown` (logged, never crashes). Unknown extra keys are
ignored. `multi_select` defaults `false`; `choices: null` → `[]`.

`ActivateResponse` adds `pendingApproval: ApprovalRequest?` (`"pending_approval"`) and
`pendingClarify: ClarifyRequest?` (`"pending_clarify"`), both `try?`-lenient like the rest.

### Reducer (`ChatFeature`)

State additions (per slot, unpersisted, reset in `init`):
- `approvalAckSupported: Bool = true`
- `approvalPendingSupported: Bool = true` (the probe's `-32601` latch)

Actions:
- `respondToApproval(approve:all:)` — unchanged signature; wire changes only.
- `respondToClarify(answer:)` — single form (unchanged signature).
- `respondToClarifyMulti(selections: [String])` — encodes the JSON array string.
- `respondToClarifyBatch(answers: [String: String])` — keyed by `qid`; the effect sends
  sequentially in `questions` order and feeds back `.clarifyRespondResult(.failure)` on the
  first error (the card stays up, banner shown; the user can retry).
- `skipClarify` — empty answer, no `question_id`; dismisses the card and appends a
  `.status(kind: "clarify", text: "Skipped")` row.
- `clarifyRespondResult(Result<Void, GatewayError>)` — failure → `errorBanner`, and for the
  single/multi form (card already dismissed) the optimistic echo row is patched to
  "Failed to send" like `approvalRespondResult`.
- `acknowledgeApproval(requestID:)` (internal) — one-shot `approval.received`;
  `approvalAckUnsupportedDetected` on `-32601`.
- `pendingApprovalProbeResult(Result<[ApprovalRequest], GatewayError>)` — see hydration.
- `.gatewayEvent(.clarifyExpire(e))` — if `pendingInteraction` is `.clarify` with that
  `requestID`: dismiss, append `.status(kind: "clarify", text: "Question timed out")`.

`respondToApproval` wire:
```
old server (requestID == nil): {session_id, choice, all}            // byte-identical to today
new server:                    {session_id, choice, all: false, request_id}
```
`choice` stays `deny` / `once` / `session`; `session` is only reachable when the view showed
the toggle, i.e. `allowsSessionChoice`.

`applyActivate` ordering (replacing today's hint block):
1. `running := response.running ?? false`.
2. If `!running`: `clearStaleInteraction` (any card) + clear the hint. Done with prompts.
3. If `running` and `response.pendingApproval` is some `a`: clear the hint; if the standing
   card is not `.approval` with the same `requestID`, `present(.approval(a))` and enqueue the
   ack. Else if `response.pendingClarify` is some `c` and the standing card is not
   `.clarify` with the same `requestID`, `present(.clarify(c))`.
4. Else if `running` and the hint is armed: consume it; if `pendingInteraction == nil` and
   `approvalPendingSupported`, return the `approval.pending` probe effect (cancellable id
   `CancelID.approvalProbe`, `cancelInFlight`); if `!approvalPendingSupported`, present
   `recoveredApprovalRequest` (today's behaviour).
5. Probe result: `.success(list)` → if still running and no card standing, present
   `list.first` (+ ack); empty → nothing. `.failure(isUnknownMethod)` → latch
   `approvalPendingSupported = false`, present `recoveredApprovalRequest` (if still running
   and no card). Other failure → `errorBanner` (an RPC failure is surfaced, never swallowed).

Everything else in `applyActivate` (the #26 live-row preservation, wholesale rebuild, inflight
seeding) is untouched. The hint's existing staleness rules (turn end clears it; answering any
approval clears it; a real `approval.request` overwrites any card) stand.

### Views (`HermesMobile`)

- `ApprovalCardView`: `showsSessionToggle = request.offersSessionApproval &&
  request.allowsSessionChoice`. Approve button hidden when `!allowsOnce` (Deny-only card with
  the server's `detail`). No other layout change.
- `ClarifyCardView` is rebuilt around one `BoundedHeightLayout` region (reuse the type from
  `ApprovalCardView.swift`; move it to its own file `BoundedHeightLayout.swift` in the same
  folder — pure move, no behaviour change) with a pinned action row:
  - single-select: rows as today (tap = submit), recommended badge via `ClarifyChoice.split`;
  - multi-select: checkmark rows + Submit (enabled when ≥ 1 selected);
  - free text: field + Send (as today);
  - batch: sections per question (each in one of the three forms; a text field for free-text
    questions), `lockedAnswers` prefilled and marked ✓, Confirm enabled when every question has
    an answer, plus Skip;
  - Skip is a secondary action on every form (desktop parity; without it an unlimited
    `clarify_timeout` locks the composer forever).
  - `ChatView.pendingCard` gains the new callbacks; `.layoutPriority(1)` stays scoped to
    `.approval` **and** batch clarify (`State.isCompressibleCardPending`), since the batch
    region is compressible now — single/free-text clarify stays rigid as documented.
- Local `@State` (selections, text per qid) is keyed on `pendingInteractionToken` through the
  existing `.id` at the call site, so a replacement card never inherits selections.

### Wire examples (tests fixtures)

```json
// approval.request (new server)
{"type":"approval.request","session_id":"live","payload":{"request_id":"ab12","command":"rm -rf build","description":"…","pattern_key":"rm_rf","choices":["once","session","always","deny"]}}
// clarify.request single multi-select
{"request_id":"c1","question":"Which targets?","choices":["iOS (Recommended)","macOS","tvOS"],"multi_select":true}
// clarify.request batch
{"request_id":"c2","questions":[{"qid":"q0","question":"Framework?","choices":["SwiftUI (Recommended)","UIKit"],"multi_select":false},{"qid":"q1","question":"Anything else?","choices":null,"multi_select":false}]}
// session.resume extras
{"pending_approval":{...as event payload...},"pending_clarify":{"request_id":"c2","questions":[...],"answers":{"q0":"SwiftUI"}}}
```

## Implementation Steps

### Task 1: `ApprovalRequest` carries `request_id` and the server's `choices`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ApprovalRequest.swift`
- Modify: `HermesKit/Tests/HermesKitTests/GatewayEventDecodingTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`

- [ ] add `requestID: String?` (`request_id`) and `choices: [String]` (default `[]`) to
      `ApprovalRequest`; extend the memberwise init with defaulted params
- [ ] add `allowsSessionChoice` and `allowsOnce` (empty `choices` → true; otherwise membership)
- [ ] rewrite the type's doc comment: request-bound since v2026.8.16, FIFO only on older
      agents; keep the Equatable-only rationale
- [ ] write decoding tests: full new-server payload, payload without `request_id`/`choices`
      (old server → nil / `[]`), `choices: ["once","deny"]` (smart-denied), malformed
      `choices` type still yields a card
- [ ] write tests for `allowsSessionChoice` / `allowsOnce` across empty, present, absent
- [ ] run tests - must pass before next task

### Task 2: Request-bound `approval.respond` and choice narrowing

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`respondToApproval`)
- Modify: `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`

- [ ] `respondToApproval`: when `request.requestID` is non-nil send `request_id` and
      `all: false`; when nil keep today's `{session_id, choice, all}` exactly; drop the
      "approvals have no request_id" comments and explain the `resolve_all`-ignored rule
- [ ] guard `session` choice: if `!request.allowsSessionChoice` treat `all == true` as `once`
      (defensive — the toggle is hidden, but the reducer must never widen)
- [ ] `ApprovalCardView`: gate the toggle on `offersSessionApproval && allowsSessionChoice`;
      hide Approve when `!allowsOnce`
- [ ] write reduction tests: new-server respond carries `request_id` + `all:false`;
      old-server respond is byte-identical to the current test fixture; `session` requested
      against `choices: ["once","deny"]` is sent as `once`; `resolved: 0` and RPC failure paths
      still behave (existing tests updated for the new fixture)
- [ ] add snapshot `testApprovalCard_noSessionChoice` (toggle hidden with a command present);
      `make snapshot` twice
- [ ] run tests - must pass before next task

### Task 3: `approval.received` acknowledgement

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`

- [ ] add `approvalAckSupported: Bool` to `State` (init `true`, per slot, unpersisted) and
      the internal actions `acknowledgeApproval(requestID:)` /
      `approvalAckUnsupportedDetected`
- [ ] on `.gatewayEvent(.approvalRequest(r))` with `r.requestID` non-nil and
      `approvalAckSupported`, merge a one-shot `approval.received {session_id, request_id}`
      effect after `present`; `-32601` → `approvalAckUnsupportedDetected`; other failures
      silent with a call-site comment naming the carve-out
- [ ] write tests: ack sent with exact params after a request; no ack when `requestID` is nil;
      `-32601` latches the flag and a second request sends nothing; a non-`-32601` failure
      leaves state untouched (no banner)
- [ ] run tests - must pass before next task

### Task 4: `ClarifyRequest` questions model, recommended split, `clarify.expire`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ApprovalRequest.swift` (move `ClarifyRequest` out)
- Create: `HermesKit/Sources/HermesKit/Models/ClarifyRequest.swift`
- Modify: `HermesKit/Sources/HermesKit/Models/GatewayEvent.swift`
- Modify: `HermesKit/Tests/HermesKitTests/GatewayEventDecodingTests.swift`
- Create: `HermesKit/Tests/HermesKitTests/ClarifyChoiceTests.swift`

- [ ] create `ClarifyRequest.swift` with `ClarifyQuestion`, the reworked `ClarifyRequest`
      (`questions`, `lockedAnswers`, `isBatch`, the single-form convenience init), and the
      custom decoder: single form → one question (`qid: nil`, `multi_select ?? false`);
      batch → `questions` mapped, each requiring `qid` + `question`; missing `request_id` or
      no usable question → throw
- [ ] add `ClarifyChoice.split(_:)` (case-insensitive `(recommended)` suffix, trimmed) and
      `ClarifyChoice.recommendedLabel` constant
- [ ] add `ClarifyExpire` and `GatewayEvent.clarifyExpire` (`"clarify.expire"`); add the case
      to the exhaustive switch(es) in `ChatFeature` (the non-transcript event list ~3477)
- [ ] write decoding tests: single with choices, single free-text (`choices: null`), single
      multi-select, batch of three mixed forms, batch with `answers`, missing `request_id` →
      `.unknown`, batch entry without `qid` → `.unknown`, `clarify.expire`
- [ ] write `ClarifyChoice.split` tests: suffix present / absent / mixed case / lone choice
- [ ] run tests - must pass before next task

### Task 5: Clarify responses: multi-select, batch sequencing, skip, expire, surfaced failures

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ClarifyFeatureTests.swift`

- [ ] `respondToClarify(answer:)`: strip the recommended label via `ClarifyChoice.split`
      before sending; replace `try?` with a `clarifyRespondResult` feedback (failure → banner +
      patch the echo row to "Failed to send")
- [ ] add `respondToClarifyMulti(selections:)` — JSON array string (`JSONEncoder` of
      `[String]`, no slash escaping concerns: use the `wireEncoder` rules only for the frame,
      the answer is a plain string) ; echo row lists the selections joined by ", "
- [ ] add `respondToClarifyBatch(answers:)` — guard every `qid` in `questions` has an answer;
      one effect sends `clarify.respond {session_id, request_id, question_id, answer}` per
      question sequentially in `questions` order; on first failure feed back `.failure` and
      leave the card standing; on success dismiss + echo one row per question
      ("Q: A" lines)
- [ ] add `skipClarify` — `{session_id, request_id, answer: ""}`; dismiss; "Skipped" row;
      failure → banner (card already dismissed)
- [ ] handle `.gatewayEvent(.clarifyExpire)` — dismiss only a matching `.clarify` card;
      "Question timed out" row; a non-matching id is a no-op
- [ ] write tests: single answer strips "(Recommended)"; multi sends a JSON array string;
      batch sends N requests in order with the right `question_id`s (record the sequence with
      `LockIsolated<[JSONValue]>`), dismisses after the last; batch failure on request 2 keeps
      the card and sets the banner, no third request; skip wire + row; expire matching /
      non-matching; existing `respondClarifyIgnoredWhenNoClarifyPending` still holds
- [ ] run tests - must pass before next task

### Task 6: `ClarifyCardView` forms over a bounded region

**Files:**
- Create: `HermesMobile/Sources/Features/Chat/BoundedHeightLayout.swift` (moved from
  `ApprovalCardView.swift`, no behaviour change)
- Modify: `HermesMobile/Sources/Features/Chat/ApprovalCardView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ClarifyCardView.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`isCompressibleCardPending`)
- Modify: `HermesMobileTests/ChatSnapshotTests.swift`
- Create: `HermesMobileTests/ClarifyCardLayoutTests.swift`

- [ ] move `BoundedHeightLayout` to its own file; keep its doc comments and the measured
      derivations intact; `tuist generate` so the new file is picked up
- [ ] rebuild `ClarifyCardView`: header + one scrollable region + pinned action row; forms:
      single-select rows (tap submits), multi-select checkmark rows + Submit, free-text field +
      Send, batch sections with per-question form and prefilled/✓ `lockedAnswers`, Confirm
      gated on completeness; Skip on every form; recommended badge from `ClarifyChoice.split`;
      no preselection anywhere
- [ ] `ChatView.pendingCard`: wire `respondToClarifyMulti` / `respondToClarifyBatch` /
      `skipClarify`; extend the `.layoutPriority(1)` predicate to
      `store.isCompressibleCardPending` (approval OR batch clarify) with the rationale updated
- [ ] add snapshots: `testClarifyCard_multiSelect`, `testClarifyCard_batch`,
      `testClarifyCard_recommendedBadge`, `testClarifyCard_batchWithLockedAnswers`
      (`make snapshot` twice each; pinned width + height since the region scrolls)
- [ ] add `ClarifyCardLayoutTests`: hosted `ChatView` at the shortest keyboard-up window
      with a 5-question batch — Confirm/Skip accessibility frames inside the window, region
      `contentSize.height > bounds.height`; single-select clarify still hugs its content
- [ ] update `docs/features/approvals.md` pointer text at the `ClarifyCardView is rigid`
      sentence (final edit lands in the docs task; note the change here so it isn't lost)
- [ ] run HermesKit tests and `make snapshot` - must pass before next task

### Task 7: Hydrate `pending_approval` / `pending_clarify` and clear stale cards

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/Session.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` (`applyActivate`,
  `clearStaleApproval` → `clearStaleInteraction`)
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatReductionTests.swift` (if a stale-card test lives there)

- [ ] `ActivateResponse`: decode `pendingApproval` / `pendingClarify` leniently; extend the
      memberwise init with defaults
- [ ] `applyActivate`: implement steps 1–3 of the ordering in Technical Details (present
      unless the same `requestID` already stands; approval wins over clarify; a presented
      pending approval enqueues the ack from Task 3; hint cleared whenever the payload carries
      `pendingApproval`)
- [ ] generalize `clearStaleApproval` to `clearStaleInteraction` (any card on a
      `running == false` hydrate); keep the turn-end call sites' behaviour for approvals and
      extend them to clarify/secret only where the doc says a card must not outlive its turn
      (`message.complete` / `error`)
- [ ] write hydrate tests: running + `pending_approval` presents the card (token 1) and sends
      the ack; re-hydrate with the same `request_id` leaves the token untouched; a different
      `request_id` replaces the card; running + `pending_clarify` (batch with `answers`)
      presents with `lockedAnswers`; both present → approval; not running clears a standing
      clarify/secret card; payload with `pending_approval` while the hint is armed → no
      generic card, hint consumed
- [ ] run tests - must pass before next task

### Task 8: Push-tap recovery reads back via `approval.pending`

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Modify: `HermesKit/Tests/HermesKitTests/HydrateTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift` (existing recovery tests)

- [ ] add `approvalPendingSupported: Bool` to `State` (init `true`, per slot) and
      `pendingApprovalProbeResult`; `CancelID.approvalProbe`
- [ ] replace the synthesis branch in `applyActivate` with step 4: consume the hint; if no
      card and supported → probe effect (`approval.pending {session_id}`, `cancelInFlight`);
      if unsupported → present `recoveredApprovalRequest` as today
- [ ] handle `pendingApprovalProbeResult`: success non-empty → present first + ack (only if
      still `isSending` and no card); empty → no-op; `-32601` → latch + generic card (same
      guards); other failure → `errorBanner`
- [ ] cancel the probe on `teardown` / `teardownSocketOnly` and on turn end (a late result
      must not raise a card over a finished transcript — also guarded by `isSending`)
- [ ] write tests: hint + running + no payload key → `approval.pending` sent with the live
      id; result with one approval presents it (token, ack); empty result → nothing, hint
      cleared; `-32601` → generic card and the latch; second hint on the same slot skips the
      RPC and synthesizes directly; non-running result arrival → no card; probe failure
      (non-`-32601`) → banner; existing `AppFeatureTests` recovery cases updated to the probe
      (the on-screen-arm `.foreground` drive still holds)
- [ ] run tests - must pass before next task

### Task 9: Verify acceptance criteria
- [ ] verify all requirements from Overview are implemented (request-bound respond, choices
      narrowing, ack, multi/batch/free-text/skip/expire, pending hydration, probe fallback)
- [ ] verify old-server byte-identity: the pre-change `approval.respond` / `clarify.respond`
      fixtures in the tests still pass unchanged for payloads without `request_id`/`choices`
- [ ] verify edge cases: same-`request_id` re-hydrate keeps the token; batch failure mid-way;
      expire for a non-matching id; hint armed with a payload that carries `pending_clarify`
      (approval probe still runs — a clarify is not an approval)
- [ ] run full test suite: `script -q /dev/null swift test --package-path HermesKit`
- [ ] run `make snapshot`; judge failures by render size (baseline drift is known)
- [ ] manual pass against a live v2026.8.27+ agent: approve from the phone after a socket
      drop; batch clarify from the agent; multi-select; skip; kill the socket mid-clarify and
      re-open — locked answers restored

### Task 10: [Final] Update documentation
- [ ] `docs/features/approvals.md`: rewrite "Push-tap approval recovery" around the
      `approval.pending` read-back with the generic card as the `-32601` fallback; document
      `request_id` + `all:false`, choice narrowing, the ack carve-out, the clarify forms and
      the clarify bounded region (replace the "ClarifyCardView is rigid" sentence)
- [ ] `docs/features/push-notifications.md`: point the tap-recovery paragraph at the new rule
- [ ] `docs/architecture.md` "Session re-hydration": `pending_approval` / `pending_clarify`,
      stale-card clearing, same-request no-bump
- [ ] `CLAUDE.md` approval/clarify bullet: request-bound, narrow-never-widen, probe fallback
- [ ] `README.md` feature list: multi-select and batch clarify
- [ ] comment on #97 with the server floor (v2026.8.16) and what older agents still get
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**
- Real-device check of the batch clarify card at AX3 with the keyboard up (the layout test
  pins `.large`); selection-vs-scroll precedence inside the region is a manual item, as for
  the approval card.
- Reconnect mid-batch with two answers locked on the desktop, then open the phone: the two
  show ✓, the rest are editable, Confirm sends all.

**External**
- Hermes server floor for the exact-recovery path is v2026.8.16; older agents keep today's
  generic card. Mention in the README's compatibility note if one exists at release time.
- #98 (event replay) can later drop the `approval.pending` probe on new servers in favour of
  replayed `approval.request` frames; keep the probe as the fallback either way.
