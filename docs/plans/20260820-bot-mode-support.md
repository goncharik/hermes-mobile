# Bot Mode support

GitHub issue: #76

## Status

This PR records the verified mobile groundwork only. It does **not** add a Bot Mode
screen, reducer, navigation entry point, or group-chat implementation.

The previous draft reducer and the Phase 2 placeholder have been removed because they
were not wired into the app and could not obtain a reliable profile roster:

- REST `GET /api/profiles` is the dependency currently used by `HermesProfileClient`.
- The upstream `profiles.list` gateway RPC is the source that returns Bot Mode metadata,
  `canonical_session`, `has_avatar`, and `bot_mode_protocol`.
- Calling that RPC requires a live gateway socket. The mobile gateway dependency is
  currently owned by the active chat slot, so a standalone roster would fail when no
  chat socket exists. This needs an application-level connection decision before a
  reducer is reintroduced.

Keeping an unconsumed reducer in the library would make the API look supported while
silently producing an empty roster or `.notConnected` errors. The next implementation
should start only after the socket ownership and navigation design are settled.

## Verified upstream contract

`profiles.list` returns, per profile:

- `name`, `is_default`, `model`, `provider`;
- `description` and `display_name` as top-level profile fields;
- `ui_meta['hermes-bots']`, when configured, with the desktop metadata fields
  `title`, `shape`, `color`, `imageKind`, `custom`, `created`, `pinned`, `hidden`,
  `groups`, and legacy scalar `group`;
- `has_avatar`, which indicates that `profiles.get_asset` can provide the avatar;
- `last_session`, `canonical_session`, and `worker_session` when sessions are included;
- `bot_mode_protocol: true` at the response level on supporting gateways.

The canonical Bot Chat is identified by the exact title `"Bot Chat"` on the bot's own
profile. Desktop resolves it with `session.list` using `include_hidden: true`, and creates
it with `session.create` using `hidden: true`. A future mobile implementation must also
materialise the row with `session.title` and must fail closed on lookup errors rather
than treating a network error as "no chat" and minting a duplicate.

## Current code

`HermesKit/Sources/HermesKit/Models/BotMeta.swift` now decodes the actual metadata
shape leniently. It does not invent `description` or `avatar` fields inside the metadata
object, and it preserves the distinction between a missing, empty, malformed, and
non-empty `hermes-bots` object.

`HermesKit/Sources/HermesKit/Models/Profile.swift` now exposes:

- `botMeta` and `isBotManaged`;
- top-level `description`;
- `hasAvatar` from the server's `has_avatar` flag.

`HermesKit/Tests/HermesKitTests/ProfileTests.swift` covers the real payload, missing and
empty metadata, unrelated `ui_meta`, malformed metadata, unknown future fields, and the
profile-level description/avatar fields.

## Next implementation steps

1. Decide whether `AppFeature` owns a long-lived gateway connection independent of the
   active chat, or add a dedicated profile-roster client that can use the app's connection
   manager.
2. Add a typed `profiles.list` gateway response model, including the response capability
   flag and `canonical_session`.
3. Add `BotRosterFeature` only after that dependency is available, with cancellable task,
   resolve/create effects, `include_hidden: true`, `hidden: true`, `session.title`, and
   fail-closed lookup handling.
4. Wire a view and navigation entry point, then add reducer and snapshot tests.
5. Scope group chats separately as a real feature build; do not add a no-op public
   reducer or placeholder domain model.
6. Run `tuist generate`, `swift test --package-path HermesKit`, and a manual test against
   a Bot-Mode-managed agent on macOS.
