import Foundation

/// Move to Hermes's commit point (#1215, part of #707): one acknowledged Keychain write that
/// adds or adopts the Hermes destination and records which webui server moved there.
///
/// The record lives on the destination's registry entry (`ServerAccount.movedWebuiServers`), so
/// it survives removing the webui entry, survives signing out of the destination, and goes when
/// the destination is removed: `removeServer` and `signOut` need nothing of their own for it.
/// The commit never switches the active server (the guided flow does that at Done, #1218) and
/// never reads or writes a push pairing: `MovePushPairing.carry` is the runner's first step
/// after it (#1216).
extension AuthManager {
    enum MoveCommitError: Error, Equatable {
        /// The source isn't a configured webui server.
        case sourceNotWebui
        /// The destination has the source's address. That host moved in place, which
        /// `replaceWebuiServer` handles (#1027).
        case sameAddress
        /// A webui server is configured at the destination's address.
        case destinationNotHermes
        /// The destination is configured but signed out, so the move couldn't run on it.
        case destinationSignedOut
        /// Another Hermes server already holds this webui server's record.
        case sourceAlreadyMoved(destinationID: String)
        /// No Profile was mapped, or one webui Profile was mapped twice.
        case invalidMapping
        /// No Hermes server holds a record for this webui server.
        case recordMissing
        /// The Keychain didn't save the change, so nothing was committed.
        case saveFailed
    }

    /// Commits a move of `source` to the Hermes server at `connection`'s address, with the
    /// Profile mappings chosen at Review, and returns the destination's entry.
    ///
    /// - A Hermes server already configured there is adopted: it gains the record, and its
    ///   own sign-in, name, initials, color, headers, preferences and pairing stay as they
    ///   are. `connection` is ignored, and the server must have a saved sign-in.
    /// - Otherwise a new Hermes server is added with `connection` as its sign-in and the
    ///   source's name, initials and color. Webui custom headers are never copied.
    ///
    /// Calling it again for a move this destination already holds returns the entry and
    /// changes nothing. When the Keychain refuses either write, it throws and leaves the
    /// registry and `servers` as they were, and puts back what was saved at a new server's
    /// address (`restoreSignIn`).
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

        // A new server's sign-in is saved before its entry, so a committed entry always has
        // one. If the entry isn't saved, whatever was saved at that address is put back.
        let previousSignIn = adopting ? nil : try? bots.load(server: destinationURL)
        if !adopting {
            do { try bots.save(connection, server: destinationURL) } catch { throw MoveCommitError.saveFailed }
        }

        let record = MovedWebuiServer(sourceServerID: source.id, profiles: profiles)
        let committed: ServerAccount
        do {
            committed = try serverRegistry.commit { servers, now in
                // Checked again under the registry's lock, against what it holds now.
                try Self.checkMove(of: source.id, to: destinationID, in: servers)
                if let index = servers.firstIndex(where: { $0.id == destinationID }) {
                    guard !servers[index].movedWebuiServers.contains(where: { $0.sourceServerID == source.id }) else {
                        return servers[index]
                    }
                    servers[index].movedWebuiServers.append(record)
                    servers[index].updatedAt = now
                    return servers[index]
                }
                // The source's identity as the registry holds it, not as a screen last read it.
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

    /// The Hermes server holding `sourceID`'s move record, with the record, or nil when
    /// that webui server never moved or its destination was removed.
    func moveRecord(forSource sourceID: String) -> (destination: ServerAccount, record: MovedWebuiServer)? {
        for server in servers {
            if let record = server.movedWebuiServers.first(where: { $0.sourceServerID == sourceID }) {
                return (server, record)
            }
        }
        return nil
    }

    /// Changes `sourceID`'s move record, such as its completion or report, with the same
    /// acknowledged write as the commit. Throws, changing nothing, when no Hermes server
    /// holds the record or the Keychain didn't save it. The record's source can't change.
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

    /// Why `sourceID` can't move to `destinationID` given `servers`, or nothing when it can.
    /// A record this destination already holds is not a conflict: the commit returns it.
    private static func checkMove(of sourceID: String, to destinationID: String, in servers: [ServerAccount]) throws {
        guard servers.contains(where: { $0.id == sourceID && $0.kind == .webui }) else {
            throw MoveCommitError.sourceNotWebui
        }
        // A webui id keeps its host's case and a Hermes address lowercases it, so compare them
        // the way a Hermes address is normalized.
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

    /// Puts back the sign-in saved at `server` before a failed commit wrote its own, or
    /// removes it when there was none. Best effort: `server` has no registry entry here, so
    /// whatever a failed rollback leaves is read by nothing, and adding the server later
    /// replaces it.
    private func restoreSignIn(_ previous: BotConnection?, at server: URL) {
        let bots = BotConnectionStore(keychain: keychain)
        if let previous {
            try? bots.save(previous, server: server)
        } else {
            try? bots.remove(server: server)
        }
    }
}
