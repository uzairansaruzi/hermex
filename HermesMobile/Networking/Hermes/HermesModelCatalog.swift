import Foundation

struct HermesModelCatalog {
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
            guard !options.isEmpty else { return nil }
            return ModelCatalogGroup(id: provider, name: row["name"].text ?? provider,
                                     providerID: provider, models: options)
        }
        self.capabilities = capabilities
        if let id = payload["model"].text, !id.isEmpty {
            active = ModelCatalogOption(id: id, displayName: id, providerID: payload["provider"].text)
        } else { active = nil }
    }

    static func sessionModelValue(_ option: ModelCatalogOption) -> String? {
        func safe(_ value: String) -> Bool {
            !value.isEmpty && !value.contains(where: { $0.isWhitespace })
                && !value.contains("--") && !value.contains(where: { "‒–—―".contains($0) })
        }
        guard safe(option.id), let provider = option.providerID, safe(provider) else { return nil }
        return "\(option.id) --provider \(provider) --session"
    }
}
