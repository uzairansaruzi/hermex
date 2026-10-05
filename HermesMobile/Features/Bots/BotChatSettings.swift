import Foundation

struct BotChatUsage: Equatable {
    let snapshot: ContextWindowSnapshot

    init(_ payload: BotJSON) {
        func count(_ key: String) -> Int? {
            guard let value = payload[key].integer, value >= 0 else { return nil }
            return value
        }
        snapshot = ContextWindowSnapshot(
            contextLength: count("context_max"), thresholdTokens: nil,
            lastPromptTokens: count("context_used"), inputTokens: count("input"),
            outputTokens: count("output"), estimatedCost: nil
        )
    }

    /// Session input is cumulative; it must never substitute for current context.
    var hasContext: Bool { snapshot.lastPromptTokens != nil && (snapshot.contextLength ?? 0) > 0 }
}

struct BotSessionControl: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case goal, loop, heartbeat
        var title: String {
            switch self {
            case .goal: return String(localized: "Goal")
            case .loop: return String(localized: "Loop")
            case .heartbeat: return String(localized: "Heartbeat")
            }
        }
    }
    let kind: Kind
    let status: String
    let title: String
    var id: String { kind.rawValue }
    var action: String? {
        switch status {
        case "active": return "\(id).pause"
        case "paused": return "\(id).resume"
        default: return nil
        }
    }
    var actionTitle: String {
        status == "paused" ? String(localized: "Resume") : String(localized: "Pause")
    }
    var consequence: String {
        status == "paused"
            ? String(localized: "Resume automatic work for this chat?")
            : String(localized: "Pause automatic follow-up work? The current response continues. You can resume here.")
    }
    static func read(_ payload: BotJSON) -> [Self] {
        Kind.allCases.compactMap { kind in
            let row = payload[kind.rawValue]
            guard let status = row["status"].text else { return nil }
            return Self(kind: kind, status: status, title: row["title"].text ?? row["prompt"].text ?? kind.title)
        }
    }
}

/// Kept separate from connection failures so a rejected setting preserves the host's explanation.
enum BotSettingFailure: Error, LocalizedError {
    case rejected(Int, String), unknownOutcome
    var errorDescription: String? {
        switch self {
        case .rejected(_, let message): return message
        case .unknownOutcome: return String(localized: "The change was not confirmed. Check its current value before trying again.")
        }
    }
}
