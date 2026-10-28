# Blocking prompts: approval, clarify, sudo, secret (#65, #97) & push-tap recovery

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Transcript & chat UI"; this doc is the full contract. Design history:
`docs/plans/completed/` (#97: `20260905-request-bound-approvals-and-clarify.md`).

Four kinds of prompt block a turn until the user answers: an approval, a clarify question, a
sudo password and a secret. Each renders as a card above the composer (`ChatView.pendingCard`)
and blocks sending until it is answered, skipped or withdrawn.

## Two wires

Hermes has delivered prompts two ways, and the app speaks both:

| | v7: server→client requests | Legacy events |
|---|---|---|
| Agents | v2026.9.14 and later (incl. v0.21.x) | v2026.9.11 and older |
| Prompt | JSON-RPC request `{id: "srq-…", method, params}` | `approval.request` / `clarify.request` / `sudo.request` / `secret.request` event |
| Answer | `request.answer {id, result}` → `{status: "ok" \| "expired"}` | `approval.respond` / `clarify.respond` / `sudo.respond` / `secret.respond` |
| Withdrawal | `request.cancel` event | none |
| Reconnect | `open_requests` replay in `session.resume` | push-tap recovered card (approvals only) |

Receiving needs no gate: one server never speaks both. The wire only matters where the app acts
on its own, in the hydrate (`ChatFeature.isServerRequestWire`): `info.desktop_contract >= 7` or a
non-empty `open_requests` means v7, anything else is legacy. `SessionInfo.desktopContract`
decodes an Int or a numeric String and is `nil` otherwise; it never throws, because a throw would
drop the whole `info`. Never gate on a version string.

## Advertisement (v7)

Since v2026.9.21 the server routes a prompt only to clients that sent `client.capabilities
{server_requests: true}`, and refuses it outright when none of the attached clients did. The
advertisement is per socket. `GatewayConnection` sends it once per connection when the
`gateway.ready` frame arrives and **holds `.ready` back until it settles or
`advertisementReadyCap` (5 s) fires**, so the reducer's first `session.resume` / `session.create`
goes out after the server knows the phone answers prompts. Frames arriving in that window are
yielded as usual. The attempt runs in a `Task`: awaiting it on the receive loop would deadlock,
since the acknowledgement arrives through that loop.

- Success stores `declines_not_shown` (v0.21.6+ sends it).
- `-32601` is silent. v2026.9.14 speaks v7 without the method, so it does NOT mean legacy.
- Any other failure yields `GatewayEvent.serverRequestsUnavailable` after `.ready` ("Couldn’t
  enable approvals and other prompts: …"). The reducer keeps it in
  `State.serverRequestsUnavailable` and `applyActivate`'s stale-banner clear restores it, so the
  banner outlives the hydrate that follows; the next `.ready` resets it. An attempt that outlives
  the cap keeps running under the 30 s request budget, and its late outcome still counts.
- No retry on the same socket. The next connect advertises again.

## Routing: the decline matrix

`GatewayConnection.handleServerRequest` routes each server request synchronously on the receive
loop; only the sends run in a `Task`.

| Method | The phone |
|---|---|
| `approval`, `clarify`, `sudo`, `secret` | yields `.serverRequest(PendingServerRequest)` at once, so a turn terminal read right after it cannot overtake the card |
| the same, params not a JSON object (`null`, missing, array, scalar) | sends that kind's skip through `request.answer` (`PendingServerRequest.malformedSkip`): `{choice: "deny"}`, `{}`, `{value: ""}` |
| the same, object params the phone cannot decode | nothing, and a `.serverRequestFailed` banner ("Couldn’t show … Answer it on another device, or stop the turn.") |
| window-owned: `terminal.read`, `preview.read`, `window.read`, `preview.act`, `tour` | sends the non-settling `4404` error frame, only once the advertisement returned `declines_not_shown: true`; otherwise nothing |
| anything else: `vault.*`, `setup_choose`, `display.install.sudo`, new methods | nothing |

Silence is deliberate. Any error response settles a request at once, which kills the card of a
desktop sharing the session, and a 4404 on a vault prompt settles it with a refusal string that
the agent hands to the password manager as the answer. The cost is that a phone-only agent waits
out that prompt's own deadline (120–300 s).

The same holds for object params the phone cannot decode: they may be a newer wire shape (upstream
reshaped clarify three times in two months) that a desktop sharing the session renders, so the
phone never denies or cancels them for everyone; only params that are not an object at all, which
no client can render, get the automatic skip. Undecodable includes an approval with no non-blank
command or description (`ApprovalRequest.hasContent`) and a `secret` naming neither a
prompt nor an env var: a blind card invites a blind answer. An empty `sudo` renders, since
v2026.9.14 sends no `command`. A failed automatic send yields `.serverRequestFailed`, which
banners without ending the turn. The 4404 frame, like every outbound frame, is encoded by
`JSONRPCRequest.wireEncoder`.

## One queue per slot

A session can hold several open requests (parallel tool calls and subagents each queue an
approval). `ChatFeature.State.serverRequests` is an ordered queue of `PendingServerRequest {id,
kind}`, oldest first, and the srq id is stored nowhere else. **While the queue is non-empty, its
head is the presented card** (`State.presentedServerRequest`). The rest wait their turn; the card
shows no "1 of N" count.

- A new id is appended; when it is the head it is raised through `present(_:)`.
- A known id (a re-delivery or a replay) is updated in place. If it is the presented card, that
  goes through **`State.refreshPresented(_:)`, the one sanctioned exception to "raise cards
  through `present(_:)`"**: same srq id only, no token bump, so the card keeps its scroll offset,
  typed text and selections.
- An answer (`ok` or `expired`), a matching `request.cancel` or turn end removes the entry, and
  `presentNextServerRequest()` raises the next head with a fresh token or dismisses the card.

## Answering

Every v7 answer is `request.answer {id, result}` through plain `gateway.send` (`wireEncoder`, the
30 s budget and a surfaced error come with it), in the shape the request arrived in:

| Request | Answer `result` | Skip |
|---|---|---|
| `approval` | `{choice: "once" \| "session" \| "deny"}` | Deny: `{choice: "deny"}` |
| `clarify` with `questions` (v0.21.6+) | `{answers: {q0: "A", q1: "[\"B\",\"C\"]", q2: "typed", q3: null}}` | `{}` (cancels the whole clarify) |
| `clarify` with a top-level `question` (v2026.9.14–.24) | `{answer: "A"}` | `{answer: ""}` |
| `sudo`, `secret` | `{value: "…"}` | `{value: ""}` |

The desktop answers with a raw response frame. `request.answer` runs the same server code and
also acknowledges, which is what lets every kind report "Already handled elsewhere". Raw frames
are used only for the 4404 decline.

**The card stays up until the server acknowledges.** `answeringServerRequestID` ignores a second
tap while an answer is in flight. The outcome arrives as `serverRequestAnswered(id:echo:_:)`; its
`AnswerEcho` carries each kind's own copy:

- `ok`: the echo row ("Approved", "Denied", the clarify answer, "Password submitted", …), then
  the next card;
- `expired`: **"Already handled elsewhere"** (another client answered first, or it timed out),
  then the next card;
- a throw or an unknown status: `errorBanner`, and the card stays answerable, because the request
  is still open server-side.

**Narrow, never widen.** The app never offers a choice the server did not list. Approve needs
`once` in `choices` (`allowsOnce`: the button hides and the reducer ignores the action without
it), "approve all" falls back to `once` without `session` (`allowsSessionChoice`), `always` is
never offered, and an empty `choices` list is permissive.

## How a card ends

- **`request.cancel`** removes the matching entry, presented or queued. A `timeout` on the
  presented card appends a "Timed out" row; an unknown id is a no-op.
- **Turn end** (`message.complete`, `.error`) clears the whole queue (`clearStalePrompts`). The
  server sends no `request.cancel` when another client answered by response frame, so turn end
  is when the phone learns of it (as the desktop does), unless its own answer comes back
  `expired` first.
- **A hydrate** reconciles the queue with the replay (next section). On v7 it never clears on
  `running == false` alone.

## Reconnect replay (v7)

`session.resume` on a live session returns `open_requests: [{id, method, params}]`, oldest first
(`ActivateResponse.openRequests`; a malformed entry is dropped, never the whole list). A cold
resume of a stored session has none. On a v7 hydrate `applyActivate` always runs
`reconcileServerRequests`, **whatever `running` says**: a `running == false` snapshot can still
have a bridge parked on an open request.

- Absence is authoritative. An id the replay does not list is dropped, and releases a stale
  `answeringServerRequestID`.
- A listed id already queued keeps its place and takes the replayed params (fresh batch-clarify
  locks), so a reordering replay never swaps the card under the user.
- A new id is appended in replay order. Unrendered or undecodable entries are not queued, and the
  reducer sends nothing for them. One raised while no client was attached never reached the live
  routing either, so it waits out its deadline unless another client answers (accepted).
- The head is refreshed in place when it is already up, and presented with a fresh token
  otherwise. A standing legacy or recovered card is replaced by the head, or dismissed by an
  empty replay.

Accepted gap: a request raised between the server building the snapshot and the app applying it
is dropped by the reconcile and comes back on the next hydrate.

**Event replay (#98) never carries a prompt.** Request frames are not stamped into the server's
event ring, so this reconcile stays the only way a prompt comes back. What the ring can hold is
`request.cancel`, and after a drop the reconnect event replay folds the gap's events BEFORE this
hydrate (`docs/architecture.md` → "Reconnect event replay"):

- A replayed `request.cancel` runs through the ordinary rules in "How a card ends": an unknown
  id is a no-op, a queued non-head id is removed silently, and the presented head is removed and
  the next head presented (a `timeout` adds a "Timed out" row, which the hydrate then wipes).
  The reconcile that follows reaches the same queue the hydrate alone would, refreshing a
  still-open next head in place (same token).
- The fold never drains the prompt queue (#66); only the hydrate's idle edge does.
- The `open_requests` copy in the `session.events.since` reply is ignored, so a card is never
  presented twice; the hydrate's list raises it.
- Legacy `*.request` events ride the ring on v2026.8.27 – v2026.9.11, but replay skips them: the
  app decodes no `*.expire`, so a prompt that expired in the gap would stand forever. Legacy
  recovery stays the push-tap card.

## Legacy wire

Agents up to v2026.9.11 get today's wire byte for byte (pinned by whole-frame tests in
`ChatInteractionTests`). The legacy events raise their card through `present(_:)`; a
`clarify.request`, `sudo.request` or `secret.request` without `request_id` stays `.unknown`.
Answers are optimistic: the card goes and the echo row is appended before the RPC. A throw
banners instead of a swallowed `try?`; for clarify, sudo and secret it also patches the row to
"Failed to send" (`legacyRespondFailed`), while an approval's row stands. Skip sends the same respond with an empty value. Turn end and a `running == false`
hydrate clear a standing approval card and the push-tap hint; legacy clarify and secret cards
are keyed by their `request_id` and stay.

Approvals answer through `approval.respond` and its `{"resolved": n}` result (`0` → "Already
handled elsewhere"). An `approval.request` event that carries the queue's `request_id` (upstream
v2026.8.16 through v2026.9.11) answers `{session_id, request_id, choice, all: false}`: the server
resolves exactly that queue entry and ignores `all` when a `request_id` is present, so the card
the user saw is the one resolved (FIFO would hit the oldest entry, while the legacy card shows
the newest). An event without one (older agents, the push-tap recovered card) keeps the FIFO
`{session_id, choice, all}`. A legacy clarify sends the raw choice text and keeps the
choices-only form (no Other row). A legacy batch clarify (`questions` plus `request_id`, even a
one-question list) answers as the desktop did: one `clarify.respond {…, question_id,
answer}` per question, in order (the bare label, `""` for a skipped question), while Skip sends
the question-less empty respond that cancels the batch.

## Clarify

`ClarifyRequest` models every shape as a `questions` list (`ClarifyQuestion {qid, question,
choices, multiSelect}`), decoded by where it arrived:

- a server request (`init(serverRequestParams:)`): a usable `questions` list → `.answers`
  (v0.21.6+, and the v2026.9.14–.24 batch; unusable entries are dropped and the rest render),
  else a top-level non-blank `question` → `.singleAnswer` (v2026.9.14–.24 single). A stray
  `request_id` is ignored;
- the legacy event (`init(legacyEvent:)`): needs `request_id` → `.legacyRespond`, with the batch's
  `questions` when it has them.

Replayed `answers` become `lockedAnswers` (a string, or `null` for a skip). Locked questions
render read-only (`isLocked`, `lockedDisplayText`) and are re-sent with the final set, where they
win over the card's answers; the phone never sends `clarify.lock`. The first of two or more
choices arrives suffixed " (Recommended)": `ClarifyChoice.split` turns that into a badge, and the
bare label is what goes out.

`ClarifyCardView` has the approval card's shape (a one-line title and a pinned action row over
one `BoundedHeightLayout` region), with the form chosen by the questions:

- one single-select question: tapping a choice submits it;
- one multi-select question: checkmark rows and Submit; the answer is a JSON-array string
  (`"[\"A\",\"B\"]"`, encoded with `wireEncoder`'s settings);
- one free-text question: a field and Send;
- several questions: one section per question, each skippable, and Confirm once every question
  is answered, skipped or locked.

Every question with choices also gets an "Other" free-text row (v7 only; the upstream tool schema
tells the model the UI adds one), sent as the typed string. Skip is on every form, and nothing is
preselected. The card sends `submitClarify(token:answers:)` with `[String: ClarifyAnswer]`, keyed by qid (`""`
for a qid-less single question): `.choices([raw])`, `.other(text)` or `.skipped`. The reducer
builds the wire text, so marker stripping and the JSON array stay in HermesKit. Form state is a
`ClarifyDraft` (a pick and Other text are exclusive; a skip keeps the edits under it), held as
view `@State` under the token key and unit-tested in `ClarifyDraftTests`. Skipping every question
one by one sends a `null` for each; the card's Skip sends `{}` and cancels the clarify. The echo
row is the answer for one question, and one `question: answer` line per question for several.

The composer stays locked behind a clarify like every other card, and Skip is the way out. The
desktop cancels the clarify and sends; here that would submit against a running turn, which #66
forbids.

Known: the v2026.9.14–.24 batch typed its answers `dict[str, str]`, and the app cannot tell it
from the v0.21.6+ shape, so a skipped question there still goes out as `null`.

## Sudo and secret

`SecretPrompt` carries the `prompt`, the sudo `command` (v2026.9.21+, redacted server-side) and
the secret's `env_var` (`envVar`); `requestID` is set only on the legacy event. `SecretCardView`
scrolls the prompt and the command or env var line in the shared
region over a pinned row of the secure field, Skip (`skipSecret`) and send; the value goes out as
typed (no trimming). Answer and skip both go through `answerSecret`. **The value never leaves the answer RPC's params**: the echo rows ("Password
submitted", "Secret skipped", …), the banners and the gateway log carry fixed copy or the prompt,
never the value, and nothing about it goes into a push.

## Push-tap approval recovery (hermes-agent #30 workaround)

An approval that fired while the socket was down is recovered from the push tap. `AppFeature`
arms a one-shot `expectsPendingApproval` hint on the target `ChatFeature.State` (via the
`pendingApprovalSessionIDs` badge set / #32 tap routing — on-screen slot, reattach, replace,
and badged-then-opened-later all covered; the **on-screen arm also drives its own
`.liveChat(.foreground)` hydrate** — never rely on the tap's scene activation racing through the
store). The hydrate (`applyActivate`) **consumes** the hint:

- **v7**: the `open_requests` replay is the recovery. The real card comes back with its command,
  and a clarify with its locks. A replay without an approval means nothing is waiting, so no
  card; the generic card is never synthesized.
- **Legacy**: a generic `ChatFeature.recoveredApprovalRequest` card (`command: nil` and an honest
  recovery `detail`) is synthesized **only when the authoritative `running` is true and no real
  card arrived**; a stopped turn drops the hint silently (no phantom card). Staleness is
  symmetric: turn end and a `running == false` hydrate clear a standing approval card and the
  hint (a card must never outlive its turn and lock the composer), and answering any approval
  clears the hint too. A real `approval.request` always overwrites the synthetic card and clears
  the hint. The recovered card has no `request_id`, so it answers through the FIFO
  `approval.respond`. Clarify has no legacy recovery (it needs the real event's `request_id`).

The **"Approve all in this session" toggle is content-gated**
(`ApprovalRequest.offersSessionApproval`, which also needs `allowsOnce && allowsSessionChoice`):
hidden on the command-less/pattern-less recovered card — a blind approve must not whitelist an
unseen danger pattern session-wide. **No push-payload change** — the generic-body privacy rule
stands.

## The approval card is a pinned button row over ONE bounded, scrollable region (#65)

**Never plain stacked `Text`.** `ApprovalCardView` sits in `ChatView`'s outer `VStack`, the
**non-scrolling** region between the greedy transcript and the composer, so when that region runs
short (long command, long `detail`, keyboard up, accessibility text size) the `VStack` compresses
the card and plain `Text` answers by **truncating with no way to reach the rest** — users had to
leave and re-enter the chat (keyboard down = more room) to read what they were approving;
`.fixedSize` alone inverts the bug and pushes Deny/Approve off screen.

**Rigid: a one-line, Dynamic-Type-clamped title and the Deny/Approve row. In the scroll, IN THIS
ORDER: the command, then `detail`, then the "approve all" toggle.** A rigid `detail` or toggle
was measured to push the buttons (and the composer) off screen at AX3/AX5 and on any phone with a
long `detail` — the rigid remainder outgrew the region on its own — so everything unbounded
scrolls; and the **order is load-bearing**, because with the title and the server-controlled
`detail` above it a 1000-char description pushed the command *entirely* below the fold at first
paint (measured: zero command pixels in the viewport), and on the shortest screen the title plus
two detail lines filled the whole floor.

The **toggle's state is mirrored on the Approve button** (`approveTitle(all:)` → "Approve all"):
the toggle is a scroll away with a long command, and a session-wide whitelist must never be
committed from a control the user cannot see as they tap.

### BoundedHeightLayout: cap, floor, reserve

The region sits in `BoundedHeightLayout` (`BoundedHeightLayout.swift`): ideal height
`min(content, cap)` — so a short card hugs its content exactly as before — and **compressible**
down to a floor, so a tight region is absorbed by the *viewport* (every byte still present and
scrollable) instead of the card over-subscribing its container. The cap is
`@ScaledMetric(relativeTo: .callout)` (base 320pt) **clamped** to
`TranscriptLayout.shortestLayoutHeight * 0.6`; the floor (96pt) is deliberately unscaled and is
**derived from what must be readable**: `commandPadding` + three `.callout` lines + the fade ramp,
i.e. on the shortest screen with the keyboard up (where the region lands exactly on it) three full
lines *of the command* are legible above the ramp **at `.large`**. That three-line contract is a
`.large` one and **degrades with Dynamic Type** — the band is a constant 64pt, ~1.3 AX3 lines and
under one at AX5 (pinned by `testTheFloorsReadableBandDegradesWithDynamicType`); scaling the floor
is not available, since three AX5 lines are ~210pt of floor and reserving that on the shortest
keyboard-up screen is measurably what pushes Deny/Approve out.

**Raising a card hands the keyboard back** — `ChatView` passes `pendingInteractionToken` to
`ComposerTextView.blockingCardToken`, which resigns first responder once per *raised* card (keyed
on the token, because `ChatView` re-renders on every streamed token and an unkeyed resign makes
the field untappable). It is a **resign, not a disable**: `canSend` is already false while a card
stands, but the field stays live so a draft is still possible — do not write "the composer is
disabled", it never was. That is the cheapest room the fix buys, since the keyboard is what
shrinks the region the card lives in (#65's own root cause: leaving and re-entering the chat
"fixed" the truncation because the keyboard was down). A **landscape** phone whose composer is
deliberately re-focused has ~100pt of fixed region and cannot hold the card (~250pt compressed)
*and* the composer — true before this change too; there the Deny/Approve row stays inside the
window (asserted on the buttons' own **accessibility frames**, the only place UIKit publishes
where a SwiftUI control landed — the hosted scroll view reports a height its content is not
painted at once the card over-subscribes) and the composer is what goes under the keyboard.

**`ChatView` gives the card `.layoutPriority(1)`** (at the `VStack` call site — a trait written
inside `pendingCard`'s `@ViewBuilder` branch does not reach the stack): without it the stack
offers each child `remaining / remainingCount` in flexibility order, the card is less flexible
than the transcript, and the region collapses onto its floor with the keyboard up (measured on an
iPhone 15: its floor, 96pt, without the priority vs 155pt with it — 88 and 227 when first
measured, before the floor was raised and the region started handing a 44pt reserve back). It is
**scoped to approvals and multi-question clarify** (`State.isCompressibleCardPending`) — a
one-question clarify card and the secret card are short forms whose region hugs them, so
priority there only blanks the transcript (measured on the old rigid clarify card:
160pt → 13pt). And because a priority-1 child is offered everything the others do not strictly
need — the greedy transcript's minimum is 0 — the region **hands a fixed 44pt of its offer back**
(`BoundedHeightLayout.reserve`, floor-outranked): without it the transcript measured **0pt** on
every phone, i.e. the decision was made with no visible context. The reserve is **absolute, not a
fraction** — a proportional one scales with the container and so kept cutting a region that had
room to fit (at a 320pt offer with 320pt of content it gave back 80pt, about four command lines,
that nothing had asked for).

The bottom fade is driven by **live scroll geometry** (`hasBottomOverflow`, mirroring #59's table
fade), never by the measured content height (a measurement-keyed fade never clears, leaving the
last line permanently ramped to transparent), and its ramp is a **quarter of the viewport capped
at 24pt** — a constant ramp is fine against `MarkdownTableView`'s always-screen-wide edge but
would tint most of a squeezed region.

### The clarify and secret cards share the region

Every card's region is one `BoundedScrollRegion` (`BoundedHeightLayout.swift`) with the approval
card's cap, floor and fade: the rigid chrome around it (a one-line title, one pinned row) is the
same size, so the same derivations hold. On the clarify card all questions, choices and Other rows
scroll; on the secret card the prompt and command / env var line do. The 44pt reserve applies only
to the multi-question clarify card, the one given layout priority.

### The pendingInteractionToken

**Every** card — approval, clarify, secret — is keyed on the reducer's monotonic
**`pendingInteractionToken`** (applied to `pendingCard` at the call site, not inside one
`@ViewBuilder` branch, so the clarify/secret shape gets it too: a secret prompt replacing another
would otherwise carry the typed password over): one card overwrites another without passing
through nil, a reused view carries the previous scroll offset, "Approve all" toggle, typed text
or clarify selections into the next one, and two back-to-back requests can be *equal* (an agent
retrying the same command), which a value-derived id cannot tell apart. The token is `public
internal(set)` and bumped only by `State.present(_:)` — **raise a card through `present`, never by
assigning `pendingInteraction`**, which is `public internal(set)` for the same reason (outside
HermesKit there is no way to raise one without its token; dismissal stays a plain `= nil`). The
one exception is `State.refreshPresented(_:)`, which swaps in a re-delivered payload for the SAME
srq id and deliberately keeps the token, so the user's edits survive a replay.

The recovered card (`command == nil`) renders no command; its region hugs the recovery copy. The
measured derivations — why the layout probes its subview with the height **unspecified** (a
`ScrollView` handed a concrete proposal swallows it whole; unspecified, it reports its content's
ideal), the ceiling arithmetic, the `ViewThatFits` rejection — live on `scrollableContent` /
`BoundedHeightLayout`; keep them there.

### What the tests guard

Guarded by `HermesMobileTests/ApprovalCardLayoutTests.swift`, which hosts **the real `ChatView`**
at keyboard-up window sizes (the card's own arithmetic being right does not mean the stack
*gives* it room — that is exactly how the first take shipped a collapsed region) as well as the
card alone. Its line-count floors are measured on the **command's own painted band** (the tinted
`secondarySystemBackground` block, read out of a render of the region's layer, contiguous from
the top of the viewport) — **never** on the viewport's height, which since the chrome shares the
scroll is satisfied entirely by header and detail lines: that is exactly how a region showing
*zero* lines of command passed a "three lines" assertion. Plus the `ChatSnapshotTests` approval
baselines, whose load-bearing part is the card's **rendered size** (the collapsed-ideal
regression showed up as 1170×553 against 1170×611 — a size mismatch anti-aliasing drift cannot
produce). `HermesMobileTests/ClarifyCardLayoutTests.swift` does the same for clarify: five
questions at the shortest keyboard-up window (320×352) keep Skip / Confirm inside the window with
a scrolling region, at 393×516 the region outranks the transcript but leaves it a row, and a
single-question card hugs its content. The `testClarifyCard_*`, `testSudoCard_*` and
`testSecretCard_*` snapshots cover the forms. Selection-vs-scroll gesture precedence inside the
region is a **manual-check item**, not a tested contract (same caveat family as #59's table
cells).
