import Foundation

/// The Hermes host's dashboard REST surface, kept apart from `BotClient` because push
/// provisioning needs no gateway socket: it signs in over HTTP with the saved Bot
/// connection, mutates the host's plugins and environment, and reads the pairing keys.
/// Every call here changes the user's server, so only the explicit Enable and Disable
/// actions build one.
@MainActor final class BotDashboardClient {
    private let connection: BotConnection
    private let session: URLSession
    private var isSignedIn = false

    init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    /// Signs this HTTP session in through the host's password gate. Later calls reuse the
    /// cookie the first sign-in stored, so a sequence of steps logs in once.
    func signIn() async throws {
        guard !isSignedIn else { return }
        let status = try await send(request(BotEndpoint.status.url(base: connection.address)))
        guard status["auth_required"].flag == true,
              status["auth_providers"].list?.contains(.string("basic")) == true else { throw BotFailure.unsupported }
        _ = try await send(request(BotEndpoint.login.url(base: connection.address), method: "POST", body: .object([
            "provider": .string("basic"), "username": .string(connection.username),
            "password": .string(connection.password)
        ])))
        let identity = try await send(request(BotEndpoint.identity.url(base: connection.address)))
        guard identity["provider"].text == "basic" else { throw BotFailure.wrongIdentity }
        isSignedIn = true
    }

    /// Writes one managed environment value at the host root. No `profile` is sent: a
    /// profile without its own value inherits the root one, which is what pairing needs.
    func setEnvironmentValue(_ key: String, _ value: String) async throws {
        _ = try await send(request(BotEndpoint.environment.url(base: connection.address), method: "PUT",
                                   body: .object(["key": .string(key), "value": .string(value)])))
    }

    /// Installs an agent plugin from its identifier, reinstalling over an existing copy.
    /// `force` is true because an install that refuses to overwrite would make the second
    /// run — re-enabling after a disable, or repairing a plugin too old for this build —
    /// fail with nothing the user can do from the phone. Reinstalling cannot unpair a
    /// device: `hermex-push` keeps its key pair in `plugin-data`, outside the install
    /// directory.
    func installPlugin(identifier: String) async throws {
        _ = try await send(request(BotEndpoint.pluginInstall.url(base: connection.address), method: "POST",
                                   body: .object(["identifier": .string(identifier), "enable": .bool(true), "force": .bool(true)])))
    }

    /// Enables or disables an installed agent plugin. Disabling is deliberately never
    /// `DELETE`: the plugin directory is also where the host's key pair used to live.
    func setPlugin(_ name: String, enabled: Bool) async throws {
        let url = BotEndpoint.pluginURL(base: connection.address, name: name, action: enabled ? "enable" : "disable")
        _ = try await send(request(url, method: "POST", body: .object([:])))
    }

    /// Restarts the agent gateway so a newly installed plugin is loaded. This interrupts
    /// the user's running work, so only a confirmed Enable reaches it.
    func restartGateway() async throws {
        _ = try await send(request(BotEndpoint.gatewayRestart.url(base: connection.address), method: "POST", body: .object([:])))
    }

    /// Reads the plugin's pairing keys. The route answers 409 until the relay URL is set
    /// and 404 until the restart has mounted it, so the caller retries both.
    func pairing() async throws -> HermexPushPairing {
        try HermexPushPairing(try await send(request(BotEndpoint.pushPairing.url(base: connection.address))))
    }

    private func request(_ url: URL, method: String = "GET", body: BotJSON? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try? JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Any non-2xx is the step's failure, carrying the status so the pairing route's 404
    /// and 409 can be retried while the host comes back up.
    private func send(_ request: URLRequest) async throws -> BotJSON {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BotFailure.transport }
        guard (200..<300).contains(response.statusCode) else { throw BotFailure.rejected(response.statusCode) }
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}
