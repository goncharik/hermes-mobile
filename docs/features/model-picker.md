# Model & reasoning picker (#81, redesigned #130)

The short rules live in `CLAUDE.md` → "Composer & input"; this doc is the full contract.
Design history: `docs/plans/completed/`. The #130 redesign follows the desktop's
`model-catalog-menu.tsx` (cards, current-row match, scroll-to-current),
`store/provider-collapse.ts` and `store/favorite-models.ts`.

## The picker path

The composer's `model · effort` chip is the ONE affordance for both settings. Tapping it sends
`.modelChipTapped`, which (with a live session id) presents the `ModelPickerFeature` child —
`@Presents var modelPicker` + `.ifLet`, the same shape as `filePreview`. The sheet's `.task`
loads the picker prefs and fetches `model.options`; a row tap or effort tap goes out as a
`Delegate` action (`.modelSelected(model:provider:)` / `.reasoningSelected`) to `ChatFeature`'s
private `selectModel` / `selectReasoning` → `configSet(key:value:previousValue:…)` →
`config.set {session_id, key, value}` wrapped in the #17 session-not-found heal (re-resume + a
single replay, `CLAUDE.md` → "Gateway & session lifecycle"). Done dismisses via
`@Dependency(\.dismiss)`.

### Who owns what

- **`ModelPickerFeature`** owns only the sheet's own state: the `model.options` load
  (`isLoading` / `options` / `error`), the inline `applyError`, and the two device-local prefs
  (`collapsedProviders`, `favorites`). Collapse and star toggles are display-only, so they work
  mid-turn too.
- **`ChatFeature`** owns selection: it mutates `model` / `reasoningEffort` /
  `pendingConfigRollback` and runs `config.set` inside the heal, so its guards decide. It also
  writes the child's `applyError` and moves `options.currentProvider` with an optimistic pick
  (below).
- **The view's display inputs** the chat owns — current model, current effort, `isBusy`,
  `extendedReasoningSupported` — are passed by `ChatView` as plain parameters. One source of
  truth, nothing synced into the child.
- **`ModelPickerLayout`** (pure, HermesKit, unit-tested) derives the sections, row ids and the
  scroll target from `(options, favorites, collapsedProviders, query, currentModel)`.
  `ModelPickerSheet` only iterates it.

### The fetch: configured providers only

`model.options` is sent as `{session_id, explicit_only: true}` — desktop `model-options.ts`
parity — so the gateway lists only providers the user explicitly configured instead of every
provider it knows (an OpenRouter or Cursor catalog was the #130 complaint). Older gateways read
params via `params.get` and simply ignore the flag. A re-fired `.task` never refetches a loaded
list or clears a shown load error. A load failure (`.server("Malformed…")` for an undecodable
result, `.disconnected` for a non-`GatewayError`) is the full-sheet `ContentUnavailableView`.

Upstream `hermes_cli/inventory.py` keeps the CURRENT provider in the list with
`authenticated: false` + a `warning` once its credentials are gone. That card (like any
unconfigured provider) has no selectable rows: the sheet renders its `warning` as a disabled
lock row, and it can't be fixed from mobile.

### Provider routing on a pick

A model selection carries the card's provider: the row tap passes
`ModelOptions.Provider.selectionSlug` — the SLUG only, nil when there is none — and the reducer
appends it to the wire value as `"<model> --provider <slug>"` — desktop parity
(`use-model-controls.ts`, which also sends `provider.slug` with no fallback). Without it the
gateway guesses the provider from the model id alone, so an `openai/…` row listed under
OpenRouter routes to the direct OpenAI provider and fails on its key ("No usable credentials
found for provider 'openai-api'"). A nil slug (no section context) stays a bare model id and
the gateway's own detection ladder routes it, exactly as before. The display name is never
used: the gateway's flag parser splits the `--provider` value on whitespace and its provider
resolver doesn't match display names, so a name like "Ollama Cloud" would parse as provider
`Ollama`, model `… Cloud` — worse than a bare id. Favorites rows route through the same slug.

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
session id (the server answers 4009 mid-turn); the sheet mirrors that by disabling the model rows
and the Options card's Reasoning row while busy and showing a "Finish or stop the current turn
to switch models." note (the effort page has its own note and disables its rows). Stars and
collapse chevrons stay live.

### Which row is current

The payload's top-level `provider` decodes leniently into `ModelOptions.currentProvider` (blank →
nil). Upstream fills it with `ctx.current_provider` — a provider ID, i.e. a row's `slug`, never
its display name — except for custom providers, which report `custom:<key>` while the row's slug
is the bare key; rows therefore decode `aliases`. `ModelOptions.isCurrent(model:in:currentModel:)`
matches on `(provider, model)` when `currentProvider` is present, with the provider half via
`Provider.matches(providerID:)` (slug, name or alias — desktop `catalogProviderMatches`), so the
same model id under two providers checks only the active one. A `currentProvider` that matches no
row marks nothing current (desktop `rowIsCurrent` parity, no model-only fallback). Without the
field (an older gateway) the match is on the model name alone, the pre-#130 behaviour.

`currentModel` is a parameter because the chat's optimistic pick is the display truth. The
provider half follows the pick too: `selectModel` sets the child's `options.currentProvider` to
the picked slug (`applyOptimisticModelPick`; a nil slug falls back to model-only), a rejected
model pick restores the provider the server last reported (`rollBackModelPick`, captured on the
first pick of a run like `pendingConfigRollback`), and a `session.info` carrying the model
confirms it. Without this a cross-provider pick would check no row until the sheet reopened.

## The sheet layout

Not searching, `ModelPickerLayout` produces, in order:

- **Options card** — iff the current model supports reasoning (`supportsReasoning(_:)`: a
  capability map `reasoning: false` hides it; unknown models default to `?? true`, so it is
  never hidden on a guess). One `Reasoning` row with the current effort trailing ("Default"
  when the chat has none) and a chevron. It pushes `ReasoningEffortList`
  (`navigationDestination(isPresented:)`, view-local presentation): the offered efforts with a
  checkmark on the current one; a tap sends `.effortRowTapped` and pops. This replaces the
  eight inline effort rows.
- **Favorites card** — iff any starred `(provider, model)` resolves to a model a CONFIGURED
  provider offers. Star order. Stale favorites (provider gone or unconfigured, model retired)
  and duplicates yield no row but stay persisted for when they come back — desktop
  `resolveFavoriteRows`; nothing is pruned. Every row shows its provider name as a caption iff
  the resolved favorites span more than one provider.
- **One card per provider**, in `orderedProviders` order (configured first). Favorited models
  are removed from their card so nothing is listed twice; a configured provider whose every
  model is favorited drops its card entirely (desktop `groupModels`). Each model row has a
  trailing star button (`star` / `star.fill`, "Add to / Remove from favorites").

Row ids are `fav::<providerID>::<model>` (Favorites) and `<providerID>::<model>`; a card header is
`header::<providerID>`. `providerID` is `ModelOptions.Provider.id` (`slug ?? name`) everywhere —
favorites, collapse and ids share it.

### Collapse

Each provider header is a button: name, rotating chevron, and — when collapsed — the model count
plus the current model's name and a checkmark if the current row lives in that card (a favorited
current lives in Favorites, so its card doesn't claim it). Cards default to expanded (desktop
`provider-collapse.ts`); collapsed ids naming no listed provider are ignored. Collapse and star
toggles animate with `.snappy`, or not at all under Reduce Motion. VoiceOver: the header carries
`.isHeader`, a Collapsed/Expanded value and an Expand/Collapse hint.

### Search

`.searchable(prompt: "Search models")` with default placement (iOS 26 puts it at the bottom on
iPhone; iOS 18 keeps the drawer). The query is view-local `@State` — internal only so a snapshot
can seed it. A non-blank query switches the layout to search mode: no Options card, no Favorites
card, every card expanded regardless of the collapse pref, favorited models kept in their card
with a filled star, and no scroll target. Rows come from `ModelOptions.filteredProviders(matching:)`
(pure, unit-tested): a provider whose NAME matches keeps all its models, else only the models whose
name matches, and a provider left with none is dropped. Matching is case- and diacritic-insensitive
substring (`"dee"` matches `deepseek-…`); an empty or whitespace-only query is the normal layout.
Zero matches shows `ContentUnavailableView.search`. Cards stay intact, so identical model names
across providers stay unambiguous.

### Centering

On open the list scrolls ONCE to `layout.scrollTarget`, anchored `.center`, from the list's
`.task` behind a `@State hasCentered` guard — never again after the user scrolls, collapses a card
or pops back from the effort page. The target chain: the current model's Favorites row → its row
in an expanded card → its collapsed card's header → a lost-credential current provider's header
(the current provider matches a non-selectable card) → nil (current model not listed). With the
model-only fallback the first match in display order wins. The derivation is unit-tested; the
scroll itself is a manual device check.

### Persistence

Both prefs live in `PreferencesClient`: `hermes.model-picker.collapsed-providers` (a sorted
`[String]` of provider ids, loaded as a `Set`) and `hermes.model-picker.favorite-models` (JSON
`[FavoriteModel]` — `{providerID, model}`; undecodable data reads as `[]`). Saving an empty value
removes the key. They are device-global, not per profile or account, and loaded on the child's
first `.task` of a presentation. Every logout (`AppFeature` logout + reauth quit,
`SettingsFeature` clear token) calls `clearModelPickerPrefs()`; a different-user re-auth's
`clearIdentityScopedPrefs` deliberately leaves them, like the read-aloud toggle.

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
runs at the clamped level. Labels are the raw level ids in the chip, the Reasoning row and the
effort page — no prettified `XHigh`/`Ultra` forms.

## The capability gate is reactive, not a probe

Every other gate in the app flips on a `-32601` / REST 404. This one can't: a pre-#62650 gateway
**knows** `config.set` and rejects the *value*. `tui_gateway/server.py`'s `config.set` handler runs
`parse_reasoning_effort(value)`, gets `None`, and answers `_err(rid, 4002, "unknown reasoning
value: <v>")` — a server error, not an unknown method. `InboundFrame` keeps only the error message
and not the code, so `GatewayError.isUnknownReasoningValue` matches the server's stable text — the
same contract, and the same fragility caveat, as `isUnknownMethod`.

One such verdict latches `ChatFeature.State.extendedReasoningSupported = false`, and
`ModelOptions.offeredEfforts(extendedSupported:)` — the ONE filter the effort page iterates, pure
and unit-tested in HermesKit so the view stays thin — drops exactly `max`/`ultra` with the
remaining order preserved.

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
  anyway). A rejected model pick also restores the sheet's current provider. Only the newest pick
  per key can roll back: `configSet` is
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
  `ModelPickerFeature.State.applyError` — `errorBanner` alone would sit behind the presented sheet —
  where it renders as an inline row above a still-usable list (never the `error`
  ContentUnavailableView, which is the `model.options` LOAD failure). The next pick clears both.
- **No `isSending` / `activity` change** — a config change is not a turn. The sheet stays open and
  the row deselects under the inline error (desktop parity: `model-menu-panel.tsx`'s
  `patchReasoning` rolls back and toasts).

## `/reasoning` stays off the slash catalog — on purpose

There is deliberately no typed reasoning command. `/reasoning` is on `mobileHiddenCommands` because
the gateway runs worker-routed commands in a separate subprocess and doesn't mirror that one back
onto the live session — it would report success while this session stayed untouched; the full
hide-list rationale is in `docs/features/slash-commands.md`. Typed anyway, it falls through to plain
`prompt.submit` like any hidden command. The chip is the affordance.

## Out of scope

Declined for mobile (brainstormed, YAGNI): the desktop's separate Thinking on/off switch and
`can_disable_reasoning` (`none` already sits at the bottom of the ladder).

Left out of the #130 redesign: the desktop's Fast Mode toggle (a separate `config.set` key —
follow-up issue), hiding individual models, provider logos, a "Default" badge on the configured
default model, per-model effort presets, and a staged pick-then-confirm flow (a tap still applies
immediately).
