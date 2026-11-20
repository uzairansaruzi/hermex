import UserNotifications
import XCTest
@testable import HermesMobile

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

        let otherInstall = PushPreviewKeys(installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        XCTAssertNil(PushPreview.open(sealed: sealed, keys: otherInstall))
        XCTAssertNil(PushPreview.open(sealed: "not base64", keys: keys))
    }

    func testAPhoneSealedPreviewOpensOnlyForItsOwnInstall() throws {
        let preview = PushPreview(title: "Hermex test notification", body: "Push reached this iPhone.")
        let sealed = try XCTUnwrap(PushPreview.seal(preview, keys: keys))
        XCTAssertNotEqual(PushPreview.seal(preview, keys: keys), sealed, "Every seal takes a fresh nonce")
        XCTAssertEqual(PushPreview.open(sealed: sealed, keys: keys), preview)

        let content = banner(sealed: sealed)
        PushPreview.rewrite(content, candidates: [keys])
        XCTAssertEqual(content.title, "Hermex test notification")
        XCTAssertEqual(content.body, "Push reached this iPhone.")

        let otherInstall = PushPreviewKeys(installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        XCTAssertNil(PushPreview.open(sealed: sealed, keys: otherInstall))
        XCTAssertNil(PushPreview.seal(preview, keys: PushPreviewKeys(installKey: keys.installKey, previewKey: "short")))
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

    func testRewriteNamesTheBotWithTheKindsLabel() throws {
        let titles = [
            "approval": "Inbox Triage · Approval needed",
            "clarify": "Inbox Triage · Question",
            "turn_error": "Inbox Triage · Turn failed",
            "reply": "Inbox Triage"
        ]
        for (kind, title) in titles {
            let content = try namedBanner(kind: kind, botName: "Inbox Triage")
            PushPreview.rewrite(content, candidates: [keys])
            XCTAssertEqual(content.title, title, kind)
            XCTAssertEqual(content.subtitle, "Sealed subtitle", kind)
            XCTAssertEqual(content.body, "Sealed body", kind)
            XCTAssertEqual(PushPayload(userInfo: content.userInfo).profile, "inbox-triage", kind)
        }
    }

    func testRewriteKeepsTheSealedTitleWithoutABotName() throws {
        let cases: [(kind: String?, botName: String?)] = [
            ("approval", nil), ("approval", ""), ("input", "Inbox Triage"), (nil, "Inbox Triage")
        ]
        for (kind, botName) in cases {
            let content = try namedBanner(kind: kind, botName: botName)
            PushPreview.rewrite(content, candidates: [keys])
            XCTAssertEqual(content.title, "Sealed title", "\(kind ?? "no kind"), \(botName ?? "no bot_name")")
            XCTAssertEqual(content.body, "Sealed body")
        }
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
        XCTAssertEqual(route(active: lan, connected: [server]), server)
        XCTAssertEqual(route(active: nil, connected: [server, lan]), lan)
    }

    func testTapWithoutABotToOpenOnlyOpensTheApp() {
        let pairings = [server: PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)]
        let opened = banner(sealed: sealed)
        PushPreview.rewrite(opened, candidates: [keys])

        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: banner(sealed: nil).userInfo, pairings: pairings) { _ in UUID() })
        var webui = opened.userInfo
        webui["source"] = "webui"
        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: webui, pairings: pairings) { _ in UUID() })
        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: opened.userInfo, pairings: [:]) { _ in UUID() })
        XCTAssertNil(PushNotificationRouter.botDestination(userInfo: opened.userInfo, pairings: pairings) { _ in nil })
    }

    private func account(_ url: URL, _ kind: ServerKind) -> ServerAccount {
        ServerAccount(id: url.absoluteString, urlString: url.absoluteString, displayName: "", initials: "",
                      headerLogoColorHex: "", createdAt: .now, updatedAt: .now, kind: kind)
    }

    private func tap(source: String, kind: ServerKind, profile: String?, isSubagent: Bool = false,
                     botConnection: UUID? = UUID()) -> URL? {
        var info = banner(sealed: nil).userInfo
        info["source"] = source
        info["is_subagent"] = isSubagent
        info[PushPayload.profileKey] = profile
        return PushNotificationRouter.link(
            userInfo: info, pairings: [server: PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)],
            servers: [account(server, kind)], botConnectionID: { _ in botConnection })
    }

    func testATapRoutesBySourceServerKindProfileAndSubagent() throws {
        for source in ["bot", "other", "future"] {
            for profile in ["inbox-triage", "", nil] as [String?] {
                for isSubagent in [false, true] {
                    let link = try XCTUnwrap(tap(source: source, kind: .hermes, profile: profile, isSubagent: isSubagent),
                                             "\(source), \(profile ?? "nil"), \(isSubagent)")
                    XCTAssertEqual(HermesSessionDestination(url: link),
                                   HermesSessionDestination(server: server, profile: profile, key: "s1", opensParent: isSubagent),
                                   "\(source), \(profile ?? "nil"), \(isSubagent)")
                }
            }
        }
        XCTAssertEqual(tap(source: "webui", kind: .webui, profile: nil),
                       WebuiPushDestination(server: server, sessionID: "s1", opensOnSource: true).url)
        let connection = UUID()
        XCTAssertEqual(tap(source: "bot", kind: .webui, profile: "inbox-triage", botConnection: connection),
                       HermesDeepLink.botURL(for: BotDestination(server: server, connectionID: connection, profile: "inbox-triage")))
        XCTAssertNil(tap(source: "bot", kind: .webui, profile: nil))
        XCTAssertNil(tap(source: "bot", kind: .webui, profile: "inbox-triage", botConnection: nil))
        XCTAssertNil(tap(source: "other", kind: .webui, profile: "inbox-triage"))
    }

    func testAHermesTapWithoutASessionOrServerOpensNothing() {
        var info = banner(sealed: nil).userInfo
        info[PushPayload.profileKey] = "inbox-triage"
        info["session_id"] = " "
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        XCTAssertNil(PushNotificationRouter.link(userInfo: info, pairings: [server: pairing],
                                                 servers: [account(server, .hermes)], botConnectionID: { _ in UUID() }))
        info["session_id"] = "s1"
        XCTAssertNil(PushNotificationRouter.link(userInfo: info, pairings: [server: pairing], servers: [],
                                                 botConnectionID: { _ in UUID() }))
        XCTAssertNil(PushNotificationRouter.link(userInfo: info, pairings: [:], servers: [account(server, .hermes)],
                                                 botConnectionID: { _ in UUID() }))
    }

    func testAHermesTapOnOneHostUnderTwoServersStaysOnTheActiveOne() throws {
        let lan = URL(string: "http://192.168.1.2:9119")!
        let other = URL(string: "https://other.example")!
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        let unrelated = PushPairing(relayURL: other, installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        let servers = [account(server, .hermes), account(lan, .hermes), account(other, .hermes)]
        func route(active: URL?) throws -> URL? {
            let link = try XCTUnwrap(PushNotificationRouter.link(
                userInfo: banner(sealed: nil).userInfo, pairings: [server: pairing, lan: pairing, other: unrelated],
                servers: servers, activeServer: active, botConnectionID: { _ in UUID() }))
            return HermesSessionDestination(url: link)?.server
        }

        XCTAssertEqual(try route(active: server), server)
        XCTAssertEqual(try route(active: lan), lan)
        XCTAssertEqual(try route(active: other), lan)
        XCTAssertEqual(try route(active: nil), lan)
    }

    func testAMixedKindSharedHostRoutesByTheActiveServersKind() throws {
        let webui = URL(string: "https://webui.example")!
        let connection = UUID()
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        var info = banner(sealed: nil).userInfo
        info[PushPayload.profileKey] = "research"
        func route(active: URL?, botConnection: UUID? = connection) -> URL? {
            PushNotificationRouter.link(userInfo: info, pairings: [server: pairing, webui: pairing],
                                        servers: [account(server, .hermes), account(webui, .webui)],
                                        activeServer: active, botConnectionID: { $0 == webui ? botConnection : nil })
        }
        let bot = HermesDeepLink.botURL(for: BotDestination(server: webui, connectionID: connection, profile: "research"))
        let session = HermesDeepLink.sessionURL(for: HermesSessionDestination(server: server, profile: "research", key: "s1"))

        XCTAssertEqual(route(active: webui), bot)
        XCTAssertEqual(route(active: server), session)
        XCTAssertEqual(route(active: nil), session, "With neither active, the first by URL")
        XCTAssertEqual(route(active: webui, botConnection: nil), session)
    }

    func testWebuiTapRoutesWithoutBotConnectionOrDecryptedProfile() throws {
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        var info = banner(sealed: nil).userInfo
        info["source"] = "webui"
        let servers = [account(server, .webui)]
        let destination = try XCTUnwrap(PushNotificationRouter.webuiDestination(
            userInfo: info, pairings: [server: pairing], servers: servers))
        XCTAssertEqual(destination, WebuiPushDestination(server: server, sessionID: "s1", opensOnSource: true),
                       "A push is about a run on its webui server (#1217)")
        XCTAssertEqual(WebuiPushDestination(url: try XCTUnwrap(destination.url)), destination)
        XCTAssertNil(PushNotificationRouter.webuiDestination(userInfo: info, pairings: [:], servers: servers))
        for source in ["bot", "other", "future"] {
            info["source"] = source
            XCTAssertNil(PushNotificationRouter.webuiDestination(userInfo: info, pairings: [server: pairing], servers: servers))
        }
        info["source"] = "webui"
        info["session_id"] = " "
        XCTAssertNil(PushNotificationRouter.webuiDestination(userInfo: info, pairings: [server: pairing], servers: servers))
    }

    func testWebuiDeepLinkAcceptsMixedCaseSchemeAndHost() throws {
        let destination = WebuiPushDestination(server: server, sessionID: "CaseSensitiveSession")
        var components = try XCTUnwrap(URLComponents(url: XCTUnwrap(destination.url), resolvingAgainstBaseURL: false))
        components.scheme = HermesDeepLink.scheme.uppercased()
        components.host = "WEBUI-PUSH"
        XCTAssertEqual(WebuiPushDestination(url: try XCTUnwrap(components.url)), destination)
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
        let servers = [account(server, .webui), account(other, .webui)]
        XCTAssertEqual(PushNotificationRouter.webuiDestination(
            userInfo: info, pairings: [server: pairing, other: pairing], servers: servers, activeServer: other)?.server, other)
        let unrelated = PushPairing(relayURL: other, installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        XCTAssertEqual(PushNotificationRouter.webuiDestination(
            userInfo: info, pairings: [server: pairing, other: unrelated], servers: servers, activeServer: other)?.server, server)
    }

    func testAWebuiTapOnAMixedKindSharedHostOpensOnTheWebuiServer() {
        let webui = URL(string: "https://webui.example")!
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        var info = banner(sealed: nil).userInfo
        info["source"] = "webui"
        func route(active: URL?, servers: [ServerAccount]) -> URL? {
            PushNotificationRouter.link(userInfo: info, pairings: [server: pairing, webui: pairing], servers: servers,
                                        activeServer: active, botConnectionID: { _ in nil })
        }
        let mixed = [account(server, .hermes), account(webui, .webui)]
        let session = WebuiPushDestination(server: webui, sessionID: "s1", opensOnSource: true).url

        XCTAssertEqual(route(active: server, servers: mixed), session)
        XCTAssertEqual(route(active: webui, servers: mixed), session)
        XCTAssertEqual(route(active: nil, servers: mixed), session)
        XCTAssertNil(route(active: server, servers: [account(server, .hermes)]))
    }

    func testLocalAlertTapOpensItsChatOnItsConfiguredServer() throws {
        let other = URL(string: "https://other.example")!
        let alert = ResponseCompletionNotificationRequest(sessionID: "s1", server: server, title: "Chat", outcome: .completed)
        let info: [AnyHashable: Any] = alert.userInfo

        XCTAssertEqual(ResponseCompletionNotificationRequest.destination(userInfo: info, servers: [other, server]),
                       HermesDeepLink.webuiSessionURL(server: server, sessionID: "s1"))
        XCTAssertNil(ResponseCompletionNotificationRequest.destination(userInfo: info, servers: [other]))
        var blank = info
        blank["session_id"] = " "
        XCTAssertNil(ResponseCompletionNotificationRequest.destination(userInfo: blank, servers: [server]))
        let noSession = ResponseCompletionNotificationRequest(sessionID: nil, server: server, title: "Chat", outcome: .failed)
        XCTAssertNil(ResponseCompletionNotificationRequest.destination(userInfo: noSession.userInfo, servers: [server]))
        XCTAssertNil(PushPayload(userInfo: info).installHash)
        XCTAssertEqual(PushPresence.presentation(userInfo: info, viewer: nil, pairings: [:]), [])
        var relay = banner(sealed: nil).userInfo
        relay["source"] = "webui"
        relay["server_hash"] = info["server_hash"]
        XCTAssertNil(ResponseCompletionNotificationRequest.destination(userInfo: relay, servers: [server]))
    }

    private func moved(to destination: URL, from sources: [URL]) -> ServerAccount {
        var holder = account(destination, .hermes)
        holder.movedWebuiServers = sources.map {
            MovedWebuiServer(sourceServerID: $0.absoluteString,
                             profiles: [MovedWebuiProfile(source: "default", destination: .hermes(profile: "work"))])
        }
        return holder
    }

    func testAMovedWebuiServersPushOpensOnItWhileItIsConfigured() {
        let webui = URL(string: "https://webui.example")!
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        var info = banner(sealed: nil).userInfo
        info["source"] = "webui"
        let link = PushNotificationRouter.link(userInfo: info, pairings: [server: pairing, webui: pairing],
                                               servers: [moved(to: server, from: [webui]), account(webui, .webui)],
                                               activeServer: server, botConnectionID: { _ in nil })
        XCTAssertEqual(link, WebuiPushDestination(server: webui, sessionID: "s1", opensOnSource: true).url)
    }

    func testAWebuiPushAfterItsServerWasRemovedOpensOnTheOneHermesServerHoldingItsInstall() throws {
        let webui = URL(string: "https://webui.example")!
        let studio = URL(string: "https://studio.example")!
        let pairing = PushPairing(relayURL: server, installKey: keys.installKey, previewKey: keys.previewKey)
        let otherInstall = PushPairing(relayURL: server, installKey: String(repeating: "f", count: 64),
                                       previewKey: keys.previewKey)
        var info = banner(sealed: nil).userInfo
        info["source"] = "webui"
        info[PushPayload.profileKey] = "default"
        func route(_ pairings: [URL: PushPairing], _ servers: [ServerAccount]) -> URL? {
            PushNotificationRouter.link(userInfo: info, pairings: pairings, servers: servers, activeServer: server,
                                        botConnectionID: { _ in nil })
        }

        let link = try XCTUnwrap(route([server: pairing], [moved(to: server, from: [webui])]))
        XCTAssertEqual(HermesSessionDestination(url: link), HermesSessionDestination(server: server, profile: nil, key: "s1"),
                       "The preview's webui Profile is no Hermes Profile")
        XCTAssertNil(route([server: pairing, studio: pairing],
                           [moved(to: server, from: [webui]), moved(to: studio, from: [URL(string: "https://b.example")!])]),
                     "Two Hermes servers on the install: the active one breaks no tie")
        XCTAssertNil(route([server: pairing], [account(server, .hermes)]), "No move: as before")
        XCTAssertNil(route([server: otherInstall], [moved(to: server, from: [webui])]),
                     "A cross-host move's old install is paired with nothing")
    }

    func testAMovedWebuiServersLocalAlertKeepsAWayIn() throws {
        let webui = URL(string: "https://webui.example")!
        let alert = ResponseCompletionNotificationRequest(sessionID: "s1", server: webui, title: "Chat", outcome: .completed)
        let onWebui = WebuiPushDestination(server: webui, sessionID: "s1", opensOnSource: true).url

        XCTAssertEqual(PushNotificationRouter.localAlertLink(
            userInfo: alert.userInfo, servers: [moved(to: server, from: [webui]), account(webui, .webui)]), onWebui)
        XCTAssertEqual(PushNotificationRouter.localAlertLink(
            userInfo: alert.userInfo, servers: [moved(to: server, from: [webui])]), onWebui,
                       "The link's route finds the destination")
        XCTAssertNil(PushNotificationRouter.localAlertLink(userInfo: alert.userInfo, servers: [account(server, .hermes)]))

        let hermesAlert = ResponseCompletionNotificationRequest(sessionID: "tip", server: server, title: "Chat",
                                                                outcome: .completed, hermesProfile: "research")
        XCTAssertEqual(PushNotificationRouter.localAlertLink(userInfo: hermesAlert.userInfo, servers: [account(server, .hermes)]),
                       HermesDeepLink.sessionURL(for: HermesSessionDestination(server: server, profile: "research", key: "tip")))
    }

    func testAHermesLocalAlertTapOpensItsSessionLink() throws {
        let alert = ResponseCompletionNotificationRequest(sessionID: "tip-2", server: server, title: "Chat",
                                                          outcome: .completed, hermesProfile: "research")
        let link = try XCTUnwrap(ResponseCompletionNotificationRequest.destination(userInfo: alert.userInfo, servers: [server]))

        XCTAssertEqual(HermesSessionDestination(url: link),
                       HermesSessionDestination(server: server, profile: "research", key: "tip-2"))
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
        let other = URL(string: "https://other.example")!
        let unrelated = PushPairing(relayURL: other, installKey: String(repeating: "f", count: 64), previewKey: keys.previewKey)
        XCTAssertEqual(PushPresence.presentation(
            userInfo: reply, viewer: .init(server: other, sessionID: "s1"), pairings: [server: pairing, other: unrelated]), shown)

        var loud = pairing
        loud.preferences = PushPreferences(presenceSuppression: false)
        XCTAssertEqual(PushPresence.presentation(userInfo: reply, viewer: open, pairings: [server: loud]), shown)
        XCTAssertEqual(PushPresence.presentation(userInfo: [:], viewer: nil, pairings: [server: pairing]), [])
        XCTAssertEqual(PushPresence.presentation(userInfo: reply, viewer: nil, pairings: [:]), [])
    }

    func testPresenceOnlyClearsForTheScreenThatEntered() {
        let presence = PushPresence(appLock: AppLock(defaults: UserDefaults(suiteName: "PushPreviewTests.presence")!))
        let chat = PushPresence.Viewer(server: server, sessionID: "s1")
        let (old, replacement) = (UUID(), UUID())
        presence.enter(chat, owner: old)
        presence.enter(chat, owner: replacement)
        presence.leave(owner: old)
        XCTAssertEqual(presence.viewer, chat)
        presence.leave(owner: replacement)
        XCTAssertNil(presence.viewer)
    }

    private func namedBanner(kind: String?, botName: String?) throws -> UNMutableNotificationContent {
        var json: [String: Any] = [
            "title": "Sealed title", "subtitle": "Sealed subtitle", "body": "Sealed body",
            "profile": "inbox-triage", "request_id": "r1"
        ]
        json["bot_name"] = botName
        let preview = try JSONDecoder().decode(PushPreview.self, from: JSONSerialization.data(withJSONObject: json))
        let content = banner(sealed: try XCTUnwrap(PushPreview.seal(preview, keys: keys)))
        content.userInfo["kind"] = kind
        return content
    }

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
