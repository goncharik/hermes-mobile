import Foundation
import HermesWidgetKit
import Testing

/// The Live Activity's wording (#138): the status label (with ActivityKit's staleness), the
/// count, the T3-style header with its needs-input suffix, and the tap target.
struct AgentActivityPresentationTests {
  private func content(
    _ count: Int,
    title: String? = "Fix the build",
    id: String? = "s1",
    profile: String? = "work",
    status: AgentActivityContent.Status = .working
  ) -> AgentActivityContent {
    AgentActivityContent(
      activeCount: count,
      headlineTitle: title,
      headlineSessionID: id,
      headlineProfile: profile,
      status: status
    )
  }

  @Test func statusReadsOutdatedOnceStaleExceptDone() {
    #expect(content(1, status: .working).displayStatus(isStale: false) == .working)
    #expect(content(1, status: .needsInput).displayStatus(isStale: false) == .needsInput)
    #expect(content(0, status: .done).displayStatus(isStale: false) == .done)
    #expect(content(1, status: .working).displayStatus(isStale: true) == .outdated)
    #expect(content(1, status: .needsInput).displayStatus(isStale: true) == .outdated)
    #expect(content(0, status: .done).displayStatus(isStale: true) == .done)
  }

  @Test func statusLabels() {
    let all: [AgentActivityContent.DisplayStatus] = [.working, .needsInput, .done, .outdated]
    #expect(all.map(\.label) == ["Working", "Needs input", "Done", "Outdated"])
  }

  @Test func countLabelPluralizes() {
    #expect(content(0, status: .done).countLabel == "No active agents")
    #expect(content(1).countLabel == "1 active agent")
    #expect(content(3).countLabel == "3 active agents")
  }

  /// T3 Code's header: the count while active, the outcome once done, "out of date" past the
  /// stale date — the final "Done" never goes stale.
  @Test func headerTitleFollowsTheDisplayStatus() {
    #expect(content(2).headerTitle(isStale: false) == "2 active agents")
    #expect(content(1, status: .needsInput).headerTitle(isStale: false) == "1 active agent")
    #expect(content(0, status: .done).headerTitle(isStale: false) == "Agent work completed")
    #expect(content(0, status: .done).headerTitle(isStale: true) == "Agent work completed")
    #expect(content(2).headerTitle(isStale: true) == "Agent status out of date")
    #expect(
      content(1, status: .needsInput).headerTitle(isStale: true) == "Agent status out of date"
    )
  }

  /// The tinted suffix shows only while the headline needs input and the app still vouches.
  @Test func headerAttentionOnlyWhileNeedsInputIsFresh() {
    #expect(content(1, status: .needsInput).headerAttention(isStale: false) == "Needs input")
    #expect(content(1, status: .needsInput).headerAttention(isStale: true) == nil)
    #expect(content(1).headerAttention(isStale: false) == nil)
    #expect(content(0, status: .done).headerAttention(isStale: false) == nil)
  }

  /// A tap opens the headline session in its own profile; no headline → the app as is.
  @Test func tapOpensTheHeadlineSession() {
    #expect(content(1).tapIntent == .openSession(id: "s1", profile: "work"))
    #expect(content(1, profile: nil).tapIntent == .openSession(id: "s1", profile: nil))
    #expect(content(1, id: nil).tapIntent == nil)
    #expect(
      content(1).tapIntent.map(WidgetDeepLink.url(for:))?.absoluteString
        == "hermesmobile://session/s1?profile=work"
    )
  }
}
