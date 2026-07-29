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

enum KanbanWriteCapability: String, CaseIterable, Hashable, Sendable {
    case createCard
    case editCard
    case comments
    case cardWorkflow
    case bulkActions
    case boardManagement

    var title: String {
        switch self {
        case .createCard: String(localized: "New Card")
        case .editCard: String(localized: "Edit Card")
        case .comments: String(localized: "Comment")
        case .cardWorkflow: String(localized: "Card Actions")
        case .bulkActions: String(localized: "Bulk Actions")
        case .boardManagement: String(localized: "Board")
        }
    }
}

enum KanbanEndpointCompatibility {
    static func isMissingCapability(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case let .http(statusCode, _) = apiError else { return false }
        if statusCode == 405 { return true }
        guard statusCode == 404,
              let message = apiError.serverMessage?.lowercased() else { return false }
        return message.contains("unknown kanban endpoint")
            || message.contains("kanban endpoint not found")
            || message.contains("unsupported kanban endpoint")
    }
}

enum KanbanDispatchMode: Equatable, Sendable {
    case preview
    case run
}

enum KanbanDispatchPhase: Equatable, Sendable {
    case submitting
    case reconciling
    case succeeded
    case refused
    case failed
    case outcomeUncertain
    case boardUnavailable

    var isInFlight: Bool { self == .submitting || self == .reconciling }

    var statusTitle: String.LocalizationValue {
        switch self {
        case .submitting: "Running Dispatcher..."
        case .reconciling: "Checking Result"
        case .succeeded: "Done"
        case .refused, .failed: "Failed"
        case .outcomeUncertain: "Outcome Uncertain"
        case .boardUnavailable: "Unavailable"
        }
    }
}

struct KanbanDispatchState: Equatable, Sendable {
    let mode: KanbanDispatchMode
    let boardSlug: String
    let phase: KanbanDispatchPhase
    let result: KanbanDispatchResult?
    let completedAt: Date?
    let boardActivityGeneration: Int
    let canAcknowledgeUncertainOutcome: Bool

    init(
        mode: KanbanDispatchMode,
        boardSlug: String,
        phase: KanbanDispatchPhase,
        result: KanbanDispatchResult?,
        completedAt: Date?,
        boardActivityGeneration: Int,
        canAcknowledgeUncertainOutcome: Bool = false
    ) {
        self.mode = mode
        self.boardSlug = boardSlug
        self.phase = phase
        self.result = result
        self.completedAt = completedAt
        self.boardActivityGeneration = boardActivityGeneration
        self.canAcknowledgeUncertainOutcome = canAcknowledgeUncertainOutcome
    }
}

enum KanbanDispatchAccessibility {
    static func summary(_ state: KanbanDispatchState, isStale: Bool) -> String {
        var parts = [
            state.mode == .preview
                ? String(localized: "Preview Dispatch")
                : String(localized: "Run Dispatcher"),
            String(localized: state.phase.statusTitle)
        ]
        if isStale {
            parts.append(
                String(localized: "This Preview is stale. Run Preview Dispatch again before relying on it.")
            )
        }
        if let result = state.result {
            parts.append(contentsOf: [
                metric("Spawned", result.spawned),
                metric("Promoted", result.promoted),
                metric("Reclaimed", result.reclaimed),
                metric("Skipped—No Assignee", result.skippedUnassigned),
                metric("Skipped—Unknown Profile", result.skippedNonspawnable),
                metric("Auto-blocked", result.autoBlocked),
                metric("Timed Out", result.timedOut),
                metric("Crashed", result.crashed)
            ])
        }
        switch state.phase {
        case .refused:
            parts.append(
                String(localized: "The server refused this Dispatcher request. Hermex did not retry it.")
            )
        case .outcomeUncertain:
            parts.append(
                String(localized: "Hermex refreshed the Board, but cannot prove whether workers started. Review the current Board before running Dispatcher again.")
            )
        case .boardUnavailable:
            parts.append(String(localized: "This Board no longer exists. Choose another Board."))
        case .submitting, .reconciling, .succeeded, .failed:
            break
        }
        return parts.joined(separator: ", ")
    }

    private static func metric(_ label: String.LocalizationValue, _ count: Int?) -> String {
        "\(String(localized: label)): \(count.map(String.init) ?? String(localized: "Unknown"))"
    }

}

enum KanbanDispatchCopy {
    static var runConfirmation: String {
        String.localizedStringWithFormat(
            String(localized: "This may start up to %lld workers and consume API budget."),
            KanbanDispatchRequest.maximum
        )
    }
}

enum KanbanDispatcherAvailability: Equatable, Sendable {
    case available
    case busy
    case outcomeUncertain
    case offline
    case incompatible
    case readOnly
    case refreshing
    case refreshFailed
}

private enum KanbanBoardCollectionExpectation {
    case boardMutation(generation: Int)
    case dispatch(generation: Int, board: String, mode: KanbanDispatchMode)
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

enum KanbanBulkActionPhase: Equatable, Sendable {
    case submitting
    case reconciling
}

enum KanbanBoardMutationKind: Equatable, Sendable {
    case create(slug: String)
    case edit(slug: String)
    case archive(slug: String)
    case makeActive(slug: String)

    var slug: String {
        switch self {
        case let .create(slug), let .edit(slug), let .archive(slug), let .makeActive(slug):
            slug
        }
    }
}

struct KanbanBoardMutationState: Equatable, Sendable {
    let kind: KanbanBoardMutationKind
    let phase: KanbanCardMutationPhase
}

struct KanbanBoardSelectionNotice: Equatable, Sendable {
    let boardName: String
}

enum KanbanBulkMemberOutcome: Equatable, Sendable {
    case succeeded
    case failed
    case outcomeUncertain
}

struct KanbanBulkMemberResult: Equatable, Sendable, Identifiable {
    let cardID: String
    let cardTitle: String
    let outcome: KanbanBulkMemberOutcome

    var id: String { cardID }
}

struct KanbanBulkActionSummary: Equatable, Sendable {
    let action: KanbanBulkAction
    let members: [KanbanBulkMemberResult]

    var succeededCount: Int { members.count { $0.outcome == .succeeded } }
    var failedCount: Int { members.count { $0.outcome == .failed } }
    var uncertainCount: Int { members.count { $0.outcome == .outcomeUncertain } }
    var failedCardIDs: Set<String> {
        Set(members.lazy.filter { $0.outcome == .failed }.map(\.cardID))
    }
    var needsAttention: [KanbanBulkMemberResult] {
        members.filter { $0.outcome != .succeeded }
    }
}

enum KanbanBulkActionsAvailability: Equatable, Sendable {
    case available
    case noSelection
    case offline
    case incompatible
    case readOnly
    case refreshing
    case boardBusy
    case invalidSelection
    case unknownStatus
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
    private static let bulkReconciliationConcurrency = 4

    let server: URL
    private(set) var state: KanbanCompatibilityState = .idle
    private(set) var report: KanbanCompatibilityReport?
    private(set) var configuration: KanbanConfiguration?
    private(set) var boards: [KanbanBoard] = []
    private(set) var snapshot: KanbanBoardSnapshot?
    private(set) var stats: KanbanStats?
    private(set) var assigneeHistory: KanbanAssigneeHistory?
    private(set) var capabilityWarnings: Set<KanbanReadCapabilityWarning> = []
    private(set) var unavailableWriteCapabilities: Set<KanbanWriteCapability> = []
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
    private(set) var isSelectingCards = false
    private(set) var selectedCardIDs: Set<String> = []
    private(set) var bulkActionPhase: KanbanBulkActionPhase?
    private(set) var bulkActionSummary: KanbanBulkActionSummary?
    private(set) var boardMutationState: KanbanBoardMutationState?
    private(set) var boardSelectionNotice: KanbanBoardSelectionNotice?
    private(set) var dispatchState: KanbanDispatchState?
    private(set) var dispatcherCapabilityIsIncompatible = false

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
    private let now: @MainActor @Sendable () -> Date
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
    private var selectedCardsByID: [String: KanbanCard] = [:]
    private var boardMutationIntendedResult: ((KanbanBoardsResponse) -> Bool)?
    private var boardMutationGeneration = 0
    private var dispatchGeneration = 0
    private var boardActivityGeneration = 0

    init(
        server: URL,
        client: (any KanbanDataClient)? = nil,
        streamClient: (any KanbanEventStreamingClient)? = nil,
        timing: KanbanLiveUpdateTiming = .production,
        archiveUndoLifetime: TimeInterval = 8,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        onAPIError: @escaping (Error) -> Void = { _ in }
    ) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.streamClient = streamClient ?? KanbanEventStreamClient()
        self.timing = timing
        self.archiveUndoLifetime = archiveUndoLifetime
        self.sleep = sleep
        self.now = now
        self.onAPIError = onAPIError
    }

    /// Future write slices must use this single seam before exposing any
    /// mutation, Dispatcher, or shared-state action.
    var canUseServerAuthoritativeActions: Bool {
        snapshot != nil && !isOffline && !isRefreshing && !refreshFailed
    }

    private var canUseWrites: Bool {
        canUseServerAuthoritativeActions
            && configuration?.readOnly == false
            && boardsResponse?.readOnly == false
            && snapshot?.readOnly == false
            && selectedBoard?.readOnly != true
            && !boardMutationBlocksWrites
    }

    var canAddComments: Bool {
        canUseWrites && !unavailableWriteCapabilities.contains(.comments)
    }

    var canMutateCards: Bool {
        canUseWrites
            && bulkActionPhase == nil
            && Set(KanbanCardEditorState.createStatuses).isSubset(of: Set(configuration?.columns ?? []))
    }

    var canCreateCards: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.createCard)
    }

    var canEditCards: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.editCard)
    }

    var canUseCardWorkflow: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.cardWorkflow)
    }

    var canUseBulkActions: Bool {
        canMutateCards && !unavailableWriteCapabilities.contains(.bulkActions)
    }

    var canManageBoards: Bool {
        canUseWrites
            && bulkActionPhase == nil
            && activeCardMutationIDs.isEmpty
            && dispatchState?.phase.isInFlight != true
            && !unavailableWriteCapabilities.contains(.boardManagement)
    }

    var dispatcherAvailability: KanbanDispatcherAvailability {
        if dispatchState?.phase.isInFlight == true
            || boardMutationBlocksWrites
            || bulkActionPhase != nil
            || !activeCardMutationIDs.isEmpty {
            return .busy
        }
        if isOffline { return .offline }
        if isRefreshing { return .refreshing }
        if refreshFailed { return .refreshFailed }
        if dispatchState?.mode == .run, dispatchState?.phase == .outcomeUncertain {
            return .outcomeUncertain
        }
        guard !dispatcherCapabilityIsIncompatible,
              state == .compatible || state == .partial,
              snapshot != nil,
              selectedBoardSlug != nil else {
            return .incompatible
        }
        if configuration?.readOnly == true
            || boardsResponse?.readOnly == true
            || snapshot?.readOnly == true
            || selectedBoard?.readOnly == true {
            return .readOnly
        }
        guard configuration?.readOnly == false,
              boardsResponse?.readOnly == false,
              snapshot?.readOnly == false else {
            return .incompatible
        }
        return .available
    }

    var isPreviewStale: Bool {
        guard let dispatchState, dispatchState.mode == .preview,
              dispatchState.phase == .succeeded else { return false }
        return dispatchState.boardSlug != selectedBoardSlug
            || dispatchState.boardActivityGeneration != boardActivityGeneration
    }

    var sharedActiveBoardSlug: String? {
        normalizedOptional(boardsResponse?.current)
    }

    var requiresBoardSelection: Bool {
        selectedBoardSlug == nil && !boards.isEmpty
    }

    func canArchiveBoard(_ board: KanbanBoard) -> Bool {
        canManageBoards && normalizedOptional(board.slug) != "default"
    }

    var selectedCardCount: Int { selectedCardIDs.count }

    var bulkActionsAvailability: KanbanBulkActionsAvailability {
        bulkActionsAvailability(for: selectedCardIDs)
    }

    private func bulkActionsAvailability(for cardIDs: Set<String>) -> KanbanBulkActionsAvailability {
        if cardIDs.isEmpty { return .noSelection }
        if bulkActionPhase != nil
            || !activeCardMutationIDs.isEmpty
            || dispatchState?.phase.isInFlight == true
            || boardMutationBlocksWrites {
            return .boardBusy
        }
        if isOffline { return .offline }
        if isRefreshing { return .refreshing }
        guard state == .compatible || state == .partial,
              snapshot != nil,
              Set(KanbanCardEditorState.createStatuses).isSubset(of: Set(configuration?.columns ?? [])),
              !unavailableWriteCapabilities.contains(.bulkActions)
        else { return .incompatible }
        guard configuration?.readOnly == false,
              boardsResponse?.readOnly == false,
              snapshot?.readOnly == false,
              selectedBoard?.readOnly != true
        else { return .readOnly }
        let selectedCards = cardIDs.compactMap { selectedCardsByID[$0] ?? cardInSnapshot($0) }
        guard selectedCards.count == cardIDs.count else { return .invalidSelection }
        guard selectedCards.allSatisfy({ $0.status?.isSupported == true }) else { return .unknownStatus }
        return .available
    }

    var canRetryFailedBulkAction: Bool {
        guard let summary = bulkActionSummary, !summary.failedCardIDs.isEmpty else { return false }
        return bulkActionsAvailability(for: summary.failedCardIDs) == .available
            && validate(summary.action)
    }

    func canSubmitBulkAction(_ action: KanbanBulkAction) -> Bool {
        bulkActionsAvailability == .available && validate(action)
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
        guard canUseCardWorkflow,
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
        let previouslySelectedBoard = normalizedOptional(selectedBoardSlug)
        let previouslySelectedBoardName = selectedBoard?.name
        invalidateBoardMutation()
        invalidateDispatch()
        dispatcherCapabilityIsIncompatible = false
        unavailableWriteCapabilities = []
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
            let availableBoards = boardsResponse.boards ?? []
            if let previouslySelectedBoard,
               !availableBoards.contains(where: { normalized($0.slug) == previouslySelectedBoard }) {
                let validationSnapshot = try await client.kanbanBoard(
                    KanbanBoardRequest(board: currentBoard)
                )
                guard isCurrent(loadID) else { return }
                let report = try KanbanCompatibilityValidator.validate(
                    configuration: configuration,
                    boardsResponse: boardsResponse,
                    boardSlug: currentBoard,
                    snapshot: validationSnapshot
                )
                guard isCurrent(loadID) else { return }
                self.configuration = configuration
                self.boardsResponse = boardsResponse
                boards = availableBoards
                handleRemovedBoard(previouslySelectedBoardName ?? previouslySelectedBoard)
                self.report = report
                state = report.isPartial ? .partial : .compatible
                return
            }
            let boardToLoad = previouslySelectedBoard ?? currentBoard
            let snapshot = try await client.kanbanBoard(KanbanBoardRequest(board: boardToLoad))
            guard isCurrent(loadID) else { return }

            let report = try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: boardsResponse,
                snapshot: snapshot
            )
            guard isCurrent(loadID) else { return }
            if selectedBoardSlug != nil, selectedBoardSlug != boardToLoad {
                resetCardSelection()
            }
            self.configuration = configuration
            self.boardsResponse = boardsResponse
            boards = availableBoards
            selectedBoardSlug = boardToLoad
            boardSelectionNotice = nil
            self.snapshot = snapshot
            markBoardActivity()
            detailRefreshRevision &+= 1
            liveCursor = max(0, snapshot.latestEventID ?? 0)
            self.report = report
            state = report.isPartial ? .partial : .compatible

            await loadSupplementaryReads(board: boardToLoad, loadID: loadID)
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
        let previousRefreshFailed = refreshFailed
        refreshFailed = false
        let boardCollectionSucceeded = await reconcileBoardCollection()
        guard !Task.isCancelled else {
            refreshFailed = previousRefreshFailed
            return
        }
        if !boardCollectionSucceeded {
            reportBoardCollectionRefreshFailure()
        }
        guard let board = selectedBoardSlug else { return }
        let generation = liveGeneration
        let succeeded = await refreshBoard(
            usingCursor: false,
            refreshSupplementary: true,
            preserveRefreshFailure: !boardCollectionSucceeded
        )
        guard !Task.isCancelled else {
            if boardCollectionSucceeded {
                refreshFailed = previousRefreshFailed
            } else {
                reportBoardCollectionRefreshFailure()
            }
            return
        }
        guard isSameLiveGeneration(board: board, generation: generation) else { return }
        if succeeded {
            isOffline = false
            loadedDetailIsStale = false
            retryLiveStream()
        } else if isOffline {
            startPollingIfNeeded()
        }
        if !boardCollectionSucceeded {
            reportBoardCollectionRefreshFailure()
        }
    }

    func selectBoard(_ slug: String) async {
        guard activeCardMutationIDs.isEmpty,
              bulkActionPhase == nil,
              !boardMutationBlocksWrites,
              dispatchState?.phase.isInFlight != true,
              boards.contains(where: { normalized($0.slug) == slug }),
              slug != selectedBoardSlug else { return }
        dispatchState = nil
        clearCardSelection()
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        resetLiveUpdates(clearCursor: true)
        selectedBoardSlug = slug
        boardSelectionNotice = nil
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        report = nil
        capabilityWarnings = []
        state = .compatible
        let succeeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        if succeeded { startLiveUpdatesIfReady() }
    }

    func previewDispatch() async {
        await performDispatch(mode: .preview)
    }

    func runDispatcher() async {
        await performDispatch(mode: .run)
    }

    func dismissDispatchResult() {
        guard let dispatch = dispatchState,
              !dispatch.phase.isInFlight,
              dispatch.phase != .outcomeUncertain
                || dispatch.canAcknowledgeUncertainOutcome else { return }
        dispatchState = nil
    }

    func refreshUncertainDispatchOutcome() async {
        guard let dispatch = dispatchState,
              dispatch.mode == .run,
              dispatch.phase == .outcomeUncertain,
              selectedBoardSlug == dispatch.boardSlug,
              !isOffline,
              !isRefreshing,
              bulkActionPhase == nil,
              activeCardMutationIDs.isEmpty,
              !boardMutationBlocksWrites else { return }
        dispatchGeneration &+= 1
        let generation = dispatchGeneration
        dispatchState = KanbanDispatchState(
            mode: .run,
            boardSlug: dispatch.boardSlug,
            phase: .reconciling,
            result: dispatch.result,
            completedAt: dispatch.completedAt,
            boardActivityGeneration: boardActivityGeneration
        )
        await reconcileRun(
            board: dispatch.boardSlug,
            generation: generation,
            result: dispatch.result,
            completedAt: dispatch.completedAt ?? now(),
            requestOutcomeIsUncertain: dispatch.result == nil,
            allowsAcknowledgementAfterSuccessfulRefresh: true
        )
    }

    func dismissBoardMutationResult() {
        guard boardMutationState?.phase.isInFlight != true,
              boardMutationState?.phase != .outcomeUncertain else { return }
        boardMutationState = nil
        boardMutationIntendedResult = nil
    }

    func checkBoardMutationResult() async {
        guard let mutation = boardMutationState,
              mutation.phase == .outcomeUncertain,
              let intendedResult = boardMutationIntendedResult else { return }
        boardMutationGeneration &+= 1
        let mutationGeneration = boardMutationGeneration
        boardMutationState = KanbanBoardMutationState(kind: mutation.kind, phase: .checkingResult)
        let response = await fetchBoardCollection(
            expectation: .boardMutation(generation: mutationGeneration)
        )
        guard continueBoardMutation(mutationGeneration, kind: mutation.kind) else {
            clearBoardMutationIfCurrent(mutationGeneration)
            return
        }
        if let response {
            boardMutationState = KanbanBoardMutationState(
                kind: mutation.kind,
                phase: intendedResult(response) ? .succeeded : .failed
            )
        } else {
            boardMutationState = KanbanBoardMutationState(
                kind: mutation.kind,
                phase: .outcomeUncertain
            )
        }
    }

    func createBoard(_ request: KanbanCreateBoardRequest) async {
        guard let slug = normalizedOptional(request.slug),
              let name = normalizedOptional(request.name),
              canManageBoards else { return }
        let normalizedRequest = KanbanCreateBoardRequest(
            slug: slug,
            name: name,
            description: request.description.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: request.icon.trimmingCharacters(in: .whitespacesAndNewlines),
            color: request.color.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await performBoardMutation(kind: .create(slug: slug)) {
            try await self.client.createKanbanBoard(normalizedRequest)
        } intendedResult: { response in
            response.boards?.contains(where: { self.normalized($0.slug) == slug }) == true
        }
    }

    func editBoard(_ request: KanbanEditBoardRequest) async {
        guard let slug = normalizedOptional(request.slug),
              let name = normalizedOptional(request.name),
              boards.contains(where: { normalized($0.slug) == slug }),
              canManageBoards else { return }
        let normalizedRequest = KanbanEditBoardRequest(
            slug: slug,
            name: name,
            description: request.description.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: request.icon.trimmingCharacters(in: .whitespacesAndNewlines),
            color: request.color.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        await performBoardMutation(kind: .edit(slug: slug)) {
            try await self.client.editKanbanBoard(normalizedRequest)
        } intendedResult: { response in
            guard let board = response.boards?.first(where: { self.normalized($0.slug) == slug }) else {
                return false
            }
            return self.normalizedOptional(board.name) == normalizedRequest.name
                && self.normalizedOptional(board.description) == self.normalizedOptional(normalizedRequest.description)
                && self.normalizedOptional(board.icon) == self.normalizedOptional(normalizedRequest.icon)
                && self.normalizedOptional(board.color) == self.normalizedOptional(normalizedRequest.color)
        }
    }

    func archiveBoard(slug: String) async {
        guard let slug = normalizedOptional(slug),
              slug != "default",
              boards.contains(where: { normalized($0.slug) == slug }),
              canManageBoards else { return }
        await performBoardMutation(kind: .archive(slug: slug)) {
            try await self.client.archiveKanbanBoard(KanbanBoardMutationRequest(slug: slug))
        } intendedResult: { response in
            response.boards?.contains(where: { self.normalized($0.slug) == slug }) != true
        }
    }

    func makeBoardActive(slug: String) async {
        guard let slug = normalizedOptional(slug),
              boards.contains(where: { normalized($0.slug) == slug }),
              canManageBoards else { return }
        await performBoardMutation(kind: .makeActive(slug: slug)) {
            try await self.client.makeKanbanBoardActive(KanbanBoardMutationRequest(slug: slug))
        } intendedResult: { response in
            self.normalized(response.current) == slug
        }
    }

    private func performDispatch(mode: KanbanDispatchMode) async {
        guard dispatcherAvailability == .available,
              let board = selectedBoardSlug else { return }
        if mode == .run {
            markBoardActivity()
        }
        dispatchGeneration &+= 1
        let generation = dispatchGeneration
        let startingBoardActivityGeneration = boardActivityGeneration
        dispatchState = KanbanDispatchState(
            mode: mode,
            boardSlug: board,
            phase: .submitting,
            result: nil,
            completedAt: nil,
            boardActivityGeneration: startingBoardActivityGeneration
        )

        do {
            let result = try await client.dispatchKanban(
                KanbanDispatchRequest(board: board, dryRun: mode == .preview)
            )
            guard continueDispatch(generation, board: board, mode: mode) else { return }
            let completedAt = now()
            if mode == .preview {
                dispatchState = KanbanDispatchState(
                    mode: .preview,
                    boardSlug: board,
                    phase: .succeeded,
                    result: result,
                    completedAt: completedAt,
                    boardActivityGeneration: startingBoardActivityGeneration
                )
                return
            }
            dispatchState = KanbanDispatchState(
                mode: .run,
                boardSlug: board,
                phase: .reconciling,
                result: result,
                completedAt: completedAt,
                boardActivityGeneration: boardActivityGeneration
            )
            await reconcileRun(
                board: board,
                generation: generation,
                result: result,
                completedAt: completedAt,
                requestOutcomeIsUncertain: false
            )
        } catch {
            guard continueDispatch(generation, board: board, mode: mode) else { return }
            if isCancellation(error) {
                clearDispatchIfCurrent(generation)
                return
            }
            forwardAuthentication(error)
            markOfflineIfNeeded(error)
            if isDispatcherIncompatible(error) {
                dispatcherCapabilityIsIncompatible = true
                updatePartialState()
            }
            let completedAt = now()
            if isDefinitiveWriteFailure(error) {
                dispatchState = KanbanDispatchState(
                    mode: mode,
                    boardSlug: board,
                    phase: .refused,
                    result: nil,
                    completedAt: completedAt,
                    boardActivityGeneration: boardActivityGeneration
                )
            } else if mode == .preview {
                dispatchState = KanbanDispatchState(
                    mode: .preview,
                    boardSlug: board,
                    phase: .failed,
                    result: nil,
                    completedAt: completedAt,
                    boardActivityGeneration: startingBoardActivityGeneration
                )
            } else {
                dispatchState = KanbanDispatchState(
                    mode: .run,
                    boardSlug: board,
                    phase: .reconciling,
                    result: nil,
                    completedAt: completedAt,
                    boardActivityGeneration: boardActivityGeneration
                )
                await reconcileRun(
                    board: board,
                    generation: generation,
                    result: nil,
                    completedAt: completedAt,
                    requestOutcomeIsUncertain: true
                )
            }
        }
    }

    private func reconcileRun(
        board: String,
        generation: Int,
        result: KanbanDispatchResult?,
        completedAt: Date,
        requestOutcomeIsUncertain: Bool,
        allowsAcknowledgementAfterSuccessfulRefresh: Bool = false
    ) async {
        guard continueDispatch(generation, board: board, mode: .run) else { return }
        let collectionSucceeded = await reconcileBoardCollection(
            expectation: .dispatch(generation: generation, board: board, mode: .run)
        )
        guard continueDispatch(generation, board: board, mode: .run) else { return }
        guard selectedBoardSlug == board else {
            dispatchState = KanbanDispatchState(
                mode: .run,
                boardSlug: board,
                phase: .boardUnavailable,
                result: result,
                completedAt: completedAt,
                boardActivityGeneration: boardActivityGeneration
            )
            return
        }
        let boardSucceeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        guard continueDispatch(generation, board: board, mode: .run) else { return }
        dispatchState = KanbanDispatchState(
            mode: .run,
            boardSlug: board,
            phase: requestOutcomeIsUncertain || !collectionSucceeded || !boardSucceeded
                ? .outcomeUncertain
                : .succeeded,
            result: result,
            completedAt: completedAt,
            boardActivityGeneration: boardActivityGeneration,
            canAcknowledgeUncertainOutcome: requestOutcomeIsUncertain
                && collectionSucceeded
                && boardSucceeded
                && allowsAcknowledgementAfterSuccessfulRefresh
        )
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
        guard isVisible, snapshot != nil else { return }
        let previousRefreshFailed = refreshFailed
        let boardCollectionSucceeded = await reconcileBoardCollection()
        guard !Task.isCancelled else {
            refreshFailed = previousRefreshFailed
            return
        }
        if !boardCollectionSucceeded {
            reportBoardCollectionRefreshFailure()
        }
        guard let board = selectedBoardSlug else { return }
        let generation = liveGeneration
        let succeeded = await refreshBoard(
            usingCursor: false,
            refreshSupplementary: true,
            preserveRefreshFailure: !boardCollectionSucceeded
        )
        guard !Task.isCancelled else {
            if boardCollectionSucceeded {
                refreshFailed = previousRefreshFailed
            } else {
                reportBoardCollectionRefreshFailure()
            }
            return
        }
        guard isCurrentLiveWork(board: board, generation: generation) else { return }
        if succeeded {
            isOffline = false
            loadedDetailIsStale = false
            retryLiveStream()
        } else {
            startPollingIfNeeded()
        }
        if !boardCollectionSucceeded {
            reportBoardCollectionRefreshFailure()
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

    func beginSelectingCards() {
        guard bulkActionPhase == nil else { return }
        isSelectingCards = true
        bulkActionSummary = nil
    }

    func toggleCardSelection(_ card: KanbanCard) {
        guard isSelectingCards,
              bulkActionPhase == nil,
              let cardID = normalizedOptional(card.cardID) else { return }
        if selectedCardIDs.remove(cardID) != nil {
            selectedCardsByID[cardID] = nil
        } else {
            selectedCardIDs.insert(cardID)
            selectedCardsByID[cardID] = card
        }
    }

    func clearCardSelection() {
        guard bulkActionPhase == nil else { return }
        resetCardSelection()
    }

    private func resetCardSelection() {
        isSelectingCards = false
        selectedCardIDs = []
        selectedCardsByID = [:]
        bulkActionSummary = nil
    }

    func dismissBulkActionSummary() {
        bulkActionSummary = nil
    }

    func performBulkAction(_ action: KanbanBulkAction) async {
        await performBulkAction(action, cardIDs: selectedCardIDs)
    }

    func retryFailedBulkAction() async {
        guard canRetryFailedBulkAction,
              let summary = bulkActionSummary else { return }
        let failedIDs = summary.failedCardIDs
        selectedCardIDs = failedIDs
        selectedCardsByID = selectedCardsByID.filter { failedIDs.contains($0.key) }
        await performBulkAction(summary.action, cardIDs: failedIDs)
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
            },
            onCapabilityUnavailable: { [weak self] capability in
                self?.markCapabilityUnavailable(capability)
            }
        )
    }

    func makeCreateCardEditorState() -> KanbanCardEditorState? {
        guard canCreateCards, let board = selectedBoardSlug else { return nil }
        return KanbanCardEditorState(
            mode: .create,
            board: board,
            client: client,
            profileOptions: profileOptions,
            tenantOptions: tenantOptions,
            prerequisiteOptions: allCards.filter { $0.cardID != nil },
            baselineCards: allCards,
            onCapabilityUnavailable: { [weak self] capability in
                self?.markCapabilityUnavailable(capability)
            }
        )
    }

    func makeEditCardEditorState(detail: KanbanCardDetailEnvelope) -> KanbanCardEditorState? {
        guard canEditCards,
              let board = selectedBoardSlug,
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
            baselineCards: allCards,
            onCapabilityUnavailable: { [weak self] capability in
                self?.markCapabilityUnavailable(capability)
            }
        )
    }

    func reconcileAfterCardMutation() async {
        _ = await refreshBoard(usingCursor: false, refreshSupplementary: true)
    }

    private func performBulkAction(_ action: KanbanBulkAction, cardIDs: Set<String>) async {
        guard bulkActionsAvailability == .available,
              validate(action),
              !cardIDs.isEmpty,
              cardIDs == selectedCardIDs,
              let board = selectedBoardSlug else { return }
        let orderedIDs = cardIDs.sorted()
        let originalCards = Dictionary(
            uniqueKeysWithValues: orderedIDs.compactMap { cardID in
                (selectedCardsByID[cardID] ?? cardInSnapshot(cardID)).map { (cardID, $0) }
            }
        )
        guard originalCards.count == orderedIDs.count else { return }

        markBoardActivity()
        bulkActionSummary = nil
        bulkActionPhase = .submitting
        do {
            _ = try await client.performKanbanBulkAction(KanbanBulkActionRequest(
                board: board,
                cardIDs: orderedIDs,
                action: action
            ))
        } catch {
            forwardAuthentication(error)
            markCapabilityUnavailableIfNeeded(.bulkActions, error: error)
        }

        guard selectedBoardSlug == board else {
            bulkActionPhase = nil
            resetCardSelection()
            return
        }
        bulkActionPhase = .reconciling
        var members: [KanbanBulkMemberResult] = []
        let detailResults = await fetchBulkCardDetails(cardIDs: orderedIDs, board: board)

        for cardID in orderedIDs {
            let original = originalCards[cardID]
            switch detailResults[cardID] {
            case let .success(detail):
                guard selectedBoardSlug == board,
                      let authoritative = detail.card,
                      normalizedOptional(authoritative.cardID) == cardID else {
                    members.append(bulkMember(
                        cardID: cardID,
                        card: original,
                        outcome: .outcomeUncertain
                    ))
                    continue
                }
                replaceCardInSnapshot(authoritative)
                selectedCardsByID[cardID] = authoritative
                let intendedResultIsPresent = actionMatches(action, card: authoritative)
                members.append(bulkMember(
                    cardID: cardID,
                    card: authoritative,
                    outcome: intendedResultIsPresent ? .succeeded : .failed
                ))
            case let .failure(error):
                members.append(bulkMember(
                    cardID: cardID,
                    card: original,
                    outcome: .outcomeUncertain
                ))
                forwardAuthentication(error)
            case nil:
                members.append(bulkMember(
                    cardID: cardID,
                    card: original,
                    outcome: .outcomeUncertain
                ))
            }
        }

        guard selectedBoardSlug == board else {
            bulkActionPhase = nil
            resetCardSelection()
            return
        }
        let summary = KanbanBulkActionSummary(action: action, members: members)
        bulkActionSummary = summary
        let retainedIDs = Set(summary.needsAttention.map(\.cardID))
        selectedCardIDs = retainedIDs
        selectedCardsByID = selectedCardsByID.filter { retainedIDs.contains($0.key) }
        bulkActionPhase = nil
        _ = await refreshBoard(usingCursor: false, refreshSupplementary: true)
    }

    private func fetchBulkCardDetails(
        cardIDs: [String],
        board: String
    ) async -> [String: Result<KanbanCardDetailEnvelope, Error>] {
        await withTaskGroup(
            of: (String, Result<KanbanCardDetailEnvelope, Error>).self,
            returning: [String: Result<KanbanCardDetailEnvelope, Error>].self
        ) { group in
            var remainingIDs = cardIDs.makeIterator()
            for _ in 0..<min(Self.bulkReconciliationConcurrency, cardIDs.count) {
                guard let cardID = remainingIDs.next() else { break }
                addBulkDetailTask(cardID: cardID, board: board, to: &group)
            }

            var results: [String: Result<KanbanCardDetailEnvelope, Error>] = [:]
            while let (cardID, result) = await group.next() {
                results[cardID] = result
                if let nextCardID = remainingIDs.next() {
                    addBulkDetailTask(cardID: nextCardID, board: board, to: &group)
                }
            }
            return results
        }
    }

    private func addBulkDetailTask(
        cardID: String,
        board: String,
        to group: inout TaskGroup<(String, Result<KanbanCardDetailEnvelope, Error>)>
    ) {
        group.addTask { [client] in
            do {
                let detail = try await client.kanbanCardDetail(
                    KanbanCardDetailRequest(cardID: cardID, board: board)
                )
                return (cardID, .success(detail))
            } catch {
                return (cardID, .failure(error))
            }
        }
    }

    private func validate(_ action: KanbanBulkAction) -> Bool {
        switch action {
        case let .changeStatus(status):
            guard let normalizedStatus = normalized(status) else { return false }
            return normalizedStatus != "running"
                && (configuration?.columns ?? []).contains(normalizedStatus)
        case let .assignProfile(profile):
            guard let profile = normalizedOptional(profile) else { return profile == nil }
            return profileOptions.contains(profile)
        case let .setPriority(priority):
            return (-100...100).contains(priority)
        case .archiveCards:
            return true
        }
    }

    private func actionMatches(_ action: KanbanBulkAction, card: KanbanCard) -> Bool {
        switch action {
        case let .changeStatus(status):
            return card.status?.rawValue == normalized(status)
        case let .assignProfile(profile):
            return normalizedOptional(card.assignee) == normalizedOptional(profile)
        case let .setPriority(priority):
            return (card.priority ?? 0) == priority
        case .archiveCards:
            return card.status?.rawValue == "archived"
        }
    }

    private func bulkMember(
        cardID: String,
        card: KanbanCard?,
        outcome: KanbanBulkMemberOutcome
    ) -> KanbanBulkMemberResult {
        KanbanBulkMemberResult(
            cardID: cardID,
            cardTitle: normalizedOptional(card?.title) ?? cardID,
            outcome: outcome
        )
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
            markCapabilityUnavailableIfNeeded(.cardWorkflow, error: error)
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
        markBoardActivity()
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
            markCapabilityUnavailableIfNeeded(.cardWorkflow, error: error)
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
        markBoardActivity()
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
        markBoardActivity()
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

    private func performBoardMutation(
        kind: KanbanBoardMutationKind,
        write: () async throws -> KanbanBoardMutationEnvelope,
        intendedResult: @escaping (KanbanBoardsResponse) -> Bool
    ) async {
        guard canManageBoards else { return }
        markBoardActivity()
        boardMutationGeneration &+= 1
        let mutationGeneration = boardMutationGeneration
        boardMutationIntendedResult = intendedResult
        boardMutationState = KanbanBoardMutationState(kind: kind, phase: .updating)
        var definitiveFailure = false
        do {
            _ = try await write()
        } catch {
            if isCancellation(error) {
                clearBoardMutationIfCurrent(mutationGeneration)
                return
            }
            guard continueBoardMutation(mutationGeneration, kind: kind) else { return }
            forwardAuthentication(error)
            markCapabilityUnavailableIfNeeded(.boardManagement, error: error)
            definitiveFailure = isDefinitiveWriteFailure(error)
        }
        guard continueBoardMutation(mutationGeneration, kind: kind) else {
            clearBoardMutationIfCurrent(mutationGeneration)
            return
        }

        if !definitiveFailure {
            boardMutationState = KanbanBoardMutationState(kind: kind, phase: .checkingResult)
        }
        let response = await fetchBoardCollection(
            expectation: .boardMutation(generation: mutationGeneration)
        )
        guard continueBoardMutation(mutationGeneration, kind: kind) else {
            clearBoardMutationIfCurrent(mutationGeneration)
            return
        }
        if definitiveFailure {
            boardMutationState = KanbanBoardMutationState(kind: kind, phase: .failed)
        } else if let response {
            boardMutationState = KanbanBoardMutationState(
                kind: kind,
                phase: intendedResult(response) ? .succeeded : .failed
            )
        } else {
            boardMutationState = KanbanBoardMutationState(kind: kind, phase: .outcomeUncertain)
        }
    }

    @discardableResult
    private func reconcileBoardCollection(
        expectation: KanbanBoardCollectionExpectation? = nil
    ) async -> Bool {
        await fetchBoardCollection(expectation: expectation) != nil
    }

    private func fetchBoardCollection(
        expectation: KanbanBoardCollectionExpectation? = nil
    ) async -> KanbanBoardsResponse? {
        guard boardCollectionExpectationIsCurrent(expectation) else { return nil }
        do {
            let response = try await client.kanbanBoards()
            guard boardCollectionExpectationIsCurrent(expectation) else { return nil }
            guard let availableBoards = response.boards,
                  normalizedOptional(response.current) != nil else {
                return nil
            }
            let previousBoards = boards
            boardsResponse = response
            boards = availableBoards
            if let selectedBoardSlug,
               !availableBoards.contains(where: { normalized($0.slug) == selectedBoardSlug }) {
                let previousName = previousBoards
                    .first(where: { normalized($0.slug) == selectedBoardSlug })?
                    .name
                handleRemovedBoard(previousName ?? selectedBoardSlug)
            }
            isOffline = false
            return response
        } catch {
            guard boardCollectionExpectationIsCurrent(expectation) else { return nil }
            markOfflineIfNeeded(error)
            forwardAuthentication(error)
            return nil
        }
    }

    private func boardCollectionExpectationIsCurrent(
        _ expectation: KanbanBoardCollectionExpectation?
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        switch expectation {
        case nil:
            return true
        case let .boardMutation(generation):
            return generation == boardMutationGeneration
        case let .dispatch(generation, board, mode):
            return continueDispatch(generation, board: board, mode: mode)
        }
    }

    private var boardMutationBlocksWrites: Bool {
        if dispatchState?.mode == .run, dispatchState?.phase.isInFlight == true {
            return true
        }
        guard let phase = boardMutationState?.phase else { return false }
        return phase.isInFlight || phase == .outcomeUncertain
    }

    private func markBoardActivity() {
        boardActivityGeneration &+= 1
    }

    private func continueDispatch(
        _ generation: Int,
        board: String,
        mode: KanbanDispatchMode
    ) -> Bool {
        generation == dispatchGeneration
            && dispatchState?.boardSlug == board
            && dispatchState?.mode == mode
            && !Task.isCancelled
    }

    private func clearDispatchIfCurrent(_ generation: Int) {
        guard generation == dispatchGeneration else { return }
        dispatchState = nil
    }

    private func invalidateDispatch() {
        dispatchGeneration &+= 1
        dispatchState = nil
    }

    private func isDispatcherIncompatible(_ error: Error) -> Bool {
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404 || statusCode == 405
    }

    private func continueBoardMutation(
        _ generation: Int,
        kind: KanbanBoardMutationKind
    ) -> Bool {
        generation == boardMutationGeneration
            && boardMutationState?.kind == kind
            && !Task.isCancelled
    }

    private func clearBoardMutationIfCurrent(_ generation: Int) {
        guard generation == boardMutationGeneration else { return }
        boardMutationState = nil
        boardMutationIntendedResult = nil
    }

    private func invalidateBoardMutation() {
        boardMutationGeneration &+= 1
        boardMutationState = nil
        boardMutationIntendedResult = nil
    }

    private func reportBoardCollectionRefreshFailure() {
        refreshFailed = !isOffline
    }

    private func handleRemovedBoard(_ boardDisplayName: String) {
        markBoardActivity()
        activeBoardLoadID = nil
        resetLiveUpdates(clearCursor: true)
        resetCardSelection()
        archiveUndoTask?.cancel()
        archiveUndo = nil
        clearSettledMutationPresentation()
        activeCardMutationIDs.removeAll()
        pendingOptimisticStatuses.removeAll()
        pendingDependencyChanges.removeAll()
        uncertainProtectedCards.removeAll()
        bulkActionPhase = nil
        bulkActionSummary = nil
        selectedBoardSlug = nil
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        report = nil
        capabilityWarnings = []
        refreshFailed = false
        boardSelectionNotice = KanbanBoardSelectionNotice(boardName: boardDisplayName)
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
    private func refreshBoard(
        usingCursor: Bool,
        refreshSupplementary: Bool = false,
        preserveRefreshFailure: Bool = false
    ) async -> Bool {
        guard let board = selectedBoardSlug else { return false }
        let boardLoadID = UUID()
        activeBoardLoadID = boardLoadID
        isRefreshing = true
        if !preserveRefreshFailure {
            refreshFailed = false
        }
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
                markBoardActivity()
                detailRefreshRevision &+= 1
                self.report = report
                state = report.isPartial ? .partial : .compatible
            }
            liveCursor = max(liveCursor, response.latestEventID ?? 0)
            isOffline = false
            if preserveRefreshFailure {
                refreshFailed = true
            }
            if refreshSupplementary {
                await loadSupplementaryReads(board: board, boardLoadID: boardLoadID)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return false }
            if isNotFound(error) {
                _ = await reconcileBoardCollection()
                if selectedBoardSlug == nil { return false }
            }
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
        state = report?.isPartial == true
            || !capabilityWarnings.isEmpty
            || !unavailableWriteCapabilities.isEmpty
            || dispatcherCapabilityIsIncompatible
            ? .partial
            : .compatible
    }

    private func markCapabilityUnavailableIfNeeded(
        _ capability: KanbanWriteCapability,
        error: Error
    ) {
        guard KanbanEndpointCompatibility.isMissingCapability(error) else { return }
        markCapabilityUnavailable(capability)
    }

    private func markCapabilityUnavailable(_ capability: KanbanWriteCapability) {
        unavailableWriteCapabilities.insert(capability)
        updatePartialState()
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
