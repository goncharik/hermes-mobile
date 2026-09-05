import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Which sessions to include when listing a profile's sessions via
/// `GET /api/profiles/sessions?archived=…`. The server accepts `exclude|include|only`;
/// mobile only needs `exclude` (active list) and `only` (the archived sheet).
public enum ProfileArchivedFilter: String, Sendable {
  /// Hide archived sessions — the normal list.
  case exclude
  /// Only archived sessions — the archived sheet.
  case only
}

/// All profile-scoped REST: profile CRUD + SOUL.md + the per-profile session list.
/// Kept separate from `HermesRESTClient` so that client stays focused on the
/// session/transcription surface. Reuses `HermesRESTClient`'s transport helpers
/// (`makeURL`/`get`/`postJSON`/`send`) so requests share one validation/decoding path.
///
/// A missing `/api/profiles` route surfaces as `RESTError.notFound` (404) so the caller
/// can gate the whole feature on capability.
@DependencyClient
public struct HermesProfileClient: Sendable {
  /// `GET /api/profiles` → `{ profiles: [ProfileInfo] }`.
  public var list: @Sendable (_ connection: ServerConnection) async throws -> [Profile]
  /// `POST /api/profiles` `{ name, clone_from_default }`. SOUL.md is a separate call.
  public var create: @Sendable (_ connection: ServerConnection, _ name: String, _ cloneFromDefault: Bool) async throws -> Void
  /// `PUT /api/profiles/{name}/soul` `{ content }` — sets the profile's SOUL.md.
  public var updateSoul: @Sendable (_ connection: ServerConnection, _ name: String, _ content: String) async throws -> Void
  /// `PATCH /api/profiles/{name}` `{ new_name }`.
  public var rename: @Sendable (_ connection: ServerConnection, _ name: String, _ newName: String) async throws -> Void
  /// `DELETE /api/profiles/{name}`.
  public var delete: @Sendable (_ connection: ServerConnection, _ name: String) async throws -> Void
  /// `GET /api/profiles/sessions?profile=&archived=&order=&limit=&offset=` →
  /// `{ sessions, profile_totals }` (we use only `sessions`).
  public var sessions: @Sendable (
    _ connection: ServerConnection,
    _ profile: String,
    _ archived: ProfileArchivedFilter,
    _ order: SessionOrder,
    _ limit: Int,
    _ offset: Int
  ) async throws -> [Session]
}

public extension HermesProfileClient {
  /// Live implementation over `URLSession` (injectable for `URLProtocol` stubs).
  /// `tokenStore` is injectable for the same reason `HermesRESTClient.live` takes one.
  static func live(
    session: URLSession = .shared,
    tokenStore: BearerTokenStore = .shared
  ) -> HermesProfileClient {
    // Same one-resolution-point rule as `HermesRESTClient.live`: profile REST is ordinary
    // `/api/*` traffic, so it authenticates through whichever regime the connection carries.
    let authFor: @Sendable (ServerConnection) async throws -> RequestAuth = { conn in
      try await resolveAuth(for: conn, session: session, tokenStore: tokenStore)
    }
    return HermesProfileClient(
      list: { conn in
        let url = try makeURL(conn.baseURL, "/api/profiles")
        let response: ProfilesResponse = try await get(url, auth: authFor(conn), session: session)
        return response.profiles
      },
      create: { conn, name, cloneFromDefault in
        let url = try makeURL(conn.baseURL, "/api/profiles")
        let body = try JSONSerialization.data(withJSONObject: [
          "name": name,
          "clone_from_default": cloneFromDefault,
        ] as [String: Any])
        try await send(url, method: "POST", body: body, auth: authFor(conn), session: session)
      },
      updateSoul: { conn, name, content in
        let url = try makeURL(conn.baseURL, "/api/profiles/\(name)/soul")
        let body = try JSONSerialization.data(withJSONObject: ["content": content])
        try await send(url, method: "PUT", body: body, auth: authFor(conn), session: session)
      },
      rename: { conn, name, newName in
        let url = try makeURL(conn.baseURL, "/api/profiles/\(name)")
        let body = try JSONSerialization.data(withJSONObject: ["new_name": newName])
        try await send(url, method: "PATCH", body: body, auth: authFor(conn), session: session)
      },
      delete: { conn, name in
        let url = try makeURL(conn.baseURL, "/api/profiles/\(name)")
        try await send(url, method: "DELETE", body: nil, auth: authFor(conn), session: session)
      },
      sessions: { conn, profile, archived, order, limit, offset in
        let url = try makeURL(conn.baseURL, "/api/profiles/sessions", query: [
          .init(name: "profile", value: profile),
          .init(name: "archived", value: archived.rawValue),
          .init(name: "order", value: order.rawValue),
          .init(name: "limit", value: String(limit)),
          .init(name: "offset", value: String(offset)),
        ])
        let response: ProfileSessionsResponse = try await get(
          url, auth: authFor(conn), session: session
        )
        return response.sessions.map(\.asSession)
      }
    )
  }

  /// Deterministic in-memory store for previews and tests — a single shared profile list
  /// (seeded with `default`) plus an in-memory SOUL.md map. Session lists are empty.
  static func inMemory() -> HermesProfileClient {
    let store = LockIsolated<[Profile]>([Profile(name: "default", isDefault: true)])
    let souls = LockIsolated<[String: String]>([:])
    return HermesProfileClient(
      list: { _ in store.value },
      create: { _, name, _ in
        store.withValue { profiles in
          guard !profiles.contains(where: { $0.name == name }) else { return }
          profiles.append(Profile(name: name))
        }
      },
      updateSoul: { _, name, content in souls.withValue { $0[name] = content } },
      rename: { _, name, newName in
        store.withValue { profiles in
          guard let idx = profiles.firstIndex(where: { $0.name == name }) else { return }
          profiles[idx].name = newName
        }
        souls.withValue { map in
          if let content = map.removeValue(forKey: name) { map[newName] = content }
        }
      },
      delete: { _, name in
        store.withValue { $0.removeAll { $0.name == name } }
        souls.withValue { $0[name] = nil }
      },
      sessions: { _, _, _, _, _, _ in [] }
    )
  }
}

extension HermesProfileClient: DependencyKey {
  public static var liveValue: HermesProfileClient { .live() }
  // Unimplemented by default — profile calls in tests must be stubbed explicitly.
  public static var testValue: HermesProfileClient { HermesProfileClient() }
}

public extension DependencyValues {
  var hermesProfiles: HermesProfileClient {
    get { self[HermesProfileClient.self] }
    set { self[HermesProfileClient.self] = newValue }
  }
}

// MARK: - DTOs

/// `GET /api/profiles` → `{ profiles: [ProfileInfo] }` (lenient — `Profile` tolerates
/// missing optional fields and never crashes).
private struct ProfilesResponse: Decodable {
  let profiles: [Profile]
}

/// `GET /api/profiles/sessions` → `{ sessions, profile_totals }`; reuses the same row
/// shape as `/api/sessions` (`SessionListDTO`). `profile_totals` is ignored for MVP.
private struct ProfileSessionsResponse: Decodable {
  let sessions: [SessionListDTO]
}
