import Foundation

struct ToolCall: Identifiable, Equatable {
    let id: String
    var name: String?
    var preview: String?
    var args: [String: JSONValue]?
    var duration: Double?
    var isError: Bool?
    var isCompleted: Bool
    let startedAt: Double

    init(
        id: String = "live-tool-\(UUID().uuidString)",
        name: String?,
        preview: String?,
        args: [String: JSONValue]?,
        duration: Double? = nil,
        isError: Bool? = nil,
        isCompleted: Bool = false,
        startedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.args = args
        self.duration = duration
        self.isError = isError
        self.isCompleted = isCompleted
        self.startedAt = startedAt
    }

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedName, !trimmedName.isEmpty else {
            return String(localized: "Tool")
        }

        if Self.isSkillViewTool(trimmedName),
           let skillName = Self.skillName(from: args) {
            return String(localized: "Load skill: \(Self.humanizedSkillName(skillName))")
        }

        return trimmedName
    }

    private static func isSkillViewTool(_ name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName == "skill_view" || normalizedName.hasSuffix(".skill_view")
    }

    private static func skillName(from args: [String: JSONValue]?) -> String? {
        let value = args?["name"]?.stringValue
            ?? args?["skill"]?.stringValue
            ?? args?["skill_name"]?.stringValue

        return nonEmpty(value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func humanizedSkillName(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return value }

        return words
            .map(Self.humanizedSkillWord)
            .joined(separator: " ")
    }

    private static func humanizedSkillWord(_ word: String) -> String {
        let lowercasedWord = word.lowercased()
        let preferredAcronyms = [
            "api": "API",
            "ios": "iOS",
            "llm": "LLM",
            "mcp": "MCP",
            "qa": "QA",
            "seo": "SEO",
            "tts": "TTS",
            "ui": "UI"
        ]

        if let acronym = preferredAcronyms[lowercasedWord] {
            return acronym
        }

        guard word.uppercased() != word else { return word }
        return String(word.prefix(1)).uppercased() + String(word.dropFirst()).lowercased()
    }
}

struct PersistedToolCall: Decodable, Equatable {
    let name: String?
    let snippet: String?
    let tid: String?
    let assistantMsgIdx: Int?
    let args: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case name
        case snippet
        case tid
        case assistantMsgIdx
        case assistantMsgIdxSnake = "assistant_msg_idx"
        case args
    }

    init(
        name: String?,
        snippet: String?,
        tid: String?,
        assistantMsgIdx: Int?,
        args: [String: JSONValue]?
    ) {
        self.name = name
        self.snippet = snippet
        self.tid = tid
        self.assistantMsgIdx = assistantMsgIdx
        self.args = args
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        snippet = container.decodeLossyStringIfPresent(forKey: .snippet)
        tid = container.decodeLossyStringIfPresent(forKey: .tid)
        assistantMsgIdx = container.decodeLossyIntIfPresent(forKey: .assistantMsgIdx)
            ?? container.decodeLossyIntIfPresent(forKey: .assistantMsgIdxSnake)
        args = try? container.decodeIfPresent([String: JSONValue].self, forKey: .args)
    }

    func toolCall(fallbackIndex: Int) -> ToolCall {
        let trimmedID = tid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String
        if let trimmedID, !trimmedID.isEmpty {
            id = trimmedID
        } else {
            id = "persisted-tool-\(fallbackIndex)"
        }

        return ToolCall(
            id: id,
            name: name,
            preview: snippet,
            args: args,
            isCompleted: true
        )
    }
}

struct ToolCallGroup: Identifiable, Equatable {
    let id: String
    let anchorMessageID: String?
    let toolCalls: [ToolCall]

    init(
        id: String = UUID().uuidString,
        anchorMessageID: String?,
        toolCalls: [ToolCall]
    ) {
        self.id = id
        self.anchorMessageID = anchorMessageID
        self.toolCalls = toolCalls
    }

    var activityTitle: String {
        String(localized: "Activity: \(toolCalls.count) tools")
    }

    var isComplete: Bool {
        toolCalls.allSatisfy(\.isCompleted)
    }

    var hasFailedTool: Bool {
        toolCalls.contains { $0.isError == true }
    }

    static func live(anchorMessageID: String?, toolCalls: [ToolCall]) -> ToolCallGroup {
        ToolCallGroup(
            id: "live-tools-\(anchorMessageID ?? "unanchored")",
            anchorMessageID: anchorMessageID,
            toolCalls: toolCalls
        )
    }

    static func groups(
        persistedToolCalls: [PersistedToolCall],
        messages: [ChatMessage],
        messageOffset: Int?
    ) -> [ToolCallGroup] {
        let derivedGroups = groupsFromMessageMetadata(messages, messageOffset: messageOffset)
        guard !persistedToolCalls.isEmpty else {
            return coalescingByAssistantTurn(derivedGroups, messages: messages, messageOffset: messageOffset)
        }

        return coalescingByAssistantTurn(
            merging(
                primaryGroups: groupsFromPersistedToolCalls(
                    persistedToolCalls,
                    messages: messages,
                    messageOffset: messageOffset
                ),
                fallbackGroups: derivedGroups
            ),
            messages: messages,
            messageOffset: messageOffset
        )
    }

    private static func groupsFromPersistedToolCalls(
        _ persistedToolCalls: [PersistedToolCall],
        messages: [ChatMessage],
        messageOffset: Int?
    ) -> [ToolCallGroup] {
        let offset = messageOffset ?? 0
        var groups: [ToolCallGroup] = []
        var groupIndexesByAnchor: [String: Int] = [:]

        for (toolIndex, persistedToolCall) in persistedToolCalls.enumerated() {
            guard let assistantMsgIdx = persistedToolCall.assistantMsgIdx else {
                continue
            }

            let loadedMessageIndex = assistantMsgIdx - offset
            guard messages.indices.contains(loadedMessageIndex) else {
                continue
            }

            guard let anchorMessageID = TranscriptTurnClassifier.assistantAnchorID(
                forRawIndex: loadedMessageIndex,
                in: messages,
                messageOffset: messageOffset
            ) else {
                continue
            }
            let toolCall = persistedToolCall.toolCall(fallbackIndex: toolIndex)

            if let groupIndex = groupIndexesByAnchor[anchorMessageID] {
                var existingGroup = groups[groupIndex]
                existingGroup = ToolCallGroup(
                    id: existingGroup.id,
                    anchorMessageID: existingGroup.anchorMessageID,
                    toolCalls: existingGroup.toolCalls + [toolCall]
                )
                groups[groupIndex] = existingGroup
            } else {
                groupIndexesByAnchor[anchorMessageID] = groups.count
                groups.append(
                    ToolCallGroup(
                        id: "persisted-tools-\(anchorMessageID)",
                        anchorMessageID: anchorMessageID,
                        toolCalls: [toolCall]
                    )
                )
            }
        }

        return groups
    }

    private static func groupsFromMessageMetadata(_ messages: [ChatMessage], messageOffset: Int?) -> [ToolCallGroup] {
        let resultsByToolID = toolResultSnippetsByID(from: messages)
        var groups: [ToolCallGroup] = []
        var currentAnchorMessageID: String?
        var currentToolCalls: [ToolCall] = []

        func flushCurrentGroup() {
            guard !currentToolCalls.isEmpty else {
                currentAnchorMessageID = nil
                return
            }

            groups.append(
                ToolCallGroup(
                    id: "persisted-tools-\(currentAnchorMessageID ?? "unanchored-\(groups.count)")",
                    anchorMessageID: currentAnchorMessageID,
                    toolCalls: uniqueToolCalls(currentToolCalls)
                )
            )
            currentAnchorMessageID = nil
            currentToolCalls = []
        }

        for (messageIndex, message) in messages.enumerated() {
            if TranscriptTurnClassifier.isUserTurnBoundary(message) {
                flushCurrentGroup()
                continue
            }

            guard message.role == "assistant" else { continue }

            let toolCalls = openAIToolCalls(
                from: message,
                messageIndex: messageIndex,
                resultsByToolID: resultsByToolID
            )
            + anthropicToolCalls(
                from: message,
                messageIndex: messageIndex,
                resultsByToolID: resultsByToolID
            )

            guard !toolCalls.isEmpty else { continue }

            if currentAnchorMessageID == nil {
                currentAnchorMessageID = TranscriptTurnClassifier.anchorID(
                    for: message,
                    at: messageIndex,
                    messageOffset: messageOffset
                )
            }
            currentToolCalls += toolCalls
        }

        flushCurrentGroup()
        return groups
    }

    private static func toolResultSnippetsByID(from messages: [ChatMessage]) -> [String: String] {
        messages.reduce(into: [String: String]()) { result, message in
            if message.role == "tool",
               let toolCallID = nonEmpty(message.toolCallId) ?? nonEmpty(message.toolUseId),
               let content = nonEmpty(message.content) {
                result[toolCallID] = content
            }

            for part in message.contentParts ?? [] {
                guard let toolResult = toolResult(from: part) else { continue }
                result[toolResult.id] = toolResult.content
            }
        }
    }

    private static func openAIToolCalls(
        from message: ChatMessage,
        messageIndex: Int,
        resultsByToolID: [String: String]
    ) -> [ToolCall] {
        (message.toolCalls ?? []).enumerated().compactMap { toolIndex, value in
            toolCall(
                fromOpenAIToolCall: value,
                messageIndex: messageIndex,
                toolIndex: toolIndex,
                resultsByToolID: resultsByToolID
            )
        }
    }

    private static func toolCall(
        fromOpenAIToolCall value: JSONValue,
        messageIndex: Int,
        toolIndex: Int,
        resultsByToolID: [String: String]
    ) -> ToolCall? {
        guard case .object(let object) = value else { return nil }

        let function = object["function"]?.objectValue
        let name = nonEmpty(function?["name"]?.stringValue)
            ?? nonEmpty(object["name"]?.stringValue)
            ?? "tool"
        let toolID = nonEmpty(object["id"]?.stringValue)
            ?? nonEmpty(object["call_id"]?.stringValue)
            ?? nonEmpty(object["tool_call_id"]?.stringValue)
            ?? "message-tool-\(messageIndex)-\(toolIndex)"
        let argumentValue = function?["arguments"]
            ?? object["arguments"]
            ?? object["args"]
            ?? object["input"]
        let preview = nonEmpty(resultsByToolID[toolID])
            ?? nonEmpty(object["snippet"]?.stringValue)
            ?? nonEmpty(object["preview"]?.stringValue)

        return ToolCall(
            id: toolID,
            name: name,
            preview: preview,
            args: arguments(from: argumentValue),
            isCompleted: true
        )
    }

    private static func anthropicToolCalls(
        from message: ChatMessage,
        messageIndex: Int,
        resultsByToolID: [String: String]
    ) -> [ToolCall] {
        (message.contentParts ?? []).enumerated().compactMap { toolIndex, value in
            guard case .object(let object) = value,
                  object["type"]?.stringValue == "tool_use"
            else {
                return nil
            }

            let name = nonEmpty(object["name"]?.stringValue) ?? "tool"
            let toolID = nonEmpty(object["id"]?.stringValue) ?? "message-tool-\(messageIndex)-\(toolIndex)"
            let argumentValue = object["input"] ?? object["arguments"] ?? object["args"]

            return ToolCall(
                id: toolID,
                name: name,
                preview: nonEmpty(resultsByToolID[toolID])
                    ?? nonEmpty(object["snippet"]?.stringValue)
                    ?? nonEmpty(object["preview"]?.stringValue),
                args: arguments(from: argumentValue),
                isCompleted: true
            )
        }
    }

    private static func toolResult(from value: JSONValue) -> (id: String, content: String)? {
        guard case .object(let object) = value,
              object["type"]?.stringValue == "tool_result",
              let id = nonEmpty(object["tool_use_id"]?.stringValue)
                ?? nonEmpty(object["tool_call_id"]?.stringValue)
                ?? nonEmpty(object["id"]?.stringValue),
              let content = resultContent(from: object["content"])
        else {
            return nil
        }

        return (id, content)
    }

    private static func resultContent(from value: JSONValue?) -> String? {
        guard let value else { return nil }

        switch value {
        case .string(let string):
            return nonEmpty(string)
        case .array(let values):
            let text = values.compactMap { item -> String? in
                if case .string(let string) = item {
                    return string
                }

                guard case .object(let object) = item else { return nil }
                return object["text"]?.stringValue
                    ?? object["content"]?.stringValue
            }
            .joined()
            return nonEmpty(text)
        case .object, .number, .bool, .null:
            return value.compactJSONString.flatMap(nonEmpty)
        }
    }

    private static func uniqueToolCalls(_ toolCalls: [ToolCall]) -> [ToolCall] {
        var stableIDIndexes: [String: Int] = [:]
        var fingerprintIndexes: [String: Int] = [:]
        var uniqueToolCalls: [ToolCall] = []
        var isGeneratedByIndex: [Bool] = []

        for toolCall in toolCalls {
            let isGenerated = isGeneratedToolID(toolCall.id)
            let fingerprint = toolCallFingerprint(toolCall)
            let stableIDIndex = isGenerated ? nil : stableIDIndexes[toolCall.id]
            let fingerprintIndex = fingerprintIndexes[fingerprint].flatMap { index -> Int? in
                isGenerated || isGeneratedByIndex[index] ? index : nil
            }

            if let existingIndex = stableIDIndex ?? fingerprintIndex {
                uniqueToolCalls[existingIndex] = mergingToolCall(uniqueToolCalls[existingIndex], with: toolCall)
                isGeneratedByIndex[existingIndex] = isGeneratedToolID(uniqueToolCalls[existingIndex].id)
                if !isGenerated {
                    stableIDIndexes[toolCall.id] = existingIndex
                }
                fingerprintIndexes[fingerprint] = existingIndex
            } else {
                if !isGenerated {
                    stableIDIndexes[toolCall.id] = uniqueToolCalls.count
                }
                if fingerprintIndexes[fingerprint] == nil || isGenerated {
                    fingerprintIndexes[fingerprint] = uniqueToolCalls.count
                }
                isGeneratedByIndex.append(isGenerated)
                uniqueToolCalls.append(toolCall)
            }
        }

        return uniqueToolCalls
    }

    static func merging(
        primaryGroups: [ToolCallGroup],
        fallbackGroups: [ToolCallGroup]
    ) -> [ToolCallGroup] {
        var merged = primaryGroups
        var groupIndexesByAnchor = Dictionary(
            uniqueKeysWithValues: primaryGroups.enumerated().compactMap { index, group in
                group.anchorMessageID.map { ($0, index) }
            }
        )

        for fallbackGroup in fallbackGroups {
            guard let anchorMessageID = fallbackGroup.anchorMessageID,
                  let groupIndex = groupIndexesByAnchor[anchorMessageID]
            else {
                if let anchorMessageID = fallbackGroup.anchorMessageID {
                    groupIndexesByAnchor[anchorMessageID] = merged.count
                }
                merged.append(fallbackGroup)
                continue
            }

            let existingGroup = merged[groupIndex]
            merged[groupIndex] = ToolCallGroup(
                id: existingGroup.id,
                anchorMessageID: existingGroup.anchorMessageID,
                toolCalls: mergingToolCalls(
                    primaryToolCalls: existingGroup.toolCalls,
                    fallbackToolCalls: fallbackGroup.toolCalls
                )
            )
        }

        return merged
    }

    static func coalescingByAssistantTurn(
        _ groups: [ToolCallGroup],
        messages: [ChatMessage],
        messageOffset: Int? = nil
    ) -> [ToolCallGroup] {
        guard groups.count > 1 else {
            return groups.map { group in
                ToolCallGroup(
                    id: group.id,
                    anchorMessageID: group.anchorMessageID,
                    toolCalls: uniqueToolCalls(group.toolCalls)
                )
            }
        }

        let messageIndexesByID = messages.enumerated().reduce(into: [String: Int]()) { result, entry in
            result[TranscriptTurnClassifier.anchorID(
                for: entry.element,
                at: entry.offset,
                messageOffset: messageOffset
            )] = entry.offset
        }
        let turnKeysByAssistantMessageID = TranscriptTurnClassifier.assistantTurnKeysByAnchorID(
            messages,
            messageOffset: messageOffset
        )
        var mergedGroups: [TurnGroupBuilder] = []
        var builderIndexesByTurnKey: [String: Int] = [:]

        for (groupOrder, group) in groups.enumerated() {
            let anchorIndex = group.anchorMessageID.flatMap { messageIndexesByID[$0] } ?? Int.max - groupOrder
            let turnKey = group.anchorMessageID.flatMap { turnKeysByAssistantMessageID[$0] }
                ?? "group:\(group.id)"

            if let builderIndex = builderIndexesByTurnKey[turnKey] {
                mergedGroups[builderIndex].append(group, anchorIndex: anchorIndex)
            } else {
                builderIndexesByTurnKey[turnKey] = mergedGroups.count
                mergedGroups.append(
                    TurnGroupBuilder(
                        turnKey: turnKey,
                        group: group,
                        anchorIndex: anchorIndex
                    )
                )
            }
        }

        return mergedGroups
            .sorted { lhs, rhs in
                if lhs.anchorIndex == rhs.anchorIndex {
                    return lhs.turnKey < rhs.turnKey
                }
                return lhs.anchorIndex < rhs.anchorIndex
            }
            .map { builder in
                ToolCallGroup(
                    id: builder.id,
                    anchorMessageID: builder.anchorMessageID,
                    toolCalls: uniqueToolCalls(builder.toolCalls)
                )
            }
    }

    private static func arguments(from value: JSONValue?) -> [String: JSONValue]? {
        guard let value else { return nil }

        if case .object(let object) = value {
            return object.isEmpty ? nil : object
        }

        guard case .string(let string) = value,
              let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = decoded
        else {
            return nil
        }

        return object.isEmpty ? nil : object
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func toolCallFingerprint(_ toolCall: ToolCall) -> String {
        return [
            "fallback",
            toolCall.displayName,
            argumentsKey(toolCall.args)
        ].joined(separator: ":")
    }

    private static func isGeneratedToolID(_ id: String) -> Bool {
        id.hasPrefix("live-tool-") || id.hasPrefix("message-tool-") || id.hasPrefix("persisted-tool-")
    }

    private static func mergingToolCalls(
        primaryToolCalls: [ToolCall],
        fallbackToolCalls: [ToolCall]
    ) -> [ToolCall] {
        var mergedToolCalls = uniqueToolCalls(primaryToolCalls)
        var fallbackNameOrdinals: [String: Int] = [:]

        for fallbackToolCall in fallbackToolCalls {
            let nameKey = toolCallNameKey(fallbackToolCall)
            let nameOrdinal = (fallbackNameOrdinals[nameKey] ?? 0) + 1
            fallbackNameOrdinals[nameKey] = nameOrdinal

            if let existingIndex = matchingToolCallIndex(
                for: fallbackToolCall,
                nameOrdinal: nameOrdinal,
                in: mergedToolCalls
            ) {
                mergedToolCalls[existingIndex] = mergingToolCall(
                    mergedToolCalls[existingIndex],
                    with: fallbackToolCall
                )
            } else {
                mergedToolCalls.append(fallbackToolCall)
            }
        }

        return uniqueToolCalls(mergedToolCalls)
    }

    private static func matchingToolCallIndex(
        for fallbackToolCall: ToolCall,
        nameOrdinal: Int,
        in toolCalls: [ToolCall]
    ) -> Int? {
        let fallbackIsGenerated = isGeneratedToolID(fallbackToolCall.id)

        // Stable transcript IDs are authoritative; generated live IDs are only
        // reconciliation hints while the completed transcript catches up.
        if !fallbackIsGenerated,
           let stableIDIndex = toolCalls.firstIndex(where: { toolCall in
               !isGeneratedToolID(toolCall.id) && toolCall.id == fallbackToolCall.id
           }) {
            return stableIDIndex
        }

        // Fingerprints preserve the saved-transcript dedupe rule when one side
        // has a generated fallback ID and both sides still carry matching args.
        let fallbackFingerprint = toolCallFingerprint(fallbackToolCall)
        if let fingerprintIndex = toolCalls.firstIndex(where: { toolCall in
            (fallbackIsGenerated || isGeneratedToolID(toolCall.id))
                && toolCallFingerprint(toolCall) == fallbackFingerprint
        }) {
            return fingerprintIndex
        }

        return matchingToolCallNameOrdinalIndex(
            for: fallbackToolCall,
            fallbackIsGenerated: fallbackIsGenerated,
            nameOrdinal: nameOrdinal,
            in: toolCalls
        )
    }

    private static func matchingToolCallNameOrdinalIndex(
        for fallbackToolCall: ToolCall,
        fallbackIsGenerated: Bool,
        nameOrdinal: Int,
        in toolCalls: [ToolCall]
    ) -> Int? {
        let fallbackNameKey = toolCallNameKey(fallbackToolCall)
        var currentOrdinal = 0

        for (index, toolCall) in toolCalls.enumerated() {
            guard toolCallNameKey(toolCall) == fallbackNameKey else { continue }
            // Name order is a last resort for live fallback events whose args
            // can be missing/truncated; never collapse two stable transcript IDs.
            guard fallbackIsGenerated || isGeneratedToolID(toolCall.id) else { continue }

            currentOrdinal += 1
            if currentOrdinal == nameOrdinal {
                return index
            }
        }

        return nil
    }

    private static func toolCallNameKey(_ toolCall: ToolCall) -> String {
        toolCall.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func argumentsKey(_ args: [String: JSONValue]?) -> String {
        guard let args, !args.isEmpty else { return "" }
        let sortedObject = Dictionary(uniqueKeysWithValues: args.sorted { $0.key < $1.key })
        return JSONValue.object(sortedObject).compactJSONString ?? ""
    }

    private static func mergingToolCall(_ existing: ToolCall, with fallback: ToolCall) -> ToolCall {
        let id = isGeneratedToolID(existing.id) && !isGeneratedToolID(fallback.id) ? fallback.id : existing.id

        return ToolCall(
            id: id,
            name: existing.name ?? fallback.name,
            preview: existing.preview ?? fallback.preview,
            args: existing.args ?? fallback.args,
            duration: existing.duration ?? fallback.duration,
            isError: mergedErrorState(existing.isError, fallback.isError),
            isCompleted: existing.isCompleted || fallback.isCompleted,
            startedAt: min(existing.startedAt, fallback.startedAt)
        )
    }

    private static func mergedErrorState(_ existing: Bool?, _ fallback: Bool?) -> Bool? {
        if existing == true || fallback == true {
            return true
        }

        return existing ?? fallback
    }
}

struct ToolCallGroupAnchorLookup: Equatable {
    private let groupsByAnchor: [String?: [ToolCallGroup]]

    init(groups: [ToolCallGroup] = []) {
        groupsByAnchor = Dictionary(grouping: groups) { group in
            group.anchorMessageID
        }
    }

    func groups(anchorMessageID: String?) -> [ToolCallGroup] {
        groupsByAnchor[anchorMessageID] ?? []
    }
}

private struct TurnGroupBuilder {
    let turnKey: String
    private(set) var id: String
    private(set) var anchorMessageID: String?
    private(set) var anchorIndex: Int
    private(set) var toolCalls: [ToolCall]

    init(turnKey: String, group: ToolCallGroup, anchorIndex: Int) {
        self.turnKey = turnKey
        id = group.id
        anchorMessageID = group.anchorMessageID
        self.anchorIndex = anchorIndex
        toolCalls = group.toolCalls
    }

    mutating func append(_ group: ToolCallGroup, anchorIndex: Int) {
        if anchorIndex < self.anchorIndex {
            id = group.id
            anchorMessageID = group.anchorMessageID
            self.anchorIndex = anchorIndex
        }
        toolCalls += group.toolCalls
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self {
            return object
        }

        return nil
    }

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
