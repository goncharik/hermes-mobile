import Foundation
import Testing

@testable import HermesKit

/// Pure-logic tests for the turn-timer formatter (`formatElapsed`) and the
/// `ChatRow.copyText` reasoning branch.
@Suite struct ThinkingModelTests {
  @Test func formatElapsedBoundaries() {
    #expect(formatElapsed(0) == "0s")
    #expect(formatElapsed(5) == "5s")
    #expect(formatElapsed(59) == "59s")
    #expect(formatElapsed(60) == "1m 0s")
    #expect(formatElapsed(61) == "1m 1s")
    #expect(formatElapsed(3599) == "59m 59s")
    #expect(formatElapsed(3600) == "1h 0m 0s")
    #expect(formatElapsed(3661) == "1h 1m 1s")
    #expect(formatElapsed(7325) == "2h 2m 5s")
  }

  @Test func formatElapsedNegativeFloorsToZero() {
    #expect(formatElapsed(-1) == "0s")
    #expect(formatElapsed(-1000) == "0s")
  }

  @Test func copyTextIsTheBurstText() {
    let row = ChatRow(id: UUID(), kind: .reasoning(text: "weighing options"))
    #expect(row.copyText == "weighing options")
  }

  @Test func copyTextOfAnOpenBurstIsItsTextSoFar() {
    let row = ChatRow(id: UUID(), kind: .reasoning(text: "still weighing"))
    #expect(row.copyText == "still weighing")
  }

  @Test func reasoningDiscriminatorIsStable() {
    #expect(ChatRow.Kind.reasoning(text: "a").discriminator == "reasoning")
    #expect(ChatRow.Kind.reasoning(text: "b").discriminator == "reasoning")
    #expect(ChatRow.Kind.reasoning(text: "a").role == nil)
  }
}
