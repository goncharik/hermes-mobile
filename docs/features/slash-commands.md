# Slash commands (#36)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Composer & input"; this doc is the full contract. Design history:
`docs/plans/completed/`.

Slash commands go through the gateway's slash pipeline, **never as prompt text**.

## Discovery & the hide-list

Discovery is a one-shot `commands.catalog` RPC in `ChatFeature` (fired once hydrate or
`session.create` reaches ready; the `model.options` convention, no new dependency client),
decoded leniently into `CommandCatalog` with the static `mobileHiddenCommands` hide-list applied
at decode (matched case-insensitively; uncategorized `pairs` are skill routes, listed last;
`sub`/`canon` keys lowercased and `sub` members deduped once at decode). The hide-list drops
BOTH terminal-only chrome AND **commands with no live effect on mobile**: the gateway runs
worker-routed commands in a separate `slash_worker` subprocess and mirrors only
`model`/`personality`/`prompt`/`compress`/`fast`/`reload-mcp`/`stop` back onto the live session
(`_mirror_slash_side_effects`), so `/new`+`/reset`, `/sessions`, `/resume`, `/reasoning`,
`/branch`(+`/fork`), `/yolo`, `/voice` and the `_TUI_EXTRA` chrome (`/density`, `/logs`,
`/mouse`) would render success while this session stayed untouched — all have native affordances
instead (`/branch` is desktop-native; `/yolo` stays hidden because desktop and mobile's
composer lightning picker use the profile-scoped `approvals.mode` RPC, gated on desktop
contract 3+ — see `approval-mode.md`; `/voice` uses the app's own mic UI). `/title` DOES work
(the worker shares the session key, so its DB write lands here).

**Capability gate = the attach pattern verbatim**: `isUnknownMethod` → `commandsUnsupported`
(fetch skipped thereafter); other failures leave the catalog `nil`, silently retried on the next
hydrate — old agents stay byte-identical. An **EMPTY decoded catalog also stays `nil`** (the
lenient decode never throws, so a garbage payload must not latch a dead catalog).

## Filtering & the submit gate

**Filtering is client-side only**: computed `slashSuggestions` delegates to the pure
`SlashSuggestionFilter` (leading whitespace trimmed like submit, leading-`/` + no-newline guard,
prefix match on names + aliases, subcommand mode after `/cmd ` with an exact match suppressed so
the panel clears after a tap) — NO stored suggestion state, no `complete.slash`.

**The submit gate and the panel share ONE shape rule** (`SlashSuggestionFilter.isCommandShaped`,
the desktop's `SLASH_COMMAND_RE = /^\/[^\s/]*(?:\s|$)/`): a leading `/` whose FIRST TOKEN holds
no second `/`. A bare `hasPrefix("/")` swallowed prose — `/tmp/agent.log look at this`,
`// TODO` — failed it twice and DESTROYED the text (composer cleared, echo row local-only).
Submit branches to the command path only when the text is command-shaped, no attachments are
staged, AND **the parsed name RESOLVES in the curated catalog**
(`CommandCatalog.resolvesCommand` — a visible command/skill route or a known alias). The
hide-list only filters the panel; without this gate a manually-typed HIDDEN command (`/new`,
`/quit`, `/branch`, `/yolo`) reached `slash.exec` and reported fake worker success. A hidden or
genuinely-unknown command instead **falls through to plain `prompt.submit`** (byte-identical to
the old-agent / nil-catalog path — the LLM sees the literal text; skill routes still resolve, so
they exec). A degenerate `/` or `/ <payload>` (empty parsed name) fails locally **without
clearing the composer or echoing a row**, so the payload is never lost.

## Pipeline & directives

Pipeline: `slash.exec` — whose SUCCESS can itself be a typed directive (the server routes
`_PENDING_INPUT_COMMANDS` (`/retry`, `/goal`, `/undo`, …) and skill bundles through
`command.dispatch` internally and answers its directive as the exec result — **parse the
directive FIRST**, desktop parity) — → on failure `command.dispatch`, with THREE no-fallback
carve-outs, all guarding against double execution: a `-32601` from `slash.exec` itself (dispatch
shipped with exec, the fallback would only add a second unknown-method roundtrip); a
**transport-shaped failure** (timeout/drop — the exec may still be running server-side); and any
`serverRoutedSlashCommands` name (a verbatim mirror of `_PENDING_INPUT_COMMANDS` — the server
already ran `command.dispatch` for those inside `slash.exec`, so the error came FROM that
dispatch and re-issuing it re-enters the same handler; `/compact` past "compress failed" has
already mutated history).

Directives: `exec`/`plugin` → output row; `alias` re-enters the pipeline **once** (single hop,
no loop); `skill`/`send` hand `message` to the normal `prompt.submit` **suppressing the
duplicate optimistic user row** (a `send` `notice` renders first as an output row — the only
feedback `/goal`/`/moa` give); `prefill` (`/undo`) drops the undone message into the composer +
renders the notice; both-fail → `errorBanner`, never a swallowed `try?` — and when the
`command.dispatch` fallback ALSO fails with only the routing-noise "not a quick/…/skill command"
error, the **original `slash.exec` error is preferred** (a worker timeout/crash must not be
buried under the noise — desktop parity, `slash.ts`). All share ONE #17 session-not-found heal
per command (`HealCursor`, `docs/architecture.md` → "Session-not-found self-heal").

## Not a turn: locking

An exec is **not a turn** — no turn anchor; the terminal actions unlock + emit
`runningChanged(false)` ONLY when no real server turn started meanwhile (`!isTurnLive`
— a `message.start` that raced the exec keeps its lock and its server-confirmed running state).
Because it is not a turn, `running` is false throughout, so a hydrate landing mid-exec would
unlock the composer and let a SECOND command clobber the first: **`slashExecInFlight` holds the
lock across `applyActivate`** (`isSending = running || slashExecInFlight`) until the exec's own
terminal action (or `.slashCommandHandedOff`, after a `skill`/`send` submit) clears it.
**`canSend` gates on BOTH `!isSending` AND `!slashExecInFlight`** — an interrupt tap or a socket
finalization can clear `isSending` mid-exec while the round-trip is still outstanding, so the
dedicated flag is what actually blocks a second submission in that window. **Mid-turn slash
submission is deliberately out of scope**: the send button is Interrupt mid-turn, so
`/steer`-while-running and mid-turn `/queue` aren't reachable — their idle-time `send`
directives work normally.

## Ephemeral output rows & the post-command refresh

**Command output rows (`ChatRow.Kind.commandOutput`) are EPHEMERAL — desktop parity**:
local-only, never in server history, wiped by the next wholesale hydrate. The post-command
refresh is nevertheless the **full server-authoritative hydrate** (`session.resume` →
`applyActivate` + title): slash commands MUTATE history — `/undo` rewinds it
(`db.rewind_to_message`), `/compress`//`/compact` rewrite it, `/retry` truncates it — and a
runtime-only refresh left those rows on screen indefinitely (re-persisted into the cache, so
even a cold relaunch repainted them). It costs nothing extra on the wire (`session.resume`
always returns the whole cooked history). Only the **just-produced (last) `commandOutput` row**
is carried across the wholesale replace and re-appended, so the command's own output survives
the refresh that removes the rows it acted on (carrying EVERY historical output row put earlier
ones after the whole transcript, out of chronological order once more than one exec had run —
older ones are dropped like any real hydrate drops them). The refresh is a **no-op if a new turn
or exec started while it was in flight** (`isSending`/`slashExecInFlight`/`isTurnLive`) — its
`session.resume` predates the new turn, so applying it would wipe the new turn's optimistic rows
and unlock a genuinely-running turn.

## Timeout budget & panel

**The slash pipeline also gets a longer per-request budget**
(`HermesGatewayClient.longRunningMethods` → 120s, desktop parity): `slash.exec` blocks the
gateway dispatcher "for seconds to minutes" and `/compress` runs an unbounded inline LLM
summarisation, so the 30s default failed it on exactly the sessions worth compressing — while
the compression succeeded server-side.

The `SlashSuggestionPanel` is view-thin between transcript and composer, rendered only when
`slashSuggestions` is non-empty; a tap sends `.slashSuggestionTapped`, which just sets
`composerText`.

## Known bounded limitations (server-internal, no clean client fix — accepted)

1. On a FRESH `session.create` the gateway's live-agent build is deferred, and the
   `model`/`personality`/`fast`/`compress` mirror is gated on `session["agent"]`, so one of
   those typed BEFORE the first message can report worker success while the not-yet-built live
   agent keeps the default — re-issue after the first turn.
2. If another client starts a REAL turn mid-exec, the `isTurnLive` cross-client guard
   suppresses the post-command refresh (no clobbering the live turn), so a `/undo`/`/retry`/
   compression history mutation stays unreconciled until the next real hydrate (foreground/
   reattach) — bounded staleness, not permanent.
3. A `skill`/`send` directive echoes the typed `/cmd` locally but persists the GENERATED
   directive message via `prompt.submit`, so the next hydrate shows the generated prompt in
   place of the `/cmd` — inherent (the server stores the generated message, desktop-consistent),
   same ephemerality as the local echo row.
