import AppIntents

// App Shortcuts (#93): make the launch intents discoverable in Shortcuts / Siri /
// Spotlight without setup. Home Screen icon Quick Actions are a separate UIKit surface;
// their static Info.plist entries and delegate routing live in `Project.swift` and
// `PushAppDelegate.swift`.
struct HermesAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartNewSessionIntent(),
      phrases: [
        "New \(.applicationName) chat",
        "Open \(.applicationName)",
      ],
      shortTitle: "New Chat",
      systemImageName: "plus.message"
    )
    AppShortcut(
      intent: StartNewSessionWithDictationIntent(),
      phrases: [
        "Dictate to \(.applicationName)",
        "Talk to \(.applicationName)",
      ],
      shortTitle: "Dictate",
      systemImageName: "mic.badge.plus"
    )
  }
}