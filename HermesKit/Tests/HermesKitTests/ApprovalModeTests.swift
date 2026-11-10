import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ApprovalModeTests {
  private func state(contract: Int? = 3) -> ChatFeature.State {
    var state = ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://localhost:9119")!, token: "t"))
    state.status = .ready
    state.desktopContract = contract
    return state
  }

  @Test(arguments: [nil, 0, 2] as [Int?])
  func unsupportedContractNeverReadsOrWrites(contract: Int?) async {
    var initial = state(contract: contract)
    initial.hasRequestedSession = true
    initial.approvalMode = .manual
    #expect(initial.displayedApprovalMode == nil)
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.gatewayEvent(.ready))
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "off"))))
    await store.send(.approvalModeSelected(.off))
    await store.finish()
  }

  @Test(arguments: [nil, "default", "work"] as [String?])
  func readyReadsScopedPolicy(profile: String?) async {
    var initial = state()
    initial.profileName = profile
    initial.hasRequestedSession = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, params in
        #expect(method == "config.get")
        #expect(params["key"] == .string("approvals.mode"))
        #expect(params["profile"] == profile.map(JSONValue.string))
        #expect(params["session_id"] == nil)
        return .object(["value": .string("manual")])
      }
    }
    await store.send(.gatewayEvent(.ready))
    await store.receive(\.approvalModeReadResponse) { $0.approvalMode = .manual }
    await store.finish()
  }

  @Test func lazyCreateDecodesContractAndReadsBeforeAgentBuild() async throws {
    let handle = try JSONDecoder().decode(SessionHandle.self, from: Data(
      #"{"session_id":"new","info":{"lazy":true,"desktop_contract":3}}"#.utf8
    ))
    #expect(handle.info?.desktopContract == 3)
    var initial = state(contract: nil)
    initial.commandsUnsupported = true
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, params in
        #expect(method == "config.get")
        #expect(params["profile"] == nil)
        return .object(["value": .string("manual")])
      }
    }
    await store.send(.sessionResult(.success(handle))) {
      $0.desktopContract = 3
      $0.liveSessionID = "new"
      $0.awaitsFirstPersist = true
      $0.hasHydrated = true
    }
    await store.receive(\.approvalModeReadResponse) { $0.approvalMode = .manual }
    await store.finish()
  }

  @Test func contractDiscoveryReadsWithoutApprovalField() async {
    let store = TestStore(initialState: state(contract: nil)) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, _ in
        #expect(method == "config.get")
        return .object(["value": .string("smart")])
      }
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(desktopContract: 3)))) {
      $0.desktopContract = 3
    }
    await store.receive(\.approvalModeReadResponse) { $0.approvalMode = .smart }
    await store.finish()
  }

  @Test(arguments: [nil, 2, 3, 7] as [Int?])
  func lazyHydrateUsesContractAndScopedRead(contract: Int?) async throws {
    let clock = TestClock()
    var initial = state(contract: contract)
    initial.commandsUnsupported = true
    initial.profileName = "work"
    initial.usage = Usage(contextUsed: 1, contextMax: 100, contextPercent: 1)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { method, params in
        #expect((contract ?? 0) >= 3)
        #expect(method == "config.get")
        #expect(params["profile"] == .string("work"))
        try await clock.sleep(for: .seconds(1))
        return .object(["value": .string("smart")])
      }
    }
    let contractField = contract.map { ",\"desktop_contract\":\($0)" } ?? ""
    let response = try JSONDecoder().decode(ActivateResponse.self, from: Data("{\"session_id\":\"live\",\"info\":{\"lazy\":true\(contractField)}}".utf8))
    await store.send(.activateResult(.success(response))) {
      $0.liveSessionID = "live"
      $0.hasHydrated = true
    }
    await store.receive(\.delegate.runningChanged)
    await store.receive(\.persistSnapshotTick)
    if (contract ?? 0) >= 3 {
      await clock.advance(by: .seconds(1))
      await store.receive(\.approvalModeReadResponse) { $0.approvalMode = .smart }
    }
    await store.finish()
  }

  @Test(arguments: [nil, "default", "work"] as [String?])
  func normalizedWriteWinsOverUnscopedBroadcastAndSecondPickIsIgnored(profile: String?) async {
    let clock = TestClock()
    var initial = state()
    initial.profileName = profile
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, params in
        #expect(method == "config.set")
        #expect(params["key"] == .string("approvals.mode"))
        #expect(params["value"] == .string("off"))
        #expect(params["profile"] == profile.map(JSONValue.string))
        #expect(params["session_id"] == nil)
        try await clock.sleep(for: .seconds(1))
        return .object(["key": .string("approvals.mode"), "value": .string("smart")])
      }
    }
    await store.send(.approvalModeSelected(.off)) {
      $0.approvalMode = .off
      $0.approvalModePending = true
      $0.approvalModeRollback = .manual
    }
    await store.send(.approvalModeSelected(.smart))
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "off"))))
    await clock.advance(by: .seconds(1))
    await store.receive(\.approvalModeResponse) {
      $0.approvalMode = .smart
      $0.approvalModePending = false
      $0.approvalModeRollback = nil
    }
    await store.finish()
  }

  @Test(arguments: [false, true])
  func failedWritePreservesRollbackAcrossLazyHydrate(broadcast: Bool) async {
    let clock = TestClock()
    var initial = state()
    initial.commandsUnsupported = true
    initial.approvalMode = .manual
    initial.profileName = "work"
    initial.usage = Usage(contextUsed: 1, contextMax: 100, contextPercent: 1)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesGateway.send = { method, params in
        #expect(params["profile"] == .string("work"))
        if method == "config.get" { return .object(["value": .string("manual")]) }
        #expect(method == "config.set")
        try await clock.sleep(for: .seconds(1))
        throw GatewayError.server("denied")
      }
    }
    await store.send(.approvalModeSelected(.off)) {
      $0.approvalMode = .off
      $0.approvalModePending = true
      $0.approvalModeRollback = .manual
    }
    await store.send(.activateResult(.success(ActivateResponse(sessionID: "live", info: SessionInfo(desktopContract: 3))))) {
      $0.liveSessionID = "live"
      $0.hasHydrated = true
    }
    await store.receive(\.delegate.runningChanged)
    await store.receive(\.persistSnapshotTick)
    if broadcast {
      await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "smart"))))
      await store.receive(\.persistSnapshotTick)
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.approvalModeResponse) {
      $0.approvalMode = .manual
      $0.approvalModePending = false
      $0.approvalModeRollback = nil
      $0.errorBanner = "Approval mode failed: denied"
    }
    await store.receive(\.approvalModeReadResponse)
    await store.finish()
  }

  @Test(arguments: ["default", "work"])
  func foreignProfileBroadcastNeedsScopedConfirmation(profile: String) async {
    let clock = TestClock()
    var initial = state()
    initial.profileName = profile
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, params in
        #expect(method == "config.get")
        #expect(params["profile"] == .string(profile))
        try await clock.sleep(for: .seconds(1))
        return .object(["value": .string("manual")])
      }
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "off"))))
    #expect(store.state.approvalMode == .manual)
    await clock.advance(by: .seconds(1))
    await store.receive(\.approvalModeReadResponse)
    await store.finish()
  }

  @Test func equalBroadcastReplacesOlderRead() async {
    let clock = TestClock()
    let reads = LockIsolated(0)
    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, _ in
        #expect(method == "config.get")
        let index = reads.withValue { $0 += 1; return $0 }
        try await clock.sleep(for: .seconds(index == 1 ? 10 : 1))
        return .object(["value": .string(index == 1 ? "off" : "manual")])
      }
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "off"))))
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "manual"))))
    await clock.advance(by: .seconds(1))
    #expect(reads.value == 2)
    await store.receive(\.approvalModeReadResponse)
    await clock.advance(by: .seconds(10))
    await store.finish()
    #expect(store.state.approvalMode == .manual)
  }

  @Test func ownProfileBroadcastUpdatesAfterConfirmation() async {
    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { _, _ in .object(["value": .string("off")]) }
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "off"))))
    await store.receive(\.approvalModeReadResponse) { $0.approvalMode = .off }
    await store.finish()
  }

  @Test(arguments: ["{}", #"{"approval_mode":null}"#, #"{"approval_mode":"future"}"#])
  func absentOrUnknownInfoPreservesKnownMode(json: String) async throws {
    var initial = state()
    initial.approvalMode = .smart
    let store = TestStore(initialState: initial) { ChatFeature() }
    let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
    await store.send(.gatewayEvent(.sessionInfo(info)))
    await store.finish()
  }

  @Test(arguments: ["teardown", "disconnect", "socketOnly"])
  func lifecycleCancelsPendingWrite(lifecycle: String) async {
    let clock = TestClock()
    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = clock
      $0.hermesGateway.send = { _, _ in
        try await clock.sleep(for: .seconds(10))
        return .object(["value": .string("off")])
      }
    }
    await store.send(.approvalModeSelected(.off)) {
      $0.approvalMode = .off
      $0.approvalModePending = true
      $0.approvalModeRollback = .manual
    }
    if lifecycle == "disconnect" {
      await store.send(.gatewayClosed) {
        $0.approvalMode = .manual
        $0.approvalModePending = false
        $0.approvalModeRollback = nil
        $0.status = .reconnecting
        $0.reconnectAttempt = 1
      }
      // Cancel reconnect as the parent does when retiring the slot.
      await store.send(.teardown)
    } else if lifecycle == "socketOnly" {
      await store.send(.teardownSocketOnly) {
        $0.approvalMode = .manual
        $0.approvalModePending = false
        $0.approvalModeRollback = nil
        $0.status = .reconnecting
      }
    } else {
      await store.send(.teardown) {
        $0.approvalMode = .manual
        $0.approvalModePending = false
        $0.approvalModeRollback = nil
      }
    }
    await clock.advance(by: .seconds(10))
    await store.finish()
  }

  @Test func selectionCancelsOlderRead() async {
    let clock = TestClock()
    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, _ in
        if method == "config.get" {
          try await clock.sleep(for: .seconds(10))
          return .object(["value": .string("manual")])
        }
        return .object(["value": .string("off")])
      }
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "smart"))))
    await store.send(.approvalModeSelected(.off)) {
      $0.approvalMode = .off
      $0.approvalModePending = true
      $0.approvalModeRollback = .manual
    }
    await store.receive(\.approvalModeResponse) {
      $0.approvalModePending = false
      $0.approvalModeRollback = nil
    }
    await clock.advance(by: .seconds(10))
    await store.finish()
  }

  @Test func teardownCancelsPendingRead() async {
    let clock = TestClock()
    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { _, _ in
        try await clock.sleep(for: .seconds(10))
        return .object(["value": .string("off")])
      }
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "off"))))
    await store.send(.teardown)
    await clock.advance(by: .seconds(10))
    await store.finish()
  }

  @Test func readResponseFromAnotherProfileIsIgnored() async {
    var initial = state()
    initial.profileName = "work"
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() }
    await store.send(.approvalModeReadResponse(profile: "default", .success(.off)))
    await store.finish()
  }

  @Test func scopedReadFailureKeepsKnownMode() async {
    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { _, _ in throw GatewayError.server("denied") }
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "off"))))
    await store.receive(\.approvalModeReadResponse) {
      $0.errorBanner = "Approval mode unavailable: denied"
    }
    await store.finish()
  }

  @Test(arguments: ["manual", "smart", "off", "future", ""])
  func wireEventAndResumeDecodePolicy(raw: String) throws {
    let frame = try InboundFrame(data: Data("""
      {"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"live","payload":{"approval_mode":"\(raw)"}}}
      """.utf8))
    guard case let .event(eventFrame) = frame,
      case let .sessionInfo(info) = eventFrame.event else {
      Issue.record("Expected session.info"); return
    }
    #expect(eventFrame.sessionID == "live")
    #expect(info.approvalMode == raw)
    let resume = try JSONDecoder().decode(ActivateResponse.self, from: Data("""
      {"session_id":"live","info":{"approval_mode":"\(raw)"}}
      """.utf8))
    #expect(resume.info?.approvalMode == raw)
  }
}
