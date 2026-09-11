import Foundation

/// The bot's plan from `todo.updated` events and the snapshot's `todo_state`.
/// Revision-monotonic: an older revision never replaces a newer one.
struct BotPlan: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let content: String
        /// `pending`, `in_progress`, `completed` or `cancelled`; anything else reads as pending.
        let status: String
        var isDone: Bool { status == "completed" || status == "cancelled" }
    }

    static let itemLimit = 50

    let items: [Item]
    let revision: Int

    /// `nil` when the payload is malformed or carries no items.
    init?(_ json: BotJSON) {
        guard let rows = json["todos"].list else { return nil }
        let items: [Item] = rows.prefix(Self.itemLimit).enumerated().compactMap { index, row in
            guard let content = row["content"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
            let id = row["id"].text.flatMap { $0.isEmpty ? nil : $0 } ?? "plan-\(index)"
            return Item(id: id, content: content, status: row["status"].text ?? "pending")
        }
        guard !items.isEmpty else { return nil }
        self.items = items
        revision = max(0, json["revision"].integer ?? 0)
    }

    var completedCount: Int { items.filter(\.isDone).count }
    var current: Item? { items.first { $0.status == "in_progress" } ?? items.first { !$0.isDone } }
    var isFinished: Bool { items.allSatisfy(\.isDone) }
}

/// A keyed notice from `notification.show`; the same key replaces in place.
struct BotNotice: Identifiable, Equatable {
    let id: String
    let text: String
    let level: String?
    var isWarning: Bool { level == "warn" || level == "error" }
}

/// One turn's live work reduced from gateway events: tool rows, model-supplied
/// reasoning, keyed notices and memory review notes. Every collection is bounded
/// and the oldest entries drop first. Pure, so replay and live delivery share it.
struct BotTurnActivity: Equatable {
    static let toolLimit = 64
    static let reasoningLimit = 32_768
    static let noticeLimit = 8

    private(set) var toolCalls: [ToolCall] = []
    private(set) var reasoning = ""
    private(set) var notices: [BotNotice] = []
    private(set) var memoryNotes: [String] = []

    var hasTurnWork: Bool { !toolCalls.isEmpty || !reasoning.isEmpty }

    /// Event types this reducer consumes; they never change the inflight text.
    static func handles(_ type: String) -> Bool {
        ["tool.start", "tool.complete", "thinking.delta", "reasoning.delta", "reasoning.available",
         "notification.show", "notification.clear", "review.summary"].contains(type)
    }

    /// Applies one event; returns false for types this reducer does not consume.
    @discardableResult
    mutating func apply(type: String, payload: BotJSON) -> Bool {
        switch type {
        case "tool.start":
            let id = Self.toolID(payload) ?? "bot-tool-\(toolCalls.count)"
            let call = ToolCall(id: id, name: payload["name"].text, preview: nil, args: payload["args"].argumentDictionary)
            if let index = toolCalls.firstIndex(where: { $0.id == id }) {
                toolCalls[index].name = call.name ?? toolCalls[index].name
                toolCalls[index].args = call.args ?? toolCalls[index].args
            } else {
                toolCalls.append(call)
                if toolCalls.count > Self.toolLimit { toolCalls.removeFirst(toolCalls.count - Self.toolLimit) }
            }
        case "tool.complete":
            let id = Self.toolID(payload)
            let index = id.flatMap { id in toolCalls.firstIndex { $0.id == id } }
            var call = index.map { toolCalls[$0] }
                ?? ToolCall(id: id ?? "bot-tool-\(toolCalls.count)", name: nil, preview: nil, args: nil)
            if let name = payload["name"].text, !name.isEmpty { call.name = name }
            if let args = payload["args"].argumentDictionary { call.args = args }
            call.preview = Self.resultPreview(payload["result"])
            call.duration = payload["duration_s"].number
            call.isCompleted = true
            if let index { toolCalls[index] = call } else {
                toolCalls.append(call)
                if toolCalls.count > Self.toolLimit { toolCalls.removeFirst(toolCalls.count - Self.toolLimit) }
            }
        case "thinking.delta", "reasoning.delta", "reasoning.available":
            guard let text = payload["text"].text, !text.isEmpty else { return true }
            // `reasoning.available` is a whole block; keep it off the previous line.
            if type == "reasoning.available", !reasoning.isEmpty, !reasoning.hasSuffix("\n") { reasoning.append("\n") }
            reasoning.append(text)
            if reasoning.count > Self.reasoningLimit { reasoning = String(reasoning.suffix(Self.reasoningLimit)) }
        case "notification.show":
            guard let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return true }
            let key = payload["key"].text ?? payload["id"].text ?? "notice-\(notices.count)"
            let notice = BotNotice(id: key, text: text, level: payload["level"].text)
            if let index = notices.firstIndex(where: { $0.id == key }) { notices[index] = notice } else {
                notices.append(notice)
                if notices.count > Self.noticeLimit { notices.removeFirst(notices.count - Self.noticeLimit) }
            }
        case "notification.clear":
            guard let key = payload["key"].text else { return true }
            notices.removeAll { $0.id == key }
        case "review.summary":
            guard let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return true }
            memoryNotes.append(text)
            if memoryNotes.count > Self.noticeLimit { memoryNotes.removeFirst(memoryNotes.count - Self.noticeLimit) }
        default:
            return false
        }
        return true
    }

    /// Drops the turn's tool rows and reasoning once a settled snapshot carries
    /// them. Notices and memory notes stay until the next turn starts.
    mutating func clearTurnWork() {
        toolCalls = []
        reasoning = ""
    }

    private static func toolID(_ payload: BotJSON) -> String? {
        guard let id = payload["tool_id"].text, !id.isEmpty else { return nil }
        return id
    }

    /// The result as the text the shared tool row formatter parses: a string as
    /// is, any other JSON re-encoded so envelope fields such as `error` are read.
    static func resultPreview(_ result: BotJSON) -> String? {
        switch result {
        case .null: return nil
        case .string(let text): return text.isEmpty ? nil : text
        default:
            guard let data = try? JSONEncoder().encode(result) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Settled tool rows and reasoning from a resume snapshot, placed before the
/// message they precede. `anchorMessageID == nil` means after the last message.
struct BotSettledActivity: Identifiable, Equatable {
    let id: String
    let anchorMessageID: String?
    let toolCalls: [ToolCall]
    let reasoning: String?
}

/// Projects the snapshot's `messages` rows into text messages plus settled
/// activity. Message identity stays `<root>/<row index>`, so ids are stable
/// across refreshes and unaffected by how many tool rows sit between messages.
enum BotTranscriptProjection {
    static func project(history: [BotJSON], root: String) -> (messages: [ChatMessage], activity: [BotSettledActivity]) {
        var messages: [ChatMessage] = []
        var activity: [BotSettledActivity] = []
        var pendingTools: [ToolCall] = []
        var pendingReasoning: [String] = []
        var pendingStart: Int?

        func flush(anchor: String?) {
            guard let start = pendingStart, !pendingTools.isEmpty || !pendingReasoning.isEmpty else { return }
            activity.append(BotSettledActivity(
                id: "\(root)/\(start)/activity", anchorMessageID: anchor, toolCalls: pendingTools,
                reasoning: pendingReasoning.isEmpty ? nil : pendingReasoning.joined(separator: "\n\n")
            ))
            pendingTools = []; pendingReasoning = []; pendingStart = nil
        }

        for (index, row) in history.enumerated() {
            guard let role = row["role"].text else { continue }
            switch role {
            case "tool":
                pendingStart = pendingStart ?? index
                pendingTools.append(ToolCall(
                    id: "\(root)/\(index)", name: row["name"].text, preview: row["context"].text,
                    args: row["args"].argumentDictionary, isCompleted: true
                ))
            case "assistant", "user":
                if role == "assistant", let text = row["reasoning"].text ?? row["reasoning_content"].text,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pendingStart = pendingStart ?? index
                    pendingReasoning.append(text)
                }
                guard let text = row["text"].text else { continue }
                let id = "\(root)/\(index)"
                flush(anchor: id)
                messages.append(ChatMessage(role: role, content: text, timestamp: nil, messageId: id))
            default:
                continue
            }
        }
        flush(anchor: nil)
        return (messages, activity)
    }
}

extension BotJSON {
    /// Tool arguments in the shared transcript model's JSON type.
    var argumentDictionary: [String: JSONValue]? {
        guard case .object(let object) = self, !object.isEmpty else { return nil }
        return object.mapValues(\.jsonValue)
    }

    var jsonValue: JSONValue {
        switch self {
        case .object(let value): return .object(value.mapValues(\.jsonValue))
        case .array(let value): return .array(value.map(\.jsonValue))
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .bool(let value): return .bool(value)
        case .null: return .null
        }
    }
}
