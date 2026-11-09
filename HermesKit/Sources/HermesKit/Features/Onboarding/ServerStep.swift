import ComposableArchitecture
import Foundation

/// The onboarding Server step (#136): the user types the agent's address, the step probes
/// `/api/status` (and, on a gated server, `/api/auth/providers`) and hands the parent a
/// `ServerProbe` describing what the server that answered offers for sign-in.
///
/// - The typed text is parsed once into a `ServerAddress`; an unparseable address never
///   probes (the view shows the inline hint off `showsInvalidAddressHint`).
/// - The probe walks `ServerAddress.candidates` (as typed, then `:9119` for http without a
///   port) and moves to the next candidate ONLY on a transport failure
///   (`ProbeFailure.isTransport`) — any HTTP answer, a 404 or a 400 included, is the server's
///   verdict and stops the loop. The success carries the candidate that answered, so the
///   `:9119` fallback is what sign-in connects to and saves.
/// - A failure lands in `.failed(failure, address)` with the address the card needs for its
///   copy and its Local Network hint (`address.kind == .localNetwork && failure.isTransport`,
///   a view decision).
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
      /// The probe of `address` failed; the card renders `failure` for that address.
      case failed(ProbeFailure, ServerAddress)
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
    case probeResponse(Result<ServerProbe, ProbeFailure>)
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
    Reduce { state, action in
      switch action {
      case .binding(\.addressText):
        // A new address invalidates whatever the old one answered (or is answering).
        state.phase = .idle
        return .cancel(id: CancelID.probe)

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

      case let .probeResponse(.failure(failure)):
        // The address is the one the probe ran against: editing it cancels the probe, so the
        // text still parses to the same address here.
        guard let address = state.address else {
          state.phase = .idle
          return .none
        }
        state.phase = .failed(failure, address)
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
      var lastFailure = ProbeFailure.other("No address to probe")
      candidates: for candidate in address.candidates {
        let status: ServerStatus
        switch await rest.probeStatus(candidate) {
        case let .success(answer):
          status = answer
        case let .failure(failure):
          // The last candidate's failure is the one reported (for `mac`, the `:9119` verdict).
          lastFailure = failure
          // An HTTP answer is the server's verdict; only "nothing answered" tries the next
          // candidate.
          if failure.isTransport { continue candidates }
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
      await send(.probeResponse(.failure(lastFailure)))
    }
    .cancellable(id: CancelID.probe, cancelInFlight: true)
  }
}
