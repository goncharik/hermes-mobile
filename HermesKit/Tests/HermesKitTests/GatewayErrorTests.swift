import Testing

@testable import HermesKit

/// Tests for the typed `GatewayError` matchers. `isSessionNotFound` gates the #17
/// self-heal: an outbound RPC that fails with a server `"session not found"` (a stale live
/// id after background→foreground) re-resumes for a fresh id and replays the call. Mirrors
/// the `isUnknownMethod` precedent (case-insensitive substring on the `.server` message).
@Suite struct GatewayErrorTests {
  // MARK: isSessionNotFound

  @Test func sessionNotFoundMatchesExactServerMessage() {
    #expect(GatewayError.server("session not found").isSessionNotFound)
  }

  @Test func sessionNotFoundMatchesDifferentCasing() {
    #expect(GatewayError.server("Session Not Found").isSessionNotFound)
    #expect(GatewayError.server("SESSION NOT FOUND").isSessionNotFound)
  }

  @Test func sessionNotFoundMatchesWhenEmbeddedInLongerMessage() {
    // The server may prefix/suffix context around the phrase — match as a substring.
    #expect(GatewayError.server("session not found: 8680ce37").isSessionNotFound)
    #expect(GatewayError.server("error: session not found").isSessionNotFound)
  }

  @Test func sessionNotFoundFalseForOtherServerMessages() {
    #expect(!GatewayError.server("unknown method: prompt.submit").isSessionNotFound)
    #expect(!GatewayError.server("invalid params").isSessionNotFound)
    #expect(!GatewayError.server("").isSessionNotFound)
  }

  @Test func sessionNotFoundFalseForNonServerCases() {
    #expect(!GatewayError.disconnected.isSessionNotFound)
    #expect(!GatewayError.notConnected.isSessionNotFound)
    #expect(!GatewayError.timedOut(method: "prompt.submit").isSessionNotFound)
    #expect(!GatewayError.authExpired.isSessionNotFound)
    #expect(!GatewayError.ticketUnavailable.isSessionNotFound)
  }

  // MARK: cross-check the matchers stay distinct

  @Test func sessionNotFoundAndUnknownMethodAreMutuallyExclusive() {
    let notFound = GatewayError.server("session not found")
    #expect(notFound.isSessionNotFound)
    #expect(!notFound.isUnknownMethod)

    let unknown = GatewayError.server("unknown method: foo")
    #expect(unknown.isUnknownMethod)
    #expect(!unknown.isSessionNotFound)
  }
}
