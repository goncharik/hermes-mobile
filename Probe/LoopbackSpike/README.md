# Loopback OAuth spike

Task 1 of `docs/plans/20260905-oauth-native-pkce-sign-in.md`. Answers one question:

> Can an `ASWebAuthenticationSession` browser redirect reach an `NWListener` the app
> itself holds on loopback?

**Outcome and findings live in `docs/features/oauth-sign-in.md` → "Spike outcome".**

This harness is **not part of any shipped target**. `Project.swift` globs
`HermesMobile/Sources/**` only, and `run.sh` builds this file with a bare `swiftc`
invocation into a hand-assembled `.app` bundle — no Xcode project, no Tuist, no SPM
target. `build/` is gitignored.

## Run

```sh
python3 Probe/LoopbackSpike/redirect_server.py 8099 &   # stands in for /auth/native/authorize
xcrun simctl boot <simulator-udid>
Probe/LoopbackSpike/run.sh <simulator-udid> [ios-deployment-version]
```

Then tap one of:

- **Run IPv4** — listener on `127.0.0.1`, redirect `http://127.0.0.1:<port>/callback`,
  auto-`cancel()` 6 s after the callback lands (time to screenshot the served page).
- **Run IPv6** — same with `[::1]`.
- **No cancel** — never cancels programmatically, so you can dismiss the sheet by hand
  and observe what the completion handler receives.

The first `start()` raises the system consent alert (`"…" Wants to Use "…" to Sign In`);
tap Continue.

Results appear in the on-screen log and in

```sh
$(xcrun simctl get_app_container <udid> me.honcharenko.LoopbackSpike data)/Documents/spike.log
```
