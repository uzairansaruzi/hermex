import Foundation
import Observation

/// One sheet owns one immutable create attempt. A deliberate retry uses the same
/// room ID and payload, including after backgrounding or losing the socket.
@MainActor @Observable final class BotRoomCreator {
    let connection: BotConnection
    let server: URL
    let roster: [BotProfile]
    private(set) var selected: [BotProfile] = []
    var name = "Group Chat"
    var query = ""
    private(set) var busy = false
    private(set) var message: String?
    private(set) var created: BotGroupRoom?
    private(set) var attempt: [String: BotJSON]?
    private var wire: (any BotTransport)?
    private var generation = UUID()
    private let store: BotConnectionStore
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    private let onReconciled: ([BotGroupRoom]) -> Void

    init(server: URL, connection: BotConnection, roster: [BotProfile],
         store: BotConnectionStore? = nil,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         onReconciled: @escaping ([BotGroupRoom]) -> Void = { _ in }) {
        self.server = server; self.connection = connection; self.roster = roster
        self.store = store ?? BotConnectionStore()
        self.makeWire = makeWire ?? { BotClient(connection: $0) }
        self.onReconciled = onReconciled
    }
    var locked: Bool { attempt != nil }
    var mayContinue: Bool { (2...6).contains(selected.count) }
    var mayCreate: Bool { !busy && created == nil && mayContinue && BotRoomRPC.validName(name) }
    var remaining: [BotProfile] {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return roster.filter { bot in
            !selected.contains(where: { $0.id == bot.id }) &&
            (filter.isEmpty ? !bot.hidden : bot.name.localizedStandardContains(filter) || bot.id.localizedStandardContains(filter))
        }
    }
    func select(_ bot: BotProfile) {
        guard !locked, selected.count < 6, roster.contains(bot), !selected.contains(where: { $0.id == bot.id }) else { return }
        selected.append(bot); query = ""
    }
    func remove(_ bot: BotProfile) {
        guard !locked else { return }
        selected.removeAll { $0.id == bot.id }
    }
    static func member(_ bot: BotProfile) -> BotJSON {
        // profiles.list at the compatibility pin exposes no separate handle.
        var fields: [String: BotJSON] = ["member_id": .string(bot.id), "profile": .string(bot.id), "handle": .string(bot.id)]
        if let displayName = bot.displayName { fields["display_name"] = .string(displayName) }
        return .object(fields)
    }
    var preview: BotGroupRoom {
        BotGroupRoom(.object(["room_id": .string("preview"), "name": .string(name),
                              "members": .array(selected.map(Self.member))]))!
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
            let caps = BotRoomCapabilities(try await client.call("groups.capabilities", [:]))
            try check(owner, client)
            guard caps.enabled, caps.methods.contains("groups.create"), caps.authority != nil else { throw BotFailure.unsupported }
            authority = caps.authority
            let params = attempt ?? ["room_id": .string(UUID().uuidString), "name": .string(name),
                                     "members": .array(selected.map(Self.member))]
            try BotRoomRPC.validate("groups.create", params)
            let result = try await client.call("groups.create", params, validateDispatch: { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner, client)
                self.attempt = params; dispatched = true
            })
            try check(owner, client)
            guard let room = BotGroupRoom(result["room"]), room.id == params["room_id"]?.text,
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
                        if let attempt, let members = attempt["members"]?.list,
                           let room = rooms.first(where: { $0.id == attempt["room_id"]?.text }),
                           room.authority == authority, authority != nil,
                           room.members.count == members.count,
                           zip(room.members, members).allSatisfy({ actual, expected in
                               actual.id == expected["member_id"].text && actual.profile == expected["profile"].text
                                   && actual.handle == expected["handle"].text
                           }) {
                            created = room; message = nil
                        }
                    } catch { /* Keep the original rejection; a failed read is not success. */ }
                }
            } else {
                message = dispatched ? String(localized: "Outcome unknown. Try Again checks the same group creation; it will not create a second room.") : error.localizedDescription
            }
        }
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
            let page = try await client.call("groups.list", ["limit": .number(500), "offset": .number(Double(offset))])
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
