import ComposableArchitecture
import HermesKit
import SnapshotTesting
import SwiftUI
import XCTest

@testable import HermesMobile

final class ChatSnapshotTests: SnapshotTestCase {
  // MARK: ChatView

  /// Build a `ChatView` over `rows`. The transcript is rendered by the sole
  /// `UICollectionView`-backed engine. The state carries a stored session id so the
  /// action bar's branch affordance renders ENABLED (`canBranch` requires a persisted
  /// id), matching a real resumed chat.
  /// `configure` mutates the built state for the handful of flags that aren't `State.init`
  /// parameters (e.g. `copiedIDToastToken`, defaulted in the init body).
  private func chatView(
    rows: [ChatRow],
    title: String,
    status: ChatFeature.State.Status,
    configure: (inout ChatFeature.State) -> Void = { _ in }
  ) -> some View {
    var state = ChatFeature.State(
      connection: connection,
      resumeStoredID: "snapshot-session",
      title: title,
      transcript: IdentifiedArray(uniqueElements: rows),
      status: status
    )
    configure(&state)
    return NavigationStack {
      ChatView(
        store: Store(initialState: state) {
          ChatFeature()
        } withDependencies: {
          // Don't open a real socket during render.
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
  }

  private func assertChatView(
    rows: [ChatRow],
    title: String,
    status: ChatFeature.State.Status,
    configure: (inout ChatFeature.State) -> Void = { _ in },
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    assertSnapshot(
      of: chatView(rows: rows, title: title, status: status, configure: configure),
      as: deviceImage(),
      file: file,
      testName: testName,
      line: line
    )
  }

  func testChatView() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "Summarize the streaming protocol.", isComplete: true)),
      ChatRow(id: id(1), kind: .tool(name: "read_file", title: "Read tui_gateway/server.py", state: .complete,
                                     detail: ToolDetail(resultText: "tui_gateway/server.py"), durationS: 0.8)),
      ChatRow(id: id(2), kind: .message(
        role: .assistant,
        text: "Here's the gist:\n\n- **WebSocket** JSON-RPC at `/api/ws`\n- Responses stream as `message.delta` events\n- Tools surface via `tool.start` / `tool.complete`",
        isComplete: true
      )),
    ]
    assertChatView(rows: rows, title: "Protocol chat", status: .ready)
  }

  /// Fenced code block + list rendering (Task 11 markdown polish).
  func testChatView_codeBlockAndReconnecting() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "Show me the connect effect.", isComplete: true)),
      ChatRow(id: id(1), kind: .message(
        role: .assistant,
        text: "Here's the gist:\n\n```swift\nfor await event in gateway.connect(url, token) {\n  await send(.gatewayEvent(event))\n}\n```\n\nThat funnels every event through one action.",
        isComplete: true
      )),
    ]
    // .reconnecting exercises the connection banner too.
    assertChatView(rows: rows, title: "Protocol chat", status: .reconnecting)
  }

  func testChatView_sentImageAttachment() {
    let rows: [ChatRow] = [
      ChatRow(
        id: id(0),
        kind: .message(role: .user, text: "What's in this picture?", isComplete: true),
        attachmentImages: [solidPNG(.systemTeal, 200)]
      ),
      ChatRow(id: id(1), kind: .message(role: .assistant, text: "A solid teal square.", isComplete: true)),
    ]
    assertChatView(rows: rows, title: "Vision chat", status: .ready)
  }

  // MARK: Slash commands (#36)

  private static func suggestion(
    _ name: String, _ description: String, isSkill: Bool = false
  ) -> SlashSuggestion {
    SlashSuggestion(
      name: name, description: description, isSkill: isSkill,
      insertionText: name + " "
    )
  }

  /// Built-ins plus a skill route (sparkles icon) — the panel's standard shape.
  func testSlashSuggestionPanel() {
    let view = SlashSuggestionPanel(
      suggestions: [
        Self.suggestion("/compress", "Summarize and compact the conversation"),
        Self.suggestion("/status", "Show session status"),
        Self.suggestion("/undo", "Revert to the previous checkpoint"),
        Self.suggestion("/plan", "Draft an implementation plan", isSkill: true),
      ],
      onTap: { _ in }
    )
    .padding(.vertical, 8)
    .frame(width: device.size?.width ?? 390)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// More rows than the visible cap: the panel stops at ~5.5 rows (half-row hints the
  /// internal scroll) instead of growing unbounded.
  func testSlashSuggestionPanel_overflowCapsHeight() {
    let view = SlashSuggestionPanel(
      suggestions: [
        Self.suggestion("/compress", "Summarize and compact the conversation"),
        Self.suggestion("/status", "Show session status"),
        Self.suggestion("/undo", "Revert to the previous checkpoint"),
        Self.suggestion("/retry", "Retry the last turn"),
        Self.suggestion("/steer", "Steer the running turn"),
        Self.suggestion("/queue", "Queue a follow-up prompt"),
        Self.suggestion("/plan", "Draft an implementation plan", isSkill: true),
      ],
      onTap: { _ in }
    )
    .padding(.vertical, 8)
    .frame(width: device.size?.width ?? 390)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Full chat screen with the catalog loaded and "/" typed: the panel slots between the
  /// transcript and the composer.
  func testChatView_slashSuggestionPanel() {
    var state = ChatFeature.State(
      connection: connection,
      title: "Slash commands",
      transcript: IdentifiedArray(uniqueElements: [
        ChatRow(id: id(0), kind: .message(role: .user, text: "Hello!", isComplete: true)),
        ChatRow(id: id(1), kind: .message(role: .assistant, text: "Hi — ready when you are.", isComplete: true)),
      ]),
      composerText: "/",
      status: .ready
    )
    state.commandCatalog = CommandCatalog(commands: [
      SlashCommand(name: "/compress", description: "Summarize and compact the conversation", category: "Session"),
      SlashCommand(name: "/status", description: "Show session status", category: "Session"),
      SlashCommand(name: "/undo", description: "Revert to the previous checkpoint", category: "Session"),
      SlashCommand(name: "/plan", description: "Draft an implementation plan", isSkill: true),
    ])
    let view = NavigationStack {
      ChatView(
        store: Store(initialState: state) {
          ChatFeature()
        } withDependencies: {
          $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
          $0.continuousClock = ImmediateClock()
        }
      )
    }
    assertSnapshot(of: view, as: deviceImage())
  }

  /// Ephemeral slash-command output (#36): the typed command as a normal user bubble,
  /// the output bubble-less, dimmed, and monospaced.
  func testChatView_commandOutputRow() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "/status", isComplete: true)),
      ChatRow(id: id(1), kind: .commandOutput(
        text: "model: claude-fable-5\nreasoning: medium\ncontext: 62k/200k tokens (31%)"
      )),
    ]
    assertChatView(rows: rows, title: "Slash commands", status: .ready)
  }

  // MARK: Message action bar (#34)

  /// Completed assistant message: the copy + branch action row renders under the text
  /// (also exercised integrated in `testChatView`).
  func testChatView_messageActionBar() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "What renders the transcript?", isComplete: true)),
      ChatRow(id: id(1), kind: .message(
        role: .assistant,
        text: "The `UICollectionView`-backed `CollectionTranscriptView` — the only engine.",
        isComplete: true
      )),
    ]
    assertChatView(rows: rows, title: "Action bar", status: .ready)
  }

  /// A streaming (incomplete) assistant row must NOT show the action bar. Rendered as a
  /// single `rowView` cell (component snapshot): a full-device capture of a streaming row
  /// is flaky — the spinner keeps animations alive while the collection view re-pins to
  /// bottom, occasionally compositing the cell twice mid-flight.
  func testStreamingAssistantRow_noActionBar() {
    let row = ChatRow(id: id(1), kind: .message(
      role: .assistant,
      text: "The `UICollectionView`-backed",
      isComplete: false
    ))
    let chat = ChatView(
      store: Store(
        initialState: ChatFeature.State(
          connection: connection,
          title: "Action bar",
          transcript: IdentifiedArray(uniqueElements: [row]),
          status: .ready
        )
      ) {
        ChatFeature()
      } withDependencies: {
        $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
        $0.continuousClock = ImmediateClock()
      }
    )
    let view = chat.rowView(row)
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Store-driven `rowView` wiring: the copy checkmark must light from the REDUCER's
  /// row-scoped token (`recentlyCopiedToken == ChatFeature.rowCopyToken(row.id)`), not
  /// just from hardcoded component props.
  func testAssistantRow_copiedViaStoreToken() {
    let row = ChatRow(id: id(1), kind: .message(
      role: .assistant, text: "Copy me.", isComplete: true
    ))
    var state = ChatFeature.State(
      connection: connection,
      title: "Action bar",
      transcript: IdentifiedArray(uniqueElements: [row]),
      status: .ready
    )
    state.recentlyCopiedToken = ChatFeature.rowCopyToken(row.id)
    let chat = ChatView(
      store: Store(initialState: state) {
        ChatFeature()
      } withDependencies: {
        $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
        $0.continuousClock = ImmediateClock()
      }
    )
    let view = chat.rowView(row)
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Store-driven `rowView` wiring: a streaming turn (`isSending`) disables + dims the
  /// branch button through the real `canBranch` gate (`!store.canBranch`).
  func testAssistantRow_branchDisabledWhileSendingViaStore() {
    let row = ChatRow(id: id(1), kind: .message(
      role: .assistant, text: "Earlier reply.", isComplete: true
    ))
    var state = ChatFeature.State(
      connection: connection,
      title: "Action bar",
      transcript: IdentifiedArray(uniqueElements: [row]),
      status: .ready
    )
    state.isSending = true
    let chat = ChatView(
      store: Store(initialState: state) {
        ChatFeature()
      } withDependencies: {
        $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
        $0.continuousClock = ImmediateClock()
      }
    )
    let view = chat.rowView(row)
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A COMPLETED assistant row whose text is whitespace-only must not show the bar
  /// (there is nothing to copy or branch).
  func testWhitespaceOnlyCompletedAssistantRow_noActionBar() {
    let row = ChatRow(id: id(1), kind: .message(
      role: .assistant, text: "  \n ", isComplete: true
    ))
    let chat = ChatView(
      store: Store(
        initialState: ChatFeature.State(
          connection: connection,
          title: "Action bar",
          transcript: IdentifiedArray(uniqueElements: [row]),
          status: .ready
        )
      ) {
        ChatFeature()
      } withDependencies: {
        $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
        $0.continuousClock = ImmediateClock()
      }
    )
    let view = chat.rowView(row)
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Read aloud (#74)

  /// A completed assistant reply rendered through the store-driven `rowView`, with
  /// `ttsPlayback` set so the bar's Read aloud button derives its state from the REAL
  /// `readAloudState(for:)`.
  private func assertReadAloudCell(
    playback: (ChatRow.ID) -> ChatFeature.State.TTSPlayback,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    let row = ChatRow(id: id(1), kind: .message(
      role: .assistant, text: "Here's the summary you asked for.", isComplete: true
    ))
    var state = ChatFeature.State(
      connection: connection,
      resumeStoredID: "snapshot-session",
      title: "Read aloud",
      transcript: IdentifiedArray(uniqueElements: [row]),
      status: .ready
    )
    state.ttsPlayback = playback(row.id)
    let chat = ChatView(
      store: Store(initialState: state) {
        ChatFeature()
      } withDependencies: {
        $0.hermesGateway.connect = { _, _ in AsyncStream { _ in } }
        $0.continuousClock = ImmediateClock()
      }
    )
    let view = chat.rowView(row)
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage(), file: file, testName: testName, line: line)
  }

  /// No clip: the `waveform` Read aloud button sits after Branch.
  func testAssistantRow_readAloudIdle() {
    assertReadAloudCell { _ in .idle }
  }

  /// This reply is synthesizing: a spinner in the same glyph slot (bar height unchanged).
  func testAssistantRow_readAloudPreparing() {
    assertReadAloudCell { .preparing($0) }
  }

  /// This reply is playing: the stop glyph (`speaker.slash`).
  func testAssistantRow_readAloudSpeaking() {
    assertReadAloudCell { .speaking($0) }
  }

  /// ANOTHER reply is playing: this row's button is dimmed + disabled (one clip at a time).
  func testAssistantRow_readAloudDisabled() {
    assertReadAloudCell { _ in .speaking(self.id(2)) }
  }

  /// Copied state: the copy icon swaps to the green checkmark while the row's
  /// feedback token is live.
  func testMessageActionBar_copied() {
    let view = MessageActionBar(
      isCopied: true,
      isBranchDisabled: false,
      onCopy: {},
      onBranch: {}
    )
    .padding()
    .frame(width: 320)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Branch disabled while a turn is running (mirrors the reducer guard).
  func testMessageActionBar_branchDisabled() {
    let view = MessageActionBar(
      isCopied: false,
      isBranchDisabled: true,
      onCopy: {},
      onBranch: {}
    )
    .padding()
    .frame(width: 320)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Review-summary status row (#47): `.status(kind: "review")` renders at `.footnote`
  /// with text selection so a multi-sentence self-improvement summary stays readable;
  /// the plain "approval" status row alongside it keeps the terse `.caption` styling.
  func testChatView_reviewSummaryStatusRow() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "Tidy up the retry logic.", isComplete: true)),
      ChatRow(id: id(1), kind: .message(role: .assistant, text: "Done — retries now back off exponentially.", isComplete: true)),
      ChatRow(id: id(2), kind: .status(kind: "approval", text: "Approved")),
      ChatRow(id: id(3), kind: .status(
        kind: "review",
        text: "💾 Self-improvement review: The retry loop now honors the backoff ceiling. Consider persisting the failure counter across restarts, and add a test for clock skew during long waits."
      )),
    ]
    assertChatView(rows: rows, title: "Review chat", status: .ready)
  }

  /// The copied-ID toast (chat toolbar ⋯ → Copy ID). The overlay is attached to the
  /// transcript rather than the outer `VStack`, so this pins that it floats just above the
  /// composer instead of covering it.
  func testChatView_copiedIDToast() {
    let rows: [ChatRow] = [
      ChatRow(id: id(0), kind: .message(role: .user, text: "What's this session's id?", isComplete: true)),
      ChatRow(id: id(1), kind: .message(
        role: .assistant,
        text: "Grab it from the ⋯ menu — I don't have it from in here.",
        isComplete: true
      )),
    ]
    // `copiedIDToastToken` is defaulted in `State.init`'s body, not a parameter — set it
    // on the built state.
    assertChatView(rows: rows, title: "Protocol chat", status: .ready) {
      $0.copiedIDToastToken = 1
    }
  }

  // MARK: Code-block copy affordance (#9)

  private static let copySample = "Run this:\n\n```bash\nmake snapshot\n```"

  func testCodeBlock_copyButtonIdle() {
    let view = MarkdownText(text: Self.copySample, tokenPrefix: "row", onCopyCode: { _, _ in })
      .padding()
      .frame(width: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  func testCodeBlock_copiedCheckmark() {
    // `copiedToken` matches the code block's token ("<prefix>#<segment index>"); the
    // sample's code is the 2nd segment (after the prose line), so index 1.
    let view = MarkdownText(
      text: Self.copySample,
      copiedToken: "row#1",
      tokenPrefix: "row",
      onCopyCode: { _, _ in }
    )
    .padding()
    .frame(width: 320)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Approval card

  /// The height is pinned for the same reason the width is on a horizontally-scrollable view
  /// (CLAUDE.md's blank-sliver gotcha, vertical edition): the card's content region is
  /// **compressible**, and `componentImage()` renders at `.sizeThatFits`, i.e. UIKit's
  /// *compressed* fitting size — which for a compressible view is its FLOOR, not its natural
  /// height. Unpinned this recorded the card 39pt short, with the region already scrolling.
  /// The frame is generous enough that the card lays out naturally inside it.
  func testApprovalCard() {
    let view = ApprovalCardView(
      request: ApprovalRequest(
        command: "rm -rf build/ && git clean -fdx",
        detail: "Delete the build directory and all untracked files"
      ),
      onApprove: { _ in },
      onDeny: {}
    )
    .frame(width: device.size?.width ?? 390, height: 260)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A command far taller than the cap (#65): the block stops growing at
  /// `contentMaxHeight`, shows the first screenful, and fades its bottom edge to signal the
  /// rest is reachable by scrolling — while Deny/Approve stay on the card.
  ///
  /// The frame is pinned in **both** axes: `componentImage()` renders at `.sizeThatFits`,
  /// which proposes nothing along a `ScrollView`'s scroll axis, and a flexible scroll view
  /// takes that literally (CLAUDE.md's blank-sliver gotcha, vertical edition).
  func testApprovalCard_longCommandScrolls() {
    let view = ApprovalCardView(
      request: ApprovalRequest(
        // One fixture, shared with the measured suite that asserts this shape's geometry —
        // two copies would drift and the two suites would stop describing the same card.
        command: ApprovalCardLayoutTests.longCommand,
        detail: "Rebuild every target and re-run the full suite"
      ),
      onApprove: { _ in },
      onDeny: {}
    )
    .frame(width: device.size?.width ?? 390, height: 460)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// Push-tap approval recovery (hermes-agent #30 workaround): the synthetic request has
  /// no command — only the recovery-copy detail — so the card must lay out command-less.
  func testApprovalCard_recovered() {
    let view = ApprovalCardView(
      request: ChatFeature.recoveredApprovalRequest,
      onApprove: { _ in },
      onDeny: {}
    )
    // Height pinned for the reason on `testApprovalCard` — this card's content happens to sit
    // under the floor today, so `.sizeThatFits` is currently faithful, but a longer recovery
    // copy would silently start recording the floor instead.
    .frame(width: device.size?.width ?? 390, height: 220)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// The server narrowed the choice set to `once` + `deny` (no `session`): the "Approve all in
  /// this session" toggle is gone — the phone never widens what the server offers.
  func testApprovalCard_noSessionChoice() {
    let view = ApprovalCardView(
      request: ApprovalRequest(
        command: "git push --force origin main",
        detail: "Overwrite the remote branch history",
        patternKey: "force_push",
        choices: ["once", "deny"]
      ),
      onApprove: { _ in },
      onDeny: {}
    )
    // Height pinned for the reason on `testApprovalCard`.
    .frame(width: device.size?.width ?? 390, height: 220)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// `choices: ["deny"]`: Approve is hidden and Deny fills the button row alone.
  func testApprovalCard_denyOnly() {
    let view = ApprovalCardView(
      request: ApprovalRequest(
        command: "rm -rf /var/lib/postgresql",
        detail: "Blocked by policy: only denial is allowed",
        choices: ["deny"]
      ),
      onApprove: { _ in },
      onDeny: {}
    )
    // Height pinned for the reason on `testApprovalCard`.
    .frame(width: device.size?.width ?? 390, height: 220)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Clarify / secret cards

  // Every clarify card's questions sit in a bounded, scrollable region, so each snapshot pins
  // width AND height (the `testApprovalCard` reason: unpinned, `.sizeThatFits` records the
  // compressed floor). The frames are generous enough for the card to lay out naturally.

  /// Legacy `clarify.request` single-select: tap-to-submit rows and Skip — no Other row
  /// (legacy keeps today's form) and so no Send.
  func testClarifyCard_choices() {
    let view = ClarifyCardView(
      request: ClarifyRequest(
        requestID: "c1",
        question: "Which environment should I deploy to?",
        choices: ["staging", "production"]
      ),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 260)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A free-text question: the field sits in the region, Send (disabled until typed) and Skip
  /// in the pinned row.
  func testClarifyCard_freeText() {
    let view = ClarifyCardView(
      request: ClarifyRequest(requestID: "c2", question: "What should I name the branch?", choices: []),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 200)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// One multi-select question mid-answer: checkbox rows (two picked, in the server's order),
  /// the Other row, and an enabled Submit.
  func testClarifyCard_multiSelect() {
    let request = ClarifyRequest(
      requestID: nil,
      questions: [ClarifyQuestion(
        qid: "q0", question: "Which platforms should the build target?",
        choices: ["iOS", "macOS", "visionOS"], multiSelect: true
      )],
      answerShape: .answers
    )
    var draft = ClarifyDraft()
    draft.toggle("iOS", in: request.questions[0])
    draft.toggle("visionOS", in: request.questions[0])
    let view = ClarifyCardView(request: request, draft: draft, onSubmit: { _ in }, onSkip: {})
      .frame(width: device.size?.width ?? 390, height: 360)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A three-question batch (single-select, multi-select, free text): one section per question,
  /// each with its own Skip, Confirm disabled until every question has an answer or a skip.
  func testClarifyCard_multiQuestion() {
    let view = ClarifyCardView(
      request: Self.batchClarify(),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 520)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// The server's `" (Recommended)"` suffix renders as a badge on the bare label — never a
  /// preselection (v7 single-select: rows submit on tap, plus the Other row and Send).
  func testClarifyCard_recommendedBadge() {
    let view = ClarifyCardView(
      request: ClarifyRequest(
        requestID: nil,
        questions: [ClarifyQuestion(
          qid: "q0", question: "Which UI framework should the new screen use?",
          choices: ["SwiftUI (Recommended)", "UIKit"]
        )],
        answerShape: .answers
      ),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 320)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A replayed batch: the server already locked q0 (an answer) and q1 (a skip), so they
  /// render read-only with a check; only q2 is still open.
  func testClarifyCard_lockedAnswers() {
    var request = Self.batchClarify()
    request.lockedAnswers = ["q0": "SwiftUI", "q1": String?.none]
    let view = ClarifyCardView(request: request, onSubmit: { _ in }, onSkip: {})
      .frame(width: device.size?.width ?? 390, height: 340)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// The Other row with typed text on a single-select question: the text is the answer, so
  /// Send is enabled.
  func testClarifyCard_otherRow() {
    let request = ClarifyRequest(
      requestID: nil,
      questions: [ClarifyQuestion(
        qid: "q0", question: "Which environment should I deploy to?",
        choices: ["staging", "production"]
      )],
      answerShape: .answers
    )
    var draft = ClarifyDraft()
    draft.setText("canary in eu-west-1", for: request.questions[0])
    let view = ClarifyCardView(request: request, draft: draft, onSubmit: { _ in }, onSkip: {})
      .frame(width: device.size?.width ?? 390, height: 320)
      .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// The batch fixture shared by the multi-question and locked-answer snapshots.
  static func batchClarify() -> ClarifyRequest {
    ClarifyRequest(
      requestID: nil,
      questions: [
        ClarifyQuestion(qid: "q0", question: "Framework?", choices: ["SwiftUI (Recommended)", "UIKit"]),
        ClarifyQuestion(qid: "q1", question: "Targets?", choices: ["iOS", "macOS"], multiSelect: true),
        ClarifyQuestion(qid: "q2", question: "What should the app be called?"),
      ],
      answerShape: .answers
    )
  }

  func testSecretCard_secure() {
    let view = SecretCardView(
      kind: .secret,
      prompt: SecretPrompt(requestID: "s1", prompt: "Enter the API key for the weather service"),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 200)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// v7 sudo (v2026.9.21+) carries the redacted command the password is for.
  func testSudoCard_command() {
    let view = SecretCardView(
      kind: .sudo,
      prompt: SecretPrompt(command: "apt install -y ripgrep fd-find"),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 200)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// A sudo command far taller than the cap scrolls inside the card's bounded region, under a
  /// bottom fade, while the field, Skip and send stay pinned below it. Height pinned for the
  /// reason on `testApprovalCard` (a compressible region renders at its floor otherwise).
  func testSudoCard_longCommandScrolls() {
    let view = SecretCardView(
      kind: .sudo,
      prompt: SecretPrompt(command: ApprovalCardLayoutTests.longCommand),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 460)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  /// v7 secret names the environment variable the value is saved under.
  func testSecretCard_envVar() {
    let view = SecretCardView(
      kind: .secret,
      prompt: SecretPrompt(prompt: "Weather API key", envVar: "OPENWEATHER_API_KEY"),
      onSubmit: { _ in },
      onSkip: {}
    )
    .frame(width: device.size?.width ?? 390, height: 200)
    .background(Color(uiColor: .systemBackground))
    assertSnapshot(of: view, as: componentImage())
  }

  // MARK: Tool/skill rows + detail sheet

  func testToolRows() {
    let view = VStack(spacing: 10) {
      ToolStatusView(name: "read_file", title: "Reading server.py", state: .running,
                     durationS: nil, hasDetail: true, onTap: {})
      ToolStatusView(name: "edit_file", title: "Edited 3 lines in ChatView.swift", state: .complete,
                     durationS: 1.4, hasDetail: true, onTap: {})
      ToolStatusView(name: "todo", title: "todo", state: .complete,
                     durationS: 0.1, hasDetail: false, onTap: {})
    }
    .padding()
    .frame(width: device.size?.width ?? 390)
    assertSnapshot(of: view, as: componentImage())
  }

  func testToolDetailSheet() {
    let view = ToolDetailSheet(
      name: "edit_file",
      title: "Edited 3 lines in ChatView.swift",
      detail: ToolDetail(
        args: .object(["path": .string("ChatView.swift"), "start": .number(42)]),
        resultText: "Applied edit successfully.",
        inlineDiff: "- old line\n+ new line"
      ),
      durationS: 1.4
    )
    assertSnapshot(of: view, as: deviceImage())
  }

  func testScrollToBottomButton() {
    // Over a gradient so the Liquid Glass refraction is visible (it's near-invisible on
    // flat black).
    let view = ScrollToBottomButton(action: {})
      .padding(40)
      .background(
        LinearGradient(
          colors: [.purple, .blue, .teal],
          startPoint: .topLeading, endPoint: .bottomTrailing
        )
      )
    assertSnapshot(of: view, as: componentImage())
  }
}
