import Foundation

extension HermesSessionDestination {
    /// Parses a server-qualified session link, `session?server=…&id=…[&profile=…]` (#1176), with
    /// the server normalized as the registry stores it. Nil for any other link, for one without a
    /// usable server or key, and for webui's legacy `session?id=`, which names no server and keeps
    /// its own route. A `profile` item without a value is `""`, the host's default Profile.
    init?(url: URL) {
        guard url.scheme?.lowercased() == HermesDeepLink.scheme.lowercased(),
              url.host?.lowercased() == HermesDeepLink.sessionHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let rawServer = items.first(where: { $0.name == "server" })?.value,
              let server = try? AuthManager.normalizedServerURL(from: rawServer),
              let key = HermesDeepLink.normalizedSessionID(items.first(where: { $0.name == "id" })?.value)
        else { return nil }
        let profile = items.first { $0.name == HermesDeepLink.profileQueryItem }
            .map { ($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let opensParent = items.contains { $0.name == HermesDeepLink.subagentQueryItem && $0.value == "1" }
        self.init(server: server, profile: profile, key: key, opensParent: opensParent)
    }
}

/// What the app does with one session link that names its server (#1176), decided before any
/// navigation so every outcome is testable without a view.
enum HermesSessionLinkOutcome: Equatable {
    /// The named server isn't configured: the app opens as it is.
    case ignore
    /// The named server is a webui server: the link is its push destination, which every legacy
    /// webui link becomes, so a moved server (#707) is redirected in that one place.
    case webui(WebuiPushDestination)
    /// Hold the link until the named server signs in, then resolve it again.
    case waitForSignIn(HermesSessionDestination)
    /// Make the named server active first; the rebuilt home takes the held link.
    case switchServer(ServerAccount, HermesSessionDestination)
    /// The named server is active and signed in: its Sessions list looks the session up.
    case open(HermesSessionDestination)
}

/// Routes a session link by the registry and auth state alone, as a Bot link is routed
/// (`BotDeepLinkRouter`). Nothing is read from, or signed in to, a server the link doesn't name:
/// another server, signed in or on its sign-in form, is switched away from first.
@MainActor enum HermesSessionLinkRouter {
    static func resolve(_ destination: HermesSessionDestination, state: AuthManager.State,
                        servers: [ServerAccount]) -> HermesSessionLinkOutcome {
        guard let account = servers.first(where: { $0.id == destination.server.absoluteString }) else { return .ignore }
        guard account.kind == .hermes else {
            return .webui(WebuiPushDestination(server: destination.server, sessionID: destination.key))
        }
        guard state.server == destination.server else { return .switchServer(account, destination) }
        if case .loggedIn = state { return .open(destination) }
        return .waitForSignIn(destination)
    }
}

/// Finds the stored session a Hermes session link names (#1176) on the server's saved
/// connection, and never guesses. A named Profile is one `GET /api/sessions/{id}` read; `""` is
/// the Profile `profiles.list` marks `is_default`; with none, every Profile is read at once, and
/// only a key exactly one of them has opens. The host answers an unknown key with the one session
/// it prefixes, so a row whose `id` isn't the link's key is no match. Any failed read fails the
/// lookup: a Profile that couldn't be read leaves the link unproven. A subagent's link
/// (`opensParent`) opens the session that delegated to the found one instead.
@MainActor enum HermesSessionLookup {
    enum Outcome: Equatable {
        /// The session as the Sessions list shows its row, which it opens the way that row does.
        case found(SessionSummary)
        /// No Profile looked in has the link's key.
        case gone
        /// More than one Profile has it, and the link didn't say which.
        case ambiguous
        /// A group room's session, which no screen opens (#1146).
        case room
    }

    /// How many parents a legacy compression chain is followed up toward its root.
    static let lineageHopLimit = 8

    static func resolve(_ destination: HermesSessionDestination, on wire: any BotTransport) async throws -> Outcome {
        let key = destination.key
        var hits: [(profile: String, row: BotJSON)] = []
        switch destination.profile {
        case let profile? where !profile.isEmpty:
            if let row = try await exactRow(key, profile: profile, on: wire) { hits.append((profile, row)) }
        case .some:
            guard let profile = try await profiles(on: wire).first(where: \.isDefault)?.name else { throw BotFailure.unsupported }
            if let row = try await exactRow(key, profile: profile, on: wire) { hits.append((profile, row)) }
        case nil:
            let reads = try await profiles(on: wire).map { profile in
                Task { (profile.name, try await exactRow(key, profile: profile.name, on: wire)) }
            }
            try await withTaskCancellationHandler {
                for read in reads {
                    let (profile, row) = try await read.value
                    if let row { hits.append((profile, row)) }
                }
            } onCancel: {
                reads.forEach { $0.cancel() }
            }
        }
        guard var hit = hits.first else { return .gone }
        guard hits.count == 1 else { return .ambiguous }
        // A subagent's push names the child; the user follows the session that delegated to it
        // (#1177): one hop up from the subagent's first segment, in the child's Profile, since a
        // subagent that compressed pushes from its newest. Every segment inherits the
        // `_delegate_from` `delegate_task` stamps, so the climb stops there even when the delegator
        // compressed too; a host without the mark climbs compression alone. A child naming no
        // parent opens itself.
        if destination.opensParent {
            let delegator = hit.row.modelConfigText("_delegate_from")
            let first = try await lineageRoot(of: hit.row, profile: hit.profile, on: wire) {
                $0.modelConfigText("_delegate_from") == delegator
            }
            if let parent = first["parent_session_id"].text, !parent.isEmpty {
                guard let row = try await exactRow(parent, profile: hit.profile, on: wire) else { return .gone }
                hit.row = row
            }
        }
        let row = try await listRow(hit.row, profile: hit.profile, on: wire)
        return row.isRoomSession ? .room : .found(row.summary(in: hit.profile))
    }

    /// `key`'s stored row under `profile`, nil when the host has no session with exactly that id.
    private static func exactRow(_ key: String, profile: String, on wire: any BotTransport) async throws -> BotJSON? {
        guard let row = try await wire.sessionRow(key: key, profile: profile), row["id"].text == key else { return nil }
        return row
    }

    private static func profiles(on wire: any BotTransport) async throws -> [(name: String, isDefault: Bool)] {
        guard let rows = try await wire.call(.profilesList(includeSessions: false))["profiles"].list else {
            throw BotFailure.unsupported
        }
        return rows.compactMap { row in
            guard let name = row["name"].text, !name.isEmpty else { return nil }
            return (name, row["is_default"].flag == true)
        }
    }

    /// The root of `found`'s legacy compression chain: reached by stepping up while the parent
    /// ended in compression and `belongs` accepts it, at most `lineageHopLimit` parents.
    private static func lineageRoot(of found: BotJSON, profile: String, on wire: any BotTransport,
                                    where belongs: (BotJSON) -> Bool = { _ in true }) async throws -> BotJSON {
        var top = found
        for _ in 0..<lineageHopLimit {
            guard let parent = top["parent_session_id"].text, !parent.isEmpty,
                  let row = try await exactRow(parent, profile: profile, on: wire),
                  row["end_reason"].text == "compression", belongs(row) else { break }
            top = row
        }
        return top
    }

    /// The found row as the host's list projects a legacy compression chain: identified under its
    /// `lineageRoot`. The chain keeps its root's `hidden` and start, and an untitled tip shows the
    /// root's title. The row stays the found one's, which the chat opens by.
    private static func listRow(_ found: BotJSON, profile: String, on wire: any BotTransport) async throws -> HermesSessionRow {
        let top = try await lineageRoot(of: found, profile: profile, on: wire)
        let own = try JSONDecoder().decode(HermesSessionRow.self, from: JSONEncoder().encode(found))
        guard top != found else { return own }
        let root = try JSONDecoder().decode(HermesSessionRow.self, from: JSONEncoder().encode(top))
        return HermesSessionRow(
            id: own.id, title: own.title ?? root.title, preview: own.preview, lastActive: own.lastActive,
            startedAt: root.startedAt ?? own.startedAt, pinned: own.pinned, archived: own.archived, unread: own.unread,
            hidden: root.hidden ?? own.hidden, model: own.model, cwd: own.cwd, messageCount: own.messageCount,
            profile: own.profile, parentSessionID: own.parentSessionID, lineageRootID: root.id
        )
    }
}
