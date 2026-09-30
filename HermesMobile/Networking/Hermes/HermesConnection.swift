import Foundation

/// One direct-Hermes connection: one ephemeral cookie jar, one password sign-in, the path
/// every Bot HTTP request and gateway upgrade is sent through, and the one gateway socket
/// its Bot screens share (`gateway`). `HermesConnections` gives every consumer of a
/// server's saved connection (the Bot screens' `BotClient`s and push provisioning's
/// `BotDashboardClient`) the same instance, so they sign in once and share one socket.
/// Setup and dev auto-login probe unsaved credentials on their own.
///
/// Sign-in is single-flight: it reads the public `/api/status` and checks the install
/// identity before the password goes out, then verifies the identity the host returns.
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
        /// the host was still succeeding. A sign-in provisioning starts gets them too.
        case provisioning
    }

    private(set) var connection: BotConnection
    /// `version` from the last sign-in's `/api/status`, read before the auth gate; nil when omitted.
    private(set) var serverVersion: String?
    /// `install_id` from the same read; nil when omitted.
    private(set) var serverInstallID: String?
    /// The standard-deadline session. The gateway socket opens on it, with its cookies.
    let session: URLSession
    /// Shares `session`'s cookie jar; only its deadlines differ.
    let provisioningSession: URLSession
    private let headers: HermesHeaders
    private let redirectGuard: CrossOriginHeaderStripper
    private let gatewayOptions: HermesGateway.Options
    private weak var liveGateway: HermesGateway?
    private var isSignedIn = false
    /// Counts sign-ins, so a 401 can tell whether another consumer has already recovered.
    private var epoch = 0
    private var signInTask: Task<Void, Error>?
    private(set) var isRetired = false

    /// `headers` are sent to this connection's origin only; production passes none.
    /// `gateway` configures the shared socket; tests script it.
    init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral, headers: HermesHeaders = .none,
         gateway: HermesGateway.Options = HermesGateway.Options()) {
        self.connection = connection
        self.headers = headers
        gatewayOptions = gateway
        let admitted = headers.values
        redirectGuard = CrossOriginHeaderStripper(baseURL: connection.address, customHeaderProvider: { admitted })
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
            let status = try await publicStatus(on: session)
            try checkCurrent()
            serverVersion = status["version"].text
            serverInstallID = BotConnection.installID(in: status)
            try connection.requireSameInstall(serverInstallID)
            guard status["auth_required"].flag == true else { throw BotFailure.unsupported }
            // #708 replaces this branch with the browser sign-in flow.
            guard status["auth_providers"].list?.contains(.string("basic")) == true else { throw BotFailure.browserSignIn }
            _ = try await decoded(.login(username: connection.username, password: connection.password), on: session)
            try checkCurrent()
            let identity = try await decoded(.identity, on: session)
            try checkCurrent()
            guard identity["provider"].text == "basic" else { throw BotFailure.wrongIdentity }
            // Trust on first use, in memory only: a later sign-in here must reach the same install.
            if connection.installID == nil { connection.installID = serverInstallID }
            isSignedIn = true
            epoch += 1
        }
        signInTask = attempt
        return attempt
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
        let ticket = try JSONDecoder().decode(BotJSON.self, from: try await data(.ticket))
        guard let token = ticket["ticket"].text, !token.isEmpty else { throw BotFailure.unsupported }
        return prepared(try HermesREST.gatewayUpgrade(base: connection.address, ticket: token))
    }

    /// Whether `saved` is still this connection: the same UUID, address, account and
    /// password, and no conflicting install id. A newly backfilled install id is taken.
    func adopt(_ saved: BotConnection) -> Bool {
        guard !isRetired, saved.id == connection.id, saved.address == connection.address,
              saved.username == connection.username, saved.password == connection.password else { return false }
        if let live = connection.installID, let stored = saved.installID, live != stored { return false }
        if connection.installID == nil { connection.installID = saved.installID }
        return true
    }

    /// Ends this connection when its server or configuration is replaced: a sign-in in
    /// flight stops and stores nothing, every call, late reply and resend after this
    /// throws `.stale`, and the gateway socket closes, telling each attached screen once.
    func retire() {
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
    /// in front of Hermes, such as Cloudflare Access.
    private func publicStatus(on session: URLSession) async throws -> BotJSON {
        let request = prepared(try HermesREST.status.request(base: connection.address))
        let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
        let body = try? JSONDecoder().decode(BotJSON.self, from: data)
        switch response.statusCode {
        case 200:
            guard let body else { throw BotFailure.notDashboard }
            return body
        case 401: throw body?.fields != nil ? BotFailure.notDashboard : BotFailure.blocked
        case 404: throw BotFailure.notDashboard
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

    /// Adds this connection's headers to a request for its own origin. A header the request
    /// already carries, such as the JSON content type or the gateway subprotocols, keeps
    /// its built-in value.
    private func prepared(_ request: URLRequest) -> URLRequest {
        guard !headers.values.isEmpty, let url = request.url, HermesHeaders.isSameOrigin(url, as: connection.address) else { return request }
        var request = request
        for header in headers.values where request.value(forHTTPHeaderField: header.sanitizedName) == nil {
            request.setValue(header.sanitizedValue, forHTTPHeaderField: header.sanitizedName)
        }
        return request
    }

    private func checkCurrent() throws {
        if isRetired { throw BotFailure.stale }
    }
}

/// Gives every consumer of the active server's saved Bot connection the same
/// `HermesConnection`, and with it the same gateway socket. It keeps one entry, keyed by
/// configured server and connection UUID, and holds it weakly, so the connection lives
/// only while a consumer does. A request for another server or UUID, or for the same UUID
/// with a new address, account or password (the connection form can keep a UUID across
/// those), retires the old connection first, so no cookie, sign-in, socket or late reply
/// crosses servers, accounts or credentials.
/// Credentials are compared on the live connection and never kept in a key.
@MainActor final class HermesConnections {
    static let shared = HermesConnections()
    private var server: String?
    private weak var current: HermesConnection?

    func connection(for saved: BotConnection, server: URL) -> HermesConnection {
        if let current, self.server == server.absoluteString, current.adopt(saved) { return current }
        current?.retire()
        let fresh = HermesConnection(connection: saved)
        current = fresh
        self.server = server.absoluteString
        return fresh
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

/// Request headers for one direct-Hermes origin, admitted by the policy the host needs:
/// no name the transport owns (the URL loading system, the cookie jar and the gateway
/// handshake set those), no name Hermes reads for its own checks (`Origin` for the
/// gateway upgrade, `X-Forwarded-Prefix` for the session cookie's path,
/// `X-Hermes-Session-Token`), and no `Bearer` authorization, which Hermes also reads as
/// its session token. Any other `Authorization` value passes, such as Cloudflare Access's
/// single-header JSON service token. Hermex has no editor or storage for these yet:
/// production passes `.none`, and the webui's custom headers are never a source.
struct HermesHeaders: Sendable {
    enum Rejection: Error, Equatable { case malformed(String), reserved(String), bearer }

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
