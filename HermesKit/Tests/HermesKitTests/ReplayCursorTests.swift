import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// #98: the reducer-owned replay watermark. `.gatewayFrame` applies the ready rules
/// (epoch adoption/reset, session-authority flag) and advances the per-slot cursor from
/// stamped frames, then reduces exactly as `.gatewayEvent`.
@MainActor
struct ReplayCursorTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }

  /// A stamped frame whose event folds to nothing, so only the cursor moves.
  private func stamped(_ seq: Int?, session: String? = "live1") -> GatewayFrame {
    GatewayFrame(.unknown(type: "probe", raw: .object([:])), sessionID: session, seq: seq)
  }

  private func makeStore(_ initial: ChatFeature.State? = nil) -> TestStoreOf<ChatFeature> {
    TestStore(initialState: initial ?? ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
    }
  }

  /// A connected slot whose session was already requested, so a `.ready` only applies its
  /// status/replay rules and fires no session effect.
  private func requestedState() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.hasRequestedSession = true
    return state
  }

  // MARK: Cursor

  @Test func monotonicSeqAdvancesTheCursor() async {
    let store = makeStore()
    await store.send(.gatewayFrame(stamped(1))) {
      $0.replayCursor = .init(sessionID: "live1", seq: 1)
    }
    await store.send(.gatewayFrame(stamped(2))) {
      $0.replayCursor = .init(sessionID: "live1", seq: 2)
    }
    await store.send(.gatewayFrame(stamped(3))) {
      $0.replayCursor = .init(sessionID: "live1", seq: 3)
    }
  }

  @Test func nonIncreasingSeqIsIgnoredButTheEventStillReduces() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayCursor = .init(sessionID: "live1", seq: 3)
    let store = makeStore(initial)
    // seq 2 after 3: the cursor holds, the delta still folds into a streaming row.
    await store.send(.gatewayFrame(GatewayFrame(.messageDelta(text: "Hi"), sessionID: "live1", seq: 2))) {
      $0.transcript = [ChatRow(id: self.uuid(0), kind: .message(role: .assistant, text: "Hi", isComplete: false))]
      $0.streamingRowID = self.uuid(0)
    }
    // An equal seq is not an advance either.
    await store.send(.gatewayFrame(stamped(3)))
    #expect(store.state.replayCursor == .init(sessionID: "live1", seq: 3))
  }

  @Test func seqLessFramesLeaveTheCursor() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayCursor = .init(sessionID: "live1", seq: 7)
    let store = makeStore(initial)
    // An older agent's frame (session id, no seq), a session-less global, and a
    // client-synthesized event never move the watermark.
    await store.send(.gatewayFrame(stamped(nil)))
    await store.send(.gatewayFrame(stamped(nil, session: nil)))
    await store.send(.gatewayFrame(GatewayFrame(.unknown(type: "skin.changed", raw: .object([:])))))
    #expect(store.state.replayCursor == .init(sessionID: "live1", seq: 7))
  }

  @Test func seqLessFramesNeverStartACursor() async {
    let store = makeStore()
    await store.send(.gatewayFrame(stamped(nil)))
    await store.send(.gatewayFrame(stamped(9, session: nil)))
    #expect(store.state.replayCursor == nil)
  }

  @Test func frameForAnotherSessionReplacesTheCursor() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayCursor = .init(sessionID: "live1", seq: 40)
    let store = makeStore(initial)
    // A re-minted live id (idle session reaped in the gap) starts over, even at a lower seq.
    await store.send(.gatewayFrame(stamped(1, session: "live2"))) {
      $0.replayCursor = .init(sessionID: "live2", seq: 1)
    }
  }

  @Test func gatewayEventNeverTouchesTheCursor() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayCursor = .init(sessionID: "live1", seq: 5)
    let store = makeStore(initial)
    // The bare event action (tests, the replay fold's reduce) carries no envelope.
    await store.send(.gatewayEvent(.unknown(type: "probe", raw: .object([:]))))
    #expect(store.state.replayCursor == .init(sessionID: "live1", seq: 5))
  }

  // MARK: Epoch and authority on ready

  @Test func readyAdoptsTheEpoch() async {
    let store = makeStore(requestedState())
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1"))) {
      $0.status = .ready
      $0.replayEpoch = "e1"
    }
  }

  @Test func readyWithTheSameEpochKeepsTheCursor() async {
    var initial = requestedState()
    initial.replayEpoch = "e1"
    initial.replayCursor = .init(sessionID: "live1", seq: 12)
    let store = makeStore(initial)
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1"))) {
      $0.status = .ready
    }
  }

  @Test func readyWithANewEpochClearsTheCursorAndAdoptsIt() async {
    var initial = requestedState()
    initial.replayEpoch = "e1"
    initial.replayCursor = .init(sessionID: "live1", seq: 12)
    let store = makeStore(initial)
    // Gateway restart: the old numbering no longer exists.
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e2"))) {
      $0.status = .ready
      $0.replayEpoch = "e2"
      $0.replayCursor = nil
    }
  }

  @Test func readyWithoutAnEpochKeepsEpochAndCursor() async {
    var initial = requestedState()
    initial.replayEpoch = "e1"
    initial.replayCursor = .init(sessionID: "live1", seq: 12)
    let store = makeStore(initial)
    await store.send(.gatewayFrame(GatewayFrame(.ready))) {
      $0.status = .ready
    }
  }

  @Test func firstEpochOverAnExistingCursorIsAdoptedWithoutClearing() async {
    // No stored epoch yet (e.g. the first ready predates epochs): nothing to compare
    // against, so the cursor stands and the epoch is simply adopted.
    var initial = requestedState()
    initial.replayCursor = .init(sessionID: "live1", seq: 12)
    let store = makeStore(initial)
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1"))) {
      $0.status = .ready
      $0.replayEpoch = "e1"
    }
  }

  @Test func sessionAuthorityIsPerConnection() async {
    let store = makeStore(requestedState())
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1", sessionAuthority: true))) {
      $0.status = .ready
      $0.replayEpoch = "e1"
      $0.isSessionAuthority = true
    }
    // A later plain ready (a different host behind the same URL, or the next connect)
    // resets it.
    await store.send(.gatewayFrame(GatewayFrame(.ready, replayEpoch: "e1"))) {
      $0.isSessionAuthority = false
    }
  }

  @Test func nonReadyFrameReplayFieldsAreIgnored() async {
    var initial = ChatFeature.State(connection: conn)
    initial.replayEpoch = "e1"
    let store = makeStore(initial)
    // Only a ready frame's epoch/authority count (the decoder never sets them elsewhere,
    // but the reducer must not trust a hand-built frame either).
    await store.send(.gatewayFrame(GatewayFrame(
      .unknown(type: "probe", raw: .object([:])), replayEpoch: "e9", sessionAuthority: true
    )))
    #expect(store.state.replayEpoch == "e1")
    #expect(store.state.isSessionAuthority == false)
  }

  // MARK: Same fold as `.gatewayEvent`

  @Test func gatewayFrameReducesIdenticallyToGatewayEvent() async {
    func run(_ action: ChatFeature.Action) async -> (ChatFeature.State, ChatSnapshot?) {
      let snapshotClient = ChatSnapshotClient.inMemory()
      let clock = TestClock()
      var initial = ChatFeature.State(connection: conn)
      initial.liveSessionID = "live1"
      initial.storedSessionID = "stored1"
      initial.status = .ready
      let store = TestStore(initialState: initial) {
        ChatFeature()
      } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 123))
        $0.chatSnapshot = snapshotClient
      }
      store.exhaustivity = .off(showSkippedAssertions: false)
      await store.send(action)
      // The debounced write-back fires for both paths.
      await clock.advance(by: .seconds(1))
      await store.receive(\.persistSnapshotTick)
      let state = store.state
      await store.send(.teardown)
      return (state, snapshotClient.loadSnapshot("stored1"))
    }

    let (eventState, eventSnapshot) = await run(.gatewayEvent(.messageDelta(text: "Hello")))
    let (frameResult, frameSnapshot) = await run(
      .gatewayFrame(GatewayFrame(.messageDelta(text: "Hello"), sessionID: "live1", seq: 4))
    )
    // The only difference is the advanced watermark.
    #expect(frameResult.replayCursor == .init(sessionID: "live1", seq: 4))
    var frameState = frameResult
    frameState.replayCursor = nil
    #expect(frameState == eventState)
    #expect(eventState.transcript.map(\.kind) == [.message(role: .assistant, text: "Hello", isComplete: false)])
    #expect(eventSnapshot != nil)
    #expect(frameSnapshot?.rows == eventSnapshot?.rows)
  }
}
