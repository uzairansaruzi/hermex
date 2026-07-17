import XCTest
@testable import HermesMobile

@MainActor
final class KanbanFeatureStateTests: XCTestCase {
    func testCompatibleHandshakeIsOrderedAndBoundToItsServer() async {
        let client = KanbanClientStub()
        let firstServer = URL(string: "https://first.example.test")!
        let secondServer = URL(string: "https://second.example.test")!
        let first = KanbanFeatureState(server: firstServer, client: client)
        let second = KanbanFeatureState(server: secondServer, client: client)

        await first.load()

        XCTAssertEqual(first.state, .compatible)
        XCTAssertEqual(first.server, firstServer)
        XCTAssertEqual(second.state, .idle)
        XCTAssertEqual(second.server, secondServer)
        let calls = await client.calls()
        XCTAssertEqual(calls, [
            .configuration,
            .boards,
            .board(KanbanBoardRequest(board: "main")),
            .stats("main"),
            .assignees("main")
        ])
    }

    func testCommentCapabilityUsesEnvelopePermissionAndHonorsExplicitBoardReadOnly() async {
        let writable = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub()
        )
        await writable.load()

        // The verified Boards contract carries read_only on the envelope, not
        // each Board entry. A missing per-Board value must not override three
        // explicit writable envelope values.
        XCTAssertNil(writable.selectedBoard?.readOnly)
        XCTAssertTrue(writable.canAddComments)
        XCTAssertTrue(writable.canMutateCards)

        let explicitReadOnly = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(boardsResult: .success(KanbanFixtures.readOnlyBoard))
        )
        await explicitReadOnly.load()
        XCTAssertEqual(explicitReadOnly.selectedBoard?.readOnly, true)
        XCTAssertFalse(explicitReadOnly.canAddComments)
        XCTAssertFalse(explicitReadOnly.canMutateCards)
    }

    func testAuthenticationForwardsToExistingHandler() async {
        let client = KanbanClientStub(configurationResult: .failure(APIError.unauthorized))
        var forwardedErrors: [Error] = []
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client,
            onAPIError: { forwardedErrors.append($0) }
        )

        await state.load()

        XCTAssertEqual(state.state, .authenticationRequired)
        XCTAssertEqual(forwardedErrors.count, 1)
        XCTAssertTrue(forwardedErrors.first is APIError)
    }

    func testNetworkServerAndContractFailuresStayDistinct() async {
        let network = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(APIError.network(underlying: URLError(.notConnectedToInternet))))
        )
        await network.load()
        XCTAssertEqual(network.state, .networkUnavailable)

        let server = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(APIError.http(statusCode: 503, body: nil)))
        )
        await server.load()
        XCTAssertEqual(server.state, .serverUnavailable)

        let contract = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(KanbanResponseError.nonJSONContentType))
        )
        await contract.load()
        XCTAssertEqual(contract.state, .incompatibleContract)
    }

    func testCancelledHandshakeReturnsToIdle() async {
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(CancellationError()))
        )

        await state.load()

        XCTAssertEqual(state.state, .idle)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.report)
    }

    func testStaleHandshakeCompletionCannotReplaceNewerResult() async {
        let client = DeferredFirstConfigurationClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)

        let firstLoad = Task { await state.load() }
        await client.waitForFirstConfiguration()

        await state.load()
        XCTAssertEqual(state.state, .compatible)

        await client.resumeFirstConfiguration()
        await firstLoad.value

        XCTAssertEqual(state.state, .compatible)
        XCTAssertFalse(state.isLoading)
    }

    func testStatusSearchUnknownStatusAndClearFiltersUseLoadedBoardData() async {
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(boardResult: .success(KanbanFixtures.richSnapshot))
        )
        await state.load()

        XCTAssertEqual(Array(state.availableStatuses.prefix(6)), KanbanFeatureState.liveStatuses)
        XCTAssertTrue(state.availableStatuses.contains("future"))
        state.selectedStatus = "ready"
        for query in ["CARD-1", "Status Focus", "markdown", "builder", "mobile"] {
            state.searchText = query
            XCTAssertEqual(state.visibleCards.map(\.cardID), ["CARD-1"], query)
        }

        state.searchText = "missing"
        XCTAssertTrue(state.visibleCards.isEmpty)
        await state.applyFilters(profile: "builder", tenant: "mobile", includeArchived: true, onlyMine: false)
        XCTAssertTrue(state.hasActiveFilters)
        await state.clearFilters()
        XCTAssertFalse(state.hasActiveFilters)
        XCTAssertEqual(state.selectedStatus, "ready")
    }

    func testFilterAndBoardTransitionsPreserveLocalPresentationState() async {
        let client = BrowsingClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        state.selectedStatus = "running"
        state.searchText = "worker"
        state.groupByProfile = true

        await state.applyFilters(profile: "review", tenant: "ops", includeArchived: true, onlyMine: true)
        XCTAssertNil(state.selectedProfile)
        XCTAssertEqual(state.selectedTenant, "ops")
        XCTAssertTrue(state.onlyMine)
        XCTAssertTrue(state.includeArchived)
        let lastFilterRequest = await client.boardRequests().last
        XCTAssertEqual(lastFilterRequest, KanbanBoardRequest(
            board: "main",
            tenant: "ops",
            includeArchived: true,
            onlyMine: true
        ))

        await state.selectBoard("release")
        XCTAssertEqual(state.selectedBoardSlug, "release")
        XCTAssertEqual(state.selectedStatus, "running")
        XCTAssertEqual(state.searchText, "worker")
        XCTAssertTrue(state.groupByProfile)
        XCTAssertEqual(state.selectedTenant, "ops")
        XCTAssertTrue(state.includeArchived)
        XCTAssertTrue(state.onlyMine)
    }

    func testBoardSwitchClearsBoardScopedDataAndRevalidatesCompatibility() async {
        let client = DeferredBoardSwitchClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        XCTAssertNotNil(state.snapshot)
        XCTAssertNotNil(state.stats)
        XCTAssertNotNil(state.assigneeHistory)

        let switchBoard = Task { await state.selectBoard("release") }
        await client.waitForReleaseRead()

        XCTAssertEqual(state.selectedBoardSlug, "release")
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.stats)
        XCTAssertNil(state.assigneeHistory)
        XCTAssertTrue(state.isRefreshing)

        await client.resumeReleaseRead()
        await switchBoard.value

        XCTAssertEqual(state.report?.board.slug, "release")
        XCTAssertEqual(state.report?.warnings, [.unsupportedStatus("future")])
        XCTAssertEqual(state.state, .partial)
        XCTAssertEqual(state.allCards.map(\.cardID), ["FUTURE-1"])
    }

    func testPullToRefreshPerformsFullReconciliation() async {
        let client = BrowsingClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let before = state.allCards

        await state.refresh()

        XCTAssertEqual(state.allCards, before)
        let lastRequest = await client.boardRequests().last
        XCTAssertNil(lastRequest?.since)
        XCTAssertFalse(state.refreshFailed)
    }

    func testRefreshRejectsMissingChangedAndPreservesStableCards() async {
        let client = MissingChangedRefreshClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let before = state.allCards

        await state.refresh()

        XCTAssertEqual(state.allCards, before)
        XCTAssertTrue(state.refreshFailed)
    }

    func testStaleFilteredReadCannotReplaceNewerFilterResult() async {
        let client = DeferredBoardClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        let stale = Task { await state.setTenantFilter("ops") }
        await client.waitForDeferredRead()
        await state.setProfileFilter("review")
        XCTAssertEqual(state.allCards.first?.cardID, "NEW")

        await client.resumeDeferredRead()
        await stale.value
        XCTAssertEqual(state.allCards.first?.cardID, "NEW")
    }

    func testCanonicalStatusAndCardAccessibilityCopy() throws {
        XCTAssertEqual(KanbanStatusPresentation("triage").title, String(localized: "Triage"))
        XCTAssertEqual(KanbanStatusPresentation("todo").title, String(localized: "To Do"))
        XCTAssertEqual(KanbanStatusPresentation("ready").title, String(localized: "Ready"))
        XCTAssertEqual(KanbanStatusPresentation("running").title, String(localized: "Running"))
        XCTAssertEqual(KanbanStatusPresentation("blocked").title, String(localized: "Blocked"))
        XCTAssertEqual(KanbanStatusPresentation("done").title, String(localized: "Done"))
        XCTAssertEqual(KanbanStatusPresentation("archived").title, String(localized: "Archived"))
        XCTAssertTrue(KanbanStatusPresentation("future").title.contains("future"))

        let card = try XCTUnwrap(KanbanFixtures.richSnapshot.columns?[1].cards?.first)
        let summary = KanbanCardAccessibility.summary(card)
        XCTAssertTrue(summary.contains("CARD-1"))
        XCTAssertTrue(summary.contains("Status Focus"))
        XCTAssertTrue(summary.contains(String(localized: "Ready")))
        XCTAssertTrue(summary.contains("builder"))
        XCTAssertTrue(summary.contains("mobile"))
        XCTAssertEqual(KanbanCountFormatter.cards(1), "1 Card")
        XCTAssertEqual(KanbanCountFormatter.cards(2), "2 Cards")
    }

    func testStatusSpecificStalenessThresholds() {
        let cards = KanbanFixtures.stalenessSnapshot.columns?.flatMap { $0.cards ?? [] } ?? []
        XCTAssertEqual(cards.map(\.staleness), [
            .none, .warning, .critical,
            .none, .warning,
            .none, .warning, .critical
        ])
    }

    func testCardMutationsAreOptimisticSerializedPerCardAndConcurrentAcrossCards() async throws {
        let client = DeferredMutationClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let firstCard = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })
        let secondCard = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-2" })

        let firstWrite = Task { await state.moveCard(firstCard, to: "ready") }
        try await waitUntil { await client.statusRequestCount == 1 }
        XCTAssertEqual(state.allCards.first { $0.cardID == "CARD-1" }?.status?.rawValue, "ready")
        XCTAssertEqual(state.mutationState(for: "CARD-1")?.phase, .updating)

        // A canonical refresh that still carries the old status must not erase
        // the pending optimistic status.
        await state.refresh()
        XCTAssertEqual(state.allCards.first { $0.cardID == "CARD-1" }?.status?.rawValue, "ready")

        let duplicateWrite = Task { await state.completeCard(firstCard) }
        let unrelatedWrite = Task { await state.moveCard(secondCard, to: "todo") }
        try await waitUntil { await client.statusRequestCount == 2 }
        let firstCardRequestCount = await client.requestCount(for: "CARD-1")
        let maximumConcurrentWrites = await client.maximumConcurrentWrites
        XCTAssertEqual(firstCardRequestCount, 1)
        XCTAssertEqual(maximumConcurrentWrites, 2)

        await client.finish(cardID: "CARD-1", status: "ready")
        await client.finish(cardID: "CARD-2", status: "todo")
        await firstWrite.value
        await duplicateWrite.value
        await unrelatedWrite.value

        XCTAssertEqual(state.mutationState(for: "CARD-1")?.phase, .succeeded)
        XCTAssertEqual(state.mutationState(for: "CARD-2")?.phase, .succeeded)
    }

    func testAmbiguousMutationRequiresReconciliationBeforeTryAgain() async throws {
        let network = APIError.network(underlying: URLError(.networkConnectionLost))
        let client = ImmediateMutationClient(
            statusResults: [.failure(network)],
            detailResults: [
                .failure(network),
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"done"}}"#))
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.completeCard(card)

        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .outcomeUncertain)
        var statusRequestCount = await client.statusRequestCount
        XCTAssertEqual(statusRequestCount, 1)
        await state.refresh()
        XCTAssertEqual(
            state.allCards.first { $0.cardID == card.cardID }?.status?.rawValue,
            "todo",
            "An ordinary refresh must preserve the recoverable Card until uncertainty is explicitly checked."
        )
        await state.checkUncertainMutation(for: card)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .succeeded)
        statusRequestCount = await client.statusRequestCount
        XCTAssertEqual(statusRequestCount, 1, "A result check must never repeat the write.")
    }

    func testArchiveUndoUsesFreshAuthoritativeStateAndDependencyRefusalsPersist() async throws {
        let client = ImmediateMutationClient(
            statusResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"archived"}}"#)),
                .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"todo"}}"#))
            ],
            detailResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"archived"}}"#))
            ],
            dependencyResult: .failure(APIError.http(statusCode: 409, body: #"{"error":"cycle"}"#))
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.archiveCard(card)
        XCTAssertTrue(state.hasAvailableArchiveUndo)
        XCTAssertFalse(state.allCards.contains { $0.cardID == card.cardID })

        await state.undoArchive()
        XCTAssertEqual(state.allCards.first { $0.cardID == card.cardID }?.status?.rawValue, "todo")
        let detailRequestCount = await client.detailRequestCount
        XCTAssertEqual(detailRequestCount, 1, "Undo must read current authoritative state first.")

        let restored = try XCTUnwrap(state.allCards.first { $0.cardID == card.cardID })
        await state.addPrerequisite("CARD-2", to: restored)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .failed)
        let dependencyRequestCount = await client.dependencyRequestCount
        XCTAssertEqual(dependencyRequestCount, 1)
    }

    func testUnknownStatusAndRunningDestinationCannotConstructWrites() async throws {
        let client = ImmediateMutationClient(snapshot: mutationSnapshot(status: "future"))
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        XCTAssertFalse(state.canMutateCard(card))
        await state.moveCard(card, to: "running")
        let statusRequestCount = await client.statusRequestCount
        XCTAssertEqual(statusRequestCount, 0)
    }

    func testArchiveUndoExpiresWithoutIssuingAnotherWrite() async throws {
        let client = ImmediateMutationClient(statusResults: [
            .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"archived"}}"#))
        ])
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client,
            archiveUndoLifetime: 0.01
        )
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.archiveCard(card)
        XCTAssertTrue(state.hasAvailableArchiveUndo)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(state.hasAvailableArchiveUndo)
        let statusRequestCount = await client.statusRequestCount
        XCTAssertEqual(statusRequestCount, 1)
    }

    func testRunningExitRequiresExplicitConfirmationBeforeWriteConstruction() async throws {
        let client = ImmediateMutationClient(
            snapshot: mutationSnapshot(status: "running"),
            statusResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"done"}}"#))
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.completeCard(card)
        var requestCount = await client.statusRequestCount
        XCTAssertEqual(requestCount, 0)

        await state.completeCard(card, confirmingRunningExit: true)
        requestCount = await client.statusRequestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .succeeded)
    }

    func testUncertainArchiveUndoStaysRecoverableAndChecksBeforeAnotherWrite() async throws {
        let network = APIError.network(underlying: URLError(.networkConnectionLost))
        let client = ImmediateMutationClient(
            statusResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"archived"}}"#)),
                .failure(network)
            ],
            detailResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"archived"}}"#)),
                .failure(network),
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"todo"}}"#))
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.archiveCard(card)
        await state.undoArchive()
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .outcomeUncertain)
        XCTAssertTrue(state.hasAvailableArchiveUndo)
        var requestCount = await client.statusRequestCount
        XCTAssertEqual(requestCount, 2)

        let recoveryCard = try XCTUnwrap(state.archiveUndo?.card)
        await state.checkUncertainMutation(for: recoveryCard)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .succeeded)
        XCTAssertFalse(state.hasAvailableArchiveUndo)
        requestCount = await client.statusRequestCount
        XCTAssertEqual(requestCount, 2, "Checking an uncertain Undo must not repeat the write.")
    }

    func testSuccessfulStatusPresentationPersistsUntilFreshDetailLoads() async throws {
        let client = ImmediateMutationClient(
            statusResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"done"}}"#))
            ],
            detailResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"done"}}"#))
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let staleCard = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })
        let detailState = try XCTUnwrap(state.makeCardDetailState(cardID: "CARD-1"))

        await state.completeCard(staleCard)

        XCTAssertEqual(state.displayedCard(staleCard).status?.rawValue, "done")
        await state.refresh()
        XCTAssertEqual(
            state.allCards.first { $0.cardID == "CARD-1" }?.status?.rawValue,
            "todo",
            "A settled detail overlay must not mask a later authoritative Board refresh."
        )
        XCTAssertEqual(state.displayedCard(staleCard).status?.rawValue, "done")
        await detailState.load()
        let laterCanonical: KanbanCardDetailEnvelope = mutationDecode(
            #"{"task":{"id":"CARD-1","status":"ready"}}"#
        )
        XCTAssertEqual(
            state.displayedCard(try XCTUnwrap(laterCanonical.card)).status?.rawValue,
            "ready",
            "A successful detail load must retire the settled status overlay."
        )
    }

    func testSuccessfulDependencyPresentationPersistsUntilFreshDetailLoads() async throws {
        let confirmed: KanbanCardDetailEnvelope = mutationDecode(
            #"{"task":{"id":"CARD-1","status":"todo"},"links":{"parents":["CARD-2"]}}"#
        )
        let client = ImmediateMutationClient(detailResults: [.success(confirmed), .success(confirmed)])
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })
        let detailState = try XCTUnwrap(state.makeCardDetailState(cardID: "CARD-1"))

        await state.addPrerequisite("CARD-2", to: card)

        XCTAssertEqual(state.displayedPrerequisites(for: "CARD-1", canonical: []), ["CARD-2"])
        await detailState.load()
        XCTAssertEqual(
            state.displayedPrerequisites(for: "CARD-1", canonical: []),
            [],
            "A successful detail load must retire the settled dependency overlay."
        )
    }

    func testUndoArchiveNotFoundDuringPrefetchClearsRecoveryOffer() async throws {
        let client = ImmediateMutationClient(
            statusResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"archived"}}"#))
            ],
            detailResults: [.failure(APIError.http(statusCode: 404, body: nil))]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.archiveCard(card)
        await state.undoArchive()

        XCTAssertFalse(state.hasAvailableArchiveUndo)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .failed)
    }

    func testUndoArchiveNotFoundDuringUncertainCheckClearsRecoveryOffer() async throws {
        let network = APIError.network(underlying: URLError(.networkConnectionLost))
        let client = ImmediateMutationClient(
            statusResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"archived"}}"#)),
                .failure(network)
            ],
            detailResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"archived"}}"#)),
                .failure(network),
                .failure(APIError.http(statusCode: 404, body: nil))
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.archiveCard(card)
        await state.undoArchive()
        let recoveryCard = try XCTUnwrap(state.archiveUndo?.card)
        await state.checkUncertainMutation(for: recoveryCard)

        XCTAssertFalse(state.hasAvailableArchiveUndo)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .failed)
    }

    func testFullLoadAndBoardSwitchClearSettledMutationPresentation() async throws {
        let boards: KanbanBoardsResponse = mutationDecode(
            #"{"boards":[{"slug":"main"},{"slug":"release"}],"current":"main","read_only":false}"#
        )
        let client = ImmediateMutationClient(
            boards: boards,
            statusResults: [
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"done"}}"#)),
                .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"done"}}"#))
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        var card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.completeCard(card)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .succeeded)
        await state.load()
        XCTAssertNil(state.mutationState(for: card.cardID))
        XCTAssertEqual(state.displayedCard(card).status?.rawValue, "todo")

        card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })
        await state.completeCard(card)
        XCTAssertEqual(state.mutationState(for: card.cardID)?.phase, .succeeded)
        await state.selectBoard("release")
        XCTAssertNil(state.mutationState(for: card.cardID))
        XCTAssertEqual(state.displayedCard(card).status?.rawValue, "todo")
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met before timeout")
    }
}

private enum KanbanEventsNotStubbed: Error { case unexpectedCall }

private extension KanbanDataClient {
    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope {
        throw KanbanEventsNotStubbed.unexpectedCall
    }
}

private actor KanbanClientStub: KanbanDataClient {
    enum Call: Equatable {
        case configuration
        case boards
        case board(KanbanBoardRequest)
        case stats(String)
        case assignees(String)
    }

    private let configurationResult: Result<KanbanConfiguration, Error>
    private let boardsResult: Result<KanbanBoardsResponse, Error>
    private let boardResult: Result<KanbanBoardSnapshot, Error>
    private var recordedCalls: [Call] = []

    init(
        configurationResult: Result<KanbanConfiguration, Error> = .success(KanbanFixtures.configuration),
        boardsResult: Result<KanbanBoardsResponse, Error> = .success(KanbanFixtures.boards),
        boardResult: Result<KanbanBoardSnapshot, Error> = .success(KanbanFixtures.snapshot)
    ) {
        self.configurationResult = configurationResult
        self.boardsResult = boardsResult
        self.boardResult = boardResult
    }

    func kanbanConfiguration() throws -> KanbanConfiguration {
        recordedCalls.append(.configuration)
        return try configurationResult.get()
    }

    func kanbanBoards() throws -> KanbanBoardsResponse {
        recordedCalls.append(.boards)
        return try boardsResult.get()
    }

    func kanbanBoard(_ request: KanbanBoardRequest) throws -> KanbanBoardSnapshot {
        recordedCalls.append(.board(request))
        return try boardResult.get()
    }

    func kanbanStats(board: String) -> KanbanStats {
        recordedCalls.append(.stats(board))
        return KanbanFixtures.stats
    }

    func kanbanAssignees(board: String) -> KanbanAssigneeHistory {
        recordedCalls.append(.assignees(board))
        return KanbanFixtures.history
    }

    func calls() -> [Call] { recordedCalls }
}

private actor DeferredFirstConfigurationClient: KanbanDataClient {
    private var configurationCalls = 0
    private var continuation: CheckedContinuation<KanbanConfiguration, Error>?

    func kanbanConfiguration() async throws -> KanbanConfiguration {
        configurationCalls += 1
        if configurationCalls == 1 {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return KanbanFixtures.configuration
    }

    func kanbanBoards() -> KanbanBoardsResponse { KanbanFixtures.boards }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot { KanbanFixtures.snapshot }
    func kanbanStats(board: String) -> KanbanStats { KanbanFixtures.stats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { KanbanFixtures.history }

    func waitForFirstConfiguration() async {
        while continuation == nil { await Task.yield() }
    }

    func resumeFirstConfiguration() {
        continuation?.resume(returning: KanbanFixtures.configuration)
        continuation = nil
    }
}

private actor DeferredMutationClient: KanbanDataClient {
    private var continuations: [String: CheckedContinuation<KanbanCardMutationEnvelope, Never>] = [:]
    private var requests: [KanbanCardStatusRequest] = []
    private var concurrentWrites = 0
    private(set) var maximumConcurrentWrites = 0

    var statusRequestCount: Int { requests.count }

    func requestCount(for cardID: String) -> Int {
        requests.count { $0.cardID == cardID }
    }

    func kanbanConfiguration() -> KanbanConfiguration {
        mutationDecode(#"{"columns":["triage","todo","ready","running","blocked","done"],"read_only":false}"#)
    }
    func kanbanBoards() -> KanbanBoardsResponse {
        mutationDecode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#)
    }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot { mutationSnapshot() }
    func kanbanStats(board: String) -> KanbanStats { mutationDecode("{}") }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { mutationDecode("{}") }

    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async -> KanbanCardMutationEnvelope {
        requests.append(request)
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        return await withCheckedContinuation { continuation in
            continuations[request.cardID] = continuation
        }
    }

    func finish(cardID: String, status: String) {
        concurrentWrites -= 1
        continuations.removeValue(forKey: cardID)?.resume(
            returning: mutationDecode(#"{"task":{"id":"\#(cardID)","status":"\#(status)"}}"#)
        )
    }
}

private actor ImmediateMutationClient: KanbanDataClient {
    private let snapshot: KanbanBoardSnapshot
    private let boards: KanbanBoardsResponse
    private var statusResults: [Result<KanbanCardMutationEnvelope, Error>]
    private var detailResults: [Result<KanbanCardDetailEnvelope, Error>]
    private let dependencyResult: Result<KanbanDependencyMutationEnvelope, Error>
    private(set) var statusRequestCount = 0
    private(set) var detailRequestCount = 0
    private(set) var dependencyRequestCount = 0

    init(
        snapshot: KanbanBoardSnapshot = mutationSnapshot(),
        boards: KanbanBoardsResponse = mutationDecode(
            #"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#
        ),
        statusResults: [Result<KanbanCardMutationEnvelope, Error>] = [],
        detailResults: [Result<KanbanCardDetailEnvelope, Error>] = [],
        dependencyResult: Result<KanbanDependencyMutationEnvelope, Error> = .success(
            mutationDecode(#"{"ok":true,"parent_id":"CARD-2","child_id":"CARD-1"}"#)
        )
    ) {
        self.snapshot = snapshot
        self.boards = boards
        self.statusResults = statusResults
        self.detailResults = detailResults
        self.dependencyResult = dependencyResult
    }

    func kanbanConfiguration() -> KanbanConfiguration {
        mutationDecode(#"{"columns":["triage","todo","ready","running","blocked","done"],"read_only":false}"#)
    }
    func kanbanBoards() -> KanbanBoardsResponse {
        boards
    }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot { snapshot }
    func kanbanStats(board: String) -> KanbanStats { mutationDecode("{}") }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { mutationDecode("{}") }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) throws -> KanbanCardDetailEnvelope {
        detailRequestCount += 1
        return try detailResults.removeFirst().get()
    }

    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) throws -> KanbanCardMutationEnvelope {
        statusRequestCount += 1
        return try statusResults.removeFirst().get()
    }

    func addKanbanDependency(
        _ request: KanbanDependencyMutationRequest
    ) throws -> KanbanDependencyMutationEnvelope {
        dependencyRequestCount += 1
        return try dependencyResult.get()
    }
}

private func mutationSnapshot(status: String = "todo") -> KanbanBoardSnapshot {
    mutationDecode("""
    {
      "changed":true,
      "read_only":false,
      "columns":[
        {"name":"triage","tasks":[{"id":"CARD-2","title":"Second","status":"triage"}]},
        {"name":"\(status)","tasks":[{"id":"CARD-1","title":"First","status":"\(status)"}]},
        {"name":"ready","tasks":[]},
        {"name":"done","tasks":[]}
      ]
    }
    """)
}

private func mutationDecode<T: Decodable>(_ json: String) -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(T.self, from: Data(json.utf8))
}

private actor BrowsingClient: KanbanDataClient {
    private var requests: [KanbanBoardRequest] = []

    func kanbanConfiguration() -> KanbanConfiguration { KanbanFixtures.configuration }
    func kanbanBoards() -> KanbanBoardsResponse { KanbanFixtures.multiBoards }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot {
        requests.append(request)
        if request.since != nil { return KanbanFixtures.unchangedSnapshot }
        return KanbanFixtures.richSnapshot
    }
    func kanbanStats(board: String) -> KanbanStats { KanbanFixtures.stats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { KanbanFixtures.history }
    func boardRequests() -> [KanbanBoardRequest] { requests }
}

private actor DeferredBoardClient: KanbanDataClient {
    private var boardCallCount = 0
    private var continuation: CheckedContinuation<KanbanBoardSnapshot, Never>?

    func kanbanConfiguration() -> KanbanConfiguration { KanbanFixtures.configuration }
    func kanbanBoards() -> KanbanBoardsResponse { KanbanFixtures.boards }
    func kanbanBoard(_ request: KanbanBoardRequest) async -> KanbanBoardSnapshot {
        boardCallCount += 1
        if boardCallCount == 1 { return KanbanFixtures.richSnapshot }
        if boardCallCount == 2 {
            return await withCheckedContinuation { continuation = $0 }
        }
        return KanbanFixtures.newSnapshot
    }
    func kanbanStats(board: String) -> KanbanStats { KanbanFixtures.stats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { KanbanFixtures.history }

    func waitForDeferredRead() async {
        while continuation == nil { await Task.yield() }
    }

    func resumeDeferredRead() {
        continuation?.resume(returning: KanbanFixtures.staleSnapshot)
        continuation = nil
    }
}

private actor DeferredBoardSwitchClient: KanbanDataClient {
    private var boardCallCount = 0
    private var releaseContinuation: CheckedContinuation<KanbanBoardSnapshot, Never>?

    func kanbanConfiguration() -> KanbanConfiguration { KanbanFixtures.configuration }
    func kanbanBoards() -> KanbanBoardsResponse { KanbanFixtures.multiBoards }
    func kanbanBoard(_ request: KanbanBoardRequest) async -> KanbanBoardSnapshot {
        boardCallCount += 1
        if boardCallCount == 1 { return KanbanFixtures.supportedSnapshot }
        return await withCheckedContinuation { releaseContinuation = $0 }
    }
    func kanbanStats(board: String) -> KanbanStats { KanbanFixtures.stats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { KanbanFixtures.history }

    func waitForReleaseRead() async {
        while releaseContinuation == nil { await Task.yield() }
    }

    func resumeReleaseRead() {
        releaseContinuation?.resume(returning: KanbanFixtures.futureSnapshot)
        releaseContinuation = nil
    }
}

private actor MissingChangedRefreshClient: KanbanDataClient {
    private var boardCallCount = 0

    func kanbanConfiguration() -> KanbanConfiguration { KanbanFixtures.configuration }
    func kanbanBoards() -> KanbanBoardsResponse { KanbanFixtures.boards }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot {
        boardCallCount += 1
        return boardCallCount == 1 ? KanbanFixtures.richSnapshot : KanbanFixtures.missingChangedSnapshot
    }
    func kanbanStats(board: String) -> KanbanStats { KanbanFixtures.stats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { KanbanFixtures.history }
}

private enum KanbanFixtures {
    static let configuration = decode(KanbanConfiguration.self, #"{"columns":["triage","todo","ready","running","blocked","done"],"read_only":false}"#)
    static let boards = decode(KanbanBoardsResponse.self, #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#)
    static let readOnlyBoard = decode(KanbanBoardsResponse.self, #"{"boards":[{"slug":"main","name":"Main","read_only":true}],"current":"main","read_only":false}"#)
    static let multiBoards = decode(KanbanBoardsResponse.self, #"{"boards":[{"slug":"main","name":"Main"},{"slug":"release","name":"Release"}],"current":"main","read_only":false}"#)
    static let snapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"read_only":false,"columns":[{"name":"triage","tasks":[]}]}"#)
    static let supportedSnapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"read_only":false,"columns":[{"name":"triage","tasks":[{"id":"OLD","status":"triage"}]}]}"#)
    static let richSnapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"latest_event_id":11,"read_only":false,"tenants":["mobile"],"assignees":["builder"],"columns":[{"name":"triage","tasks":[]},{"name":"ready","tasks":[{"id":"CARD-1","title":"Status Focus","body":"markdown preview","status":"ready","assignee":"builder","tenant":"mobile"}]},{"name":"future","tasks":[{"id":"FUTURE-1","title":"Future","status":"future"}]}]}"#)
    static let futureSnapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"read_only":false,"columns":[{"name":"future","tasks":[{"id":"FUTURE-1","status":"future"}]}]}"#)
    static let unchangedSnapshot = decode(KanbanBoardSnapshot.self, #"{"changed":false,"latest_event_id":11,"read_only":false}"#)
    static let missingChangedSnapshot = decode(KanbanBoardSnapshot.self, #"{"latest_event_id":12,"read_only":false,"columns":[{"name":"triage","tasks":[]}]}"#)
    static let newSnapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"latest_event_id":13,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"NEW","title":"Newest filter","status":"ready"}]}]}"#)
    static let staleSnapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"latest_event_id":12,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"STALE","title":"Stale filter","status":"ready"}]}]}"#)
    static let stalenessSnapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"columns":[{"name":"running","tasks":[{"id":"r1","status":"running","age_seconds":599},{"id":"r2","status":"running","age_seconds":600},{"id":"r3","status":"running","age_seconds":3600}]},{"name":"ready","tasks":[{"id":"q1","status":"ready","age_seconds":3599},{"id":"q2","status":"ready","age_seconds":3600}]},{"name":"blocked","tasks":[{"id":"b1","status":"blocked","age_seconds":3599},{"id":"b2","status":"blocked","age_seconds":3600},{"id":"b3","status":"blocked","age_seconds":86400}]}]}"#)
    static let stats = decode(KanbanStats.self, #"{"by_status":{"triage":0}}"#)
    static let history = decode(KanbanAssigneeHistory.self, #"{"assignees":["builder"]}"#)

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(T.self, from: Data(json.utf8))
    }
}
