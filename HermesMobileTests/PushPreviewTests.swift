import UserNotifications
import XCTest
@testable import HermesMobile

/// The sealed-preview decrypt, the banner rewrite and the tap route (#559). The vector
/// is the plugin's own `plugin/hermex_push_tests/fixtures/sealed_preview.json`.
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
