import Foundation

/// Direct Hermes payloads deliberately stay separate from webui endpoint models.
/// Accessors tolerate absent and future fields; required capabilities are checked at use.
indirect enum BotJSON: Codable, Hashable, Sendable {
    case object([String: BotJSON]), array([BotJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([BotJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: BotJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> BotJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String? { if case .string(let v) = self { return v }; return nil }
    var list: [BotJSON]? { if case .array(let v) = self { return v }; return nil }
    var fields: [String: BotJSON]? { if case .object(let v) = self { return v }; return nil }
    var flag: Bool? { if case .bool(let v) = self { return v }; return nil }
    var integer: Int? { if case .number(let v) = self { return Int(exactly: v) }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
}

enum BotFailure: Error, Equatable, LocalizedError {
    case stale, unsupported, missingChat, wrongIdentity, differentHost, rejected(Int), transport, invalidAddress
    var errorDescription: String? {
        switch self {
        case .stale: return String(localized: "This action is no longer current. Refresh the conversation.")
        case .unsupported: return String(localized: "This Hermes connection does not support Bot chat here.")
        case .missingChat: return String(localized: "Open this bot’s chat in Hermes Desktop, then refresh.")
        case .wrongIdentity: return String(localized: "The conversation identity changed. Check this bot in Desktop.")
        case .differentHost: return String(localized: "The Hermes host at this address reports a different identity than the one you connected to. Check the address in the Hermes connection.")
        case .rejected(401), .rejected(403): return String(localized: "Sign in again. Check your Bot connection username and password.")
        case .rejected(-32601): return String(localized: "This Hermes connection does not support Bot chat here.")
        case .rejected(4090): return String(localized: "Another Hermes process owns this conversation. Resolve it on the host, then refresh.")
        case .rejected(4130): return String(localized: "This conversation is too large to open here. Use Desktop.")
        case .invalidAddress: return String(localized: "Enter a Hermes HTTP or HTTPS address without a path, credentials or query.")
        default: return String(localized: "Connection lost. The bot may still be working. Reconnect to check its current conversation.")
        }
    }
}

enum BotEndpoint: String {
    case status = "api/status", login = "auth/password-login", identity = "api/auth/me"
    case ticket = "api/auth/ws-ticket", socket = "api/ws"
    case imageUpload = "api/chat/image-upload"
    /// Dashboard routes push provisioning uses (#557), verified against a 0.21.3 host on
    /// 2026-09-19: install takes `{identifier, enable, force, ref}` and has no profile
    /// parameter, enable and disable are path-only, and `PUT /api/env` and the gateway
    /// restart take an optional `profile` Hermex leaves unset so every profile inherits.
    case environment = "api/env"
    case pluginInstall = "api/dashboard/agent-plugins/install"
    case gatewayRestart = "api/gateway/restart"
    case pushPairing = "api/plugins/hermex-push/pairing"
    func url(base: URL) -> URL { base.appendingPathComponent(rawValue) }
    /// `POST /api/dashboard/agent-plugins/{name}/{action}` for `enable` and `disable`.
    static func pluginURL(base: URL, name: String, action: String) -> URL {
        base.appendingPathComponent("api/dashboard/agent-plugins")
            .appendingPathComponent(name).appendingPathComponent(action)
    }
    /// `DELETE /api/profiles/{name}`, the only Profile removal the host exposes; the
    /// gateway has no `profiles.delete` RPC. `name` is a validated Profile slug.
    static func profileURL(base: URL, name: String) -> URL {
        base.appendingPathComponent("api/profiles").appendingPathComponent(name)
    }
}

@MainActor protocol BotTransport: AnyObject {
    var replayEpoch: String? { get }
    var serverVersion: String? { get }
    /// `install_id` from `/api/status` at the last connect; nil when the host omits it.
    var serverInstallID: String? { get }
    /// Sequenced event params or a complete string-id server-request envelope.
    var onEvent: ((BotJSON) -> Void)? { get set }
    var onDisconnect: ((Error) -> Void)? { get set }
    func connect() async throws
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String
    func artifactData(path: String, context: BotArtifactContext) async throws -> Data
    /// Removes a Profile on the host over the authenticated HTTP session. Only
    /// a 200 with `ok` counts as deleted; anything else leaves the bot in place.
    func deleteProfile(_ name: String) async throws
    func close()
}

extension BotTransport {
    var serverVersion: String? { nil }
    var serverInstallID: String? { nil }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        throw BotFailure.unsupported
    }

    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        throw BotArtifactFailure.unavailable
    }

    func deleteProfile(_ name: String) async throws {
        throw BotFailure.unsupported
    }

    func call(_ method: String, _ params: [String: BotJSON]) async throws -> BotJSON {
        try await call(method, params, validateDispatch: nil)
    }
}
