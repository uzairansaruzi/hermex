import Foundation

struct ModelFavoriteKey: Codable, Equatable, Hashable {
    let modelID: String
    let providerID: String?
}

struct ModelFavoritesStore: @unchecked Sendable {
    private static let baseKey = "hermes.mobile.favoriteModels"

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    init(server: URL, defaults: UserDefaults = .standard) {
        let key = defaults.scopedModelListKey(base: Self.baseKey, server: server)
        self.init(defaults: defaults, storageKey: key)
    }

    static func remove(for server: URL, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: UserDefaults.modelListKey(base: baseKey, server: server))
    }

    var favoriteKeys: [ModelFavoriteKey] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ModelFavoriteKey].self, from: data) else {
            return []
        }

        return Self.deduplicated(decoded)
    }

    func isFavorite(_ option: ModelCatalogOption) -> Bool {
        favoriteKeys.contains(option.favoriteKey)
    }

    @discardableResult
    func toggleFavorite(for option: ModelCatalogOption) -> [ModelFavoriteKey] {
        let key = option.favoriteKey
        var keys = favoriteKeys

        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
        } else {
            keys.append(key)
        }

        save(keys)
        return keys
    }

    @discardableResult
    func removeFavorite(for option: ModelCatalogOption) -> [ModelFavoriteKey] {
        let keys = favoriteKeys.filter { $0 != option.favoriteKey }
        save(keys)
        return keys
    }

    func save(_ keys: [ModelFavoriteKey]) {
        let deduplicated = Self.deduplicated(keys)
        guard let data = try? JSONEncoder().encode(deduplicated) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func visibleFavoriteOptions(
        in groups: [ModelCatalogGroup],
        favoriteKeys: [ModelFavoriteKey]
    ) -> [ModelCatalogOption] {
        let optionsByKey = groups.catalogOptionsByFavoriteKey()

        return deduplicated(favoriteKeys).map { key in
            optionsByKey[key] ?? key.fallbackOption
        }
    }

    private static func deduplicated(_ keys: [ModelFavoriteKey]) -> [ModelFavoriteKey] {
        var seen = Set<ModelFavoriteKey>()
        var result: [ModelFavoriteKey] = []

        for key in keys where seen.insert(key).inserted {
            result.append(key)
        }

        return result
    }
}

struct ModelRecentsStore: @unchecked Sendable {
    private static let baseKey = "hermes.mobile.recentModels"

    private let defaults: UserDefaults
    private let storageKey: String
    private let limit: Int

    init(defaults: UserDefaults, storageKey: String, limit: Int = 5) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.limit = limit
    }

    init(server: URL, defaults: UserDefaults = .standard) {
        let key = defaults.scopedModelListKey(base: Self.baseKey, server: server)
        self.init(defaults: defaults, storageKey: key)
    }

    static func remove(for server: URL, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: UserDefaults.modelListKey(base: baseKey, server: server))
    }

    var recentKeys: [ModelFavoriteKey] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ModelFavoriteKey].self, from: data) else {
            return []
        }

        return Self.limitedDeduplicated(decoded, limit: limit)
    }

    @discardableResult
    func recordRecent(_ option: ModelCatalogOption) -> [ModelFavoriteKey] {
        let key = option.favoriteKey
        let keys = Self.limitedDeduplicated([key] + recentKeys, limit: limit)
        save(keys)
        return keys
    }

    @discardableResult
    func removeRecent(for option: ModelCatalogOption) -> [ModelFavoriteKey] {
        let keys = recentKeys.filter { $0 != option.favoriteKey }
        save(keys)
        return keys
    }

    func save(_ keys: [ModelFavoriteKey]) {
        let deduplicated = Self.limitedDeduplicated(keys, limit: limit)
        guard let data = try? JSONEncoder().encode(deduplicated) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func visibleRecentOptions(
        in groups: [ModelCatalogGroup],
        recentKeys: [ModelFavoriteKey],
        favoriteKeys: [ModelFavoriteKey]
    ) -> [ModelCatalogOption] {
        let favoriteKeySet = Set(favoriteKeys)
        let optionsByKey = groups.catalogOptionsByFavoriteKey()

        return limitedDeduplicated(recentKeys, limit: recentKeys.count)
            .filter { !favoriteKeySet.contains($0) }
            .map { key in optionsByKey[key] ?? key.fallbackOption }
    }

    private static func limitedDeduplicated(_ keys: [ModelFavoriteKey], limit: Int) -> [ModelFavoriteKey] {
        var seen = Set<ModelFavoriteKey>()
        var result: [ModelFavoriteKey] = []

        for key in keys where seen.insert(key).inserted {
            result.append(key)
            if result.count == limit {
                break
            }
        }

        return result
    }
}

struct ModelPreset: Codable, Equatable {
    var effort: String?
    var fast: Bool?
}

struct ModelPresetStore: @unchecked Sendable {
    private static let baseKey = "hermes.mobile.modelPresets"

    private let defaults: UserDefaults
    private let storageKey: String

    init(server: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storageKey = defaults.scopedModelListKey(base: Self.baseKey, server: server)
    }

    static func remove(for server: URL, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: UserDefaults.modelListKey(base: baseKey, server: server))
    }

    func preset(for key: ModelFavoriteKey) -> ModelPreset? { presets[key] }

    func record(effort: String, for key: ModelFavoriteKey) {
        var all = presets
        all[key, default: ModelPreset()].effort = effort
        save(all)
    }

    func record(fast: Bool, for key: ModelFavoriteKey) {
        var all = presets
        all[key, default: ModelPreset()].fast = fast
        save(all)
    }

    private var presets: [ModelFavoriteKey: ModelPreset] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ModelFavoriteKey: ModelPreset].self, from: data) else { return [:] }
        return decoded
    }

    private func save(_ presets: [ModelFavoriteKey: ModelPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private extension UserDefaults {
    static func modelListKey(base: String, server: URL) -> String {
        "\(base)|\(server.absoluteString)"
    }

    func scopedModelListKey(base: String, server: URL) -> String {
        let key = Self.modelListKey(base: base, server: server)
        if let shared = object(forKey: base) {
            if object(forKey: key) == nil { set(shared, forKey: key) }
            removeObject(forKey: base)
        }
        return key
    }
}

extension Sequence where Element == ModelCatalogGroup {
    func catalogOptionsByFavoriteKey() -> [ModelFavoriteKey: ModelCatalogOption] {
        var optionsByKey: [ModelFavoriteKey: ModelCatalogOption] = [:]
        for option in flatMap(\.allModels) where optionsByKey[option.favoriteKey] == nil {
            optionsByKey[option.favoriteKey] = option
        }
        return optionsByKey
    }
}

extension ModelCatalogOption {
    var favoriteKey: ModelFavoriteKey {
        ModelFavoriteKey(modelID: id, providerID: providerID)
    }
}

private extension ModelFavoriteKey {
    var fallbackOption: ModelCatalogOption {
        ModelCatalogOption(id: modelID, displayName: modelID, providerID: providerID)
    }
}
