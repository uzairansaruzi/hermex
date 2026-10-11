import XCTest
@testable import HermesMobile

/// The Hermes session link (#1176): `session?server=…&profile=…&id=…`, what it encodes, how
/// the legacy session forms keep their routes, and what the router does with it before any
/// navigation: open, switch servers, wait for sign-in, hand a webui server's to its push route,
/// or drop it.
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

    /// The registry keeps normalized addresses, so a link written with a trailing slash or a
    /// dashboard path still names its configured server.
    func testParsingNormalizesTheServer() throws {
        for server in ["https://hermes.example/", "https://hermes.example/dashboard/"] {
            let parsed = HermesSessionDestination(url: try url("server=\(server)&id=abc&profile=research"))
            XCTAssertEqual(parsed, HermesSessionDestination(server: hermes, profile: "research", key: "abc"), server)
        }
    }

    /// A link without a usable server or key is dropped rather than guessed; `session?id=` without
    /// a server stays the webui route it was (#971).
    func testALinkMissingItsServerOrKeyIsNotAHermesSessionLink() throws {
        for query in ["id=abc", "server=https://hermes.example", "server=https://hermes.example&id=%20",
                      "server=not%20a%20url&id=abc", "server=ftp://hermes.example&id=abc"] {
            XCTAssertNil(HermesSessionDestination(url: try url(query)), query)
        }
        XCTAssertNil(HermesSessionDestination(url: try url("server=https://hermes.example&id=abc", host: "webui-push")))
        XCTAssertEqual(HermesDeepLink.sessionID(from: try url("id=abc")), "abc", "The legacy link keeps its parse")
    }

    /// The webui push link and the Hermes session link never parse as each other.
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

    /// Another server active, signed in or on its sign-in form: the link's server activates first
    /// and the rebuilt home routes it. Nothing is read from or signed in to the active one.
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

    /// A session link replaces the links already held: with server B signed out holding a Bot
    /// link for server A, a session link for B leaves only B's, so signing in to B neither reads
    /// A's saved connection nor switches to A.
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

    /// `session?server=<webui server>&id=` is a legacy form: it becomes that server's push
    /// destination and nothing else, so a moved server (#707) is redirected in one place.
    func testAWebuiServersSessionLinkBecomesItsPushDestination() throws {
        let link = try XCTUnwrap(HermesSessionDestination(url: try url("server=https://webui.example/&id=abc&profile=research")))
        XCTAssertEqual(HermesSessionLinkRouter.resolve(link, state: .loggedIn(server: hermes), servers: servers),
                       .webui(WebuiPushDestination(server: webui, sessionID: "abc")))
    }
}
