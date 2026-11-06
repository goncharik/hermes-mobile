import AppIntents

// App Shortcuts (#93): make the launch intents available in Shortcuts, Siri, Spotlight and the
// Action button without any setup. Explicit phrases only; there is deliberately no
// "Open <app>" phrase mapped to a new chat.
struct HermesAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartNewSessionIntent(),
      phrases: [
        "New \(.applicationName) chat",
        "Start a chat in \(.applicationName)",
      ],
      shortTitle: "New Chat",
      systemImageName: "plus.message"
    )
    AppShortcut(
      intent: StartNewSessionWithDictationIntent(),
      phrases: [
        "Dictate to \(.applicationName)",
      ],
      shortTitle: "Dictate",
      systemImageName: "mic.badge.plus"
    )
  }
}
