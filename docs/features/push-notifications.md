# Push notifications (#46, #64)

Normative invariants moved out of `CLAUDE.md` (2026-08-14 restructure). The short rules live in
`CLAUDE.md` → "Push notifications"; this doc is the full contract. Architecture detail:
`docs/architecture.md` → Push notifications. Push-tap **approval recovery** lives in
`docs/features/approvals.md`. Design history: `docs/plans/completed/`.

## Three artifacts, three repos

Push notifications span THREE artifacts but only the iOS app lives in this repo: `hermes-push`
(a standalone pip plugin — **hermes-agent is NOT modified**) and the serverless **push gateway**
(holds the `.p8`) live in **separate repos** — plugin: `goncharik/hermes-mobile-push-plugin`
(public); gateway: `goncharik/hermes-mobile-push-gateway` (private, holds the Apple secret).

## Conventions

- **Capability-gate** — the toggle/controls hide when `POST /api/plugins/hermes-push/register`
  404s → `pushAvailable = false` (mirrors attach/profiles).
- **Generic-body privacy rule** — NO message content/args/reasoning/command ever goes in a push;
  only a generic title/body + `session_id` transit the gateway (content is fetched in-app over
  the private net).
- Compile-time **`apns_env`** (`#if DEBUG` → `sandbox`, else `production`) **must match the
  `aps-environment` entitlement** — which is driven **per-build-configuration** via
  `$(APS_ENVIRONMENT)` (Debug → `development`, Release → `production`) in `Project.swift`, NOT a
  static value (Tuist emits the entitlement verbatim with no Xcode export rewrite, so a static
  `development` would ship a sandbox entitlement on Release).
- **Permission is requested on the sessions-list appearance** (right after login), per the
  product decision — NOT first launch.
- **`PushClient` is iOS-only-guarded** like `AudioRecorderClient` (`#if canImport(UIKit)`;
  non-iOS `liveValue = testValue`); keep pure logic (hex, `apnsEnv`, payload parse,
  foreground-suppression) — and `PushBridge` itself (Foundation-only: `NSLock` + `AsyncStream`)
  — outside the guard so the stream/buffer behavior is macOS-tested.

## No shared secret on the device or in the plugin

**The app does NOT sign pushes, and the plugin holds NO shared secret** — the gateway is the
only place the signing key (`HMAC_SECRET`) lives (a single hosted gateway serves all App Store
users, so a plugin-held shared secret would be world-readable). The gateway instead **issues a
device-scoped capability**: `POST /register {device_token} → {capability}` where
`capability = hex(HMAC-SHA256(HMAC_SECRET, "hpc1:"+device_token))`. The plugin fetches it
lazily, caches it per-device in its token store, and presents it on every `POST /push` (which
**requires** `capability` — the old shared-secret `hmac`-over-all-fields is gone), re-fetching
once on a `403 invalid_capability`. A leaked capability can only push to its own device. The iOS
app is unchanged: it still calls the **plugin's** `/register`
(`{device_token, apns_env, app_version}` → `{ok, device_token, apns_env}`, a different endpoint
from the gateway's capability `/register`) and persists no secret (no Keychain push-secret).

## The four triggers

**All four triggers fire via real plugin hooks** (CLI + gateway): approval
(`pre_approval_request`), turn-complete (`post_llm_call`, gated to ~>10s turns via a
`pre_llm_call` start anchor), error (`on_session_end`, genuine failures only — not
success/interrupt), and clarify (`pre_tool_call` filtered to the `clarify` tool, fired before
the user is prompted — not duration-gated).

## Cold-launch tap replay (#46)

A launch-from-push tap is dropped at two independent points unless both are covered:

- `PushBridge` buffers a tap that fires with no **live** `tapStream()` subscriber and the first
  subscriber drains it **consume-once** (cleared after delivery — a stale tap must not
  re-navigate a later re-subscriber, unlike the idempotent `lastToken` replay; terminated
  continuations are pruned via `onTermination`, so a cancelled observer can't strand a dead
  entry that defeats the `isEmpty` buffer gate).
- A tap arriving before `state.home` exists is stashed in `AppFeature.State.pendingPushTap`
  (single stash, last-wins; process-lifetime, cleared on logout, badge bookkeeping unchanged)
  and re-sent as `.pushTapped` when `home` is created (`.autoConnectSucceeded` AND the
  manual-login `.onboarding(.delegate(.connected))`) — always replay through the one #32 routing
  path (slot dedup, approval-hint arming, placeholder `Session(id:)` + `session.resume`), never
  call `openSession` directly.

The stash records the persisted server URL at stash time and a login to a **different** server
drops it (scrubbing its badge entry) instead of replaying — resuming a foreign session id would
trip the resume self-heal into creating a spurious empty chat; an unknown origin (logged out, no
stored URL) replays unverified. Home creation seeds the persisted profile selection
and capability verdict (`makeHomeState`; see `docs/architecture.md`) so the replayed open resumes under the right profile — the replay fires before
the list's `.task` prefs reload.

## Internal agent forks never push (#64)

Plugin-side only — no iOS/gateway change: a `delegate_task`/`curator` child fires the same hooks
mid-parent-turn with `platform == "subagent"`/`"curator"` and its own `session_id`, so the
plugin drops its `complete`/`error` and keeps its id out of the approval turn-tracker; approvals
are never filtered and never carry the parent's id. Only those exact values are filtered
(anything else fails open), and the deny-list may only ever be widened to a fork that owns its
`session_id` — `agent/background_review.py` (inherits the parent's `platform` AND `session_id`)
is the known-unfixed second root cause. The normative contract lives in the plugin's
`triggers.py`.
