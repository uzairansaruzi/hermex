import XCTest
@testable import HermesMobile

/// The Limits widget's snapshot (#1409): when a window stops showing its percentage, that a load
/// can't write after its server or connection went, and where its Usage link opens.
@MainActor final class ProviderLimitsSnapshotTests: XCTestCase {
    private let hermesServer = URL(string: "https://hermes.example")!
    private let webuiServer = URL(string: "https://a.test")!
    private let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!
    private var file: ProviderLimitsSnapshotFile { ProviderLimitsSnapshotFile(directory: directory) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func card(_ id: String, updatedAt: Date?, rows: [(String, Double, Date?)]) -> ProviderLimitCard {
        ProviderLimitCard(id: id, title: id.capitalized, plan: nil, rows: rows.map { label, percent, reset in
            ProviderLimitRow(id: "\(id)-\(label)", label: label, amount: nil, fraction: percent / 100,
                             remainingPercent: percent, resetAt: reset, note: nil)
        }, updatedAt: updatedAt)
    }

    private func scope(connectionID: UUID = UUID(), profile: String = "work") -> ProviderLimitsPublisher.Scope {
        ProviderLimitsPublisher.Scope(server: hermesServer, connectionID: connectionID, profile: profile)
    }

    func testAWindowStopsShowingItsPercentageAtResetOrAnHourAfterItsMeasurement() throws {
        let publisher = ProviderLimitsPublisher(file: file, reloadWidget: {})
        let ticket = publisher.ticket(for: scope())
        let codex = card("codex", updatedAt: measuredAt, rows: [("5h", 12, measuredAt + 30 * 60),
                                                                 ("Weekly", 54, measuredAt + 3 * 86_400)])
        publisher.publish([codex, card("claude", updatedAt: nil, rows: [("5h", 38, nil)])], stale: [],
                          with: ticket, now: measuredAt)
        let undated = try XCTUnwrap(file.read()?.providers.first { $0.id == "claude" })
        XCTAssertNil(undated.remainingPercent(of: undated.windows[0], at: measuredAt),
                     "A provider with no measurement time never shows a percentage")
        // The failed refresh 50 minutes later keeps the card: its measurement stays the old one.
        publisher.publish([codex], stale: ["codex"], with: ticket, now: measuredAt + 50 * 60)

        let snapshot = try XCTUnwrap(file.read())
        let provider = try XCTUnwrap(snapshot.providers.first)
        let fiveHour = provider.windows[0], weekly = provider.windows[1]
        XCTAssertEqual(provider.remainingPercent(of: fiveHour, at: measuredAt + 29 * 60), 12)
        XCTAssertNil(provider.remainingPercent(of: fiveHour, at: measuredAt + 30 * 60), "Past its reset")
        XCTAssertEqual(provider.remainingPercent(of: weekly, at: measuredAt + 59 * 60), 54)
        XCTAssertNil(provider.remainingPercent(of: weekly, at: measuredAt + 60 * 60), "An hour after measurement")
        XCTAssertTrue(provider.isStale)
        XCTAssertEqual(snapshot.deadlines(after: measuredAt), [measuredAt + 30 * 60, measuredAt + 60 * 60])

        try Data("{not json".utf8).write(to: file.url)
        XCTAssertNil(file.read(), "A corrupt file reads as no snapshot")
    }

    func testALoadCannotWriteOverANewerProfileOrAfterAServerSwitch() async throws {
        let publisher = ProviderLimitsPublisher(file: file, reloadWidget: {})
        let connectionID = UUID()
        func heldLoad(_ profile: String) async -> (InsightsViewModel, HeldQuotaClient, Task<Void, Never>) {
            let client = HeldQuotaClient()
            let viewModel = InsightsViewModel(client: client, publishesLimits: scope(connectionID: connectionID, profile: profile),
                                              publisher: publisher)
            let load = Task { await viewModel.loadLimits(refresh: true) }
            await fulfillment(of: [client.quotaHeld], timeout: 5)
            return (viewModel, client, load)
        }

        // Usage for "work" closes mid-refresh, and Usage for "home" opens and loads.
        let (_, closed, closedLoad) = await heldLoad("work")
        let (_, newer, newerLoad) = await heldLoad("home")
        newer.answer(40)
        await newerLoad.value
        closed.answer(12)
        await closedLoad.value
        XCTAssertEqual(file.read()?.profile, "home", "A closed Profile's late refresh")

        let (viewModel, client, load) = await heldLoad("home")
        publisher.invalidate()
        client.answer(40)
        await load.value
        XCTAssertEqual(viewModel.limitCards.count, 1, "The screen still shows what it loaded")
        XCTAssertNil(file.read(), "A load that started before a server switch")
    }

    func testTheWidgetEmptiesWhenItsServerOrConnectionStopsBeingTheOneInUse() async throws {
        let keychain = InMemoryKeychainStore()
        let publisher = ProviderLimitsPublisher(file: file, reloadWidget: {})
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: ServerRegistry.inMemory(keychain: keychain), hermesConnections: HermesConnections(),
            preferences: .ephemeral(), forgetPush: { _ in }, limitsPublisher: publisher)
        await manager.configure(serverURLString: webuiServer.absoluteString, password: "")
        let record = BotConnection(id: UUID(), name: "Studio", address: hermesServer, username: "me", password: "secret")
        XCTAssertTrue(manager.addHermesServer(record))
        let store = BotConnectionStore(keychain: keychain, limitsPublisher: publisher)
        func publish(_ connectionID: UUID) {
            publisher.publish([card("codex", updatedAt: measuredAt, rows: [("5h", 12, nil)])], stale: [],
                              with: publisher.ticket(for: scope(connectionID: connectionID)), now: measuredAt)
        }

        publish(record.id)
        manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.kind == .webui }))
        XCTAssertNil(file.read(), "Switching servers")

        manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.kind == .hermes }))
        publish(record.id)
        await manager.removeServer(try XCTUnwrap(manager.servers.first { $0.kind == .webui }))
        try store.save(record, server: hermesServer)
        XCTAssertNotNil(file.read(), "Removing another server, or saving the same connection again")

        // Every way to replace it (sign-in, the Bots editor) saves it through the store.
        let replacement = BotConnection(id: UUID(), name: "Studio", address: hermesServer, username: "you",
                                        password: "secret")
        try store.save(replacement, server: hermesServer)
        XCTAssertNil(file.read(), "Replacing the connection")

        publish(replacement.id)
        await manager.signOut()
        XCTAssertNil(file.read(), "Signing out")
    }

    func testAUsageLinkOpensOnlyOnTheSignedInActiveServerAndConnectionItNames() throws {
        let connectionID = UUID()
        let destination = HermesUsageDestination(serverKey: BotHistoryCache.Scope.key(hermesServer),
                                                 connectionID: connectionID, profile: "work")
        let link = try XCTUnwrap(HermesUsageDestination(url: try XCTUnwrap(destination.url)))
        XCTAssertEqual(link, destination)
        XCTAssertFalse(link.url?.absoluteString.contains("hermes.example") ?? true, "The link names no server URL")

        let servers = [account(hermesServer, kind: .hermes), account(webuiServer, kind: .webui)]
        func opens(_ state: AuthManager.State, saved: UUID?) -> Bool {
            link.opens(state: state, servers: servers, savedConnectionID: { _ in saved })
        }
        XCTAssertTrue(opens(.loggedIn(server: hermesServer), saved: connectionID))
        XCTAssertFalse(opens(.loggedIn(server: webuiServer), saved: connectionID), "Another server is active")
        XCTAssertFalse(opens(.loggedIn(server: hermesServer), saved: UUID()), "The connection was replaced")
        XCTAssertFalse(opens(.loggedOut(server: hermesServer), saved: connectionID), "Signed out")
    }

    private func account(_ server: URL, kind: ServerKind) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }
}

/// One keyed provider whose quota read waits until the test answers it.
@MainActor private final class HeldQuotaClient: InsightsDataClient {
    nonisolated var insightsFeatures: InsightsFeatures { .hermes }
    let quotaHeld = XCTestExpectation(description: "the quota read is held")
    private var pending: CheckedContinuation<ProviderQuotaResponse, Error>?

    func providers() async throws -> ProvidersResponse {
        ProvidersResponse(providers: [ProviderSummary(id: "openai-codex", displayName: "Codex", hasKey: true)],
                          activeProvider: "openai-codex")
    }

    func providerQuota(provider: String, refresh: Bool) async throws -> ProviderQuotaResponse {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            quotaHeld.fulfill()
        }
    }

    /// Answers the held read with one 5 h window at `remainingPercent`.
    func answer(_ remainingPercent: Double) {
        pending?.resume(returning: ProviderQuotaResponse(status: "available", accountLimits: ProviderAccountLimits(
            fetchedAt: "2027-01-15T08:00:00Z", windows: [ProviderQuotaWindow(label: "5h", remainingPercent: remainingPercent)])))
        pending = nil
    }

    func insights(days: Int) async throws -> InsightsResponse { throw BotFailure.unsupported }
    func sessions() async throws -> SessionsResponse { throw BotFailure.unsupported }
}
