import XCTest
@testable import HermesMobile

@MainActor
final class KanbanFeatureStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearSavedKanbanBoards()
    }

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

    // MARK: - Browsed Board restoration (#259)

    func testBrowsedBoardIsRestoredForTheSameServerAndIsolatedFromOthers() async {
        let defaults = makeIsolatedDefaults()
        let firstServer = URL(string: "https://first.example.test")!
        let secondServer = URL(string: "https://second.example.test")!

        let browsing = KanbanFeatureState(
            server: firstServer,
            client: KanbanClientStub(boardsResult: .success(KanbanFixtures.multiBoards)),
            defaults: defaults
        )
        await browsing.load()
        await browsing.selectBoard("release")
        XCTAssertEqual(browsing.selectedBoardSlug, "release")

        // A rebuilt state for the same server reopens Release directly: the
        // handshake never requests the server-global current Board first.
        let restoredClient = KanbanClientStub(boardsResult: .success(KanbanFixtures.multiBoards))
        let restored = KanbanFeatureState(server: firstServer, client: restoredClient, defaults: defaults)
        await restored.load()
        XCTAssertEqual(restored.selectedBoardSlug, "release")
        XCTAssertEqual(restored.sharedActiveBoardSlug, "main")
        XCTAssertNil(restored.boardSelectionNotice)
        let restoredCalls = await restoredClient.calls()
        XCTAssertEqual(restoredCalls, [
            .configuration,
            .boards,
            .board(KanbanBoardRequest(board: "release")),
            .stats("release"),
            .assignees("release")
        ])

        let otherServer = KanbanFeatureState(
            server: secondServer,
            client: KanbanClientStub(boardsResult: .success(KanbanFixtures.multiBoards)),
            defaults: defaults
        )
        await otherServer.load()
        XCTAssertEqual(otherServer.selectedBoardSlug, "main")
        XCTAssertEqual(KanbanBoardPreference.savedSlug(for: firstServer, in: defaults), "release")
        XCTAssertEqual(KanbanBoardPreference.savedSlug(for: secondServer, in: defaults), "main")
    }

    func testStaleSavedBoardIsDroppedAndColdStartFallsBackToCurrentBoard() async {
        let defaults = makeIsolatedDefaults()
        let server = URL(string: "https://example.test")!
        KanbanBoardPreference.save("ghost", for: server, in: defaults)
        let client = KanbanClientStub(boardsResult: .success(KanbanFixtures.multiBoards))
        let state = KanbanFeatureState(server: server, client: client, defaults: defaults)

        await state.load()

        XCTAssertEqual(state.state, .compatible)
        XCTAssertEqual(state.selectedBoardSlug, "main")
        XCTAssertNil(state.boardSelectionNotice)
        let calls = await client.calls()
        XCTAssertFalse(calls.contains(.board(KanbanBoardRequest(board: "ghost"))))
        XCTAssertEqual(KanbanBoardPreference.savedSlug(for: server, in: defaults), "main")
    }

    func testBoardRemovedWhileBrowsingClearsTheSavedChoice() async throws {
        let defaults = makeIsolatedDefaults()
        let server = URL(string: "https://example.test")!
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"},{"slug":"release","name":"Release"}],"current":"main","read_only":false}"#
            )),
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#
            ))
        ])
        let state = KanbanFeatureState(server: server, client: client, defaults: defaults)
        await state.load()
        await state.selectBoard("release")
        XCTAssertEqual(KanbanBoardPreference.savedSlug(for: server, in: defaults), "release")

        await state.refresh()

        XCTAssertNil(state.selectedBoardSlug)
        XCTAssertNil(KanbanBoardPreference.savedSlug(for: server, in: defaults))
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "KanbanFeatureStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
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

    func testGroupByProfileDraftCancelsOrAppliesLocallyWithoutRefetchingBoard() async {
        let client = BrowsingClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let requestsBeforeToggle = await client.boardRequests()
        var draft = KanbanFiltersDraft(model: state)

        draft.groupsByProfile = true

        XCTAssertFalse(state.groupByProfile, "A cancelled draft must not mutate presentation state.")
        var requestsAfterDraftChange = await client.boardRequests()
        XCTAssertEqual(requestsAfterDraftChange, requestsBeforeToggle)

        await draft.apply(to: state)

        XCTAssertTrue(state.groupByProfile)
        requestsAfterDraftChange = await client.boardRequests()
        XCTAssertEqual(requestsAfterDraftChange, requestsBeforeToggle)
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
        XCTAssertTrue(KanbanBulkAccessibility.selectionLabel(card, isSelected: true).contains(String(localized: "Selected")))
        XCTAssertFalse(KanbanBulkAccessibility.selectionLabel(card, isSelected: false).contains(String(localized: "Selected")))
        let bulkSummary = KanbanBulkActionSummary(
            action: .changeStatus("done"),
            members: [
                KanbanBulkMemberResult(cardID: "CARD-1", cardTitle: "First", outcome: .succeeded),
                KanbanBulkMemberResult(cardID: "CARD-2", cardTitle: "Second", outcome: .failed),
                KanbanBulkMemberResult(cardID: "CARD-3", cardTitle: "Third", outcome: .outcomeUncertain)
            ]
        )
        let bulkLabel = KanbanBulkAccessibility.resultLabel(bulkSummary)
        XCTAssertTrue(bulkLabel.contains("1 \(String(localized: "Complete"))"))
        XCTAssertTrue(bulkLabel.contains("1 \(String(localized: "Failed"))"))
        XCTAssertTrue(bulkLabel.contains("1 \(String(localized: "Outcome Uncertain"))"))
        XCTAssertEqual(KanbanCountFormatter.cards(1), "1 Card")
        XCTAssertEqual(KanbanCountFormatter.cards(2), "2 Cards")
        let board: KanbanBoard = mutationDecode(
            #"{"slug":"release","name":"Release"}"#
        )
        XCTAssertEqual(KanbanBoardAccessibility.browseLabel(board), "Browse Board: Release")
        XCTAssertEqual(KanbanBoardAccessibility.actionsLabel(board), "Board actions for Release")
        XCTAssertEqual(
            KanbanBoardAccessibility.statusValue(isBrowsing: true, isActive: true),
            "\(String(localized: "Browsing")), \(String(localized: "Active"))"
        )
        let describedBoard: KanbanBoard = mutationDecode(
            #"{"slug":"release","name":"Release","description":"Release planning","total":3}"#
        )
        XCTAssertEqual(
            KanbanBoardAccessibility.browseSummary(describedBoard, isActive: true),
            "Browse Board: Release, Release planning, 3 Cards, Active"
        )

        let dispatchResult: KanbanDispatchResult = mutationDecode(
            #"{"spawned":[{"id":"secret"}],"promoted":2,"reclaimed":0,"skipped_unassigned":[],"skipped_nonspawnable":[],"auto_blocked":[],"timed_out":[],"crashed":[]}"#
        )
        let dispatchLabel = KanbanDispatchAccessibility.summary(
            KanbanDispatchState(
                mode: .preview,
                boardSlug: "main",
                phase: .succeeded,
                result: dispatchResult,
                completedAt: nil,
                boardActivityGeneration: 1
            ),
            isStale: true
        )
        XCTAssertTrue(dispatchLabel.contains(String(localized: "Preview Dispatch")))
        XCTAssertTrue(dispatchLabel.contains("\(String(localized: "Spawned")): 1"))
        XCTAssertTrue(dispatchLabel.contains("\(String(localized: "Promoted")): 2"))
        XCTAssertTrue(dispatchLabel.contains(String(localized: "This Preview is stale. Run Preview Dispatch again before relying on it.")))
        XCTAssertFalse(dispatchLabel.contains("secret"))
        let submittingLabel = KanbanDispatchAccessibility.summary(
            KanbanDispatchState(
                mode: .run,
                boardSlug: "main",
                phase: .submitting,
                result: nil,
                completedAt: nil,
                boardActivityGeneration: 1
            ),
            isStale: false
        )
        XCTAssertTrue(submittingLabel.contains(String(localized: "Running Dispatcher...")))
        XCTAssertFalse(submittingLabel.contains(String(localized: "Updating task...")))
        XCTAssertEqual(
            KanbanDispatchCopy.runConfirmation,
            "This may start up to \(KanbanDispatchRequest.maximum) workers and consume API budget."
        )
    }

    func testBoardRowPresentationSeparatesLocalBrowsingFromApplicableMenuActions() {
        let ordinary: KanbanBoard = mutationDecode(
            #"{"slug":"release","name":"Release"}"#
        )
        let ordinaryPresentation = KanbanBoardRowPresentation(
            board: ordinary,
            selectedBoardSlug: "main",
            sharedActiveBoardSlug: "main",
            canManageBoards: true
        )
        XCTAssertEqual(ordinaryPresentation.browseSlug, "release")
        XCTAssertEqual(ordinaryPresentation.actions, [.edit, .makeActive, .archive])
        XCTAssertTrue(ordinaryPresentation.mutationsAreEnabled)
        XCTAssertFalse(ordinaryPresentation.isBrowsing)
        XCTAssertFalse(ordinaryPresentation.isActive)

        let browsedPresentation = KanbanBoardRowPresentation(
            board: ordinary,
            selectedBoardSlug: "release",
            sharedActiveBoardSlug: "main",
            canManageBoards: true
        )
        XCTAssertNil(browsedPresentation.browseSlug)
        XCTAssertEqual(browsedPresentation.actions, [.edit, .makeActive, .archive])
        XCTAssertTrue(browsedPresentation.isBrowsing)

        let activePresentation = KanbanBoardRowPresentation(
            board: ordinary,
            selectedBoardSlug: "main",
            sharedActiveBoardSlug: "release",
            canManageBoards: true
        )
        XCTAssertEqual(activePresentation.browseSlug, "release")
        XCTAssertEqual(activePresentation.actions, [.edit, .archive])
        XCTAssertTrue(activePresentation.isActive)

        let defaultBoard: KanbanBoard = mutationDecode(
            #"{"slug":"default","name":"Default"}"#
        )
        let defaultPresentation = KanbanBoardRowPresentation(
            board: defaultBoard,
            selectedBoardSlug: "release",
            sharedActiveBoardSlug: "release",
            canManageBoards: true
        )
        XCTAssertEqual(defaultPresentation.browseSlug, "default")
        XCTAssertEqual(defaultPresentation.actions, [.edit, .makeActive])
        XCTAssertFalse(defaultPresentation.actions.contains(.archive))
    }

    func testBoardRowPresentationDisablesAllMutationsWhenManagementIsUnavailable() {
        let board: KanbanBoard = mutationDecode(
            #"{"slug":"release","name":"Release"}"#
        )
        let presentation = KanbanBoardRowPresentation(
            board: board,
            selectedBoardSlug: "main",
            sharedActiveBoardSlug: "main",
            canManageBoards: false
        )

        XCTAssertEqual(presentation.browseSlug, "release")
        XCTAssertEqual(presentation.actions, [.edit, .makeActive, .archive])
        XCTAssertFalse(presentation.mutationsAreEnabled)
        XCTAssertEqual(KanbanBoardRowAction.edit.systemImage, "pencil")
        XCTAssertEqual(KanbanBoardRowAction.makeActive.systemImage, "checkmark.circle")
        XCTAssertEqual(KanbanBoardRowAction.archive.systemImage, "archivebox")

        let invalidBoard: KanbanBoard = mutationDecode(
            #"{"name":"Missing slug"}"#
        )
        let invalidPresentation = KanbanBoardRowPresentation(
            board: invalidBoard,
            selectedBoardSlug: "main",
            sharedActiveBoardSlug: "main",
            canManageBoards: true
        )
        XCTAssertNil(invalidPresentation.browseSlug)
        XCTAssertFalse(invalidPresentation.isBrowsing)
        XCTAssertFalse(invalidPresentation.mutationsAreEnabled)
        XCTAssertTrue(invalidPresentation.actions.isEmpty)
    }

    func testCardRowPrimaryActionKeepsNavigationAndSelectionDistinct() throws {
        let card = try XCTUnwrap(KanbanFixtures.richSnapshot.columns?[1].cards?.first)
        let cardID = try XCTUnwrap(card.cardID)

        XCTAssertEqual(
            KanbanCardRowPrimaryAction.resolve(for: card, isSelecting: false),
            .openDetail(cardID)
        )
        XCTAssertEqual(
            KanbanCardRowPrimaryAction.resolve(for: card, isSelecting: true),
            .toggleSelection(cardID)
        )
        XCTAssertEqual(
            KanbanCardRowPrimaryAction.focusTarget(
                afterDismissing: cardID,
                visibleCards: [card]
            ),
            cardID
        )
        XCTAssertNil(
            KanbanCardRowPrimaryAction.focusTarget(
                afterDismissing: cardID,
                visibleCards: []
            )
        )

        let missingIdentity: KanbanCard = mutationDecode(#"{"title":"Missing identity"}"#)
        XCTAssertNil(
            KanbanCardRowPrimaryAction.resolve(for: missingIdentity, isSelecting: false)
        )
        XCTAssertNil(
            KanbanCardRowPrimaryAction.resolve(for: missingIdentity, isSelecting: true)
        )
    }

    func testStatusSpecificStalenessThresholds() {
        let cards = KanbanFixtures.stalenessSnapshot.columns?.flatMap { $0.cards ?? [] } ?? []
        XCTAssertEqual(cards.map(\.staleness), [
            .none, .warning, .critical,
            .none, .warning,
            .none, .warning, .critical
        ])
    }

    func testPreviewDispatchIsOptionalSingleFlightTimestampedAndBecomesStaleAfterRefresh() async {
        let completedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let client = DispatcherClient(defersFirstDispatch: true)
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client,
            now: { completedAt }
        )
        await state.load()

        let preview = Task { await state.previewDispatch() }
        await client.waitForDeferredDispatch()
        await state.previewDispatch()

        let inFlightRequestCount = await client.dispatchRequestCount
        XCTAssertEqual(inFlightRequestCount, 1)
        XCTAssertEqual(state.dispatcherAvailability, .busy)
        await client.resumeDeferredDispatch()
        await preview.value

        XCTAssertEqual(state.dispatchState?.mode, .preview)
        XCTAssertEqual(state.dispatchState?.phase, .succeeded)
        XCTAssertEqual(state.dispatchState?.completedAt, completedAt)
        let previewRequest = await client.dispatchRequests.first
        XCTAssertEqual(previewRequest?.dryRun, true)
        XCTAssertFalse(state.isPreviewStale)

        await state.refresh()

        XCTAssertTrue(state.isPreviewStale)
        let finalRequestCount = await client.dispatchRequestCount
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testDispatcherToolbarResultPersistsUntilExplicitDismissal() async {
        let client = DispatcherClient()
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client
        )
        await state.load()

        XCTAssertFalse(KanbanDispatcherPresentation.hasResult(state.dispatchState))
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarAccessibilityLabel(for: state.dispatchState),
            String(localized: "Dispatcher")
        )

        await state.previewDispatch()

        XCTAssertTrue(KanbanDispatcherPresentation.hasResult(state.dispatchState))
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarAccessibilityLabel(for: state.dispatchState),
            String(localized: "Dispatcher, result available")
        )

        let failed = KanbanDispatchState(
            mode: .preview,
            boardSlug: "main",
            phase: .failed,
            result: nil,
            completedAt: nil,
            boardActivityGeneration: 0
        )
        let refused = KanbanDispatchState(
            mode: .run,
            boardSlug: "main",
            phase: .refused,
            result: nil,
            completedAt: nil,
            boardActivityGeneration: 0
        )
        let uncertain = KanbanDispatchState(
            mode: .run,
            boardSlug: "main",
            phase: .outcomeUncertain,
            result: nil,
            completedAt: nil,
            boardActivityGeneration: 0
        )
        let uncertainWithResult = KanbanDispatchState(
            mode: .run,
            boardSlug: "main",
            phase: .outcomeUncertain,
            result: state.dispatchState?.result,
            completedAt: nil,
            boardActivityGeneration: 0
        )
        XCTAssertFalse(KanbanDispatcherPresentation.hasResult(failed))
        XCTAssertFalse(KanbanDispatcherPresentation.hasResult(refused))
        XCTAssertFalse(KanbanDispatcherPresentation.hasResult(uncertain))
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarSystemImage(for: failed),
            "bolt.horizontal.circle"
        )
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarSystemImage(for: refused),
            "bolt.horizontal.circle"
        )
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarSystemImage(for: uncertain),
            "exclamationmark.circle.fill",
            "Ambiguous-outcome recovery must use a distinct, visibly reopenable indicator."
        )
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarAccessibilityLabel(for: uncertain),
            String(localized: "Dispatcher, attention required")
        )
        XCTAssertTrue(KanbanDispatcherPresentation.hasResult(uncertainWithResult))
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarSystemImage(for: state.dispatchState),
            "bolt.horizontal.circle.fill"
        )
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarSystemImage(for: uncertainWithResult),
            "bolt.horizontal.circle.fill"
        )
        XCTAssertEqual(
            KanbanDispatcherPresentation.toolbarAccessibilityLabel(for: uncertainWithResult),
            String(localized: "Dispatcher, result available")
        )

        state.dismissDispatchResult()

        XCTAssertNil(state.dispatchState)
        XCTAssertFalse(KanbanDispatcherPresentation.hasResult(state.dispatchState))
    }

    func testRunDispatcherJoinsBoardWideLockAndAlwaysReconcilesWithoutRequiringPreview() async {
        let multipleBoards: KanbanBoardsResponse = mutationDecode(
            #"{"boards":[{"slug":"main"},{"slug":"release"}],"current":"main","read_only":false}"#
        )
        let client = DispatcherClient(
            boardsResponses: [multipleBoards],
            defersFirstDispatch: true
        )
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client
        )
        await state.load()

        let run = Task { await state.runDispatcher() }
        await client.waitForDeferredDispatch()

        XCTAssertFalse(state.canMutateCards)
        XCTAssertFalse(state.canManageBoards)
        XCTAssertEqual(state.dispatcherAvailability, .busy)
        await state.previewDispatch()
        await state.selectBoard("release")
        let lockedRequestCount = await client.dispatchRequestCount
        XCTAssertEqual(lockedRequestCount, 1)
        XCTAssertEqual(state.selectedBoardSlug, "main")

        await client.resumeDeferredDispatch()
        await run.value

        XCTAssertEqual(state.dispatchState?.mode, .run)
        XCTAssertEqual(state.dispatchState?.phase, .succeeded)
        XCTAssertEqual(state.dispatchState?.result?.spawned, 1)
        let runRequest = await client.dispatchRequests.first
        let reconciledBoardRequestCount = await client.boardRequestCount
        XCTAssertEqual(runRequest?.dryRun, false)
        XCTAssertEqual(reconciledBoardRequestCount, 2, "Run must refetch the canonical Board.")
        XCTAssertTrue(state.canMutateCards)
    }

    func testAmbiguousRunRequiresSuccessfulRefreshAndAcknowledgementBeforeManualRetry() async {
        let client = DispatcherClient(
            dispatchResults: [
                .failure(APIError.network(underlying: URLError(.timedOut))),
                .failure(APIError.network(underlying: URLError(.timedOut)))
            ]
        )
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client
        )
        await state.load()

        await state.runDispatcher()

        XCTAssertEqual(state.dispatchState?.phase, .outcomeUncertain)
        XCTAssertFalse(state.dispatchState?.canAcknowledgeUncertainOutcome == true)
        XCTAssertEqual(state.dispatcherAvailability, .outcomeUncertain)
        XCTAssertNil(state.dispatchState?.result)
        let initialDispatchRequestCount = await client.dispatchRequestCount
        let initialBoardRequestCount = await client.boardRequestCount
        XCTAssertEqual(initialDispatchRequestCount, 1)
        XCTAssertEqual(initialBoardRequestCount, 2)

        state.dismissDispatchResult()
        XCTAssertEqual(state.dispatchState?.phase, .outcomeUncertain)
        await state.runDispatcher()
        let requestCountAfterBlockedRetry = await client.dispatchRequestCount
        XCTAssertEqual(requestCountAfterBlockedRetry, 1)

        await state.refreshUncertainDispatchOutcome()

        XCTAssertEqual(state.dispatchState?.phase, .outcomeUncertain)
        XCTAssertTrue(state.dispatchState?.canAcknowledgeUncertainOutcome == true)
        var dispatchRequestCount = await client.dispatchRequestCount
        var boardRequestCount = await client.boardRequestCount
        XCTAssertEqual(dispatchRequestCount, 1, "A refresh must never retry Run Dispatcher.")
        XCTAssertEqual(boardRequestCount, 3)

        state.dismissDispatchResult()
        XCTAssertNil(state.dispatchState)

        await state.runDispatcher()

        dispatchRequestCount = await client.dispatchRequestCount
        boardRequestCount = await client.boardRequestCount
        XCTAssertEqual(dispatchRequestCount, 2, "Only an acknowledged manual retry may submit again.")
        XCTAssertEqual(boardRequestCount, 4)
    }

    func testKnownDispatchResultResolvesAfterFailedReconciliationThenSuccessfulRefresh() async {
        let client = DispatcherClient(boardResults: [
            .success(mutationSnapshot()),
            .failure(APIError.http(statusCode: 503, body: nil)),
            .success(mutationSnapshot(status: "running"))
        ])
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client
        )
        await state.load()

        await state.runDispatcher()

        XCTAssertEqual(state.dispatchState?.phase, .outcomeUncertain)
        XCTAssertNotNil(state.dispatchState?.result)
        XCTAssertTrue(state.refreshFailed)
        XCTAssertEqual(state.dispatcherAvailability, .refreshFailed)

        await state.refreshUncertainDispatchOutcome()

        XCTAssertEqual(state.dispatchState?.phase, .succeeded)
        XCTAssertFalse(state.refreshFailed)
        let dispatchRequestCount = await client.dispatchRequestCount
        let boardRequestCount = await client.boardRequestCount
        XCTAssertEqual(dispatchRequestCount, 1)
        XCTAssertEqual(boardRequestCount, 3)
    }

    func testMalformedRunResultIsUncertainWhilePreviewFailureIsSafeAndRetryable() async {
        let malformed = KanbanDispatchResponseError.missingResultCategories
        let runClient = DispatcherClient(dispatchResults: [.failure(malformed)])
        let runState = KanbanFeatureState(
            server: URL(string: "https://run.example.test")!,
            client: runClient
        )
        await runState.load()
        await runState.runDispatcher()
        XCTAssertEqual(runState.dispatchState?.phase, .outcomeUncertain)
        let malformedRunRequestCount = await runClient.dispatchRequestCount
        XCTAssertEqual(malformedRunRequestCount, 1)

        let previewClient = DispatcherClient(dispatchResults: [.failure(malformed)])
        let previewState = KanbanFeatureState(
            server: URL(string: "https://preview.example.test")!,
            client: previewClient
        )
        await previewState.load()
        await previewState.previewDispatch()
        XCTAssertEqual(previewState.dispatchState?.phase, .failed)
        XCTAssertEqual(previewState.dispatcherAvailability, .available)
    }

    func testDispatcherRefusalIncompatibilityPartialCapabilityAndOfflineStayDistinct() async {
        let refusalClient = DispatcherClient(
            dispatchResults: [.failure(APIError.http(statusCode: 409, body: nil))]
        )
        let refusal = KanbanFeatureState(
            server: URL(string: "https://refusal.example.test")!,
            client: refusalClient
        )
        await refusal.load()
        await refusal.runDispatcher()
        XCTAssertEqual(refusal.dispatchState?.phase, .refused)
        XCTAssertFalse(refusal.dispatcherCapabilityIsIncompatible)

        let incompatibleClient = DispatcherClient(
            dispatchResults: [.failure(APIError.http(statusCode: 404, body: nil))]
        )
        let incompatible = KanbanFeatureState(
            server: URL(string: "https://old.example.test")!,
            client: incompatibleClient
        )
        await incompatible.load()
        await incompatible.previewDispatch()
        XCTAssertEqual(incompatible.dispatchState?.phase, .refused)
        XCTAssertEqual(incompatible.dispatcherAvailability, .incompatible)

        let partialClient = DispatcherClient(statsError: KanbanResponseError.nonJSONContentType)
        let partial = KanbanFeatureState(
            server: URL(string: "https://partial.example.test")!,
            client: partialClient
        )
        await partial.load()
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.dispatcherAvailability, .available)

        let missingWriteCapability = DispatcherClient(
            configuration: mutationDecode(
                #"{"columns":["triage","todo","ready","running","blocked","done"]}"#
            )
        )
        let unavailable = KanbanFeatureState(
            server: URL(string: "https://unknown.example.test")!,
            client: missingWriteCapability
        )
        await unavailable.load()
        XCTAssertEqual(unavailable.state, .partial)
        XCTAssertEqual(unavailable.dispatcherAvailability, .incompatible)

        let offlineClient = DispatcherClient(
            dispatchResults: [
                .failure(APIError.network(underlying: URLError(.notConnectedToInternet)))
            ]
        )
        let offline = KanbanFeatureState(
            server: URL(string: "https://offline.example.test")!,
            client: offlineClient
        )
        await offline.load()
        await offline.previewDispatch()
        XCTAssertEqual(offline.dispatcherAvailability, .offline)
    }

    func testRunReportsRemovedBoardAndDispatcherStateNeverCrossesServers() async {
        let removedBoards: KanbanBoardsResponse = mutationDecode(
            #"{"boards":[{"slug":"release"}],"current":"release","read_only":false}"#
        )
        let firstClient = DispatcherClient(boardsResponses: [
            mutationDecode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#),
            removedBoards
        ])
        let secondClient = DispatcherClient()
        let first = KanbanFeatureState(
            server: URL(string: "https://first.example.test")!,
            client: firstClient
        )
        let second = KanbanFeatureState(
            server: URL(string: "https://second.example.test")!,
            client: secondClient
        )
        await first.load()
        await second.load()

        await first.runDispatcher()

        XCTAssertEqual(first.dispatchState?.phase, .boardUnavailable)
        XCTAssertNil(first.selectedBoardSlug)
        XCTAssertNotNil(first.boardSelectionNotice)
        XCTAssertNil(second.dispatchState)
        let secondDispatchRequestCount = await secondClient.dispatchRequestCount
        XCTAssertEqual(secondDispatchRequestCount, 0)
    }

    func testObsoleteDispatchCollectionCannotOverwriteReloadedState() async {
        let client = DeferredBoardCollectionClient()
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client
        )
        await state.load()

        let run = Task { await state.runDispatcher() }
        await client.waitForDeferredCollection()

        await state.load()
        await client.resumeDeferredCollection(
            mutationDecode(
                #"{"boards":[{"slug":"release"}],"current":"release","read_only":false}"#
            )
        )
        await run.value

        XCTAssertEqual(state.selectedBoardSlug, "main")
        XCTAssertEqual(state.boards.compactMap(\.slug), ["main"])
        XCTAssertNil(state.boardSelectionNotice)
        XCTAssertNil(state.dispatchState)
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

    func testMissingWorkflowEndpointDisablesOnlyCardWorkflow() async throws {
        let client = ImmediateMutationClient(statusResults: [
            .failure(APIError.http(
                statusCode: 404,
                body: #"{"error":"Unknown Kanban endpoint; refresh the client"}"#
            ))
        ])
        let state = KanbanFeatureState(
            server: URL(string: "https://workflow-capability.example.test")!,
            client: client
        )
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        await state.completeCard(card)

        XCTAssertEqual(state.state, .partial)
        XCTAssertEqual(state.unavailableWriteCapabilities, [.cardWorkflow])
        XCTAssertFalse(state.canUseCardWorkflow)
        XCTAssertTrue(state.canUseBulkActions)
        XCTAssertTrue(state.canCreateCards)
        XCTAssertTrue(state.canManageBoards)
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

    func testCardSelectionSurvivesFiltersAndRefreshButNeverCrossesBoards() async throws {
        let client = BrowsingClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })

        state.beginSelectingCards()
        state.toggleCardSelection(card)
        await state.applyFilters(profile: "builder", tenant: "mobile", includeArchived: false, onlyMine: false)
        await state.refresh()

        XCTAssertTrue(state.isSelectingCards)
        XCTAssertEqual(state.selectedCardIDs, ["CARD-1"])
        XCTAssertEqual(state.selectedCardCount, 1)

        await state.selectBoard("release")
        XCTAssertFalse(state.isSelectingCards)
        XCTAssertTrue(state.selectedCardIDs.isEmpty)
        XCTAssertNil(state.bulkActionSummary)
    }

    func testBulkAvailabilityExplainsUnknownStatusAndRejectsInvalidActions() async throws {
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(boardResult: .success(KanbanFixtures.richSnapshot))
        )
        await state.load()
        let unknown = try XCTUnwrap(state.allCards.first { $0.cardID == "FUTURE-1" })
        state.beginSelectingCards()
        state.toggleCardSelection(unknown)

        XCTAssertEqual(state.bulkActionsAvailability, .unknownStatus)
        XCTAssertFalse(state.canSubmitBulkAction(.changeStatus("running")))
        XCTAssertFalse(state.canSubmitBulkAction(.setPriority(101)))
        XCTAssertFalse(state.canSubmitBulkAction(.assignProfile("not-a-profile")))
    }

    func testBulkPartialResultRefetchesEveryCardAndRetryTargetsOnlyFailed() async throws {
        let client = BulkActionClient(
            boardSnapshots: [
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "done", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "done", secondStatus: "done")
            ],
            bulkResponses: [
                mutationDecode(
                    #"{"results":[{"id":"CARD-1","ok":true},{"id":"CARD-2","ok":false,"error":"refused"}],"read_only":false}"#
                ),
                mutationDecode(#"{"results":[{"id":"CARD-2","ok":true}],"read_only":false}"#)
            ],
            detailResults: [
                "CARD-1": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"done"}}"#))
                ],
                "CARD-2": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-2","title":"Second","status":"todo"}}"#)),
                    .success(mutationDecode(#"{"task":{"id":"CARD-2","title":"Second","status":"done"}}"#))
                ]
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        state.beginSelectingCards()
        state.allCards.forEach(state.toggleCardSelection)

        await state.performBulkAction(.changeStatus("done"))

        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 1)
        XCTAssertEqual(state.bulkActionSummary?.failedCount, 1)
        XCTAssertEqual(state.bulkActionSummary?.uncertainCount, 0)
        XCTAssertEqual(state.selectedCardIDs, ["CARD-2"])
        XCTAssertTrue(state.canRetryFailedBulkAction)
        let firstDetailRequests = await client.detailRequests()
        XCTAssertEqual(Set(firstDetailRequests), ["CARD-1", "CARD-2"])

        await state.retryFailedBulkAction()

        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 1)
        XCTAssertEqual(state.bulkActionSummary?.failedCount, 0)
        XCTAssertTrue(state.selectedCardIDs.isEmpty)
        XCTAssertFalse(state.canRetryFailedBulkAction)
        let requests = await client.bulkRequests()
        XCTAssertEqual(requests.map(\.cardIDs), [["CARD-1", "CARD-2"], ["CARD-2"]])
    }

    func testBulkMalformedReconciliationRemainsSelectedButCannotBlindlyRetry() async throws {
        let client = BulkActionClient(
            boardSnapshots: [
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "done", secondStatus: "todo")
            ],
            bulkResponses: [
                mutationDecode(#"{"results":[{"id":"CARD-1","ok":true},42],"read_only":false}"#)
            ],
            detailResults: [
                "CARD-1": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"done"}}"#))
                ],
                "CARD-2": [
                    .failure(KanbanResponseError.nonJSONContentType)
                ]
            ]
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        state.beginSelectingCards()
        state.allCards.forEach(state.toggleCardSelection)

        await state.performBulkAction(.changeStatus("done"))

        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 1)
        XCTAssertEqual(state.bulkActionSummary?.uncertainCount, 1)
        XCTAssertEqual(state.selectedCardIDs, ["CARD-2"])
        XCTAssertFalse(state.canRetryFailedBulkAction)
        let detailRequests = await client.detailRequests()
        XCTAssertEqual(Set(detailRequests), ["CARD-1", "CARD-2"])
    }

    func testBulkSubmissionLocksOtherBoardWritesThroughReconciliation() async throws {
        let client = BulkActionClient(
            boardSnapshots: [
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "done", secondStatus: "todo")
            ],
            bulkResponses: [
                mutationDecode(#"{"results":[{"id":"CARD-1","ok":true}],"read_only":false}"#)
            ],
            detailResults: [
                "CARD-1": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"done"}}"#))
                ]
            ],
            defersFirstBulkResponse: true
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let first = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })
        state.beginSelectingCards()
        state.toggleCardSelection(first)

        let submission = Task { await state.performBulkAction(.changeStatus("done")) }
        await client.waitForDeferredBulkResponse()

        XCTAssertEqual(state.bulkActionPhase, .submitting)
        XCTAssertEqual(state.bulkActionsAvailability, .boardBusy)
        XCTAssertFalse(state.canMutateCards)

        await client.resumeDeferredBulkResponse()
        await submission.value

        XCTAssertNil(state.bulkActionPhase)
        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 1)
    }

    func testBulkTransportFailureStillReconcilesEveryCard() async {
        let client = BulkActionClient(
            boardSnapshots: [
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "done", secondStatus: "done")
            ],
            bulkResponses: [],
            detailResults: [
                "CARD-1": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"done"}}"#))
                ],
                "CARD-2": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-2","title":"Second","status":"done"}}"#))
                ]
            ],
            bulkError: KanbanResponseError.nonJSONContentType
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        state.beginSelectingCards()
        state.allCards.forEach(state.toggleCardSelection)

        await state.performBulkAction(.changeStatus("done"))

        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 2)
        let detailRequests = await client.detailRequests()
        XCTAssertEqual(Set(detailRequests), ["CARD-1", "CARD-2"])
    }

    func testMissingBulkEndpointDisablesOnlyBulkActionsAfterReconciliation() async throws {
        let client = BulkActionClient(
            boardSnapshots: [
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo")
            ],
            bulkResponses: [],
            detailResults: [
                "CARD-1": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-1","status":"todo"}}"#))
                ]
            ],
            bulkError: APIError.http(
                statusCode: 404,
                body: #"{"error":"Unknown Kanban endpoint; refresh the client"}"#
            )
        )
        let state = KanbanFeatureState(
            server: URL(string: "https://bulk-capability.example.test")!,
            client: client
        )
        await state.load()
        let card = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })
        state.beginSelectingCards()
        state.toggleCardSelection(card)

        await state.performBulkAction(.changeStatus("done"))

        XCTAssertEqual(state.state, .partial)
        XCTAssertEqual(state.unavailableWriteCapabilities, [.bulkActions])
        XCTAssertFalse(state.canUseBulkActions)
        XCTAssertTrue(state.canUseCardWorkflow)
        XCTAssertTrue(state.canCreateCards)
    }

    func testBulkReconciliationFetchesCardDetailsConcurrently() async throws {
        let client = BulkActionClient(
            boardSnapshots: [
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "done", secondStatus: "done")
            ],
            bulkResponses: [
                mutationDecode(#"{"results":[{"id":"CARD-1","ok":true},{"id":"CARD-2","ok":true}]}"#)
            ],
            detailResults: [
                "CARD-1": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-1","title":"First","status":"done"}}"#))
                ],
                "CARD-2": [
                    .success(mutationDecode(#"{"task":{"id":"CARD-2","title":"Second","status":"done"}}"#))
                ]
            ],
            defersFirstDetailResponse: true
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        state.beginSelectingCards()
        state.allCards.forEach(state.toggleCardSelection)

        let submission = Task { await state.performBulkAction(.changeStatus("done")) }
        await client.waitForDeferredDetailResponse()
        try await waitUntil { await client.detailRequests().count == 2 }
        await client.resumeDeferredDetailResponse()
        await submission.value

        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 2)
    }

    func testReloadAfterBrowsedBoardRemovalClearsSelectionDuringBulkSubmission() async throws {
        let client = BulkActionClient(
            boardSnapshots: [
                bulkSnapshot(firstStatus: "todo", secondStatus: "todo"),
                bulkSnapshot(firstStatus: "done", secondStatus: "done")
            ],
            boardsResponses: [
                mutationDecode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#),
                mutationDecode(#"{"boards":[{"slug":"release"}],"current":"release","read_only":false}"#)
            ],
            bulkResponses: [
                mutationDecode(#"{"results":[{"id":"CARD-1","ok":true}]}"#)
            ],
            detailResults: [:],
            defersFirstBulkResponse: true
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let first = try XCTUnwrap(state.allCards.first { $0.cardID == "CARD-1" })
        state.beginSelectingCards()
        state.toggleCardSelection(first)

        let submission = Task { await state.performBulkAction(.changeStatus("done")) }
        await client.waitForDeferredBulkResponse()
        await state.load()

        XCTAssertNil(state.selectedBoardSlug)
        XCTAssertEqual(state.boardSelectionNotice?.boardName, "main")
        XCTAssertFalse(state.isSelectingCards)
        XCTAssertTrue(state.selectedCardIDs.isEmpty)

        await client.resumeDeferredBulkResponse()
        await submission.value
        XCTAssertNil(state.bulkActionPhase)
        XCTAssertNil(state.bulkActionSummary)
    }

    func testKanbanLabPartialScenarioProvidesSafePerCardFailureRecovery() async throws {
        let state = KanbanLabScenario.partial.makeModel()
        await state.load()
        state.beginSelectingCards()
        for card in state.allCards where ["CARD-3", "CARD-4"].contains(card.cardID ?? "") {
            state.toggleCardSelection(card)
        }

        await state.performBulkAction(.changeStatus("done"))

        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 1)
        XCTAssertEqual(state.bulkActionSummary?.failedCount, 1)
        XCTAssertEqual(state.selectedCardIDs, ["CARD-4"])
        XCTAssertTrue(state.canRetryFailedBulkAction)
    }

    func testBoardWritesSerializeAndCreationNeverChangesLocalOrSharedSelection() async throws {
        let client = BoardManagementClient(
            boardsResponses: [
                .success(mutationDecode(
                    #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#
                )),
                .success(mutationDecode(
                    #"{"boards":[{"slug":"main","name":"Main"},{"slug":"release","name":"Release"}],"current":"main","read_only":false}"#
                ))
            ],
            defersCreate: true
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        let creation = Task {
            await state.createBoard(KanbanCreateBoardRequest(
                slug: "release",
                name: "Release",
                description: "",
                icon: "",
                color: ""
            ))
        }
        await client.waitForDeferredCreate()
        XCTAssertEqual(state.boardMutationState?.phase, .updating)

        await state.makeBoardActive(slug: "main")
        let makeActiveRequestCount = await client.makeActiveRequestCount
        XCTAssertEqual(makeActiveRequestCount, 0)

        await client.resumeDeferredCreate()
        await creation.value

        let createRequestCount = await client.createRequestCount
        XCTAssertEqual(createRequestCount, 1)
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        XCTAssertEqual(state.selectedBoardSlug, "main")
        XCTAssertEqual(state.sharedActiveBoardSlug, "main")
        XCTAssertTrue(state.boards.contains { $0.slug == "release" })
    }

    func testRemoteSharedActiveChangeNeverNavigatesLocallyBrowsedBoard() async {
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main"},{"slug":"release"}],"current":"main","read_only":false}"#
            )),
            .success(mutationDecode(
                #"{"boards":[{"slug":"main"},{"slug":"release"}],"current":"release","read_only":false}"#
            ))
        ])
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        await state.refresh()

        XCTAssertEqual(state.sharedActiveBoardSlug, "release")
        XCTAssertEqual(state.selectedBoardSlug, "main")
        let lastBoardRequest = await client.boardRequests().last
        XCTAssertEqual(lastBoardRequest?.board, "main")
    }

    func testRemoteArchiveReturnsToBoardSelectionAndTearsDownBoardState() async throws {
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"},{"slug":"release","name":"Release"}],"current":"main","read_only":false}"#
            )),
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#
            ))
        ])
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        await state.selectBoard("release")
        state.beginSelectingCards()
        if let card = state.allCards.first { state.toggleCardSelection(card) }

        await state.refresh()

        XCTAssertNil(state.selectedBoardSlug)
        XCTAssertNil(state.snapshot)
        XCTAssertTrue(state.selectedCardIDs.isEmpty)
        XCTAssertEqual(state.boardSelectionNotice?.boardName, "Release")
        XCTAssertTrue(state.requiresBoardSelection)
    }

    func testRemovedBoardReloadPreservesPartialCompatibilityAndDisplayName() async {
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"},{"slug":"release","name":"Release"}],"current":"main","read_only":false}"#
            )),
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#
            ))
        ])
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        await state.selectBoard("release")

        await state.load()

        XCTAssertEqual(state.state, .partial)
        XCTAssertEqual(state.report?.warnings, [.unsupportedStatus("future")])
        XCTAssertNil(state.selectedBoardSlug)
        XCTAssertEqual(state.boardSelectionNotice?.boardName, "Release")
    }

    func testPartialBoardContractDisablesBoardManagement() async {
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"}],"current":"main"}"#
            ))
        ])
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        XCTAssertEqual(state.state, .partial)
        XCTAssertFalse(state.canManageBoards)
        await state.createBoard(KanbanCreateBoardRequest(
            slug: "release",
            name: "Release",
            description: "",
            icon: "",
            color: ""
        ))
        let createRequestCount = await client.createRequestCount
        XCTAssertEqual(createRequestCount, 0)
    }

    func testNetworkBoardCollectionFailureRefreshesSelectedBoardAndKeepsWritesDisabled() async {
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#
            )),
            .failure(APIError.network(underlying: URLError(.notConnectedToInternet)))
        ])
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        let loadedCards = state.allCards

        await state.refresh()

        XCTAssertFalse(state.isOffline)
        XCTAssertFalse(state.loadedDetailIsStale)
        XCTAssertEqual(state.allCards, loadedCards)
        XCTAssertFalse(state.canManageBoards)
        XCTAssertTrue(state.refreshFailed)
    }

    func testIncompleteBoardCollectionRefreshesSelectedBoardButKeepsWritesDisabled() async {
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#
            )),
            .success(mutationDecode(
                #"{"current":"main","read_only":false}"#
            ))
        ], refreshBoardSnapshot: mutationDecode(
            #"{"changed":true,"latest_event_id":12,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"REFRESHED","status":"ready"}]}]}"#
        ))
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        await state.refresh()

        XCTAssertFalse(state.isOffline)
        XCTAssertTrue(state.refreshFailed)
        XCTAssertEqual(state.allCards.map(\.cardID), ["REFRESHED"])
        XCTAssertFalse(state.canUseServerAuthoritativeActions)
        XCTAssertFalse(state.canManageBoards)
    }

    func testCancelledBoardCollectionRefreshDoesNotReportFailureOrBlockWrites() async {
        let client = DeferredBoardCollectionClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        let refresh = Task { await state.refresh() }
        await client.waitForDeferredCollection()
        refresh.cancel()
        await client.resumeDeferredCollection()
        await refresh.value

        XCTAssertFalse(state.refreshFailed)
        XCTAssertTrue(state.canUseServerAuthoritativeActions)
        let boardRequestCount = await client.boardRequestCount
        XCTAssertEqual(boardRequestCount, 1)
    }

    func testBoardManagementStateRemainsIsolatedPerServer() async {
        let firstClient = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#
            )),
            .success(mutationDecode(
                #"{"boards":[{"slug":"main","name":"Main"},{"slug":"release","name":"Release"}],"current":"main","read_only":false}"#
            ))
        ])
        let secondClient = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"personal","name":"Personal"}],"current":"personal","read_only":false}"#
            ))
        ])
        let first = KanbanFeatureState(
            server: URL(string: "https://first.example.test")!,
            client: firstClient
        )
        let second = KanbanFeatureState(
            server: URL(string: "https://second.example.test")!,
            client: secondClient
        )
        await first.load()
        await second.load()

        await first.createBoard(KanbanCreateBoardRequest(
            slug: "release",
            name: "Release",
            description: "",
            icon: "",
            color: ""
        ))

        XCTAssertTrue(first.boards.contains { $0.slug == "release" })
        XCTAssertEqual(second.boards.map(\.slug), ["personal"])
        XCTAssertEqual(second.selectedBoardSlug, "personal")
        let secondCreateRequestCount = await secondClient.createRequestCount
        XCTAssertEqual(secondCreateRequestCount, 0)
    }

    func testAmbiguousBoardWriteChecksAuthoritativeListAndDefaultArchiveIsBlocked() async {
        let client = BoardManagementClient(
            boardsResponses: [
                .success(mutationDecode(
                    #"{"boards":[{"slug":"default"}],"current":"default","read_only":false}"#
                )),
                .success(mutationDecode(
                    #"{"boards":[{"slug":"default"},{"slug":"release"}],"current":"default","read_only":false}"#
                ))
            ],
            createResult: .failure(APIError.network(underlying: URLError(.timedOut)))
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        await state.archiveBoard(slug: "default")
        let archiveRequestCount = await client.archiveRequestCount
        XCTAssertEqual(archiveRequestCount, 0)

        await state.createBoard(KanbanCreateBoardRequest(
            slug: "release",
            name: "Release",
            description: "",
            icon: "",
            color: ""
        ))

        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        XCTAssertEqual(state.selectedBoardSlug, "default")
    }

    func testUncertainBoardWriteBlocksRetryUntilAnotherAuthoritativeCheck() async {
        let client = BoardManagementClient(
            boardsResponses: [
                .success(mutationDecode(
                    #"{"boards":[{"slug":"main"},{"slug":"release"}],"current":"main","read_only":false}"#
                )),
                .failure(APIError.network(underlying: URLError(.networkConnectionLost))),
                .success(mutationDecode(
                    #"{"boards":[{"slug":"main"},{"slug":"release"},{"slug":"planned"}],"current":"main","read_only":false}"#
                ))
            ],
            createResult: .failure(APIError.network(underlying: URLError(.timedOut)))
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()
        state.beginSelectingCards()
        if let card = state.allCards.first { state.toggleCardSelection(card) }

        await state.createBoard(KanbanCreateBoardRequest(
            slug: "planned",
            name: "Planned",
            description: "",
            icon: "",
            color: ""
        ))

        XCTAssertEqual(state.boardMutationState?.phase, .outcomeUncertain)
        XCTAssertFalse(state.canManageBoards)
        XCTAssertFalse(state.canAddComments)
        XCTAssertFalse(state.canMutateCards)
        XCTAssertEqual(state.bulkActionsAvailability, .boardBusy)
        await state.selectBoard("release")
        XCTAssertEqual(state.selectedBoardSlug, "main")
        await state.checkBoardMutationResult()
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        XCTAssertTrue(state.canManageBoards)
        XCTAssertTrue(state.canMutateCards)
    }

    func testReloadInvalidatesInFlightBoardMutationBeforeItCanApplyStaleState() async {
        let client = BoardManagementClient(
            boardsResponses: [
                .success(mutationDecode(
                    #"{"boards":[{"slug":"main","name":"Original"}],"current":"main","read_only":false}"#
                )),
                .success(mutationDecode(
                    #"{"boards":[{"slug":"main","name":"Reloaded"}],"current":"main","read_only":false}"#
                ))
            ],
            defersCreate: true
        )
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        let creation = Task {
            await state.createBoard(KanbanCreateBoardRequest(
                slug: "release",
                name: "Release",
                description: "",
                icon: "",
                color: ""
            ))
        }
        await client.waitForDeferredCreate()
        XCTAssertEqual(state.boardMutationState?.phase, .updating)

        await state.load()
        XCTAssertEqual(state.boards.first?.name, "Reloaded")
        XCTAssertNil(state.boardMutationState)

        await client.resumeDeferredCreate()
        await creation.value

        XCTAssertEqual(state.boards.first?.name, "Reloaded")
        XCTAssertNil(state.boardMutationState)
        let boardsRequestCount = await client.boardsRequestCount
        XCTAssertEqual(boardsRequestCount, 2)
    }

    func testEditActivateAndArchiveReconcileTheBoardCollection() async {
        let client = BoardManagementClient(boardsResponses: [
            .success(mutationDecode(
                #"{"boards":[{"slug":"default","name":"Default"},{"slug":"release","name":"Old"}],"current":"default","read_only":false}"#
            )),
            .success(mutationDecode(
                ##"{"boards":[{"slug":"default","name":"Default"},{"slug":"release","name":"Release","description":"","icon":"🚀","color":"#00AAFF"}],"current":"default","read_only":false}"##
            )),
            .success(mutationDecode(
                ##"{"boards":[{"slug":"default","name":"Default"},{"slug":"release","name":"Release","description":"","icon":"🚀","color":"#00AAFF"}],"current":"release","read_only":false}"##
            )),
            .success(mutationDecode(
                #"{"boards":[{"slug":"default","name":"Default"}],"current":"default","read_only":false}"#
            ))
        ])
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)
        await state.load()

        await state.editBoard(KanbanEditBoardRequest(
            slug: "release",
            name: "Release",
            description: "",
            icon: "🚀",
            color: "#00AAFF"
        ))
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)

        await state.makeBoardActive(slug: "release")
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        XCTAssertEqual(state.sharedActiveBoardSlug, "release")
        XCTAssertEqual(state.selectedBoardSlug, "default")

        await state.archiveBoard(slug: "release")
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        XCTAssertFalse(state.boards.contains { $0.slug == "release" })
        let editRequest = await client.editRequests().first
        let activeRequest = await client.activeRequests().first
        let archiveRequest = await client.archiveRequests().first
        XCTAssertEqual(editRequest?.slug, "release")
        XCTAssertEqual(activeRequest?.slug, "release")
        XCTAssertEqual(archiveRequest?.slug, "release")
    }

    func testMissingBoardManagementEndpointDisablesOnlyThatCapabilityUntilReload() async {
        let missingEndpoint = APIError.http(
            statusCode: 404,
            body: #"{"error":"Unknown Kanban endpoint; refresh the client"}"#
        )
        let client = BoardManagementClient(
            boardsResponses: [
                .success(KanbanFixtures.boards),
                .success(KanbanFixtures.boards)
            ],
            createResult: .failure(missingEndpoint),
            boardSnapshot: KanbanFixtures.snapshot
        )
        let state = KanbanFeatureState(
            server: URL(string: "https://capability.example.test")!,
            client: client
        )

        await state.load()
        await state.createBoard(KanbanCreateBoardRequest(
            slug: "release",
            name: "Release",
            description: "",
            icon: "",
            color: ""
        ))

        XCTAssertEqual(state.state, .partial)
        XCTAssertEqual(state.unavailableWriteCapabilities, [.boardManagement])
        XCTAssertFalse(state.canManageBoards)
        XCTAssertTrue(state.canCreateCards)
        XCTAssertTrue(state.canUseCardWorkflow)

        await state.load()

        XCTAssertEqual(state.state, .compatible)
        XCTAssertTrue(state.unavailableWriteCapabilities.isEmpty)
        XCTAssertTrue(state.canManageBoards)
    }

    func testCapabilityDetectionDoesNotConfuseMissingEntitiesWithMissingEndpoints() {
        XCTAssertTrue(KanbanEndpointCompatibility.isMissingCapability(
            APIError.http(statusCode: 405, body: nil)
        ))
        XCTAssertTrue(KanbanEndpointCompatibility.isMissingCapability(
            APIError.http(
                statusCode: 404,
                body: #"{"error":"Unknown Kanban endpoint; refresh the client"}"#
            )
        ))
        XCTAssertFalse(KanbanEndpointCompatibility.isMissingCapability(
            APIError.http(statusCode: 404, body: #"{"error":"task not found"}"#)
        ))
        XCTAssertFalse(KanbanEndpointCompatibility.isMissingCapability(
            APIError.http(statusCode: 404, body: nil)
        ))
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

private actor BoardManagementClient: KanbanDataClient {
    private var boardsResponses: [Result<KanbanBoardsResponse, Error>]
    private let createResult: Result<KanbanBoardMutationEnvelope, Error>
    private let configuration: KanbanConfiguration
    private var boardSnapshots: [KanbanBoardSnapshot]
    private var createContinuation: CheckedContinuation<Void, Never>?
    private let defersCreate: Bool
    private var shouldDeferCreate: Bool
    private var recordedBoardRequests: [KanbanBoardRequest] = []
    private var recordedEditRequests: [KanbanEditBoardRequest] = []
    private var recordedArchiveRequests: [KanbanBoardMutationRequest] = []
    private var recordedActiveRequests: [KanbanBoardMutationRequest] = []
    private(set) var createRequestCount = 0
    private(set) var archiveRequestCount = 0
    private(set) var makeActiveRequestCount = 0
    private(set) var boardsRequestCount = 0

    init(
        boardsResponses: [Result<KanbanBoardsResponse, Error>],
        createResult: Result<KanbanBoardMutationEnvelope, Error> = .success(
            mutationDecode(#"{"board":{"slug":"release"},"current":"main","read_only":false}"#)
        ),
        configuration: KanbanConfiguration = KanbanFixtures.configuration,
        boardSnapshot: KanbanBoardSnapshot = KanbanFixtures.richSnapshot,
        refreshBoardSnapshot: KanbanBoardSnapshot? = nil,
        defersCreate: Bool = false
    ) {
        self.boardsResponses = boardsResponses
        self.createResult = createResult
        self.configuration = configuration
        boardSnapshots = [boardSnapshot]
        if let refreshBoardSnapshot {
            boardSnapshots.append(refreshBoardSnapshot)
        }
        self.defersCreate = defersCreate
        shouldDeferCreate = defersCreate
    }

    func kanbanConfiguration() -> KanbanConfiguration { configuration }

    func kanbanBoards() throws -> KanbanBoardsResponse {
        boardsRequestCount += 1
        if boardsResponses.count > 1 {
            return try boardsResponses.removeFirst().get()
        }
        return try boardsResponses[0].get()
    }

    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot {
        recordedBoardRequests.append(request)
        if boardSnapshots.count > 1 {
            return boardSnapshots.removeFirst()
        }
        return boardSnapshots[0]
    }

    func kanbanStats(board: String) -> KanbanStats { KanbanFixtures.stats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { KanbanFixtures.history }

    func createKanbanBoard(_ request: KanbanCreateBoardRequest) async throws -> KanbanBoardMutationEnvelope {
        createRequestCount += 1
        if shouldDeferCreate {
            shouldDeferCreate = false
            await withCheckedContinuation { createContinuation = $0 }
        }
        return try createResult.get()
    }

    func archiveKanbanBoard(
        _ request: KanbanBoardMutationRequest
    ) -> KanbanBoardMutationEnvelope {
        archiveRequestCount += 1
        recordedArchiveRequests.append(request)
        return mutationDecode(#"{"current":"main","read_only":false}"#)
    }

    func editKanbanBoard(
        _ request: KanbanEditBoardRequest
    ) -> KanbanBoardMutationEnvelope {
        recordedEditRequests.append(request)
        return mutationDecode(#"{"board":{"slug":"\#(request.slug)"},"read_only":false}"#)
    }

    func makeKanbanBoardActive(
        _ request: KanbanBoardMutationRequest
    ) -> KanbanBoardMutationEnvelope {
        makeActiveRequestCount += 1
        recordedActiveRequests.append(request)
        return mutationDecode(#"{"current":"\#(request.slug)","read_only":false}"#)
    }

    func boardRequests() -> [KanbanBoardRequest] { recordedBoardRequests }
    func editRequests() -> [KanbanEditBoardRequest] { recordedEditRequests }
    func archiveRequests() -> [KanbanBoardMutationRequest] { recordedArchiveRequests }
    func activeRequests() -> [KanbanBoardMutationRequest] { recordedActiveRequests }

    func waitForDeferredCreate() async {
        guard defersCreate else { return }
        while createContinuation == nil { await Task.yield() }
    }

    func resumeDeferredCreate() {
        createContinuation?.resume()
        createContinuation = nil
    }
}

private actor DeferredBoardCollectionClient: KanbanDataClient {
    private var collectionRequestCount = 0
    private var collectionContinuation: CheckedContinuation<KanbanBoardsResponse, Never>?
    private(set) var boardRequestCount = 0

    func kanbanConfiguration() -> KanbanConfiguration { KanbanFixtures.configuration }

    func kanbanBoards() async -> KanbanBoardsResponse {
        collectionRequestCount += 1
        if collectionRequestCount != 2 {
            return KanbanFixtures.boards
        }
        return await withCheckedContinuation { collectionContinuation = $0 }
    }

    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot {
        boardRequestCount += 1
        return KanbanFixtures.richSnapshot
    }

    func kanbanStats(board: String) -> KanbanStats { KanbanFixtures.stats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { KanbanFixtures.history }

    func dispatchKanban(_ request: KanbanDispatchRequest) -> KanbanDispatchResult {
        mutationDecode(
            #"{"spawned":[],"promoted":0,"reclaimed":0,"skipped_unassigned":[],"skipped_nonspawnable":[],"auto_blocked":[],"timed_out":[],"crashed":[]}"#
        )
    }

    func waitForDeferredCollection() async {
        while collectionContinuation == nil { await Task.yield() }
    }

    func resumeDeferredCollection(
        _ response: KanbanBoardsResponse = KanbanFixtures.boards
    ) {
        collectionContinuation?.resume(returning: response)
        collectionContinuation = nil
    }
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

private actor DispatcherClient: KanbanDataClient {
    private let configuration: KanbanConfiguration
    private var boardsResponses: [KanbanBoardsResponse]
    private var boardResults: [Result<KanbanBoardSnapshot, Error>]
    private var dispatchResults: [Result<KanbanDispatchResult, Error>]
    private let statsError: Error?
    private var shouldDeferDispatch: Bool
    private var dispatchContinuation: CheckedContinuation<Void, Never>?
    private(set) var dispatchRequests: [KanbanDispatchRequest] = []
    private(set) var boardRequestCount = 0

    var dispatchRequestCount: Int { dispatchRequests.count }

    init(
        configuration: KanbanConfiguration = mutationDecode(
            #"{"columns":["triage","todo","ready","running","blocked","done"],"read_only":false}"#
        ),
        boardsResponses: [KanbanBoardsResponse] = [
            mutationDecode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#)
        ],
        boardSnapshots: [KanbanBoardSnapshot] = [mutationSnapshot()],
        boardResults: [Result<KanbanBoardSnapshot, Error>]? = nil,
        dispatchResults: [Result<KanbanDispatchResult, Error>] = [
            .success(mutationDecode(
                #"{"spawned":[{"future":"shape"}],"promoted":0,"reclaimed":0,"skipped_unassigned":[],"skipped_nonspawnable":[],"auto_blocked":[],"timed_out":[],"crashed":[]}"#
            ))
        ],
        statsError: Error? = nil,
        defersFirstDispatch: Bool = false
    ) {
        self.configuration = configuration
        self.boardsResponses = boardsResponses
        self.boardResults = boardResults ?? boardSnapshots.map(Result.success)
        self.dispatchResults = dispatchResults
        self.statsError = statsError
        shouldDeferDispatch = defersFirstDispatch
    }

    func kanbanConfiguration() -> KanbanConfiguration {
        configuration
    }

    func kanbanBoards() -> KanbanBoardsResponse {
        if boardsResponses.count > 1 { return boardsResponses.removeFirst() }
        return boardsResponses[0]
    }

    func kanbanBoard(_ request: KanbanBoardRequest) throws -> KanbanBoardSnapshot {
        boardRequestCount += 1
        if boardResults.count > 1 { return try boardResults.removeFirst().get() }
        return try boardResults[0].get()
    }

    func kanbanStats(board: String) throws -> KanbanStats {
        if let statsError { throw statsError }
        return mutationDecode("{}")
    }

    func kanbanAssignees(board: String) -> KanbanAssigneeHistory {
        mutationDecode("{}")
    }

    func dispatchKanban(_ request: KanbanDispatchRequest) async throws -> KanbanDispatchResult {
        dispatchRequests.append(request)
        if shouldDeferDispatch {
            shouldDeferDispatch = false
            await withCheckedContinuation { dispatchContinuation = $0 }
        }
        return try dispatchResults.removeFirst().get()
    }

    func waitForDeferredDispatch() async {
        while dispatchContinuation == nil { await Task.yield() }
    }

    func resumeDeferredDispatch() {
        dispatchContinuation?.resume()
        dispatchContinuation = nil
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

private actor BulkActionClient: KanbanDataClient {
    private var boardSnapshots: [KanbanBoardSnapshot]
    private var boardsResponses: [KanbanBoardsResponse]
    private var bulkResponses: [KanbanBulkActionEnvelope]
    private var detailResults: [String: [Result<KanbanCardDetailEnvelope, Error>]]
    private var recordedBulkRequests: [KanbanBulkActionRequest] = []
    private var recordedDetailRequests: [String] = []
    private var shouldDeferBulkResponse: Bool
    private var bulkContinuation: CheckedContinuation<Void, Never>?
    private var shouldDeferDetailResponse: Bool
    private var detailContinuation: CheckedContinuation<Void, Never>?
    private var bulkError: Error?

    init(
        boardSnapshots: [KanbanBoardSnapshot],
        boardsResponses: [KanbanBoardsResponse] = [
            mutationDecode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#)
        ],
        bulkResponses: [KanbanBulkActionEnvelope],
        detailResults: [String: [Result<KanbanCardDetailEnvelope, Error>]],
        defersFirstBulkResponse: Bool = false,
        defersFirstDetailResponse: Bool = false,
        bulkError: Error? = nil
    ) {
        self.boardSnapshots = boardSnapshots
        self.boardsResponses = boardsResponses
        self.bulkResponses = bulkResponses
        self.detailResults = detailResults
        shouldDeferBulkResponse = defersFirstBulkResponse
        shouldDeferDetailResponse = defersFirstDetailResponse
        self.bulkError = bulkError
    }

    func kanbanConfiguration() -> KanbanConfiguration {
        mutationDecode(
            #"{"columns":["triage","todo","ready","running","blocked","done"],"assignees":["builder","reviewer"],"read_only":false}"#
        )
    }

    func kanbanBoards() -> KanbanBoardsResponse {
        if boardsResponses.count > 1 { return boardsResponses.removeFirst() }
        return boardsResponses[0]
    }

    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot {
        if boardSnapshots.count > 1 { return boardSnapshots.removeFirst() }
        return boardSnapshots[0]
    }

    func kanbanStats(board: String) -> KanbanStats { mutationDecode("{}") }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { mutationDecode("{}") }

    func performKanbanBulkAction(
        _ request: KanbanBulkActionRequest
    ) async throws -> KanbanBulkActionEnvelope {
        recordedBulkRequests.append(request)
        if shouldDeferBulkResponse {
            shouldDeferBulkResponse = false
            await withCheckedContinuation { bulkContinuation = $0 }
        }
        if let error = bulkError {
            bulkError = nil
            throw error
        }
        return bulkResponses.removeFirst()
    }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        recordedDetailRequests.append(request.cardID)
        if shouldDeferDetailResponse {
            shouldDeferDetailResponse = false
            await withCheckedContinuation { detailContinuation = $0 }
        }
        guard var results = detailResults[request.cardID], !results.isEmpty else {
            throw KanbanResponseError.nonJSONContentType
        }
        let result = results.removeFirst()
        detailResults[request.cardID] = results
        return try result.get()
    }

    func bulkRequests() -> [KanbanBulkActionRequest] { recordedBulkRequests }
    func detailRequests() -> [String] { recordedDetailRequests }

    func waitForDeferredBulkResponse() async {
        while bulkContinuation == nil { await Task.yield() }
    }

    func resumeDeferredBulkResponse() {
        bulkContinuation?.resume()
        bulkContinuation = nil
    }

    func waitForDeferredDetailResponse() async {
        while detailContinuation == nil { await Task.yield() }
    }

    func resumeDeferredDetailResponse() {
        detailContinuation?.resume()
        detailContinuation = nil
    }
}

private func mutationSnapshot(status: String = "todo") -> KanbanBoardSnapshot {
    return mutationDecode("""
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

private func bulkSnapshot(firstStatus: String, secondStatus: String) -> KanbanBoardSnapshot {
    let cards = [
        ("CARD-1", "First", firstStatus),
        ("CARD-2", "Second", secondStatus)
    ]
    let todoCards = cards
        .filter { $0.2 == "todo" }
        .map { #"{"id":"\#($0.0)","title":"\#($0.1)","status":"todo"}"# }
        .joined(separator: ",")
    let doneCards = cards
        .filter { $0.2 == "done" }
        .map { #"{"id":"\#($0.0)","title":"\#($0.1)","status":"done"}"# }
        .joined(separator: ",")
    return mutationDecode("""
    {
      "changed": true,
      "read_only": false,
      "columns": [
        {"name":"triage","tasks":[]},
        {"name":"todo","tasks":[\(todoCards)]},
        {"name":"ready","tasks":[]},
        {"name":"running","tasks":[]},
        {"name":"blocked","tasks":[]},
        {"name":"done","tasks":[\(doneCards)]}
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

extension XCTestCase {
    /// `KanbanFeatureState` persists the browsed Board slug into
    /// `UserDefaults.standard` unless a test injects its own suite (#259). Clear
    /// those keys so one test's browsing cannot leak into another's cold load.
    func clearSavedKanbanBoards() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("kanban.selectedBoard|") {
            defaults.removeObject(forKey: key)
        }
    }
}
