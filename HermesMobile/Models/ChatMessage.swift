import Foundation

struct ChatMessage: Decodable, Equatable, Identifiable {
    var id: String {
        messageId ?? "\(role ?? "unknown")-\(timestamp ?? 0)-\(content ?? "")"
    }

    let role: String?
    let content: String?
    let timestamp: Double?
    let messageId: String?
    let name: String?
    let toolCallId: String?
    let toolUseId: String?
    let toolCalls: [JSONValue]?
    let contentParts: [JSONValue]?
    let reasoning: String?
    let attachments: [MessageAttachment]?

    init(
        role: String?,
        content: String?,
        timestamp: Double?,
        messageId: String?,
        name: String? = nil,
        toolCallId: String? = nil,
        toolUseId: String? = nil,
        toolCalls: [JSONValue]? = nil,
        contentParts: [JSONValue]? = nil,
        reasoning: String? = nil,
        attachments: [MessageAttachment]? = nil
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.messageId = messageId
        self.name = name
        self.toolCallId = toolCallId
        self.toolUseId = toolUseId
        self.toolCalls = toolCalls
        self.contentParts = contentParts
        self.reasoning = reasoning
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case timestamp
        case messageId
        case name
        case toolCallId
        case toolUseId
        case toolCalls
        case reasoning
        case attachments
        case underscoredTimestamp = "_ts"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = container.decodeLossyStringIfPresent(forKey: .role)
        let decodedContent = Self.decodeContentTolerantly(from: container)
        content = decodedContent.text
        timestamp = container.decodeLossyDoubleIfPresent(forKey: .underscoredTimestamp)
            ?? container.decodeLossyDoubleIfPresent(forKey: .timestamp)
        messageId = container.decodeLossyStringIfPresent(forKey: .messageId)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        toolCallId = container.decodeLossyStringIfPresent(forKey: .toolCallId)
        toolUseId = container.decodeLossyStringIfPresent(forKey: .toolUseId)
        toolCalls = try? container.decodeIfPresent([JSONValue].self, forKey: .toolCalls)
        contentParts = decodedContent.parts
        reasoning = container.decodeLossyStringIfPresent(forKey: .reasoning)
        let decodedAttachments = Self.decodeAttachmentsTolerantly(from: container)
        attachments = Self.attachments(decodedAttachments, enrichedByMarkerIn: content)
    }

    private static func attachments(
        _ decodedAttachments: [MessageAttachment]?,
        enrichedByMarkerIn content: String?
    ) -> [MessageAttachment]? {
        let inferredAttachments = MessageAttachment.inferredFromAttachedFilesMarker(in: content)

        guard let decodedAttachments, !decodedAttachments.isEmpty else {
            return inferredAttachments
        }

        guard let inferredAttachments, !inferredAttachments.isEmpty else {
            return decodedAttachments
        }

        var availableInferred = Array(inferredAttachments.enumerated())
        return decodedAttachments.enumerated().map { index, attachment in
            guard nonEmptyString(attachment.path) == nil,
                  let inferred = matchingInferredAttachment(
                    for: attachment,
                    at: index,
                    from: &availableInferred
                  )
            else {
                return attachment
            }

            return MessageAttachment(
                name: nonEmptyString(attachment.name) ?? inferred.name,
                path: nonEmptyString(inferred.path),
                mime: attachment.mime ?? inferred.mime,
                size: attachment.size ?? inferred.size,
                isImage: attachment.isImage ?? inferred.isImage
            )
        }
    }

    private static func matchingInferredAttachment(
        for attachment: MessageAttachment,
        at index: Int,
        from availableInferred: inout [(offset: Int, element: MessageAttachment)]
    ) -> MessageAttachment? {
        if let key = attachment.identityKey,
           let matchedIndex = availableInferred.firstIndex(where: { $0.element.identityKey == key }) {
            return availableInferred.remove(at: matchedIndex).element
        }

        guard let matchedIndex = availableInferred.firstIndex(where: { $0.offset == index }) else {
            return nil
        }

        return availableInferred.remove(at: matchedIndex).element
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func decodeContentTolerantly(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> (text: String?, parts: [JSONValue]?) {
        if let content = container.decodeLossyStringIfPresent(forKey: .content) {
            return (content, nil)
        }

        guard let value = try? container.decodeIfPresent(JSONValue.self, forKey: .content) else {
            return (nil, nil)
        }

        if case .array(let parts) = value {
            return (textContent(from: parts), parts)
        }

        return (value.compactJSONString, nil)
    }

    private static func textContent(from parts: [JSONValue]) -> String? {
        let text = parts.compactMap { part -> String? in
            if case .string(let value) = part {
                return value
            }

            guard case .object(let object) = part,
                  object["type"]?.stringValue == "text"
            else {
                return nil
            }

            return object["text"]?.stringValue
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : text
    }

    private static func decodeAttachmentsTolerantly(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [MessageAttachment]? {
        // Fast path: direct array decode when every attachment is well-shaped.
        if let direct = try? container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) {
            return direct
        }

        // Fallback: decode as raw JSON values so one malformed attachment
        // does not throw away the entire message array.
        guard let jsonValues = try? container.decodeIfPresent([JSONValue].self, forKey: .attachments) else {
            return nil
        }

        let itemDecoder = JSONDecoder()
        itemDecoder.keyDecodingStrategy = .convertFromSnakeCase

        return jsonValues.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? itemDecoder.decode(MessageAttachment.self, from: data)
        }
    }
}

enum TranscriptTurnClassifier {
    static func anchorID(for message: ChatMessage, at index: Int, messageOffset: Int? = nil) -> String {
        if let messageID = nonEmpty(message.messageId) {
            return messageID
        }

        return "raw:\(max(0, messageOffset ?? 0) + index)"
    }

    static func isUserTurnBoundary(_ message: ChatMessage) -> Bool {
        guard message.role == "user" else { return false }
        return hasVisibleUserContent(message)
    }

    static func isToolResultOnlyMessage(_ message: ChatMessage) -> Bool {
        message.role == "user" && !hasVisibleUserContent(message)
    }

    static func assistantTurnKeysByAnchorID(_ messages: [ChatMessage], messageOffset: Int? = nil) -> [String: String] {
        var keysByMessageID: [String: String] = [:]
        var currentTurnKey = "turn:start"

        for (messageIndex, message) in messages.enumerated() {
            if isUserTurnBoundary(message) {
                currentTurnKey = "turn:user:\(max(0, messageOffset ?? 0) + messageIndex)"
            }

            if message.role == "assistant" {
                keysByMessageID[anchorID(for: message, at: messageIndex, messageOffset: messageOffset)] = currentTurnKey
            }
        }

        return keysByMessageID
    }

    static func assistantTurnKeysByMessageID(_ messages: [ChatMessage]) -> [String: String] {
        assistantTurnKeysByAnchorID(messages)
    }

    static func assistantAnchorID(
        forRawIndex rawIndex: Int,
        in messages: [ChatMessage],
        messageOffset: Int? = nil
    ) -> String? {
        guard messages.indices.contains(rawIndex) else { return nil }

        if messages[rawIndex].role == "assistant" {
            return anchorID(for: messages[rawIndex], at: rawIndex, messageOffset: messageOffset)
        }

        let lowerBound = previousUserBoundaryIndex(before: rawIndex, in: messages).map { $0 + 1 } ?? messages.startIndex
        if rawIndex > lowerBound {
            for index in stride(from: rawIndex - 1, through: lowerBound, by: -1) where messages[index].role == "assistant" {
                return anchorID(for: messages[index], at: index, messageOffset: messageOffset)
            }
        }

        let upperBound = nextUserBoundaryIndex(after: rawIndex, in: messages) ?? messages.endIndex
        if messages.index(after: rawIndex) < upperBound {
            for index in messages.index(after: rawIndex)..<upperBound where messages[index].role == "assistant" {
                return anchorID(for: messages[index], at: index, messageOffset: messageOffset)
            }
        }

        return nil
    }

    static func currentTurnAssistantAnchorIDs(in messages: [ChatMessage], messageOffset: Int? = nil) -> [String] {
        let latestUserIndex = messages.lastIndex { isUserTurnBoundary($0) }
        let startIndex = latestUserIndex.map { messages.index(after: $0) } ?? messages.startIndex
        guard startIndex < messages.endIndex else { return [] }

        return messages[startIndex...].enumerated().compactMap { offset, message in
            guard message.role == "assistant" else { return nil }
            return anchorID(for: message, at: startIndex + offset, messageOffset: messageOffset)
        }
    }

    static func currentTurnAssistantMessageIDs(in messages: [ChatMessage]) -> [String] {
        currentTurnAssistantAnchorIDs(in: messages)
    }

    private static func previousUserBoundaryIndex(before rawIndex: Int, in messages: [ChatMessage]) -> Int? {
        guard rawIndex > messages.startIndex else { return nil }

        for index in stride(from: rawIndex - 1, through: messages.startIndex, by: -1) where isUserTurnBoundary(messages[index]) {
            return index
        }

        return nil
    }

    private static func nextUserBoundaryIndex(after rawIndex: Int, in messages: [ChatMessage]) -> Int? {
        let nextIndex = messages.index(after: rawIndex)
        guard nextIndex < messages.endIndex else { return nil }

        return messages[nextIndex...].firstIndex { isUserTurnBoundary($0) }
    }

    private static func hasVisibleUserContent(_ message: ChatMessage) -> Bool {
        guard message.role == "user" else { return false }

        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        return message.attachments?.isEmpty == false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return "\(value)"
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return "\(value)"
        }

        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }

        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }

        guard let stringValue = try? decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key),
           value.isFinite {
            return Int(value)
        }

        guard let stringValue = try? decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(trimmed) {
            return value
        }

        guard let value = Double(trimmed),
              value.isFinite
        else {
            return nil
        }

        return Int(value)
    }

    func decodeLossyBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            switch value {
            case 0:
                return false
            case 1:
                return true
            default:
                return nil
            }
        }

        guard let stringValue = try? decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }
}

private extension JSONValue {
    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return JSONValue.lossyNumberString(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null:
            return nil
        }
    }

    var compactJSONString: String? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
