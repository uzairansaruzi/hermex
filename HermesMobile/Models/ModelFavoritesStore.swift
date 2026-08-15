import Foundation

struct ModelFavoriteKey: Codable, Equatable, Hashable {
    let modelID: String
    let providerID: String?
}

// Provider identity is server-scoped because two Hermex servers can expose the
// same provider ID for unrelated backends.
struct ProviderFavoritesStore: @unchecked Sendable {
    static let shared = ProviderFavoritesStore()

    private struct Snapshot: Codable {
        var servers: [String: [String]] = [:]
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "hermes.mobile.favoriteProviders"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func favoriteProviderIDs(serverID: String) -> [String] {
        Self.deduplicated(snapshot.servers[serverID] ?? [])
    }

    func isFavorite(providerID: String, serverID: String) -> Bool {
        favoriteProviderIDs(serverID: serverID).contains(providerID)
    }

    @discardableResult
    func toggleFavorite(providerID: String, serverID: String) -> [String] {
        guard let normalizedID = Self.normalized(providerID) else {
            return favoriteProviderIDs(serverID: serverID)
        }

        var value = snapshot
        var providerIDs = Self.deduplicated(value.servers[serverID] ?? [])
        if let index = providerIDs.firstIndex(of: normalizedID) {
            providerIDs.remove(at: index)
        } else {
            providerIDs.append(normalizedID)
        }
        value.servers[serverID] = providerIDs
        save(value)
        return providerIDs
    }

    func save(_ providerIDs: [String], serverID: String) {
        var value = snapshot
        value.servers[serverID] = Self.deduplicated(providerIDs)
        save(value)
    }

    private var snapshot: Snapshot {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return decoded
    }

    private func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func normalized(_ providerID: String) -> String? {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deduplicated(_ providerIDs: [String]) -> [String] {
        var seen = Set<String>()
        return providerIDs.compactMap(normalized).filter { seen.insert($0).inserted }
    }
}

// UserDefaults supports concurrent preference access; these stores are immutable wrappers around it.
struct ModelFavoritesStore: @unchecked Sendable {
    static let shared = ModelFavoritesStore()

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "hermes.mobile.favoriteModels"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
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
    static let shared = ModelRecentsStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let limit: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "hermes.mobile.recentModels",
        limit: Int = 5
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.limit = limit
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

    /// Full-picker recents intentionally include starred models. The compact
    /// composer menu keeps using `visibleRecentOptions` above so its Favorites
    /// and Recent sections remain de-duplicated.
    static func visibleAllRecentOptions(
        in groups: [ModelCatalogGroup],
        recentKeys: [ModelFavoriteKey]
    ) -> [ModelCatalogOption] {
        let optionsByKey = groups.catalogOptionsByFavoriteKey()

        return limitedDeduplicated(recentKeys, limit: recentKeys.count)
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

extension Sequence where Element == ModelCatalogGroup {
    func catalogOptionsByFavoriteKey() -> [ModelFavoriteKey: ModelCatalogOption] {
        var optionsByKey: [ModelFavoriteKey: ModelCatalogOption] = [:]
        for option in flatMap(\.models) where optionsByKey[option.favoriteKey] == nil {
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
