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
    var turnDuration: Double?
    /// Optional server display hint (e.g. `"steer"`). Added after the initial
    /// schema; SwiftData migrates it as a nullable column on existing stores.
    var displayKind: String?
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

    /// Writes every field of `message` into this row and stamps it with `cachedAt`.
    /// Used for new rows; existing rows go through `refresh` so unchanged ones stay clean.
    func apply(_ message: ChatMessage, sortIndex: Int, cachedAt: Date = Date()) {
        write(message, blobs: Blobs(message), sortIndex: sortIndex, cachedAt: cachedAt)
    }

    /// Upserts `message` into an existing row during a window write. A row that
    /// already holds exactly this message is not rewritten; only its
    /// `cachedAt`/`expiresAt` move forward, and at most once per
    /// `CachePolicy.rowRefreshInterval`, so recaching a 50-300 row window dirties
    /// only the rows that changed while LRU eviction and the TTL stay roughly right.
    func refresh(from message: ChatMessage, sortIndex: Int, cachedAt: Date) {
        let blobs = Blobs(message)
        guard matches(message, blobs: blobs, sortIndex: sortIndex) else {
            write(message, blobs: blobs, sortIndex: sortIndex, cachedAt: cachedAt)
            return
        }
        if cachedAt.timeIntervalSince(self.cachedAt) >= CachePolicy.rowRefreshInterval {
            stamp(cachedAt)
        }
    }

    private func matches(_ message: ChatMessage, blobs: Blobs, sortIndex: Int) -> Bool {
        self.sortIndex == sortIndex
            && role == message.role
            && content == message.content
            && timestamp == message.timestamp
            && messageId == message.messageId
            && name == message.name
            && toolCallId == message.toolCallId
            && toolUseId == message.toolUseId
            && reasoning == message.reasoning
            && turnTps == message.turnTps
            && turnDuration == message.turnDuration
            && displayKind == message.displayKind
            && toolCallsData == blobs.toolCalls
            && contentPartsData == blobs.contentParts
            && attachmentsData == blobs.attachments
    }

    private func write(_ message: ChatMessage, blobs: Blobs, sortIndex: Int, cachedAt: Date) {
        self.sortIndex = sortIndex
        role = message.role
        content = message.content
        timestamp = message.timestamp
        messageId = message.messageId
        name = message.name
        toolCallId = message.toolCallId
        toolUseId = message.toolUseId
        toolCallsData = blobs.toolCalls
        contentPartsData = blobs.contentParts
        reasoning = message.reasoning
        turnTps = message.turnTps
        turnDuration = message.turnDuration
        displayKind = message.displayKind
        attachmentsData = blobs.attachments
        stamp(cachedAt)
    }

    private func stamp(_ cachedAt: Date) {
        self.cachedAt = cachedAt
        expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
    }
}

/// The encoded JSON columns of one message. Keys are sorted so equal values
/// encode to equal bytes, which lets `CachedMessage.refresh` compare them.
private struct Blobs {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    let toolCalls: Data?
    let contentParts: Data?
    let attachments: Data?

    init(_ message: ChatMessage) {
        toolCalls = Self.encode(message.toolCalls)
        contentParts = Self.encode(message.contentParts)
        attachments = Self.encode(message.attachments)
    }

    private static func encode<Element: Encodable>(_ values: [Element]?) -> Data? {
        guard let values, !values.isEmpty else { return nil }
        return try? encoder.encode(values)
    }
}
