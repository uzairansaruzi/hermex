import CryptoKit
import Foundation

/// A bounded, disposable index of settled conversations this phone has loaded.
/// All disk access and text matching run on the actor, away from SwiftUI rendering.
actor BotHistoryCache {
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
        /// Optional server display hint (e.g. `"steer"`). Absent on snapshots
        /// saved before steering hints existed; decodes as nil.
        let displayKind: String?

        init(id: String, role: String, text: String, displayKind: String? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.displayKind = displayKind
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
        if let previous = snapshots.first(where: { $0.scope == scope && $0.profileID == profileID }),
           previous.savedAt > receivedAt { return }
        var seen: Set<String> = []
        let rows = messages.suffix(Self.maximumMessages).compactMap { message -> Message? in
            guard let role = message.role, ["user", "assistant"].contains(role),
                  let text = message.content, !text.isEmpty,
                  text.utf8.count <= Self.maximumMessageBytes, seen.insert(message.id).inserted else { return nil }
            return Message(id: message.id, role: role, text: text, displayKind: message.displayKind)
        }
        if let previous = snapshots.first(where: { $0.scope == scope && $0.profileID == profileID }),
           previous.root == root, previous.tip == tip, previous.messages == rows,
           receivedAt.timeIntervalSince(previous.savedAt) < 60 { return }
        snapshots.removeAll { $0.scope == scope && $0.profileID == profileID }
        if !rows.isEmpty {
            snapshots.append(Snapshot(id: UUID(), scope: scope, profileID: profileID, profileName: profileName, root: root,
                                      tip: tip, savedAt: receivedAt, messages: rows))
        }
        prune(now: receivedAt)
        try persist()
    }

    func search(_ query: String, scope: Scope, profileIDs: Set<String>?, now: Date = Date()) throws -> [Hit] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        try load()
        let previousCount = snapshots.count
        snapshots.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime }
        persistPruning(previousCount: previousCount)
        var hits: [Hit] = []
        for snapshot in snapshots.reversed() where snapshot.scope == scope
            && (profileIDs?.contains(snapshot.profileID) ?? true) && now.timeIntervalSince(snapshot.savedAt) < Self.lifetime {
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

    /// Removal revokes queued writes from the old connection. Cache clearing
    /// allows later snapshots, but rejects writes captured before the clear.
    func remove(server: URL, connectionID: UUID? = nil, now: Date = Date()) throws {
        let key = Scope.key(server)
        if let connectionID { removed.insert(Scope(server: server, connectionID: connectionID)) }
        else { clearedAt[key] = now }
        try load()
        snapshots.removeAll { $0.scope.serverKey == key && (connectionID == nil || $0.scope.connectionID == connectionID) }
        try persist()
    }

    /// Drops one deleted bot's snapshots. The scope stays writable for the other bots.
    func removeProfile(server: URL, connectionID: UUID, profileID: String) throws {
        let scope = Scope(server: server, connectionID: connectionID)
        try load()
        snapshots.removeAll { $0.scope == scope && $0.profileID == profileID }
        try persist()
    }

    func removeServer(_ server: URL, activeConnectionID: UUID?) throws {
        let key = Scope.key(server)
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

    private func prune(now: Date) {
        snapshots.removeAll { now.timeIntervalSince($0.savedAt) >= Self.lifetime }
        // Use encoded bytes for the actual disk budget, including JSON escaping.
        while !snapshots.isEmpty && (snapshots.count > 100 || ((try? JSONEncoder().encode(snapshots).count) ?? Int.max) > Self.maximumBytes) {
            snapshots.removeFirst()
        }
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

    private func persist() throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshots).write(to: directory.appendingPathComponent("history.json"),
                                                 options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
