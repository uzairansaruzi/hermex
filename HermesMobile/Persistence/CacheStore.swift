import Foundation
import SwiftData

enum CacheStore {
    @MainActor
    static func cachedSessions(
        serverURL: URL,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [SessionSummary] {
        let serverURLString = serverURL.absoluteString
        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )

        return try context.fetch(descriptor)
            .filter { $0.archived != true && $0.expiresAt > now }
            .map(SessionSummary.init(cachedSession:))
    }

    @MainActor
    static func cachedMessages(
        serverURL: URL,
        sessionID: String,
        in context: ModelContext,
        limit: Int? = nil,
        now: Date = Date()
    ) throws -> [ChatMessage] {
        if let limit, limit <= 0 {
            return []
        }

        let serverURLString = serverURL.absoluteString
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
                    && cachedMessage.sessionID == sessionID
                    && cachedMessage.expiresAt > now
            },
            sortBy: [
                SortDescriptor(
                    \CachedMessage.sortIndex,
                    order: limit == nil ? .forward : .reverse
                )
            ]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }

        let cachedMessages = try context.fetch(descriptor)
        if limit != nil {
            return cachedMessages.reversed().map(ChatMessage.init(cachedMessage:))
        }
        return cachedMessages.map(ChatMessage.init(cachedMessage:))
    }

    @MainActor
    static func cacheSessions(
        _ sessions: [SessionSummary],
        serverURL: URL,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let serverURLString = serverURL.absoluteString
        let cacheableSessions = sessions.filter { $0.archived != true && $0.sessionId != nil }
        let freshKeys = Set(cacheableSessions.compactMap { session -> String? in
            guard let sessionID = session.sessionId else { return nil }
            return CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
        })

        // One server-scoped fetch serves both the upsert lookups and the stale
        // sweep, mirroring `cacheMessages`. Inserted rows join the dictionary so a
        // duplicate session in the response updates that row instead of inserting
        // a second one with the same unique key.
        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )
        let cachedSessions = try context.fetch(descriptor)
        var cachedSessionsByKey = cachedSessions.reduce(into: [String: CachedSession]()) {
            $0[$1.cacheKey] = $1
        }

        for session in cacheableSessions {
            guard let sessionID = session.sessionId else { continue }
            let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
            if let cachedSession = cachedSessionsByKey[cacheKey] {
                cachedSession.apply(session, cachedAt: cachedAt)
            } else {
                let cachedSession = CachedSession(serverURLString: serverURLString, session: session, cachedAt: cachedAt)
                context.insert(cachedSession)
                cachedSessionsByKey[cacheKey] = cachedSession
            }
        }

        let staleSessions = cachedSessions.filter { !freshKeys.contains($0.cacheKey) }
        for staleSession in staleSessions {
            context.delete(staleSession)
        }

        try saveAndTrim(context, now: cachedAt)
    }

    @MainActor
    static func cacheSession(
        _ session: SessionSummary,
        serverURL: URL,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        guard let sessionID = session.sessionId else { return }

        let serverURLString = serverURL.absoluteString
        let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)

        if session.archived == true {
            if let cachedSession = try cachedSession(cacheKey: cacheKey, in: context) {
                context.delete(cachedSession)
            }
        } else if let cachedSession = try cachedSession(cacheKey: cacheKey, in: context) {
            cachedSession.apply(session, cachedAt: cachedAt)
        } else {
            context.insert(CachedSession(serverURLString: serverURLString, session: session, cachedAt: cachedAt))
        }

        try saveAndTrim(context, now: cachedAt)
    }

    @MainActor
    static func cacheMessages(
        _ messages: [ChatMessage],
        serverURL: URL,
        sessionID: String,
        in context: ModelContext,
        cachedAt: Date = Date()
    ) throws {
        let serverURLString = serverURL.absoluteString
        let freshKeys = Set(messages.enumerated().map { offset, message in
            CachedMessage.cacheKey(
                serverURLString: serverURLString,
                sessionID: sessionID,
                message: message,
                sortIndex: offset
            )
        })
        // One session-scoped fetch serves both the upsert lookups below and the
        // stale sweep at the end. `CachedMessage.cacheKey` already embeds the
        // server and session, so this window holds every row a per-message
        // lookup could have matched. Rows inserted below are absent from the
        // snapshot, which is what the stale sweep wants: their keys are fresh.
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
                    && cachedMessage.sessionID == sessionID
            }
        )
        let cachedMessages = try context.fetch(descriptor)
        let cachedMessagesByKey = cachedMessages.reduce(into: [String: CachedMessage]()) {
            $0[$1.cacheKey] = $1
        }

        for (offset, message) in messages.enumerated() {
            let cacheKey = CachedMessage.cacheKey(
                serverURLString: serverURLString,
                sessionID: sessionID,
                message: message,
                sortIndex: offset
            )
            if let cachedMessage = cachedMessagesByKey[cacheKey] {
                cachedMessage.refresh(from: message, sortIndex: offset, cachedAt: cachedAt)
            } else {
                context.insert(CachedMessage(
                    serverURLString: serverURLString,
                    sessionID: sessionID,
                    message: message,
                    sortIndex: offset,
                    cachedAt: cachedAt
                ))
            }
        }

        let staleMessages = cachedMessages.filter { !freshKeys.contains($0.cacheKey) }
        for staleMessage in staleMessages {
            context.delete(staleMessage)
        }

        try saveAndTrim(context, now: cachedAt)
    }

    /// Deletes only the cached sessions and messages belonging to `serverURL`,
    /// leaving every other configured server's offline data intact (#18). Backs
    /// the Settings "Clear Offline Cache" action (active server) and the purge
    /// of a server's cache when it is removed, so a removed/reset server never
    /// leaves orphaned rows behind.
    @MainActor
    static func clearCache(for serverURL: URL, in context: ModelContext) throws {
        let serverURLString = serverURL.absoluteString

        let sessionDescriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )
        for cachedSession in try context.fetch(sessionDescriptor) {
            context.delete(cachedSession)
        }

        let messageDescriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
            }
        )
        for cachedMessage in try context.fetch(messageDescriptor) {
            context.delete(cachedMessage)
        }

        try context.save()
    }

    /// Saves a cache write, then enforces the TTL and the message cap. The write
    /// is saved first so the store-side delete and count below see exactly what
    /// the context holds: a row this write just refreshed is no longer expired in
    /// the store either. Maintenance never loads rows unless some must go: the
    /// expiry delete runs in the store and eviction starts from a COUNT.
    @MainActor
    private static func saveAndTrim(_ context: ModelContext, now: Date) throws {
        try context.save()
        try context.delete(model: CachedSession.self, where: #Predicate { $0.expiresAt <= now })
        try context.delete(model: CachedMessage.self, where: #Predicate { $0.expiresAt <= now })
        try evictOldestMessagesIfNeeded(in: context)
        if context.hasChanges {
            try context.save()
        }
    }

    /// Deletes the least recently cached messages above `CachePolicy.maxMessages`,
    /// fetching only the overflow rows.
    @MainActor
    private static func evictOldestMessagesIfNeeded(in context: ModelContext) throws {
        let overflowCount = try context.fetchCount(FetchDescriptor<CachedMessage>()) - CachePolicy.maxMessages
        guard overflowCount > 0 else { return }

        var descriptor = FetchDescriptor<CachedMessage>(
            sortBy: [
                SortDescriptor(\.cachedAt),
                SortDescriptor(\.timestamp),
                SortDescriptor(\.sortIndex)
            ]
        )
        descriptor.fetchLimit = overflowCount
        for message in try context.fetch(descriptor) {
            context.delete(message)
        }
    }

    @MainActor
    private static func cachedSession(cacheKey: String, in context: ModelContext) throws -> CachedSession? {
        var descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.cacheKey == cacheKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

private extension SessionSummary {
    init(cachedSession: CachedSession) {
        sessionId = cachedSession.sessionID
        title = cachedSession.title
        workspace = cachedSession.workspace
        model = cachedSession.model
        modelProvider = cachedSession.modelProvider
        messageCount = cachedSession.messageCount
        createdAt = cachedSession.createdAt
        updatedAt = cachedSession.updatedAt
        lastMessageAt = cachedSession.lastMessageAt
        pinned = cachedSession.pinned
        archived = cachedSession.archived
        projectId = cachedSession.projectId
        profile = cachedSession.profile
        inputTokens = cachedSession.inputTokens
        outputTokens = cachedSession.outputTokens
        estimatedCost = cachedSession.estimatedCost
        activeStreamId = cachedSession.activeStreamId
        isStreaming = cachedSession.isStreaming
        isCliSession = cachedSession.isCliSession
        userMessageCount = cachedSession.userMessageCount
        hasPendingUserMessage = cachedSession.hasPendingUserMessage
        pendingStartedAt = cachedSession.pendingStartedAt
        worktreePath = cachedSession.worktreePath
        sourceTag = cachedSession.sourceTag
        rawSource = cachedSession.rawSource
        sessionSource = cachedSession.sessionSource
        sourceLabel = cachedSession.sourceLabel
        parentSessionId = cachedSession.parentSessionId
        relationshipType = cachedSession.relationshipType
        readOnly = cachedSession.readOnly
        isReadOnly = cachedSession.isReadOnly
        matchType = nil
        matchPreview = nil
    }
}

private extension ChatMessage {
    init(cachedMessage: CachedMessage) {
        let attachments: [MessageAttachment]?
        if let data = cachedMessage.attachmentsData {
            attachments = try? JSONDecoder().decode([MessageAttachment].self, from: data)
        } else {
            attachments = nil
        }
        let toolCalls: [JSONValue]?
        if let data = cachedMessage.toolCallsData {
            toolCalls = try? JSONDecoder().decode([JSONValue].self, from: data)
        } else {
            toolCalls = nil
        }
        let contentParts: [JSONValue]?
        if let data = cachedMessage.contentPartsData {
            contentParts = try? JSONDecoder().decode([JSONValue].self, from: data)
        } else {
            contentParts = nil
        }
        self.init(
            role: cachedMessage.role,
            content: cachedMessage.content,
            timestamp: cachedMessage.timestamp,
            messageId: cachedMessage.messageId,
            name: cachedMessage.name,
            toolCallId: cachedMessage.toolCallId,
            toolUseId: cachedMessage.toolUseId,
            toolCalls: toolCalls,
            contentParts: contentParts,
            reasoning: cachedMessage.reasoning,
            attachments: attachments,
            displayKind: cachedMessage.displayKind,
            turnTps: cachedMessage.turnTps,
            turnDuration: cachedMessage.turnDuration
        )
    }
}
