import Observation
import SwiftData
import UIKit

@MainActor @Observable final class BotInbox {
    enum Link: Equatable { case idle, connecting, live, disconnected }

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

    struct SectionName: Identifiable, Equatable {
        let id: String
        let name: String
    }

    struct ChatSection: Identifiable {
        let id: String
        let name: String?
        let chats: [ChatRow]
    }

    var sections: [ChatSection] {
        let rows = rows(matching: "")
        var filed: [String: [ChatRow]] = [:]
        var unfiled: [ChatRow] = []
        for profile in rows.others + rows.hidden {
            if let id = profile.sectionID, profile.sectionName != nil { filed[id, default: []].append(.bot(profile)) }
            else { unfiled.append(.bot(profile)) }
        }
        unfiled += visibleRooms.filter { isRoomHidden($0) ? showsHidden : !isRoomPinned($0) }.map(ChatRow.room)
        var blocks = sectionNames.compactMap { section in
            filed[section.id].map { ChatSection(id: "section:" + section.id, name: section.name, chats: byAttention($0)) }
        }
        if !unfiled.isEmpty { blocks.append(ChatSection(id: "unfiled", name: nil, chats: byAttention(unfiled))) }
        return blocks
    }

    var sectionNames: [SectionName] {
        var tallies: [String: [(name: String, count: Int)]] = [:]
        var ids: [String] = []
        for profile in profiles {
            guard let id = profile.sectionID, let name = profile.sectionName else { continue }
            if tallies[id] == nil { ids.append(id) }
            if let index = tallies[id, default: []].firstIndex(where: { $0.name == name }) { tallies[id]![index].count += 1 }
            else { tallies[id, default: []].append((name, 1)) }
        }
        let named = ids.map { id in
            let names = tallies[id]!
            let winner = names.dropFirst().reduce(names[0]) { $1.count > $0.count ? $1 : $0 }
            return SectionName(id: id, name: winner.name)
        }
        return Self.ordered(named, placed: sectionOrder)
    }

    var reorderableSectionNames: [SectionName] {
        let listed = Set(profiles.compactMap { $0.sectionName != nil && (!$0.pinned || $0.hidden) ? $0.sectionID : nil })
        return sectionNames.filter { listed.contains($0.id) }
    }

    static func ordered(_ sections: [SectionName], placed: [String]) -> [SectionName] {
        let byID = Dictionary(sections.map { ($0.id, $0) }) { first, _ in first }
        var used = Set<String>()
        let front = placed.compactMap { id in used.insert(id).inserted ? byID[id] : nil }
        let rest = sections.filter { !used.contains($0.id) }.sorted {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return $0.id < $1.id
            }
        }
        return front + rest
    }

    var pinned: [ChatRow] {
        byAttention(rows(matching: "").pinned.map(ChatRow.bot))
            + byAttention(visibleRooms.filter { isRoomPinned($0) && !isRoomHidden($0) }.map(ChatRow.room))
    }

    private var visibleRooms: [BotGroupRoom] { roomCapabilities.enabled ? rooms : [] }

    private func byAttention(_ rows: [ChatRow]) -> [ChatRow] {
        func rank(_ row: ChatRow) -> Int {
            guard case .bot(let profile) = row else { return 3 }
            switch liveStatuses[profile.id] {
            case .waiting: return 0
            case .working: return 1
            case nil: return isUnread(profile) ? 2 : 3
            }
        }
        return rows.map { (row: $0, rank: rank($0)) }.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            switch ($0.row.activity, $1.row.activity) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.row.id < $1.row.id
            }
        }.map(\.row)
    }

    let server: URL
    private(set) var connection: BotConnection?
    private(set) var profiles: [BotProfile] = []
    private(set) var rooms: [BotGroupRoom] = []
    private var hasRoomList = false
    private(set) var roomCapabilities = BotRoomCapabilities(.null)
    private(set) var roomFlags = BotRoomOrganizeStore.Flags()
    private(set) var sectionOrder: [String] = []
    private(set) var avatars: [String: UIImage] = [:]
    private(set) var link = Link.idle
    private(set) var errorMessage: String?
    private(set) var needsSignIn = false
    private(set) var needsAddress = false
    private(set) var routeAdvice: String?
    private(set) var notice: String?
    private(set) var editing: Set<String> = []
    private var uncertainDeletions: Set<String> = []
    var showsHidden = false
    var selection = BotInboxSelection()
    private(set) var seen: [String: Double] = [:]
    private(set) var liveStatuses: [String: BotLiveStatus] = [:]
    private(set) var liveStatusesAreStale = false
    private(set) var isReconnecting = false
    var homeConnection: HomeConnectionStatus.Facts {
        HomeConnectionStatus.Facts(keepsRows: !profiles.isEmpty && errorMessage == nil && routeAdvice == nil,
                                   isReconnecting: isReconnecting)
    }

    private var wire: (any BotTransport)?
    private let reconnect: BotReconnectSchedule
    private let isNetworkAvailable: @MainActor () -> Bool
    private var openSerial = 0
    private var routeFailures = 0
    private static let routeFailuresBeforeAdvice = 3
    private var reloadTask: Task<Void, Never>?
    private var reloadWanted = false
    private var reloadSerial = 0
    private var readsLiveStatus = true
    private var statusSerial = 0
    private var retriesStatusRead = false
    private var statusPollTask: Task<Void, Never>?
    private var returnedFrom: String?
    private let store: BotConnectionStore
    private let unread: BotUnreadStore
    private let roomStore: BotRoomOrganizeStore
    private let sectionOrderStore: BotSectionOrderStore
    private let avatarStore: BotAvatarStore
    private let historyCache: BotHistoryCache
    private let rosterCache: BotRosterCache
    private let profileNames: HermesProfileNameCache
    private let widgets: BotWidgetPublisher
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    private let purgeLocalState: @MainActor (UUID, String) async -> Void
    @ObservationIgnored var offlineCache: ModelContext?
    private let reloadSpacing: Duration
    private let statusPollInterval: Duration

    init(server: URL, store: BotConnectionStore? = nil, unread: BotUnreadStore = BotUnreadStore(),
         roomStore: BotRoomOrganizeStore = BotRoomOrganizeStore(),
         sectionOrderStore: BotSectionOrderStore = BotSectionOrderStore(),
         avatarStore: BotAvatarStore? = nil, historyCache: BotHistoryCache = .shared, rosterCache: BotRosterCache = .shared,
         profileNames: HermesProfileNameCache = .shared, widgets: BotWidgetPublisher? = nil,
         reloadSpacing: Duration = .seconds(1),
         reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)],
         statusPollInterval: Duration = .seconds(5),
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         purgeLocalState: (@MainActor (UUID, String) async -> Void)? = nil,
         isNetworkAvailable: @escaping @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied }) {
        self.server = server; self.store = store ?? BotConnectionStore(); self.unread = unread; self.roomStore = roomStore
        self.sectionOrderStore = sectionOrderStore
        self.avatarStore = avatarStore ?? .shared; self.reloadSpacing = reloadSpacing
        reconnect = BotReconnectSchedule(delays: reconnectDelays, isNetworkAvailable: isNetworkAvailable)
        self.isNetworkAvailable = isNetworkAvailable
        self.historyCache = historyCache; self.rosterCache = rosterCache; self.profileNames = profileNames
        self.widgets = widgets ?? .shared
        self.statusPollInterval = statusPollInterval
        self.makeWire = makeWire ?? { BotClient(saved: $0, server: server) }
        self.purgeLocalState = purgeLocalState ?? { connectionID, profile in
            await ChatDraftStore.shared.discardBotDrafts(server: server, connectionID: connectionID, profile: profile)
        }
        connection = try? self.store.load(server: server)
    }

    var hiddenCount: Int { profiles.filter(\.hidden).count + visibleRooms.filter(isRoomHidden).count }

    func rows(matching search: String) -> Rows {
        let matching = profiles.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        let shown = matching.filter { !$0.hidden }
        return Rows(pinned: shown.filter(\.pinned), others: shown.filter { !$0.pinned },
                    hidden: showsHidden || !search.isEmpty ? matching.filter(\.hidden) : [])
    }

    struct BotChatHit: Identifiable, Equatable {
        let profileID: String
        let snippet: String?
        let isFromUser: Bool?
        var id: String { profileID }
    }

    func searchBotChats(_ query: String) async throws -> [BotChatHit] {
        guard link == .live, let client = wire, !query.isEmpty else { return [] }
        var hits: [BotChatHit] = []
        for profile in profiles {
            let results = try await client.searchSessions(query: query, profile: profile.id,
                                                          limit: HermesREST.sessionSearchMaximum)
            guard wire === client else { throw BotFailure.stale }
            try Task.checkCancellation()
            let current = Set([profile.canonicalID, profile.canonicalTipID].compactMap { $0 })
            if let match = results.first(where: { $0.row.isBotChat && (current.contains($0.row.id) || current.contains($0.row.identity)) }) {
                hits.append(BotChatHit(profileID: profile.id, snippet: match.snippet, isFromUser: match.role.map { $0 == "user" }))
            }
        }
        return hits
    }

    func isUnread(_ profile: BotProfile) -> Bool {
        guard let lastActive = profile.lastActive?.timeIntervalSince1970, let mark = seen[profile.id] else { return false }
        return lastActive > mark
    }

    func markSeen(_ profile: BotProfile) {
        guard let lastActive = profile.lastActive?.timeIntervalSince1970, seen[profile.id] != lastActive else { return }
        seen[profile.id] = lastActive
        persistSeen()
    }

    func noteReturn(from profile: BotProfile) {
        markSeen(profile)
        returnedFrom = profile.id
    }

    func open() async {
        teardown(); hasRoomList = false
        var client: (any BotTransport)?
        do {
            let saved = try store.load(server: server)
            if connection?.id != saved?.id {
                selection = BotInboxSelection()
                profiles = []; avatars = [:]; seen = [:]; rooms = []; roomCapabilities = BotRoomCapabilities(.null)
                roomFlags = BotRoomOrganizeStore.Flags(); sectionOrder = []; setLiveStatuses([:])
                setReconnecting(false)
            }
            if connection?.id != saved?.id || connection?.address != saved?.address {
                routeFailures = 0; routeAdvice = nil
            }
            if connection != saved { needsSignIn = false; needsAddress = false }
            connection = saved
            guard var saved else { link = .idle; return }
            if seen.isEmpty { seen = unread.load(connectionID: saved.id) }
            if roomFlags == BotRoomOrganizeStore.Flags() { roomFlags = roomStore.load(connectionID: saved.id) }
            if sectionOrder.isEmpty { sectionOrder = sectionOrderStore.load(server: server, connectionID: saved.id) }
            guard !needsSignIn else { link = .disconnected; return }
            if profiles.isEmpty {
                let serial = openSerial
                let cached = await rosterCache.load(.init(server: server, connectionID: saved.id))
                guard serial == openSerial, !Task.isCancelled, let fresh = try? store.load(server: server) else { return }
                var unrotated = fresh
                if let token = saved.oauth?.refreshToken { unrotated.oauth?.refreshToken = token }
                guard unrotated == saved else { return }
                saved = fresh; connection = fresh
                if let cached, profiles.isEmpty {
                    profiles = Self.roster(cached)
                    avatars = avatarStore.images(connectionID: saved.id)
                }
            }
            let opened = makeWire(saved)
            client = opened
            wire = opened; link = .connecting; errorMessage = nil; notice = nil; readsLiveStatus = true; retriesStatusRead = false
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
            routeFailures = 0; routeAdvice = nil
            recordInstallID(opened.serverInstallID, for: saved)
            guard await reload(opened) else { return }
            let statuses = statusPollTask
            await refreshRooms(opened)
            guard wire === opened, !Task.isCancelled else { return }
            link = .live
            reconnect.succeeded()
            await refreshAvatars(opened)
            await statuses?.value
        } catch {
            guard !Task.isCancelled else { return }
            if let client {
                if wire === client { drop(client, error: error) }
            } else {
                link = .disconnected; errorMessage = (error as? BotFailure ?? .transport).localizedDescription
                needsSignIn = error as? BotFailure == .rejected(401)
                needsAddress = error as? BotFailure == .gatewayListener
                setLiveStatuses([:]); setReconnecting(false)
            }
        }
    }

    private func recordInstallID(_ live: String?, for opened: BotConnection) {
        guard let live else { return }
        if connection?.id == opened.id, connection?.address == opened.address, connection?.installID == nil {
            connection?.installID = live
        }
        guard var fresh = try? store.load(server: server), fresh.id == opened.id,
              fresh.address == opened.address, fresh.installID == nil else { return }
        fresh.installID = live
        try? store.save(fresh, server: server)
    }

    func signInSaved() { needsSignIn = false }

    func noteRejectedSignIn(_ rejected: BotConnection) {
        guard let connection, rejected.id == connection.id, rejected.address == connection.address,
              rejected.username == connection.username, rejected.password == connection.password else { return }
        close(); setLiveStatuses([:]); link = .disconnected
        routeFailures = 0; routeAdvice = nil
        errorMessage = BotConnectionAdvice.message(for: BotFailure.rejected(401), address: rejected.address)
        needsSignIn = true; needsAddress = false
    }

    func networkPathDidChange() {
        if !isNetworkAvailable(), !liveStatuses.isEmpty { setLiveStatuses(liveStatuses, stale: true) }
        reconnect.networkPathDidChange()
    }

    func reconnectNow() { reconnect.networkPathDidChange() }

    func close() {
        teardown()
        setReconnecting(false)
        if liveStatusesAreStale { setLiveStatuses([:]) }
    }

    private func teardown() {
        openSerial += 1
        reconnect.cancel()
        reloadTask?.cancel(); reloadTask = nil; reloadWanted = false
        statusPollTask?.cancel(); statusPollTask = nil
        wire?.close(); wire = nil
        link = .idle
    }

    private static func isRouteFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard case .rejected(let code)? = error as? BotFailure else { return false }
        return (502...504).contains(code) || (520...530).contains(code)
    }

    var isLoadingRoster: Bool {
        connection != nil && profiles.isEmpty && errorMessage == nil && routeAdvice == nil && link != .live
    }

    func mayEdit(_ profile: BotProfile) -> Bool { link == .live && !editing.contains(profile.id) }

    func mayDelete(_ profile: BotProfile) -> Bool { profile.id != "default" && mayEdit(profile) }

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

    private func forget(_ profile: String) async {
        if selection.profile?.id == profile { selection = BotInboxSelection() }
        guard let connection else { return }
        seen.removeValue(forKey: profile); persistSeen()
        avatarStore.setImage(nil, connectionID: connection.id, profile: profile, revision: nil)
        if let offlineCache {
            try? CacheStore.removeHermesBotChats(serverURL: server, connectionID: connection.id, profile: profile, in: offlineCache)
        }
        await purgeLocalState(connection.id, profile)
    }

    func setPinned(_ pinned: Bool, _ profile: BotProfile) async { await configure(profile, ["pinned": .bool(pinned)]) }
    func setHidden(_ hidden: Bool, _ profile: BotProfile) async { await configure(profile, ["hidden": .bool(hidden)]) }

    func moveToSection(_ profile: BotProfile, _ section: SectionName) async {
        guard profile.sectionID != section.id || profile.sectionName != section.name else { return }
        await configure(profile, ["sectionId": .string(section.id), "sectionName": .string(section.name)])
    }

    func moveToNewSection(_ profile: BotProfile, name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = sectionNames.first(where: { $0.name == name }) { return await moveToSection(profile, existing) }
        await configure(profile, ["sectionId": .string(Self.newSectionID()), "sectionName": .string(name)])
    }

    func removeFromSection(_ profile: BotProfile) async {
        await configure(profile, ["sectionId": .null, "sectionName": .null])
    }

    static func newSectionID(now: Date = .now) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let millis = String(Int64(now.timeIntervalSince1970 * 1000), radix: 36)
        return "sec-\(millis)-" + String((0..<5).map { _ in alphabet.randomElement()! })
    }

    private func configure(_ profile: BotProfile, _ changes: [String: BotJSON]) async {
        guard mayEdit(profile), let client = wire else { return }
        editing.insert(profile.id); notice = nil
        defer { editing.remove(profile.id) }
        let look = profile.look.merging(changes) { $1 }
        do {
            let reply = try await client.call(.profilesConfigure(.init(
                name: profile.id, look: .init(fields: look, revision: profile.lookRevision ?? 0))))
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

    private func reload(_ client: any BotTransport) async -> Bool {
        reloadSerial += 1
        let serial = reloadSerial
        let scope = connection.map { BotRosterCache.Scope(server: server, connectionID: $0.id) }
        let readAt = ContinuousClock.now
        do {
            let roster = try await client.call(.profilesList(includeSessions: true))
            guard wire === client, serial == reloadSerial else { return false }
            guard let rows = roster["profiles"].list else { throw BotFailure.unsupported }
            let previous = Set(profiles.map(\.id))
            profiles = Self.roster(rows)
            setReconnecting(false)
            if profileNames.save(profiles.map { .init(profile: $0.id, title: $0.name, model: $0.model) }, for: server) {
                ProfileEntityProvider.refreshAppShortcuts(changed: true)
            }
            if let connection { widgets.publish(profiles, server: server, connectionID: connection.id) }
            var changed = false
            for profile in profiles {
                guard let lastActive = profile.lastActive?.timeIntervalSince1970,
                      seen[profile.id] == nil || profile.id == returnedFrom else { continue }
                seen[profile.id] = lastActive; changed = true
            }
            returnedFrom = nil
            if changed { persistSeen() }
            let present = Set(profiles.map(\.id))
            if let connection, let offlineCache {
                for name in previous.subtracting(present) {
                    try? CacheStore.removeHermesBotChats(serverURL: server, connectionID: connection.id, profile: name, in: offlineCache)
                }
            }
            let settled = uncertainDeletions
            uncertainDeletions = []
            for name in settled where !present.contains(name) {
                await forget(name)
                guard wire === client, serial == reloadSerial else { return false }
            }
            if let scope {
                await rosterCache.save(rows, scope: scope, readAt: readAt)
                guard wire === client, serial == reloadSerial else { return false }
            }
            startLiveStatusRead(client)
            return true
        } catch {
            guard wire === client, serial == reloadSerial else { return false }
            drop(client, error: error)
            return false
        }
    }

    private func startLiveStatusRead(_ client: any BotTransport, after delay: Duration? = nil) {
        statusPollTask?.cancel(); statusPollTask = nil
        guard readsLiveStatus else { return }
        statusPollTask = Task { [weak self] in
            if let delay, (try? await Task.sleep(for: delay)) == nil { return }
            guard !Task.isCancelled, let self, self.wire === client else { return }
            await self.readLiveStatuses(client)
        }
    }

    private func readLiveStatuses(_ client: any BotTransport) async {
        statusSerial += 1
        let serial = statusSerial, roster = reloadSerial
        func current() -> Bool {
            !Task.isCancelled && wire === client && serial == statusSerial && roster == reloadSerial
        }
        do {
            let reply = try await client.call(.sessionActiveList)
            guard current() else { return }
            setLiveStatuses(BotLiveStatus.statuses(reply["sessions"].list ?? [], profiles: profiles))
            retriesStatusRead = false
        } catch {
            guard current() else { return }
            if error as? BotFailure == .rejected(-32601) {
                readsLiveStatus = false
                setLiveStatuses([:])
            } else {
                retriesStatusRead = retriesStatusRead || !liveStatuses.isEmpty
                setLiveStatuses(liveStatuses, stale: !liveStatuses.isEmpty)
            }
        }
        if liveStatuses.isEmpty && !retriesStatusRead { statusPollTask = nil }
        else { startLiveStatusRead(client, after: statusPollInterval) }
    }

    private static func roster(_ rows: [BotJSON]) -> [BotProfile] {
        var ids = Set<String>()
        return rows.compactMap(BotProfile.init).filter { ids.insert($0.id).inserted }
    }

    private func setLiveStatuses(_ statuses: [String: BotLiveStatus], stale: Bool = false) {
        if statuses != liveStatuses { liveStatuses = statuses }
        if stale != liveStatusesAreStale { liveStatusesAreStale = stale }
    }

    private func setReconnecting(_ reconnecting: Bool) {
        if reconnecting != isReconnecting { isReconnecting = reconnecting }
    }

    func roomKey(_ room: BotGroupRoom) -> BotRoomKey? {
        connection.map { BotRoomKey(server: server, connectionID: $0.id, roomID: room.id) }
    }

    var searchableRoomIDs: Set<String>? {
        hasRoomList && link == .live ? Set(rooms.map(\.id)) : nil
    }

    func roomForSearch(_ hit: BotHistoryCache.Hit) -> BotGroupRoom? {
        guard let connection, hit.snapshot.scope == BotHistoryCache.Scope(server: server, connectionID: connection.id),
              let saved = hit.snapshot.cachedRoom else { return nil }
        if let current = rooms.first(where: { $0.id == saved.id }) { return current }
        return searchableRoomIDs == nil ? saved : nil
    }

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

    func setRoomPinned(_ pinned: Bool, _ room: BotGroupRoom) {
        if pinned { roomFlags.pinned.insert(room.id) } else { roomFlags.pinned.remove(room.id) }
        persistRoomFlags()
    }
    func setRoomHidden(_ hidden: Bool, _ room: BotGroupRoom) {
        if hidden { roomFlags.hidden.insert(room.id) } else { roomFlags.hidden.remove(room.id) }
        persistRoomFlags()
    }

    func setSectionOrder(_ ids: [String]) {
        guard let connection, ids != sectionOrder else { return }
        sectionOrder = ids
        sectionOrderStore.save(ids, server: server, connectionID: connection.id)
    }

    func placeReorderableSections(_ ids: [String]) {
        let listed = Set(ids)
        var next = ids[...]
        setSectionOrder(sectionNames.compactMap { section in
            if listed.contains(section.id) { return next.popFirst() }
            return sectionOrder.contains(section.id) ? section.id : nil
        })
    }

    func resetSectionOrder() { setSectionOrder([]) }

    func mayRenameRoom(_ room: BotGroupRoom) -> Bool { mayCommandRoom(room, "groups.rename") }
    func mayDisbandRoom(_ room: BotGroupRoom) -> Bool { mayCommandRoom(room, "groups.disband") }
    private func mayCommandRoom(_ room: BotGroupRoom, _ method: String) -> Bool {
        link == .live && roomCapabilities.methods.contains(method)
            && !room.isForeign(to: roomCapabilities.authority) && !editing.contains(ChatRow.room(room).id)
    }

    func renameRoom(_ room: BotGroupRoom, to name: String) async {
        guard mayRenameRoom(room), BotRoomRPC.validName(name), name != room.name, let client = wire else { return }
        await commandRoom(room, .groupsRename(roomID: room.id, eventID: UUID().uuidString, name: name), client) { result in
            guard let updated = BotGroupRoom(result["room"]), updated.id == room.id, !updated.disbanded
            else { throw BotFailure.unsupported }
            if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = updated }
        }
    }

    func disbandRoom(_ room: BotGroupRoom) async {
        guard mayDisbandRoom(room), let client = wire, let key = roomKey(room) else { return }
        let disbanded = await commandRoom(room, .groupsDisband(roomID: room.id), client) { result in
            guard result["tombstone"]["room_id"].text == room.id,
                  result["tombstone"]["disbanded_at"].number != nil else { throw BotFailure.unsupported }
            rooms.removeAll { $0.id == room.id }
            roomFlags.pinned.remove(room.id); roomFlags.hidden.remove(room.id); persistRoomFlags()
        }
        if disbanded { try? await historyCache.removeRoom(key) }
    }

    @discardableResult
    private func commandRoom(_ room: BotGroupRoom, _ call: HermesCall,
                             _ client: any BotTransport, accept: (BotJSON) throws -> Void) async -> Bool {
        let id = ChatRow.room(room).id
        editing.insert(id); notice = nil
        defer { editing.remove(id) }
        do {
            let result = try await client.call(call)
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

    private func refreshRooms(_ client: any BotTransport) async {
        do {
            let value = try await client.call(.groupsCapabilities)
            guard wire === client, !Task.isCancelled else { return }
            let capabilities = BotRoomCapabilities(value)
            roomCapabilities = capabilities
            guard capabilities.enabled else { rooms = []; hasRoomList = true; return }
            var found: [BotGroupRoom] = []
            var offset = 0
            while true {
                let page = try await client.call(.groupsList(offset: offset))
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
        guard wire === client, !Task.isCancelled else { return }
        await widgets.renderAvatars(profiles, server: server, connectionID: connection.id, photos: avatars)
    }

    private func drop(_ client: any BotTransport, error: Error) {
        reloadTask?.cancel(); reloadTask = nil; reloadWanted = false
        statusPollTask?.cancel(); statusPollTask = nil
        client.close(); wire = nil
        link = .disconnected
        let address = connection?.address
        guard BotConnectionAdvice.isRetryable(error) else {
            setLiveStatuses([:]); setReconnecting(false)
            routeFailures = 0; routeAdvice = nil
            errorMessage = address.map { BotConnectionAdvice.message(for: error, address: $0) }
                ?? (error as? BotFailure ?? .transport).localizedDescription
            needsSignIn = error as? BotFailure == .rejected(401)
            needsAddress = error as? BotFailure == .gatewayListener
            return
        }
        if Self.isRouteFailure(error) { routeFailures += 1 } else { routeFailures = 0; routeAdvice = nil }
        if routeFailures >= Self.routeFailuresBeforeAdvice, profiles.isEmpty, let address {
            routeAdvice = BotConnectionAdvice.message(for: error, address: address)
        }
        setLiveStatuses(liveStatuses, stale: !liveStatuses.isEmpty)
        if !profiles.isEmpty { setReconnecting(true) }
        reconnect.schedule { [weak self] in await self?.open() }
    }

    private func persistSeen() {
        guard let connection else { return }
        unread.save(seen, connectionID: connection.id)
    }
}

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

struct BotSectionOrderStore {
    var defaults: UserDefaults = .standard

    private func key(_ server: URL, _ connectionID: UUID) -> String {
        "bot-inbox-section-order." + connectionID.uuidString + "|" + server.absoluteString
    }

    func load(server: URL, connectionID: UUID) -> [String] {
        defaults.stringArray(forKey: key(server, connectionID)) ?? []
    }

    func save(_ ids: [String], server: URL, connectionID: UUID) {
        if ids.isEmpty { remove(server: server, connectionID: connectionID) }
        else { defaults.set(ids, forKey: key(server, connectionID)) }
    }

    func remove(server: URL, connectionID: UUID) {
        defaults.removeObject(forKey: key(server, connectionID))
    }
}

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
