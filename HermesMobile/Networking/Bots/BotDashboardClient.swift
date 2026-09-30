import Foundation

/// The Hermes host's dashboard REST surface, kept apart from `BotClient` because push
/// provisioning needs no gateway socket: it mutates the host's plugins and environment
/// and reads the pairing keys, over the sign-in and cookie jar the server's Bot screens
/// share. Its writes change the user's server, so only confirmed actions (Enable, Disable,
/// the plugin update) make them; the plugin version reads alone run on their own.
@MainActor final class BotDashboardClient {
    private let http: HermesConnection

    /// Provisioning for `server`'s saved connection, on the sign-in its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    /// Signs in through the host's password gate unless the connection already is, with
    /// the provisioning deadline. The install identity is checked before the password
    /// goes out, so a swapped host is refused before anything on it changes.
    func signIn() async throws {
        try await http.signIn(deadline: .provisioning)
    }

    /// Writes one managed environment value at the host root. No `profile` is sent: a
    /// profile without its own value inherits the root one, which is what pairing needs.
    func setEnvironmentValue(_ key: String, _ value: String) async throws {
        _ = try await send(.setEnvironment(key: key, value: value))
    }

    /// Installs an agent plugin from its identifier, reinstalling over an existing copy.
    /// `force` is true because an install that refuses to overwrite would make the second
    /// run — re-enabling after a disable, or repairing a plugin too old for this build —
    /// fail with nothing the user can do from the phone. Reinstalling cannot unpair a
    /// device: `hermex-push` keeps its key pair in `plugin-data`, outside the install
    /// directory.
    func installPlugin(identifier: String) async throws {
        _ = try await send(.installPlugin(identifier: identifier))
    }

    /// Enables or disables an installed agent plugin. Disabling is deliberately never
    /// `DELETE`: the plugin directory is also where the host's key pair used to live.
    func setPlugin(_ name: String, enabled: Bool) async throws {
        _ = try await send(.setPlugin(name: name, enabled: enabled))
    }

    /// Restarts the agent gateway so a newly installed plugin is loaded. This interrupts
    /// the user's running work, so only a confirmed Enable or plugin update reaches it.
    func restartGateway() async throws {
        _ = try await send(.restartGateway)
    }

    /// Reads the plugin's pairing keys. The route answers 409 until the relay URL is set
    /// and 404 until the restart has mounted it, so the caller retries both.
    func pairing() async throws -> PushPairing {
        try HermexPushPlugin.pairing(try await send(.pushPairing))
    }

    /// The hermex-push version the dashboard process has loaded, from the pairing route;
    /// nil for a plugin too old to say. Keys are not decoded, so an old plugin's still read.
    func loadedPluginVersion() async throws -> HermexPushPluginVersion? {
        HermexPushPlugin.loadedVersion(try await send(.pushPairing))
    }

    /// The hermex-push version on the host's disk, from the plugins hub.
    func installedPluginVersion() async throws -> HermexPushPluginVersion? {
        HermexPushPlugin.installedVersion(hub: try await send(.pluginsHub))
    }

    /// Any non-2xx is the step's failure, carrying the status so the pairing route's 404
    /// and 409 can be retried while the host comes back up. Each step gets the
    /// provisioning deadline.
    private func send(_ rest: HermesREST) async throws -> BotJSON {
        let data = try await http.data(rest, deadline: .provisioning, accepting: 200..<300)
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}
