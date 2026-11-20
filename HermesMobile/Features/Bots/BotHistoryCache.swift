import CryptoKit
import Foundation

actor BotHistoryCache {
    nonisolated let recent = BotRecentTranscripts()
    struct Scope: Codable, Hashable, Sendable {
        let serverKey: String
        let connectionID: UUID
        init(server: URL, connectionID: UUID) {
            serverKey = Self.key(server)
            self.connectionID = connectionID
        }
        static func key(_ server: URL) -> String {
            SHA256.hash(data: Data(server.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Message: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let role: String
        let text: String
        var seq: Int? = nil
        var sender: String? = nil
        var memberID: String? = nil
        var timestamp: Double? = nil
        var displayKind: String? = nil
        var threadID: String? = nil
        var eventID: String? = nil

        var roomEvent: BotJSON? {
            guard let seq else { return nil }
            return .object(["seq": .number(Double(seq)), "kind": .string(role),
                "event_id": eventID.map(BotJSON.string) ?? .null,
                "actor": .object(["id": memberID.map(BotJSON.string) ?? .null,
                                  "display_name": sender.map(BotJSON.string) ?? .null]),
                "payload": .object(["text": .string(text), "thread_id": threadID.map(BotJSON.string) ?? .null]),
                "created_at": timestamp.map(BotJSON.number) ?? .null])
        }
    }
    struct Snapshot: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let scope: Scope
        let profileName: String?
        let savedAt: Date
        let messages: [Message]
        var roomID: String? = nil
        var cursor: Int? = nil
        var earlierBoundary: Int? = nil

        var cachedRoom: BotGroupRoom? {
            guard let roomID else { return nil }
            return BotGroupRoom(.object(["room_id": .string(roomID),
                "name": .string(profileName ?? roomID), "latest_seq": .number(Double(cursor ?? 0))]))
        }

        var replayPage: BotJSON {
            .object(["events": .array(messages.compactMap(\.roomEvent)),
                     "cursor": .number(Double(cursor ?? 0))])
        }
    }
    struct Hit: Identifiable, Equatable, Sendable {
        var id: String { "\(snapshot.id)/\(message.id)" }
        let snapshot: Snapshot
        let message: Message
        let excerpt: String
    }

    static let shared = BotHistoryCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BotHistory", isDirectory: true))
    static let maximumMessages = 500
    static let maximumMessageBytes = 16_384
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumHits = 100
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let cursorOnlySaveInterval: TimeInterval = 10 * 60
    private let directory: URL?
    private var loaded = false
    private var needsPrunePersistence = false
    private var lastRoomWriteAt = Date.distantPast
    private var snapshots: [Snapshot] = []
    private struct RoomIdentity: Hashable {
        let scope: Scope
        let id: String
    }
    private var removedRooms: Set<RoomIdentity> = []
    private var removed: Set<Scope> = []
    private var clearedAt: [String: Date] = [:]

    init(directory: URL? = nil) { self.directory = directory }

    func search(_ query: String, scope: Scope, roomIDs: Set<String>?, now: Date = Date()) throws -> [Hit] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        try load()
        let previousCount = snapshots.count
        snapshots.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime }
        persistPruning(previousCount: previousCount)
        var hits: [Hit] = []
        for snapshot in snapshots.reversed() where snapshot.scope == scope
            && snapshot.roomID.map { roomIDs?.contains($0) ?? true } == true
            && now.timeIntervalSince(snapshot.savedAt) < Self.lifetime {
            for message in snapshot.messages.reversed() {
                try Task.checkCancellation()
                guard let range = message.text.range(of: query, options: .caseInsensitive) else { continue }
                let start = message.text.index(range.lowerBound, offsetBy: -55, limitedBy: message.text.startIndex) ?? message.text.startIndex
                let end = message.text.index(range.upperBound, offsetBy: 100, limitedBy: message.text.endIndex) ?? message.text.endIndex
                let excerpt = (start == message.text.startIndex ? "" : "…") + String(message.text[start..<end])
                    + (end == message.text.endIndex ? "" : "…")
                hits.append(Hit(snapshot: snapshot, message: message, excerpt: excerpt))
                if hits.count == Self.maximumHits { return hits }
            }
        }
        return hits
    }

    func appendRoom(key: BotRoomKey, room: BotGroupRoom, page: BotJSON, since: Int,
                    receivedAt: Date = Date()) throws {
        try Task.checkCancellation()
        let scope = Scope(server: key.server, connectionID: key.connectionID)
        guard !removed.contains(scope), !removedRooms.contains(.init(scope: scope, id: key.roomID)),
              receivedAt > (clearedAt[scope.serverKey] ?? .distantPast),
              room.id == key.roomID, !room.disbanded,
              let cursor = page["cursor"].integer, cursor >= since else { return }
        try load()
        let previous = snapshots.first { $0.scope == scope && $0.roomID == key.roomID }
        let overlaps = previous.map { since <= ($0.cursor ?? 0) && cursor >= ($0.earlierBoundary ?? 0) } ?? false
        var rows = overlaps ? previous?.messages ?? [] : []
        var seen = Set(rows.compactMap(\.seq))
        for value in page["events"].list ?? [] {
            guard value["room_id"].text == key.roomID, let event = BotRoomEvent(value),
                  event.seq > since, event.seq <= cursor,
                  ["message.user", "message.member"].contains(event.kind),
                  let text = event.payload["text"].text, !text.isEmpty,
                  text.utf8.count <= Self.maximumMessageBytes, seen.insert(event.seq).inserted else { continue }
            rows.append(Message(id: String(event.seq), role: event.kind, text: text, seq: event.seq,
                sender: event.kind == "message.user" ? String(localized: "You") : event.sender(in: room),
                memberID: event.payload["member_id"].text ?? event.actor["id"].text, timestamp: event.timestamp, threadID: event.threadID, eventID: event.eventID))
        }
        rows.sort { ($0.seq ?? 0) < ($1.seq ?? 0) }
        var boundary = overlaps ? min(previous?.earlierBoundary ?? since, since) : since
        if rows.count > Self.maximumMessages {
            boundary = max(boundary, rows[rows.count - Self.maximumMessages - 1].seq ?? boundary)
            rows = Array(rows.suffix(Self.maximumMessages))
        }
        let next = Snapshot(id: previous?.id ?? UUID(), scope: scope, profileName: room.name,
            savedAt: max(previous?.savedAt ?? receivedAt, receivedAt), messages: rows, roomID: key.roomID,
            cursor: overlaps ? max(previous?.cursor ?? 0, cursor) : cursor, earlierBoundary: boundary)
        let cursorOnly = previous.map { $0.messages == next.messages && $0.earlierBoundary == next.earlierBoundary
            && $0.profileName == next.profileName } ?? false
        if cursorOnly, previous?.cursor == next.cursor { return }
        snapshots.removeAll { $0.scope == scope && $0.roomID == key.roomID }
        snapshots.append(next)
        guard !cursorOnly || receivedAt.timeIntervalSince(lastRoomWriteAt) >= Self.cursorOnlySaveInterval else { return }
        try persist(prune(now: receivedAt))
        lastRoomWriteAt = receivedAt
    }

    func roomHistory(_ key: BotRoomKey, now: Date = Date()) throws -> Snapshot? {
        try Task.checkCancellation()
        try load()
        let previousCount = snapshots.count
        snapshots.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime }
        persistPruning(previousCount: previousCount)
        let scope = Scope(server: key.server, connectionID: key.connectionID)
        return snapshots.first { $0.scope == scope && $0.roomID == key.roomID }
    }

    func removeRoom(_ key: BotRoomKey) throws {
        recent.remove { $0 == .init(key) }
        let scope = Scope(server: key.server, connectionID: key.connectionID)
        removedRooms.insert(.init(scope: scope, id: key.roomID))
        try load()
        snapshots.removeAll { $0.scope == scope && $0.roomID == key.roomID }
        try persist()
    }

    func retainRooms(_ ids: Set<String>, scope: Scope) throws {
        recent.remove { $0.scope == scope && !ids.contains($0.roomID) }
        try load()
        let removed = snapshots.compactMap { snapshot -> String? in
            guard snapshot.scope == scope, let id = snapshot.roomID, !ids.contains(id) else { return nil }
            return id
        }
        guard !removed.isEmpty else { return }
        removedRooms.formUnion(removed.map { RoomIdentity(scope: scope, id: $0) })
        snapshots.removeAll { $0.scope == scope && $0.roomID.map { !ids.contains($0) } == true }
        try persist()
    }

    func remove(server: URL, connectionID: UUID? = nil, now: Date = Date()) throws {
        let key = Scope.key(server)
        recent.remove { $0.scope.serverKey == key && (connectionID == nil || $0.scope.connectionID == connectionID) }
        if let connectionID { removed.insert(Scope(server: server, connectionID: connectionID)) }
        else { clearedAt[key] = now }
        try load()
        snapshots.removeAll { $0.scope.serverKey == key && (connectionID == nil || $0.scope.connectionID == connectionID) }
        try persist()
    }

    func removeServer(_ server: URL, activeConnectionID: UUID?) throws {
        let key = Scope.key(server)
        recent.remove { $0.scope.serverKey == key }
        if let activeConnectionID { removed.insert(Scope(server: server, connectionID: activeConnectionID)) }
        try load()
        removed.formUnion(snapshots.filter { $0.scope.serverKey == key }.map(\.scope))
        try remove(server: server)
    }

    private func load() throws {
        guard !loaded else { return }
        loaded = true
        guard let directory else { return }
        let file = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumBytes * 2 else { return }
        snapshots = try JSONDecoder().decode([Snapshot].self, from: Data(contentsOf: file))
        let previousCount = snapshots.count
        snapshots.removeAll { $0.roomID == nil }
        lastRoomWriteAt = snapshots.map(\.savedAt).max() ?? .distantPast
        prune(now: Date())
        persistPruning(previousCount: previousCount)
    }

    @discardableResult
    private func prune(now: Date) -> Data? {
        snapshots.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime }
        if snapshots.count > 100 { snapshots.removeFirst(snapshots.count - 100) }
        while !snapshots.isEmpty {
            if let data = try? JSONEncoder().encode(snapshots), data.count <= Self.maximumBytes { return data }
            snapshots.removeFirst()
        }
        return nil
    }

    private func persistPruning(previousCount: Int) {
        needsPrunePersistence = needsPrunePersistence || snapshots.count != previousCount
        guard needsPrunePersistence else { return }
        do {
            try persist()
            needsPrunePersistence = false
        } catch {
        }
    }

    private func persist(_ encoded: Data? = nil) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (encoded ?? JSONEncoder().encode(snapshots)).write(to: directory.appendingPathComponent("history.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

actor BotRosterCache {
    typealias Scope = BotHistoryCache.Scope

    static let shared = BotRosterCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BotRoster", isDirectory: true))
    static let maximumRows = 200
    static let maximumBytes = 2 * 1024 * 1024
    private let directory: URL
    private var savedReadAt: [Scope: ContinuousClock.Instant] = [:]
    private var removedAt: [String: ContinuousClock.Instant] = [:]
    private let willLoad: @Sendable () async -> Void

    init(directory: URL, willLoad: @escaping @Sendable () async -> Void = {}) {
        self.directory = directory; self.willLoad = willLoad
    }

    func load(_ scope: Scope) async -> [BotJSON]? {
        await willLoad()
        let file = file(scope)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([BotJSON].self, from: data),
              !rows.isEmpty, rows.count <= Self.maximumRows else { return nil }
        return rows
    }

    func save(_ rows: [BotJSON], scope: Scope, readAt: ContinuousClock.Instant) {
        let revoked = [removedAt[scope.serverKey], removedAt[name(scope)], savedReadAt[scope]].compactMap { $0 }
        guard revoked.allSatisfy({ $0 < readAt }) else { return }
        savedReadAt[scope] = readAt
        guard !rows.isEmpty, rows.count <= Self.maximumRows,
              let data = try? JSONEncoder().encode(rows), data.count <= Self.maximumBytes else {
            try? FileManager.default.removeItem(at: file(scope))
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(server: URL, connectionID: UUID? = nil, now: ContinuousClock.Instant = .now) {
        let key = Scope.key(server)
        let prefix = connectionID.map { name(.init(server: server, connectionID: $0)) } ?? key
        removedAt[prefix] = now
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix + (connectionID == nil ? "-" : ".")) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func name(_ scope: Scope) -> String { scope.serverKey + "-" + scope.connectionID.uuidString }
    private func file(_ scope: Scope) -> URL { directory.appendingPathComponent(name(scope) + ".json") }
}

final class BotRecentTranscripts: @unchecked Sendable {
    struct Key: Hashable {
        let scope: BotHistoryCache.Scope
        let roomID: String
        init(_ room: BotRoomKey) {
            scope = .init(server: room.server, connectionID: room.connectionID); roomID = room.roomID
        }
    }
    private struct Entry {
        var owner: UUID
        var log: BotRoomLog?
        var cost: Int
        var access: UInt64
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var access: UInt64 = 0
    private let maximumEntries: Int
    private let maximumBytes: Int

    init(maximumEntries: Int = 12, maximumBytes: Int = 8 * 1024 * 1024) {
        self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes
    }

    func log(for key: Key) -> BotRoomLog? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            access &+= 1; entry.access = access; entries[key] = entry
            return entry.log
        }
    }

    func begin(_ key: Key) -> UUID {
        lock.withLock {
            let owner = UUID(); access &+= 1
            entries[key] = Entry(owner: owner, log: entries[key]?.log,
                                 cost: entries[key]?.cost ?? 0, access: access)
            prune()
            return owner
        }
    }

    func save(_ log: BotRoomLog, for key: Key, owner: UUID) {
        let cost = 2 * log.events.reduce(0) { $0 + 256 + $1.payload.jsonValue.recentCost + $1.actor.jsonValue.recentCost }
        lock.withLock {
            guard entries[key]?.owner == owner else { return }
            guard cost <= maximumBytes else { entries.removeValue(forKey: key); return }
            access &+= 1
            entries[key] = Entry(owner: owner, log: log, cost: cost, access: access)
            prune()
        }
    }

    func remove(where matches: (Key) -> Bool) {
        lock.withLock { entries = entries.filter { !matches($0.key) } }
    }

    private func prune() {
        var bytes = entries.values.reduce(0) { $0 + $1.cost }
        while entries.count > maximumEntries || bytes > maximumBytes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            bytes -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
        }
    }
}

private extension JSONValue {
    var recentCost: Int {
        switch self {
        case .string(let text): return 32 + text.utf8.count
        case .array(let values): return 32 + values.reduce(0) { $0 + $1.recentCost }
        case .object(let fields): return 32 + fields.reduce(0) { $0 + 32 + $1.key.utf8.count + $1.value.recentCost }
        default: return 16
        }
    }
}
