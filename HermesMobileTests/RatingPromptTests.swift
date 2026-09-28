import XCTest
@testable import HermesMobile

final class RatingPromptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let server = URL(staticString: "https://rating.example")

    private func policy(count: Int = 10, age: Double = 3, lastRequestAge: Double? = nil, previousCount: Int = 0) -> RatingPromptPolicy {
        RatingPromptPolicy(
            firstLaunchDate: now.addingTimeInterval(-age * RatingPromptPolicy.day),
            completedResponses: count,
            lastRequestDate: lastRequestAge.map { now.addingTimeInterval(-$0 * RatingPromptPolicy.day) },
            responsesAtLastRequest: previousCount
        )
    }

    func testFirstRequestRequiresTenResponsesAndThreeDays() {
        XCTAssertFalse(policy(count: 0).isEligible(at: now))
        XCTAssertFalse(policy(count: 9).isEligible(at: now))
        XCTAssertFalse(policy(age: 2.99).isEligible(at: now))
        XCTAssertTrue(policy().isEligible(at: now))
        XCTAssertFalse(RatingPromptPolicy(firstLaunchDate: nil, completedResponses: 100,
                                         lastRequestDate: nil, responsesAtLastRequest: 0).isEligible(at: now))
    }

    func testLaterRequestsRequireBothCooldowns() {
        XCTAssertFalse(policy(count: 40, lastRequestAge: 59.99, previousCount: 10).isEligible(at: now))
        XCTAssertFalse(policy(count: 39, lastRequestAge: 60, previousCount: 10).isEligible(at: now))
        XCTAssertTrue(policy(count: 40, lastRequestAge: 60, previousCount: 10).isEligible(at: now))
        XCTAssertFalse(policy(count: 40, lastRequestAge: -1, previousCount: 10).isEligible(at: now))
    }

    func testTipCardWaitsSevenDaysAfterRatingRequest() {
        XCTAssertTrue(policy().allowsTipCard(at: now))
        XCTAssertFalse(policy(lastRequestAge: 6.99).allowsTipCard(at: now))
        XCTAssertTrue(policy(lastRequestAge: 7).allowsTipCard(at: now))
    }

    @MainActor
    func testFirstLaunchRecordedOnceAndBlocksEntireFirstLaunch() throws {
        let defaults = try makeDefaults()
        let first = RatingPromptState(defaults: defaults, now: now)
        for _ in 0..<10 { first.recordCompletedResponse() }
        XCTAssertFalse(first.canRequest(at: now.addingTimeInterval(4 * RatingPromptPolicy.day)))
        let nextLaunch = RatingPromptState(defaults: defaults, now: now.addingTimeInterval(4 * RatingPromptPolicy.day))
        XCTAssertEqual(nextLaunch.policy.firstLaunchDate, now)
        XCTAssertEqual(nextLaunch.policy.completedResponses, 10)
        XCTAssertTrue(nextLaunch.canRequest(at: now.addingTimeInterval(4 * RatingPromptPolicy.day)))
    }

    @MainActor
    func testOnlyQuietWarmMomentsRequestAndRecordBeforeCallingStoreKit() throws {
        let state = try makeEligibleState()
        var calls = 0
        let request = { calls += 1 }
        XCTAssertFalse(state.requestIfEligible(moment: .coldLaunch, isSessionListVisible: true, hasActiveStream: false, request: request))
        XCTAssertFalse(state.requestIfEligible(moment: .foreground, isSessionListVisible: false, hasActiveStream: false, request: request))
        XCTAssertFalse(state.requestIfEligible(moment: .returnedToSessionList, isSessionListVisible: true, hasActiveStream: true, request: request))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(state.requestIfEligible(moment: .foreground, isSessionListVisible: true, hasActiveStream: false) {
            XCTAssertNotNil(state.policy.lastRequestDate)
            XCTAssertEqual(state.policy.responsesAtLastRequest, 10)
            calls += 1
        })
        XCTAssertFalse(state.requestIfEligible(moment: .returnedToSessionList, isSessionListVisible: true, hasActiveStream: false, request: request))
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testTipShownInThisLaunchSuppressesRatingEvenAfterDismissal() throws {
        let state = try makeEligibleState()
        state.recordTipCardShown()
        XCTAssertFalse(state.canRequest())
    }

    @MainActor
    func testResetRestoresFreshState() throws {
        let state = try makeEligibleState()
        state.requestIfEligible(moment: .returnedToSessionList, isSessionListVisible: true, hasActiveStream: false, request: {})
        state.recordTipCardShown()
        state.reset(now: now)
        XCTAssertEqual(state.policy.firstLaunchDate, now)
        XCTAssertEqual(state.policy.completedResponses, 0)
        XCTAssertNil(state.policy.lastRequestDate)
        XCTAssertEqual(state.policy.responsesAtLastRequest, 0)
        XCTAssertTrue(state.isFirstLaunch)
        XCTAssertFalse(state.tipCardShownThisLaunch)
    }

    @MainActor
    func testFreshRemoteStreamBlocksRequestEvenIfHiddenFromSidebar() async throws {
        let state = try makeEligibleState()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let sessions = try decoder.decode([SessionSummary].self, from: Data(#"[{"session_id":"hidden","archived":true,"active_stream_id":"s1"}]"#.utf8))
        await state.requestWhenQuiet(moment: .foreground, server: server, isSessionListVisible: { true }, loadSessions: { sessions }) {
            XCTFail("A remote stream must block the request")
        }
        XCTAssertNil(state.policy.lastRequestDate)
    }

    @MainActor
    func testNavigationChangedDuringRefreshSkipsRequest() async throws {
        let state = try makeEligibleState()
        var visible = true
        await state.requestWhenQuiet(moment: .returnedToSessionList, server: server, isSessionListVisible: { visible }, loadSessions: {
            visible = false
            return []
        }) { XCTFail("A stale list check must not prompt") }
        XCTAssertNil(state.policy.lastRequestDate)
    }

    @MainActor
    func testCancelledRefreshSkipsRequest() async throws {
        let state = try makeEligibleState()
        let task = Task {
            await state.requestWhenQuiet(moment: .foreground, server: server, isSessionListVisible: { true }, loadSessions: {
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }) { XCTFail("Cancelled work must not prompt") }
        }
        await task.value
        XCTAssertNil(state.policy.lastRequestDate)
    }

    @MainActor
    func testUnavailableSessionDataSkipsRequest() async throws {
        let state = try makeEligibleState()
        await state.requestWhenQuiet(moment: .foreground, server: server, isSessionListVisible: { true }, loadSessions: { nil }) {
            XCTFail("Missing server data must not count as idle")
        }
        await state.requestWhenQuiet(moment: .foreground, server: server, isSessionListVisible: { true }, loadSessions: {
            throw URLError(.notConnectedToInternet)
        }) { XCTFail("Offline must not count as idle") }
        XCTAssertNil(state.policy.lastRequestDate)
    }

    @MainActor
    func testQuietReturnRequestsOnceAndPersistsCooldown() async throws {
        let state = try makeEligibleState()
        var calls = 0
        for _ in 0..<2 {
            await state.requestWhenQuiet(moment: .returnedToSessionList, server: server, isSessionListVisible: { true }, loadSessions: { [] }) {
                calls += 1
            }
        }
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(state.policy.lastRequestDate)
    }

    @MainActor
    private func makeEligibleState() throws -> RatingPromptState {
        let defaults = try makeDefaults()
        defaults.set(Date().addingTimeInterval(-4 * RatingPromptPolicy.day), forKey: RatingPromptSettings.firstLaunchDateKey)
        defaults.set(10, forKey: TipJar.completedResponseCountKey)
        return RatingPromptState(defaults: defaults)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "RatingPromptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
