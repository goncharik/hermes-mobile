# Agent update from Settings

Settings → Server shows, under the Agent version row, whether the connected Hermes agent
can be updated and, for a git install with commits available, an **Update** button. After a
confirmation the phone asks the server to run `hermes update` (the same action as the
dashboard's update button) and follows it to a verdict. Reducer: `AgentUpdateFeature`
(scoped into `SettingsFeature.agentUpdate`); view: `AgentUpdateRows`; wire models:
`Models/AgentUpdate.swift`; tests: `AgentUpdateTests`.

## Server contract

All three are dashboard endpoints (`hermes_cli/web_routers/actions.py`), sent with the app's
normal dashboard credential (token header, session cookie or bearer).

| Call | When | Notes |
|---|---|---|
| `GET /api/hermes/update/check?force=true` | every Settings appearance; "Check for updates" | `force` busts the 24 h cache. `can_apply` is true only for git installs; `message` carries guidance for the others. |
| `POST /api/hermes/update` | once, after the confirmation | `{ok, pid, action_id}`; `{ok, already_running: true}` when another update holds the lock; a 2xx `{ok:false, message}` refusal for docker/nix/apt/managed installs. |
| `GET /api/actions/hermes-update/status?lines=1` | recovery, polling, "Check update status" | `running`, `exit_code`, `action_id` (present only once that run logged its success marker) and `receipt`, a summary of this action's receipt or else the newest receipt of any run. Current agents put the writer's `action_id` in it. |

A 404 (or 405 from an older agent's catch-all) on the check, or a 401/403, hides the whole
feature silently. Token mode with an empty token has no dashboard credential and never
probes. Saving a token in Settings re-runs the probe with it at once, so the updater can
appear without reopening Settings. The recovery status read is sent only after the check
proved the endpoints exist.

**Authorization caveat:** the dashboard has no per-user admin role. Any credential the
dashboard accepts can start an update, from the app or anywhere else. The app adds a
confirmation, not an authorization layer.

## Invariants

- **One POST per confirmation, never retried.** A transport failure, offline error,
  undecodable reply or any 5xx (a proxy's 502/503/504 included) after sending is
  ambiguous: the server may have started. It becomes
  `.uncertain`, which offers only the read-only "Check update status". There is no
  automatic retry and no second Update button until a status read settles it.
- **Never treat a reconnect as success.** The update restarts the dashboard and gateways, so
  the connection dropping and coming back proves nothing. Polling tolerates the drop.
  Success needs a finished receipt (`finished_at` set) proven to be this phone's run:
  either the receipt names our `action_id`, or (older agents whose receipts carry no id)
  the status `action_id` is ours, meaning our run logged its success marker. A failure may
  also be matched by time (receipt `started_at` at or after our POST, whole seconds),
  because a wrong "failed" is safe and a wrong "succeeded" is not. Outcomes the app
  doesn't know settle as unknown.
- **Ownership persists.** The POST's `action_id` and the POST time are saved
  (`PreferencesClient.saveOwnedAgentUpdate`, `OwnedAgentUpdate`) inside the effect, before
  the result reaches the reducer, through an unstructured task so dismissing Settings
  mid-request can't drop it. Reopening Settings or relaunching the app re-observes that run
  read-only instead of offering a new start. The slot holds no secret and is scoped to
  server origin plus account (`ServerConnection.agentUpdateScope`, a SHA-256, never the
  credential). A different scope drops it. Clearing is compare-and-clear by action id, so
  settling an old run can't erase a newer one. Logout clears it.
- **Read fencing.** Every check, status read and poll runs under one cancel ID.
  Appearing, confirming, rechecking and settling cancel whatever read is still in flight,
  and a cancelled effect's answer never reaches the reducer, so a slow response from an
  earlier phase (for example a recovery read that saw someone else's run) can't relabel
  the current one. The POST is outside that ID: its result always lands.
- **Not ours is never ours.** `already_running`, a running action we don't own, or a status
  naming another action id shows "An update started elsewhere is running", never a
  success. If the server has moved on to another action, ours is released as unknown.
- **Bounded.** Polling runs every 5 s for at most 30 minutes while Settings is open, then
  shows unknown. Three idle reads with nothing to correlate release ownership as unknown, so
  a receipt that never arrives can't block the updater for good. While our success marker
  is logged but our receipt isn't finalized (restart and verify steps), the app keeps
  following it, and one explicit status check after the poll budget releases it.
- **Only git installs get the button.** `can_apply && update_available`. Docker, nix, apt
  and managed installs show the server's `message` and no button.

## Confirmation

"Update Hermes agent?" with the warning that `hermes update` runs on the server and
restarts it, and that every session on that install may be interrupted, including the
dashboard and messaging gateways. Rendered with `.bottomActionSheet` like other
confirmations (iOS 26 `confirmationDialog` issue, see `BottomActionSheet.swift`).

## States (`AgentUpdateFeature.State.Phase`)

`hidden` · `checking` · `ready` (button or guidance) · `starting` · `running` (ours) ·
`externalRunning` · `succeeded(version)` (Agent row adopts the receipt's version via
`.delegate(.updated)`) · `failed(reason)` · `uncertain`.
