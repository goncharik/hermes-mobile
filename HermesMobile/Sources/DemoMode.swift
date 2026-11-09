#if DEBUG
import ComposableArchitecture
import Foundation
import HermesKit

/// Seeded "demo mode" used **only** for App Store screenshot capture (never shipped in
/// Release — the whole file is `#if DEBUG`). Activated by the `HERMES_DEMO` env var, whose
/// value selects a scenario. Each scenario builds a fully-seeded `AppFeature.State` plus a
/// set of inert dependency overrides so no live socket/REST traffic mutates the curated
/// state on screen.
///
/// Launch from the host shell with, e.g.:
///   SIMCTL_CHILD_HERMES_DEMO=chat xcrun simctl launch <udid> me.honcharenko.HermesMobile
enum DemoMode {
  /// The selected scenario name, or `nil` when the env var is unset (normal launch).
  static var scenario: String? {
    guard let raw = ProcessInfo.processInfo.environment["HERMES_DEMO"]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else { return nil }
    return raw.lowercased()
  }

  static var isActive: Bool { scenario != nil }

  // Fixed reference values so relative timestamps render deterministically.
  private static let now = Date(timeIntervalSince1970: 1_749_600_000)
  /// Pinned so the date-section headers never depend on the capture device's time zone:
  /// `now` is Wed 11 Jun 2025 00:00 UTC, i.e. still Tue 10 Jun's nominal day (4 AM
  /// rollover), with a Monday-first week.
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = 2
    return calendar
  }()
  private static let connection = ServerConnection(
    baseURL: URL(string: "http://mac.tailnet:9119")!,
    token: "demo-token"
  )

  /// The "connect" scenario's typed address: a bare Tailscale name (tailnet, so the Sign in
  /// step shows no public-cleartext warning).
  private static let connectAddress = ServerAddress("mac-mini.tail4c2e.ts.net")!

  /// What the "connect" scenario's Server step found: the `:9119` fallback answered, offering
  /// a password and Nous Research sign-in (native PKCE advertised, so the provider shows).
  private static let connectProbe = ServerProbe(
    address: connectAddress,
    baseURL: connectAddress.candidates.last!,
    capability: ServerAuthCapability(
      passwordProvider: AuthProvider(name: "basic", displayName: "Password", supportsPassword: true),
      oauthProviders: [AuthProvider(name: "nous", displayName: "Nous Research", supportsPassword: false)],
      supportsNativeFlow: true
    ),
    version: "0.19.2"
  )

  /// Build the root store for the active scenario.
  static func makeStore() -> StoreOf<AppFeature> {
    let scenario = self.scenario ?? "chat"
    return Store(initialState: state(for: scenario)) {
      AppFeature()
    } withDependencies: { deps in
      configure(&deps)
    }
  }

  // MARK: Dependency overrides

  private static func configure(_ deps: inout DependencyValues) {
    // Never open a real socket — a never-emitting stream keeps the seeded transcript /
    // ready status frozen exactly as authored.
    deps.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
    // Session-list refresh + poll return the seeded sessions unchanged — both the unscoped
    // (`rest.sessions`) and the profile-scoped (`profiles.sessions`) fetch paths. Both
    // source slices get the same page, which the list merges back to one copy.
    deps.hermesREST.sessions = { _, _, _, _, _ in seededSessions }
    deps.hermesProfiles.sessions = { _, _, _, _, _, _, _ in seededSessions }
    // The agent always exposes the default profile, so the "default" pill is always present.
    deps.hermesProfiles.list = { _ in [Profile(name: "default", isDefault: true)] }
    // Keep the Cron Jobs tab frozen on the seeded jobs across polls, and serve each job's
    // runs from the seed when its row is expanded (the real `/runs` endpoint binds runs by
    // job, whatever their session ids look like).
    deps.hermesREST.cronJobs = { _, _ in seededCronJobs }
    deps.hermesREST.cronJobRuns = { _, jobID, _, _ in seededCronRuns[jobID] ?? [] }
    // "notify" needs REAL notification permission (the panel captures a live banner from
    // `simctl push`), so report the plugin ready and the permission as granted → the reducer
    // registers "silently", which on a fresh simulator runs the OS permission prompt with no
    // Turn on card in the backdrop. Every other scenario reports unknown: no prompt, no card,
    // no live REST.
    let pushStatus: PushPluginStatus = scenario == "notify" ? .ready : .unknown
    deps.hermesREST.pushPluginStatus = { _ in pushStatus }
    if scenario == "notify" {
      deps.push.authorizationStatus = { .authorized }
    }
    // Settings probes the same hub for the plugin's version. Report no version so the demo
    // never renders the "plugin update available" row in a screenshot.
    deps.hermesREST.pushPluginInfo = { _ in PushPluginInfo(status: pushStatus) }
    // Deterministic relative timestamps and date-section headers.
    deps.date = .constant(now)
    deps.sessionListCalendar = calendar
    // Persisted UI prefs, pre-seeded so `reloadPrefs` keeps our curated pins/unread state.
    deps.preferences = demoPreferences
    // An App Intent (#93) fired during a capture must not swap the curated chat for a new
    // one: the demo store never observes the intent stream (the app still just opens).
    deps.launchIntents.incoming = { AsyncStream { _ in } }
    // The seeded rows must not overwrite the real widget mirror, nor start a Live Activity
    // (already "Outdated" under the pinned date) in a capture. Activities still read as
    // allowed, so Settings shows its normal footer, not the "turned off in iOS Settings" one
    // (a start then fails quietly).
    deps.widgetMirror = .noop
    var liveActivity = LiveActivityClient.noop
    liveActivity.areActivitiesEnabled = { true }
    deps.liveActivity = liveActivity
  }

  private static var demoPreferences: PreferencesClient {
    var client = PreferencesClient.inMemory()
    client.loadServerURL = { connection.baseURL.absoluteString }
    client.loadPinnedIDs = { ["s0"] }
    client.loadSeenCounts = {
      // s1 and the newest digest run have unread activity (seen < messageCount) — the
      // cron run lights its run row's dot under the expanded digest job.
      var seen = Dictionary(uniqueKeysWithValues: seededSessions.map { ($0.id, $0.messageCount ?? 0) })
      seen["s1"] = 6
      seen[newestDigestRunID] = 1
      return seen
    }
    // The App Store captures show the list itself, not the first-run tips row (#136).
    client.loadOnboardingTipsDismissed = { true }
    return client
  }

  // MARK: Scenario → state

  private static func state(for scenario: String) -> AppFeature.State {
    switch scenario {
    // "notify" shares the sessions backdrop — the panel's banner arrives live via
    // `simctl push` after the scenario grants notification permission (see `configure`).
    case "sessions", "notify":
      return AppFeature.State(home: sessionListState)
    case "work":
      return chatScenario(workChat)
    case "voice":
      return chatScenario(voiceChat)
    case "connect":
      // The Sign in step (#136) over an already-answered Server step, as the flow leaves it
      // after a probe: a password + Nous Research agent. Seeded rather than probed, so no
      // live REST call runs (the Server step below it has no auto-probe).
      var onboarding = ConnectionFeature.State()
      onboarding.path.append(.server(ServerStep.State(addressText: connectAddress.typed)))
      onboarding.path.append(.signIn(SignInStep.State(probe: connectProbe)))
      onboarding.lastProbedCapability = connectProbe.capability
      return AppFeature.State(onboarding: onboarding)
    default: // "chat"
      return chatScenario(heroChat)
    }
  }

  /// A chat scenario needs a home (so the nav stack has a root) plus one pushed chat:
  /// the chat state fills the live-chat slot and the path holds its thin marker, carrying
  /// the chat's session key. The marker is the COMPACT presentation (#80): on an iPad the
  /// launch `layoutChanged(.regular)` clears it and the same slot renders as the detail
  /// column instead.
  private static func chatScenario(_ chat: ChatFeature.State) -> AppFeature.State {
    AppFeature.State(
      home: sessionListState,
      path: StackState([ChatScreen.State(sessionKey: chat.sessionKey)]),
      liveChat: chat
    )
  }

  // MARK: Sessions

  private static let seededSessions: [Session] = {
    // Everyday life: planning, research, writing, travel — no dev workspaces. The
    // last-active ages (hours before `now`) spread the unpinned rows across the Today /
    // Yesterday / Last week date sections under "Pinned".
    let rows: [(id: String, title: String, isActive: Bool, hoursAgo: Double)] = [
      ("s0", "Plan a long weekend in Lisbon", false, 40.0 / 60), // 40 min
      ("s1", "Summarize my unread newsletters", true, 2),
      ("s2", "Draft a thank-you note to Sarah", false, 5),
      ("s3", "Weekly meal plan & grocery list", false, 26),
      ("s4", "Compare two health insurance plans", false, 30),
      ("s5", "Birthday gift ideas for Mom", false, 8 * 24),
    ]
    var sessions: [Session] = rows.map { row in
      let lastActive = now.addingTimeInterval(-row.hoursAgo * 3_600)
      return Session(
        id: row.id,
        title: row.title,
        updatedAt: lastActive,
        startedAt: lastActive,
        messageCount: 12,
        isActive: row.isActive
      )
    }
    // The cron run sessions also land in the list's `source=cron` slice, as on a real agent
    // (the jobs alone bring up the Cron Jobs tab); the tab shows runs only under their
    // expanded job, served from `seededCronRuns`.
    sessions.append(contentsOf: seededCronRuns.keys.sorted().flatMap { seededCronRuns[$0] ?? [] })
    return sessions
  }()

  private static let newestDigestRunID = "local-7c41e2a9"

  /// Each seeded job's runs, newest first, as `GET /api/cron/jobs/{id}/runs` returns them.
  /// Opaque `local-*` session ids, like the unified runtime's scheduler gives them — the job
  /// binding is the map key, never the id. Run times match the jobs' schedules (UTC): the
  /// digest ran this morning (unread) and yesterday; the paused sweep ran once.
  private static let seededCronRuns: [String: [Session]] = {
    func run(_ id: String, _ title: String, at seconds: TimeInterval, messages: Int) -> Session {
      let date = Date(timeIntervalSince1970: seconds)
      return Session(
        id: id, title: title, updatedAt: date, startedAt: date, messageCount: messages,
        source: Session.cronSource
      )
    }
    return [
      "digest01": [
        run(newestDigestRunID, "Morning news digest", at: 1_749_538_800, messages: 3), // Jun 10, 07:00
        run("local-3f09b6d2", "Morning news digest", at: 1_749_452_400, messages: 3), // Jun 9, 07:00
      ],
      "sweep02": [
        run("local-a8e5170c", "Evening inbox sweep", at: 1_749_492_000, messages: 2), // Jun 9, 18:00
      ],
    ]
  }()

  /// The cron *jobs* the runs above belong to: the digest is live with a visible
  /// next-run countdown; the sweep is paused (amber pip, "Paused" caption).
  private static let seededCronJobs: [CronJob] = [
    CronJob(
      id: "digest01",
      name: "Morning news digest",
      scheduleDisplay: "every day at 07:00",
      state: "scheduled",
      nextRunAt: Date(timeIntervalSince1970: 1_749_600_000 + 7 * 3_600)  // Jun 11, 07:00: "in 7 hr."
    ),
    CronJob(
      id: "sweep02",
      name: "Evening inbox sweep",
      scheduleDisplay: "every day at 18:00",
      state: "paused"
    ),
  ]

  private static var sessionListState: SessionListFeature.State {
    SessionListFeature.State(
      connection: connection,
      sessions: IdentifiedArray(uniqueElements: seededSessions),
      now: now,
      calendar: calendar,
      pinnedIDs: ["s0"],
      showsOnboardingTips: false, // matches `demoPreferences`: no tips row in the captures
      cronJobs: IdentifiedArray(uniqueElements: seededCronJobs),
      // The digest starts expanded with its runs loaded, so the panel shows job → runs at a
      // glance (the launch load refetches the same seed).
      expandedCronJobID: "digest01",
      expandedCronRuns: seededCronRuns["digest01"]
    )
  }

  // MARK: Chat transcripts

  private static func rowID(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// Panel 1 — hero: a clean everyday Q&A (research / summarize) with one tool call.
  private static var heroChat: ChatFeature.State {
    var state = ChatFeature.State(
      connection: connection,
      title: "Weekend reading",
      transcript: IdentifiedArray(uniqueElements: [
        ChatRow(id: rowID(0), kind: .message(
          role: .user, text: "Summarize the three articles I saved about better sleep.", isComplete: true)),
        ChatRow(id: rowID(1), kind: .tool(
          name: "web_fetch", title: "Read 3 saved articles", state: .complete,
          detail: ToolDetail(resultText: "3 articles"), durationS: 1.1)),
        ChatRow(id: rowID(2), kind: .message(
          role: .assistant,
          text: "## The gist\n\n- **Keep a steady schedule** — same sleep and wake time, even on weekends\n- **Wind down screens** 60–90 min before bed, and dim the lights\n\n| Habit | Payoff |\n| --- | --- |\n| Fixed wake time | Deeper sleep |\n| No caffeine after 2pm | Faster wind-down |\n| Cool, dark room | Fewer wake-ups |",
          isComplete: true)),
        ChatRow(id: rowID(3), kind: .message(
          role: .user, text: "Love it. Remind me to wind down at 10pm tonight?", isComplete: true)),
        ChatRow(id: rowID(4), kind: .tool(
          name: "reminders", title: "Added “Wind down” at 10:00 PM", state: .complete,
          detail: ToolDetail(resultText: "reminder set"), durationS: 0.4)),
        ChatRow(id: rowID(5), kind: .message(
          role: .assistant,
          text: "Done — I'll nudge you at **10:00 pm**. Sleep well 🌙",
          isComplete: true)),
      ]),
      status: .ready
    )
    state.model = "claude-opus-4-8"
    state.usage = .init(contextUsed: 48_000, contextMax: 200_000, contextPercent: 24)
    return state
  }

  /// Panel 3 — "watch it work": the agent researching + acting across tools, live. Internal
  /// so a snapshot pins the panel.
  static var workChat: ChatFeature.State {
    var state = ChatFeature.State(
      connection: connection,
      title: "Lisbon trip",
      transcript: IdentifiedArray(uniqueElements: [
        ChatRow(id: rowID(0), kind: .message(
          role: .user,
          text: "Find 3 well-rated hotels in Lisbon under €150 and add the trip to my calendar.",
          isComplete: true)),
        ChatRow(id: rowID(1), kind: .tool(
          name: "web_search", title: "hotels in Lisbon under €150", state: .complete,
          detail: ToolDetail(args: .object(["query": .string("hotels in Lisbon under €150")]), resultText: "hotels"),
          durationS: 0.9)),
        ChatRow(id: rowID(2), kind: .tool(
          name: "web_fetch", title: "Compared 12 options by rating & price", state: .complete,
          detail: ToolDetail(resultText: "compared"), durationS: 1.6)),
        ChatRow(id: rowID(3), kind: .tool(
          name: "calendar", title: "Adding “Lisbon trip” to your calendar", state: .running,
          detail: nil, durationS: nil)),
        ChatRow(id: rowID(4), kind: .reasoning(
          text: "Shortlisting three places under €150 with the best reviews, then blocking the dates on your calendar.")),
      ]),
      status: .ready
    )
    state.isTurnLive = true
    state.fold.expandedRuns = [RunKey(turnOrdinal: 0, runOrdinal: 0)]
    state.turnSeconds = 7
    state.turnStatus = "Updating calendar…"
    state.model = "claude-opus-4-8"
    state.usage = .init(contextUsed: 96_000, contextMax: 200_000, contextPercent: 48)
    return state
  }

  /// Panel 4 — voice input: the composer mid-recording with a live waveform (writing help).
  private static var voiceChat: ChatFeature.State {
    var state = ChatFeature.State(
      connection: connection,
      title: "Mom's birthday",
      transcript: IdentifiedArray(uniqueElements: [
        ChatRow(id: rowID(0), kind: .message(
          role: .user, text: "Help me write a warm birthday message for my mom.", isComplete: true)),
        ChatRow(id: rowID(1), kind: .message(
          role: .assistant,
          text: "Here's a start:\n\n“Happy birthday, Mom! Thank you for always believing in me — I hope your day is every bit as wonderful as you are.”\n\nWant it more playful, or short enough for a card?",
          isComplete: true)),
      ]),
      status: .ready
    )
    state.recording = .recording
    state.waveformLevels = [0.1, 0.35, 0.6, 0.8, 0.5, 0.25, 0.4, 0.7, 0.9, 0.55, 0.3, 0.15, 0.45, 0.65]
    state.recordingSeconds = 6
    state.model = "claude-opus-4-8"
    return state
  }
}
#endif
