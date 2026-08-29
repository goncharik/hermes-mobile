import ComposableArchitecture
import Foundation

/// A cron job with its run-history sessions — one row of the grouped Cron Jobs section.
/// Built by `SessionListFeature.State.cronJobGroups`.
public struct CronJobGroup: Equatable, Sendable, Identifiable {
  public var job: CronJob
  /// The job's most recent runs (newest first), capped to `State.cronPeekLimit`.
  public var runs: [Session]
  /// Whether ANY of the job's runs (capped or not) is unread — drives the job row's dot.
  public var hasUnread: Bool

  public var id: String { job.id }

  public init(job: CronJob, runs: [Session], hasUnread: Bool = false) {
    self.job = job
    self.runs = runs
    self.hasUnread = hasUnread
  }
}

/// Lists Hermes sessions for the connected server and supports full-text search.
/// Tapping a row or the "+" button emits a delegate the parent uses to open chat
/// (resume) or start a new session — `ChatFeature` wiring lands in Task 8.
@Reducer
public struct SessionListFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var sessions: IdentifiedArrayOf<Session>
    public var searchQuery: String
    public var isLoading: Bool
    public var loadError: String?
    /// Reference "now" for relative row timestamps; set from the date dependency on
    /// load so the value is controllable (deterministic snapshots/tests).
    public var now: Date
    /// Last-seen message count per session id (persisted) — drives the unread indicator.
    public var seenCounts: [String: Int]
    /// Pinned session ids (persisted), order = display order in the top "Pinned" section.
    public var pinnedIDs: [String]
    /// Workspace group ids the user expanded past the collapsed limit.
    public var expandedGroups: Set<String>
    /// Ids whose archive PATCH is currently IN FLIGHT. Transient: an id is added when its
    /// PATCH starts and removed on BOTH success and failure. While an id is here, a list/search
    /// response that lands during the in-flight window filters it out (suppressing a stale row),
    /// and the poll skips. On success the in-flight fetch is cancelled so no stale response can
    /// land after the id is cleared; future authoritative fetches exclude archived sessions
    /// server-side (`archived=exclude`), so no permanent filter is needed.
    public var archivingIDs: Set<String>
    /// Ids whose `DELETE /api/sessions/{id}` is currently IN FLIGHT. Same transient
    /// contract as `archivingIDs`: added when the DELETE starts, removed on success and
    /// failure; while an id is here a landing list/search response filters it out and the
    /// poll skips, so a reload can't resurrect the optimistically-removed row.
    public var deletingIDs: Set<String>
    /// Whether the agent supports `DELETE /api/sessions/{id}`. Default `true` (optimistic,
    /// no pre-probe); flipped off by a delete answering the missing-endpoint verdict
    /// (`RESTError.isMissingEndpointVerdict` — 404 OR 405, see that property). When false
    /// all Delete affordances hide and the swipe default clamps back to Archive
    /// (`effectiveSwipeAction`).
    public var deleteSupported: Bool
    /// The persisted default destructive action for the trailing swipe (Archive/Delete);
    /// loaded with the other prefs. Views must read `effectiveSwipeAction`, which clamps
    /// this to `.archive` while the agent lacks the DELETE capability.
    public var defaultSwipeAction: SessionSwipeAction
    /// Whether the always-on "Cron Jobs" section is shown. Device-local UI pref, seeded
    /// from prefs on load; toggled from the organize menu. Defaults to `true` (shown).
    public var showCronSection: Bool
    /// Ids whose rename PATCH is currently IN FLIGHT. Transient: added when the PATCH starts,
    /// removed on success/failure. While non-empty the poll skips (like `archivingIDs`) so a
    /// fetch landing mid-PATCH can't clobber the optimistic title with the server's old one.
    public var renamingInFlightIDs: Set<String>
    /// Session currently being renamed (drives the rename alert's presentation); nil = no alert.
    public var renamingID: Session.ID?
    /// The editable title text bound to the rename alert's `TextField`.
    public var renameDraft: String
    /// How the list groups its rows (workspace vs chronological); persisted, loaded on `task`.
    public var groupingMode: SessionGroupingMode
    /// The profiles available on the connected agent (default + any custom). Populated from
    /// `profiles.list` on `.task`; empty when the agent lacks the profiles API.
    public var profiles: IdentifiedArrayOf<Profile>
    /// The device-local selected profile name. Defaults to the persisted pref or `"default"`.
    /// New chats + the scoped session list are bound to this profile.
    public var selectedProfileName: String
    /// Whether the agent exposes `/api/profiles` (set false on a 404 from `profiles.list`).
    /// When false the selector is hidden and the list uses today's unscoped `/api/sessions`.
    public var profilesSupported: Bool
    /// Custom profile currently being renamed (drives the rename alert); nil = no alert.
    public var renamingProfileName: String?
    /// The editable text bound to the profile-rename alert's `TextField`.
    public var profileRenameDraft: String
    /// Whether the connected agent exposes the `hermes-push` plugin (push registration
    /// endpoint present). `true` once a `registerPush` succeeds; `false` on a definitive 404
    /// (plugin not installed). Threaded into Settings so the notifications UI is capability-gated.
    /// Defaults to `true` (optimistic) so we attempt registration before the first probe.
    public var pushAvailable: Bool
    /// Whether the push info sheet is presented. Raised when the plugin is not ready and the
    /// prompt isn't currently snoozed; dismissed by either of the sheet's two buttons. Pure
    /// presentation state (a `Bool`) — the sheet's buttons send `SessionListFeature` actions.
    public var showPushSetupSheet: Bool
    /// Cron jobs fetched from `GET /api/cron/jobs` — the grouping spine of the Cron Jobs
    /// section. Empty until the first fetch lands (the section falls back to the flat run
    /// list meanwhile).
    public var cronJobs: IdentifiedArrayOf<CronJob>
    /// Whether the agent exposes `/api/cron/jobs` (set false on a definitive 404 — older
    /// agent). When false the section renders today's flat cron-session rows and the jobs
    /// fetch is skipped on subsequent polls.
    public var cronJobsSupported: Bool
    /// The job whose inline run-peek is expanded — single-open so the section stays
    /// scannable (mirrors the desktop sidebar's peek).
    public var expandedCronJobID: String?
    /// Job ids whose trigger/pause/resume RPC is IN FLIGHT. Transient double-fire guard
    /// (mirrors `archivingIDs`): added when the POST starts, removed on success/failure.
    public var cronActionInFlightIDs: Set<String>
    /// Non-`nil` while the transient "Session ID copied" toast is showing. Purely transient
    /// confirmation state: raised by a copy, cleared by the timed expiry. It's a counter
    /// rather than a `Bool` so a re-copy while the toast is already up is still an
    /// observable change — that's what re-announces the copy to VoiceOver (a `Bool` would
    /// stay `true` and the announcement would be swallowed).
    public var copiedIDToastToken: Int?
    @Presents public var settings: SettingsFeature.State?
    @Presents public var archived: ArchivedSessionsFeature.State?
    /// Monotonic count of `archived` sheet presentations, bumped each time the sheet is
    /// (re)presented. The sheet's DELETE round-trips (parent-run — see
    /// `Action.archivedDeleteSucceeded`) capture it at initiation so a late outcome can be
    /// correlated with the presentation that started it: after a dismiss-and-reopen the
    /// same session id can be deleted AGAIN, and re-injecting the FIRST request's outcome
    /// into the new sheet would clear the new operation's guard and resurrect its row —
    /// leaving the second request's real outcome with nowhere to land. A stale-generation
    /// outcome is applied at the list instead (capability verdict / banner), exactly like
    /// an outcome landing after dismissal.
    public var archivedSheetGeneration: Int = 0
    @Presents public var addProfile: AddProfileFeature.State?
    @Presents public var confirmationDialog: ConfirmationDialogState<Action.Dialog>?

    /// The default profile name — never renamable/deletable, and the implicit fallback.
    public static let defaultProfileName = "default"

    /// The device-local persisted profile selection, falling back to
    /// `defaultProfileName`. The ONE fallback rule, shared by the list's `.task` prefs
    /// reload and `AppFeature.makeHomeState`'s creation-time seeding (#46) — change it
    /// here and both sites follow.
    static func persistedProfileName(_ preferences: PreferencesClient) -> String {
      preferences.loadSelectedProfileID() ?? defaultProfileName
    }

    /// Collapsed groups show at most this many rows before a "Show more".
    public static let collapsedLimit = 5

    public init(
      connection: ServerConnection,
      sessions: IdentifiedArrayOf<Session> = [],
      searchQuery: String = "",
      isLoading: Bool = false,
      loadError: String? = nil,
      now: Date = Date(timeIntervalSince1970: 0),
      seenCounts: [String: Int] = [:],
      pinnedIDs: [String] = [],
      expandedGroups: Set<String> = [],
      archivingIDs: Set<String> = [],
      deletingIDs: Set<String> = [],
      deleteSupported: Bool = true,
      defaultSwipeAction: SessionSwipeAction = .default,
      showCronSection: Bool = true,
      renamingInFlightIDs: Set<String> = [],
      renamingID: Session.ID? = nil,
      renameDraft: String = "",
      groupingMode: SessionGroupingMode = .default,
      profiles: IdentifiedArrayOf<Profile> = [],
      selectedProfileName: String = SessionListFeature.State.defaultProfileName,
      profilesSupported: Bool = false,
      renamingProfileName: String? = nil,
      profileRenameDraft: String = "",
      pushAvailable: Bool = true,
      showPushSetupSheet: Bool = false,
      cronJobs: IdentifiedArrayOf<CronJob> = [],
      cronJobsSupported: Bool = true,
      expandedCronJobID: String? = nil,
      cronActionInFlightIDs: Set<String> = [],
      copiedIDToastToken: Int? = nil,
      settings: SettingsFeature.State? = nil,
      addProfile: AddProfileFeature.State? = nil
    ) {
      self.connection = connection
      self.sessions = sessions
      self.searchQuery = searchQuery
      self.isLoading = isLoading
      self.loadError = loadError
      self.now = now
      self.seenCounts = seenCounts
      self.pinnedIDs = pinnedIDs
      self.expandedGroups = expandedGroups
      self.archivingIDs = archivingIDs
      self.deletingIDs = deletingIDs
      self.deleteSupported = deleteSupported
      self.defaultSwipeAction = defaultSwipeAction
      self.showCronSection = showCronSection
      self.renamingInFlightIDs = renamingInFlightIDs
      self.renamingID = renamingID
      self.renameDraft = renameDraft
      self.groupingMode = groupingMode
      self.profiles = profiles
      self.selectedProfileName = selectedProfileName
      self.profilesSupported = profilesSupported
      self.renamingProfileName = renamingProfileName
      self.profileRenameDraft = profileRenameDraft
      self.pushAvailable = pushAvailable
      self.showPushSetupSheet = showPushSetupSheet
      self.cronJobs = cronJobs
      self.cronJobsSupported = cronJobsSupported
      self.expandedCronJobID = expandedCronJobID
      self.cronActionInFlightIDs = cronActionInFlightIDs
      self.copiedIDToastToken = copiedIDToastToken
      self.settings = settings
      self.addProfile = addProfile
    }

    /// Whether the currently-selected profile is the default (no `?profile=` scoping for
    /// reads/mutations, and a `nil` profile threaded into archive/rename).
    public var isDefaultProfileSelected: Bool {
      selectedProfileName == Self.defaultProfileName
    }

    /// The profile name to thread into session-scoped REST calls (archive/rename): `nil`
    /// for the default profile or when the agent lacks the profiles API, else the name.
    public var scopedProfileName: String? {
      guard profilesSupported, !isDefaultProfileSelected else { return nil }
      return selectedProfileName
    }

    /// The destructive action the trailing swipe actually offers: the persisted
    /// preference, clamped back to `.archive` while the agent lacks the DELETE
    /// capability (a stale `.delete` pref must never surface a dead button).
    public var effectiveSwipeAction: SessionSwipeAction {
      deleteSupported ? defaultSwipeAction : .archive
    }

    /// True while a search query is active — the list shows flat results, not workspace
    /// groups (search has no `cwd`).
    public var isSearching: Bool {
      !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cron-scheduled sessions, pulled out of the interactive list and shown in their own
    /// always-on "Cron Jobs" section. Sorted by recency (`updatedAt` desc, `nil` last),
    /// mirroring `chronologicalSessions`.
    public var cronSessions: [Session] {
      sessions.filter(\.isCron)
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// The non-cron remainder — everything the pinning/workspace/chronological computeds
    /// operate on, so cron sessions never feed the interactive sections (a pinned-but-cron
    /// id surfaces only under Cron Jobs).
    public var interactiveSessions: [Session] {
      sessions.filter { !$0.isCron }
    }

    /// Runs shown in a job's inline peek — enough to glance at history without turning the
    /// section into a full history browser (mirrors the desktop sidebar's limit).
    public static let cronPeekLimit = 5

    /// The Cron Jobs section grouped desktop-style: one entry per *job* (sorted soonest
    /// next-run first, no-next-run last, then title), each carrying its most recent *runs*
    /// (the cron sessions whose id-embedded job id matches, capped to `cronPeekLimit`).
    /// Empty when the agent lacks the jobs API or no jobs were fetched yet — the view then
    /// falls back to the flat run list.
    public var cronJobGroups: [CronJobGroup] {
      guard cronJobsSupported, !cronJobs.isEmpty else { return [] }
      var runsByJob: [String: [Session]] = [:]
      for session in cronSessions {  // recency-sorted, so each bucket inherits newest-first
        guard let jobID = CronJob.jobID(fromSessionID: session.id) else { continue }
        runsByJob[jobID, default: []].append(session)
      }
      let unread = unreadSessionIDs
      return cronJobs.elements
        .sorted(by: Self.cronJobOrder)
        .map { job in
          let runs = runsByJob[job.id] ?? []
          return CronJobGroup(
            job: job,
            runs: Array(runs.prefix(Self.cronPeekLimit)),
            // Unread is judged over ALL the job's runs (not just the peeked ones) so a
            // burst of runs can't hide an unread older one.
            hasUnread: runs.contains { unread.contains($0.id) }
          )
        }
    }

    /// Cron sessions that match none of the fetched jobs (deleted job, legacy id shape) —
    /// rendered flat below the groups so no run is ever invisible. Empty while grouping is
    /// inactive (the flat fallback shows everything then).
    public var unmatchedCronSessions: [Session] {
      guard cronJobsSupported, !cronJobs.isEmpty else { return [] }
      let known = Set(cronJobs.ids)
      return cronSessions.filter { session in
        CronJob.jobID(fromSessionID: session.id).map { !known.contains($0) } ?? true
      }
    }

    /// Cron sessions with unseen output — the section header's aggregate badge (the
    /// desktop's `CRON JOBS 4`), visible without scrolling into the section.
    public var cronUnreadCount: Int {
      let unread = unreadSessionIDs
      return cronSessions.filter { unread.contains($0.id) }.count
    }

    /// Desktop-parity job ordering: soonest next run first, jobs without a next run sink
    /// to the bottom, then title for stability.
    private static func cronJobOrder(_ a: CronJob, _ b: CronJob) -> Bool {
      switch (a.nextRunAt, b.nextRunAt) {
      case let (l?, r?) where l != r: return l < r
      case (.some, .none): return true
      case (.none, .some): return false
      default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
      }
    }

    /// Pinned sessions resolved from `pinnedIDs`, in pin order; stale ids are dropped. Cron
    /// sessions are excluded (they belong to the Cron Jobs section), even if pinned.
    public var pinnedSessions: [Session] {
      pinnedIDs.compactMap { id in sessions[id: id].flatMap { $0.isCron ? nil : $0 } }
    }

    /// The Pinned lane's rows with branch nesting applied WITHIN the pinned slice: a branch
    /// nests (with its elbow stem) only when its parent is also pinned; a pinned branch
    /// whose parent isn't pinned de-nests to a normal row. Top-level order stays the user's
    /// pin order (`sortTopLevelByRecency: false`) — nesting is display-only and must not
    /// reorder pins.
    public var pinnedEntries: [SessionBranchEntry] {
      flattenSessionsWithBranches(pinnedSessions, sortTopLevelByRecency: false)
    }

    /// Non-cron sessions not pinned — these feed the workspace grouping.
    public var unpinnedSessions: [Session] {
      let pinned = Set(pinnedIDs)
      return interactiveSessions.filter { !pinned.contains($0.id) }
    }

    /// Sessions grouped by workspace for the (non-search) list, desktop-style.
    /// Pinned sessions are excluded — they render in the top "Pinned" section.
    public var groups: [SessionGroup] {
      SessionGroup.grouped(unpinnedSessions)
    }

    /// Flat, last-active-ordered list of the unpinned sessions — the chronological mode's
    /// rows (pinned sessions still render in the top "Pinned" section). `nil` dates sort last.
    public var chronologicalSessions: [Session] {
      unpinnedSessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// The chronological lane's rows with branch nesting applied: branches render under
    /// their parent with elbow stems, and a parent cluster sorts by its freshest member
    /// (activity on a branch lifts the whole group). Applied AFTER the cron partition —
    /// cron rows never reach this lane. Orphans (parent pinned/absent) de-nest.
    public var chronologicalEntries: [SessionBranchEntry] {
      flattenSessionsWithBranches(chronologicalSessions)
    }

    /// Sessions with new activity since the user last opened them.
    public var unreadSessionIDs: Set<Session.ID> {
      Set(sessions.compactMap { session in
        guard let count = session.messageCount, let seen = seenCounts[session.id], count > seen
        else { return nil }
        return session.id
      })
    }

    /// Rows to show for a group given its collapsed/expanded state.
    public func visibleSessions(in group: SessionGroup) -> [Session] {
      guard !expandedGroups.contains(group.id), group.sessions.count > Self.collapsedLimit
      else { return group.sessions }
      return Array(group.sessions.prefix(Self.collapsedLimit))
    }

    /// A workspace group's visible rows with branch nesting applied — nesting happens
    /// within the RENDERED slice only (desktop parity), so it runs after both the cron
    /// partition and the collapsed-limit cap: a branch whose parent got capped out (or
    /// lives in another group) de-nests rather than hiding.
    public func visibleEntries(in group: SessionGroup) -> [SessionBranchEntry] {
      flattenSessionsWithBranches(visibleSessions(in: group))
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case onDisappear
    case pulledToRefresh
    case pollTick
    case sessionsResponse(Result<[Session], RESTError>)
    case sessionTapped(Session.ID)
    case newSessionButtonTapped
    case pinSession(id: Session.ID)
    case unpinSession(id: Session.ID)
    /// Put a row's session id on the pasteboard and raise the transient confirmation toast.
    case copyIDButtonTapped(id: Session.ID)
    /// The copy toast's dwell time elapsed — hide it.
    case copiedIDToastExpired
    case toggleGroupExpansion(groupID: String)
    /// Switch the list grouping (workspace/chronological) and persist the choice.
    case setGroupingMode(SessionGroupingMode)
    /// Toggle the always-on "Cron Jobs" section and persist the choice.
    case setShowCronSection(Bool)
    case archiveButtonTapped(id: Session.ID)
    /// Archive RPC succeeded — clear the transient in-flight guard and cancel (or, when
    /// one is pending, restart — see `cancelOrRestartFetch`) any fetch that started
    /// during the PATCH window so a stale response can't land after the guard is gone.
    case archiveSucceeded(id: Session.ID)
    /// Archive RPC failed — the server still has the session. Clear the in-flight guard and
    /// roll back locally: re-insert the `session` at its saved `index`, restore the
    /// pin at `pinIndex` (nil if it wasn't pinned) and the prior `seenCount`, persist, and
    /// surface the error. `profileName` + `searchQuery` are the list context the PATCH was
    /// issued under — the row re-insert is dropped when the context changed mid-flight,
    /// while the pin/seen restore always applies (see `rollBackFailedRemoval` for the rule).
    case archiveFailed(
      id: Session.ID, session: Session, index: Int, pinIndex: Int?, seenCount: Int?,
      profileName: String?, searchQuery: String
    )
    /// Ask to permanently delete a session (presents the confirmation dialog).
    case deleteButtonTapped(id: Session.ID)
    /// Delete RPC succeeded — clear the transient in-flight guard, emit
    /// `Delegate.sessionDeleteSucceeded`, and cancel/restart any fetch that started
    /// during the DELETE window (mirrors `archiveSucceeded`).
    case deleteSucceeded(id: Session.ID)
    /// Delete RPC failed. Clear the in-flight guard and roll back locally (same rollback
    /// payload + same context rule as archive — see `rollBackFailedRemoval`). A definitive
    /// 404/405 `error` additionally flips `deleteSupported` off SILENTLY (older agent —
    /// no banner, mirror the capability flips); any other error surfaces the banner.
    case deleteFailed(
      id: Session.ID, session: Session, index: Int, pinIndex: Int?, seenCount: Int?,
      profileName: String?, searchQuery: String, error: RESTError
    )
    /// The archived sheet's DELETE round-trip finished. The round-trip runs HERE, not in
    /// the sheet — a presented child's effects are cancelled on dismissal, so a sheet-run
    /// DELETE racing Done/swipe-down would be silently dropped after the cache wipe
    /// already happened (see `ArchivedSessionsFeature.Delegate.deleted`). Success is
    /// re-injected into the sheet while it still owns the delete, and the badge delegate
    /// fires. `generation` is the sheet presentation the delete was initiated under
    /// (`State.archivedSheetGeneration`) — the session id alone is ambiguous across a
    /// dismiss-and-reopen, where a re-deleted id could pair with a STALE outcome.
    case archivedDeleteSucceeded(id: Session.ID, generation: Int)
    /// The archived sheet's DELETE failed: re-injected into the sheet while it still owns
    /// the delete (rollback + capability verdict happen there); with the sheet gone — or
    /// when `generation` shows the outcome belongs to a PREVIOUS presentation of the
    /// sheet — the verdict/banner applies to the list so the outcome never vanishes.
    case archivedDeleteFailed(
      id: Session.ID, session: Session, index: Int, generation: Int, error: RESTError
    )
    /// Open the rename alert for a row: seeds `renameDraft` with the row's current title.
    case renameButtonTapped(id: Session.ID)
    /// Commit the rename: optimistically update the row's title and fire the REST PATCH.
    case confirmRename
    /// Rename PATCH succeeded — the optimistic value stands.
    case renameSucceeded(id: Session.ID)
    /// Rename PATCH failed — restore `previousTitle` and surface the error.
    case renameFailed(id: Session.ID, previousTitle: String?)
    /// Dismiss the rename alert without applying changes.
    case cancelRename
    case confirmationDialog(PresentationAction<Dialog>)
    case settingsButtonTapped
    case settings(PresentationAction<SettingsFeature.Action>)
    /// Open the Archived sessions sheet (from the top-trailing menu).
    case archivedButtonTapped
    case archived(PresentationAction<ArchivedSessionsFeature.Action>)
    // MARK: Profiles
    /// Switch the active profile (persist, reset list UI, refetch the scoped session list).
    case selectProfile(name: String)
    /// Response from the `profiles.list` capability probe on `.task` (also fetches sessions).
    case profilesResponse(Result<[Profile], RESTError>)
    /// Refresh of the profile list WITHOUT a session fetch (after create/delete, paired with a
    /// subsequent `selectProfile` that does the single scoped fetch).
    case profilesRefreshed([Profile])
    /// Open the Add-profile sheet.
    case addProfileTapped
    case addProfile(PresentationAction<AddProfileFeature.Action>)
    /// Open the rename alert for a custom profile: seeds `profileRenameDraft` with its name.
    case renameProfileTapped(name: String)
    /// Commit the profile rename from the alert (sends the entered draft as `newName`).
    case confirmRenameProfile
    /// Dismiss the profile-rename alert without applying changes.
    case cancelRenameProfile
    /// Begin renaming a custom profile (opens the inline rename via the dialog/menu path).
    case renameProfileButtonTapped(name: String, newName: String)
    /// Rename PATCH succeeded — the optimistic profile name stands.
    case renameProfileSucceeded
    /// Rename PATCH failed — restore `previousProfiles` and surface the error.
    case renameProfileFailed(previousProfiles: IdentifiedArrayOf<Profile>, previousSelected: String)
    /// Ask to delete a custom profile (presents the confirmation dialog).
    case deleteProfileButtonTapped(name: String)
    /// Delete PATCH succeeded — remove the profile locally and, if it was active, re-home to
    /// default and refetch sessions.
    case deleteProfileSucceeded(name: String)
    /// Delete failed — surface the error (no local state was changed yet).
    case deleteProfileFailed
    /// Event-driven working-glow patch from the open chat (routed by `AppFeature` from
    /// `ChatFeature.Delegate.runningChanged`): set the row's `isActive` INSTANTLY so the glow
    /// clears/lights the moment the agent stops/starts, rather than waiting for the next poll.
    /// Always server-confirmed (the delegate only fires from `message.start`/`complete`/`error`
    /// and the `session.resume` `running` flag) — a cached `running-guess` never reaches here,
    /// so it can never start a glow on its own. The poll remains the backstop for not-open
    /// sessions. A no-op for an unknown id (the session isn't in the current list).
    case setSessionRunning(id: Session.ID, running: Bool)
    // MARK: Cron jobs
    /// Result of the `GET /api/cron/jobs` fetch (runs alongside every session load).
    /// Success stores the jobs; a definitive `.notFound` flips `cronJobsSupported` off
    /// (older agent → flat fallback, fetch skipped from then on); transient failures keep
    /// the previous jobs so the section doesn't flap.
    case cronJobsResponse(Result<[CronJob], RESTError>)
    /// Toggle a job's inline run-peek (single-open: expanding one collapses another).
    case cronJobTapped(id: String)
    /// "Run now" on a job row — `POST /api/cron/jobs/{id}/trigger`.
    case triggerCronJob(id: String)
    /// Pause a job — `POST /api/cron/jobs/{id}/pause`.
    case pauseCronJob(id: String)
    /// Resume a paused job — `POST /api/cron/jobs/{id}/resume`.
    case resumeCronJob(id: String)
    /// A cron action RPC finished: lift the in-flight guard; on success refetch from the
    /// server (the full load after a trigger so the new run session appears, jobs-only for
    /// pause/resume); on failure surface the banner. No optimistic mutation — job state is
    /// server-computed and the refetch/poll reconciles.
    case cronJobActionFinished(id: String, refetchSessions: Bool, error: RESTError?)
    // MARK: Push notifications
    /// Kicks off contextual push setup once the list appears (right after login): first probe
    /// the `hermes-push` plugin readiness, then branch on the result. Fired from `.task`.
    case setupPush
    /// Result of the plugin-readiness probe (`rest.pushPluginStatus`). `ready` → permission +
    /// register (and clear any snooze); `notReady` → set `pushAvailable=false` and raise the
    /// info sheet unless snoozed; `unknown` → leave capability as-is (don't nag).
    case pushPluginStatusLoaded(PushPluginStatus)
    /// Begin the permission-request + token-observe flow (only when the plugin is ready).
    case requestPushAuthorization
    /// The info sheet's "Ask agent to install" button — open a new chat with the install prompt
    /// pre-filled in the composer (dismisses the sheet; bubbles up via the create delegate).
    case pushSetupAskAgentTapped
    /// The info sheet's "Later" button — dismiss + snooze (Fibonacci backoff on the Later count).
    case pushSetupLaterTapped
    /// A device token arrived from `PushClient.register()` (initial registration OR an OS
    /// rotation) — (re-)register it with the agent. Carries the lowercase-hex token.
    case pushTokenReceived(String)
    /// `rest.registerPush` succeeded → push is available.
    case pushRegistered
    /// `rest.registerPush` failed; a `.notFound` flips `pushAvailable` off (plugin not installed).
    case pushRegisterFailed(RESTError)
    case delegate(Delegate)

    @CasePathable
    public enum Dialog: Equatable {
      case confirmArchive(id: Session.ID)
      case confirmDelete(id: Session.ID)
      case confirmDeleteProfile(name: String)
    }

    @CasePathable
    public enum Delegate {
      case openSession(Session)
      /// Open a NEW chat. `initialComposerText` (when non-nil) is pre-filled in the composer
      /// but NOT sent — used by the push "Ask agent to install" flow so the user reviews + sends.
      case createSession(initialComposerText: String?)
      case disconnect
      /// The user confirmed archiving this session (the optimistic removal + PATCH follow).
      /// Emitted FIRST so the parent can tear the live-chat slot down when it matches — a
      /// detached slot's socket must not keep streaming into a now-archived session.
      case sessionArchived(id: Session.ID)
      /// The user confirmed permanently deleting this session (the optimistic removal +
      /// DELETE follow). Emitted FIRST, like `sessionArchived`, so the parent tears the
      /// live-chat slot down when it matches AND wipes the session's cached snapshot +
      /// turn anchor — a deleted session must not repaint from cache.
      case sessionDeleted(id: Session.ID)
      /// The server CONFIRMED a permanent delete (main list or archived sheet). Distinct
      /// from `sessionDeleted` (optimistic, at initiation): cleanup that must NOT survive
      /// a failed delete keys off this one — `AppFeature` drops the session's
      /// pending-approval badge entry here, because after a failed delete the approval is
      /// still pending on the server and nothing short of a fresh push would repopulate
      /// the entry.
      case sessionDeleteSucceeded(id: Session.ID)
    }
  }

  // One id for BOTH the list fetch and the search fetch: any new fetch (list refresh, poll,
  // or search) cancels the previous in-flight one, so a late list response can't overwrite
  // active search results (and vice versa). `poll` is the separate timer loop.
  private enum CancelID { case fetch, poll, pushTokens, copyIDToast }

  /// How often the list auto-refreshes while visible, to keep `isActive` (working glow) fresh.
  private static let pollInterval: Duration = .seconds(10)

  /// How long a copy confirmation (the "Session ID copied" toast) stays up before
  /// auto-dismissing. Same name/value in every feature that confirms a copy.
  static let copiedFeedbackDuration: Duration = .seconds(1.5)

  @Dependency(\.hermesREST) var rest
  @Dependency(\.hermesProfiles) var profiles
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.preferences) var preferences
  @Dependency(\.push) var push
  @Dependency(\.pasteboard) var pasteboard

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        // Refresh "now", reload persisted prefs (incl. the device-local selected profile),
        // probe the profiles capability, and start the auto-poll loop.
        reloadPrefs(&state)
        state.selectedProfileName = Self.State.persistedProfileName(preferences)
        state.isLoading = true
        return .merge(
          .run { [profiles, connection = state.connection] send in
            do {
              let result = try await profiles.list(connection)
              await send(.profilesResponse(.success(result)))
            } catch let error as RESTError {
              await send(.profilesResponse(.failure(error)))
            } catch {
              await send(.profilesResponse(.failure(.unreachable)))
            }
          }
          .cancellable(id: CancelID.fetch, cancelInFlight: true),
          .run { [clock, interval = Self.pollInterval] send in
            while true {
              try await clock.sleep(for: interval)
              await send(.pollTick)
            }
          }
          .cancellable(id: CancelID.poll, cancelInFlight: true),
          // Contextual push setup: prompt for permission now that we're past login, and (if
          // granted) start observing device tokens. Per the product decision the permission
          // prompt fires here on the sessions list — never at first launch.
          .send(.setupPush)
        )

      case .onDisappear:
        // Stop the poll (and any in-flight fetch / search debounce) when the list goes away.
        return .merge(
          .cancel(id: CancelID.poll),
          .cancel(id: CancelID.fetch),
          .cancel(id: CancelID.pushTokens)
        )

      case .pollTick:
        // Skip the auto-refresh while searching (don't fight the user's query), while an
        // archive or delete is in flight (don't churn / risk resurrecting the removed row),
        // or while a rename PATCH is in flight (a fetch could clobber the optimistic title
        // with the old one).
        guard !state.isSearching, state.archivingIDs.isEmpty, state.deletingIDs.isEmpty,
          state.renamingInFlightIDs.isEmpty
        else { return .none }
        return .send(.pulledToRefresh)

      case .pulledToRefresh:
        // A plain reload — does NOT (re)start the poll loop.
        return load(&state)

      case let .setSessionRunning(id, running):
        // Patch the in-memory row's working flag (drives the glow) the instant the open chat
        // tells us this session's authoritative running state changed. No-op if the session
        // isn't in the current list (e.g. archived/filtered) — the poll handles those.
        guard state.sessions[id: id]?.isActive != running else { return .none }
        state.sessions[id: id]?.isActive = running
        return .none

      case let .cronJobsResponse(.success(jobs)):
        state.cronJobsSupported = true
        // Defensive uniquing (first wins): the unscoped fetch aggregates every profile's
        // jobs file, so never crash on a duplicated id (e.g. a copied profile home).
        state.cronJobs = IdentifiedArray(jobs, uniquingIDsWith: { first, _ in first })
        return .none

      case let .cronJobsResponse(.failure(error)):
        // A definitive 404 → old agent without the cron API. Fall back to the flat section
        // and stop fetching. Anything transient keeps the previous jobs (no flapping).
        if error == .notFound {
          state.cronJobsSupported = false
          state.cronJobs = []
          state.expandedCronJobID = nil
        }
        return .none

      case let .cronJobTapped(id):
        state.expandedCronJobID = state.expandedCronJobID == id ? nil : id
        return .none

      case let .triggerCronJob(id):
        return performCronAction(&state, id: id, refetchSessions: true) { rest, conn, jobID, profile in
          try await rest.triggerCronJob(conn, jobID, profile)
        }

      case let .pauseCronJob(id):
        return performCronAction(&state, id: id, refetchSessions: false) { rest, conn, jobID, profile in
          try await rest.pauseCronJob(conn, jobID, profile)
        }

      case let .resumeCronJob(id):
        return performCronAction(&state, id: id, refetchSessions: false) { rest, conn, jobID, profile in
          try await rest.resumeCronJob(conn, jobID, profile)
        }

      case let .cronJobActionFinished(id, refetchSessions, error):
        state.cronActionInFlightIDs.remove(id)
        if let error {
          // Surface the server's copy verbatim (e.g. a 400 detail) via the existing banner.
          state.loadError = error.message
          return .none
        }
        // Success → reconcile from the server. A trigger just spawned a run session, so do
        // the full load (sessions + jobs); pause/resume only changed the job, so a
        // jobs-only refetch avoids churning the list.
        if refetchSessions { return load(&state) }
        return .run { [
          rest, connection = state.connection,
          profile = state.profilesSupported ? state.selectedProfileName : nil
        ] send in
          await send(fetchCronJobs(rest: rest, connection: connection, profile: profile))
        }

      case .setupPush:
        // Push onboarding (after login, on the list). FIRST probe whether the `hermes-push`
        // plugin is installed + enabled (a REST-only check that works without the WS); the
        // result decides whether to request permission, raise the info sheet, or do nothing.
        return .run { [rest, connection = state.connection] send in
          let status = (try? await rest.pushPluginStatus(connection)) ?? .unknown
          await send(.pushPluginStatusLoaded(status))
        }
        .cancellable(id: CancelID.pushTokens, cancelInFlight: true)

      case let .pushPluginStatusLoaded(status):
        switch status {
        case .ready:
          // Plugin is live → push is available. Clear any prior snooze (so a later uninstall
          // re-prompts fresh) and run the existing permission-request + token-register flow.
          state.pushAvailable = true
          state.showPushSetupSheet = false
          preferences.clearPushPromptSnooze()
          return .send(.requestPushAuthorization)
        case .notReady:
          // Plugin absent / disabled → push isn't available. Raise the info sheet unless the
          // prompt is currently snoozed (Fibonacci backoff from prior "Later" taps).
          state.pushAvailable = false
          if !isPushPromptSnoozed() {
            state.showPushSetupSheet = true
          }
          return .none
        case .unknown:
          // Endpoint 404 / network error — can't tell. Don't nag; leave capability as-is.
          return .none
        }

      case .requestPushAuthorization:
        // Contextual permission request. If granted, observe the device-token stream as a
        // long-running cancellable effect — each emitted token (the first registration and any
        // OS rotation) drives a (re-)register. If denied we do nothing further; the toggle in
        // Settings can re-prompt later.
        return .run { [push] send in
          guard await push.requestAuthorization() else { return }
          for await token in push.register() {
            await send(.pushTokenReceived(token))
          }
        }
        .cancellable(id: CancelID.pushTokens, cancelInFlight: true)

      case .pushSetupAskAgentTapped:
        // Dismiss the sheet and open a new chat with the install prompt pre-filled (NOT sent —
        // the user reviews and sends). Bubbles up via the create delegate, carrying the text.
        state.showPushSetupSheet = false
        return .send(.delegate(.createSession(initialComposerText: PushSetup.installPrompt)))

      case .pushSetupLaterTapped:
        // Dismiss + snooze: bump the Later count and push the next prompt out by the matching
        // Fibonacci interval, persisting both so it survives relaunch.
        state.showPushSetupSheet = false
        let count = (preferences.loadPushPromptSnooze()?.count ?? 0) + 1
        let until = now.addingTimeInterval(Double(pushPromptSnoozeDays(laterCount: count)) * 86_400)
        preferences.savePushPromptSnooze(count, until)
        return .none

      case let .pushTokenReceived(token):
        // (Re-)register this device token with the agent's push plugin, threading the
        // compile-time APNs env + app version. Persist the token (non-secret) so logout can
        // unregister with it even when the live stream isn't producing.
        preferences.savePushDeviceToken(token)
        return .run { [rest, push, connection = state.connection] send in
          let env = PushClient.apnsEnv
          let version = push.appVersion()
          do {
            try await rest.registerPush(connection, token, env, version)
            await send(.pushRegistered)
          } catch let error as RESTError {
            await send(.pushRegisterFailed(error))
          } catch {
            await send(.pushRegisterFailed(.unreachable))
          }
        }

      case .pushRegistered:
        // Plugin present → push is available. The app does not sign pushes (the plugin signs
        // with a shared secret), so there's nothing to persist on success.
        state.pushAvailable = true
        return .none

      case let .pushRegisterFailed(error):
        // A definitive 404 means the plugin isn't installed — capability-gate the push UI off.
        // Other (transient) failures leave `pushAvailable` as-is so we retry on the next token.
        if error == .notFound {
          state.pushAvailable = false
        }
        return .none

      case .binding(\.searchQuery):
        // Only the searchQuery binding drives the fetch; other bound fields (renameDraft)
        // must NOT trigger a search. A CLEARED query (trimmed-empty — the field's
        // clear/cancel, or backspacing out the text) reloads the normal list IMMEDIATELY
        // via `load`: there is no keystroke burst to debounce on the way out, and `load`
        // raises `isLoading` — which is what lets `cancelOrRestartFetch` see this fetch
        // as pending. The debounced branch below sets no flag, and with the query already
        // empty `isSearching` no longer covers the window, so a mutation success landing
        // mid-window would otherwise bare-cancel the pending reload and strand the stale
        // search results until the next poll.
        guard state.isSearching else { return load(&state) }
        return .run { [
          rest, profiles, connection = state.connection, query = state.searchQuery, clock,
          profileName = state.selectedProfileName, profilesSupported = state.profilesSupported
        ] send in
          try await clock.sleep(for: .milliseconds(300))
          await send(fetchSessions(
            rest: rest, profiles: profiles, connection: connection, query: query,
            profileName: profileName, profilesSupported: profilesSupported
          ))
        }
        // Shared `fetch` id: cancels any in-flight list load so a late list response can't
        // overwrite these search results.
        .cancellable(id: CancelID.fetch, cancelInFlight: true)

      case .binding:
        // Other bindings (e.g. renameDraft) are pure state edits — no side effects.
        return .none

      case let .sessionsResponse(.success(sessions)):
        state.isLoading = false
        state.loadError = nil
        // Belt-and-suspenders: drop any session whose archive PATCH or DELETE is still in
        // flight, so a fetch that completes during that window can't repopulate the removed row.
        let inFlight = state.archivingIDs.union(state.deletingIDs)
        let filtered = inFlight.isEmpty
          ? sessions
          : sessions.filter { !inFlight.contains($0.id) }
        // The list AND search endpoints can return the same session id more than once
        // (#78). `IdentifiedArray(uniqueElements:)` preconditions on unique ids and
        // trapped in the field, so dedupe first — keep the FIRST occurrence (server order).
        state.sessions = IdentifiedArray(filtered, uniquingIDsWith: { first, _ in first })
        let visible = state.sessions
        // Seed last-seen counts for newly-discovered sessions so they don't all show as
        // unread on first sight; only later increases flag unread.
        var seeded = false
        for session in visible where state.seenCounts[session.id] == nil {
          state.seenCounts[session.id] = session.messageCount ?? 0
          seeded = true
        }
        guard seeded else { return .none }
        return persistSeenCounts(state.seenCounts)

      case let .sessionsResponse(.failure(error)):
        state.isLoading = false
        state.loadError = error.message
        return .none

      case let .sessionTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        // Opening clears the unread flag (mark seen at the current count).
        state.seenCounts[id] = session.messageCount ?? state.seenCounts[id] ?? 0
        return .merge(
          persistSeenCounts(state.seenCounts),
          .send(.delegate(.openSession(session)))
        )

      case let .pinSession(id):
        guard !state.pinnedIDs.contains(id) else { return .none }
        state.pinnedIDs.append(id)
        return persistPinnedIDs(state.pinnedIDs)

      case let .unpinSession(id):
        state.pinnedIDs.removeAll { $0 == id }
        return persistPinnedIDs(state.pinnedIDs)

      case let .copyIDButtonTapped(id):
        state.copiedIDToastToken = (state.copiedIDToastToken ?? 0) + 1
        // Copy now; hide the confirmation after a beat. A second copy while the toast is
        // up restarts the dwell (cancelInFlight) so the latest copy owns the countdown.
        return .merge(
          .run { [pasteboard] _ in pasteboard.copy(id) },
          .run { [clock] send in
            try await clock.sleep(for: Self.copiedFeedbackDuration)
            await send(.copiedIDToastExpired)
          }
          .cancellable(id: CancelID.copyIDToast, cancelInFlight: true)
        )

      case .copiedIDToastExpired:
        state.copiedIDToastToken = nil
        return .none

      case let .setGroupingMode(mode):
        guard state.groupingMode != mode else { return .none }
        state.groupingMode = mode
        return .run { [preferences] _ in preferences.saveGroupingMode(mode) }

      case let .setShowCronSection(show):
        guard state.showCronSection != show else { return .none }
        state.showCronSection = show
        return .run { [preferences] _ in preferences.saveShowCronSection(show) }

      case let .toggleGroupExpansion(groupID):
        if !state.expandedGroups.insert(groupID).inserted {
          state.expandedGroups.remove(groupID)
        }
        return .none

      case let .archiveButtonTapped(id):
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Archive session?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmArchive(id: id)) {
            TextState("Archive")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("This hides the session from the list. You can restore it from the server.")
        }
        return .none

      case let .confirmationDialog(.presented(.confirmArchive(id))):
        guard let index = state.sessions.index(id: id) else { return .none }
        // Capture rollback info BEFORE mutating: the session + its list index, the pin position
        // (if pinned) and prior seen baseline — so a failed RPC can restore everything locally.
        let session = state.sessions[index]
        let pinIndex = state.pinnedIDs.firstIndex(of: id)
        let seenCount = state.seenCounts[id]
        // Optimistic removal: drop from the list + clear its pin/seen entries, persist,
        // then run the RPC. On failure we re-insert and surface the error.
        state.sessions.remove(id: id)
        state.pinnedIDs.removeAll { $0 == id }
        state.seenCounts[id] = nil
        // Mark as in-flight so a fetch landing during the PATCH window filters it out and the
        // poll skips — closing the window where a reload could resurrect the removed row.
        state.archivingIDs.insert(id)
        let pinnedIDs = state.pinnedIDs
        let seenCounts = state.seenCounts
        // Cancel any in-flight fetch (list load OR search) too: one started before this
        // archive could land afterward and resurrect the row we just optimistically removed.
        let archiveProfile = state.scopedProfileName
        let archiveQuery = state.searchQuery
        return .concatenate(
          // Tell the parent FIRST (before the PATCH runs) so it can tear the live-chat slot
          // down when this is the slot's session — the (possibly detached) socket must not
          // keep streaming into a now-archived session.
          .send(.delegate(.sessionArchived(id: id))),
          .merge(
            .cancel(id: CancelID.fetch),
            .run { [rest, preferences, connection = state.connection] send in
              preferences.savePinnedIDs(pinnedIDs)
              preferences.saveSeenCounts(seenCounts)
              do {
                try await rest.archive(connection, id, true, archiveProfile)
                await send(.archiveSucceeded(id: id))
              } catch {
                await send(.archiveFailed(
                  id: id, session: session, index: index, pinIndex: pinIndex,
                  seenCount: seenCount, profileName: archiveProfile, searchQuery: archiveQuery
                ))
              }
            }
          )
        )

      case let .deleteButtonTapped(id):
        // Mirror of the archived sheet's guard: the view already hides Delete affordances
        // when the capability is off, but a context menu rendered before the flag flipped
        // can still fire — refuse rather than round-trip a doomed DELETE.
        guard state.deleteSupported else { return .none }
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Delete session?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDelete(id: id)) {
            TextState("Delete")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("This permanently deletes the session and its history.")
        }
        return .none

      case let .confirmationDialog(.presented(.confirmDelete(id))):
        // Same capability guard as `deleteButtonTapped` — the flag can flip (e.g. mirrored
        // from the archived sheet) while this dialog is already up.
        guard state.deleteSupported, let index = state.sessions.index(id: id) else { return .none }
        // Mirror of `.confirmArchive`: capture rollback info BEFORE mutating (session + list
        // index + pin position + seen baseline), then optimistically remove + persist and run
        // the DELETE. On failure everything is restored locally.
        let session = state.sessions[index]
        let pinIndex = state.pinnedIDs.firstIndex(of: id)
        let seenCount = state.seenCounts[id]
        state.sessions.remove(id: id)
        state.pinnedIDs.removeAll { $0 == id }
        state.seenCounts[id] = nil
        // In-flight guard: a fetch landing during the DELETE window filters this id out and
        // the poll skips — closing the window where a reload could resurrect the removed row.
        state.deletingIDs.insert(id)
        let pinnedIDs = state.pinnedIDs
        let seenCounts = state.seenCounts
        let deleteProfile = state.scopedProfileName
        let deleteQuery = state.searchQuery
        return .concatenate(
          // Tell the parent FIRST (before the DELETE runs) so it can tear the live-chat slot
          // down when this is the slot's session and wipe the cached snapshot — the socket
          // must not keep streaming into (and the cache must not repaint) a deleted session.
          .send(.delegate(.sessionDeleted(id: id))),
          .merge(
            // Cancel any in-flight fetch (list load OR search): one started before this
            // delete could land afterward and resurrect the row we just removed.
            .cancel(id: CancelID.fetch),
            .run { [rest, preferences, connection = state.connection] send in
              preferences.savePinnedIDs(pinnedIDs)
              preferences.saveSeenCounts(seenCounts)
              do {
                try await rest.deleteSession(connection, id, deleteProfile)
                await send(.deleteSucceeded(id: id))
              } catch {
                await send(.deleteFailed(
                  id: id, session: session, index: index, pinIndex: pinIndex,
                  seenCount: seenCount, profileName: deleteProfile, searchQuery: deleteQuery,
                  error: asRESTError(error)
                ))
              }
            }
          )
        )

      case let .deleteSucceeded(id):
        // DELETE landed (an `already_absent` body is success by contract) — clear the
        // transient guard so the poll resumes, and cancel/restart any fetch that started
        // during the window (see `cancelOrRestartFetch`): with the guard now gone, its
        // stale response could resurrect the row. The badge delegate fires on CONFIRMED
        // deletes only — see `Delegate.sessionDeleteSucceeded`.
        state.deletingIDs.remove(id)
        return .merge(
          .send(.delegate(.sessionDeleteSucceeded(id: id))),
          cancelOrRestartFetch(&state)
        )

      case let .deleteFailed(id, session, index, pinIndex, seenCount, profileName, searchQuery, error):
        // The delete didn't take — the server still has the session. Lift the guard and
        // roll back (rollback rule: `rollBackFailedRemoval`). A missing-endpoint verdict
        // (`isMissingEndpointVerdict`) → flip the capability off SILENTLY, no banner,
        // like the other capability flips (the flag is server-wide, so it applies
        // whatever the context). Anything else surfaces the banner.
        state.deletingIDs.remove(id)
        rollBackFailedRemoval(
          &state, id: id, session: session, index: index, pinIndex: pinIndex,
          seenCount: seenCount, profileName: profileName, searchQuery: searchQuery
        )
        if error.isMissingEndpointVerdict {
          state.deleteSupported = false
        } else {
          state.loadError = "Couldn’t delete the session."
        }
        return .none

      case let .confirmationDialog(.presented(.confirmDeleteProfile(name))):
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        return .run { [profiles, connection = state.connection] send in
          do {
            try await profiles.delete(connection, name)
            await send(.deleteProfileSucceeded(name: name))
          } catch {
            await send(.deleteProfileFailed)
          }
        }

      case .confirmationDialog:
        return .none

      case let .archiveSucceeded(id):
        // PATCH landed — clear the transient guard so the poll resumes. Cancel/restart any
        // fetch that started during the PATCH window (see `cancelOrRestartFetch`): with
        // the guard now gone, its (stale) response could otherwise resurrect the archived
        // row. Future authoritative fetches exclude archived sessions server-side
        // (`archived=exclude`), so no permanent filter is needed.
        state.archivingIDs.remove(id)
        return cancelOrRestartFetch(&state)

      case let .archiveFailed(id, session, index, pinIndex, seenCount, profileName, searchQuery):
        // The archive didn't take — the server still has the session. Lift the in-flight
        // guard, roll back (rollback rule: `rollBackFailedRemoval`), and surface the error.
        state.archivingIDs.remove(id)
        rollBackFailedRemoval(
          &state, id: id, session: session, index: index, pinIndex: pinIndex,
          seenCount: seenCount, profileName: profileName, searchQuery: searchQuery
        )
        state.loadError = "Couldn’t archive the session."
        return .none

      case let .renameButtonTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        state.renamingID = id
        state.renameDraft = session.title ?? ""
        return .none

      case .confirmRename:
        guard let id = state.renamingID, let session = state.sessions[id: id] else {
          state.renamingID = nil
          state.renameDraft = ""
          return .none
        }
        // Capture the previous title for rollback, then optimistically apply the trimmed draft
        // (an empty draft clears the title, mirroring the server's null/empty behaviour).
        let previousTitle = session.title
        let trimmed = state.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        state.sessions[id: id]?.title = trimmed.isEmpty ? nil : trimmed
        state.renamingID = nil
        state.renameDraft = ""
        // Mark as in-flight (poll skips while set) and cancel any in-flight fetch — one started
        // before this PATCH could land mid-window and clobber the optimistic title with the
        // server's old one. Mirrors archive's protection.
        state.renamingInFlightIDs.insert(id)
        let renameProfile = state.scopedProfileName
        return .merge(
          .cancel(id: CancelID.fetch),
          .run { [rest, connection = state.connection] send in
            do {
              try await rest.rename(connection, id, trimmed, renameProfile)
              await send(.renameSucceeded(id: id))
            } catch {
              await send(.renameFailed(id: id, previousTitle: previousTitle))
            }
          }
        )

      case let .renameSucceeded(id):
        // PATCH landed — the optimistic title stands; lift the in-flight guard so the poll
        // resumes. Cancel/restart any fetch that started during the PATCH window (see
        // `cancelOrRestartFetch`): with the guard now gone, its (stale) response could
        // otherwise clobber the optimistic title with the server's pre-rename value.
        // Mirrors archiveSucceeded's protection.
        state.renamingInFlightIDs.remove(id)
        return cancelOrRestartFetch(&state)

      case let .renameFailed(id, previousTitle):
        // The rename didn't take (e.g. a 400 for an over-long/duplicate title) — lift the guard,
        // restore the previous title locally, and surface the error.
        state.renamingInFlightIDs.remove(id)
        state.sessions[id: id]?.title = previousTitle
        state.loadError = "Couldn’t rename the session."
        return .none

      case .cancelRename:
        state.renamingID = nil
        state.renameDraft = ""
        return .none

      case .newSessionButtonTapped:
        return .send(.delegate(.createSession(initialComposerText: nil)))

      case .settingsButtonTapped:
        state.settings = SettingsFeature.State(
          connection: state.connection,
          pushAvailable: state.pushAvailable,
          defaultSwipeAction: state.defaultSwipeAction,
          deleteSupported: state.deleteSupported
        )
        return .none

      case .archivedButtonTapped:
        // New presentation → new generation: outcomes of DELETEs initiated under an
        // earlier presentation must not be re-injected into this one (see
        // `archivedSheetGeneration`).
        state.archivedSheetGeneration += 1
        state.archived = ArchivedSessionsFeature.State(
          connection: state.connection,
          profileName: state.scopedProfileName,
          now: state.now,
          // Seed the sheet with the list's capability verdict so an already-flipped flag
          // hides the sheet's Delete affordances from the start.
          deleteSupported: state.deleteSupported
        )
        return .none

      case let .archived(.presented(.delegate(.openSession(session)))):
        // Open from the archived sheet → dismiss it and resume in the main stack.
        state.archived = nil
        return .send(.delegate(.openSession(session)))

      case let .archived(.presented(.delegate(.deleted(id, session, index)))):
        // A delete inside the archived sheet. The sheet already removed the row
        // optimistically; the DELETE round-trip runs HERE — a presented child's effects
        // are cancelled on dismissal, so a sheet-run DELETE racing Done/swipe-down would
        // be silently dropped after the cache wipe already happened. Forward as this
        // list's own `sessionDeleted` FIRST so `AppFeature` wipes the cached snapshot +
        // turn anchor and tears the live-chat slot down when the id matches (an archived
        // session CAN be the slot: opening one from the sheet resumes it without
        // un-archiving, and another client can archive the slot's session).
        let profileName = state.archived?.profileName
        // Stamp the round-trip with the CURRENT presentation so its outcome can only be
        // re-injected into this sheet instance (id alone is ambiguous after a
        // dismiss-and-reopen re-deletes the same session).
        let generation = state.archivedSheetGeneration
        return .concatenate(
          .send(.delegate(.sessionDeleted(id: id))),
          .run { [rest, connection = state.connection] send in
            do {
              try await rest.deleteSession(connection, id, profileName)
              await send(.archivedDeleteSucceeded(id: id, generation: generation))
            } catch {
              await send(.archivedDeleteFailed(
                id: id, session: session, index: index, generation: generation,
                error: asRESTError(error)
              ))
            }
          }
        )

      case let .archivedDeleteSucceeded(id, generation):
        // Server confirmed the sheet-initiated delete → the badge delegate fires (see
        // `Delegate.sessionDeleteSucceeded`), and the outcome is re-injected into the
        // sheet ONLY while the SAME presentation (`generation`) still owns this delete
        // (its `deletingIDs` guard holds the id) — a dismissed sheet has nothing to
        // update, and a re-opened one is a different generation whose fresh fetch (or
        // own re-delete of the same id) this must not touch.
        let confirmed: Effect<Action> = .send(.delegate(.sessionDeleteSucceeded(id: id)))
        guard generation == state.archivedSheetGeneration,
          state.archived?.deletingIDs.contains(id) == true
        else { return confirmed }
        return .merge(confirmed, .send(.archived(.presented(.deleteSucceeded(id: id)))))

      case let .archivedDeleteFailed(id, session, index, generation, error):
        // Re-inject into the sheet while the SAME presentation still owns the delete
        // (rollback + capability verdict happen there, and `deleteUnsupported` mirrors
        // back here). With the sheet gone — or the outcome stamped by a PREVIOUS
        // presentation (a stale failure must not clear a re-opened sheet's own guard and
        // resurrect its row) — the outcome must not vanish: apply the capability
        // verdict — it's server-wide — or the failure banner to the list itself.
        if generation == state.archivedSheetGeneration,
          state.archived?.deletingIDs.contains(id) == true {
          return .send(.archived(.presented(.deleteFailed(
            id: id, session: session, index: index, error: error
          ))))
        }
        if error.isMissingEndpointVerdict {
          state.deleteSupported = false
        } else {
          state.loadError = "Couldn’t delete the session."
        }
        return .none

      case .archived(.presented(.delegate(.deleteUnsupported))):
        // A delete inside the archived sheet answered 404/405 — mirror the capability
        // verdict onto the list's own flag so its Delete affordances hide too.
        state.deleteSupported = false
        return .none

      case .archived:
        return .none

      // MARK: Profiles

      case let .profilesResponse(.success(result)):
        state.profilesSupported = true
        state.profiles = Self.dedupedProfiles(result)
        // If the persisted selection no longer exists on the server, re-home to default.
        if state.profiles[id: state.selectedProfileName] == nil {
          state.selectedProfileName = Self.State.defaultProfileName
          preferences.saveSelectedProfileID(state.selectedProfileName)
        }
        return load(&state)

      case .profilesResponse(.failure):
        // A 404 (old agent) or any failure → behave as today: no scoping, unscoped fetch.
        state.profilesSupported = false
        state.profiles = []
        return load(&state)

      case let .profilesRefreshed(result):
        state.profilesSupported = true
        state.profiles = Self.dedupedProfiles(result)
        return .none

      case let .selectProfile(name):
        // No-op when already selected (avoids a redundant refetch / UI reset).
        guard name != state.selectedProfileName else { return .none }
        state.selectedProfileName = name
        // Reset the list UI on switch (search + group expansion don't carry across profiles).
        state.searchQuery = ""
        state.expandedGroups = []
        // Cron jobs are profile-scoped too: drop the old profile's jobs + peek so the
        // section can't show cross-profile rows while the scoped refetch is in flight.
        state.cronJobs = []
        state.expandedCronJobID = nil
        preferences.saveSelectedProfileID(name)
        return load(&state)

      case .addProfileTapped:
        state.addProfile = AddProfileFeature.State(connection: state.connection)
        return .none

      case let .addProfile(.presented(.delegate(.created(name)))):
        // Dismiss the sheet, refresh the profile list (no fetch), THEN select the new profile
        // (which does the single scoped fetch). Sequential so the refreshed list is in place
        // before the switch, and avoids a redundant double fetch.
        state.addProfile = nil
        return .run { [profiles, connection = state.connection] send in
          if let result = try? await profiles.list(connection) {
            await send(.profilesRefreshed(result))
          }
          await send(.selectProfile(name: name))
        }

      case .addProfile:
        return .none

      case let .renameProfileTapped(name):
        // Open the rename alert (default profile is never renamable).
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        state.renamingProfileName = name
        state.profileRenameDraft = profile.name
        return .none

      case .confirmRenameProfile:
        guard let name = state.renamingProfileName else { return .none }
        let newName = state.profileRenameDraft
        state.renamingProfileName = nil
        state.profileRenameDraft = ""
        return .send(.renameProfileButtonTapped(name: name, newName: newName))

      case .cancelRenameProfile:
        state.renamingProfileName = nil
        state.profileRenameDraft = ""
        return .none

      case let .renameProfileButtonTapped(name, newName):
        // The default profile is never renamable — guard even if the view slips up.
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name, ProfileName.isValid(trimmed) else { return .none }
        // Optimistic rename with rollback (mirrors session rename).
        let previousProfiles = state.profiles
        let previousSelected = state.selectedProfileName
        var renamed = profile
        renamed.name = trimmed
        state.profiles[id: name] = nil
        state.profiles.append(renamed)
        if state.selectedProfileName == name {
          state.selectedProfileName = trimmed
          preferences.saveSelectedProfileID(trimmed)
        }
        return .run { [profiles, connection = state.connection] send in
          do {
            try await profiles.rename(connection, name, trimmed)
            await send(.renameProfileSucceeded)
          } catch {
            await send(.renameProfileFailed(
              previousProfiles: previousProfiles, previousSelected: previousSelected
            ))
          }
        }

      case .renameProfileSucceeded:
        return .none

      case let .renameProfileFailed(previousProfiles, previousSelected):
        state.profiles = previousProfiles
        state.selectedProfileName = previousSelected
        preferences.saveSelectedProfileID(previousSelected)
        state.loadError = "Couldn’t rename the profile."
        return .none

      case let .deleteProfileButtonTapped(name):
        // The default profile is never deletable — guard even if the view slips up.
        guard let profile = state.profiles[id: name], !profile.isDefault else { return .none }
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Delete profile?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDeleteProfile(name: name)) {
            TextState("Delete")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("This permanently deletes the profile and its sessions on the server.")
        }
        return .none

      case let .deleteProfileSucceeded(name):
        state.profiles[id: name] = nil
        // If the deleted profile was active, re-home to default and refetch its sessions.
        if state.selectedProfileName == name {
          state.selectedProfileName = Self.State.defaultProfileName
          state.searchQuery = ""
          state.expandedGroups = []
          state.cronJobs = []
          state.expandedCronJobID = nil
          preferences.saveSelectedProfileID(Self.State.defaultProfileName)
          return load(&state)
        }
        return .none

      case .deleteProfileFailed:
        state.loadError = "Couldn’t delete the profile."
        return .none

      case let .settings(.presented(.delegate(.tokenSaved(token)))):
        state.connection.token = token
        return .none

      case .settings(.presented(.delegate(.disconnect))):
        state.settings = nil
        return .send(.delegate(.disconnect))

      case .settings(.presented(.delegate(.reconnect))):
        // Manual reconnect = re-fetch the list over REST.
        return .send(.pulledToRefresh)

      case let .settings(.presented(.delegate(.defaultSwipeActionChanged(action)))):
        // Mirror the new default immediately (Settings already persisted it) so the swipe
        // rows are right the moment the sheet dismisses.
        state.defaultSwipeAction = action
        return .none

      case .settings(.presented(.delegate(.installPushPlugin))):
        // The Settings push guide's "Ask agent" → dismiss Settings (Settings already requested
        // its own dismissal) and open a new chat with the install prompt pre-filled.
        state.settings = nil
        return .send(.delegate(.createSession(initialComposerText: PushSetup.installPrompt)))

      case .settings:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$settings, action: \.settings) {
      SettingsFeature()
    }
    .ifLet(\.$archived, action: \.archived) {
      ArchivedSessionsFeature()
    }
    .ifLet(\.$addProfile, action: \.addProfile) {
      AddProfileFeature()
    }
    .ifLet(\.$confirmationDialog, action: \.confirmationDialog)
  }

  /// Refresh "now", clear errors, and reload the non-secret persisted prefs (seen counts,
  /// pins, grouping). Shared by `.task` and `load()` — `.task` additionally reloads the
  /// selected profile before probing the profiles capability.
  private func reloadPrefs(_ state: inout State) {
    state.now = now
    state.loadError = nil
    state.seenCounts = preferences.loadSeenCounts()
    state.pinnedIDs = preferences.loadPinnedIDs()
    state.groupingMode = preferences.loadGroupingMode()
    state.defaultSwipeAction = preferences.loadDefaultSessionSwipeAction()
    state.showCronSection = preferences.loadShowCronSection()
  }

  /// Refresh "now", clear errors, reload persisted prefs, and fetch the session list
  /// (profile-scoped when supported; unscoped otherwise — search always unscoped).
  private func load(_ state: inout State) -> Effect<Action> {
    reloadPrefs(&state)
    state.isLoading = true
    return .run { [
      rest, profiles, connection = state.connection, query = state.searchQuery,
      profileName = state.selectedProfileName, profilesSupported = state.profilesSupported,
      cronJobsSupported = state.cronJobsSupported
    ] send in
      await send(fetchSessions(
        rest: rest, profiles: profiles, connection: connection, query: query,
        profileName: profileName, profilesSupported: profilesSupported
      ))
      // Refresh the cron jobs in the SAME effect, after the list, so the two responses
      // arrive in a deterministic order (no racy merge). Skipped while searching (the
      // section is hidden then) and once the agent proved it lacks the API. When the agent
      // supports profiles the fetch is scoped to the SELECTED profile (the literal name,
      // incl. "default" — matching the scoped session list, so a job's runs are actually
      // in `sessions`); unscoped agents omit the param.
      if cronJobsSupported, query.trimmingCharacters(in: .whitespaces).isEmpty {
        await send(fetchCronJobs(
          rest: rest, connection: connection,
          profile: profilesSupported ? profileName : nil
        ))
      }
    }
    // Shared `fetch` id: a newer load/search/poll cancels this one, so an older in-flight
    // fetch finishing late can't overwrite `state.sessions` (stale list or search results).
    .cancellable(id: CancelID.fetch, cancelInFlight: true)
  }

  /// A successful archive/delete/rename just lifted its in-flight guard — that guard was
  /// the only thing filtering the removed/renamed row out of a landing response, so a
  /// fetch that started during the RPC window must not deliver its stale response now.
  /// When one is actually pending (`isLoading`, or an active search whose debounced fetch
  /// may be in flight — and the poll is paused while searching, so nothing would
  /// self-heal), RESTART the current-context fetch: it supersedes the stale one
  /// (`cancelInFlight`) and lands an authoritative post-RPC response instead of stranding
  /// a stuck spinner or stale search results. Otherwise a bare cancel suffices (the poll
  /// is the backstop). A JUST-CLEARED search is covered by the `isLoading` arm: clearing
  /// the query reloads through `load` (see the `searchQuery` binding), which raises the
  /// flag — the debounced search effect is the only fetch that raises neither.
  private func cancelOrRestartFetch(_ state: inout State) -> Effect<Action> {
    guard state.isLoading || state.isSearching else { return .cancel(id: CancelID.fetch) }
    return load(&state)
  }

  /// THE rollback rule for a failed archive/delete RPC (the server still has the session,
  /// so the optimistic removal must be undone). Two halves, deliberately asymmetric:
  ///
  /// - **Pin + seen baseline: ALWAYS restored and persisted.** Both live under single
  ///   device-global prefs keys keyed by session id (`PreferencesClient` — they are not
  ///   profile-scoped), so the restore is correct whatever list the UI shows now; skipping
  ///   it would permanently lose the pin/unread baseline for a session the server kept.
  /// - **The row re-insert applies ONLY while the list still shows the SAME context the
  ///   RPC was issued under** — same profile scope AND same (raw) search query. After a
  ///   mid-flight profile switch the captured session belongs to the OLD profile's list
  ///   (a cross-profile row would open under the wrong scope), and after a query change
  ///   the saved index points into a DIFFERENT result set (the poll is paused while
  ///   searching, so a wrong-query row would stick). A skipped re-insert self-heals: the
  ///   original context's next fetch returns the still-existing row.
  private func rollBackFailedRemoval(
    _ state: inout State, id: Session.ID, session: Session, index: Int,
    pinIndex: Int?, seenCount: Int?, profileName: String?, searchQuery: String
  ) {
    if let pinIndex {
      let pinAt = min(pinIndex, state.pinnedIDs.count)
      state.pinnedIDs.insert(id, at: pinAt)
    }
    state.seenCounts[id] = seenCount
    preferences.savePinnedIDs(state.pinnedIDs)
    preferences.saveSeenCounts(state.seenCounts)
    if profileName == state.scopedProfileName, searchQuery == state.searchQuery {
      let insertAt = min(index, state.sessions.count)
      state.sessions.insert(session, at: insertAt)
    }
  }

  /// Whether the push info sheet is currently snoozed — a persisted `until` exists and `now`
  /// is still before it. A cleared snooze (ready/logout) or an elapsed window returns `false`.
  private func isPushPromptSnoozed() -> Bool {
    guard let snooze = preferences.loadPushPromptSnooze() else { return false }
    return now < snooze.until
  }

  /// Shared trigger/pause/resume flow: guard against a double-fire while the job's RPC is
  /// in flight, then run it and funnel the outcome through `.cronJobActionFinished`.
  /// Threads the same profile scoping as the jobs fetch (literal selected name when the
  /// agent supports profiles, else nil).
  private func performCronAction(
    _ state: inout State,
    id: String,
    refetchSessions: Bool,
    rpc: @escaping @Sendable (HermesRESTClient, ServerConnection, String, String?) async throws -> Void
  ) -> Effect<Action> {
    guard !state.cronActionInFlightIDs.contains(id) else { return .none }
    state.cronActionInFlightIDs.insert(id)
    let profile = state.profilesSupported ? state.selectedProfileName : nil
    return .run { [rest, connection = state.connection] send in
      do {
        try await rpc(rest, connection, id, profile)
        await send(.cronJobActionFinished(id: id, refetchSessions: refetchSessions, error: nil))
      } catch let error as RESTError {
        await send(.cronJobActionFinished(id: id, refetchSessions: refetchSessions, error: error))
      } catch {
        await send(.cronJobActionFinished(id: id, refetchSessions: refetchSessions, error: .unreachable))
      }
    }
  }

  private func persistSeenCounts(_ counts: [String: Int]) -> Effect<Action> {
    .run { [preferences] _ in preferences.saveSeenCounts(counts) }
  }

  private func persistPinnedIDs(_ ids: [String]) -> Effect<Action> {
    .run { [preferences] _ in preferences.savePinnedIDs(ids) }
  }

  /// Build the profile array tolerating a duplicate `name` in the server response (keep
  /// the first occurrence) — `IdentifiedArray(uniqueElements:)` traps on duplicates (#78).
  private static func dedupedProfiles(_ profiles: [Profile]) -> IdentifiedArrayOf<Profile> {
    IdentifiedArray(profiles, uniquingIDsWith: { first, _ in first })
  }
}

/// Fetch the list (or search results when a query is present) and map to a response.
///
/// When `profilesSupported` is true the active list is fetched via the profile-scoped
/// endpoint (`profiles.sessions(profile:…)`); otherwise it falls back to today's
/// unscoped `/api/sessions`. Search is never profile-scoped (mirrors the desktop) — it
/// always goes through `rest.search`.
/// Fetch the cron jobs and map to a response action. `profile` is the literal selected
/// name when the agent supports profiles (matching the scoped session list), else nil
/// (the server aggregates all — which on a single-profile agent is just "default").
private func fetchCronJobs(
  rest: HermesRESTClient,
  connection: ServerConnection,
  profile: String?
) async -> SessionListFeature.Action {
  do {
    return .cronJobsResponse(.success(try await rest.cronJobs(connection, profile)))
  } catch let error as RESTError {
    return .cronJobsResponse(.failure(error))
  } catch {
    return .cronJobsResponse(.failure(.unreachable))
  }
}

private func fetchSessions(
  rest: HermesRESTClient,
  profiles: HermesProfileClient,
  connection: ServerConnection,
  query rawQuery: String,
  profileName: String,
  profilesSupported: Bool
) async -> SessionListFeature.Action {
  let query = rawQuery.trimmingCharacters(in: .whitespaces)
  do {
    let sessions: [Session]
    if !query.isEmpty {
      sessions = try await rest.search(connection, query)
    } else if profilesSupported {
      // The dedicated profiles endpoint takes the literal name (incl. "default") — unlike the
      // legacy per-session mutation endpoints, which use `scopedProfileName` (default→nil). The
      // canonical default name is `SessionListFeature.State.defaultProfileName`.
      sessions = try await profiles.sessions(connection, profileName, .exclude, .recent, 50, 0)
    } else {
      sessions = try await rest.sessions(connection, 50, 0, .recent)
    }
    return .sessionsResponse(.success(sessions))
  } catch let error as RESTError {
    return .sessionsResponse(.failure(error))
  } catch {
    return .sessionsResponse(.failure(.unreachable))
  }
}
