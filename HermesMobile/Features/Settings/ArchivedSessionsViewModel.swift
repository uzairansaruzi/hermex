import Foundation
import Observation
import SwiftData

/// Where a Hermes server's Archived screen (#1048) reads from: the server's saved connection,
/// the Profile it lists, and its client on the connection's shared socket.
struct HermesArchiveSource {
    let connection: BotConnection
    /// The Sessions list's Profile; nil (from Settings) lists the server's pick
    /// (`HermesProfilePreference`), else the Profile the host's dashboard runs.
    let profile: String?
    /// Each connect's client; tests script it.
    var makeWire: @MainActor (BotConnection) -> any BotTransport
    var preferences: UserDefaults = .standard

    /// The server's saved connection, on the socket its other screens share.
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
    /// Last raw failure, exposed so the view can forward it to the shared
    /// API-error handler (401 → re-login), mirroring `SessionListViewModel`.
    private(set) var lastError: Error?
    /// More archived sessions wait on a Hermes host.
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// The Profile a Hermes server's screen lists, once it is known.
    private(set) var hermesProfile: String?

    private let server: URL
    private let client: APIClient
    /// Set on a Hermes server: rows come from its archived pages, and nothing reaches the webui API.
    private let hermes: HermesArchiveSource?
    @ObservationIgnored private var wire: (any BotTransport)?
    @ObservationIgnored private var pages = HermesSessionPages(archived: true)
    /// Bumped by each read, and by each restore or delete, so only a read that began after the
    /// screen's last change applies.
    @ObservationIgnored private var readSerial = 0
    /// Bumped each time a first-page read replaces `pages`, so a refused restore puts its row
    /// back only into the pages it left.
    @ObservationIgnored private var pagesRead = 0

    var isUnarchiving: Bool {
        !unarchivingSessionIDs.isEmpty
    }

    var isHermes: Bool { hermes != nil }

    /// A Hermes server's screen holds a client on the socket.
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
            // `include_archived=1` is required — the default response excludes
            // archived rows entirely, which made this view permanently empty
            // (issue #17). The merged response keeps the visible rows too; each
            // row carries an `archived` flag (verified against upstream routes.py
            // @312d3fab and the live server), so filter client-side.
            let response = try await client.sessions(includeArchived: true)
            sessions = (response.sessions ?? []).filter {
                Self.nonEmpty($0.sessionId) != nil && $0.archived == true
            }
        } catch {
            // A cancelled load (pull-to-refresh superseding `.task`, or the view
            // disappearing) is not a failure — don't flash an error state.
            if !Self.isCancellationError(error) {
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
            // Rejections (subagent / read-only CLI sessions) arrive as HTTP 400
            // and throw above; a 200 body with an `error` field is surfaced too
            // so the server's own message is always shown (issue #17). An
            // explicit `ok: false` without an `error` string is still a failure
            // (matching the `ok != false` guard used across the app) — only a
            // missing `ok` is treated as success, per tolerant decoding.
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
            if !Self.isCancellationError(error) {
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

    /// A restore or delete of `session` is in flight.
    func isChanging(_ session: SessionSummary) -> Bool {
        guard let sessionId = session.sessionId else { return false }
        return unarchivingSessionIDs.contains(sessionId) || deletingSessionIDs.contains(sessionId)
    }

    // MARK: Hermes (#1048)

    /// The Hermes session a row opens, in the row's Profile. Nil for a Bot Chat row, which opens
    /// in its bot (`hermesBot(for:)`).
    func hermesChat(for session: SessionSummary) -> HermesSessionChat? {
        guard let hermes, let profile = hermesProfile, session.hermes?.isBotChat != true else { return nil }
        return session.hermesChat(on: server, connection: hermes.connection, listedIn: profile)
    }

    /// The bot whose Bot Chat this row is (#1146): it opens through the app's bot route, as a
    /// Sessions search hit does, so the Bots tab owns that chat's replaced notice, Update sign-in
    /// and read mark. Nil for any other row.
    func hermesBot(for session: SessionSummary) -> BotDestination? {
        hermes.flatMap { session.hermesBot(on: server, connectionID: $0.connection.id) }
    }

    /// Reads the next page of archived sessions, one at a time, and reads on past a page of room
    /// sessions alone, which shows no row (#1146). A restore or delete moves the host's later
    /// rows, so no page is read while one is out, and one already out is dropped.
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
            guard serial == readSerial, !Self.isCancellationError(error) else { return }
            actionErrorMessage = hermesFailure(error)
        }
    }

    /// Deletes an archived Hermes session through `HermesSessionDeletion`, once the host
    /// confirms; a busy or held one stays, and the screen says why. Reads still out when it
    /// starts or ends are dropped, as a restore's are. A deleted session leaves the offline
    /// cache in `modelContext` too, where one archived elsewhere may still sit (#1054).
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
            }
            dropReads()
            pages.remove(sessionId)
            show(pages)
            return true
        } catch {
            if !Self.isCancellationError(error) { actionErrorMessage = hermesFailure(error) }
            return false
        }
    }

    /// Ends this screen's calls; the shared socket stays for the server's other screens.
    func close() {
        readSerial += 1
        wire?.close()
        wire = nil
        isLoading = false
        isLoadingMore = false
    }

    /// The first page of the Profile's archived sessions, hidden Bot Chats included. A read
    /// that begins meanwhile replaces it.
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
            // A first page of room sessions alone shows nothing yet.
            if pages.rows.isEmpty, pages.hasMore { await loadMore() }
        } catch {
            guard serial == readSerial, !Task.isCancelled, !Self.isCancellationError(error) else { return }
            // A client the socket dropped is replaced on the next load.
            if let failure = error as? BotFailure, [.stale, .transport].contains(failure) { wire?.close(); wire = nil }
            errorMessage = hermesFailure(error)
        }
    }

    /// This screen's client on the socket, connecting it first. A client another load
    /// connected meanwhile wins, and this one leaves, as it does when the read that asked for it
    /// ended meanwhile (`close()` on the background), so a later load connects afresh.
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

    /// The Profile the screen lists: the Sessions list's, else the server's pick while the host
    /// still lists it, else the Profile its dashboard runs. Settled once per screen.
    private func listedProfile(_ hermes: HermesArchiveSource, on wire: any BotTransport) async throws -> String {
        if let profile = hermes.profile ?? hermesProfile {
            hermesProfile = profile
            return profile
        }
        let rows = (try? await wire.call(.profilesList(includeSessions: false)))?["profiles"].list ?? []
        let current = try await wire.currentProfile()
        let profile = HermesProfilePreference.resolve(for: server, listed: rows.compactMap { $0["name"].text },
                                                      current: current, in: hermes.preferences)
        hermesProfile = profile
        return profile
    }

    /// Restores an archived row: it leaves at once, and a refusal puts it back where it stood,
    /// unless a refresh replaced the pages meanwhile: those list it where the host has it.
    /// A read still out when the restore starts or ends could show it again, so it is dropped.
    /// When this screen's client closed before the host's answer was read (`.stale`), the
    /// restore may have landed: the row stays gone, and the screen's next load shows the host's.
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
            if !Self.isCancellationError(error) { actionErrorMessage = hermesFailure(error) }
            return false
        }
    }

    /// Ends the reads still out, with their spinners: they began before a change this screen
    /// made, so they could show a row it just restored or deleted.
    private func dropReads() {
        readSerial += 1
        isLoading = false
        isLoadingMore = false
    }

    /// Shows `pages`, less a row whose restore is still out.
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

    /// Mirrors `SessionListViewModel`'s cancellation check: a `CancellationError`
    /// or a (possibly `APIError.network`-wrapped) `URLError.cancelled`.
    private static func isCancellationError(_ error: Error) -> Bool {
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
