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
        now: Date = Date()
    ) throws -> [ChatMessage] {
        let serverURLString = serverURL.absoluteString
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
                    && cachedMessage.sessionID == sessionID
            }
        )

        return try context.fetch(descriptor)
            .filter { $0.expiresAt > now }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(ChatMessage.init(cachedMessage:))
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

        for session in cacheableSessions {
            guard let sessionID = session.sessionId else { continue }
            let cacheKey = CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
            if let cachedSession = try cachedSession(cacheKey: cacheKey, in: context) {
                cachedSession.apply(session, cachedAt: cachedAt)
            } else {
                context.insert(CachedSession(serverURLString: serverURLString, session: session, cachedAt: cachedAt))
            }
        }

        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )
        let staleSessions = try context.fetch(descriptor).filter { !freshKeys.contains($0.cacheKey) }
        for staleSession in staleSessions {
            context.delete(staleSession)
        }

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
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

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
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

        for (offset, message) in messages.enumerated() {
            let cacheKey = CachedMessage.cacheKey(
                serverURLString: serverURLString,
                sessionID: sessionID,
                message: message,
                sortIndex: offset
            )
            if let cachedMessage = try cachedMessage(cacheKey: cacheKey, in: context) {
                cachedMessage.apply(message, sortIndex: offset, cachedAt: cachedAt)
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

        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.serverURLString == serverURLString
                    && cachedMessage.sessionID == sessionID
            }
        )
        let staleMessages = try context.fetch(descriptor).filter { !freshKeys.contains($0.cacheKey) }
        for staleMessage in staleMessages {
            context.delete(staleMessage)
        }

        try performMaintenance(in: context, now: cachedAt)
        try context.save()
    }

    @MainActor
    static func clearAll(in context: ModelContext) throws {
        for cachedSession in try context.fetch(FetchDescriptor<CachedSession>()) {
            context.delete(cachedSession)
        }

        for cachedMessage in try context.fetch(FetchDescriptor<CachedMessage>()) {
            context.delete(cachedMessage)
        }

        try context.save()
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

    @MainActor
    private static func performMaintenance(in context: ModelContext, now: Date) throws {
        try deleteExpiredSessions(in: context, now: now)
        try deleteExpiredMessages(in: context, now: now)
        try evictOldestMessagesIfNeeded(in: context)
    }

    @MainActor
    private static func deleteExpiredSessions(in context: ModelContext, now: Date) throws {
        let descriptor = FetchDescriptor<CachedSession>()
        let expiredSessions = try context.fetch(descriptor).filter { $0.expiresAt <= now }
        for session in expiredSessions {
            context.delete(session)
        }
    }

    @MainActor
    private static func deleteExpiredMessages(in context: ModelContext, now: Date) throws {
        let descriptor = FetchDescriptor<CachedMessage>()
        let expiredMessages = try context.fetch(descriptor).filter { $0.expiresAt <= now }
        for message in expiredMessages {
            context.delete(message)
        }
    }

    @MainActor
    private static func evictOldestMessagesIfNeeded(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<CachedMessage>()
        let messages = try context.fetch(descriptor)
        let overflowCount = messages.count - CachePolicy.maxMessages
        guard overflowCount > 0 else { return }

        let messagesToEvict = messages
            .sorted { left, right in
                if left.cachedAt != right.cachedAt {
                    return left.cachedAt < right.cachedAt
                }

                if left.timestamp != right.timestamp {
                    return (left.timestamp ?? 0) < (right.timestamp ?? 0)
                }

                return left.sortIndex < right.sortIndex
            }
            .prefix(overflowCount)

        for message in messagesToEvict {
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

    @MainActor
    private static func cachedMessage(cacheKey: String, in context: ModelContext) throws -> CachedMessage? {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { cachedMessage in
                cachedMessage.cacheKey == cacheKey
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
        sessionSource = cachedSession.sessionSource
        sourceLabel = cachedSession.sourceLabel
        matchType = nil
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
            attachments: attachments
        )
    }
}
