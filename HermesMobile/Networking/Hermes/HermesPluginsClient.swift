import Foundation

/// What an install fetches: a catalog entry, which the host resolves itself, at the commit the review
/// showed, or a repository at its latest commit. A catalog name is never turned into a repository,
/// so its removal list always applies (#1582).
enum HermesPluginSource: Equatable, Sendable {
    case catalog(name: String, pin: String)
    case repo(String)
}

/// One row of `plugins.manage list` on a Hermes host (#1582). `key` is its identity: names collide
/// across category folders (`image_gen/fal`, `video_gen/fal`). `install_dir`, a host path, is never
/// decoded.
struct HermesPlugin: Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    let version: String
    let summary: String
    /// The catalog tier a catalog install came from, or else where it came from: `bundled`, `user`, `git`.
    let origin: String
    /// The catalog entry a catalog install came from.
    let catalogName: String?
    /// False for anything the user installed, which the host's `source` marks as other than bundled.
    let isBundled: Bool
    let isEnabled: Bool
    let hasUpdate: Bool

    var id: String { key }

    /// The category folder in `key`, which tells two rows with the same name apart.
    var category: String? {
        key.firstIndex(of: "/").map { String(key[..<$0]) }
    }

    /// `key` without its category folder.
    var leaf: String {
        key.lastIndex(of: "/").map { String(key[key.index(after: $0)...]) } ?? key
    }

    /// A row with neither a key nor a name can't be addressed, so it isn't listed. The host's other
    /// statuses, `disabled` and `not enabled`, both read as off.
    init?(_ row: BotJSON) {
        guard let key = row["key"].text ?? row["name"].text, !key.isEmpty else { return nil }
        self.key = key
        name = row["name"].text ?? key
        version = row["version"].text ?? ""
        summary = (row["description"].text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let source = row["source"].text ?? ""
        origin = row["catalog_tier"].text ?? source
        catalogName = row["catalog_name"].text
        isBundled = source == "bundled"
        isEnabled = row["status"].text == "enabled"
        hasUpdate = row["update_available"].flag == true
    }
}

/// What the host reported after a toggle (#1582), which is all the screen says about it.
struct HermesPluginChange: Equatable, Sendable {
    /// The row the host read back, when it could.
    let plugin: HermesPlugin?
    let isUnchanged: Bool
    let needsRestart: Bool
    /// Parts of a plugin turned on that wait for the next session, such as its tools.
    let waitsForNextSession: Bool
    /// MCP servers of a plugin turned on that didn't connect.
    let failedServers: [String]

    /// `activation` can be an earlier load's summary after turning a plugin off, so only an enable reads it.
    init(_ reply: BotJSON, enabling: Bool) {
        plugin = HermesPlugin(reply["plugin"])
        isUnchanged = reply["unchanged"].flag == true
        needsRestart = reply["restart_required"].flag == true
        let activation = enabling ? reply["activation"] : .null
        waitsForNextSession = !(activation["deferred"].fields ?? [:]).isEmpty
        failedServers = (activation["live_now"]["mcp_servers"].list ?? []).compactMap { server in
            server["connected"].flag == true ? nil : server["name"].text
        }
    }
}

/// What the host reported after an install (#1582).
struct HermesPluginInstall: Equatable, Sendable {
    /// The installed plugin's name, which is also its key in the list.
    let name: String
    let isEnabled: Bool
    let change: HermesPluginChange
    /// The variables its manifest requires and the Profile hasn't set.
    let missingKeys: [String]

    init?(_ reply: BotJSON) {
        guard let name = reply["plugin_name"].text, !name.isEmpty else { return nil }
        self.name = name
        isEnabled = reply["enabled"].flag == true
        change = HermesPluginChange(reply, enabling: isEnabled)
        missingKeys = (reply["missing_env"].list ?? []).compactMap(\.text)
    }
}

/// What one Profile relies on, for deciding which toggles to confirm (#1582). A nil field couldn't
/// be read, and every plugin it might cover is then treated as relied on.
struct HermesPluginStakes: Equatable, Sendable {
    /// The platforms set up on the Profile, id to display name.
    var connectedPlatforms: [String: String]?
    /// The Profile's memory provider, empty for the built-in one.
    var memoryProvider: String?

    /// The plain-language warning a toggle needs first, or nil to apply it at once. Plugins Hermex
    /// or sign-in relies on are never hidden or blocked: upstream's own comment says disabling
    /// `basic` makes password auth silently fail.
    func warning(for plugin: HermesPlugin, turningOn: Bool) -> String? {
        if plugin.category == "dashboard_auth" {
            if plugin.key == "dashboard_auth/basic", !turningOn {
                return String(localized: "This is the password sign-in for this server. Hermex signs in with it, so turning it off can lock this iPhone out until you fix it on the host.")
            }
            return String(localized: "This changes how people sign in to this server. It can lock this iPhone out until you fix it on the host.")
        }
        if plugin.key == "hermex-screen" {
            return turningOn
                ? String(localized: "Anyone with this server's login could then see and control everything on this computer.")
                : String(localized: "Bot Screen stops working on this Profile until you turn this back on.")
        }
        guard !turningOn else { return nil }
        if plugin.key == "hermex-push" {
            return String(localized: "Hermex notifications from this Profile stop until you turn this back on.")
        }
        if plugin.category == "platforms" {
            guard let connectedPlatforms else {
                return String(localized: "This messaging platform may be connected. Turning it off disconnects Hermes from it after a restart.")
            }
            return connectedPlatforms[plugin.leaf].map {
                String(localized: "\($0) is connected on this Profile. Turning this off disconnects Hermes from it after a restart.")
            }
        }
        // The host doesn't list bundled memory providers, so only a user install can be the active one.
        guard let memoryProvider else {
            return plugin.isBundled ? nil : String(localized: "This may be the memory provider this Profile uses. New sessions can't reach what it stored until you turn it back on.")
        }
        return !memoryProvider.isEmpty && [plugin.name, plugin.key, plugin.leaf].contains(memoryProvider)
            ? String(localized: "This is the memory provider this Profile uses. New sessions can't reach what it stored until you turn it back on.")
            : nil
    }
}

/// The Plugins screen's client on a Hermes host (#1582). Management goes over `plugins.manage`,
/// because only it can name a Profile: the REST mutations act on the Profile the dashboard runs as.
/// Every request names the Profile, and nothing is cached, so a row never shows under another
/// server or Profile.
@MainActor final class HermesPluginsClient {
    private let http: HermesConnection

    /// `server`'s saved connection, on the sign-in and socket its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    /// The host's Profiles and the one to start on, its default.
    func profiles() async throws -> (names: [String], initial: String) {
        try await HermesEnvironmentClient(http: http).profiles()
    }

    /// Every plugin on `profile`, in the host's order.
    func plugins(profile: String) async throws -> [HermesPlugin] {
        (try await gateway(.pluginsList(profile: profile))["plugins"].list ?? []).compactMap(HermesPlugin.init)
    }

    func setPlugin(key: String, enabled: Bool, profile: String) async throws -> HermesPluginChange {
        HermesPluginChange(try await gateway(.pluginsToggle(profile: profile, key: key, enable: enabled)), enabling: enabled)
    }

    /// The release the host reported at sign-in.
    var hostVersion: String? { http.serverVersion }

    /// The host's plugin catalog, decoded off the main thread because it runs to megabytes.
    func catalog() async throws -> HermesPluginCatalog {
        let body = try HermesCronClient.accepted(try await http.reply(.pluginCatalog))
        return try await Task.detached(priority: .userInitiated) { try HermesPluginCatalog(body) }.value
    }

    /// Installs on `profile`. A reply with no plugin name is a host this client doesn't understand,
    /// so the outcome is unknown and it throws as a lost reply would.
    func install(_ source: HermesPluginSource, profile: String, replace: Bool, enable: Bool) async throws -> HermesPluginInstall {
        guard let install = HermesPluginInstall(try await gateway(.pluginsInstall(profile: profile, source: source, replace: replace, enable: enable)))
        else { throw BotFailure.unsupported }
        return install
    }

    /// Removes a user install from `profile`. True when its memory provider went with it, which puts
    /// the Profile back on the built-in one.
    func remove(key: String, profile: String) async throws -> Bool {
        try await gateway(.pluginsRemove(profile: profile, key: key))["cleared_memory_provider"].flag == true
    }

    /// Writes one required key to `profile`'s `.env`. The value goes out once and isn't read back.
    func saveKey(_ name: String, value: String, profile: String) async throws {
        try await HermesEnvironmentClient(http: http).set(name, value: value, profile: profile)
    }

    /// What `profile` relies on. A route the host refuses leaves its field unknown.
    func stakes(profile: String) async -> HermesPluginStakes {
        async let platforms = optionalRead(.messagingPlatforms(profile: profile))
        async let memory = optionalRead(.memoryStatus(profile: profile))
        let (platformsReply, memoryReply) = await (platforms, memory)
        return HermesPluginStakes(
            connectedPlatforms: platformsReply?["platforms"].list.map { rows in
                Dictionary(rows.compactMap { row -> (String, String)? in
                    guard let id = row["id"].text, row["enabled"].flag == true, row["configured"].flag == true else { return nil }
                    return (id, row["name"].text ?? id)
                }, uniquingKeysWith: { first, _ in first })
            },
            memoryProvider: memoryReply?["active"].text
        )
    }

    /// Asks the host to restart the gateway serving `profile`, interrupting its running work and,
    /// when the host runs one gateway for all its Profiles, theirs too. It answers once the restart
    /// has started, not once it has finished.
    func restartGateway(profile: String) async throws {
        _ = try HermesCronClient.accepted(try await http.reply(.restartGateway(profile: profile), deadline: .provisioning))
    }

    private func gateway(_ call: HermesCall) async throws -> BotJSON {
        let client = BotClient(http: http)
        defer { client.close() }
        try await client.connect()
        return try await client.call(call)
    }

    private func optionalRead(_ rest: HermesREST) async -> BotJSON? {
        guard let reply = try? await http.reply(rest), (200..<300).contains(reply.status) else { return nil }
        return try? JSONDecoder().decode(BotJSON.self, from: reply.body)
    }
}
