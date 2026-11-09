import Foundation

/// Pure helpers for the push-notification onboarding flow: the canonical plugin name, the
/// install prompt seeded into a new chat composer, the readiness signal derived from the
/// agent's plugin hub, and the Fibonacci snooze schedule for the "Later" backoff.
///
/// Everything here is platform-free and unit-tested — the views/reducers consume these
/// constants and functions rather than redefining copy or math.
public enum PushSetup {
  /// The plugin we look for in the agent's plugin hub (entry-point name on the agent).
  public static let pluginName = "hermes-push"

  /// Public repo for the plugin users install on their own agent.
  public static let pluginURLString = "https://github.com/goncharik/hermes-mobile-push-plugin"

  /// The oldest plugin release the app considers current. Below this we offer an in-app
  /// update (Settings) because the older plugin has a user-visible defect the app cannot
  /// work around from its side.
  ///
  /// `0.2.0` filters delegated-subagent and curator forks, so a finished subagent no longer
  /// fires a misleading "Turn complete" push mid-parent-turn (hermes-mobile #64). A 0.1.0
  /// install pushes once per finished subagent.
  ///
  /// Bump this ONLY for a plugin change the user would want pushed at them — not for every
  /// release. Every bump nags every user whose agent is behind.
  public static let minimumPluginVersion = "0.2.0"

  /// Defined ONCE here so the reducer can seed a new chat's composer with it (and the info
  /// sheet no longer renders it). A plain, ready-to-send instruction the user reviews before
  /// sending — it asks the agent to install the plugin **as a directory plugin** (the only
  /// install that mounts its registration route) and enable + restart.
  ///
  /// It covers BOTH a fresh install and an update in place: `git clone` into an existing
  /// non-empty directory fails outright, and by the time this prompt matters most the user
  /// usually already has an older copy installed. This is the fallback path — Settings offers
  /// a one-tap update when the plugin directory is a git checkout the agent can pull.
  public static let installPrompt = """
    Please install (or update) the hermes-push plugin so I can receive push notifications on \
    my phone. It has to be a directory plugin (a plain pip install loads the hooks but does \
    NOT mount the registration route the app needs).

    If ~/.hermes/plugins/hermes-push already exists, update it in place:
    git -C ~/.hermes/plugins/hermes-push pull --ff-only

    Otherwise clone it fresh:
    git clone https://github.com/goncharik/hermes-mobile-push-plugin.git ~/.hermes/plugins/hermes-push
    (and `pip install fastapi` if it isn't already available)

    Then make sure it's enabled with `hermes plugins enable hermes-push` (or add `hermes-push` \
    under `plugins.enabled` in ~/.hermes/config.yaml) — it's fine if it already is.

    Finally, RESTART the Hermes web/dashboard server (not just the chat process). The plugin's \
    REST routes only mount when that server starts up, and a pull only changes files on disk — \
    the restart is what actually loads the new code. After restarting, tell me it's done.
    """
}

/// Readiness of the `hermes-push` plugin on the connected agent, derived from
/// `GET /api/dashboard/plugins/hub`.
public enum PushPluginStatus: Equatable, Sendable {
  /// Present AND `runtime_status == "enabled"` → read the permission: register silently when
  /// granted; the session list's Turn on card when never asked (unless snoozed); nothing when
  /// denied.
  case ready
  /// Present but not enabled (disabled/inactive), OR absent from the list → the session
  /// list's install card (unless snoozed).
  case notReady
  /// The endpoint 404'd or the request failed — we can't tell, so don't nag (leave the
  /// capability flag as-is).
  case unknown
}

/// What the plugin hub tells us about the installed `hermes-push` plugin: its readiness, the
/// version it reports from its own manifest, and whether the agent can `git pull` it in place.
///
/// `version` and `canUpdateGit` are only meaningful when the plugin was found — a `.unknown`
/// or absent plugin carries `nil` / `false`, which reads as "no update to offer" everywhere.
public struct PushPluginInfo: Equatable, Sendable {
  public var status: PushPluginStatus
  /// The plugin's own `plugin.yaml` version as the agent reports it (e.g. `"0.2.0"`), or
  /// `nil` when absent/blank. Older agents may not report one at all.
  public var version: String?
  /// `can_update_git` — the plugin lives under `~/.hermes/plugins/` AND is a git checkout, so
  /// `POST /api/dashboard/agent-plugins/{name}/update` can pull it. A pip/entry-point install
  /// or a hand-copied directory is `false` and must go through the chat prompt instead.
  public var canUpdateGit: Bool

  public init(status: PushPluginStatus, version: String? = nil, canUpdateGit: Bool = false) {
    self.status = status
    self.version = version
    self.canUpdateGit = canUpdateGit
  }

  /// `true` when the reported version is strictly older than `PushSetup.minimumPluginVersion`.
  ///
  /// Deliberately conservative — an unreported or unparseable version is NOT treated as
  /// outdated. We would rather miss an update prompt than nag someone who is already current
  /// (or whose agent simply doesn't report versions).
  public var isOutdated: Bool {
    PushSetup.isVersion(version, olderThan: PushSetup.minimumPluginVersion)
  }
}

/// Outcome of `POST /api/dashboard/agent-plugins/{name}/update` (a `git pull --ff-only` on the
/// agent). A failure throws `RESTError` instead, carrying the server's `detail` verbatim.
public struct PushPluginUpdateResult: Equatable, Sendable {
  /// The server saw "Already up to date" — the pull succeeded but changed nothing, so there is
  /// no restart to prompt for.
  public var unchanged: Bool

  public init(unchanged: Bool) {
    self.unchanged = unchanged
  }
}

public extension PushSetup {
  /// Compare two dot-separated numeric versions (`"0.1.0"` vs `"0.2.0"`), returning `true`
  /// when `version` is strictly older than `minimum`.
  ///
  /// Intentionally narrow: this is a gate on OUR OWN plugin's versions, which are plain
  /// `MAJOR.MINOR.PATCH` integers — it is not a general semver implementation and does not
  /// understand pre-release or build metadata.
  ///
  /// **Anything it cannot parse with confidence returns `false`** (not outdated): `nil`, empty,
  /// or any component that isn't a plain integer (`"1.0.0-rc1"`, `"main"`, `"unknown"`). The
  /// failure mode of a wrong `true` is nagging a current user with an update that does nothing;
  /// the failure mode of a wrong `false` is a missed prompt they can still reach from the
  /// guide sheet. The second is cheaper, so unparseable stays silent.
  ///
  /// Components are compared pairwise, padding the shorter side with zeros, so `"0.2"` and
  /// `"0.2.0"` are equal and neither is older than the other.
  static func isVersion(_ version: String?, olderThan minimum: String) -> Bool {
    guard let lhs = versionComponents(version), let rhs = versionComponents(minimum) else {
      return false
    }
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      if left != right { return left < right }
    }
    return false // equal
  }

  /// Split a version into non-negative integer components, or `nil` if any part isn't one.
  /// A leading `v` is tolerated (`"v0.2.0"`) since tags commonly carry it.
  private static func versionComponents(_ version: String?) -> [Int]? {
    guard var text = version?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return nil }
    var components: [Int] = []
    components.reserveCapacity(parts.count)
    for part in parts {
      guard let value = Int(part), value >= 0 else { return nil }
      components.append(value)
    }
    return components
  }
}

/// Days to snooze the session-list push card after the N-th "Not now" / "Later" tap
/// (1-indexed). A Fibonacci backoff capped at ~60 days so the nag spaces out quickly but never
/// disappears entirely.
///
/// `1→1, 2→2, 3→3, 4→5, 5→8, 6→13, 7→21, 8→34, 9→55, 10+→60`. A `laterCount` below 1 is
/// treated as 1 (first snooze).
public func pushPromptSnoozeDays(laterCount: Int) -> Int {
  let n = max(1, laterCount)
  // Fibonacci sequence indexed so 1→1, 2→2, 3→3, 4→5, … (i.e. Fib(2), Fib(3), Fib(4), …).
  var a = 1 // Fib(1)
  var b = 1 // Fib(2)
  for _ in 0..<n {
    (a, b) = (b, a + b)
  }
  // After `n` steps `a` is Fib(n+1): n=1→1, 2→2, 3→3, 4→5, 5→8, 6→13, 7→21, 8→34, 9→55.
  return min(a, 60)
}
