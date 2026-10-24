# Approval cards: layout (#65) & push-tap recovery (#30 workaround)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Transcript & chat UI"; this doc is the full contract. Design history:
`docs/plans/completed/`.

## Push-tap approval recovery (hermes-agent #30 workaround)

A lost `approval.request` (socket down when it fired) is recovered from the approval push tap:
`AppFeature` arms a one-shot `expectsPendingApproval` hint on the target `ChatFeature.State` (via
the `pendingApprovalSessionIDs` badge set / #32 tap routing — on-screen slot, reattach, replace,
and badged-then-opened-later all covered; the **on-screen arm also drives its own
`.liveChat(.foreground)` hydrate** — never rely on the tap's scene activation racing through the
store); hydrate (`applyActivate`) **consumes** the hint and synthesizes a generic
`ChatFeature.recoveredApprovalRequest` card (`command: nil` + honest recovery `detail`) **only
when the authoritative `running` is true and no real `pendingInteraction` arrived** — a stopped
turn drops it silently (no phantom card).

**Staleness is symmetric**: turn-end (`message.complete`/`error`) and a `running == false`
hydrate clear any standing `.approval` card + the hint (a card must never outlive its turn and
lock the composer), and answering any approval clears the hint too. A real `approval.request`
always overwrites the synthetic card AND clears the hint.

Approvals are server-request-bound when delivered through the WebSocket JSON-RPC gateway. The
server sends an `approval` request with a transport request id; the card preserves that id and
answers through `request.answer {id, result: {choice}}`. The server returns `status: "ok"` when it
was handled and `status: "expired"` when another client already handled or the request timed out;
the latter patches the optimistic status row to **"Already handled elsewhere"**. Older event-based
approvals continue to use `approval.respond` and its `{"resolved": n}` result for compatibility.
RPC failures surface through `errorBanner` (no swallowed `try?`).

Once the phone advertises server requests, a phone-only session may receive unsupported prompt kinds
such as clarify, sudo, secret, or vault requests. The phone intentionally leaves those requests
untouched for another attached client, so a phone-only agent can wait until the server-side prompt
deadline rather than fail immediately. Support for those prompt kinds is part of the #97 follow-up.

The legacy push-tap recovery path remains compatible: a recovered card has no transport request id,
so it answers through the FIFO `approval.respond` path; the server withdraws the corresponding
server-side request as part of that compatibility flow.

The phone advertises `client.capabilities {server_requests: true}` after the gateway is ready.
Approval requests are rendered locally. Unsupported server requests are intentionally left alone so
another attached client can handle them. The phone sends the non-settling `4404` decline only for
window-owned methods (`terminal.read`, `preview.read`, `window.read`, `preview.act`, `tour`) when
the backend advertises `declines_not_shown: true`. It never declines `vault.*`, `setup_choose`,
`display.install.sudo`, or the other prompt kinds that are not yet rendered here. A malformed
`approval` payload is answered with `{choice: "deny"}` so the agent is not left waiting.

The **"Approve all in this session" toggle is content-gated**
(`ApprovalRequest.offersSessionApproval`): hidden on the command-less/pattern-less recovered
card — a blind approve must not whitelist an unseen danger pattern session-wide. **No
push-payload change** — the generic-body privacy rule stands; composes with #30 (a re-surfaced
real event just replaces the generic card). Clarify recovery is out of scope (needs the real
event's `request_id`).

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

The region sits in `BoundedHeightLayout`: ideal height `min(content, cap)` — so a short card hugs
its content exactly as before — and **compressible** down to a floor, so a tight region is
absorbed by the *viewport* (every byte still present and scrollable) instead of the card
over-subscribing its container. The cap is `@ScaledMetric(relativeTo: .callout)` (base 320pt)
**clamped** to `TranscriptLayout.shortestLayoutHeight * 0.6`; the floor (96pt) is deliberately
unscaled and is **derived from what must be readable**: `commandPadding` + three `.callout` lines
+ the fade ramp, i.e. on the shortest screen with the keyboard up (where the region lands exactly
on it) three full lines *of the command* are legible above the ramp **at `.large`**. That
three-line contract is a `.large` one and **degrades with Dynamic Type** — the band is a constant
64pt, ~1.3 AX3 lines and under one at AX5 (pinned by
`testTheFloorsReadableBandDegradesWithDynamicType`); scaling the floor is not available, since
three AX5 lines are ~210pt of floor and reserving that on the shortest keyboard-up screen is
measurably what pushes Deny/Approve out.

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
**scoped to `.approval`** (`State.isApprovalPending`) — `ClarifyCardView` is rigid stacked
content that cannot use the extra room, so priority there only blanks the transcript (measured
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

### The pendingInteractionToken

**Every** card — approval, clarify, secret — is keyed on the reducer's monotonic
**`pendingInteractionToken`** (applied to `pendingCard` at the call site, not inside one
`@ViewBuilder` branch, so the clarify/secret shape gets it too: a secret prompt replacing another
would otherwise carry the typed password over): one card overwrites another without passing
through nil, a reused view carries the previous scroll offset, "Approve all" toggle or typed text
into the next one, and two back-to-back requests can be *equal* (an agent retrying the same
command), which a value-derived id cannot tell apart. The token is `public internal(set)` and
bumped only by `State.present(_:)` — **raise a card through `present`, never by assigning
`pendingInteraction`**, which is `public internal(set)` for the same reason (outside HermesKit
there is no way to raise one without its token; dismissal stays a plain `= nil`).

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
produce). Selection-vs-scroll gesture precedence inside the region is a **manual-check item**,
not a tested contract (same caveat family as #59's table cells).
