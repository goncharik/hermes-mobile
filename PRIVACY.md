# Privacy Policy

**Hermes Mobile** · Effective date: November 5, 2026

Hermes Mobile is an iPhone and iPad app for controlling a [Hermes Agent](https://github.com/NousResearch/hermes-agent)
that you run yourself, on your own computer or server. This policy explains what the app
does with your information. The short version: the app talks to your own agent and keeps
what it needs on your device. The developer never receives your conversations, files or
credentials.

## What the developer collects

Hermes Mobile has no analytics, no advertising, no tracking, and no third-party SDKs or
services. There is no Hermes Mobile account.

The only data that passes through a server the developer runs is for push notifications, and
only if you turn them on: your device's notification token, a session identifier and a
generic title and body, used only to deliver the notification (see
[Push notifications](#push-notifications)).

## Your Hermes agent

The app connects only to the server address you enter when you sign in, which is your own
Hermes Agent. Everything you do in a chat travels directly between the app and that agent:

- the messages you send and the replies you receive;
- photos, camera captures, PDFs and other files you attach;
- voice recordings, which your agent transcribes into text;
- replies you choose to have read aloud, which your agent turns into speech;
- files on your agent's machine that you open for preview.

What your agent does with this data, for example sending prompts to an AI model provider,
depends on how you have configured it and on the policies of the services it uses. This app
has no control over that.

## Signing in

Your sign-in credentials (an access token, the session cookies from a password sign-in, or
the tokens from an OAuth sign-in) are stored in the iOS Keychain on your device and are sent
only to your agent.

If your agent offers sign-in through an identity provider (OAuth), the provider's sign-in
page opens in a secure Safari sheet. That page is run by the provider and covered by its own
privacy policy. The result returns to the app on your device and is never routed through the
developer.

## What is stored on your device

- **Keychain:** your sign-in credentials.
- **App preferences:** the server address, pinned sessions, which sessions you have read,
  your default swipe action, the selected agent profile, the "read replies aloud" setting,
  the "Live Activity" and "Show session titles" settings, your notification device token, and
  when to show the notifications prompt again.
- **Widget data:** a file shared with the app's widgets (`widget-sessions.json`) holding up
  to 5 session titles, their workspace folder names, whether each is working or waiting on
  you, and when each was last updated. Only the widgets read it.
- **Live Activity:** while agents are running, the Lock Screen and the Dynamic Island show
  how many are active and the title of the session that needs you or is working. Turn off
  "Show session titles" to show its workspace folder instead, or "Live Activity" to hide it.
- **Chat cache:** a local database with recent messages from up to 50 sessions, so chats
  appear instantly when you open them. Your agent remains the source of truth, and the
  cache is refreshed from it.

Signing out (Settings → Sign out) deletes your credentials and the chat cache, resets the
preferences that belong to that server, replaces the widget data with a signed-out state and
ends the Live Activity. The app icon you choose is remembered by iOS itself.

## Push notifications

Notifications are optional and off until you turn them on. They also require the
`hermes-push` plugin on your agent.

When you turn them on, the app gives your agent the device token that Apple assigns for
notifications, along with the app version. When your agent needs your attention, its plugin
sends that token, a generic title and body, and a session identifier to a small push gateway
operated by the developer. The gateway forwards the notification to Apple Push Notification
service, which delivers it to your device.

A notification never contains message text, commands, tool arguments or anything else from
your conversation. When you tap one, the app fetches the content directly from your agent.
You can turn notifications off at any time in iOS Settings. Technical details:
[docs/features/push-notifications.md](docs/features/push-notifications.md).

## Feedback and diagnostics

- **Report a bug / Request a feature** opens a new GitHub issue in your browser, prefilled
  with the app version, build number, iOS version and device model. Nothing is sent unless
  you submit the issue on GitHub. GitHub issues are public and covered by GitHub's privacy
  policy.
- **Rate Hermes Mobile** (once the app is on the App Store) opens its App Store review page.
- **Copy diagnostics** (Settings → About → Diagnostics) copies a text report to your
  clipboard only when you tap it. The report contains the app version and build, iOS
  version, device model, your server address (without any user name, password or query
  parameters), your sign-in method with your user name or ID, your agent's version, and short excerpts
  of recent connection events (up to 80 characters each, which can include fragments of
  messages or commands). It never includes your token, password, cookies or OAuth tokens.
  The app does not send the report anywhere; you decide where to paste it, so review it
  before sharing.

## Crash reports from Apple

If you have chosen to share analytics with app developers in your iOS settings, or you test
the app through TestFlight, Apple may share crash reports and basic usage statistics with
the developer. This happens under Apple's privacy policy and settings, not through the app.

## Permissions

The app asks for access to the microphone (voice input), the camera (to attach a photo), the
local network (to reach your agent), and notifications (if you turn them on). Each is used
only for the feature that asked for it. Attaching from your photo library uses the system
photo picker, which gives the app only the photos you select.

## Changes to this policy

Any change will be published in this file with a new effective date. The full history is in
the project's Git repository.

## Contact

Questions or concerns: open an issue at
[github.com/goncharik/hermes-mobile/issues](https://github.com/goncharik/hermes-mobile/issues).
