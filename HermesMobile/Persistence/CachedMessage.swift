import Foundation
import SwiftData

@Model
final class CachedMessage {
    @Attribute(.unique) var cacheKey: String
    var serverURLString: String
    var sessionID: String
    var sortIndex: Int
    var role: String?
    var content: String?
    var timestamp: Double?
    var messageId: String?
    var name: String?
    var toolCallId: String?
    var toolUseId: String?
    var toolCallsData: Data?
    var contentPartsData: Data?
    var reasoning: String?
    var attachmentsData: Data?
    var turnTps: Double?
    var cachedAt: Date
    var expiresAt: Date

    init(
        serverURLString: String,
        sessionID: String,
        message: ChatMessage,
        sortIndex: Int,
        cachedAt: Date = Date()
    ) {
        self.cacheKey = Self.cacheKey(
            serverURLString: serverURLString,
            sessionID: sessionID,
            message: message,
            sortIndex: sortIndex
        )
        self.serverURLString = serverURLString
        self.sessionID = sessionID
        self.sortIndex = sortIndex
        self.cachedAt = cachedAt
        self.expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
        apply(message, sortIndex: sortIndex, cachedAt: cachedAt)
    }

    static func cacheKey(
        serverURLString: String,
        sessionID: String,
        message: ChatMessage,
        sortIndex: Int
    ) -> String {
        let messagePart = message.messageId ?? "\(sortIndex)-\(message.timestamp ?? 0)"
        return "\(serverURLString)|session|\(sessionID)|message|\(messagePart)"
    }

    func apply(_ message: ChatMessage, sortIndex: Int, cachedAt: Date = Date()) {
        self.sortIndex = sortIndex
        role = message.role
        content = message.content
        timestamp = message.timestamp
        messageId = message.messageId
        name = message.name
        toolCallId = message.toolCallId
        toolUseId = message.toolUseId
        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            toolCallsData = try? JSONEncoder().encode(toolCalls)
        } else {
            toolCallsData = nil
        }
        if let contentParts = message.contentParts, !contentParts.isEmpty {
            contentPartsData = try? JSONEncoder().encode(contentParts)
        } else {
            contentPartsData = nil
        }
        reasoning = message.reasoning
        turnTps = message.turnTps
        if let attachments = message.attachments, !attachments.isEmpty {
            attachmentsData = try? JSONEncoder().encode(attachments)
        } else {
            attachmentsData = nil
        }
        self.cachedAt = cachedAt
        expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
    }
}
