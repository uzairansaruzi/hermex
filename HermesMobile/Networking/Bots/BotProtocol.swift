import Foundation

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
    case stale, unsupported, missingChat, wrongIdentity, differentHost, rejected(Int), transport, invalidAddress, notDashboard
    case blocked
    case browserSignIn
    case signInExpired
    case browserSignInFailed
    case upgradeRefused(Int)
    case outdated(String)
    case signInChanged
    case gatewayListener
    case profileNotServed(String, HermesStandaloneReason?)
    case resumeRefused(String)
    var errorDescription: String? {
        switch self {
        case .stale: return String(localized: "This action is no longer current. Refresh the conversation.")
        case .unsupported, .notDashboard: return String(localized: "This Hermes connection does not support Bot chat here.")
        case .missingChat: return String(localized: "Open this bot’s chat in Hermes Desktop, then refresh.")
        case .wrongIdentity: return String(localized: "The conversation identity changed. Check this bot in Desktop.")
        case .differentHost: return String(localized: "The Hermes host at this address reports a different identity than the one you connected to. Check the address in the Hermes connection.")
        case .rejected(401): return String(localized: "Hermes didn't accept the username or password.")
        case .rejected(403): return String(localized: "Something in front of Hermes, such as Cloudflare Access, blocked the request.")
        case .rejected(502...504): return String(localized: "Your proxy answered, but Hermes didn't. Check that the dashboard is running on the host.")
        case .rejected(520...530): return String(localized: "Cloudflare can't reach your tunnel. Check that cloudflared and the dashboard are running on the host.")
        case .rejected(-32601): return String(localized: "This Hermes connection does not support Bot chat here.")
        case .rejected(4090): return String(localized: "Another Hermes process owns this conversation. Resolve it on the host, then refresh.")
        case .rejected(4130): return String(localized: "This conversation is too large to open here. Use Desktop.")
        case .resumeRefused("runtime_coordination_required"): return String(localized: "Hermes needs coordination on the host before it can open this session from here. Open it in Hermes Desktop.")
        case .resumeRefused(let reason): return String(localized: "Hermes refused to open this session (\(reason)). Check Hermes on the host, then try again.")
        case .invalidAddress: return String(localized: "Enter a Hermes HTTP or HTTPS address without a path, credentials or query.")
        case .blocked: return String(localized: "Something in front of Hermes, such as Cloudflare Access, wants its own sign-in first. Add its service token under Connection Headers in the Hermes connection, or use an address that skips it, such as the dashboard's local network address.")
        case .browserSignIn: return String(localized: "This Hermes host only offers sign-in with a browser, which Hermex doesn't support yet. To connect now, add a dashboard username and password on the host.")
        case .signInExpired: return String(localized: "Your Hermes sign-in expired. Sign in again.")
        case .signInChanged: return String(localized: "This server’s sign-in changed. Sign in again to continue.")
        case .gatewayListener: return String(localized: "This Hermes Webapp has no sign-in, and Hermex connects only to one that has. Turn its sign-in on, or connect to hermes dashboard (port 9119 by default) instead.")
        case .profileNotServed(let profile, nil):
            return String(localized: "This Hermes Webapp doesn’t serve the \(profile) Profile, so its chats can’t open here. On the host, hermes gateway status says why. Or connect to hermes dashboard, which serves every Profile.")
        case .profileNotServed(let profile, let reason?):
            let why = reason.summary ?? String(localized: "The host serves only one Profile right now.")
            return String(localized: "This Hermes Webapp doesn’t serve the \(profile) Profile, so its chats can’t open here. \(why)")
        case .browserSignInFailed: return String(localized: "The browser sign-in didn't finish. Try again.")
        case .upgradeRefused: return String(localized: "Hermes accepted the sign-in, but the live connection was refused. If a proxy or tunnel sits in front of Hermes, turn on WebSocket support and let the Sec-WebSocket-Protocol header through.")
        case .outdated(let version):
            return String(localized: "This Hermes host runs \(version). Hermex needs Hermes \(HermesCompatibility.minimumVersion) or later. Update Hermes on the host, then try again.")
        default: return String(localized: "Connection lost. The bot may still be working. Reconnect to check its current conversation.")
        }
    }
}

enum BotConnectionAdvice {
    static func isRetryable(_ error: Error) -> Bool {
        switch error as? BotFailure {
        case .unsupported, .wrongIdentity, .differentHost, .invalidAddress, .notDashboard,
             .blocked, .browserSignIn, .signInExpired, .signInChanged, .upgradeRefused, .outdated,
             .gatewayListener, .profileNotServed, .resumeRefused: return false
        case .rejected(-32601), .rejected(4001), .rejected(4090), .rejected(4130): return false
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

struct HermesAttemptRecord: Equatable, Sendable {
    enum Stage: CaseIterable, Sendable {
        case status
        case signIn
        case identity
        case liveAuthorization
        case liveHandshake
    }

    enum Failure: Equatable, Sendable {
        case http(Int), timedOut, unreachable, certificate, other

        init(_ error: Error) {
            switch error {
            case BotFailure.rejected(let code) where (100..<600).contains(code): self = .http(code)
            case BotFailure.upgradeRefused(let code): self = .http(code)
            case let error as URLError:
                switch error.code {
                case .timedOut: self = .timedOut
                case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost,
                     .notConnectedToInternet, .dataNotAllowed: self = .unreachable
                case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: self = .certificate
                default: self = .other
                }
            default: self = .other
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case notChecked, passed, failed(Failure)
    }

    let started: Date
    var reportedRelease: String?
    private var outcomes: [Stage: Outcome] = [:]

    init(started: Date = .now) {
        self.started = started
    }

    subscript(stage: Stage) -> Outcome {
        get { outcomes[stage] ?? .notChecked }
        set { outcomes[stage] = newValue }
    }

    func report(app: String = Self.appVersion, system: String = Self.systemVersion) -> String {
        let lines = [
            "Hermex connection details",
            "App: \(app)",
            "iOS: \(system)",
            "Server kind: \(self[.status] == .passed ? "Hermes" : "unknown")",
            "Reported release: \(reportedRelease ?? "unknown")",
            "Tested release: \(HermesCompatibility.testedVersion)",
            "Attempt: \(startedText)"
        ] + Stage.allCases.map { "\($0.reportName): \(self[$0].reportText)" }
        return lines.joined(separator: "\n")
    }

    var startedText: String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = TimeZone(identifier: "UTC")
        time.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return time.string(from: started)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "\(version) (\(info?["CFBundleVersion"] as? String ?? "unknown"))"
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

extension HermesAttemptRecord.Stage {
    var reportName: String {
        switch self {
        case .status: return "Status"
        case .signIn: return "Sign-in"
        case .identity: return "Identity"
        case .liveAuthorization: return "Live authorization"
        case .liveHandshake: return "Live handshake"
        }
    }
}

extension HermesAttemptRecord.Outcome {
    var reportText: String {
        switch self {
        case .notChecked: return "Not checked"
        case .passed: return "Passed"
        case .failed(.http(let code)): return "Failed (HTTP \(code))"
        case .failed(.timedOut): return "Failed (timed out)"
        case .failed(.unreachable): return "Failed (couldn't connect)"
        case .failed(.certificate): return "Failed (certificate)"
        case .failed(.other): return "Failed"
        }
    }
}

@MainActor protocol BotTransport: AnyObject {
    var replayEpoch: String? { get }
    var speaksCanonicalProtocol: Bool { get }
    var serverVersion: String? { get }
    var serverInstallID: String? { get }
    var unavailableMethods: Set<String> { get }
    var lastAttempt: HermesAttemptRecord? { get }
    var onEvent: ((BotJSON) -> Void)? { get set }
    var onDisconnect: ((Error) -> Void)? { get set }
    func connect() async throws
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON
    func respond(toRequest id: String, result: BotJSON, validateDispatch: (() throws -> Void)?) async throws
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> BotUploadedImage
    func artifactData(path: String, context: BotArtifactContext, limit: Int?) async throws -> Data
    func keepPlatformNote(profile: String) async
    func deleteProfile(_ name: String) async throws
    func currentProfile() async throws -> String
    func sessionMessages(_ key: String, profile: String, offset: Int?) async throws -> [BotJSON]?
    func speech(text: String, profile: String) async throws -> Data
    func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage
    func scheduledSessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage
    func archivedSessionCount(profile: String) async throws -> Int
    func searchScheduledSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult]
    func sessionScanPage(profile: String, offset: Int) async throws -> HermesScanPage
    @discardableResult
    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String?
    func exportSession(key: String, profile: String) async throws -> Data
    func sessionRow(key: String, profile: String) async throws -> BotJSON?
    func importSessions(body: Data) async throws -> BotJSON
    func searchSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult]
    var attachedRuntimes: Set<String> { get }
    func release(profile: String, sessionID: String)
    func close()
}

extension BotTransport {
    var speaksCanonicalProtocol: Bool { false }

    func respond(toRequest id: String, result: BotJSON, validateDispatch: (() throws -> Void)?) async throws {
        throw BotFailure.unsupported
    }
    var serverVersion: String? { nil }
    var serverInstallID: String? { nil }
    var unavailableMethods: Set<String> { [] }
    var lastAttempt: HermesAttemptRecord? { nil }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> BotUploadedImage {
        throw BotFailure.unsupported
    }

    func artifactData(path: String, context: BotArtifactContext, limit: Int?) async throws -> Data {
        throw BotArtifactFailure.unavailable
    }

    func keepPlatformNote(profile: String) async {}

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

    func sessionMessages(_ key: String, profile: String) async throws -> [BotJSON]? {
        try await sessionMessages(key, profile: profile, offset: nil)
    }

    func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        throw BotFailure.unsupported
    }

    func scheduledSessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        throw BotFailure.unsupported
    }

    func archivedSessionCount(profile: String) async throws -> Int {
        throw BotFailure.unsupported
    }

    func searchScheduledSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult] {
        throw BotFailure.unsupported
    }

    func sessionScanPage(profile: String, offset: Int) async throws -> HermesScanPage {
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

    func searchSessions(query: String, profile: String) async throws -> [HermesSessionSearchResult] {
        try await searchSessions(query: query, profile: profile, limit: HermesREST.sessionSearchLimit)
    }

    var attachedRuntimes: Set<String> { [] }
    func release(profile: String, sessionID: String) {}

    func call(_ call: HermesCall) async throws -> BotJSON {
        try await self.call(call, validateDispatch: nil)
    }
}

enum HermesSignInMethod: Hashable {
    case password
    case browser
    case open

    static var openWarning: String {
        String(localized: "This dashboard has no password. Anyone who can reach this address can use your agent. To require one, set dashboard.public_url on the host and turn on its password.")
    }

    static func offered(by status: BotJSON) -> [HermesSignInMethod]? {
        switch status["auth_required"].flag {
        case false?: return [.open]
        case true?:
            var methods: [HermesSignInMethod] = []
            if status["auth_providers"].list?.contains(.string("basic")) == true { methods.append(.password) }
            if status["auth_flows"].list?.contains(.string("native_pkce")) == true { methods.append(.browser) }
            return methods.isEmpty ? [.password] : methods
        case nil: return nil
        }
    }
}

struct BotHostStatus: Equatable {
    var version: String?
    var gatewayRunning: Bool?
    var gatewayState: String?
    var gatewayExitReason: String?
    var heartbeatStale: Double?
    var platformsConnected: Int?
    var platformsConfigured: Int?
    var profiles: [String]?
    var signInMethods: [HermesSignInMethod]

    init(_ json: BotJSON) {
        version = json["version"].text
        gatewayRunning = json["gateway_running"].flag
        gatewayState = json["gateway_state"].text
        gatewayExitReason = json["gateway_exit_reason"].text
        heartbeatStale = json["gateway_heartbeat_stale_s"].number
        platformsConnected = json["components"]["platforms"]["connected"].integer
        platformsConfigured = json["components"]["platforms"]["configured"].integer
        profiles = json["profiles"].list.map { items in
            var seen = Set<String>()
            return items.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        signInMethods = HermesSignInMethod.offered(by: json) ?? [.password]
    }
}

enum BotHostProbeFailure: Error, Equatable {
    case unreachable(String)
    case blocked
    case answered(Int)
    case notHermes
}

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
