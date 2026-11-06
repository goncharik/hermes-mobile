---
worth: yes
where: HermesKit/Sources/HermesKit/Models/ModelPickerLayout.swift:220
added: 2026-11-06
---
# model picker doesn't center on a collapsed provider card

When the current model sits in a collapsed provider card, `ModelPickerLayout.scrollTarget` returns
the card's `header::<providerID>`, which is only the `Section`'s `ForEach` id in
`ModelPickerSheet`. `List`'s `ScrollViewProxy.scrollTo` doesn't reach a section id, so on device the
sheet opens at the top instead of centered (confirmed after PR #151 / #130). The lost-credential
fallback (line 225) targets a header the same way and likely fails too. Row targets (Favorites row,
expanded card row) work.

Accepted as a corner case at merge. Likely fix: give the scroll a real row to land on — e.g. a
one-line summary row in a collapsed card that carries the current model, or the lost-credential
warning row — and keep the derivation's unit tests in step.
