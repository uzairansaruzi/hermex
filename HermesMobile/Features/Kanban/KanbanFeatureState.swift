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
    private let onAPIError: (Error) -> Void

    init(
        server: URL,
        client: (any KanbanDataClient)? = nil,
        onAPIError: @escaping (Error) -> Void = { _ in }
    ) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.onAPIError = onAPIError
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

    func load() async {
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
            self.report = report
            state = report.isPartial ? .partial : .compatible

            await loadSupplementaryReads(board: currentBoard, loadID: loadID)
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
        await refreshBoard(usingCursor: true)
    }

    func selectBoard(_ slug: String) async {
        guard boards.contains(where: { normalized($0.slug) == slug }), slug != selectedBoardSlug else { return }
        selectedBoardSlug = slug
        snapshot = nil
        stats = nil
        assigneeHistory = nil
        report = nil
        capabilityWarnings = []
        state = .compatible
        await refreshBoard(usingCursor: false, refreshSupplementary: true)
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

    private var searchMatchedCards: [KanbanCard] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allCards }
        return allCards.filter { card in
            [card.cardID, card.title, card.body, card.assignee, card.tenant]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    private func refreshBoard(usingCursor: Bool, refreshSupplementary: Bool = false) async {
        guard let board = selectedBoardSlug else { return }
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
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            if usingCursor, response.changed == false {
                // A cursor refresh may return the minimal unchanged envelope.
            } else {
                let report = try validateBrowsingSnapshot(response, board: board)
                snapshot = response
                self.report = report
                state = report.isPartial ? .partial : .compatible
            }
            if refreshSupplementary {
                await loadSupplementaryReads(board: board, boardLoadID: boardLoadID)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentBoardLoad(boardLoadID, board: board) else { return }
            refreshFailed = true
            forwardAuthentication(error)
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
