import Foundation

/// Projection of the direct-Hermes picker contract into the shared native picker.
/// No webui transport, favorites, or Profile defaults participate in a chat choice.
struct BotModelCatalog {
    // Accepted by the pinned host's parse_reasoning_effort; "off" is a display command.
    static let effortLevels = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    let groups: [ModelCatalogGroup]
    let active: ModelCatalogOption?
    let capabilities: [ModelFavoriteKey: BotJSON]

    init(_ payload: BotJSON) {
        var seenProviders = Set<String>()
        var capabilities: [ModelFavoriteKey: BotJSON] = [:]
        groups = (payload["providers"].list ?? []).compactMap { row in
            guard let provider = row["slug"].text, !provider.isEmpty,
                  seenProviders.insert(provider).inserted else { return nil }
            var seenModels = Set<String>()
            let unavailable = Set((row["unavailable_models"].list ?? []).compactMap(\.text))
            let options = (row["models"].list ?? []).compactMap { value -> ModelCatalogOption? in
                guard row["authenticated"].flag != false, let id = value.text, !id.isEmpty,
                      !unavailable.contains(id), seenModels.insert(id).inserted else { return nil }
                let option = ModelCatalogOption(id: id, displayName: id, providerID: provider)
                capabilities[option.favoriteKey] = row["capabilities"][id]
                return option
            }
            return ModelCatalogGroup(id: provider, name: row["name"].text ?? provider,
                                     providerID: provider, models: options)
        }
        self.capabilities = capabilities
        if let id = payload["model"].text, !id.isEmpty {
            active = ModelCatalogOption(id: id, displayName: id, providerID: payload["provider"].text)
        } else { active = nil }
    }

    /// The host parses a flag string, not shell quoting. Reject tokens that could
    /// change scope; always send --session, even when the host persists picks by default.
    static func sessionModelValue(_ option: ModelCatalogOption) -> String? {
        func safe(_ value: String) -> Bool {
            !value.isEmpty && !value.contains(where: { $0.isWhitespace })
                && !value.contains("--") && !value.contains(where: { "‒–—―".contains($0) })
        }
        guard safe(option.id), let provider = option.providerID, safe(provider) else { return nil }
        return "\(option.id) --provider \(provider) --session"
    }
}

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
