import XCTest
import AppIntents
@testable import HermesMobile

/// Covers the New Chat App Intent plumbing (issue #337): the parameter-less deep-link URL,
/// its round-trip detection, the router bridge an intent writes to, and the intent itself.
final class AppIntentNewChatTests: XCTestCase {

    // `AppIntentRouter` is a shared singleton, so reset its pending link around every
    // test. Doing it in setUp/tearDown (rather than inline) guarantees a clean slate
    // before each test and cleanup after every exit path — including a failed assertion
    // or a thrown error mid-test — so router state can't leak between tests.
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { AppIntentRouter.shared.pendingDeepLink = nil }
    }

    override func tearDown() async throws {
        await MainActor.run { AppIntentRouter.shared.pendingDeepLink = nil }
        try await super.tearDown()
    }

    func testIsNewChatURLAcceptsItsOwnURL() throws {
        let url = try XCTUnwrap(HermesDeepLink.newChatURL)
        XCTAssertTrue(HermesDeepLink.isNewChatURL(url))
    }

    func testSessionURLIsNotANewChatURL() throws {
        let session = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: "abc123"))
        XCTAssertFalse(HermesDeepLink.isNewChatURL(session))
    }

    func testNewChatURLDoesNotParseAsASessionID() throws {
        let url = try XCTUnwrap(HermesDeepLink.newChatURL)
        XCTAssertNil(HermesDeepLink.sessionID(from: url))
    }

    @MainActor
    func testNewChatIntentQueuesTheNewChatDeepLink() async throws {
        let router = AppIntentRouter.shared
        _ = try await NewChatIntent().perform()
        XCTAssertEqual(router.pendingDeepLink, HermesDeepLink.newChatURL)
    }

    // MARK: - New Chat with Voice (issue #338)

    func testIsNewChatVoiceURLAcceptsItsOwnURL() throws {
        let url = try XCTUnwrap(HermesDeepLink.newChatVoiceURL)
        XCTAssertTrue(HermesDeepLink.isNewChatVoiceURL(url))
    }

    func testVoiceAndPlainNewChatURLsDoNotAlias() throws {
        let voiceURL = try XCTUnwrap(HermesDeepLink.newChatVoiceURL)
        let plainURL = try XCTUnwrap(HermesDeepLink.newChatURL)
        // The two intents must route distinctly: a voice URL is not a plain new-chat URL,
        // and vice versa.
        XCTAssertFalse(HermesDeepLink.isNewChatURL(voiceURL))
        XCTAssertFalse(HermesDeepLink.isNewChatVoiceURL(plainURL))
    }

    @MainActor
    func testNewChatVoiceIntentQueuesTheVoiceDeepLink() async throws {
        let router = AppIntentRouter.shared
        _ = try await NewChatVoiceIntent().perform()
        XCTAssertEqual(router.pendingDeepLink, HermesDeepLink.newChatVoiceURL)
    }

    // MARK: - On a Hermes server (#1180)

    private let hermes = URL(string: "https://hermes.example")!
    private let studio = URL(string: "https://studio.example:9119")!
    private let webui = URL(string: "https://webui.example")!

    private func account(_ server: URL, _ kind: ServerKind) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }

    private var servers: [ServerAccount] { [account(hermes, .hermes), account(studio, .hermes), account(webui, .webui)] }

    @MainActor
    func testNewChatOnAnActiveHermesServerStaysThere() throws {
        for state in [AuthManager.State.loggedIn(server: hermes), .loggedOut(server: hermes)] {
            let chat = try XCTUnwrap(HermesNewChatDestination.onActiveServer(state: state, servers: servers,
                                                                             autoStartsVoiceInput: true))
            XCTAssertEqual(chat.server, hermes)
            XCTAssertNil(chat.profile, "New Session's Profile, which the list settles")
            XCTAssertTrue(chat.autoStartsVoiceInput)
        }
        XCTAssertNil(HermesNewChatDestination.onActiveServer(state: .loggedIn(server: webui), servers: servers,
                                                             autoStartsVoiceInput: false), "A webui server keeps its New Chat")
        XCTAssertNil(HermesNewChatDestination.onActiveServer(state: .unconfigured, servers: [], autoStartsVoiceInput: false))
    }

    @MainActor
    func testAHermesNewChatOpensOnlyOnItsSignedInServer() {
        let chat = HermesNewChatDestination(server: studio, profile: "dev")
        XCTAssertEqual(chat.route(state: .loggedIn(server: studio), servers: servers), .open)
        XCTAssertEqual(chat.route(state: .loggedOut(server: studio), servers: servers), .waitForSignIn)
        XCTAssertEqual(chat.route(state: .loggedIn(server: webui), servers: servers), .switchServer(account(studio, .hermes)))
        XCTAssertEqual(chat.route(state: .loggedIn(server: studio), servers: [account(hermes, .hermes)]), .ignore,
                       "A removed server's Shortcut opens nothing")
        XCTAssertEqual(HermesNewChatDestination(server: webui, profile: "dev").route(state: .loggedIn(server: webui), servers: servers),
                       .ignore)
    }

    @MainActor
    func testAHeldNewChatReplacesOlderLinksAndWaitsForItsServer() {
        var links = PendingLinks(deepLinkedSessionID: "legacy", newChatRequest: NewChatRequest())
        let chat = HermesNewChatDestination(server: studio, profile: "dev")

        XCTAssertEqual(links.open(chat, state: .loggedIn(server: webui), servers: servers), account(studio, .hermes))
        XCTAssertNil(links.deepLinkedSessionID)
        XCTAssertNil(links.newChatRequest)
        XCTAssertEqual(links.hermesNewChat, chat)

        XCTAssertNil(links.reroute(state: .loggedOut(server: studio), servers: servers, isBotModeEnabled: false))
        XCTAssertEqual(links.hermesNewChat, chat, "Held through the sign-in")
        XCTAssertNil(links.reroute(state: .loggedIn(server: studio), servers: [account(webui, .webui)], isBotModeEnabled: false))
        XCTAssertNil(links.hermesNewChat, "Its server was removed")
    }

    @MainActor
    func testTheSessionsListOpensTheNewChatInItsProfileOnceItCan() {
        let connection = BotConnection(id: UUID(), name: "Host", address: studio, username: "me", password: "secret")
        let entry = HermesSessionListEntry(server: studio, connection: connection, profile: nil)
        let voice = HermesNewChatDestination(server: studio, profile: nil, autoStartsVoiceInput: true)

        XCTAssertNil(voice.chat(on: entry, listed: nil, isLive: true), "Waits for New Session's Profile")
        XCTAssertNil(voice.chat(on: entry, listed: "default", isLive: false), "Waits for the host, as New Session does")
        let opened = voice.chat(on: entry, listed: "default", isLive: true)
        XCTAssertEqual(opened?.target, .new(profile: "default"))
        XCTAssertEqual(opened?.server, studio)
        XCTAssertEqual(opened?.autoStartsVoiceInput, true)

        let named = HermesNewChatDestination(server: studio, profile: "dev").chat(on: entry, listed: "default", isLive: true)
        XCTAssertEqual(named?.target, .new(profile: "dev"), "The Shortcut's Profile wins over the list's")
        XCTAssertEqual(named?.autoStartsVoiceInput, false)
        XCTAssertNil(HermesNewChatDestination(server: hermes, profile: "dev").chat(on: entry, listed: "default", isLive: true),
                     "Another server's list opens nothing")
    }
}
