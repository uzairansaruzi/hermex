import Foundation

enum HermesPluginSource: Equatable, Sendable {
    case catalog(name: String, pin: String)
    case repo(String)
}

struct HermesPlugin: Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    let version: String
    let summary: String
    let origin: String
    let catalogName: String?
    let isBundled: Bool
    let isEnabled: Bool
    let hasUpdate: Bool
    let updateVersion: String?
    let settings: [HermesPluginSetting]

    var id: String { key }

    var category: String? {
        key.firstIndex(of: "/").map { String(key[..<$0]) }
    }

    var leaf: String {
        key.lastIndex(of: "/").map { String(key[key.index(after: $0)...]) } ?? key
    }

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
        hasUpdate = row["update_available"].flag == true && key != "hermex-push" && key != "hermex-screen"
        updateVersion = row["catalog_version"].text
        var keys = Set<String>()
        settings = (row["settings_schema"].list ?? []).compactMap(HermesPluginSetting.init)
            .filter { keys.insert($0.key).inserted }
    }
}

struct HermesPluginChange: Equatable, Sendable {
    let plugin: HermesPlugin?
    let isUnchanged: Bool
    let needsRestart: Bool
    let waitsForNextSession: Bool
    let failedServers: [String]

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

enum HermesPluginUpdate: Equatable, Sendable {
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
    case needsConsent(newAbilities: [String])
    case blockedByScan(canOverride: Bool, findings: [Finding])

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

struct HermesPluginSetting: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case string, number, boolean, json
        case choice([String])
        case secret(env: String, isSet: Bool)
    }

    enum Parsed: Equatable {
        case value(BotJSON)
        case unset
        case invalid(String)
    }

    let key: String
    let label: String
    let description: String
    let isRequired: Bool
    let kind: Kind
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

struct HermesPluginInstall: Equatable, Sendable {
    let name: String
    let isEnabled: Bool
    let change: HermesPluginChange
    let missingKeys: [String]

    init?(_ reply: BotJSON) {
        guard let name = reply["plugin_name"].text, !name.isEmpty else { return nil }
        self.name = name
        isEnabled = reply["enabled"].flag == true
        change = HermesPluginChange(reply, enabling: isEnabled)
        missingKeys = (reply["missing_env"].list ?? []).compactMap(\.text)
    }
}

struct HermesPluginStakes: Equatable, Sendable {
    var connectedPlatforms: [String: String]?
    var memoryProvider: String?

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
        guard let memoryProvider else {
            return plugin.isBundled ? nil : String(localized: "This may be the memory provider this Profile uses. New sessions can't reach what it stored until you turn it back on.")
        }
        return !memoryProvider.isEmpty && [plugin.name, plugin.key, plugin.leaf].contains(memoryProvider)
            ? String(localized: "This is the memory provider this Profile uses. New sessions can't reach what it stored until you turn it back on.")
            : nil
    }
}

@MainActor final class HermesPluginsClient {
    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    func profiles() async throws -> (names: [String], initial: String) {
        try await HermesEnvironmentClient(http: http).profiles()
    }

    func plugins(profile: String) async throws -> [HermesPlugin] {
        (try await gateway(.pluginsList(profile: profile))["plugins"].list ?? []).compactMap(HermesPlugin.init)
    }

    func setPlugin(key: String, enabled: Bool, profile: String) async throws -> HermesPluginChange {
        HermesPluginChange(try await gateway(.pluginsToggle(profile: profile, key: key, enable: enabled)), enabling: enabled)
    }

    var hostVersion: String? { http.serverVersion }

    func catalog() async throws -> HermesPluginCatalog {
        let body = try HermesCronClient.accepted(try await http.reply(.pluginCatalog))
        return try await Task.detached(priority: .userInitiated) { try HermesPluginCatalog(body) }.value
    }

    func install(_ source: HermesPluginSource, profile: String, replace: Bool, enable: Bool) async throws -> HermesPluginInstall {
        guard let install = HermesPluginInstall(try await gateway(.pluginsInstall(profile: profile, source: source, replace: replace, enable: enable)))
        else { throw BotFailure.unsupported }
        return install
    }

    func remove(key: String, profile: String) async throws -> Bool {
        try await gateway(.pluginsRemove(profile: profile, key: key))["cleared_memory_provider"].flag == true
    }

    func update(key: String, profile: String, acceptCapabilities: Bool, acceptCaution: Bool) async throws -> HermesPluginUpdate {
        let reply = try await gateway(.pluginsUpdate(profile: profile, key: key, acceptCapabilities: acceptCapabilities, acceptCaution: acceptCaution))
        guard let update = HermesPluginUpdate(reply) else { throw BotFailure.unsupported }
        return update
    }

    func saveSettings(key: String, values: [String: BotJSON], profile: String) async throws -> HermesPlugin? {
        HermesPlugin(try await gateway(.pluginsSettings(profile: profile, key: key, values: values))["plugin"])
    }

    func removeKey(_ name: String, profile: String) async throws {
        try await HermesEnvironmentClient(http: http).remove(name, profile: profile)
    }

    func saveKey(_ name: String, value: String, profile: String) async throws {
        try await HermesEnvironmentClient(http: http).set(name, value: value, profile: profile)
    }

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
