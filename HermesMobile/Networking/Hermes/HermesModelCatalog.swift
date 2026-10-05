import Foundation

/// `model.options` projected into the shared native picker: providers the host has not
/// authenticated, models it marks unavailable, and providers left with none are left out. Bot Chat's model menu and a
/// Hermes session's composer (#1015) both read it; no webui transport participates.
struct HermesModelCatalog {
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
            // As webui's catalog does, a provider with nothing to pick gets no section.
            guard !options.isEmpty else { return nil }
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
