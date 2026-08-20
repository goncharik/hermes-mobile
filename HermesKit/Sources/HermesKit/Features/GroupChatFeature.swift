import ComposableArchitecture
import Foundation

// MARK: - Phase 2 — Group Chat Rooms (SKELETON, NOT FUNCTIONAL)
//
// This file is a planning skeleton, not a working feature. It exists to make the
// scope of Phase 2 concrete — the types a real implementation would need and the
// exact points where it must replicate desktop-plugin behavior — WITHOUT claiming
// to be tested or working code. Every method below either does nothing or returns a
// placeholder; none of it is wired into any view or the app's dependency graph.
//
// Read `docs/plans/YYYYMMDD-bot-mode-support.md` (Phase 2 section) before touching
// this. Do not enable/wire this feature until that plan's open questions are
// resolved and the round-robin logic below is actually implemented and tested.
//
// ── Why this is hard (see the investigation on GitHub issue #76) ──────────────────
//
// Unlike Phase 1's canonical "Bot Chat" (a plain session the backend auto-decorates),
// a group-chat "room" has NO server-side concept at all. On desktop
// (`apps/desktop/src/plugins/hermes-bots/plugin.js`) a room is:
//
//   1. N ordinary sessions, one per member, each titled `"Group: <name>"` and created
//      with `session.create hidden:true` (the generic hidden-session flag — NOT a
//      Bot-Mode-specific mechanism) so they don't clutter the normal session list.
//   2. Browsed via `session.list include_hidden:true`.
//   3. Orchestrated ENTIRELY client-side: the plugin decides who replies to a
//      message, fires `hermes -p <bot> chat -c "Group: <name>" ...` sequentially per
//      responding member, waits for each reply, and stitches results into one shared
//      transcript view. There is no "post to room" RPC — every member turn is an
//      independent, ordinary agent invocation against that member's own hidden
//      session.
//
// Porting this to Swift means reimplementing, from scratch, in HermesKit:
//
//   - Room membership model + per-member hidden-session bookkeeping (member name →
//     that room's session id, created lazily on first message like `session.create`
//     already works for a 1:1 chat).
//   - The turn-taking policy: up to 3 serial rounds, @mention resolution (does the
//     message mention specific members, or does "everyone" reply), each member
//     independently deciding to reply-or-pass (this is a property of THAT member's
//     own agent turn, not something the orchestrator can predict — the orchestrator
//     just has to run the turn and see what comes back), and the "settle" condition
//     (a full round with everyone silent ends the exchange).
//   - Hard caps mirrored exactly from desktop (10 messages/send, 3 rounds) so a
//     misbehaving room can't spin forever burning API calls on a phone's data plan.
//   - A merged, chronologically-interleaved transcript view across N member
//     sessions — none of `ChatFeature`'s single-session transcript machinery
//     (`CollectionTranscriptView`, deterministic row ids, streaming fold) was built
//     for "N sessions rendered as one room," so this is a materially different
//     rendering problem, not a reuse of the existing chat UI.
//   - Cross-machine rooms (desktop's "Rooms can span machines") are explicitly
//     OUT OF SCOPE for a first mobile pass — Connections/multi-gateway support
//     doesn't exist on mobile at all yet.
//
// None of the above is an API integration problem. It is a genuine feature build on
// the order of the original `ChatFeature`, and should be scoped/estimated as such —
// this skeleton's job is only to make that legible, not to shortcut it.

/// Placeholder domain type for a group-chat room. Field set is a best-effort sketch,
/// NOT a verified contract — there is no server-side "room" object to decode this
/// from (see file header). A real implementation likely derives this client-side from
/// the set of hidden `"Group: <name>"` sessions each member profile owns, rather than
/// fetching it as one object from anywhere.
public struct GroupChatRoom: Equatable, Sendable, Identifiable {
  public var id: String { name }
  public var name: String
  /// Profile names of the members seated in this room.
  public var memberNames: [String]

  public init(name: String, memberNames: [String]) {
    self.name = name
    self.memberNames = memberNames
  }
}

/// Placeholder reducer. Intentionally minimal: `task` does nothing, and there is no
/// send/round-orchestration action at all yet — adding one prematurely would just be
/// unverified surface area. A real implementation needs, at minimum, the turn-taking
/// state machine described in the file header before this type is useful for anything.
@Reducer
public struct GroupChatFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    public var room: GroupChatRoom

    public init(connection: ServerConnection, room: GroupChatRoom) {
      self.connection = connection
      self.room = room
    }
  }

  public enum Action {
    case task
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { _, action in
      switch action {
      case .task:
        // TODO(Phase 2): enumerate this room's per-member hidden sessions via
        // `session.list include_hidden:true` filtered to `"Group: \(room.name)"`,
        // merge their histories into one interleaved transcript, and establish
        // whatever live-update mechanism keeps it current while multiple member
        // turns may be running concurrently. None of this exists yet.
        return .none
      }
    }
  }
}
