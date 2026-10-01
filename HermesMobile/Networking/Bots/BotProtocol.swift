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
    /// `notDashboard`: the address answered `/api/status` with 404, a JSON 401 (the webui's
    /// auth gate) or a body that is not JSON, so it is not a Hermes dashboard (often the
    /// webui address). Permanent.
    case stale, unsupported, missingChat, wrongIdentity, differentHost, rejected(Int), transport, invalidAddress, notDashboard
    /// Something in front of Hermes wants its own sign-in: a request ended on another host
    /// (an access proxy's login page), or `/api/status` answered a 401 whose body is not a
    /// JSON object. Permanent.
    case blocked
    /// The host requires sign-in but offers no `basic` provider, only a browser (OIDC)
    /// one Hermex can't use yet. Permanent.
    case browserSignIn
    /// The gateway upgrade was refused with this HTTP status after a good sign-in, usually
    /// by a proxy that drops the ticket header or has no WebSocket support. Permanent;
    /// 408, 429 and 5xx arrive as `.rejected` instead (`init(upgradeStatus:)`).
    case upgradeRefused(Int)
    /// `/api/status` reported this release, older than `HermesCompatibility.minimumVersion`,
    /// so sign-in stopped before the password. Permanent.
    case outdated(String)
    var errorDescription: String? {
        switch self {
        case .stale: return String(localized: "This action is no longer current. Refresh the conversation.")
        // `BotConnectionAdvice` names the host for `.notDashboard`; this is the hostless fallback.
        case .unsupported, .notDashboard: return String(localized: "This Hermes connection does not support Bot chat here.")
        case .missingChat: return String(localized: "Open this bot’s chat in Hermes Desktop, then refresh.")
        case .wrongIdentity: return String(localized: "The conversation identity changed. Check this bot in Desktop.")
        case .differentHost: return String(localized: "The Hermes host at this address reports a different identity than the one you connected to. Check the address in the Hermes connection.")
        case .rejected(401): return String(localized: "Hermes didn't accept the username or password.")
        // Hermes's REST routes never answer 403, but the gateway upgrade does (see `.upgradeRefused`).
        // Hermes never answers 520-530 itself. 502-504 usually come from a proxy; Hermes's own 503
        // (its auth provider is unreachable) shares the approved proxy copy.
        case .rejected(403): return String(localized: "Something in front of Hermes, such as Cloudflare Access, blocked the request.")
        case .rejected(502...504): return String(localized: "Your proxy answered, but Hermes didn't. Check that the dashboard is running on the host.")
        case .rejected(520...530): return String(localized: "Cloudflare can't reach your tunnel. Check that cloudflared and the dashboard are running on the host.")
        case .rejected(-32601): return String(localized: "This Hermes connection does not support Bot chat here.")
        case .rejected(4090): return String(localized: "Another Hermes process owns this conversation. Resolve it on the host, then refresh.")
        case .rejected(4130): return String(localized: "This conversation is too large to open here. Use Desktop.")
        case .invalidAddress: return String(localized: "Enter a Hermes HTTP or HTTPS address without a path, credentials or query.")
        case .blocked: return String(localized: "Something in front of Hermes, such as Cloudflare Access, wants its own sign-in first. Add its service token under Connection Headers in the Hermes connection, or use an address that skips it, such as the dashboard's local network address.")
        case .browserSignIn: return String(localized: "This Hermes host only offers sign-in with a browser, which Hermex doesn't support yet. To connect now, add a dashboard username and password on the host.")
        case .upgradeRefused: return String(localized: "Hermes accepted the sign-in, but the live connection was refused. If a proxy or tunnel sits in front of Hermes, turn on WebSocket support and let the Sec-WebSocket-Protocol header through.")
        case .outdated(let version):
            return String(localized: "This Hermes host runs \(version). Hermex needs Hermes \(HermesCompatibility.minimumVersion) or later. Update Hermes on the host, then try again.")
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

/// One screen's connection to the Bot gateway. `BotClient` is the real one: a handle on
/// the socket every screen of the saved connection shares.
@MainActor protocol BotTransport: AnyObject {
    var replayEpoch: String? { get }
    var serverVersion: String? { get }
    /// `install_id` from `/api/status` at the last connect; nil when the host omits it.
    var serverInstallID: String? { get }
    /// Gateway methods the host answered -32601 (method not found) on this connection,
    /// shared by every screen on it; a new connection starts empty.
    var unavailableMethods: Set<String> { get }
    /// Sequenced event params or a complete string-id server-request envelope. The socket
    /// is shared, so this sees other screens' sessions too: admit only your own.
    var onEvent: ((BotJSON) -> Void)? { get set }
    /// The socket was lost or its connection replaced; once each time, never for `close()`.
    var onDisconnect: ((Error) -> Void)? { get set }
    func connect() async throws
    /// Sends one typed request. `validateDispatch` runs immediately before the
    /// socket write, so an action that went stale while queued is never sent.
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String
    func artifactData(path: String, context: BotArtifactContext) async throws -> Data
    /// Removes a Profile on the host over the authenticated HTTP session. Only
    /// a 200 with `ok` counts as deleted; anything else leaves the bot in place.
    func deleteProfile(_ name: String) async throws
    /// Ends this screen's calls, uploads and downloads; the shared socket stays for others.
    func close()
}

extension BotTransport {
    var serverVersion: String? { nil }
    var serverInstallID: String? { nil }
    var unavailableMethods: Set<String> { [] }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        throw BotFailure.unsupported
    }

    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        throw BotArtifactFailure.unavailable
    }

    func deleteProfile(_ name: String) async throws {
        throw BotFailure.unsupported
    }

    func call(_ call: HermesCall) async throws -> BotJSON {
        try await self.call(call, validateDispatch: nil)
    }
}

/// The public `GET /api/status` fields the connection screen shows. Every field is
/// optional because hosts add, omit and rename them between releases.
struct BotHostStatus: Equatable {
    var version: String?
    var gatewayRunning: Bool?
    /// `starting`, `running`, `draining`, `degraded`, `startup_failed` or `stopped` at
    /// the pin; any other value is shown as unknown.
    var gatewayState: String?
    /// Null after a clean stop.
    var gatewayExitReason: String?
    /// Seconds since the gateway's last heartbeat, set only while its process is alive
    /// but wedged.
    var heartbeatStale: Double?
    var platformsConnected: Int?
    var platformsConfigured: Int?

    init(_ json: BotJSON) {
        version = json["version"].text
        gatewayRunning = json["gateway_running"].flag
        gatewayState = json["gateway_state"].text
        gatewayExitReason = json["gateway_exit_reason"].text
        heartbeatStale = json["gateway_heartbeat_stale_s"].number
        platformsConnected = json["components"]["platforms"]["connected"].integer
        platformsConfigured = json["components"]["platforms"]["configured"].integer
    }
}

/// Why the status probe produced no status. Kept apart from `BotFailure`, whose copy
/// is about chats.
enum BotHostProbeFailure: Error, Equatable {
    /// The transport failed; carries the system's reason.
    case unreachable(String)
    /// Something in front of Hermes refused the public route: a 401 or 403, or a
    /// redirect to another host such as an access sign-in page.
    case blocked
    case answered(Int)
    /// A 200 whose body is not a JSON object.
    case notHermes
}

/// One unauthenticated `GET /api/status` on its own short-lived session. It sends no
/// cookies or credentials, so checking never counts against the host's sign-in limit;
/// only the saved Connection Headers, which a proxy such as Cloudflare Access needs even
/// for this public route. A redirect to another host drops them.
struct BotHostStatusProbe {
    let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        self.configuration = configuration
    }

    func check(_ address: URL, headers: HermesHeaders = .none) async -> Result<BotHostStatus, BotHostProbeFailure> {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let request = headers.applied(to: try HermesREST.status.request(base: address), origin: address)
            let (data, response) = try await session.data(for: request, delegate: headers.redirectGuard(for: address))
            guard let response = response as? HTTPURLResponse else { return .failure(.notHermes) }
            if response.url?.host != request.url?.host || [401, 403].contains(response.statusCode) { return .failure(.blocked) }
            guard response.statusCode == 200 else { return .failure(.answered(response.statusCode)) }
            guard let json = try? JSONDecoder().decode(BotJSON.self, from: data), json.fields != nil else {
                return .failure(.notHermes)
            }
            return .success(BotHostStatus(json))
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }
}
