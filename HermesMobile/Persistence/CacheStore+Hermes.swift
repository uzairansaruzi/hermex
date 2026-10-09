import Foundation
import SwiftData

/// The offline cache of a Hermes server's Sessions list and transcripts (#1054), in the webui
/// cache's tables, so sign-out, server removal and Clear Offline Cache (`clearCache(for:)`) take
/// them with the server's other rows.
///
/// A session is keyed `<server>|hermes|<Profile>|<lineage root>`, the list's identity, and keeps
/// the tip it opens by as `sessionID`. A message is keyed `<server>|hermes|<Profile>|<lineage
/// root>|row|<row id>`, with the scope `hermes|<Profile>|<lineage root>` as its `sessionID`. Each
/// Profile has its own store, so the same id in two never collides.
///
/// The list and a transcript arrive a page at a time, so no write sweeps what a page left out. A
/// session goes when this phone deleted or archived it, when a walk from the list's first page
/// reached its end without it, or by the TTL. A message goes when a newest read no longer holds
/// it inside the row ids that read covered, from its oldest row on (a rewind or undo), or by
/// the TTL or the cap.
///
/// A bot's Bot Chat (#1144) caches only its transcript, never a list row, under the scope
/// `hermes-bot|<connection>|<Profile>|<canonical root>`: the root `identify` finds is its
/// identity, which a compaction that moves its stored key leaves in place. A webui server's
/// list reads and sweeps every session row of its server, so the chat finds its root again
/// from its message rows, not from a session row.
extension CacheStore {
    /// A Hermes session's scope: the message rows' `sessionID`, and the tail of every key.
    static func hermesScope(profile: String, lineageRoot: String) -> String {
        "hermes|\(profile)|\(lineageRoot)"
    }

    static func hermesSessionKey(serverURL: URL, profile: String, lineageRoot: String) -> String {
        "\(serverURL.absoluteString)|\(hermesScope(profile: profile, lineageRoot: lineageRoot))"
    }

    static func hermesMessageKey(serverURL: URL, profile: String, lineageRoot: String, rowID: Int) -> String {
        hermesMessageKey(serverURL: serverURL, scope: hermesScope(profile: profile, lineageRoot: lineageRoot), rowID: rowID)
    }

    private static func hermesMessageKey(serverURL: URL, scope: String, rowID: Int) -> String {
        "\(serverURL.absoluteString)|\(scope)|row|\(rowID)"
    }

    /// A bot's Bot Chat's scope on the connection `connectionID`: the message rows' `sessionID`.
    static func hermesBotChatScope(connectionID: UUID, profile: String, root: String) -> String {
        hermesBotChatScopePrefix(connectionID: connectionID, profile: profile) + root
    }

    private static func hermesBotChatScopePrefix(connectionID: UUID, profile: String) -> String {
        "hermes-bot|\(connectionID.uuidString)|\(profile)|"
    }

    // MARK: Sessions

    /// `profile`'s unexpired cached sessions on `serverURL`, or every Profile's when nil (#709),
    /// latest activity first, as the host lists them; the list puts pinned rows first itself.
    @MainActor
    static func cachedHermesSessions(
        serverURL: URL,
        profile: String?,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [SessionSummary] {
        try hermesSessionRows(serverURL: serverURL, profile: profile, in: context)
            .filter { $0.expiresAt > now }
            .map(SessionSummary.init(cachedSession:))
            .sorted { ($0.lastMessageAt ?? $0.createdAt ?? 0) > ($1.lastMessageAt ?? $1.createdAt ?? 0) }
    }

    /// Upserts the Hermes list rows read so far, `rows` of `profile`'s list, without removing
    /// one they lack, unless `reachedEnd`: the walk then saw the whole list from its first page,
    /// so a cached row it lacks was deleted or archived elsewhere. Archived rows and Bot Chats
    /// are never cached. An unchanged row is rewritten only once `CachePolicy.rowRefreshInterval`
    /// has passed, so a list that reads again on every change dirties only what changed.
    @MainActor
    static func cacheHermesSessions(
        _ rows: [SessionSummary],
        profile: String,
        reachedEnd: Bool,
        serverURL: URL,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let signpost = performanceSignposter.beginInterval("Cache Write")
        defer { performanceSignposter.endInterval("Cache Write", signpost, "rows=\(rows.count, privacy: .public)") }

        let cached = try hermesSessionRows(serverURL: serverURL, profile: profile, in: context)
        var cachedByKey = Dictionary(cached.map { ($0.cacheKey, $0) }, uniquingKeysWith: { first, _ in first })
        var fresh = Set<String>()
        for row in rows {
            guard let hermes = row.hermes, !hermes.isBotChat, row.archived != true, row.sessionId != nil else { continue }
            let key = hermesSessionKey(serverURL: serverURL, profile: profile, lineageRoot: hermes.lineageRoot)
            guard fresh.insert(key).inserted else { continue }
            if let existing = cachedByKey[key] {
                if SessionSummary(cachedSession: existing) != row
                    || cachedAt.timeIntervalSince(existing.cachedAt) >= CachePolicy.rowRefreshInterval {
                    existing.apply(row, cachedAt: cachedAt)
                }
            } else {
                let inserted = CachedSession(serverURLString: serverURL.absoluteString, session: row, cacheKey: key,
                                             cachedAt: cachedAt)
                context.insert(inserted)
                cachedByKey[key] = inserted
            }
        }
        if reachedEnd {
            for row in cached where !fresh.contains(row.cacheKey) {
                context.delete(row)
            }
        }
        try saveAndTrim(context, now: cachedAt)
    }

    /// Removes a session this phone deleted or archived, with its transcript.
    @MainActor
    static func removeHermesSession(lineageRoot: String, profile: String, serverURL: URL, in context: ModelContext) throws {
        let key = hermesSessionKey(serverURL: serverURL, profile: profile, lineageRoot: lineageRoot)
        try context.delete(model: CachedSession.self, where: #Predicate { $0.cacheKey == key })
        let serverURLString = serverURL.absoluteString
        let scope = hermesScope(profile: profile, lineageRoot: lineageRoot)
        try context.delete(model: CachedMessage.self, where: #Predicate {
            $0.serverURLString == serverURLString && $0.sessionID == scope
        })
        try context.save()
    }

    /// The lineage root of `profile`'s cached row whose tip is `key`, so a chat opened by its key
    /// reads and writes the transcript under the list's identity. Nil when no cached row has it.
    @MainActor
    static func hermesLineageRoot(forKey key: String, profile: String, serverURL: URL, in context: ModelContext) throws -> String? {
        let serverURLString = serverURL.absoluteString
        let prefix = hermesSessionKey(serverURL: serverURL, profile: profile, lineageRoot: "")
        let descriptor = FetchDescriptor<CachedSession>(predicate: #Predicate {
            $0.serverURLString == serverURLString && $0.sessionID == key
        })
        return try context.fetch(descriptor).first { $0.cacheKey.hasPrefix(prefix) }?.lineageRoot
    }

    /// Every cached session of `profile` on `serverURL`, or of every Profile when nil, expired
    /// ones included.
    @MainActor
    private static func hermesSessionRows(serverURL: URL, profile: String?, in context: ModelContext) throws -> [CachedSession] {
        let serverURLString = serverURL.absoluteString
        let prefix = profile.map { hermesSessionKey(serverURL: serverURL, profile: $0, lineageRoot: "") }
            ?? "\(serverURLString)|hermes|"
        let descriptor = FetchDescriptor<CachedSession>(predicate: #Predicate { $0.serverURLString == serverURLString })
        return try context.fetch(descriptor).filter { $0.cacheKey.hasPrefix(prefix) }
    }

    // MARK: Transcripts

    /// The newest `limit` unexpired cached messages of a Hermes session, oldest first.
    @MainActor
    static func cachedHermesMessages(
        serverURL: URL,
        profile: String,
        lineageRoot: String,
        in context: ModelContext,
        limit: Int,
        now: Date = Date()
    ) throws -> [ChatMessage] {
        try cachedHermesMessages(serverURL: serverURL, scope: hermesScope(profile: profile, lineageRoot: lineageRoot),
                                 in: context, limit: limit, now: now)
    }

    /// The newest `limit` unexpired cached messages under `scope`, a session's or a Bot Chat's,
    /// oldest first.
    @MainActor
    static func cachedHermesMessages(
        serverURL: URL,
        scope: String,
        in context: ModelContext,
        limit: Int,
        now: Date = Date()
    ) throws -> [ChatMessage] {
        let serverURLString = serverURL.absoluteString
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate {
                $0.serverURLString == serverURLString && $0.sessionID == scope && $0.expiresAt > now
            },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).reversed().map(ChatMessage.init(cachedMessage:))
    }

    /// Upserts a Hermes session's settled history as the chat holds it, `messages` in its
    /// order: the rows held, back from the newest. Rows without a `rowID` (the running turn's,
    /// the chat's own) are skipped. A cached row not held here, from an older page an earlier
    /// visit read, keeps its place before them, unless it sits in the part the last newest read
    /// covered (`newestCoverage`): after the first of that read's rows the cache holds, or
    /// anywhere once it reached the first row. Then the host cut it, and it goes.
    @MainActor
    static func cacheHermesMessages(
        _ messages: [ChatMessage],
        newestCoverage: HermesNewestCoverage?,
        serverURL: URL,
        profile: String,
        lineageRoot: String,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        try cacheHermesMessages(messages, newestCoverage: newestCoverage, serverURL: serverURL,
                                scope: hermesScope(profile: profile, lineageRoot: lineageRoot), in: context, cachedAt: cachedAt)
    }

    /// `cacheHermesMessages` under `scope`, a session's or a Bot Chat's.
    @MainActor
    static func cacheHermesMessages(
        _ messages: [ChatMessage],
        newestCoverage: HermesNewestCoverage?,
        serverURL: URL,
        scope: String,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let held = messages.compactMap { message in message.rowID.map { (id: $0, message: message) } }
        let signpost = performanceSignposter.beginInterval("Cache Write")
        defer { performanceSignposter.endInterval("Cache Write", signpost, "rows=\(held.count, privacy: .public)") }

        let serverURLString = serverURL.absoluteString
        let cached = try context.fetch(FetchDescriptor<CachedMessage>(predicate: #Predicate {
            $0.serverURLString == serverURLString && $0.sessionID == scope
        }))
        let cachedByKey = Dictionary(cached.map { ($0.cacheKey, $0) }, uniquingKeysWith: { first, _ in first })
        let key = { (id: Int) in hermesMessageKey(serverURL: serverURL, scope: scope, rowID: id) }
        let heldKeys = Set(held.map { key($0.id) })

        // Where the newest read's part starts in the cache's order.
        let covered: Int? = switch newestCoverage {
        case .all?: Int.min
        case .from(let ids)?: ids.lazy.compactMap { cachedByKey[key($0)]?.sortIndex }.first
        case nil: nil
        }
        var start = 0
        for row in cached where !heldKeys.contains(row.cacheKey) {
            if let covered, row.sortIndex > covered {
                context.delete(row)
            } else {
                start = max(start, row.sortIndex + 1)
            }
        }
        var written = Set<String>()
        for (offset, row) in held.enumerated() {
            let rowKey = key(row.id)
            guard written.insert(rowKey).inserted else { continue }
            if let existing = cachedByKey[rowKey] {
                existing.refresh(from: row.message, sortIndex: start + offset, cachedAt: cachedAt)
            } else {
                context.insert(CachedMessage(serverURLString: serverURLString, sessionID: scope, message: row.message,
                                             sortIndex: start + offset, cacheKey: rowKey, cachedAt: cachedAt))
            }
        }
        try saveAndTrim(context, now: cachedAt)
    }

    // MARK: Bot Chat

    /// The canonical root of the Bot Chat transcript cached for `profile` on `connectionID`, so
    /// the chat shows it before its attach finds the root. Nil when none is cached.
    @MainActor
    static func cachedHermesBotChatRoot(
        serverURL: URL,
        connectionID: UUID,
        profile: String,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> String? {
        let serverURLString = serverURL.absoluteString
        let prefix = hermesBotChatScopePrefix(connectionID: connectionID, profile: profile)
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate {
                $0.serverURLString == serverURLString && $0.sessionID.starts(with: prefix) && $0.expiresAt > now
            },
            sortBy: [SortDescriptor(\.cachedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map { String($0.sessionID.dropFirst(prefix.count)) }
    }

    /// Removes the Bot Chat transcripts cached for `profile` on `connectionID` under any root but
    /// `root`: the attach found another canonical root, a Bot Chat made again.
    @MainActor
    static func removeHermesBotChats(
        exceptRoot root: String,
        serverURL: URL,
        connectionID: UUID,
        profile: String,
        in context: ModelContext
    ) throws {
        let prefix = hermesBotChatScopePrefix(connectionID: connectionID, profile: profile)
        try removeHermesBotChats(serverURL: serverURL, prefix: prefix, except: prefix + root, in: context)
    }

    /// Removes the Bot Chat transcripts cached on `connectionID`, only `profile`'s when given: a
    /// deleted Profile's, or a discarded connection's. A chat's write already under way can't put
    /// them back (`hermesCacheEpoch`).
    @MainActor
    static func removeHermesBotChats(serverURL: URL, connectionID: UUID, profile: String? = nil, in context: ModelContext) throws {
        revokeHermesWriters(serverURL: serverURL)
        let prefix = profile.map { hermesBotChatScopePrefix(connectionID: connectionID, profile: $0) }
            ?? "hermes-bot|\(connectionID.uuidString)|"
        try removeHermesBotChats(serverURL: serverURL, prefix: prefix, except: nil, in: context)
    }

    @MainActor
    private static func removeHermesBotChats(serverURL: URL, prefix: String, except kept: String?, in context: ModelContext) throws {
        let serverURLString = serverURL.absoluteString
        // No scope is empty, so an empty `kept` keeps nothing.
        let kept = kept ?? ""
        try context.delete(model: CachedMessage.self, where: #Predicate {
            $0.serverURLString == serverURLString && $0.sessionID.starts(with: prefix) && $0.sessionID != kept
        })
        try context.save()
    }

    // MARK: Writers

    /// Each server's Hermes cache epoch. Clearing the server's cache, or removing a Profile's or
    /// connection's Bot Chats, moves it on, so a write that began before can't put back what
    /// went (#628).
    @MainActor private static var hermesEpochs: [String: Int] = [:]

    /// The epoch a Hermes chat takes at each attach, before its reads. The chat writes to the
    /// cache only while it is still the server's.
    @MainActor
    static func hermesCacheEpoch(serverURL: URL) -> Int {
        hermesEpochs[serverURL.absoluteString, default: 0]
    }

    /// Ends every Hermes chat's writes to `serverURL`'s cache until its next attach.
    @MainActor
    static func revokeHermesWriters(serverURL: URL) {
        hermesEpochs[serverURL.absoluteString, default: 0] &+= 1
    }
}
