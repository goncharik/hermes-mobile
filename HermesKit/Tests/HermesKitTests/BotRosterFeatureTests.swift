import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct BotRosterFeatureTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  private func botProfile(_ name: String, title: String? = nil) -> Profile {
    Profile(name: name, botMeta: BotMeta(title: title))
  }

  @Test func taskPopulatesBotsFilteredFromAllProfiles() async {
    let store = TestStore(initialState: BotRosterFeature.State(connection: connection)) {
      BotRosterFeature()
    } withDependencies: {
      $0.hermesProfiles.list = { @Sendable _ in
        [
          Profile(name: "default", isDefault: true), // plain profile — not a bot
          self.botProfile("researcher", title: "Research Buddy"),
          self.botProfile("writer", title: "Writer"),
        ]
      }
    }

    await store.send(.task) { $0.isLoading = true }
    await store.receive(\.profilesResponse.success) {
      $0.isLoading = false
      $0.profilesSupported = true
      $0.allProfiles = [
        Profile(name: "default", isDefault: true),
        self.botProfile("researcher", title: "Research Buddy"),
        self.botProfile("writer", title: "Writer"),
      ]
    }

    #expect(store.state.bots.map(\.name) == ["researcher", "writer"])
  }

  @Test func notFoundFlipsProfilesSupportedOffSilently() async {
    let store = TestStore(initialState: BotRosterFeature.State(connection: connection)) {
      BotRosterFeature()
    } withDependencies: {
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.notFound }
    }

    await store.send(.task) { $0.isLoading = true }
    await store.receive(\.profilesResponse.failure) {
      $0.isLoading = false
      $0.profilesSupported = false
      $0.loadError = nil
    }
  }

  @Test func otherFailureSurfacesErrorBanner() async {
    let store = TestStore(initialState: BotRosterFeature.State(connection: connection)) {
      BotRosterFeature()
    } withDependencies: {
      $0.hermesProfiles.list = { @Sendable _ in throw RESTError.unreachable }
    }

    await store.send(.task) { $0.isLoading = true }
    await store.receive(\.profilesResponse.failure) {
      $0.isLoading = false
      $0.loadError = RESTError.unreachable.message
    }
  }

  @Test func tappingBotWithExistingChatOpensItDirectly() async {
    let store = TestStore(initialState: BotRosterFeature.State(connection: connection)) {
      BotRosterFeature()
    } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        #expect(method == "session.list")
        #expect(params["title"]?.stringValue == "Bot Chat")
        #expect(params["profile"]?.stringValue == "researcher")
        return .object([
          "sessions": .array([
            .object([
              "id": .string("20260101_000000_abcdef"),
              "title": .string("Bot Chat"),
              "preview": .string("Hey there"),
            ])
          ])
        ])
      }
    }

    await store.send(.botTapped(name: "researcher")) {
      $0.resolvingBotName = "researcher"
    }
    await store.receive(\.existingBotChatResolved.success) {
      $0.resolvingBotName = nil
    }
    await store.receive(\.delegate.openBotChat) { _ in }
  }

  @Test func tappingBotWithNoExistingChatCreatesOne() async {
    let store = TestStore(initialState: BotRosterFeature.State(connection: connection)) {
      BotRosterFeature()
    } withDependencies: {
      $0.hermesGateway.send = { @Sendable method, params in
        switch method {
        case "session.list":
          return .object(["sessions": .array([])])
        case "session.create":
          #expect(params["profile"]?.stringValue == "researcher")
          #expect(params["title"]?.stringValue == "Bot Chat")
          return .object([
            "session_id": .string("live-abc"),
            "stored_session_id": .string("20260101_000000_abcdef"),
          ])
        default:
          Issue.record("unexpected method \(method)")
          return .null
        }
      }
    }

    await store.send(.botTapped(name: "researcher")) {
      $0.resolvingBotName = "researcher"
    }
    await store.receive(\.existingBotChatResolved.success)
    await store.receive(\.botChatCreated.success) {
      $0.resolvingBotName = nil
    }
    await store.receive(\.delegate.openBotChat) { _ in }
  }

  @Test func doubleTapWhileResolvingIsIgnored() async {
    var state = BotRosterFeature.State(connection: connection)
    state.resolvingBotName = "researcher"
    let store = TestStore(initialState: state) {
      BotRosterFeature()
    }

    // No dependency stubs registered — if the guard didn't hold, this would trap on
    // an unimplemented `hermesGateway.send`.
    await store.send(.botTapped(name: "researcher"))
  }

  @Test func lookupFailureSurfacesLoadFailedDelegate() async {
    let store = TestStore(initialState: BotRosterFeature.State(connection: connection)) {
      BotRosterFeature()
    } withDependencies: {
      $0.hermesGateway.send = { @Sendable _, _ in throw GatewayError.server("boom") }
    }

    await store.send(.botTapped(name: "researcher")) {
      $0.resolvingBotName = "researcher"
    }
    await store.receive(\.existingBotChatResolved.failure) {
      $0.resolvingBotName = nil
    }
    await store.receive(\.delegate.loadFailed)
  }
}
