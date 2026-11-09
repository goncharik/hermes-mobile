import ComposableArchitecture
import Foundation

/// The onboarding Server step (#136): the user types the agent's address, the step probes
/// `/api/status` (and, on a gated server, `/api/auth/providers`) and hands the parent a
/// `ServerProbe` describing what the server that answered offers for sign-in.
///
/// - The typed text is parsed once into a `ServerAddress`; an unparseable address never
///   probes (the view shows the inline hint off `showsInvalidAddressHint`).
/// - The probe walks `ServerAddress.candidates` (as typed, then `:9119` for http without a
///   port) and moves to the next candidate only while nothing (or something that isn't
///   Hermes) answered (`ProbeFailure.triesNextCandidate`) — a Hermes verdict, a 400
///   included, stops the loop. The success carries the candidate that answered, so the
///   `:9119` fallback is what sign-in connects to and saves.
/// - A failure lands in `.failed(FailedServerProbe)`: the address, the candidates tried and
///   the last one's failure — what the card needs for its copy and its Local Network hint.
/// - Editing the address resets to `.idle` and cancels an in-flight probe.
@Reducer
public struct ServerStep {
  @ObservableState
  public struct State: Equatable {
    public var addressText: String
    /// Credentials-verdict entry (#62 fallback): probe once on the first appear. Consumed by
    /// that probe, so popping back from Sign in never re-probes.
    public var autoProbe: Bool
    public var phase: Phase = .idle

    public init(addressText: String = "", autoProbe: Bool = false) {
      self.addressText = addressText
      self.autoProbe = autoProbe
    }

    public enum Phase: Equatable, Sendable {
      /// The probe failed; the card renders it.
      case failed(FailedServerProbe)
      case idle
      case probing(Stage)
    }

    public enum Stage: Equatable, Sendable {
      /// The `/api/status` answer is in; fetching the sign-in options.
      case readingSignInOptions
      /// Waiting for `/api/status` from one of the candidates.
      case reaching
    }

    /// The typed text as an address, or `nil` when it is not usable.
    public var address: ServerAddress? { ServerAddress(addressText) }

    /// Continue is offered once something is typed and no probe is in flight; an invalid
    /// address still taps through to the inline hint rather than a dead button.
    public var canContinue: Bool {
      !isProbing && !addressText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var isProbing: Bool {
      if case .probing = phase { return true }
      return false
    }

    /// The three rows of the probe checklist, in display order.
    public enum Check: CaseIterable, Equatable, Sendable {
      /// "Reaching <host>" — some candidate answered over HTTP.
      case reaching
      /// "Checking it's a Hermes agent" — the answer decoded as `/api/status`.
      case hermes
      /// "Reading sign-in options" — the providers fetch.
      case signInOptions
    }

    public enum CheckStatus: Equatable, Sendable {
      case failed
      case passed
      case pending
      case running
    }

    /// The status of one checklist row for the current phase; `nil` while idle, when no
    /// checklist is shown. `/api/status` answering is what moves the probe to
    /// `.readingSignInOptions`, so that stage has both reaching and the Hermes check passed.
    public func status(of check: Check) -> CheckStatus? {
      let order = Check.allCases
      let index = order.firstIndex(of: check)!
      switch phase {
      case .idle:
        return nil
      case .probing(.reaching):
        return index == 0 ? .running : .pending
      case .probing(.readingSignInOptions):
        return check == .signInOptions ? .running : .passed
      case let .failed(failed):
        let failedIndex = order.firstIndex(of: failed.failure.failedCheck)!
        if index < failedIndex { return .passed }
        return index == failedIndex ? .failed : .pending
      }
    }

    /// Something is typed but it does not parse as an address.
    public var showsInvalidAddressHint: Bool {
      !addressText.trimmingCharacters(in: .whitespaces).isEmpty && address == nil
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case continueButtonTapped
    case delegate(Delegate)
    case onAppear
    case probeResponse(Result<ServerProbe, FailedServerProbe>)
    /// `/api/status` answered — advances `.reaching` → `.readingSignInOptions`.
    case statusReceived

    @CasePathable
    public enum Delegate {
      case probeSucceeded(ServerProbe)
    }
  }

  private enum CancelID { case probe }

  @Dependency(\.hermesREST) var rest

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
      // Only a CHANGED address resets: a redundant binding write (SwiftUI echoing the same
      // text on a focus change) must not cancel the probe it just started.
      .onChange(of: \.addressText) { _, _ in
        Reduce { state, _ in
          // A new address invalidates whatever the old one answered (or is answering).
          state.phase = .idle
          return .cancel(id: CancelID.probe)
        }
      }
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .continueButtonTapped:
        return startProbe(&state)

      case .delegate:
        return .none

      case .onAppear:
        // Only the credentials-verdict entry probes on its own, and only once: a re-appear
        // (popping back from Sign in) leaves the step as the user left it.
        guard state.autoProbe, state.phase == .idle else { return .none }
        state.autoProbe = false
        return startProbe(&state)

      case let .probeResponse(.success(probe)):
        state.phase = .idle
        return .send(.delegate(.probeSucceeded(probe)))

      case let .probeResponse(.failure(failed)):
        state.phase = .failed(failed)
        return .none

      case .statusReceived:
        guard case .probing(.reaching) = state.phase else { return .none }
        state.phase = .probing(.readingSignInOptions)
        return .none
      }
    }
  }

  private func startProbe(_ state: inout State) -> Effect<Action> {
    guard !state.isProbing, let address = state.address else { return .none }
    state.phase = .probing(.reaching)
    return .run { [rest] send in
      // `candidates` is never empty; the placeholder is always overwritten.
      var lastFailure = ProbeFailure.requestFailed("No address to probe")
      var tried: [URL] = []
      candidates: for candidate in address.candidates {
        tried.append(candidate)
        let status: ServerStatus
        switch await rest.probeStatus(candidate) {
        case let .success(answer):
          status = answer
        case let .failure(failure):
          // The last candidate's failure is the one reported (for `mac`, the `:9119` verdict).
          lastFailure = failure
          if failure.triesNextCandidate { continue candidates }
          break candidates
        }
        await send(.statusReceived)
        // Only a gated server has providers worth fetching; a providers failure
        // (404/transport) is swallowed as "no providers", same as the launch probe.
        var providers: [AuthProvider]?
        if status.authRequired == true {
          providers = (try? await rest.authProviders(candidate)) ?? nil
        }
        let probe = ServerProbe(
          address: address,
          baseURL: candidate,
          capability: ServerAuthCapability(from: status, providers: providers),
          version: status.version
        )
        await send(.probeResponse(.success(probe)))
        return
      }
      await send(
        .probeResponse(.failure(FailedServerProbe(address: address, failure: lastFailure, tried: tried)))
      )
    }
    .cancellable(id: CancelID.probe, cancelInFlight: true)
  }
}
