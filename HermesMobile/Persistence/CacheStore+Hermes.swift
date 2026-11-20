import Foundation
import SwiftData

extension CacheStore {
    static func hermesScope(profile: String, lineageRoot: String) -> String {
        "hermes|\(profile)|\(lineageRoot)"
    }

    static func hermesSessionKey(serverURL: URL, profile: String, lineageRoot: String) -> String {
        "\(serverURL.absoluteString)|\(hermesScope(profile: profile, lineageRoot: lineageRoot))"
    }

    private static func hermesMessageKey(serverURL: URL, scope: String, rowID: Int) -> String {
        "\(serverURL.absoluteString)|\(scope)|row|\(rowID)"
    }

    static func hermesBotChatScope(connectionID: UUID, profile: String, root: String) -> String {
        hermesBotChatScopePrefix(connectionID: connectionID, profile: profile) + root
    }

    static func hermesArchivedBotChatScope(connectionID: UUID, profile: String, root: String) -> String {
        hermesBotChatScopePrefix(connectionID: connectionID, profile: profile, archived: true) + root
    }

    private static func hermesBotChatScopePrefix(connectionID: UUID, profile: String?, archived: Bool = false) -> String {
        "\(archived ? "hermes-bot-archive" : "hermes-bot")|\(connectionID.uuidString)|" + (profile.map { "\($0)|" } ?? "")
    }

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

    @MainActor
    static func hermesLineageRoot(forKey key: String, profile: String, serverURL: URL, in context: ModelContext) throws -> String? {
        let serverURLString = serverURL.absoluteString
        let prefix = hermesSessionKey(serverURL: serverURL, profile: profile, lineageRoot: "")
        let descriptor = FetchDescriptor<CachedSession>(predicate: #Predicate {
            $0.serverURLString == serverURLString && $0.sessionID == key
        })
        return try context.fetch(descriptor).first { $0.cacheKey.hasPrefix(prefix) }?.lineageRoot
    }

    @MainActor
    private static func hermesSessionRows(serverURL: URL, profile: String?, in context: ModelContext) throws -> [CachedSession] {
        let serverURLString = serverURL.absoluteString
        let prefix = profile.map { hermesSessionKey(serverURL: serverURL, profile: $0, lineageRoot: "") }
            ?? "\(serverURLString)|hermes|"
        let descriptor = FetchDescriptor<CachedSession>(predicate: #Predicate {
            $0.serverURLString == serverURLString && $0.cacheKey.starts(with: prefix)
        })
        return try context.fetch(descriptor)
    }

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

    @MainActor
    static func cachedHermesMessages(
        serverURL: URL,
        scope: String,
        in context: ModelContext,
        limit: Int,
        now: Date = Date()
    ) throws -> [ChatMessage] {
        try cachedHermesTranscript(serverURL: serverURL, scope: scope, in: context, limit: limit, now: now).messages
    }

    @MainActor
    static func cachedHermesTranscript(
        serverURL: URL,
        scope: String,
        in context: ModelContext,
        limit: Int,
        now: Date = Date()
    ) throws -> (messages: [ChatMessage], workAnchorIDs: Set<String>) {
        let serverURLString = serverURL.absoluteString
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate {
                $0.serverURLString == serverURLString && $0.sessionID == scope && $0.expiresAt > now
            },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let rows = try context.fetch(descriptor)
        return (rows.reversed().map(ChatMessage.init(cachedMessage:)),
                Set(rows.compactMap { $0.anchorsWork == true ? $0.messageId : nil }))
    }

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

    @MainActor
    static func cacheHermesMessages(
        _ messages: [ChatMessage],
        workAnchorIDs: Set<String> = [],
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
        let key = { (id: Int) in hermesMessageKey(serverURL: serverURL, scope: scope, rowID: id) }
        let (cachedByKey, start) = try dropHermesMessagesTheHostCut(keeping: Set(held.map { key($0.id) }), newestCoverage: newestCoverage,
                                                                    serverURL: serverURL, scope: scope, in: context)
        var written = Set<String>()
        for (offset, row) in held.enumerated() {
            let rowKey = key(row.id)
            guard written.insert(rowKey).inserted else { continue }
            let cachedRow: CachedMessage
            if let existing = cachedByKey[rowKey] {
                existing.refresh(from: row.message, sortIndex: start + offset, cachedAt: cachedAt)
                cachedRow = existing
            } else {
                cachedRow = CachedMessage(serverURLString: serverURLString, sessionID: scope, message: row.message,
                                          sortIndex: start + offset, cacheKey: rowKey, cachedAt: cachedAt)
                context.insert(cachedRow)
            }
            let anchorsWork = row.message.messageId.map(workAnchorIDs.contains) ?? false
            if (cachedRow.anchorsWork ?? false) != anchorsWork { cachedRow.anchorsWork = anchorsWork }
        }
        try saveAndTrim(context, now: cachedAt)
    }

    @MainActor
    static func dropHermesMessagesTheHostCut(
        from messages: [ChatMessage],
        newestCoverage: HermesNewestCoverage,
        serverURL: URL,
        scope: String,
        in context: ModelContext
    ) throws {
        let held = Set(messages.compactMap { $0.rowID.map { hermesMessageKey(serverURL: serverURL, scope: scope, rowID: $0) } })
        _ = try dropHermesMessagesTheHostCut(keeping: held, newestCoverage: newestCoverage, serverURL: serverURL,
                                             scope: scope, in: context)
        try context.save()
    }

    @MainActor
    private static func dropHermesMessagesTheHostCut(
        keeping held: Set<String>,
        newestCoverage: HermesNewestCoverage?,
        serverURL: URL,
        scope: String,
        in context: ModelContext
    ) throws -> (cachedByKey: [String: CachedMessage], start: Int) {
        let serverURLString = serverURL.absoluteString
        let cached = try context.fetch(FetchDescriptor<CachedMessage>(predicate: #Predicate {
            $0.serverURLString == serverURLString && $0.sessionID == scope
        }))
        let cachedByKey = Dictionary(cached.map { ($0.cacheKey, $0) }, uniquingKeysWith: { first, _ in first })
        let key = { (id: Int) in hermesMessageKey(serverURL: serverURL, scope: scope, rowID: id) }

        let covered: Int? = switch newestCoverage {
        case .all?: Int.min
        case .from(let ids)?: ids.lazy.compactMap { cachedByKey[key($0)]?.sortIndex }.first
        case nil: nil
        }
        var start = 0
        for row in cached where !held.contains(row.cacheKey) {
            if let covered, row.sortIndex > covered {
                context.delete(row)
            } else {
                start = max(start, row.sortIndex + 1)
            }
        }
        return (cachedByKey, start)
    }

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

    @MainActor
    static func removeHermesBotChatRoot(_ root: String, serverURL: URL, connectionID: UUID, profile: String, in context: ModelContext) throws {
        revokeHermesWriters(serverURL: serverURL)
        let serverURLString = serverURL.absoluteString
        let bot = hermesBotChatScope(connectionID: connectionID, profile: profile, root: root)
        let archived = hermesArchivedBotChatScope(connectionID: connectionID, profile: profile, root: root)
        try context.delete(model: CachedMessage.self, where: #Predicate {
            $0.serverURLString == serverURLString && ($0.sessionID == bot || $0.sessionID == archived)
        })
        try context.save()
    }

    @MainActor
    static func removeHermesBotChats(serverURL: URL, connectionID: UUID, profile: String? = nil, in context: ModelContext) throws {
        revokeHermesWriters(serverURL: serverURL)
        for archived in [false, true] {
            let prefix = hermesBotChatScopePrefix(connectionID: connectionID, profile: profile, archived: archived)
            try removeHermesBotChats(serverURL: serverURL, prefix: prefix, except: nil, in: context)
        }
    }

    @MainActor
    private static func removeHermesBotChats(serverURL: URL, prefix: String, except kept: String?, in context: ModelContext) throws {
        let serverURLString = serverURL.absoluteString
        let kept = kept ?? ""
        try context.delete(model: CachedMessage.self, where: #Predicate {
            $0.serverURLString == serverURLString && $0.sessionID.starts(with: prefix) && $0.sessionID != kept
        })
        try context.save()
    }

    @MainActor private static var hermesEpochs: [String: Int] = [:]

    @MainActor
    static func hermesCacheEpoch(serverURL: URL) -> Int {
        hermesEpochs[serverURL.absoluteString, default: 0]
    }

    @MainActor
    static func revokeHermesWriters(serverURL: URL) {
        hermesEpochs[serverURL.absoluteString, default: 0] &+= 1
    }
}
