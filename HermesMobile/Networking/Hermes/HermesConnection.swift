import Foundation
import OSLog

@MainActor final class HermesConnection {
    enum Deadline {
        case standard
        case provisioning
    }

    private(set) var connection: BotConnection
    private(set) var serverVersion: String?
    private(set) var serverInstallID: String?
    private(set) var servesWebapp = false
    private(set) var unavailableMethods: Set<String> = []
    private(set) var attachedRuntimes: Set<String> = []
    private(set) var lastAttempt: HermesAttemptRecord?
    private(set) var attemptCount = 0
    private var platformNoteChecks: [String: Task<Bool, Never>] = [:]
    let session: URLSession
    let provisioningSession: URLSession
    private let headers: HermesHeaders
    private let redirectGuard: CrossOriginHeaderStripper
    private let gatewayOptions: HermesGateway.Options
    private(set) weak var liveGateway: HermesGateway?
    private var profileGateways: [String: WeakGateway] = [:]
    private struct WeakGateway { weak var gateway: HermesGateway? }
    private var consumerCount = 0
    private var isSignedIn = false
    private enum Credential {
        case accessToken(String)
        case pageToken(String)
    }
    private var credential: Credential?
    private var epoch = 0
    private var signInTask: Task<Void, Error>?
    private(set) var isRetired = false
    var onLoginRejected: ((BotFailure) -> Void)?
    var onSignedIn: ((HermesGatewayKind) -> Void)?
    var onRefreshTokenRotated: ((String) -> Void)?
    var savedRefreshToken: (() async throws -> String?)?
    private(set) var refreshInFlight: Task<String, Error>?
    let serial: Int
    private static var connectionCount = 0

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

    var gateway: HermesGateway {
        if let liveGateway { return liveGateway }
        let fresh = HermesGateway(http: self, options: gatewayOptions)
        liveGateway = fresh
        return fresh
    }

    func gateway(profile: String) -> HermesGateway {
        guard servesWebapp else { return gateway }
        if let live = profileGateways[profile]?.gateway { return live }
        let fresh = HermesGateway(http: self, options: gatewayOptions, profile: profile)
        profileGateways[profile] = WeakGateway(gateway: fresh)
        return fresh
    }

    func opensSharedSocket() async -> Bool {
        let probe = BotClient(http: self)
        defer { probe.close() }
        return (try? await probe.connect()) != nil
    }

    var liveGateways: [HermesGateway] {
        ([liveGateway] + profileGateways.values.map(\.gateway)).compactMap { $0 }
    }

    func makeConsumerID() -> Int {
        consumerCount += 1
        return consumerCount
    }

    func noteUnavailable(_ method: String) {
        unavailableMethods.insert(method)
    }

    func noteAttached(_ runtime: String) {
        attachedRuntimes.insert(runtime)
    }

    func keepPlatformNote(profile: String) async {
        guard !profile.isEmpty else { return }
        let check = platformNoteChecks[profile] ?? Task { [weak self] in
            await self?.writePlatformNoteIfChanged(profile: profile) ?? false
        }
        platformNoteChecks[profile] = check
        if await !check.value, platformNoteChecks[profile] == check { platformNoteChecks[profile] = nil }
    }

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

    func noteClosed(_ runtime: String) {
        attachedRuntimes.remove(runtime)
    }

    func signIn(deadline: Deadline = .standard) async throws {
        try checkCurrent()
        if isSignedIn { return }
        let attempt = signInTask ?? beginSignIn(on: session(for: deadline))
        do { try await attempt.value } catch { try checkCurrent(); throw error }
        try checkCurrent()
    }

    private func beginSignIn(on session: URLSession) -> Task<Void, Error> {
        let record = beginAttempt()
        let attempt = Task {
            defer { signInTask = nil }
            var step = "status"
            var stage = HermesAttemptRecord.Stage.status
            do {
                let status = try await publicStatus(on: session)
                try checkCurrent()
                serverVersion = status["version"].text
                serverInstallID = BotConnection.installID(in: status)
                servesWebapp = false
                update(record) { $0.reportedRelease = self.serverVersion }
                if let version = serverVersion, !HermesCompatibility.isSupported(version) { throw BotFailure.outdated(version) }
                try connection.requireSameInstall(serverInstallID)
                guard let methods = HermesSignInMethod.offered(by: status) else { throw BotFailure.unsupported }
                update(record) { $0[.status] = .passed }
                stage = .signIn
                if methods == [.open] {
                    guard connection.hasNoCredentials else { throw BotFailure.signInChanged }
                    step = "page"
                    let page = try await Self.send(prepared(try HermesREST.dashboardPage.request(base: connection.address)),
                                                   on: session, accepting: 200..<201, redirectGuard: redirectGuard)
                    try checkCurrent()
                    guard let token = HermesREST.pageToken(in: page) else {
                        throw HermesREST.withholdsPageToken(page) ? BotFailure.gatewayListener : BotFailure.unsupported
                    }
                    credential = .pageToken(token)
                    step = "token"
                    _ = try await decoded(.profilesActive, on: session)
                    try checkCurrent()
                    update(record) { $0[.signIn] = .passed }
                } else if let account = connection.oauth {
                    if credential == nil {
                        step = "refresh"
                        try await refresh(on: session)
                    }
                    update(record) { $0[.signIn] = .passed }
                    step = "identity"; stage = .identity
                    let identity = try await decoded(.identity, on: session)
                    try checkCurrent()
                    guard identity["provider"].text == account.provider, identity["user_id"].text == account.userID else {
                        throw BotFailure.wrongIdentity
                    }
                } else {
                    step = "login"
                    guard !connection.hasNoCredentials else { throw BotFailure.signInChanged }
                    guard status["auth_providers"].list?.contains(.string("basic")) == true else { throw BotFailure.browserSignIn }
                    _ = try await decoded(.login(username: connection.username, password: connection.password), on: session)
                    try checkCurrent()
                    update(record) { $0[.signIn] = .passed }
                    step = "identity"; stage = .identity
                    let identity = try await decoded(.identity, on: session)
                    try checkCurrent()
                    guard identity["provider"].text == "basic" else { throw BotFailure.wrongIdentity }
                }
                if serverInstallID == nil {
                    step = "install"
                    serverInstallID = BotConnection.installID(in: try await decoded(.status, on: session))
                    try checkCurrent()
                    servesWebapp = serverInstallID != nil
                    try connection.requireSameInstall(serverInstallID)
                }
                if stage == .identity { update(record) { $0[.identity] = .passed } }
                if connection.installID == nil { connection.installID = serverInstallID }
                isSignedIn = true
                epoch += 1
                onSignedIn?(servesWebapp ? .webapp : .dashboard)
                let release = serverVersion ?? "unreported"
                HermesConnectionLog.logger.notice("c\(self.serial, privacy: .public): signed in, release \(release, privacy: .public)")
            } catch {
                credential = nil
                update(record) { $0[stage] = .failed(.init(error)) }
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

    func signIn(browserCode code: String, verifier: String) async throws {
        try checkCurrent()
        let record = beginAttempt()
        let access: String, account: HermesOAuth
        do {
            let request = prepared(try HermesREST.nativeToken(code: code, verifier: verifier).request(base: connection.address))
            let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
            try checkCurrent()
            switch response.statusCode {
            case 200: break
            case 400: throw BotFailure.browserSignInFailed
            case let code: throw BotFailure.rejected(code)
            }
            let tokens = try JSONDecoder().decode(BotJSON.self, from: data)
            guard let token = tokens["access_token"].text, !token.isEmpty,
                  let refresh = tokens["refresh_token"].text, !refresh.isEmpty,
                  let provider = tokens["provider"].text, !provider.isEmpty,
                  let user = tokens["user_id"].text, !user.isEmpty else { throw BotFailure.unsupported }
            access = token
            account = HermesOAuth(provider: provider, userID: user, refreshToken: refresh)
        } catch {
            update(record) { $0[.signIn] = .failed(.init(error)) }
            throw error
        }
        let old = connection
        connection = BotConnection(id: old.id, name: old.name, address: old.address, username: account.userID, password: "",
                                   hermesVersion: old.hermesVersion, installID: old.installID, headers: old.headers,
                                   oauth: account)
        isSignedIn = false
        credential = .accessToken(access)
        try await signIn()
    }

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

    func status() async throws -> BotJSON {
        try checkCurrent()
        let record = beginAttempt()
        do {
            let status = try await publicStatus(on: session, onlyHostRefusalIs400: true)
            update(record) { $0[.status] = .passed; $0.reportedRelease = status["version"].text }
            return status
        } catch {
            update(record) { $0[.status] = .failed(.init(error)) }
            throw error
        }
    }

    func answersStatus() async -> Bool {
        guard !isRetired else { return false }
        return (try? await publicStatus(on: session)) != nil
    }

    func publicData(_ rest: HermesREST) async throws -> Data {
        try checkCurrent()
        let data = try await Self.send(prepared(try rest.request(base: connection.address)), on: session,
                                       accepting: 200..<201, redirectGuard: redirectGuard)
        try checkCurrent()
        return data
    }

    func data(_ rest: HermesREST, deadline: Deadline = .standard, accepting accepted: Range<Int> = 200..<201,
              validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> Data {
        let redirectGuard = self.redirectGuard
        return try await authorized(try rest.request(base: connection.address), deadline: deadline,
                                    validateDispatch: validateDispatch) { request, session in
            try await Self.send(request, on: session, accepting: accepted, redirectGuard: redirectGuard)
        }
    }

    func reply(_ rest: HermesREST, deadline: Deadline = .standard,
               validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> (body: Data, status: Int) {
        try await reply(try rest.request(base: connection.address), deadline: deadline, validateDispatch: validateDispatch)
    }

    func reply(_ request: URLRequest, deadline: Deadline = .standard,
               validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> (body: Data, status: Int) {
        let redirectGuard = self.redirectGuard
        return try await authorized(request, deadline: deadline, validateDispatch: validateDispatch) { request, session in
            let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
            if response.statusCode == 401 { throw BotFailure.rejected(401) }
            return (data, response.statusCode)
        }
    }

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
            if epoch == sentEpoch, isSignedIn { isSignedIn = false; credential = nil }
            try await signIn(deadline: deadline)
            try validateDispatch?()
            let value = try await perform(bearing(request), session)
            try checkCurrent()
            return value
        }
    }

    func gatewayUpgrade(profile: String? = nil) async throws -> URLRequest {
        try await upgrade(recordsLiveStages: true, ticket: profile.map { .profileTicket(profile: $0) } ?? .ticket) {
            try HermesREST.gatewayUpgrade(base: connection.address, pass: $0)
        }
    }

    func kanbanEventsUpgrade(board: String, since: Int) async throws -> URLRequest {
        try await upgrade(recordsLiveStages: false) {
            try HermesREST.kanbanEventsUpgrade(base: connection.address, board: board, since: since, pass: $0)
        }
    }

    func screenUpgrade(ticket: String) throws -> URLRequest {
        prepared(try HermesREST.screenUpgrade(base: connection.address, ticket: ticket))
    }

    func screenPluginUpgrade(streamTicket: String) async throws -> URLRequest {
        try await upgrade(recordsLiveStages: false) {
            try HermesREST.screenPluginUpgrade(base: connection.address, streamTicket: streamTicket, pass: $0)
        }
    }

    private func upgrade(recordsLiveStages: Bool, ticket route: HermesREST = .ticket,
                         _ build: (HermesREST.UpgradePass) throws -> URLRequest) async throws -> URLRequest {
        do {
            try await signIn()
            if recordsLiveStages { update(attemptCount) { $0[.liveAuthorization] = .notChecked; $0[.liveHandshake] = .notChecked } }
            func pass() async throws -> HermesREST.UpgradePass {
                if case .pageToken = credential {
                    _ = try await data(.profilesActive)
                    if case .pageToken(let token)? = credential { return .pageToken(token) }
                }
                let ticket = try JSONDecoder().decode(BotJSON.self, from: try await data(route))
                guard let token = ticket["ticket"].text, !token.isEmpty else { throw BotFailure.unsupported }
                return .ticket(token)
            }
            let upgrade = prepared(try build(try await pass()))
            if recordsLiveStages { update(attemptCount) { $0[.liveAuthorization] = .passed } }
            return upgrade
        } catch {
            if !isRetired, isSignedIn {
                let reason = HermesConnectionLog.reason(error)
                HermesConnectionLog.logger.error("c\(self.serial, privacy: .public): sign-in failed at ticket: \(reason, privacy: .public)")
                if recordsLiveStages { update(attemptCount) { $0[.liveAuthorization] = .failed(.init(error)) } }
            }
            throw error
        }
    }

    func noteLiveHandshake(_ error: Error?, attempt: Int) {
        update(attempt) { $0[.liveHandshake] = error.map { .failed(.init($0)) } ?? .passed }
    }

    private func beginAttempt() -> Int {
        attemptCount += 1
        lastAttempt = HermesAttemptRecord()
        return attemptCount
    }

    private func update(_ attempt: Int, _ change: (inout HermesAttemptRecord) -> Void) {
        guard attempt == attemptCount, !isRetired, var record = lastAttempt else { return }
        change(&record)
        lastAttempt = record
    }

    func adopt(_ saved: BotConnection) -> Bool {
        guard !isRetired, saved.id == connection.id, saved.address == connection.address,
              saved.username == connection.username, saved.password == connection.password,
              (saved.headers ?? []) == (connection.headers ?? []) else { return false }
        if let live = connection.installID, let stored = saved.installID, live != stored { return false }
        guard saved.oauth?.provider == connection.oauth?.provider, saved.oauth?.userID == connection.oauth?.userID else {
            return false
        }
        if connection.installID == nil { connection.installID = saved.installID }
        return true
    }

    func retire() {
        HermesConnectionLog.logger.notice("c\(self.serial, privacy: .public): connection retired")
        isRetired = true
        isSignedIn = false
        credential = nil
        lastAttempt = nil
        signInTask?.cancel()
        signInTask = nil
        liveGateways.forEach { $0.retire() }
    }

    private func decoded(_ rest: HermesREST, on session: URLSession) async throws -> BotJSON {
        let data = try await Self.send(bearing(prepared(try rest.request(base: connection.address))), on: session,
                                       accepting: 200..<201, redirectGuard: redirectGuard)
        return try JSONDecoder().decode(BotJSON.self, from: data)
    }

    private func publicStatus(on session: URLSession, onlyHostRefusalIs400: Bool = false) async throws -> BotJSON {
        var request = prepared(try HermesREST.status.request(base: connection.address))
        request.httpShouldHandleCookies = false
        let (data, response) = try await Self.exchange(request, on: session, redirectGuard: redirectGuard)
        let body = try? JSONDecoder().decode(BotJSON.self, from: data)
        switch response.statusCode {
        case 200:
            guard let body else { throw BotFailure.notDashboard }
            return body
        case 401: throw body?.fields != nil ? BotFailure.notDashboard : BotFailure.blocked
        case 404: throw BotFailure.notDashboard
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

@MainActor final class HermesConnections {
    static let shared = HermesConnections()
    var onSignInRejected: ((URL, BotFailure) -> Void)?
    var onSignedIn: ((URL, HermesGatewayKind) -> Void)?
    private let configuration: () -> URLSessionConfiguration
    private let store: BotConnectionStore
    private var server: String?
    private weak var current: HermesConnection?
    private var retiredRefreshes: [String: Task<String, Error>] = [:]

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
        fresh.onSignedIn = { [weak self] gateway in self?.onSignedIn?(server, gateway) }
        if saved.oauth != nil { keepRefreshTokens(of: fresh, server: server) }
        current = fresh
        self.server = server.absoluteString
        return fresh
    }

    func ownConnection(for saved: BotConnection, server: URL) -> HermesConnection {
        let own = HermesConnection(connection: saved, configuration: configuration())
        if saved.oauth != nil { keepRefreshTokens(of: own, server: server) }
        return own
    }

    func retire(own: HermesConnection, server: URL) {
        if let task = own.refreshInFlight { retiredRefreshes[server.absoluteString] = task }
        own.retire()
    }

    func closeForBackground() {
        current?.liveGateways.forEach { $0.closeForBackground() }
    }

    func networkPathDidChange() {
        for gateway in current?.liveGateways ?? [] { Task { await gateway.probe() } }
    }

    func reconnectGateway(server: URL) {
        guard self.server == server.absoluteString else { return }
        current?.liveGateways.forEach { $0.dropSocket() }
    }

    func lastAttempt(server: URL) -> HermesAttemptRecord? {
        guard self.server == server.absoluteString else { return nil }
        return current?.lastAttempt
    }

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

enum HermesRestartWait {
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

struct HermesHeaders: Sendable {
    enum Rejection: Error, Equatable, LocalizedError {
        case malformed(String), reserved(String), bearer
        case authorization

        var errorDescription: String? {
            switch self {
            case .bearer:
                return String(localized: "Hermes reads Authorization: Bearer as its own sign-in and refuses it. Remove this header to connect.")
            case .authorization:
                return String(localized: "This server signs in through the browser, so Hermex sends its own Authorization header. Remove this header to connect. For Cloudflare Access, use the CF-Access-Client-Id and CF-Access-Client-Secret headers instead.")
            case .reserved(let name):
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
    static let sessionTokenName = "X-Hermes-Session-Token"

    let values: [CustomHeader]

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

    init(saved: BotConnection) {
        self = (try? HermesHeaders(saved.headers ?? [], signsInWithBrowser: saved.oauth != nil)) ?? .none
    }

    func applied(to request: URLRequest, origin: URL) -> URLRequest {
        guard !values.isEmpty, let url = request.url, Self.isSameOrigin(url, as: origin) else { return request }
        var request = request
        for header in values where request.value(forHTTPHeaderField: header.sanitizedName) == nil {
            request.setValue(header.sanitizedValue, forHTTPHeaderField: header.sanitizedName)
        }
        return request
    }

    func redirectGuard(for origin: URL) -> CrossOriginHeaderStripper {
        let admitted = values + [CustomHeader(name: Self.sessionTokenName)]
        return CrossOriginHeaderStripper(baseURL: origin, sentHeaders: admitted)
    }

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

enum HermesConnectionLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile", category: "HermesConnection")

    static func reason(_ error: Error) -> String {
        switch error {
        case BotFailure.profileNotServed: return "profileNotServed"
        case BotFailure.resumeRefused: return "resumeRefused"
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
