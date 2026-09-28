import UserNotifications
import XCTest
@testable import HermesMobile

/// The sealed-preview decrypt, the banner rewrite, the tap route (#559) and foreground
/// presentation (#566). The vector is the plugin's own
/// `plugin/hermex_push_tests/fixtures/sealed_preview.json`.
@MainActor final class PushPreviewTests: XCTestCase {
    private let keys = PushPreviewKeys(
        installKey: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        previewKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    )
    private let installHash = "a8ae6e6ee929abea3afcfc5258c8ccd6f85273e0d4626d26c7279f3250f77c8e"
    private let sealed = "AAECAwQFBgcICQoLPCCicrGJpzm3Y9/uw4QdHqH6pUeFGSsVTAuApydLd9pgZI6Ixqx3uB3XX4T8pQQajDYE9HjsgZRQ+EQ3Os/XnoJToBO/tARbPjDPCI76YpwapusQExImDY6JwaUc0oOv6YW0xXNanJh9oshh732iWJbB"
    private let server = URL(string: "https://hermes.example")!

    func testOpensThePluginTestVector() {
        XCTAssertEqual(keys.installHash, installHash)
        XCTAssertEqual(
            PushPreview.open(sealed: sealed, keys: keys),
            PushPreview(title: "Hermes", subtitle: "what time is it", body: "Noon.", profile: "default", requestID: "")
        )
    }

    func testWrongKeyTamperedBlobAndOtherInstallAllFail() {
        let wrongKey = PushPreviewKeys(installKey: keys.installKey, previewKey: Data(repeating: 9, count: 32).base64EncodedString())
        XCTAssertNil(PushPreview.open(sealed: sealed, keys: wrongKey))

        var blob = Data(base64Encoded: sealed)!
        blob[20] ^= 1
        XCTAssertNil(PushPreview.open(sealed: blob.base64EncodedString(), keys: keys))

        // Same preview key under another install: the AAD no longer matches.
        let otherInstall = PushPreviewKeys(installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        XCTAssertNil(PushPreview.open(sealed: sealed, keys: otherInstall))
        XCTAssertNil(PushPreview.open(sealed: "not base64", keys: keys))
    }

    func testRewriteShowsThePreviewAndKeepsTheProfileForTheTap() {
        let content = banner(sealed: sealed)
        PushPreview.rewrite(content, candidates: [PushPreviewKeys(installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey), keys])

        XCTAssertEqual(content.title, "Hermes")
        XCTAssertEqual(content.subtitle, "what time is it")
        XCTAssertEqual(content.body, "Noon.")
        XCTAssertEqual(PushPayload(userInfo: content.userInfo).profile, "default")
    }

    func testRewriteLeavesTheBannerContentFreeOnAnyFailure() {
        for content in [banner(sealed: nil), banner(sealed: "AAAA")] {
            PushPreview.rewrite(content, candidates: [keys])
            XCTAssertEqual(content.title, "Hermex")
            XCTAssertEqual(content.subtitle, "")
            XCTAssertEqual(content.body, "New activity")
            XCTAssertNil(PushPayload(userInfo: content.userInfo).profile)
        }

        let unpaired = banner(sealed: sealed)
        PushPreview.rewrite(unpaired, candidates: [])
        XCTAssertEqual(unpaired.body, "New activity")
    }

    func testTapOpensTheBotOnThePairedServer() {
        let connection = UUID()
        let other = URL(string: "https://other.example")!
        let pairings = [
            other: PushPairing(relayURL: other, installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey),
            server: PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        ]
        let content = banner(sealed: sealed)
        PushPreview.rewrite(content, candidates: [keys])

        XCTAssertEqual(
            PushNotificationRouter.botDestination(userInfo: content.userInfo, pairings: pairings) {
                $0 == self.server ? connection : UUID()
            },
            BotDestination(server: server, connectionID: connection, profile: "default")
        )
    }

    func testOneHostUnderTwoServersStaysOnTheActiveOne() {
        let lan = URL(string: "http://192.168.1.2:9120")!
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        let content = banner(sealed: sealed)
        PushPreview.rewrite(content, candidates: [keys])
        func route(active: URL?, connected: Set<URL>) -> URL? {
            PushNotificationRouter.botDestination(
                userInfo: content.userInfo, pairings: [server: pairing, lan: pairing], activeServer: active
            ) { connected.contains($0) ? UUID() : nil }?.server
        }

        XCTAssertEqual(route(active: server, connected: [server, lan]), server)
        XCTAssertEqual(route(active: lan, connected: [server, lan]), lan)
        // The active alias has no Bot connection: the other one still routes.
        XCTAssertEqual(route(active: lan, connected: [server]), server)
        XCTAssertEqual(route(active: nil, connected: [server, lan]), lan)
    }

    func testTapWithoutABotToOpenOnlyOpensTheApp() {
        let pairings = [server: PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)]
        let opened = banner(sealed: sealed)
        PushPreview.rewrite(opened, candidates: [keys])

        // The preview never opened, so no Profile.
        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: banner(sealed: nil).userInfo, pairings: pairings) { _ in UUID() })
        // A webui session is not a bot.
        var webui = opened.userInfo
        webui["source"] = "webui"
        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: webui, pairings: pairings) { _ in UUID() })
        // The pairing was wiped, or the server has no Bot connection.
        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: opened.userInfo, pairings: [:]) { _ in UUID() })
        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: opened.userInfo, pairings: pairings) { _ in nil })
    }

    func testWebuiTapRoutesWithoutBotConnectionOrDecryptedProfile() throws {
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        var info = banner(sealed: nil).userInfo
        info["source"] = "webui"
        let destination = try XCTUnwrap(PushNotificationRouter.webuiDestination(
            userInfo: info, pairings: [server: pairing]))
        XCTAssertEqual(destination, WebuiPushDestination(server: server, sessionID: "s1"))
        XCTAssertEqual(WebuiPushDestination(url: try XCTUnwrap(destination.url)), destination)
        XCTAssertNil(PushNotificationRouter.webuiDestination(userInfo: info, pairings: [:]))
        for source in ["bot", "other", "future"] {
            info["source"] = source
            XCTAssertNil(PushNotificationRouter.webuiDestination(userInfo: info, pairings: [server: pairing]))
        }
        info["source"] = "webui"
        info["session_id"] = " "
        XCTAssertNil(PushNotificationRouter.webuiDestination(userInfo: info, pairings: [server: pairing]))
    }

    func testWebuiDeepLinkAcceptsMixedCaseSchemeAndHost() throws {
        let destination = WebuiPushDestination(server: server, sessionID: "CaseSensitiveSession")
        var components = try XCTUnwrap(URLComponents(url: XCTUnwrap(destination.url), resolvingAgainstBaseURL: false))
        components.scheme = HermesDeepLink.scheme.uppercased()
        components.host = "WEBUI-PUSH"
        XCTAssertEqual(WebuiPushDestination(url: try XCTUnwrap(components.url)), destination)
    }

    func testWebuiPreviewUsesTheSameSealedEnvelope() {
        let content = banner(sealed: sealed)
        content.userInfo["source"] = "webui"
        PushPreview.rewrite(content, candidates: [keys])
        XCTAssertEqual(content.body, "Noon.")
        XCTAssertEqual(PushPayload(userInfo: content.userInfo).source, "webui")
    }

    func testWebuiRouteSwitchesToItsServerAndWaitsForItsSignIn() {
        let other = URL(string: "https://other.example")!
        let destination = WebuiPushDestination(server: server, sessionID: "s1")
        let account = ServerAccount(id: server.absoluteString, urlString: server.absoluteString,
                                    displayName: "", initials: "", headerLogoColorHex: "",
                                    createdAt: .now, updatedAt: .now)
        XCTAssertEqual(destination.route(state: .loggedIn(server: other), servers: [account]), .switchServer(account))
        XCTAssertEqual(destination.route(state: .loggedOut(server: other), servers: [account]), .switchServer(account))
        XCTAssertEqual(destination.route(state: .loggedOut(server: server), servers: [account]), .waitForSignIn)
        XCTAssertEqual(destination.route(state: .loggedIn(server: server), servers: [account]), .open)
        XCTAssertEqual(destination.route(state: .loggedIn(server: other), servers: []), .ignore)
    }

    func testWebuiTapOnlyMatchesItsInstallAndPrefersActiveAlias() {
        let other = URL(string: "https://other.example")!
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        var info = banner(sealed: nil).userInfo
        info["source"] = "webui"
        XCTAssertEqual(PushNotificationRouter.webuiDestination(
            userInfo: info, pairings: [server: pairing, other: pairing], activeServer: other)?.server, other)
        let unrelated = PushPairing(relayURL: other, installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        XCTAssertEqual(PushNotificationRouter.webuiDestination(
            userInfo: info, pairings: [server: pairing, other: unrelated], activeServer: other)?.server, server)
    }

    func testForegroundShowsRelayPushesButQuietsTheOpenChatsReplies() {
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        let open = PushPresence.Viewer(server: server, sessionID: "s1")
        let reply = banner(sealed: nil).userInfo
        let shown: UNNotificationPresentationOptions = [.banner, .list, .sound]
        XCTAssertEqual(PushPresence.presentation(userInfo: reply, viewer: open, pairings: [server: pairing]), [])
        for kind in ["approval", "clarify", "input", "turn_error"] {
            var info = reply
            info["kind"] = kind
            XCTAssertEqual(PushPresence.presentation(userInfo: info, viewer: open, pairings: [server: pairing]), shown)
        }
        XCTAssertEqual(PushPresence.presentation(userInfo: reply, viewer: nil, pairings: [server: pairing]), shown)
        XCTAssertEqual(PushPresence.presentation(
            userInfo: reply, viewer: .init(server: server, sessionID: "s2"), pairings: [server: pairing]), shown)
        // The same session ID open on another server's install is a different conversation.
        let other = URL(string: "https://other.example")!
        let unrelated = PushPairing(relayURL: other, installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        XCTAssertEqual(PushPresence.presentation(
            userInfo: reply, viewer: .init(server: other, sessionID: "s1"), pairings: [server: pairing, other: unrelated]), shown)

        var loud = pairing
        loud.preferences = PushPreferences(presenceSuppression: false)
        XCTAssertEqual(PushPresence.presentation(userInfo: reply, viewer: open, pairings: [server: loud]), shown)
        // Local alerts and pushes from an install this phone no longer holds keep the
        // system default of showing nothing in the foreground.
        XCTAssertEqual(PushPresence.presentation(userInfo: [:], viewer: nil, pairings: [server: pairing]), [])
        XCTAssertEqual(PushPresence.presentation(userInfo: reply, viewer: nil, pairings: [:]), [])
    }

    func testPresenceOnlyClearsForTheScreenThatEntered() {
        let presence = PushPresence()
        let chat = PushPresence.Viewer(server: server, sessionID: "s1")
        let (old, replacement) = (UUID(), UUID())
        // A deep link can rebuild the same conversation before the old screen disappears.
        presence.enter(chat, owner: old)
        presence.enter(chat, owner: replacement)
        presence.leave(owner: old)
        XCTAssertEqual(presence.viewer, chat)
        presence.leave(owner: replacement)
        XCTAssertNil(presence.viewer)
    }

    /// A banner as the relay's `bannerPush` builds it.
    private func banner(sealed: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Hermex"
        content.body = "New activity"
        content.userInfo = [
            "v": 1, "kind": "reply", "install_hash": installHash, "session_id": "s1",
            "source": "bot", "is_subagent": false, "sealed": sealed ?? NSNull()
        ]
        return content
    }
}
