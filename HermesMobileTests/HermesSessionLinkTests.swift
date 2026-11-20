import XCTest
@testable import HermesMobile

@MainActor final class HermesSessionLinkTests: XCTestCase {
    private let hermes = URL(string: "https://hermes.example")!
    private let otherHermes = URL(string: "https://studio.example:9119")!
    private let webui = URL(string: "https://webui.example")!

    private func account(_ server: URL, kind: ServerKind) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "",
                      initials: "", headerLogoColorHex: HeaderLogoColor.defaultHex,
                      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }

    private var servers: [ServerAccount] {
        [account(hermes, kind: .hermes), account(otherHermes, kind: .hermes), account(webui, kind: .webui)]
    }

    private func url(_ query: String, host: String = "session") throws -> URL {
        try XCTUnwrap(URL(string: "\(HermesDeepLink.scheme)://\(host)?\(query)"))
    }

    func testLinkRoundTripsItsServerProfileAndKey() throws {
        for profile in ["inbox-triage", "Chef de Cuisine", "日報", "", nil] as [String?] {
            let sent = HermesSessionDestination(server: hermes, profile: profile, key: "20261010_120000_a1b2c3")
            let link = try XCTUnwrap(HermesDeepLink.sessionURL(for: sent))
            XCTAssertEqual(link.scheme, HermesDeepLink.scheme)
            XCTAssertEqual(link.host, HermesDeepLink.sessionHost)
            XCTAssertEqual(HermesSessionDestination(url: link), sent, "Profile \(profile ?? "nil")")
        }
    }

    func testASubagentLinkKeepsItsParentStep() throws {
        let sent = HermesSessionDestination(server: hermes, profile: nil, key: "child", opensParent: true)
        XCTAssertEqual(HermesSessionDestination(url: try XCTUnwrap(HermesDeepLink.sessionURL(for: sent))), sent)
        XCTAssertEqual(HermesSessionDestination(url: try url("server=https://hermes.example&id=child"))?.opensParent, false)
    }

    func testParsingNormalizesTheServer() throws {
        for server in ["https://hermes.example/", "https://hermes.example/dashboard/"] {
            let parsed = HermesSessionDestination(url: try url("server=\(server)&id=abc&profile=research"))
            XCTAssertEqual(parsed, HermesSessionDestination(server: hermes, profile: "research", key: "abc"), server)
        }
    }

    func testALinkMissingItsServerOrKeyIsNotAHermesSessionLink() throws {
        for query in ["id=abc", "server=https://hermes.example", "server=https://hermes.example&id=%20",
                      "server=not%20a%20url&id=abc", "server=ftp://hermes.example&id=abc"] {
            XCTAssertNil(HermesSessionDestination(url: try url(query)), query)
        }
        XCTAssertNil(HermesSessionDestination(url: try url("server=https://hermes.example&id=abc", host: "webui-push")))
        XCTAssertEqual(HermesDeepLink.sessionID(from: try url("id=abc")), "abc", "The legacy link keeps its parse")
    }

    func testALinkNamingAnUnusableServerIsNotALegacyLink() throws {
        for query in ["server=ftp://hermes.example&id=abc", "server=not%20a%20url&id=abc", "server=&id=abc", "server&id=abc"] {
            XCTAssertNil(HermesDeepLink.sessionID(from: try url(query)), query)
        }
    }

    func testTheWebuiPushLinkKeepsItsOwnRoute() throws {
        let push = try XCTUnwrap(HermesDeepLink.webuiSessionURL(server: webui, sessionID: "abc"))
        XCTAssertEqual(WebuiPushDestination(url: push), WebuiPushDestination(server: webui, sessionID: "abc"))
        XCTAssertNil(HermesSessionDestination(url: push))
        XCTAssertNil(WebuiPushDestination(url: try url("server=https://webui.example&id=abc")))
    }

    func testALinkForTheActiveSignedInServerOpens() {
        let link = HermesSessionDestination(server: hermes, profile: "research", key: "abc")
        XCTAssertEqual(HermesSessionLinkRouter.resolve(link, state: .loggedIn(server: hermes), servers: servers), .open(link))
    }

    func testALinkForAnotherServerSwitchesFirst() {
        let link = HermesSessionDestination(server: hermes, profile: nil, key: "abc")
        for state in [AuthManager.State.loggedIn(server: otherHermes), .loggedIn(server: webui), .loggedOut(server: otherHermes)] {
            XCTAssertEqual(HermesSessionLinkRouter.resolve(link, state: state, servers: servers),
                           .switchServer(account(hermes, kind: .hermes), link), "\(state)")
        }
    }

    func testASignedOutServerHoldsItsLinkForSignIn() {
        let link = HermesSessionDestination(server: hermes, profile: "", key: "abc")
        XCTAssertEqual(HermesSessionLinkRouter.resolve(link, state: .loggedOut(server: hermes), servers: servers),
                       .waitForSignIn(link))
    }

    func testALinkForAServerThatIsNotConfiguredIsDropped() {
        let link = HermesSessionDestination(server: URL(string: "https://gone.example")!, profile: "research", key: "abc")
        XCTAssertEqual(HermesSessionLinkRouter.resolve(link, state: .loggedIn(server: hermes), servers: servers), .ignore)
    }

    func testASessionLinkReplacesAHeldBotLinkForAnotherServer() {
        let signedOut = AuthManager.State.loggedOut(server: hermes)
        let bot = BotDestination(server: otherHermes, connectionID: UUID(), profile: "inbox-triage")
        var links = PendingLinks(deepLinkedSessionID: "legacy", newChatRequest: NewChatRequest())
        XCTAssertNil(links.route(bot, state: signedOut, servers: servers, isBotModeEnabled: true,
                                 botConnectionID: { _ in bot.connectionID }))
        XCTAssertEqual(links.bot, bot, "held for the sign-in")

        let session = HermesSessionDestination(server: hermes, profile: "research", key: "abc")
        XCTAssertNil(links.open(session, state: signedOut, servers: servers))

        var lookedUp: [URL] = []
        let switched = links.reroute(state: .loggedIn(server: hermes), servers: servers, isBotModeEnabled: true,
                                     botConnectionID: { lookedUp.append($0); return bot.connectionID })
        XCTAssertNil(switched, "no server switch")
        XCTAssertEqual(lookedUp, [], "no other server's saved connection read")
        XCTAssertEqual(links.hermesSession, session)
        XCTAssertNil(links.bot)
        XCTAssertNil(links.deepLinkedSessionID)
        XCTAssertNil(links.newChatRequest)
    }

    func testAWebuiServersSessionLinkBecomesItsPushDestination() throws {
        let link = try XCTUnwrap(HermesSessionDestination(url: try url("server=https://webui.example/&id=abc&profile=research")))
        XCTAssertEqual(HermesSessionLinkRouter.resolve(link, state: .loggedIn(server: hermes), servers: servers),
                       .webui(WebuiPushDestination(server: webui, sessionID: "abc")))
    }

    private func coveredList() -> HermesSessionListCovers {
        let connection = BotConnection(id: UUID(), name: "Host", address: hermes, username: "me", password: "secret")
        let session = SessionSummary(title: "Synthetic chat", workspace: "/workspace")
        var covers = HermesSessionListCovers()
        covers.chat = HermesSessionChat(server: hermes, connection: connection, target: .new(profile: "research"))
        covers.renaming = session
        covers.exported = SessionExportShareItem(fileURL: URL(fileURLWithPath: "/tmp/export/chat.json"))
        covers.moving = HermesProjectMove(session: session, projectName: "Docs", folder: "/docs", isBusy: false)
        covers.showingArchived = true
        covers.showingKanban = true
        return covers
    }

    func testALinkForTheListsServerBringsItsRowsForward() {
        var covers = coveredList()
        covers.accept(HermesSessionDestination(server: hermes, profile: "research", key: "abc"), on: hermes)
        XCTAssertNil(covers.chat)
        XCTAssertNil(covers.renaming)
        XCTAssertNil(covers.exported)
        XCTAssertNil(covers.moving)
        XCTAssertFalse(covers.showingArchived)
        XCTAssertFalse(covers.isCoveredByScreen, "Kanban and Archived Sessions are popped")
    }

    func testAnExportFromBeforeALinkDoesNotPresent() {
        var covers = HermesSessionListCovers()
        let before = covers.generation
        covers.accept(HermesSessionDestination(server: hermes, profile: "research", key: "abc"), on: hermes)
        let item = SessionExportShareItem(fileURL: URL(fileURLWithPath: "/tmp/export/chat.json"))
        covers.present(item, startedAt: before)
        XCTAssertNil(covers.exported)

        covers.present(item, startedAt: covers.generation)
        XCTAssertEqual(covers.exported?.fileURL, item.fileURL)
    }

    func testOnlyALinkForTheListsServerClosesAnything() {
        for link in [nil, HermesSessionDestination(server: otherHermes, profile: "research", key: "abc")] {
            var covers = coveredList()
            let chat = covers.chat
            covers.accept(link, on: hermes)
            XCTAssertEqual(covers.chat, chat)
            XCTAssertNotNil(covers.renaming)
            XCTAssertTrue(covers.isCoveredByScreen)
        }
    }
}

@MainActor final class MovedWebuiLinkTests: XCTestCase {
    private let hermes = URL(string: "https://hermes.example")!
    private let studio = URL(string: "https://studio.example:9119")!
    private let webui = URL(string: "https://webui.example")!
    private let otherWebui = URL(string: "https://other-webui.example")!

    private func account(_ server: URL, _ kind: ServerKind, moved sources: [URL] = []) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 0), kind: kind,
                      movedWebuiServers: sources.map {
                          MovedWebuiServer(sourceServerID: $0.absoluteString,
                                           profiles: [MovedWebuiProfile(source: "default", destination: .hermes(profile: "work"))])
                      })
    }

    private func moved(to destination: URL, from sources: [URL]) -> ServerAccount {
        account(destination, .hermes, moved: sources)
    }

    func testAMovedServersLinkOpensOnItsDestinationFirst() throws {
        let servers = [moved(to: hermes, from: [webui]), account(webui, .webui)]
        let expected = HermesSessionDestination(server: hermes, profile: nil, key: "abc", movedFrom: webui)

        var links = PendingLinks()
        XCTAssertEqual(links.open(WebuiPushDestination(server: webui, sessionID: "abc"), state: .loggedIn(server: webui),
                                  servers: servers), servers[0])
        XCTAssertEqual(links.hermesSession, expected)
        XCTAssertNil(links.webuiPush)

        let named = try XCTUnwrap(HermesSessionDestination(url: XCTUnwrap(URL(
            string: "\(HermesDeepLink.scheme)://session?server=https://webui.example&id=abc&profile=default"))))
        links = PendingLinks()
        XCTAssertNil(links.open(named, state: .loggedIn(server: hermes), servers: servers))
        XCTAssertEqual(links.hermesSession, expected, "Its webui Profile is no Hermes Profile")
    }

    func testTheFallbackOpensOnTheWebuiServerWithoutComingBack() throws {
        let link = HermesSessionDestination(server: hermes, profile: nil, key: "abc", movedFrom: webui)
        let fallback = try XCTUnwrap(WebuiPushDestination(url: XCTUnwrap(MovedWebuiRoute.fallback(for: link))))
        XCTAssertEqual(fallback, WebuiPushDestination(server: webui, sessionID: "abc", opensOnSource: true))

        let servers = [moved(to: hermes, from: [webui]), account(webui, .webui)]
        var links = PendingLinks()
        XCTAssertEqual(links.open(fallback, state: .loggedIn(server: hermes), servers: servers), servers[1])
        XCTAssertEqual(links.webuiPush, fallback)
        XCTAssertNil(links.hermesSession)

        let removed = [moved(to: hermes, from: [webui])]
        XCTAssertNil(links.open(fallback, state: .loggedIn(server: hermes), servers: removed))
        let gone = try XCTUnwrap(links.hermesSession)
        XCTAssertNil(gone.movedFrom)
        XCTAssertNil(MovedWebuiRoute.fallback(for: gone))
        XCTAssertNil(MovedWebuiRoute.fallback(for: HermesSessionDestination(server: hermes, profile: nil, key: "abc")))
    }

    func testARemovedWebuiServersLinksReachItsDestination() throws {
        let servers = [moved(to: hermes, from: [webui])]
        let expected = HermesSessionDestination(server: hermes, profile: nil, key: "abc")
        let named = try XCTUnwrap(HermesSessionDestination(url: XCTUnwrap(URL(
            string: "\(HermesDeepLink.scheme)://session?server=https://webui.example&id=abc"))))

        var links = PendingLinks()
        XCTAssertNil(links.open(named, state: .loggedOut(server: hermes), servers: servers))
        XCTAssertEqual(links.hermesSession, expected, "Held for the destination's sign-in")
        XCTAssertNil(links.reroute(state: .loggedIn(server: hermes), servers: servers, isBotModeEnabled: true))
        XCTAssertEqual(links.hermesSession, expected)

        links = PendingLinks()
        XCTAssertEqual(links.open(WebuiPushDestination(server: webui, sessionID: "abc", opensOnSource: true),
                                  state: .loggedIn(server: studio), servers: servers + [account(studio, .hermes)]),
                       servers[0], "A run's link has nowhere else to go")
        XCTAssertEqual(links.hermesSession, expected)
    }

    func testRemovingTheDestinationRestoresTodaysRoutes() throws {
        var links = PendingLinks()
        let push = WebuiPushDestination(server: webui, sessionID: "abc")
        let unmoved = [account(hermes, .hermes), account(webui, .webui)]
        XCTAssertEqual(links.open(push, state: .loggedIn(server: hermes), servers: unmoved), unmoved[1])
        XCTAssertEqual(links.webuiPush, push)

        let named = try XCTUnwrap(HermesSessionDestination(url: XCTUnwrap(URL(
            string: "\(HermesDeepLink.scheme)://session?server=https://webui.example&id=abc"))))
        links = PendingLinks()
        XCTAssertNil(links.open(named, state: .loggedIn(server: hermes), servers: [account(hermes, .hermes)]))
        XCTAssertNil(links.hermesSession)
        XCTAssertNil(links.webuiPush)
    }

    func testARunsLinkStaysOnItsRetainedWebuiServer() throws {
        let servers = [moved(to: hermes, from: [webui]), account(webui, .webui)]
        var components = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(HermesDeepLink.webuiSessionURL(server: webui, sessionID: "abc")), resolvingAgainstBaseURL: false))
        components.queryItems?.append(URLQueryItem(name: "activity", value: "run-1"))
        let tap = try XCTUnwrap(WebuiPushDestination(url: XCTUnwrap(components.url)))
        XCTAssertTrue(tap.opensOnSource)

        for link in [tap, WebuiPushDestination(server: webui, sessionID: "abc", opensOnSource: true)] {
            var links = PendingLinks()
            XCTAssertEqual(links.open(link, state: .loggedIn(server: hermes), servers: servers), servers[1])
            XCTAssertEqual(links.webuiPush, link)
            XCTAssertNil(links.hermesSession)
        }
    }

    func testABareLinkOpensOnlyWhereNoOtherServerCouldOwnIt() {
        func route(_ servers: [ServerAccount], active: URL?) -> MovedWebuiRoute.Outcome<HermesSessionDestination> {
            MovedWebuiRoute.bareSession("abc", active: active, servers: servers)
        }
        let unmoved = [account(hermes, .hermes), account(webui, .webui)]
        XCTAssertEqual(route(unmoved, active: hermes), .webui(.switchServer(unmoved[1])), "No move: today's route")
        XCTAssertEqual(route(unmoved, active: webui), .webui(.stay))

        XCTAssertEqual(route([moved(to: hermes, from: [webui]), account(webui, .webui)], active: webui),
                       .hermes(HermesSessionDestination(server: hermes, profile: nil, key: "abc", movedFrom: webui)))
        XCTAssertEqual(route([moved(to: hermes, from: [webui])], active: hermes),
                       .hermes(HermesSessionDestination(server: hermes, profile: nil, key: "abc")))
        XCTAssertEqual(route([moved(to: hermes, from: [webui, otherWebui]), account(webui, .webui)], active: hermes),
                       .hermes(HermesSessionDestination(server: hermes, profile: nil, key: "abc", movedFrom: webui)))

        let withUnmoved = [moved(to: hermes, from: [webui]), account(webui, .webui), account(otherWebui, .webui)]
        for active in [hermes, webui, otherWebui] {
            XCTAssertEqual(route(withUnmoved, active: active), .refuse, "An unmoved webui server could own it")
        }
        let twoDestinations = [moved(to: hermes, from: [webui]), moved(to: studio, from: [otherWebui])]
        XCTAssertEqual(route(twoDestinations, active: hermes), .refuse, "The active destination breaks no tie")
        let twoFallbacks = [moved(to: hermes, from: [webui, otherWebui]), account(webui, .webui), account(otherWebui, .webui)]
        XCTAssertEqual(route(twoFallbacks, active: webui), .refuse, "Either webui server could be its fallback")
    }
}
