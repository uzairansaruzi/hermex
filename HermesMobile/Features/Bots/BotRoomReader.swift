import Foundation
import Observation

/// One visible room owns one socket. Closing invalidates replies before
/// cancelling transport; backgrounding keeps the loaded window but stops all reads.
@MainActor @Observable final class BotRoomReader {
    enum Link: Equatable { case idle, connecting, live, stopped }
    let key: BotRoomKey
    let connection: BotConnection
    let initialSequence: Int?
    @ObservationIgnored private let cache: BotHistoryCache
    @ObservationIgnored private(set) var historyRemoval: Task<Void, Never>?
    private(set) var room: BotGroupRoom
    private(set) var events: [BotRoomEvent] = []
    private(set) var status = BotRoomStatus(.null)
    private(set) var link = Link.idle
    private(set) var errorMessage: String?
    private(set) var hasEarlier = false
    private(set) var loadingEarlier = false
    private(set) var foreignAuthority = false
    var draft = ""
    private(set) var commandMessage: String?
    private(set) var uncertainSend: Send?
    private(set) var uncertainDisband = false
    private var renaming = false
    private(set) var busy = false
    private(set) var awaitingStop = false
    private(set) var inactiveActions = Set<BotRoomAction.Identity>()
    struct Send: Equatable {
        let text: String
        let eventID: String
        let threadID: String
        init(text: String) { self.text = text; eventID = UUID().uuidString; threadID = UUID().uuidString }
    }
    @ObservationIgnored private var viewOwner: UUID?
    @ObservationIgnored private var commandID: UUID?
    @ObservationIgnored private var dispatched = false
    @ObservationIgnored private var sending: Send?
    @ObservationIgnored private var stateRevision = 0
    @ObservationIgnored private var log = BotRoomLog()
    @ObservationIgnored private var wire: (any BotTransport)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var capabilities = BotRoomCapabilities(.null)
    @ObservationIgnored private var lastAuthority: BotJSON?
    @ObservationIgnored private let makeWire: @MainActor (BotConnection) -> any BotTransport
    @ObservationIgnored private let onExpired: () -> Void
    @ObservationIgnored private let onChanged: (BotGroupRoom) -> Void
    @ObservationIgnored private let onDisbanded: () -> Void

    init(key: BotRoomKey, connection: BotConnection, room: BotGroupRoom,
         cache: BotHistoryCache = .shared, initialSequence: Int? = nil,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         onExpired: @escaping () -> Void = {},
         onChanged: @escaping (BotGroupRoom) -> Void = { _ in },
         onDisbanded: @escaping () -> Void = {}) {
        self.key = key; self.connection = connection; self.room = room
        self.cache = cache; self.initialSequence = initialSequence
        self.onChanged = onChanged; self.onDisbanded = onDisbanded
        self.makeWire = makeWire ?? { BotClient(connection: $0) }; self.onExpired = onExpired
    }

    /// Room and profile share state, but each visible screen claims async ownership.
    /// Navigation callbacks can arrive in either order; the old screen cannot close the new socket.
    func open(owner: UUID? = nil) async {
        viewOwner = owner
        suspend()
        let client = makeWire(connection)
        wire = client; link = .connecting; errorMessage = nil
        client.onDisconnect = { [weak self] error in
            guard let self, self.wire === client else { return }
            self.fail(error, client)
        }
        do {
            await historyRemoval?.value
            let cached = try? await cache.roomHistory(key)
            try check(client)
            if let cached {
                var restored = BotRoomLog()
                restored.apply(cached.replayPage)
                restored.loadedEarlier(from: cached.earlierBoundary ?? 0)
                log = restored; publishLog()
            }
            try await client.connect()
            try check(client)
            let value = try await client.call("groups.capabilities", [:])
            try check(client)
            capabilities = BotRoomCapabilities(value)
            guard capabilities.enabled else { throw BotFailure.unsupported }
            if uncertainDisband, try await reconcileDisband(client) { return }
            let latest = try await readState(client)
            var initial = log
            if cached == nil {
                initial.begin(latest: latest)
                if let sequence = initialSequence, sequence > 0, sequence <= latest {
                    initial.begin(latest: min(latest, sequence + 199))
                }
            }
            if let sequence = initialSequence, sequence > 0, sequence <= initial.earlierBoundary {
                let earlier = try await readPages(client, since: sequence - 1, through: initial.earlierBoundary)
                try check(client)
                for page in earlier { initial.apply(page) }
                initial.loadedEarlier(from: sequence - 1)
            }
            let pages = try await readPages(client, since: initial.cursor)
            try check(client)
            for page in pages { initial.apply(page) }
            log = initial; publishLog()
            if try observeAuthority(pages.last, client) { _ = try await readState(client) }
            try check(client)
            link = .live
            pollTask = Task { [weak self] in
                while let self, self.wire === client, !Task.isCancelled {
                    do { try await Task.sleep(for: self.status.interval) } catch { return }
                    guard self.wire === client, !Task.isCancelled else { return }
                    await self.poll()
                }
            }
        } catch { fail(error, client) }
    }

    /// Independently callable for scripted tests; the timer only schedules reads.
    func poll() async {
        guard let client = wire, link == .live else { return }
        do {
            let latest = try await readState(client)
            guard latest > log.cursor else { return }
            let pages = try await readPages(client, since: log.cursor)
            try check(client)
            for page in pages { log.apply(page) }
            publishLog()
            if try observeAuthority(pages.last, client) { _ = try await readState(client) }
        } catch { fail(error, client) }
    }

    func loadEarlier() async {
        guard let client = wire, link == .live, hasEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        let boundary = log.earlierBoundary
        let start = BotRoomLog.windowStart(before: boundary)
        do {
            let pages = try await readPages(client, since: start, through: boundary)
            try check(client)
            for page in pages { log.apply(page) }
            log.loadedEarlier(from: start); publishLog(); loadingEarlier = false
        } catch { fail(error, client) }
    }

    func leave(owner: UUID) {
        guard viewOwner == owner else { return }
        close(); viewOwner = nil
    }

    func suspend() {
        if busy && dispatched {
            uncertainSend = sending ?? uncertainSend
            commandMessage = String(localized: "Outcome unknown. Reconnect to check the room. Commands are never resent automatically.")
        }
        commandID = nil; busy = false; sending = nil; dispatched = false; renaming = false
        let old = wire; wire = nil
        pollTask?.cancel(); pollTask = nil
        old?.onDisconnect = nil; old?.onEvent = nil
        old?.close(); loadingEarlier = false; link = .idle
    }

    func close() {
        suspend(); log = BotRoomLog(); events = []; hasEarlier = false
        status = BotRoomStatus(.null); lastAuthority = nil
    }

    var canParticipate: Bool {
        link == .live && !uncertainDisband && !foreignAuthority && capabilities.authority != nil && room.authority == capabilities.authority
    }
    var showsComposer: Bool { !foreignAuthority }
    var showsStop: Bool { status.working || status.stopping > 0 || awaitingStop }
    var mayStop: Bool { allows("groups.stop") && !busy && !awaitingStop && status.stopping == 0 && status.stoppable > 0 }
    var mayEditDraft: Bool { !busy && uncertainSend == nil }
    var maySend: Bool { allows("groups.send") && !busy && uncertainSend == nil && BotRoomRPC.validText(draft) }
    var mayResend: Bool { allows("groups.send") && !busy && uncertainSend != nil }
    var statusText: String? {
        if status.stopping > 0 || awaitingStop { return String(localized: "Stopping…") }
        if status.blocked { return String(localized: "Waiting for you") }
        if status.working { return String(localized: "Working…") }
        return nil
    }
    private func allows(_ method: String) -> Bool { canParticipate && capabilities.methods.contains(method) }
    func mayAct(_ action: BotRoomAction) -> Bool {
        !busy && action.isAnswerable && !inactiveActions.contains(action.id) && status.actions.contains(action)
            && allows(action.isRetry ? "groups.retry" : "groups.approve")
    }

    var showsRename: Bool { !foreignAuthority && capabilities.methods.contains("groups.rename") }
    var showsDisband: Bool { !foreignAuthority && capabilities.methods.contains("groups.disband") }
    var mayRename: Bool { allows("groups.rename") && !busy }
    var finishingStop: Bool { status.stopping > 0 || awaitingStop }
    var mayDisband: Bool { allows("groups.disband") && !busy && !finishingStop }

    func rename(_ name: String) async {
        guard mayRename, BotRoomRPC.validName(name), name != room.name else { return }
        renaming = true
        await command("groups.rename", params: ["room_id": .string(key.roomID),
            "event_id": .string(UUID().uuidString), "name": .string(name)], validate: {}, accept: { result in
            guard let updated = BotGroupRoom(result["room"]), updated.id == self.key.roomID,
                  !updated.disbanded else { throw BotFailure.unsupported }
            self.stateRevision += 1
            self.room = updated; self.onChanged(updated)
        })
    }

    func disband() async {
        guard mayDisband else { return }
        let owner = viewOwner
        await command("groups.disband", params: ["room_id": .string(key.roomID)], validate: {
            guard !self.finishingStop else { throw BotFailure.stale }
            self.uncertainDisband = true
        }, accept: { result in
            guard result["tombstone"]["room_id"].text == self.key.roomID,
                  result["tombstone"]["disbanded_at"].number != nil else { throw BotFailure.unsupported }
            self.finishDisband()
        })
        // A disconnect may invalidate the write's continuation. Recover with reads
        // only while still visible; background/close leaves link idle.
        if viewOwner == owner && uncertainDisband && link == .stopped { await open(owner: owner) }
    }

    private func finishDisband() {
        uncertainDisband = false; discardHistory(); close(); onDisbanded()
    }

    private func reconcileDisband(_ client: any BotTransport) async throws -> Bool {
        let rooms = try await BotRoomList.read(client) { try self.check(client) }
        if !rooms.contains(where: { $0.id == key.roomID }) { finishDisband(); return true }
        uncertainDisband = false
        commandMessage = String(localized: "The room is still present. Disband was not confirmed.")
        return false
    }

    /// Every explicit Send mints a thread so it queues instead of superseding work.
    /// Only the dedicated retry button reuses an uncertain send's id and payload.
    func send(retry: Bool = false) async {
        guard retry ? mayResend : maySend else { return }
        let request = retry ? uncertainSend! : Send(text: draft)
        sending = request
        let params: [String: BotJSON] = ["room_id": .string(key.roomID), "event_id": .string(request.eventID),
            "payload": .object(["text": .string(request.text), "thread_id": .string(request.threadID)])]
        await command("groups.send", params: params, validate: {}, accept: { result in
            guard result["accepted"].flag == true, result["client_event_id"].text == request.eventID,
                  result["event"]["room_id"].text == self.key.roomID,
                  result["event"]["kind"].text == "message.user",
                  result["event"]["payload"]["thread_id"].text == request.threadID,
                  result["event"]["payload"]["text"].text != nil,
                  BotRoomEvent(result["event"]) != nil else { throw BotFailure.unsupported }
            self.log.acknowledge(result["event"])
            self.uncertainSend = nil; self.sending = nil
            if self.draft == request.text { self.draft = "" }
            self.publishLog()
        })
    }

    func stop() async {
        guard mayStop else { return }
        await command("groups.stop", params: ["room_id": .string(key.roomID), "cancel_id": .string(UUID().uuidString)],
                      validate: { guard self.status.stoppable > 0 else { throw BotFailure.stale } }, accept: { result in
            guard result["cancelled"].integer != nil else { throw BotFailure.unsupported }
            self.awaitingStop = true
        })
    }

    func act(_ action: BotRoomAction, choice: BotApprovalRequest.Choice? = nil) async {
        guard mayAct(action), let params = action.parameters(roomID: key.roomID, choice: choice) else { return }
        let method = action.isRetry ? "groups.retry" : "groups.approve"
        await command(method, params: params, validate: {
            guard self.status.actions.contains(action), !self.inactiveActions.contains(action.id) else { throw BotFailure.stale }
            self.inactiveActions.insert(action.id)
        }, accept: { result in
            guard result[action.isRetry ? "retried" : "approved"].flag == true else { throw BotFailure.unsupported }
        })
    }

    /// Ownership and the pending tuple are checked in BotClient's actual socket
    /// write closure. A lost reply never starts another command.
    private func command(_ method: String, params: [String: BotJSON], validate: @escaping () throws -> Void,
                         accept: (BotJSON) throws -> Void) async {
        guard let client = wire, allows(method), !busy else { sending = nil; return }
        let token = UUID(), epoch = room.epoch
        commandID = token; busy = true; dispatched = false; commandMessage = nil
        do {
            let result = try await client.call(method, params, validateDispatch: { [weak self] in
                guard let self, self.commandID == token, self.wire === client, self.allows(method),
                      self.room.epoch == epoch, !Task.isCancelled else { throw BotFailure.stale }
                try validate()
                self.dispatched = true
                self.stateRevision += 1
            })
            guard commandID == token, wire === client else { return }
            try check(client)
            try accept(result)
        } catch {
            guard commandID == token, wire === client else { return }
            if let rejection = error as? BotRoomFailure {
                if method == "groups.disband" { uncertainDisband = false }
                commandMessage = rejection.localizedDescription
                if rejection.reason == "authority_conflict" { foreignAuthority = true }
                if rejection.expired { discardHistory(); close(); onExpired(); return }
                // A rejected retry does not erase the uncertainty of the original send.
            } else if dispatched {
                uncertainSend = sending ?? uncertainSend
                commandMessage = String(localized: "Outcome unknown. Reconnect to check the room. Commands are never resent automatically.")
            } else { commandMessage = error.localizedDescription }
        }
        guard commandID == token, wire === client else { return }
        commandID = nil; busy = false; dispatched = false; sending = nil; renaming = false
        if uncertainDisband {
            do { if try await reconcileDisband(client) { return } }
            catch { fail(error, client); return }
        }
        // Read after every acknowledgment or rejection (including 5118/5119).
        // Inactive tuples stay inert even if a stale server snapshot repeats them.
        await poll()
    }

    private func check(_ client: any BotTransport) throws {
        guard wire === client, !Task.isCancelled else { throw BotFailure.stale }
    }

    private func readState(_ client: any BotTransport) async throws -> Int {
        stateRevision += 1
        let revision = stateRevision
        let value = try await client.call("groups.state", ["room_id": .string(key.roomID)])
        try check(client)
        guard let updated = BotGroupRoom(value["room"]), updated.id == key.roomID else { throw BotFailure.unsupported }
        guard revision == stateRevision else { return room.latestSeq }
        if updated.disbanded { throw BotRoomFailure(code: 4114, reason: nil) }
        if !renaming && room != updated { room = updated; onChanged(updated) }
        let nextStatus = BotRoomStatus(value["driver_status"])
        if status != nextStatus { status = nextStatus }
        if !busy && nextStatus.stopping == 0 { awaitingStop = false }
        let pendingIDs = Set(nextStatus.actions.map(\.id))
        inactiveActions = inactiveActions.filter { $0.kind != "retry" || pendingIDs.contains($0) }
        let foreign = updated.isForeign(to: capabilities.authority)
        if foreignAuthority != foreign { foreignAuthority = foreign }
        return updated.latestSeq
    }

    /// History windows stop at their old boundary. Live/open replay drains all
    /// pages, including pages containing only unknown kinds. Reject stalled cursors.
    private func readPages(_ client: any BotTransport, since: Int, through: Int? = nil) async throws -> [BotJSON] {
        var cursor = since
        var pages: [BotJSON] = []
        while true {
            let limit = min(capabilities.pageLimit, through.map { max(1, $0 - cursor) } ?? capabilities.pageLimit)
            let receivedAt = Date()
            let page = try await client.call("groups.log", ["room_id": .string(key.roomID),
                "since_seq": .number(Double(cursor)), "limit": .number(Double(limit))])
            try check(client)
            guard page["events"].list != nil, let next = page["cursor"].integer, next >= cursor,
                  let more = page["has_more"].flag else { throw BotFailure.unsupported }
            pages.append(page)
            // Storage is best-effort. A failed disk write must not stop live reading.
            try? await cache.appendRoom(key: key, room: room, page: page, since: cursor, receivedAt: receivedAt)
            try check(client)
            if !more || through.map({ next >= $0 }) == true { break }
            guard next > cursor else { throw BotFailure.unsupported }
            cursor = next
        }
        return pages
    }

    private func observeAuthority(_ page: BotJSON?, _ client: any BotTransport) throws -> Bool {
        try check(client)
        guard let authority = page?["authority"], authority != .null else { return false }
        let moved = lastAuthority != nil && lastAuthority != authority
        lastAuthority = authority
        if let owner = authority["gateway_id"].text, let local = capabilities.authority, owner != local {
            foreignAuthority = true
        }
        return moved
    }

    private func publishLog() {
        // A poll can race the send acknowledgment. Do not publish our own pending
        // message as sent until the RPC result has been validated.
        let visible = log.events.filter { event in
            guard let sending else { return true }
            return event.kind != "message.user" || event.payload["thread_id"].text != sending.threadID
        }
        if events != visible { events = visible }
        hasEarlier = log.earlierBoundary > 0
    }

    private func discardHistory() {
        let cache = cache, key = key
        // Deletion intentionally outlives the screen; it never mutates view state.
        historyRemoval = Task { try? await cache.removeRoom(key) }
    }

    private func fail(_ error: Error, _ client: any BotTransport) {
        guard wire === client else { return }
        suspend(); link = .stopped
        errorMessage = error.localizedDescription
        if let failure = error as? BotRoomFailure, failure.expired { discardHistory(); close(); onExpired() }
    }
}
