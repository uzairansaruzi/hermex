import Foundation

extension AuthManager {
    enum MoveCommitError: Error, Equatable {
        case sourceNotWebui
        case sameAddress
        case destinationNotHermes
        case destinationSignedOut
        case sourceAlreadyMoved(destinationID: String)
        case invalidMapping
        case recordMissing
        case saveFailed
    }

    @discardableResult
    func commitMove(from source: ServerAccount, to connection: BotConnection,
                    profiles: [MovedWebuiProfile]) throws -> ServerAccount {
        let destinationURL = (try? BotConnection.address(connection.address.absoluteString)) ?? connection.address
        let destinationID = destinationURL.absoluteString
        let sources = profiles.map(\.source)
        guard !sources.isEmpty, Set(sources).count == sources.count else { throw MoveCommitError.invalidMapping }

        let bots = BotConnectionStore(keychain: keychain)
        try Self.checkMove(of: source.id, to: destinationID, in: serverRegistry.servers)
        let existing = serverRegistry.servers.first { $0.id == destinationID }
        if let existing, existing.movedWebuiServers.contains(where: { $0.sourceServerID == source.id }) {
            return existing
        }
        let adopting = existing != nil
        if adopting {
            guard (try? bots.load(server: destinationURL)) != nil else { throw MoveCommitError.destinationSignedOut }
        }

        let previousSignIn = adopting ? nil : try? bots.load(server: destinationURL)
        if !adopting {
            do { try bots.save(connection, server: destinationURL) } catch { throw MoveCommitError.saveFailed }
        }

        let record = MovedWebuiServer(sourceServerID: source.id, profiles: profiles)
        let committed: ServerAccount
        do {
            committed = try serverRegistry.commit { servers, now in
                try Self.checkMove(of: source.id, to: destinationID, in: servers)
                if let index = servers.firstIndex(where: { $0.id == destinationID }) {
                    guard !servers[index].movedWebuiServers.contains(where: { $0.sourceServerID == source.id }) else {
                        return servers[index]
                    }
                    servers[index].movedWebuiServers.append(record)
                    servers[index].updatedAt = now
                    return servers[index]
                }
                let identity = servers.first { $0.id == source.id } ?? source
                let added = ServerAccount(
                    id: destinationID, urlString: destinationID,
                    displayName: identity.displayName, initials: identity.initials,
                    headerLogoColorHex: identity.headerLogoColorHex,
                    createdAt: now, updatedAt: now,
                    kind: .hermes, serverVersion: connection.hermesVersion,
                    movedWebuiServers: [record]
                )
                servers.append(added)
                return added
            }
        } catch {
            if !adopting { restoreSignIn(previousSignIn, at: destinationURL) }
            throw (error as? MoveCommitError) ?? .saveFailed
        }
        refreshServers()
        return committed
    }

    func moveRecord(forSource sourceID: String) -> (destination: ServerAccount, record: MovedWebuiServer)? {
        for server in servers {
            if let record = server.movedWebuiServers.first(where: { $0.sourceServerID == sourceID }) {
                return (server, record)
            }
        }
        return nil
    }

    func updateMoveRecord(forSource sourceID: String, _ change: (inout MovedWebuiServer) -> Void) throws {
        do {
            try serverRegistry.commit { servers, now in
                guard let index = servers.firstIndex(where: { $0.movedWebuiServers.contains { $0.sourceServerID == sourceID } }),
                      let recordIndex = servers[index].movedWebuiServers.firstIndex(where: { $0.sourceServerID == sourceID })
                else { throw MoveCommitError.recordMissing }
                change(&servers[index].movedWebuiServers[recordIndex])
                servers[index].updatedAt = now
            }
        } catch {
            throw (error as? MoveCommitError) ?? .saveFailed
        }
        refreshServers()
    }

    var isMoveQuestionDue: Bool { dueMoveQuestionSource != nil }

    func askAboutMoveIfDue() {
        guard let source = dueMoveQuestionSource, let sourceURL = URL(string: source.id) else { return }
        askedAboutMoveThisLaunch = true
        let hasBotsSignIn = (try? BotConnectionStore(keychain: keychain).load(server: sourceURL)) != nil
        noteMovePrompt(.asked, forSource: source.id)
        moveQuestion = MoveToHermesQuestion(sourceID: source.id, hasBotsSignIn: hasBotsSignIn)
    }

    private var dueMoveQuestionSource: ServerAccount? {
        guard !askedAboutMoveThisLaunch, moveOffer == nil, moveQuestion == nil, case .loggedIn = state,
              let active = activeServer, active.kind == .webui, active.moveToHermesPrompt == nil,
              !removingServerIDs.contains(active.id), moveRecord(forSource: active.id) == nil
        else { return nil }
        return active
    }

    func showsMoveInvite(for serverID: String) -> Bool {
        guard let server = servers.first(where: { $0.id == serverID }), server.kind == .webui,
              server.moveToHermesPrompt == .asked else { return false }
        return moveRecord(forSource: serverID) == nil
    }

    func noteMovePrompt(_ prompt: MoveToHermesPrompt, forSource sourceID: String) {
        guard let server = servers.first(where: { $0.id == sourceID && $0.kind == .webui }),
              server.moveToHermesPrompt != prompt, server.moveToHermesPrompt != .dismissed else { return }
        try? serverRegistry.commit { servers, _ in
            guard let index = servers.firstIndex(where: { $0.id == sourceID }) else { return }
            servers[index].moveToHermesPrompt = prompt
        }
        refreshServers()
    }

    private static func checkMove(of sourceID: String, to destinationID: String, in servers: [ServerAccount]) throws {
        guard servers.contains(where: { $0.id == sourceID && $0.kind == .webui }) else {
            throw MoveCommitError.sourceNotWebui
        }
        func asHermesAddress(_ id: String) -> String { (try? BotConnection.address(id))?.absoluteString ?? id }
        guard asHermesAddress(sourceID) != destinationID else { throw MoveCommitError.sameAddress }
        if servers.contains(where: { $0.kind != .hermes && asHermesAddress($0.id) == destinationID }) {
            throw MoveCommitError.destinationNotHermes
        }
        if let holder = servers.first(where: { server in
            server.id != destinationID && server.movedWebuiServers.contains { $0.sourceServerID == sourceID }
        }) {
            throw MoveCommitError.sourceAlreadyMoved(destinationID: holder.id)
        }
    }

    private func restoreSignIn(_ previous: BotConnection?, at server: URL) {
        let bots = BotConnectionStore(keychain: keychain)
        if let previous {
            try? bots.save(previous, server: server)
        } else {
            try? bots.remove(server: server)
        }
    }
}
