import AppIntents
import Foundation

/// An App Intents value standing in for a server profile, so an intent can take "which
/// profile" as a parameter the user picks while configuring a Shortcut / Siri phrase
/// (issue #339). This is the *shared* entity issue #8 (profile widgets) reuses — whichever
/// of #339/#8 ships first owns it, the other reuses it, so the picker plumbing isn't
/// duplicated.
struct ProfileEntity: AppEntity, Identifiable {
    /// The profile's server name (e.g. `default`, `dev`). The stable identifier the deep link
    /// and `createSession(profile:)` use to pin a new chat to this profile.
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
/// launched), so it can't assume a logged-in session: it tries a fresh server fetch, then
/// falls back to the profiles the app cached on its last foreground load — so the picker is
/// still populated when the background fetch can't authenticate. Both paths degrade to an
/// empty list rather than throwing, which the system renders as an empty picker (#339).
struct ProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [ProfileEntity.ID]) async throws -> [ProfileEntity] {
        let wanted = Set(identifiers)
        return await ProfileEntityProvider.currentEntities().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        await ProfileEntityProvider.currentEntities()
    }
}

/// Resolves the current profile list for App Intents, live-first with a cached fallback.
/// Kept separate from the `EntityQuery` so the fetch/cache policy is reusable (e.g. by #8).
enum ProfileEntityProvider {
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
    /// Hermes servers' Profiles stay out of the list until #706. Nil when no webui server
    /// is configured.
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

    private static func savedServerURL() -> URL? {
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
