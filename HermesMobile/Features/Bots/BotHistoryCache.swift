import CryptoKit
import Foundation

/// A bounded, disposable index of settled conversations this phone has loaded.
/// All disk access and text matching run on the actor, away from SwiftUI rendering.
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
        /// Optional server display hint (e.g. `"steer"`). Absent on snapshots
        /// saved before steering hints existed; decodes as nil.
        var displayKind: String? = nil

        /// Rebuild only the message projection, never cached commands or runtime state.
        var roomEvent: BotJSON? {
            guard let seq else { return nil }
            return .object(["seq": .number(Double(seq)), "kind": .string(role),
                "actor": .object(["id": memberID.map(BotJSON.string) ?? .null,
                                  "display_name": sender.map(BotJSON.string) ?? .null]),
                "payload": .object(["text": .string(text)]),
                "created_at": timestamp.map(BotJSON.number) ?? .null])
        }
    }
    struct Snapshot: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let scope: Scope
        let profileID: String
        let profileName: String?
        let root: String
        let tip: String
        let savedAt: Date
        let messages: [Message]
        var roomID: String? = nil
        var cursor: Int? = nil
        var earlierBoundary: Int? = nil

        /// Minimal identity for opening a saved room while its live list is unavailable.
        /// Runtime authority, members and permissions always come from groups.state.
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
    private let directory: URL?
    private var loaded = false
    private var needsPrunePersistence = false
    private var snapshots: [Snapshot] = []
    private struct RoomIdentity: Hashable {
        let scope: Scope
        let id: String
    }
    private var removedRooms: Set<RoomIdentity> = []
    private var removed: Set<Scope> = []
    private var clearedAt: [String: Date] = [:]

    /// A nil directory is an isolated memory cache, used by fixtures.
    init(directory: URL? = nil) { self.directory = directory }

    /// Replace the whole saved projection: undo, compression and changed roots
    /// must never leave old rows searchable under a refreshed canonical chat.
    func replace(scope: Scope, profileID: String, profileName: String? = nil, root: String, tip: String,
                 messages: [ChatMessage], receivedAt: Date = Date()) throws {
        try Task.checkCancellation()
        guard !removed.contains(scope), receivedAt > (clearedAt[scope.serverKey] ?? .distantPast) else { return }
        try load()
        if let previous = snapshots.first(where: { $0.scope == scope && $0.roomID == nil && $0.profileID == profileID }),
           previous.savedAt > receivedAt { return }
        var seen: Set<String> = []
        let rows = messages.suffix(Self.maximumMessages).compactMap { message -> Message? in
            guard let role = message.role, ["user", "assistant"].contains(role),
                  let text = message.content, !text.isEmpty,
                  text.utf8.count <= Self.maximumMessageBytes, seen.insert(message.id).inserted else { return nil }
            return Message(id: message.id, role: role, text: text, displayKind: message.displayKind)
        }
        if let previous = snapshots.first(where: { $0.scope == scope && $0.roomID == nil && $0.profileID == profileID }),
           previous.root == root, previous.tip == tip, previous.messages == rows,
           receivedAt.timeIntervalSince(previous.savedAt) < 60 { return }
        snapshots.removeAll { $0.scope == scope && $0.roomID == nil && $0.profileID == profileID }
        if !rows.isEmpty {
            snapshots.append(Snapshot(id: UUID(), scope: scope, profileID: profileID, profileName: profileName, root: root,
                                      tip: tip, savedAt: receivedAt, messages: rows))
        }
        try persist(prune(now: receivedAt))
    }

    func search(_ query: String, scope: Scope, profileIDs: Set<String>?, roomIDs: Set<String>? = [], now: Date = Date()) throws -> [Hit] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        try load()
        let previousCount = snapshots.count
        snapshots.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime }
        persistPruning(previousCount: previousCount)
        var hits: [Hit] = []
        for snapshot in snapshots.reversed() where snapshot.scope == scope
            && (snapshot.roomID.map { roomIDs?.contains($0) ?? true }
                ?? (profileIDs?.contains(snapshot.profileID) ?? true)) && now.timeIntervalSince(snapshot.savedAt) < Self.lifetime {
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

    /// Append overlapping replay pages by sequence. Coverage includes invisible events,
    /// while the disk projection contains only bounded user/member message text.
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
        // A gap cannot become a saved cursor: retain only the newly read window.
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
                memberID: event.payload["member_id"].text ?? event.actor["id"].text, timestamp: event.timestamp))
        }
        rows.sort { ($0.seq ?? 0) < ($1.seq ?? 0) }
        var boundary = overlaps ? min(previous?.earlierBoundary ?? since, since) : since
        if rows.count > Self.maximumMessages {
            boundary = max(boundary, rows[rows.count - Self.maximumMessages - 1].seq ?? boundary)
            rows = Array(rows.suffix(Self.maximumMessages))
        }
        let next = Snapshot(id: previous?.id ?? UUID(), scope: scope, profileID: "", profileName: room.name,
            root: "", tip: "", savedAt: max(previous?.savedAt ?? receivedAt, receivedAt), messages: rows,
            roomID: key.roomID, cursor: overlaps ? max(previous?.cursor ?? 0, cursor) : cursor,
            earlierBoundary: boundary)
        let cursorOnly = previous.map { $0.messages == next.messages && $0.earlierBoundary == next.earlierBoundary
            && $0.profileName == next.profileName } ?? false
        if cursorOnly, previous?.cursor == next.cursor { return }
        snapshots.removeAll { $0.scope == scope && $0.roomID == key.roomID }
        snapshots.append(next)
        // Invisible events move only the cursor: keep it in memory and let the next real
        // write persist it. After a kill, reopening re-reads from the older saved cursor
        // and the overlap merge above absorbs the repeated pages.
        guard !cursorOnly else { return }
        try persist(prune(now: receivedAt))
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

    /// Room IDs are permanently retired by expiry/disband. Revoke late page writes too.
    func removeRoom(_ key: BotRoomKey) throws {
        recent.remove { $0 == .room(key) }
        let scope = Scope(server: key.server, connectionID: key.connectionID)
        removedRooms.insert(.init(scope: scope, id: key.roomID))
        try load()
        snapshots.removeAll { $0.scope == scope && $0.roomID == key.roomID }
        try persist()
    }

    /// Call only with a complete authoritative room list, never a partial page.
    func retainRooms(_ ids: Set<String>, scope: Scope) throws {
        recent.remove {
            guard $0.scope == scope, case .room(let id) = $0.conversation else { return false }
            return !ids.contains(id)
        }
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

    /// Removal revokes queued writes from the old connection. Cache clearing
    /// allows later snapshots, but rejects writes captured before the clear.
    func remove(server: URL, connectionID: UUID? = nil, now: Date = Date()) throws {
        let key = Scope.key(server)
        recent.remove { $0.scope.serverKey == key && (connectionID == nil || $0.scope.connectionID == connectionID) }
        if let connectionID { removed.insert(Scope(server: server, connectionID: connectionID)) }
        else { clearedAt[key] = now }
        try load()
        snapshots.removeAll { $0.scope.serverKey == key && (connectionID == nil || $0.scope.connectionID == connectionID) }
        try persist()
    }

    /// Drops one deleted bot's snapshots. The scope stays writable for the other bots.
    func removeProfile(server: URL, connectionID: UUID, profileID: String) throws {
        recent.remove { $0 == .bot(server: server, connectionID: connectionID, profile: profileID) }
        let scope = Scope(server: server, connectionID: connectionID)
        try load()
        snapshots.removeAll { $0.scope == scope && $0.roomID == nil && $0.profileID == profileID }
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
        prune(now: Date())
        persistPruning(previousCount: previousCount)
    }

    /// Drops expired snapshots, then the oldest ones until the index fits the count and
    /// byte budget. Returns the encoded index so `persist` does not encode it again.
    @discardableResult
    private func prune(now: Date) -> Data? {
        snapshots.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime }
        if snapshots.count > 100 { snapshots.removeFirst(snapshots.count - 100) }
        // Use encoded bytes for the actual disk budget, including JSON escaping.
        // Under budget this is the only encode; each eviction re-encodes once.
        while !snapshots.isEmpty {
            if let data = try? JSONEncoder().encode(snapshots), data.count <= Self.maximumBytes { return data }
            snapshots.removeFirst()
        }
        return nil
    }

    /// Expiry cleanup must not prevent reading fresh messages when storage is
    /// temporarily unwritable. Keep it pending so the next search retries it.
    private func persistPruning(previousCount: Int) {
        needsPrunePersistence = needsPrunePersistence || snapshots.count != previousCount
        guard needsPrunePersistence else { return }
        do {
            try persist()
            needsPrunePersistence = false
        } catch {
            // Fresh in-memory results remain usable; retry on the next access.
        }
    }

    /// Writes the index atomically. Pass `encoded` only when it is `prune`'s
    /// result for the current `snapshots`.
    private func persist(_ encoded: Data? = nil) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (encoded ?? JSONEncoder().encode(snapshots)).write(to: directory.appendingPathComponent("history.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Recent rendered values, separate from the lossy on-disk search index. The lock
/// covers every access because screens read synchronously before their first frame,
/// while the history actor invalidates entries. Snapshots contain value types only:
/// no clients, callbacks, approval state, or credentials cross this boundary.
final class BotRecentTranscripts: @unchecked Sendable {
    enum Conversation: Hashable { case bot(String), room(String) }
    struct Key: Hashable {
        let scope: BotHistoryCache.Scope
        let conversation: Conversation
        static func bot(server: URL, connectionID: UUID, profile: String) -> Key {
            Key(scope: .init(server: server, connectionID: connectionID), conversation: .bot(profile))
        }
        static func room(_ room: BotRoomKey) -> Key {
            Key(scope: .init(server: room.server, connectionID: room.connectionID), conversation: .room(room.roomID))
        }
    }
    struct Bot {
        let root: String
        let messages: [ChatMessage]
        let activity: [BotSettledActivity]

        init(root: String, messages: [ChatMessage], activity: [BotSettledActivity]) {
            self.root = root
            self.messages = Array(messages.suffix(500))
            let ids = Set(self.messages.map(\.id))
            self.activity = Array(activity.filter { $0.anchorMessageID.map(ids.contains) ?? true }.suffix(500))
        }
    }
    enum Snapshot {
        case bot(Bot), room(BotRoomLog)
        var cost: Int {
            switch self {
            case .bot(let bot):
                let messages = bot.messages.reduce(0) { total, row in
                    total + 256 + (row.content?.utf8.count ?? 0) + (row.reasoning?.utf8.count ?? 0)
                        + JSONValue.object(row.displayMetadata ?? [:]).recentCost
                }
                let activity = bot.activity.reduce(0) { total, row in
                    total + 128 + (row.reasoning?.utf8.count ?? 0) + row.toolCalls.reduce(0) { total, tool in
                        total + 256 + (tool.preview?.utf8.count ?? 0) + JSONValue.object(tool.args ?? [:]).recentCost
                    }
                }
                return 2 * (messages + activity)
            case .room(let log):
                return 2 * log.events.reduce(0) { $0 + 256 + $1.payload.jsonValue.recentCost + $1.actor.jsonValue.recentCost }
            }
        }
    }
    private struct Entry {
        var owner: UUID
        var snapshot: Snapshot?
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

    func snapshot(for key: Key) -> Snapshot? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            access &+= 1; entry.access = access; entries[key] = entry
            return entry.snapshot
        }
    }

    /// Claim writes when a screen starts recovery, not during SwiftUI construction.
    /// A later owner or removal makes every older writer inert.
    func begin(_ key: Key) -> UUID {
        lock.withLock {
            let owner = UUID(); access &+= 1
            entries[key] = Entry(owner: owner, snapshot: entries[key]?.snapshot,
                                 cost: entries[key]?.cost ?? 0, access: access)
            prune()
            return owner
        }
    }

    func save(_ snapshot: Snapshot, for key: Key, owner: UUID) {
        let cost = snapshot.cost
        lock.withLock {
            guard entries[key]?.owner == owner else { return }
            guard cost <= maximumBytes else { entries.removeValue(forKey: key); return }
            access &+= 1
            entries[key] = Entry(owner: owner, snapshot: snapshot, cost: cost, access: access)
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
