import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Slash-command support (#36), Task 3: the one-shot `commands.catalog` fetch fired when a
/// session becomes ready, capability-gated the attach way — `-32601` flips
/// `commandsUnsupported` (suppressing future fetches), any other failure stays silent with
/// the catalog `nil` so the next hydrate naturally retries.
///
/// Task 4: the computed `slashSuggestions` (pure derivation from `composerText` + catalog,
/// nothing stored) and `.slashSuggestionTapped` (inserts the suggestion's text, nothing else).
///
/// Task 6: the `slash.exec` pipeline in `composerSubmitted` — a typed `/cmd` with a loaded
/// catalog echoes a user row and executes through the gateway's slash pipeline (never
/// `prompt.submit`), appends the ephemeral `commandOutput` row, then fires the full
/// server-authoritative refresh (`session.resume` → `applyActivate`, carrying the ephemeral
/// output rows across the wholesale replace). Backward-compat guard: nil catalog /
/// `commandsUnsupported` / staged attachments all take today's plain path byte-identical.
///
/// Task 7: the `command.dispatch` fallback when `slash.exec` rejects the command — typed
/// directives decoded leniently: `exec`/`plugin` → output row, `alias` → single-hop
/// re-entry (a second alias fails, never loops), `skill`/`send` → the directive's message
/// through the normal `prompt.submit` with the duplicate optimistic user row suppressed;
/// both-RPCs-fail → banner + unlocked composer.
@MainActor
struct SlashCommandChatTests {
  private let conn = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "t")
  private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", n))")!
  }
  /// The pinned `date` the stores use — what the fold stamps on echoed user rows.
  private let t0 = Date(timeIntervalSince1970: 0)

  /// A realistic `commands.catalog` payload: two categorized built-ins (one with
  /// subcommands + an alias) and one uncategorized skill route appended last.
  nonisolated private static let catalogPayload: JSONValue = .object([
    "pairs": .array([
      .array([.string("/status"), .string("Show session status")]),
      .array([.string("/goal"), .string("Manage the standing goal")]),
      .array([.string("/deploy"), .string("Skill: ship the build")]),
    ]),
    "sub": .object(["/goal": .array([.string("show"), .string("pause"), .string("resume")])]),
    "canon": .object([
      "/status": .string("/status"),
      "/st": .string("/status"),
      "/goal": .string("/goal"),
      "/deploy": .string("/deploy"),
    ]),
    "categories": .array([
      .object([
        "name": .string("Session"),
        "pairs": .array([
          .array([.string("/status"), .string("Show session status")]),
          .array([.string("/goal"), .string("Manage the standing goal")]),
        ]),
      ]),
    ]),
  ])

  /// What `catalogPayload` decodes to (Task 1's lenient decode).
  nonisolated private static let expectedCatalog = CommandCatalog(
    commands: [
      SlashCommand(name: "/status", description: "Show session status", category: "Session", isSkill: false),
      SlashCommand(name: "/goal", description: "Manage the standing goal", category: "Session", isSkill: false),
      SlashCommand(name: "/deploy", description: "Skill: ship the build", category: nil, isSkill: true),
    ],
    subcommands: ["/goal": ["show", "pause", "resume"]],
    canonical: [
      "/status": "/status",
      "/st": "/status",
      "/goal": "/goal",
      "/deploy": "/deploy",
    ]
  )

  /// A minimal `session.resume` payload (idle turn, info + usage present so no fallback
  /// `session.usage` fetch muddies the call log).
  nonisolated private static let activatePayload: JSONValue = .object([
    "session_id": .string("live123"),
    "stored_session_id": .string("stored123"),
    "messages": .array([]),
    "running": .bool(false),
    "info": .object([
      "model": .string("claude-opus-4-8"),
      "usage": .object([
        "context_used": .number(1), "context_max": .number(200_000), "context_percent": .number(0),
      ]),
    ]),
  ])

  // MARK: Successful fetch

  @Test func hydrateReadyFetchesAndPopulatesCatalog() async {
    // Once the hydrate reaches ready, the one-shot `commands.catalog` fetch fires (with the
    // live session id) and populates `commandCatalog`; a later hydrate of the same screen
    // does NOT refetch a loaded catalog.
    let catalogCalls = LockIsolated(0)
    let catalogParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "commands.catalog" {
          catalogCalls.withValue { $0 += 1 }
          catalogParams.setValue(params)
          return Self.catalogPayload
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await store.receive(\.commandCatalogLoaded) {
      $0.commandCatalog = Self.expectedCatalog
    }
    #expect(store.state.commandsUnsupported == false)
    #expect(catalogParams.value?["session_id"]?.stringValue == "live123")
    #expect(catalogCalls.value == 1)

    // A second hydrate (foreground over the healthy socket) must NOT refetch — the catalog
    // is already loaded. Drain every effect before the terminal assert so a straggling
    // (buggy) refetch can't slip past the counter.
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
    await store.finish()
    #expect(catalogCalls.value == 1)
  }

  @Test func freshSessionCreateFetchesCatalog() async {
    // A brand-new chat resolves through `session.create` (no hydrate ever fires), so the
    // catalog fetch rides the create result — otherwise a fresh chat would have no slash
    // panel until the first foreground re-hydrate.
    let store = TestStore(initialState: ChatFeature.State(connection: conn)) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" { return Self.catalogPayload }
        return .object([
          "session_id": .string("live123"),
          "stored_session_id": .string("stored123"),
          "message_count": .number(0),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.sessionResult.success) {
      $0.liveSessionID = "live123"
      $0.storedSessionID = "stored123"
    }
    await store.receive(\.commandCatalogLoaded) {
      $0.commandCatalog = Self.expectedCatalog
    }
    await store.send(.teardown)
  }

  // MARK: Capability gate (attach pattern)

  @Test func unknownMethodFlipsCommandsUnsupportedAndSuppressesFutureFetches() async {
    // An old agent answers `-32601` ("unknown method") → `commandsUnsupported` latches, no
    // banner (nothing the user did failed), and later hydrates never poke the agent again.
    let catalogCalls = LockIsolated(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" {
          catalogCalls.withValue { $0 += 1 }
          throw GatewayError.server("unknown method: commands.catalog")
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await store.receive(\.commandsUnsupportedDetected) {
      $0.commandsUnsupported = true
    }
    #expect(store.state.commandCatalog == nil)
    #expect(store.state.errorBanner == nil)
    #expect(catalogCalls.value == 1)

    // The next hydrate skips the fetch entirely — the capability is ruled out. Drain
    // every effect before the terminal assert so a straggling (buggy) refetch can't slip
    // past the counter.
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    await store.send(.teardown)
    await store.finish()
    #expect(catalogCalls.value == 1)
  }

  // MARK: Transient failure retries on the next hydrate

  @Test func transientCatalogFailureLeavesNilAndNextHydrateRefetches() async {
    // A transient failure (network / server hiccup) is silent: no banner, catalog stays
    // `nil`, `commandsUnsupported` stays false — and the next hydrate naturally refetches.
    let catalogCalls = LockIsolated(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" {
          let attempt = catalogCalls.withValue { $0 += 1; return $0 }
          guard attempt > 1 else { throw GatewayError.server("catalog exploded") }
          return Self.catalogPayload
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await waitUntil { catalogCalls.value == 1 }
    // Silent: no state change, no banner — the catalog just stays unloaded.
    #expect(store.state.commandCatalog == nil)
    #expect(store.state.commandsUnsupported == false)
    #expect(store.state.errorBanner == nil)

    // The next hydrate refetches and succeeds this time.
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    await store.receive(\.commandCatalogLoaded) {
      $0.commandCatalog = Self.expectedCatalog
    }
    #expect(catalogCalls.value == 2)
    await store.send(.teardown)
  }

  @Test func emptyCatalogPayloadStaysNilForLaterRetry() async {
    // The lenient decode never throws, so a garbage/empty payload surfaces as an EMPTY
    // catalog — as useless as none. It must NOT latch: state stays `nil` (silent) so a
    // later hydrate can still recover a real catalog.
    let catalogCalls = LockIsolated(0)
    let store = TestStore(initialState: ChatFeature.State(connection: conn, resumeStoredID: "stored123")) {
      ChatFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "commands.catalog" {
          catalogCalls.withValue { $0 += 1 }
          return .object([:]) // no pairs/sub/canon/categories at all
        }
        return Self.activatePayload
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.gatewayEvent(.ready))
    await store.receive(\.activateResult.success)
    await waitUntil { catalogCalls.value == 1 }
    // Drain every effect (applying any skipped actions) BEFORE the terminal asserts — a
    // buggy `.commandCatalogLoaded(empty)` still buffered would otherwise never reach
    // state and the guard would pass vacuously.
    await store.send(.teardown)
    await store.finish()
    #expect(store.state.commandCatalog == nil)
    #expect(store.state.commandsUnsupported == false)
  }

  // MARK: Computed suggestions (Task 4)

  /// A loaded-catalog state with no gateway plumbing: the suggestion tests exercise only
  /// the pure computed property + the tap action, no effects fire.
  private func stateWithCatalog() -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.commandCatalog = Self.expectedCatalog
    return state
  }

  @Test func typingSlashYieldsFullSuggestionList() async {
    // The issue's core affordance: typing "/" surfaces the whole curated catalog in
    // category order with the skill route last — derived from the computed property,
    // no stored suggestion state.
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/"))) {
      $0.composerText = "/"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["/status", "/goal", "/deploy"])
    #expect(store.state.slashSuggestions.map(\.isSkill) == [false, false, true])
  }

  @Test func typingFiltersSuggestions() async {
    // Continued typing narrows by case-insensitive prefix; aliases resolve to their
    // canonical row ("/st" matches "/status" both directly and via the "/st" alias —
    // shown once).
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/go"))) {
      $0.composerText = "/go"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["/goal"])

    await store.send(.binding(.set(\.composerText, "/st"))) {
      $0.composerText = "/st"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["/status"])

    // Subcommand mode: a known command + space + partial completes from the `sub` map.
    await store.send(.binding(.set(\.composerText, "/goal p"))) {
      $0.composerText = "/goal p"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["pause"])
  }

  @Test func tapInsertsCommandAndClearsPanel() async throws {
    // Tapping a command row puts "/name " (trailing space, ready for args) in the
    // composer and changes NOTHING else; the computed suggestions clear on their own
    // ("/status " has no subcommands).
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/st"))) {
      $0.composerText = "/st"
    }
    let suggestion = try #require(store.state.slashSuggestions.first)
    await store.send(.slashSuggestionTapped(suggestion)) {
      $0.composerText = "/status "
    }
    #expect(store.state.slashSuggestions.isEmpty)

    // A subcommand tap inserts "/cmd sub" (no trailing space — the arg is complete) and
    // the panel clears itself: an exact subcommand match is suppressed by the filter.
    await store.send(.binding(.set(\.composerText, "/goal p"))) {
      $0.composerText = "/goal p"
    }
    let sub = try #require(store.state.slashSuggestions.first)
    await store.send(.slashSuggestionTapped(sub)) {
      $0.composerText = "/goal pause"
    }
    #expect(store.state.slashSuggestions.isEmpty)
  }

  @Test func nonSlashInputNeverProducesSuggestions() async {
    // Ordinary prose — including a mid-sentence slash and multiline text — must never
    // pop the panel.
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "hello"))) {
      $0.composerText = "hello"
    }
    #expect(store.state.slashSuggestions.isEmpty)

    await store.send(.binding(.set(\.composerText, "see /status for details"))) {
      $0.composerText = "see /status for details"
    }
    #expect(store.state.slashSuggestions.isEmpty)

    await store.send(.binding(.set(\.composerText, "/status\nsecond line"))) {
      $0.composerText = "/status\nsecond line"
    }
    #expect(store.state.slashSuggestions.isEmpty)

    // Shape rule (desktop's `SLASH_COMMAND_RE`): a first token containing a second "/" is
    // a path or a comment, never a command — the panel and the submit gate agree.
    for prose in ["/tmp/agent.log look at this", "/Users/me/notes.md summarize", "//TODO fix"] {
      await store.send(.binding(.set(\.composerText, prose))) {
        $0.composerText = prose
      }
      #expect(store.state.slashSuggestions.isEmpty, "\(prose) must not suggest")
    }
  }

  @Test func suggestionsEmptyWhenCommandsUnsupported() async {
    // Backward-compat guard: an old agent (commandsUnsupported latched) never shows the
    // panel — even defensively against a somehow-populated catalog. And with no catalog
    // loaded yet (nil), "/" likewise yields nothing.
    var unsupported = stateWithCatalog()
    unsupported.commandsUnsupported = true
    let store = TestStore(initialState: unsupported) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/"))) {
      $0.composerText = "/"
    }
    #expect(store.state.slashSuggestions.isEmpty)

    let nilCatalog = TestStore(initialState: ChatFeature.State(connection: conn)) { ChatFeature() }
    await nilCatalog.send(.binding(.set(\.composerText, "/"))) {
      $0.composerText = "/"
    }
    #expect(nilCatalog.state.slashSuggestions.isEmpty)
  }

  @Test func aStandingCardSuppressesTheSuggestionsWithoutTouchingTheDraft() async {
    // #65: the panel is a fixed slab in the same non-scrolling region as a blocking card and
    // the composer, and stacking the two pushes the card's Deny/Approve row off screen on a
    // small phone. A card standing therefore empties the suggestions — for a draft typed
    // BEFORE the card arrives (this case) as much as for one typed after, since the card only
    // resigns the composer, never disables it.
    let store = TestStore(initialState: stateWithCatalog()) { ChatFeature() }

    await store.send(.binding(.set(\.composerText, "/st"))) {
      $0.composerText = "/st"
    }
    #expect(store.state.slashSuggestions.map(\.name) == ["/status"])

    await store.send(.gatewayEvent(.approvalRequest(ApprovalRequest(command: "rm -rf /")))) {
      $0.present(.approval(ApprovalRequest(command: "rm -rf /")))
    }
    #expect(store.state.slashSuggestions.isEmpty)
    // The suppression is display-only: the draft is still there (the composer stays editable),
    // and it could not have been submitted meanwhile anyway.
    #expect(store.state.composerText == "/st")
    #expect(store.state.canSend == false)

    // Every blocking card, not just the approval: the clarify and secret cards own the same
    // region (and carry a text field of their own, which the panel would sit on top of).
    var clarifying = store.state
    clarifying.present(.clarify(ClarifyRequest(requestID: "r", question: "Which target?")))
    #expect(clarifying.slashSuggestions.isEmpty)
    var secret = store.state
    secret.present(.secret(.sudo, SecretPrompt(requestID: "r", prompt: "Password")))
    #expect(secret.slashSuggestions.isEmpty)

    // Answering the card brings the panel straight back — nothing had to be re-typed.
    var answered = store.state
    answered.pendingInteraction = nil
    #expect(answered.slashSuggestions.map(\.name) == ["/status"])
    #expect(answered.composerText == "/st")
  }

  // MARK: slash.exec pipeline (Task 6)

  /// A ready chat with the catalog loaded and a resolved session, poised to submit.
  ///
  /// `extraCommands` injects additional catalog entries so a pipeline test can submit a
  /// command that isn't part of the minimal shared fixture (`/fork`, `/retry`, `/undo`, …).
  /// The submit gate now routes to `slash.exec` ONLY for commands that resolve in the
  /// catalog (`CommandCatalog.resolvesCommand`), so these commands must be present or they
  /// would fall through to a plain `prompt.submit`.
  private func readyStateWithCatalog(
    composerText: String = "/status",
    extraCommands: [String] = []
  ) -> ChatFeature.State {
    var state = ChatFeature.State(connection: conn)
    state.liveSessionID = "live123"
    state.storedSessionID = "stored123"
    if extraCommands.isEmpty {
      state.commandCatalog = Self.expectedCatalog
    } else {
      state.commandCatalog = CommandCatalog(
        commands: Self.expectedCatalog.commands + extraCommands.map {
          SlashCommand(name: $0, description: "", category: "Session", isSkill: false)
        },
        subcommands: Self.expectedCatalog.subcommands,
        canonical: Self.expectedCatalog.canonical
      )
    }
    state.composerText = composerText
    return state
  }

  @Test func slashSubmitRunsExecPipelineAndRefreshesRuntime() async {
    // The issue's core exec path: "/status" echoes a user row, goes out as
    // `slash.exec {command (no slash), session_id}` — NOT prompt.submit — appends the
    // ephemeral commandOutput row, unlocks the composer, and then the SERVER-AUTHORITATIVE
    // refresh rebuilds the transcript from `session.resume` (slash commands mutate history:
    // `/compress` rewrites it, `/undo` rewinds it) while CARRYING the ephemeral
    // commandOutput row across the wholesale replace.
    let calls = LockIsolated<[String]>([])
    let execParams = LockIsolated<JSONValue?>(nil)
    let snapshot = ChatSnapshotClient.inMemory()
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = snapshot
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec":
          execParams.setValue(params)
          return .object(["output": .string("Session: all good")])
        case "session.resume":
          return .object([
            "session_id": .string("live123"),
            "messages": .array([
              .object(["id": .number(1), "role": .string("user"), "text": .string("server history")]),
            ]),
            "running": .bool(false),
            "info": .object([
              "model": .string("claude-opus-4-9"),
              "title": .string("Renamed by slash"),
              "usage": .object(["context_used": .number(500), "context_max": .number(200_000)]),
            ]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/status", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
      $0.slashExecInFlight = true
    }
    await store.receive(\.slashCommandOutput) {
      $0.transcript.append(ChatRow(id: self.uuid(1), kind: .commandOutput(text: "Session: all good")))
      $0.isSending = false
      $0.slashExecInFlight = false
    }
    // The client-side "turn" end is delegated (no server event follows an exec) so a
    // detached slot waiting on it is released.
    await store.receive({ action in
      guard case let .delegate(.runningChanged(sessionID, running)) = action else { return false }
      return sessionID == "stored123" && running == false
    })
    await store.receive(\.slashHistoryRefreshed) {
      $0.model = "claude-opus-4-9"
      $0.title = "Renamed by slash"
      $0.usage = Usage(contextUsed: 500, contextMax: 200_000)
    }
    await store.finish()

    // Exactly the pipeline RPCs — never prompt.submit; the command travels slash-less.
    #expect(calls.value == ["slash.exec", "session.resume"])
    #expect(execParams.value?["command"]?.stringValue == "status")
    #expect(execParams.value?["session_id"]?.stringValue == "live123")
    // Server-authoritative: the transcript is the server's history (the optimistic "/status"
    // echo is gone — server wins) with the EPHEMERAL command output carried across the
    // wholesale replace and re-appended last.
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "server history", isComplete: true),
      .commandOutput(text: "Session: all good"),
    ])
    #expect(store.state.errorBanner == nil)
    // The slash branch sets NO turn anchor (an exec is not a turn — a hydrate mid-exec
    // must never resurrect a phantom elapsed timer).
    #expect(snapshot.turnAnchor("stored123") == nil)
  }

  @Test func slashAliasIsCanonicalizedForTheWireCommand() async {
    // #36 follow-up (still live for NON-compress aliases): typing an ALIAS in FULL must reach
    // `slash.exec` as its CANONICAL name — the gateway's live handler recognizes only canonical
    // names (`_LIVE_SESSION_DIRECT_COMMANDS`), so a raw alias would fall through to the isolated
    // slash-worker subprocess and report "Unknown command". The user still SEES the raw alias
    // they typed in the transcript — only the wire command is canonical. (`/compress`/`/compact`
    // no longer exercise this path — they route to the dedicated `session.compress` RPC — so
    // this uses the generic `/st → /status` alias, proving the retained canonicalization helper.)
    let execParams = LockIsolated<JSONValue?>(nil)
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.commandCatalog = CommandCatalog(
      commands: [SlashCommand(name: "/status", description: "Show status", category: "Session", isSkill: false)],
      subcommands: [:],
      canonical: ["/status": "/status", "/st": "/status"]
    )
    initial.composerText = "/st here 5"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "slash.exec" {
          execParams.setValue(params)
          return .object(["output": .string("status: all good")])
        }
        return .object([
          "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
          "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      // The RAW typed alias is echoed as the user row — only the WIRE command is canonical.
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/st here 5", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
      $0.slashExecInFlight = true
    }
    await store.receive(\.slashCommandOutput)
    await store.finish()
    // The alias was resolved: slash.exec got "status here 5", NEVER "st here 5".
    #expect(execParams.value?["command"]?.stringValue == "status here 5")
    #expect(execParams.value?["session_id"]?.stringValue == "live123")
  }

  @Test func slashExecOutputIsStrippedOfANSIEscapes() async {
    // BUG (#36 follow-up): the agent formats slash output for a terminal (SGR colors,
    // box-drawing color runs). On mobile the ESC byte is invisible, so the sequences render
    // as literal garbage (`[1;31m`, `[0m`, `[38;2;255;215;0m`). The `commandOutput` row must
    // be clean — the mascot and box-drawing chrome are kept, only ESC sequences removed.
    let esc = "\u{1B}"
    let ansi = "\(esc)[1;31mUnknown command: /foo\(esc)[0m\n\(esc)[38;2;255;215;0m(^_^)?\(esc)[0m +---+"
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        if method == "slash.exec" { return .object(["output": .string(ansi)]) }
        return .object([
          "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
          "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput)
    await store.finish()
    // The ephemeral row (carried across the post-command refresh) is clean text.
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "Unknown command: /foo\n(^_^)? +---+"))
  }

  @Test func slashExecWarningAndEmptyOutputDegradeGracefully() async {
    // Web-reference parity: a `warning` is prefixed above the body, and an empty/missing
    // `output` degrades to "/name: no output" rather than an empty row.
    let execCount = LockIsolated(0)
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        switch method {
        case "slash.exec":
          let attempt = execCount.withValue { $0 += 1; return $0 }
          if attempt == 1 {
            return .object(["output": .string("done"), "warning": .string("deprecated")])
          }
          return .object([:]) // no output at all
        case "session.resume":
          // The post-command refresh (usage present → no session.usage fallback).
          return .object([
            "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "warning: deprecated\ndone"))

    await store.send(.binding(.set(\.composerText, "/status"))) {
      $0.composerText = "/status"
    }
    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "/status: no output"))
  }

  @Test func slashExecFailureSurfacesBannerAndUnlocks() async {
    // The both-fail contract: `slash.exec` rejects, the `command.dispatch` fallback is
    // attempted and fails too → banner + unlocked composer — never a swallowed `try?`.
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec", "command.dispatch": throw GatewayError.server("boom")
        default: return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/status", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
    }
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: boom"
      $0.isSending = false
    }
    // The failure is a client-side turn end too — the delegate releases a detached slot.
    await store.receive({ action in
      guard case let .delegate(.runningChanged(sessionID, running)) = action else { return false }
      return sessionID == "stored123" && running == false
    })
    await store.finish()
    // The fallback WAS attempted before failing; the typed command row stays visible and
    // no output row was appended.
    #expect(calls.value == ["slash.exec", "command.dispatch"])
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "/status", isComplete: true),
    ])
  }

  @Test func slashExecSelfHealsOnSessionNotFound() async {
    // The exec rides the standard #17 self-heal: a stale live id answers "session not
    // found" → re-resume for a fresh id, replay the exec ONCE against it, output lands
    // with no banner.
    let calls = LockIsolated<[(method: String, sid: String?)]>([])
    var initial = readyStateWithCatalog()
    initial.liveSessionID = "stale-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        let sid = params["session_id"]?.stringValue
        calls.withValue { $0.append((method, sid)) }
        switch method {
        case "slash.exec":
          if sid == "stale-live" { throw GatewayError.server("session not found") }
          return .object(["output": .string("ok")])
        case "session.resume":
          // Serves both the #17 heal and the post-command refresh.
          return .object([
            "session_id": .string("fresh-live"),
            "stored_session_id": .string("stored123"),
            "messages": .array([]),
            "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
    }
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()

    // Exec, heal-resume, single replay (against the fresh id), then the runtime refresh.
    #expect(calls.value.map(\.method) == ["slash.exec", "session.resume", "slash.exec", "session.resume"])
    #expect(calls.value[2].sid == "fresh-live")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "ok"))
  }

  @Test func slashExecOnUnpersistedBranchHealsViaSeededCreate() async {
    // Merge-gap fix: a slash command on an UNPERSISTED branch (#34) — attach-by-live-id, a
    // durable `branchSeed`, a stored id that has NO DB row — must self-heal EXACTLY like the
    // plain-prompt/attachments paths when `slash.exec` answers "session not found" (a routine
    // reap after background→foreground). Because `attachLiveSessionID != nil`, the captured
    // stored id is dropped and the heal recreates the SEEDED session (`session.create` with
    // messages + parent_session_id — NOT a `session.resume` of the row-less stored id, which
    // would 4007 again and throw), then replays the exec once. Mirrors
    // `ChatBranchTests.submitHealRecreatesSeededSessionAndKeepsAttachMode` for the slash path.
    let calls = LockIsolated<[(method: String, params: JSONValue)]>([])
    var initial = readyStateWithCatalog()
    initial.liveSessionID = "branch-live"
    initial.attachLiveSessionID = "branch-live"
    initial.branchSeed = .init(text: "seeded answer", parentSessionID: "parent-1")
    initial.storedSessionID = "branch-stored" // a bare session_key with no DB row
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append((method, params)) }
        switch method {
        case "slash.exec":
          if params["session_id"]?.stringValue == "branch-live" {
            throw GatewayError.server("session not found") // the reaped live id
          }
          return .object(["output": .string("ok")])
        case "session.create":
          return .object([
            "session_id": .string("fresh-live"), "stored_session_id": .string("fresh-stored"),
          ])
        case "session.resume":
          // Only the post-command refresh should reach here (against the healed id) —
          // NEVER the #17 heal, which must take the seeded-create path for a row-less branch.
          return .object([
            "session_id": .string("fresh-live"),
            "messages": .array([]),
            "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    // The heal recreated the SEEDED session and kept attach-by-live-id + the seed (its DB
    // row lands when the replayed command's own history refresh persists it).
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
      $0.storedSessionID = "fresh-stored"
      $0.attachLiveSessionID = "fresh-live"
    }
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()

    // slash.exec (reaped) → SEEDED session.create → replay slash.exec → post-command refresh.
    #expect(calls.value.map(\.method) == ["slash.exec", "session.create", "slash.exec", "session.resume"])
    // The heal's create carried the branch seed + parent link — never a bare create.
    let createParams = calls.value[1].params
    guard case let .array(messages)? = createParams["messages"] else {
      Issue.record("heal create missing the seed messages")
      return
    }
    #expect(messages.first?["content"]?.stringValue == "seeded answer")
    #expect(createParams["parent_session_id"]?.stringValue == "parent-1")
    // The replayed exec targeted the fresh live id.
    #expect(calls.value[2].params["session_id"]?.stringValue == "fresh-live")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.branchSeed == .init(text: "seeded answer", parentSessionID: "parent-1"))
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "ok"))
  }

  @Test func slashExecUnknownMethodFailsDirectlyWithoutDispatchFallback() async {
    // A `-32601` from slash.exec fails directly — `command.dispatch` shipped alongside
    // `slash.exec` (same pipeline), so the fallback could only answer a second `-32601`.
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        throw GatewayError.server("unknown method: slash.exec")
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: unknown method: slash.exec"
      $0.isSending = false
    }
    await store.finish()
    #expect(calls.value == ["slash.exec"])
  }

  @Test func transportShapedExecFailureSkipsTheDispatchFallback() async {
    // A timeout (or drop) can leave the exec STILL RUNNING server-side (`slash.exec` has
    // a 45s worker budget vs the client's 30s per-RPC timeout) — falling back to
    // `command.dispatch` could execute the command a SECOND time (`/retry` would truncate
    // and resend twice). Both transport-shaped failures must fail directly.
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        let attempt = calls.withValue { $0.append(method); return $0.count }
        if attempt == 1 { throw GatewayError.timedOut(method: "slash.exec") }
        throw GatewayError.disconnected
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: request timed out: slash.exec"
      $0.isSending = false
    }

    await store.send(.binding(.set(\.composerText, "/status"))) {
      $0.composerText = "/status"
    }
    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: Connection lost."
      $0.isSending = false
    }
    await store.finish()
    // Two submits, two exec attempts — and NO command.dispatch roundtrip for either.
    #expect(calls.value == ["slash.exec", "slash.exec"])
  }

  @Test func degenerateSlashKeepsTheTypedTextAndNeverHitsTheWire() async {
    // "/" (and "/ <payload>") parses to an empty command name. The server could only answer
    // "empty command" after a doomed roundtrip, so the reducer guards BEFORE clearing the
    // composer: the banner is raised, nothing hits the wire, no user row is echoed, and —
    // critically — the typed text is handed back intact. Desktop restores the draft for
    // exactly this case; without it an arbitrarily long payload after a stray slash is
    // lost forever.
    let calls = LockIsolated<[String]>([])
    let payload = "/ a very long pasted payload the user must not lose"
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: payload)
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.errorBanner = "Command failed: empty command"
    }
    await store.finish()
    #expect(calls.value.isEmpty)
    #expect(store.state.composerText == payload)
    #expect(store.state.transcript.isEmpty)
    #expect(store.state.isSending == false)
    #expect(store.state.slashExecInFlight == false)

    // A bare "/" behaves identically.
    let bare = TestStore(
      initialState: readyStateWithCatalog(composerText: "/")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        return .object([:])
      }
    }
    bare.exhaustivity = .off(showSkippedAssertions: false)
    await bare.send(.composerSubmitted) {
      $0.errorBanner = "Command failed: empty command"
    }
    await bare.finish()
    #expect(calls.value.isEmpty)
    #expect(bare.state.composerText == "/")
  }

  @Test func pathLikeSlashTextGoesThroughPlainPromptSubmit() async {
    // The shape rule (desktop's `SLASH_COMMAND_RE = /^\/[^\s/]*(?:\s|$)/`): a first token
    // containing a SECOND "/" is a path or a comment, not a command. A bare `hasPrefix("/")`
    // routed `/tmp/agent.log look at this` into the slash pipeline, where it failed twice
    // and DESTROYED the message (the composer is cleared on submit and the echoed row is
    // local-only). These must reach the agent as ordinary prompts.
    let calls = LockIsolated<[(method: String, text: String?)]>([])
    for prose in ["/tmp/agent.log look at this", "/Users/me/notes.md summarize", "//TODO fix this"] {
      let store = TestStore(
        initialState: readyStateWithCatalog(composerText: prose)
      ) { ChatFeature() } withDependencies: {
        $0.uuid = .incrementing
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.chatSnapshot = .inMemory()
        $0.hermesGateway.send = { @Sendable method, params in
          calls.withValue { $0.append((method, params["text"]?.stringValue)) }
          return .object([:])
        }
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(.composerSubmitted) {
        $0.composerText = ""
        $0.isSending = true
      }
      await store.finish()
      // The plain path: prompt.submit with the text verbatim, never slash.exec, and the
      // usual turn anchor + optimistic user row.
      #expect(calls.value.map(\.method) == ["prompt.submit"])
      #expect(calls.value.first?.text == prose)
      #expect(store.state.slashExecInFlight == false)
      #expect(store.state.transcript.map(\.kind) == [
        .message(role: .user, text: prose, isComplete: true),
      ])
      calls.setValue([])
    }
  }

  @Test func multilineSlashTextTakesTheSlashPipeline() async {
    // Desktop/server parity: slash args may span newlines (`/goal <pasted text>` — the
    // server splits on any whitespace, and the desktop's `\s` shape terminator matches a
    // newline), so a multiline submission whose FIRST TOKEN is command-shaped still
    // executes through slash.exec — the suggestion panel simply never shows for it.
    let execParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/goal line one\nline two")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        if method == "slash.exec" {
          execParams.setValue(params)
          return .object(["output": .string("goal set")])
        }
        return .object([
          "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
          "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()
    #expect(execParams.value?["command"]?.stringValue == "goal line one\nline two")
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "goal set"))
  }

  @Test func serverRoutedCommandFailureSkipsTheDispatchFallback() async {
    // The gateway routes `_PENDING_INPUT_COMMANDS` (`/undo`, `/retry`, `/steer`, …)
    // through `command.dispatch` ITSELF, inside `slash.exec`. An error therefore comes FROM
    // a dispatch that already ran, so re-issuing our own would re-enter the same handler —
    // a `/retry` that reached its truncate-and-resend has already mutated history and would
    // run twice. Same double-execution class as the transport-failure guard. (`/compress`/
    // `/compact` are NOT here: they route to the dedicated `session.compress` RPC and never
    // reach `slash.exec` — covered by the compress tests.)
    let calls = LockIsolated<[String]>([])
    for command in ["/undo", "/retry", "/steer"] {
      let store = TestStore(
        initialState: readyStateWithCatalog(composerText: command, extraCommands: [command])
      ) { ChatFeature() } withDependencies: {
        $0.uuid = .incrementing
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
        $0.chatSnapshot = .inMemory()
        $0.hermesGateway.send = { @Sendable method, _ in
          calls.withValue { $0.append(method) }
          throw GatewayError.server("compress failed")
        }
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(.composerSubmitted)
      await store.receive(\.slashCommandFailed) {
        $0.errorBanner = "Command failed: compress failed"
        $0.isSending = false
        $0.slashExecInFlight = false
      }
      await store.finish()
      #expect(calls.value == ["slash.exec"], "\(command) must not re-dispatch")
      calls.setValue([])
    }

    // Contrast: a command the server does NOT route internally still gets the fallback.
    let other = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/deploy")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        other.withValue { $0.append(method) }
        throw GatewayError.server("not a quick/plugin/skill command")
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed)
    await store.finish()
    #expect(other.value == ["slash.exec", "command.dispatch"])
  }

  // MARK: session.compress (dedicated RPC — desktop parity, version-independent)

  @Test func compressRoutesToSessionCompressNotSlashExec() async {
    // The reported bug's fix: `/compress` calls the DEDICATED `session.compress` gateway RPC
    // — NEVER `slash.exec` (which falls through to an isolated worker on older agents). It
    // locks/unlocks the composer via the SAME slash terminal path, appends a confirmation
    // commandOutput row (from the server summary), and runs the server-authoritative refresh
    // so the transcript + context-usage pill update (compression rewrites history + usage).
    // NOTE: the shared catalog does NOT contain `/compress` — detection is hardcoded
    // (`compressCommandNames`), NOT catalog-derived, proving it works even when the catalog
    // omits or mislabels it.
    let calls = LockIsolated<[String]>([])
    let compressParams = LockIsolated<JSONValue?>(nil)
    let snapshot = ChatSnapshotClient.inMemory()
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/compress")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = snapshot
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append(method) }
        switch method {
        case "session.compress":
          compressParams.setValue(params)
          return .object([
            "status": .string("compressed"),
            "removed": .number(8),
            "summary": .object([
              "headline": .string("Compressed 12 → 4 messages"),
              "token_line": .string("~40,000 → ~12,000 tokens"),
              "note": .string("Older turns summarized."),
              "aborted": .bool(false),
            ]),
            "usage": .object(["context_used": .number(12000), "context_max": .number(200_000)]),
          ])
        case "session.resume":
          return .object([
            "session_id": .string("live123"),
            "messages": .array([
              .object(["id": .number(1), "role": .string("user"), "text": .string("compressed history")]),
            ]),
            "running": .bool(false),
            "info": .object([
              "model": .string("claude-opus-4-8"),
              "usage": .object(["context_used": .number(12000), "context_max": .number(200_000)]),
            ]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/compress", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
      $0.slashExecInFlight = true
    }
    await store.receive(\.slashCommandOutput) {
      $0.transcript.append(ChatRow(
        id: self.uuid(1),
        kind: .commandOutput(text: "Compressed 12 → 4 messages\n~40,000 → ~12,000 tokens\nOlder turns summarized.")
      ))
      $0.isSending = false
      $0.slashExecInFlight = false
    }
    await store.receive({ action in
      guard case let .delegate(.runningChanged(sessionID, running)) = action else { return false }
      return sessionID == "stored123" && running == false
    })
    await store.receive(\.slashHistoryRefreshed) {
      $0.usage = Usage(contextUsed: 12000, contextMax: 200_000)
    }
    await store.finish()

    // Exactly the dedicated RPC + the post-command refresh — NEVER slash.exec/command.dispatch.
    #expect(calls.value == ["session.compress", "session.resume"])
    #expect(compressParams.value?["session_id"]?.stringValue == "live123")
    // No focus topic typed → the param is omitted (byte-minimal request).
    #expect(compressParams.value?["focus_topic"] == nil)
    // Server-authoritative: the transcript is the server's post-compress history with the
    // ephemeral confirmation carried across the wholesale replace.
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "compressed history", isComplete: true),
      .commandOutput(text: "Compressed 12 → 4 messages\n~40,000 → ~12,000 tokens\nOlder turns summarized."),
    ])
    #expect(store.state.errorBanner == nil)
    // An exec-style command sets NO turn anchor (a hydrate mid-command must not resurrect a
    // phantom elapsed timer).
    #expect(snapshot.turnAnchor("stored123") == nil)
  }

  @Test func compactAliasAlsoRoutesToSessionCompress() async {
    // The ACTUAL reported bug: the ALIAS `/compact` must ALSO reach `session.compress`, never
    // `slash.exec`. This holds even with an OLDER agent's MISLABELING catalog whose `canon`
    // self-maps `/compact → /compact` (so client-side canonicalization is a no-op) — detection
    // is by hardcoded canonical intent, not the catalog. The RAW `/compact` is echoed as the
    // user row.
    let calls = LockIsolated<[String]>([])
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    // The buggy old-agent catalog: alias self-maps instead of resolving to /compress.
    initial.commandCatalog = CommandCatalog(
      commands: [SlashCommand(name: "/compress", description: "Compress context", category: "Session", isSkill: false)],
      subcommands: [:],
      canonical: ["/compress": "/compress", "/compact": "/compact"]
    )
    initial.composerText = "/compact"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "session.compress":
          return .object(["status": .string("compressed"), "removed": .number(3)])
        case "session.resume":
          return .object([
            "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      // The RAW typed alias is echoed as the user row.
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/compact", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
      $0.slashExecInFlight = true
    }
    await store.receive(\.slashCommandOutput) {
      $0.transcript.append(ChatRow(id: self.uuid(1), kind: .commandOutput(text: "Compressed 3 messages.")))
      $0.isSending = false
      $0.slashExecInFlight = false
    }
    await store.receive({ action in
      guard case .delegate(.runningChanged) = action else { return false }
      return true
    })
    await store.receive(\.slashHistoryRefreshed)
    await store.finish()

    // `/compact` reached session.compress — NEVER slash.exec / command.dispatch.
    #expect(calls.value == ["session.compress", "session.resume"])
    #expect(store.state.errorBanner == nil)
  }

  @Test func compressThreadsFocusTopicAndSynthesizesConfirmation() async {
    // A typed argument becomes the compression `focus_topic`, and when the server returns no
    // display text (no summary / message / host_ack / removed count) the confirmation is
    // synthesized to a sensible "Context compressed." so the user always gets feedback.
    let compressParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/compress just the auth flow")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        switch method {
        case "session.compress":
          compressParams.setValue(params)
          return .object(["status": .string("compressed")]) // no display text at all
        case "session.resume":
          return .object([
            "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()
    #expect(compressParams.value?["focus_topic"]?.stringValue == "just the auth flow")
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "Context compressed."))
  }

  @Test func compressFailureSurfacesBannerAndUnlocks() async {
    // A `session.compress` failure surfaces `.slashCommandFailed` (banner + unlocked composer)
    // — never a swallowed `try?` — and runs NO history refresh (a failure lands no change).
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/compress")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        throw GatewayError.server("compress boom")
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/compress", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
      $0.slashExecInFlight = true
    }
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: compress boom"
      $0.isSending = false
      $0.slashExecInFlight = false
    }
    await store.receive({ action in
      guard case let .delegate(.runningChanged(sessionID, running)) = action else { return false }
      return sessionID == "stored123" && running == false
    })
    await store.finish()
    // Only the compress RPC ran — no dispatch fallback, no refresh.
    #expect(calls.value == ["session.compress"])
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "/compress", isComplete: true),
    ])
  }

  @Test func compressSelfHealsOnSessionNotFound() async {
    // The compress RPC rides the standard #17 self-heal: a stale live id answers "session not
    // found" → re-resume for a fresh id, replay session.compress ONCE against it, confirmation
    // lands with no banner. Mirrors the slash-exec heal test shape.
    let calls = LockIsolated<[(method: String, sid: String?)]>([])
    var initial = readyStateWithCatalog(composerText: "/compress")
    initial.liveSessionID = "stale-live"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        let sid = params["session_id"]?.stringValue
        calls.withValue { $0.append((method, sid)) }
        switch method {
        case "session.compress":
          if sid == "stale-live" { throw GatewayError.server("session not found") }
          return .object(["status": .string("compressed"), "removed": .number(2)])
        case "session.resume":
          // Serves both the #17 heal and the post-command refresh.
          return .object([
            "session_id": .string("fresh-live"),
            "stored_session_id": .string("stored123"),
            "messages": .array([]),
            "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.liveSessionIDRefreshed) {
      $0.liveSessionID = "fresh-live"
    }
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()

    // compress (stale) → heal-resume → single replay (fresh id) → post-command refresh.
    #expect(calls.value.map(\.method) == ["session.compress", "session.resume", "session.compress", "session.resume"])
    #expect(calls.value[2].sid == "fresh-live")
    #expect(store.state.errorBanner == nil)
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "Compressed 2 messages."))
  }

  @Test func hydrateMidExecKeepsTheComposerLocked() async {
    // A hydrate landing while the exec is in flight (`.foreground`, `.reattached`, a
    // reconnect `.ready`) reports `running == false` — an exec is NOT a turn. Taking that
    // verbatim would UNLOCK the composer mid-command and let a SECOND slash command be
    // submitted, whose state the first exec's terminal action would then tear down.
    // `slashExecInFlight` holds the lock until the exec's own terminal action clears it.
    let calls = LockIsolated<[String]>([])
    let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    var initial = readyStateWithCatalog()
    initial.status = .ready // `.foreground` hydrates a healthy socket instead of redialing
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        if method == "slash.exec" {
          for await _ in gate { break } // block until the hydrate has landed
          return .object(["output": .string("late output")])
        }
        return .object([
          "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
          "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
        ])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.isSending = true
      $0.slashExecInFlight = true
    }
    // A foreground hydrate lands mid-exec and reports an idle session.
    await store.send(.foreground)
    await store.receive(\.activateResult.success)
    #expect(store.state.isSending, "the composer must stay locked while the exec runs")
    #expect(store.state.canSend == false)

    gateContinuation.yield(())
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
      $0.slashExecInFlight = false
    }
    await store.finish()
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "late output"))
  }

  @Test func serverTurnStartedMidExecKeepsLockAndRunningState() async {
    // Cross-client race: another client starts a REAL turn (`message.start`) in this
    // session while our exec is in flight. The exec completion appends its row but must
    // NOT clobber the turn — no unlock, no client-side `runningChanged(false)` (the
    // delegate stays server-confirmed), and no runtime refresh mid-turn.
    let calls = LockIsolated<[String]>([])
    let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = TestClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        if method == "slash.exec" {
          // Block until the test releases the gate (after the server turn started).
          for await _ in gate { break }
          return .object(["output": .string("late output")])
        }
        return .object([:])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    // Another client's turn begins while the exec is still in flight.
    await store.send(.gatewayEvent(.messageStart))
    gateContinuation.yield(())

    await store.receive(\.slashCommandOutput)
    // The lock belongs to the streaming server turn now — the exec completion left it.
    #expect(store.state.isSending)

    // The server turn's own lifecycle unlocks; no session.resume refresh fired mid-turn.
    await store.send(.gatewayEvent(.messageComplete(text: "server answer", usage: nil)))
    #expect(store.state.isSending == false)
    await store.send(.teardown)
    await store.finish()
    #expect(calls.value == ["slash.exec"])
  }

  // MARK: command.dispatch fallback (Task 7)

  @Test func dispatchExecDirectiveRendersOutputRow() async {
    // `slash.exec` rejects the command → the pipeline falls back to
    // `command.dispatch {name, arg, session_id}`, whose `exec` directive's output renders
    // the same ephemeral commandOutput row (then the standard runtime-only refresh fires).
    let calls = LockIsolated<[String]>([])
    let dispatchParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/status verbose")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec":
          throw GatewayError.server("needs client dispatch")
        case "command.dispatch":
          dispatchParams.setValue(params)
          return .object(["type": .string("exec"), "output": .string("dispatched output")])
        case "session.resume":
          // The post-command refresh (usage present → no session.usage fallback).
          return .object([
            "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()

    // Exec → dispatch fallback → the output action's runtime refresh; the dispatch
    // carries the parsed name + arg (never the raw slashed text).
    #expect(calls.value == ["slash.exec", "command.dispatch", "session.resume"])
    #expect(dispatchParams.value?["name"]?.stringValue == "status")
    #expect(dispatchParams.value?["arg"]?.stringValue == "verbose")
    #expect(dispatchParams.value?["session_id"]?.stringValue == "live123")
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "dispatched output"))
    #expect(store.state.errorBanner == nil)
  }

  @Test func aliasDirectiveResolvesWithSingleHop() async {
    // "/fork main" is unknown to slash.exec; dispatch answers an `alias` directive → the
    // pipeline re-enters ONCE with "/branch main" (target + preserved arg) and the
    // target's exec output lands. No banner, composer unlocked.
    let calls = LockIsolated<[(method: String, command: String?)]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/fork main", extraCommands: ["/fork"])
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append((method, params["command"]?.stringValue)) }
        switch method {
        case "slash.exec":
          guard params["command"]?.stringValue == "branch main" else {
            throw GatewayError.server("unknown command")
          }
          return .object(["output": .string("branched")])
        case "command.dispatch":
          return .object(["type": .string("alias"), "target": .string("branch")])
        case "session.resume":
          return .object([
            "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()

    #expect(calls.value.map(\.method) == ["slash.exec", "command.dispatch", "slash.exec", "session.resume"])
    #expect(calls.value[2].command == "branch main")
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "branched"))
    #expect(store.state.errorBanner == nil)
  }

  @Test func doubleAliasHitsTheErrorPath() async {
    // Single hop only: a registry misconfigured with alias → alias must fail to the
    // error path after one re-entry — never loop (deliberate divergence from the web
    // reference's unbounded recursion).
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/fork", extraCommands: ["/fork"])
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec": throw GatewayError.server("unknown command")
        case "command.dispatch":
          return .object(["type": .string("alias"), "target": .string("other")])
        default: return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: /other: alias resolved to another alias (/other)"
      $0.isSending = false
    }
    await store.finish()

    // Exactly one hop: exec + dispatch for the typed command, exec + dispatch for the
    // alias target, then the hard stop — no third round.
    #expect(calls.value == ["slash.exec", "command.dispatch", "slash.exec", "command.dispatch"])
  }

  @Test func skillDirectiveSubmitsPromptWithExactlyOneUserRow() async {
    // "/deploy tidy the API" is a skill route: slash.exec rejects it, dispatch answers a
    // `skill` directive whose message goes through the NORMAL prompt.submit — with the
    // duplicate optimistic user row suppressed (the typed "/deploy …" row is already in
    // the transcript). isSending stays true: the turn streams via events like any prompt.
    let calls = LockIsolated<[String]>([])
    let submitParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/deploy tidy the API")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec":
          throw GatewayError.server("skill routes dispatch client-side")
        case "command.dispatch":
          return .object([
            "type": .string("skill"), "name": .string("deploy"),
            "message": .string("Use the deploy skill: tidy the API"),
          ])
        case "prompt.submit":
          submitParams.setValue(params)
          return .object(["status": .string("streaming")])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/deploy tidy the API", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
    }
    await store.finish()

    #expect(calls.value == ["slash.exec", "command.dispatch", "prompt.submit"])
    #expect(submitParams.value?["text"]?.stringValue == "Use the deploy skill: tidy the API")
    #expect(submitParams.value?["session_id"]?.stringValue == "live123")
    // Exactly one user row — the typed command; the directive's message is NOT echoed
    // and no output row appears (streaming/thinking will take over via events).
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "/deploy tidy the API", isComplete: true),
    ])
    #expect(store.state.isSending)
    #expect(store.state.errorBanner == nil)
  }

  @Test func malformedDirectiveFailsCleanly() async {
    // Lenient directive decode: an unknown `type` — and a skill payload missing its
    // message — are error surfaces (banner + unlocked composer), never a crash and
    // never a swallowed `try?`.
    let store = TestStore(initialState: readyStateWithCatalog()) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        switch method {
        case "slash.exec":
          throw GatewayError.server("nope")
        case "command.dispatch":
          guard params["name"]?.stringValue == "deploy" else {
            return .object(["type": .string("mystery")])
          }
          return .object(["type": .string("skill"), "name": .string("deploy")]) // no message
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: invalid response: command.dispatch"
      $0.isSending = false
    }

    await store.send(.binding(.set(\.composerText, "/deploy"))) {
      $0.composerText = "/deploy"
    }
    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: /deploy: skill payload missing message"
      $0.isSending = false
    }
    await store.finish()
  }

  // MARK: Directive-shaped slash.exec SUCCESS (server routes _PENDING_INPUT_COMMANDS
  // and skill bundles through command.dispatch INSIDE slash.exec and answers the typed
  // directive as the exec result — desktop parity: parse the directive FIRST)

  @Test func execSuccessCarryingExecDirectiveRendersOutputRow() async {
    // /retry & friends: the exec SUCCESS result IS the dispatch directive. Misreading it
    // as {output, warning} would render "/retry: no output" after the server already
    // truncated history — the directive must be routed.
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/retry", extraCommands: ["/retry"])
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec":
          return .object(["type": .string("exec"), "output": .string("retrying last exchange")])
        case "session.resume":
          return .object([
            "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput) {
      $0.isSending = false
    }
    await store.finish()
    // No command.dispatch roundtrip — the directive rode the exec success.
    #expect(calls.value == ["slash.exec", "session.resume"])
    #expect(store.state.transcript.last?.kind == .commandOutput(text: "retrying last exchange"))
    #expect(store.state.errorBanner == nil)
  }

  @Test func sendDirectiveOnExecSuccessRendersNoticeAndSubmitsPrompt() async {
    // /goal: the exec success answers {type:"send", notice, message}. The notice is the
    // backend's ONLY feedback for the state change — render it as an output row — and the
    // message goes through the normal prompt.submit with the duplicate optimistic user
    // row suppressed (the typed "/goal …" row is the one user row).
    let calls = LockIsolated<[String]>([])
    let submitParams = LockIsolated<JSONValue?>(nil)
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/goal ship the feature")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec":
          return .object([
            "type": .string("send"),
            "notice": .string("⊙ Goal set: ship the feature"),
            "message": .string("Work toward the goal: ship the feature"),
          ])
        case "prompt.submit":
          submitParams.setValue(params)
          return .object(["status": .string("streaming")])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/goal ship the feature", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
    }
    await store.receive(\.slashCommandNotice) {
      $0.transcript.append(
        ChatRow(id: self.uuid(1), kind: .commandOutput(text: "⊙ Goal set: ship the feature"))
      )
    }
    await store.finish()

    #expect(calls.value == ["slash.exec", "prompt.submit"])
    #expect(submitParams.value?["text"]?.stringValue == "Work toward the goal: ship the feature")
    // The notice did NOT unlock: the submitted turn streams via events like any prompt.
    #expect(store.state.isSending)
    // Exactly one user row (the typed command) + the notice row.
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "/goal ship the feature", isComplete: true),
      .commandOutput(text: "⊙ Goal set: ship the feature"),
    ])
    #expect(store.state.errorBanner == nil)
  }

  @Test func prefillDirectivePrefillsComposerAndDropsTheRewoundTurns() async {
    // /undo answers {type:"prefill", message, notice} AFTER rewinding history on disk
    // (`db.rewind_to_message`): the undone message lands in the composer for editing
    // (never auto-resubmitted) and the notice renders as the output row — silently
    // dropping either would leave a destructive server-side change with zero feedback.
    // The refresh is then SERVER-AUTHORITATIVE: the rewound turns must actually leave the
    // screen (a runtime-only refresh left them standing indefinitely — re-persisted into
    // the cache, so even a cold relaunch repainted them, and re-sending the prefill
    // produced a visually duplicated turn).
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/undo", extraCommands: ["/undo"])
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec":
          return .object([
            "type": .string("prefill"),
            "message": .string("my undone prompt"),
            "notice": .string("↶ Undid 1 turn (2 message(s)). Edit and resubmit, or send a new message."),
          ])
        case "session.resume":
          // The post-rewind history: the undone exchange is gone server-side.
          return .object([
            "session_id": .string("live123"),
            "messages": .array([
              .object(["id": .number(1), "role": .string("user"), "text": .string("kept turn")]),
            ]),
            "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/undo", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
      $0.slashExecInFlight = true
    }
    await store.receive(\.slashCommandPrefill) {
      $0.transcript.append(ChatRow(
        id: self.uuid(1),
        kind: .commandOutput(text: "↶ Undid 1 turn (2 message(s)). Edit and resubmit, or send a new message.")
      ))
      $0.composerText = "my undone prompt"
      $0.isSending = false
      $0.slashExecInFlight = false
    }
    await store.receive(\.slashHistoryRefreshed)
    await store.finish()

    // The undone message is edited, not auto-resubmitted — no prompt.submit.
    #expect(calls.value == ["slash.exec", "session.resume"])
    // Server wins: the transcript is the post-rewind history, the optimistic "/undo" echo
    // is gone, and only the ephemeral notice rides across the wholesale replace.
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "kept turn", isComplete: true),
      .commandOutput(text: "↶ Undid 1 turn (2 message(s)). Edit and resubmit, or send a new message."),
    ])
    #expect(store.state.errorBanner == nil)
  }

  @Test func skillDirectivePromptSubmitFailureSurfacesBannerAndUnlocks() async {
    // The directive's message is a real outbound RPC too: a prompt.submit failure after
    // a skill/send directive must surface the banner and unlock — never a locked
    // composer or a swallowed error.
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/deploy tidy")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec":
          throw GatewayError.server("skill routes dispatch client-side")
        case "command.dispatch":
          return .object([
            "type": .string("skill"), "name": .string("deploy"),
            "message": .string("Use the deploy skill: tidy"),
          ])
        case "prompt.submit":
          throw GatewayError.server("submit boom")
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: submit boom"
      $0.isSending = false
    }
    await store.finish()
    #expect(calls.value == ["slash.exec", "command.dispatch", "prompt.submit"])
  }

  @Test func sendDirectiveWithEmptyMessageFailsWithHonestWording() async {
    // The send-flavored empty-message wording (the skill flavor is covered by
    // malformedDirectiveFailsCleanly).
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/deploy")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        switch method {
        case "slash.exec":
          throw GatewayError.server("nope")
        case "command.dispatch":
          return .object(["type": .string("send"), "message": .string("   ")])
        default:
          return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: /deploy: empty message"
      $0.isSending = false
    }
    await store.finish()
  }

  // MARK: Backward-compat guard (Task 6)

  @Test func slashTextWithoutCatalogGoesThroughPlainPromptSubmit() async {
    // With a nil catalog (here: `commandsUnsupported` latched; a not-yet-fetched catalog
    // with `commandsUnsupported == false` behaves the same — the submit branch keys off
    // the catalog alone) "/status" is ordinary prompt text: one prompt.submit, no
    // slash.exec, isSending follows the normal turn lifecycle. Byte-identical to today.
    let calls = LockIsolated<[String]>([])
    let submitParams = LockIsolated<JSONValue?>(nil)
    var initial = ChatFeature.State(connection: conn)
    initial.liveSessionID = "live123"
    initial.storedSessionID = "stored123"
    initial.commandsUnsupported = true
    initial.composerText = "/status"
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, params in
        calls.withValue { $0.append(method) }
        if method == "prompt.submit" { submitParams.setValue(params) }
        return .object(["status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted) {
      $0.transcript = [
        ChatRow(id: self.uuid(0), kind: .message(role: .user, text: "/status", isComplete: true), timestamp: self.t0),
      ]
      $0.composerText = ""
      $0.isSending = true
    }
    await store.finish()

    #expect(calls.value == ["prompt.submit"])
    #expect(submitParams.value?["text"]?.stringValue == "/status")
    #expect(store.state.isSending) // the turn streams via events, not the RPC ack
    #expect(store.state.errorBanner == nil)
  }

  @Test func stagedAttachmentsForceThePlainPath() async {
    // Attachments always take the plain upload→submit path even when the text is a valid
    // slash command and the catalog is loaded — the exec pipeline has no attachment
    // semantics, and bytes must upload first.
    let calls = LockIsolated<[String]>([])
    var initial = readyStateWithCatalog()
    initial.attachments = [
      ComposerAttachment(
        id: uuid(99), kind: .image, filename: "a.png", mimeType: "image/png", data: Data([1])
      ),
    ]
    let store = TestStore(initialState: initial) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        return .object(["status": .string("streaming")])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.attachmentsSubmitted)
    await store.finish()

    #expect(calls.value == ["image.attach_bytes", "prompt.submit"])
    #expect(!calls.value.contains("slash.exec"))
  }

  // MARK: Codex review round (findings #1, #2, #5, #6, #9)

  @Test func canSendBlockedWhileSlashExecInFlight() async {
    // Finding #1: an interrupt tap or socket finalization can clear `isSending` while a
    // slash exec is still outstanding. `canSend` must ALSO gate on `slashExecInFlight`, or a
    // SECOND submission could slip through that window — and the first command's completion
    // (`finishSlashExec`) would then clear its state.
    var state = readyStateWithCatalog(composerText: "type something new")
    state.isSending = false        // an interrupt / socket finalization cleared it
    state.slashExecInFlight = true // ...but the exec is still running
    #expect(state.canSend == false)

    // Since #66, `composerSubmitted` in that window QUEUES the draft — still no RPC while
    // the exec holds the composer (the entry drains only after the exec's terminal action).
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        return .object([:])
      }
    }
    await store.send(.composerSubmitted) {
      $0.queuedPrompts = [QueuedPrompt(id: self.uuid(0), text: "type something new")]
      $0.composerText = ""
    }
    #expect(calls.value.isEmpty, "no RPC while a slash exec holds the composer")
  }

  @Test func typedHiddenOrUnknownCommandFallsThroughToPlainPrompt() async {
    // Finding #2: the submit gate execs ONLY commands the CURATED catalog resolves. A
    // manually-typed command absent from it — a hidden terminal-only / worker-isolated one
    // (`/new`, `/quit`, `/branch`, `/yolo`) or a genuine unknown — must NOT reach
    // `slash.exec`, where a hidden command runs in the isolated slash-worker subprocess and
    // reports FAKE success while this session is untouched. It falls through to a plain
    // `prompt.submit`, byte-identical to the old-agent / nil-catalog path (the LLM just sees
    // the literal text).
    // `/reasoning` stays on the hide-list deliberately (#81): the reasoning picker chip is the
    // mobile affordance, and the slash worker would not mirror the change onto this session.
    for command in ["/new", "/quit", "/branch retry", "/yolo", "/reasoning max", "/totallyunknown"] {
      let calls = LockIsolated<[String]>([])
      let submitText = LockIsolated<String?>(nil)
      let store = TestStore(
        initialState: readyStateWithCatalog(composerText: command)
      ) { ChatFeature() } withDependencies: {
        $0.uuid = .incrementing
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = ImmediateClock()
        $0.chatSnapshot = .inMemory()
        $0.hermesGateway.send = { @Sendable method, params in
          calls.withValue { $0.append(method) }
          if method == "prompt.submit" { submitText.setValue(params["text"]?.stringValue) }
          return .object(["status": .string("streaming")])
        }
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(.composerSubmitted)
      await store.finish()

      #expect(calls.value == ["prompt.submit"], "\(command) must take the plain path, never slash.exec")
      #expect(submitText.value == command, "the literal text is sent verbatim")
      #expect(store.state.slashExecInFlight == false)
      #expect(store.state.composerText == "")
    }
  }

  @Test func typedAliasStillResolvesAndExecs() async {
    // Finding #2 must not break aliases: "/st" is in the catalog's canonical map
    // ("/st" → "/status"), so it RESOLVES and execs through `slash.exec` (the server
    // resolves the alias), never plain `prompt.submit`.
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/st")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec": return .object(["output": .string("status ok")])
        case "session.resume":
          return .object([
            "session_id": .string("live123"), "messages": .array([]), "running": .bool(false),
            "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
          ])
        default: return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandOutput)
    await store.finish()
    #expect(calls.value.first == "slash.exec", "an aliased command still execs, not prompt.submit")
    #expect(!calls.value.contains("prompt.submit"))
  }

  @Test func staleRefreshAfterNewTurnStartedIsIgnored() async {
    // Finding #6: the post-command refresh's `session.resume` is async and the composer is
    // UNLOCKED for that window. If a NEW turn started meanwhile (`isSending == true`), the
    // response PREDATES it — applying it would wholesale-replace the transcript, wiping the
    // new turn's optimistic rows and resetting `isSending`. It must be a no-op.
    let stalePayload: JSONValue = .object([
      "session_id": .string("live123"),
      "messages": .array([
        .object(["id": .number(1), "role": .string("user"), "text": .string("stale server row")]),
      ]),
      "running": .bool(false),
      "info": .object(["model": .string("stale-model")]),
    ])
    let response = stalePayload.decoded(ActivateResponse.self)!

    var state = readyStateWithCatalog(composerText: "")
    state.isSending = true // a fresh prompt.submit started while the refresh was in flight
    state.transcript = [ChatRow(id: uuid(1), kind: .message(role: .user, text: "new turn prompt", isComplete: true))]
    let store = TestStore(initialState: state) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
    }

    // Full exhaustivity: the stale refresh must change NOTHING (no transcript replace, no
    // model swap, no isSending reset).
    await store.send(.slashHistoryRefreshed(response))
  }

  @Test func refreshCarriesOnlyTheLatestCommandOutputRow() async {
    // Finding #5: carrying EVERY historical `commandOutput` row across the wholesale replace
    // re-appended older outputs after the whole server transcript, out of chronological
    // order once more than one exec had run. Carry ONLY the just-produced (last) one.
    let historyPayload: JSONValue = .object([
      "session_id": .string("live123"),
      "messages": .array([
        .object(["id": .number(1), "role": .string("user"), "text": .string("server history")]),
      ]),
      "running": .bool(false),
      "info": .object(["usage": .object(["context_used": .number(1), "context_max": .number(200_000)])]),
    ])
    let response = historyPayload.decoded(ActivateResponse.self)!

    var state = readyStateWithCatalog(composerText: "")
    state.isSending = false
    state.slashExecInFlight = false
    state.transcript = [
      ChatRow(id: uuid(1), kind: .commandOutput(text: "first command output")),
      ChatRow(id: uuid(2), kind: .commandOutput(text: "second command output")),
    ]
    let store = TestStore(initialState: state) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.slashHistoryRefreshed(response))
    // Server history first, then ONLY the latest command output — the older one is dropped.
    #expect(store.state.transcript.map(\.kind) == [
      .message(role: .user, text: "server history", isComplete: true),
      .commandOutput(text: "second command output"),
    ])
  }

  @Test func originalSlashExecErrorSurvivesRoutingNoiseFallback() async {
    // Finding #9: when BOTH the exec and the `command.dispatch` fallback fail, and the
    // fallback only reports the routing-noise "not a quick/…/skill command" error, the
    // ORIGINAL `slash.exec` failure (a worker timeout/crash) is the real error and must be
    // surfaced — not buried under the routing noise (desktop parity, `slash.ts`).
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: readyStateWithCatalog(composerText: "/status")
    ) { ChatFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
      $0.chatSnapshot = .inMemory()
      $0.hermesGateway.send = { @Sendable method, _ in
        calls.withValue { $0.append(method) }
        switch method {
        case "slash.exec": throw GatewayError.server("slash worker crashed mid-run")
        case "command.dispatch": throw GatewayError.server("not a quick/plugin/bundle/skill command: status")
        default: return .object([:])
        }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.composerSubmitted)
    await store.receive(\.slashCommandFailed) {
      $0.errorBanner = "Command failed: slash worker crashed mid-run"
      $0.isSending = false
      $0.slashExecInFlight = false
    }
    await store.finish()
    // Both surfaces were tried; the informative original error won.
    #expect(calls.value == ["slash.exec", "command.dispatch"])
  }
}

/// Direct pins for the pure `parseSlashCommand` split (the web reference's `parseSlash`) —
/// the pipeline's `{name, arg}` contract for slash.exec fallbacks and directives.
struct ParseSlashCommandTests {
  @Test func splitsNameAndTrimmedArg() {
    #expect(parseSlashCommand("/status") == ("status", ""))
    #expect(parseSlashCommand("/steer focus on tests  ") == ("steer", "focus on tests"))
  }

  @Test func stripsAllLeadingSlashes() {
    #expect(parseSlashCommand("//status") == ("status", ""))
    #expect(parseSlashCommand("///x arg") == ("x", "arg"))
  }

  @Test func bareOrDegenerateSlashYieldsEmptyName() {
    // An empty name short-circuits the pipeline locally ("empty command") — no roundtrip.
    #expect(parseSlashCommand("/") == ("", ""))
    #expect(parseSlashCommand("/ trailing text") == ("", "trailing text"))
  }

  @Test func splitsOnAnyWhitespaceIncludingNewlines() {
    // Server/desktop parity: both `split(maxsplit=1)` on ANY whitespace, so tab and
    // newline separate the name and multiline args survive in the arg.
    #expect(parseSlashCommand("/steer\tfocus here") == ("steer", "focus here"))
    #expect(parseSlashCommand("/goal line one\nline two") == ("goal", "line one\nline two"))
  }
}
