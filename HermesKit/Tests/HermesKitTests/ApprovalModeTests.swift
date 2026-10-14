import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

@MainActor
struct ApprovalModeTests {
  private func state() -> ChatFeature.State {
    ChatFeature.State(connection: ServerConnection(baseURL: URL(string: "http://localhost:9119")!, token: "t"))
  }

  private func info(_ value: String) throws -> SessionInfo {
    try JSONDecoder().decode(SessionInfo.self, from: Data(value.utf8))
  }

  @Test func selectionIsOptimisticAndUnsupportedIsInert() async {
    let unsupported = TestStore(initialState: state()) { ChatFeature() }
    await unsupported.send(.approvalModeSelected(.off))
    await unsupported.finish()

    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, params in
        #expect(method == "config.set")
        #expect(params["key"] == .string("approvals.mode"))
        #expect(params["value"] == .string("off"))
        return .object([:]) // acknowledgment need not echo the policy
      }
    }
    await store.send(.approvalModeSelected(.off)) {
      $0.approvalMode = .off
      $0.approvalModePending = true
      $0.approvalModeRollback = .manual
    }
    await store.receive(\.approvalModeResponse) {
      $0.approvalModePending = false
      $0.approvalModeRollback = nil
    }
    await store.finish()
  }

  @Test(arguments: [false, true])
  func failedWriteRestoresLatestAuthority(broadcast: Bool) async {
    let clock = TestClock()
    var initial = state()
    initial.approvalMode = .manual
    initial.profileName = "work"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { method, params in
        #expect(method == "config.set")
        #expect(params["profile"] == .string("work"))
        try await clock.sleep(for: .seconds(1))
        throw GatewayError.server("denied")
      }
    }
    await store.send(.approvalModeSelected(.off)) {
      $0.approvalMode = .off
      $0.approvalModePending = true
      $0.approvalModeRollback = .manual
    }
    // Single-flight: a second pick cannot create a stale completion race.
    await store.send(.approvalModeSelected(.smart))
    if broadcast {
      await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "smart")))) {
        $0.approvalMode = .smart
        $0.approvalModeRollback = .smart
      }
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.approvalModeResponse) {
      $0.approvalMode = broadcast ? .smart : .manual
      $0.approvalModePending = false
      $0.approvalModeRollback = nil
      $0.errorBanner = "Approval mode failed: denied"
    }
    await store.finish()
  }

  @Test func lateAcknowledgmentDoesNotOverwriteBroadcast() async {
    let clock = TestClock()
    var initial = state()
    initial.approvalMode = .manual
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.hermesGateway.send = { _, params in
        #expect(params["profile"] == nil)
        try await clock.sleep(for: .seconds(1))
        return .object(["value": .string("off")])
      }
    }
    await store.send(.approvalModeSelected(.off)) {
      $0.approvalMode = .off
      $0.approvalModePending = true
      $0.approvalModeRollback = .manual
    }
    await store.send(.gatewayEvent(.sessionInfo(SessionInfo(approvalMode: "smart")))) {
      $0.approvalMode = .smart
      $0.approvalModeRollback = .smart
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.approvalModeResponse) {
      $0.approvalModePending = false
      $0.approvalModeRollback = nil
    }
    await store.finish()
  }

  @Test(arguments: ["manual", "smart", "off", "future", ""])
  func wireEventAndResumeDecodePolicy(raw: String) throws {
    let frame = try InboundFrame(data: Data("""
      {"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"live","payload":{"approval_mode":"\(raw)"}}}
      """.utf8))
    guard case let .event(sessionID, .sessionInfo(info)) = frame else {
      Issue.record("Expected session.info"); return
    }
    #expect(sessionID == "live")
    #expect(info.approvalMode == raw)
    let resume = try JSONDecoder().decode(ActivateResponse.self, from: Data("""
      {"session_id":"live","info":{"approval_mode":"\(raw)"}}
      """.utf8))
    #expect(resume.info?.approvalMode == raw)
  }

  @Test(arguments: ["{}", #"{"approval_mode":null}"#, #"{"approval_mode":"future"}"#])
  func unsupportedInfoIsSilent(json: String) async throws {
    let store = TestStore(initialState: state()) { ChatFeature() }
    await store.send(.gatewayEvent(.sessionInfo(try info(json))))
    await store.send(.approvalModeSelected(.off))
    await store.finish()
  }

  @Test(arguments: [true, false])
  func hydrateUsesInfoWithoutConfigRead(supported: Bool) async {
    var initial = state()
    initial.commandsUnsupported = true
    let usage = Usage(contextUsed: 1, contextMax: 100, contextPercent: 1)
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    let response = ActivateResponse(sessionID: "live", info: SessionInfo(
      usage: usage, approvalMode: supported ? "smart" : nil
    ))
    await store.send(.activateResult(.success(response))) {
      $0.liveSessionID = "live"
      $0.status = .ready
      $0.hasHydrated = true
      $0.usage = usage
      $0.approvalMode = supported ? .smart : nil
    }
    await store.receive(\.delegate.runningChanged)
    await store.receive(\.persistSnapshotTick)
    await store.finish()
  }

  @Test func liveInfoDiscoversCapabilityWithoutRPC() async throws {
    let store = TestStore(initialState: state()) { ChatFeature() }
    await store.send(.gatewayEvent(.sessionInfo(try info(#"{"approval_mode":"smart"}"#)))) {
      $0.approvalMode = .smart
    }
    await store.send(.gatewayEvent(.sessionInfo(try info(#"{}"#))))
    await store.send(.gatewayEvent(.sessionInfo(try info(#"{"approval_mode":"off"}"#)))) {
      $0.approvalMode = .off
    }
    await store.finish()
  }
}
