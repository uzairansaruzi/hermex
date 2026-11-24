import Foundation

@MainActor final class BotDashboardClient {
    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    var servesWebapp: Bool { http.servesWebapp }

    func signIn() async throws {
        try await http.signIn(deadline: .provisioning)
    }

    func setEnvironmentValue(_ key: String, _ value: String) async throws {
        _ = try await send(.setEnvironment(key: key, value: value, profile: nil))
    }

    func installPlugin(identifier: String, ref: String? = nil) async throws {
        _ = try await send(.installPlugin(identifier: identifier, ref: ref))
    }

    func removePlugin(_ name: String) async throws {
        _ = try await send(.removePlugin(name: name))
    }

    func setPlugin(_ name: String, enabled: Bool,
                   validateDispatch: (@MainActor () throws -> Void)? = nil) async throws {
        _ = try await send(.setPlugin(name: name, enabled: enabled), validateDispatch: validateDispatch)
    }

    func restartGateway() async throws {
        _ = try await send(.restartGateway())
    }

    func restartHermes() async throws {
        _ = try await send(.restartDashboard, validateDispatch: { [http] in
            if http.servesWebapp { throw BotFailure.stale }
        })
    }

    func answersStatus() async -> Bool {
        await http.answersStatus()
    }

    func pairing() async throws -> PushPairing {
        try HermexPushPlugin.pairing(try await readPluginRoute(.pushPairing))
    }

    func loadedPluginVersion() async throws -> HermexPushPluginVersion? {
        HermexPushPlugin.loadedVersion(try await readPluginRoute(.pushPairing))
    }

    func companionRoutes() async throws -> HermexCompanionRoutes {
        let (data, status) = try await http.reply(.pluginCapabilities)
        if status == 404 { return .closed }
        guard (200..<300).contains(status) else { throw BotFailure.rejected(status) }
        return HermexCompanionRoutes((try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null)
    }

    func hasPluginOnDisk() async throws -> Bool? {
        HermexPushPlugin.isOnDisk(hub: try await send(.pluginsHub))
    }

    func installedPluginVersion() async throws -> HermexPushPluginVersion? {
        HermexPushPlugin.installedVersion(hub: try await send(.pluginsHub))
    }

    func hostListing() async throws -> HermexPushHostListing? {
        let client = BotClient(http: http)
        defer { client.close() }
        try await client.connect()
        return HermexPushPlugin.hostListing(try await client.call(.pluginsList(profile: nil)))
    }

    private func readPluginRoute(_ rest: HermesREST) async throws -> BotJSON {
        let (data, status) = try await http.reply(rest, deadline: .provisioning)
        let body = (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
        guard (200..<300).contains(status) else {
            if status == 404, let missing = HermexPushPlugin.missingRoute(body) { throw missing }
            throw BotFailure.rejected(status)
        }
        return body
    }

    private func send(_ rest: HermesREST,
                      validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> BotJSON {
        let data = try await http.data(rest, deadline: .provisioning, accepting: 200..<300,
                                       validateDispatch: validateDispatch)
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}
