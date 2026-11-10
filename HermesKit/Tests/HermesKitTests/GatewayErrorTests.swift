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

  /// A session-authority host's refusal is the bare reason code (#166), matched exactly.
  @Test func sessionNotFoundMatchesTheAuthorityReasonCode() {
    #expect(GatewayError.server("not_found").isSessionNotFound)
    #expect(!GatewayError.server("file not_found here").isSessionNotFound)
    #expect(!GatewayError.server("permission_denied").isSessionNotFound)
  }

  @Test func submitUnattachedMatchesOnlyPermissionDenied() {
    #expect(GatewayError.server("permission_denied").isSubmitUnattached)
    #expect(!GatewayError.server("not_found").isSubmitUnattached)
    #expect(!GatewayError.disconnected.isSubmitUnattached)
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

  // MARK: isUnknownReasoningValue

  @Test func unknownReasoningValueMatchesServerText() {
    #expect(GatewayError.server("unknown reasoning value: max").isUnknownReasoningValue)
    #expect(GatewayError.server("unknown reasoning value: ultra").isUnknownReasoningValue)
  }

  @Test func unknownReasoningValueMatchesDifferentCasing() {
    #expect(GatewayError.server("Unknown Reasoning Value: max").isUnknownReasoningValue)
    #expect(GatewayError.server("UNKNOWN REASONING VALUE: ultra").isUnknownReasoningValue)
  }

  @Test func unknownReasoningValueFalseForOtherServerMessages() {
    // Prefix-anchored like `isUnknownMethod`: only the gateway's own 4002 text counts.
    #expect(!GatewayError.server("unknown method: config.set").isUnknownReasoningValue)
    #expect(!GatewayError.server("session not found").isUnknownReasoningValue)
    #expect(!GatewayError.server("cannot switch model mid-turn").isUnknownReasoningValue)
    #expect(!GatewayError.server("").isUnknownReasoningValue)
    #expect(!GatewayError.server("error: unknown reasoning value: max").isUnknownReasoningValue)
  }

  @Test func unknownReasoningValueFalseForNonServerCases() {
    #expect(!GatewayError.timedOut(method: "config.set").isUnknownReasoningValue)
    #expect(!GatewayError.disconnected.isUnknownReasoningValue)
    #expect(!GatewayError.notConnected.isUnknownReasoningValue)
    #expect(!GatewayError.authExpired.isUnknownReasoningValue)
    #expect(!GatewayError.ticketUnavailable.isUnknownReasoningValue)
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

  @Test func unknownReasoningValueIsDistinctFromTheOtherMatchers() {
    let rejected = GatewayError.server("unknown reasoning value: max")
    #expect(rejected.isUnknownReasoningValue)
    #expect(!rejected.isUnknownMethod)
    #expect(!rejected.isSessionNotFound)
    #expect(!rejected.isDisconnected)
    #expect(!rejected.isTimedOut)
  }
}
