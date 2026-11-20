import Foundation
import Observation
import SwiftData

struct HermesArchiveSource {
    let connection: BotConnection
    let profile: String?
    var makeWire: @MainActor (BotConnection) -> any BotTransport
    var preferences: UserDefaults = .standard

    static func saved(_ connection: BotConnection, server: URL, profile: String?) -> Self {
        Self(connection: connection, profile: profile, makeWire: { BotClient(saved: $0, server: server) })
    }
}

@MainActor
@Observable
final class ArchivedSessionsViewModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var unarchivingSessionIDs: Set<String> = []
    private(set) var deletingSessionIDs: Set<String> = []
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private(set) var hermesProfile: String?

    private let server: URL
    private let client: APIClient
    private let hermes: HermesArchiveSource?
    @ObservationIgnored private var wire: (any BotTransport)?
    @ObservationIgnored private var pages = HermesSessionPages(archived: true)
    @ObservationIgnored private var readSerial = 0
    @ObservationIgnored private var pagesRead = 0

    var isUnarchiving: Bool {
        !unarchivingSessionIDs.isEmpty
    }

    var isHermes: Bool { hermes != nil }

    var isConnected: Bool { wire != nil }

    init(server: URL, client: APIClient? = nil, hermes: HermesArchiveSource? = nil) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.hermes = hermes
    }

    func load() async {
        if let hermes { return await loadHermes(hermes) }
        isLoading = true
        errorMessage = nil
        actionErrorMessage = nil
        lastError = nil

        do {
            let response = try await client.sessions(includeArchived: true)
            sessions = (response.sessions ?? []).filter {
                Self.nonEmpty($0.sessionId) != nil && $0.archived == true
            }
        } catch {
            if !error.isCancellation {
                lastError = error
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    func unarchive(_ session: SessionSummary) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId) else {
            actionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }
        guard !isChanging(session) else {
            return false
        }

        if hermes != nil { return await restoreHermes(session, key: sessionId) }

        guard let removedSession = removeSession(withID: sessionId) else {
            return false
        }

        unarchivingSessionIDs.insert(sessionId)
        actionErrorMessage = nil
        lastError = nil
        defer {
            unarchivingSessionIDs.remove(sessionId)
        }

        do {
            let response = try await client.archiveSession(id: sessionId, archived: false)
            if let error = Self.nonEmpty(response.error) {
                restore(removedSession)
                actionErrorMessage = error
                return false
            }
            if response.ok == false {
                restore(removedSession)
                actionErrorMessage = String(localized: "The server could not unarchive this session.")
                return false
            }
            return true
        } catch {
            restore(removedSession)
            if !error.isCancellation {
                lastError = error
                actionErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    func isUnarchiving(_ session: SessionSummary) -> Bool {
        guard let sessionId = session.sessionId else { return false }
        return unarchivingSessionIDs.contains(sessionId)
    }

    func isChanging(_ session: SessionSummary) -> Bool {
        guard let sessionId = session.sessionId else { return false }
        return unarchivingSessionIDs.contains(sessionId) || deletingSessionIDs.contains(sessionId)
    }

    func hermesChat(for session: SessionSummary) -> HermesSessionChat? {
        guard let hermes, let profile = hermesProfile, session.hermes?.isBotChat != true else { return nil }
        return session.hermesChat(on: server, connection: hermes.connection, listedIn: profile)
    }

    func hermesBot(for session: SessionSummary) -> BotDestination? {
        hermes.flatMap { session.hermesBot(on: server, connectionID: $0.connection.id) }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, unarchivingSessionIDs.isEmpty, deletingSessionIDs.isEmpty,
              let wire, let profile = hermesProfile else { return }
        let serial = readSerial
        isLoadingMore = true
        defer { if serial == readSerial { isLoadingMore = false } }
        let shown = pages.rows.count
        do {
            repeat {
                let page = try await wire.sessionPage(profile: profile, offset: self.pages.nextOffset, archived: true)
                guard serial == readSerial else { return }
                var pages = self.pages
                pages.append(page)
                show(pages)
            } while self.pages.rows.count == shown && self.pages.hasMore
        } catch {
            guard serial == readSerial, !error.isCancellation, error as? BotFailure != .stale else { return }
            actionErrorMessage = hermesFailure(error)
        }
    }

    func delete(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> Bool {
        guard let sessionId = Self.nonEmpty(session.sessionId), !isChanging(session) else { return false }
        deletingSessionIDs.insert(sessionId)
        actionErrorMessage = nil
        defer { deletingSessionIDs.remove(sessionId) }
        dropReads()
        do {
            guard let wire, let profile = Self.nonEmpty(session.profile) ?? hermesProfile else { throw BotFailure.transport }
            let outcome = try await HermesSessionDeletion.delete(key: sessionId, profile: profile, on: wire)
            if let refusal = HermesSessionDeletion.message(for: outcome) {
                actionErrorMessage = refusal
                return false
            }
            if let modelContext, let root = session.hermes?.lineageRoot, let listed = hermesProfile {
                try? CacheStore.removeHermesSession(lineageRoot: root, profile: listed, serverURL: server, in: modelContext)
                if let botRoot = session.hermes?.botChatRoot, let hermes {
                    try? CacheStore.removeHermesBotChatRoot(botRoot, serverURL: server, connectionID: hermes.connection.id,
                                                            profile: listed, in: modelContext)
                }
            }
            dropReads()
            pages.remove(sessionId)
            show(pages)
            return true
        } catch {
            if !error.isCancellation { actionErrorMessage = hermesFailure(error) }
            return false
        }
    }

    func close() {
        readSerial += 1
        wire?.close()
        wire = nil
        isLoading = false
        isLoadingMore = false
    }

    private func loadHermes(_ hermes: HermesArchiveSource) async {
        readSerial += 1
        let serial = readSerial
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        actionErrorMessage = nil
        defer { if serial == readSerial { isLoading = false } }
        do {
            let wire = try await connectedWire(hermes, for: serial)
            let profile = try await listedProfile(hermes, on: wire)
            var pages = HermesSessionPages(archived: true)
            pages.append(try await wire.sessionPage(profile: profile, offset: 0, archived: true))
            guard serial == readSerial else { return }
            pagesRead += 1
            show(pages)
            if pages.rows.isEmpty, pages.hasMore { await loadMore() }
        } catch {
            guard serial == readSerial, !Task.isCancelled, !error.isCancellation else { return }
            if let failure = error as? BotFailure, [.stale, .transport].contains(failure) { wire?.close(); wire = nil }
            errorMessage = hermesFailure(error)
        }
    }

    private func connectedWire(_ hermes: HermesArchiveSource, for serial: Int) async throws -> any BotTransport {
        if let wire { return wire }
        let wire = hermes.makeWire(hermes.connection)
        wire.onDisconnect = { [weak self, weak wire] _ in
            guard let self, let wire, self.wire === wire else { return }
            self.wire = nil
        }
        try await wire.connect()
        guard serial == readSerial else {
            wire.close()
            throw BotFailure.stale
        }
        if let current = self.wire {
            wire.close()
            return current
        }
        self.wire = wire
        return wire
    }

    private func listedProfile(_ hermes: HermesArchiveSource, on wire: any BotTransport) async throws -> String {
        if let profile = hermes.profile ?? hermesProfile {
            hermesProfile = profile
            return profile
        }
        let profile = try await HermesProfilePreference.starting(for: server, on: wire, in: hermes.preferences).profile
        hermesProfile = profile
        return profile
    }

    private func restoreHermes(_ session: SessionSummary, key: String) async -> Bool {
        guard let wire, let profile = Self.nonEmpty(session.profile) ?? hermesProfile else {
            actionErrorMessage = hermesFailure(BotFailure.transport)
            return false
        }
        unarchivingSessionIDs.insert(key)
        actionErrorMessage = nil
        defer { unarchivingSessionIDs.remove(key) }
        dropReads()
        let read = pagesRead
        let before = pages.apply(.archived(false), to: key)
        show(pages)
        do {
            try await wire.updateSession(.archived(false), key: key, profile: profile)
            dropReads()
            _ = pages.apply(.archived(false), to: key)
            show(pages)
            return true
        } catch {
            if error as? BotFailure == .stale { return false }
            if let before, read == pagesRead { pages.restore(before.row, at: before.index) }
            unarchivingSessionIDs.remove(key)
            show(pages)
            if !error.isCancellation { actionErrorMessage = hermesFailure(error) }
            return false
        }
    }

    private func dropReads() {
        readSerial += 1
        isLoading = false
        isLoadingMore = false
    }

    private func show(_ pages: HermesSessionPages) {
        self.pages = pages
        if hasMore != pages.hasMore { hasMore = pages.hasMore }
        let profile = hermesProfile ?? ""
        let rows = pages.rows.filter { !unarchivingSessionIDs.contains($0.id) }.map { $0.summary(in: profile) }
        if rows != sessions { sessions = rows }
    }

    private func hermesFailure(_ error: Error) -> String {
        if let refusal = error as? HermesSessionRefusal { return refusal.message }
        if error is URLError, let hermes { return BotConnectionAdvice.message(for: error, address: hermes.connection.address) }
        return error.localizedDescription
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    private func removeSession(withID sessionId: String) -> (index: Int, session: SessionSummary)? {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else {
            return nil
        }

        let removed = sessions.remove(at: index)
        return (index, removed)
    }

    private func restore(_ removedSession: (index: Int, session: SessionSummary)) {
        guard removedSession.session.sessionId != nil,
              !sessions.contains(where: { $0.sessionId == removedSession.session.sessionId })
        else {
            return
        }

        sessions.insert(removedSession.session, at: min(removedSession.index, sessions.count))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
