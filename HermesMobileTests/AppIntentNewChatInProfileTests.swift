import XCTest
import AppIntents
@testable import HermesMobile

/// Covers the "New Chat in <Profile>" App Intent plumbing (issue #339): the profile-carrying
/// deep link, its non-aliasing with the other new-chat links, the `NewChatRequest` threading,
/// the intent itself, and the shared `ProfileEntity` mapping + cache.
final class AppIntentNewChatInProfileTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { AppIntentRouter.shared.pendingDeepLink = nil }
    }

    override func tearDown() async throws {
        await MainActor.run { AppIntentRouter.shared.pendingDeepLink = nil }
        ProfileStatusFixture.replies = [:]
        try await super.tearDown()
    }

    // MARK: - With a Hermes server active (#899)

    private func account(_ id: String, _ kind: ServerKind) -> ServerAccount {
        ServerAccount(id: id, urlString: id, displayName: "", initials: "", headerLogoColorHex: HeaderLogoColor.defaultHex,
                      createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }

    func testTheProfileListComesOnlyFromAWebuiServer() throws {
        let hermes = account("https://hermes.example", .hermes)
        let first = account("https://a.test", .webui), second = account("https://b.test", .webui)
        let profileServer = { (active: String?, servers: [ServerAccount]) in
            ProfileEntityProvider.profileServer(active: active.flatMap { URL(string: $0) }, servers: servers)?.absoluteString
        }

        XCTAssertEqual(profileServer("https://b.test", [hermes, first, second]), "https://b.test")
        XCTAssertEqual(profileServer("https://hermes.example", [hermes, first, second]), "https://a.test",
                       "The webui server New Chat in Profile switches to")
        XCTAssertNil(profileServer("https://hermes.example", [hermes]))
        XCTAssertNil(profileServer(nil, [first]))
    }

    // MARK: - Hermes servers' Profiles (#1180)

    private func account(_ id: String, _ kind: ServerKind, named name: String) -> ServerAccount {
        var named = account(id, kind)
        named.displayName = name
        return named
    }

    func testAHermesProfileIdNamesItsServerAndRoundTrips() throws {
        let studio = try XCTUnwrap(URL(string: "https://studio.test"))
        let entity = ProfileEntity(hermesServer: studio, profile: "inbox-triage", title: "Inbox Triage")
        XCTAssertEqual(entity.id, "https://studio.test|inbox-triage")
        XCTAssertEqual(entity.name, "Inbox Triage")
        XCTAssertEqual(entity.subtitle, "inbox-triage")
        XCTAssertEqual(entity.hermesNewChat?.server, studio)
        XCTAssertEqual(entity.hermesNewChat?.profile, "inbox-triage")

        let unnamed = ProfileEntity(hermesServer: studio, profile: "dev", title: nil)
        XCTAssertEqual(unnamed.name, "dev", "A Profile the roster never named is titled by its own name")
        XCTAssertNil(unnamed.subtitle)
    }

    func testABareIdStaysAWebuiProfile() {
        XCTAssertNil(ProfileEntity(id: "dev", name: "dev", subtitle: nil).hermesNewChat)
        XCTAssertNil(ProfileEntity(id: "a|b", name: "a|b", subtitle: nil).hermesNewChat)
    }

    @MainActor
    func testAHermesProfileQueuesALinkToItsServer() async throws {
        let studio = try XCTUnwrap(URL(string: "https://studio.test"))
        let intent = NewChatInProfileIntent()
        intent.profile = ProfileEntity(hermesServer: studio, profile: "inbox-triage", title: "Inbox Triage")
        _ = try await intent.perform()

        let url = try XCTUnwrap(AppIntentRouter.shared.pendingDeepLink)
        let destination = try XCTUnwrap(HermesNewChatDestination(url: url))
        XCTAssertEqual(destination.server, studio)
        XCTAssertEqual(destination.profile, "inbox-triage")
        XCTAssertFalse(destination.autoStartsVoiceInput)
    }

    func testASavedBareProfileLinkKeepsItsWebuiRoute() throws {
        let url = try XCTUnwrap(HermesDeepLink.newChatInProfileURL(profileName: "dev"))
        XCTAssertNil(HermesNewChatDestination(url: url))
        XCTAssertTrue(HermesDeepLink.isWebuiNewChatInProfileURL(url))
        XCTAssertEqual(HermesDeepLink.profileName(fromNewChatInProfile: url), "dev")
        let bare = try XCTUnwrap(URL(string: "\(HermesDeepLink.scheme)://new-chat-profile"))
        XCTAssertTrue(HermesDeepLink.isWebuiNewChatInProfileURL(bare), "A link with no profile stays a plain webui new chat")
    }

    /// A link naming a server never falls back to the webui route, which would open another
    /// server's composer.
    func testALinkNamingAServerThatCannotOpenIsNotAWebuiLink() throws {
        for query in ["server=https%3A%2F%2Fstudio.test&profile=", "server=https%3A%2F%2Fstudio.test&profile=%20",
                      "server=https%3A%2F%2Fstudio.test", "server=not%20a%20url&profile=dev",
                      "server=ftp://studio.test&profile=dev", "server=&profile=dev", "server&profile=dev"] {
            let url = try XCTUnwrap(URL(string: "\(HermesDeepLink.scheme)://new-chat-profile?\(query)"))
            XCTAssertNil(HermesNewChatDestination(url: url), query)
            XCTAssertFalse(HermesDeepLink.isWebuiNewChatInProfileURL(url), query)
        }
    }

    @MainActor
    func testThePickerHasOneSectionPerServer() async throws {
        let studio = account("https://studio.test", .hermes, named: "Studio Mac")
        let laptop = account("https://laptop.test", .webui, named: "Laptop")
        let air = account("https://air.test", .hermes, named: "")
        ProfileStatusFixture.replies = [
            "studio.test": (200, #"{"version":"0.21.5","profiles":["default","inbox-triage"],"auth_required":true}"#),
            "air.test": (200, #"{"profiles":["default"," ",7]}"#)
        ]
        let (names, suite, defaults) = makeIsolatedNames()
        defer { defaults.removePersistentDomain(forName: suite) }
        names.save([.init(profile: "default", title: "Hermes"), .init(profile: "inbox-triage", title: "Inbox Triage")],
                   for: URL(string: "https://studio.test")!)

        let sections = await ProfileEntityProvider.sections(
            servers: [studio, laptop, air], active: URL(string: "https://studio.test"), names: names,
            webui: { [ProfileEntity(id: "default", name: "Default", subtitle: "gpt-6 · openai")] },
            liveNames: Self.liveNames
        )

        XCTAssertEqual(sections.map(\.title), ["Studio Mac", String(localized: "Laptop (Web UI)"), "air.test"])
        XCTAssertEqual(sections[0].profiles.map(\.id), ["https://studio.test|default", "https://studio.test|inbox-triage"])
        XCTAssertEqual(sections[0].profiles.map(\.name), ["Hermes", "Inbox Triage"])
        XCTAssertEqual(sections[0].profiles.map(\.subtitle), ["default", "inbox-triage"])
        XCTAssertEqual(sections[1].profiles.map(\.id), ["default"], "A webui Profile keeps its bare id")
        XCTAssertEqual(sections[2].profiles.map(\.id), ["https://air.test|default"],
                       "The same Profile on another server is another choice")
    }

    @MainActor
    func testAnUnreadableHostListsItsCachedNames() async throws {
        let studio = account("https://studio.test", .hermes, named: "Studio Mac")
        let air = account("https://air.test", .hermes, named: "Air")
        ProfileStatusFixture.replies = ["studio.test": (502, "Bad gateway")]
        let (names, suite, defaults) = makeIsolatedNames()
        defer { defaults.removePersistentDomain(forName: suite) }
        names.save([.init(profile: "default", title: "Hermes")], for: URL(string: "https://studio.test")!)
        names.save([.init(profile: "dev", title: "Dev Bot")], for: URL(string: "https://elsewhere.test")!)

        let sections = await ProfileEntityProvider.sections(
            servers: [studio, air], active: URL(string: "https://studio.test"), names: names,
            webui: { XCTFail("No webui server is configured"); return [] }, liveNames: Self.liveNames
        )

        XCTAssertEqual(sections.map(\.title), ["Studio Mac"], "A host with no names to show has no section")
        XCTAssertEqual(sections.first?.profiles.map(\.id), ["https://studio.test|default"])
        XCTAssertEqual(sections.first?.profiles.map(\.name), ["Hermes"])
    }

    @MainActor
    func testSavedShortcutsResolveHermesIdsFromTheirConfiguredServer() async throws {
        let studio = account("https://studio.test", .hermes, named: "Studio Mac")
        let (names, suite, defaults) = makeIsolatedNames()
        defer { defaults.removePersistentDomain(forName: suite) }
        names.save([.init(profile: "inbox-triage", title: "Inbox Triage")], for: URL(string: "https://studio.test")!)

        let resolved = await ProfileEntityProvider.entities(
            for: ["https://studio.test|inbox-triage", "https://gone.test|dev", "dev"], servers: [studio], names: names,
            webui: { [ProfileEntity(id: "dev", name: "Dev", subtitle: nil)] }
        )

        XCTAssertEqual(resolved.map(\.id), ["https://studio.test|inbox-triage", "dev"],
                       "A removed server's Profile no longer resolves; a bare id resolves as before")
        XCTAssertEqual(resolved.first?.name, "Inbox Triage")
    }

    func testTheNameCacheIsPerServer() throws {
        let (names, suite, defaults) = makeIsolatedNames()
        defer { defaults.removePersistentDomain(forName: suite) }
        let studio = try XCTUnwrap(URL(string: "https://studio.test")), air = try XCTUnwrap(URL(string: "https://air.test"))

        XCTAssertTrue(names.save([.init(profile: "default", title: "Hermes")], for: studio))
        XCTAssertFalse(names.save([.init(profile: "default", title: "Hermes")], for: studio), "An identical roster is no change")
        XCTAssertTrue(names.save([.init(profile: "default", title: "Air")], for: air))
        names.remove(server: studio)

        XCTAssertEqual(names.names(for: studio), [])
        XCTAssertEqual(names.names(for: air), [.init(profile: "default", title: "Air")])
    }

    /// Server URLs are credential-like and stay out of the app group (#1180).
    func testTheNameCacheStoresNoServerURL() throws {
        let (names, suite, defaults) = makeIsolatedNames()
        defer { defaults.removePersistentDomain(forName: suite) }
        let studio = try XCTUnwrap(URL(string: "https://studio.test"))
        names.save([.init(profile: "default", title: "Hermes")], for: studio)

        let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(stored.count, 1)
        for (key, value) in stored {
            XCTAssertFalse(key.contains("studio.test"), key)
            let payload = String(decoding: try XCTUnwrap(value as? Data), as: UTF8.self)
            XCTAssertFalse(payload.contains("studio.test"), payload)
        }
        XCTAssertEqual(names.names(for: studio), [.init(profile: "default", title: "Hermes")])
    }

    /// `/api/status` through `ProfileStatusFixture`, as the picker reads it.
    private static let liveNames: @Sendable (ServerAccount) async -> [String]? = { account in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileStatusFixture.self]
        return await ProfileEntityProvider.liveProfileNames(of: account, probe: BotHostStatusProbe(configuration: configuration))
    }

    private func makeIsolatedNames() -> (HermesProfileNameCache, String, UserDefaults) {
        let suite = "test.hermesprofilenames.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (HermesProfileNameCache(defaults: defaults), suite, defaults)
    }

    func testWebuiEntryPointsLeaveAHermesServerForTheFirstWebuiServer() {
        let hermes = account("https://hermes.example", .hermes)
        let first = account("https://a.test", .webui), second = account("https://b.test", .webui)

        XCTAssertEqual(WebuiEntryRoute.resolve(active: URL(string: "https://hermes.example"), servers: [hermes, first, second]),
                       .switchServer(first))
        XCTAssertEqual(WebuiEntryRoute.resolve(active: URL(string: "https://hermes.example"), servers: [hermes]), .unavailable)
        XCTAssertEqual(WebuiEntryRoute.resolve(active: URL(string: "https://b.test"), servers: [hermes, first, second]), .stay)
        XCTAssertEqual(WebuiEntryRoute.resolve(active: nil, servers: [hermes]), .stay)
    }

    // MARK: - After Move to Hermes (#1217)

    /// A Hermes server holding move records for webui servers, each with Review's mappings.
    private func moved(_ id: String, from moves: [(source: String, profiles: [MovedWebuiProfile])]) -> ServerAccount {
        var holder = account(id, .hermes)
        holder.movedWebuiServers = moves.map { MovedWebuiServer(sourceServerID: $0.source, profiles: $0.profiles) }
        return holder
    }

    private func newChat(_ profile: String, active: String?, _ servers: [ServerAccount])
        -> MovedWebuiRoute.Outcome<HermesNewChatDestination> {
        MovedWebuiRoute.newChat(inProfile: profile, active: active.flatMap(URL.init(string:)), servers: servers)
    }

    /// Where a Hermes outcome opens, without the request's fresh id.
    private func opens(_ outcome: MovedWebuiRoute.Outcome<HermesNewChatDestination>) -> String? {
        guard case .hermes(let destination) = outcome else { return nil }
        return "\(destination.server.absoluteString)|\(destination.profile ?? "")"
    }

    /// A moved webui server's Profile opens where Review mapped it: a Hermes Profile, or the
    /// webui server it was kept on, which can't open it once removed.
    func testAWebuiProfileShortcutFollowsItsMove() {
        let webui = account("https://webui.test", .webui)
        let toResearch = moved("https://hermes.test", from: [("https://webui.test", [
            MovedWebuiProfile(source: "dev", destination: .hermes(profile: "research")),
            MovedWebuiProfile(source: "ops", destination: .keepOnWebui)
        ])])

        for active in ["https://webui.test", "https://hermes.test"] {
            XCTAssertEqual(opens(newChat("dev", active: active, [toResearch, webui])), "https://hermes.test|research")
        }
        XCTAssertEqual(newChat("ops", active: "https://webui.test", [toResearch, webui]), .webui(.stay))
        XCTAssertEqual(newChat("ops", active: "https://hermes.test", [toResearch, webui]), .webui(.switchServer(webui)))
        XCTAssertEqual(newChat("ops", active: "https://hermes.test", [toResearch]), .refuse,
                       "Kept on a webui server since removed")
        XCTAssertEqual(opens(newChat("dev", active: "https://hermes.test", [toResearch])), "https://hermes.test|research")
        XCTAssertEqual(newChat("qa", active: "https://webui.test", [toResearch, webui]), .webui(.unavailable),
                       "A Profile its Review didn't name never goes to the moved server")
    }

    /// Once a move names the Profile, every place that could take it counts, an unmoved webui
    /// server included, and the active server never breaks the tie. With no move naming it,
    /// today's route among unmoved webui servers.
    func testAWebuiProfileShortcutRefusesWhenAnotherPlaceCouldTakeIt() {
        let webui = account("https://webui.test", .webui), unmoved = account("https://other.test", .webui)
        let toResearch = moved("https://hermes.test", from: [("https://webui.test", [
            MovedWebuiProfile(source: "dev", destination: .hermes(profile: "research"))
        ])])
        for active in ["https://other.test", "https://hermes.test", "https://webui.test"] {
            XCTAssertEqual(newChat("dev", active: active, [toResearch, webui, unmoved]), .refuse, active)
        }
        XCTAssertEqual(newChat("qa", active: "https://other.test", [toResearch, webui, unmoved]), .webui(.stay))
        XCTAssertEqual(newChat("qa", active: "https://webui.test", [toResearch, webui, unmoved]), .webui(.switchServer(unmoved)))

        let toStudio = moved("https://studio.test", from: [("https://b.test", [
            MovedWebuiProfile(source: "dev", destination: .hermes(profile: "research"))
        ])])
        XCTAssertEqual(newChat("dev", active: "https://hermes.test", [toResearch, toStudio]), .refuse)
        let kept = moved("https://studio.test", from: [("https://b.test", [MovedWebuiProfile(source: "dev", destination: .keepOnWebui)])])
        XCTAssertEqual(newChat("dev", active: "https://hermes.test", [toResearch, kept]), .refuse,
                       "A removed webui server that kept the Profile still claims it")
        let sameMapping = moved("https://hermes.test", from: [
            ("https://webui.test", [MovedWebuiProfile(source: "dev", destination: .hermes(profile: "research"))]),
            ("https://b.test", [MovedWebuiProfile(source: "dev", destination: .hermes(profile: "research"))])
        ])
        XCTAssertEqual(opens(newChat("dev", active: "https://hermes.test", [sameMapping])), "https://hermes.test|research",
                       "Two moves that agree are one place")

        let none = [account("https://hermes.test", .hermes), webui, unmoved]
        XCTAssertEqual(newChat("dev", active: "https://hermes.test", none), .webui(.switchServer(webui)), "No move: as before")
    }

    /// A saved bare-id Shortcut keeps resolving while a move named its Profile, with its webui
    /// server gone, so running it decides where it goes.
    @MainActor func testASavedBareShortcutResolvesWhileAMoveNamesItsProfile() async {
        let (names, suite, defaults) = makeIsolatedNames()
        defer { defaults.removePersistentDomain(forName: suite) }
        let destination = moved("https://hermes.test", from: [("https://webui.test", [
            MovedWebuiProfile(source: "dev", destination: .hermes(profile: "research"))
        ])])

        let resolved = await ProfileEntityProvider.entities(for: ["dev", "qa"], servers: [destination], names: names,
                                                            webui: { [] })

        XCTAssertEqual(resolved.map(\.id), ["dev"])
    }

    // MARK: - Deep link shape

    func testBlankProfileNameProducesNoURL() {
        XCTAssertNil(HermesDeepLink.newChatInProfileURL(profileName: ""))
        XCTAssertNil(HermesDeepLink.newChatInProfileURL(profileName: "   "))
    }

    func testProfileNameWithSpacesAndUnicodeRoundTrips() throws {
        let name = "Work Café 工作"
        let url = try XCTUnwrap(HermesDeepLink.newChatInProfileURL(profileName: name))
        XCTAssertEqual(HermesDeepLink.profileName(fromNewChatInProfile: url), name)
    }

    func testProfileNameIsTrimmedOnBuildAndRead() throws {
        let url = try XCTUnwrap(HermesDeepLink.newChatInProfileURL(profileName: "  dev  "))
        XCTAssertEqual(HermesDeepLink.profileName(fromNewChatInProfile: url), "dev")
    }

    // MARK: - Non-aliasing with the other new-chat links

    func testProfileURLDoesNotAliasPlainVoiceOrSession() throws {
        let profileURL = try XCTUnwrap(HermesDeepLink.newChatInProfileURL(profileName: "dev"))
        XCTAssertFalse(HermesDeepLink.isNewChatURL(profileURL))
        XCTAssertFalse(HermesDeepLink.isNewChatVoiceURL(profileURL))
        XCTAssertNil(HermesDeepLink.sessionID(from: profileURL))
    }

    func testPlainVoiceAndSessionURLsAreNotProfileURLs() throws {
        let plain = try XCTUnwrap(HermesDeepLink.newChatURL)
        let voice = try XCTUnwrap(HermesDeepLink.newChatVoiceURL)
        let session = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: "abc123"))
        XCTAssertFalse(HermesDeepLink.isNewChatInProfileURL(plain))
        XCTAssertFalse(HermesDeepLink.isNewChatInProfileURL(voice))
        XCTAssertFalse(HermesDeepLink.isNewChatInProfileURL(session))
        XCTAssertNil(HermesDeepLink.profileName(fromNewChatInProfile: plain))
    }

    // MARK: - NewChatRequest threading

    // MARK: - Intent

    @MainActor
    func testIntentQueuesTheProfileDeepLink() async throws {
        var intent = NewChatInProfileIntent()
        intent.profile = ProfileEntity(id: "dev", name: "dev", subtitle: nil)
        _ = try await intent.perform()
        XCTAssertEqual(
            AppIntentRouter.shared.pendingDeepLink,
            HermesDeepLink.newChatInProfileURL(profileName: "dev")
        )
    }

    // MARK: - ProfileEntity mapping

    // MARK: - Cache

    func testCacheRoundTripsProfilesAsEntities() throws {
        let (cache, suite, defaults) = makeIsolatedCache()
        defer { defaults.removePersistentDomain(forName: suite) }

        cache.save([
            ProfileSummary(name: "default", path: nil, isDefault: true, isActive: true,
                           gatewayRunning: nil, model: "gpt", provider: "openai", hasEnv: nil, skillCount: nil),
            ProfileSummary(name: "dev", path: nil, isDefault: false, isActive: false,
                           gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        ])

        let loaded = cache.loadEntities()
        XCTAssertEqual(loaded.map(\.id), ["default", "dev"])
        XCTAssertEqual(loaded.first?.name, String(localized: "Default"))
        XCTAssertEqual(loaded.first?.subtitle, "gpt · openai")
    }

    func testCacheSkipsUnnamedProfiles() throws {
        let (cache, suite, defaults) = makeIsolatedCache()
        defer { defaults.removePersistentDomain(forName: suite) }

        cache.save([
            ProfileSummary(name: "  ", path: nil, isDefault: nil, isActive: nil,
                           gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil),
            ProfileSummary(name: "dev", path: nil, isDefault: nil, isActive: nil,
                           gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        ])

        XCTAssertEqual(cache.loadEntities().map(\.id), ["dev"])
    }

    func testSavingEmptyProfilesClearsTheCache() throws {
        let (cache, suite, defaults) = makeIsolatedCache()
        defer { defaults.removePersistentDomain(forName: suite) }

        cache.save([
            ProfileSummary(name: "dev", path: nil, isDefault: nil, isActive: nil,
                           gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        ])
        XCTAssertFalse(cache.loadEntities().isEmpty)

        cache.save([])
        XCTAssertTrue(cache.loadEntities().isEmpty)
    }

    func testSaveReportsChangeOnlyWhenTheSetMoves() throws {
        let (cache, suite, defaults) = makeIsolatedCache()
        defer { defaults.removePersistentDomain(forName: suite) }

        let dev = ProfileSummary(name: "dev", path: nil, isDefault: nil, isActive: nil,
                                 gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        let prod = ProfileSummary(name: "prod", path: nil, isDefault: nil, isActive: nil,
                                  gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil)

        XCTAssertTrue(cache.save([dev]), "first non-empty write is a change")
        XCTAssertFalse(cache.save([dev]), "identical write is not a change")
        XCTAssertTrue(cache.save([dev, prod]), "a new profile is a change")
        XCTAssertTrue(cache.save([]), "clearing a populated cache is a change")
        XCTAssertFalse(cache.save([]), "clearing an already-empty cache is not a change")
    }

    /// A `ProfileEntityCache` backed by a throwaway `UserDefaults` suite so tests never touch
    /// the real app-group cache.
    private func makeIsolatedCache() -> (ProfileEntityCache, String, UserDefaults) {
        let suite = "test.profileentitycache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ProfileEntityCache(defaults: defaults), suite, defaults)
    }
}

/// Answers `/api/status` per host from `replies`; any other host can't be reached.
private final class ProfileStatusFixture: URLProtocol {
    nonisolated(unsafe) static var replies: [String: (Int, String)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/api/status", let (status, body) = Self.replies[url.host ?? ""] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
