# Mid-turn prompt queuing (#66)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Composer & input"; this doc is the full contract. Design history:
`docs/plans/completed/`.

Mid-turn prompt queuing is **CLIENT-side** — the server's `queued_prompt` slot is a single
merge-only slot with NO edit/delete API (`session.interrupt` silently clears it), which is why
the desktop keeps its queue client-side too; mobile mirrors that and **never submits against a
running turn** (the server's `busy_input_mode` redirect/steer policy deliberately never engages
from mobile, and old 4009-ing agents behave identically).

## Queuing

`.composerSubmitted` while `isSending || slashExecInFlight` freezes the draft (text + staged
attachments) into `queuedPrompts` (gated by `canQueue` — same gates as `canSend` minus the two
turn locks); the composer's Stop shows only while `isSending && !canQueue`, so typing brings the
send arrow back and a blocking card (which suppresses queuing) brings Stop back.

## The two helpers

**Everything funnels through two helpers**: `submitDraft` (the ONE submit pipeline — attachment
upload, slash routing, #17 heal — shared by the idle composer path, byte-identical, and the
drain via `fromQueue:` which must never touch the live composer) and `drainQueueIfReady`
(head-only, one turn per entry, re-checks every precondition; drain edges = `message.complete`,
a card leaving on an idle turn (`request.cancel`), an idle-confirming hydrate in
`applyActivate` — which covers `.gatewayClosed` finalization and the post-slash refresh — and
Send-now's post-interrupt `.maybeDrainQueue` re-check). A reconnect event replay fold (#98) is
never a drain or park edge: its `message.complete` / `request.cancel` / `.error` describe the
past, so `isFoldingReplay` makes them no-ops until the hydrate's `running` says the turn is idle
(`docs/architecture.md` → "Reconnect event replay").

**The drain never barges in on read-aloud (#74).** It fires on the same live `message.complete`
that starts auto-speak, so it must not cut the reply it just triggered: only USER submits (the
idle send, the mid-turn queue append) and the mic silence a clip and stamp the `interrupted`
latch. But **every regular `prompt.submit` built by `submitDraft` consumes the latch**,
`fromQueue:` included, so a prompt queued while a clip played carries `interrupted: true` when it
drains (within the 120 s TTL). Details: `docs/features/read-aloud.md` → "Barge-in latch".

## Parking

Manual Stop and turn `.error` park (`isQueueParked`) — desktop park-on-explicit-stop parity, and
no burning the queue against a failing server; a FAILED drain re-parks the entry at the head and
removes its optimistic echo row (`drainingEntry`/`drainingRowID`; a queued message is never
silently lost and never shows twice), while `message.start` / turn terminals /
`.attachmentsSubmitted` / the slash terminals consume it.

## Send now & edit

**Send now = interrupt-then-send** (promote to head, `sendNowArmed` one-shot override that also
survives the interrupted turn's `.error` terminal; during a slash exec there is no interrupt —
the exec's terminal drains). **Edit requires an empty composer** (reducer guard authoritative;
the panel's menu item mirrors it).

## Panel & lifetime

The `QueuedPromptsPanel` pins ABOVE the composer (above `SlashSuggestionPanel`) — deliberately
NOT transcript rows, so wholesale hydrates can't wipe or duplicate entries — hugging ≤3 rows and
scrolling at a fixed `@ScaledMetric` height beyond (#65's non-scrolling-region rules; fixed
rather than `min(content, cap)` because a `ScrollView` swallows concrete height proposals).

**The queue is in-memory only** (survives navigation/backgrounding via the live-chat slot; dies
with the process — same lifetime as an unsent draft; snapshot persistence is an explicit
non-goal and attachment bytes must never reach GRDB), so **`AppFeature` keeps a slot with
`hasQueuedWork` alive** — both the idle-pop and the detached turn-end teardowns check it; a
queue parked while detached keeps the slot indefinitely (accepted; bounded by re-open/archive).
