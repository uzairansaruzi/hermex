import UserNotifications
import XCTest
@testable import HermesMobile

/// Move to Hermes's commit point and pairing carry (#1215): the destination's record, its
/// acknowledged save, removal of either server, and when a push pairing is copied.
@MainActor
final class MoveToHermesCommitTests: XCTestCase {
    private let source = URL(string: "https://a.test")!
    private let destination = URL(string: "https://hermes.example")!
    private let mappings = [
        MovedWebuiProfile(source: "default", destination: .hermes(profile: "default")),
        MovedWebuiProfile(source: "work", destination: .keepOnWebui),
    ]

    // MARK: - Commit

    func testCommitAddsTheDestinationWithTheSourcesIdentityAndStaysOnTheSource() throws {
        let (manager, keychain) = try makeManager()
        let staleSource = try XCTUnwrap(manager.activeServer)
        manager.updateServerIdentity(staleSource, displayName: "Studio", initials: "ST", headerLogoColorHex: "#123456")

        // The copy a screen read before the edit still gets the edited identity.
        let committed = try manager.commitMove(from: staleSource, to: connection(), profiles: mappings)

        XCTAssertEqual(committed.id, destination.absoluteString)
        XCTAssertEqual(committed.kind, .hermes)
        XCTAssertEqual([committed.displayName, committed.initials, committed.headerLogoColorHex], ["Studio", "ST", "#123456"])
        XCTAssertEqual(committed.serverVersion, "0.21.5")
        XCTAssertEqual(committed.movedWebuiServers, [MovedWebuiServer(sourceServerID: source.absoluteString, profiles: mappings)])
        XCTAssertEqual(manager.servers.map(\.id), [source.absoluteString, destination.absoluteString])
        XCTAssertEqual(manager.state, .loggedIn(server: source), "The commit never switches servers")
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: destination)?.username, "me")
        XCTAssertNil(keychain.scopedValue(.customHeaders, scope: destination.absoluteString), "Webui headers stay behind")
        XCTAssertEqual(reloaded(keychain).first { $0.id == destination.absoluteString }, committed)
    }

    func testAFailedSaveCommitsNothingAndPutsTheSignInBack() throws {
        let (manager, keychain) = try makeManager()
        let before = manager.servers
        let orphan = BotConnection(id: UUID(), name: "Old", address: destination, username: "old", password: "old")
        try BotConnectionStore(keychain: keychain).save(orphan, server: destination)

        keychain.failingKeys = [.servers]
        XCTAssertThrowsError(try manager.commitMove(from: try XCTUnwrap(manager.activeServer), to: connection(), profiles: mappings)) {
            XCTAssertEqual($0 as? AuthManager.MoveCommitError, .saveFailed)
        }
        XCTAssertEqual(manager.servers, before)
        XCTAssertEqual(reloaded(keychain), before)
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: destination), orphan)

        // A sign-in that can't be saved stops the commit before the registry is written.
        keychain.failingKeys = [.botConnection]
        XCTAssertThrowsError(try manager.commitMove(from: try XCTUnwrap(manager.activeServer), to: connection(), profiles: mappings)) {
            XCTAssertEqual($0 as? AuthManager.MoveCommitError, .saveFailed)
        }
        keychain.failingKeys = []
        XCTAssertEqual(reloaded(keychain), before)
    }

    func testAdoptingKeepsTheDestinationsOwnSignInIdentityAndActiveServer() throws {
        let (manager, keychain) = try makeManager()
        let sourceAccount = try XCTUnwrap(manager.activeServer)
        XCTAssertTrue(manager.addHermesServer(connection()))
        let adopted = try XCTUnwrap(manager.activeServer)
        manager.updateServerIdentity(adopted, displayName: "Mine", initials: "MI", headerLogoColorHex: "#654321")

        let committed = try manager.commitMove(from: sourceAccount, to: connection(password: "other"), profiles: mappings)

        XCTAssertEqual([committed.displayName, committed.initials, committed.headerLogoColorHex], ["Mine", "MI", "#654321"])
        XCTAssertEqual(committed.movedWebuiServers.map(\.sourceServerID), [source.absoluteString])
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: destination)?.password, "secret")
        XCTAssertEqual(manager.state, .loggedIn(server: destination))

        // A failed save leaves the adopted server as it was, sign-in included.
        let otherSource = try addWebui(manager, "https://b.test")
        keychain.failingKeys = [.servers]
        XCTAssertThrowsError(try manager.commitMove(from: otherSource, to: connection(), profiles: mappings))
        XCTAssertEqual(manager.servers.first { $0.id == destination.absoluteString }, committed)
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: destination)?.password, "secret")
    }

    func testOneWebuiServerMovesToOneDestinationAndARepeatChangesNothing() throws {
        let (manager, _) = try makeManager()
        let sourceAccount = try XCTUnwrap(manager.activeServer)
        let first = try manager.commitMove(from: sourceAccount, to: connection(), profiles: mappings)

        let again = try manager.commitMove(from: sourceAccount, to: connection(), profiles: [mappings[0]])
        XCTAssertEqual(again, first)

        let other = BotConnection(id: UUID(), name: "Other", address: URL(string: "https://other.example")!, username: "me", password: "p")
        XCTAssertThrowsError(try manager.commitMove(from: sourceAccount, to: other, profiles: mappings)) {
            XCTAssertEqual($0 as? AuthManager.MoveCommitError, .sourceAlreadyMoved(destinationID: destination.absoluteString))
        }
        XCTAssertEqual(manager.servers.count, 2)
    }

    func testTheCommitRefusesWhatItCannotRecord() throws {
        let (manager, keychain) = try makeManager()
        let sourceAccount = try XCTUnwrap(manager.activeServer)
        let webuiDestination = try addWebui(manager, "https://b.test")
        XCTAssertTrue(manager.addHermesServer(connection()))
        let hermes = try XCTUnwrap(manager.activeServer)
        func refusal(_ from: ServerAccount, _ to: BotConnection, _ profiles: [MovedWebuiProfile]) -> AuthManager.MoveCommitError? {
            do { try manager.commitMove(from: from, to: to, profiles: profiles); return nil } catch {
                return error as? AuthManager.MoveCommitError
            }
        }
        let sameAddress = BotConnection(id: UUID(), name: "Same", address: source, username: "me", password: "p")
        let atWebui = BotConnection(id: UUID(), name: "B", address: URL(string: webuiDestination.urlString)!, username: "me", password: "p")

        XCTAssertEqual(refusal(sourceAccount, sameAddress, mappings), .sameAddress)
        // A webui id keeps its host's case; a Hermes address is lowercased.
        let mixedCase = try addWebui(manager, "https://Studio.Example")
        let lowercased = BotConnection(id: UUID(), name: "S", address: URL(string: "https://studio.example")!, username: "me", password: "p")
        XCTAssertEqual(refusal(mixedCase, lowercased, mappings), .sameAddress)
        XCTAssertEqual(refusal(sourceAccount, lowercased, mappings), .destinationNotHermes,
                       "A webui server saved with capitals still holds the address")
        XCTAssertEqual(refusal(sourceAccount, atWebui, mappings), .destinationNotHermes)
        XCTAssertEqual(refusal(hermes, connection(), mappings), .sourceNotWebui)
        XCTAssertEqual(refusal(sourceAccount, connection(), []), .invalidMapping)
        XCTAssertEqual(refusal(sourceAccount, connection(), [mappings[0], mappings[0]]), .invalidMapping)
        try BotConnectionStore(keychain: keychain).remove(server: destination)
        XCTAssertEqual(refusal(sourceAccount, connection(), mappings), .destinationSignedOut)
        XCTAssertTrue(manager.servers.allSatisfy { $0.movedWebuiServers.isEmpty })
    }

    func testAnIdentityEditFromAnOlderCopyKeepsTheRecord() throws {
        let (manager, keychain) = try makeManager()
        let sourceAccount = try XCTUnwrap(manager.activeServer)
        XCTAssertTrue(manager.addHermesServer(connection()))
        let staleCopy = try XCTUnwrap(manager.activeServer)
        try manager.commitMove(from: sourceAccount, to: connection(), profiles: mappings)

        manager.updateServerIdentity(staleCopy, displayName: "Renamed", initials: "RE", headerLogoColorHex: "#000000")

        let stored = try XCTUnwrap(reloaded(keychain).first { $0.id == destination.absoluteString })
        XCTAssertEqual(stored.displayName, "Renamed")
        XCTAssertEqual(stored.movedWebuiServers.map(\.sourceServerID), [source.absoluteString])
    }

    func testTheRecordOutlivesTheSourceAndSignOutAndGoesWithTheDestination() async throws {
        let (manager, keychain) = try makeManager()
        let sourceAccount = try XCTUnwrap(manager.activeServer)
        try manager.commitMove(from: sourceAccount, to: connection(), profiles: mappings)

        await manager.removeServer(sourceAccount)
        XCTAssertEqual(manager.moveRecord(forSource: source.absoluteString)?.destination.id, destination.absoluteString)
        XCTAssertEqual(manager.state, .loggedIn(server: destination))

        await manager.signOut()
        XCTAssertEqual(manager.state, .loggedOut(server: destination))
        XCTAssertEqual(manager.moveRecord(forSource: source.absoluteString)?.record.profiles, mappings)

        await manager.removeServer(try XCTUnwrap(manager.servers.first))
        XCTAssertNil(manager.moveRecord(forSource: source.absoluteString))
        XCTAssertTrue(reloaded(keychain).isEmpty)
    }

    func testRecordUpdatesAreAcknowledged() throws {
        let (manager, keychain) = try makeManager()
        try manager.commitMove(from: try XCTUnwrap(manager.activeServer), to: connection(), profiles: mappings)
        let done = Date(timeIntervalSince1970: 1_000)
        let report = MovedWebuiReport(remaining: 3, unchecked: nil, oversized: 1, recordedAt: done)

        try manager.updateMoveRecord(forSource: source.absoluteString) { $0.completedAt = done; $0.report = report }
        let stored = try XCTUnwrap(reloaded(keychain).first { $0.id == destination.absoluteString }?.movedWebuiServers.first)
        XCTAssertEqual(stored.completedAt, done)
        XCTAssertEqual(stored.report, report)

        keychain.failingKeys = [.servers]
        XCTAssertThrowsError(try manager.updateMoveRecord(forSource: source.absoluteString) { $0.report = nil }) {
            XCTAssertEqual($0 as? AuthManager.MoveCommitError, .saveFailed)
        }
        XCTAssertEqual(manager.moveRecord(forSource: source.absoluteString)?.record.report, report)
        XCTAssertThrowsError(try manager.updateMoveRecord(forSource: "https://never.test") { _ in }) {
            XCTAssertEqual($0 as? AuthManager.MoveCommitError, .recordMissing)
        }
    }

    func testRecordsDecodeTolerantly() throws {
        let json = """
        {"id": "https://hermes.example", "kind": "hermes", "movedWebuiServers": [
          {"sourceServerID": "https://a.test", "completedAt": "not a date", "future": 1,
           "report": {"remaining": "many", "oversized": 2, "recordedAt": 0},
           "profiles": [{"source": "default", "hermesProfile": "default"}, {"source": "work", "keepOnWebui": true},
                        {"source": "lost"}, {"source": "blank", "hermesProfile": ""}, {"hermesProfile": "x"},
                        {"source": "both", "hermesProfile": "default", "keepOnWebui": true}]},
          {"profiles": []},
          {"sourceServerID": "https://b.test", "report": {"remaining": 1}}
        ]}
        """
        let account = try JSONDecoder().decode(ServerAccount.self, from: Data(json.utf8))

        XCTAssertEqual(account.movedWebuiServers, [
            MovedWebuiServer(sourceServerID: "https://a.test", profiles: mappings, completedAt: nil,
                             report: MovedWebuiReport(remaining: nil, unchecked: nil, oversized: 2,
                                                      recordedAt: Date(timeIntervalSinceReferenceDate: 0))),
            MovedWebuiServer(sourceServerID: "https://b.test", profiles: []),
        ])
        XCTAssertNil(account.movedWebuiServers[0].destination(ofProfile: "lost"), "An unreadable mapping is unmapped")
        XCTAssertNil(account.movedWebuiServers[0].destination(ofProfile: "both"), "Conflicting choices are unmapped")
        let older = try JSONDecoder().decode(ServerAccount.self, from: Data(#"{"id": "https://a.test"}"#.utf8))
        XCTAssertEqual(older.movedWebuiServers, [])
        let roundTrip = try JSONDecoder().decode(ServerAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(roundTrip, account)
    }

    // MARK: - Pairing carry

    func testTheSameInstallIsCopiedWithItsRegistrationAndNoRelayCall() async throws {
        let harness = PairingHarness()
        var stored = pairing(install: "a")
        stored.registeredToken = "abcd"
        stored.preferences = PushPreferences(replies: false)
        harness.store.pairings[source] = stored

        let outcome = await harness.carry(source, destination, reads: pairing(install: "a"))

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(harness.store.pairings[destination], stored)
        XCTAssertEqual(harness.store.pairings[source], stored)
        XCTAssertEqual(harness.reads, 1)
        XCTAssertEqual(harness.relay.calls, 0)
    }

    func testAnotherHostCopiesNothing() async throws {
        let harness = PairingHarness()
        harness.store.pairings[source] = pairing(install: "a")

        let outcome = await harness.carry(source, destination, reads: pairing(install: "b"))

        XCTAssertEqual(outcome, .differentInstall)
        XCTAssertNil(harness.store.pairings[destination])
        XCTAssertEqual(harness.relay.calls, 0)
    }

    func testAnExistingDestinationPairingStaysAndTheHostIsNeverRead() async throws {
        let harness = PairingHarness()
        harness.store.pairings[source] = pairing(install: "a")
        harness.store.pairings[destination] = pairing(install: "b")

        let kept = await harness.carry(source, destination, reads: pairing(install: "a"))
        XCTAssertEqual(kept, .destinationAlreadyPaired)
        XCTAssertEqual(harness.store.pairings[destination], pairing(install: "b"))

        harness.store.pairings = [:]
        let unpaired = await harness.carry(source, destination, reads: pairing(install: "a"))
        XCTAssertEqual(unpaired, .sourceUnpaired)
        XCTAssertEqual(harness.reads, 0)
        XCTAssertEqual(harness.relay.calls, 0)
    }

    func testAnUnreadableHostOrARemovedDestinationCopiesNothing() async throws {
        let harness = PairingHarness()
        harness.store.pairings[source] = pairing(install: "a")

        let unreadable = await harness.carry(source, destination, reads: nil)
        XCTAssertEqual(unreadable, .unchecked)
        let removed = await harness.carry(source, destination, reads: pairing(install: "a"), configured: false)
        XCTAssertEqual(removed, .unchecked)
        XCTAssertNil(harness.store.pairings[destination], "No hidden pairing for a server that went")
        XCTAssertEqual(harness.relay.calls, 0)
    }

    // MARK: - Helpers

    private func connection(password: String = "secret") -> BotConnection {
        BotConnection(id: UUID(), name: "Studio", address: destination, username: "me", password: password,
                      hermesVersion: "0.21.5")
    }

    private func pairing(install: Character) -> PushPairing {
        PushPairing(relayURL: URL(string: "https://relay.example")!, installKey: String(repeating: install, count: 64),
                    previewKey: Data(repeating: 1, count: 32).base64EncodedString())
    }

    /// The webui server `a.test` signed in and active, with its own custom header, and Bot
    /// Mode (beta) off, which a move never needs (#712).
    private func makeManager() throws -> (AuthManager, FailingKeychain) {
        let keychain = FailingKeychain()
        let preferences = UserDefaults.ephemeral()
        try keychain.save(source.absoluteString, forKey: .serverURL)
        try keychain.save([CustomHeader(name: "X-Webui", value: "token")].encodedForStorage() ?? "",
                          forKey: .customHeaders, scope: source.absoluteString)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            headerStore: CustomHeaderStore(),
            serverRegistry: ServerRegistry(keychain: keychain, identityDefaults: .ephemeral()),
            hermesConnections: HermesConnections(),
            preferences: preferences,
            forgetPush: { _ in }
        )
        guard manager.state == .loggedIn(server: source) else {
            XCTFail("Expected the webui server signed in, got \(manager.state)")
            throw FailingKeychain.WriteFailed()
        }
        return (manager, keychain)
    }

    /// Adds a second webui server without switching to it.
    private func addWebui(_ manager: AuthManager, _ address: String) throws -> ServerAccount {
        let active = try XCTUnwrap(manager.activeServer)
        manager.serverRegistry.activate(url: try XCTUnwrap(URL(string: address)))
        manager.serverRegistry.setActive(id: active.id)
        manager.refreshServers()
        return try XCTUnwrap(manager.servers.first { $0.id == address })
    }

    /// The registry as a relaunch would load it from `keychain`.
    private func reloaded(_ keychain: FailingKeychain) -> [ServerAccount] {
        ServerRegistry(keychain: keychain, identityDefaults: .ephemeral()).servers
    }
}

/// An in-memory Keychain whose writes to `failingKeys` throw, as a full or locked Keychain would.
private final class FailingKeychain: KeychainStoring {
    struct WriteFailed: Error {}
    var failingKeys: Set<KeychainStore.Key> = []
    private let base = InMemoryKeychainStore()

    func save(_ value: String, forKey key: KeychainStore.Key) throws {
        if failingKeys.contains(key) { throw WriteFailed() }
        try base.save(value, forKey: key)
    }
    func load(_ key: KeychainStore.Key) throws -> String? { try base.load(key) }
    func delete(_ key: KeychainStore.Key) throws { try base.delete(key) }
    func save(_ value: String, forKey key: KeychainStore.Key, scope: String) throws {
        if failingKeys.contains(key) { throw WriteFailed() }
        try base.save(value, forKey: key, scope: scope)
    }
    func load(_ key: KeychainStore.Key, scope: String) throws -> String? { try base.load(key, scope: scope) }
    func delete(_ key: KeychainStore.Key, scope: String) throws { try base.delete(key, scope: scope) }
    func scopedValue(_ key: KeychainStore.Key, scope: String) -> String? { base.scopedValue(key, scope: scope) }
}

/// A real `PushRegistrar` over an in-memory pairing store and a relay that counts calls.
@MainActor
private final class PairingHarness {
    let store = MemoryPairingStore()
    let relay = CountingRelay()
    private(set) var reads = 0
    private lazy var registrar = PushRegistrar(store: store, relay: relay, remoteNotifications: NoRemoteNotifications(),
                                               authorization: NoAuthorization(), identity: nil)

    /// Carries `source`'s pairing to `destination`, whose host reads as `reads` (nil fails).
    func carry(_ source: URL, _ destination: URL, reads pairing: PushPairing?, configured: Bool = true) async -> MovePushPairingOutcome {
        await MovePushPairing.carry(from: source, to: destination, registrar: registrar,
                                    isConfigured: { _ in configured }) {
            self.reads += 1
            guard let pairing else { throw URLError(.notConnectedToInternet) }
            return pairing
        }
    }
}

@MainActor
private final class MemoryPairingStore: PushPairingStoring {
    var pairings: [URL: PushPairing] = [:]
    func pairing(for server: URL) throws -> PushPairing? { pairings[server] }
    func save(_ pairing: PushPairing, for server: URL) throws { pairings[server] = pairing }
    func remove(for server: URL) throws { pairings[server] = nil }
    func allPairings() throws -> [URL: PushPairing] { pairings }
}

@MainActor
private final class CountingRelay: PushRelayRegistering {
    private(set) var calls = 0
    func registerDevice(token: String, identity: PushBuildIdentity, pairing: PushPairing) async throws { calls += 1 }
    func deleteDevice(token: String, pairing: PushPairing) async throws { calls += 1 }
}

@MainActor
private struct NoRemoteNotifications: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {}
    func unregisterForRemoteNotifications() {}
}

private struct NoAuthorization: ResponseCompletionNotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func requestAuthorization() async -> Bool { false }
    func schedule(_ request: ResponseCompletionNotificationRequest) async {}
}
