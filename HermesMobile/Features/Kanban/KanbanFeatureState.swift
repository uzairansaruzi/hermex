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

    init(
        server: URL,
        client: (any KanbanDataClient)? = nil,
        streamClient: (any KanbanEventStreamingClient)? = nil,
        timing: KanbanLiveUpdateTiming = .production,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        onAPIError: @escaping (Error) -> Void = { _ in }
    ) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.streamClient = streamClient ?? KanbanEventStreamClient()
        self.timing = timing
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
        guard boards.contains(where: { normalized($0.slug) == slug }), slug != selectedBoardSlug else { return }
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
            onAPIError: onAPIError
        )
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
                snapshot = response
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
