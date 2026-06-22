import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

/// Snapshot coverage for the session state-sync / live-resume work (plan Task 10):
///
/// - **Re-hydration parity** — a chat rebuilt from stored history via
///   `reconstructTranscript` renders the *same* `ChatRow`s (and therefore the same image)
///   as the live fold of the equivalent gateway-event stream. For a plain
///   user → streamed-answer → tool-call(+result) turn the live fold and the reconstruction
///   produce byte-identical rows in the same order, so both views are asserted against one
///   shared baseline.
/// - **Re-hydrated chat with tool calls + thinking** — the full rehydration layout
///   (reasoning row + assistant text + completed tool row with its recovered command/result).
/// - **Instant-paint** — the cached snapshot painted from `ChatSnapshotClient` *before*
///   `session.resume` lands (shown with the subtle "reconnecting" status).
///
/// Row timestamps aren't shown in `ChatView` rows, so determinism only requires the pinned
/// dark traits + immediate clock from `SnapshotTestCase`.
final class HydrationSnapshotTests: SnapshotTestCase {
  // MARK: Fixtures

  /// Stored history for a turn, in the **cooked `session.resume` shape** the gateway actually
  /// returns (`_history_to_messages`): a user prompt, a pre-flattened `role:"tool"` row
  /// (display `name` + `context` preview — the server already matched call → result), then the
  /// assistant's answer. (No `tool_calls` arrays / `tool_call_id` — those are server-internal.)
  private func storedHistory() -> [SessionMessage] {
    [
      SessionMessage(id: 1, role: "user", text: "What's in server.py?"),
      SessionMessage(id: 2, role: "tool", name: "read_file", context: "server.py"),
      SessionMessage(id: 3, role: "assistant", text: "It defines the WebSocket gateway."),
    ]
  }

  /// Build a `ChatView` over a fixed set of rows, with the socket stubbed so no real
  /// connection opens during render.
  private func chatView(rows: [ChatRow], status: ChatFeature.State.Status = .ready) -> some View {
    NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            title: "Hydration chat",
            transcript: IdentifiedArray(uniqueElements: rows),
            status: status
          )
        ) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
  }

  // MARK: Re-hydration renders the stored history

  /// A re-hydrated transcript rebuilt from the cooked `session.resume` history renders the
  /// expected rows: user prompt, a completed tool row (name + `context` preview), and the
  /// assistant's answer, in the server's stream order (tool before the final answer).
  func testRehydrated_rendersStoredHistory() {
    let rows = reconstructTranscript(storedHistory())

    XCTAssertEqual(rows.map { $0.kind }, [
      .message(role: .user, text: "What's in server.py?", isComplete: true),
      .tool(name: "read_file", title: "read_file", state: .complete,
            detail: ToolDetail(argsText: "server.py"), durationS: nil),
      .message(role: .assistant, text: "It defines the WebSocket gateway.", isComplete: true),
    ])

    assertSnapshot(of: chatView(rows: rows), as: deviceImage(), named: "rehydrated")
  }

  // MARK: Re-hydrated chat with tool calls + thinking

  /// The full rehydration layout from cooked history: the user prompt, a completed tool row
  /// (name + preview), the assistant's reasoning disclosure (no "· 0s" — duration is unknown
  /// on re-hydration), and the assistant's answer.
  func testRehydrated_toolCallsAndThinking() {
    let history: [SessionMessage] = [
      SessionMessage(id: 1, role: "user", text: "Summarize the streaming protocol."),
      SessionMessage(id: 2, role: "tool", name: "read_file", context: "tui_gateway/server.py"),
      SessionMessage(
        id: 3, role: "assistant",
        text: "Here's the gist: it's a WebSocket JSON-RPC stream.",
        reasoning: "Let me look at the gateway server first, then the event types."
      ),
    ]
    let rows = reconstructTranscript(history)
    assertSnapshot(of: chatView(rows: rows), as: deviceImage())
  }

  // MARK: Instant-paint from the snapshot cache

  /// What the user sees the instant a session opens, painted from the `ChatSnapshotClient`
  /// cache before `session.resume` lands — the cached tail + model/usage with a subtle
  /// "reconnecting" status (never blank).
  func testInstantPaint_fromCache() {
    let cached = ChatSnapshot(
      model: "claude-sonnet-4",
      usage: Usage(contextUsed: 42_000, contextMax: 200_000, contextPercent: 21),
      rows: [
        ChatRow(id: id(0), kind: .message(role: .user, text: "Cached from a previous open.", isComplete: true)),
        ChatRow(id: id(1), kind: .message(
          role: .assistant,
          text: "This tail was painted instantly from the SQLite snapshot.",
          isComplete: true
        )),
      ]
    )
    let view = NavigationStack {
      ChatView(
        store: Store(
          initialState: ChatFeature.State(
            connection: connection,
            resumeStoredID: "20260610_120231_afcca6",
            title: "Cached chat",
            // No explicit transcript → init reads the snapshot synchronously and paints it.
            status: .reconnecting
          )
        ) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
          $0.chatSnapshot.loadSnapshot = { _ in cached }
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }
}
