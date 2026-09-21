import XCTest
@testable import HermesMobile

/// The one bot deep link (#554): what it encodes, and what the router does with it
/// before any navigation happens — Bot Mode off, signed out, a link for the server
/// that is not active, a removed server or connection, and an unknown Profile.
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

    private func account(_ server: URL) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "",
                      initials: "", headerLogoColorHex: HeaderLogoColor.defaultHex,
                      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func resolve(
        _ destination: BotDestination,
        state: AuthManager.State,
        servers: [URL] = [],
        isBotModeEnabled: Bool = true,
        connectionID: UUID?
    ) -> BotDeepLinkOutcome {
        BotDeepLinkRouter.resolve(destination, state: state, servers: servers.map(account),
                                  isBotModeEnabled: isBotModeEnabled, botConnectionID: { _ in connectionID })
    }

    func testLinkRoundTripsTheIdentityItRoutesBy() throws {
        for profile in ["inbox-triage", "Chef de Cuisine", "日報"] {
            let sent = destination(profile: profile, conversation: "root-7")
            let url = try XCTUnwrap(HermesDeepLink.botURL(for: sent))
            XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
            XCTAssertEqual(url.host, HermesDeepLink.botHost)
            XCTAssertEqual(HermesDeepLink.botDestination(from: url), sent)
        }

        // The conversation is optional: a link without one still routes.
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

        // A trailing slash still matches the registry's normalized server id.
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

    func testBotModeOffOpensTheAppWithNoBotUI() {
        let outcome = resolve(destination(), state: .loggedIn(server: serverA), servers: [serverA],
                              isBotModeEnabled: false, connectionID: connectionID)
        XCTAssertEqual(outcome, .ignore)
    }

    func testRemovedServerOrReplacedConnectionOpensTheAppNormally() {
        // The server was deleted after the link was minted.
        XCTAssertEqual(resolve(destination(), state: .loggedIn(server: serverB), servers: [serverB],
                               connectionID: connectionID), .ignore)
        // The Bot connection was removed…
        XCTAssertEqual(resolve(destination(), state: .loggedIn(server: serverA), servers: [serverA],
                               connectionID: nil), .ignore)
        // …or replaced, which mints a new UUID even under the same name.
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
        // Server B's own credentials, cache and drafts come with the switch; nothing
        // opens under the still-active server A.
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
        // Equal Profile names on a different connection are a different bot.
        XCTAssertNil(BotDeepLinkRouter.profile(for: destination(), connection: other, profiles: profiles))
        XCTAssertNil(BotDeepLinkRouter.profile(for: destination(), connection: nil, profiles: profiles))
        // An unknown Profile leaves the user on the inbox rather than opening a guess.
        XCTAssertNil(BotDeepLinkRouter.profile(for: destination(profile: "retired"),
                                               connection: connection, profiles: profiles))
    }

    func testUnknownProfileDismissesThePresentedChatAndLinkedRoot() {
        let profile = BotProfile(.object(["name": .string("inbox-triage")]))!
        let connection = BotConnection(id: connectionID, name: "Fixture", address: serverA,
                                       username: "fixture", password: "fixture")
        let room = BotRoomKey(server: serverA, connectionID: connectionID, roomID: "room")
        // Both bot and group chats must return to the inbox, even when the stale
        // link also names a conversation that must not affect the next manual tap.
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

    func testAHeldLinkSurvivesAConnectingOrRetryingInboxButNotAMissingConnection() {
        // Only a live roster answers a link…
        XCTAssertTrue(BotDeepLinkRouter.inboxCanAnswer(link: .live, hasConnection: true, hasSettled: true))
        // …a connecting or dropped socket keeps it, so a reconnect still routes it.
        XCTAssertFalse(BotDeepLinkRouter.inboxCanAnswer(link: .connecting, hasConnection: true, hasSettled: true))
        XCTAssertFalse(BotDeepLinkRouter.inboxCanAnswer(link: .disconnected, hasConnection: true, hasSettled: true))
        // No Bot connection at all is a settled answer: nothing will ever resolve it.
        XCTAssertTrue(BotDeepLinkRouter.inboxCanAnswer(link: .idle, hasConnection: false, hasSettled: true))
        // …but not before the inbox has opened once, when nothing is loaded yet.
        XCTAssertFalse(BotDeepLinkRouter.inboxCanAnswer(link: .idle, hasConnection: false, hasSettled: false))
    }

    func testDeepLinkedConversationTheBotHasReplacedIsReportedInsteadOfOpened() async {
        let wire = BotFixtureWire()
        wire.root = "root-now"
        let model = conversation(named: "root-then", wire: wire)
        await model.recover()

        XCTAssertTrue(model.linkedRootIsStale)
        XCTAssertNotEqual(model.connectionState, .connected)
        // Rejected before `session.resume`, which can auto-continue the bot's work.
        XCTAssertFalse(wire.calls.contains { $0.0 == "session.resume" })
        model.suspend()
    }

    func testDeepLinkedConversationTheBotStillHasOpensNormally() async {
        let wire = BotFixtureWire()
        wire.root = "root-now"
        let model = conversation(named: "root-now", wire: wire)
        await model.recover()

        XCTAssertFalse(model.linkedRootIsStale)
        XCTAssertEqual(model.connectionState, .connected)
        model.suspend()
    }

    private func conversation(named conversation: String, wire: BotFixtureWire) -> BotConversation {
        BotConversation(
            server: serverA,
            connection: BotConnection(id: connectionID, name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                      username: "user", password: "fixture", hermesVersion: nil),
            profile: BotProfile(.object(["name": .string("inbox-triage")]))!,
            conversation: conversation,
            wire: wire,
            drafts: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60))
        )
    }
}
