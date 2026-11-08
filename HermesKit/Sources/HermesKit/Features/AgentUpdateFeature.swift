import ComposableArchitecture
import Foundation

/// Settings' agent updater: offers a confirmed, server-side `hermes update` next to the Agent
/// row and follows it to a verdict. The full contract is in `docs/features/agent-update.md`;
/// the invariants this reducer enforces:
///
/// - **One POST per confirmation, never retried.** A transport failure or a 5xx after sending
///   is ambiguous (the server may have started), so it lands in `.uncertain`, not a retry.
/// - **Ownership.** The action id the POST returns is persisted (`OwnedAgentUpdate`, scoped to
///   server + account) BEFORE the result reaches the reducer, so dismissing Settings or a
///   relaunch re-observes the run read-only instead of losing it or starting another.
/// - **Read fencing.** Every check/status read runs under one cancel ID; appearing,
///   confirming, rechecking and settling cancel whatever is still in flight, so a slow
///   response from an earlier phase is dropped and can never relabel the current one.
/// - **Only a correlated receipt settles.** Success needs a finished receipt that is
///   provably this phone's run; a reconnect, an exit code or another run's receipt never is.
///   Anything unprovable ends `.uncertain`, with a GET-only "Check update status".
/// - **Hidden when unusable**: no credential, a 401/403, or an agent without the endpoints
///   (404/405) shows nothing.
@Reducer
public struct AgentUpdateFeature {
  @ObservableState
  public struct State: Equatable {
    /// Derived from `SettingsFeature.State.connection`. Not observed: no view reads it, and
    /// the parent's getter writes it on every read.
    @ObservationStateIgnored public var connection: ServerConnection
    public var phase: Phase
    /// The last availability check; drives the Update button and the install guidance.
    public var check: AgentUpdateCheck?
    /// The update this phone started and still has to settle (mirrors `PreferencesClient`).
    public var owned: OwnedAgentUpdate?
    /// A user-initiated (or reopen) GET is in flight — disables the recheck button.
    public var isRechecking: Bool
    /// Consecutive idle statuses that couldn't settle the owned run. Bounded, so a run whose
    /// receipt can't be correlated releases ownership instead of blocking the updater.
    public var idleObservations: Int
    @Presents public var confirmationDialog: ConfirmationDialogState<Action.Dialog>?

    public enum Phase: Equatable, Sendable {
      /// Nothing to show: not checked yet, the check failed, or this server/credential can't
      /// use the updater.
      case hidden
      case checking
      /// Checked; `check` says whether an update is offered or which guidance to show.
      case ready
      case starting
      /// This phone's update is running (or finishing its restart/verify steps).
      case running
      /// An update this phone didn't start is running; never reported as ours.
      case externalRunning
      /// This phone's run finished successfully; carries its receipt's version.
      case succeeded(String?)
      case failed(String)
      /// The outcome can't be proven either way; only a read-only status check is offered.
      case uncertain
    }

    public init(
      connection: ServerConnection,
      phase: Phase = .hidden,
      check: AgentUpdateCheck? = nil,
      owned: OwnedAgentUpdate? = nil
    ) {
      self.connection = connection
      self.phase = phase
      self.check = check
      self.owned = owned
      self.isRechecking = false
      self.idleObservations = 0
    }

    /// A git install with commits available and nothing else in flight → the Update button.
    public var offersUpdate: Bool {
      guard phase == .ready, owned == nil, let check else { return false }
      return check.canApply && check.updateAvailable
    }

    /// The server's guidance for an install the app can't update (docker, nix, apt, managed).
    public var guidance: String? {
      guard phase == .ready, let check, !check.canApply else { return nil }
      return check.message
    }

    /// Unsettled observations offer only a read-only status GET, never another start.
    public var offersStatusRecheck: Bool { phase == .uncertain || phase == .externalRunning }

    /// A settled outcome offers a fresh availability check.
    public var offersCheckAgain: Bool {
      switch phase {
      case .succeeded, .failed: true
      default: false
      }
    }
  }

  public enum Action {
    case task
    case updateTapped
    /// "Check update status" (unsettled) or "Check again" (settled). GET only.
    case recheckTapped
    case confirmationDialog(PresentationAction<Dialog>)
    case checked(Result<AgentUpdateCheck, RESTError>)
    /// The single POST's result. `owned` is what the effect already persisted.
    case started(Result<AgentUpdateStart, RESTError>, owned: OwnedAgentUpdate?)
    case observed(Observation, Result<AgentUpdateActionStatus, RESTError>)
    case observationExpired
    case delegate(Delegate)

    @CasePathable
    public enum Dialog: Equatable, Sendable {
      case confirmUpdate
    }

    /// Why a status GET was made: `recovery` looks for an update started elsewhere on
    /// appearance, `reopen` resumes an owned one, `poll` follows ours, `recheck` is the user's.
    public enum Observation: Equatable, Sendable { case recovery, reopen, poll, recheck }

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// This phone's update succeeded; the Agent row should show the new version.
      case updated(version: String?)
    }
  }

  @Dependency(\.hermesREST) var rest
  @Dependency(\.preferences) var preferences
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  /// Every read (availability check, status GET, poll) runs under `reads`. Starting a new
  /// phase cancels it, and TCA drops what a cancelled effect sends, so a late answer from an
  /// earlier phase never reaches the reducer. The POST is deliberately NOT under it: its
  /// result must always land (see `.started`).
  private enum CancelID { case reads }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        // A POST in flight reports back on its own; re-probing now would race it.
        guard state.phase != .starting else { return .none }
        // Token mode with no token has no dashboard credential to send: nothing to offer.
        if case .token("") = state.connection.auth {
          state.phase = .hidden
          return .cancel(id: CancelID.reads)
        }
        state.idleObservations = 0
        state.owned = preferences.loadOwnedAgentUpdate(state.connection.agentUpdateScope)
        if state.owned != nil {
          // Our update from an earlier visit: observe it read-only, never replay the POST,
          // and offer no start until it settles.
          state.phase = .uncertain
          state.isRechecking = true
          return observe(state, .reopen)
        }
        state.phase = .checking
        return fetchCheck(state)

      case let .checked(result):
        state.isRechecking = false
        switch result {
        case let .success(check):
          state.check = check
          // Availability never overrides an owned or external observation.
          guard state.owned == nil, state.phase == .checking else { return .none }
          state.phase = .ready
          // The endpoints exist: look for an update already running (started elsewhere).
          // A read, so a confirmed start cancels it.
          return observe(state, .recovery)
        case let .failure(error):
          // Informational like the Agent row: hide rather than banner (an owned run keeps its
          // observation). Missing endpoints and credentials the dashboard rejects are
          // expected, not worth a log line.
          if state.owned == nil { state.phase = .hidden }
          if !error.isMissingEndpointVerdict, !error.rejectsCredential {
            debugLog.note("api.update.check", error.message)
          }
        }
        return .none

      case .updateTapped:
        guard state.offersUpdate else { return .none }
        state.confirmationDialog = ConfirmationDialogState {
          TextState("Update Hermes agent?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmUpdate) {
            TextState("Update")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "This runs hermes update on the server and restarts it. Every session on that install may be interrupted, including the dashboard and messaging gateways."
          )
        }
        return .none

      case .confirmationDialog(.presented(.confirmUpdate)):
        guard state.offersUpdate else { return .none }
        state.confirmationDialog = nil
        state.phase = .starting
        state.isRechecking = false
        let requestedAt = now
        // Fence: recovery/availability reads still in flight are now stale.
        return .merge(.cancel(id: CancelID.reads), .run { [rest, preferences, connection = state.connection] send in
          // Unstructured on purpose: dismissing Settings cancels this effect, but a POST
          // already on the wire must still deliver its action id to persistence — otherwise
          // reopening would find a running update it can't recognize as ours.
          let result = await Task { try await rest.startAgentUpdate(connection) }.result
            .mapError(asRESTError)
          var owned: OwnedAgentUpdate?
          if case let .success(.started(actionID?)) = result {
            owned = OwnedAgentUpdate(
              scope: connection.agentUpdateScope, actionID: actionID, requestedAt: requestedAt
            )
            preferences.saveOwnedAgentUpdate(owned!)
          }
          await send(.started(result, owned: owned))
        })

      case .confirmationDialog:
        return .none

      case let .started(result, owned):
        guard state.phase == .starting else {
          // Superseded locally, but an accepted run is still ours: adopt it for a read-only
          // status check.
          if let owned, state.owned == nil {
            state.owned = owned
            state.phase = .uncertain
          }
          return .none
        }
        switch result {
        case let .failure(error):
          // The request may have reached the server: ambiguous, never retried.
          state.phase = error.isAmbiguousAfterSend ? .uncertain : .failed(error.message)
          return .none
        case .success(.alreadyRunning):
          state.phase = .externalRunning
          return .none
        case .success(.started(actionID: nil)):
          // An older agent that names no action: the run can't be told apart from others.
          state.phase = .uncertain
          return .none
        case .success(.started):
          state.owned = owned
          state.idleObservations = 0
          state.phase = .running
          return poll(state)
        }

      case let .observed(source, result):
        if source != .poll { state.isRechecking = false }
        guard case let .success(status) = result else {
          // A restart briefly cuts the connection: polling carries on. A failed explicit read
          // leaves an owned/uncertain run unknown — never "ready".
          if source == .recheck || source == .reopen, state.owned != nil || state.phase == .uncertain {
            state.phase = .uncertain
          }
          return .none
        }
        if let owned = state.owned {
          return settleOwned(&state, owned, source, status)
        }
        // Not ours: an update from another client is never labelled a success here.
        if status.running {
          if state.phase != .hidden { state.phase = .externalRunning }
          return .none
        }
        // Authoritatively idle after an explicit recheck: only now may a start be offered
        // again, after a fresh availability check.
        guard source == .recheck else { return .none }
        state.phase = .checking
        state.isRechecking = true
        return fetchCheck(state)

      case .observationExpired:
        if state.phase == .running { state.phase = .uncertain }
        return .none

      case .recheckTapped:
        guard !state.isRechecking else { return .none }
        if state.offersStatusRecheck {
          state.isRechecking = true
          return observe(state, .recheck)
        }
        guard state.offersCheckAgain else { return .none }
        state.phase = .checking
        state.isRechecking = true
        return fetchCheck(state)

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$confirmationDialog, action: \.confirmationDialog)
  }

  // MARK: Owned settlement

  /// Interpret a status for the run this phone owns. Server facts this relies on
  /// (`hermes_cli/web_routers/actions.py`): the status `action_id` appears only once the
  /// update log carries that run's success marker, which is printed BEFORE the restart and
  /// receipt finalize; `receipt` is this action's receipt when one exists, else the newest
  /// of any run, and names its writer in `action_id` on current agents.
  private func settleOwned(
    _ state: inout State, _ owned: OwnedAgentUpdate,
    _ source: Action.Observation, _ status: AgentUpdateActionStatus
  ) -> Effect<Action> {
    // The server has moved on to another action: ours can no longer be observed.
    if let other = status.actionID, other != owned.actionID {
      state.phase = status.running ? .externalRunning : .uncertain
      return release(&state, owned)
    }
    let receipt = status.receipt.flatMap { owned.owns($0) ? $0 : nil }
    if let receipt, receipt.finishedAt != nil {
      // Success must be proven by id: the receipt names our action, or (older agents whose
      // receipts carry no id) the success marker for our action is in the log. A
      // time-correlated failure is enough to report failure; never success.
      let provenOurs = receipt.actionID == owned.actionID || status.actionID == owned.actionID
      switch receipt.outcome {
      case "success":
        state.phase = provenOurs ? .succeeded(receipt.postVersion) : .uncertain
      case "partial", "failed", "refused":
        state.phase = .failed(
          receipt.outcome == "refused"
            ? "The server refused the update. Check its update log."
            : "The update didn't complete cleanly. Check the server's update log."
        )
      default:
        state.phase = .uncertain
      }
      let effect = release(&state, owned)
      if case let .succeeded(version) = state.phase {
        return .merge(effect, .send(.delegate(.updated(version: version))))
      }
      return effect
    }
    if status.running {
      // In progress (a nil id is the normal running shape): ours, as far as we can tell.
      state.idleObservations = 0
      guard state.phase != .running else { return .none }
      state.phase = .running
      return poll(state)
    }
    // Idle but still finishing: our receipt isn't finalized yet, or our success marker is
    // logged while the restart + verify steps run. Keep following it — unless the user
    // explicitly rechecks after the bounded poll ran out, which releases it as unknown so a
    // receipt that never arrives can't block the updater for good.
    let finishing = receipt != nil || status.actionID == owned.actionID
    if finishing, source != .recheck {
      if source == .poll { return .none }
      state.phase = .running
      return poll(state)
    }
    // Idle and nothing correlates (no receipt, an older run's, or an unprovable one).
    state.idleObservations += 1
    if source == .recheck || state.idleObservations >= ownedIdleReleaseLimit {
      state.phase = .uncertain
      return release(&state, owned)
    }
    if source != .poll { state.phase = .uncertain }
    return .none
  }

  /// Drop ownership (persisted slot included) and cancel late polls.
  private func release(_ state: inout State, _ owned: OwnedAgentUpdate) -> Effect<Action> {
    preferences.clearOwnedAgentUpdate(owned.actionID)
    state.owned = nil
    state.idleObservations = 0
    return .cancel(id: CancelID.reads)
  }

  // MARK: Effects

  /// One availability check; replaces any read still in flight.
  private func fetchCheck(_ state: State) -> Effect<Action> {
    .run { [rest, connection = state.connection] send in
      do {
        await send(.checked(.success(try await rest.checkAgentUpdate(connection))))
      } catch {
        await send(.checked(.failure(asRESTError(error))))
      }
    }
    .cancellable(id: CancelID.reads, cancelInFlight: true)
  }

  /// One read-only status GET; replaces any read still in flight.
  private func observe(_ state: State, _ source: Action.Observation) -> Effect<Action> {
    .run { [rest, connection = state.connection] send in
      do {
        await send(.observed(source, .success(try await rest.agentUpdateStatus(connection))))
      } catch {
        await send(.observed(source, .failure(asRESTError(error))))
      }
    }
    .cancellable(id: CancelID.reads, cancelInFlight: true)
  }

  /// Bounded (30 min) follow of the owned run while Settings is open. The server update
  /// carries on regardless; reopening Settings resumes the observation.
  private func poll(_ state: State) -> Effect<Action> {
    .run { [rest, clock, connection = state.connection] send in
      for _ in 0..<pollLimit {
        do {
          await send(.observed(.poll, .success(try await rest.agentUpdateStatus(connection))))
        } catch is CancellationError {
          return
        } catch {
          await send(.observed(.poll, .failure(asRESTError(error))))
        }
        do { try await clock.sleep(for: pollInterval) } catch { return }
      }
      await send(.observationExpired)
    }
    .cancellable(id: CancelID.reads, cancelInFlight: true)
  }
}

/// Idle statuses that can't settle an owned run before it is released as unknown.
let ownedIdleReleaseLimit = 3
private let pollInterval: Duration = .seconds(5)
private let pollLimit = 360

extension RESTError {
  /// The request may have reached the server before failing, so its effect is unknown. A
  /// 5xx counts: a proxy's 502/503/504 or a handler crash can follow a spawned update.
  var isAmbiguousAfterSend: Bool {
    switch self {
    case .unreachable, .offline, .decoding, .serviceUnavailable: true
    case let .server(status, _): (500..<600).contains(status)
    default: false
    }
  }

  /// The dashboard rejected this credential for the endpoint.
  var rejectsCredential: Bool {
    switch self {
    case .unauthorized, .server(status: 403, detail: _): true
    default: false
    }
  }
}
