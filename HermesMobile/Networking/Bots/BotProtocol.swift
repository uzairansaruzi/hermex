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
    /// `notDashboard`: the address answered `/api/status` with 401, 404 or a body that
    /// is not JSON, so it is not a Hermes dashboard (often the webui address). Permanent.
    case stale, unsupported, missingChat, wrongIdentity, differentHost, rejected(Int), transport, invalidAddress, notDashboard
    var errorDescription: String? {
        switch self {
        case .stale: return String(localized: "This action is no longer current. Refresh the conversation.")
        // `BotConnectionAdvice` names the host for `.notDashboard`; this is the hostless fallback.
        case .unsupported, .notDashboard: return String(localized: "This Hermes connection does not support Bot chat here.")
        case .missingChat: return String(localized: "Open this bot’s chat in Hermes Desktop, then refresh.")
        case .wrongIdentity: return String(localized: "The conversation identity changed. Check this bot in Desktop.")
        case .differentHost: return String(localized: "The Hermes host at this address reports a different identity than the one you connected to. Check the address in the Hermes connection.")
        case .rejected(401): return String(localized: "Sign in again. Check your Bot connection username and password.")
        // Hermes never answers 403 or 520-530 itself. 502-504 usually come from a proxy; Hermes's
        // own 503 (its auth provider is unreachable) shares the approved proxy copy.
        case .rejected(403): return String(localized: "Something in front of Hermes, such as Cloudflare Access, blocked the request.")
        case .rejected(502...504): return String(localized: "Your proxy answered, but Hermes didn't. Check that the dashboard is running on the host.")
        case .rejected(520...530): return String(localized: "Cloudflare can't reach your tunnel. Check that cloudflared and the dashboard are running on the host.")
        case .rejected(-32601): return String(localized: "This Hermes connection does not support Bot chat here.")
        case .rejected(4090): return String(localized: "Another Hermes process owns this conversation. Resolve it on the host, then refresh.")
        case .rejected(4130): return String(localized: "This conversation is too large to open here. Use Desktop.")
        case .invalidAddress: return String(localized: "Enter a Hermes HTTP or HTTPS address without a path, credentials or query.")
        default: return String(localized: "Connection lost. The bot may still be working. Reconnect to check its current conversation.")
        }
    }
}

/// What to check when a Bot connection fails, for the connection form, the inbox and a
/// chat. Names only the host of the connection's own address, never a credential.
/// `URLError`s pass through `BotClient` unwrapped on purpose: reconnect logic reads any
/// non-`BotFailure` error as transport, so only the copy maps them.
enum BotConnectionAdvice {
    static func message(for error: Error, address: URL) -> String {
        let host = address.host ?? address.absoluteString
        if let error = error as? URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                return String(localized: "Couldn't find \(host). Check the address. For a Tailscale or VPN name, make sure this iPhone is connected to it.")
            case .cannotConnectToHost:
                return String(localized: "\(host) refused the connection. Check the port and that the Hermes dashboard is running.")
            case .timedOut:
                return String(localized: "\(host) didn't answer. Check that this iPhone can reach it on this network, or use your tunnel address.")
            case .notConnectedToInternet, .dataNotAllowed:
                return String(localized: "This iPhone is offline.")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return String(localized: "Couldn't make a secure connection to \(host). Check its certificate. A dashboard on your local network without HTTPS needs http://.")
            case .appTransportSecurityRequiresSecureConnection:
                return String(localized: "iOS blocked this insecure HTTP connection. Use HTTPS, a local network address, or a Tailscale name or IP.")
            default:
                return String(localized: "Couldn't reach \(host). Check the address and network.")
            }
        }
        switch error as? BotFailure {
        case .rejected(400)?:
            // Host-header refusal: the dashboard trusts only its bound host and `dashboard.public_url`.
            return String(localized: "Hermes doesn't accept \(host) as its address. On the host, set dashboard.public_url to \(address.absoluteString), then restart the dashboard.")
        case .rejected(429)?:
            return String(localized: "Too many sign-in attempts. Wait a minute, then try again.")
        case .notDashboard?:
            return String(localized: "\(host) isn't a Hermes dashboard. Use the dashboard address, not the Hermes Web UI.")
        case let failure?:
            return failure.localizedDescription
        case nil:
            return String(localized: "Couldn't reach \(host). Check the address and network.")
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
