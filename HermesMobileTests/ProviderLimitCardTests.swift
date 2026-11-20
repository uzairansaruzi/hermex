import XCTest
@testable import HermesMobile

final class ProviderLimitCardTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    func testResetCountdownAcrossMinutesHoursDaysAndThePast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            providerLimitResetText(now.addingTimeInterval(4 * 3600 + 59 * 60), now: now, locale: enUS),
            "Resets in 4h 59m"
        )
        XCTAssertEqual(
            providerLimitResetText(now.addingTimeInterval(23 * 3600 + 35 * 60), now: now, locale: enUS),
            "Resets in 23h 35m"
        )
        XCTAssertEqual(
            providerLimitResetText(now.addingTimeInterval(45 * 60), now: now, locale: enUS),
            "Resets in 45m"
        )
        XCTAssertEqual(
            providerLimitResetText(now.addingTimeInterval(27 * 3600), now: now, locale: enUS),
            "Resets in 1d 3h"
        )
        XCTAssertEqual(providerLimitResetText(now.addingTimeInterval(-60), now: now, locale: enUS), "Resets soon")
        XCTAssertEqual(providerLimitResetText(now.addingTimeInterval(30), now: now, locale: enUS), "Resets soon")
        XCTAssertNil(providerLimitResetText(nil, now: now, locale: enUS))
    }

    func testParsesBothUpstreamTimestampShapes() {
        XCTAssertEqual(
            providerQuotaDate("2026-09-06T07:55:41Z"),
            Date(timeIntervalSince1970: 1_788_681_341)
        )
        let fractional = try? XCTUnwrap(providerQuotaDate("2026-09-06T02:56:37.848820Z"))
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, 1_788_663_397, accuracy: 1)
        XCTAssertNil(providerQuotaDate(nil))
        XCTAssertNil(providerQuotaDate("   "))
        XCTAssertNil(providerQuotaDate("not a date"))
    }

    func testAccountLimitsCardKeepsWindowsInOrder() throws {
        let response = try decodeQuota(APIClientProviderQuotaTests.codexPayload)
        let card = try XCTUnwrap(
            ProviderLimitCard(provider: "openai-codex", response: response, fetchedAt: Date())
        )

        XCTAssertEqual(card.title, "OpenAI Codex")
        XCTAssertEqual(card.plan, "Plus")
        XCTAssertEqual(card.rows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(card.rows.map(\.amount), ["100% left", "2% left"])
        XCTAssertEqual(card.rows[1].fraction ?? 0, 0.02, accuracy: 0.0001)
        XCTAssertEqual(card.rows[0].resetAt, providerQuotaDate("2026-09-06T07:55:41Z"))
        XCTAssertEqual(card.updatedAt, providerQuotaDate("2026-09-06T02:56:37.848820Z"))
    }

    func testWindowWithoutRemainingPercentKeepsItsResetLineButLosesTheBar() throws {
        let response = try decodeQuota("""
        {
          "status": "available", "display_name": "Anthropic",
          "account_limits": {
            "available": true, "fetched_at": "2026-09-06T02:56:37Z",
            "windows": [
              {"label": "Weekly", "used_percent": null, "remaining_percent": null, "reset_at": "2026-09-07T02:28:47Z"}
            ]
          }
        }
        """)

        let row = try XCTUnwrap(
            ProviderLimitCard(provider: "anthropic", response: response, fetchedAt: Date())?.rows.first
        )

        XCTAssertEqual(row.label, "Weekly")
        XCTAssertNil(row.amount)
        XCTAssertNil(row.fraction)
        XCTAssertNil(row.remainingPercent)
        XCTAssertNotNil(row.resetAt)
    }

    func testCreditsCardUsesTheClientFetchTimeAndRatioBar() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)
        let card = try XCTUnwrap(
            ProviderLimitCard(provider: "openrouter", response: response, fetchedAt: fetchedAt)
        )

        XCTAssertEqual(card.title, "OpenRouter")
        XCTAssertNil(card.plan)
        XCTAssertEqual(card.updatedAt, fetchedAt)

        let row = try XCTUnwrap(card.rows.first)
        XCTAssertEqual(row.label, "Credits")
        XCTAssertEqual(row.amount, providerLimitAmountLeftText(0))
        XCTAssertEqual(row.fraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(providerLimitTint(remainingPercent: row.remainingPercent), .critical)
        XCTAssertEqual(row.note?.contains(usageFormattedCost(10)), true)
    }

    func testUncappedCreditsShowUsageWithoutABar() throws {
        let response = try decodeQuota("""
        {
          "status": "available", "display_name": "OpenRouter",
          "quota": {"limit_remaining": null, "usage": 4.5, "limit": null}
        }
        """)

        let row = try XCTUnwrap(
            ProviderLimitCard(provider: "openrouter", response: response, fetchedAt: Date())?.rows.first
        )

        XCTAssertNil(row.amount)
        XCTAssertNil(row.fraction)
        XCTAssertEqual(row.note, String(localized: "\(usageFormattedCost(4.5)) used"))
    }

    func testNonRenderablePayloadsProduceNoCard() throws {
        let cases = [
            #"{"status": "unsupported", "supported": false, "display_name": "OpenCode Free"}"#,
            #"{"status": "unavailable", "display_name": "Anthropic", "account_limits": null}"#,
            #"{"status": "no_key", "display_name": "OpenRouter", "quota": null}"#,
            #"{"status": "invalid_key", "display_name": "OpenRouter", "quota": null}"#,
            #"{"status": "available", "display_name": "Anthropic", "account_limits": {"available": true, "windows": []}}"#,
            #"{"status": "available", "display_name": "OpenRouter", "quota": {"limit_remaining": null, "usage": null, "limit": null}}"#
        ]

        for json in cases {
            let response = try decodeQuota(json)
            XCTAssertNil(
                ProviderLimitCard(provider: "p", response: response, fetchedAt: Date()),
                json
            )
        }
    }

    func testSelectionKeepsActiveProviderFirstAndOnlyKeyedCandidates() {
        let selection = providerQuotaSelection(from: ProvidersResponse(
            providers: [
                ProviderSummary(id: "opencode-free", hasKey: false),
                ProviderSummary(id: "openai-codex", hasKey: true),
                ProviderSummary(id: "openrouter", hasKey: true),
                ProviderSummary(id: "anthropic", hasKey: false)
            ],
            activeProvider: "opencode-free"
        ))

        XCTAssertEqual(selection, ["openai-codex", "openrouter"])
    }

    func testSelectionDoesNotDuplicateAnActiveCandidate() {
        let selection = providerQuotaSelection(from: ProvidersResponse(
            providers: [
                ProviderSummary(id: "openai-codex", hasKey: true),
                ProviderSummary(id: "openrouter", hasKey: true)
            ],
            activeProvider: "OpenAI-Codex"
        ))

        XCTAssertEqual(selection, ["openai-codex", "openrouter"])
    }

    func testSelectionAlwaysProbesTheKeyedActiveProvider() {
        let selection = providerQuotaSelection(from: ProvidersResponse(
            providers: [
                ProviderSummary(id: "openai", hasKey: true),
                ProviderSummary(id: "anthropic", hasKey: true)
            ],
            activeProvider: "openai"
        ))

        XCTAssertEqual(selection, ["openai", "anthropic"])
    }

    @MainActor
    func testLoadLimitsBuildsCardsInSelectionOrder() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [
                    ProviderSummary(id: "openai-codex", hasKey: true),
                    ProviderSummary(id: "openrouter", hasKey: true)
                ],
                activeProvider: "openrouter"
            ),
            quotas: [
                "openai-codex": try decodeQuota(APIClientProviderQuotaTests.codexPayload),
                "openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)
            ]
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.loadLimits()

        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter", "openai-codex"])
        XCTAssertEqual(client.refreshFlags, [false, false])
    }

    @MainActor
    func testRefreshPassesRefreshToEveryProbe() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openrouter", hasKey: true)],
                activeProvider: "openrouter"
            ),
            quotas: ["openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)]
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.loadLimits(refresh: true)

        XCTAssertEqual(client.refreshFlags, [true])
    }

    @MainActor
    func testFailingQuotaProbeLeavesAnalyticsAndErrorStateUntouched() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openrouter", hasKey: true)],
                activeProvider: "openrouter"
            ),
            quotas: [:],
            insights: try decodeInsights(#"{"period_days": 30, "total_tokens": 42}"#)
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.load()
        await viewModel.loadLimits()

        XCTAssertTrue(viewModel.limitCards.isEmpty)
        XCTAssertEqual(viewModel.totalTokens, 42)
        XCTAssertEqual(viewModel.dataSource, .server)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testFailingProvidersCallIsSilentAndLeavesAnalyticsAlone() async throws {
        let client = QuotaStubClient(
            providers: nil,
            quotas: [:],
            insights: try decodeInsights(#"{"period_days": 30, "total_tokens": 7}"#)
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.load()
        await viewModel.loadLimits()

        XCTAssertTrue(viewModel.limitCards.isEmpty)
        XCTAssertEqual(viewModel.totalTokens, 7)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testSlowQuotaProbeDoesNotDelayOrDisturbAnalytics() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openrouter", hasKey: true)],
                activeProvider: "openrouter"
            ),
            quotas: ["openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)],
            insights: try decodeInsights(#"{"period_days": 30, "total_tokens": 99}"#)
        )
        client.holdsQuota = true

        let viewModel = InsightsViewModel(client: client)
        let limits = Task { await viewModel.loadLimits() }

        await client.waitForHeldQuota()
        await viewModel.load()

        XCTAssertEqual(viewModel.totalTokens, 99)
        XCTAssertTrue(viewModel.limitCards.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)

        client.releaseHeldQuota()
        await limits.value

        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
    }

    @MainActor
    func testSupersededLoadDiscardsItsCards() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openrouter", hasKey: true)],
                activeProvider: "openrouter"
            ),
            quotas: ["openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)]
        )
        client.holdsQuota = true

        let viewModel = InsightsViewModel(client: client)
        let stale = Task { await viewModel.loadLimits() }
        await client.waitForHeldQuota()

        client.holdsQuota = false
        await viewModel.loadLimits()
        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])

        client.releaseHeldQuota()
        await stale.value

        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
        XCTAssertEqual(client.quotaCallCount, 2)
    }

    @MainActor
    func testFailedRefreshKeepsTheLastCardAndMarksItStale() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [
                    ProviderSummary(id: "openai-codex", hasKey: true),
                    ProviderSummary(id: "openrouter", hasKey: true)
                ],
                activeProvider: "openrouter"
            ),
            quotas: [
                "openai-codex": try decodeQuota(APIClientProviderQuotaTests.codexPayload),
                "openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)
            ]
        )
        let viewModel = InsightsViewModel(client: client)
        await viewModel.loadLimits()
        let loaded = viewModel.limitCards

        client.quotas = ["openai-codex": try decodeQuota(#"{"provider": "openai-codex", "status": "unavailable"}"#)]
        await viewModel.loadLimits(refresh: true)

        XCTAssertEqual(viewModel.limitCards, loaded)
        XCTAssertEqual(viewModel.staleLimitIDs, ["openrouter", "openai-codex"])

        client.quotas = [
            "openai-codex": try decodeQuota(APIClientProviderQuotaTests.codexPayload),
            "openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)
        ]
        await viewModel.loadLimits(refresh: true)

        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter", "openai-codex"])
        XCTAssertTrue(viewModel.staleLimitIDs.isEmpty)
    }

    @MainActor
    func testRefreshThatNoLongerQualifiesRemovesTheCard() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openrouter", hasKey: true)],
                activeProvider: "openrouter"
            ),
            quotas: ["openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)]
        )
        let viewModel = InsightsViewModel(client: client)
        await viewModel.loadLimits()

        client.quotas = ["openrouter": try decodeQuota(#"{"provider": "openrouter", "status": "no_key"}"#)]
        await viewModel.loadLimits(refresh: true)

        XCTAssertTrue(viewModel.limitCards.isEmpty)
        XCTAssertTrue(viewModel.staleLimitIDs.isEmpty)
    }

    @MainActor
    func testOnlyTheNewestFailedProvidersReadMarksCardsStale() async throws {
        let providers = ProvidersResponse(
            providers: [ProviderSummary(id: "openrouter", hasKey: true)],
            activeProvider: "openrouter"
        )
        let client = QuotaStubClient(
            providers: providers,
            quotas: ["openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)]
        )
        let viewModel = InsightsViewModel(client: client)
        await viewModel.loadLimits()

        client.holdsProviders = true
        let superseded = Task { await viewModel.loadLimits(refresh: true) }
        await client.waitForHeldProviders()

        client.holdsProviders = false
        await viewModel.loadLimits(refresh: true)
        client.providersResponse = nil
        client.releaseHeldProviders()
        await superseded.value

        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
        XCTAssertTrue(viewModel.staleLimitIDs.isEmpty)

        await viewModel.loadLimits(refresh: true)

        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
        XCTAssertEqual(viewModel.staleLimitIDs, ["openrouter"])
    }

    @MainActor
    func testLoadingFlagStaysFalseWithoutCandidateProviders() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openai-codex", hasKey: false)],
                activeProvider: "openai-codex"
            ),
            quotas: [:]
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.loadLimits()

        XCTAssertFalse(viewModel.isLoadingLimits)
        XCTAssertFalse(viewModel.showsLimits)
        XCTAssertEqual(client.quotaCallCount, 0)
    }

    @MainActor
    func testLoadingFlagIsTrueWhileAProbeIsPendingAndFalseOnceItResolves() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openrouter", hasKey: true)],
                activeProvider: "openrouter"
            ),
            quotas: ["openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)]
        )
        client.holdsQuota = true

        let viewModel = InsightsViewModel(client: client)
        let limits = Task { await viewModel.loadLimits() }
        await client.waitForHeldQuota()

        XCTAssertTrue(viewModel.isLoadingLimits)
        XCTAssertTrue(viewModel.limitCards.isEmpty)
        XCTAssertTrue(viewModel.showsLimits)

        client.releaseHeldQuota()
        await limits.value

        XCTAssertFalse(viewModel.isLoadingLimits)
        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
    }

    @MainActor
    func testLoadingFlagIsClearedWhenTheProvidersCallFails() async throws {
        let viewModel = InsightsViewModel(client: QuotaStubClient(providers: nil, quotas: [:]))

        await viewModel.loadLimits()

        XCTAssertFalse(viewModel.isLoadingLimits)
        XCTAssertFalse(viewModel.showsLimits)
    }

    @MainActor
    func testSupersededLoadDoesNotClearTheNewerLoadsFlag() async throws {
        let client = QuotaStubClient(
            providers: ProvidersResponse(
                providers: [ProviderSummary(id: "openrouter", hasKey: true)],
                activeProvider: "openrouter"
            ),
            quotas: ["openrouter": try decodeQuota(APIClientProviderQuotaTests.openRouterPayload)]
        )
        client.holdsQuota = true

        let viewModel = InsightsViewModel(client: client)
        let stale = Task { await viewModel.loadLimits() }
        await client.waitForHeldQuota(count: 1)

        let newer = Task { await viewModel.loadLimits() }
        await client.waitForHeldQuota(count: 2)
        XCTAssertTrue(viewModel.isLoadingLimits)

        client.releaseHeldQuota(call: 1)
        await stale.value

        XCTAssertTrue(viewModel.isLoadingLimits)
        XCTAssertTrue(viewModel.limitCards.isEmpty)

        client.releaseHeldQuota(call: 2)
        await newer.value

        XCTAssertFalse(viewModel.isLoadingLimits)
        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
    }

    private func decodeQuota(_ json: String) throws -> ProviderQuotaResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProviderQuotaResponse.self, from: Data(json.utf8))
    }

    private func decodeInsights(_ json: String) throws -> InsightsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(InsightsResponse.self, from: Data(json.utf8))
    }
}

@MainActor
private final class QuotaStubClient: InsightsDataClient {
    nonisolated var insightsFeatures: InsightsFeatures { .webui }
    var holdsQuota = false
    var holdsProviders = false
    private(set) var refreshFlags: [Bool] = []
    private(set) var quotaCallCount = 0

    var providersResponse: ProvidersResponse?
    var quotas: [String: ProviderQuotaResponse]
    private let insightsResponse: InsightsResponse?
    private var heldProviders: CheckedContinuation<Void, Never>?
    private var providersParkWaiter: CheckedContinuation<Void, Never>?
    private var heldContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var parkWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        providers: ProvidersResponse?,
        quotas: [String: ProviderQuotaResponse],
        insights: InsightsResponse? = nil
    ) {
        self.providersResponse = providers
        self.quotas = quotas
        self.insightsResponse = insights
    }

    func sessions() async throws -> SessionsResponse {
        throw QuotaStubError()
    }

    func insights(days: Int) async throws -> InsightsResponse {
        guard let insightsResponse else { throw QuotaStubError() }
        return insightsResponse
    }

    func providers() async throws -> ProvidersResponse {
        if holdsProviders {
            await withCheckedContinuation { continuation in
                heldProviders = continuation
                providersParkWaiter?.resume()
                providersParkWaiter = nil
            }
        }

        guard let providersResponse else { throw QuotaStubError() }
        return providersResponse
    }

    func waitForHeldProviders() async {
        guard heldProviders == nil else { return }
        await withCheckedContinuation { providersParkWaiter = $0 }
    }

    func releaseHeldProviders() {
        heldProviders?.resume()
        heldProviders = nil
    }

    func providerQuota(provider: String, refresh: Bool) async throws -> ProviderQuotaResponse {
        quotaCallCount += 1
        let call = quotaCallCount
        refreshFlags.append(refresh)

        if holdsQuota {
            await withCheckedContinuation { continuation in
                heldContinuations[call] = continuation
                let parked = heldContinuations.count
                let ready = parkWaiters.filter { $0.count <= parked }
                parkWaiters.removeAll { $0.count <= parked }
                ready.forEach { $0.continuation.resume() }
            }
        }

        guard let quota = quotas[provider] else { throw QuotaStubError() }
        return quota
    }

    func waitForHeldQuota(count: Int = 1) async {
        guard heldContinuations.count < count else { return }
        await withCheckedContinuation { parkWaiters.append((count, $0)) }
    }

    func releaseHeldQuota() {
        for continuation in heldContinuations.values {
            continuation.resume()
        }
        heldContinuations.removeAll()
    }

    func releaseHeldQuota(call: Int) {
        heldContinuations.removeValue(forKey: call)?.resume()
    }
}

private struct QuotaStubError: LocalizedError {
    var errorDescription: String? { "Quota probe failed" }
}
