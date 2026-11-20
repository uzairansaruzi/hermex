import Foundation
import Observation

@MainActor
@Observable
final class AuthManager {
    enum State: Equatable {
        case unconfigured
        case loggedOut(server: URL)
        case loggedIn(server: URL)

        var server: URL? {
            switch self {
            case .unconfigured: return nil
            case .loggedOut(let server), .loggedIn(let server): return server
            }
        }
    }

    nonisolated static let passkeyOnlyMessage =
        String(localized: "This server signs in with passkeys, which Hermex doesn't support yet.")

    nonisolated static let oidcOnlyMessage =
        String(localized: "This server signs in with single sign-on, which Hermex doesn't support yet.")

    nonisolated static let trustedAuthNotSignedInMessage =
        String(localized: "This server signs in through an identity proxy, which didn't authorize this request. Open the server in a browser, or check the custom headers.")

    nonisolated static func unsupportedSignInMessage(for status: AuthStatusResponse) -> String? {
        guard status.authEnabled == true, !status.isAlreadySignedIn else { return nil }
        guard status.passwordAuthEnabled == false else { return nil }

        if status.oidcEnabled == true { return oidcOnlyMessage }
        if status.trustedAuthEnabled == true { return trustedAuthNotSignedInMessage }
        return passkeyOnlyMessage
    }

    private(set) var state: State = .unconfigured {
        didSet {
            if let old = oldValue.server, old != state.server { hermesConnections.retire(server: old) }
            if case .loggedIn = oldValue, oldValue != state { limitsPublisher.invalidate() }
            dropStaleMoveSheets()
        }
    }
    private(set) var lastErrorMessage: String?

    private(set) var servers: [ServerAccount] = []
    @ObservationIgnored private(set) var removingServerIDs: Set<String> = []
    var moveOffer: MoveToHermesOffer? {
        didSet { if moveOffer != nil { askedAboutMoveThisLaunch = true } }
    }
    var moveQuestion: MoveToHermesQuestion?
    @ObservationIgnored var askedAboutMoveThisLaunch = false

    let keychain: any KeychainStoring
    private let clientFactory: (URL) -> any AuthAPIClient
    private let probeClientFactory: (URL, [CustomHeader]) -> any AuthAPIClient
    private let headerStore: CustomHeaderStore
    private let logoutTimeout: Duration
    let serverRegistry: ServerRegistry
    private let hermesConnections: HermesConnections
    private let preferences: UserDefaults
    var handBackScreenHolds: (URL) -> Void = { server in Task { await ScreenHolds.handBackAll(server: server) } }
    private let forgetPush: @MainActor (URL) async -> Void
    private let limitsPublisher: ProviderLimitsPublisher

    init(
        keychain: any KeychainStoring = KeychainStore(),
        clientFactory: @escaping (URL) -> any AuthAPIClient = { APIClient(baseURL: $0) },
        probeClientFactory: @escaping (URL, [CustomHeader]) -> any AuthAPIClient = { url, headers in
            APIClient(baseURL: url, customHeaderProvider: { headers })
        },
        headerStore: CustomHeaderStore = .shared,
        logoutTimeout: Duration = .seconds(5),
        serverRegistry: ServerRegistry = .shared,
        hermesConnections: HermesConnections? = nil,
        preferences: UserDefaults = .standard,
        forgetPush: @escaping @MainActor (URL) async -> Void = { await PushRegistrar.shared?.forget(for: $0) },
        limitsPublisher: ProviderLimitsPublisher? = nil
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.probeClientFactory = probeClientFactory
        self.headerStore = headerStore
        self.logoutTimeout = logoutTimeout
        self.serverRegistry = serverRegistry
        self.hermesConnections = hermesConnections ?? .shared
        self.preferences = preferences
        self.forgetPush = forgetPush
        self.limitsPublisher = limitsPublisher ?? .shared
        restoreSavedServer()
        refreshServers()
        self.hermesConnections.onSignInRejected = { [weak self] server, failure in
            self?.hermesSignInRejected(server: server, failure: failure)
        }
        self.hermesConnections.onSignedIn = { [weak self] server, gateway in
            self?.hermesSignedIn(server: server, gateway: gateway)
        }
    }

    var activeServerID: String? { state.server?.absoluteString }

    var activeServer: ServerAccount? { servers.first { $0.id == activeServerID } }

    func kind(of server: URL) -> ServerKind {
        servers.first { $0.id == server.absoluteString }?.kind ?? .webui
    }

    func refreshServers() {
        servers = serverRegistry.servers
        dropStaleMoveSheets()
    }

    private func dropStaleMoveSheets() {
        let active: String? = if case .loggedIn(let server) = state { server.absoluteString } else { nil }
        func kindOf(_ id: String) -> ServerKind? { servers.first { $0.id == id }?.kind }
        if let offer = moveOffer, active != offer.destinationID || kindOf(offer.sourceID) != .webui
            || kindOf(offer.destinationID) != .hermes || !removingServerIDs.isDisjoint(with: [offer.sourceID, offer.destinationID]) {
            moveOffer = nil
        }
        if let question = moveQuestion, active != question.sourceID || kindOf(question.sourceID) != .webui
            || removingServerIDs.contains(question.sourceID) {
            moveQuestion = nil
        }
    }

    var currentCustomHeaders: [CustomHeader] {
        headerStore.snapshot()
    }

    func testConnection(
        serverURLString: String,
        customHeaders: [CustomHeader]? = nil
    ) async throws -> AuthStatusResponse {
        if let customHeaders {
            headerStore.replace(with: customHeaders.sanitizedForStorage())
        }

        let serverURL = try Self.normalizedServerURL(from: serverURLString)
        let client = clientFactory(serverURL)

        return try await testConnection(client: client)
    }

    private func testConnection(client: any AuthAPIClient) async throws -> AuthStatusResponse {
        let health = try await client.health()
        guard health.status == "ok" else {
            throw APIError.http(statusCode: 200, body: "Unexpected health status.")
        }

        return try await client.authStatus()
    }

    func configure(
        serverURLString: String,
        password: String,
        customHeaders: [CustomHeader]? = nil
    ) async {
        lastErrorMessage = nil

        if let customHeaders {
            headerStore.replace(with: customHeaders.sanitizedForStorage())
        }

        do {
            let serverURL = try Self.normalizedServerURL(from: serverURLString)
            guard kind(of: serverURL) == .webui else {
                lastErrorMessage = String(localized: "This server is already configured.")
                return
            }
            let client = clientFactory(serverURL)
            let authStatus = try await testConnection(client: client)

            if let message = Self.unsupportedSignInMessage(for: authStatus) {
                lastErrorMessage = message
                return
            }

            if authStatus.authEnabled == true, !authStatus.isAlreadySignedIn {
                guard !password.isEmpty else {
                    lastErrorMessage = String(localized: "Enter the server password.")
                    return
                }

                let loginResponse = try await client.login(password: password)
                guard loginResponse.ok == true else {
                    state = .loggedOut(server: serverURL)
                    lastErrorMessage = APIError.unauthorized.localizedDescription
                    return
                }
            }

            try keychain.save(serverURL.absoluteString, forKey: .serverURL)
            serverRegistry.activate(url: serverURL)
            persistCustomHeaders(for: serverURL)
            refreshServers()
            state = .loggedIn(server: serverURL)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    enum AddServerOutcome: Equatable {
        case added(URL)
        case needsPassword
        case failed(serverAnswered: Bool)
    }

    @discardableResult
    func addServer(
        serverURLString: String,
        password: String,
        customHeaders: [CustomHeader] = []
    ) async -> AddServerOutcome {
        lastErrorMessage = nil

        let serverURL: URL
        do {
            serverURL = try Self.normalizedServerURL(from: serverURLString)
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed(serverAnswered: false)
        }

        guard !serverRegistry.servers.contains(where: { $0.id == serverURL.absoluteString }) else {
            lastErrorMessage = String(localized: "This server is already configured.")
            return .failed(serverAnswered: false)
        }

        let newHeaders = customHeaders.sanitizedForStorage()
        let client = probeClientFactory(serverURL, newHeaders)
        var serverAnswered = false

        do {
            let authStatus = try await testConnection(client: client)
            serverAnswered = true

            if let message = Self.unsupportedSignInMessage(for: authStatus) {
                lastErrorMessage = message
                return .failed(serverAnswered: true)
            }

            if authStatus.authEnabled == true, !authStatus.isAlreadySignedIn {
                guard !password.isEmpty else {
                    return .needsPassword
                }

                let loginResponse = try await client.login(password: password)
                guard loginResponse.ok == true else {
                    lastErrorMessage = APIError.unauthorized.localizedDescription
                    return .failed(serverAnswered: true)
                }
            }

            try keychain.save(serverURL.absoluteString, forKey: .serverURL)
            headerStore.replace(with: newHeaders)
            handBackScreens(leavingFor: serverURL)
            serverRegistry.activate(url: serverURL)
            persistCustomHeaders(for: serverURL)
            refreshServers()
            ProfileEntityCache.shared.save([])
            state = .loggedIn(server: serverURL)
            return .added(serverURL)
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed(serverAnswered: serverAnswered)
        }
    }

    @discardableResult
    func addHermesServer(_ connection: BotConnection, activating: Bool = true) -> Bool {
        lastErrorMessage = nil
        let server = (try? BotConnection.address(connection.address.absoluteString)) ?? connection.address
        guard !serverRegistry.servers.contains(where: { $0.id == server.absoluteString }) else {
            lastErrorMessage = String(localized: "This server is already configured.")
            return false
        }
        do {
            try BotConnectionStore(keychain: keychain).save(connection, server: server)
            if activating { try keychain.save(server.absoluteString, forKey: .serverURL) }
        } catch {
            lastErrorMessage = String(localized: "Could not save sign-in details on this iPhone.")
            return false
        }
        guard activating else {
            serverRegistry.add(url: server, kind: .hermes, serverVersion: connection.hermesVersion)
            refreshServers()
            return true
        }
        handBackScreens(leavingFor: server)
        serverRegistry.activate(url: server, kind: .hermes, serverVersion: connection.hermesVersion)
        refreshServers()
        ProfileEntityCache.shared.save([])
        enterActiveServer(server)
        moveOffer = MoveToHermesOffer(destinationID: server.absoluteString, servers: servers)
        return true
    }

    func replaceWebuiServer(with connection: BotConnection) async -> Bool {
        lastErrorMessage = nil
        let server = (try? BotConnection.address(connection.address.absoluteString)) ?? connection.address
        guard let webui = servers.first(where: { $0.id == server.absoluteString }), webui.kind == .webui else {
            lastErrorMessage = String(localized: "This server is already configured.")
            return false
        }
        await removeServer(webui)
        guard addHermesServer(connection), let added = activeServer else { return false }
        updateServerIdentity(added, displayName: webui.displayName, initials: webui.initials,
                             headerLogoColorHex: webui.headerLogoColorHex)
        return true
    }

    struct SavedHermesSignIn: Equatable {
        let serverName: String
        let connection: BotConnection
    }

    func savedHermesSignIns(at address: URL) -> [SavedHermesSignIn] {
        let store = BotConnectionStore(keychain: keychain)
        return servers.compactMap { account in
            guard account.kind == .webui, let server = URL(string: account.urlString),
                  let saved = try? store.load(server: server),
                  (try? BotConnection.address(saved.address.absoluteString)) == address else { return nil }
            let name = account.displayName.isEmpty ? (server.host ?? account.urlString) : account.displayName
            return SavedHermesSignIn(serverName: name, connection: saved)
        }
    }

    func hermesSignInRejected(server: URL, failure: BotFailure = .rejected(401)) {
        guard state == .loggedIn(server: server), kind(of: server) == .hermes else { return }
        lastErrorMessage = BotConnectionAdvice.message(for: failure, address: server)
        state = .loggedOut(server: server)
    }

    func hermesSignInSaved(server: URL, offersMove: Bool = true) {
        guard var account = servers.first(where: { $0.id == server.absoluteString }), account.kind == .hermes,
              let saved = try? BotConnectionStore(keychain: keychain).load(server: server) else { return }
        if account.serverVersion != saved.hermesVersion {
            account.serverVersion = saved.hermesVersion
            serverRegistry.update(account)
            refreshServers()
        }
        if state == .loggedOut(server: server) {
            lastErrorMessage = nil
            state = .loggedIn(server: server)
        }
        if offersMove, state == .loggedIn(server: server) {
            moveOffer = MoveToHermesOffer(destinationID: server.absoluteString, servers: servers)
        }
    }

    func hermesSignedIn(server: URL, gateway: HermesGatewayKind) {
        guard var account = servers.first(where: { $0.id == server.absoluteString }), account.kind == .hermes,
              account.hermesGateway != gateway else { return }
        account.hermesGateway = gateway
        serverRegistry.update(account)
        refreshServers()
    }

    func hermesServerUpdated(server: URL, to version: String) {
        let store = BotConnectionStore(keychain: keychain)
        if var saved = try? store.load(server: server), saved.hermesVersion != version {
            saved.hermesVersion = version
            try? store.save(saved, server: server)
        }
        guard var account = servers.first(where: { $0.id == server.absoluteString }), account.kind == .hermes,
              account.serverVersion != version else { return }
        account.serverVersion = version
        serverRegistry.update(account)
        refreshServers()
    }

    func updateCustomHeaders(_ headers: [CustomHeader], persist: Bool = true) {
        headerStore.replace(with: headers.sanitizedForStorage())
        if persist, let server = state.server {
            persistCustomHeaders(for: server)
        }
    }

    func signOut() async {
        guard let active = state.server else {
            clearLocalAuth(for: nil)
            state = .unconfigured
            return
        }

        await ScreenHolds.handBackAll(server: active)
        if kind(of: active) == .hermes {
            try? await BotHistoryCache.shared.removeServer(active, activeConnectionID: (try? BotConnectionStore(keychain: keychain).load(server: active))?.id)
            await ChatDraftStore.shared.discardBotDrafts(server: active)
            await forgetPush(active)
            removeBotConnection(for: active)
            await BotRosterCache.shared.remove(server: active)
            guard state.server == active else { return }
            lastErrorMessage = nil
            state = .loggedOut(server: active)
            return
        }

        if case .loggedIn = state {
            await attemptBestEffortServerLogout(server: active)
        }

        try? await BotHistoryCache.shared.removeServer(active, activeConnectionID: (try? BotConnectionStore(keychain: keychain).load(server: active))?.id)
        SessionUnreadStore().remove(for: active)
        await ChatDraftStore.shared.discardBotDrafts(server: active)
        await forgetPush(active)
        advanceAfterRemoving(activeServer: active)
        await BotRosterCache.shared.remove(server: active)
        BotWidgetPublisher.shared.remove(server: active)
    }

    func removeServer(_ account: ServerAccount) async {
        guard let serverURL = URL(string: account.urlString) else { return }
        removingServerIDs.insert(account.id)
        defer { removingServerIDs.remove(account.id) }
        limitsPublisher.invalidate(server: serverURL)
        dropStaleMoveSheets()
        await ScreenHolds.handBackAll(server: serverURL)
        let movedSources = (servers.first { $0.id == account.id } ?? account).movedWebuiServers.map(\.sourceServerID)
        try? await BotHistoryCache.shared.removeServer(serverURL, activeConnectionID: (try? BotConnectionStore(keychain: keychain).load(server: serverURL))?.id)
        SessionUnreadStore().remove(for: serverURL)
        HermesProfileNameCache.shared.remove(server: serverURL)
        await ChatDraftStore.shared.discardBotDrafts(server: serverURL)
        await forgetPush(serverURL)
        let isActive = state.server?.absoluteString == account.id

        if isActive {
            if case .loggedIn = state, account.kind == .webui {
                await attemptBestEffortServerLogout(server: serverURL)
            }
            advanceAfterRemoving(activeServer: serverURL)
        } else {
            clearLocalArtifacts(for: serverURL)
            serverRegistry.remove(id: account.id)
            refreshServers()
        }
        await BotRosterCache.shared.remove(server: serverURL)
        BotWidgetPublisher.shared.remove(server: serverURL)
        MoveToHermesJournal.discard(sources: movedSources, destinationID: account.id)
    }

    func switchActiveServer(to account: ServerAccount) {
        guard account.id != state.server?.absoluteString,
              let serverURL = URL(string: account.urlString) else { return }

        handBackScreens(leavingFor: serverURL)
        serverRegistry.setActive(id: account.id)
        refreshServers()
        try? keychain.save(serverURL.absoluteString, forKey: .serverURL)
        ProfileEntityCache.shared.save([])
        lastErrorMessage = nil
        enterActiveServer(serverURL)
    }

    func updateServerIdentity(
        _ account: ServerAccount,
        displayName: String,
        initials: String,
        headerLogoColorHex: String
    ) {
        var updated = account
        updated.displayName = displayName
        updated.initials = initials
        updated.headerLogoColorHex = headerLogoColorHex
        serverRegistry.update(updated)
        refreshServers()
    }

    private func advanceAfterRemoving(activeServer server: URL) {
        try? keychain.delete(.customHeaders)
        clearLocalArtifacts(for: server)
        ProfileEntityCache.shared.save([])

        let nextActive = serverRegistry.remove(id: server.absoluteString)
        refreshServers()

        if let nextActive, let nextURL = URL(string: nextActive.urlString) {
            try? keychain.save(nextURL.absoluteString, forKey: .serverURL)
            lastErrorMessage = nil
            enterActiveServer(nextURL)
        } else {
            try? keychain.delete(.serverURL)
            headerStore.replace(with: [])
            state = .unconfigured
        }
    }

    private func clearLocalArtifacts(for server: URL) {
        try? keychain.delete(.customHeaders, scope: server.absoluteString)
        removeBotConnection(for: server)
        if kind(of: server) == .webui { clearSessionCookies(for: server) }
    }

    private func handBackScreens(leavingFor next: URL) {
        guard let departing = state.server, departing != next else { return }
        handBackScreenHolds(departing)
    }

    private func removeBotConnection(for server: URL) {
        BotScreenSettings.remove(for: server, in: preferences)
        ScreenHoldStore(keychain: keychain).removeAll(server: server)
        ModelFavoritesStore.remove(for: server, in: preferences)
        ModelRecentsStore.remove(for: server, in: preferences)
        ModelPresetStore.remove(for: server, in: preferences)
        HermesProfilePreference.save(nil, for: server, in: preferences)
        HermesProfilePreference.saveShowsAllProfiles(false, for: server, in: preferences)
        HermesProfilePreference.saveLastListed(nil, for: server, in: preferences)
        let bots = BotConnectionStore(keychain: keychain)
        if let connection = try? bots.load(server: server) {
            BotAvatarStore.shared.removeAll(connectionID: connection.id)
        }
        try? bots.remove(server: server)
    }

    private func attemptBestEffortServerLogout(server: URL) async {
        let client = clientFactory(server)
        let timeout = logoutTimeout

        let logoutTask = Task { @MainActor in
            _ = try await client.logout()
        }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            logoutTask.cancel()
        }

        _ = try? await logoutTask.value
        timeoutTask.cancel()
    }

    func handleAPIError(_ error: Error) {
        guard case APIError.unauthorized = error else {
            return
        }
        if let server = state.server, kind(of: server) == .hermes { return }

        lastErrorMessage = String(localized: "Your session expired. Sign in again.")

        switch state {
        case .loggedIn(let server), .loggedOut(let server):
            clearSessionCookies(for: server)
            state = .loggedOut(server: server)
        case .unconfigured:
            clearLocalAuth(for: nil)
        }
    }

    private func clearLocalAuth(for server: URL?) {
        try? keychain.delete(.serverURL)
        try? keychain.delete(.customHeaders)

        if let server {
            try? keychain.delete(.customHeaders, scope: server.absoluteString)
            clearSessionCookies(for: server)
        } else {
            clearAllSessionCookies()
        }

        serverRegistry.forgetActiveServer()
        refreshServers()
        headerStore.replace(with: [])
        ProfileEntityCache.shared.save([])
    }

    private func persistCustomHeaders(for server: URL) {
        let scope = server.absoluteString
        let headers = headerStore.snapshot()
        if let encoded = headers.encodedForStorage() {
            try? keychain.save(encoded, forKey: .customHeaders, scope: scope)
        } else {
            try? keychain.delete(.customHeaders, scope: scope)
        }
    }

    private func hydrateCustomHeaders(for server: URL) {
        let scope = server.absoluteString
        let stored: String?
        if let scoped = try? keychain.load(.customHeaders, scope: scope) {
            stored = scoped
        } else if let legacy = try? keychain.load(.customHeaders) {
            if (try? keychain.save(legacy, forKey: .customHeaders, scope: scope)) != nil {
                try? keychain.delete(.customHeaders)
            }
            stored = legacy
        } else {
            stored = nil
        }
        headerStore.replace(with: [CustomHeader].decodeFromStorage(stored))
    }

    private func clearSessionCookies(for server: URL) {
        let storage = HTTPCookieStorage.shared
        storage.cookies(for: server)?.forEach { storage.deleteCookie($0) }
    }

    private func clearAllSessionCookies() {
        HTTPCookieStorage.shared.cookies?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }

    private func restoreSavedServer() {
        guard
            let savedValue = try? keychain.load(.serverURL),
            let savedURL = URL(string: savedValue)
        else {
            state = .unconfigured
            return
        }

        serverRegistry.activate(url: savedURL)
        refreshServers()
        enterActiveServer(savedURL)
    }

    private func enterActiveServer(_ server: URL) {
        guard kind(of: server) == .hermes else {
            hydrateCustomHeaders(for: server)
            state = .loggedIn(server: server)
            return
        }
        headerStore.replace(with: [])
        let saved = try? BotConnectionStore(keychain: keychain).load(server: server)
        state = saved == nil ? .loggedOut(server: server) : .loggedIn(server: server)
    }

    nonisolated static func normalizedServerURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.invalidServerURL
        }

        let valueWithScheme = trimmed.contains("://") ? trimmed : "\(defaultScheme(forSchemalessServer: trimmed))://\(trimmed)"
        guard var components = URLComponents(string: valueWithScheme), components.host != nil else {
            throw APIError.invalidServerURL
        }

        components.host = normalizedHost(components.host)
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let url = components.url, url.scheme == "https" || url.scheme == "http" else {
            throw APIError.invalidServerURL
        }

        return url
    }

    private nonisolated static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }

        let lowercasedHost = host.lowercased()
        guard lowercasedHost.hasPrefix("www.webui.") else {
            return host
        }

        return String(host.dropFirst(4))
    }

    private nonisolated static func defaultScheme(forSchemalessServer rawValue: String) -> String {
        guard
            let host = URLComponents(string: "http://\(rawValue)")?.host?.lowercased(),
            shouldDefaultToPlainHTTP(host: host)
        else {
            return "https"
        }

        return "http"
    }

    private nonisolated static func shouldDefaultToPlainHTTP(host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" {
            return true
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}

protocol AuthAPIClient: Sendable {
    func health() async throws -> HealthResponse
    func authStatus() async throws -> AuthStatusResponse
    func login(password: String) async throws -> LoginResponse
    func logout() async throws -> LoginResponse
}

extension APIClient: AuthAPIClient {}
