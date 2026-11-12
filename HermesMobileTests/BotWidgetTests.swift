import XCTest
@testable import HermesMobile

/// The Bot widget (#1643): where its digest-keyed tap opens, and the snapshot its picker reads.
@MainActor final class BotWidgetTests: XCTestCase {
    private let hermes = URL(string: "https://hermes.example")!
    private let studio = URL(string: "https://studio.example")!
    private let webui = URL(string: "https://webui.example")!

    private func account(_ server: URL, _ kind: ServerKind) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }

    /// The link a widget for `profile` on `server` sends, read back the way `ContentView` reads it.
    private func tap(_ server: URL, _ profile: String = "work") throws -> BotWidgetDestination {
        let url = try XCTUnwrap(BotWidgetDestination(serverKey: BotHistoryCache.Scope.key(server), profile: profile).url)
        XCTAssertNil(HermesDeepLink.botDestination(from: url), "Never read as a bot link")
        return try XCTUnwrap(BotWidgetDestination(url: url))
    }

    func testATapOpensTheBotOnItsServerAndSwitchesToIt() throws {
        let connection = UUID()
        let servers = [account(hermes, .hermes), account(studio, .hermes)]
        let ids: @MainActor (URL) -> UUID? = { $0 == self.hermes ? connection : UUID() }
        let expected = BotDestination(server: hermes, connectionID: connection, profile: "work")

        var links = PendingLinks()
        XCTAssertNil(links.open(try tap(hermes), state: .loggedIn(server: hermes), servers: servers,
                                isBotModeEnabled: false, botConnectionID: ids))
        XCTAssertEqual(links.bot, expected)

        links = PendingLinks()
        XCTAssertEqual(links.open(try tap(hermes), state: .loggedIn(server: studio), servers: servers,
                                  isBotModeEnabled: false, botConnectionID: ids), servers[0])
        XCTAssertEqual(links.bot, expected)
    }

    func testAnUnknownServerOrAWebuiServerWithBotModeOffOpensNothing() throws {
        let servers = [account(hermes, .hermes), account(webui, .webui)]
        var links = PendingLinks()
        XCTAssertNil(links.open(try tap(studio), state: .loggedIn(server: hermes), servers: servers,
                                isBotModeEnabled: true, botConnectionID: { _ in UUID() }))
        XCTAssertNil(links.bot)
        XCTAssertNil(links.botWidget)

        XCTAssertNil(links.open(try tap(webui), state: .loggedIn(server: hermes), servers: servers,
                                isBotModeEnabled: false, botConnectionID: { _ in UUID() }))
        XCTAssertNil(links.bot)
        XCTAssertNil(links.botWidget)
    }

    /// A sign-out deleted the server's Bot connection, so the link waits by digest and Profile and
    /// opens the bot on the connection the next sign-in saves.
    func testASignedOutServerHoldsTheTapUntilSignInSavesANewConnection() throws {
        let servers = [account(hermes, .hermes), account(studio, .hermes)]
        var saved: UUID?
        let ids: @MainActor (URL) -> UUID? = { $0 == self.hermes ? saved : UUID() }

        var links = PendingLinks()
        XCTAssertEqual(links.open(try tap(hermes), state: .loggedIn(server: studio), servers: servers,
                                  isBotModeEnabled: false, botConnectionID: ids), servers[0], "Shows its sign-in form")
        XCTAssertNil(links.reroute(state: .loggedOut(server: hermes), servers: servers, isBotModeEnabled: false,
                                   botConnectionID: ids))
        XCTAssertNotNil(links.botWidget)
        XCTAssertNil(links.bot)

        let signedIn = UUID()
        saved = signedIn
        XCTAssertNil(links.reroute(state: .loggedIn(server: hermes), servers: servers, isBotModeEnabled: false,
                                   botConnectionID: ids))
        XCTAssertEqual(links.bot, BotDestination(server: hermes, connectionID: signedIn, profile: "work"))
        XCTAssertNil(links.botWidget)
    }

    func testTheSnapshotKeepsEqualProfileNamesOnTwoServersApartAndDropsARemovedServer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = BotWidgetSnapshotFile(directory: directory)
        let publisher = BotWidgetPublisher(file: file, serverTitle: { $0.host ?? "" }, reloadWidget: {},
                                           configuredBots: { [] })
        let work = try XCTUnwrap(BotProfile(.object(["name": .string("work")])))
        publisher.publish([work], server: hermes)
        publisher.publish([work], server: studio)

        let snapshot = file.read()
        let ids = Set(snapshot.servers.flatMap { server in server.bots.map { BotWidgetEntity(serverKey: server.serverKey, bot: $0).id } })
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotNil(snapshot.bot(serverKey: BotHistoryCache.Scope.key(hermes), profile: "work"))
        XCTAssertNotNil(snapshot.bot(serverKey: BotHistoryCache.Scope.key(studio), profile: "work"))

        publisher.remove(server: hermes)
        XCTAssertNil(file.read().bot(serverKey: BotHistoryCache.Scope.key(hermes), profile: "work"))
        XCTAssertNotNil(file.read().bot(serverKey: BotHistoryCache.Scope.key(studio), profile: "work"))
    }
}
