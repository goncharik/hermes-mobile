---
worth: later
where: HermesKit/Sources/HermesKit/Features/ChatFeature.swift:6308
added: 2026-11-10
---
# branch boundary can miss a same-text commentary + final turn

On a session-authority host the branch boundary (`through_message_id`) is resolved by matching the
tapped reply's text in the fetched snapshot (`branchBoundaryRowID`). A turn stored as commentary +
final with the same text shows as one row in the client transcript, so the occurrence count drifts
and the boundary can land on the wrong row. The child silently gets a partial turn; the parent is
untouched. Raised in the #164 review, left out of #168 (it touches the transcript model and every
hydrate path).

Fix (Desktop `branchThroughRowId`): keep `row_id` on transcript rows (hydrate already returns it; a
live final gets it from `message.complete.persisted_turn.final_assistant_row_id`) and branch by id,
refusing when it's missing. That also drops the full-history `session.resume` per tap and makes the
stale-fence retry safe (it currently re-matches by text).

Unknown that settles the value: how often a turn actually stores commentary and final with identical
text. If that is near zero, the text match is good enough and this can be dropped.
