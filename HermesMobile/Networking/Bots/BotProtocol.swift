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
    /// Whether a screen that lost its connection to `error` should reconnect on its backoff
    /// (the inbox, the Sessions list). False for a refusal the user has to act on: sign-in,
    /// an unsupported host or address, an address that now reaches a different host or is not
    /// a dashboard, an access proxy's own sign-in, a host with browser sign-in only, a refused
    /// gateway upgrade, a Hermes release older than the minimum, and any other permanent HTTP
    /// client error (a 404 is not a Hermes host). Server errors, rate limits and JSON-RPC
    /// faults other than "method missing" are the retry loop's problem.
    static func isRetryable(_ error: Error) -> Bool {
        switch error as? BotFailure {
        case .unsupported, .wrongIdentity, .differentHost, .invalidAddress, .notDashboard,
             .blocked, .browserSignIn, .upgradeRefused, .outdated: return false
        case .rejected(-32601), .rejected(4090), .rejected(4130): return false
        case .rejected(408), .rejected(429): return true
        case .rejected(let code): return !(400..<500).contains(code)
        default: return true
        }
    }

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
    /// One file the host serves by `path` under `context`'s Profile and session. `limit` caps a
    /// preview's bytes; nil reads the whole file, as a MEDIA file's export does (#1112).
    func artifactData(path: String, context: BotArtifactContext, limit: Int?) async throws -> Data
    /// Removes a Profile on the host over the authenticated HTTP session. Only
    /// a 200 with `ok` counts as deleted; anything else leaves the bot in place.
    func deleteProfile(_ name: String) async throws
    /// The Profile the host's dashboard is scoped to (`/api/profiles/active` `current`), the
    /// one a new session runs under.
    func currentProfile() async throws -> String
    /// A stored session's rows under `profile` (`HermesREST.sessionMessages`): its latest 500
    /// without an offset, else one transcript page from `offset` (#1047). Nil when the host has
    /// no such session (404).
    func sessionMessages(_ key: String, profile: String, offset: Int?) async throws -> [BotJSON]?
    /// `text` spoken in `profile`'s voice (`HermesREST.speak`): the audio bytes, of a format the
    /// host's TTS provider chose. Any refusal or unreadable reply throws.
    func speech(text: String, profile: String) async throws -> Data
    /// One page of `profile`'s sessions for the Sessions list, or with `archived` for the
    /// Archived screen (`HermesREST.sessionList`, #1046, #1048).
    func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage
    /// Writes one change to a session (`HermesREST.updateSession`, #1046, #1048) and returns the
    /// title the host keeps. A change the host refuses with its reason, such as a title already
    /// in use, throws `HermesSessionRefusal`.
    @discardableResult
    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String?
    /// The session's row and messages as the host exports them (`HermesREST.sessionExport`, #1048).
    func exportSession(key: String, profile: String) async throws -> Data
    /// That exact session's stored row (`HermesREST.sessionRow`, #1051); nil when the host has
    /// no such session (404).
    func sessionRow(key: String, profile: String) async throws -> BotJSON?
    /// Sends one session import, its JSON `body` already encoded (`HermesREST.importSessions`,
    /// #1051), and returns the host's result. A payload the host refuses throws its reason as
    /// `HermesSessionRefusal`.
    func importSessions(body: Data) async throws -> BotJSON
    /// `profile`'s sessions matching `query`, in the host's order, at most `limit`
    /// (`HermesREST.sessionSearch`, #1053).
    func searchSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult]
    /// The runtimes this phone's screens attached on the connection (`session.resume`) or branched
    /// (`session.branch`, #1051) and have not closed, so a delete can tell its own from another
    /// app's (#1048).
    var attachedRuntimes: Set<String> { get }
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

    func artifactData(path: String, context: BotArtifactContext, limit: Int?) async throws -> Data {
        throw BotArtifactFailure.unavailable
    }

    /// A preview's download: at most 25 MB.
    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        try await artifactData(path: path, context: context, limit: BotArtifactBuffer.maximumBytes)
    }

    func deleteProfile(_ name: String) async throws {
        throw BotFailure.unsupported
    }

    func currentProfile() async throws -> String {
        throw BotFailure.unsupported
    }

    func sessionMessages(_ key: String, profile: String, offset: Int?) async throws -> [BotJSON]? {
        throw BotFailure.unsupported
    }

    func speech(text: String, profile: String) async throws -> Data {
        throw BotFailure.unsupported
    }

    /// A stored session's latest 500 rows, as a background task's result reads them.
    func sessionMessages(_ key: String, profile: String) async throws -> [BotJSON]? {
        try await sessionMessages(key, profile: profile, offset: nil)
    }

    func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        throw BotFailure.unsupported
    }

    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String? {
        throw BotFailure.unsupported
    }

    func exportSession(key: String, profile: String) async throws -> Data {
        throw BotFailure.unsupported
    }

    func sessionRow(key: String, profile: String) async throws -> BotJSON? {
        throw BotFailure.unsupported
    }

    func importSessions(body: Data) async throws -> BotJSON {
        throw BotFailure.unsupported
    }

    func searchSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult] {
        throw BotFailure.unsupported
    }

    /// The search at the Sessions list's page size, `HermesREST.sessionSearchLimit`.
    func searchSessions(query: String, profile: String) async throws -> [HermesSessionSearchResult] {
        try await searchSessions(query: query, profile: profile, limit: HermesREST.sessionSearchLimit)
    }

    var attachedRuntimes: Set<String> { [] }

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

extension BotJSON {
    /// Tool arguments in the shared transcript model's JSON type.
    var argumentDictionary: [String: JSONValue]? {
        guard case .object(let object) = self, !object.isEmpty else { return nil }
        return object.mapValues(\.jsonValue)
    }

    var jsonValue: JSONValue {
        switch self {
        case .object(let value): return .object(value.mapValues(\.jsonValue))
        case .array(let value): return .array(value.map(\.jsonValue))
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .bool(let value): return .bool(value)
        case .null: return .null
        }
    }

    /// A tool result as the text the shared tool row formatter parses: a string as
    /// is, any other JSON re-encoded so envelope fields such as `error` are read.
    var toolResultPreview: String? {
        switch self {
        case .null: return nil
        case .string(let text): return text.isEmpty ? nil : text
        default:
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
