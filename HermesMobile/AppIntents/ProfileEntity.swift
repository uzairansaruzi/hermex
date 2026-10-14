import AppIntents
import Foundation

/// An App Intents value standing in for a server profile, so an intent can take "which
/// profile" as a parameter the user picks while configuring a Shortcut / Siri phrase
/// (issue #339). This is the *shared* entity issue #8 (profile widgets) reuses — whichever
/// of #339/#8 ships first owns it, the other reuses it, so the picker plumbing isn't
/// duplicated.
struct ProfileEntity: AppEntity, Identifiable, Equatable {
    /// A webui profile's server name (e.g. `default`, `dev`): the stable identifier the deep link
    /// and `createSession(profile:)` use to pin a new chat to this profile. A Hermes server's
    /// Profile is `<server URL>|<profile>` (#1180), so the same name on two servers is two choices.
    let id: String
    /// Human-facing label, mirroring `ProfileSummary.displayName` (so `default` → "Default").
    let name: String
    /// Optional one-line subtitle for the picker (model · provider), best-effort.
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
    /// A Hermes server's Profile (#1180), titled by the name its Bots roster last showed, with the
    /// Profile's own name under it; one the roster never named is titled by its own name alone.
    init(hermesServer server: URL, profile: String, title: String?) {
        let shown = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        id = "\(server.absoluteString)|\(profile)"
        name = shown.isEmpty ? profile : shown
        subtitle = shown.isEmpty || shown == profile ? nil : profile
    }

    /// The new Hermes session this Profile opens (#1180); nil for a webui profile's bare id, which
    /// keeps the webui route a Shortcut saved before #1180 has (#971).
    var hermesNewChat: HermesNewChatDestination? {
        guard let bar = id.firstIndex(of: "|"), let server = HermesNewChatDestination.server(String(id[..<bar])) else {
            return nil
        }
        let profile = String(id[id.index(after: bar)...])
        return profile.isEmpty ? nil : HermesNewChatDestination(server: server, profile: profile)
    }

    /// Builds an entity from a decoded server profile, skipping a profile with no usable name
    /// (the name is the load-bearing identifier for routing and session creation).
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

/// Supplies the profile choices for a profile-parameterized App Intent. iOS runs this
/// *outside* the live app (e.g. while you configure a Shortcut, possibly before the app has
/// launched), so it can't assume a logged-in session: each server is read fresh, then falls back
/// to what the app cached on its last foreground load, so the picker is still populated when a
/// read can't authenticate. Both paths degrade to an empty list rather than throwing, which the
/// system renders as an empty picker (#339). The picker has a section per server (#1180).
struct ProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [ProfileEntity.ID]) async throws -> [ProfileEntity] {
        await ProfileEntityProvider.entities(for: identifiers)
    }

    /// One server's choices are one untitled section.
    func suggestedEntities() async throws -> IntentItemCollection<ProfileEntity> {
        let sections = await ProfileEntityProvider.sections()
        guard sections.count > 1 else { return IntentItemCollection(items: sections.first?.profiles ?? []) }
        return IntentItemCollection(sections: sections.map { IntentItemSection("\($0.title)", items: $0.profiles) })
    }
}

/// One server's part of the Profile picker (#1180), titled by the server's name.
struct ProfileEntitySection: Equatable {
    let title: String
    let profiles: [ProfileEntity]
}

/// Resolves the current profile list for App Intents, live-first with a cached fallback.
/// Kept separate from the `EntityQuery` so the fetch/cache policy is reusable (e.g. by #8).
enum ProfileEntityProvider {
    /// The webui server's profiles (`profileServer`), live-first with a cached fallback.
    static func currentEntities() async -> [ProfileEntity] {
        // A successful fetch always mirrors into the cache: a non-empty result is stored and
        // returned, while an empty result clears the cache (the server genuinely has no
        // profiles) so a stale list can't linger. A *failed* fetch (nil) leaves the cache
        // untouched, so a transient network/auth blip falls back to the last-known profiles
        // instead of emptying the picker.
        if let live = try? await fetchLiveProfiles() {
            ProfileEntityCache.shared.save(live)
            if !live.isEmpty { return live.compactMap(ProfileEntity.init) }
        }
        return ProfileEntityCache.shared.loadEntities()
    }

    /// The picker's sections, one per configured server in the registry's order (#1180): a
    /// Hermes server's Profiles as its public `/api/status` names them (no sign-in from here),
    /// else as its Bots roster last cached them, and the webui server `profileServer` picks,
    /// whose bare ids New Chat in Profile opens wherever they always have. Every server is read
    /// at once; one with nothing to list has no section.
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
                let titles = Dictionary(cached.map { ($0.profile, $0.title) }, uniquingKeysWith: { first, _ in first })
                profiles = (live[account.id] ?? cached.map(\.profile)).map {
                    ProfileEntity(hermesServer: server, profile: $0, title: titles[$0])
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

    /// Saved Shortcuts' Profiles. A Hermes id resolves from the id itself while its server is
    /// configured, titled from the cached roster without reading the host; a bare id resolves
    /// against the webui list as it always has (#971), or while a webui server's move to Hermes
    /// named it, even after that server is removed (#1217). Running it then decides where it goes
    /// (`MovedWebuiRoute.newChat`), and opens nothing where more than one place could take it.
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
            let title = names.names(for: chat.server).first { $0.profile == profile }?.title
            return ProfileEntity(hermesServer: chat.server, profile: profile, title: title)
        }
    }

    /// The Profile names a Hermes server's public `/api/status` reports, read with the Connection
    /// Headers its saved sign-in carries, as every request to it does. Nil when it can't be read.
    @MainActor static func liveProfileNames(of account: ServerAccount,
                                            probe: BotHostStatusProbe = BotHostStatusProbe()) async -> [String]? {
        guard let server = URL(string: account.urlString) else { return nil }
        let headers = (try? BotConnectionStore().load(server: server))?.map(HermesHeaders.init(saved:)) ?? .none
        guard case .success(let status) = await probe.check(server, headers: headers) else { return nil }
        return status.profiles
    }

    /// The server's name as its avatar's switcher shows it: its display name, else its host.
    private static func name(of account: ServerAccount) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? URL(string: account.urlString)?.host ?? account.urlString : name
    }

    /// Best-effort live fetch against the saved server. Returns `[]` (not an error) when no
    /// server is configured; a network/auth failure throws so the caller falls back to cache.
    ///
    /// Runs out-of-process (App Intents), where `CustomHeaderStore.shared` — which
    /// `AuthManager` hydrates only on a foreground launch — is empty. So we read the server's
    /// custom headers straight from the Keychain (reachable cross-process) and pass them
    /// explicitly; otherwise a reverse proxy that authenticates on a header rejects this fetch
    /// and the picker can never refresh live. (The session cookie is also absent out-of-process,
    /// so a cookie-auth server still falls back to the cache — this just stops the ad-hoc client
    /// from silently dropping the headers every other client in the app carries.)
    private static func fetchLiveProfiles() async throws -> [ProfileSummary] {
        guard let server = profileServer(active: savedServerURL(), servers: ServerRegistry.shared.servers) else { return [] }
        let headers = customHeaders(for: server)
        let response = try await APIClient(baseURL: server, customHeaderProvider: { headers }).profiles()
        return response.profiles ?? []
    }

    /// The webui server whose Profiles Shortcuts lists: the active one, or while a Hermes
    /// server is active the first webui server, which New Chat in Profile switches to.
    /// Nil when no webui server is configured. A webui server that moved to Hermes still lists
    /// here; running its Profile's Shortcut follows the move (`MovedWebuiRoute.newChat`, #1217).
    static func profileServer(active: URL?, servers: [ServerAccount]) -> URL? {
        guard let active else { return nil }
        guard servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes else { return active }
        return servers.first { $0.kind == .webui }.flatMap { URL(string: $0.urlString) }
    }

    /// Loads the server's stored custom headers (scoped key first, then the pre-#16 global
    /// blob) without mutating the Keychain — mirrors `AuthManager.hydrateCustomHeaders`, but
    /// read-only since this runs in the App Intents process.
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

    /// Nudges the system to re-read `suggestedEntities()` so a freshly loaded profile list
    /// surfaces (or updates) the parameterized "New Chat in <Profile>" App Shortcut. iOS only
    /// indexes a parameterized App Shortcut once its suggested values exist, so without this
    /// call the shortcut never appears — the parameter-less New Chat shortcuts show, but this
    /// one doesn't until the system re-queries (#339).
    ///
    /// Fires on the first profile load of each app launch (so the shortcut re-registers after
    /// an app reinstall / index reset, even when the profile list itself is unchanged) and on
    /// any later change — but not on every redundant reload, to avoid needless re-indexing.
    @MainActor
    static func refreshAppShortcuts(changed: Bool) {
        guard changed || !didRefreshAppShortcutsThisLaunch else { return }
        didRefreshAppShortcutsThisLaunch = true
        HermexShortcuts.updateAppShortcutParameters()
    }
}

/// Persists the last-known profile list to the app-group container so an App Intents query
/// (and #8's widgets, which run out-of-process) can populate their picker without a live,
/// authenticated server call. The app refreshes this on every foreground profiles load.
struct ProfileEntityCache {
    static let shared = ProfileEntityCache()

    private let defaults: UserDefaults?
    // `.v2`: bumped from v1 when the App Shortcut refresh nudge was added, so the first load
    // on an upgraded install reads an empty cache and is treated as a change — which fires
    // `updateAppShortcutParameters()` once even though the profile list itself is unchanged.
    private let storageKey = "cachedProfileEntities.v2"

    init(defaults: UserDefaults? = UserDefaults(suiteName: HermesShareDraft.appGroupIdentifier)) {
        self.defaults = defaults
    }

    /// Mirrors the profiles into the cache: writes a compact snapshot when non-empty, clears
    /// the entry when empty so a stale list can't linger after the server reports none.
    /// Returns whether the stored snapshot actually changed, so the caller can avoid
    /// re-indexing App Shortcuts when nothing moved.
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

/// Minimal codable snapshot of a profile for the cache — deliberately decoupled from the
/// server model so an upstream shape change can't break a cached read.
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

/// The Profile names each Hermes server's Bots roster last showed (#1180), in the app-group
/// container, so the Shortcuts picker titles a host's Profiles as the app does and still lists
/// them while the host can't be read or is signed out. One entry per server, keyed by a digest of
/// its URL so the app group holds no server URL, written on every roster read and deleted with
/// the server.
struct HermesProfileNameCache {
    struct Name: Codable, Equatable {
        let profile: String
        let title: String
    }

    static let shared = HermesProfileNameCache()

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: HermesShareDraft.appGroupIdentifier)) {
        self.defaults = defaults
    }

    /// Replaces `server`'s names, an empty roster clearing them, and returns whether they changed,
    /// so the caller re-indexes App Shortcuts only then.
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
