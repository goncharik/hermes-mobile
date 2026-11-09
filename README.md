<div align="center">

<img src="HermesMobile/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" alt="Hermes Mobile" width="120" />

# Hermes Agent Mobile Companion

**Drive your self-hosted Hermes agent from your iPhone or iPad.**

Chat with sessions, watch the agent work in real time, and approve or clarify its
actions — all on the go, while the real runtime stays on your Mac or server.

**[Join the public TestFlight beta →](https://testflight.apple.com/join/SyHGvf9n)**

<img src="app-store-preview.png" alt="Hermes Mobile screenshots" width="100%" />
<br/>

Native SwiftUI · [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) · no agent logic on the device

</div>

## What it does

Hermes Mobile is a thin remote client for a self-hosted
**[Hermes Agent](https://github.com/NousResearch/hermes-agent)**. The agent
keeps running on your machine; your iPhone or iPad is a window into it — so you can step
away from your desk and still keep your agent moving.

- **Connect once.** Enter your agent's address — a bare host name is enough, since the app
  also tries the dashboard's default port 9119 — and the app checks it before asking you to
  sign in. If the address doesn't work, a card says what went wrong and what to try: Tailscale
  is off, the dashboard isn't running, the agent rejected the address, the certificate isn't
  trusted, or the phone is offline. Then sign in the way your agent is configured:
  a username and password when the server runs gated auth (the recommended setup), your
  identity provider via OAuth (Nous Research or your own OIDC server — it opens in Safari,
  so your existing session and passkeys just work), or a static token
  (loopback/`--insecure`). The app detects which methods the server offers and shows the
  right options. Credentials live in the iOS Keychain and the app
  auto-logs-in on launch; if a gated session expires while you're using it, a quick
  re-auth prompt gets you back in without losing your place. And if the agent simply
  isn't reachable at launch — VPN/Tailscale off, no internet, agent down — you get a
  retry screen naming the server instead of a sign-in form (it retries by itself when
  you foreground the app, right after you flip the VPN on); only a real rejection sends
  you back to sign-in.
- **Find any session.** Browse sessions as inbox-style cards (workspace, title, preview,
  model, message count) sorted into Today / Yesterday / Last week… sections, search
  across all of them, pin the ones you care about, rename or archive them — or
  permanently delete the ones you're done with, from the main list or the archived
  view (a Settings option picks whether a full swipe archives or deletes) — and
  resume or start a new one. Cron jobs get their own tab: see each job's status and
  recent runs, and run, pause, resume or delete it.
- **Switch profiles.** Keep multiple Hermes profiles on one agent and switch between
  them with one tap from a Safari-style header pill — each profile has its own scoped session list,
  and new chats are created under the selected one. Create custom profiles (with an
  optional SOUL.md) right from the app.
- **Watch it work.** Streaming responses render as native Markdown. A running turn shows
  the agent's live status and an elapsed timer; when it finishes, its tool calls, reasoning
  and interim commentary fold behind one "Worked for …" line above the reply. Expand it to
  see run summaries ("Ran 6 commands and read 5 files") and per-call lines that open in
  place to terminal output, diffs, file reads or search hits, with the full payload a tap
  away. A reopened session keeps each call's target and file edits; command output and
  search results are shown for live turns only. Sessions that are actively running get a subtle glow. When the agent's
  background self-improvement review posts a summary, it shows up right in the chat as
  a system line (live sessions only).
- **Compose hands-free or with files.** Dictate a message with voice input (a live
  waveform while recording; transcribed by your agent), and attach photos, camera
  captures, PDFs, or any file straight from the composer — or just paste a copied
  screenshot into the message field.
- **Hear the replies.** Turn on "Read replies aloud" from the composer and the newest finished
  reply is spoken by your agent's TTS provider, with a "Reading aloud" pill to stop it and the
  screen kept awake while you listen. You can also read any single reply from its action bar.
  Sending a message or tapping the mic cuts playback off. On agents without text-to-speech
  the controls simply don't appear.
- **Queue the next prompt while it works.** Mid-turn, the send button comes back the
  moment you type: your draft (text and attachments) queues above the composer and
  fires automatically as the next turn when the current one finishes. Queued messages
  can be edited, deleted, or sent immediately (interrupting the running turn) from
  their context menu; stopping a turn holds the queue instead of firing it.
- **Run slash commands.** Type `/` in the composer to pull up the agent's command
  catalog — built-ins like `/compress`, `/undo`, `/status`, plus your installed
  skills — with as-you-type filtering and tap-to-insert. Commands execute through
  the agent's real slash pipeline (skill commands stream like a normal turn), so
  mid-conversation session control works on the go. On agents without
  command support the composer simply behaves as before.
- **See how full the context is.** A color-coded pill in the composer shows
  used/max tokens and percent (mirroring the Hermes TUI thresholds); tap it for a
  breakdown of input/output split, compactions, and estimated cost.
- **Switch model and reasoning.** Tap the `model · effort` chip to pick from the providers
  you've configured. Star models to pin them in a Favorites card, collapse providers you
  rarely use, and search across them all. The sheet opens centered on the current model,
  and Reasoning sets the effort level (`none` … `ultra`).
- **Copy what you need.** Copy a whole message, or just a single code block with a
  one-tap button and a green-check confirmation — or grab a session's id from its
  long-press menu (or the chat's ⋯ menu) when you need to cross-reference it with the
  agent's CLI or logs.
- **Open the files it made.** When the agent mentions a file on its host — a report, a
  screenshot, a log, a `/workspace/...` path — the path is a tappable link right in the
  message. Text files, images and PDFs preview in a sheet; anything else shows a card
  with the name, path and size. Copy the path, or Share the file to Files, AirDrop or
  Mail without ever walking over to the machine.
- **Branch a reply into a new chat.** Every finished assistant message has a branch
  button that starts a fresh session seeded with just that message — explore a tangent
  without derailing the original conversation. Branches show nested under their parent
  in the session list, desktop-style.
- **Approve from anywhere.** The mobile-native payoff: respond to approval, clarify,
  and `sudo`/`secret` prompts the moment they arrive. Clarify questions come in every
  form the desktop app shows: pick one choice, tick several, type your own answer with
  "Other", or work through a batch of up to five questions on one card (the agent's
  recommended choice is marked, never preselected). When several prompts are waiting,
  they queue and show one at a time. Lost the connection, or opened the app from a push
  notification? The open prompts come back exactly as the agent asked them, with the
  command or question in full (no content ever transits the push gateway). If you
  answer something already handled on another client, the app says so. Works with
  current Hermes releases, which send prompts as server requests, and with older agents
  that still use the event-based prompts (there, a push tap brings back a generic
  approve/deny card, and the newer clarify forms are not available).
- **Stays connected.** Automatic reconnect with backoff and a clear connection banner
  when the link drops. On current Hermes releases a reconnect also catches up on what a
  running turn did while you were offline: the tool calls and reasoning from the gap show up
  right away instead of when the turn ends. Reopening a session — after navigating away,
  backgrounding the app, or a cold relaunch — restores its live state: the right model,
  context usage, its tool-call and reasoning history, and an in-progress turn that keeps streaming
  with its timer ticking.
  A running turn even keeps its live connection while you browse the session list, and for a
  short grace window after backgrounding — falling back to reconnect-and-restore beyond that.
- **Native on iPad.** In a wide window the session list sits in a sidebar next to the
  open chat (side by side in landscape, an overlay sidebar in portrait), the sidebar
  highlights the session you're viewing, the chat column stays a readable width, and a
  new chat opens on an empty-state hero instead of a blank screen. Slide Over and
  narrow windows fall back to the phone layout.
- **Get pinged when it needs you.** Opt in to push notifications and the agent can ping
  your device — even when the app is closed — when it needs an approval, asks you to
  clarify, finishes a longer turn, or hits an error. This rides a three-part
  setup: a plugin on your own agent triggers the notification, a tiny stateless gateway
  the app's publisher operates forwards it to Apple Push (it's the only place the APNs
  key can safely live), and the app deep-links you straight to the session. Privacy by
  design: only a generic title/body and the `session_id` ever transit the gateway — the
  real message content is fetched in-app over your private network, never through Apple.
  The app never asks for permission out of the blue: after you sign in, the session list
  shows a **Turn on** card (or, when the plugin is missing, one that asks your agent to
  install it), and **Not now** snoozes it. A row of getting-started tips sits below it until
  you hide it.
- **Start a chat without opening the app first.** "New Hermes chat" and "Dictate to Hermes"
  work from Shortcuts, Siri, Spotlight and the app icon's long-press menu with no setup, and
  can be assigned to the Action button (iPhone 15 Pro and later): the app opens on a fresh
  chat under your selected profile, and the dictation shortcut starts the mic as soon as the chat appears.
- **Keep an eye on it from the Home Screen.** A quick-actions widget starts a chat, a photo
  or a dictation in one tap; a sessions widget lists your latest sessions with which ones are
  working or waiting on you; New Chat and Dictate controls sit in Control Center and on the
  Lock Screen. While agents run, a Live Activity on the Lock Screen and in the Dynamic Island
  counts them and headlines the session that needs you, else the one at work (turn it off,
  or hide session titles, in Settings). Everything is local: when the app can no longer see
  your agents, the widgets and the activity say "Outdated" instead of guessing.
- **Make it yours.** Pick the home-screen icon from eight designs in Settings: the gold and
  blueprint originals plus six Hermes variants. Settings also gathers everything else in
  one place: the server you're connected to and how you signed in, notifications, a
  one-tap bug report or feature request that opens GitHub with your app version, iOS
  version and device already filled in, and an About section with the version, the
  privacy policy, open-source acknowledgements, and a diagnostics report you can copy
  into an issue (it never includes your credentials).

## Get the app

Install it from the **[public TestFlight beta](https://testflight.apple.com/join/SyHGvf9n)**
(iPhone and iPad, iOS 18+). The app is only the remote control: you still need a running
Hermes Agent your device can reach over your network or VPN. Do step 1 of the quick start
below on the agent machine (the app's built-in **Set Up Your Agent** guide walks you
through the same recipe), then connect as in step 3. Building from source is only needed
if you want to hack on the app.

## Quick start

You'll need macOS with **Xcode 26+**, **Tuist** (`brew install tuist`), and a running
Hermes Agent reachable from your Mac.

> **Hermes Cloud runs your agent for you.** Open your agent in the Nous portal, copy its
> address, and paste it into Hermes Mobile's agent address field. You'll sign in with your
> Nous Research account.
> No agent yet? Create one in the [Nous portal](https://portal.nousresearch.com).
>
> That's the guide's **Hermes Cloud** tab: with a cloud agent, skip step 1 below. The
> steps below are the **On my computer** tab.

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

The app's built-in **Set Up Your Agent** guide (on the Welcome and server address screens,
and on every connection-failure card) walks you through this same recipe with copyable
commands.

**2. Build and run the app:**

```sh
make run        # builds and launches on a simulator — no signing needed
```

**3. Connect.** Open the app, enter your server address (e.g. `<tailnet-host>` or
`http://<tailnet-host>:9119`) and tap **Continue**, then sign in with the username and
password from step 1 (or **Continue with Nous Research** for a Hermes Cloud agent). That's
it — you're in.

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

Then paste the printed token into the token field on the app's sign-in screen (under
**Other ways to sign in** if a password form shows). Recent Hermes releases
ignore `--insecure` and always require a login beyond the machine itself — if the
dashboard refuses to start or still asks you to sign in, use the password setup above.
Never expose `--insecure` to the public internet.

</details>

For the full web-dashboard reference (hashed passwords, more auth providers), see the
[Hermes dashboard docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard).

To run on a physical device, see [`docs/development.md`](docs/development.md).

## Documentation

- [**Architecture**](docs/architecture.md) — how the app is structured, the TCA
  feature tree, dependency clients, and the wire protocol.
- [**Development**](docs/development.md) — building, running on device, testing,
  snapshots, and TestFlight distribution.
- [**Privacy policy**](PRIVACY.md) — what the app stores on your device and what it
  sends where (in short: your conversations go only to your own agent).

## Status

The MVP is feature-complete and shipping to TestFlight — the full loop (connect,
browse/search/resume/create, stream, approve/clarify) is built and covered by unit and
SwiftUI snapshot tests. It's a personal tool first, designed to run over a private
network.

## License

[MIT](LICENSE) © Eugene Honcharenko
