# Model & reasoning picker (#81)

The short rules live in `CLAUDE.md` → "Composer & input"; this doc is the full contract.
Design history: `docs/plans/completed/`.

## The picker path

The composer's `model · effort` chip is the ONE affordance for both settings. Tapping it sends
`.modelChipTapped` → a session-scoped `model.options` RPC → `State.ModelPicker` →
`ModelPickerSheet` → `.modelSelected` / `.reasoningSelected` → the private
`configSet(key:value:previousValue:…)` → `config.set {session_id, key, value}` wrapped in the #17
session-not-found heal (re-resume + a single replay, `CLAUDE.md` → "Gateway & session lifecycle").

A model selection carries the picker section's provider: the row tap passes
`ModelOptions.Provider.selectionSlug` — the SLUG only, nil when there is none — and the reducer
appends it to the wire value as `"<model> --provider <slug>"` — desktop parity
(`use-model-controls.ts`, which also sends `provider.slug` with no fallback). Without it the
gateway guesses the provider from the model id alone, so an `openai/…` row listed under
OpenRouter routes to the direct OpenAI provider and fails on its key ("No usable credentials
found for provider 'openai-api'"). A nil slug (no section context) stays a bare model id and
the gateway's own detection ladder routes it, exactly as before. The display name is never
used: the gateway's flag parser splits the `--provider` value on whitespace and its provider
resolver doesn't match display names, so a name like "Ollama Cloud" would parse as provider
`Ollama`, model `… Cloud` — worse than a bare id.

One behavioral note, same as desktop: with `--provider` present, a switch never persists to
`config.yaml` when a default model is already configured — the gateway's
`resolve_persist_behavior` treats provider-bound picks as exploratory and skips the
`model.persist_switch_by_default` check. Bare-id picks honor that config key (a pick without
`--provider` persists when it is `true`); provider-bound picks are session-only unless the
desktop sends an explicit `--global`, which no client picker does today.

Selection is **optimistic and server-reconciled**: the reducer writes `state.model` /
`state.reasoningEffort` before the RPC, and success is deliberately fire-and-forget — the gateway
emits `session.info` after a successful `config.set` and `.sessionInfo` already reconciles both
fields, so there is no success action to handle. Selection is guarded on `!isSending` and a live
session id (the server answers 4009 mid-turn); the sheet mirrors that by disabling every row while
busy and showing a "Finish or stop the current turn to switch models." note.

Provider rendering follows the usual gate-by-capability idiom: `orderedProviders` lists configured
providers first and unconfigured ones disabled with the server's `warning` hint (they can't be set
up from mobile), and `supportsReasoning(_:)` hides the effort rows for a model whose capability map
says `reasoning: false` — unknown models default to `?? true`, so the control is never hidden on a
guess.

### Search

The sheet has a `.searchable` field (drawer placement, always visible) that filters in place without
collapsing the provider grouping. `ModelOptions.filteredProviders(matching:)` — pure and unit-tested,
the view stays thin — keeps a provider section whose NAME matches the query (all of its models stay),
else keeps only the models whose name matches, dropping a provider left with no matches. An empty or
whitespace-only query returns the full `orderedProviders` unchanged. Matching is case- and
diacritic-insensitive substring (`"dee"` matches `deepseek-…`), so a user with many providers/models
can jump straight to one instead of scrolling. Zero matches shows a `ContentUnavailableView.search`.
Because filtering keeps sections intact, identical model names across providers stay unambiguous —
the section header disambiguates.

## The scale is always full — the server clamps, the client offers

`ModelOptions.reasoningEfforts` mirrors `hermes_constants.VALID_REASONING_EFFORTS` verbatim with
`none` first (`parse_reasoning_effort` accepts it too): `none, minimal, low, medium, high, xhigh,
max, ultra`. `max`/`ultra` were added upstream on 2026-07-12 (#62650).

**The client offers the full ladder on every reasoning-capable model and never filters by model.**
The transports clamp per provider **on the wire** (gpt-5.6 maps `ultra`→`max`, xAI tops out at
`high`, OpenAI-compatible tops out at `max`), and `hermes_cli/inventory.py::_apply_capabilities`
**deliberately does not forward per-model `supported_efforts`** because it under-reports — there is
no server-published list to filter against, so a client-side per-model filter would only invent
restrictions the server doesn't have. Consequence, and it is the intended behaviour (desktop does
the same): picking `ultra` on a model that clamps leaves the chip reading `ultra` while the turn
runs at the clamped level. Labels are the raw level ids in both chip and sheet — no prettified
`XHigh`/`Ultra` forms.

## The capability gate is reactive, not a probe

Every other gate in the app flips on a `-32601` / REST 404. This one can't: a pre-#62650 gateway
**knows** `config.set` and rejects the *value*. `tui_gateway/server.py`'s `config.set` handler runs
`parse_reasoning_effort(value)`, gets `None`, and answers `_err(rid, 4002, "unknown reasoning
value: <v>")` — a server error, not an unknown method. `InboundFrame` keeps only the error message
and not the code, so `GatewayError.isUnknownReasoningValue` matches the server's stable text — the
same contract, and the same fragility caveat, as `isUnknownMethod`.

One such verdict latches `ChatFeature.State.extendedReasoningSupported = false`, and
`ModelOptions.offeredEfforts(extendedSupported:)` — the ONE filter the sheet iterates, pure and
unit-tested in HermesKit so the view stays thin — drops exactly `max`/`ultra` with the remaining
order preserved.

**The latch is per chat slot and unpersisted**, the same lifetime as `commandsUnsupported`: it is
not in `ChatSnapshotClient` even though the chip's `reasoningEffort` is cached there, and it is
`true` again in a fresh slot's `init`. That is what makes an agent upgrade free — the next chat
re-offers the levels with no re-probe logic. The accepted cost is bounded staleness: a latched slot
that outlives an agent upgrade keeps hiding `max`/`ultra` until that chat is torn down.

## One failure path for both keys

`configSet` used to swallow everything with `_ = try? await …`, leaving a rejected change as a
lying chip. A failure that survives the heal's single replay now becomes
`.configSetFailed(key:value:previousValue:error:)` — ONE action serving both `model` and
`reasoning` (a non-`GatewayError` maps to `.disconnected`, the same fallback the `model.options`
fetch uses). The reduction is:

- **Rollback, unconditionally, by key** — `state.model` / `state.reasoningEffort` back to the last
  SERVER-confirmed value, never to a still-unconfirmed pick: `State.pendingConfigRollback` holds it
  per key, written on the first pick of a run and dropped again by the rollback or by the next
  `session.info` / hydrate carrying that key (the next authoritative `session.info` wins again
  anyway). Only the newest pick per key can roll back: `configSet` is
  `.cancellable(id: CancelID.configSet(key), cancelInFlight: true)`, so a superseded request never
  reaches `.configSetFailed`. Cancelling the effect does not recall an already-transmitted frame —
  accepted, because the gateway's WS reader awaits each `dispatch` before reading the next frame and
  `config.set` is not in its `_LONG_HANDLERS` pool set, so same-socket `config.set`s apply in send
  order and the newest pick is what the server (and its trailing `session.info`) ends up holding.
- **Latch only on the capability verdict**: `key == "reasoning" && error.isUnknownReasoningValue`.
  Transport failures and every other server error (a mid-turn 4009 included) roll back and banner
  but **never latch** — a transport failure is not a capability verdict, the same rule that keeps a
  launch connection failure off the credentials path (#62).
- **Banner**: the latch case names the rejected value (`This agent doesn’t support "<value>"
  reasoning.`); otherwise `Couldn’t change <key>: <message>`. The same text is mirrored into
  `ModelPicker.applyError` — `errorBanner` alone would sit behind the presented sheet — where it
  renders as an inline row above a still-usable list (never the `error` ContentUnavailableView,
  which is the `model.options` LOAD failure). The next pick clears both.
- **No `isSending` / `activity` change** — a config change is not a turn. The sheet stays open and
  the row deselects under the inline error (desktop parity: `model-menu-panel.tsx`'s
  `patchReasoning` rolls back and toasts).

## `/reasoning` stays off the slash catalog — on purpose

There is deliberately no typed reasoning command. `/reasoning` is on `mobileHiddenCommands` because
the gateway runs worker-routed commands in a separate subprocess and doesn't mirror that one back
onto the live session — it would report success while this session stayed untouched; the full
hide-list rationale is in `docs/features/slash-commands.md`. Typed anyway, it falls through to plain
`prompt.submit` like any hidden command. The chip is the affordance.

Also declined for mobile (brainstormed, YAGNI): the desktop's separate Thinking on/off switch and
`can_disable_reasoning` (`none` already sits at the bottom of the ladder).
