import Foundation
import Observation

enum KanbanCompatibilityState: Equatable {
    case idle
    case checking
    case compatible
    case partial
    case authenticationRequired
    case networkUnavailable
    case serverUnavailable
    case incompatibleContract
}

enum KanbanReadCapabilityWarning: Hashable, Sendable {
    case statsUnavailable
    case profileHistoryUnavailable
}

enum KanbanCardMutationPhase: Equatable, Sendable {
    case updating
    case checkingResult
    case succeeded
    case failed
    case outcomeUncertain

    var isInFlight: Bool { self == .updating || self == .checkingResult }
}

enum KanbanCardMutationKind: Equatable, Sendable {
    case status(String)
    case block(String?)
    case unblock
    case addPrerequisite(String)
    case removePrerequisite(String)
    case archive(previousStatus: String)
    case undoArchive(status: String)
}

struct KanbanCardMutationState: Equatable, Sendable {
    let kind: KanbanCardMutationKind
    let phase: KanbanCardMutationPhase
}

struct KanbanArchiveUndo: Equatable, Sendable {
    let cardID: String
    let cardTitle: String
    let previousStatus: String
    let expiresAt: Date
    let card: KanbanCard
}

private struct KanbanPendingDependencyChange {
    let prerequisiteID: String
    let isAdding: Bool
}

struct KanbanLiveUpdateTiming: Sendable {
    let coalescingDelay: Duration
    let reconnectDelays: [Duration]
    let pollingInterval: Duration
    let failuresBeforePolling: Int

    static let production = KanbanLiveUpdateTiming(
        coalescingDelay: .milliseconds(300),
        reconnectDelays: [.seconds(1), .seconds(2), .seconds(4)],
        pollingInterval: .seconds(30),
        failuresBeforePolling: 3
    )
}

/// Server-bound, transient Kanban browsing state. Each instance owns one
/// server's Board choice, filters, selection, and snapshots; nothing is shared
/// across servers or persisted by this slice.
@MainActor
@Observable
final class KanbanFeatureState {
    static let liveStatuses = ["triage", "todo", "ready", "running", "blocked", "done"]

    let server: URL
    private(set) var state: KanbanCompatibilityState = .idle
    private(set) var report: KanbanCompatibilityReport?
    private(set) var configuration: KanbanConfiguration?
    private(set) var boards: [KanbanBoard] = []
    private(set) var snapshot: KanbanBoardSnapshot?
    private(set) var stats: KanbanStats?
    private(set) var assigneeHistory: KanbanAssigneeHistory?
    private(set) var capabilityWarnings: Set<KanbanReadCapabilityWarning> = []
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var refreshFailed = false
    private(set) var isOffline = false
    private(set) var liveUpdatesDelayed = false
    private(set) var loadedDetailIsStale = false
    private(set) var liveCursor = 0
    private(set) var detailRefreshRevision = 0
    private(set) var cardMutationStates: [String: KanbanCardMutationState] = [:]
    private(set) var archiveUndo: KanbanArchiveUndo?

    private(set) var selectedBoardSlug: String?
    var selectedStatus = "triage"
    var searchText = ""
    var selectedProfile: String?
    var selectedTenant: String?
    var includeArchived = false
    var onlyMine = false
    var groupByProfile = false

    private var activeLoadID: UUID?
    private var activeBoardLoadID: UUID?
    private var boardsResponse: KanbanBoardsResponse?
    private let client: any KanbanDataClient
    private let streamClient: any KanbanEventStreamingClient
    private let timing: KanbanLiveUpdateTiming
    private let archiveUndoLifetime: TimeInterval
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void
    private let onAPIError: (Error) -> Void
    private var isVisible = false
    private var sceneIsActive = true
    private var liveGeneration = 0
    private var streamAttemptID = 0
    private var streamFailureCount = 0
    private var reconnectTask: Task<Void, Never>?
    private var coalescingTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var activeCardMutationIDs: [String: UUID] = [:]
    private var pendingOptimisticStatuses: [String: String] = [:]
    private var settledDetailStatuses: [String: String] = [:]
    private var uncertainProtectedCards: [String: KanbanCard] = [:]
    private var pendingDependencyChanges: [String: KanbanPendingDependencyChange] = [:]
    private var archiveUndoTask: Task<Void, Never>?

    init(
        server: URL,
        client: (any KanbanDataClient)? = nil,
        streamClient: (any KanbanEventStreamingClient)? = nil,
        timing: KanbanLiveUpdateTiming = .production,
        archiveUndoLifetime: TimeInterval = 8,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        onAPIError: @escaping (Error) -> Void = { _ in }
    ) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.streamClient = streamClient ?? KanbanEventStreamClient()
        self.timing = timing
        self.archiveUndoLifetime = archiveUndoLifetime
        self.sleep = sleep
        self.onAPIError = onAPIError
    }

    /// Future write slices must use this single seam before exposing any
    /// mutation, Dispatcher, or shared-state action.
    var canUseServerAuthoritativeActions: Bool {
        snapshot != nil && !isOffline && !isRefreshing
    }

    var canAddComments: Bool {
        canUseServerAuthoritativeActions
            && configuration?.readOnly == false
            && boardsResponse?.readOnly == false
            && snapshot?.readOnly == false
            && selectedBoard?.readOnly != true
    }

    var canMutateCards: Bool {
        canAddComments
            && Set(KanbanCardEditorState.createStatuses).isSubset(of: Set(configuration?.columns ?? []))
    }

    var hasAvailableArchiveUndo: Bool {
        guard let archiveUndo else { return false }
        return archiveUndo.expiresAt > Date()
    }

    var selectedBoard: KanbanBoard? {
        guard let selectedBoardSlug else { return nil }
        return boards.first { normalized($0.slug) == selectedBoardSlug }
    }

    var availableStatuses: [String] {
        var result = Self.liveStatuses
        if includeArchived { result.append("archived") }
        for column in snapshot?.columns ?? [] {
            guard let name = normalized(column.name), !result.contains(name) else { continue }
            result.append(name)
        }
        return result
    }

    var profileOptions: [String] {
        sortedUnique(
            (configuration?.assignees ?? [])
                + (assigneeHistory?.assignees ?? [])
                + (snapshot?.assignees ?? [])
                + allCards.compactMap(\.assignee)
        )
    }

    var tenantOptions: [String] {
        sortedUnique((snapshot?.tenants ?? []) + allCards.compactMap(\.tenant))
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedProfile != nil
            || selectedTenant != nil
            || includeArchived
            || onlyMine
    }

    var allCards: [KanbanCard] {
        (snapshot?.columns ?? []).flatMap { $0.cards ?? [] }
    }

    var visibleCards: [KanbanCard] {
        searchMatchedCards.filter { $0.status?.rawValue == selectedStatus }
    }

    var groupedVisibleCards: [(profile: String?, cards: [KanbanCard])] {
        let groups = Dictionary(grouping: visibleCards, by: { normalized($0.assignee) })
        return groups
            .map { (profile: $0.key, cards: $0.value) }
            .sorted {
                switch ($0.profile, $1.profile) {
                case (nil, nil): false
                case (nil, _): true
                case (_, nil): false
                case let (left?, right?): left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }
            }
    }

    func statusCount(_ status: String) -> Int {
        searchMatchedCards.count { $0.status?.rawValue == status }
    }

    func canMutateCard(_ card: KanbanCard) -> Bool {
        guard canMutateCards,
              normalizedOptional(card.cardID) != nil,
              let status = card.status?.rawValue else { return false }
        return Self.liveStatuses.contains(status) || status == "archived"
    }

    func isMutatingCard(_ cardID: String?) -> Bool {
        guard let cardID = normalizedOptional(cardID) else { return false }
        return activeCardMutationIDs[cardID] != nil
    }

    func mutationState(for cardID: String?) -> KanbanCardMutationState? {
        guard let cardID = normalizedOptional(cardID) else { return nil }
        return cardMutationStates[cardID]
    }

    func moveDestinations(for card: KanbanCard) -> [String] {
        guard canMutateCard(card) else { return [] }
        let ordinaryDestinations = Set(["triage", "todo", "ready"])
        return (configuration?.columns ?? [])
            .filter { ordinaryDestinations.contains($0) && $0 != card.status?.rawValue }
    }

    func displayedPrerequisites(for cardID: String, canonical: [String]) -> [String] {
        guard let change = pendingDependencyChanges[cardID] else { return canonical }
        var result = canonical.filter { $0 != change.prerequisiteID }
        if change.isAdding { result.append(change.prerequisiteID) }
        return Array(Set(result)).sorted()
    }

    func displayedCard(_ canonical: KanbanCard) -> KanbanCard {
        guard let cardID = normalizedOptional(canonical.cardID),
              let status = pendingOptimisticStatuses[cardID] ?? settledDetailStatuses[cardID] else {
            return canonical
        }
        return canonical.replacingStatus(status)
    }

    func acknowledgeLoadedCardDetail(_ detail: KanbanCardDetailEnvelope) {
        guard let cardID = normalizedOptional(detail.card?.cardID),
              activeCardMutationIDs[cardID] == nil,
              cardMutationStates[cardID]?.phase == .succeeded else { return }
        settledDetailStatuses[cardID] = nil
        pendingDependencyChanges[cardID] = nil
    }

    func moveCard(
        _ card: KanbanCard,
        to status: String,
        confirmingRunningExit: Bool = false
    ) async {
        guard status != "running", moveDestinations(for: card).contains(status) else { return }
        await performStatusMutation(
            card,
            status: status,
            kind: .status(status),
            confirmingRunningExit: confirmingRunningExit
        )
    }

    func completeCard(_ card: KanbanCard, confirmingRunningExit: Bool = false) async {
        guard card.status?.rawValue != "done", card.status?.rawValue != "archived" else { return }
        await performStatusMutation(
            card,
            status: "done",
            kind: .status("done"),
            confirmingRunningExit: confirmingRunningExit
        )
    }

    func archiveCard(_ card: KanbanCard, confirmingRunningExit: Bool = false) async {
        guard let previousStatus = card.status?.rawValue, previousStatus != "archived" else { return }
        await performStatusMutation(
            card,
            status: "archived",
            kind: .archive(previousStatus: previousStatus),
            confirmingRunningExit: confirmingRunningExit
        )
    }

    func blockCard(
        _ card: KanbanCard,
        reason: String?,
        confirmingRunningExit: Bool = false
    ) async {
        guard canMutateCard(card), card.status?.rawValue != "blocked", card.status?.rawValue != "archived" else { return }
        let reason = normalizedOptional(reason)
        await performStatusMutation(
            card,
            status: "blocked",
            kind: .block(reason),
            confirmingRunningExit: confirmingRunningExit
        ) { [client, selectedBoardSlug] cardID in
            guard let board = selectedBoardSlug else { throw CancellationError() }
            return try await client.blockKanbanCard(
                KanbanCardActionRequest(cardID: cardID, board: board, reason: reason)
            )
        }
    }

    func unblockCard(_ card: KanbanCard) async {
        guard canMutateCard(card), card.status?.rawValue == "blocked" else { return }
        await performStatusMutation(card, status: "ready", kind: .unblock) { [client, selectedBoardSlug] cardID in
            guard let board = selectedBoardSlug else { throw CancellationError() }
            return try await client.unblockKanbanCard(
                KanbanCardActionRequest(cardID: cardID, board: board, reason: nil)
            )
        }
    }

    func addPrerequisite(_ prerequisiteID: String, to card: KanbanCard) async {
        await mutatePrerequisite(prerequisiteID, card: card, isAdding: true)
    }

    func removePrerequisite(_ prerequisiteID: String, from card: KanbanCard) async {
        await mutatePrerequisite(prerequisiteID, card: card, isAdding: false)
    }

    func undoArchive() async {
        guard hasAvailableArchiveUndo,
              let undo = archiveUndo,
              let board = selectedBoardSlug else {
            archiveUndo = nil
            return
        }
        archiveUndoTask?.cancel()
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: undo.cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: undo.cardID)
            guard let card = detail.card, card.status?.rawValue == "archived" else {
                archiveUndo = nil
                if let card = detail.card { replaceCardInSnapshot(card) }
                cardMutationStates[undo.cardID] = KanbanCardMutationState(
                    kind: .undoArchive(status: undo.previousStatus), phase: .failed
                )
                detailRefreshRevision &+= 1
                return
            }
            archiveUndo = nil
            await performStatusMutation(
                card,
                status: undo.previousStatus,
                kind: .undoArchive(status: undo.previousStatus)
            )
            if let phase = cardMutationStates[undo.cardID]?.phase,
               phase == .failed || phase == .outcomeUncertain {
                archiveUndo = recoveryUndo(from: undo, card: card)
            }
        } catch {
            forwardAuthentication(error)
            if isNotFound(error) {
                archiveUndo = nil
                uncertainProtectedCards[undo.cardID] = nil
                removeCardFromSnapshot(undo.cardID)
                cardMutationStates[undo.cardID] = KanbanCardMutationState(
                    kind: .undoArchive(status: undo.previousStatus), phase: .failed
                )
                detailRefreshRevision &+= 1
                return
            }
            archiveUndo = recoveryUndo(from: undo, card: undo.card)
            cardMutationStates[undo.cardID] = KanbanCardMutationState(
                kind: .undoArchive(status: undo.previousStatus), phase: .outcomeUncertain
            )
        }
    }

    func retryMutation(for card: KanbanCard) async {
        guard let cardID = normalizedOptional(card.cardID),
              let mutation = cardMutationStates[cardID],
              mutation.phase == .failed else { return }
        switch mutation.kind {
        case let .status(status):
            await performStatusMutation(card, status: status, kind: mutation.kind)
        case let .block(reason):
            await blockCard(card, reason: reason)
        case .unblock:
            await unblockCard(card)
        case let .addPrerequisite(prerequisiteID):
            await addPrerequisite(prerequisiteID, to: card)
        case let .removePrerequisite(prerequisiteID):
            await removePrerequisite(prerequisiteID, from: card)
        case .archive:
            await archiveCard(card)
        case let .undoArchive(status):
            await performStatusMutation(card, status: status, kind: mutation.kind)
        }
    }

    func checkUncertainMutation(for card: KanbanCard) async {
        guard let cardID = normalizedOptional(card.cardID),
              let mutation = cardMutationStates[cardID],
              mutation.phase == .outcomeUncertain,
              activeCardMutationIDs[cardID] == nil,
              let board = selectedBoardSlug else { return }
        cardMutationStates[cardID] = KanbanCardMutationState(
            kind: mutation.kind,
            phase: .checkingResult
        )
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
            guard let authoritative = detail.card else { throw KanbanMutationSettlementError.unexpectedStatus }
            uncertainProtectedCards[cardID] = nil
            replaceCardInSnapshot(authoritative)
            let succeeded: Bool
            switch mutation.kind {
            case let .status(status), let .undoArchive(status):
                succeeded = authoritative.status?.rawValue == status
            case .block:
                succeeded = authoritative.status?.rawValue == "blocked"
            case .unblock:
                succeeded = authoritative.status?.rawValue == "ready"
            case .archive:
                succeeded = authoritative.status?.rawValue == "archived"
            case let .addPrerequisite(prerequisiteID):
                succeeded = detail.links?.prerequisites?.contains(prerequisiteID) == true
            case let .removePrerequisite(prerequisiteID):
                succeeded = detail.links?.prerequisites?.contains(prerequisiteID) != true
            }
            cardMutationStates[cardID] = KanbanCardMutationState(
                kind: mutation.kind,
                phase: succeeded ? .succeeded : .failed
            )
            if case .undoArchive = mutation.kind, succeeded { archiveUndo = nil }
            detailRefreshRevision &+= 1
        } catch {
            forwardAuthentication(error)
            if isNotFound(error) {
                uncertainProtectedCards[cardID] = nil
                removeCardFromSnapshot(cardID)
                if case .undoArchive = mutation.kind { archiveUndo = nil }
            }
            cardMutationStates[cardID] = KanbanCardMutationState(
                kind: mutation.kind,
                phase: isNotFound(error) ? .failed : .outcomeUncertain
            )
        }
    }

    func load() async {
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        resetLiveUpdates(clearCursor: true)
        let loadID = UUID()
        activeLoadID = loadID
        activeBoardLoadID = nil
        isLoading = true
        refreshFailed = false
        state = .checking
        report = nil
        configuration = nil
        boards = []
        boardsResponse = nil
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        capabilityWarnings = []
        defer {
            if activeLoadID == loadID { isLoading = false }
        }

        do {
            // Ordered exactly as §17.2 requires; every probe is a verified GET.
            let configuration = try await client.kanbanConfiguration()
            guard isCurrent(loadID) else { return }
            let boardsResponse = try await client.kanbanBoards()
            guard isCurrent(loadID) else { return }
            guard let currentBoard = normalized(boardsResponse.current) else {
                throw KanbanContractViolation.missingCurrentBoard
            }
            let snapshot = try await client.kanbanBoard(KanbanBoardRequest(board: currentBoard))
            guard isCurrent(loadID) else { return }

            let report = try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: boardsResponse,
                snapshot: snapshot
            )
            guard isCurrent(loadID) else { return }
            self.configuration = configuration
            self.boardsResponse = boardsResponse
            boards = boardsResponse.boards ?? []
            selectedBoardSlug = currentBoard
            self.snapshot = snapshot
            detailRefreshRevision &+= 1
            liveCursor = max(0, snapshot.latestEventID ?? 0)
            self.report = report
            state = report.isPartial ? .partial : .compatible

            await loadSupplementaryReads(board: currentBoard, loadID: loadID)
            startLiveUpdatesIfReady()
        } catch is CancellationError {
            guard activeLoadID == loadID else { return }
            report = nil
            state = .idle
        } catch {
            guard isCurrent(loadID) else { return }
            report = nil
            state = Self.classify(error)
            forwardAuthentication(error)
        }
    }

    func retry() async {
        if snapshot == nil {
            await load()
        } else {
            await refresh()
        }
    }

    func refresh() async {
        guard let board = selectedBoardSlug else { return }
        let generation = liveGeneration
        let succeeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        guard isSameLiveGeneration(board: board, generation: generation) else { return }
        if succeeded {
            isOffline = false
            loadedDetailIsStale = false
            retryLiveStream()
        } else if isOffline {
            startPollingIfNeeded()
        }
    }

    func selectBoard(_ slug: String) async {
        guard activeCardMutationIDs.isEmpty,
              boards.contains(where: { normalized($0.slug) == slug }),
              slug != selectedBoardSlug else { return }
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        resetLiveUpdates(clearCursor: true)
        selectedBoardSlug = slug
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        report = nil
        capabilityWarnings = []
        state = .compatible
        let succeeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        if succeeded { startLiveUpdatesIfReady() }
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible {
            startLiveUpdatesIfReady()
        } else {
            suspendLiveUpdates()
        }
    }

    func setSceneActive(_ active: Bool) async {
        guard sceneIsActive != active else { return }
        sceneIsActive = active
        if !active {
            suspendLiveUpdates()
            return
        }
        guard isVisible, snapshot != nil, let board = selectedBoardSlug else { return }
        let generation = liveGeneration
        let succeeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        guard isCurrentLiveWork(board: board, generation: generation) else { return }
        if succeeded {
            isOffline = false
            loadedDetailIsStale = false
            retryLiveStream()
        } else {
            startPollingIfNeeded()
        }
    }

    func setProfileFilter(_ profile: String?) async {
        selectedProfile = normalized(profile)
        if selectedProfile != nil { onlyMine = false }
        await refreshBoard(usingCursor: false)
    }

    func setTenantFilter(_ tenant: String?) async {
        selectedTenant = normalized(tenant)
        await refreshBoard(usingCursor: false)
    }

    func setIncludeArchived(_ included: Bool) async {
        includeArchived = included
        if !included, selectedStatus == "archived" { selectedStatus = "triage" }
        await refreshBoard(usingCursor: false)
    }

    func setOnlyMine(_ enabled: Bool) async {
        onlyMine = enabled
        if enabled { selectedProfile = nil }
        await refreshBoard(usingCursor: false)
    }

    func applyFilters(profile: String?, tenant: String?, includeArchived: Bool, onlyMine: Bool) async {
        selectedProfile = onlyMine ? nil : normalized(profile)
        selectedTenant = normalized(tenant)
        self.includeArchived = includeArchived
        self.onlyMine = onlyMine
        if !includeArchived, selectedStatus == "archived" { selectedStatus = "triage" }
        await refreshBoard(usingCursor: false)
    }

    func clearFilters() async {
        searchText = ""
        selectedProfile = nil
        selectedTenant = nil
        includeArchived = false
        onlyMine = false
        if selectedStatus == "archived" { selectedStatus = "triage" }
        await refreshBoard(usingCursor: false)
    }

    func makeCardDetailState(cardID: String) -> KanbanCardDetailState? {
        guard let board = selectedBoardSlug else { return nil }
        return KanbanCardDetailState(
            cardID: cardID,
            board: board,
            client: client,
            onAPIError: onAPIError,
            onDetailLoaded: { [weak self] detail in
                self?.acknowledgeLoadedCardDetail(detail)
            }
        )
    }

    func makeCreateCardEditorState() -> KanbanCardEditorState? {
        guard let board = selectedBoardSlug else { return nil }
        return KanbanCardEditorState(
            mode: .create,
            board: board,
            client: client,
            profileOptions: profileOptions,
            tenantOptions: tenantOptions,
            prerequisiteOptions: allCards.filter { $0.cardID != nil },
            baselineCards: allCards
        )
    }

    func makeEditCardEditorState(detail: KanbanCardDetailEnvelope) -> KanbanCardEditorState? {
        guard let board = selectedBoardSlug,
              let card = detail.card,
              let cardID = normalized(card.cardID) else { return nil }
        return KanbanCardEditorState(
            mode: .edit(cardID: cardID),
            board: board,
            client: client,
            card: card,
            prerequisiteID: detail.links?.prerequisites?.first,
            profileOptions: profileOptions,
            tenantOptions: tenantOptions,
            prerequisiteOptions: allCards.filter { $0.cardID != nil && $0.cardID != cardID },
            baselineCards: allCards
        )
    }

    func reconcileAfterCardMutation() async {
        _ = await refreshBoard(usingCursor: false, refreshSupplementary: true)
    }

    private func performStatusMutation(
        _ card: KanbanCard,
        status: String,
        kind: KanbanCardMutationKind,
        confirmingRunningExit: Bool = false,
        write: ((String) async throws -> KanbanCardMutationEnvelope)? = nil
    ) async {
        guard status != "running",
              card.status?.rawValue != "running" || confirmingRunningExit,
              canMutateCard(card),
              let cardID = normalizedOptional(card.cardID),
              activeCardMutationIDs[cardID] == nil,
              let board = selectedBoardSlug else { return }

        let baseline = cardInSnapshot(cardID) ?? card
        uncertainProtectedCards[cardID] = nil
        settledDetailStatuses[cardID] = nil
        let mutationID = UUID()
        activeCardMutationIDs[cardID] = mutationID
        pendingOptimisticStatuses[cardID] = status
        cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .updating)
        replaceCardInSnapshot(baseline.replacingStatus(status))

        do {
            let response: KanbanCardMutationEnvelope
            if let write {
                response = try await write(cardID)
            } else {
                response = try await client.setKanbanCardStatus(
                    KanbanCardStatusRequest(cardID: cardID, board: board, status: status)
                )
            }
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            let authoritative = try KanbanCardMutationValidator.validate(response, expectedCardID: cardID)
            guard authoritative.status?.rawValue == status else {
                throw KanbanMutationSettlementError.unexpectedStatus
            }
            settleSuccessfulStatusMutation(
                authoritative,
                baseline: baseline,
                kind: kind,
                mutationID: mutationID
            )
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            guard !isCancellation(error) else {
                restoreFailedOptimisticMutation(cardID: cardID, baseline: baseline, kind: kind, phase: .failed)
                return
            }
            forwardAuthentication(error)
            if isDefinitiveWriteFailure(error) {
                restoreFailedOptimisticMutation(cardID: cardID, baseline: baseline, kind: kind, phase: .failed)
            } else {
                cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .checkingResult)
                await reconcileStatusMutation(
                    cardID: cardID,
                    expectedStatus: status,
                    baseline: baseline,
                    kind: kind,
                    mutationID: mutationID
                )
            }
        }
    }

    private func reconcileStatusMutation(
        cardID: String,
        expectedStatus: String,
        baseline: KanbanCard,
        kind: KanbanCardMutationKind,
        mutationID: UUID
    ) async {
        guard let board = selectedBoardSlug else { return }
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
            guard activeCardMutationIDs[cardID] == mutationID, let authoritative = detail.card else { return }
            if authoritative.status?.rawValue == expectedStatus {
                settleSuccessfulStatusMutation(
                    authoritative,
                    baseline: baseline,
                    kind: kind,
                    mutationID: mutationID
                )
            } else {
                restoreFailedOptimisticMutation(
                    cardID: cardID,
                    baseline: authoritative,
                    kind: kind,
                    phase: .failed
                )
            }
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            forwardAuthentication(error)
            if isNotFound(error) {
                removeCardFromSnapshot(cardID)
                finishMutation(cardID: cardID, kind: kind, phase: .failed)
            } else {
                restoreFailedOptimisticMutation(
                    cardID: cardID,
                    baseline: baseline,
                    kind: kind,
                    phase: .outcomeUncertain
                )
            }
        }
    }

    private func settleSuccessfulStatusMutation(
        _ authoritative: KanbanCard,
        baseline: KanbanCard,
        kind: KanbanCardMutationKind,
        mutationID: UUID
    ) {
        guard let cardID = normalizedOptional(authoritative.cardID),
              activeCardMutationIDs[cardID] == mutationID else { return }
        pendingOptimisticStatuses[cardID] = nil
        settledDetailStatuses[cardID] = authoritative.status?.rawValue
        replaceCardInSnapshot(authoritative)
        finishMutation(cardID: cardID, kind: kind, phase: .succeeded)
        if case let .archive(previousStatus) = kind {
            offerArchiveUndo(
                card: authoritative,
                title: baseline.title,
                previousStatus: previousStatus
            )
        }
    }

    private func mutatePrerequisite(_ prerequisiteID: String, card: KanbanCard, isAdding: Bool) async {
        guard canMutateCard(card),
              let cardID = normalizedOptional(card.cardID),
              let prerequisiteID = normalizedOptional(prerequisiteID),
              prerequisiteID != cardID,
              activeCardMutationIDs[cardID] == nil,
              let board = selectedBoardSlug else { return }

        let kind: KanbanCardMutationKind = isAdding
            ? .addPrerequisite(prerequisiteID)
            : .removePrerequisite(prerequisiteID)
        let request = KanbanDependencyMutationRequest(
            board: board,
            prerequisiteID: prerequisiteID,
            dependentID: cardID
        )
        let mutationID = UUID()
        activeCardMutationIDs[cardID] = mutationID
        pendingDependencyChanges[cardID] = KanbanPendingDependencyChange(
            prerequisiteID: prerequisiteID,
            isAdding: isAdding
        )
        cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .updating)

        do {
            let response = try await (isAdding
                ? client.addKanbanDependency(request)
                : client.removeKanbanDependency(request))
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            try KanbanDependencyMutationValidator.validate(response, request: request)
            cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .checkingResult)
            await reconcileDependencyMutation(
                request: request,
                shouldExist: isAdding,
                kind: kind,
                mutationID: mutationID
            )
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            forwardAuthentication(error)
            if isDefinitiveWriteFailure(error) {
                pendingDependencyChanges[cardID] = nil
                finishMutation(cardID: cardID, kind: kind, phase: .failed)
            } else {
                cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: .checkingResult)
                await reconcileDependencyMutation(
                    request: request,
                    shouldExist: isAdding,
                    kind: kind,
                    mutationID: mutationID
                )
            }
        }
    }

    private func reconcileDependencyMutation(
        request: KanbanDependencyMutationRequest,
        shouldExist: Bool,
        kind: KanbanCardMutationKind,
        mutationID: UUID
    ) async {
        let cardID = request.dependentID
        do {
            let detail = try await client.kanbanCardDetail(
                KanbanCardDetailRequest(cardID: cardID, board: request.board)
            )
            try KanbanCardDetailValidator.validate(detail, requestedCardID: cardID)
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            let exists = detail.links?.prerequisites?.contains(request.prerequisiteID) == true
            let succeeded = exists == shouldExist
            if !succeeded { pendingDependencyChanges[cardID] = nil }
            finishMutation(cardID: cardID, kind: kind, phase: succeeded ? .succeeded : .failed)
        } catch {
            guard activeCardMutationIDs[cardID] == mutationID else { return }
            forwardAuthentication(error)
            pendingDependencyChanges[cardID] = nil
            finishMutation(
                cardID: cardID,
                kind: kind,
                phase: isNotFound(error) ? .failed : .outcomeUncertain
            )
        }
    }

    private func offerArchiveUndo(card: KanbanCard, title: String?, previousStatus: String) {
        guard let cardID = normalizedOptional(card.cardID) else { return }
        archiveUndoTask?.cancel()
        let undo = KanbanArchiveUndo(
            cardID: cardID,
            cardTitle: normalizedOptional(title) ?? cardID,
            previousStatus: previousStatus,
            expiresAt: Date().addingTimeInterval(archiveUndoLifetime),
            card: card
        )
        archiveUndo = undo
        archiveUndoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.archiveUndoLifetime))
            guard !Task.isCancelled, self.archiveUndo == undo else { return }
            self.archiveUndo = nil
        }
    }

    private func recoveryUndo(from undo: KanbanArchiveUndo, card: KanbanCard) -> KanbanArchiveUndo {
        KanbanArchiveUndo(
            cardID: undo.cardID,
            cardTitle: undo.cardTitle,
            previousStatus: undo.previousStatus,
            expiresAt: .distantFuture,
            card: card
        )
    }

    private func restoreFailedOptimisticMutation(
        cardID: String,
        baseline: KanbanCard,
        kind: KanbanCardMutationKind,
        phase: KanbanCardMutationPhase
    ) {
        pendingOptimisticStatuses[cardID] = nil
        settledDetailStatuses[cardID] = nil
        uncertainProtectedCards[cardID] = phase == .outcomeUncertain ? baseline : nil
        replaceCardInSnapshot(baseline)
        finishMutation(cardID: cardID, kind: kind, phase: phase)
    }

    private func finishMutation(
        cardID: String,
        kind: KanbanCardMutationKind,
        phase: KanbanCardMutationPhase
    ) {
        activeCardMutationIDs[cardID] = nil
        if phase != .outcomeUncertain { uncertainProtectedCards[cardID] = nil }
        cardMutationStates[cardID] = KanbanCardMutationState(kind: kind, phase: phase)
        detailRefreshRevision &+= 1
    }

    private func clearSettledMutationPresentation() {
        let activeCardIDs = Set(activeCardMutationIDs.keys)
        cardMutationStates = cardMutationStates.filter { activeCardIDs.contains($0.key) }
        pendingOptimisticStatuses = pendingOptimisticStatuses.filter { activeCardIDs.contains($0.key) }
        settledDetailStatuses = settledDetailStatuses.filter { activeCardIDs.contains($0.key) }
        pendingDependencyChanges = pendingDependencyChanges.filter { activeCardIDs.contains($0.key) }
        uncertainProtectedCards = uncertainProtectedCards.filter { activeCardIDs.contains($0.key) }
    }

    private func cardInSnapshot(_ cardID: String) -> KanbanCard? {
        allCards.first { normalizedOptional($0.cardID) == cardID }
    }

    private func replaceCardInSnapshot(_ card: KanbanCard) {
        guard let snapshot, let cardID = normalizedOptional(card.cardID),
              let destination = normalizedOptional(card.status?.rawValue) else { return }
        var destinationFound = false
        var columns = (snapshot.columns ?? []).map { column in
            var cards = (column.cards ?? []).filter { normalizedOptional($0.cardID) != cardID }
            if column.name == destination {
                cards.append(card)
                destinationFound = true
            }
            return KanbanColumn(name: column.name, cards: cards)
        }
        if !destinationFound, destination != "archived" || includeArchived {
            columns.append(KanbanColumn(name: destination, cards: [card]))
        }
        self.snapshot = snapshotReplacingColumns(snapshot, columns: columns)
    }

    private func removeCardFromSnapshot(_ cardID: String) {
        guard let snapshot else { return }
        let columns = (snapshot.columns ?? []).map { column in
            KanbanColumn(
                name: column.name,
                cards: (column.cards ?? []).filter { normalizedOptional($0.cardID) != cardID }
            )
        }
        self.snapshot = snapshotReplacingColumns(snapshot, columns: columns)
    }

    private func applyingPendingOptimism(to response: KanbanBoardSnapshot) -> KanbanBoardSnapshot {
        var result = response
        for card in uncertainProtectedCards.values {
            result = snapshotReplacing(card, in: result)
        }
        for (cardID, status) in pendingOptimisticStatuses {
            guard let card = (result.columns ?? []).flatMap({ $0.cards ?? [] }).first(where: {
                normalizedOptional($0.cardID) == cardID
            }) ?? cardInSnapshot(cardID) else { continue }
            result = snapshotReplacing(card.replacingStatus(status), in: result)
        }
        return result
    }

    private func snapshotReplacing(_ card: KanbanCard, in snapshot: KanbanBoardSnapshot) -> KanbanBoardSnapshot {
        guard let cardID = normalizedOptional(card.cardID),
              let destination = normalizedOptional(card.status?.rawValue) else { return snapshot }
        var destinationFound = false
        var columns = (snapshot.columns ?? []).map { column in
            var cards = (column.cards ?? []).filter { normalizedOptional($0.cardID) != cardID }
            if column.name == destination {
                cards.append(card)
                destinationFound = true
            }
            return KanbanColumn(name: column.name, cards: cards)
        }
        if !destinationFound, destination != "archived" || includeArchived {
            columns.append(KanbanColumn(name: destination, cards: [card]))
        }
        return snapshotReplacingColumns(snapshot, columns: columns)
    }

    private func snapshotReplacingColumns(
        _ snapshot: KanbanBoardSnapshot,
        columns: [KanbanColumn]
    ) -> KanbanBoardSnapshot {
        KanbanBoardSnapshot(
            columns: columns,
            tenants: snapshot.tenants,
            assignees: snapshot.assignees,
            filters: snapshot.filters,
            changed: snapshot.changed,
            latestEventID: snapshot.latestEventID,
            readOnly: snapshot.readOnly
        )
    }

    private func isDefinitiveWriteFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return error is KanbanRequestError }
        switch apiError {
        case .unauthorized, .invalidServerURL:
            return true
        case let .http(statusCode, _):
            return (400..<500).contains(statusCode) && statusCode != 408
        case .network, .decoding:
            return false
        }
    }

    private func isNotFound(_ error: Error) -> Bool {
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404
    }

    private func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if case let APIError.network(underlying) = error {
            return (underlying as? URLError)?.code == .cancelled
        }
        return false
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var searchMatchedCards: [KanbanCard] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allCards }
        return allCards.filter { card in
            [card.cardID, card.title, card.body, card.assignee, card.tenant]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    @discardableResult
    private func refreshBoard(usingCursor: Bool, refreshSupplementary: Bool = false) async -> Bool {
        guard let board = selectedBoardSlug else { return false }
        let boardLoadID = UUID()
        activeBoardLoadID = boardLoadID
        isRefreshing = true
        refreshFailed = false
        defer {
            if activeBoardLoadID == boardLoadID { isRefreshing = false }
        }

        let request = KanbanBoardRequest(
            board: board,
            tenant: selectedTenant,
            assignee: selectedProfile,
            includeArchived: includeArchived,
            onlyMine: onlyMine,
            since: usingCursor ? snapshot?.latestEventID : nil
        )
        do {
            let response = try await client.kanbanBoard(request)
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return false }
            if usingCursor, response.changed == false {
                // A cursor refresh may return the minimal unchanged envelope.
            } else {
                let report = try validateBrowsingSnapshot(response, board: board)
                snapshot = applyingPendingOptimism(to: response)
                detailRefreshRevision &+= 1
                self.report = report
                state = report.isPartial ? .partial : .compatible
            }
            liveCursor = max(liveCursor, response.latestEventID ?? 0)
            isOffline = false
            if refreshSupplementary {
                await loadSupplementaryReads(board: board, boardLoadID: boardLoadID)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return false }
            refreshFailed = true
            markOfflineIfNeeded(error)
            forwardAuthentication(error)
            return false
        }
    }

    private func startLiveUpdatesIfReady() {
        guard isVisible, sceneIsActive, snapshot != nil, selectedBoardSlug != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        startStream()
    }

    private func startStream() {
        guard isVisible, sceneIsActive, let board = selectedBoardSlug else { return }
        streamAttemptID += 1
        let attemptID = streamAttemptID
        let generation = liveGeneration
        let url = Endpoint.kanbanEventsStream(
            KanbanEventsStreamRequest(board: board, since: liveCursor)
        ).url(relativeTo: server)
        streamClient.start(
            url: url,
            onFrame: { [weak self] frame in
                self?.handleStreamFrame(
                    frame,
                    board: board,
                    generation: generation,
                    attemptID: attemptID
                )
            },
            onFailure: { [weak self] in
                self?.handleStreamFailure(
                    board: board,
                    generation: generation,
                    attemptID: attemptID
                )
            }
        )
    }

    private func handleStreamFrame(
        _ frame: KanbanStreamFrame,
        board: String,
        generation: Int,
        attemptID: Int
    ) {
        guard isCurrentLiveWork(board: board, generation: generation), streamAttemptID == attemptID else { return }
        switch frame {
        case let .hello(cursor, frameBoard):
            guard frameBoard == board else {
                handleStreamFailure(board: board, generation: generation, attemptID: attemptID)
                return
            }
            liveCursor = max(liveCursor, cursor)
            streamFailureCount = 0
            liveUpdatesDelayed = false
        case let .events(events, cursor, frameID):
            guard (frameID == nil || frameID == cursor),
                  events.allSatisfy({ event in
                      guard let eventID = event.eventID else { return false }
                      return eventID <= cursor
                  }) else {
                handleStreamFailure(board: board, generation: generation, attemptID: attemptID)
                return
            }
            guard cursor > liveCursor else { return }
            liveCursor = cursor
            scheduleCoalescedReconciliation(board: board, generation: generation)
        case .malformed:
            handleStreamFailure(board: board, generation: generation, attemptID: attemptID)
        case .ignored:
            break
        }
    }

    private func handleStreamFailure(board: String, generation: Int, attemptID: Int) {
        guard isCurrentLiveWork(board: board, generation: generation), streamAttemptID == attemptID else { return }
        streamAttemptID += 1 // Makes duplicate callbacks from this attempt inert.
        streamClient.stop()
        streamFailureCount += 1
        if streamFailureCount >= timing.failuresBeforePolling {
            liveUpdatesDelayed = true
            startPollingIfNeeded()
            return
        }

        let reconnectDelays = timing.reconnectDelays.isEmpty ? [.seconds(1)] : timing.reconnectDelays
        let delayIndex = min(streamFailureCount - 1, reconnectDelays.count - 1)
        let delay = reconnectDelays[delayIndex]
        let sleep = self.sleep
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.isCurrentLiveWork(board: board, generation: generation) else { return }
            self.startStream()
        }
    }

    private func scheduleCoalescedReconciliation(board: String, generation: Int) {
        let sleep = self.sleep
        let delay = timing.coalescingDelay
        coalescingTask?.cancel()
        coalescingTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.isCurrentLiveWork(board: board, generation: generation) else { return }
            let succeeded = await self.refreshBoard(usingCursor: false, refreshSupplementary: true)
            guard self.isCurrentLiveWork(board: board, generation: generation) else { return }
            if !succeeded, self.isOffline { self.startPollingIfNeeded() }
        }
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil, isVisible, sceneIsActive, let board = selectedBoardSlug else { return }
        streamClient.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        let generation = liveGeneration
        let sleep = self.sleep
        let interval = timing.pollingInterval
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, self.isCurrentLiveWork(board: board, generation: generation) else { return }
                await self.pollEvents(board: board, generation: generation)
            }
        }
    }

    private func pollEvents(board: String, generation: Int) async {
        do {
            let envelope = try await client.kanbanEvents(
                KanbanEventsRequest(board: board, since: liveCursor)
            )
            guard isCurrentLiveWork(board: board, generation: generation),
                  let cursor = envelope.cursor,
                  cursor >= liveCursor,
                  let events = envelope.events,
                  events.allSatisfy({ event in
                      guard let eventID = event.eventID else { return false }
                      return eventID <= cursor
                  }) else { return }
            let wasOffline = isOffline
            if wasOffline {
                liveCursor = max(liveCursor, cursor)
                let succeeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
                if succeeded {
                    loadedDetailIsStale = false
                    retryLiveStream()
                }
            } else if cursor > liveCursor {
                liveCursor = cursor
                scheduleCoalescedReconciliation(board: board, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLiveWork(board: board, generation: generation) else { return }
            markOfflineIfNeeded(error)
            forwardAuthentication(error)
        }
    }

    private func retryLiveStream() {
        guard isVisible, sceneIsActive else { return }
        pollingTask?.cancel()
        pollingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        streamFailureCount = 0
        startStream()
    }

    private func suspendLiveUpdates() {
        liveGeneration += 1
        activeBoardLoadID = UUID()
        streamClient.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        coalescingTask?.cancel()
        coalescingTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func resetLiveUpdates(clearCursor: Bool) {
        suspendLiveUpdates()
        streamFailureCount = 0
        liveUpdatesDelayed = false
        isOffline = false
        loadedDetailIsStale = false
        if clearCursor { liveCursor = 0 }
    }

    private func isCurrentLiveWork(board: String, generation: Int) -> Bool {
        isSameLiveGeneration(board: board, generation: generation)
            && isVisible
            && sceneIsActive
    }

    private func isSameLiveGeneration(board: String, generation: Int) -> Bool {
        generation == liveGeneration
            && selectedBoardSlug == board
            && !Task.isCancelled
    }

    private func markOfflineIfNeeded(_ error: Error) {
        guard snapshot != nil else { return }
        if let apiError = error as? APIError, case .network = apiError {
            isOffline = true
            loadedDetailIsStale = true
        }
    }

    private func loadSupplementaryReads(board: String, loadID: UUID) async {
        do {
            let stats = try await client.kanbanStats(board: board)
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            self.stats = stats
        } catch {
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            capabilityWarnings.insert(.statsUnavailable)
            forwardAuthentication(error)
        }

        do {
            let history = try await client.kanbanAssignees(board: board)
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            assigneeHistory = history
        } catch {
            guard isCurrent(loadID), selectedBoardSlug == board else { return }
            capabilityWarnings.insert(.profileHistoryUnavailable)
            forwardAuthentication(error)
        }
        updatePartialState()
    }

    private func loadSupplementaryReads(board: String, boardLoadID: UUID) async {
        do {
            let stats = try await client.kanbanStats(board: board)
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            self.stats = stats
            capabilityWarnings.remove(.statsUnavailable)
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            capabilityWarnings.insert(.statsUnavailable)
            forwardAuthentication(error)
        }

        do {
            let history = try await client.kanbanAssignees(board: board)
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            assigneeHistory = history
            capabilityWarnings.remove(.profileHistoryUnavailable)
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            capabilityWarnings.insert(.profileHistoryUnavailable)
            forwardAuthentication(error)
        }
        updatePartialState()
    }

    private func validateBrowsingSnapshot(
        _ snapshot: KanbanBoardSnapshot,
        board: String
    ) throws -> KanbanCompatibilityReport {
        guard let configuration, let boardsResponse else {
            throw KanbanContractViolation.missingConfigurationColumns
        }
        return try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boardsResponse,
            boardSlug: board,
            snapshot: snapshot
        )
    }

    private func updatePartialState() {
        guard snapshot != nil else { return }
        state = report?.isPartial == true || !capabilityWarnings.isEmpty ? .partial : .compatible
    }

    private func isCurrent(_ loadID: UUID) -> Bool {
        activeLoadID == loadID && !Task.isCancelled
    }

    private func isCurrentBoardLoad(_ loadID: UUID, board: String) -> Bool {
        activeBoardLoadID == loadID && selectedBoardSlug == board && !Task.isCancelled
    }

    private func forwardAuthentication(_ error: Error) {
        if case APIError.unauthorized = error { onAPIError(error) }
    }

    private static func classify(_ error: Error) -> KanbanCompatibilityState {
        if error is KanbanContractViolation || error is KanbanResponseError {
            return .incompatibleContract
        }
        guard let apiError = error as? APIError else { return .networkUnavailable }
        switch apiError {
        case .unauthorized:
            return .authenticationRequired
        case .network:
            return .networkUnavailable
        case let .http(statusCode, _):
            return [502, 503, 504].contains(statusCode) ? .serverUnavailable : .incompatibleContract
        case .decoding, .invalidServerURL:
            return .incompatibleContract
        }
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { normalized($0) }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private enum KanbanMutationSettlementError: Error {
    case unexpectedStatus
}
