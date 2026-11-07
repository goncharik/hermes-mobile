import Foundation
import HermesWidgetKit
import Testing

/// The Live Activity's wording (#138): the status label (with ActivityKit's staleness), the
/// count header, the headline / secondary text with and without titles, and the tap target.
struct AgentActivityPresentationTests {
  private func content(
    _ count: Int,
    title: String? = "Fix the build",
    workspace: String? = "hermes",
    id: String? = "s1",
    profile: String? = "work",
    status: AgentActivityContent.Status = .working
  ) -> AgentActivityContent {
    AgentActivityContent(
      activeCount: count,
      headlineTitle: title,
      headlineWorkspace: workspace,
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

  /// With a title: title, then the workspace. Titles off: the workspace takes the title's
  /// place and is not repeated. Neither: only the status shows.
  @Test func headlineFallsBackToTheWorkspaceWithoutATitle() {
    let titled = content(1)
    #expect(titled.headlineText == "Fix the build")
    #expect(titled.secondaryText == "hermes")

    let untitled = content(1, title: nil)
    #expect(untitled.headlineText == "hermes")
    #expect(untitled.secondaryText == nil)

    let titleOnly = content(1, workspace: nil)
    #expect(titleOnly.headlineText == "Fix the build")
    #expect(titleOnly.secondaryText == nil)

    let bare = content(1, title: nil, workspace: nil)
    #expect(bare.headlineText == nil)
    #expect(bare.secondaryText == nil)
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
