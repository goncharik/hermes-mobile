# Mid-turn prompt queuing (#66)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Composer & input"; this doc is the full contract. Design history:
`docs/plans/completed/`.

Mid-turn prompt queuing is **CLIENT-side** — the server's `queued_prompt` slot is a single
merge-only slot with NO edit/delete API (`session.interrupt` silently clears it), which is why
the desktop keeps its queue client-side too; mobile mirrors that and **never submits against a
running turn** (the server's `busy_input_mode` redirect/steer policy deliberately never engages
from mobile, and old 4009-ing agents behave identically). The one carve-out is the explicit
**Steer now** below: a `session.steer`, never a `prompt.submit`.

**Every drain submit carries `queued: true`** (desktop `fromQueue`; v0.21.6+, older agents ignore
the key). The client can be wrong about idle: an accepted steer the turn ended before delivering
(`pending_steer`), or a `queued` accept during compression, becomes the SERVER's own next turn
right after `message.complete`, the same edge the drain fires on. Without the flag the drain's
`prompt.submit` would hit that turn's default `interrupt` busy policy and cut its answer. With it
the busy path only holds the text for the turn after (`{status: "queued"}`), which consumes the
entry (`.drainedEntryHeld`: the server owns it now; its echo row stays and `isSending` stays on)
rather than re-parking or re-draining it. The slash `send`/`skill` directive of a drained
command is not flagged (its `prompt.submit` runs after a `slash.exec` round trip).

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

## Steer now

**Steer now** (desktop `steerQueuedNow`) delivers a queued entry INTO the running turn via
`session.steer {session_id, text}`, without interrupting it. The panel offers it, and the reducer
re-checks, only while `canSteerQueued` and `SteerEligibility.isSteerable(entry)`:

- **Gating.** `canSteerQueued`: `isSending && !slashExecInFlight` (a slash exec never marks the
  session running, so its steer could only be `rejected`), `steerSupported`, no steer in flight,
  `status == .ready`, no standing card (`pendingInteraction`, so the #97 card queue gates it like
  queuing and the drain), no branch create, no #98 replay read pending. `SteerEligibility`
  (desktop `isSteerableEntry`): no attachments, non-empty after trimming, not command-shaped.
- **The in-flight marker.** `steeringEntryID` marks the entry; it STAYS in `queuedPrompts` (in
  place, a spinner and "Steering…" on the row, menu inert, Delete / Edit / Send now ignored)
  until the RPC answers. The steer unparks
  the queue (a keep-it-moving intent, like Send now); a Stop while it runs parks it again and the
  result leaves that park alone.
- **The drain waits on it.** `drainQueueIfReady` requires `steeringEntryID == nil`, so a turn
  end racing the RPC never fires the entry behind it first. Every outcome clears the marker and
  calls `drainQueueIfReady`, which re-checks everything (a still-running turn, a park, a #98
  `isFoldingReplay` fold: the result never drains during a fold).
- **Accepted** is `status == "queued"` only: the entry leaves the queue and is echoed as a user
  bubble where it arrived (desktop `sealAcceptedCorrection`): a non-empty streaming row is
  sealed as live commentary (complete, never counted for read-aloud) so later deltas open a new
  row below it. The model keeps streaming the SAME segment, so its next `message.interim` /
  `message.complete` carries the whole segment: the sealed text is remembered
  (`steerSealedTexts`, desktop `interimBoundaryPending`) and cut off that one event
  (`textAfterSealedSegments`); nothing left means no new row. `message.start`, a turn error and
  an idle hydrate drop it; a running hydrate keeps it (the segment is still open).
- **Hydrate (#26 rule plus one placement rule).** The bubble is tracked in
  `liveCorrectionRowIDs`, so a running hydrate keeps it like sealed commentary, unless the
  history now carries it as one of THIS turn's trailing `display_kind: "steer"` rows (older
  user rows, an earlier identical prompt included, never match). `SessionInflight` decodes
  `inflight.corrections` / `correction_offsets`; a correction this client holds no bubble for
  (another client's steer, a cold open) gets one placed by its offset: the unsealed output
  before it is sealed above it, in the streaming row's slot among the live rows, and the rest
  seeds the streaming row below. Without usable offsets it follows the live output (desktop's
  fallback order).
- **Lost accept.** A steer whose reply timed out or whose socket dropped keeps its entry (and a
  "Couldn't steer" banner when it timed out). The entry is remembered as attempted
  (`steerAttemptedEntryIDs`); a hydrate whose turn lists its text as a correction this client
  holds no bubble for (or, once the turn ended, an idle hydrate whose last turn persisted it as a
  `steer` row) drops it from the queue, so it never drains as a second delivery. An entry
  never steered, or one the server answered (`rejected`, an error), is never dropped this way.
- **Undelivered** is everything else: `rejected` (the turn ended first; the gateway documents it
  as "queue it as a normal next prompt"), `voice_stopped`, a missing or unknown status. The entry
  stays where it was, unparked, and drains as usual.
- **Unsupported.** `-32601` (`isUnknownMethod`) or 4010 `agent does not support steer`
  (`isSteerUnsupported`, matched on the stable text) flips the per-slot, unpersisted
  `steerSupported` off silently: the action hides, the entry stays queued and unparked. Other
  errors banner (except a dropped socket) and keep the entry.
- **Heal is resume-only.** A stale live id re-resumes the stored session (no seed, never a
  `session.create`) and replays the steer once. With no stored id (a new chat, an attached or
  seeded branch #34) the steer is undelivered: a correction must never rebind the chat to a
  different session than the turn it corrects.
- **During compression** the gateway answers `queued` too, but the text went into its own
  next-turn `queued_prompt` slot, not the live turn, and `session.interrupt` clears that slot.
  The client treats it as accepted (the echo shows it sent); a Stop before the next turn loses it,
  the same as any server-queued text.
- **Accept, then Stop.** An accepted steer only buffers the text (`AIAgent._pending_steer`) until
  the next tool result. A Stop before then drops it (`AIAgent.interrupt()`): the bubble stays but
  the text never reached the model, and the entry is already gone. Same trade as compression.
- **Lost accept, live socket.** The lost-accept drop needs a hydrate before the turn ends. After a
  reconnect the replay hydrate holds the drain, so that's covered; after a 30 s timeout on a live
  socket nothing hydrates, and `message.complete` drains the entry a second time (rare; accepted).
- **Read-aloud (#74).** Steer now is not a `prompt.submit` and starts no new reply, so it does
  not stop a playing clip or stamp the barge-in latch; typing the entry into the queue already
  barged in.

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
