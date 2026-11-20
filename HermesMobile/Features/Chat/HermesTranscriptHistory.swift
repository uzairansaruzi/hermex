import Foundation

struct HermesTranscriptHistory: Equatable {
    private(set) var rows: [BotJSON] = []
    private(set) var hasOlder = false
    private var ids: Set<Int> = []
    private var newer = 0
    private(set) var needsRecount = false
    private(set) var newestCoverage: HermesNewestCoverage?

    var nextOffset: Int { rows.count + newer }

    func reaches(_ rows: [BotJSON]) -> Bool {
        ids.isEmpty || rows.contains { Self.id($0).map(ids.contains) == true }
    }

    func holds(_ id: Int) -> Bool { ids.contains(id) }

    mutating func mergeNewest(_ fresh: [BotJSON], reachedStart: Bool) {
        var seen = Set<Int>()
        let fresh = fresh.filter { Self.id($0).map { seen.insert($0).inserted } == true }
        let freshIDs = fresh.compactMap(Self.id)
        newestCoverage = reachedStart ? .all : freshIDs.isEmpty ? nil : .from(rowIDs: freshIDs)
        if !reachedStart, let shared = rows.firstIndex(where: { Self.id($0).map(seen.contains) == true }) {
            replace(with: rows[..<shared].filter { Self.id($0).map(seen.contains) == false } + fresh)
        } else {
            replace(with: fresh)
            hasOlder = !reachedStart
        }
        newer = 0
        needsRecount = false
    }

    mutating func countNewer(in fresh: [BotJSON]) -> Bool {
        var seen = Set<Int>()
        let fresh = fresh.filter { Self.id($0).map { seen.insert($0).inserted } == true }
        guard let last = fresh.lastIndex(where: { Self.id($0).map(ids.contains) == true }) else { return false }
        newer = fresh.count - 1 - last
        needsRecount = false
        return true
    }

    @discardableResult
    mutating func prependOlder(_ page: [BotJSON]) -> Bool {
        var seen = ids
        let older = page.prefix { Self.id($0).map(ids.contains) != true }
            .filter { row in Self.id(row).map { seen.insert($0).inserted } == true }
        replace(with: older + rows)
        hasOlder = page.count >= HermesREST.transcriptPageSize
        needsRecount = hasOlder && older.isEmpty
        return !older.isEmpty
    }

    mutating func cut(before id: Int) {
        guard let index = rows.firstIndex(where: { Self.id($0) == id }) else { return }
        replace(with: Array(rows[..<index]))
        needsRecount = true
    }

    private mutating func replace(with rows: [BotJSON]) {
        self.rows = rows
        ids = Set(rows.compactMap(Self.id))
    }

    static func id(_ row: BotJSON) -> Int? { row["id"].integer }
}

enum HermesNewestCoverage: Equatable {
    case all
    case from(rowIDs: [Int])
}

enum HermesBranchCount {
    static func count(through rowID: Int, in rows: [BotJSON]) -> Int? {
        var count = 0
        for row in rows {
            let counts = copies(row)
            if counts { count += 1 }
            if HermesTranscriptHistory.id(row) == rowID { return counts ? count : nil }
        }
        return nil
    }

    private static func copies(_ row: BotJSON) -> Bool {
        guard let role = row["role"].text, role == "user" || role == "assistant" else { return false }
        return hasText(row["content"])
    }

    private static func hasText(_ content: BotJSON) -> Bool {
        switch content {
        case .string(let text): return isText(text)
        case .array(let parts):
            return parts.contains { part in
                if let text = part.text ?? part["text"].text { return isText(text) }
                return part["type"].text.map { objectHasText(part, kind: $0) } ?? false
            }
        case .object: return objectHasText(content, kind: content["type"].text)
        case .null: return false
        case .number, .bool: return true
        }
    }

    private static func objectHasText(_ object: BotJSON, kind: String?) -> Bool {
        guard let kind else { return object.fields?["text"].map { isText($0.text) } ?? true }
        return !["text", "input_text", "output_text"].contains(kind) || isText(object["text"].text ?? object["content"].text)
    }

    private static func isText(_ text: String?) -> Bool {
        text?.contains { !$0.isWhitespace } == true
    }
}

struct HermesCompaction: Equatable {
    let referenceText: String
    let anchorMessageID: String?
}

enum HermesTranscriptProjection {
    struct Result: Equatable {
        var messages: [ChatMessage] = []
        var toolCallGroups: [ToolCallGroup] = []
        var reasoningGroups: [ReasoningGroup] = []
        var compaction: HermesCompaction?
    }

    static func project(_ rows: [BotJSON], root: String) -> Result {
        var result = Result()
        var tools: [ToolCall] = []
        var reasoning: [String] = []
        var pendingStart: Int?
        var calls: [String: (name: String?, args: [String: JSONValue]?)] = [:]

        func flush(anchor: String?) {
            guard let start = pendingStart else { return }
            if !tools.isEmpty {
                result.toolCallGroups.append(ToolCallGroup(id: "\(root)/row-\(start)/tools", anchorMessageID: anchor, toolCalls: tools))
            }
            if !reasoning.isEmpty {
                result.reasoningGroups.append(ReasoningGroup(id: "\(root)/row-\(start)/reasoning", anchorMessageID: anchor,
                                                             text: reasoning.joined(separator: "\n\n")))
            }
            tools = []; reasoning = []; pendingStart = nil
        }

        for row in rows {
            guard let rowID = HermesTranscriptHistory.id(row), let role = row["role"].text else { continue }
            let kind = row["display_kind"].text
            if row["_compressed_summary"].flag == true {
                result.compaction = HermesCompaction(referenceText: summary(row["content"].text ?? ""),
                                                     anchorMessageID: result.messages.last?.messageId)
                guard row["display_content"].text != nil else { continue }
            }
            guard kind != "hidden" else { continue }
            switch role {
            case "tool":
                pendingStart = pendingStart ?? rowID
                let call = row["tool_call_id"].text.flatMap { calls[$0] }
                tools.append(ToolCall(
                    id: "\(root)/row-\(rowID)", name: call?.name ?? row["tool_name"].text,
                    preview: row["content"].toolResultPreview, args: call?.args, isCompleted: true,
                    startedAt: row["timestamp"].number ?? 0
                ))
            case "assistant", "user":
                if role == "assistant" {
                    for call in row["tool_calls"].list ?? [] {
                        guard let id = call["id"].text ?? call["call_id"].text else { continue }
                        calls[id] = (toolName(call, labels: row["tool_call_labels"][id]), arguments(call["function"]["arguments"]))
                    }
                    let thought = row["display_reasoning"].text ?? row["reasoning"].text ?? row["reasoning_content"].text
                    if let thought, !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pendingStart = pendingStart ?? rowID
                        reasoning.append(thought)
                    }
                }
                let text = Self.text(row)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      role == "assistant" || !text.drop(while: \.isWhitespace).hasPrefix("[System:") else { continue }
                let id = "\(root)/row-\(rowID)"
                flush(anchor: id)
                let isDelegationCompletion = kind == HermesDelegationCompletion.displayKind
                let steer = role == "user" ? ChatMessage.strippedSteerText(from: text) : nil
                let skill = role == "user" ? skillInvocation(text) : nil
                result.messages.append(ChatMessage(
                    role: isDelegationCompletion ? "delegation_completion" : role,
                    content: skill ?? (role == "user" && !isDelegationCompletion ? BotMentions.displayText(steer ?? text) : text),
                    timestamp: row["timestamp"].number,
                    messageId: id,
                    displayKind: steer != nil ? ChatMessage.steerDisplayKind : kind ?? (skill == nil ? nil : "skill_invocation"),
                    displayMetadata: row["display_metadata"].argumentDictionary,
                    rowID: rowID,
                    isCompacted: row["active"].integer == 0
                ))
            default:
                continue
            }
        }
        flush(anchor: nil)
        return result
    }

    private static func text(_ row: BotJSON) -> String {
        let body: String
        if let shown = row["display_content"].text {
            body = shown
        } else if let parts = row["content"].list {
            body = parts.compactMap { $0.text ?? $0["text"].text }.joined()
        } else {
            body = row["content"].text ?? ""
        }
        let commentary = (row["display_commentary"].list ?? []).compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let joined = commentary.joined(separator: "\n\n")
        guard !commentary.isEmpty, joined.trimmingCharacters(in: .whitespacesAndNewlines)
            != body.trimmingCharacters(in: .whitespacesAndNewlines) else { return body }
        return ([joined] + (body.isEmpty ? [] : [body])).joined(separator: "\n\n")
    }

    static func skillInvocation(_ text: String) -> String? {
        guard let head = text.range(of: "[IMPORTANT: The user has invoked the ", options: .anchored) else { return nil }
        let quoted = text[head.upperBound...]
        var name = ""
        if quoted.first == "\"", let close = quoted.dropFirst().firstIndex(of: "\"") {
            name = quoted[quoted.index(after: quoted.startIndex)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func cut(after marker: String, before stop: String, last: Bool = false) -> Substring {
            guard let start = text.range(of: marker, options: last ? .backwards : [])?.upperBound else { return "" }
            let tail = text[start...]
            return tail[..<(tail.range(of: stop)?.lowerBound ?? tail.endIndex)]
        }
        let instruction = text.contains(" skill bundle,")
            ? cut(after: "\nUser instruction: ", before: "\n\n[Loaded as part of the ")
            : text.contains("The full skill content is loaded below.]")
            ? cut(after: "The user has provided the following instruction alongside the skill invocation: ",
                  before: "\n\n[Runtime note:", last: true)
            : ""
        let words = instruction.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let label = name.hasPrefix("/") ? name : "/\(name)"
        if !words.isEmpty { return name.isEmpty ? words : "\(label) \(words)" }
        return name.isEmpty ? nil : label
    }

    private static func toolName(_ call: BotJSON, labels: BotJSON) -> String? {
        let named = (labels.list ?? []).compactMap { $0["text"].text ?? $0["name"].text }.filter { !$0.isEmpty }
        return named.isEmpty ? call["function"]["name"].text : named.joined(separator: ", ")
    }

    private static func arguments(_ value: BotJSON) -> [String: JSONValue]? {
        guard let text = value.text else { return value.argumentDictionary }
        return (try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8)))?.argumentDictionary
    }

    static func summary(_ content: String) -> String {
        var text = Substring(content)
        if let merged = text.range(of: "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]") {
            text = text[merged.upperBound...]
        }
        text = text.drop(while: \.isWhitespace)
        if ChatMarkerMessageClassifier.isContextCompactionText(String(text)) {
            text = text.firstIndex(of: "\n").map { text[$0...] } ?? ""
        }
        if let end = text.range(of: "--- END OF CONTEXT SUMMARY") { text = text[..<end.lowerBound] }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CronRunPrompt: Equatable {
    let skills: [String]
    let body: String

    private static let hint = "[IMPORTANT: You are running as a scheduled cron job."
    private static let missingSkills = "[IMPORTANT: The following skill(s) were listed for this job but could not be found and were skipped: "
    private static let instruction = "The user has provided the following instruction alongside the skill invocation: "
    private static let skill = "[IMPORTANT: The user has invoked the \""

    init?(_ message: ChatMessage) {
        guard message.role == "user", let content = message.content else { return nil }
        var rest = content[...]
        var skills: [String] = []
        if rest.hasPrefix(Self.missingSkills) {
            guard let task = rest.range(of: Self.instruction + Self.hint) else { return nil }
            for block in rest[..<task.lowerBound].split(separator: "\n") where block.hasPrefix(Self.skill) {
                skills.append(String(block.dropFirst(Self.skill.count).prefix { $0 != "\"" }))
            }
            rest = rest[task.lowerBound...].dropFirst(Self.instruction.count)
        }
        while rest.hasPrefix("/"), let space = rest.firstIndex(of: " ") {
            skills.append(String(rest[rest.index(after: rest.startIndex)..<space]))
            rest = rest[rest.index(after: space)...]
        }
        guard rest.hasPrefix(Self.hint), let end = Self.end(ofBracketOpening: rest) else { return nil }
        self.skills = skills
        body = rest[end...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func end(ofBracketOpening text: Substring) -> Substring.Index? {
        var depth = 0
        for index in text.indices {
            if text[index] == "[" {
                depth += 1
            } else if text[index] == "]" {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            }
        }
        return nil
    }
}
