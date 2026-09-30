import Foundation

/// Every HTTP request Hermex sends to a direct Hermes host. A case builds its
/// method, path, query and JSON body against the connection's address.
/// `HermesConnection` sends them with its headers and cookie jar; only the connection
/// screen's status probe sends `.status` bare. Each operation reads its own reply status.
///
/// The push provisioning routes (#557) were verified against a 0.21.3 host on
/// 2026-09-19: install takes `{identifier, enable, force, ref}` and has no profile
/// parameter, enable and disable are path-only, and `PUT /api/env` and the gateway
/// restart take an optional `profile` Hermex leaves unset so every Profile inherits.
/// The plugins hub (#851) is read at the pin ca678285: `{plugins: [{name, version, …}]}`,
/// cached for 5 s and cleared by an install, so an update needs no rescan first.
enum HermesREST: Equatable, Sendable {
    /// Public, so it reads the host before any credential is sent.
    case status
    case login(username: String, password: String)
    case identity
    /// Mints the single-use ticket one gateway socket presents.
    case ticket
    /// `DELETE /api/profiles/{name}`, the only Profile removal the host exposes; the
    /// gateway has no `profiles.delete` RPC. `name` is a validated Profile slug.
    case deleteProfile(name: String)
    /// Stores image bytes under the Profile. The returned path travels in one prompt.
    case uploadImage(profile: String, filename: String, dataURL: String)
    /// One session-scoped file download. `path` is checked against the address.
    case downloadArtifact(path: String, profile: String, sessionID: String)
    /// Writes one managed environment value at the host root.
    case setEnvironment(key: String, value: String)
    /// Installs an agent plugin, reinstalling over an existing copy.
    case installPlugin(identifier: String)
    case setPlugin(name: String, enabled: Bool)
    case restartGateway
    case pushPairing
    /// Every agent plugin with its on-disk version.
    case pluginsHub

    func request(base: URL) throws -> URLRequest {
        switch self {
        case .status: return Self.get(base.appendingPathComponent("api/status"))
        case .login(let username, let password):
            return try Self.send("POST", base.appendingPathComponent("auth/password-login"), [
                "provider": .string("basic"), "username": .string(username), "password": .string(password)
            ])
        case .identity: return Self.get(base.appendingPathComponent("api/auth/me"))
        case .ticket: return try Self.send("POST", base.appendingPathComponent("api/auth/ws-ticket"), [:])
        case .deleteProfile(let name):
            var request = URLRequest(url: base.appendingPathComponent("api/profiles").appendingPathComponent(name))
            request.httpMethod = "DELETE"
            return request
        case .uploadImage(let profile, let filename, let dataURL):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/chat/image-upload"), resolvingAgainstBaseURL: false),
                  !profile.isEmpty else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "profile", value: profile)]
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return try Self.send("POST", url, ["filename": .string(filename), "data_url": .string(dataURL)])
        case .downloadArtifact(let path, let profile, let sessionID):
            guard !profile.isEmpty, !sessionID.isEmpty else { throw BotArtifactFailure.invalidReference }
            let path = try BotArtifactReference.path(path, address: base)
            var parts = URLComponents(url: base.appendingPathComponent("api/fs/download"), resolvingAgainstBaseURL: false)
            parts?.queryItems = [URLQueryItem(name: "path", value: path),
                                 URLQueryItem(name: "profile", value: profile),
                                 URLQueryItem(name: "session_id", value: sessionID)]
            guard let url = parts?.url else { throw BotArtifactFailure.invalidReference }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        case .setEnvironment(let key, let value):
            return try Self.send("PUT", base.appendingPathComponent("api/env"), ["key": .string(key), "value": .string(value)])
        case .installPlugin(let identifier):
            return try Self.send("POST", base.appendingPathComponent("api/dashboard/agent-plugins/install"), [
                "identifier": .string(identifier), "enable": .bool(true), "force": .bool(true)
            ])
        case .setPlugin(let name, let enabled):
            let url = base.appendingPathComponent("api/dashboard/agent-plugins").appendingPathComponent(name)
                .appendingPathComponent(enabled ? "enable" : "disable")
            return try Self.send("POST", url, [:])
        case .restartGateway: return try Self.send("POST", base.appendingPathComponent("api/gateway/restart"), [:])
        case .pushPairing: return Self.get(base.appendingPathComponent("api/plugins/hermex-push/pairing"))
        case .pluginsHub: return Self.get(base.appendingPathComponent("api/dashboard/plugins/hub"))
        }
    }

    /// The gateway socket's upgrade: the `ws`/`wss` URL matching the address's scheme,
    /// offering `hermes-gateway-v1` and the single-use ticket as subprotocols. A request's
    /// `Sec-WebSocket-Protocol` header is where `URLSessionWebSocketTask` takes them from.
    static func gatewayUpgrade(base: URL, ticket: String) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)
        else { throw BotFailure.unsupported }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        var request = URLRequest(url: url)
        request.setValue("hermes-gateway-v1, hermes-gateway-ticket." + ticket, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    private static func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }

    private static func send(_ method: String, _ url: URL, _ body: [String: BotJSON]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(BotJSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
