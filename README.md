<div align="center">

<img src="HermesMobile/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" alt="Hermes Mobile" width="120" />

# Hermes Agent Mobile Companion

**Drive your self-hosted Hermes agent from your iPhone.**

Chat with sessions, watch the agent work in real time, and approve or clarify its
actions — all from your pocket, while the real runtime stays on your Mac or server.

<img src="app-store-preview.png" alt="Hermes Mobile screenshots" width="100%" />
<br/>

Native SwiftUI · [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) · no agent logic on the phone

</div>

## What it does

Hermes Mobile is a thin remote client for a self-hosted
**[Hermes Agent](https://github.com/NousResearch/hermes-agent)**. The agent
keeps running on your machine; the phone is a window into it — so you can step away
from your desk and still keep your agent moving.

- **Connect once.** Enter your server URL and sign in the way your agent is configured:
  a username and password when the server runs gated auth (the recommended setup), or a
  static token (loopback/`--insecure`). The app detects which methods the server offers
  and shows the right fields. Credentials live in the iOS Keychain and the app
  auto-logs-in on launch; if a gated session expires while you're using it, a quick
  re-auth prompt gets you back in without losing your place. And if the agent simply
  isn't reachable at launch — VPN/Tailscale off, no internet, agent down — you get a
  retry screen naming the server instead of a sign-in form (it retries by itself when
  you foreground the app, right after you flip the VPN on); only a real rejection sends
  you back to sign-in.
- **Find any session.** Browse sessions grouped by workspace, search across all of
  them, pin the ones you care about, rename or archive them — or permanently delete
  the ones you're done with, from the main list or the archived view (a Settings
  option picks whether a full swipe archives or deletes) — and resume or start a
  new one.
- **Switch profiles.** Keep multiple Hermes profiles on one agent and switch between
  them from a Safari-style header pill — each profile has its own scoped session list,
  and new chats are created under the selected one. Create custom profiles (with an
  optional SOUL.md) right from the app.
- **Watch it work.** Streaming responses render as native Markdown, with tool/skill
  activity rows (tap for args, results, and diffs), a live "Thinking" indicator with an
  elapsed timer that collapses into a reviewable reasoning + status disclosure when the
  turn ends, and a subtle glow on sessions that are actively running. When the agent's
  background self-improvement review posts a summary, it shows up right in the chat as
  a system line (live sessions only).
- **Compose hands-free or with files.** Dictate a message with voice input (a live
  waveform while recording; transcribed by your agent), and attach photos, camera
  captures, PDFs, or any file straight from the composer — or just paste a copied
  screenshot into the message field.
- **Queue the next prompt while it works.** Mid-turn, the send button comes back the
  moment you type: your draft (text and attachments) queues above the composer and
  fires automatically as the next turn when the current one finishes. Queued messages
  can be edited, deleted, or sent immediately (interrupting the running turn) from
  their context menu; stopping a turn holds the queue instead of firing it.
- **Run slash commands.** Type `/` in the composer to pull up the agent's command
  catalog — built-ins like `/compress`, `/undo`, `/status`, plus your installed
  skills — with as-you-type filtering and tap-to-insert. Commands execute through
  the agent's real slash pipeline (skill commands stream like a normal turn), so
  mid-conversation session control works from your pocket. On agents without
  command support the composer simply behaves as before.
- **See how full the context is.** A color-coded pill in the composer shows
  used/max tokens and percent (mirroring the Hermes TUI thresholds); tap it for a
  breakdown of input/output split, compactions, and estimated cost.
- **Copy what you need.** Copy a whole message, or just a single code block with a
  one-tap button and a green-check confirmation — or grab a session's id from its
  long-press menu (or the chat's ⋯ menu) when you need to cross-reference it with the
  agent's CLI or logs.
- **Branch a reply into a new chat.** Every finished assistant message has a branch
  button that starts a fresh session seeded with just that message — explore a tangent
  without derailing the original conversation. Branches show nested under their parent
  in the session list, desktop-style.
- **Approve from anywhere.** The mobile-native payoff: respond to approval, clarify,
  and `sudo`/`secret` prompts the moment they arrive. Even if the app was offline when
  an approval fired, tapping its push notification still surfaces an approve/deny card
  (generic, since no command content ever transits the push gateway) — with honest
  "already handled elsewhere" feedback if it was resolved on another client.
- **Stays connected.** Automatic reconnect with backoff and a clear connection banner
  when the link drops. Reopening a session — after navigating away, backgrounding the app,
  or a cold relaunch — restores its live state: the right model, context usage, full
  tool/thinking history, and an in-progress turn that keeps streaming with its timer ticking.
  A running turn even keeps its live connection while you browse the session list, and for a
  short grace window after backgrounding — falling back to reconnect-and-restore beyond that.
- **Get pinged when it needs you.** Opt in to push notifications and the agent can ping
  your phone — even when the app is closed — when it needs an approval, asks you to
  clarify, finishes a longer turn, or hits an error. This rides a three-part
  setup: a plugin on your own agent triggers the notification, a tiny stateless gateway
  the app's publisher operates forwards it to Apple Push (it's the only place the APNs
  key can safely live), and the app deep-links you straight to the session. Privacy by
  design: only a generic title/body and the `session_id` ever transit the gateway — the
  real message content is fetched in-app over your private network, never through Apple.

## Quick start

You'll need macOS with **Xcode 26+**, **Tuist** (`brew install tuist`), and a running
Hermes Agent reachable from your Mac.

**1. Expose Hermes to your network.** On the Hermes machine, run this in a terminal to
add your credentials to `~/.hermes/.env` — edit the username and password first (most
special characters are fine in the password — but the agent's .env parser treats a few
specially: avoid `${…}`, quotes around the whole value, and `#` after a space; the secret
is generated for you and keeps you signed in across agent restarts; running the `echo`
line in a shell matters — Hermes reads `.env` without shell expansion, so a pasted
`$(openssl …)` would become a literal secret):

```sh
cat >> ~/.hermes/.env <<'EOF'
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=you
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=…
EOF
echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)" >> ~/.hermes/.env
```

Then launch the dashboard so other devices can reach it — password login switches on
automatically as soon as the dashboard is reachable beyond the machine itself
(a non-loopback bind without `--insecure`):

```sh
hermes dashboard --host 0.0.0.0 --port 9119 --no-open
```

> ⚠️ Password login is meant for trusted networks and VPNs only. The trust boundary is
> your private network (e.g. Tailscale) — never port-forward the dashboard to the open
> internet.

The app's built-in **Set Up Your Agent** guide (on the sign-in screen) walks you
through this same recipe with copyable commands.

**2. Build and run the app:**

```sh
make run        # builds and launches on a simulator — no signing needed
```

**3. Connect.** Open the app and enter your server URL (e.g.
`http://<tailnet-host>:9119`), pick **Password**, and sign in with the username and
password from step 1. That's it — you're in.

<details>
<summary><strong>Last resort: token mode</strong> (fully trusted networks only)</summary>

A session token is a master key to your agent: anyone holding it can act as you —
indefinitely. Only on a network where every device is one you've explicitly added,
you can skip the password gate by binding with auth disabled and a stable token —
generate and export the token first (the dashboard reads it once at launch; the
`echo` prints the token so you can paste it into the app), then launch:

```sh
export HERMES_DASHBOARD_SESSION_TOKEN=$(openssl rand -hex 32)
echo "$HERMES_DASHBOARD_SESSION_TOKEN"
hermes dashboard --host 0.0.0.0 --insecure
```

Then pick **Token** in the app and paste the printed token. Recent Hermes releases
ignore `--insecure` and always require a login beyond the machine itself — if the
dashboard refuses to start or still asks you to sign in, use the password setup above.
Never expose `--insecure` to the public internet.

</details>

For the full web-dashboard reference (hashed passwords, more auth providers), see the
[Hermes dashboard docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard).

To run on a physical device, see [`docs/development.md`](docs/development.md).

## Documentation

- [**Website**](https://goncharik.github.io/hermes-mobile/) — features,
  screenshots, quick start, and current progress (served from [`site/`](site/)).
- [**Architecture**](docs/architecture.md) — how the app is structured, the TCA
  feature tree, dependency clients, and the wire protocol.
- [**Development**](docs/development.md) — building, running on device, testing,
  snapshots, and TestFlight distribution.

## Status

The MVP is feature-complete and shipping to TestFlight — the full loop (connect,
browse/search/resume/create, stream, approve/clarify) is built and covered by unit and
SwiftUI snapshot tests. It's a personal tool first, designed to run over a private
network.

## License

[MIT](LICENSE) © Eugene Honcharenko
