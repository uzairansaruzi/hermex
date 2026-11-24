import Foundation
import Observation
import SwiftData
import SwiftUI

struct ScheduledSessionGroups: Equatable {
    let needsYou: [SessionSummary]
    let ordinary: [SessionSummary]
    let scheduled: [SessionSummary]
    let totalScheduledCount: Int

    init(partitioning visible: [SessionSummary], totalScheduledCount: Int,
         needsInput: ((SessionSummary) -> Bool)? = nil) {
        var needsYou: [SessionSummary] = []
        var ordinary: [SessionSummary] = []
        var scheduled: [SessionSummary] = []
        for session in visible {
            if session.isCronSession {
                if session.archived != true { scheduled.append(session) }
            } else if session.archived != true, needsInput?(session) == true {
                needsYou.append(session)
            } else {
                ordinary.append(session)
            }
        }
        self.needsYou = needsYou
        self.ordinary = ordinary
        self.scheduled = scheduled.first?.hermes == nil ? scheduled : scheduled.sorted {
            let left = $0.lastMessageAt ?? $0.createdAt ?? 0, right = $1.lastMessageAt ?? $1.createdAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
        self.totalScheduledCount = totalScheduledCount
    }

    var scheduledPreview: [SessionSummary] {
        Array(scheduled.prefix(5))
    }

    var hasAdditionalScheduledSessions: Bool {
        scheduled.count > scheduledPreview.count
    }

    func showsDisclosure(isSearchActive: Bool) -> Bool {
        totalScheduledCount > 0 && (!isSearchActive || !scheduled.isEmpty)
    }
}

enum ActiveSessionStateRefreshResult: Equatable {
    case unchanged
    case reloaded
    case failed
}

struct HermesSessionListSource {
    let connection: BotConnection
    let profile: String?
    var makeWire: @MainActor (BotConnection) -> any BotTransport
    var preferences: UserDefaults = .standard
    var changeDebounce: Duration = .seconds(1)
    var statusPollInterval: Duration = .seconds(5)
    var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    var isNetworkAvailable: @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied }
}

@MainActor
@Observable
final class SessionListViewModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var isCreatingSession = false
    private(set) var isCreatingProject = false
    private(set) var isLoadingProjects = false
    private(set) var isDeletingProject = false
    private(set) var isRenamingSession = false
    private(set) var isRenamingProject = false
    private(set) var isMovingSession = false
    private(set) var isViewingCachedData = false {
        didSet { if !isViewingCachedData { isCachedCopyProvisional = false } }
    }
    private(set) var isCachedCopyProvisional = false
    var showsOfflineCache: Bool { isViewingCachedData && !isCachedCopyProvisional }
    private(set) var projects: [ProjectSummary] = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var cacheErrorMessage: String?
    private(set) var searchErrorMessage: String?
    private(set) var isSearchingRemoteSessions = false
    private(set) var sessionLoadError: Error?
    var hermesRefusalOverRows: String? {
        guard !sessions.isEmpty, let sessionLoadError, !BotConnectionAdvice.isRetryable(sessionLoadError) else { return nil }
        return errorMessage
    }
    var hermesConnection: HomeConnectionStatus.Facts {
        HomeConnectionStatus.Facts(keepsRows: !sessions.isEmpty && !isViewingCachedData && hermesRefusalOverRows == nil,
                                   isReconnecting: isHermesReconnecting)
    }
    private(set) var lastError: Error?
    private(set) var activeProfileName: String?
    private(set) var activeProfileDisplayName: String?
    private(set) var activeProfileModel: String?
    private(set) var activeProfileProvider: String?
    private(set) var profileOptions: [ProfileSummary] = []
    private(set) var isSingleProfileMode = false
    private(set) var isLoadingActiveProfile = false
    private(set) var isSwitchingActiveProfile = false
    private(set) var switchingActiveProfileName: String?
    private(set) var activeProfileErrorMessage: String?
    private(set) var mutatingSessionIDs: Set<String> = []
    private(set) var archivedCount: Int?

    private(set) var attentionStatesBySessionID: [String: SessionRowAttentionState] = [:]
    private(set) var hermesBackgroundWork: Set<String> = []
    private(set) var attentionStatesAreStale = false
    private(set) var isHermesReconnecting = false
    private(set) var seenMessageTimes: [String: Double]

    private(set) var remoteContentSearchSessionIDs: [String] = []
    private(set) var remoteContentSearchExcerpts: [String: String] = [:]
    private var activeRemoteSearchQuery: String?
    private var sessionOpenGeneration = 0
    private(set) var openingSessionID: String?
    private var activeProfileGeneration = 0

    private let client: APIClient
    private let sessionMutator: SessionMutator
    let server: URL
    private let unreadStore: SessionUnreadStore
    private var viewingSessionID: String?
    private var returnedFromSessionIDs: Set<String> = []
    private var firstReturnLoad: (revision: Int, sessionIDs: Set<String>)?
    private var returnRevision = 0
    private var activeLoadCount = 0

    private let hermes: HermesSessionListSource?
    private(set) var hermesProfile: String?
    private(set) var hermesShowsAllProfiles = false
    private(set) var hermesProfiles: [String] = []
    private(set) var hermesProfileModels: [String: String] = [:]
    private var hasReadHermes = false
    var isHermesLive: Bool { hasReadHermes && !isViewingCachedData }
    private(set) var renameErrorMessage: String?
    private(set) var hasMoreSessions = false
    private(set) var isLoadingMoreSessions = false
    private(set) var hasMoreScheduledSessions = false
    private(set) var isLoadingMoreScheduledSessions = false
    private(set) var hermesScheduledTotal = 0
    var isHermes: Bool { hermes != nil }
    private var hermesUnreadMarks: [String: HermesUnreadMark] = [:]
    @ObservationIgnored private var hermesUnreadWrites: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var hermesWire: (any BotTransport)?
    @ObservationIgnored private var hermesConnectingWire: (any BotTransport)?
    @ObservationIgnored private var hermesIsListening = false
    @ObservationIgnored private var hermesPages = HermesProfilePages()
    @ObservationIgnored private var hermesScheduledPages = HermesProfilePages()
    @ObservationIgnored private var hermesReadSerial = 0
    @ObservationIgnored private var hermesProjectsSerial = 0
    @ObservationIgnored private var hermesStatusSerial = 0
    @ObservationIgnored private var hermesRosterSerial = 0
    @ObservationIgnored private var hermesRosterTask: Task<Void, Never>?
    @ObservationIgnored private var hermesReloadTask: Task<Void, Never>?
    @ObservationIgnored private var hermesReloadWanted = false
    @ObservationIgnored private var hermesDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var hermesStatusTask: Task<Void, Never>?
    @ObservationIgnored private var hermesArchivedCountTask: Task<Void, Never>?
    @ObservationIgnored private let hermesReconnect: BotReconnectSchedule?
    @ObservationIgnored private var hermesReadsStatus = true
    @ObservationIgnored private var hermesReadsApprovals = true
    @ObservationIgnored private var hermesReadsRoster = true
    @ObservationIgnored private var hermesRetriesStatus = false
    @ObservationIgnored private var hermesReturnedFrom: Set<String> = []
    @ObservationIgnored private var hermesProjectOwners: [String: String] = [:]
    @ObservationIgnored private var hermesProjectsRead = false
    private(set) var projectSheetErrorMessage: String?
    @ObservationIgnored private var hermesSearchResults: [(profile: String, row: HermesSessionRow)] = []
    @ObservationIgnored private var hermesSearchWrites = 0
    private var hermesSearchRows: [SessionSummary] = []
    private var hermesSearchSnippets: [String: String] = [:]
    @ObservationIgnored private var hermesSearchAwaitsConnect = false
    @ObservationIgnored private var hermesCache: ModelContext?

    init(server: URL, client: APIClient? = nil, unreadStore: SessionUnreadStore = SessionUnreadStore(),
         hermes: HermesSessionListSource? = nil) {
        self.server = server
        self.unreadStore = unreadStore
        self.hermes = hermes
        hermesProfile = hermes?.profile
        hermesReconnect = hermes.map { BotReconnectSchedule(delays: $0.reconnectDelays, isNetworkAvailable: $0.isNetworkAvailable) }
        hermesShowsAllProfiles = hermes.map { HermesProfilePreference.showsAllProfiles(for: server, in: $0.preferences) } ?? false
        isLoading = hermes != nil
        seenMessageTimes = unreadStore.load(for: server)
        let resolvedClient = client ?? APIClient(baseURL: server)
        self.client = resolvedClient
        self.sessionMutator = SessionMutator(client: resolvedClient)

        _ = Self.sweepLeakedExportsOnce
    }

    nonisolated static var exportsRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-exports", isDirectory: true)
    }

    nonisolated private static let sweepLeakedExportsOnce: Void = {
        try? FileManager.default.removeItem(at: exportsRootDirectory)
    }()

    func visibleSessions(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll,
        statusFilter: HermesSessionStatusFilter = .all,
        draftRows: Set<ChatDraftStore.DraftRow> = []
    ) -> [SessionSummary] {
        visibleSessions(
            among: sessions,
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility,
            statusFilter: statusFilter,
            draftRows: draftRows
        )
    }

    func visibleActiveSessions(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [SessionSummary] {
        let activeSessions = sessions.filter(SessionRowView.isActiveStreaming)
        guard !activeSessions.isEmpty else { return [] }
        return visibleSessions(
            among: activeSessions,
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility
        )
    }

    private func visibleSessions(
        among candidates: [SessionSummary],
        searchText rawSearchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility,
        statusFilter: HermesSessionStatusFilter = .all,
        draftRows: Set<ChatDraftStore.DraftRow> = []
    ) -> [SessionSummary] {
        let query = Self.normalizedSearchQuery(rawSearchText)
        let searchTerms = query.split(whereSeparator: \.isWhitespace)
        let baseSessions = candidates.filter { automatedVisibility.shows($0) }
        let projectFilteredSessions = baseSessions.filter { session in
            guard let selectedProjectID else { return true }
            return session.projectId == selectedProjectID
        }.filter { matches($0, statusFilter, draftRows) }
        let localMatches = projectFilteredSessions.filter { session in
            guard !searchTerms.isEmpty else { return true }
            let searchableText = Self.searchableText(for: session)
            return searchTerms.allSatisfy { searchableText.contains($0) }
        }
        let sortedLocalMatches = Self.sortedSessions(localMatches)

        guard !query.isEmpty, activeRemoteSearchQuery == query else {
            return sortedLocalMatches
        }
        if hermes != nil {
            return sortedLocalMatches + hermesSearchMatches(excluding: sortedLocalMatches, selectedProjectID: selectedProjectID)
                .filter { automatedVisibility.shows($0) && matches($0, statusFilter, draftRows) }
        }

        let localMatchIDs = Set(sortedLocalMatches.compactMap(\.sessionId))
        let sessionsByID = Dictionary(
            projectFilteredSessions.compactMap { session -> (String, SessionSummary)? in
                guard let sessionID = session.sessionId, !sessionID.isEmpty else { return nil }
                return (sessionID, session)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMatches = remoteContentSearchSessionIDs.compactMap { sessionID -> SessionSummary? in
            guard !localMatchIDs.contains(sessionID) else { return nil }
            return sessionsByID[sessionID]
        }

        return sortedLocalMatches + Self.sortedSessions(remoteMatches)
    }

    private func matches(_ session: SessionSummary, _ status: HermesSessionStatusFilter,
                         _ draftRows: Set<ChatDraftStore.DraftRow>) -> Bool {
        switch status {
        case .all: return true
        case .working: return attentionState(for: session) != nil
        case .unread: return isUnread(session)
        case .draft:
            guard let root = session.hermes?.lineageRoot, let profile = Self.nonEmpty(session.profile) ?? hermesProfile
            else { return false }
            return draftRows.contains(.init(profile: profile, key: root))
        }
    }

    func scheduledSessionGroups(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll,
        statusFilter: HermesSessionStatusFilter = .all,
        draftRows: Set<ChatDraftStore.DraftRow> = []
    ) -> ScheduledSessionGroups {
        let liftsWaiting = hermes != nil && !isViewingCachedData && Self.normalizedSearchQuery(searchText).isEmpty
        return ScheduledSessionGroups(
            partitioning: visibleSessions(
                searchText: searchText,
                selectedProjectID: selectedProjectID,
                automatedVisibility: automatedVisibility,
                statusFilter: statusFilter,
                draftRows: draftRows
            ),
            totalScheduledCount: automatedVisibility.showsCron
                ? (hermes != nil && !isViewingCachedData ? hermesScheduledTotal : sessions.filter { $0.isCronSession && $0.archived != true }.count)
                : 0,
            needsInput: liftsWaiting ? { [.input, .approval].contains(self.attentionState(for: $0)) } : nil
        )
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil, animation: Animation? = nil) async -> Bool {
        let revision = returnRevision
        let firstReturnedIDs = returnedFromSessionIDs
        let inFlightIDs = firstReturnLoad?.revision == revision ? firstReturnLoad?.sessionIDs ?? [] : []
        let returnedFromIDs = firstReturnedIDs.union(inFlightIDs)
        returnedFromSessionIDs.removeAll()
        if !firstReturnedIDs.isEmpty {
            firstReturnLoad = (revision, firstReturnedIDs)
        }
        activeLoadCount += 1
        isLoading = true
        errorMessage = nil
        cacheErrorMessage = nil
        sessionLoadError = nil
        lastError = nil
        defer {
            if !firstReturnedIDs.isEmpty && firstReturnLoad?.revision == revision {
                firstReturnLoad = nil
            }
            activeLoadCount -= 1
            isLoading = activeLoadCount > 0
        }

        do {
            let response = try await client.sessions()
            guard revision == returnRevision else { return false }
            let allSessions = response.sessions ?? []
            let visibleSessions = allSessions
                .filter {
                    Self.nonEmpty($0.sessionId) != nil
                        && $0.archived != true
                        && $0.shouldAppearInSessionList
                }
            reconcileUnread(visibleSessions, allSessions: allSessions, returnedFromIDs: returnedFromIDs)
            applySessions(visibleSessions, archivedCount: response.archivedCount, animation: animation)
            isViewingCachedData = false

            if let modelContext {
                do {
                    try CacheStore.cacheSessions(visibleSessions, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return true
        } catch {
            guard !error.isCancellation else { return false }
            guard revision == returnRevision else { return false }

            lastError = error
            sessionLoadError = error
            if CacheFallbackPolicy.shouldUseCache(for: error), let modelContext {
                do {
                    let cachedSessions = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                        .filter(\.shouldAppearInSessionList)
                    if !cachedSessions.isEmpty {
                        sessions = cachedSessions
                        isViewingCachedData = true
                        errorMessage = nil
                        clearAttentionStates()
                    } else {
                        isViewingCachedData = false
                        errorMessage = error.localizedDescription
                    }
                } catch {
                    cacheErrorMessage = error.localizedDescription
                    isViewingCachedData = false
                    errorMessage = lastError?.localizedDescription
                }
            } else {
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }

            return false
        }
    }

    func loadActiveProfile() async {
        guard !isLoadingActiveProfile else { return }

        isLoadingActiveProfile = true
        activeProfileErrorMessage = nil
        let generation = activeProfileGeneration
        defer { isLoadingActiveProfile = false }

        do {
            let response = try await client.profiles()
            guard !Task.isCancelled, generation == activeProfileGeneration else { return }
            applyActiveProfile(response)
        } catch {
            guard !Task.isCancelled, !error.isCancellation,
                  generation == activeProfileGeneration else { return }

            activeProfileErrorMessage = error.localizedDescription
        }
    }

    func adoptDefaultProfileSelection(_ selection: DefaultProfileSelection) {
        activeProfileGeneration += 1
        let profile = profileOptions.first { $0.normalizedName == selection.name }
        activeProfileName = selection.name
        activeProfileDisplayName = selection.displayName
        activeProfileModel = Self.nonEmpty(selection.defaultModel) ?? Self.nonEmpty(profile?.model)
        activeProfileProvider = Self.nonEmpty(profile?.provider)
        activeProfileErrorMessage = nil
    }

    func switchActiveProfile(_ profile: ProfileSummary) async -> Bool {
        guard !isViewingCachedData else {
            activeProfileErrorMessage = String(localized: "Reconnect to the server to change profiles.")
            return false
        }

        guard let profileName = Self.nonEmpty(profile.name) else {
            activeProfileErrorMessage = String(localized: "The server did not provide a profile name.")
            return false
        }

        guard profileName != activeProfileName else {
            return true
        }

        isSwitchingActiveProfile = true
        switchingActiveProfileName = profileName
        activeProfileErrorMessage = nil
        lastError = nil
        defer {
            isSwitchingActiveProfile = false
            switchingActiveProfileName = nil
        }

        do {
            let response = try await client.switchProfile(name: profileName)
            if let error = Self.nonEmpty(response.error) {
                activeProfileErrorMessage = error
                return false
            }

            let resolvedName = Self.nonEmpty(response.active) ?? profileName
            let profileResponse = ProfilesResponse(
                profiles: response.profiles ?? profileOptions,
                active: resolvedName,
                singleProfileMode: isSingleProfileMode
            )
            applyActiveProfile(
                profileResponse,
                fallbackProfile: profile,
                fallbackDefaultModel: response.defaultModel
            )
            return true
        } catch {
            guard !error.isCancellation else { return false }

            lastError = error
            activeProfileErrorMessage = error.localizedDescription
            return false
        }
    }

    func searchSessions(
        query rawQuery: String,
        content: Bool = true,
        depth: Int = 5,
        debounceNanoseconds: UInt64 = 350_000_000
    ) async {
        let query = Self.normalizedSearchQuery(rawQuery)
        let repeatsHermesSearch = hermes != nil && activeRemoteSearchQuery == query
        activeRemoteSearchQuery = query
        remoteContentSearchSessionIDs = []
        remoteContentSearchExcerpts = [:]
        if !repeatsHermesSearch { clearHermesSearchMatches() }
        searchErrorMessage = nil

        guard !query.isEmpty, !isViewingCachedData else {
            isSearchingRemoteSessions = false
            if hermes != nil, !query.isEmpty { hermesSearchAwaitsConnect = true }
            return
        }

        do {
            if debounceNanoseconds > 0 {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            }

            guard !Task.isCancelled, activeRemoteSearchQuery == query else { return }

            isSearchingRemoteSessions = true
            if hermes != nil {
                guard try await searchHermes(query) else { return }
            } else {
                let response = try await client.searchSessions(query: query, content: content, depth: depth)

                guard !Task.isCancelled, activeRemoteSearchQuery == query else { return }

                let matches = contentMatches(from: response.sessions ?? [])
                remoteContentSearchSessionIDs = matches.sessionIDs
                remoteContentSearchExcerpts = matches.excerpts
            }
            isSearchingRemoteSessions = false
        } catch {
            guard activeRemoteSearchQuery == query else { return }

            isSearchingRemoteSessions = false
            guard !error.isCancellation else { return }
            if hermes != nil, error as? BotFailure == .stale { hermesSearchAwaitsConnect = true; return }

            remoteContentSearchSessionIDs = []
            remoteContentSearchExcerpts = [:]
            searchErrorMessage = error.localizedDescription
            lastError = error
        }
    }

    func searchExcerpt(for session: SessionSummary, searchText: String) -> SessionSearchExcerpt? {
        let query = Self.normalizedSearchQuery(searchText)
        if session.hermes != nil {
            guard !query.isEmpty, activeRemoteSearchQuery == query, let snippet = hermesSearchSnippets[session.id] else { return nil }
            return SessionSearchExcerpt(hermesSnippet: snippet, query: query)
        }

        guard !query.isEmpty, activeRemoteSearchQuery == query,
              let sessionID = session.sessionId,
              let text = remoteContentSearchExcerpts[sessionID]
        else {
            return nil
        }

        return SessionSearchExcerpt(text: text, query: query)
    }

    func clearSearchResults() {
        activeRemoteSearchQuery = nil
        remoteContentSearchSessionIDs = []
        remoteContentSearchExcerpts = [:]
        clearHermesSearchMatches()
        searchErrorMessage = nil
        isSearchingRemoteSessions = false
    }

    private var loadFailureRefreshResult: ActiveSessionStateRefreshResult {
        lastError == nil ? .unchanged : .failed
    }

    @discardableResult
    func refreshActiveSessionStatesIfNeeded(
        streamIDs rawStreamIDs: [String],
        modelContext: ModelContext? = nil
    ) async -> ActiveSessionStateRefreshResult {
        guard !isViewingCachedData, !isLoading else { return .unchanged }

        let streamIDs = Self.normalizedStreamIDs(rawStreamIDs)
        guard !streamIDs.isEmpty else {
            return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
        }

        for streamID in streamIDs {
            do {
                let response = try await client.chatStreamStatus(streamID: streamID)
                guard response.active == false else { continue }
                return await load(modelContext: modelContext) ? .reloaded : loadFailureRefreshResult
            } catch {
                guard !error.isCancellation else { return .unchanged }
                if case APIError.unauthorized = error {
                    lastError = error
                    return .failed
                }
                continue
            }
        }

        return await refreshAttentionStates()
    }

    func attentionState(for session: SessionSummary) -> SessionRowAttentionState? {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return nil }
        if let state = attentionStatesBySessionID[sessionID] { return state }
        guard !hermesBackgroundWork.isEmpty else { return nil }
        let working = hermesBackgroundWork.contains(sessionID)
            || session.hermes.map { hermesBackgroundWork.contains($0.lineageRoot) } == true
        return working ? .working : nil
    }

    func isUnread(_ session: SessionSummary) -> Bool {
        if let hermes = session.hermes {
            return session.sessionId.flatMap { hermesUnreadMarks[$0]?.unread } ?? hermes.unread
        }
        guard let sessionID = Self.nonEmpty(session.sessionId),
              let timestamp = Self.messageTime(for: session),
              let seen = seenMessageTimes[sessionID],
              !SessionRowView.isActiveStreaming(session),
              session.hasPendingUserMessage != true
        else { return false }
        return timestamp > seen
    }

    func canToggleUnread(_ session: SessionSummary) -> Bool {
        if let hermes = session.hermes {
            return !isViewingCachedData && !hermes.isBotChat && Self.nonEmpty(session.sessionId) != nil
        }
        return Self.nonEmpty(session.sessionId) != nil
            && Self.messageTime(for: session) != nil
            && !SessionRowView.isActiveStreaming(session)
            && session.hasPendingUserMessage != true
    }

    func beginViewing(_ session: SessionSummary) {
        if session.hermes != nil {
            setHermesUnread(false, session)
            return
        }
        viewingSessionID = Self.nonEmpty(session.sessionId)
        markSeen(session)
    }

    func noteReturn(from session: SessionSummary) {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return }
        if viewingSessionID == sessionID { viewingSessionID = nil }
        returnedFromSessionIDs.insert(sessionID)
        returnRevision &+= 1
    }

    func unreadRowsInScope(selectedProjectID: String?,
                           automatedVisibility: AutomatedSessionVisibility = .showAll) -> [SessionSummary] {
        sessions.filter { session in
            automatedVisibility.shows(session) && (selectedProjectID == nil || session.projectId == selectedProjectID)
                && isUnread(session) && canToggleUnread(session)
        }
    }

    private(set) var isMarkingAllRead = false

    func markAllHermesRead(rows: [SessionSummary]) async -> Int {
        guard !isMarkingAllRead else { return 0 }
        isMarkingAllRead = true
        defer { isMarkingAllRead = false }
        let targets = rows.filter { isUnread($0) && canToggleUnread($0) }
        var confirmed = 0
        await withTaskGroup(of: Bool.self) { group in
            var remaining = targets.makeIterator()
            for _ in 0..<Self.maxConcurrentReadMarks {
                guard let row = remaining.next() else { break }
                group.addTask { await self.markHermesRead(row) }
            }
            while let taken = await group.next() {
                if taken { confirmed += 1 }
                if let row = remaining.next() { group.addTask { await self.markHermesRead(row) } }
            }
        }
        return confirmed
    }

    private static let maxConcurrentReadMarks = 4

    private func markHermesRead(_ session: SessionSummary) async -> Bool {
        await setHermesUnread(false, session)?.value ?? false
    }

    func toggleUnread(_ session: SessionSummary) {
        if session.hermes != nil {
            setHermesUnread(!isUnread(session), session)
            return
        }
        guard canToggleUnread(session),
              let sessionID = Self.nonEmpty(session.sessionId),
              let timestamp = Self.messageTime(for: session)
        else { return }
        seenMessageTimes[sessionID] = isUnread(session) ? timestamp : timestamp.nextDown
        persistSeen()
    }

    private func markSeen(_ session: SessionSummary) {
        guard let sessionID = Self.nonEmpty(session.sessionId),
              let timestamp = Self.messageTime(for: session),
              (seenMessageTimes[sessionID] ?? 0) < timestamp
        else { return }
        seenMessageTimes[sessionID] = timestamp
        persistSeen()
    }

    private func reconcileUnread(
        _ visibleSessions: [SessionSummary],
        allSessions: [SessionSummary],
        returnedFromIDs: Set<String>
    ) {
        let presentIDs = Set(allSessions.compactMap { Self.nonEmpty($0.sessionId) })
        var updated = seenMessageTimes.filter { presentIDs.contains($0.key) }
        for session in visibleSessions {
            guard let sessionID = Self.nonEmpty(session.sessionId),
                  let timestamp = Self.messageTime(for: session)
            else { continue }
            if updated[sessionID] == nil
                || returnedFromIDs.contains(sessionID)
                || viewingSessionID == sessionID {
                updated[sessionID] = max(updated[sessionID] ?? timestamp, timestamp)
            }
        }
        guard updated != seenMessageTimes else { return }
        seenMessageTimes = updated
        persistSeen()
    }

    private func persistSeen() {
        unreadStore.save(seenMessageTimes, for: server)
    }

    private static func messageTime(for session: SessionSummary) -> Double? {
        guard let timestamp = session.lastMessageAt, timestamp.isFinite, timestamp > 0 else { return nil }
        return timestamp
    }

    private func refreshAttentionStates() async -> ActiveSessionStateRefreshResult {
        let streamingSessions = sessions.filter { SessionRowView.isActiveStreaming($0) }
        guard !streamingSessions.isEmpty else {
            clearAttentionStates()
            return .unchanged
        }

        var refreshed: [String: SessionRowAttentionState] = [:]

        for session in streamingSessions {
            guard let sessionID = Self.nonEmpty(session.sessionId) else { continue }

            async let pendingApproval = client.approvalPending(sessionID: sessionID)
            async let pendingClarification = client.clarifyPending(sessionID: sessionID)

            let previous = attentionStatesBySessionID[sessionID]
            var hasPendingApproval = false
            var hasPendingClarification = false
            var probeErrors: [Error] = []

            do {
                let response = try await pendingApproval
                hasPendingApproval = Self.hasPending(response.pending)
            } catch {
                probeErrors.append(error)
                hasPendingApproval = previous == .approval
            }

            do {
                let response = try await pendingClarification
                hasPendingClarification = Self.hasPending(response.pending)
            } catch {
                probeErrors.append(error)
                hasPendingClarification = previous == .input
            }

            for error in probeErrors {
                guard !error.isCancellation else { return .unchanged }
                if case APIError.unauthorized = error {
                    lastError = error
                    return .failed
                }
            }

            refreshed[sessionID] = SessionRowAttentionState.resolve(
                session: session,
                hasPendingApproval: hasPendingApproval,
                hasPendingClarification: hasPendingClarification
            )
        }

        guard refreshed != attentionStatesBySessionID else { return .unchanged }
        attentionStatesBySessionID = refreshed
        return .unchanged
    }

    private static func hasPending(_ pending: PendingApproval?) -> Bool {
        guard let pending else { return false }
        return !pending.isEmpty
    }

    private static func hasPending(_ pending: PendingClarification?) -> Bool {
        guard let pending else { return false }
        return !pending.isEmpty
    }

    private func clearAttentionStates() {
        guard !attentionStatesBySessionID.isEmpty else { return }
        attentionStatesBySessionID = [:]
    }

    private func pruneAttentionStates() {
        guard !attentionStatesBySessionID.isEmpty else { return }

        let streamingSessionIDs = Set(sessions.compactMap { session -> String? in
            guard SessionRowView.isActiveStreaming(session) else { return nil }
            return Self.nonEmpty(session.sessionId)
        })
        let pruned = attentionStatesBySessionID.filter { streamingSessionIDs.contains($0.key) }
        guard pruned != attentionStatesBySessionID else { return }
        attentionStatesBySessionID = pruned
    }

    func loadSessionForDeepLink(id rawSessionID: String, modelContext: ModelContext? = nil, isPush: Bool = false) async -> SessionSummary? {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }

        if !isPush, let loadedSession = sessions.first(where: { $0.sessionId == sessionID }) {
            return loadedSession
        }

        actionErrorMessage = nil
        lastError = nil

        if !isPush, let modelContext {
            do {
                if let cachedSession = try CacheStore.cachedSessions(serverURL: server, in: modelContext)
                    .first(where: { $0.sessionId == sessionID }) {
                    return cachedSession
                }
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        do {
            let response = try await client.session(id: sessionID, includeMessages: false, messageLimit: nil)
            guard !Task.isCancelled else { return nil }
            guard let sessionDetail = response.session else {
                if isPush { return nil }
                actionErrorMessage = String(localized: "The server did not return the linked session.")
                return nil
            }

            if isPush, sessionDetail.sessionId != sessionID { return nil }
            let session = SessionSummary(from: sessionDetail)
            if session.archived != true,
               session.shouldAppearInSessionList,
               !sessions.contains(where: { $0.sessionId == session.sessionId }) {
                sessions.insert(session, at: 0)
            }

            if let modelContext, session.shouldAppearInSessionList {
                do {
                    try CacheStore.cacheSession(session, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return session
        } catch {
            guard !Task.isCancelled else { return nil }
            if isPush, case APIError.http(404, _) = error { return nil }
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func sessionForOpening(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> SessionSummary? {
        sessionOpenGeneration &+= 1
        let generation = sessionOpenGeneration
        openingSessionID = nil
        actionErrorMessage = nil
        lastError = nil

        guard !isViewingCachedData, session.requiresExternalImport else {
            return session
        }

        guard let sessionID = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        openingSessionID = session.sessionId
        defer {
            if generation == sessionOpenGeneration { openingSessionID = nil }
        }

        do {
            let response = try await client.importExternalSession(id: sessionID)
            guard !Task.isCancelled, generation == sessionOpenGeneration else { return nil }
            guard let detail = response.session else {
                actionErrorMessage = String(localized: "The server did not return the linked session.")
                return nil
            }

            guard let importedSession = storeOpenedExternalSession(
                detail,
                listedSession: session,
                expectedSessionID: sessionID,
                modelContext: modelContext
            ) else {
                actionErrorMessage = String(localized: "The server did not return the linked session.")
                return nil
            }

            return importedSession
        } catch let importError {
            guard !Task.isCancelled,
                  generation == sessionOpenGeneration,
                  !importError.isCancellation
            else {
                return nil
            }

            do {
                let response = try await client.session(
                    id: sessionID,
                    includeMessages: false,
                    messageLimit: nil
                )
                guard !Task.isCancelled, generation == sessionOpenGeneration else { return nil }
                guard let detail = response.session,
                      let existingSession = storeOpenedExternalSession(
                          detail,
                          listedSession: session,
                          expectedSessionID: sessionID,
                          modelContext: modelContext
                      )
                else {
                    recordSessionImportFailure(importError)
                    return nil
                }

                return existingSession
            } catch {
                guard !Task.isCancelled,
                      generation == sessionOpenGeneration,
                      !error.isCancellation
                else {
                    return nil
                }

                recordSessionImportFailure(importError)
                return nil
            }
        }
    }

    private func storeOpenedExternalSession(
        _ detail: SessionDetail,
        listedSession: SessionSummary,
        expectedSessionID: String,
        modelContext: ModelContext?
    ) -> SessionSummary? {
        let currentSession = sessions.first(where: { $0.sessionId == expectedSessionID }) ?? listedSession
        let resolvedSession = currentSession.mergingImportedDetail(detail)
        guard resolvedSession.sessionId == expectedSessionID else { return nil }

        if let index = sessions.firstIndex(where: { $0.sessionId == expectedSessionID }) {
            sessions[index] = resolvedSession
        }

        if let modelContext, resolvedSession.shouldAppearInSessionList {
            do {
                try CacheStore.cacheSession(resolvedSession, serverURL: server, in: modelContext)
            } catch {
                cacheErrorMessage = error.localizedDescription
            }
        }

        return resolvedSession
    }

    private func recordSessionImportFailure(_ error: Error) {
        lastError = error
        actionErrorMessage = (error as? APIError)?.serverMessage ?? error.localizedDescription
    }

    func invalidateSessionOpening() {
        sessionOpenGeneration &+= 1
        openingSessionID = nil
    }

    func setPinned(
        _ pinned: Bool,
        for session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        if session.hermes != nil { return await changeHermesSession(session, .pinned(pinned), animation: animation) }
        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.setPinned(pinned, sessionID: sessionId)
        }
    }

    func archive(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        if session.hermes != nil { return await changeHermesSession(session, .archived(true), animation: animation) }
        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.archive(sessionID: sessionId)
        }
    }

    func unarchive(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        if session.hermes != nil { return await changeHermesSession(session, .archived(false), animation: animation) }
        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.unarchive(sessionID: sessionId)
        }
    }

    func delete(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil,
        animation: Animation? = nil
    ) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        if session.hermes != nil { return await deleteHermesSession(session, animation: animation) }
        guard beginSessionMutation(sessionId) else { return false }
        defer { endSessionMutation(sessionId) }

        return await mutate(modelContext: modelContext, animation: animation) {
            try await sessionMutator.delete(sessionID: sessionId)
        }
    }

    func isMutating(_ session: SessionSummary) -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else { return false }
        return mutatingSessionIDs.contains(sessionId)
    }

    func rename(_ session: SessionSummary, to rawTitle: String, modelContext: ModelContext? = nil) async -> Bool {
        renameErrorMessage = nil
        guard !isViewingCachedData else {
            renameErrorMessage = String(localized: "Reconnect to the server to rename a session.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            renameErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let title = Self.nonEmpty(rawTitle) else {
            renameErrorMessage = String(localized: "Enter a session title.")
            return false
        }

        if session.hermes != nil { return await renameHermesSession(session, to: title) }
        isRenamingSession = true
        lastError = nil
        defer { isRenamingSession = false }

        do {
            let response = try await sessionMutator.rename(sessionID: sessionId, title: title)
            if let error = Self.nonEmpty(response.error) {
                renameErrorMessage = error
                return false
            }

            let resolvedTitle = Self.nonEmpty(response.session?.title) ?? title
            let baseSession = sessions.first(where: { $0.sessionId == sessionId }) ?? session
            let updatedSession = baseSession.replacingTitle(with: resolvedTitle)
            if let existingIndex = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                sessions[existingIndex] = updatedSession
            }

            if let modelContext {
                do {
                    try CacheStore.cacheSession(updatedSession, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return true
        } catch {
            guard !error.isCancellation else { return false }

            lastError = error
            renameErrorMessage = error.localizedDescription
            return false
        }
    }

    func duplicate(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> SessionSummary? {
        guard SessionRowActionPolicy.canDuplicate(session) else {
            actionErrorMessage = String(localized: "This command is not available in the mobile app.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        if session.hermes != nil { return await duplicateHermesSession(session) }
        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil

        do {
            let result = try await sessionMutator.duplicate(sessionID: sessionId)

            guard let duplicatedSession = result.session else {
                actionErrorMessage = result.errorMessage
                return nil
            }

            await load(modelContext: modelContext)
            if !sessions.contains(where: { $0.sessionId == duplicatedSession.sessionId }) {
                sessions.insert(duplicatedSession, at: 0)

                if let modelContext {
                    do {
                        try CacheStore.cacheSessions(sessions, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }
            return duplicatedSession
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func export(_ session: SessionSummary, format: SessionExportFormat) async -> URL? {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to export a session.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        guard beginSessionMutation(sessionId) else { return nil }
        defer { endSessionMutation(sessionId) }

        actionErrorMessage = nil
        lastError = nil

        do {
            let file = try await session.hermes == nil
                ? client.exportSession(id: sessionId, format: format, fallbackTitle: session.title)
                : exportHermesSession(session, key: sessionId, format: format)

            let directory = Self.exportsRootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileURL = directory.appendingPathComponent(file.filename)
            try file.data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            guard !error.isCancellation else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func loadProjects() async {
        isLoadingProjects = true
        actionErrorMessage = nil
        lastError = nil
        defer { isLoadingProjects = false }

        do {
            let response = try await client.projects()
            projects = response.projects ?? []
        } catch {
            guard !error.isCancellation else { return }

            lastError = error
            actionErrorMessage = error.localizedDescription
        }
    }

    func move(_ session: SessionSummary, to projectID: String?, modelContext: ModelContext? = nil) async {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return
        }

        guard beginSessionMutation(sessionId) else { return }
        defer { endSessionMutation(sessionId) }

        isMovingSession = true
        defer { isMovingSession = false }

        _ = await mutate(modelContext: modelContext) {
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
        }
    }

    func createProject(
        named rawName: String,
        color: String,
        moving session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        projectSheetErrorMessage = nil
        lastError = nil

        guard let sessionId = session.sessionId else {
            projectSheetErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            projectSheetErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        isMovingSession = true
        defer {
            isCreatingProject = false
            isMovingSession = false
        }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                projectSheetErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                projectSheetErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !error.isCancellation else { return false }

            lastError = error
            projectSheetErrorMessage = error.localizedDescription
            return false
        }
    }

    func createEmptyProject(
        named rawName: String,
        color: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        projectSheetErrorMessage = nil
        lastError = nil

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            projectSheetErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        defer { isCreatingProject = false }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                projectSheetErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                projectSheetErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !error.isCancellation else { return false }

            lastError = error
            projectSheetErrorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ project: ProjectSummary, modelContext: ModelContext? = nil) async -> Bool {
        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }
        if project.hermes != nil { return await deleteHermesProject(projectID) }

        isDeletingProject = true
        actionErrorMessage = nil
        lastError = nil
        defer { isDeletingProject = false }

        do {
            _ = try await client.deleteProject(id: projectID)
            projects.removeAll { $0.projectId == projectID }
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !error.isCancellation else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ project: ProjectSummary, named rawName: String, color: String?) async -> Bool {
        projectSheetErrorMessage = nil
        lastError = nil

        guard let projectID = project.projectId, !projectID.isEmpty else {
            projectSheetErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            projectSheetErrorMessage = String(localized: "Enter a project name.")
            return false
        }
        if project.hermes != nil { return await renameHermesProject(projectID, named: name, color: color) }

        isRenamingProject = true
        defer { isRenamingProject = false }

        do {
            let response = try await client.renameProject(id: projectID, name: name, color: color)
            guard let renamedProject = response.project else {
                projectSheetErrorMessage = response.error ?? String(localized: "The server did not return the renamed project.")
                return false
            }

            guard renamedProject.projectId?.isEmpty == false else {
                projectSheetErrorMessage = response.error ?? String(localized: "The server did not return the renamed project ID.")
                return false
            }

            upsertProject(renamedProject)
            return true
        } catch {
            guard !error.isCancellation else { return false }

            lastError = error
            projectSheetErrorMessage = error.localizedDescription
            return false
        }
    }

    func createSession(
        modelContext: ModelContext? = nil,
        profile: String? = nil,
        projectID: String? = nil
    ) async -> SessionSummary? {
        isCreatingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isCreatingSession = false }

        do {
            let requestedProfile = Self.nonEmpty(profile) ?? Self.nonEmpty(activeProfileName)
            var workspace: String?
            if requestedProfile == nil {
                let workspaces = try await client.workspaces()
                workspace = workspaces.last ?? workspaces.workspaces?.compactMap(\.path).first
            }
            let response = try await client.createSession(
                workspace: workspace,
                model: nil,
                modelProvider: nil,
                profile: requestedProfile,
                projectID: Self.nonEmpty(projectID)
            )

            guard let sessionDetail = response.session else {
                actionErrorMessage = String(localized: "The server did not return the new session.")
                return nil
            }

            let newSession = SessionSummary(from: sessionDetail)
            guard newSession.sessionId?.isEmpty == false else {
                actionErrorMessage = String(localized: "The server did not return the new session ID.")
                return nil
            }

            if newSession.shouldAppearInSessionList {
                if let existingIndex = sessions.firstIndex(where: { $0.sessionId == newSession.sessionId }) {
                    sessions[existingIndex] = newSession
                } else {
                    sessions.insert(newSession, at: 0)
                }

                if let modelContext {
                    do {
                        try CacheStore.cacheSession(newSession, serverURL: server, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }

            return newSession
        } catch {
            guard !error.isCancellation else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    func removeEmptySidebarPlaceholders() {
        let filtered = sessions.filter(\.shouldAppearInSessionList)
        guard filtered.count != sessions.count else { return }
        sessions = filtered
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func activeStreamIDs(in sessions: [SessionSummary]) -> [String] {
        normalizedStreamIDs(sessions.compactMap(\.activeStreamId))
    }

    private static func normalizedStreamIDs(_ rawStreamIDs: [String]) -> [String] {
        Array(Set(rawStreamIDs.compactMap(nonEmpty))).sorted()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sortedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) {
                return left.pinned == true
            }

            return timestamp(for: left) > timestamp(for: right)
        }
    }

    private static func timestamp(for session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }

    private static func searchableText(for session: SessionSummary) -> String {
        [
            session.title,
            session.hermes?.preview,
            session.workspace,
            session.model,
            session.modelProvider,
            session.profile,
            session.sourceLabel
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private func applySessions(
        _ newSessions: [SessionSummary],
        archivedCount newArchivedCount: Int?,
        animation: Animation?
    ) {
        guard let animation else {
            sessions = newSessions
            archivedCount = newArchivedCount
            pruneAttentionStates()
            return
        }

        withAnimation(animation) {
            sessions = newSessions
            archivedCount = newArchivedCount
        }
        pruneAttentionStates()
    }

    private func contentMatches(
        from sessions: [SessionSummary]
    ) -> (sessionIDs: [String], excerpts: [String: String]) {
        let locallyVisibleSessionIDs = Set(self.sessions.compactMap { session -> String? in
            guard session.archived != true, let sessionID = session.sessionId, !sessionID.isEmpty else {
                return nil
            }

            return sessionID
        })
        var seenSessionIDs = Set<String>()
        var sessionIDs: [String] = []
        var excerpts: [String: String] = [:]

        for session in sessions {
            guard session.matchType?.lowercased() == "content",
                  let sessionID = session.sessionId,
                  locallyVisibleSessionIDs.contains(sessionID),
                  !seenSessionIDs.contains(sessionID)
            else {
                continue
            }

            seenSessionIDs.insert(sessionID)
            sessionIDs.append(sessionID)

            if let preview = session.matchPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
               !preview.isEmpty {
                excerpts[sessionID] = preview
            }
        }

        return (sessionIDs, excerpts)
    }

    private func beginSessionMutation(_ sessionId: String) -> Bool {
        mutatingSessionIDs.insert(sessionId).inserted
    }

    private func endSessionMutation(_ sessionId: String) {
        mutatingSessionIDs.remove(sessionId)
    }

    private func upsertProject(_ project: ProjectSummary) {
        guard let projectID = project.projectId, !projectID.isEmpty else { return }

        if let existingIndex = projects.firstIndex(where: { $0.projectId == projectID }) {
            projects[existingIndex] = project
        } else {
            projects.append(project)
        }
    }

    private func applyActiveProfile(
        _ response: ProfilesResponse,
        fallbackProfile: ProfileSummary? = nil,
        fallbackDefaultModel: String? = nil
    ) {
        activeProfileGeneration += 1
        profileOptions = response.profiles ?? profileOptions

        if let singleProfileMode = response.singleProfileMode {
            isSingleProfileMode = singleProfileMode
        }

        if let profiles = response.profiles {
            let changed = ProfileEntityCache.shared.save(profiles)
            ProfileEntityProvider.refreshAppShortcuts(changed: changed)
        }

        let profileName = response.effectiveDefaultProfileName
        let profile = response.profile(matching: profileName) ?? fallbackProfile

        activeProfileName = profileName
        activeProfileDisplayName = response.displayName(for: profileName)
            ?? profile?.displayName
        activeProfileModel = Self.nonEmpty(profile?.model) ?? Self.nonEmpty(fallbackDefaultModel)
        activeProfileProvider = Self.nonEmpty(profile?.provider)
    }

    var isHermesConnected: Bool { hermesWire != nil }

    func openHermes(modelContext: ModelContext? = nil) async {
        guard let hermes else { return }
        if let modelContext { hermesCache = modelContext }
        hermesIsListening = true
        let followed = followSavedHermesProfile()
        if let wire = hermesWire {
            guard wire !== hermesConnectingWire else { return }
            let listed = hermesProfiles
            if hermesShowsAllProfiles { await readHermesProfiles(wire) }
            if followed || hermesProfiles != listed { _ = await watchHermesProfile(wire) }
            await reloadHermes()
            await runAwaitedHermesSearch()
            if !hermesShowsAllProfiles { await readHermesProfiles(wire) }
            return
        }
        hermesReconnect?.cancel()
        let wire = hermes.makeWire(hermes.connection)
        hermesWire = wire
        hermesReadsStatus = true
        hermesReadsApprovals = true
        hermesReadsRoster = true
        if sessions.isEmpty { isLoading = !showCachedHermesSessions(provisional: true) }
        wire.onEvent = { [weak self, weak wire] event in
            guard let self, let wire, self.hermesWire === wire, self.hermesIsListening,
                  event["type"].text == "sessions.changed" else { return }
            self.noteHermesChange()
        }
        wire.onDisconnect = { [weak self, weak wire] error in
            guard let self, let wire, self.hermesWire === wire else { return }
            self.dropHermes(error)
        }
        hermesConnectingWire = wire
        do {
            try await wire.connect()
            if hermesConnectingWire === wire { hermesConnectingWire = nil }
            guard hermesWire === wire else { return }
            if hermesProfile == nil || hermesShowsAllProfiles { await readHermesProfiles(wire) }
            if hermesProfile == nil { await resolveHermesProfile(wire) }
            guard hermesWire === wire else { return }
            if await watchHermesProfile(wire) { _ = await moveOffRemovedHermesProfile(wire) }
            guard hermesWire === wire else { return }
            await reloadHermes()
            await runAwaitedHermesSearch()
            await readHermesProfiles(wire)
        } catch {
            if hermesConnectingWire === wire { hermesConnectingWire = nil }
            guard hermesWire === wire else { return }
            if Task.isCancelled { wire.close(); hermesWire = nil; isLoading = false; return }
            if !isHermesReconnecting { showCachedHermesSessions(after: error) }
            dropHermes(error)
        }
    }

    func pauseHermes() {
        hermesIsListening = false
        hermesDebounceTask?.cancel(); hermesDebounceTask = nil
        hermesStatusTask?.cancel(); hermesStatusTask = nil
        hermesRosterTask?.cancel(); hermesRosterTask = nil
    }

    func closeHermes() {
        teardownHermes()
        setHermesReconnecting(false)
        if attentionStatesAreStale { setHermesStates([:]) }
    }

    private func teardownHermes() {
        pauseHermes()
        hermesReconnect?.cancel()
        hermesReloadTask?.cancel(); hermesReloadTask = nil; hermesReloadWanted = false
        hermesArchivedCountTask?.cancel(); hermesArchivedCountTask = nil
        hermesReadSerial += 1
        isLoading = false; isLoadingMoreSessions = false; isLoadingMoreScheduledSessions = false
        hermesWire?.close(); hermesWire = nil; hermesConnectingWire = nil
        hasReadHermes = false
        clearHermesBackgroundWork()
        if activeRemoteSearchQuery?.isEmpty == false { hermesSearchAwaitsConnect = true }
    }

    func refreshHermes(modelContext: ModelContext? = nil) async {
        if activeRemoteSearchQuery?.isEmpty == false { hermesSearchAwaitsConnect = true }
        await openHermes(modelContext: modelContext)
    }

    func selectHermesProfile(_ profile: String) async {
        guard let hermes, profile != hermesProfile || hermesShowsAllProfiles else { return }
        HermesProfilePreference.save(profile, for: server, in: hermes.preferences)
        HermesProfilePreference.saveShowsAllProfiles(false, for: server, in: hermes.preferences)
        hermesShowsAllProfiles = false
        await showHermesProfile(profile)
    }

    func showAllHermesProfiles() async {
        guard let hermes, !hermesShowsAllProfiles, let profile = hermesProfile else { return }
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: hermes.preferences)
        hermesShowsAllProfiles = true
        await showHermesProfile(profile)
    }

    private var hermesListedProfiles: [String] {
        guard let hermesProfile else { return [] }
        return hermesShowsAllProfiles && !hermesProfiles.isEmpty ? hermesProfiles : [hermesProfile]
    }

    func loadMoreHermesSessions() async {
        guard hasMoreSessions, !isLoadingMoreSessions, let wire = hermesWire, wire !== hermesConnectingWire else { return }
        let serial = hermesReadSerial
        isLoadingMoreSessions = true
        defer { if serial == hermesReadSerial { isLoadingMoreSessions = false } }
        do {
            var pages = hermesPages
            for profile in hermesListedProfiles where pages[profile].hasMore {
                let page = try await wire.sessionPage(profile: profile, offset: pages[profile].nextOffset, archived: false)
                guard serial == hermesReadSerial, hermesWire === wire else { return }
                pages[profile].append(page)
            }
            applyHermes(pages, readSerial: serial)
        } catch {
            guard serial == hermesReadSerial, hermesWire === wire, !Task.isCancelled else { return }
            showHermesFailure(error)
        }
    }

    func loadMoreHermesScheduledSessions() async {
        guard hasMoreScheduledSessions, !isLoadingMoreScheduledSessions, let wire = hermesWire,
              wire !== hermesConnectingWire else { return }
        let serial = hermesReadSerial
        isLoadingMoreScheduledSessions = true
        defer { if serial == hermesReadSerial { isLoadingMoreScheduledSessions = false } }
        do {
            var pages = hermesScheduledPages
            for profile in hermesListedProfiles where pages[profile].hasMore {
                let page = try await wire.scheduledSessionPage(profile: profile, offset: pages[profile].nextOffset, archived: false)
                guard serial == hermesReadSerial, hermesWire === wire else { return }
                pages[profile].append(page)
            }
            applyHermesScheduled(pages)
            showHermesPages(hermesPages, animation: nil)
            cacheHermesRows(hermesPages)
            if errorMessage != nil || sessionLoadError != nil { errorMessage = nil; sessionLoadError = nil }
        } catch {
            guard serial == hermesReadSerial, hermesWire === wire, !Task.isCancelled else { return }
            showHermesFailure(error)
        }
    }

    private func applyHermesScheduled(_ pages: HermesProfilePages) {
        hermesScheduledPages = pages
        hasMoreScheduledSessions = pages.hasMore
        hermesScheduledTotal = pages.totalCount
    }

    func noteHermesReturn(from key: String) {
        hermesReturnedFrom.insert(key)
        if hermesIsListening { requestHermesReload() }
    }

    private func reloadHermes() async {
        guard let wire = hermesWire, hermesProfile != nil else { return }
        hermesReadSerial += 1
        let serial = hermesReadSerial
        var holdsPaging = true
        defer {
            if holdsPaging, serial == hermesReadSerial {
                isLoading = false
                if isLoadingMoreSessions { isLoadingMoreSessions = false }
                if isLoadingMoreScheduledSessions { isLoadingMoreScheduledSessions = false }
            }
        }
        do {
            async let ordinary = readHermesPages(wire, previous: hermesPages, loadingMore: isLoadingMoreSessions,
                                                scheduled: false, profiles: hermesListedProfiles, serial: serial)
            async let cron = readHermesPages(wire, previous: hermesScheduledPages, loadingMore: isLoadingMoreScheduledSessions,
                                            scheduled: true, profiles: hermesListedProfiles, serial: serial)
            var (pages, scheduled) = try await (ordinary, cron)
            while hermesListedProfiles.contains(where: { profile in
                (pages[profile].hasMore && pages[profile].nextOffset < hermesPages[profile].nextOffset)
                    || (scheduled[profile].hasMore && scheduled[profile].nextOffset < hermesScheduledPages[profile].nextOffset)
            }) {
                async let moreOrdinary = readHermesPages(wire, previous: hermesPages, loadingMore: false,
                                                        scheduled: false, profiles: hermesListedProfiles, serial: serial, starting: pages)
                async let moreCron = readHermesPages(wire, previous: hermesScheduledPages, loadingMore: false,
                                                    scheduled: true, profiles: hermesListedProfiles, serial: serial, starting: scheduled)
                (pages, scheduled) = try await (moreOrdinary, moreCron)
            }
            guard serial == hermesReadSerial, hermesWire === wire, !Task.isCancelled else { return }
            applyHermesScheduled(scheduled)
            applyHermes(pages, readSerial: serial)
            setHermesReconnecting(false)
            hermesReconnect?.succeeded()
            holdsPaging = false
            isLoading = false
            if isLoadingMoreSessions { isLoadingMoreSessions = false }
            if isLoadingMoreScheduledSessions { isLoadingMoreScheduledSessions = false }
            startHermesRosterRead(wire)
            startHermesStatusRead(wire)
            if !hermesShowsAllProfiles {
                await readHermesProjects(wire, readSerial: serial)
                startHermesArchivedCountRead(wire, readSerial: serial)
            } else if archivedCount != nil {
                archivedCount = nil
            }
            await runAwaitedHermesSearch()
        } catch {
            guard serial == hermesReadSerial, hermesWire === wire, !Task.isCancelled else { return }
            if error as? BotFailure == .stale { return dropHermes(error) }
            if error as? BotFailure == .rejected(404) {
                if hermesShowsAllProfiles {
                    let listed = hermesProfiles
                    await readHermesProfiles(wire)
                    if hermesWire === wire, hermesProfiles != listed { return requestHermesReload() }
                } else if await moveOffRemovedHermesProfile(wire) {
                    return
                }
            }
            if isHermesReconnecting { return dropHermes(error) }
            if showCachedHermesSessions(after: error) { return }
            showHermesFailure(error)
        }
    }

    private func readHermesPages(
        _ wire: any BotTransport, previous: HermesProfilePages, loadingMore: Bool,
        scheduled: Bool, profiles: [String], serial: Int, starting: HermesProfilePages = HermesProfilePages()
    ) async throws -> HermesProfilePages {
        let pageSize = HermesREST.sessionPageSize
        var pages = starting
        for profile in profiles {
            let wanted = max(previous[profile].nextOffset + (loadingMore ? pageSize : 0), pageSize)
            while pages[profile].hasMore, pages[profile].nextOffset < wanted {
                try Task.checkCancellation()
                guard serial == hermesReadSerial, hermesWire === wire else { throw CancellationError() }
                let offset = pages[profile].nextOffset
                let page: HermesSessionPage
                if scheduled {
                    page = try await wire.scheduledSessionPage(profile: profile, offset: offset, archived: false)
                } else {
                    page = try await wire.sessionPage(profile: profile, offset: offset, archived: false)
                }
                try Task.checkCancellation()
                guard serial == hermesReadSerial, hermesWire === wire else { throw CancellationError() }
                pages[profile].append(page)
            }
        }
        return pages
    }

    private func applyHermes(_ pages: HermesProfilePages, readSerial: Int) {
        hermesPages = pages
        if hasMoreSessions != pages.hasMore { hasMoreSessions = pages.hasMore }
        let marks = hermesUnreadMarks.filter { $0.value.settledBefore.map { $0 > readSerial } ?? true }
        if marks.count != hermesUnreadMarks.count { hermesUnreadMarks = marks }
        let rows = hermesRows(pages) + hermesRows(hermesScheduledPages)
        if isViewingCachedData { isViewingCachedData = false }
        for row in rows where row.sessionId.map(hermesReturnedFrom.contains) == true && row.hermes?.unread == true {
            setHermesUnread(false, row)
        }
        hermesReturnedFrom = []
        if sessions != rows { sessions = rows }
        if !hasReadHermes { hasReadHermes = true }
        errorMessage = nil; sessionLoadError = nil
        cacheHermesRows(pages)
        if let hermes, let hermesProfile { HermesProfilePreference.saveLastListed(hermesProfile, for: server, in: hermes.preferences) }
    }

    private func cacheHermesRows(_ pages: HermesProfilePages) {
        guard let hermesCache else { return }
        do {
            for profile in hermesListedProfiles {
                let rows = (pages[profile].rows + hermesScheduledPages[profile].rows).map { $0.summary(in: profile, project: hermesProjectOwners[$0.id]) }
                try CacheStore.cacheHermesSessions(rows, profile: profile, reachedEnd: !pages[profile].hasMore && !hermesScheduledPages[profile].hasMore,
                                                   serverURL: server, in: hermesCache)
            }
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func showCachedHermesSessions(after error: Error) -> Bool {
        if CacheFallbackPolicy.shouldUseCache(for: error), showCachedHermesSessions(provisional: false) { return true }
        if isCachedCopyProvisional { sessions = []; isViewingCachedData = false }
        return false
    }

    @discardableResult
    private func showCachedHermesSessions(provisional: Bool) -> Bool {
        guard let hermes, let hermesCache else { return false }
        let picked = hermesProfile ?? hermes.preferences.string(forKey: HermesProfilePreference.key(for: server))
        let profile = picked ?? HermesProfilePreference.lastListed(for: server, in: hermes.preferences)
        guard hermesShowsAllProfiles || profile != nil else { return false }
        let cached: [SessionSummary]
        do {
            cached = try CacheStore.cachedHermesSessions(serverURL: server, profile: hermesShowsAllProfiles ? nil : profile,
                                                         in: hermesCache)
        } catch {
            cacheErrorMessage = error.localizedDescription
            return false
        }
        guard !cached.isEmpty else { return false }
        if hermesProfile == nil { hermesProfile = picked }
        if sessions != cached { sessions = cached }
        hasMoreSessions = false
        isViewingCachedData = true
        isCachedCopyProvisional = provisional
        errorMessage = nil; sessionLoadError = nil
        setHermesStates([:])
        clearHermesBackgroundWork()
        clearHermesSearchMatches()
        if activeRemoteSearchQuery?.isEmpty == false { hermesSearchAwaitsConnect = true }
        return true
    }

    private func forgetCachedHermesSession(_ session: SessionSummary) {
        guard let hermesCache, let root = session.hermes?.lineageRoot, let profile = Self.nonEmpty(session.profile) else { return }
        do {
            try CacheStore.removeHermesSession(lineageRoot: root, profile: profile, serverURL: server, in: hermesCache)
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    private func hermesRows(_ pages: HermesProfilePages) -> [SessionSummary] {
        pages.rows.map { $0.row.summary(in: $0.profile, project: hermesProjectOwners[$0.row.id]) }
    }

    private func showHermesFailure(_ error: Error) {
        guard let hermes else { return }
        isLoading = false
        sessionLoadError = error
        errorMessage = BotConnectionAdvice.message(for: error, address: hermes.connection.address)
    }

    @discardableResult
    private func setHermesUnread(_ unread: Bool, _ session: SessionSummary) -> Task<Bool, Never>? {
        guard !isViewingCachedData, let wire = hermesWire, let key = Self.nonEmpty(session.sessionId),
              let profile = Self.nonEmpty(session.profile) ?? hermesProfile else { return nil }
        let mark = HermesUnreadMark(unread: unread)
        hermesUnreadMarks[key] = mark
        let earlier = hermesUnreadWrites[key]
        let write = Task<Bool, Never> { [weak self] in
            _ = await earlier?.value
            let written: Bool
            do { try await wire.updateSession(.unread(unread), key: key, profile: profile); written = true } catch { written = false }
            guard let self, self.hermesUnreadMarks[key]?.id == mark.id else { return written }
            if written { self.hermesUnreadMarks[key]?.settledBefore = self.hermesReadSerial + 1 } else { self.hermesUnreadMarks[key] = nil }
            return written
        }
        hermesUnreadWrites[key] = write
        return write
    }

    private func watchHermesProfile(_ wire: any BotTransport) async -> Bool {
        var removed = false
        for profile in hermesListedProfiles {
            do { _ = try await wire.call(.sessionMostRecent(profile: profile)) } catch BotFailure.rejected(4064) {
                if profile == hermesProfile { removed = true }
            } catch {}
        }
        return removed
    }

    private func resolveHermesProfile(_ wire: any BotTransport) async {
        guard let hermes else { return }
        let current = (try? await wire.currentProfile()) ?? "default"
        guard hermesWire === wire else { return }
        hermesProfile = HermesProfilePreference.resolve(for: server, listed: hermesProfiles, current: current, in: hermes.preferences)
    }

    private func moveOffRemovedHermesProfile(_ wire: any BotTransport) async -> Bool {
        guard let hermes, let removed = hermesProfile else { return false }
        await readHermesProfiles(wire)
        guard hermesWire === wire, !hermesProfiles.isEmpty, !hermesProfiles.contains(removed),
              let current = try? await wire.currentProfile(), hermesWire === wire else { return false }
        let next = HermesProfilePreference.resolve(for: server, listed: hermesProfiles, current: current, in: hermes.preferences)
        guard next != removed, hermesProfiles.contains(next) else { return false }
        await showHermesProfile(next)
        return true
    }

    private func showHermesProfile(_ profile: String) async {
        hermesProfile = profile
        hermesPages = HermesProfilePages()
        applyHermesScheduled(HermesProfilePages())
        isLoadingMoreScheduledSessions = false
        hermesReadSerial += 1
        sessions = []; hasMoreSessions = false; isLoadingMoreSessions = false; isViewingCachedData = false
        hermesUnreadMarks = [:]; hermesReturnedFrom = []
        projects = []; hermesProjectOwners = [:]; hermesProjectsRead = false; archivedCount = nil
        clearHermesSearchMatches()
        errorMessage = nil; sessionLoadError = nil
        setHermesStates([:]); setHermesReconnecting(false)
        clearHermesBackgroundWork()
        guard let wire = hermesWire else { return await openHermes() }
        isLoading = true
        guard wire !== hermesConnectingWire else { return }
        if hermesShowsAllProfiles && hermesProfiles.isEmpty { await readHermesProfiles(wire) }
        _ = await watchHermesProfile(wire)
        await reloadHermes()
    }

    private func followSavedHermesProfile() -> Bool {
        guard let hermes, let saved = hermes.preferences.string(forKey: HermesProfilePreference.key(for: server)),
              saved != hermesProfile, hermesProfiles.contains(saved) else { return false }
        hermesProfile = saved
        guard !hermesShowsAllProfiles else { return false }
        hermesPages = HermesProfilePages()
        applyHermesScheduled(HermesProfilePages())
        isLoadingMoreScheduledSessions = false
        sessions = []; hasMoreSessions = false; isViewingCachedData = false
        hermesUnreadMarks = [:]; hermesReturnedFrom = []
        projects = []; hermesProjectOwners = [:]; hermesProjectsRead = false; archivedCount = nil
        clearHermesSearchMatches()
        setHermesStates([:]); setHermesReconnecting(false)
        clearHermesBackgroundWork()
        isLoading = true
        return true
    }

    func readHostProfiles() async -> [String]? {
        guard let wire = hermesWire else { return nil }
        return await readHermesProfiles(wire)
    }

    @discardableResult
    private func readHermesProfiles(_ wire: any BotTransport) async -> [String]? {
        guard let reply = try? await wire.call(.profilesList(includeSessions: false)), hermesWire === wire,
              let rows = reply["profiles"].list else { return nil }
        let names = rows.compactMap { $0["name"].text }.filter { !$0.isEmpty }
        if names != hermesProfiles { hermesProfiles = names }
        let models = Dictionary(rows.compactMap { row -> (String, String)? in
            guard let name = row["name"].text, let model = row["model"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !model.isEmpty else { return nil }
            return (name, model)
        }, uniquingKeysWith: { first, _ in first })
        if models != hermesProfileModels { hermesProfileModels = models }
        if hermesShowsAllProfiles, let pick = hermesProfile, !names.isEmpty, !names.contains(pick) {
            await resolveHermesProfile(wire)
        }
        return names
    }

    func networkPathDidChange() {
        if hermes?.isNetworkAvailable() == false, !attentionStatesBySessionID.isEmpty {
            setHermesStates(attentionStatesBySessionID, stale: true)
        }
        hermesReconnect?.networkPathDidChange()
    }

    func reconnectNow() { hermesReconnect?.networkPathDidChange() }

    private func dropHermes(_ error: Error) {
        if isCachedCopyProvisional { showCachedHermesSessions(after: error) }
        let listening = hermesIsListening
        teardownHermes()
        hermesIsListening = listening
        guard BotConnectionAdvice.isRetryable(error) else {
            setHermesStates([:]); setHermesReconnecting(false)
            return showHermesFailure(error)
        }
        setHermesStates(attentionStatesBySessionID, stale: !attentionStatesBySessionID.isEmpty)
        if sessions.isEmpty {
            showHermesFailure(error)
        } else {
            if errorMessage != nil || sessionLoadError != nil { errorMessage = nil; sessionLoadError = nil }
            setHermesReconnecting(true)
        }
        guard listening else { return }
        hermesReconnect?.schedule { [weak self] in
            guard let self, self.hermesIsListening else { return }
            await self.openHermes()
        }
    }

    private func noteHermesChange() {
        guard let hermes else { return }
        hermesDebounceTask?.cancel()
        hermesDebounceTask = Task { [weak self] in
            guard (try? await Task.sleep(for: hermes.changeDebounce)) != nil, let self, !Task.isCancelled else { return }
            self.hermesDebounceTask = nil
            self.requestHermesReload()
        }
    }

    private func requestHermesReload() {
        hermesReloadWanted = true
        guard hermesReloadTask == nil, let wire = hermesWire, wire !== hermesConnectingWire else { return }
        hermesReloadTask = Task { [weak self] in
            while let self, self.hermesReloadWanted, self.hermesWire === wire, !Task.isCancelled {
                self.hermesReloadWanted = false
                await self.reloadHermes()
            }
            guard let self, self.hermesWire === wire else { return }
            self.hermesReloadTask = nil
        }
    }

    func hermesHostIsIdle() async -> Bool? {
        guard isHermesLive, let wire = hermesWire,
              let reply = try? await wire.call(.sessionActiveList()),
              let sessions = reply["sessions"].list else { return nil }
        return sessions.allSatisfy { $0["status"].text == "idle" }
    }

    private func startHermesStatusRead(_ wire: any BotTransport, after delay: Duration? = nil) {
        hermesStatusTask?.cancel(); hermesStatusTask = nil
        guard hermesReadsStatus, hermesIsListening else { return }
        hermesStatusTask = Task { [weak self] in
            if let delay, (try? await Task.sleep(for: delay)) == nil { return }
            guard !Task.isCancelled, let self, self.hermesWire === wire else { return }
            await self.readHermesStatuses(wire)
        }
    }

    private func readHermesStatuses(_ wire: any BotTransport) async {
        guard let hermes else { return }
        hermesStatusSerial += 1
        let serial = hermesStatusSerial
        func current() -> Bool { !Task.isCancelled && hermesWire === wire && serial == hermesStatusSerial }
        do {
            let reply = try await wire.call(.sessionActiveList())
            guard current() else { return }
            let listed = Set(sessions.compactMap(\.sessionId))
            let items = reply["sessions"].list ?? []
            var states = SessionRowAttentionState.hermesStates(items).filter { listed.contains($0.key) }
            let waiting = hermesReadsApprovals ? Self.hermesWaitingRuntimes(items, states: states) : []
            for (key, _) in waiting where attentionStatesBySessionID[key] == .approval { states[key] = .approval }
            setHermesStates(states)
            hermesRetriesStatus = false
            if !waiting.isEmpty {
                let (pending, unsupported) = await hermesPendingApprovals(waiting, wire: wire)
                guard current() else { return }
                if unsupported { hermesReadsApprovals = false }
                for (key, isPending) in pending { states[key] = isPending ? .approval : .input }
                setHermesStates(states)
            }
        } catch {
            guard current() else { return }
            if error as? BotFailure == .rejected(-32601) {
                hermesReadsStatus = false
                setHermesStates([:])
            } else {
                hermesRetriesStatus = hermesRetriesStatus || !attentionStatesBySessionID.isEmpty
                setHermesStates(attentionStatesBySessionID, stale: !attentionStatesBySessionID.isEmpty)
            }
        }
        if attentionStatesBySessionID.isEmpty && !hermesRetriesStatus { hermesStatusTask = nil }
        else { startHermesStatusRead(wire, after: hermes.statusPollInterval) }
    }

    private func startHermesRosterRead(_ wire: any BotTransport) {
        hermesRosterTask?.cancel(); hermesRosterTask = nil
        guard hermesReadsRoster, hermesIsListening else { return }
        hermesRosterSerial += 1
        let serial = hermesRosterSerial, profiles = hermesListedProfiles
        hermesRosterTask = Task { [weak self] in await self?.readHermesRoster(wire, profiles: profiles, serial: serial) }
    }

    private func readHermesRoster(_ wire: any BotTransport, profiles: [String], serial: Int) async {
        let replies = await withTaskGroup(of: Result<BotJSON, Error>.self) { group in
            for profile in profiles {
                group.addTask { @MainActor in
                    do { return .success(try await wire.call(.subagentRoster(profile: profile))) } catch { return .failure(error) }
                }
            }
            var replies: [Result<BotJSON, Error>] = []
            for await reply in group { replies.append(reply) }
            return replies
        }
        guard !Task.isCancelled, hermesWire === wire, serial == hermesRosterSerial else { return }
        hermesRosterTask = nil
        var working: Set<String> = []
        for reply in replies {
            switch reply {
            case .success(let roster):
                for entry in roster["sessions"].list ?? []
                where (entry["subagents"].integer ?? 0) > 0 || (entry["background"].integer ?? 0) > 0 {
                    if let id = Self.nonEmpty(entry["session_id"].text) { working.insert(id) }
                }
            case .failure(let error):
                if error as? BotFailure == .rejected(-32601) { hermesReadsRoster = false }
                return setHermesBackgroundWork([])
            }
        }
        setHermesBackgroundWork(working)
    }

    private func clearHermesBackgroundWork() {
        hermesRosterTask?.cancel(); hermesRosterTask = nil
        hermesRosterSerial += 1
        setHermesBackgroundWork([])
    }

    private func setHermesBackgroundWork(_ ids: Set<String>) {
        if ids != hermesBackgroundWork { hermesBackgroundWork = ids }
    }

    private static func hermesWaitingRuntimes(_ items: [BotJSON], states: [String: SessionRowAttentionState])
        -> [(key: String, runtime: String)] {
        items.compactMap { item in
            guard let key = item["session_key"].text, states[key] == .input,
                  BotLiveStatus(wire: item["status"].text) == .waiting,
                  let runtime = item["id"].text, !runtime.isEmpty else { return nil }
            return (key, runtime)
        }
    }

    private func hermesPendingApprovals(_ waiting: [(key: String, runtime: String)], wire: any BotTransport) async
        -> (pending: [String: Bool], unsupported: Bool) {
        await withTaskGroup(of: (key: String, pending: Bool?, unsupported: Bool).self) { group in
            for (key, runtime) in waiting {
                group.addTask { @MainActor in
                    do {
                        let reply = try await wire.call(.approvalPending(sessionID: runtime))
                        return (key, !(reply["approvals"].list ?? []).isEmpty, false)
                    } catch {
                        return (key, nil, error as? BotFailure == .rejected(-32601))
                    }
                }
            }
            var result: (pending: [String: Bool], unsupported: Bool) = ([:], false)
            var failed: Set<String> = []
            for await answer in group {
                result.unsupported = result.unsupported || answer.unsupported
                if let pending = answer.pending { result.pending[answer.key] = result.pending[answer.key] == true || pending }
                else { failed.insert(answer.key) }
            }
            for key in failed where result.pending[key] != true { result.pending[key] = nil }
            return result
        }
    }

    private func setHermesStates(_ states: [String: SessionRowAttentionState], stale: Bool = false) {
        if states != attentionStatesBySessionID { attentionStatesBySessionID = states }
        if stale != attentionStatesAreStale { attentionStatesAreStale = stale }
    }

    private func setHermesReconnecting(_ reconnecting: Bool) {
        if reconnecting != isHermesReconnecting { isHermesReconnecting = reconnecting }
    }

    private func searchHermes(_ query: String) async throws -> Bool {
        let profiles = hermesListedProfiles
        guard let wire = hermesWire, !profiles.isEmpty else { throw BotFailure.stale }
        while true {
            let writes = hermesSearchWrites
            var found: [(profile: String, result: HermesSessionSearchResult)] = []
            for profile in profiles {
                found += try await wire.searchSessions(query: query, profile: profile).map { (profile, $0) }
                guard !Task.isCancelled, activeRemoteSearchQuery == query, hermesWire === wire,
                      hermesListedProfiles == profiles else { return false }
                found += try await wire.searchScheduledSessions(query: query, profile: profile, limit: HermesREST.sessionSearchLimit)
                    .filter { $0.row.archived != true }.map { (profile, $0) }
                guard !Task.isCancelled, activeRemoteSearchQuery == query, hermesWire === wire,
                      hermesListedProfiles == profiles else { return false }
            }
            guard writes == hermesSearchWrites else { continue }
            hermesSearchSnippets = Dictionary(found.compactMap { match in match.result.snippet.map { (match.result.row.identity, $0) } },
                                              uniquingKeysWith: { first, _ in first })
            showHermesSearch(found.map { ($0.profile, $0.result.row) })
            return true
        }
    }

    private func showHermesSearch(_ results: [(profile: String, row: HermesSessionRow)]) {
        hermesSearchResults = results
        let rows = results.map { $0.row.summary(in: $0.profile, project: hermesProjectOwners[$0.row.id]) }
        if rows != hermesSearchRows { hermesSearchRows = rows }
    }

    private func applyToHermesSearch(_ change: HermesSessionChange?, key: String) {
        hermesSearchWrites += 1
        guard let index = hermesSearchResults.firstIndex(where: { $0.row.id == key }) else { return }
        var results = hermesSearchResults
        switch change {
        case nil: results.remove(at: index)
        case .pinned(let pinned)?: results[index].row.pinned = pinned
        case .archived(let archived)?: results[index].row.archived = archived
        case .title(let title)?: results[index].row.title = title
        case .unread?: return
        }
        showHermesSearch(results)
    }

    private func runAwaitedHermesSearch() async {
        guard hermesSearchAwaitsConnect, let query = activeRemoteSearchQuery else { return }
        hermesSearchAwaitsConnect = false
        await searchSessions(query: query, debounceNanoseconds: 0)
    }

    private func hermesSearchMatches(excluding shown: [SessionSummary], selectedProjectID: String?) -> [SessionSummary] {
        guard !hermesSearchRows.isEmpty else { return [] }
        var seen = Set(shown.map(\.id))
        let loaded = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return hermesSearchRows.compactMap { result in
            let row = loaded[result.id] ?? result
            guard selectedProjectID == nil || row.projectId == selectedProjectID, seen.insert(row.id).inserted else { return nil }
            return row
        }
    }

    private func clearHermesSearchMatches() {
        hermesSearchResults = []
        hermesSearchAwaitsConnect = false
        if !hermesSearchRows.isEmpty { hermesSearchRows = [] }
        if !hermesSearchSnippets.isEmpty { hermesSearchSnippets = [:] }
    }

    func clearRenameError() {
        renameErrorMessage = nil
    }

    private func hermesTarget(_ session: SessionSummary) -> (wire: any BotTransport, key: String, profile: String)? {
        guard let key = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }
        guard let wire = hermesWire, let profile = Self.nonEmpty(session.profile) ?? hermesProfile else {
            showHermesActionFailure(BotFailure.transport)
            return nil
        }
        return (wire, key, profile)
    }

    private func changeHermesSession(_ session: SessionSummary, _ change: HermesSessionChange,
                                     animation: Animation?) async -> Bool {
        guard let target = hermesTarget(session), beginSessionMutation(target.key) else { return false }
        let (wire, key, profile) = target
        let listed = hermesListedProfiles
        defer { endSessionMutation(key) }
        actionErrorMessage = nil
        hermesReadSerial += 1
        var pages = session.isCronSession ? hermesScheduledPages : hermesPages
        let before = pages.apply(change, to: key)
        showHermesPages(pages, scheduled: session.isCronSession, animation: animation)
        do {
            try await wire.updateSession(change, key: key, profile: profile)
            if change == .archived(true) { forgetCachedHermesSession(session) }
            applyToHermesSearch(change, key: key)
            requestHermesReload()
            return true
        } catch {
            let unknown = error as? BotFailure == .stale
            if !unknown, hermesListedProfiles == listed, let before {
                var pages = session.isCronSession ? hermesScheduledPages : hermesPages
                pages[before.profile].restore(before.row, at: before.index)
                showHermesPages(pages, scheduled: session.isCronSession, animation: animation)
            }
            requestHermesReload()
            if !unknown, !Task.isCancelled { showHermesActionFailure(error) }
            return false
        }
    }

    private func deleteHermesSession(_ session: SessionSummary, animation: Animation?) async -> Bool {
        guard let target = hermesTarget(session), beginSessionMutation(target.key) else { return false }
        let (wire, key, profile) = target
        defer { endSessionMutation(key) }
        actionErrorMessage = nil
        do {
            let outcome = try await HermesSessionDeletion.delete(key: key, profile: profile, on: wire)
            if let refusal = HermesSessionDeletion.message(for: outcome) {
                actionErrorMessage = refusal
                return false
            }
            forgetCachedHermesSession(session)
            hermesReadSerial += 1
            var pages = session.isCronSession ? hermesScheduledPages : hermesPages
            pages.remove(key)
            showHermesPages(pages, scheduled: session.isCronSession, animation: animation)
            applyToHermesSearch(nil, key: key)
            requestHermesReload()
            return true
        } catch {
            if !Task.isCancelled { showHermesActionFailure(error) }
            return false
        }
    }

    private func renameHermesSession(_ session: SessionSummary, to title: String) async -> Bool {
        guard let target = hermesTarget(session) else {
            renameErrorMessage = actionErrorMessage
            actionErrorMessage = nil
            return false
        }
        let (wire, key, profile) = target
        isRenamingSession = true
        renameErrorMessage = nil
        defer { isRenamingSession = false }
        do {
            let kept = try await wire.updateSession(.title(title), key: key, profile: profile)
            let change = HermesSessionChange.title(Self.nonEmpty(kept) ?? title)
            hermesReadSerial += 1
            var pages = session.isCronSession ? hermesScheduledPages : hermesPages
            _ = pages.apply(change, to: key)
            showHermesPages(pages, scheduled: session.isCronSession, animation: nil)
            applyToHermesSearch(change, key: key)
            requestHermesReload()
            return true
        } catch {
            if !Task.isCancelled, error as? BotFailure != .stale { renameErrorMessage = hermesActionFailure(error) }
            return false
        }
    }

    private func duplicateHermesSession(_ session: SessionSummary) async -> SessionSummary? {
        guard let target = hermesTarget(session), beginSessionMutation(target.key) else { return nil }
        let (wire, key, profile) = target
        defer { endSessionMutation(key) }
        actionErrorMessage = nil
        do {
            let copy = try await HermesSessionDuplication.duplicate(key: key, profile: profile, title: SessionRowView.displayTitle(for: session),
                                                                   on: wire)
            requestHermesReload()
            return HermesSessionRow(id: copy.key, title: copy.title, profile: profile).summary(in: profile)
        } catch BotFailure.unsupported {
            actionErrorMessage = String(localized: "The server did not return the duplicated session.")
            return nil
        } catch {
            if !Task.isCancelled { showHermesActionFailure(error) }
            return nil
        }
    }

    private func exportHermesSession(_ session: SessionSummary, key: String,
                                     format: SessionExportFormat) async throws -> SessionExportFile {
        guard format == .json, let wire = hermesWire,
              let profile = Self.nonEmpty(session.profile) ?? hermesProfile else { throw BotFailure.transport }
        let data = try await wire.exportSession(key: key, profile: profile)
        return SessionExportFile(data: data, filename: SessionExportFile.filename(
            contentDisposition: nil, fallbackTitle: SessionRowView.displayTitle(for: session), sessionID: key, format: .json
        ))
    }

    private func showHermesPages(_ pages: HermesProfilePages, scheduled: Bool = false, animation: Animation?) {
        if scheduled { applyHermesScheduled(pages) } else { hermesPages = pages }
        let rows = hermesRows(hermesPages) + hermesRows(hermesScheduledPages)
        guard rows != sessions else { return }
        if let animation { withAnimation(animation) { sessions = rows } } else { sessions = rows }
    }

    private func showHermesActionFailure(_ error: Error) {
        actionErrorMessage = hermesActionFailure(error)
    }

    private func hermesActionFailure(_ error: Error) -> String {
        if let refusal = error as? HermesSessionRefusal { return refusal.message }
        if error is URLError, let hermes { return BotConnectionAdvice.message(for: error, address: hermes.connection.address) }
        return error.localizedDescription
    }

    func hermesLaneIsShort(_ projectID: String) -> Bool {
        guard let claimed = projects.first(where: { $0.projectId == projectID })?.hermes?.claimedCount else { return false }
        return sessions.lazy.filter { $0.projectId == projectID }.count < claimed
    }

    func hermesNewSessionFolder(lane: String?) -> String? {
        guard let lane, !hermesShowsAllProfiles else { return nil }
        return projects.first { $0.projectId == lane }?.hermes?.folder
    }

    func fillHermesLane(_ projectID: String) async {
        guard let profile = hermesProfile else { return }
        while hermesLaneIsShort(projectID), hasMoreSessions, !isLoadingMoreSessions {
            let offset = hermesPages[profile].nextOffset
            await loadMoreHermesSessions()
            guard hermesPages[profile].nextOffset > offset else { return }
        }
    }

    func completeHermesFolder(_ word: String) async -> HermesFolderCompletion.Suggestions {
        guard HermesFolderCompletion.completes(word), let wire = hermesWire, let profile = hermesProfile,
              let reply = try? await wire.call(.completeFolder(word: word, profile: profile)) else { return .init() }
        return HermesFolderCompletion.suggestions(from: reply, typed: word)
    }

    func clearProjectSheetError() {
        projectSheetErrorMessage = nil
    }

    func createHermesProject(named rawName: String, color: String, folder rawFolder: String) async -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = rawFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        guard let wire = hermesWire, let profile = hermesProfile else {
            projectSheetErrorMessage = hermesActionFailure(BotFailure.transport)
            return nil
        }
        isCreatingProject = true
        projectSheetErrorMessage = nil
        defer { isCreatingProject = false }
        do {
            _ = try await wire.call(.projectsCreate(profile: profile, name: name, folder: folder, color: color))
            await readHermesProjects(wire, readSerial: hermesReadSerial)
            return folder
        } catch {
            if !Task.isCancelled { projectSheetErrorMessage = hermesActionFailure(error) }
            return nil
        }
    }

    private func renameHermesProject(_ id: String, named name: String, color: String?) async -> Bool {
        guard let wire = hermesWire, let profile = hermesProfile else {
            projectSheetErrorMessage = hermesActionFailure(BotFailure.transport)
            return false
        }
        isRenamingProject = true
        projectSheetErrorMessage = nil
        defer { isRenamingProject = false }
        do {
            _ = try await wire.call(.projectsUpdate(profile: profile, id: id, name: name,
                                                    color: color.flatMap { $0.isEmpty ? nil : $0 }))
            await readHermesProjects(wire, readSerial: hermesReadSerial)
            return true
        } catch {
            if !Task.isCancelled { projectSheetErrorMessage = hermesActionFailure(error) }
            return false
        }
    }

    private func deleteHermesProject(_ id: String) async -> Bool {
        guard let wire = hermesWire, let profile = hermesProfile else {
            showHermesActionFailure(BotFailure.transport)
            return false
        }
        isDeletingProject = true
        actionErrorMessage = nil
        defer { isDeletingProject = false }
        do {
            _ = try await wire.call(.projectsDelete(profile: profile, id: id))
            await readHermesProjects(wire, readSerial: hermesReadSerial)
            return true
        } catch {
            if !Task.isCancelled { showHermesActionFailure(error) }
            return false
        }
    }

    func moveHermesSession(_ session: SessionSummary, toFolder folder: String) async -> String? {
        guard let target = hermesTarget(session), beginSessionMutation(target.key) else { return nil }
        let (wire, key, profile) = target
        let left = (sessions.first { $0.sessionId == key } ?? session).workspace
        defer { endSessionMutation(key) }
        isMovingSession = true
        actionErrorMessage = nil
        defer { isMovingSession = false }
        do {
            if wire.speaksCanonicalProtocol {
                _ = try await wire.mutateStoredSession(profile: profile, key: key, .workspace(cwd: folder))
            } else {
                _ = try await wire.call(.sessionWorkspaceMove(profile: profile, storedKey: key, cwd: folder))
            }
            requestHermesReload()
            return left.flatMap { $0.isEmpty || $0 == folder ? nil : $0 }
        } catch BotSettingFailure.rejected(4017, _) {
            actionErrorMessage = String(localized: "Hermes can't find the folder \(folder), so the session didn't move.")
            return nil
        } catch {
            requestHermesReload()
            if !Task.isCancelled, error as? BotFailure != .stale { showHermesActionFailure(error) }
            return nil
        }
    }

    private func readHermesProjects(_ wire: any BotTransport, readSerial serial: Int) async {
        guard let profile = hermesProfile else { return }
        hermesProjectsSerial += 1
        let projectsSerial = hermesProjectsSerial
        let showsLoading = !hermesProjectsRead
        if showsLoading { isLoadingProjects = true }
        defer { if showsLoading { isLoadingProjects = false } }
        let reply = try? await wire.call(.projectsTree(profile: profile))
        guard serial == hermesReadSerial, projectsSerial == hermesProjectsSerial,
              hermesWire === wire, hermesProfile == profile else { return }
        hermesProjectsRead = true
        guard let reply else { return }
        let tree = HermesProjectTree(reply: reply)
        hermesProjectOwners = tree.owners
        if projects != tree.projects { projects = tree.projects }
        showHermesPages(hermesPages, animation: nil)
        showHermesSearch(hermesSearchResults)
    }

    private func startHermesArchivedCountRead(_ wire: any BotTransport, readSerial serial: Int) {
        guard serial == hermesReadSerial, hermesWire === wire, !Task.isCancelled, !hermesShowsAllProfiles else { return }
        hermesArchivedCountTask?.cancel()
        hermesArchivedCountTask = Task { [weak self] in
            await self?.readHermesArchivedCount(wire, readSerial: serial)
        }
    }

    private func readHermesArchivedCount(_ wire: any BotTransport, readSerial serial: Int) async {
        guard let profile = hermesProfile,
              let count = try? await wire.archivedSessionCount(profile: profile), !Task.isCancelled,
              serial == hermesReadSerial, hermesWire === wire, hermesProfile == profile, !hermesShowsAllProfiles,
              count != archivedCount else { return }
        archivedCount = count
    }

    private func mutate(
        modelContext: ModelContext? = nil,
        animation: Animation? = nil,
        _ operation: () async throws -> Void
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        do {
            try await operation()
            return await load(modelContext: modelContext, animation: animation)
        } catch {
            guard !error.isCancellation else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

}

private struct HermesUnreadMark: Equatable {
    let id = UUID()
    let unread: Bool
    var settledBefore: Int?
}
