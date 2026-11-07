import Foundation
import Observation

/// One sheet owns one immutable create attempt. A deliberate retry uses the same
/// room ID and payload, including after backgrounding or losing the socket.
@MainActor @Observable final class BotRoomCreator {
    let connection: BotConnection
    let server: URL
    let roster: [BotProfile]
    /// The Profiles a canonical host can seat (`BotRoomCapabilities.seatableProfiles`, #1605); nil
    /// on a dashboard, which seats its whole roster. No other bot is offered or sent. Create
    /// refreshes it from the host's latest answer.
    private(set) var seatable: Set<String>?
    private(set) var selected: [BotProfile] = []
    var name = "Group Chat"
    var query = ""
    private(set) var busy = false
    private(set) var message: String?
    private(set) var created: BotGroupRoom?
    private(set) var attempt: HermesCall.RoomCreation?
    private var wire: (any BotTransport)?
    private var generation = UUID()
    private let store: BotConnectionStore
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    private let onReconciled: ([BotGroupRoom]) -> Void

    init(server: URL, connection: BotConnection, roster: [BotProfile], seatable: Set<String>? = nil,
         store: BotConnectionStore? = nil,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         onReconciled: @escaping ([BotGroupRoom]) -> Void = { _ in }) {
        self.server = server; self.connection = connection; self.roster = roster; self.seatable = seatable
        self.store = store ?? BotConnectionStore()
        self.makeWire = makeWire ?? { BotClient(saved: $0, server: server) }
        self.onReconciled = onReconciled
    }
    var locked: Bool { attempt != nil }
    var mayContinue: Bool { (2...6).contains(selected.count) }
    var mayCreate: Bool { !busy && created == nil && mayContinue && BotRoomRPC.validName(name) }
    /// Whether the host can seat `bot`.
    func seats(_ bot: BotProfile) -> Bool { seatable?.contains(bot.id) ?? true }
    /// The host can't seat some bot the list would otherwise show, so the list says it left some out.
    var leavesOutBots: Bool { roster.contains { !$0.hidden && !seats($0) } }
    /// Fewer than two bots can join, so no group can be made.
    var tooFewToSeat: Bool { seatable != nil && roster.filter(seats).count < 2 }
    var remaining: [BotProfile] {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return roster.filter { bot in
            seats(bot) && !selected.contains(where: { $0.id == bot.id }) &&
            (filter.isEmpty ? !bot.hidden : bot.name.localizedStandardContains(filter) || bot.id.localizedStandardContains(filter))
        }
    }
    func select(_ bot: BotProfile) {
        guard !locked, selected.count < 6, roster.contains(bot), seats(bot), !selected.contains(where: { $0.id == bot.id }) else { return }
        selected.append(bot); query = ""
    }
    func remove(_ bot: BotProfile) {
        guard !locked else { return }
        selected.removeAll { $0.id == bot.id }
    }
    static func member(_ bot: BotProfile) -> HermesCall.RoomMember {
        // profiles.list at the compatibility pin exposes no separate handle.
        HermesCall.RoomMember(memberID: bot.id, profile: bot.id, handle: bot.id, displayName: bot.displayName)
    }
    var preview: BotGroupRoom {
        BotGroupRoom(.object(["room_id": .string("preview"), "name": .string(name),
                              "members": .array(selected.map { Self.member($0).json })]))!
    }

    func create() async {
        guard mayCreate else { return }
        let owner = UUID(); generation = owner
        let client = makeWire(connection); wire = client; busy = true; message = nil
        var dispatched = false
        var authority: String?
        defer {
            client.onDisconnect = nil; client.close()
            if generation == owner { wire = nil; busy = false }
        }
        do {
            try check(owner, client)
            try await client.connect(); try check(owner, client)
            let caps = BotRoomCapabilities(try await client.call(.groupsCapabilities))
            try check(owner, client)
            guard caps.enabled, caps.methods.contains("groups.create"), caps.authority != nil else { throw BotFailure.unsupported }
            authority = caps.authority
            // Rechecked at create: a bot the host stopped seating since the sheet opened is never sent.
            // The host refuses such a member before it looks for the room, so a Try Again reads the
            // rooms instead: the room it made, or an unlocked choice when it made none.
            if let fresh = caps.seatableProfiles, !selected.allSatisfy({ fresh.contains($0.id) }) {
                if let attempt {
                    let rooms = try await BotRoomList.read(client) { try self.check(owner, client) }
                    try check(owner, client); onReconciled(rooms)
                    if let room = Self.room(made: attempt, in: rooms, authority: authority) { created = room; return }
                    self.attempt = nil
                }
                seatable = fresh
                selected.removeAll { !fresh.contains($0.id) }
                message = String(localized: "A bot you chose can’t join group chats on this Hermes any more. Go back and choose again.")
                return
            }
            let creation = attempt ?? HermesCall.RoomCreation(roomID: UUID().uuidString, name: name,
                                                              members: selected.map(Self.member))
            let result = try await client.call(.groupsCreate(creation), validateDispatch: { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner, client)
                self.attempt = creation; dispatched = true
            })
            try check(owner, client)
            guard let room = BotGroupRoom(result["room"]), room.id == creation.roomID,
                  !room.disbanded, room.authority == caps.authority else { throw BotFailure.unsupported }
            created = room
        } catch {
            guard generation == owner, !Task.isCancelled else { return }
            if let failure = error as? BotRoomFailure {
                message = failure.localizedDescription
                if failure.code == 4110 {
                    do {
                        let rooms = try await BotRoomList.read(client) { try self.check(owner, client) }
                        try check(owner, client); onReconciled(rooms)
                        // Another client can rename the room between a lost create
                        // reply and retry. Its permanent ID and frozen members still
                        // identify our successful creation; the name may differ.
                        if let attempt, let room = Self.room(made: attempt, in: rooms, authority: authority) {
                            created = room; message = nil
                        }
                    } catch { /* Keep the original rejection; a failed read is not success. */ }
                }
            } else {
                message = dispatched ? String(localized: "Outcome unknown. Try Again checks the same group creation; it will not create a second room.") : error.localizedDescription
            }
        }
    }

    /// The room `attempt` made, found in `rooms` by its permanent id, frozen members and authority;
    /// its name may differ, since another client can rename it in between.
    private static func room(made attempt: HermesCall.RoomCreation, in rooms: [BotGroupRoom], authority: String?) -> BotGroupRoom? {
        guard let authority, let room = rooms.first(where: { $0.id == attempt.roomID }), room.authority == authority,
              room.members.count == attempt.members.count,
              zip(room.members, attempt.members).allSatisfy({ actual, expected in
                  actual.id == expected.memberID && actual.profile == expected.profile && actual.handle == expected.handle
              }) else { return nil }
        return room
    }

    func suspend() {
        if busy && locked { message = String(localized: "Outcome unknown. Try Again checks the same group creation; it will not create a second room.") }
        generation = UUID(); wire?.close(); wire = nil; busy = false
    }
    private func check(_ owner: UUID, _ client: any BotTransport) throws {
        guard generation == owner, wire === client, !Task.isCancelled,
              try store.load(server: server)?.id == connection.id else { throw BotFailure.stale }
    }
}

/// A complete active-room read is needed before deciding an uncertain disband
/// removed its room. One missing page must never look like successful deletion.
enum BotRoomList {
    @MainActor static func read(_ client: any BotTransport, check: () throws -> Void) async throws -> [BotGroupRoom] {
        var rooms: [BotGroupRoom] = [], offset = 0
        while true {
            let page = try await client.call(.groupsList(offset: offset))
            try check()
            guard let rows = page["rooms"].list else { throw BotFailure.unsupported }
            for row in rows {
                guard let room = BotGroupRoom(row) else { throw BotFailure.unsupported }
                if !room.disbanded { rooms.append(room) }
            }
            guard page["next_offset"] != .null else { return rooms }
            guard let next = page["next_offset"].integer, next > offset else { throw BotFailure.unsupported }
            offset = next
        }
    }
}
