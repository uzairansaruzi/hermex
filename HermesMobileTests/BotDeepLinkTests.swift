import XCTest
@testable import HermesMobile

@MainActor final class BotDeepLinkTests: XCTestCase {
    private let serverA = URL(string: "https://a.example")!
    private let serverB = URL(string: "https://b.example")!
    private let connectionID = UUID()

    private func destination(
        server: URL? = nil,
        connectionID: UUID? = nil,
        profile: String = "inbox-triage",
        conversation: String? = nil
    ) -> BotDestination {
        BotDestination(server: server ?? serverA, connectionID: connectionID ?? self.connectionID,
                       profile: profile, conversation: conversation)
    }

    private func account(_ server: URL, kind: ServerKind = .webui) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "",
                      initials: "", headerLogoColorHex: HeaderLogoColor.defaultHex,
                      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }

    private func resolve(
        _ destination: BotDestination,
        state: AuthManager.State,
        servers: [URL] = [],
        hermesServers: [URL] = [],
        isBotModeEnabled: Bool = true,
        connectionID: UUID?
    ) -> BotDeepLinkOutcome {
        BotDeepLinkRouter.resolve(destination, state: state,
                                  servers: servers.map { account($0) } + hermesServers.map { account($0, kind: .hermes) },
                                  isBotModeEnabled: isBotModeEnabled, botConnectionID: { _ in connectionID })
    }

    func testAScreenLinkSurvivesTheRoundTrip() throws {
        let id = UUID()
        let server = URL(string: "https://hermes.example")!
        let plain = BotDestination(server: server, connectionID: id, profile: "work")
        XCTAssertEqual(try HermesDeepLink.botDestination(from: XCTUnwrap(HermesDeepLink.botURL(for: plain)))?.opensScreen, false)
        var screen = plain
        screen.opensScreen = true
        XCTAssertEqual(try HermesDeepLink.botDestination(from: XCTUnwrap(HermesDeepLink.botURL(for: screen)))?.opensScreen, true)
    }

    func testAHermesServersLinkOpensItEvenWithBotModeOff() throws {
        let hermes = try XCTUnwrap(URL(string: "http://127.0.0.1:9199"))
        let link = destination(server: hermes)
        let parsed = try XCTUnwrap(HermesDeepLink.botURL(for: link).flatMap(HermesDeepLink.botDestination(from:)))
        XCTAssertEqual(parsed.server.absoluteString, "http://127.0.0.1:9199", "The link names the Hermes server by its id")

        XCTAssertEqual(resolve(parsed, state: .loggedIn(server: serverA), servers: [serverA], hermesServers: [hermes],
                               isBotModeEnabled: false, connectionID: connectionID),
                       .switchServer(account(hermes, kind: .hermes), parsed))
        XCTAssertEqual(resolve(parsed, state: .loggedIn(server: hermes), servers: [serverA], hermesServers: [hermes],
                               isBotModeEnabled: false, connectionID: connectionID), .open(parsed))
        XCTAssertEqual(resolve(destination(), state: .loggedIn(server: hermes), servers: [serverA], hermesServers: [hermes],
                               isBotModeEnabled: false, connectionID: connectionID), .ignore)
    }

    func testLinkRoundTripsTheIdentityItRoutesBy() throws {
        for profile in ["inbox-triage", "Chef de Cuisine", "日報"] {
            let sent = destination(profile: profile, conversation: "root-7")
            let url = try XCTUnwrap(HermesDeepLink.botURL(for: sent))
            XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
            XCTAssertEqual(url.host, HermesDeepLink.botHost)
            XCTAssertEqual(HermesDeepLink.botDestination(from: url), sent)
        }

        let url = try XCTUnwrap(HermesDeepLink.botURL(for: destination()))
        XCTAssertEqual(HermesDeepLink.botDestination(from: url), destination())
    }

    func testLinkIsDroppedWhenItCannotNameOneBotWithoutGuessing() throws {
        let complete = "\(HermesDeepLink.scheme)://bot?server=https://a.example&connection=\(connectionID.uuidString)&profile=inbox-triage"
        XCTAssertNotNil(HermesDeepLink.botDestination(from: try XCTUnwrap(URL(string: complete))))

        for raw in [
            "\(HermesDeepLink.scheme)://bot?connection=\(connectionID.uuidString)&profile=inbox-triage",
            "\(HermesDeepLink.scheme)://bot?server=https://a.example&profile=inbox-triage",
            "\(HermesDeepLink.scheme)://bot?server=https://a.example&connection=not-a-uuid&profile=inbox-triage",
            "\(HermesDeepLink.scheme)://bot?server=https://a.example&connection=\(connectionID.uuidString)&profile=%20",
            "\(HermesDeepLink.scheme)://bot?server=%20&connection=\(connectionID.uuidString)&profile=inbox-triage"
        ] {
            XCTAssertNil(HermesDeepLink.botDestination(from: try XCTUnwrap(URL(string: raw))), raw)
        }

        let trailing = try XCTUnwrap(URL(string: "\(HermesDeepLink.scheme)://bot?server=https://a.example/&connection=\(connectionID.uuidString)&profile=inbox-triage"))
        XCTAssertEqual(HermesDeepLink.botDestination(from: trailing), destination())
    }

    func testBotAndSessionLinksNeverAliasEachOther() throws {
        let bot = try XCTUnwrap(HermesDeepLink.botURL(for: destination()))
        XCTAssertNil(HermesDeepLink.sessionID(from: bot))
        XCTAssertFalse(HermesDeepLink.isNewChatURL(bot))
        XCTAssertFalse(HermesDeepLink.isNewChatInProfileURL(bot))

        let session = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: "abc"))
        XCTAssertNil(HermesDeepLink.botDestination(from: session))
    }

    func testRemovedServerOrReplacedConnectionOpensTheAppNormally() {
        XCTAssertEqual(resolve(destination(), state: .loggedIn(server: serverB), servers: [serverB],
                               connectionID: connectionID), .ignore)
        XCTAssertEqual(resolve(destination(), state: .loggedIn(server: serverA), servers: [serverA],
                               connectionID: nil), .ignore)
        XCTAssertEqual(resolve(destination(), state: .loggedIn(server: serverA), servers: [serverA],
                               connectionID: UUID()), .ignore)
    }

    func testLinkForTheActiveServerOpens() {
        XCTAssertEqual(resolve(destination(), state: .loggedIn(server: serverA), servers: [serverA, serverB],
                               connectionID: connectionID), .open(destination()))
    }

    func testLinkForAnotherServerSwitchesToItFirst() {
        let outcome = resolve(destination(server: serverB), state: .loggedIn(server: serverA),
                              servers: [serverA, serverB], connectionID: connectionID)
        XCTAssertEqual(outcome, .switchServer(account(serverB), destination(server: serverB)))
    }

    func testSignedOutLinkWaitsForSignIn() {
        XCTAssertEqual(resolve(destination(), state: .loggedOut(server: serverA), servers: [serverA],
                               connectionID: connectionID), .waitForSignIn(destination()))
        XCTAssertEqual(resolve(destination(), state: .unconfigured, servers: [serverA],
                               connectionID: connectionID), .waitForSignIn(destination()))
    }

    func testRosterResolutionMatchesOnlyTheNamedConnectionAndProfile() {
        let connection = BotConnection(id: connectionID, name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                       username: "user", password: "fixture", hermesVersion: nil)
        let other = BotConnection(id: UUID(), name: "Mac", address: connection.address,
                                  username: "user", password: "fixture", hermesVersion: nil)
        let profiles = [BotProfile(.object(["name": .string("inbox-triage")]))!,
                        BotProfile(.object(["name": .string("default")]))!]

        XCTAssertEqual(BotDeepLinkRouter.profile(for: destination(), connection: connection, profiles: profiles)?.id,
                       "inbox-triage")
        XCTAssertNil(BotDeepLinkRouter.profile(for: destination(), connection: other, profiles: profiles))
        XCTAssertNil(BotDeepLinkRouter.profile(for: destination(), connection: nil, profiles: profiles))
        XCTAssertNil(BotDeepLinkRouter.profile(for: destination(profile: "retired"),
                                               connection: connection, profiles: profiles))
    }

    func testUnknownProfileDismissesThePresentedChatAndLinkedRoot() {
        let profile = BotProfile(.object(["name": .string("inbox-triage")]))!
        let connection = BotConnection(id: connectionID, name: "Fixture", address: serverA,
                                       username: "fixture", password: "fixture")
        let room = BotRoomKey(server: serverA, connectionID: connectionID, roomID: "room")
        for initial in [BotInboxSelection(profile: profile, conversation: "old-root"),
                        BotInboxSelection(room: room)] {
            var selection = initial
            selection.open(destination(profile: "retired", conversation: "stale-root"),
                           connection: connection, profiles: [profile])
            XCTAssertNil(selection.profile)
            XCTAssertNil(selection.room)
            XCTAssertNil(selection.conversation)
        }
    }

    func testValidProfileLinkReplacesRoomAndPreservesExpectedConversation() {
        let profile = BotProfile(.object(["name": .string("inbox-triage")]))!
        let connection = BotConnection(id: connectionID, name: "Fixture", address: serverA,
                                       username: "fixture", password: "fixture")
        var selection = BotInboxSelection(
            room: BotRoomKey(server: serverA, connectionID: connectionID, roomID: "room"))
        selection.open(destination(conversation: "expected-root"), connection: connection, profiles: [profile])
        XCTAssertEqual(selection.profile, profile)
        XCTAssertNil(selection.room)
        XCTAssertEqual(selection.conversation, "expected-root")
    }

    func testEveryBotRouteOpensItsCanonicalChatInTheRegularChat() throws {
        let profile = BotProfile(.object(["name": .string("inbox-triage")]))!
        let connection = BotConnection(id: connectionID, name: "Fixture", address: serverA,
                                       username: "fixture", password: "fixture")
        let row = try XCTUnwrap(BotInboxSelection(profile: profile).chat(server: serverA, connection: connection))
        XCTAssertEqual(row.target, .canonicalChat(profile: "inbox-triage"))
        XCTAssertEqual(row.server, serverA)
        XCTAssertEqual(row.connection.id, connectionID)
        XCTAssertNil(row.linkedRoot)
        XCTAssertNil(row.botChatRoot)

        for (link, root) in [(destination(conversation: "root-1"), "root-1"), (destination(), nil)] {
            var selection = BotInboxSelection()
            let parsed = try XCTUnwrap(HermesDeepLink.botURL(for: link).flatMap(HermesDeepLink.botDestination(from:)))
            selection.open(parsed, connection: connection, profiles: [profile])
            let chat = try XCTUnwrap(selection.chat(server: serverA, connection: connection))
            XCTAssertEqual(chat.target, .canonicalChat(profile: "inbox-triage"))
            XCTAssertEqual(chat.linkedRoot, root)
        }
        XCTAssertNil(BotInboxSelection().chat(server: serverA, connection: connection))

        let elsewhere = BotConnection(id: UUID(), name: "Fixture", address: serverB, username: "fixture", password: "fixture")
        let other = try XCTUnwrap(BotInboxSelection(profile: profile).chat(server: serverB, connection: elsewhere))
        XCTAssertEqual(row.target.draftKey(server: row.server, connectionID: row.connection.id),
                       .bot(server: serverA, connectionID: connectionID, profile: "inbox-triage"))
        XCTAssertEqual(other.target.draftKey(server: other.server, connectionID: other.connection.id),
                       .bot(server: serverB, connectionID: elsewhere.id, profile: "inbox-triage"))
    }

    func testAHeldLinkSurvivesAConnectingOrRetryingInboxButNotAMissingConnection() {
        XCTAssertTrue(BotDeepLinkRouter.inboxCanAnswer(link: .live, hasConnection: true, hasSettled: true))
        XCTAssertFalse(BotDeepLinkRouter.inboxCanAnswer(link: .connecting, hasConnection: true, hasSettled: true))
        XCTAssertFalse(BotDeepLinkRouter.inboxCanAnswer(link: .disconnected, hasConnection: true, hasSettled: true))
        XCTAssertTrue(BotDeepLinkRouter.inboxCanAnswer(link: .idle, hasConnection: false, hasSettled: true))
        XCTAssertFalse(BotDeepLinkRouter.inboxCanAnswer(link: .idle, hasConnection: false, hasSettled: false))
    }

    func testADeepLinkedConversationOpensTheBotsCurrentChat() async {
        for linked in ["root-then", "root-now"] {
            let wire = BotFixtureWire()
            wire.root = "root-now"
            let model = conversation(named: linked, wire: wire)
            await model.activate()
            XCTAssertEqual(model.connectionState, .connected, linked)
            XCTAssertEqual(model.root, "root-now", linked)
            model.suspend()
        }
    }

    private func conversation(named conversation: String, wire: BotFixtureWire) -> HermesConversation {
        HermesConversation(
            server: serverA,
            connection: BotConnection(id: connectionID, name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                      username: "user", password: "fixture", hermesVersion: nil),
            target: .canonicalChat(profile: "inbox-triage"), linkedRoot: conversation, wire: wire
        )
    }
}
