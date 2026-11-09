import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

private let basicProvider = AuthProvider(
  name: "basic", displayName: "Password", supportsPassword: true
)

private let tokenOnlyStatus = ServerStatus(version: "0.17.0")

private let gatedStatus = ServerStatus(
  version: "0.17.0", authRequired: true, authProviders: ["basic"]
)

private func state(_ text: String, autoProbe: Bool = false) -> ServerStep.State {
  ServerStep.State(addressText: text, autoProbe: autoProbe)
}

/// The failed phase for `text` after the probe walked its first `tried` candidates (all of
/// them by default).
private func failed(
  _ failure: ProbeFailure, _ text: String, tried: Int? = nil
) -> ServerStep.State.Phase {
  let address = ServerAddress(text)!
  let candidates = address.candidates
  return .failed(
    FailedServerProbe(
      address: address, failure: failure, tried: Array(candidates.prefix(tried ?? candidates.count))
    )
  )
}

@MainActor
struct ServerStepTests {
  // MARK: - Derived state

  @Test func continueNeedsTextAndNoProbeInFlight() {
    #expect(state("").canContinue == false)
    #expect(state("   ").canContinue == false)
    #expect(state("mac").canContinue == true)
    var probing = state("mac")
    probing.phase = .probing(.reaching)
    #expect(probing.canContinue == false)
    #expect(probing.isProbing == true)
  }

  @Test func invalidAddressHintShowsOnlyForTypedUnparseableText() {
    #expect(state("").showsInvalidAddressHint == false)
    #expect(state("mac:9119").showsInvalidAddressHint == false)
    #expect(state("http://").showsInvalidAddressHint == true)
    #expect(state("http://").address == nil)
  }

  @Test func checklistFollowsThePhase() {
    var step = state("mac")
    let checks = ServerStep.State.Check.allCases
    #expect(checks == [.reaching, .hermes, .signInOptions])
    #expect(checks.map { step.status(of: $0) } == [nil, nil, nil])

    step.phase = .probing(.reaching)
    #expect(checks.map { step.status(of: $0) } == [.running, .pending, .pending])

    step.phase = .probing(.readingSignInOptions)
    #expect(checks.map { step.status(of: $0) } == [.passed, .passed, .running])

    step.phase = failed(.refused, "mac")
    #expect(checks.map { step.status(of: $0) } == [.failed, .pending, .pending])

    step.phase = failed(.notHermes(httpStatus: 404), "mac")
    #expect(checks.map { step.status(of: $0) } == [.passed, .failed, .pending])
  }

  // MARK: - Continue

  @Test func invalidAddressStaysIdleWithoutProbing() async {
    let store = TestStore(initialState: state("http://")) { ServerStep() }
    await store.send(.continueButtonTapped)
  }

  @Test func successOnTheFirstCandidate() async {
    let probed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state("mac:9119")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { url in
        probed.withValue { $0.append(url) }
        return .success(tokenOnlyStatus)
      }
    }
    let expected = ServerProbe(
      address: ServerAddress("mac:9119")!,
      baseURL: URL(string: "http://mac:9119")!,
      capability: .tokenOnly,
      version: "0.17.0"
    )
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(\.delegate.probeSucceeded, expected)
    #expect(probed.value == [URL(string: "http://mac:9119")!])
  }

  @Test func gatedServerFetchesProvidersFromTheAnsweringURL() async {
    let providersURL = LockIsolated<URL?>(nil)
    let store = TestStore(initialState: state("https://agent.example.com")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in .success(gatedStatus) }
      $0.hermesREST.authProviders = { url in
        providersURL.setValue(url)
        return [basicProvider]
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(\.delegate.probeSucceeded)
    #expect(providersURL.value == URL(string: "https://agent.example.com"))
  }

  @Test func providersFailureIsSwallowedAsNoProviders() async {
    let store = TestStore(initialState: state("mac:9119")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in .success(gatedStatus) }
      $0.hermesREST.authProviders = { _ in throw RESTError.notFound }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(
      \.delegate.probeSucceeded,
      ServerProbe(
        address: ServerAddress("mac:9119")!,
        baseURL: URL(string: "http://mac:9119")!,
        capability: .tokenOnly,
        version: "0.17.0"
      )
    )
  }

  @Test func gatedSuccessCarriesTheProbedCapability() async {
    let store = TestStore(initialState: state("mac:9119")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in .success(gatedStatus) }
      $0.hermesREST.authProviders = { _ in [basicProvider] }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(
      \.delegate.probeSucceeded,
      ServerProbe(
        address: ServerAddress("mac:9119")!,
        baseURL: URL(string: "http://mac:9119")!,
        capability: ServerAuthCapability(from: gatedStatus, providers: [basicProvider]),
        version: "0.17.0"
      )
    )
  }

  // MARK: - Fallback port

  @Test func refusedFallsBackTo9119AndTheSuccessCarriesIt() async {
    let probed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state("mac")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { url in
        probed.withValue { $0.append(url) }
        return url.port == 9119 ? .success(tokenOnlyStatus) : .failure(.refused)
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(
      \.delegate.probeSucceeded,
      ServerProbe(
        address: ServerAddress("mac")!,
        baseURL: URL(string: "http://mac:9119")!,
        capability: .tokenOnly,
        version: "0.17.0"
      )
    )
    #expect(probed.value == [URL(string: "http://mac")!, URL(string: "http://mac:9119")!])
  }

  /// Something that isn't Hermes on port 80 (a NAS page, a web server) is no reason to stop:
  /// the dashboard may still be on its default port.
  @Test func notHermesOnTheTypedURLFallsBackTo9119() async {
    let probed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state("mac")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { url in
        probed.withValue { $0.append(url) }
        return url.port == 9119 ? .success(tokenOnlyStatus) : .failure(.notHermes(httpStatus: 404))
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(\.delegate.probeSucceeded)
    #expect(store.state.phase == .idle)
    #expect(probed.value == [URL(string: "http://mac")!, URL(string: "http://mac:9119")!])
  }

  /// A Hermes verdict (or a failure no other port changes) is final.
  @Test(arguments: [
    ProbeFailure.hostRejected(detail: "Invalid Host header. Dashboard requests must use the bound hostname."),
    .httpError("Bad Request"),
    .untrustedCertificate,
    .offline,
    .requestFailed("unsupported URL"),
  ])
  func aFinalFailureDoesNotFallBack(failure: ProbeFailure) async {
    let probed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state("mac")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { url in
        probed.withValue { $0.append(url) }
        return .failure(failure)
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.probeResponse.failure) {
      $0.phase = failed(failure, "mac", tried: 1)
    }
    #expect(probed.value == [URL(string: "http://mac")!])
  }

  @Test func bothCandidatesFailingReportsTheLastFailure() async {
    let probed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state("192.168.1.20")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { url in
        probed.withValue { $0.append(url) }
        return .failure(url.port == 9119 ? .timedOut : .refused)
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.probeResponse.failure) {
      $0.phase = failed(.timedOut, "192.168.1.20")
    }
    #expect(probed.value.count == 2)
  }

  /// Mixed: nothing on port 80, and `:9119` answers with a verdict — that answer (and both
  /// URLs tried) is what the card reports.
  @Test(arguments: [
    ProbeFailure.notHermes(httpStatus: 404),
    .hostRejected(detail: "Invalid Host header."),
  ])
  func aRefusedTypedURLThenAnAnswerOn9119ReportsTheAnswer(answer: ProbeFailure) async {
    let probed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state("mac")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { url in
        probed.withValue { $0.append(url) }
        return .failure(url.port == 9119 ? answer : .refused)
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.probeResponse.failure) {
      $0.phase = failed(answer, "mac")
    }
    #expect(probed.value == [URL(string: "http://mac")!, URL(string: "http://mac:9119")!])
  }

  @Test func explicitPortOrHTTPSHasNoFallback() async {
    for text in ["mac:8080", "https://mac"] {
      let probed = LockIsolated<[URL]>([])
      let store = TestStore(initialState: state(text)) {
        ServerStep()
      } withDependencies: {
        $0.hermesREST.probeStatus = { url in
          probed.withValue { $0.append(url) }
          return .failure(.refused)
        }
      }
      await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
      await store.receive(\.probeResponse.failure) {
        $0.phase = failed(.refused, text)
      }
      #expect(probed.value.count == 1)
    }
  }

  // MARK: - Failures

  @Test(arguments: [
    ProbeFailure.offline,
    .hostNotFound,
    .refused,
    .timedOut,
    .untrustedCertificate,
    .notHermes(httpStatus: 404),
    .notHermes(httpStatus: 200),
    .hostRejected(detail: "Invalid Host header"),
    .httpError("HTTP 500"),
    .requestFailed("unsupported URL"),
  ])
  func eachFailureLandsInFailedWithItsAddress(failure: ProbeFailure) async {
    let store = TestStore(initialState: state("https://agent.example.com")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in .failure(failure) }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.probeResponse.failure) {
      $0.phase = failed(failure, "https://agent.example.com")
    }
  }

  @Test func retryAfterAFailureProbesAgain() async {
    let attempts = LockIsolated(0)
    var initial = state("mac:9119")
    initial.phase = failed(.refused, "mac:9119")
    let store = TestStore(initialState: initial) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in
        attempts.withValue { $0 += 1 }
        return .failure(.timedOut)
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.receive(\.probeResponse.failure) {
      $0.phase = failed(.timedOut, "mac:9119")
    }
    #expect(attempts.value == 1)
  }

  @Test func continueWhileProbingIsIgnored() async {
    var initial = state("mac:9119")
    initial.phase = .probing(.reaching)
    let store = TestStore(initialState: initial) { ServerStep() }
    await store.send(.continueButtonTapped)
  }

  // MARK: - Editing

  @Test func editingCancelsAnInFlightProbe() async {
    let store = TestStore(initialState: state("mac:9119")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in
        try? await Task.never()
        return .success(tokenOnlyStatus)
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    await store.send(\.binding.addressText, "mac:9120") {
      $0.addressText = "mac:9120"
      $0.phase = .idle
    }
    await store.finish()
  }

  /// SwiftUI may write the field's unchanged text back (e.g. on the focus change Continue
  /// causes): that is not an edit, so the probe it just started keeps running and lands.
  @Test func aRedundantAddressWriteDoesNotCancelTheProbe() async {
    let (started, signalStarted) = AsyncStream<Void>.makeStream()
    let release = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let store = TestStore(initialState: state("mac:9119")) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in
        await withCheckedContinuation { continuation in
          release.setValue(continuation)
          signalStarted.yield()
        }
        return .success(tokenOnlyStatus)
      }
    }
    await store.send(.continueButtonTapped) { $0.phase = .probing(.reaching) }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    await store.send(\.binding.addressText, "mac:9119")
    release.value?.resume()
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(\.delegate.probeSucceeded)
  }

  @Test func editingClearsAFailure() async {
    var initial = state("mac:9119")
    initial.phase = failed(.refused, "mac:9119")
    let store = TestStore(initialState: initial) { ServerStep() }
    await store.send(\.binding.addressText, "mac:9120") {
      $0.addressText = "mac:9120"
      $0.phase = .idle
    }
  }

  // MARK: - Auto-probe

  @Test func autoProbeOnAppearAndNoReprobeOnReappear() async {
    let attempts = LockIsolated(0)
    let store = TestStore(initialState: state("http://mac:9119", autoProbe: true)) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in
        attempts.withValue { $0 += 1 }
        return .success(tokenOnlyStatus)
      }
    }
    await store.send(.onAppear) {
      $0.autoProbe = false
      $0.phase = .probing(.reaching)
    }
    await store.receive(\.statusReceived) { $0.phase = .probing(.readingSignInOptions) }
    await store.receive(\.probeResponse.success) { $0.phase = .idle }
    await store.receive(\.delegate.probeSucceeded)
    // Popping back from Sign in re-appears the step: no second probe.
    await store.send(.onAppear)
    #expect(attempts.value == 1)
  }

  @Test func autoProbeFailureDoesNotReprobeOnReappear() async {
    let store = TestStore(initialState: state("http://mac:9119", autoProbe: true)) {
      ServerStep()
    } withDependencies: {
      $0.hermesREST.probeStatus = { _ in .failure(.refused) }
    }
    await store.send(.onAppear) {
      $0.autoProbe = false
      $0.phase = .probing(.reaching)
    }
    await store.receive(\.probeResponse.failure) {
      $0.phase = failed(.refused, "http://mac:9119")
    }
    await store.send(.onAppear)
  }

  @Test func onAppearWithoutAutoProbeDoesNothing() async {
    let store = TestStore(initialState: state("mac:9119")) { ServerStep() }
    await store.send(.onAppear)
  }

  @Test func statusReceivedOutsideReachingIsIgnored() async {
    let store = TestStore(initialState: state("mac:9119")) { ServerStep() }
    await store.send(.statusReceived)
  }
}
