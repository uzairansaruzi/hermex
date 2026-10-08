import Foundation
import Observation
import SwiftData
import SwiftUI

struct SessionListSection: Identifiable {
    enum Kind: String {
        case pinned
        case today
        case yesterday
        case earlier
    }

    let kind: Kind
    let title: String
    let sessions: [SessionSummary]

    var id: String { kind.rawValue }
}

struct ScheduledSessionGroups: Equatable {
    let ordinary: [SessionSummary]
    let scheduled: [SessionSummary]
    let totalScheduledCount: Int

    /// Splits the visible rows in one pass, keeping their order: cron rows go
    /// to `scheduled` unless archived, everything else to `ordinary`.
    init(partitioning visible: [SessionSummary], totalScheduledCount: Int) {
        var ordinary: [SessionSummary] = []
        var scheduled: [SessionSummary] = []
        for session in visible {
            if session.isCronSession {
                if session.archived != true { scheduled.append(session) }
            } else {
                ordinary.append(session)
            }
        }
        self.ordinary = ordinary
        self.scheduled = scheduled
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

/// Where a Hermes server's session list (#1046) reads from: the server's saved connection, the
/// Profile it opens on, and its client on the connection's shared socket.
struct HermesSessionListSource {
    let connection: BotConnection
    /// The Profile the list opens on; nil takes the server's pick, or the host's `current`, once
    /// the socket is up (the Hermes home's list, #709).
    let profile: String?
    /// Each open's client; tests script it.
    var makeWire: @MainActor (BotConnection) -> any BotTransport
    var preferences: UserDefaults = .standard
    /// The quiet time after the last `sessions.changed` before the list reads again.
    var changeDebounce: Duration = .seconds(1)
    /// The gap between live-state re-reads while a row is busy: `sessions.changed` can miss a
    /// turn's end, since post-turn work writes nothing.
    var statusPollInterval: Duration = .seconds(5)
    /// Waits before each reconnect after a lost socket; the last one repeats.
    var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
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
    private(set) var isViewingCachedData = false
    private(set) var projects: [ProjectSummary] = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var cacheErrorMessage: String?
    private(set) var searchErrorMessage: String?
    private(set) var isSearchingRemoteSessions = false
    private(set) var sessionLoadError: Error?
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
    /// Total archived sessions reported by the last successful list load
    /// (`archived_count`, issue #17). nil until a load succeeds or when an older
    /// server omits the field — the Archived entry stays hidden then.
    private(set) var archivedCount: Int?

    /// Attention state per streaming session, refreshed on the same tick that
    /// already checks stream liveness. Only sessions with an active stream ever
    /// have an entry, and the map is reassigned only when a value actually
    /// changes so rows do not invalidate on every poll tick.
    private(set) var attentionStatesBySessionID: [String: SessionRowAttentionState] = [:]
    private(set) var seenMessageTimes: [String: Double]

    private(set) var remoteContentSearchSessionIDs: [String] = []
    /// `match_preview` per content-matched session from the last search, so a
    /// row can show why it matched. Empty against servers that omit the field.
    private(set) var remoteContentSearchExcerpts: [String: String] = [:]
    private var activeRemoteSearchQuery: String?
    private var sessionOpenGeneration = 0
    /// The external session the live `sessionForOpening` is still importing, so
    /// Next and Previous Chat step past it before navigation lands. Nil once
    /// that open finishes or a newer open or navigation invalidates it.
    private(set) var openingSessionID: String?
    private var activeProfileGeneration = 0

    private let client: APIClient
    private let sessionMutator: SessionMutator
    private let server: URL
    private let unreadStore: SessionUnreadStore
    private var viewingSessionID: String?
    private var returnedFromSessionIDs: Set<String> = []
    private var firstReturnLoad: (revision: Int, sessionIDs: Set<String>)?
    private var returnRevision = 0
    private var activeLoadCount = 0

    // MARK: Hermes state (#1046)

    /// Set when this list shows a Hermes server's sessions; nil on webui.
    private let hermes: HermesSessionListSource?
    /// The Profile a Hermes list shows, and the one New Session opens in while it shows every
    /// Profile's sessions.
    private(set) var hermesProfile: String?
    /// The list shows every Profile's sessions, merged (#709).
    private(set) var hermesShowsAllProfiles = false
    /// The Hermes host's Profiles, for the Profile menu; empty until `profiles.list` answers.
    private(set) var hermesProfiles: [String] = []
    /// The host's reason for refusing the last Hermes rename, shown in the rename sheet (#1048).
    private(set) var renameErrorMessage: String?
    /// More of the Profile's sessions wait on the host.
    private(set) var hasMoreSessions = false
    private(set) var isLoadingMoreSessions = false
    /// Read marks this phone wrote and shows ahead of the host's, by session id.
    private var hermesUnreadMarks: [String: HermesUnreadMark] = [:]
    /// Each session's latest read-mark write, which its next one waits for.
    @ObservationIgnored private var hermesUnreadWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var hermesWire: (any BotTransport)?
    /// False while a chat covers the list: `sessions.changed` is ignored and live states rest.
    @ObservationIgnored private var hermesIsListening = false
    @ObservationIgnored private var hermesPages = HermesProfilePages()
    /// Bumped by each list read, so only the newest one applies.
    @ObservationIgnored private var hermesReadSerial = 0
    /// Bumped by each project-lane read: a create, rename or delete reads the lanes under the
    /// list read's serial, so an older lane read could otherwise answer last and apply.
    @ObservationIgnored private var hermesProjectsSerial = 0
    @ObservationIgnored private var hermesStatusSerial = 0
    @ObservationIgnored private var hermesReloadTask: Task<Void, Never>?
    @ObservationIgnored private var hermesReloadWanted = false
    @ObservationIgnored private var hermesDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var hermesStatusTask: Task<Void, Never>?
    @ObservationIgnored private var hermesReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var hermesReconnectAttempts = 0
    /// False once the host answered `session.active_list` "method not found".
    @ObservationIgnored private var hermesReadsStatus = true
    /// A live-state read failed while a row was busy, so re-reads go on until one succeeds.
    @ObservationIgnored private var hermesRetriesStatus = false
    /// Sessions a chat opened from this list has just closed.
    @ObservationIgnored private var hermesReturnedFrom: Set<String> = []
    /// The project lane that claims each listed session, by session id, from the last
    /// `projects.tree` (#1052).
    @ObservationIgnored private var hermesProjectOwners: [String: String] = [:]
    /// The Profile's lanes were read once, so a read shows "Loading projects..." only before that.
    @ObservationIgnored private var hermesProjectsRead = false
    /// The host's reason for refusing the open project sheet's create or rename (#1052).
    private(set) var projectSheetErrorMessage: String?
    /// The host's matches for the active search on a Hermes list (#1053), in its order, as it
    /// answered but for the deletes, archives, restores and renames this phone made since, each
    /// with the Profile searched.
    @ObservationIgnored private var hermesSearchResults: [(profile: String, row: HermesSessionRow)] = []
    /// Bumped by each write the host confirmed, so a search out meanwhile, whose answer may
    /// predate it, asks again rather than undo it on the matches.
    @ObservationIgnored private var hermesSearchWrites = 0
    /// `hermesSearchResults` as rows built from the results' own fields; a loaded row shows in
    /// its place.
    private var hermesSearchRows: [SessionSummary] = []
    /// Each content match's snippet, its `>>>`/`<<<` marks and all, by row identity.
    private var hermesSearchSnippets: [String: String] = [:]
    /// A Hermes search that ran before the list's socket was attached, as one a list opened
    /// searching starts or one run while it showed cached rows, or one whose matches went stale
    /// when the socket closed or the user pulled to refresh; the list's next connect or refresh
    /// runs it.
    @ObservationIgnored private var hermesSearchAwaitsConnect = false
    /// The offline cache the list's pages are written to and read back from while its host
    /// can't be reached (#1054), from the screen's `openHermes(modelContext:)`.
    @ObservationIgnored private var hermesCache: ModelContext?

    /// `hermes` makes this a Hermes server's list; nothing then reaches the webui API.
    init(server: URL, client: APIClient? = nil, unreadStore: SessionUnreadStore = SessionUnreadStore(),
         hermes: HermesSessionListSource? = nil) {
        self.server = server
        self.unreadStore = unreadStore
        self.hermes = hermes
        hermesProfile = hermes?.profile
        hermesShowsAllProfiles = hermes.map { HermesProfilePreference.showsAllProfiles(for: server, in: $0.preferences) } ?? false
        // A Hermes list loads as soon as it appears, so it starts on the skeleton.
        isLoading = hermes != nil
        seenMessageTimes = unreadStore.load(for: server)
        let resolvedClient = client ?? APIClient(baseURL: server)
        self.client = resolvedClient
        self.sessionMutator = SessionMutator(client: resolvedClient)

        // Sweep exports leaked by a previous app run (view dismissed while a
        // download was in flight, so the share sheet — and its on-dismiss
        // cleanup — never appeared). `State(initialValue:)` re-runs this init
        // on every parent redraw, so the sweep must be once-per-process (the
        // lazy static below), or it would delete a file an active share sheet
        // is presenting. The first-ever init always precedes the first export,
        // so the single sweep can never race an in-flight export.
        _ = Self.sweepLeakedExportsOnce
    }

    /// Root temp directory holding one UUID subdirectory per export
    /// (see `export(_:format:)`).
    nonisolated static var exportsRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-exports", isDirectory: true)
    }

    /// Lazy static ⇒ runs exactly once per process, on first access.
    nonisolated private static let sweepLeakedExportsOnce: Void = {
        try? FileManager.default.removeItem(at: exportsRootDirectory)
    }()

    var sections: [SessionListSection] {
        let sortedSessions = sessions.sorted { left, right in
            timestamp(for: left) > timestamp(for: right)
        }
        let pinned = sortedSessions.filter { $0.pinned == true }
        let unpinned = sortedSessions.filter { $0.pinned != true }

        let calendar = Calendar.current
        let today = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInToday(date)
        }
        let yesterday = unpinned.filter { session in
            guard let date = date(for: session) else { return false }
            return calendar.isDateInYesterday(date)
        }
        let earlier = unpinned.filter { session in
            guard let date = date(for: session) else { return true }
            return !calendar.isDateInToday(date) && !calendar.isDateInYesterday(date)
        }

        return [
            SessionListSection(kind: .pinned, title: String(localized: "Pinned"), sessions: pinned),
            SessionListSection(kind: .today, title: String(localized: "Today"), sessions: today),
            SessionListSection(kind: .yesterday, title: String(localized: "Yesterday"), sessions: yesterday),
            SessionListSection(kind: .earlier, title: String(localized: "Earlier"), sessions: earlier)
        ]
        .filter { !$0.sessions.isEmpty }
    }

    /// The rows the list shows for this search, project filter, and automated
    /// visibility: local matches sorted, then loaded remote content matches.
    func visibleSessions(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> [SessionSummary] {
        visibleSessions(
            among: sessions,
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedVisibility
        )
    }

    /// The visible rows that are still streaming, for the list's active-row
    /// monitor. Filters to streaming rows first (usually zero to two), so a
    /// body pass does not filter and sort every session to find them.
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

    /// Visibility is decided per row, so running this over a subset of
    /// `sessions` yields exactly the visible rows of that subset. A Hermes search
    /// also brings the host's matches the loaded pages lack (#1053).
    private func visibleSessions(
        among candidates: [SessionSummary],
        searchText rawSearchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility
    ) -> [SessionSummary] {
        let query = Self.normalizedSearchQuery(rawSearchText)
        // Every word must appear somewhere in the row, in any order and field.
        let searchTerms = query.split(whereSeparator: \.isWhitespace)
        let baseSessions = candidates.filter { automatedVisibility.shows($0) }
        let projectFilteredSessions = baseSessions.filter { session in
            guard let selectedProjectID else { return true }
            return session.projectId == selectedProjectID
        }
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

    func scheduledSessionGroups(
        searchText: String,
        selectedProjectID: String?,
        automatedVisibility: AutomatedSessionVisibility = .showAll
    ) -> ScheduledSessionGroups {
        ScheduledSessionGroups(
            partitioning: visibleSessions(
                searchText: searchText,
                selectedProjectID: selectedProjectID,
                automatedVisibility: automatedVisibility
            ),
            totalScheduledCount: automatedVisibility.showsCron
                ? sessions.filter { $0.isCronSession && $0.archived != true }.count
                : 0
        )
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil, animation: Animation? = nil) async -> Bool {
        // Overlapping requests for the same return share its mark. A later
        // return starts a new window, even if the prior load is still in flight.
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
            guard !isCancellationError(error) else { return false }
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
                        // Cached rows carry no live server state, so nothing can
                        // still be waiting on the user here.
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
            guard !Task.isCancelled, !isCancellationError(error),
                  generation == activeProfileGeneration else { return }

            activeProfileErrorMessage = error.localizedDescription
        }
    }

    /// Adopts Settings' confirmed switch synchronously, before New Chat can run.
    /// Earlier profile reads must not replace this newer server-confirmed selection.
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
            // The switch response has no `single_profile_mode` field; carry the
            // last known value forward so the switcher visibility doesn't flap.
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
            guard !isCancellationError(error) else { return false }

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
        // A Hermes list keeps showing its matches while the same search runs again, as when a
        // chat opened from them closes, until the host's new answer replaces them.
        let repeatsHermesSearch = hermes != nil && activeRemoteSearchQuery == query
        activeRemoteSearchQuery = query
        remoteContentSearchSessionIDs = []
        remoteContentSearchExcerpts = [:]
        if !repeatsHermesSearch { clearHermesSearchMatches() }
        searchErrorMessage = nil

        guard !query.isEmpty, !isViewingCachedData else {
            isSearchingRemoteSessions = false
            // A Hermes list showing cached rows asks the host once a read replaces them.
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
            guard !isCancellationError(error) else { return }
            if hermes != nil, error as? BotFailure == .stale { hermesSearchAwaitsConnect = true; return }

            remoteContentSearchSessionIDs = []
            remoteContentSearchExcerpts = [:]
            searchErrorMessage = error.localizedDescription
            lastError = error
        }
    }

    /// The excerpt to show under a row, paired with the query that produced it.
    /// nil when the row did not match on content, when the search was cleared,
    /// or when the server is older than `match_preview`.
    ///
    /// `searchText` is the query of the *screen* asking, not the view model's:
    /// screens with their own search field (Scheduled sessions) share this view
    /// model, and they must not inherit the sidebar's last excerpts. Same guard
    /// `visibleSessions(searchText:selectedProjectID:)` applies to remote rows.
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
                guard !isCancellationError(error) else { return .unchanged }
                if case APIError.unauthorized = error {
                    lastError = error
                    return .failed
                }
                continue
            }
        }

        return await refreshAttentionStates()
    }

    /// The attention state a row should show, or nil while nothing is pending.
    func attentionState(for session: SessionSummary) -> SessionRowAttentionState? {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return nil }
        return attentionStatesBySessionID[sessionID]
    }

    /// A settled row is unread only when its server timestamp moved past the
    /// last timestamp this device showed. No phone clock enters the comparison.
    /// A Hermes row is unread when the host says so, or this phone just marked it.
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

    /// Not on a Bot Chat a Hermes search lists (#1053): the Bots inbox keeps its own read mark.
    func canToggleUnread(_ session: SessionSummary) -> Bool {
        if let hermes = session.hermes { return !hermes.isBotChat && Self.nonEmpty(session.sessionId) != nil }
        return Self.nonEmpty(session.sessionId) != nil
            && Self.messageTime(for: session) != nil
            && !SessionRowView.isActiveStreaming(session)
            && session.hasPendingUserMessage != true
    }

    /// Every chat entry point selects a destination, so this one stamp covers
    /// rows, deep links, push, App Intents and Live Activity navigation.
    /// A Hermes row is marked read on the host, so Desktop agrees.
    func beginViewing(_ session: SessionSummary) {
        if session.hermes != nil { return setHermesUnread(false, session) }
        viewingSessionID = Self.nonEmpty(session.sessionId)
        markSeen(session)
    }

    /// The next list load after a chat closes stamps its freshest server
    /// timestamp if it succeeds, including a reply completed during that visit.
    func noteReturn(from session: SessionSummary) {
        guard let sessionID = Self.nonEmpty(session.sessionId) else { return }
        if viewingSessionID == sessionID { viewingSessionID = nil }
        returnedFromSessionIDs.insert(sessionID)
        returnRevision &+= 1
    }

    func toggleUnread(_ session: SessionSummary) {
        if session.hermes != nil { return setHermesUnread(!isUnread(session), session) }
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

    /// One approval probe and one clarification probe per streaming row, on the
    /// tick the caller already runs. Sessions without an active stream are never
    /// probed, and there is no separate polling loop or timer. A row's two
    /// probes go out together, so N streaming rows cost about N round trips per
    /// tick instead of 2N.
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

            // A failed probe is not evidence that nothing is pending, so it
            // keeps what the last successful tick knew rather than letting the
            // row fall back to "Working". The rule is deliberately simple: a
            // previous `.approval` masks any clarification, so it carries no
            // clarify knowledge, and a clarify probe that fails behind it
            // resolves to nothing pending.
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
                guard !isCancellationError(error) else { return .unchanged }
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

    /// Attention state only means something for a row the server still reports
    /// as streaming, so a reload that ends a stream drops that row's entry.
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

    /// Imports external sessions before navigation, matching hermes-webui's
    /// `_openSidebarSession`. A newer tap invalidates any older response so a
    /// slow import cannot replace the user's current destination.
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
                  !isCancellationError(importError)
            else {
                return nil
            }

            // WebUI treats import as a refresh: if it fails, an already imported
            // session may still be available through the canonical detail route.
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
                      !isCancellationError(error)
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

    /// Undoes an archive from the list: restores the session, then reloads so
    /// its row returns to its old place (the server keeps `updated_at`). A second
    /// call while one is in flight for the same session sends nothing.
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
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to rename a session.")
            return false
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let title = Self.nonEmpty(rawTitle) else {
            actionErrorMessage = String(localized: "Enter a session title.")
            return false
        }

        if session.hermes != nil { return await renameHermesSession(session, to: title) }
        isRenamingSession = true
        actionErrorMessage = nil
        lastError = nil
        defer { isRenamingSession = false }

        do {
            let response = try await sessionMutator.rename(sessionID: sessionId, title: title)
            if let error = Self.nonEmpty(response.error) {
                actionErrorMessage = error
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
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
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

    /// Downloads the session transcript (`GET /api/session/export`, or a Hermes host's
    /// `GET /api/sessions/{id}/export`, JSON only, #1048) and writes it to a unique temp
    /// directory so the share sheet can offer it as a file with a real filename. Returns the
    /// file URL, or nil after surfacing the failure through the standard action-error alert.
    /// The caller owns cleanup of the returned file's parent directory after sharing.
    func export(_ session: SessionSummary, format: SessionExportFormat) async -> URL? {
        guard !isViewingCachedData else {
            actionErrorMessage = String(localized: "Reconnect to the server to export a session.")
            return nil
        }

        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        // Reuses the per-session mutation gate: it disables the row's other
        // actions while the download runs (the "progress state") and blocks a
        // double-tap from firing two exports.
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
            guard !isCancellationError(error) else { return nil }

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
            guard !isCancellationError(error) else { return }

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
        actionErrorMessage = nil
        lastError = nil

        guard let sessionId = session.sessionId else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
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
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            try await sessionMutator.move(sessionID: sessionId, to: projectID)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a new project without moving any session into it.
    ///
    /// Mirrors ``createProject(named:color:moving:modelContext:)`` but skips the
    /// `sessionMutator.move(...)` step, so the Projects sidebar's standalone
    /// "Add project" button can make an empty, unassigned project.
    func createEmptyProject(
        named rawName: String,
        color: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }

        isCreatingProject = true
        defer { isCreatingProject = false }

        do {
            let createResponse = try await client.createProject(name: name, color: color)
            guard let project = createResponse.project else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project.")
                return false
            }

            guard let projectID = project.projectId, !projectID.isEmpty else {
                actionErrorMessage = createResponse.error ?? String(localized: "The server did not return the new project ID.")
                return false
            }

            upsertProject(project)
            await load(modelContext: modelContext)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
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
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ project: ProjectSummary, named rawName: String, color: String?) async -> Bool {
        actionErrorMessage = nil
        lastError = nil

        guard let projectID = project.projectId, !projectID.isEmpty else {
            actionErrorMessage = String(localized: "The server did not provide a project ID.")
            return false
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionErrorMessage = String(localized: "Enter a project name.")
            return false
        }
        if project.hermes != nil { return await renameHermesProject(projectID, named: name, color: color) }

        isRenamingProject = true
        defer { isRenamingProject = false }

        do {
            let response = try await client.renameProject(id: projectID, name: name, color: color)
            guard let renamedProject = response.project else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project.")
                return false
            }

            guard renamedProject.projectId?.isEmpty == false else {
                actionErrorMessage = response.error ?? String(localized: "The server did not return the renamed project ID.")
                return false
            }

            upsertProject(renamedProject)
            return true
        } catch {
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a session in the explicit App Intent profile or the sidebar's selected
    /// profile. The server supplies that profile's model and last workspace. With
    /// neither profile known, preserve the cookie-scoped workspace lookup. In-app New
    /// Chat passes the project filter the user tapped under as `projectID` (#875).
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
            guard !isCancellationError(error) else { return nil }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Drops any empty Untitled placeholders still held in memory. Used when
    /// returning from the pending new-chat flow so stale rows cannot flash during
    /// the navigation pop animation.
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

    /// Lowercased fields joined by spaces. Search terms hold no spaces, so a
    /// term found here always sits inside a single field.
    private static func searchableText(for session: SessionSummary) -> String {
        [
            session.title,
            // An untitled Hermes row shows its first prompt, so that is what its words are.
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

    /// `archivedCount` is applied inside the same transaction as the rows so the
    /// bottom Archived entry inserts/removes with the list mutation animation.
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

    /// Content-match rows narrowed to sessions the list can actually show, in
    /// server order, plus each row's excerpt when the server sent one.
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

    private func timestamp(for session: SessionSummary) -> Double {
        Self.timestamp(for: session)
    }

    private func date(for session: SessionSummary) -> Date? {
        let value = timestamp(for: session)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
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

        // Tolerant: only a present field moves the flag, so an older server
        // (or the carried-forward switch-response value) keeps today's behavior.
        if let singleProfileMode = response.singleProfileMode {
            isSingleProfileMode = singleProfileMode
        }

        // Keep the App Intents profile cache fresh so the "New Chat in <Profile>" picker
        // (#339) stays populated when the Shortcuts app resolves it in the background, where
        // a live, authenticated fetch may not be possible, then nudge the system to (re-)index
        // the parameterized App Shortcut (iOS only indexes it once its suggested values exist).
        // A nil `profiles` (field absent/undecoded) is left untouched — tolerant decoding — but
        // an explicit empty list is forwarded so `save([])` can clear a stale picker if the
        // server ever reports none.
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

    // MARK: - Hermes (#1046)

    /// The Hermes list holds a client on the socket: it is open, or a chat covers it.
    var isHermesConnected: Bool { hermesWire != nil }

    /// Shows the Hermes Profile's list and keeps it current while it is on screen: connects
    /// to the shared socket, names the Profile so the host watches its store, reads the list
    /// and its live states, and reloads on `sessions.changed`. A list a chat covered keeps its
    /// socket and only reads again. Also the pull-to-refresh and foreground path. Each page
    /// read goes to `modelContext`, the offline cache, which the list shows, read-only, while
    /// the host can't be reached (#1054); the list keeps it for the reads it makes on its own.
    func openHermes(modelContext: ModelContext? = nil) async {
        guard let hermes else { return }
        if let modelContext { hermesCache = modelContext }
        hermesIsListening = true
        let followed = followSavedHermesProfile()
        if let wire = hermesWire {
            // A list of every Profile reads today's names before its pages, and names a new one
            // on the socket.
            let listed = hermesProfiles
            if hermesShowsAllProfiles { await readHermesProfiles(wire) }
            if followed || hermesProfiles != listed { _ = await watchHermesProfile(wire) }
            await reloadHermes()
            await runAwaitedHermesSearch()
            if !hermesShowsAllProfiles { await readHermesProfiles(wire) }
            return
        }
        let wire = hermes.makeWire(hermes.connection)
        hermesWire = wire
        hermesReadsStatus = true
        if sessions.isEmpty { isLoading = true }
        wire.onEvent = { [weak self, weak wire] event in
            guard let self, let wire, self.hermesWire === wire, self.hermesIsListening,
                  event["type"].text == "sessions.changed" else { return }
            self.noteHermesChange()
        }
        wire.onDisconnect = { [weak self, weak wire] error in
            guard let self, let wire, self.hermesWire === wire else { return }
            self.dropHermes(error)
        }
        do {
            try await wire.connect()
            guard hermesWire === wire else { return }
            hermesReconnectAttempts = 0
            if hermesProfile == nil || hermesShowsAllProfiles { await readHermesProfiles(wire) }
            if hermesProfile == nil { await resolveHermesProfile(wire) }
            guard hermesWire === wire else { return }
            if await watchHermesProfile(wire) { _ = await moveOffRemovedHermesProfile(wire) }
            guard hermesWire === wire else { return }
            await reloadHermes()
            await runAwaitedHermesSearch()
            await readHermesProfiles(wire)
        } catch {
            guard hermesWire === wire else { return }
            // The screen left while connecting: the next open starts a fresh client.
            if Task.isCancelled { wire.close(); hermesWire = nil; isLoading = false; return }
            showCachedHermesSessions(after: error)
            dropHermes(error)
        }
    }

    /// A chat now covers the list: events wait until it returns. The socket stays, so a read
    /// mark written as the chat opened still reaches the host.
    func pauseHermes() {
        hermesIsListening = false
        hermesDebounceTask?.cancel(); hermesDebounceTask = nil
        hermesStatusTask?.cancel(); hermesStatusTask = nil
    }

    /// The list left the screen for good, or the app went to the background.
    func closeHermes() {
        pauseHermes()
        hermesReconnectTask?.cancel(); hermesReconnectTask = nil
        hermesReloadTask?.cancel(); hermesReloadTask = nil; hermesReloadWanted = false
        hermesReadSerial += 1
        isLoading = false; isLoadingMoreSessions = false
        hermesWire?.close(); hermesWire = nil
        // Matches past the loaded pages change only when the host is searched again.
        if activeRemoteSearchQuery?.isEmpty == false { hermesSearchAwaitsConnect = true }
    }

    /// Pull to refresh: the list reads again, and so does the active search, whose matches
    /// past the loaded pages (one another device deleted, say) change only when it runs again.
    func refreshHermes(modelContext: ModelContext? = nil) async {
        if activeRemoteSearchQuery?.isEmpty == false { hermesSearchAwaitsConnect = true }
        await openHermes(modelContext: modelContext)
    }

    /// Shows `profile`'s sessions, and remembers it as the server's pick, which the composer's
    /// Profile chip and the next New Session share (#1015). It is never written to the host.
    func selectHermesProfile(_ profile: String) async {
        guard let hermes, profile != hermesProfile || hermesShowsAllProfiles else { return }
        HermesProfilePreference.save(profile, for: server, in: hermes.preferences)
        HermesProfilePreference.saveShowsAllProfiles(false, for: server, in: hermes.preferences)
        hermesShowsAllProfiles = false
        await showHermesProfile(profile)
    }

    /// Shows every Profile's sessions, merged, and remembers that for the server (#709). The
    /// pick stays the Profile New Session opens in.
    func showAllHermesProfiles() async {
        guard let hermes, !hermesShowsAllProfiles, let profile = hermesProfile else { return }
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: hermes.preferences)
        hermesShowsAllProfiles = true
        await showHermesProfile(profile)
    }

    /// The Profiles the list reads: every one the host lists while it shows them all, else the
    /// picked one.
    private var hermesListedProfiles: [String] {
        guard let hermesProfile else { return [] }
        return hermesShowsAllProfiles && !hermesProfiles.isEmpty ? hermesProfiles : [hermesProfile]
    }

    /// Reads the next page, one at a time: of every listed Profile with more, so a merged list
    /// shows the rows it held back. A list read that begins meanwhile replaces it and reads that
    /// page itself, so the flag stays up until that read ends.
    func loadMoreHermesSessions() async {
        guard hasMoreSessions, !isLoadingMoreSessions, let wire = hermesWire else { return }
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

    /// A chat opened from this list closed on `key`. The next list read marks it read again
    /// when the host says it is unread: a reply that finished while it was open was seen.
    func noteHermesReturn(from key: String) {
        hermesReturnedFrom.insert(key)
        if hermesIsListening { requestHermesReload() }
    }

    /// Reads as many pages of each listed Profile as the list holds, plus the page a "Load more"
    /// it replaces was reading, and applies them only if no newer read began; then the Profile's
    /// project lanes, which a list of every Profile has none of.
    private func reloadHermes() async {
        guard let wire = hermesWire, hermesProfile != nil else { return }
        hermesReadSerial += 1
        let serial = hermesReadSerial
        let pageSize = HermesREST.sessionPageSize
        var holdsPaging = true
        defer {
            if holdsPaging, serial == hermesReadSerial {
                isLoading = false
                if isLoadingMoreSessions { isLoadingMoreSessions = false }
            }
        }
        var pages = HermesProfilePages()
        do {
            for profile in hermesListedProfiles {
                let wanted = max(hermesPages[profile].nextOffset + (isLoadingMoreSessions ? pageSize : 0), pageSize)
                while pages[profile].hasMore, pages[profile].nextOffset < wanted {
                    let page = try await wire.sessionPage(profile: profile, offset: pages[profile].nextOffset, archived: false)
                    guard serial == hermesReadSerial, hermesWire === wire else { return }
                    pages[profile].append(page)
                }
            }
            applyHermes(pages, readSerial: serial)
            // The rows are in, and the lanes, read next, never hold them back. A "Load more"
            // that starts meanwhile owns the paging flag, so this read lets go of it once.
            holdsPaging = false
            isLoading = false
            if isLoadingMoreSessions { isLoadingMoreSessions = false }
            startHermesStatusRead(wire)
            if !hermesShowsAllProfiles { await readHermesProjects(wire, readSerial: serial) }
            await runAwaitedHermesSearch()
        } catch {
            guard serial == hermesReadSerial, hermesWire === wire, !Task.isCancelled else { return }
            // The client left the socket without a word (a call its screen cancelled): reconnect.
            if error as? BotFailure == .stale { return dropHermes(error) }
            if error as? BotFailure == .rejected(404) {
                if hermesShowsAllProfiles {
                    // One of the Profiles went: list the rest.
                    let listed = hermesProfiles
                    await readHermesProfiles(wire)
                    if hermesWire === wire, hermesProfiles != listed { return requestHermesReload() }
                } else if await moveOffRemovedHermesProfile(wire) {
                    return
                }
            }
            if showCachedHermesSessions(after: error) { return }
            showHermesFailure(error)
        }
    }

    private func applyHermes(_ pages: HermesProfilePages, readSerial: Int) {
        hermesPages = pages
        if hasMoreSessions != pages.hasMore { hasMoreSessions = pages.hasMore }
        // A mark the host had already taken when this read began is the host's own now.
        let marks = hermesUnreadMarks.filter { $0.value.settledBefore.map { $0 > readSerial } ?? true }
        if marks.count != hermesUnreadMarks.count { hermesUnreadMarks = marks }
        let rows = hermesRows(pages)
        // By the host's own mark: one this phone wrote as the chat opened came before the reply.
        for row in rows where row.sessionId.map(hermesReturnedFrom.contains) == true && row.hermes?.unread == true {
            setHermesUnread(false, row)
        }
        hermesReturnedFrom = []
        if sessions != rows { sessions = rows }
        if isViewingCachedData { isViewingCachedData = false }
        errorMessage = nil; sessionLoadError = nil
        cacheHermesRows(pages)
    }

    /// Writes each listed Profile's rows read so far to its offline cache, every row it read,
    /// shown or held back, and says when they run from its list's first page to its end.
    private func cacheHermesRows(_ pages: HermesProfilePages) {
        guard let hermesCache else { return }
        do {
            for profile in hermesListedProfiles {
                let rows = pages[profile].rows.map { $0.summary(in: profile, project: hermesProjectOwners[$0.id]) }
                try CacheStore.cacheHermesSessions(rows, profile: profile, reachedEnd: !pages[profile].hasMore,
                                                   serverURL: server, in: hermesCache)
            }
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    /// A list read that failed because the host can't be reached shows the Profile's cached
    /// rows instead, or every Profile's while it lists them all, read-only (`isViewingCachedData`), until a read succeeds. Search then reads
    /// only them, so the host's matches go, and the active search asks the host again once a
    /// read succeeds. False when it can't: another failure, or nothing cached.
    @discardableResult
    private func showCachedHermesSessions(after error: Error) -> Bool {
        guard CacheFallbackPolicy.shouldUseCache(for: error), let hermes, let hermesCache else { return false }
        // A list that never reached the host to settle its Profile reads the server's pick.
        let picked = hermesProfile ?? hermes.preferences.string(forKey: HermesProfilePreference.key(for: server))
        guard hermesShowsAllProfiles || picked != nil else { return false }
        let cached: [SessionSummary]
        do {
            cached = try CacheStore.cachedHermesSessions(serverURL: server, profile: hermesShowsAllProfiles ? nil : picked,
                                                         in: hermesCache)
        } catch {
            cacheErrorMessage = error.localizedDescription
            return false
        }
        guard !cached.isEmpty else { return false }
        // The pick is the Profile the rows open in and New Session uses; the host checks it on connect.
        if hermesProfile == nil { hermesProfile = picked }
        if sessions != cached { sessions = cached }
        hasMoreSessions = false
        isViewingCachedData = true
        errorMessage = nil; sessionLoadError = nil
        setHermesStates([:])
        clearHermesSearchMatches()
        if activeRemoteSearchQuery?.isEmpty == false { hermesSearchAwaitsConnect = true }
        return true
    }

    /// Drops a session this phone deleted or archived from its Profile's offline cache.
    private func forgetCachedHermesSession(_ session: SessionSummary) {
        guard let hermesCache, let root = session.hermes?.lineageRoot, let profile = Self.nonEmpty(session.profile) else { return }
        do {
            try CacheStore.removeHermesSession(lineageRoot: root, profile: profile, serverURL: server, in: hermesCache)
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    /// The rows `pages` show, each in its Profile and the project lane that claims it.
    private func hermesRows(_ pages: HermesProfilePages) -> [SessionSummary] {
        pages.rows.map { $0.row.summary(in: $0.profile, project: hermesProjectOwners[$0.row.id]) }
    }

    private func showHermesFailure(_ error: Error) {
        guard let hermes else { return }
        isLoading = false
        sessionLoadError = error
        errorMessage = BotConnectionAdvice.message(for: error, address: hermes.connection.address)
    }

    /// Shows the host's mark as `unread` at once and writes it once the session's earlier write
    /// has landed, so the host takes them in the order they were made; a refused or lost write
    /// shows the host's again. A later write to the same session replaces this one's outcome.
    private func setHermesUnread(_ unread: Bool, _ session: SessionSummary) {
        guard let wire = hermesWire, let key = Self.nonEmpty(session.sessionId),
              let profile = Self.nonEmpty(session.profile) ?? hermesProfile else { return }
        let mark = HermesUnreadMark(unread: unread)
        hermesUnreadMarks[key] = mark
        let earlier = hermesUnreadWrites[key]
        hermesUnreadWrites[key] = Task { [weak self] in
            await earlier?.value
            let written: Bool
            do { try await wire.updateSession(.unread(unread), key: key, profile: profile); written = true } catch { written = false }
            guard let self, self.hermesUnreadMarks[key]?.id == mark.id else { return }
            if written { self.hermesUnreadMarks[key]?.settledBefore = self.hermesReadSerial + 1 } else { self.hermesUnreadMarks[key] = nil }
        }
    }

    /// Names each listed Profile on the socket, the read the host needs before it watches that
    /// Profile's store; it keeps watching every one named. True when the host no longer has the
    /// picked Profile; any other failure only costs live updates.
    private func watchHermesProfile(_ wire: any BotTransport) async -> Bool {
        var removed = false
        for profile in hermesListedProfiles {
            do { _ = try await wire.call(.sessionMostRecent(profile: profile)) } catch BotFailure.rejected(4064) {
                if profile == hermesProfile { removed = true }
            } catch {}
        }
        return removed
    }

    /// A list opened without a Profile, or showing every Profile while its pick went from the host,
    /// takes the server's pick while the host lists it, else the Profile the host's dashboard runs
    /// (`HermesProfilePreference`, which drops a stale pick).
    private func resolveHermesProfile(_ wire: any BotTransport) async {
        guard let hermes else { return }
        let current = (try? await wire.currentProfile()) ?? "default"
        guard hermesWire === wire else { return }
        hermesProfile = HermesProfilePreference.resolve(for: server, listed: hermesProfiles, current: current, in: hermes.preferences)
    }

    /// The listed Profile is gone from the host: the list moves to the server's pick or, once
    /// that is gone too, the Profile the host's dashboard runs (`HermesProfilePreference`).
    /// False when there is nowhere else to go.
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
        hermesReadSerial += 1
        sessions = []; hasMoreSessions = false; isLoadingMoreSessions = false; isViewingCachedData = false
        hermesUnreadMarks = [:]; hermesReturnedFrom = []
        projects = []; hermesProjectOwners = [:]; hermesProjectsRead = false
        clearHermesSearchMatches()
        errorMessage = nil; sessionLoadError = nil
        setHermesStates([:])
        guard let wire = hermesWire else { return await openHermes() }
        isLoading = true
        if hermesShowsAllProfiles && hermesProfiles.isEmpty { await readHermesProfiles(wire) }
        _ = await watchHermesProfile(wire)
        await reloadHermes()
    }

    /// Follows a Profile picked elsewhere since the list last read, such as on the composer's
    /// chip. True when the list moved.
    private func followSavedHermesProfile() -> Bool {
        guard let hermes, let saved = hermes.preferences.string(forKey: HermesProfilePreference.key(for: server)),
              saved != hermesProfile, hermesProfiles.contains(saved) else { return false }
        hermesProfile = saved
        // Every Profile is listed already; the pick only names the one New Session opens in.
        guard !hermesShowsAllProfiles else { return false }
        hermesPages = HermesProfilePages()
        sessions = []; hasMoreSessions = false; isViewingCachedData = false
        hermesUnreadMarks = [:]; hermesReturnedFrom = []
        projects = []; hermesProjectOwners = [:]; hermesProjectsRead = false
        clearHermesSearchMatches()
        setHermesStates([:])
        isLoading = true
        return true
    }

    private func readHermesProfiles(_ wire: any BotTransport) async {
        guard let reply = try? await wire.call(.profilesList(includeSessions: false)), hermesWire === wire,
              let rows = reply["profiles"].list else { return }
        let names = rows.compactMap { $0["name"].text }.filter { !$0.isEmpty }
        if names != hermesProfiles { hermesProfiles = names }
        // A list of every Profile names only those the host still has, so a pick removed elsewhere
        // shows up here rather than as a refused watch.
        if hermesShowsAllProfiles, let pick = hermesProfile, !names.isEmpty, !names.contains(pick) {
            await resolveHermesProfile(wire)
        }
    }

    /// A lost socket: the rows stay, live states clear, and the list reconnects on the inbox's
    /// backoff while it is on screen. A refusal the user has to act on
    /// (`BotConnectionAdvice.isRetryable`) stops there and is kept as the list's error, which
    /// shows once no rows do; pull to refresh tries again.
    private func dropHermes(_ error: Error) {
        guard let hermes else { return }
        let listening = hermesIsListening
        closeHermes()
        hermesIsListening = listening
        setHermesStates([:])
        let retries = BotConnectionAdvice.isRetryable(error)
        if sessions.isEmpty || !retries { showHermesFailure(error) }
        guard listening, retries else { return }
        let delay = hermes.reconnectDelays[min(hermesReconnectAttempts, hermes.reconnectDelays.count - 1)]
        hermesReconnectAttempts += 1
        hermesReconnectTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self, self.hermesIsListening else { return }
            self.hermesReconnectTask = nil
            await self.openHermes()
        }
    }

    /// Coalesces a burst of `sessions.changed` into one read after a quiet `changeDebounce`.
    private func noteHermesChange() {
        guard let hermes else { return }
        hermesDebounceTask?.cancel()
        hermesDebounceTask = Task { [weak self] in
            guard (try? await Task.sleep(for: hermes.changeDebounce)) != nil, let self, !Task.isCancelled else { return }
            self.hermesDebounceTask = nil
            self.requestHermesReload()
        }
    }

    /// One list read in flight and at most one more after it, however many ask meanwhile.
    private func requestHermesReload() {
        hermesReloadWanted = true
        guard hermesReloadTask == nil, let wire = hermesWire else { return }
        hermesReloadTask = Task { [weak self] in
            while let self, self.hermesReloadWanted, self.hermesWire === wire, !Task.isCancelled {
                self.hermesReloadWanted = false
                await self.reloadHermes()
            }
            guard let self, self.hermesWire === wire else { return }
            self.hermesReloadTask = nil
        }
    }

    /// Replaces any live-state read in flight with one read, now or after `delay`.
    private func startHermesStatusRead(_ wire: any BotTransport, after delay: Duration? = nil) {
        hermesStatusTask?.cancel(); hermesStatusTask = nil
        guard hermesReadsStatus, hermesIsListening else { return }
        hermesStatusTask = Task { [weak self] in
            if let delay, (try? await Task.sleep(for: delay)) == nil { return }
            guard !Task.isCancelled, let self, self.hermesWire === wire else { return }
            await self.readHermesStatuses(wire)
        }
    }

    /// One `session.active_list`, mapped onto the listed rows by session key. A failed read
    /// shows no states rather than old ones. While a row is busy, or a read failed while one
    /// was, it reads again after `statusPollInterval`; once all are idle it stops.
    private func readHermesStatuses(_ wire: any BotTransport) async {
        guard let hermes else { return }
        hermesStatusSerial += 1
        let serial = hermesStatusSerial
        func current() -> Bool { !Task.isCancelled && hermesWire === wire && serial == hermesStatusSerial }
        do {
            let reply = try await wire.call(.sessionActiveList)
            guard current() else { return }
            let listed = Set(sessions.compactMap(\.sessionId))
            setHermesStates(SessionRowAttentionState.hermesStates(reply["sessions"].list ?? []).filter { listed.contains($0.key) })
            hermesRetriesStatus = false
        } catch {
            guard current() else { return }
            if error as? BotFailure == .rejected(-32601) { hermesReadsStatus = false }
            hermesRetriesStatus = hermesRetriesStatus || !attentionStatesBySessionID.isEmpty
            setHermesStates([:])
        }
        if attentionStatesBySessionID.isEmpty && !hermesRetriesStatus { hermesStatusTask = nil }
        else { startHermesStatusRead(wire, after: hermes.statusPollInterval) }
    }

    /// Writes only a real change, so an unchanged re-read never invalidates the rows.
    private func setHermesStates(_ states: [String: SessionRowAttentionState]) {
        if states != attentionStatesBySessionID { attentionStatesBySessionID = states }
    }

    // MARK: Hermes search (#1053)

    /// One search of each listed Profile for `query`, applied unless a newer search, a Profile
    /// switch or a new client replaced it meanwhile. A write the host confirmed while it was out
    /// may postdate its answer, so it asks again. False when it was replaced.
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
            }
            guard writes == hermesSearchWrites else { continue }
            hermesSearchSnippets = Dictionary(found.compactMap { match in match.result.snippet.map { (match.result.row.identity, $0) } },
                                              uniquingKeysWith: { first, _ in first })
            showHermesSearch(found.map { ($0.profile, $0.result.row) })
            return true
        }
    }

    /// Shows `results` as the search's matches, each in its Profile and the project lane that
    /// now claims it, so the lanes read after the search apply to it too.
    private func showHermesSearch(_ results: [(profile: String, row: HermesSessionRow)]) {
        hermesSearchResults = results
        let rows = results.map { $0.row.summary(in: $0.profile, project: hermesProjectOwners[$0.row.id]) }
        if rows != hermesSearchRows { hermesSearchRows = rows }
    }

    /// Shows a write the host confirmed on the search's matches, which only a new search reads
    /// again: a delete (`nil`) drops the match, and a pin, archive, restore or rename shows on it.
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

    /// Runs the search that found the list's socket not yet attached, or went stale, now that
    /// the list has read again.
    private func runAwaitedHermesSearch() async {
        guard hermesSearchAwaitsConnect, let query = activeRemoteSearchQuery else { return }
        hermesSearchAwaitsConnect = false
        await searchSessions(query: query, debounceNanoseconds: 0)
    }

    /// The host's matches the local filter missed, in the host's order, so a pasted id's
    /// session leads. Each merges with the list by identity, its compression lineage's root: a
    /// loaded row shows as listed, pin and read mark included, and any other from the result.
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

    /// Writes only a real change, so clearing an empty search never invalidates the rows.
    private func clearHermesSearchMatches() {
        hermesSearchResults = []
        hermesSearchAwaitsConnect = false
        if !hermesSearchRows.isEmpty { hermesSearchRows = [] }
        if !hermesSearchSnippets.isEmpty { hermesSearchSnippets = [:] }
    }

    // MARK: Hermes row actions (#1048)

    func clearRenameError() {
        renameErrorMessage = nil
    }

    /// The list's client, the session's key and its Profile, or nil after saying why not.
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

    /// Pins, archives or restores a row: shows the change at once, writes it, and puts the row
    /// back if the host refuses, unless the list moved to another Profile meanwhile. A list read
    /// already out predates the change, so it is dropped, and the list reads again once the host
    /// has answered. When the list's client closed first (`.stale`: the app left, or a screen
    /// was pushed), the write may have landed, so the row stays as shown, unannounced, and the
    /// list's next read shows the host's.
    private func changeHermesSession(_ session: SessionSummary, _ change: HermesSessionChange,
                                     animation: Animation?) async -> Bool {
        guard let target = hermesTarget(session), beginSessionMutation(target.key) else { return false }
        let (wire, key, profile) = target
        let listed = hermesListedProfiles
        defer { endSessionMutation(key) }
        actionErrorMessage = nil
        hermesReadSerial += 1
        var pages = hermesPages
        let before = pages.apply(change, to: key)
        showHermesPages(pages, animation: animation)
        do {
            try await wire.updateSession(change, key: key, profile: profile)
            if change == .archived(true) { forgetCachedHermesSession(session) }
            applyToHermesSearch(change, key: key)
            requestHermesReload()
            return true
        } catch {
            let unknown = error as? BotFailure == .stale
            if !unknown, hermesListedProfiles == listed, let before {
                var pages = hermesPages
                pages[before.profile].restore(before.row, at: before.index)
                showHermesPages(pages, animation: animation)
            }
            requestHermesReload()
            if !unknown, !Task.isCancelled { showHermesActionFailure(error) }
            return false
        }
    }

    /// Deletes a row through `HermesSessionDeletion`, once the host confirms; a busy or held
    /// session stays, and the list says why.
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
            var pages = hermesPages
            pages.remove(key)
            showHermesPages(pages, animation: animation)
            applyToHermesSearch(nil, key: key)
            requestHermesReload()
            return true
        } catch {
            if !Task.isCancelled { showHermesActionFailure(error) }
            return false
        }
    }

    /// Renames a row from the rename sheet. The host cleans the title, and its refusal (a title
    /// in use, too long, or a Bot Chat's) stays in the sheet as `renameErrorMessage`. A rename
    /// whose answer came after the list's client closed (`.stale`) may have landed, so the sheet
    /// stays without a message.
    private func renameHermesSession(_ session: SessionSummary, to title: String) async -> Bool {
        guard let target = hermesTarget(session) else {
            // The sheet is up, so the reason goes there rather than to the list's alert.
            renameErrorMessage = actionErrorMessage
            actionErrorMessage = nil
            return false
        }
        let (wire, key, profile) = target
        isRenamingSession = true
        renameErrorMessage = nil
        actionErrorMessage = nil
        defer { isRenamingSession = false }
        do {
            let kept = try await wire.updateSession(.title(title), key: key, profile: profile)
            let change = HermesSessionChange.title(Self.nonEmpty(kept) ?? title)
            hermesReadSerial += 1
            var pages = hermesPages
            _ = pages.apply(change, to: key)
            showHermesPages(pages, animation: nil)
            applyToHermesSearch(change, key: key)
            requestHermesReload()
            return true
        } catch {
            if !Task.isCancelled, error as? BotFailure != .stale { renameErrorMessage = hermesActionFailure(error) }
            return false
        }
    }

    /// Duplicates a row through `HermesSessionDuplication` and returns the copy as a row to open,
    /// titled after the row as it shows; the list reads again. Nil after saying why.
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

    /// The host's JSON export, named after the row's title. The host has no HTML export.
    private func exportHermesSession(_ session: SessionSummary, key: String,
                                     format: SessionExportFormat) async throws -> SessionExportFile {
        guard format == .json, let wire = hermesWire,
              let profile = Self.nonEmpty(session.profile) ?? hermesProfile else { throw BotFailure.transport }
        let data = try await wire.exportSession(key: key, profile: profile)
        return SessionExportFile(data: data, filename: SessionExportFile.filename(
            contentDisposition: nil, fallbackTitle: SessionRowView.displayTitle(for: session), sessionID: key, format: .json
        ))
    }

    /// Shows `pages` without reading the host: a change this phone made.
    private func showHermesPages(_ pages: HermesProfilePages, animation: Animation?) {
        hermesPages = pages
        let rows = hermesRows(pages)
        guard rows != sessions else { return }
        if let animation { withAnimation(animation) { sessions = rows } } else { sessions = rows }
    }

    private func showHermesActionFailure(_ error: Error) {
        actionErrorMessage = hermesActionFailure(error)
    }

    /// Why a row action failed: the host's own reason, what to check when it can't be reached,
    /// or the connection's state.
    private func hermesActionFailure(_ error: Error) -> String {
        if let refusal = error as? HermesSessionRefusal { return refusal.message }
        if error is URLError, let hermes { return BotConnectionAdvice.message(for: error, address: hermes.connection.address) }
        return error.localizedDescription
    }

    // MARK: Hermes projects (#1052)

    /// Whether the lane `projectID` shows fewer of its sessions than the host named for it, so
    /// later pages hold the rest.
    func hermesLaneIsShort(_ projectID: String) -> Bool {
        guard let claimed = projects.first(where: { $0.projectId == projectID })?.hermes?.claimedCount else { return false }
        return sessions.lazy.filter { $0.projectId == projectID }.count < claimed
    }

    /// Reads pages until the lane `projectID` holds every session the host named for it, or the
    /// list ends. A failed or replaced read stops, and "Load more" tries again.
    func fillHermesLane(_ projectID: String) async {
        guard let profile = hermesProfile else { return }
        while hermesLaneIsShort(projectID), hasMoreSessions, !isLoadingMoreSessions {
            let offset = hermesPages[profile].nextOffset
            await loadMoreHermesSessions()
            guard hermesPages[profile].nextOffset > offset else { return }
        }
    }

    /// The host's folders that complete `word` in the create sheet's folder field; none when it
    /// can't be completed or the host doesn't answer.
    func completeHermesFolder(_ word: String) async -> HermesFolderCompletion.Suggestions {
        guard HermesFolderCompletion.completes(word), let wire = hermesWire, let profile = hermesProfile,
              let reply = try? await wire.call(.completeFolder(word: word, profile: profile)) else { return .init() }
        return HermesFolderCompletion.suggestions(from: reply, typed: word)
    }

    func clearProjectSheetError() {
        projectSheetErrorMessage = nil
    }

    /// Creates a project on one host folder, its primary. Sessions working in that folder join
    /// it, so the lanes are read again. The host's refusal, such as a folder another project
    /// already has, stays in the sheet. Returns the folder it was saved on; nil when it wasn't.
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

    /// Removes the project only: its sessions stay in the list, now in whichever lane claims
    /// their folders. The reply's `active_id` is Desktop's pick and can still name the deleted
    /// project, so it is never read.
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

    /// Move to Project: the host sets the session's working folder to `folder`, where Hermes
    /// works from then on; its files stay where they are. A busy session moves too, mid-turn.
    /// The list reads again, so the row shows in the lane that claims its new folder. Returns
    /// the folder it left, which Undo moves it back to; nil when it didn't move or had none.
    func moveHermesSession(_ session: SessionSummary, toFolder folder: String) async -> String? {
        guard let target = hermesTarget(session), beginSessionMutation(target.key) else { return nil }
        let (wire, key, profile) = target
        let left = (sessions.first { $0.sessionId == key } ?? session).workspace
        defer { endSessionMutation(key) }
        isMovingSession = true
        actionErrorMessage = nil
        defer { isMovingSession = false }
        do {
            _ = try await wire.call(.sessionWorkspaceMove(profile: profile, storedKey: key, cwd: folder))
            requestHermesReload()
            return left.flatMap { $0.isEmpty || $0 == folder ? nil : $0 }
        } catch BotSettingFailure.rejected(4017, _) {
            actionErrorMessage = String(localized: "Hermes can't find the folder \(folder), so the session didn't move.")
            return nil
        } catch {
            // A reply lost with the list's client (`.stale`) may have moved it: the next read shows.
            requestHermesReload()
            if !Task.isCancelled, error as? BotFailure != .stale { showHermesActionFailure(error) }
            return nil
        }
    }

    /// Reads the Profile's project lanes and shows each listed row in the lane that claims it.
    /// Only the latest lane read, under a list read still current, applies; a failed one keeps
    /// the last lanes, which only filter the list.
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
            guard !isCancellationError(error) else { return false }

            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }

}

/// A read mark this phone wrote to a Hermes session (#1046). `settledBefore` is the first list
/// read to begin after the host took it; nil while the write is out.
private struct HermesUnreadMark: Equatable {
    let id = UUID()
    let unread: Bool
    var settledBefore: Int?
}
