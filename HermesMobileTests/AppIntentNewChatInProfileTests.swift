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

    func testWebuiEntryPointsLeaveAHermesServerForTheFirstWebuiServer() {
        let hermes = account("https://hermes.example", .hermes)
        let first = account("https://a.test", .webui), second = account("https://b.test", .webui)

        XCTAssertEqual(WebuiEntryRoute.resolve(active: URL(string: "https://hermes.example"), servers: [hermes, first, second]),
                       .switchServer(first))
        XCTAssertEqual(WebuiEntryRoute.resolve(active: URL(string: "https://hermes.example"), servers: [hermes]), .unavailable)
        XCTAssertEqual(WebuiEntryRoute.resolve(active: URL(string: "https://b.test"), servers: [hermes, first, second]), .stay)
        XCTAssertEqual(WebuiEntryRoute.resolve(active: nil, servers: [hermes]), .stay)
    }

    // MARK: - Deep link shape

    func testNewChatInProfileURLUsesProfileHostAndCarriesName() throws {
        let url = try XCTUnwrap(HermesDeepLink.newChatInProfileURL(profileName: "dev"))
        XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
        XCTAssertEqual(url.host, HermesDeepLink.newChatInProfileHost)
        XCTAssertEqual(HermesDeepLink.profileName(fromNewChatInProfile: url), "dev")
    }

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

    func testIsNewChatInProfileURLIsCaseInsensitiveOnHost() throws {
        let url = try XCTUnwrap(URL(string: "\(HermesDeepLink.scheme)://New-Chat-Profile?profile=dev"))
        XCTAssertTrue(HermesDeepLink.isNewChatInProfileURL(url))
    }

    func testProfileNameNilWhenQueryMissing() throws {
        let url = try XCTUnwrap(URL(string: "\(HermesDeepLink.scheme)://new-chat-profile"))
        XCTAssertNil(HermesDeepLink.profileName(fromNewChatInProfile: url))
    }

    func testForeignSchemeIsNotAProfileURL() throws {
        let url = try XCTUnwrap(URL(string: "https://new-chat-profile?profile=dev"))
        XCTAssertFalse(HermesDeepLink.isNewChatInProfileURL(url))
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

    func testNewChatRequestDefaultsToNoProfile() {
        XCTAssertNil(NewChatRequest().profileName)
    }

    func testNewChatRequestCarriesProfileName() {
        XCTAssertEqual(NewChatRequest(profileName: "dev").profileName, "dev")
    }

    func testNewChatRequestVoiceAndProfileAreIndependent() {
        let request = NewChatRequest(autoStartsVoiceInput: false, profileName: "dev")
        XCTAssertFalse(request.autoStartsVoiceInput)
        XCTAssertEqual(request.profileName, "dev")
    }

    // MARK: - Intent

    func testIntentOpensAppWhenRun() {
        XCTAssertTrue(NewChatInProfileIntent.openAppWhenRun)
    }

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

    func testProfileEntityFromSummaryUsesNameAndModelProviderSubtitle() throws {
        let summary = ProfileSummary(
            name: "dev", path: nil, isDefault: false, isActive: false,
            gatewayRunning: nil, model: "kimi", provider: "opencode", hasEnv: nil, skillCount: nil
        )
        let entity = try XCTUnwrap(ProfileEntity(summary))
        XCTAssertEqual(entity.id, "dev")
        XCTAssertEqual(entity.name, "dev")
        XCTAssertEqual(entity.subtitle, "kimi · opencode")
    }

    func testDefaultProfileEntityUsesLocalizedDisplayName() throws {
        let summary = ProfileSummary(
            name: "default", path: nil, isDefault: true, isActive: true,
            gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil
        )
        let entity = try XCTUnwrap(ProfileEntity(summary))
        XCTAssertEqual(entity.id, "default")
        XCTAssertEqual(entity.name, String(localized: "Default"))
        XCTAssertNil(entity.subtitle)
    }

    func testProfileEntityIsNilForBlankName() {
        let summary = ProfileSummary(
            name: "   ", path: nil, isDefault: nil, isActive: nil,
            gatewayRunning: nil, model: nil, provider: nil, hasEnv: nil, skillCount: nil
        )
        XCTAssertNil(ProfileEntity(summary))
    }

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
