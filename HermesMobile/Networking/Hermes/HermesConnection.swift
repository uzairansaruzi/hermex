import Foundation
import OSLog

/// One direct-Hermes connection: one ephemeral cookie jar, one sign-in, the path
/// every Bot HTTP request and gateway upgrade is sent through, and the one gateway socket
/// its Bot screens share (`gateway`). `HermesConnections` gives every consumer of a
/// server's saved connection (the Bot screens' `BotClient`s and push provisioning's
/// `BotDashboardClient`) the same instance, so they sign in once and share one socket.
/// Setup and dev auto-login probe unsaved credentials on their own.
///
/// Sign-in is single-flight: it reads the public `/api/status`, refuses a release older
/// than `HermesCompatibility.minimumVersion` and checks the install identity before the
/// password goes out, then verifies the identity the host returns. A password connection
/// signs in with its username and password, and the host's session cookie authenticates what
/// follows. A browser sign-in's connection (`BotConnection.oauth`, #708) trades its refresh
/// token for an access token instead, held in memory only and sent as `Authorization: Bearer`
/// on every signed-in request; the host rotates the refresh token each time, and the new one
/// is saved (`onRefreshTokenRotated`) before the access token is used. A dashboard with no
/// sign-in (`HermesSignInMethod.open`, #1314) is signed in to with the session token its page
/// carries, read again at every sign-in, also held in memory only and sent as
/// `X-Hermes-Session-Token`; a host restart replaces it, which the 401 below recovers from.
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
        /// does a Task's Run Now, which the host answers once the run has finished (#1041), and
        /// Listen's speech, whose first request can install the host's TTS engine (#1072), and a
        /// session export and import, which carry every message (#1048, #1051).
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
    /// Every runtime a `session.resume` on this connection reached, or a `session.branch` made
    /// (#1051), and no `session.close` here ended (#1048), recorded by `gateway`. The host keeps a runtime after its screen leaves,
    /// and refuses to delete a session any runtime holds, so a delete closes this phone's own
    /// idle one first. It lasts as long as this connection, past any one socket, as the host's
    /// runtimes do; one the host has since reaped stays here and is never in
    /// `session.active_list` again.
    private(set) var attachedRuntimes: Set<String> = []
    /// Each Profile's `keepPlatformNote` check on this connection, by Profile: one that found the
    /// note current or wrote it, or one still running, which a later call waits for. A failed
    /// check is dropped, so each Profile is read once per sign-in unless a read fails.
    private var platformNoteChecks: [String: Task<Bool, Never>] = [:]
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
    /// What every signed-in request carries besides the cookie jar.
    private enum Credential {
        /// A browser sign-in's access token from the last refresh, sent as `Authorization: Bearer`.
        case accessToken(String)
        /// An open dashboard's session token from its page (`HermesREST.pageToken(in:)`), sent as
        /// `X-Hermes-Session-Token`, never `Authorization`, which a proxy's basic auth may hold.
        case pageToken(String)
    }
    /// Nil for a password connection, and until a browser sign-in's first refresh or an open
    /// dashboard's page read. A 401 or a failed sign-in drops it, so the next sign-in refreshes
    /// or reads the page again.
    private var credential: Credential?
    /// Counts sign-ins, so a 401 can tell whether another consumer has already recovered.
    private var epoch = 0
    private var signInTask: Task<Void, Error>?
    private(set) var isRetired = false
    /// Called with `.rejected(401)` when the login step answers 401, with `.signInChanged`
    /// when the saved sign-in no longer matches the host's (`BotConnection.hasNoCredentials`), and
    /// with `.signInExpired` when the host refuses a browser sign-in's refresh token, before the
    /// failure reaches any consumer, including the re-sign-in a signed-in 401 starts.
    /// `HermesConnections` sets it so `AuthManager` can sign a Hermes server out (#899); nothing
    /// here remembers it.
    var onLoginRejected: ((BotFailure) -> Void)?
    /// Called with the refresh token the host rotated the sent one into, before the new access
    /// token is used, even when this connection was retired meanwhile: the host has already
    /// retired the sent one. `HermesConnections` saves it.
    var onRefreshTokenRotated: ((String) -> Void)?
    /// Asked before each refresh for a refresh token saved since this connection last saw one,
    /// such as the first one or one a Move to Hermes connection rotated (#1265), to send instead
    /// of its own; nil keeps its own. `HermesConnections` answers from the Keychain, after waiting
    /// for a refresh a retired connection on the same server still has in flight; a Keychain
    /// read that fails throws, so the sign-in fails before any token is spent.
    var savedRefreshToken: (() async throws -> String?)?
    /// The refresh in flight, which retiring this connection never cancels: once the host has
    /// the request it may already have rotated the token, and only its reply saves the new one.
    private(set) var refreshInFlight: Task<String, Error>?
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

    /// The gateway's report that a `session.resume` reached `runtime`.
    func noteAttached(_ runtime: String) {
        attachedRuntimes.insert(runtime)
    }

    /// Keeps `HermesREST.platformNote` as `profile`'s `platform_hints.hermex.append` (#1278), the
    /// note the host gives an agent built for a session that runs as `HermesCall.source`. Reads
    /// the config once per Profile on this connection and writes only a missing or changed note;
    /// a call while that check runs waits for it, so no chat's agent is built before the note is
    /// written. A failure only lets the next call try again: a chat opens without the note rather
    /// than not at all.
    func keepPlatformNote(profile: String) async {
        guard !profile.isEmpty else { return }
        let check = platformNoteChecks[profile] ?? Task { [weak self] in
            await self?.writePlatformNoteIfChanged(profile: profile) ?? false
        }
        platformNoteChecks[profile] = check
        if await !check.value, platformNoteChecks[profile] == check { platformNoteChecks[profile] = nil }
    }

    /// Whether `profile`'s config holds the current note, after writing it when it was missing or
    /// different.
    private func writePlatformNoteIfChanged(profile: String) async -> Bool {
        do {
            let config = try JSONDecoder().decode(BotJSON.self, from: try await data(.config(profile: profile)))
            if config["platform_hints"][HermesCall.source]["append"].text != HermesREST.platformNote {
                _ = try await data(.setPlatformNote(profile: profile))
            }
            return true
        } catch {
            return false
        }
    }

    /// The gateway's report that a `session.close` here ended `runtime`.
    func noteClosed(_ runtime: String) {
        attachedRuntimes.remove(runtime)
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
                guard let method = HermesSignInMethod(status) else { throw BotFailure.unsupported }
                if method == .open {
                    guard connection.hasNoCredentials else { throw BotFailure.signInChanged }
                    step = "page"
                    let page = try await Self.send(prepared(try HermesREST.dashboardPage.request(base: connection.address)),
                                                   on: session, accepting: 200..<201, redirectGuard: redirectGuard)
                    try checkCurrent()
                    guard let token = HermesREST.pageToken(in: page) else { throw BotFailure.unsupported }
                    credential = .pageToken(token)
                    // Any gated read proves the token. At the 0.21.5 pin `/api/auth/me` answers 401
                    // in this mode, since only the password gate sets a session.
                    step = "token"
                    _ = try await decoded(.profilesActive, on: session)
                    try checkCurrent()
                } else if let account = connection.oauth {
                    if credential == nil {
                        step = "refresh"
                        try await refresh(on: session)
                    }
                    step = "identity"
                    let identity = try await decoded(.identity, on: session)
                    try checkCurrent()
                    guard identity["provider"].text == account.provider, identity["user_id"].text == account.userID else {
                        throw BotFailure.wrongIdentity
                    }
                } else {
                    step = "login"
                    guard !connection.hasNoCredentials else { throw BotFailure.signInChanged }
                    // A browser-only host signs in from its form (`HermesBrowserSignIn`), never here.
                    guard status["auth_providers"].list?.contains(.string("basic")) == true else { throw BotFailure.browserSignIn }
                    _ = try await decoded(.login(username: connection.username, password: connection.password), on: session)
                    try checkCurrent()
                    step = "identity"
                    let identity = try await decoded(.identity, on: session)
                    try checkCurrent()
                    guard identity["provider"].text == "basic" else { throw BotFailure.wrongIdentity }
                }
                // Trust on first use, in memory only: a later sign-in here must reach the same install.
                if connection.installID == nil { connection.installID = serverInstallID }
                isSignedIn = true
                epoch += 1
                let release = serverVersion ?? "unreported"
                HermesConnectionLog.logger.notice("c\(self.serial, privacy: .public): signed in, release \(release, privacy: .public)")
            } catch {
                credential = nil
                // A retired connection has already logged that it was retired.
                if !isRetired {
                    let reason = HermesConnectionLog.reason(error), failedStep = step
                    HermesConnectionLog.logger.error("c\(self.serial, privacy: .public): sign-in failed at \(failedStep, privacy: .public): \(reason, privacy: .public)")
                    switch (failedStep, error as? BotFailure) {
                    case ("login", .rejected(401)?): onLoginRejected?(.rejected(401))
                    case (_, .signInChanged?): onLoginRejected?(.signInChanged)
                    case ("refresh", .signInExpired?): onLoginRejected?(.signInExpired)
                    default: break
                    }
                }
                throw error
            }
        }
        signInTask = attempt
        return attempt
    }

    /// Finishes a browser sign-in on a connection not yet saved (#708): trades the loopback
    /// `code` and its PKCE `verifier` for tokens at `/auth/native/token`, makes this a
    /// browser sign-in's connection (`connection.oauth`, with the host's user id as its
    /// username and no password), and signs in with the access token, which checks the
    /// release, the install and the identity. The caller saves `connection`. A refused
    /// code (400) is `.browserSignInFailed`.
    func signIn(browserCode code: String, verifier: String) async throws {
        try checkCurrent()
        let request = prepared(try HermesREST.nativeToken(code: code, verifier: verifier).request(base: connection.address))
        let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
        try checkCurrent()
        switch response.statusCode {
        case 200: break
        case 400: throw BotFailure.browserSignInFailed
        case let code: throw BotFailure.rejected(code)
        }
        let tokens = try JSONDecoder().decode(BotJSON.self, from: data)
        guard let access = tokens["access_token"].text, !access.isEmpty,
              let refresh = tokens["refresh_token"].text, !refresh.isEmpty,
              let provider = tokens["provider"].text, !provider.isEmpty,
              let user = tokens["user_id"].text, !user.isEmpty else { throw BotFailure.unsupported }
        let old = connection
        connection = BotConnection(id: old.id, name: old.name, address: old.address, username: user, password: "",
                                   hermesVersion: old.hermesVersion, installID: old.installID, headers: old.headers,
                                   oauth: HermesOAuth(provider: provider, userID: user, refreshToken: refresh))
        isSignedIn = false
        credential = .accessToken(access)
        try await signIn()
    }

    /// Trades the refresh token for an access token and the rotated refresh token, which is
    /// saved before the access token is kept. The exchange and the save run in
    /// `refreshInFlight`, which a retired connection's cancelled sign-in leaves to finish.
    /// 401 means the host no longer accepts the refresh token (`.signInExpired`); any other
    /// refusal is `.rejected` and leaves the token for the next sign-in.
    private func refresh(on session: URLSession) async throws {
        if let source = savedRefreshToken {
            let saved = try await source()
            try checkCurrent()
            if let saved { connection.oauth?.refreshToken = saved }
        }
        guard let account = connection.oauth else { throw BotFailure.unsupported }
        let sent = account.refreshToken
        let request = prepared(try HermesREST.nativeRefresh(refreshToken: sent, provider: account.provider)
            .request(base: connection.address))
        let redirectGuard = self.redirectGuard
        let rotation = Task { () throws -> String in
            let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
            switch response.statusCode {
            case 200: break
            case 401: throw BotFailure.signInExpired
            case let code: throw BotFailure.rejected(code)
            }
            let tokens = try JSONDecoder().decode(BotJSON.self, from: data)
            guard let access = tokens["access_token"].text, !access.isEmpty else { throw BotFailure.unsupported }
            if let rotated = tokens["refresh_token"].text, !rotated.isEmpty, rotated != sent {
                self.connection.oauth?.refreshToken = rotated
                self.onRefreshTokenRotated?(rotated)
            }
            return access
        }
        refreshInFlight = rotation
        defer { refreshInFlight = nil }
        let access = try await rotation.value
        try checkCurrent()
        credential = .accessToken(access)
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
    /// refused cron or Kanban write (#1044) or a session title (#1048). A 401 still signs in
    /// again and resends once, as `data` does; `validateDispatch` is as in `authorized`.
    func reply(_ rest: HermesREST, deadline: Deadline = .standard,
               validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> (body: Data, status: Int) {
        try await reply(try rest.request(base: connection.address), deadline: deadline, validateDispatch: validateDispatch)
    }

    /// `reply` for a request built off the main actor from a `HermesREST` case, such as
    /// dictation's base64 upload (#1071).
    func reply(_ request: URLRequest, deadline: Deadline = .standard,
               validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> (body: Data, status: Int) {
        let redirectGuard = self.redirectGuard
        return try await authorized(request, deadline: deadline, validateDispatch: validateDispatch) { request, session in
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
            let value = try await perform(bearing(request), session)
            try checkCurrent()
            return value
        } catch BotFailure.rejected(401) {
            try checkCurrent()
            // The first reply to show the session expired drops it; later ones join the same sign-in,
            // even one still checking a new credential, which a late reply must not drop.
            if epoch == sentEpoch, isSignedIn { isSignedIn = false; credential = nil }
            try await signIn(deadline: deadline)
            try validateDispatch?()
            let value = try await perform(bearing(request), session)
            try checkCurrent()
            return value
        }
    }

    /// Returns the gateway upgrade, presenting a single-use ticket minted for it or an open
    /// dashboard's page token.
    func gatewayUpgrade() async throws -> URLRequest {
        try await upgrade { try HermesREST.gatewayUpgrade(base: connection.address, pass: $0) }
    }

    /// Returns `board`'s Kanban event socket upgrade, with this connection's headers (#1045),
    /// presenting a single-use ticket, never the gateway's, or an open dashboard's page token.
    func kanbanEventsUpgrade(board: String, since: Int) async throws -> URLRequest {
        try await upgrade {
            try HermesREST.kanbanEventsUpgrade(base: connection.address, board: board, since: since, pass: $0)
        }
    }

    /// Returns the upgrade `build` makes for a fresh pass, with this connection's headers. Either
    /// pass is preceded by a signed-in read, so a 401 signs in again first: minting the ticket,
    /// or for a page token a gated read, since a refused upgrade can't tell a token a host
    /// restart replaced from any other refusal.
    private func upgrade(_ build: (HermesREST.UpgradePass) throws -> URLRequest) async throws -> URLRequest {
        do {
            try await signIn()
            if case .pageToken = credential {
                _ = try await data(.profilesActive)
                if case .pageToken(let token)? = credential { return prepared(try build(.pageToken(token))) }
            }
            let ticket = try JSONDecoder().decode(BotJSON.self, from: try await data(.ticket))
            guard let token = ticket["ticket"].text, !token.isEmpty else { throw BotFailure.unsupported }
            return prepared(try build(.ticket(token)))
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

    /// Whether `saved` is still this connection: the same UUID, address, account, password,
    /// headers and browser sign-in account, and no conflicting install id. A newly
    /// backfilled install id is taken.
    func adopt(_ saved: BotConnection) -> Bool {
        guard !isRetired, saved.id == connection.id, saved.address == connection.address,
              saved.username == connection.username, saved.password == connection.password,
              (saved.headers ?? []) == (connection.headers ?? []) else { return false }
        if let live = connection.installID, let stored = saved.installID, live != stored { return false }
        // A browser sign-in is the same account whatever its refresh token, which only this
        // connection's copy is sure to hold.
        guard saved.oauth?.provider == connection.oauth?.provider, saved.oauth?.userID == connection.oauth?.userID else {
            return false
        }
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
        credential = nil
        signInTask?.cancel()
        signInTask = nil
        liveGateway?.retire()
    }

    /// The login, identity and token reads, which run before there is a session.
    private func decoded(_ rest: HermesREST, on session: URLSession) async throws -> BotJSON {
        let data = try await Self.send(bearing(prepared(try rest.request(base: connection.address))), on: session,
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
    /// a same-host redirect from http to https is not a proxy. A 3xx reply is a redirect the
    /// guard refused, because it would have carried a body off the origin, and is `.blocked` too.
    private nonisolated static func exchange(_ request: URLRequest, on session: URLSession,
                                             redirectGuard: CrossOriginHeaderStripper) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
        guard let response = response as? HTTPURLResponse else { throw BotFailure.transport }
        if let final = response.url?.host, final.lowercased() != request.url?.host?.lowercased() { throw BotFailure.blocked }
        if (300..<400).contains(response.statusCode) { throw BotFailure.blocked }
        return (data, response)
    }

    private func prepared(_ request: URLRequest) -> URLRequest {
        headers.applied(to: request, origin: connection.address)
    }

    /// `request` with the connection's credential, when there is one. The socket upgrades
    /// never carry it as a header: they present a ticket it minted, or the page token in the URL.
    private func bearing(_ request: URLRequest) -> URLRequest {
        var request = request
        switch credential {
        case .accessToken(let token)?: request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .pageToken(let token)?: request.setValue(token, forHTTPHeaderField: HermesHeaders.sessionTokenName)
        case nil: break
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
/// with a new address, account, password or headers (the connection form can keep a UUID
/// across those), retires the old connection first, so no cookie, sign-in, socket or late
/// reply crosses servers, accounts, credentials or headers.
/// Credentials and headers are compared on the live connection and never kept in a key.
/// A browser sign-in's connection refreshes from the refresh token saved in the Keychain, not
/// the one in `saved`, and saves each rotated one there (#708) (`keepRefreshTokens`). So does
/// one made beside the current one (`ownConnection`), whose rotations the current one then
/// refreshes from.
@MainActor final class HermesConnections {
    static let shared = HermesConnections()
    /// Told which configured server's sign-in the host refused: `.rejected(401)` for a
    /// saved username or password at the login step, `.signInExpired` for a browser
    /// sign-in's refresh token. `AuthManager` sets it and signs that server out when it is
    /// the active Hermes server (#899).
    var onSignInRejected: ((URL, BotFailure) -> Void)?
    private let configuration: () -> URLSessionConfiguration
    private let store: BotConnectionStore
    private var server: String?
    private weak var current: HermesConnection?
    /// The refresh each server's last retired connection still had in flight, so the next
    /// refresh there, by any connection, reads the token it rotated to, not the one it spent.
    private var retiredRefreshes: [String: Task<String, Error>] = [:]

    /// `configuration` makes each new connection's URL session setup, with a cookie jar of
    /// its own; tests script the host with it. `keychain` holds the saved records whose
    /// refresh tokens the connections read and rotate.
    init(configuration: @escaping () -> URLSessionConfiguration = { .ephemeral },
         keychain: any KeychainStoring = KeychainStore()) {
        self.configuration = configuration
        store = BotConnectionStore(keychain: keychain)
    }

    func connection(for saved: BotConnection, server: URL) -> HermesConnection {
        if let current, self.server == server.absoluteString, current.adopt(saved) { return current }
        retireCurrent()
        let fresh = HermesConnection(connection: saved, configuration: configuration())
        fresh.onLoginRejected = { [weak self] failure in self?.onSignInRejected?(server, failure) }
        if saved.oauth != nil { keepRefreshTokens(of: fresh, server: server) }
        current = fresh
        self.server = server.absoluteString
        return fresh
    }

    /// A connection to `saved` of the caller's own, beside `server`'s current one, which it
    /// never replaces or retires: Move to Hermes's destination (#1265). A browser sign-in's
    /// keeps refresh tokens as the current one does. `retire(own:server:)` ends it.
    func ownConnection(for saved: BotConnection, server: URL) -> HermesConnection {
        let own = HermesConnection(connection: saved, configuration: configuration())
        if saved.oauth != nil { keepRefreshTokens(of: own, server: server) }
        return own
    }

    /// Ends a connection `ownConnection` made, leaving any refresh it has in flight for the
    /// next connection on `server` to wait for.
    func retire(own: HermesConnection, server: URL) {
        if let task = own.refreshInFlight { retiredRefreshes[server.absoluteString] = task }
        own.retire()
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
        retireCurrent()
        self.current = nil
    }

    private func retireCurrent() {
        guard let current else { return }
        if let task = current.refreshInFlight, let server { retiredRefreshes[server] = task }
        current.retire()
    }

    /// Starts each of `fresh`'s refreshes from the token saved for it when that changed since
    /// it last looked, once any refresh a retired connection on `server` still has in flight
    /// has saved its own, and saves each rotated one. That refresh is looked up at each refresh,
    /// not when `fresh` is made, since a connection beside it can be retired later (#1265).
    /// A save only replaces the token this connection last saw saved, so a record removed or
    /// signed in again keeps what it has, and a failed save is retried at the next rotation,
    /// from the token in memory.
    private func keepRefreshTokens(of fresh: HermesConnection, server: URL) {
        let store = store, id = fresh.connection.id, serial = fresh.serial
        var saved: String?
        fresh.savedRefreshToken = { [weak self] in
            _ = try? await self?.retiredRefreshes[server.absoluteString]?.value
            guard let record = try store.load(server: server), record.id == id,
                  let token = record.oauth?.refreshToken, token != saved else { return nil }
            saved = token
            return token
        }
        fresh.onRefreshTokenRotated = { rotated in
            guard let previous = saved else { return }
            do {
                try store.saveRotatedRefreshToken(rotated, replacing: previous, connection: id, server: server)
                saved = rotated
            } catch {
                HermesConnectionLog.logger.error("c\(serial, privacy: .public): rotated refresh token not saved: \(HermesConnectionLog.reason(error), privacy: .public)")
            }
        }
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
/// single-header JSON service token, except on a browser sign-in's connection (#708), whose
/// own bearer is its `Authorization`: there Access takes its two-header form. The only source is the Hermes connection's own
/// record (`BotConnection.headers`, edited as Connection Headers in its form), never the
/// webui's custom headers.
struct HermesHeaders: Sendable {
    enum Rejection: Error, Equatable, LocalizedError {
        case malformed(String), reserved(String), bearer
        /// Any `Authorization` header on a connection that signs in through the browser.
        case authorization

        /// Shown under the connection form's Connection Headers row.
        var errorDescription: String? {
            switch self {
            case .bearer:
                return String(localized: "Hermes reads Authorization: Bearer as its own sign-in and refuses it. Remove this header to connect.")
            case .authorization:
                return String(localized: "This server signs in through the browser, so Hermex sends its own Authorization header. Remove this header to connect. For Cloudflare Access, use the CF-Access-Client-Id and CF-Access-Client-Secret headers instead.")
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
    /// The header an open dashboard reads its page's session token from (#1314).
    static let sessionTokenName = "X-Hermes-Session-Token"

    let values: [CustomHeader]

    /// Admits `headers` for a connection, which `signsInWithBrowser` when it sends its own
    /// bearer (`BotConnection.oauth`).
    init(_ headers: [CustomHeader], signsInWithBrowser: Bool = false) throws {
        for header in headers {
            let name = header.sanitizedName.lowercased()
            guard header.isApplicable else { throw Rejection.malformed(header.sanitizedName) }
            guard !Self.reserved.contains(name), !name.hasPrefix("sec-websocket-") else {
                throw Rejection.reserved(header.sanitizedName)
            }
            let scheme = header.sanitizedValue.split(whereSeparator: \.isWhitespace).first?.lowercased()
            if name == "authorization", scheme == "bearer" { throw Rejection.bearer }
            if name == "authorization", signsInWithBrowser { throw Rejection.authorization }
        }
        values = headers
    }

    private init(admitted: [CustomHeader]) { values = admitted }

    /// The headers `saved`'s requests carry. A saved list the policy now refuses sends
    /// none: the connection form shows why under its Connection Headers row and keeps
    /// Connect off until it is fixed.
    init(saved: BotConnection) {
        self = (try? HermesHeaders(saved.headers ?? [], signsInWithBrowser: saved.oauth != nil)) ?? .none
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

    /// The task delegate that drops these headers, and an open dashboard's session token, from
    /// a redirect that leaves `origin`, such as an access proxy's bounce to its sign-in page.
    func redirectGuard(for origin: URL) -> CrossOriginHeaderStripper {
        let admitted = values + [CustomHeader(name: Self.sessionTokenName)]
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
