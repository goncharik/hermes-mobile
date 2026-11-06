# Model picker redesign: configured-only providers, favorites, collapse, centering (#130)

## Overview
- TestFlight feedback (#130): users with large catalogs (OpenRouter, Cursor) scroll through
  everything in `ModelPickerSheet`. Redesign the sheet after the desktop's
  `model-catalog-menu.tsx` and the T3 Code mobile picker:
  - only providers the user explicitly configured (`model.options` `explicit_only: true`);
  - provider cards with a collapse chevron, collapse state persisted on the device;
  - a star per model row, starred models pinned in a Favorites card at the top;
  - an Options card with one "Reasoning › <effort>" row that pushes the effort list (replaces the
    8 inline effort rows);
  - on open, the list scrolls ONCE to the current model, centered.
- Tap-to-apply, the optimistic `config.set` + rollback path, the #17 heal, the `--provider` slug
  routing and the `max`/`ultra` latch are all unchanged.

## Context (from discovery)
- `HermesKit/Sources/HermesKit/Models/ModelOptions.swift` — payload model, `orderedProviders`,
  `filteredProviders(matching:)`, `supportsReasoning`, `offeredEfforts(extendedSupported:)`.
- `HermesKit/Sources/HermesKit/Features/ChatFeature.swift` — `State.ModelPicker` (~l.579),
  `modelPicker: ModelPicker?` (~l.178), `.modelChipTapped` fetch (~l.2683),
  `.modelOptionsResponse`, `.modelSelected`, `.reasoningSelected`, `.configSetFailed` (writes
  `modelPicker?.applyError`), `.modelPickerDismissed`, `clearConfigError` (~l.5302).
  Precedent for a presented child: `@Presents var filePreview: FilePreviewFeature.State?` +
  `.ifLet(\.$filePreview, action: \.filePreview)` (~l.183, ~l.2856).
- `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift` — `live`/`inMemory`, logout clears
  happen in `AppFeature.swift` (~l.439, ~l.815) and `SettingsFeature.swift` (~l.494).
- `HermesMobile/Sources/Features/Chat/ModelPickerSheet.swift` — closure-driven view;
  `ChatView.swift` presents it via `.sheet(isPresented: modelPickerBinding)`.
- Tests: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift` (~25 model-picker
  references), `HermesMobileTests/ComposerSnapshotTests.swift` (4 `ModelPickerSheet` snapshots,
  `deviceImage()`).
- Docs: `docs/features/model-picker.md`, `CLAUDE.md` "Composer & input" model-picker bullet.
- Desktop reference (upstream hermes-agent): `apps/desktop/src/lib/model-options.ts` sends
  `explicit_only: true`; `store/provider-collapse.ts` (default expanded, search overrides
  collapse); `store/favorite-models.ts` (`provider::model`, Favorites section on top, removed from
  provider groups, hidden while searching); scroll-to-current on open.
  Gateway: `tui_gateway/methods_complete.py` `model.options` reads `explicit_only` via
  `params.get` → older gateways ignore it; `hermes_cli/inventory.py` keeps the CURRENT provider
  row with `authenticated=false` + `warning` when its credentials are gone.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; commit at each task completion
- commit messages: capitalized verb, no conventional-commit prefixes, concise
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** — `make test` (HermesKit) and,
  for view tasks, `make snapshot`
- **CRITICAL: update this plan file when scope changes during implementation**
- TCA conventions (Point-Free skills `pfw-composable-architecture`, `pfw-testing`,
  `pfw-dependencies`, `pfw-swift-navigation`, `pfw-snapshot-testing`, `pfw-modern-swiftui`):
  `@Reducer` with `body` + `Reduce`; `@ObservableState`; actions named literally after the user
  event or effect result (`starButtonTapped`, `modelOptionsResponse`); `Action` NOT `Equatable`;
  `Result`, never `TaskResult`; `@Dependency` declared in the reducer, controlled dependencies
  only; `@Presents` + `.ifLet` + `$store.scope(state:action:)` sheet (no legacy
  `sheet(store:)`); child→parent via `Delegate` actions; `@Dependency(\.dismiss)` for
  self-dismissal; exhaustive `TestStore`.

## Testing Strategy
- **unit tests** (Swift Testing, `swift test` / `make test`): `ModelOptions` decode + current-row
  match, `ModelPickerLayout` pure derivation, `PreferencesClient` in-memory round-trips,
  `ModelPickerFeature` TestStore, `ChatFeature` integration (delegate handling, `explicit_only`,
  `applyError` mirroring), logout clearing in `AppFeature`/`SettingsFeature`.
- **snapshot tests** (`make snapshot`): the sheet is a `List` → `deviceImage()` (never
  `componentImage()`), light + dark. To add a new test run `make snapshot` twice (first records
  and fails by design). Re-record the existing `ModelPickerSheet` baselines in the same PR.
- No hosted behavior-probe tests (centering is verified manually; its target derivation is
  unit-tested in `ModelPickerLayout`).

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; document blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **Extract `ModelPickerFeature`** (new child reducer in HermesKit) instead of growing the
  5000-line `ChatFeature`. It owns the picker's own state (load, options, load error, apply error,
  collapsed set, favorites), the `model.options` fetch, and the two persistence toggles. Selection
  stays a PARENT concern (it mutates `ChatFeature.model`/`reasoningEffort`/
  `pendingConfigRollback` and runs `configSet` inside the #17 heal), so the child forwards row
  taps as `Delegate` actions. `ChatFeature` presents it with `@Presents var modelPicker` +
  `.ifLet`, mirroring `filePreview`.
- **Parent-owned display inputs** (`currentModel`, `currentEffort`, `isBusy`,
  `extendedReasoningSupported`) are passed to the view as plain parameters from `ChatView` — one
  source of truth, no state syncing into the child.
- **Pure `ModelPickerLayout`** (HermesKit, outside any UIKit guard) derives sections, row ids and
  the scroll target from `(options, favorites, collapsed, query, currentModel, currentProvider)`.
  The view only iterates it.
- **Persistence** in `PreferencesClient` (two new entries, device-global, cleared on logout).
- **View**: card-style `List` sections with custom collapsible headers, star buttons, Options
  card with a pushed effort list (view-local `navigationDestination` — pure presentation, no
  logic), `ScrollViewReader` centering once per presentation.

## Technical Details
- `ModelOptions`:
  - decode top-level `provider` (`String?`) → `currentProvider`, lenient (`try?`).
  - `func isCurrent(model: String, providerID: String, currentModel: String?) -> Bool`
    (or equivalent): when `currentProvider` is present, match on `(provider slug, model)`;
    otherwise fall back to model-name-only (today's behaviour). Compare against
    `Provider.selectionSlug`/`id` — verify which value the gateway reports in `provider`
    (upstream `inventory.py` returns the slug) and document it.
- `FavoriteModel: Codable, Hashable, Sendable { providerID: String; model: String }` (public,
  explicit `public init`).
- `PreferencesClient`:
  - `loadCollapsedModelProviders / saveCollapsedModelProviders (Set<String>)`,
    key `hermes.model-picker.collapsed-providers` (stored as `[String]`).
  - `loadFavoriteModels / saveFavoriteModels ([FavoriteModel])`, key
    `hermes.model-picker.favorite-models` (JSON `Data`, decode failure → `[]`).
  - `clearModelPickerPrefs()` extension (both keys) called from every logout site
    (`AppFeature` ×2, `SettingsFeature`). NOT part of `clearIdentityScopedPrefs` (device-global,
    like the read-aloud toggle).
- `ModelPickerFeature` (`@Reducer public struct`):
  - `State` (`@ObservableState`, `Equatable`, `Sendable`): `sessionID: String`, `isLoading`,
    `options: ModelOptions?`, `error: String?`, `applyError: String?`,
    `collapsedProviders: Set<String>`, `favorites: [FavoriteModel]`.
  - `Action`: `task` (view `.task` → fetch + prefs load), `modelOptionsResponse(Result<ModelOptions,
    GatewayError>)`, `providerHeaderTapped(String)`, `starButtonTapped(FavoriteModel)`,
    `modelRowTapped(model: String, providerSlug: String?)`, `effortRowTapped(String)`,
    `doneButtonTapped`, `delegate(Delegate)` with `Delegate.modelSelected(model:provider:)`,
    `.reasoningSelected(String)`.
  - Fetch: `model.options` with `{"session_id", "explicit_only": true}`; same
    decode/`.server("Malformed…")`/`.disconnected` mapping as today.
  - Prefs are loaded synchronously in `.task` (or in the parent when building the state —
    pick one and test it); toggles mutate state then `preferences.save…` (sync client call in
    the reducer is the existing pattern — `saveAutoSpeakReplies`).
  - Toggles are allowed while the parent is busy (display-only).
  - `doneButtonTapped` → `.run { _ in await dismiss() }`.
- `ChatFeature`:
  - `@Presents public var modelPicker: ModelPickerFeature.State?`;
    `case modelPicker(PresentationAction<ModelPickerFeature.Action>)`; `.ifLet`.
  - `.modelChipTapped` (guard `liveSessionID`) → `state.modelPicker = .init(sessionID:)`.
  - Delegate `.modelSelected` / `.reasoningSelected` → today's `.modelSelected` /
    `.reasoningSelected` logic, moved into private helpers (behaviour byte-identical, including
    guards, rollback bookkeeping, `clearConfigError`, `configSet`).
  - `.configSetFailed` and `clearConfigError` keep writing `state.modelPicker?.applyError`.
  - Remove `.modelPickerDismissed`, `.modelOptionsResponse`, and the old `State.ModelPicker`.
  - Check the `ChatFeature` effect-cancellation lists (e.g. the comment near l.1533 about
    `filePreview`) for anything that must account for the new presented child.
- `ModelPickerLayout` (pure):
  - `enum Section { case options; case favorites([Row]); case provider(ProviderSection) }`
    where `ProviderSection { provider, isCollapsed, rows: [Row], currentModelName: String? }`
    and `Row { id: String, model, providerID, providerSlug, providerName, isFavorite, isCurrent,
    showsProviderCaption }`.
  - Not searching: `.options` iff `supportsReasoning(currentModel)`; `.favorites` iff any
    favorite resolves to an offered configured `(provider, model)` (stale ones skipped, order =
    star order, `showsProviderCaption` iff resolved favorites span >1 provider); provider sections
    in `orderedProviders` order, favorited models removed from their card; a provider whose
    every model is favorited still shows its header (count 0 rows) — decide and test.
    Collapsed header carries `currentModelName` when current lives in it.
  - Searching (non-blank query): no `.options`, no `.favorites`, every provider expanded, rows
    from `filteredProviders(matching:)`, favorited models stay in their provider card (with a
    filled star).
  - Unconfigured / lost-credential providers: a section with no selectable rows that the view
    renders as today's disabled warning row.
  - Row ids: `fav::<providerID>::<model>`, `<providerID>::<model>`; header id
    `header::<providerID>`.
  - `scrollTarget`: nil while searching; else favorite row id if current is favorited, else the
    current row id if its provider is expanded, else `header::<providerID>`; nil if current is not
    in the list.
- `ModelPickerSheet` (view):
  - Takes `store: StoreOf<ModelPickerFeature>` + `currentModel`, `currentEffort`, `isBusy`,
    `extendedReasoningSupported`; `@State searchText`, `@State hasCentered`.
  - `List` `.insetGrouped`; Options card: `Reasoning` row with trailing current effort + chevron,
    `navigationDestination(isPresented:)` → effort list (offeredEfforts, checkmark on current),
    tap sends `.effortRowTapped` and pops.
  - Provider section header = `Button` (name, count when collapsed, current model + checkmark
    when collapsed and current inside, chevron rotating by state; respects reduce-motion);
    VoiceOver label/hint ("Collapse"/"Expand"), `.isHeader` trait.
  - Model row: name, checkmark when current, trailing star `Button` (`star`/`star.fill`,
    a11y label "Add to favorites"/"Remove from favorites"); row tap disabled while busy, star
    always enabled.
  - Favorites rows: provider name caption when `showsProviderCaption`.
  - Centering: `ScrollViewReader`; when options first become non-nil (`.onChange` or `.task(id:)`)
    and `!hasCentered`, `proxy.scrollTo(target, anchor: .center)` then `hasCentered = true`.
  - Toolbar: `confirmationAction` Done (checkmark icon with "Done" a11y label) →
    `.doneButtonTapped`. `.searchable(text:prompt: "Search models")` with default placement (iOS
    26 places it at the bottom on iPhone; iOS 18 keeps the drawer).
- `ChatView`: `.sheet(item: $store.scope(state: \.modelPicker, action: \.modelPicker))`, drop
  `modelPickerBinding`.

## What Goes Where
- **Implementation Steps**: code, tests, docs in this repo.
- **Post-Completion**: PR, internal TestFlight build, #130 comment, Fast Mode follow-up issue,
  manual device checks.

## Implementation Steps

### Task 1: Decode the current provider in ModelOptions and match the current row on (provider, model)

**Files:**
- Modify: `HermesKit/Sources/HermesKit/Models/ModelOptions.swift`
- Modify: `HermesKit/Tests/HermesKitTests/` (the existing `ModelOptions` test file — locate with
  grep; create `ModelOptionsTests.swift` if none)

- [x] confirm against upstream `hermes_cli/inventory.py` (`git -C ../hermes-agent show
      upstream/main:hermes_cli/inventory.py`) what the payload's top-level `provider` holds (slug
      vs name) and note it in the doc comment
- [x] add `currentProvider: String?` decoded leniently from `provider`; extend `init`
- [x] add the current-row predicate (provider+model when `currentProvider` present, model-only
      fallback otherwise)
- [x] write tests: decode with/without `provider`, malformed `provider` ignored
- [x] write tests: same model id under two providers → only the matching provider's row is
      current; absent `currentProvider` → model-only fallback
- [x] run `make test` — must pass before next task
- ➕ `provider` is a provider ID (= row `slug`) EXCEPT for custom providers (`custom:<key>` vs bare
      slug), so `Provider` now decodes `aliases` and matches via `Provider.matches(providerID:)`
      (slug / name / alias — desktop `catalogProviderMatches`). Predicate shipped as
      `ModelOptions.isCurrent(model:in:currentModel:)`; a `currentProvider` matching no row marks
      nothing current (no model-only fallback, desktop parity).

### Task 2: Persist collapsed providers and favorite models in PreferencesClient

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/FavoriteModel.swift`
- Modify: `HermesKit/Sources/HermesKit/Clients/PreferencesClient.swift`
- Modify: `HermesKit/Sources/HermesKit/AppFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/SettingsFeature.swift`
- Modify: the existing PreferencesClient / logout tests (locate with grep)

- [x] add `FavoriteModel` (`Codable, Hashable, Sendable`, public init)
- [x] add load/save closures for collapsed providers and favorites to `PreferencesClient`
      (defaults `[]`), `live` (keys above, JSON for favorites) and `inMemory`
- [x] add `clearModelPickerPrefs()` extension and call it at every logout site (`AppFeature`
      ×2, `SettingsFeature`)
- [x] write tests: in-memory round-trip; `live(defaults:)` with a throwaway suite round-trip and
      corrupt-data → `[]`
- [x] update logout tests to assert both prefs are cleared
- [x] run `make test` — must pass before next task

### Task 3: Add the pure ModelPickerLayout derivation

**Files:**
- Create: `HermesKit/Sources/HermesKit/Models/ModelPickerLayout.swift`
- Create: `HermesKit/Tests/HermesKitTests/ModelPickerLayoutTests.swift`

- [x] implement sections (options / favorites / provider sections with collapse +
      `currentModelName`), row ids, and `scrollTarget` per Technical Details
- [x] implement search mode (no options/favorites, all expanded, `filteredProviders`)
- [x] write tests: section order; options hidden for `reasoning: false`; favorites order,
      stale favorites skipped, removal from provider card, provider caption only when >1 provider
- [x] write tests: collapsed provider keeps header + `currentModelName`; unconfigured /
      lost-credential provider section; search mode; stale collapsed ids ignored
- [x] write tests: scroll target favorite → expanded row → collapsed header → nil (searching /
      current absent)
- [x] run `make test` — must pass before next task
- ➕ decided: a configured provider whose every model is favorited drops its card (desktop
      `groupModels` parity); `ProviderSection` gained `modelCount` (rows are empty when
      collapsed) and `isSelectable`; a lost-credential current provider's header is the
      `scrollTarget` when no row is current; `Section` is `Identifiable` (`options`,
      `favorites`, `header::<id>`).

### Task 4: Extract ModelPickerFeature and present it from ChatFeature

**Files:**
- Create: `HermesKit/Sources/HermesKit/Features/ModelPickerFeature.swift`
- Modify: `HermesKit/Sources/HermesKit/Features/ChatFeature.swift`
- Create: `HermesKit/Tests/HermesKitTests/ModelPickerFeatureTests.swift`
- Modify: `HermesKit/Tests/HermesKitTests/ChatInteractionTests.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift` (compile-only wiring; the sheet
  redesign is Task 5)

- [x] create `ModelPickerFeature` (state, actions, delegate, fetch with `explicit_only: true`,
      prefs load, toggles + persistence, dismiss) per Technical Details
- [x] replace `State.ModelPicker` with `@Presents var modelPicker: ModelPickerFeature.State?`
      + `.ifLet`; route delegate `modelSelected`/`reasoningSelected` into the existing logic
      (behaviour unchanged); keep `configSetFailed`/`clearConfigError` writing
      `modelPicker?.applyError`; remove `.modelPickerDismissed`/`.modelOptionsResponse`
- [x] minimally adapt `ChatView` + `ModelPickerSheet` call site to the scoped store so the app
      target builds
- [x] write `ModelPickerFeatureTests`: `.task` sends `explicit_only: true` + `session_id` and
      loads prefs; success / malformed / `GatewayError` / non-gateway error; header toggle
      collapses + expands + persists; star toggle adds (appends) / removes + persists; row tap
      and effort tap emit delegates; done dismisses
- [x] migrate `ChatInteractionTests` model-picker tests to the child/delegate path, keeping every
      existing assertion (optimistic write, `--provider` wire value, bare id, rollback, latch,
      `applyError` mirror, busy guard)
- [x] run `make test` — must pass before next task
- ➕ the sheet's `options.currentProvider` follows an optimistic model pick
      (`State.applyOptimisticModelPick`), is restored by a rejected pick (`.configSetFailed`
      model key) and confirmed by a `session.info` carrying the model — otherwise a
      cross-provider pick would check no row under the `(provider, model)` match.
      `ModelPickerSheet` now takes the scoped store (rendering unchanged; the four baselines
      still pass), and `SelfHealTests` picks go through the presented child too.

### Task 5: Redesign ModelPickerSheet (cards, collapse, stars, Options → effort list, centering)

**Files:**
- Modify: `HermesMobile/Sources/Features/Chat/ModelPickerSheet.swift`
- Modify: `HermesMobile/Sources/Features/Chat/ChatView.swift`

- [ ] render `ModelPickerLayout` sections: Options card, Favorites card, provider cards with
      collapsible header buttons, model rows with star buttons, disabled warning row for
      unconfigured/lost-credential providers; busy note + inline apply error unchanged
- [ ] effort list as a pushed page (`navigationDestination(isPresented:)`), offered efforts,
      checkmark, tap sends `.effortRowTapped` and pops
- [ ] once-per-presentation centering with `ScrollViewReader` on `layout.scrollTarget`
- [ ] Done toolbar button → `.doneButtonTapped`; `.searchable` with default placement;
      `ContentUnavailableView.search` for zero matches
- [ ] accessibility: header/star labels + hints, reduce-motion-aware chevron animation
- [ ] `tuist generate` if files were added, build the app target (`make build` or the
      documented xcodebuild command) — must compile cleanly

### Task 6: Snapshot the redesigned sheet

**Files:**
- Modify: `HermesMobileTests/ComposerSnapshotTests.swift`
- Modify: `HermesMobileTests/__Snapshots__/ComposerSnapshotTests/` (baselines)

- [ ] update the four existing `ModelPickerSheet` snapshots to the new API (store built from
      `ModelPickerFeature.State`, no `.task` side effects — use a reducer-less/no-op store or
      `withDependencies` test values) and re-record them
- [ ] add: expanded with Favorites (multi-provider captions), collapsed provider showing the
      current model, busy, effort sub-list page, search active; light + dark where the file's
      convention does so
- [ ] `make snapshot` twice for new tests; final run clean (all suites, not only new ones)

### Task 7: Verify acceptance criteria
- [ ] verify every Overview requirement against the running code (explicit_only, favorites,
      collapse persistence, Options card, centering, tap-to-apply unchanged)
- [ ] verify edge cases: no favorites, all models of a provider favorited, stale favorite,
      current model missing from the list, lost-credential current provider, older gateway
      without `provider` field
- [ ] run full suites: `make test` and `make snapshot`
- [ ] build the app target

### Task 8: [Final] Update documentation
- [ ] rewrite the affected parts of `docs/features/model-picker.md`: fetch (`explicit_only`,
      lost-credential row), Options card + pushed effort list (replaces inline rows), Favorites,
      collapse, centering, `ModelPickerFeature`/`ModelPickerLayout` ownership, prefs + logout
- [ ] update the `CLAUDE.md` model-picker bullet (one-line rule + pointer; keep it 5–8 lines),
      and the `CLAUDE.md` "Persistence" prefs list if it enumerates prefs
- [ ] update `README.md` if it describes the picker
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems — informational only*

**Release:**
- rebase onto `origin/main`, open the PR (link #130), internal-only TestFlight upload via
  `asc --profile hermes` (no external group)
- comment on #130 linking the PR; open a follow-up issue for the Fast Mode toggle (desktop has it;
  separate `config.set` key)

**Manual verification (device):**
- picker opens centered on the current model (favorite, expanded provider, collapsed provider)
- collapse/favorites survive app relaunch and are gone after logout
- an OpenRouter-sized catalog: collapse + favorites make the list short; search still finds
  collapsed models
- iOS 26 bottom search bar vs iOS 18 top drawer
- picking a model/effort still applies immediately and rolls back on failure
