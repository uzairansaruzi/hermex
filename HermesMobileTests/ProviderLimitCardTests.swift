import XCTest
@testable import HermesMobile

/// The Usage screen's provider limit cards (#415): the pure presentation
/// helpers, the card builder, the provider selection rule, and the promise that
/// a failing or slow quota probe never disturbs the analytics on the same
/// screen.
///
/// Every time-sensitive assertion passes an explicit `now` and an explicit
/// locale, so nothing here depends on the clock or the runner's region.
final class ProviderLimitCardTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    // MARK: - Pure helpers

    func testTintTiersAtBoundaries() {
        XCTAssertEqual(providerLimitTint(remainingPercent: 100), .normal)
        XCTAssertEqual(providerLimitTint(remainingPercent: 25.1), .normal)
        XCTAssertEqual(providerLimitTint(remainingPercent: 25), .warning)
        XCTAssertEqual(providerLimitTint(remainingPercent: 10.1), .warning)
        XCTAssertEqual(providerLimitTint(remainingPercent: 10), .critical)
        XCTAssertEqual(providerLimitTint(remainingPercent: 0), .critical)
        // No number means no signal — a nil must not read as an emergency.
        XCTAssertEqual(providerLimitTint(remainingPercent: nil), .normal)
    }

    func testPercentTextRoundsAndClamps() {
        XCTAssertEqual(providerLimitPercentLeftText(100), "100% left")
        XCTAssertEqual(providerLimitPercentLeftText(2), "2% left")
        XCTAssertEqual(providerLimitPercentLeftText(0), "0% left")
        XCTAssertEqual(providerLimitPercentLeftText(1.6), "2% left")
        XCTAssertEqual(providerLimitPercentLeftText(140), "100% left")
        XCTAssertEqual(providerLimitPercentLeftText(-3), "0% left")
    }

    func testMoneyTextUsesUSDInTheGivenLocale() {
        XCTAssertEqual(providerLimitAmountLeftText(0, locale: enUS), "$0.00 left")
        XCTAssertEqual(providerLimitAmountLeftText(10.0296785, locale: enUS), "$10.03 left")
        XCTAssertEqual(usageFormattedCost(10, locale: enUS), "$10.00")
    }

    func testFractionClampsToTheBar() {
        XCTAssertEqual(providerLimitFraction(remainingPercent: 100), 1, accuracy: 0.0001)
        XCTAssertEqual(providerLimitFraction(remainingPercent: 2), 0.02, accuracy: 0.0001)
        XCTAssertEqual(providerLimitFraction(remainingPercent: -5), 0, accuracy: 0.0001)
        XCTAssertEqual(providerLimitFraction(remainingPercent: 250), 1, accuracy: 0.0001)
    }

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
        // Past, and inside the last minute, both read as imminent rather than
        // counting down to zero or going negative.
        XCTAssertEqual(providerLimitResetText(now.addingTimeInterval(-60), now: now, locale: enUS), "Resets soon")
        XCTAssertEqual(providerLimitResetText(now.addingTimeInterval(30), now: now, locale: enUS), "Resets soon")
        XCTAssertNil(providerLimitResetText(nil, now: now, locale: enUS))
    }

    func testResetCountdownSpellsUnitsOutForVoiceOver() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let spoken = try? XCTUnwrap(
            providerLimitResetText(now.addingTimeInterval(23 * 3600 + 35 * 60), now: now, width: .wide, locale: enUS)
        )

        XCTAssertEqual(spoken?.contains("23 hours"), true)
        XCTAssertEqual(spoken?.contains("35 minutes"), true)
    }

    func testUpdatedAgoUsesOneUnit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(providerLimitUpdatedText(now.addingTimeInterval(-41), now: now, locale: enUS), "Updated 41 sec ago")
        XCTAssertEqual(providerLimitUpdatedText(now, now: now, locale: enUS), "Updated 0 sec ago")
        XCTAssertEqual(providerLimitUpdatedText(now.addingTimeInterval(-5 * 60), now: now, locale: enUS), "Updated 5 min ago")
        XCTAssertEqual(providerLimitUpdatedText(now.addingTimeInterval(-3 * 3600), now: now, locale: enUS), "Updated 3 hr ago")
        XCTAssertNil(providerLimitUpdatedText(nil, now: now, locale: enUS))
    }

    func testParsesBothUpstreamTimestampShapes() {
        XCTAssertEqual(
            providerQuotaDate("2026-09-06T07:55:41Z"),
            Date(timeIntervalSince1970: 1_788_681_341)
        )
        // Microsecond precision, which ISO8601DateFormatter does not take
        // directly — the fraction is dropped rather than losing the row.
        let fractional = try? XCTUnwrap(providerQuotaDate("2026-09-06T02:56:37.848820Z"))
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, 1_788_663_397, accuracy: 1)
        XCTAssertNil(providerQuotaDate(nil))
        XCTAssertNil(providerQuotaDate("   "))
        XCTAssertNil(providerQuotaDate("not a date"))
    }

    // MARK: - Card building

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
        // The account payload carries its own timestamp; the client's is unused.
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
            // Available, but with nothing worth drawing.
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

    // MARK: - Selection rule

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

    func testSelectionIsEmptyWithoutKeyedProviders() {
        XCTAssertTrue(providerQuotaSelection(from: ProvidersResponse(
            providers: [ProviderSummary(id: "openai-codex", hasKey: false)],
            activeProvider: "openai-codex"
        )).isEmpty)

        XCTAssertTrue(providerQuotaSelection(from: ProvidersResponse(providers: nil, activeProvider: nil)).isEmpty)
    }

    /// The active provider is always probed when it holds a key, even when it is
    /// not one of the three Hermex knows about — the server is the authority on
    /// what it can answer for.
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

    // MARK: - View model

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

    /// A quota probe that never answers must not hold up — or corrupt — the
    /// analytics load that runs beside it.
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

    /// The generation guard: a superseded load must not repaint the cards a
    /// newer one already produced.
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

        // A second load starts while the first is still parked on its probe.
        client.holdsQuota = false
        await viewModel.loadLimits()
        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])

        client.releaseHeldQuota()
        await stale.value

        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
        // The stale probe answered last and still did not get to write.
        XCTAssertEqual(client.quotaCallCount, 2)
    }

    // MARK: - Loading placeholder state

    /// Nothing to probe means nothing to reserve room for: a server with no
    /// keyed provider must never flash the placeholder.
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
        // The placeholder holds the slot before any card exists.
        XCTAssertTrue(viewModel.limitCards.isEmpty)
        XCTAssertTrue(viewModel.showsLimits)

        client.releaseHeldQuota()
        await limits.value

        XCTAssertFalse(viewModel.isLoadingLimits)
        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"])
    }

    /// A failing `providers()` call is silent, but it still has to put the
    /// placeholder away rather than leaving it up forever.
    @MainActor
    func testLoadingFlagIsClearedWhenTheProvidersCallFails() async throws {
        let viewModel = InsightsViewModel(client: QuotaStubClient(providers: nil, quotas: [:]))

        await viewModel.loadLimits()

        XCTAssertFalse(viewModel.isLoadingLimits)
        XCTAssertFalse(viewModel.showsLimits)
    }

    /// The generation guard again, from the flag's side: a stale load finishing
    /// late must not take the newer load's placeholder down with it.
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

    // MARK: - Helpers

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

/// Scripts `/api/providers` and `/api/provider/quota`, and can park one quota
/// probe on a continuation so a test can order events without sleeping.
@MainActor
private final class QuotaStubClient: InsightsDataClient {
    var holdsQuota = false
    private(set) var refreshFlags: [Bool] = []
    private(set) var quotaCallCount = 0

    private let providersResponse: ProvidersResponse?
    private let quotas: [String: ProviderQuotaResponse]
    private let insightsResponse: InsightsResponse?
    /// Keyed by 1-based probe number so a test can park two loads at once and
    /// release the stale one first.
    private var heldContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

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
        guard let providersResponse else { throw QuotaStubError() }
        return providersResponse
    }

    func providerQuota(provider: String, refresh: Bool) async throws -> ProviderQuotaResponse {
        quotaCallCount += 1
        let call = quotaCallCount
        refreshFlags.append(refresh)

        if holdsQuota {
            await withCheckedContinuation { continuation in
                heldContinuations[call] = continuation
            }
        }

        guard let quota = quotas[provider] else { throw QuotaStubError() }
        return quota
    }

    /// Returns once `count` probes are parked at the same time.
    func waitForHeldQuota(count: Int = 1) async {
        while heldContinuations.count < count {
            await Task.yield()
        }
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
