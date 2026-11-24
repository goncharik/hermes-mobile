# State machines

This inventory covers adaptive navigation and its dependencies on the live-chat slot.
Other state machines remain documented in their feature guides; this is not a complete
inventory of the app yet.

## Adaptive navigation

Owners: `HermesMobile/Sources/AppView.swift` reports size-class changes;
`HermesKit/Sources/HermesKit/AppFeature.swift` owns `layout`, `path`, `liveChat`,
`slotGeneration`, and `reduceLayoutChanged`. The detailed contract is in
[`features/ipad-layout.md`](features/ipad-layout.md).

- `compact`: either size class is compact or unresolved. The session list uses a
  navigation stack. A visible chat has one `ChatScreen` marker.
- `regular`: both size classes are regular, on iPad or the open iPhone Duo.
  The existing split view shows the session list and selected chat. The path is empty.
- `liveChat` is the one shared chat slot in both layouts. Layout changes preserve
  its session, socket, transcript, queued work, draft, and active input, except when
  narrowing discards an unused pristine new chat.

| Source | Event | Guard | Destination | Side effects |
| --- | --- | --- | --- | --- |
| Either | `layoutChanged` | Layout unchanged | Same | None |
| Compact | `layoutChanged(.regular)` | Slot exists | Regular | Set layout first; clear navigation markers; render the same slot in the detail column |
| Compact | `layoutChanged(.regular)` | No slot, home exists | Regular | Set layout; fill and connect the normal new-chat detail slot |
| Compact | `layoutChanged(.regular)` | No home | Regular | Record layout for the eventual home landing |
| Regular | `layoutChanged(.compact)` | Slot is pristine | Compact | Set layout first; use the existing teardown sequence; leave the list visible |
| Regular | `layoutChanged(.compact)` | Slot has a session, draft, queued work, or input in flight | Compact | Set layout first; set exactly one marker; preserve the slot |
| Regular | `layoutChanged(.compact)` | No slot | Compact | Set layout; leave the path empty |
| Either | `chatViewDisappeared` during a column move | Chat is still attached | Same | No teardown or microphone release |

Forbidden transitions: a regular layout with a chat marker; two rendered copies of
the chat; socket teardown caused only by a column move; dropping queued work or input
when folding. `layout` must be set before navigation changes trigger view disappearance.

Duplicate layout events are no-ops. Size-class events are reduced in order on the
main actor. The latest root size classes are reported on launch, including before
home appears. Layout changes do not submit requests or add retries; connection
failure, cancellation, and foreground recovery keep the existing chat lifecycle.

Tests: `HermesMobileTests/AppLayoutTests.swift` covers classification and height-only
changes at the real view boundary. `HermesKit/Tests/HermesKitTests/AppFeatureTests.swift`
covers marker reconciliation, pristine-seat teardown, draft/attachment/recording
preservation, profile reseating, duplicate events, and socket continuity during
layout changes. Keyboard and transcript geometry are also covered by
`ChatColumnLayoutTests.swift` and `TranscriptKeyboardScrollTests.swift` in
`HermesMobileTests`.
