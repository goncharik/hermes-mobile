import ComposableArchitecture
import Foundation
import Testing

@testable import HermesKit

/// Archive and Delete from the open chat's ⋯ menu: confirm first, hand the list's REST
/// contract (under the CHAT's profile) to the parent, close the chat only on the server's
/// acknowledgement.
@MainActor
struct ChatMenuArchiveDeleteTests {
  private let connection = ServerConnection(baseURL: URL(string: "http://mac.tailnet:9119")!, token: "tok")

  /// A resumed chat on a saved session, scoped to `profile`.
  private func savedChat(_ id: String = "s1", profile: String? = "work") -> ChatFeature.State {
    var chat = ChatFeature.State(connection: connection, resumeStoredID: id, profileName: profile)
    chat.liveSessionID = "live-\(id)"
    return chat
  }

  private struct Call: Equatable {
    let id: String
    let profile: String?
  }

  // MARK: ChatFeature

  /// The chat only confirms; the REST call is handed to the parent (`removeSession`) with
  /// the chat's OWN profile, so navigation can't cancel it with the slot's effects.
  @Test(arguments: [false, true])
  func confirmingHandsTheRemovalToTheParentUnderTheChatsProfile(isDelete: Bool) async {
    // No REST override: the chat itself must not call the server.
    let store = TestStore(initialState: savedChat()) { ChatFeature() }

    if isDelete {
      await store.send(.deleteButtonTapped) {
        $0.confirmationDialog = ConfirmationDialogState {
          TextState("Delete session?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDelete) { TextState("Delete") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("This permanently deletes the session and its history.")
        }
      }
      await store.send(.confirmationDialog(.presented(.confirmDelete))) {
        $0.confirmationDialog = nil
        $0.removingSessionID = "s1"
      }
    } else {
      await store.send(.archiveButtonTapped) {
        $0.confirmationDialog = ConfirmationDialogState {
          TextState("Archive session?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmArchive) { TextState("Archive") }
          ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
          TextState("This hides the session from the list. You can restore it from the server.")
        }
      }
      await store.send(.confirmationDialog(.presented(.confirmArchive))) {
        $0.confirmationDialog = nil
        $0.removingSessionID = "s1"
      }
    }
    await store.receive(\.delegate.removeSession, .init(
      kind: isDelete ? .delete : .archive, id: "s1", connection: connection, profileName: "work"
    ))
    // A second confirmation while in flight is inert.
    await store.send(.archiveButtonTapped)
    await store.send(.deleteButtonTapped)
  }

  @Test func cancellingTheConfirmationSendsNothing() async {
    let store = TestStore(initialState: savedChat()) { ChatFeature() }
    store.exhaustivity = .off
    await store.send(.deleteButtonTapped)
    await store.send(.confirmationDialog(.dismiss)) {
      $0.confirmationDialog = nil
    }
    // No REST override: an unimplemented call would fail the test.
  }

  @Test func archiveFailureKeepsTheChatOpenWithABanner() async {
    var chat = savedChat()
    chat.removingSessionID = "s1"
    let store = TestStore(initialState: chat) { ChatFeature() }
    await store.send(.archiveFailed(id: "s1", error: .unreachable)) {
      $0.removingSessionID = nil
      $0.errorBanner = "Couldn’t archive the session."
    }
  }

  @Test func deleteFailureKeepsTheChatOpenWithABannerAndTheCapability() async {
    var chat = savedChat()
    chat.removingSessionID = "s1"
    let store = TestStore(initialState: chat) { ChatFeature() }
    await store.send(.deleteFailed(id: "s1", error: .server(status: 500, detail: nil))) {
      $0.removingSessionID = nil
      $0.errorBanner = "Couldn’t delete the session."
    }
    #expect(store.state.deleteSupported)
  }

  /// 404 and 405 are both the missing-endpoint verdict: silent flip (no banner), Delete
  /// hides, and the chat stays open.
  @Test(arguments: [RESTError.notFound, .server(status: 405, detail: nil)])
  func deleteUnsupportedFlipsTheCapabilitySilently(error: RESTError) async {
    var chat = savedChat()
    chat.removingSessionID = "s1"
    let store = TestStore(initialState: chat) { ChatFeature() }
    await store.send(.deleteFailed(id: "s1", error: error)) {
      $0.removingSessionID = nil
      $0.deleteSupported = false
    }
    #expect(store.state.errorBanner == nil)
    // Once unsupported, Delete is inert.
    await store.send(.deleteButtonTapped)
    #expect(store.state.confirmationDialog == nil)
  }

  /// Archive has no capability flag (the list has none either): an agent without the PATCH
  /// answers like any other failure — banner, chat stays open.
  @Test func archiveUnsupportedEndpointSurfacesTheBanner() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: savedChat(profile: nil)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.hermesREST.archive = { @Sendable _, _, _, _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.liveChat(.archiveButtonTapped))
    await store.send(.liveChat(.confirmationDialog(.presented(.confirmArchive))))
    await store.receive(\.liveChat.archiveFailed)
    await store.finish()
    #expect(store.state.liveChat?.errorBanner == "Couldn’t archive the session.")
    #expect(store.state.home?.deleteSupported == true)
  }

  /// A never-saved new chat — before its handshake, and after it (a minted key with no
  /// server row until the first prompt) — has nothing to archive or delete.
  @Test func newChatOffersNeitherAction() async {
    var fresh = ChatFeature.State(connection: connection, profileName: "work")
    #expect(!fresh.canArchiveOrDelete)
    fresh.liveSessionID = "live"
    fresh.storedSessionID = "minted"
    fresh.awaitsFirstPersist = true
    #expect(!fresh.canArchiveOrDelete)

    let store = TestStore(initialState: fresh) { ChatFeature() }
    await store.send(.archiveButtonTapped)
    await store.send(.deleteButtonTapped)

    fresh.awaitsFirstPersist = false // the first prompt persisted the row
    #expect(fresh.canArchiveOrDelete)
  }

  // MARK: AppFeature

  /// Archive success from the chat: the slot is torn down (with the normal flush) only
  /// after the server acknowledged, and the list drops the row.
  @Test func chatArchiveSuccessTearsDownTheSlotAndDropsTheRow() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: savedChat(profile: nil)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.archiveButtonTapped))
    await store.send(.liveChat(.confirmationDialog(.presented(.confirmArchive))))
    await store.receive(\.liveChat.delegate.removeSession)
    #expect(store.state.liveChat != nil) // still open while the PATCH is in flight
    await store.receive(\.sessionRemovalFinished)
    await store.receive(\.liveChat.persistNow)
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.home.sessionRemovedElsewhere)
    await store.finish()
    #expect(store.state.home?.sessions[id: "s1"] == nil)
  }

  /// Delete success from the chat: snapshot wiped, teardown WITHOUT the flush (spied — a
  /// flush would re-save the deleted history), row and approval-badge entry dropped.
  @Test func chatDeleteSuccessWipesTheSnapshotAndSkipsTheFlush() async {
    let snapshots = ChatSnapshotClient.inMemory()
    snapshots.saveSnapshot("s1", ChatSnapshot(model: "gpt-5", rows: []))
    let writes = LockIsolated<[String]>([])
    var spy = snapshots
    spy.saveSnapshot = { @Sendable id, snapshot in
      writes.withValue { $0.append("save:\(id)") }
      snapshots.saveSnapshot(id, snapshot)
    }
    spy.setTurnAnchor = { @Sendable id, date in
      writes.withValue { $0.append("anchor:\(id)") }
      snapshots.setTurnAnchor(id, date)
    }
    var chat = savedChat(profile: nil)
    chat.isSending = true

    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat,
        pendingApprovalSessionIDs: ["s1"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = spy
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in }
      $0.push.setBadgeCount = { @Sendable _ in }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.deleteButtonTapped))
    await store.send(.liveChat(.confirmationDialog(.presented(.confirmDelete))))
    await store.receive(\.liveChat.delegate.removeSession)
    await store.receive(\.sessionRemovalFinished) {
      $0.pendingApprovalSessionIDs = []
    }
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.receive(\.home.sessionRemovedElsewhere)
    await store.finish()
    #expect(writes.value.isEmpty)
    #expect(snapshots.loadSnapshot("s1") == nil)
    #expect(store.state.home?.sessions[id: "s1"] == nil)
  }

  /// A failed archive or delete leaves the slot, the cached snapshot and the row alone.
  @Test(arguments: [false, true])
  func chatRemovalFailureLeavesEverythingInPlace(isDelete: Bool) async {
    let snapshots = ChatSnapshotClient.inMemory()
    snapshots.saveSnapshot("s1", ChatSnapshot(model: "gpt-5", rows: []))
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: savedChat(profile: nil)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = snapshots
      $0.hermesREST.archive = { @Sendable _, _, _, _ in throw RESTError.unreachable }
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw RESTError.unreachable }
    }
    store.exhaustivity = .off

    if isDelete {
      await store.send(.liveChat(.deleteButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmDelete))))
    } else {
      await store.send(.liveChat(.archiveButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmArchive))))
    }
    await store.skipReceivedActions()
    await store.finish()
    #expect(store.state.liveChat?.sessionKey == "s1")
    #expect(store.state.liveChat?.isRemovingSession == false)
    #expect(store.state.liveChat?.errorBanner != nil)
    #expect(snapshots.loadSnapshot("s1") != nil)
    #expect(store.state.home?.sessions[id: "s1"] != nil)
  }

  /// The sidebar switched to another profile while this chat stayed open: both actions
  /// still go to the CHAT's profile (`work`), never the list's (`default`), and success
  /// still closes the chat.
  @Test(arguments: [false, true])
  func chatRemovalAfterAProfileSwitchUsesTheChatsProfile(isDelete: Bool) async {
    let calls = LockIsolated<[Call]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          selectedProfileName: "default",
          profilesSupported: true
        ),
        liveChat: savedChat(profile: "work")
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.hermesREST.archive = { @Sendable _, id, _, profile in
        calls.withValue { $0.append(Call(id: id, profile: profile)) }
      }
      $0.hermesREST.deleteSession = { @Sendable _, id, profile in
        calls.withValue { $0.append(Call(id: id, profile: profile)) }
      }
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in [] }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    if isDelete {
      await store.send(.liveChat(.deleteButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmDelete))))
    } else {
      await store.send(.liveChat(.archiveButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmArchive))))
    }
    await store.skipReceivedActions()
    await store.finish()
    #expect(calls.value == [Call(id: "s1", profile: "work")])
    #expect(store.state.liveChat == nil)
  }

  /// One capability, both ways: the chat's 404/405 hides the list's Delete, and the list's
  /// verdict reaches the open chat (and a newly seated one).
  @Test func deleteCapabilityMirrorsBetweenChatAndList() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: savedChat(profile: nil)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in throw RESTError.server(status: 405, detail: nil) }
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.deleteButtonTapped))
    await store.send(.liveChat(.confirmationDialog(.presented(.confirmDelete))))
    await store.receive(\.sessionRemovalFinished)
    await store.receive(\.liveChat.deleteFailed)
    await store.finish()
    #expect(store.state.liveChat?.errorBanner == nil)
    #expect(store.state.home?.deleteSupported == false)
    #expect(store.state.liveChat?.deleteSupported == false)
    #expect(store.state.liveChat != nil)

    // List → chat: a capable verdict (e.g. a fresh home) re-enables it on the slot.
    await store.send(.home(.binding(.set(\.deleteSupported, true))))
    #expect(store.state.liveChat?.deleteSupported == true)
  }

  // MARK: Review regressions (#147)

  /// The user confirms, then leaves (opens another chat) before the server answers: the
  /// round-trip runs in the PARENT, so the confirmed removal is not cancelled with the old
  /// slot — its row/pin/seen, snapshot and badge cleanup still happen — and the new chat is
  /// left alone.
  @Test(arguments: [false, true])
  func confirmedRemovalSurvivesOpeningAnotherChat(isDelete: Bool) async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePinnedIDs(["s1", "b"])
    prefs.saveSeenCounts(["s1": 3, "b": 1])
    let snapshots = ChatSnapshotClient.inMemory()
    snapshots.saveSnapshot("s1", ChatSnapshot(model: "gpt-5", rows: []))
    let (gate, release) = AsyncStream<Void>.makeStream()
    let calls = LockIsolated<[Call]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(
          connection: connection,
          sessions: [Session(id: "s1"), Session(id: "b")],
          seenCounts: ["s1": 3, "b": 1],
          pinnedIDs: ["s1", "b"]
        ),
        liveChat: savedChat(profile: nil),
        pendingApprovalSessionIDs: ["s1"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.chatSnapshot = snapshots
      $0.hermesREST.archive = { @Sendable _, id, _, profile in
        for await _ in gate { break }
        calls.withValue { $0.append(Call(id: id, profile: profile)) }
      }
      $0.hermesREST.deleteSession = { @Sendable _, id, profile in
        for await _ in gate { break }
        calls.withValue { $0.append(Call(id: id, profile: profile)) }
      }
      $0.hermesREST.setUnread = { @Sendable _, _, _, _ in }
      $0.push.setBadgeCount = { @Sendable _ in }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    if isDelete {
      await store.send(.liveChat(.deleteButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmDelete))))
    } else {
      await store.send(.liveChat(.archiveButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmArchive))))
    }
    await store.receive(\.liveChat.delegate.removeSession)
    // Navigate away before the REST reply: another chat replaces the slot.
    await store.send(.home(.delegate(.openSession(Session(id: "other")))))
    await store.receive(\.fillLiveChat)
    #expect(store.state.liveChat?.sessionKey == "other")

    release.yield()
    await store.receive(\.sessionRemovalFinished)
    await store.finish()
    // Received-but-unasserted actions only fold into `store.state` once skipped.
    await store.skipReceivedActions(strict: false)
    #expect(calls.value == [Call(id: "s1", profile: nil)])
    #expect(store.state.home?.sessions.map(\.id) == ["b"])
    #expect(store.state.home?.pinnedIDs == ["b"])
    #expect(prefs.loadPinnedIDs() == ["b"])
    #expect(prefs.loadSeenCounts()["s1"] == nil)
    #expect(store.state.liveChat?.sessionKey == "other") // the replacement is untouched
    if isDelete {
      #expect(snapshots.loadSnapshot("s1") == nil)
      #expect(store.state.pendingApprovalSessionIDs.isEmpty)
    } else {
      #expect(snapshots.loadSnapshot("s1") != nil)
    }
  }

  /// A failure whose chat is gone lands on the list (it can't vanish): a banner, or for a
  /// 404/405 DELETE the silent capability flip.
  @Test func removalFailureAfterLeavingTheChatSurfacesOnTheList() async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")])
      )
    ) {
      AppFeature()
    }
    let removal = ChatFeature.Action.Delegate.SessionRemoval(
      kind: .delete, id: "s1", connection: connection, profileName: nil
    )
    await store.send(.sessionRemovalFinished(removal, failure: .unreachable)) {
      $0.home?.loadError = "Couldn’t delete the session."
    }
    await store.send(.sessionRemovalFinished(removal, failure: .notFound)) {
      $0.home?.deleteSupported = false
    }
  }

  /// The deleted chat's slot is torn down BEFORE the awaited badge update: a chat opened
  /// while `setBadgeCount` is still pending must survive when it completes.
  @Test func deleteTeardownDoesNotWaitForTheBadgeUpdate() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let badgeCalls = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: savedChat(profile: nil),
        pendingApprovalSessionIDs: ["s1"]
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.hermesREST.setUnread = { @Sendable _, _, _, _ in }
      // Only the removal's badge update parks (the open's own update must not share the
      // single-consumer stream).
      $0.push.setBadgeCount = { @Sendable _ in
        guard badgeCalls.withValue({ $0 += 1; return $0 }) == 1 else { return }
        for await _ in gate { break }
      }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let removal = ChatFeature.Action.Delegate.SessionRemoval(
      kind: .delete, id: "s1", connection: connection, profileName: nil
    )
    await store.send(.sessionRemovalFinished(removal, failure: nil))
    await store.receive(\.liveChat.teardown)
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    // Badge still pending; the user opens another chat in the gap.
    await store.send(.home(.delegate(.openSession(Session(id: "other")))))
    #expect(store.state.liveChat?.sessionKey == "other")
    release.yield()
    release.finish()
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.liveChat?.sessionKey == "other")
  }

  /// A removal that lands while the list is loading (or searching) restarts the fetch —
  /// and that reload must read the CLEANED pins/seen, not the stale persisted ones.
  @Test(arguments: [false, true])
  func removalDuringALoadPersistsPrefsBeforeTheReload(searching: Bool) async {
    let prefs = PreferencesClient.inMemory()
    prefs.savePinnedIDs(["s1", "b"])
    prefs.saveSeenCounts(["s1": 3, "b": 1])
    let store = TestStore(
      initialState: SessionListFeature.State(
        connection: connection,
        sessions: [Session(id: "s1"), Session(id: "b")],
        searchQuery: searching ? "query" : "",
        isLoading: !searching,
        seenCounts: ["s1": 3, "b": 1],
        pinnedIDs: ["s1", "b"]
      )
    ) {
      SessionListFeature()
    } withDependencies: {
      $0.preferences = prefs
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.hermesREST.sessions = { @Sendable _, _, _, _, _ in try await Task.never() }
      $0.hermesREST.search = { @Sendable _, _, _ in try await Task.never() }
      $0.hermesREST.cronJobs = { @Sendable _, _ in throw RESTError.notFound }
    }
    store.exhaustivity = .off

    await store.send(.sessionRemovedElsewhere(id: "s1"))
    #expect(store.state.isLoading) // the fetch was restarted, not just cancelled
    #expect(store.state.pinnedIDs == ["b"])
    #expect(store.state.seenCounts == ["b": 1])
    #expect(prefs.loadPinnedIDs() == ["b"])
    #expect(prefs.loadSeenCounts() == ["b": 1])
    await store.send(.onDisappear)
  }

  // MARK: Review regressions, round 2 (#147)

  /// iPhone: the chat on screen (its marker on the stack) is archived or deleted from its own
  /// menu — the marker must pop with the slot, or the stack shows an empty destination
  /// under a Back button.
  @Test(arguments: [false, true])
  func compactRemovalOfTheOnScreenChatPopsItsMarker(isDelete: Bool) async {
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "s1")]),
        liveChat: savedChat(profile: nil)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.hermesREST.archive = { @Sendable _, _, _, _ in }
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in }
      $0.push.setBadgeCount = { @Sendable _ in }
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    if isDelete {
      await store.send(.liveChat(.deleteButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmDelete))))
    } else {
      await store.send(.liveChat(.archiveButtonTapped))
      await store.send(.liveChat(.confirmationDialog(.presented(.confirmArchive))))
    }
    await store.receive(\.liveChat.delegate.removeSession)
    #expect(store.state.path.count == 1) // still on screen while the call is in flight
    await store.receive(\.sessionRemovalFinished) {
      $0.path = StackState()
    }
    await store.receive(\.clearLiveChat) {
      $0.liveChat = nil
    }
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.path.isEmpty)
    #expect(store.state.liveChat == nil)
    #expect(store.state.home?.sessions[id: "s1"] == nil)
  }

  /// A detached slot (compact, marker already popped) for ANOTHER session is left alone, and
  /// so is the path — only the removed session's chat closes.
  @Test func compactRemovalOfAnotherSessionLeavesTheStackAlone() async {
    var other = savedChat("other", profile: nil)
    other.liveSessionID = "live-other"
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        path: StackState([ChatScreen.State(sessionKey: "other")]),
        liveChat: other
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
    }
    store.exhaustivity = .off
    let removal = ChatFeature.Action.Delegate.SessionRemoval(
      kind: .archive, id: "s1", connection: connection, profileName: nil
    )
    await store.send(.sessionRemovalFinished(removal, failure: nil))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.path.count == 1)
    #expect(store.state.liveChat?.sessionKey == "other")
  }

  /// Logout while a removal is in flight: the effect is cancelled, so a late failure can't
  /// raise "Couldn’t delete the session." on the next account's list, and a 404/405 can't
  /// hide Delete there.
  @Test(arguments: [RESTError.unreachable, .notFound])
  func logoutCancelsAnInFlightRemoval(error: RESTError) async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: savedChat(profile: nil)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.preferences = .inMemory()
      $0.chatSnapshot = .inMemory()
      $0.push = PushClient.inMemory().client
      $0.hermesREST.deleteSession = { @Sendable _, _, _ in
        for await _ in gate { break }
        throw error
      }
    }
    store.exhaustivity = .off

    await store.send(.liveChat(.deleteButtonTapped))
    await store.send(.liveChat(.confirmationDialog(.presented(.confirmDelete))))
    await store.receive(\.liveChat.delegate.removeSession)
    await store.send(.home(.delegate(.disconnect)))
    // Sign in again (same server here — the worst case for a stale verdict).
    await store.send(.onboarding(.delegate(.connected(connection))))
    release.yield()
    release.finish()
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.home?.loadError == nil)
    #expect(store.state.home?.deleteSupported == true)
  }

  /// Belt and braces: a reply that still arrives for a server the app is no longer signed
  /// in to is dropped — no banner and no capability flip on the new server's list.
  @Test(arguments: [RESTError.unreachable, .notFound, .server(status: 405, detail: nil)])
  func removalReplyForAnotherServerIsDropped(error: RESTError) async {
    let otherServer = ServerConnection(baseURL: URL(string: "http://other.tailnet:9119")!, token: "t2")
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: otherServer, sessions: [Session(id: "s1")])
      )
    ) {
      AppFeature()
    }
    let removal = ChatFeature.Action.Delegate.SessionRemoval(
      kind: .delete, id: "s1", connection: connection, profileName: nil
    )
    await store.send(.sessionRemovalFinished(removal, failure: error))
    await store.send(.sessionRemovalFinished(removal, failure: nil))
    #expect(store.state.home?.loadError == nil)
    #expect(store.state.home?.deleteSupported == true)
    #expect(store.state.home?.sessions[id: "s1"] != nil)
  }

  /// The #17 heal recreated the session while the removal was in flight (`sessionKey`
  /// changed): the failure still goes back to the chat that asked, re-enabling its items,
  /// instead of landing on the list.
  @Test(arguments: [false, true])
  func removalFailureAfterAHealReachesTheChat(isDelete: Bool) async {
    var chat = savedChat(profile: nil)
    chat.removingSessionID = "s1"
    chat.storedSessionID = "healed" // the heal re-keyed the slot
    let store = TestStore(
      initialState: AppFeature.State(
        home: SessionListFeature.State(connection: connection, sessions: [Session(id: "s1")]),
        liveChat: chat
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off
    let removal = ChatFeature.Action.Delegate.SessionRemoval(
      kind: isDelete ? .delete : .archive, id: "s1", connection: connection, profileName: nil
    )
    await store.send(.sessionRemovalFinished(removal, failure: .unreachable))
    if isDelete {
      await store.receive(\.liveChat.deleteFailed)
    } else {
      await store.receive(\.liveChat.archiveFailed)
    }
    #expect(store.state.liveChat?.isRemovingSession == false)
    #expect(store.state.liveChat?.errorBanner != nil)
    #expect(store.state.home?.loadError == nil)
  }
}
