import Foundation
import OSLog

/// One direct-Hermes connection: one ephemeral cookie jar, one password sign-in, the path
/// every Bot HTTP request and gateway upgrade is sent through, and the one gateway socket
/// its Bot screens share (`gateway`). `HermesConnections` gives every consumer of a
/// server's saved connection (the Bot screens' `BotClient`s and push provisioning's
/// `BotDashboardClient`) the same instance, so they sign in once and share one socket.
/// Setup and dev auto-login probe unsaved credentials on their own.
///
/// Sign-in is single-flight: it reads the public `/api/status`, refuses a release older
/// than `HermesCompatibility.minimumVersion` and checks the install identity before the
/// password goes out, then verifies the identity the host returns.
/// Cancelling one waiting consumer never cancels it. A signed-in request the host answers
/// with 401 signs in again once, sharing that sign-in with any other consumer's 401, and
/// is resent: the auth gate refuses before any handler runs, so the resend cannot repeat
/// a write. Nothing else is retried, and a transport failure or 5xx leaves the sign-in as
/// it was. After `retire()`, every call and every late reply throws `.stale`, and the
/// gateway socket has ended.
@MainActor final class HermesConnection {
    enum Deadline {
        /// 15 seconds per request and 30 overall, like the gateway's own calls.
        case standard
        /// 120 and 180: installing a plugin clones a repository on the host, and a restart
        /// takes the gateway down and back up. 15 seconds would read as a failure while
        /// the host was still succeeding. A sign-in provisioning starts gets them too, and so
        /// does a Task's Run Now, which the host answers once the run has finished (#1041).
        case provisioning
    }

    private(set) var connection: BotConnection
    /// `version` from the last sign-in's `/api/status`, read before the auth gate; nil when omitted.
    private(set) var serverVersion: String?
    /// `install_id` from the same read; nil when omitted.
    private(set) var serverInstallID: String?
    /// Gateway methods the host answered -32601 (method not found) on this connection, so
    /// a control one chat found missing stays off in every chat on it. Recorded by
    /// `gateway`; a new connection starts empty.
    private(set) var unavailableMethods: Set<String> = []
    /// The standard-deadline session. The gateway socket opens on it, with its cookies.
    let session: URLSession
    /// Shares `session`'s cookie jar; only its deadlines differ.
    let provisioningSession: URLSession
    private let headers: HermesHeaders
    private let redirectGuard: CrossOriginHeaderStripper
    private let gatewayOptions: HermesGateway.Options
    /// The gateway while some screen's `BotClient` holds it; nil while none does.
    private(set) weak var liveGateway: HermesGateway?
    private var isSignedIn = false
    /// Counts sign-ins, so a 401 can tell whether another consumer has already recovered.
    private var epoch = 0
    private var signInTask: Task<Void, Error>?
    private(set) var isRetired = false
    /// Called when the login step answers 401, before the failure reaches any consumer,
    /// including the re-login a signed-in 401 starts. `HermesConnections` sets it so
    /// `AuthManager` can sign a Hermes server out (#899); nothing here remembers it.
    var onLoginRejected: (() -> Void)?
    /// Numbers connections in this process (`c1`, `c2`, …), so log lines from two servers
    /// can be told apart without naming either.
    let serial: Int
    private static var connectionCount = 0

    /// Sends `connection`'s saved headers to its origin only (`HermesHeaders(saved:)`).
    /// `gateway` configures the shared socket; tests script it.
    init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral,
         gateway: HermesGateway.Options = HermesGateway.Options()) {
        self.connection = connection
        headers = HermesHeaders(saved: connection)
        gatewayOptions = gateway
        Self.connectionCount += 1
        serial = Self.connectionCount
        redirectGuard = headers.redirectGuard(for: connection.address)
        let standard = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        standard.timeoutIntervalForRequest = 15
        standard.timeoutIntervalForResource = 30
        let provisioning = standard.copy() as? URLSessionConfiguration ?? .ephemeral
        provisioning.timeoutIntervalForRequest = 120
        provisioning.timeoutIntervalForResource = 180
        provisioning.httpCookieStorage = standard.httpCookieStorage
        session = URLSession(configuration: standard)
        provisioningSession = URLSession(configuration: provisioning)
    }

    /// The gateway socket every Bot screen on this connection shares. It is made on first
    /// use and kept while a screen's `BotClient` holds it.
    var gateway: HermesGateway {
        if let liveGateway { return liveGateway }
        let fresh = HermesGateway(http: self, options: gatewayOptions)
        liveGateway = fresh
        return fresh
    }

    /// The gateway's report that the host answered `method` with -32601.
    func noteUnavailable(_ method: String) {
        unavailableMethods.insert(method)
    }

    /// Signs in unless this connection already is. Concurrent callers share one attempt,
    /// which runs on the session for the `deadline` of the caller that started it.
    func signIn(deadline: Deadline = .standard) async throws {
        try checkCurrent()
        if isSignedIn { return }
        let attempt = signInTask ?? beginSignIn(on: session(for: deadline))
        do { try await attempt.value } catch { try checkCurrent(); throw error }
        try checkCurrent()
    }

    private func beginSignIn(on session: URLSession) -> Task<Void, Error> {
        let attempt = Task {
            defer { signInTask = nil }
            // The step a failure is logged at.
            var step = "status"
            do {
                let status = try await publicStatus(on: session)
                try checkCurrent()
                serverVersion = status["version"].text
                serverInstallID = BotConnection.installID(in: status)
                if let version = serverVersion, !HermesCompatibility.isSupported(version) { throw BotFailure.outdated(version) }
                try connection.requireSameInstall(serverInstallID)
                guard status["auth_required"].flag == true else { throw BotFailure.unsupported }
                // #708 replaces this branch with the browser sign-in flow.
                guard status["auth_providers"].list?.contains(.string("basic")) == true else { throw BotFailure.browserSignIn }
                step = "login"
                _ = try await decoded(.login(username: connection.username, password: connection.password), on: session)
                try checkCurrent()
                step = "identity"
                let identity = try await decoded(.identity, on: session)
                try checkCurrent()
                guard identity["provider"].text == "basic" else { throw BotFailure.wrongIdentity }
                // Trust on first use, in memory only: a later sign-in here must reach the same install.
                if connection.installID == nil { connection.installID = serverInstallID }
                isSignedIn = true
                epoch += 1
                let release = serverVersion ?? "unreported"
                HermesConnectionLog.logger.notice("c\(self.serial, privacy: .public): signed in, release \(release, privacy: .public)")
            } catch {
                // A retired connection has already logged that it was retired.
                if !isRetired {
                    let reason = HermesConnectionLog.reason(error), failedStep = step
                    HermesConnectionLog.logger.error("c\(self.serial, privacy: .public): sign-in failed at \(failedStep, privacy: .public): \(reason, privacy: .public)")
                    if step == "login", error as? BotFailure == .rejected(401) { onLoginRejected?() }
                }
                throw error
            }
        }
        signInTask = attempt
        return attempt
    }

    /// Reads the public `/api/status` once, with this connection's headers and no
    /// credentials, classified as sign-in classifies it: `.notDashboard`, `.blocked` or
    /// `.rejected`. The connect form reads it to tell a Hermes dashboard from a webui (#900).
    /// Its probe can reach a port the webui path never would, such as plain HTTP on a TLS
    /// port, so here only the dashboard's own Host-header refusal is `.rejected(400)`, and
    /// any other 400 is `.notDashboard`.
    func status() async throws -> BotJSON {
        try checkCurrent()
        return try await publicStatus(on: session, onlyHostRefusalIs400: true)
    }

    /// One public `/api/status` read, without signing in: whether the host answers at all, as
    /// push provisioning asks while Hermes restarts. Any failure is a no.
    func answersStatus() async -> Bool {
        guard !isRetired else { return false }
        return (try? await publicStatus(on: session)) != nil
    }

    /// The body of one public route the host answers before its auth gate, such as
    /// `/api/health`, sent with this connection's headers and without signing in. Any status
    /// but 200 throws `BotFailure.rejected`.
    func publicData(_ rest: HermesREST) async throws -> Data {
        try checkCurrent()
        let data = try await Self.send(prepared(try rest.request(base: connection.address)), on: session,
                                       accepting: 200..<201, redirectGuard: redirectGuard)
        try checkCurrent()
        return data
    }

    /// Sends one signed-in request built from `rest` and returns the body of a reply whose
    /// status is in `accepted`. Any other status throws `BotFailure.rejected`.
    /// `validateDispatch` is as in `authorized`.
    func data(_ rest: HermesREST, deadline: Deadline = .standard, accepting accepted: Range<Int> = 200..<201,
              validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> Data {
        let redirectGuard = self.redirectGuard
        return try await authorized(try rest.request(base: connection.address), deadline: deadline,
                                    validateDispatch: validateDispatch) { request, session in
            try await Self.send(request, on: session, accepting: accepted, redirectGuard: redirectGuard)
        }
    }

    /// Sends one signed-in request built from `rest` and returns its body and status, whatever
    /// the status, for routes whose refusals carry the host's reason (`{detail}`), such as a
    /// refused cron or Kanban write (#1044). A 401 still signs in again and resends once, as
    /// `data` does.
    func reply(_ rest: HermesREST, deadline: Deadline = .standard) async throws -> (body: Data, status: Int) {
        let redirectGuard = self.redirectGuard
        return try await authorized(try rest.request(base: connection.address), deadline: deadline) { request, session in
            let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
            if response.statusCode == 401 { throw BotFailure.rejected(401) }
            return (data, response.statusCode)
        }
    }

    /// Runs `perform` signed in, with `request` given this connection's headers. `perform`
    /// sends it on the session for `deadline` and throws `BotFailure.rejected(401)` for an
    /// unauthenticated reply, which alone signs in again and resends it, once.
    /// `validateDispatch` runs just before each send, the resend included, once any sign-in
    /// it waited on is done: a consumer that closed meanwhile throws there, and nothing goes out.
    func authorized<T: Sendable>(_ request: URLRequest, deadline: Deadline = .standard,
                                 validateDispatch: (@MainActor () throws -> Void)? = nil,
                                 _ perform: @Sendable (URLRequest, URLSession) async throws -> T) async throws -> T {
        let request = prepared(request)
        let session = self.session(for: deadline)
        try await signIn(deadline: deadline)
        try validateDispatch?()
        let sentEpoch = epoch
        do {
            let value = try await perform(request, session)
            try checkCurrent()
            return value
        } catch BotFailure.rejected(401) {
            try checkCurrent()
            // The first reply to show the session expired drops it; later ones join the same sign-in.
            if epoch == sentEpoch { isSignedIn = false }
            try await signIn(deadline: deadline)
            try validateDispatch?()
            let value = try await perform(request, session)
            try checkCurrent()
            return value
        }
    }

    /// Mints one single-use ticket and returns the gateway upgrade that presents it.
    func gatewayUpgrade() async throws -> URLRequest {
        try await upgrade { try HermesREST.gatewayUpgrade(base: connection.address, ticket: $0) }
    }

    /// Mints one single-use ticket, never the gateway's, and returns `board`'s Kanban event
    /// socket upgrade that presents it, with this connection's headers (#1045).
    func kanbanEventsUpgrade(board: String, since: Int) async throws -> URLRequest {
        try await upgrade {
            try HermesREST.kanbanEventsUpgrade(base: connection.address, board: board, since: since, ticket: $0)
        }
    }

    /// Mints one ticket and returns the upgrade `build` makes for it, with this connection's headers.
    private func upgrade(_ build: (String) throws -> URLRequest) async throws -> URLRequest {
        do {
            let ticket = try JSONDecoder().decode(BotJSON.self, from: try await data(.ticket))
            guard let token = ticket["ticket"].text, !token.isEmpty else { throw BotFailure.unsupported }
            return prepared(try build(token))
        } catch {
            // A failed sign-in, including the one after the ticket's 401, leaves this
            // connection signed out and has already logged its own step.
            if !isRetired, isSignedIn {
                let reason = HermesConnectionLog.reason(error)
                HermesConnectionLog.logger.error("c\(self.serial, privacy: .public): sign-in failed at ticket: \(reason, privacy: .public)")
            }
            throw error
        }
    }

    /// Whether `saved` is still this connection: the same UUID, address, account,
    /// password and headers, and no conflicting install id. A newly backfilled install id
    /// is taken.
    func adopt(_ saved: BotConnection) -> Bool {
        guard !isRetired, saved.id == connection.id, saved.address == connection.address,
              saved.username == connection.username, saved.password == connection.password,
              (saved.headers ?? []) == (connection.headers ?? []) else { return false }
        if let live = connection.installID, let stored = saved.installID, live != stored { return false }
        if connection.installID == nil { connection.installID = saved.installID }
        return true
    }

    /// Ends this connection when its server or configuration is replaced: a sign-in in
    /// flight stops and stores nothing, every call, late reply and resend after this
    /// throws `.stale`, and the gateway socket closes, telling each attached screen once.
    func retire() {
        HermesConnectionLog.logger.notice("c\(self.serial, privacy: .public): connection retired")
        isRetired = true
        isSignedIn = false
        signInTask?.cancel()
        signInTask = nil
        liveGateway?.retire()
    }

    /// The login and identity reads, which run before there is a session.
    private func decoded(_ rest: HermesREST, on session: URLSession) async throws -> BotJSON {
        let data = try await Self.send(prepared(try rest.request(base: connection.address)), on: session,
                                       accepting: 200..<201, redirectGuard: redirectGuard)
        return try JSONDecoder().decode(BotJSON.self, from: data)
    }

    /// The first sign-in read. `/api/status` is public on every dashboard, so a 404, a body
    /// that is not JSON, or a 401 whose body is a JSON object (the webui's auth gate) means
    /// the address is something else, such as the webui. Any other 401 comes from something
    /// in front of Hermes, such as Cloudflare Access. `onlyHostRefusalIs400` is `status()`'s.
    private func publicStatus(on session: URLSession, onlyHostRefusalIs400: Bool = false) async throws -> BotJSON {
        let request = prepared(try HermesREST.status.request(base: connection.address))
        let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
        let body = try? JSONDecoder().decode(BotJSON.self, from: data)
        switch response.statusCode {
        case 200:
            guard let body else { throw BotFailure.notDashboard }
            return body
        case 401: throw body?.fields != nil ? BotFailure.notDashboard : BotFailure.blocked
        case 404: throw BotFailure.notDashboard
        // The dashboard's Host-header middleware answers `{"detail": "Invalid Host header. …"}`.
        case 400 where onlyHostRefusalIs400 && body?["detail"].text?.hasPrefix("Invalid Host header") != true:
            throw BotFailure.notDashboard
        case let code: throw BotFailure.rejected(code)
        }
    }

    private func session(for deadline: Deadline) -> URLSession {
        deadline == .provisioning ? provisioningSession : session
    }

    private nonisolated static func send(_ request: URLRequest, on session: URLSession, accepting accepted: Range<Int>,
                                         redirectGuard: CrossOriginHeaderStripper) async throws -> Data {
        let (data, response) = try await exchange(request, on: session, redirectGuard: redirectGuard)
        guard accepted.contains(response.statusCode) else { throw BotFailure.rejected(response.statusCode) }
        return data
    }

    /// Sends `request` and returns the final reply, whatever its status. A reply from another
    /// host means a redirect led to something in front of Hermes, such as an access proxy's
    /// sign-in page, and throws `.blocked`, like the status probe. Only the host is compared:
    /// a same-host redirect from http to https is not a proxy.
    private nonisolated static func exchange(_ request: URLRequest, on session: URLSession,
                                             redirectGuard: CrossOriginHeaderStripper) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        guard let response = response as? HTTPURLResponse else { throw BotFailure.transport }
        if let final = response.url?.host, final.lowercased() != request.url?.host?.lowercased() { throw BotFailure.blocked }
        return (data, response)
    }

    private func prepared(_ request: URLRequest) -> URLRequest {
        headers.applied(to: request, origin: connection.address)
    }

    private func checkCurrent() throws {
        if isRetired { throw BotFailure.stale }
    }
}

/// Gives every consumer of the active server's saved Bot connection the same
/// `HermesConnection`, and with it the same gateway socket. It keeps one entry, keyed by
/// configured server and connection UUID, and holds it weakly, so the connection lives
/// only while a consumer does. A request for another server or UUID, or for the same UUID
/// with a new address, account, password or headers (the connection form can keep a UUID
/// across those), retires the old connection first, so no cookie, sign-in, socket or late
/// reply crosses servers, accounts, credentials or headers.
/// Credentials and headers are compared on the live connection and never kept in a key.
@MainActor final class HermesConnections {
    static let shared = HermesConnections()
    /// Told which configured server's saved username or password the host refused at the
    /// login step. `AuthManager` sets it and signs that server out when it is the active
    /// Hermes server (#899).
    var onSignInRejected: ((URL) -> Void)?
    private let configuration: () -> URLSessionConfiguration
    private var server: String?
    private weak var current: HermesConnection?

    /// `configuration` makes each new connection's URL session setup, with a cookie jar of
    /// its own; tests script the host with it.
    init(configuration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.configuration = configuration
    }

    func connection(for saved: BotConnection, server: URL) -> HermesConnection {
        if let current, self.server == server.absoluteString, current.adopt(saved) { return current }
        current?.retire()
        let fresh = HermesConnection(connection: saved, configuration: configuration())
        fresh.onLoginRejected = { [weak self] in self?.onSignInRejected?(server) }
        current = fresh
        self.server = server.absoluteString
        return fresh
    }

    /// Closes the current connection's gateway socket, silently, because the app went to
    /// the background (#902). `ContentView` calls it on `.background` only, so Control
    /// Center and banners (`.inactive`) keep the socket.
    func closeForBackground() {
        current?.liveGateway?.closeForBackground()
    }

    /// Ends `server`'s gateway socket as lost because its dashboard restarted on an update
    /// (#1075), so every Bot screen on it reconnects now, onto a fresh ticket and handshake,
    /// rather than on its backoff or its next `.active`. Nothing happens for another server.
    func reconnectGateway(server: URL) {
        guard self.server == server.absoluteString else { return }
        current?.liveGateway?.dropSocket()
    }

    /// Retires `server`'s connection now unless `saved`, its newly saved record, is still
    /// that connection. `AuthManager` calls it when `server` stops being active, and
    /// `BotConnectionStore` when its credentials are saved or removed, so a sign-in in
    /// flight stores nothing and no request is sent or resent after the change, rather
    /// than until the next lookup.
    func retire(server: URL, unlessStill saved: BotConnection? = nil) {
        guard let current, self.server == server.absoluteString else { return }
        if let saved, current.adopt(saved) { return }
        current.retire()
        self.current = nil
    }
}

/// The wait for a Hermes dashboard that went away to restart: push's "Restart Hermes…" (#934)
/// and an update from Settings (#1075). Whoever starts the restart counts a dropped connection
/// on that request as the restart having begun. The probe signs in again for the restarted
/// dashboard's new session key, which `HermesConnection` does on the first 401.
enum HermesRestartWait {
    /// Sleeps each of `delays` in turn and then asks `probe`, until `isFinal` holds for its
    /// answer or the schedule runs out. The last answer stands: the final probe's, which is
    /// nil when it heard nothing. A cancelled sleep ends the wait with the answer before it.
    @MainActor static func lastAnswer<Answer>(
        after delays: [Duration], sleep: @Sendable (Duration) async throws -> Void,
        probe: () async -> Answer?, isFinal: (Answer) -> Bool
    ) async -> Answer? {
        var answer: Answer?
        for delay in delays {
            do { try await sleep(delay) } catch { break }
            answer = await probe()
            if let answer, isFinal(answer) { break }
        }
        return answer
    }
}

/// Request headers for one direct-Hermes origin, admitted by the policy the host needs:
/// no name the transport owns (the URL loading system, the cookie jar and the gateway
/// handshake set those), no name Hermes reads for its own checks (`Origin` for the
/// gateway upgrade, `X-Forwarded-Prefix` for the session cookie's path,
/// `X-Hermes-Session-Token`), and no `Bearer` authorization, which Hermes also reads as
/// its session token. Any other `Authorization` value passes, such as Cloudflare Access's
/// single-header JSON service token. The only source is the Hermes connection's own
/// record (`BotConnection.headers`, edited as Connection Headers in its form), never the
/// webui's custom headers.
struct HermesHeaders: Sendable {
    enum Rejection: Error, Equatable, LocalizedError {
        case malformed(String), reserved(String), bearer

        /// Shown under the connection form's Connection Headers row.
        var errorDescription: String? {
            switch self {
            case .bearer:
                return String(localized: "Hermes reads Authorization: Bearer as its own sign-in and refuses it. Remove this header to connect.")
            case .reserved(let name):
                // First-strong isolates keep the name in one left-to-right run in right-to-left text.
                let shown = "\u{2068}\(name)\u{2069}"
                return String(localized: "\(shown) is reserved for Hermex and Hermes, so it can't be a connection header. Remove this header to connect.")
            case .malformed(let name):
                let shown = "\u{2068}\(name)\u{2069}"
                return String(localized: "\(shown) isn't a valid header: names can't contain spaces or colons, and values must fit on one line. Fix or remove it to connect.")
            }
        }
    }

    static let none = HermesHeaders(admitted: [])
    private static let reserved: Set<String> = [
        "host", "connection", "upgrade", "content-length", "transfer-encoding", "te", "trailer",
        "keep-alive", "proxy-connection", "proxy-authorization", "cookie",
        "origin", "x-forwarded-prefix", "x-hermes-session-token"
    ]

    let values: [CustomHeader]

    init(_ headers: [CustomHeader]) throws {
        for header in headers {
            let name = header.sanitizedName.lowercased()
            guard header.isApplicable else { throw Rejection.malformed(header.sanitizedName) }
            guard !Self.reserved.contains(name), !name.hasPrefix("sec-websocket-") else {
                throw Rejection.reserved(header.sanitizedName)
            }
            let scheme = header.sanitizedValue.split(whereSeparator: \.isWhitespace).first?.lowercased()
            if name == "authorization", scheme == "bearer" { throw Rejection.bearer }
        }
        values = headers
    }

    private init(admitted: [CustomHeader]) { values = admitted }

    /// The headers `saved`'s requests carry. A saved list the policy now refuses sends
    /// none: the connection form shows why under its Connection Headers row and keeps
    /// Connect off until it is fixed.
    init(saved: BotConnection) {
        self = (try? HermesHeaders(saved.headers ?? [])) ?? .none
    }

    /// `request` with these headers added when it is for `origin`. A header the request
    /// already carries, such as the JSON content type or the gateway subprotocols, keeps
    /// its built-in value.
    func applied(to request: URLRequest, origin: URL) -> URLRequest {
        guard !values.isEmpty, let url = request.url, Self.isSameOrigin(url, as: origin) else { return request }
        var request = request
        for header in values where request.value(forHTTPHeaderField: header.sanitizedName) == nil {
            request.setValue(header.sanitizedValue, forHTTPHeaderField: header.sanitizedName)
        }
        return request
    }

    /// The task delegate that drops these headers from a redirect that leaves `origin`.
    func redirectGuard(for origin: URL) -> CrossOriginHeaderStripper {
        let admitted = values
        return CrossOriginHeaderStripper(baseURL: origin, customHeaderProvider: { admitted })
    }

    /// Same scheme, host and port as `address`, reading the gateway's `ws`/`wss` as `http`/`https`.
    static func isSameOrigin(_ url: URL, as address: URL) -> Bool {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        switch parts.scheme?.lowercased() {
        case "wss": parts.scheme = "https"
        case "ws": parts.scheme = "http"
        default: break
        }
        guard let http = parts.url else { return false }
        return APIClient.isSameOrigin(http, as: address)
    }
}

/// The device log for a Hermes connection, under the bundle ID and the category
/// `HermesConnection`: sign-ins, and the gateway socket opening, closing and dropping, a
/// reply that matched no open call and a call that got no reply. Lines name connections
/// `c1`, `c2`, … and each connection's sockets `s0`, `s1`, …, never the server itself.
/// Interpolate only numbers, step, case and method names, the release `/api/status`
/// reports (upstream's package version) and `reason(_:)`, each `privacy: .public`; never
/// a host, address, URL, session or runtime id, Profile name, title, message text,
/// ticket, replay epoch or install id. Events, deltas and keepalive pongs are never logged.
enum HermesConnectionLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile", category: "HermesConnection")

    /// Names `error` for a log line without its description or user info: a `URLError`'s
    /// user info holds the failing URL, and so the host, and a rejection can carry the
    /// host's own text. `BotFailure`'s payloads are status and error codes, and the
    /// release `/api/status` reported for `.outdated`.
    static func reason(_ error: Error) -> String {
        switch error {
        case let failure as BotFailure: return "\(failure)"
        case let error as URLError: return "URLError \(error.code.rawValue)"
        case is DecodingError: return "DecodingError"
        case is CancellationError: return "cancelled"
        default:
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
    }
}
