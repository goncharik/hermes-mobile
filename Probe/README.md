# M0 Protocol Probe

A throwaway Swift script that confirms the Hermes wire protocol ("Model A") against
a **real running server** before we build the app. See
`docs/plans/2026-06-09-hermes-ios-mvp.md` → Milestone M0.

`Probe/LoopbackSpike/` is the other harness under this directory — the #19 OAuth loopback spike,
committed rather than throwaway. Its own README covers running it.

## What it does

1. Opens a WebSocket to `<SERVER_URL>/api/ws?token=<HERMES_TOKEN>`.
2. Calls `session.create`, captures the `session_id`.
3. Calls `prompt.submit` with a harmless prompt.
4. Logs every JSON-RPC frame and server event, summarizing payload shapes.
5. Writes all raw frames to `Probe/fixtures/session-events.jsonl` for reuse as a
   reduction-test fixture.

## Prerequisites (on the Hermes machine)

Hermes must be launched so the token path works from a non-loopback host:

```
hermes ... --host 0.0.0.0 --insecure          # disables the OAuth gate
HERMES_DASHBOARD_SESSION_TOKEN=<stable secret> # stable token (survives restarts)
```

The probe machine must reach the server (same tailnet / LAN).

## Run

```sh
SERVER_URL=http://<tailscale-host>:9119 \
HERMES_TOKEN=<your stable token> \
swift Probe/main.swift
```

Optional env: `PROMPT="..."`, `IDLE_TIMEOUT=60`.

## Expected result

`✅ streaming loop confirmed` plus a summary listing the event types observed
(expect at least `gateway.ready`, `session.info`, `message.start`, `message.delta`,
`message.complete`). Any payload-shape surprises should be noted back into the
plan's "Verified WebSocket protocol" section.
