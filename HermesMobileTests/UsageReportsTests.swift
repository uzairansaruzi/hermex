import XCTest
@testable import HermesMobile

@MainActor
final class UsageReportsTests: XCTestCase {
    /// Wednesday of 2026-W46, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_398_400)
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let device = UsageDevice(channel: .testflight, appVersion: "1.9.0", osVersion: "26.1",
                                     deviceModel: "iPhone17,2", language: "en", region: "US")
    private var servers: [ServerAccount] = []

    override func setUp() {
        super.setUp()
        UsageReportFixture.reset()
        servers = [
            Self.server("https://mac.tail1234.ts.net:9119", kind: .hermes, version: "0.14.2"),
            Self.server("https://webui.example.com", kind: .webui, version: nil),
        ]
    }

    func testNothingIsTalliedOrSentWhileReportsAreOff() async throws {
        let defaults = try makeDefaults()
        let reports = makeReports(defaults: defaults)
        let rating = RatingPromptState(defaults: defaults, now: now, usage: reports)
        rating.recordCompletedResponse()
        reports.record(.tasks, now: now)
        SessionListCardState(card: .tip, defaults: defaults).openLinkFromCard(usage: reports)
        await reports.appBecameActive(now: now)
        XCTAssertNil(reports.thisWeek)

        await reports.appBecameActive(now: now.addingTimeInterval(week))
        XCTAssertNil(reports.thisWeek)
        XCTAssertTrue(UsageReportFixture.requests.isEmpty)
    }

    func testNothingIsTalliedOrSentWithoutAServer() async throws {
        let defaults = try makeDefaults()
        let reports = makeReports(defaults: defaults)
        reports.allow(now: now)
        reports.record(.tasks, now: now)
        servers = []
        let withoutServers = makeReports(defaults: defaults)
        withoutServers.record(.memory, now: now)
        XCTAssertEqual(withoutServers.thisWeek?.features, [.tasks])

        await withoutServers.appBecameActive(now: now.addingTimeInterval(week))
        XCTAssertTrue(UsageReportFixture.requests.isEmpty)
    }

    func testReportNamesNoServerAndReportsOnlyPlainReleases() throws {
        servers.append(Self.server("https://canary.example.org", kind: .hermes, version: "0.21.4+canary.my-host"))
        let report = UsageReport(version: 1, tallies: UsageTallies(week: UsageWeekID(containing: now)),
                                 firstReportOfMonth: true, installDate: now, device: device, servers: servers,
                                 settings: .init(pushEnabled: false, appLock: false))
        let body = String(decoding: try report.encoded(), as: UTF8.self)
        for leak in ["https", "tail1234", "webui.example.com", "canary.example.org", "my-host"] {
            XCTAssertFalse(body.contains(leak), leak)
        }
        XCTAssertEqual(report.servers.versions.map(\.version), ["0.14.2", "unknown", "other"])
        XCTAssertEqual(report.servers.hermes, 2)
        XCTAssertEqual(report.servers.webui, 1)
    }

    func testPreviewIsTheBodyThatIsSentOnceAfterTheWeekEnds() async throws {
        let defaults = try makeDefaults()
        let reports = makeReports(defaults: defaults)
        reports.allow(now: now)
        RatingPromptState(defaults: defaults, now: now, usage: reports).recordCompletedResponse()
        reports.record(.kanban, now: now)
        SessionListCardState(card: .tip, defaults: defaults).openLinkFromCard(usage: reports)
        let preview = await reports.preview(now: now)

        await reports.appBecameActive(now: now.addingTimeInterval(week))
        await reports.appBecameActive(now: now.addingTimeInterval(week + 60))
        XCTAssertEqual(UsageReportFixture.requests.count, 1)
        XCTAssertEqual(UsageReportFixture.requests.first?.body, try preview.encoded())
        XCTAssertEqual(preview.week, "2026-W46")
    }

    func testAFailedSendIsNeverRetriedByALaterLaunch() async throws {
        let defaults = try makeDefaults()
        UsageReportFixture.fails = true
        let reports = makeReports(defaults: defaults)
        reports.allow(now: now)
        await reports.appBecameActive(now: now.addingTimeInterval(week))
        XCTAssertEqual(UsageReportFixture.requests.count, 1)

        UsageReportFixture.fails = false
        await makeReports(defaults: defaults).appBecameActive(now: now.addingTimeInterval(week + 60))
        XCTAssertEqual(UsageReportFixture.requests.count, 1)
    }

    func testTalliesTwoWeeksOldAreDiscarded() async throws {
        let defaults = try makeDefaults()
        let reports = makeReports(defaults: defaults)
        reports.allow(now: now)
        await reports.appBecameActive(now: now.addingTimeInterval(2 * week))
        XCTAssertTrue(UsageReportFixture.requests.isEmpty)
        XCTAssertEqual(reports.thisWeek?.week, UsageWeekID(containing: now.addingTimeInterval(2 * week)))
    }

    func testTurningOffWhileTheReportIsBuiltSendsNothingEvenIfTurnedBackOn() async throws {
        let defaults = try makeDefaults()
        var reports: UsageReports?
        // Off and straight back on while the report is being built: the erased week stays unsent.
        reports = makeReports(defaults: defaults, device: { @MainActor [device, now, week] in
            reports?.turnOff()
            reports?.allow(now: now.addingTimeInterval(week))
            return device
        })
        reports?.allow(now: now)
        reports?.record(.skills, now: now)
        await reports?.appBecameActive(now: now.addingTimeInterval(week))
        XCTAssertTrue(UsageReportFixture.requests.isEmpty)
        XCTAssertEqual(reports?.thisWeek?.features, [])
        XCTAssertNil(defaults.data(forKey: UsageReports.Keys.endedWeek))
    }

    func testTheRequestCarriesNoCookieOrCredentialHeader() async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: UsageReports.collectorURL.host() ?? "", .path: "/",
                                                           .name: "session", .value: "secret"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        addTeardownBlock { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let defaults = try makeDefaults()
        let reports = makeReports(defaults: defaults)
        reports.allow(now: now)
        await reports.appBecameActive(now: now.addingTimeInterval(week))

        let headers = try XCTUnwrap(UsageReportFixture.requests.first?.headers)
        XCTAssertEqual(Set(headers.keys.map { $0.lowercased() }).subtracting(["content-type", "content-length"]), [])
    }

    func testADebugBuildNeverSends() async throws {
        let defaults = try makeDefaults()
        let reports = UsageReports(defaults: defaults, servers: { [servers] in servers },
                                   readSettings: { _ in .init(pushEnabled: false, appLock: false) },
                                   device: { [device] in device }, session: URLSession(configuration: UsageReportFixture.configuration()))
        reports.allow(now: now)
        await reports.appBecameActive(now: now.addingTimeInterval(week))
        XCTAssertTrue(UsageReportFixture.requests.isEmpty)
    }

    func testOnlyTheCardsOwnButtonsCountAndTheAboutRowsDoNot() throws {
        let defaults = try makeDefaults()
        let reports = makeReports(defaults: defaults)
        reports.allow(now: now)
        SessionListCardState(card: .star, defaults: defaults).recordLinkOpened()
        XCTAssertEqual(reports.thisWeek?.star, UsageCardTally())

        SessionListCardState(card: .tip, defaults: defaults).openLinkFromCard(usage: reports)
        SessionListCardState(card: .star, defaults: defaults).dismissFromCard(usage: reports)
        XCTAssertEqual(reports.thisWeek?.tip, UsageCardTally(linkOpened: true))
        XCTAssertEqual(reports.thisWeek?.star, UsageCardTally(dismissed: true))
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let name = "UsageReportsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeReports(defaults: UserDefaults, device: (() async -> UsageDevice)? = nil) -> UsageReports {
        UsageReports(defaults: defaults, servers: { [servers] in servers },
                     readSettings: { _ in .init(pushEnabled: true, appLock: false) },
                     device: device ?? { [device = self.device] in device },
                     session: URLSession(configuration: UsageReportFixture.configuration()), buildSends: true)
    }

    private static func server(_ url: String, kind: ServerKind, version: String?) -> ServerAccount {
        ServerAccount(id: url, urlString: url, displayName: "My Mac", initials: "MM",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .distantPast, updatedAt: .distantPast,
                      kind: kind, serverVersion: version)
    }
}

/// Stands in for the collector: records each request's headers and body, then answers 204 or fails.
private final class UsageReportFixture: URLProtocol {
    struct Request { let headers: [String: String]; let body: Data? }

    nonisolated(unsafe) private static var recorded: [Request] = []
    nonisolated(unsafe) static var fails = false
    private static let lock = NSLock()

    static var requests: [Request] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = []; fails = false } }

    /// The app's own configuration, with this fixture in front of the network.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.usageReports
        configuration.protocolClasses = [UsageReportFixture.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let fails = Self.lock.withLock {
            Self.recorded.append(Request(headers: request.allHTTPHeaderFields ?? [:], body: body))
            return Self.fails
        }
        if fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
