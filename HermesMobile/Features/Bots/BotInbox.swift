import Observation
import UIKit

/// The Bots inbox for one configured server: the roster, Desktop's pin and hidden
/// organization, device-local unread marks, and one live subscription that lasts
/// while the inbox is visible. `open()` owns the transport and `close()` ends it;
/// every late reply is dropped by the wire identity check, so a replaced or closed
/// connection never writes into the screen.
@MainActor @Observable final class BotInbox {
    enum Link: Equatable { case idle, connecting, live, disconnected }

    /// The roster split the way Desktop draws it: pinned first, the rest in server
    /// order, hidden bots apart and only when revealed or when a search names them.
    struct Rows: Equatable {
        var pinned: [BotProfile] = []
        var others: [BotProfile] = []
        var hidden: [BotProfile] = []
    }

    enum ChatRow: Identifiable {
        case bot(BotProfile)
        case room(BotGroupRoom)

        var id: String {
            switch self {
            case .bot(let profile): return "bot:" + profile.id
            case .room(let room): return "room:" + room.id
            }
        }

        var activity: Date? {
            switch self {
            case .bot(let profile): return profile.lastActive
            case .room(let room): return room.updatedAt
            }
        }
    }

    /// Pinned tiles stay separate; all other visible chats share one timeline.
    var chats: [ChatRow] {
        let rows = rows(matching: "")
        let bots = (rows.others + rows.hidden).map(ChatRow.bot)
        // A hidden room lives in the revealed list whether or not it is also
        // pinned, exactly as a hidden bot does, so it can always be unhidden.
        let groups = visibleRooms.filter { isRoomHidden($0) ? showsHidden : !isRoomPinned($0) }.map(ChatRow.room)
        return Self.byActivity(bots + groups)
    }

    /// The tiles above the timeline: Desktop's pinned bots, then rooms pinned on
    /// this phone, each group by activity.
    var pinned: [ChatRow] {
        Self.byActivity(rows(matching: "").pinned.map(ChatRow.bot))
            + Self.byActivity(visibleRooms.filter { isRoomPinned($0) && !isRoomHidden($0) }.map(ChatRow.room))
    }

    private var visibleRooms: [BotGroupRoom] { roomCapabilities.enabled ? rooms : [] }

    private static func byActivity(_ rows: [ChatRow]) -> [ChatRow] {
        rows.sorted {
            switch ($0.activity, $1.activity) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
    }

    let server: URL
    private(set) var connection: BotConnection?
    private(set) var profiles: [BotProfile] = []
    private(set) var rooms: [BotGroupRoom] = []
    private var hasRoomList = false
    private(set) var roomCapabilities = BotRoomCapabilities(.null)
    /// Rooms pinned or hidden on this phone. The host has no such fields for
    /// rooms, so unlike a bot's pin these never reach Desktop.
    private(set) var roomFlags = BotRoomOrganizeStore.Flags()
    private(set) var avatars: [String: UIImage] = [:]
    private(set) var link = Link.idle
    private(set) var errorMessage: String?
    /// Outcome of the last pin or hide write when it did not apply.
    private(set) var notice: String?
    /// Profiles with a pin or hide write in flight; their actions stay inert.
    private(set) var editing: Set<String> = []
    /// Deletes whose reply was lost. The next roster read settles them: a bot that
    /// is gone gets its local state purged then, one that is still there is kept.
    private var uncertainDeletions: Set<String> = []
    /// Session-only reveal of hidden bots, as in Desktop. Never persisted.
    var showsHidden = false
    /// Device-local watermarks for the current connection: the canonical
    /// `last_active` the user last saw for each Profile. Never leaves the phone.
    private(set) var seen: [String: Double] = [:]

    private var wire: (any BotTransport)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var reloadTask: Task<Void, Never>?
    private var reloadWanted = false
    private var reloadSerial = 0
    private var returnedFrom: String?
    private let store: BotConnectionStore
    private let unread: BotUnreadStore
    private let roomStore: BotRoomOrganizeStore
    private let avatarStore: BotAvatarStore
    private let historyCache: BotHistoryCache
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    /// Drops this phone's drafts and cached history for one deleted bot.
    private let purgeLocalState: @MainActor (UUID, String) async -> Void
    /// Minimum gap between event-driven roster reads; the host already floors
    /// `sessions.changed` at two seconds, this guards against a chattier one.
    private let reloadSpacing: Duration
    /// Waits before each silent reconnect after a lost socket; the last one repeats.
    private let reconnectDelays: [Duration]

    init(server: URL, store: BotConnectionStore? = nil, unread: BotUnreadStore = BotUnreadStore(),
         roomStore: BotRoomOrganizeStore = BotRoomOrganizeStore(),
         avatarStore: BotAvatarStore? = nil, historyCache: BotHistoryCache = .shared, reloadSpacing: Duration = .seconds(1),
         reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)],
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         purgeLocalState: (@MainActor (UUID, String) async -> Void)? = nil) {
        self.server = server; self.store = store ?? BotConnectionStore(); self.unread = unread; self.roomStore = roomStore
        self.avatarStore = avatarStore ?? .shared; self.reloadSpacing = reloadSpacing
        self.reconnectDelays = reconnectDelays; self.historyCache = historyCache
        self.makeWire = makeWire ?? { BotClient(connection: $0) }
        self.purgeLocalState = purgeLocalState ?? { connectionID, profile in
            try? await BotHistoryCache.shared.removeProfile(server: server, connectionID: connectionID, profileID: profile)
            await ChatDraftStore.shared.discardBotDrafts(server: server, connectionID: connectionID, profile: profile)
        }
        // Known before the first frame, so a saved connection draws the loading
        // skeleton rather than flashing "Connect to Hermes" until `open()` runs.
        connection = try? self.store.load(server: server)
    }

    var hiddenCount: Int { profiles.filter(\.hidden).count + visibleRooms.filter(isRoomHidden).count }

    func rows(matching search: String) -> Rows {
        let matching = profiles.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        let shown = matching.filter { !$0.hidden }
        return Rows(pinned: shown.filter(\.pinned), others: shown.filter { !$0.pinned },
                    hidden: showsHidden || !search.isEmpty ? matching.filter(\.hidden) : [])
    }

    /// True when the canonical chat moved past what this device last showed.
    /// A row without a watermark reads as seen: the first roster load seeds it.
    func isUnread(_ profile: BotProfile) -> Bool {
        guard let lastActive = profile.lastActive?.timeIntervalSince1970, let mark = seen[profile.id] else { return false }
        return lastActive > mark
    }

    /// The user is entering this bot's chat: the row's activity is now seen.
    func markSeen(_ profile: BotProfile) {
        guard let lastActive = profile.lastActive?.timeIntervalSince1970, seen[profile.id] != lastActive else { return }
        seen[profile.id] = lastActive
        persistSeen()
    }

    /// The user came back from this bot's chat. Whatever the next roster read
    /// shows was on screen while they were there, so it is marked seen once and
    /// normal tracking resumes after that.
    func noteReturn(from profile: BotProfile) {
        markSeen(profile)
        returnedFrom = profile.id
    }

    /// Connects, reads the roster and avatars, and keeps the socket for live
    /// `sessions.changed` reloads. Also the pull-to-refresh and Reconnect path.
    func open() async {
        close(); hasRoomList = false
        var client: (any BotTransport)?
        do {
            let saved = try store.load(server: server)
            if connection?.id != saved?.id {
                profiles = []; avatars = [:]; seen = [:]; rooms = []; roomCapabilities = BotRoomCapabilities(.null)
                roomFlags = BotRoomOrganizeStore.Flags()
            }
            connection = saved
            guard let saved else { link = .idle; return }
            if seen.isEmpty { seen = unread.load(connectionID: saved.id) }
            if roomFlags == BotRoomOrganizeStore.Flags() { roomFlags = roomStore.load(connectionID: saved.id) }
            let opened = makeWire(saved)
            client = opened
            wire = opened; link = .connecting; errorMessage = nil; notice = nil
            opened.onEvent = { [weak self] event in
                guard let self, self.wire === opened, event["type"].text == "sessions.changed" else { return }
                self.noteChange()
            }
            opened.onDisconnect = { [weak self] error in
                guard let self, self.wire === opened else { return }
                self.drop(opened, error: error)
            }
            try await opened.connect()
            guard wire === opened, !Task.isCancelled else { return }
            recordInstallID(opened.serverInstallID, for: saved)
            guard await reload(opened) else { return }
            await refreshRooms(opened)
            guard wire === opened, !Task.isCancelled else { return }
            link = .live
            reconnectAttempts = 0
            await refreshAvatars(opened)
        } catch {
            guard !Task.isCancelled else { return }
            if let client {
                // The socket's own disconnect callback may already have dropped this
                // client and scheduled the quiet retry; a second report would paint
                // the message over it.
                if wire === client { drop(client, error: error) }
            } else {
                // A saved-connection read can fail before any client exists; that is
                // still a visible failure with the Reconnect path, not a stale roster.
                link = .disconnected; errorMessage = (error as? BotFailure ?? .transport).localizedDescription
            }
        }
    }

    /// Trust on first use: stores the host's `install_id` on a record that has none, so
    /// every later connect can refuse an address that starts reaching another host. The
    /// record is re-read rather than taken from `opened`, because the connection form may
    /// have saved a new password or name under the same UUID while this inbox connected.
    private func recordInstallID(_ live: String?, for opened: BotConnection) {
        guard let live, var fresh = try? store.load(server: server), fresh.id == opened.id,
              fresh.address == opened.address, fresh.installID == nil else { return }
        fresh.installID = live
        try? store.save(fresh, server: server)
    }

    func close() {
        reconnectTask?.cancel(); reconnectTask = nil
        reloadTask?.cancel(); reloadTask = nil; reloadWanted = false
        wire?.close(); wire = nil
        link = .idle
    }

    /// A lost socket or a failed read is retried quietly, with growing delays, for
    /// as long as the inbox stays open; the roster stays on screen meanwhile. Only
    /// a refusal the user has to act on shows a message and the Reconnect button:
    /// sign-in, an unsupported host or address, an address that now reaches a
    /// different host, and any other permanent HTTP
    /// client error (a 404 is not a Hermes host). Server errors, rate limits and
    /// JSON-RPC faults other than "method missing" are the retry loop's problem.
    private static func isRetryable(_ error: Error) -> Bool {
        switch error as? BotFailure {
        case .unsupported, .wrongIdentity, .differentHost, .invalidAddress: return false
        case .rejected(-32601), .rejected(4090), .rejected(4130): return false
        case .rejected(408), .rejected(429): return true
        case .rejected(let code): return !(400..<500).contains(code)
        default: return true
        }
    }

    /// True until the first roster lands: the inbox shows a skeleton instead of a
    /// connection message while it connects, or quietly retries, with nothing to show.
    var isLoadingRoster: Bool {
        connection != nil && profiles.isEmpty && errorMessage == nil && link != .live
    }

    func mayEdit(_ profile: BotProfile) -> Bool { link == .live && !editing.contains(profile.id) }

    /// The built-in Profile is the host itself; Hermes refuses to delete it.
    func mayDelete(_ profile: BotProfile) -> Bool { profile.id != "default" && mayEdit(profile) }

    /// Deletes the Profile on the host, then this phone's state for it. A refused
    /// delete leaves everything in place; a lost reply is reported as uncertain and
    /// never retried on its own, because the next roster read settles it.
    func delete(_ profile: BotProfile) async {
        guard mayDelete(profile), let client = wire else { return }
        editing.insert(profile.id); notice = nil
        defer { editing.remove(profile.id) }
        do {
            try await client.deleteProfile(profile.id)
            guard wire === client else { return }
            await forget(profile.id)
            guard wire === client else { return }
            _ = await reload(client)
        } catch {
            guard wire === client else { return }
            if case BotFailure.rejected = error {
                notice = String(localized: "Hermes did not delete this bot. It is still on the host.")
            } else {
                uncertainDeletions.insert(profile.id)
                notice = String(localized: "Could not confirm whether the bot was deleted. Pull down to refresh.")
            }
        }
    }

    /// Drops everything this phone kept for a bot that no longer exists on the host.
    private func forget(_ profile: String) async {
        guard let connection else { return }
        seen.removeValue(forKey: profile); persistSeen()
        avatarStore.setImage(nil, connectionID: connection.id, profile: profile, revision: nil)
        await purgeLocalState(connection.id, profile)
    }

    func setPinned(_ pinned: Bool, _ profile: BotProfile) async { await configure(profile, "pinned", .bool(pinned)) }
    func setHidden(_ hidden: Bool, _ profile: BotProfile) async { await configure(profile, "hidden", .bool(hidden)) }

    /// Writes one Desktop look field through `profiles.configure`, sending the whole
    /// `hermes-bots` object back so unrelated Desktop fields survive, under the look
    /// revision the row was read at. Nothing is shown as done until the host says
    /// it applied and the roster is re-read; a conflict means Desktop wrote in
    /// between, so the fresh roster is shown and the user decides whether to retry.
    private func configure(_ profile: BotProfile, _ field: String, _ value: BotJSON) async {
        guard mayEdit(profile), let client = wire else { return }
        editing.insert(profile.id); notice = nil
        defer { editing.remove(profile.id) }
        var look = profile.look
        look[field] = value
        do {
            let reply = try await client.call("profiles.configure", [
                "name": .string(profile.id),
                "ui_meta": .object(["hermes-bots": .object(look)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .number(Double(profile.lookRevision ?? 0))])
            ])
            guard wire === client else { return }
            if reply["applied"]["ui_meta"].flag != true {
                notice = reply["applied"]["ui_meta_conflicts"] != .null
                    ? String(localized: "This bot changed in Hermes Desktop. The list was refreshed; try again.")
                    : String(localized: "Hermes did not save this change.")
            }
            if await reload(client) { await refreshAvatars(client) }
        } catch {
            guard wire === client else { return }
            notice = error as? BotFailure == .rejected(-32601)
                ? String(localized: "This Hermes version cannot organize bots from the phone.")
                : String(localized: "Hermes did not save this change.")
        }
    }

    /// Coalesces `sessions.changed` bursts: one reload in flight, at most one
    /// more queued, spaced by `reloadSpacing`. Avatars are not refreshed here
    /// because the event follows session activity, and a look change never moves it.
    private func noteChange() {
        reloadWanted = true
        guard reloadTask == nil, let client = wire else { return }
        reloadTask = Task { [weak self] in
            while let self, self.reloadWanted, self.wire === client, !Task.isCancelled {
                self.reloadWanted = false
                _ = await self.reload(client)
                guard self.wire === client, (try? await Task.sleep(for: self.reloadSpacing)) != nil else { break }
            }
            guard let self, self.wire === client else { return }
            self.reloadTask = nil
        }
    }

    /// One `profiles.list` on the live socket. Only the newest request's reply is
    /// applied, and only while `client` still owns the inbox.
    private func reload(_ client: any BotTransport) async -> Bool {
        reloadSerial += 1
        let serial = reloadSerial
        do {
            let roster = try await client.call("profiles.list", ["include_sessions": .bool(true)])
            guard wire === client, serial == reloadSerial else { return false }
            guard let rows = roster["profiles"].list else { throw BotFailure.unsupported }
            var ids = Set<String>()
            profiles = rows.compactMap(BotProfile.init).filter { ids.insert($0.id).inserted }
            if let connection {
                let scope = BotHistoryCache.Scope(server: server, connectionID: connection.id)
                historyCache.recent.remove {
                    guard $0.scope == scope, case .bot(let id) = $0.conversation else { return false }
                    return !ids.contains(id)
                }
            }
            var changed = false
            for profile in profiles {
                guard let lastActive = profile.lastActive?.timeIntervalSince1970,
                      seen[profile.id] == nil || profile.id == returnedFrom else { continue }
                seen[profile.id] = lastActive; changed = true
            }
            returnedFrom = nil
            if changed { persistSeen() }
            let present = Set(profiles.map(\.id))
            let settled = uncertainDeletions
            uncertainDeletions = []
            for name in settled where !present.contains(name) {
                await forget(name)
                guard wire === client, serial == reloadSerial else { return false }
            }
            return true
        } catch {
            guard wire === client, serial == reloadSerial else { return false }
            drop(client, error: error)
            return false
        }
    }

    func roomKey(_ room: BotGroupRoom) -> BotRoomKey? {
        connection.map { BotRoomKey(server: server, connectionID: $0.id, roomID: room.id) }
    }

    /// A failed room read is not an authoritative empty list, even if the Bot roster is live.
    var searchableRoomIDs: Set<String>? {
        hasRoomList && link == .live ? Set(rooms.map(\.id)) : nil
    }

    func roomForSearch(_ hit: BotHistoryCache.Hit) -> BotGroupRoom? {
        guard let connection, hit.snapshot.scope == BotHistoryCache.Scope(server: server, connectionID: connection.id),
              let saved = hit.snapshot.cachedRoom else { return nil }
        if let current = rooms.first(where: { $0.id == saved.id }) { return current }
        return searchableRoomIDs == nil ? saved : nil
    }

    /// Admit a cached identity for navigation only while the live list is unavailable.
    /// Search dismissal rechecks the room, so a fresh list or connection change still wins.
    func selectRoomSearchHit(_ hit: BotHistoryCache.Hit) -> BotGroupRoom? {
        guard let room = roomForSearch(hit) else { return nil }
        if !rooms.contains(where: { $0.id == room.id }) { rooms.append(room) }
        return room
    }

    func rooms(matching query: String) -> [BotGroupRoom] {
        guard roomCapabilities.enabled else { return [] }
        return rooms.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }

    func updateRoom(_ room: BotGroupRoom, connectionID: UUID) {
        guard connection?.id == connectionID else { return }
        if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = room }
        else { rooms.insert(room, at: 0) }
    }
    func removeRoom(_ key: BotRoomKey) {
        guard key.server == server, key.connectionID == connection?.id else { return }
        rooms.removeAll { $0.id == key.roomID }
    }
    func reconcileRooms(_ values: [BotGroupRoom], connectionID: UUID) {
        guard connection?.id == connectionID else { return }
        rooms = values
    }

    func expireRoom(_ key: BotRoomKey) {
        guard key.server == server, key.connectionID == connection?.id else { return }
        rooms.removeAll { $0.id == key.roomID }
        notice = String(localized: "This room’s history is no longer available.")
    }

    func isRoomPinned(_ room: BotGroupRoom) -> Bool { roomFlags.pinned.contains(room.id) }
    func isRoomHidden(_ room: BotGroupRoom) -> Bool { roomFlags.hidden.contains(room.id) }

    /// Phone-only, so these apply at once and need no host round trip.
    func setRoomPinned(_ pinned: Bool, _ room: BotGroupRoom) {
        if pinned { roomFlags.pinned.insert(room.id) } else { roomFlags.pinned.remove(room.id) }
        persistRoomFlags()
    }
    func setRoomHidden(_ hidden: Bool, _ room: BotGroupRoom) {
        if hidden { roomFlags.hidden.insert(room.id) } else { roomFlags.hidden.remove(room.id) }
        persistRoomFlags()
    }

    /// Rename and disband follow the room screen's gates: the host must offer the
    /// method, the room must be this gateway's own, and no write for it may be in
    /// flight. A room under another gateway's authority is read-only from here.
    func mayRenameRoom(_ room: BotGroupRoom) -> Bool { mayCommandRoom(room, "groups.rename") }
    func mayDisbandRoom(_ room: BotGroupRoom) -> Bool { mayCommandRoom(room, "groups.disband") }
    private func mayCommandRoom(_ room: BotGroupRoom, _ method: String) -> Bool {
        link == .live && roomCapabilities.methods.contains(method)
            && !room.isForeign(to: roomCapabilities.authority) && !editing.contains(ChatRow.room(room).id)
    }

    func renameRoom(_ room: BotGroupRoom, to name: String) async {
        guard mayRenameRoom(room), BotRoomRPC.validName(name), name != room.name, let client = wire else { return }
        await commandRoom(room, "groups.rename", ["room_id": .string(room.id),
            "event_id": .string(UUID().uuidString), "name": .string(name)], client) { result in
            guard let updated = BotGroupRoom(result["room"]), updated.id == room.id, !updated.disbanded
            else { throw BotFailure.unsupported }
            if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = updated }
        }
    }

    /// Nothing local is dropped until the host confirms the tombstone; a lost
    /// reply is settled by the next room list, which prunes what is gone.
    func disbandRoom(_ room: BotGroupRoom) async {
        guard mayDisbandRoom(room), let client = wire, let key = roomKey(room) else { return }
        let disbanded = await commandRoom(room, "groups.disband", ["room_id": .string(room.id)], client) { result in
            guard result["tombstone"]["room_id"].text == room.id,
                  result["tombstone"]["disbanded_at"].number != nil else { throw BotFailure.unsupported }
            rooms.removeAll { $0.id == room.id }
            roomFlags.pinned.remove(room.id); roomFlags.hidden.remove(room.id); persistRoomFlags()
        }
        if disbanded { try? await historyCache.removeRoom(key) }
    }

    /// True when the host accepted the write and `accept` took it.
    @discardableResult
    private func commandRoom(_ room: BotGroupRoom, _ method: String, _ params: [String: BotJSON],
                             _ client: any BotTransport, accept: (BotJSON) throws -> Void) async -> Bool {
        let id = ChatRow.room(room).id
        editing.insert(id); notice = nil
        defer { editing.remove(id) }
        do {
            let result = try await client.call(method, params)
            guard wire === client else { return false }
            try accept(result)
            return true
        } catch {
            guard wire === client else { return false }
            notice = (error as? BotRoomFailure)?.localizedDescription
                ?? String(localized: "Hermes did not save this change.")
            return false
        }
    }

    private func persistRoomFlags() {
        guard let connection else { return }
        roomStore.save(roomFlags, connectionID: connection.id)
    }

    /// Capabilities are re-read on every inbox open/refresh, never inferred from
    /// a mutating probe. Unsupported hosts keep their ordinary Bot inbox.
    private func refreshRooms(_ client: any BotTransport) async {
        do {
            let value = try await client.call("groups.capabilities", [:])
            guard wire === client, !Task.isCancelled else { return }
            let capabilities = BotRoomCapabilities(value)
            roomCapabilities = capabilities
            guard capabilities.enabled else { rooms = []; hasRoomList = true; return }
            var found: [BotGroupRoom] = []
            var offset = 0
            while true {
                let page = try await client.call("groups.list", ["limit": .number(500), "offset": .number(Double(offset))])
                guard wire === client, !Task.isCancelled else { return }
                guard let rows = page["rooms"].list else { throw BotFailure.unsupported }
                found += rows.compactMap(BotGroupRoom.init).filter { !$0.disbanded }
                guard let next = page["next_offset"].integer else { break }
                guard next > offset else { throw BotFailure.unsupported }
                offset = next
            }
            var ids = Set<String>()
            rooms = found.filter { ids.insert($0.id).inserted }; hasRoomList = true
            let pruned = BotRoomOrganizeStore.Flags(pinned: roomFlags.pinned.intersection(ids),
                                                   hidden: roomFlags.hidden.intersection(ids))
            if pruned != roomFlags { roomFlags = pruned; persistRoomFlags() }
            if let connectionID = connection?.id {
                try? await historyCache.retainRooms(ids, scope: .init(server: server, connectionID: connectionID))
            }
        } catch {
            guard wire === client, !Task.isCancelled else { return }
            rooms = []; hasRoomList = false; roomCapabilities = BotRoomCapabilities(.null)
            // Method absence is the expected gate on older Hermes hosts.
            if let failure = error as? BotRoomFailure, failure.code != -32601 {
                notice = failure.localizedDescription
            }
        }
    }

    private func refreshAvatars(_ client: any BotTransport) async {
        guard let connection else { return }
        await avatarStore.refresh(profiles, connectionID: connection.id, using: client) {
            if wire === client { avatars = avatarStore.images(connectionID: connection.id) }
        }
    }

    private func drop(_ client: any BotTransport, error: Error) {
        reloadTask?.cancel(); reloadTask = nil; reloadWanted = false
        client.close(); wire = nil
        link = .disconnected
        guard Self.isRetryable(error) else {
            errorMessage = (error as? BotFailure ?? .transport).localizedDescription
            return
        }
        let delay = reconnectDelays[min(reconnectAttempts, reconnectDelays.count - 1)]
        reconnectAttempts += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            await self.open()
        }
    }

    private func persistSeen() {
        guard let connection else { return }
        unread.save(seen, connectionID: connection.id)
    }
}

/// Device-local record of the canonical activity the user last saw per bot,
/// keyed by connection UUID so equal Profile names on two hosts never share a
/// mark. Plain timestamps, so `UserDefaults` rather than the Keychain; the
/// values never leave the phone and Desktop has no matching state to sync.
struct BotUnreadStore {
    var defaults: UserDefaults = .standard

    private func key(_ connectionID: UUID) -> String { "bot-inbox-seen." + connectionID.uuidString }

    func load(connectionID: UUID) -> [String: Double] {
        defaults.dictionary(forKey: key(connectionID)) as? [String: Double] ?? [:]
    }

    func save(_ seen: [String: Double], connectionID: UUID) {
        defaults.set(seen, forKey: key(connectionID))
    }

    func remove(connectionID: UUID) {
        defaults.removeObject(forKey: key(connectionID))
    }
}

/// Phone-local pin and hide marks for group rooms, keyed by connection UUID like
/// the unread marks. The host keeps no such state for rooms, so a pin made here
/// never shows in Desktop or on another phone.
struct BotRoomOrganizeStore {
    struct Flags: Equatable {
        var pinned: Set<String> = []
        var hidden: Set<String> = []
    }

    var defaults: UserDefaults = .standard

    private func key(_ connectionID: UUID) -> String { "bot-inbox-rooms." + connectionID.uuidString }

    func load(connectionID: UUID) -> Flags {
        let stored = defaults.dictionary(forKey: key(connectionID)) as? [String: [String]] ?? [:]
        return Flags(pinned: Set(stored["pinned"] ?? []), hidden: Set(stored["hidden"] ?? []))
    }

    func save(_ flags: Flags, connectionID: UUID) {
        defaults.set(["pinned": Array(flags.pinned).sorted(), "hidden": Array(flags.hidden).sorted()],
                     forKey: key(connectionID))
    }

    func remove(connectionID: UUID) {
        defaults.removeObject(forKey: key(connectionID))
    }
}
