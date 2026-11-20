import Foundation
import SwiftData

enum CacheContainer {
    static let configuration = ModelConfiguration(groupContainer: .none)

    static func open() -> ModelContainer {
        if let group = HermesShareDraft.containerURL() {
            moveStore(from: group.appending(path: "Library/Application Support/\(configuration.url.lastPathComponent)"),
                      to: configuration.url)
        }
        return container(for: configuration)
    }

    static func container(for configuration: ModelConfiguration) -> ModelContainer {
        do {
            return try ModelContainer(for: CachedSession.self, CachedMessage.self, configurations: configuration)
        } catch {
            return try! ModelContainer(for: CachedSession.self, CachedMessage.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    static func moveStore(from source: URL, to destination: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let suffixes = ["-wal", "-shm", ""]
        for suffix in suffixes { try? fileManager.removeItem(atPath: destination.path + suffix) }
        for suffix in suffixes {
            do {
                try fileManager.moveItem(atPath: source.path + suffix, toPath: destination.path + suffix)
            } catch {
                try? fileManager.removeItem(atPath: source.path + suffix)
            }
        }
    }
}

enum CacheStore {
    @MainActor
    static func cachedSessions(
        serverURL: URL,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> [SessionSummary] {
        var rows = 0
        let signpost = performanceSignposter.beginInterval("Cache Read")
        defer { performanceSignposter.endInterval("Cache Read", signpost, "rows=\(rows, privacy: .public)") }

        let serverURLString = serverURL.absoluteString
        let descriptor = FetchDescriptor<CachedSession>(
            predicate: #Predicate { cachedSession in
                cachedSession.serverURLString == serverURLString
            }
        )

        let sessions = try context.fetch(descriptor)
            .filter { $0.archived != true && $0.expiresAt > now }
            .map(SessionSummary.init(cachedSession:))
        rows = sessions.count
        return sessions
    }

    @MainActor
    static func cachedSession(id sessionID: String, serverURL: URL, in context: ModelContext) throws -> SessionSummary? {
        let cacheKey = CachedSession.cacheKey(serverURLString: serverURL.absoluteString, sessionID: sessionID)
        return try cachedSession(cacheKey: cacheKey, in: context).map(SessionSummary.init(cachedSession:))
    }

    @MainActor
    static func cachedMessages(
        serverURL: URL,
        sessionID: String,
        in context: ModelContext,
        limit: Int? = nil,
        now: Date = Date()
    ) throws -> [ChatMessage] {
        var rows = 0
        let signpost = performanceSignposter.beginInterval("Cache Read")
        defer { performanceSignposter.endInterval("Cache Read", signpost, "rows=\(rows, privacy: .public)") }

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
        rows = cachedMessages.count
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
        let signpost = performanceSignposter.beginInterval("Cache Write")
        defer { performanceSignposter.endInterval("Cache Write", signpost, "rows=\(sessions.count, privacy: .public)") }

        let serverURLString = serverURL.absoluteString
        let cacheableSessions = sessions.filter { $0.archived != true && $0.sessionId != nil }
        let freshKeys = Set(cacheableSessions.compactMap { session -> String? in
            guard let sessionID = session.sessionId else { return nil }
            return CachedSession.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
        })

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

        let signpost = performanceSignposter.beginInterval("Cache Write")
        defer { performanceSignposter.endInterval("Cache Write", signpost, "rows=1") }

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
        let signpost = performanceSignposter.beginInterval("Cache Write")
        defer { performanceSignposter.endInterval("Cache Write", signpost, "rows=\(messages.count, privacy: .public)") }

        let serverURLString = serverURL.absoluteString
        let freshKeys = Set(messages.enumerated().map { offset, message in
            CachedMessage.cacheKey(
                serverURLString: serverURLString,
                sessionID: sessionID,
                message: message,
                sortIndex: offset
            )
        })
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

    @MainActor
    static func clearCache(for serverURL: URL, in context: ModelContext) throws {
        revokeHermesWriters(serverURL: serverURL)
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
    static func saveAndTrim(_ context: ModelContext, now: Date) throws {
        try context.save()
        try context.delete(model: CachedSession.self, where: #Predicate { $0.expiresAt <= now })
        try context.delete(model: CachedMessage.self, where: #Predicate { $0.expiresAt <= now })
        try evictOldestMessagesIfNeeded(in: context)
        if context.hasChanges {
            try context.save()
        }
    }

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

extension SessionSummary {
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
        hermes = cachedSession.lineageRoot.map {
            Hermes(lineageRoot: $0, unread: cachedSession.unread == true, preview: cachedSession.preview)
        }
    }
}

extension ChatMessage {
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
        let displayMetadata = cachedMessage.displayMetadataData.flatMap {
            try? JSONDecoder().decode([String: JSONValue].self, from: $0)
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
            displayMetadata: displayMetadata,
            turnTps: cachedMessage.turnTps,
            turnDuration: cachedMessage.turnDuration,
            rowID: cachedMessage.rowID
        )
    }
}
