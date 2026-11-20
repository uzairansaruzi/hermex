import Foundation

extension HermesSessionDestination {
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

enum HermesSessionLinkOutcome: Equatable {
    case ignore
    case webui(WebuiPushDestination)
    case waitForSignIn(HermesSessionDestination)
    case switchServer(ServerAccount, HermesSessionDestination)
    case open(HermesSessionDestination)
}

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

@MainActor enum HermesSessionLookup {
    enum Outcome: Equatable {
        case found(SessionSummary)
        case gone
        case ambiguous
        case room
    }

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
        if destination.opensParent {
            if let delegator = hit.row.modelConfigText("_delegate_from"), !delegator.isEmpty {
                guard let row = try await exactRow(delegator, profile: hit.profile, on: wire) else { return .gone }
                hit.row = row
            } else if let parent = hit.row["parent_session_id"].text, !parent.isEmpty {
                guard let row = try await exactRow(parent, profile: hit.profile, on: wire),
                      row["end_reason"].text != "compression" else { return .gone }
                hit.row = row
            }
        }
        let row = try await listRow(hit.row, profile: hit.profile, on: wire)
        return row.isRoomSession ? .room : .found(row.summary(in: hit.profile))
    }

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

    private static func lineageRoot(of found: BotJSON, profile: String, on wire: any BotTransport) async throws -> BotJSON? {
        var top = found
        var hops = 0
        while let parent = top["parent_session_id"].text, !parent.isEmpty,
              let row = try await exactRow(parent, profile: profile, on: wire),
              row["end_reason"].text == "compression" {
            guard hops < lineageHopLimit else { return nil }
            top = row
            hops += 1
        }
        return top
    }

    private static func listRow(_ found: BotJSON, profile: String, on wire: any BotTransport) async throws -> HermesSessionRow {
        let own = try JSONDecoder().decode(HermesSessionRow.self, from: JSONEncoder().encode(found))
        guard let top = try await lineageRoot(of: found, profile: profile, on: wire), top != found else { return own }
        let root = try JSONDecoder().decode(HermesSessionRow.self, from: JSONEncoder().encode(top))
        return HermesSessionRow(
            id: own.id, title: own.title ?? root.title, preview: own.preview, lastActive: own.lastActive,
            startedAt: root.startedAt ?? own.startedAt, pinned: own.pinned, archived: own.archived, unread: own.unread,
            hidden: root.hidden ?? own.hidden, model: own.model, cwd: own.cwd, messageCount: own.messageCount,
            profile: own.profile, parentSessionID: own.parentSessionID, lineageRootID: root.id
        )
    }
}
