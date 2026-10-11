import ComposableArchitecture
import Foundation

/// The Archived sessions screen (presented as a sheet from the session list). Lists the
/// server's soft-archived sessions (`GET /api/sessions?archived=only`) and lets the user
/// **Restore** them (un-archive via the same `PATCH {archived:false}`), **Delete** them
/// permanently (immediate, no confirmation — this is the bulk-cleanup surface and the
/// rows are already tucked away), or **open** one (bubbled up through
/// `delegate.openSession`, so the main navigation stack resumes it).
@Reducer
public struct ArchivedSessionsFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    /// Active profile to scope the archived list/restore/delete to — seeded from the
    /// list's `scopedProfileName`, so it is the LITERAL selected name (including
    /// `"default"`) whenever the agent has the profiles API, and `nil` only when it
    /// doesn't (#114). When set, listing/restore go through the profile-scoped endpoints
    /// so they hit that profile's `state.db`; `nil` takes the unscoped endpoints, which
    /// the server resolves to its LAUNCH profile (not necessarily `"default"`).
    public var profileName: String?
    public var sessions: IdentifiedArrayOf<Session>
    public var isLoading: Bool
    public var loadError: String?
    /// Reference "now" for relative row timestamps (injected so it's controllable in tests).
    public var now: Date
    /// Ids whose restore (un-archive) PATCH is in flight — guards against a double tap.
    public var restoringIDs: Set<String>
    /// Ids whose permanent DELETE is in flight — same double-tap/refresh guard as restore.
    public var deletingIDs: Set<String>
    /// Whether the agent has the `DELETE /api/sessions/{id}` endpoint. Seeded from the
    /// session list's flag when the sheet is presented; a definitive 404/405 here flips
    /// it off for the rest of the sheet's lifetime (and mirrors back to the list via
    /// `delegate.deleteUnsupported`), hiding the Delete affordances.
    public var deleteSupported: Bool
    /// Non-`nil` while the transient "Session ID copied" toast is showing. Purely transient
    /// confirmation state: raised by a copy, cleared by the timed expiry. It's a counter
    /// rather than a `Bool` so a re-copy while the toast is already up is still an
    /// observable change — that's what re-announces the copy to VoiceOver (a `Bool` would
    /// stay `true` and the announcement would be swallowed).
    public var copiedIDToastToken: Int?

    public init(
      connection: ServerConnection,
      profileName: String? = nil,
      sessions: IdentifiedArrayOf<Session> = [],
      isLoading: Bool = false,
      loadError: String? = nil,
      now: Date = Date(timeIntervalSince1970: 0),
      restoringIDs: Set<String> = [],
      deletingIDs: Set<String> = [],
      deleteSupported: Bool = true,
      copiedIDToastToken: Int? = nil
    ) {
      self.connection = connection
      self.profileName = profileName
      self.sessions = sessions
      self.isLoading = isLoading
      self.loadError = loadError
      self.now = now
      self.restoringIDs = restoringIDs
      self.deletingIDs = deletingIDs
      self.deleteSupported = deleteSupported
      self.copiedIDToastToken = copiedIDToastToken
    }
  }

  public enum Action {
    case task
    case archivedResponse(Result<[Session], RESTError>)
    case restoreButtonTapped(id: Session.ID)
    /// Restore PATCH succeeded — the optimistic removal stands.
    case restoreSucceeded(id: Session.ID)
    /// Restore PATCH failed — re-insert the session at its saved index and surface the error.
    case restoreFailed(id: Session.ID, session: Session, index: Int)
    /// Permanently delete a row — IMMEDIATE, no confirmation (decided in planning: the
    /// archived sheet is the bulk-cleanup surface and its rows are already tucked away).
    case deleteButtonTapped(id: Session.ID)
    /// DELETE landed (an `already_absent` body is success by contract) — the optimistic
    /// removal stands. Re-injected by the PARENT, which owns the round-trip (see
    /// `Delegate.deleted`).
    case deleteSucceeded(id: Session.ID)
    /// DELETE failed — re-insert at the saved index. A 404/405 `error` is the capability
    /// verdict (flip `deleteSupported` off silently); anything else surfaces the banner.
    /// Re-injected by the PARENT, which owns the round-trip (see `Delegate.deleted`).
    case deleteFailed(id: Session.ID, session: Session, index: Int, error: RESTError)
    case sessionTapped(id: Session.ID)
    /// Put a row's session id on the pasteboard and raise the transient confirmation toast.
    case copyIDButtonTapped(id: Session.ID)
    /// The copy toast's dwell time elapsed — hide it.
    case copiedIDToastExpired
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// Open/resume an archived session — the parent dismisses the sheet and navigates.
      case openSession(Session)
      /// A row's permanent delete was initiated (fires BEFORE the DELETE round-trips),
      /// carrying the rollback payload (the removed `session` + its `index`). The PARENT
      /// runs the DELETE round-trip and re-injects `deleteSucceeded`/`deleteFailed` while
      /// the sheet is still up: an effect returned from this presented sheet would be
      /// cancelled the moment the sheet is dismissed (`ifLet` cancels a presented child's
      /// effects), so a Done/swipe-down racing the DELETE would silently leave the
      /// session on the server after the cache and badge were already updated.
      /// The parent also forwards the id as its own `sessionDeleted` so `AppFeature`
      /// wipes the cached snapshot + turn anchor and tears the live-chat slot down when
      /// the id matches. An archived session CAN be the slot: opening one from this
      /// sheet resumes it without un-archiving, and another client can archive the
      /// slot's session out from under this device.
      case deleted(id: Session.ID, session: Session, index: Int)
      /// A delete answered 404/405 (agent lacks the DELETE endpoint) — the parent mirrors
      /// its own `deleteSupported` flag off so the main list hides Delete too.
      case deleteUnsupported
    }
  }

  private enum CancelID { case fetch, copyIDToast }

  /// How long a copy confirmation (the "Session ID copied" toast) stays up before
  /// auto-dismissing. Same name/value in every feature that confirms a copy.
  static let copiedFeedbackDuration: Duration = .seconds(1.5)

  @Dependency(\.hermesREST) var rest
  @Dependency(\.hermesProfiles) var profiles
  @Dependency(\.date.now) var now
  @Dependency(\.continuousClock) var clock
  @Dependency(\.pasteboard) var pasteboard

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.now = now
        return fetchListing(&state)

      case let .archivedResponse(.success(sessions)):
        state.isLoading = false
        state.loadError = nil
        // Drop any row whose restore OR delete is still in flight, so a refresh landing
        // during either window can't resurrect the optimistically removed row.
        let inFlight = state.restoringIDs.union(state.deletingIDs)
        let visible = inFlight.isEmpty
          ? sessions
          : sessions.filter { !inFlight.contains($0.id) }
        state.sessions = IdentifiedArray(uniqueElements: visible)
        return .none

      case let .archivedResponse(.failure(error)):
        state.isLoading = false
        state.loadError = error.message
        return .none

      case let .restoreButtonTapped(id):
        guard let index = state.sessions.index(id: id) else { return .none }
        // Optimistic removal + in-flight guard; re-insert at `index` if the PATCH fails.
        let session = state.sessions[index]
        state.sessions.remove(id: id)
        state.restoringIDs.insert(id)
        return .run { [rest, connection = state.connection, profileName = state.profileName] send in
          do {
            try await rest.archive(connection, id, false, profileName) // archived:false = restore
            await send(.restoreSucceeded(id: id))
          } catch {
            await send(.restoreFailed(id: id, session: session, index: index))
          }
        }

      case let .restoreSucceeded(id):
        state.restoringIDs.remove(id)
        return .none

      case let .restoreFailed(id, session, index):
        state.restoringIDs.remove(id)
        let insertAt = min(index, state.sessions.count)
        state.sessions.insert(session, at: insertAt)
        state.loadError = "Couldn’t restore the session."
        return .none

      case let .deleteButtonTapped(id):
        guard state.deleteSupported else { return .none }
        guard let index = state.sessions.index(id: id) else { return .none }
        // Immediate — no confirmation dialog (planning decision; see the action doc).
        // Optimistic removal + in-flight guard; the DELETE itself is the PARENT's (see
        // the delegate case doc — a presented child's effect dies with the sheet), handed
        // over with the rollback payload. The parent forwards to `AppFeature`, which
        // wipes the cached snapshot + turn anchor and tears the live-chat slot down when
        // this is the slot's session (an archived session CAN be the slot). The wipe
        // deliberately stays even if the DELETE later fails (same asymmetry as the main
        // list: re-opening resumes fresh).
        let session = state.sessions[index]
        state.sessions.remove(id: id)
        state.deletingIDs.insert(id)
        return .send(.delegate(.deleted(id: id, session: session, index: index)))

      case let .deleteSucceeded(id):
        // DELETE landed (re-injected by the parent, which owns the round-trip) — clear
        // the transient guard. A listing fetch still in flight at presentation would —
        // with the guard now gone — resurrect the permanently deleted row when its stale
        // response lands: when one is pending (`isLoading`), RESTART it for a fresh
        // post-delete listing (a bare cancel would strand the sheet's spinner forever —
        // the sheet has no poll); otherwise a plain cancel suffices.
        state.deletingIDs.remove(id)
        guard state.isLoading else { return .cancel(id: CancelID.fetch) }
        return fetchListing(&state)

      case let .deleteFailed(id, session, index, error):
        // The delete didn't take (re-injected by the parent, which owns the round-trip)
        // — the server still has the session. Lift the guard and re-insert at the saved
        // index. A missing-endpoint verdict
        // (`isMissingEndpointVerdict`) → flip the capability off SILENTLY (no banner,
        // like the other capability flips), hide the Delete affordances for the rest of
        // the sheet's lifetime, and mirror the verdict back to the session list.
        // Anything else surfaces the banner.
        state.deletingIDs.remove(id)
        let insertAt = min(index, state.sessions.count)
        state.sessions.insert(session, at: insertAt)
        if error.isMissingEndpointVerdict {
          state.deleteSupported = false
          return .send(.delegate(.deleteUnsupported))
        } else {
          state.loadError = "Couldn’t delete the session."
          return .none
        }

      case let .sessionTapped(id):
        guard let session = state.sessions[id: id] else { return .none }
        return .send(.delegate(.openSession(session)))

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

      case .delegate:
        return .none
      }
    }
  }

  /// Start (or restart) the archived-listing fetch: raise the spinner and fetch the
  /// server's archived list (profile-scoped when the sheet is). ID'd so a completed
  /// delete can supersede it — a stale listing landing after `deleteSucceeded` lifted
  /// the `deletingIDs` filter would resurrect the permanently deleted row.
  private func fetchListing(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.loadError = nil
    return .run { [rest, profiles, connection = state.connection, profileName = state.profileName] send in
      do {
        let sessions: [Session]
        if let profileName {
          // Profile-scoped list → hits this profile's `state.db` (the literal `"default"`
          // included), not the server's launch profile's.
          sessions = try await profiles.sessions(connection, profileName, .only, .recent, 100, 0)
        } else {
          sessions = try await rest.archivedSessions(connection, 100, 0)
        }
        await send(.archivedResponse(.success(sessions)))
      } catch let error as RESTError {
        await send(.archivedResponse(.failure(error)))
      } catch {
        await send(.archivedResponse(.failure(.unreachable)))
      }
    }
    .cancellable(id: CancelID.fetch, cancelInFlight: true)
  }
}
