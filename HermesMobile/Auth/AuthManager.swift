import Foundation
import Observation

@MainActor
@Observable
final class AuthManager {
    enum State: Equatable {
        case unconfigured
        case loggedOut(server: URL)
        case loggedIn(server: URL)

        /// The server this state refers to, if any — used to scope sign-out and
        /// session-expiry to the active server (#16). `unconfigured` has none.
        var server: URL? {
            switch self {
            case .unconfigured: return nil
            case .loggedOut(let server), .loggedIn(let server): return server
            }
        }
    }

    /// Shown when a server has auth on but explicitly reports password auth off,
    /// i.e. it signs in with passkeys (which we can't do yet). See issue #255.
    nonisolated static let passkeyOnlyMessage =
        String(localized: "This server signs in with passkeys, which Hermex doesn't support yet.")

    /// Single sign-on. Hermex cannot run the OIDC redirect flow yet, and an
    /// external browser's session is not shared with the app.
    nonisolated static let oidcOnlyMessage =
        String(localized: "This server signs in with single sign-on, which Hermex doesn't support yet.")

    /// Trusted-header mode where the proxy did *not* authenticate this request,
    /// so the server reports the mode but not a session.
    nonisolated static let trustedAuthNotSignedInMessage =
        String(localized: "This server signs in through an identity proxy, which didn't authorize this request. Open the server in a browser, or check the custom headers.")

    /// Why the app can't complete sign-in on its own, or nil when it can —
    /// either there's no auth, the server already signed this client in, or a
    /// password login is available.
    ///
    /// Replaces the "auth on and password auth off ⇒ passkeys" inference that
    /// used to live in three places. `is_auth_enabled()` upstream
    /// (`api/auth.py:563`) also covers OIDC and trusted-header, so that
    /// inference locked out working deployments and told them the wrong reason
    /// (#3).
    nonisolated static func unsupportedSignInMessage(for status: AuthStatusResponse) -> String? {
        guard status.authEnabled == true, !status.isAlreadySignedIn else { return nil }
        // A missing value means an older server that doesn't report it; fall
        // through to the password path rather than block a working user.
        guard status.passwordAuthEnabled == false else { return nil }

        if status.oidcEnabled == true { return oidcOnlyMessage }
        if status.trustedAuthEnabled == true { return trustedAuthNotSignedInMessage }
        return passkeyOnlyMessage
    }

    private(set) var state: State = .unconfigured {
        // The shared Bot connection signs in with the active server's saved credentials.
        didSet { if let old = oldValue.server, old != state.server { hermesConnections.retire(server: old) } }
    }
    private(set) var lastErrorMessage: String?

    /// Observable snapshot of every configured server, mirrored from the
    /// `ServerRegistry` (the persistent source of truth) after each mutation so
    /// the Settings server list updates reactively (#17). The active server is the
    /// one whose `id` matches `state.server?.absoluteString`.
    private(set) var servers: [ServerAccount] = []

    private let keychain: any KeychainStoring
    private let clientFactory: (URL) -> any AuthAPIClient
    /// Builds a client bound to explicit headers (not the shared `CustomHeaderStore`)
    /// — used by `addServer` to probe a new server without disturbing the active
    /// server's live headers (#17).
    private let probeClientFactory: (URL, [CustomHeader]) -> any AuthAPIClient
    private let headerStore: CustomHeaderStore
    private let logoutTimeout: Duration
    private let serverRegistry: ServerRegistry
    private let hermesConnections: HermesConnections
    /// Where the Bot Mode gate is read (`BotModeGate`), which adding a Hermes server needs.
    private let preferences: UserDefaults

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
        preferences: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.probeClientFactory = probeClientFactory
        self.headerStore = headerStore
        self.logoutTimeout = logoutTimeout
        self.serverRegistry = serverRegistry
        self.hermesConnections = hermesConnections ?? .shared
        self.preferences = preferences
        restoreSavedServer()
        refreshServers()
        self.hermesConnections.onSignInRejected = { [weak self] server in self?.hermesSignInRejected(server: server) }
    }

    /// The active server's id (its normalized URL string), or nil when
    /// unconfigured. Used by the Settings list to mark which row is active.
    var activeServerID: String? { state.server?.absoluteString }

    /// The active server's registry entry, or nil when unconfigured.
    var activeServer: ServerAccount? { servers.first { $0.id == activeServerID } }

    /// What `server` is. A URL missing from the registry reads as webui, the only kind
    /// before #899.
    func kind(of server: URL) -> ServerKind {
        servers.first { $0.id == server.absoluteString }?.kind ?? .webui
    }

    /// Re-reads the registry into the observable `servers` snapshot. Called after
    /// every registry mutation routed through this manager.
    private func refreshServers() {
        servers = serverRegistry.servers
    }

    /// The headers currently in effect — used to prefill the editor on the connect
    /// and Settings screens.
    var currentCustomHeaders: [CustomHeader] {
        headerStore.snapshot()
    }

    func testConnection(
        serverURLString: String,
        customHeaders: [CustomHeader]? = nil
    ) async throws -> AuthStatusResponse {
        // Apply the in-progress headers before the very first probe so the health
        // and auth-status calls already traverse the proxy. Passing nil leaves the
        // current headers untouched (#255).
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
            // A webui server and a Hermes server never share a URL (#899).
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

            // `logged_in` means the server already authenticated this client —
            // trusted-header mode does it at the proxy — so there is nothing to
            // log in with and the server is saved as signed in (#3).
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

            // Persist only on success: the server URL and the headers that reached it.
            try keychain.save(serverURL.absoluteString, forKey: .serverURL)
            // Record (or re-activate) this server in the multi-server registry,
            // shadowing the Keychain `server_url` write above (#15). Dedupes by
            // normalized URL.
            serverRegistry.activate(url: serverURL)
            // Persist the headers that reached this server under its own scoped key
            // so they never apply to a different server (#16).
            persistCustomHeaders(for: serverURL)
            refreshServers()
            state = .loggedIn(server: serverURL)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Outcome of `addServer`, so the in-app add-server flow can reveal the
    /// password field only when the server actually needs one (#17).
    enum AddServerOutcome: Equatable {
        case added(URL)
        case needsPassword
        case failed
    }

    /// Adds (and switches to) another server from the in-app add-server flow.
    ///
    /// Unlike `configure` (the onboarding path), this NEVER mutates the active
    /// server's state or its live header store until the add fully succeeds: the
    /// new server is probed through a client bound to *its own* headers (via
    /// `probeClientFactory`), not the shared `CustomHeaderStore`. So a typo or an
    /// unreachable server can't bounce the user out of a working session, and the
    /// active server's concurrent requests (polling / SSE reconnect) never pick up
    /// the new server's headers during the async probe window. Rejects a URL that's
    /// already configured (no duplicate normalized URLs). On success the new server
    /// becomes active and its headers are persisted under its own scoped key (#16).
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
            return .failed
        }

        guard !serverRegistry.servers.contains(where: { $0.id == serverURL.absoluteString }) else {
            lastErrorMessage = String(localized: "This server is already configured.")
            return .failed
        }

        let newHeaders = customHeaders.sanitizedForStorage()
        // Probe with a client scoped to the NEW server's headers, leaving the live
        // header store (and the active server's in-flight/SSE requests) untouched.
        let client = probeClientFactory(serverURL, newHeaders)

        do {
            let authStatus = try await testConnection(client: client)

            if let message = Self.unsupportedSignInMessage(for: authStatus) {
                lastErrorMessage = message
                return .failed
            }

            if authStatus.authEnabled == true, !authStatus.isAlreadySignedIn {
                guard !password.isEmpty else {
                    // Not an error — the UI reveals the password field and retries.
                    return .needsPassword
                }

                let loginResponse = try await client.login(password: password)
                guard loginResponse.ok == true else {
                    lastErrorMessage = APIError.unauthorized.localizedDescription
                    return .failed
                }
            }

            // Commit only now that the add succeeded: the new server becomes
            // active, so its headers move into the live store and persist under its
            // own scoped key (#16). The previous active server's headers were never
            // disturbed, and stay safe in their own scoped Keychain entry.
            //
            // Do the throwing Keychain write first so a write failure leaves the
            // live header store (and the active server) completely untouched.
            try keychain.save(serverURL.absoluteString, forKey: .serverURL)
            headerStore.replace(with: newHeaders)
            serverRegistry.activate(url: serverURL)
            persistCustomHeaders(for: serverURL)
            refreshServers()
            state = .loggedIn(server: serverURL)
            return .added(serverURL)
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed
        }
    }

    /// Adds (and switches to) a Hermes server (#899): `connection` is a sign-in the
    /// connection form or dev sign-in has already verified, and becomes the server's own
    /// record, saved under its address, which is also the server's id. Needs Bot Mode on
    /// (`BotModeGate`); refuses an address already in the registry, as `addServer` does, so
    /// a webui server and a Hermes server never share a URL (`replaceWebuiServer` swaps
    /// one for the other). Returns whether it was added.
    @discardableResult
    func addHermesServer(_ connection: BotConnection) -> Bool {
        lastErrorMessage = nil
        guard BotModeGate.isEnabled(in: preferences) else { return false }
        let server = (try? BotConnection.address(connection.address.absoluteString)) ?? connection.address
        guard !serverRegistry.servers.contains(where: { $0.id == server.absoluteString }) else {
            lastErrorMessage = String(localized: "This server is already configured.")
            return false
        }
        do {
            try BotConnectionStore(keychain: keychain).save(connection, server: server)
            try keychain.save(server.absoluteString, forKey: .serverURL)
        } catch {
            lastErrorMessage = String(localized: "Could not save sign-in details on this iPhone.")
            return false
        }
        serverRegistry.activate(url: server, kind: .hermes, serverVersion: connection.hermesVersion)
        refreshServers()
        // The Shortcuts Profile list belonged to the server this replaces as active (#339).
        ProfileEntityCache.shared.save([])
        enterActiveServer(server)
        return true
    }

    /// Replaces the webui server saved at `connection`'s address with a Hermes server, for a
    /// host that moved from hermes-webui to the dashboard (#1027). `connection` is a sign-in
    /// already verified, as for `addHermesServer`. The webui server goes as `removeServer`
    /// takes it (its sign-in, cache and drafts on this iPhone), and the Hermes server keeps
    /// its name, initials and color. Refuses unless a webui server is saved there. Returns
    /// whether the Hermes server was added.
    func replaceWebuiServer(with connection: BotConnection) async -> Bool {
        lastErrorMessage = nil
        guard BotModeGate.isEnabled(in: preferences) else { return false }
        let server = (try? BotConnection.address(connection.address.absoluteString)) ?? connection.address
        guard let webui = servers.first(where: { $0.id == server.absoluteString }), webui.kind == .webui else {
            lastErrorMessage = String(localized: "This server is already configured.")
            return false
        }
        // No suspension between the removal's last step and the add, so no screen ever
        // shows the server the removal falls back to.
        await removeServer(webui)
        guard addHermesServer(connection), let added = activeServer else { return false }
        updateServerIdentity(added, displayName: webui.displayName, initials: webui.initials,
                             headerLogoColorHex: webui.headerLogoColorHex)
        return true
    }

    /// A Hermes sign-in a webui server keeps for its Bots, which the connect form offers
    /// to copy into a new Hermes server at the same address (#900).
    struct SavedHermesSignIn: Equatable {
        /// The webui server that keeps it, named as Settings → Servers names it.
        let serverName: String
        let connection: BotConnection
    }

    /// The sign-ins configured webui servers keep for exactly `address`, each saved address
    /// parsed by `BotConnection.address(_:)` as the typed one was. Never matched by
    /// `install_id`: it comes from the public `/api/status`, so any host could report
    /// another's and be offered its saved password.
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

    /// The host refused the active Hermes server's saved username or password at the
    /// login step (`HermesConnections.onSignInRejected`), including the one silent
    /// re-login a signed-in 401 starts. Shows that server's sign-in form, where no Bot
    /// screen exists to send the refused password again. Any other server, and a webui
    /// server's own Hermes connection, which keeps its per-screen flag (#884), stays as it is.
    func hermesSignInRejected(server: URL) {
        guard state == .loggedIn(server: server), kind(of: server) == .hermes else { return }
        lastErrorMessage = BotConnectionAdvice.message(for: BotFailure.rejected(401), address: server)
        state = .loggedOut(server: server)
    }

    /// The Hermes connection form saved `server`'s sign-in. Records the release the host
    /// reported, and signs the server back in when it is the active Hermes server waiting
    /// on its sign-in form. A no-op for a webui server.
    func hermesSignInSaved(server: URL) {
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
    }

    /// An update from Settings installed `version` on the Hermes server `server` (#1075).
    /// Records it on the server's saved sign-in and its registry entry, where a sign-in would
    /// have, and changes nothing else: a server waiting on its sign-in form stays there.
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

    /// Updates the in-effect headers from the Settings editor while signed in. The
    /// in-memory snapshot always updates immediately (so live requests pick them
    /// up), but the Keychain write is opt-in: the editor refreshes on every
    /// keystroke (`persist: false`, cheap) and persists once on dismiss
    /// (`persist: true`), since Keychain writes are slow enough to stutter typing
    /// (#255).
    func updateCustomHeaders(_ headers: [CustomHeader], persist: Bool = true) {
        headerStore.replace(with: headers.sanitizedForStorage())
        // Persist under the active server's scoped key. The Settings editor is only
        // reachable while signed in, so a server is always present here; if somehow
        // unconfigured there's nothing to scope to, so we skip the write (#16).
        if persist, let server = state.server {
            persistCustomHeaders(for: server)
        }
    }

    /// Signs out of the **active** server: best-effort server-side logout, then
    /// drops it locally and auto-switches to the next remaining server — returning
    /// to onboarding only when none remain (#17). A single-server install behaves
    /// exactly as before (sign out → onboarding). A Hermes server stays configured: its
    /// record and Bot data are deleted and its sign-in form shows, with its address (#899).
    func signOut() async {
        guard let active = state.server else {
            // Defensive: nothing is active. Safe full reset to onboarding.
            clearLocalAuth(for: nil)
            state = .unconfigured
            return
        }

        if kind(of: active) == .hermes {
            try? await BotHistoryCache.shared.removeServer(active, activeConnectionID: (try? BotConnectionStore(keychain: keychain).load(server: active))?.id)
            await ChatDraftStore.shared.discardBotDrafts(server: active)
            removeBotConnection(for: active)
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
        await PushRegistrar.shared?.forget(for: active)
        advanceAfterRemoving(activeServer: active)
    }

    /// Removes a configured server. When it's the active one this behaves like
    /// `signOut` (best-effort server logout + auto-switch / onboarding). A
    /// non-active server is just dropped locally — its registry row, scoped
    /// headers, and cookies — leaving the active server's auth untouched (#17).
    func removeServer(_ account: ServerAccount) async {
        guard let serverURL = URL(string: account.urlString) else { return }
        try? await BotHistoryCache.shared.removeServer(serverURL, activeConnectionID: (try? BotConnectionStore(keychain: keychain).load(server: serverURL))?.id)
        SessionUnreadStore().remove(for: serverURL)
        await ChatDraftStore.shared.discardBotDrafts(server: serverURL)
        // A Hermes server has no push pairing until #706, so the relay is never called for one.
        if account.kind == .webui { await PushRegistrar.shared?.forget(for: serverURL) }
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
    }

    /// Switches the active server to an already-registered one (the Settings
    /// switcher). Mirrors the cold-launch path: persist the URL, set it active, and
    /// enter it (`enterActiveServer`): a webui server optimistically `.loggedIn` with
    /// its scoped headers, a stale cookie demoted by the first request's 401
    /// (`handleAPIError`), exactly like a relaunch — so no extra round-trip here.
    func switchActiveServer(to account: ServerAccount) {
        guard account.id != state.server?.absoluteString,
              let serverURL = URL(string: account.urlString) else { return }

        serverRegistry.setActive(id: account.id)
        refreshServers()
        try? keychain.save(serverURL.absoluteString, forKey: .serverURL)
        // Drop the App Intents profile picker cache (#339): it holds the previous server's
        // profiles, which would leak into Shortcuts / Siri if the new server's fetch is
        // delayed or fails. The new server's profiles reload on the next foreground fetch.
        ProfileEntityCache.shared.save([])
        lastErrorMessage = nil
        enterActiveServer(serverURL)
    }

    /// Updates a server's per-server identity (display name, initials, Header Logo
    /// Color). When `account` is the active server the registry mirrors the new
    /// identity into the global identity defaults, so the avatar / header tint
    /// update live (#17).
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

    /// Drops the active server locally + from the registry, then auto-switches to
    /// the next remaining server, or returns to onboarding when none remain. The
    /// shared core of `signOut` and active-server `removeServer` (#17).
    private func advanceAfterRemoving(activeServer server: URL) {
        // Always drop any pre-#16 global header remnant on a sign-out path.
        try? keychain.delete(.customHeaders)
        clearLocalArtifacts(for: server)
        // Drop the App Intents profile picker cache (#339): the cached profiles belong to the
        // server being removed, so they're stale whether we switch to another server (its
        // profiles reload on the next foreground fetch) or return to onboarding.
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

    /// Deletes one server's local auth artifacts — its scoped custom headers, its
    /// Bot connection with that connection's cached avatars, shared sign-in and remembered
    /// Hermes Profile, and its cookies — without touching the registry or the global
    /// `server_url` key. Its push pairing lives in the shared Keychain access group and is torn down by
    /// `PushRegistrar.forget`, which the removal paths above await first. A Hermes
    /// server's sign-in never uses the shared cookie jar, so the cookies of a webui
    /// server on the same host stay.
    private func clearLocalArtifacts(for server: URL) {
        try? keychain.delete(.customHeaders, scope: server.absoluteString)
        removeBotConnection(for: server)
        if kind(of: server) == .webui { clearSessionCookies(for: server) }
    }

    /// Deletes `server`'s Bot connection record with that connection's cached avatars,
    /// which also retires its shared sign-in (`BotConnectionStore.remove`), and the Profile
    /// its New Session remembers (#1015).
    private func removeBotConnection(for server: URL) {
        HermesProfilePreference.save(nil, for: server, in: preferences)
        let bots = BotConnectionStore(keychain: keychain)
        if let connection = try? bots.load(server: server) {
            BotAvatarStore.shared.removeAll(connectionID: connection.id)
        }
        try? bots.remove(server: server)
    }

    /// Tells the server to end the session, but never lets an unreachable or
    /// slow server block local sign-out. The request is best-effort and bounded
    /// by `logoutTimeout`; on failure, timeout, or cancellation we just move on
    /// so the caller can always clear local auth and return to onboarding.
    ///
    /// Order matters: this runs while the session cookie still exists, so a
    /// reachable server is logged out server-side before `clearLocalAuth()`
    /// deletes the cookie. See issue #249.
    private func attemptBestEffortServerLogout(server: URL) async {
        let client = clientFactory(server)
        // Copy to a local so the timeout task captures only the value, not `self`.
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
        // A webui 401 is never about a Hermes server's own sign-in: a late reply from a
        // webui screen a switch left behind must not sign the Hermes server out (#899).
        if let server = state.server, kind(of: server) == .hermes { return }

        lastErrorMessage = String(localized: "Your session expired. Sign in again.")

        switch state {
        case .loggedIn(let server), .loggedOut(let server):
            // The server is still valid; only the session cookie is stale. Keep the
            // Keychain entry so re-login is a one-field affair, and clear only this
            // server's cookies so other configured servers stay signed in (#16).
            clearSessionCookies(for: server)
            state = .loggedOut(server: server)
        case .unconfigured:
            clearLocalAuth(for: nil)
        }
    }

    /// Clears local auth for `server` (a full per-server sign-out): forgets that
    /// server's saved URL, its scoped custom headers, and its cookies, leaving any
    /// other configured server untouched (#16). (Session-expiry via
    /// `handleAPIError` keeps the URL + headers so re-login behind a proxy is a
    /// one-field affair — see #255.)
    ///
    /// When `server` is nil (a 401 while unconfigured) there's no active server to
    /// scope to, so we fall back to clearing the global remnants and the whole
    /// cookie jar as a safe reset.
    private func clearLocalAuth(for server: URL?) {
        // The legacy single-server URL key is global; always clear it on sign-out.
        try? keychain.delete(.serverURL)
        // Drop any pre-#16 global header blob too, so it can't linger or be
        // re-migrated after the user has signed out.
        try? keychain.delete(.customHeaders)

        if let server {
            try? keychain.delete(.customHeaders, scope: server.absoluteString)
            clearSessionCookies(for: server)
        } else {
            clearAllSessionCookies()
        }

        // Forget the active server in the registry (leaves other servers intact).
        serverRegistry.forgetActiveServer()
        refreshServers()
        headerStore.replace(with: [])
        // Drop the App Intents profile picker cache (#339) so a signed-out user doesn't see
        // the previous server's profiles lingering in Shortcuts / Siri.
        ProfileEntityCache.shared.save([])
    }

    /// Mirrors the in-memory header snapshot to `server`'s scoped Keychain entry:
    /// writes it when non-empty, deletes it when empty so no stale list lingers for
    /// that server (#16).
    private func persistCustomHeaders(for server: URL) {
        let scope = server.absoluteString
        let headers = headerStore.snapshot()
        if let encoded = headers.encodedForStorage() {
            try? keychain.save(encoded, forKey: .customHeaders, scope: scope)
        } else {
            try? keychain.delete(.customHeaders, scope: scope)
        }
    }

    /// Loads `server`'s custom headers into the live snapshot before any client is
    /// built, so the first request after launch already carries them (#255). On the
    /// first launch after the per-server split there's no scoped entry yet, so we
    /// migrate the pre-#16 global blob in place — write it under the scoped key and
    /// drop the global remnant — and use it. One scoped Keychain read on the
    /// steady-state path (#16).
    private func hydrateCustomHeaders(for server: URL) {
        let scope = server.absoluteString
        let stored: String?
        if let scoped = try? keychain.load(.customHeaders, scope: scope) {
            stored = scoped
        } else if let legacy = try? keychain.load(.customHeaders) {
            try? keychain.save(legacy, forKey: .customHeaders, scope: scope)
            try? keychain.delete(.customHeaders)
            stored = legacy
        } else {
            stored = nil
        }
        headerStore.replace(with: [CustomHeader].decodeFromStorage(stored))
    }

    /// Deletes only the cookies that would be sent to `server` (matched by host,
    /// path, and security via `HTTPCookieStorage.cookies(for:)`), so signing out of
    /// or expiring one server leaves other servers' cookies intact (#16).
    ///
    /// Different-host servers are fully isolated this way. Two servers that share a
    /// host but differ only by port still share a cookie jar (cookies aren't
    /// port-scoped) — a documented limitation; closing it would need the per-server
    /// cookie snapshot/restore deferred to the #17 switcher.
    private func clearSessionCookies(for server: URL) {
        let storage = HTTPCookieStorage.shared
        storage.cookies(for: server)?.forEach { storage.deleteCookie($0) }
    }

    /// Clears the entire shared cookie jar. Used only as a fallback when there's no
    /// active server to scope to (a 401 while unconfigured).
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
            // No saved server: nothing is active, so no scoped headers apply.
            state = .unconfigured
            return
        }

        // One-time migration of the saved single server into the multi-server
        // registry (#15). Idempotent: an already-registered server is just
        // re-activated, and its per-server identity is only seeded on first
        // insert, so #17 edits survive relaunch.
        serverRegistry.activate(url: savedURL)
        refreshServers()
        enterActiveServer(savedURL)
    }

    /// Enters `server`, already active in the registry. A webui server's headers are
    /// hydrated (migrating the pre-#16 global blob on the first launch after the split)
    /// before any client is built, so its first request carries them (#255/#16), and it
    /// enters `.loggedIn` optimistically: a stale cookie is demoted by the first 401
    /// (`handleAPIError`). A Hermes server sends no webui headers and is signed in only
    /// while its own record exists; without one its sign-in form shows (#899).
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
