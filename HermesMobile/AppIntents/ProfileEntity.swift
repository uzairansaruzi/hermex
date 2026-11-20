import AppIntents
import Foundation

struct ProfileEntity: AppEntity, Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Profile")
    }

    static var defaultQuery = ProfileEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        if let subtitle, !subtitle.isEmpty {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
        }
        return DisplayRepresentation(title: "\(name)")
    }
}

extension ProfileEntity {
    init(hermesServer server: URL, profile: String, title: String?, model: String? = nil) {
        let shown = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        id = "\(server.absoluteString)|\(profile)"
        name = shown.isEmpty ? profile : shown
        let details = [shown.isEmpty || shown == profile ? "" : profile, model].filter { !$0.isEmpty }
        subtitle = details.isEmpty ? nil : details.joined(separator: " · ")
    }

    var hermesNewChat: HermesNewChatDestination? {
        guard let bar = id.firstIndex(of: "|"), let server = HermesNewChatDestination.server(String(id[..<bar])) else {
            return nil
        }
        let profile = String(id[id.index(after: bar)...])
        return profile.isEmpty ? nil : HermesNewChatDestination(server: server, profile: profile)
    }

    init?(_ summary: ProfileSummary) {
        guard let id = summary.normalizedName else { return nil }
        self.id = id
        self.name = summary.displayName
        self.subtitle = Self.subtitle(for: summary)
    }

    private static func subtitle(for summary: ProfileSummary) -> String? {
        let parts = [summary.model, summary.provider]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [ProfileEntity.ID]) async throws -> [ProfileEntity] {
        await ProfileEntityProvider.entities(for: identifiers)
    }

    func suggestedEntities() async throws -> IntentItemCollection<ProfileEntity> {
        let sections = await ProfileEntityProvider.sections()
        guard sections.count > 1 else { return IntentItemCollection(items: sections.first?.profiles ?? []) }
        return IntentItemCollection(sections: sections.map { IntentItemSection("\($0.title)", items: $0.profiles) })
    }
}

struct ProfileEntitySection: Equatable {
    let title: String
    let profiles: [ProfileEntity]
}

enum ProfileEntityProvider {
    static func currentEntities() async -> [ProfileEntity] {
        if let live = try? await fetchLiveProfiles() {
            ProfileEntityCache.shared.save(live)
            if !live.isEmpty { return live.compactMap(ProfileEntity.init) }
        }
        return ProfileEntityCache.shared.loadEntities()
    }

    @MainActor static func sections(
        servers: [ServerAccount] = ServerRegistry.shared.servers, active: URL? = savedServerURL(),
        names: HermesProfileNameCache = .shared,
        webui: @escaping @Sendable () async -> [ProfileEntity] = { await currentEntities() },
        liveNames: @escaping @Sendable (ServerAccount) async -> [String]? = { await liveProfileNames(of: $0) }
    ) async -> [ProfileEntitySection] {
        let webuiServer = profileServer(active: active, servers: servers)?.absoluteString
        async let webuiProfiles = webuiServer == nil ? [] : webui()
        var live: [String: [String]] = [:]
        await withTaskGroup(of: (String, [String]?).self) { group in
            for account in servers where account.kind == .hermes {
                group.addTask { (account.id, await liveNames(account)) }
            }
            for await (id, listed) in group { live[id] = listed }
        }
        let webuiList = await webuiProfiles
        return servers.compactMap { account in
            let profiles: [ProfileEntity]
            switch account.kind {
            case .hermes:
                guard let server = URL(string: account.urlString) else { return nil }
                let cached = names.names(for: server)
                let named = Dictionary(cached.map { ($0.profile, $0) }, uniquingKeysWith: { first, _ in first })
                profiles = (live[account.id] ?? cached.map(\.profile)).map {
                    ProfileEntity(hermesServer: server, profile: $0, title: named[$0]?.title, model: named[$0]?.model)
                }
            case .webui:
                guard account.id == webuiServer else { return nil }
                profiles = webuiList
            }
            guard !profiles.isEmpty else { return nil }
            let name = Self.name(of: account)
            return ProfileEntitySection(title: account.kind == .webui ? String(localized: "\(name) (Web UI)") : name,
                                        profiles: profiles)
        }
    }

    @MainActor static func entities(
        for identifiers: [String], servers: [ServerAccount] = ServerRegistry.shared.servers,
        names: HermesProfileNameCache = .shared, webui: () async -> [ProfileEntity] = { await currentEntities() }
    ) async -> [ProfileEntity] {
        let bare = identifiers.contains { ProfileEntity(id: $0, name: $0, subtitle: nil).hermesNewChat == nil }
        let webuiList = bare ? await webui() : []
        return identifiers.compactMap { id in
            guard let chat = ProfileEntity(id: id, name: id, subtitle: nil).hermesNewChat, let profile = chat.profile else {
                if let listed = webuiList.first(where: { $0.id == id }) { return listed }
                return MovedWebuiRoute.names(profile: id, in: servers) ? ProfileEntity(id: id, name: id, subtitle: nil) : nil
            }
            guard servers.contains(where: { $0.id == chat.server.absoluteString && $0.kind == .hermes }) else { return nil }
            let named = names.names(for: chat.server).first { $0.profile == profile }
            return ProfileEntity(hermesServer: chat.server, profile: profile, title: named?.title, model: named?.model)
        }
    }

    @MainActor static func liveProfileNames(of account: ServerAccount,
                                            probe: BotHostStatusProbe = BotHostStatusProbe()) async -> [String]? {
        guard let server = URL(string: account.urlString) else { return nil }
        let headers = (try? BotConnectionStore().load(server: server))?.map(HermesHeaders.init(saved:)) ?? .none
        guard case .success(let status) = await probe.check(server, headers: headers) else { return nil }
        return status.profiles
    }

    private static func name(of account: ServerAccount) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? URL(string: account.urlString)?.host ?? account.urlString : name
    }

    private static func fetchLiveProfiles() async throws -> [ProfileSummary] {
        guard let server = profileServer(active: savedServerURL(), servers: ServerRegistry.shared.servers) else { return [] }
        let headers = customHeaders(for: server)
        let response = try await APIClient(baseURL: server, customHeaderProvider: { headers }).profiles()
        return response.profiles ?? []
    }

    static func profileServer(active: URL?, servers: [ServerAccount]) -> URL? {
        guard let active else { return nil }
        guard servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes else { return active }
        return servers.first { $0.kind == .webui }.flatMap { URL(string: $0.urlString) }
    }

    private static func customHeaders(for server: URL) -> [CustomHeader] {
        let keychain = KeychainStore()
        let stored: String?
        if let scoped = try? keychain.load(.customHeaders, scope: server.absoluteString) {
            stored = scoped
        } else {
            stored = try? keychain.load(.customHeaders)
        }
        return [CustomHeader].decodeFromStorage(stored)
    }

    static func savedServerURL() -> URL? {
        guard let raw = try? KeychainStore().load(.serverURL),
              let url = URL(string: raw) else {
            return nil
        }
        return url
    }

    @MainActor private static var didRefreshAppShortcutsThisLaunch = false

    @MainActor
    static func refreshAppShortcuts(changed: Bool) {
        guard changed || !didRefreshAppShortcutsThisLaunch else { return }
        didRefreshAppShortcutsThisLaunch = true
        HermexShortcuts.updateAppShortcutParameters()
    }
}

struct ProfileEntityCache {
    static let shared = ProfileEntityCache()

    private let defaults: UserDefaults?
    private let storageKey = "cachedProfileEntities.v2"

    init(defaults: UserDefaults? = UserDefaults(suiteName: HermesShareDraft.appGroupIdentifier)) {
        self.defaults = defaults
    }

    @discardableResult
    func save(_ profiles: [ProfileSummary]) -> Bool {
        guard let defaults else { return false }
        let snapshot = profiles.compactMap(CachedProfile.init)
        guard snapshot != loadCached() else { return false }

        if snapshot.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return true
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    func loadEntities() -> [ProfileEntity] {
        loadCached().map(\.entity)
    }

    private func loadCached() -> [CachedProfile] {
        guard let defaults,
              let data = defaults.data(forKey: storageKey),
              let cached = try? JSONDecoder().decode([CachedProfile].self, from: data)
        else {
            return []
        }
        return cached
    }
}

private struct CachedProfile: Codable, Equatable {
    let id: String
    let name: String
    let subtitle: String?

    init?(_ summary: ProfileSummary) {
        guard let entity = ProfileEntity(summary) else { return nil }
        self.id = entity.id
        self.name = entity.name
        self.subtitle = entity.subtitle
    }

    var entity: ProfileEntity {
        ProfileEntity(id: id, name: name, subtitle: subtitle)
    }
}

struct HermesProfileNameCache {
    struct Name: Codable, Equatable {
        let profile: String
        let title: String
        var model: String? = nil
    }

    static let shared = HermesProfileNameCache()

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: HermesShareDraft.appGroupIdentifier)) {
        self.defaults = defaults
    }

    @discardableResult
    func save(_ names: [Name], for server: URL) -> Bool {
        guard let defaults, names != self.names(for: server) else { return false }
        if names.isEmpty {
            defaults.removeObject(forKey: key(server))
        } else if let data = try? JSONEncoder().encode(names) {
            defaults.set(data, forKey: key(server))
        }
        return true
    }

    func names(for server: URL) -> [Name] {
        guard let data = defaults?.data(forKey: key(server)) else { return [] }
        return (try? JSONDecoder().decode([Name].self, from: data)) ?? []
    }

    func remove(server: URL) {
        defaults?.removeObject(forKey: key(server))
    }

    private func key(_ server: URL) -> String { "hermesProfileNames.v1|\(BotHistoryCache.Scope.key(server))" }
}
