# Chat Markdown rendering & tables (#27, #59)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Transcript & chat UI"; this doc is the full contract. Update it when the behavior
changes. Design history: `docs/plans/completed/`.

## Block-level structure & selection (#27)

Chat Markdown renders block-level structure — pure classification in `MarkdownSegment`
(headers / blockquotes / tables alongside prose + fenced code; fences take precedence, odd markup
degrades to prose), rendered in `MarkdownText` (headings → scaled bold, blockquote → indented bar,
table → `MarkdownTableView`). **Only USER messages have a bubble** — assistant / tool / reasoning
rows render bubble-less plain content, and the assistant Markdown is selectable: **prose is the
only guaranteed part** (it renders through `SelectableText`, a real `UITextView`), while headings /
blockquotes / table cells rely on `.textSelection(.enabled)`, which `SelectableText`'s doc comment
records as unreliable inside the transcript's `UICollectionView`. `MarkdownTableView`
**re-applies the modifier on its own `Grid`** rather than relying on inheritance through the
table's horizontal `ScrollView` — belt-and-braces, and by construction a **no-op**
(`.textSelection` is an Environment value and `ScrollView` does not reset the environment;
measured size-neutral, identical `contentSize`, hosted height and snapshot bytes). It removes
a doubt about inheritance; it fixes nothing known to be broken and does **not** make table-cell
selection a proven contract. The half that actually matters — whether the selection gesture
beats the collection view's and the table's own pan recognisers — is **untested** and stays a
**manual-check item**.

## Tables pan instead of clipping (#59)

**Tables live in their own `MarkdownTableView`** (#59, no longer an inline `Grid` in
`MarkdownText`): the `Grid` sits in a horizontal `ScrollView`
(`.scrollBounceBehavior(.basedOnSize)`) so a table wider than the screen **PANS instead of
clipping** — with a trailing fade, because iOS only flashes the scroll indicator mid-drag and a
panned table would otherwise look exactly like the clipped one the issue reported — while one that
fits renders inline, neither pans nor bounces nor fades.

**The fade is layout-direction-aware on BOTH halves**: SwiftUI mirrors the scroll view under
`.rightToLeft` (the table opens parked at the right, hidden columns to the left) and mirrors the
mask's `HStack`, but **not** the `LinearGradient`'s `.leading`/`.trailing` stops — so the direction
is passed explicitly to `hasTrailingOverflow` *and* `trailingFadeMask`, where the measurements live.

The horizontal pan offset needs **no** row-scoped `.id()`: a recycled `UIHostingConfiguration` cell
re-opens its table at the leading edge (measured; an in-place `reconfigureItems` on the *same* row
does keep the pan, which is what makes that test non-vacuous).

## Column width capping

Each cell is sized by the file's own `CappedWidthLayout` at `MarkdownTableView.columnMaxWidth`
(a base cap, `@ScaledMetric`-scaled so the readable-measure rationale survives Dynamic Type, then
**clamped to `columnMaxWidthCeiling`**) — **NOT `.frame(maxWidth:)`, which cannot cap anything
inside a horizontal `ScrollView`**. The clamp is load-bearing: unclamped the scaled cap overshoots
any iPhone, so even a **single-column** table — the shape that physically cannot overflow — would
have to be panned to read one line of prose. The ceiling is **derived, not typed** — it *is*
`TranscriptLayout.narrowestRowWidth` (narrowest supported screen minus the transcript section's
own insets), so the layout and the cap cannot drift apart, and the layout tests build their rows
with the production `TranscriptLayout.makeLayout()`. It is a **constant**, never the offered
width: `CappedWidthLayout` proposes the cap **regardless of the incoming proposal**, so the
table's measured height is **width-invariant** where the old grid's was not, and a
`GeometryReader`-derived clamp would destroy exactly that.

**The measured derivation — the per-category scaled widths, the ceiling arithmetic, the cell
heights that make clamping beat both alternatives — lives on
`MarkdownTableView.columnMaxWidthCeiling` and `CappedWidthLayout`; keep it there.**

## What the tests guard

Width-invariance is the **proxy the tests guard, not a reproduction of #59's gap** (that symptom
is measured-vs-displayed height at ONE width, intermittent, and verified only by eye); it is what
makes reverting the renderer shape go red. Confirming the streaming/hydrating symptom is gone
stays a **device check** (#59's closing gate). The layout invariants are locked by **measured**
tests (`HermesMobileTests/MarkdownTableLayoutTests.swift` — hosts the real view, reads
`contentSize` vs `bounds` off the `UIScrollView`, guards the ceiling at the **narrowest** row, and
lays a row out in a **real `UICollectionView`** with the transcript's `.estimated(60)` self-sizing
layout and `UIHostingConfiguration` cell registration, relaid out wide → narrow → reconfigured,
with a prose control proving the harness can go red), not only snapshots: a device-width snapshot
of a panning table and of a truncated one are the same first screenful, so a snapshot alone cannot
tell them apart. A **multi-column** prose table still pans by design — the accepted cost of capped
columns over the old squeeze-everything-equally grid.
