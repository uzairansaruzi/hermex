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
    /// The version a catalog install would update to, when the host knows it.
    let updateVersion: String?
    /// The manifest's settings form, empty for most plugins.
    let settings: [HermesPluginSetting]

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
        // This build pins hermex-push and hermex-screen, and their own pages update them or the app
        // does, so they never offer an Update here.
        hasUpdate = row["update_available"].flag == true && key != "hermex-push" && key != "hermex-screen"
        updateVersion = row["catalog_version"].text
        // A repeated key keeps its first entry: the settings form holds one draft per key.
        var keys = Set<String>()
        settings = (row["settings_schema"].list ?? []).compactMap(HermesPluginSetting.init)
            .filter { keys.insert($0.key).inserted }
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

/// What an update came back with (#1582). The last two changed nothing, and wait for the user.
enum HermesPluginUpdate: Equatable, Sendable {
    /// One thing a security scan found, with the file and line it found it on.
    struct Finding: Equatable, Sendable, Identifiable {
        let id = UUID()
        let severity: String
        let description: String
        let location: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            (lhs.severity, lhs.description, lhs.location) == (rhs.severity, rhs.description, rhs.location)
        }
    }

    case finished(HermesPluginChange)
    /// A re-pin that gives the plugin new abilities, in the host's own lines.
    case needsConsent(newAbilities: [String])
    /// `canOverride` only for a caution verdict. A dangerous one, or any the app doesn't know, can't be.
    case blockedByScan(canOverride: Bool, findings: [Finding])

    /// A reply with none of these is a host this client doesn't understand, so it's nil.
    init?(_ reply: BotJSON) {
        if reply["consent_required"].flag == true {
            self = .needsConsent(newAbilities: (reply["delta_lines"].list ?? []).compactMap(\.text))
        } else if reply["scan_blocked"].flag == true {
            self = .blockedByScan(canOverride: reply["scan_verdict"].text == "caution", findings: (reply["scan_findings"].list ?? []).map { finding in
                let line = finding["line"].integer.map { ":\($0)" } ?? ""
                return Finding(severity: finding["severity"].text ?? "", description: finding["description"].text ?? "",
                               location: (finding["file"].text ?? "") + line)
            })
        } else if reply["ok"].flag == true {
            self = .finished(HermesPluginChange(reply, enabling: true))
        } else {
            return nil
        }
    }
}

/// One field of a plugin's settings form (#1582). A field of a type this build doesn't know isn't
/// shown, so it's never sent. A secret never carries its value, only whether it's set.
struct HermesPluginSetting: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case string, number, boolean, json
        case choice([String])
        case secret(env: String, isSet: Bool)
    }

    /// What a field's text comes to.
    enum Parsed: Equatable {
        case value(BotJSON)
        /// Empty, on a field with no value to clear.
        case unset
        case invalid(String)
    }

    let key: String
    let label: String
    let description: String
    let isRequired: Bool
    let kind: Kind
    /// The saved value, or else the manifest's default. Null when it has neither.
    let value: BotJSON

    var id: String { key }

    init?(_ row: BotJSON) {
        guard let key = row["key"].text, !key.isEmpty else { return nil }
        switch row["type"].text {
        case "string": kind = .string
        case "number": kind = .number
        case "boolean": kind = .boolean
        case "json": kind = .json
        case "enum": kind = .choice((row["choices"].list ?? []).compactMap(\.text))
        case "secret":
            guard let env = row["env"].text, !env.isEmpty else { return nil }
            kind = .secret(env: env, isSet: row["has_value"].flag == true)
        default: return nil
        }
        self.key = key
        label = row["label"].text ?? key
        description = row["description"].text ?? ""
        isRequired = row["required"].flag == true
        value = row["value"]
    }

    /// The text a form starts from.
    var text: String {
        switch (kind, value) {
        case (_, .null): return ""
        case (_, .string(let text)): return text
        case (_, .bool(let flag)): return flag ? "true" : "false"
        case (_, .number(let number)):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    /// What `text` means for this field. A list or object is the only JSON the host accepts here.
    func parse(_ text: String) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .string: return value == .null && text.isEmpty ? .unset : .value(.string(text))
        case .choice: return trimmed.isEmpty ? .unset : .value(.string(trimmed))
        case .boolean: return trimmed.isEmpty ? .unset : .value(.bool(trimmed == "true"))
        case .number:
            if trimmed.isEmpty { return value == .null ? .unset : .invalid(String(localized: "Enter a number.")) }
            guard let number = Double(trimmed), number.isFinite else { return .invalid(String(localized: "Enter a number.")) }
            return .value(.number(number))
        case .json:
            if trimmed.isEmpty { return value == .null ? .unset : .invalid(String(localized: "Enter a JSON list or object.")) }
            guard let parsed = try? JSONDecoder().decode(BotJSON.self, from: Data(trimmed.utf8)) else {
                return .invalid(String(localized: "Enter a JSON list or object."))
            }
            switch parsed {
            case .array, .object: return .value(parsed)
            default: return .invalid(String(localized: "Enter a JSON list or object."))
            }
        case .secret: return .unset
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

    /// Updates a user install on `profile`. The two accepts are the user's answers to an earlier reply.
    func update(key: String, profile: String, acceptCapabilities: Bool, acceptCaution: Bool) async throws -> HermesPluginUpdate {
        let reply = try await gateway(.pluginsUpdate(profile: profile, key: key, acceptCapabilities: acceptCapabilities, acceptCaution: acceptCaution))
        guard let update = HermesPluginUpdate(reply) else { throw BotFailure.unsupported }
        return update
    }

    /// Writes settings for `key` on `profile`, and answers with the row the host read back.
    func saveSettings(key: String, values: [String: BotJSON], profile: String) async throws -> HermesPlugin? {
        HermesPlugin(try await gateway(.pluginsSettings(profile: profile, key: key, values: values))["plugin"])
    }

    /// Takes one key off `profile`'s `.env`.
    func removeKey(_ name: String, profile: String) async throws {
        try await HermesEnvironmentClient(http: http).remove(name, profile: profile)
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
