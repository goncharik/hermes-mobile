import ComposableArchitecture
import Foundation

/// Phase 1 of Bot Mode support (see `docs/plans/YYYYMMDD-bot-mode-support.md`).
///
/// Surfaces the subset of Bot Mode that is "free" given the backend's actual design:
/// a Bot Mode Bot is nothing but a Hermes profile carrying a `ui_meta['hermes-bots']`
/// block, and its canonical "Bot Chat" is nothing but an ordinary session titled
/// exactly `"Bot Chat"` — the backend (`tools/bot_mode_probe.py`) injects the
/// messaging protocol into that session's system prompt automatically whenever any
/// profile on the install is Bot-Mode-managed. Mobile does not need to reimplement
/// any of that: it only needs to (a) know which profiles are bots, and (b) resolve-or-
/// create each one's "Bot Chat" session, exactly like the desktop plugin does via
/// `session.create title:"Bot Chat"` / the `session.list title:` exact-match lookup
/// (`tui_gateway/methods_session.py`, the `title_lookup` branch — the comment there
/// literally calls out "Bot Mode's canonical 'Bot Chat'" as the reason that lookup
/// exists).
///
/// Explicitly OUT of scope here (Phase 2 — see the skeleton in
/// `GroupChatFeature.swift` and the plan doc): group-chat rooms, @mention hand-off
/// orchestration, routines. Those have no server API to call — they are the desktop
/// plugin's own client-side orchestration and would need a from-scratch Swift port.
///
/// NOT YET VERIFIED against a live Bot-Mode-managed agent — in particular whether
/// `GET /api/profiles` forwards `ui_meta` the same way the `profiles.list` RPC does
/// (see `Profile.botMeta` doc comment). Written to compile and unit-test cleanly
/// against the documented/inferred contract; needs a real device + live agent pass
/// before merge.
@Reducer
public struct BotRosterFeature {
  @ObservableState
  public struct State: Equatable {
    public var connection: ServerConnection
    /// Every profile the agent reports (unfiltered) — kept around so a `botTapped`
    /// action can look up model/provider without a second round-trip.
    public var allProfiles: IdentifiedArrayOf<Profile>
    /// `allProfiles` filtered to `isBotManaged`, in server order. This is what the
    /// roster view renders. Empty (not an error state) on an install with no bots —
    /// the overwhelmingly common case; the view should render a "No Bots yet" empty
    /// state rather than nothing, matching the desktop's roster-with-New-Agent-button.
    public var bots: IdentifiedArrayOf<Profile> {
      IdentifiedArray(uniqueElements: allProfiles.filter(\.isBotManaged))
    }
    public var isLoading: Bool
    public var loadError: String?
    /// Whether the agent exposes `/api/profiles` at all — mirrors
    /// `SessionListFeature.State.profilesSupported`. When false the roster can't be
    /// shown (no way to enumerate bots), and the caller should hide the Bots tab
    /// entirely rather than show a permanent error.
    public var profilesSupported: Bool
    /// Name of the bot whose "Bot Chat" resolve-or-create round-trip is in flight —
    /// guards against a double-tap re-firing the RPC pair.
    public var resolvingBotName: String?

    public init(
      connection: ServerConnection,
      allProfiles: IdentifiedArrayOf<Profile> = [],
      isLoading: Bool = false,
      loadError: String? = nil,
      profilesSupported: Bool = true,
      resolvingBotName: String? = nil
    ) {
      self.connection = connection
      self.allProfiles = allProfiles
      self.isLoading = isLoading
      self.loadError = loadError
      self.profilesSupported = profilesSupported
      self.resolvingBotName = resolvingBotName
    }
  }

  public enum Action {
    case task
    case profilesResponse(Result<[Profile], RESTError>)
    case botTapped(name: String)
    /// The `session.list title:"Bot Chat"` lookup (scoped to the tapped bot's
    /// profile) resolved to an existing session, or found none (`nil` inside
    /// `.success`) meaning a fresh one must be created.
    case existingBotChatResolved(botName: String, Result<Session?, GatewayError>)
    /// `session.create profile:<bot> title:"Bot Chat"` completed for a bot that had
    /// no existing canonical chat.
    case botChatCreated(botName: String, Result<Session, GatewayError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      /// Open this bot's canonical Bot Chat — the parent (AppFeature-equivalent host)
      /// pushes a `ChatFeature` scoped to `profileName`, resuming `session`.
      case openBotChat(session: Session, profileName: String)
      case loadFailed(String)
    }
  }

  @Dependency(\.hermesProfiles) var profiles
  @Dependency(\.hermesGateway) var gateway

  /// The exact session title the backend gates the messaging-protocol injection on
  /// (`tools/bot_mode_probe.py::BOT_CHAT_TITLE`). Must stay byte-identical.
  public static let botChatTitle = "Bot Chat"

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.isLoading = true
        state.loadError = nil
        return .run { [profiles, connection = state.connection] send in
          do {
            let list = try await profiles.list(connection)
            await send(.profilesResponse(.success(list)))
          } catch let error as RESTError {
            await send(.profilesResponse(.failure(error)))
          } catch {
            await send(.profilesResponse(.failure(.unreachable)))
          }
        }

      case let .profilesResponse(.success(list)):
        state.isLoading = false
        state.loadError = nil
        state.profilesSupported = true
        state.allProfiles = IdentifiedArray(uniqueElements: list)
        return .none

      case let .profilesResponse(.failure(error)):
        state.isLoading = false
        // A 404 means the agent predates `/api/profiles` entirely — there is no way
        // to enumerate bots, so this isn't a transient error to bannner, it's a
        // capability gate (mirrors `SessionListFeature`'s `profilesSupported` flip).
        if error == .notFound {
          state.profilesSupported = false
          state.loadError = nil
        } else {
          state.loadError = error.message
        }
        return .none

      case let .botTapped(name):
        guard state.resolvingBotName == nil else { return .none } // in-flight guard
        state.resolvingBotName = name
        return .run { [gateway, botChatTitle = Self.botChatTitle] send in
          do {
            let result = try await gateway.send(
              "session.list",
              .object(["title": .string(botChatTitle), "profile": .string(name)])
            )
            let sessions = result["sessions"]?.arrayValue ?? []
            let existing = sessions.first.flatMap { row -> Session? in
              guard let id = row["id"]?.stringValue ?? row["resolved_id"]?.stringValue else { return nil }
              return Session(
                id: row["resolved_id"]?.stringValue ?? id,
                title: row["title"]?.stringValue,
                preview: row["preview"]?.stringValue,
                messageCount: row["message_count"]?.intValue,
                source: row["source"]?.stringValue
              )
            }
            await send(.existingBotChatResolved(botName: name, .success(existing)))
          } catch let error as GatewayError {
            await send(.existingBotChatResolved(botName: name, .failure(error)))
          } catch {
            await send(.existingBotChatResolved(botName: name, .failure(.server(String(describing: error)))))
          }
        }

      case let .existingBotChatResolved(botName, .success(.some(session))):
        state.resolvingBotName = nil
        return .send(.delegate(.openBotChat(session: session, profileName: botName)))

      case let .existingBotChatResolved(botName, .success(.none)):
        // No canonical chat yet for this bot — create it. This is the "introduces
        // itself as the first message of its new Bot Chat" moment on desktop; mobile
        // does not attempt to replay that greeting itself, it just opens an empty
        // chat and lets the bot's own system prompt (injected server-side) drive the
        // conversation once the user sends the first message.
        return .run { [gateway, botChatTitle = Self.botChatTitle] send in
          do {
            let result = try await gateway.send(
              "session.create",
              .object(["profile": .string(botName), "title": .string(botChatTitle)])
            )
            guard let handle = result.decoded(SessionHandle.self) else {
              await send(.botChatCreated(botName: botName, .failure(.server("Malformed session.create result"))))
              return
            }
            let session = Session(id: handle.storedSessionID ?? handle.sessionID, title: botChatTitle)
            await send(.botChatCreated(botName: botName, .success(session)))
          } catch let error as GatewayError {
            await send(.botChatCreated(botName: botName, .failure(error)))
          } catch {
            await send(.botChatCreated(botName: botName, .failure(.server(String(describing: error)))))
          }
        }

      case let .existingBotChatResolved(botName, .failure(error)):
        state.resolvingBotName = nil
        return .send(.delegate(.loadFailed("Couldn’t open \(botName)’s chat: \(error.message)")))

      case let .botChatCreated(botName, .success(session)):
        state.resolvingBotName = nil
        return .send(.delegate(.openBotChat(session: session, profileName: botName)))

      case let .botChatCreated(botName, .failure(error)):
        state.resolvingBotName = nil
        return .send(.delegate(.loadFailed("Couldn’t create \(botName)’s chat: \(error.message)")))

      case .delegate:
        return .none
      }
    }
  }
}
