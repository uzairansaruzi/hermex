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
        String(localized: "This server signs in with passkeys, which Zora doesn't support yet.")

    private(set) var state: State = .unconfigured
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

    init(
        keychain: any KeychainStoring = KeychainStore(),
        clientFactory: @escaping (URL) -> any AuthAPIClient = { APIClient(baseURL: $0) },
        probeClientFactory: @escaping (URL, [CustomHeader]) -> any AuthAPIClient = { url, headers in
            APIClient(baseURL: url, customHeaderProvider: { headers })
        },
        headerStore: CustomHeaderStore = .shared,
        logoutTimeout: Duration = .seconds(5),
        serverRegistry: ServerRegistry = .shared
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.probeClientFactory = probeClientFactory
        self.headerStore = headerStore
        self.logoutTimeout = logoutTimeout
        self.serverRegistry = serverRegistry
        restoreSavedServer()
        refreshServers()
    }

    /// The active server's id (its normalized URL string), or nil when
    /// unconfigured. Used by the Settings list to mark which row is active.
    var activeServerID: String? { state.server?.absoluteString }

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
            let client = clientFactory(serverURL)
            let authStatus = try await testConnection(client: client)

            // Passkey-only: auth is on but the server explicitly reports password
            // auth off. Only an explicit false counts — a missing field means an
            // older server that doesn't report it, so we must fall through to the
            // password path and never block a working password user (#255).
            if authStatus.authEnabled == true, authStatus.passwordAuthEnabled == false {
                lastErrorMessage = Self.passkeyOnlyMessage
                return
            }

            if authStatus.authEnabled == true {
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

            if authStatus.authEnabled == true, authStatus.passwordAuthEnabled == false {
                lastErrorMessage = Self.passkeyOnlyMessage
                return .failed
            }

            if authStatus.authEnabled == true {
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
    /// exactly as before (sign out → onboarding).
    func signOut() async {
        guard let active = state.server else {
            // Defensive: nothing is active. Safe full reset to onboarding.
            clearLocalAuth(for: nil)
            state = .unconfigured
            return
        }

        if case .loggedIn = state {
            await attemptBestEffortServerLogout(server: active)
        }

        advanceAfterRemoving(activeServer: active)
    }

    /// Removes a configured server. When it's the active one this behaves like
    /// `signOut` (best-effort server logout + auto-switch / onboarding). A
    /// non-active server is just dropped locally — its registry row, scoped
    /// headers, and cookies — leaving the active server's auth untouched (#17).
    func removeServer(_ account: ServerAccount) async {
        guard let serverURL = URL(string: account.urlString) else { return }
        let isActive = state.server?.absoluteString == account.id

        if isActive {
            if case .loggedIn = state {
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
    /// switcher). Mirrors the cold-launch path: persist the URL, set it active,
    /// hydrate its scoped headers, and optimistically enter `.loggedIn`. A stale
    /// cookie is demoted to `.loggedOut` by the first request's 401
    /// (`handleAPIError`), exactly like a relaunch — so no extra round-trip here.
    func switchActiveServer(to account: ServerAccount) {
        guard account.id != state.server?.absoluteString,
              let serverURL = URL(string: account.urlString) else { return }

        serverRegistry.setActive(id: account.id)
        refreshServers()
        try? keychain.save(serverURL.absoluteString, forKey: .serverURL)
        hydrateCustomHeaders(for: serverURL)
        // Drop the App Intents profile picker cache (#339): it holds the previous server's
        // profiles, which would leak into Shortcuts / Siri if the new server's fetch is
        // delayed or fails. The new server's profiles reload on the next foreground fetch.
        ProfileEntityCache.shared.save([])
        lastErrorMessage = nil
        state = .loggedIn(server: serverURL)
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
            hydrateCustomHeaders(for: nextURL)
            lastErrorMessage = nil
            state = .loggedIn(server: nextURL)
        } else {
            try? keychain.delete(.serverURL)
            headerStore.replace(with: [])
            state = .unconfigured
        }
    }

    /// Deletes one server's local auth artifacts — its scoped custom headers and
    /// its cookies — without touching the registry or the global `server_url` key.
    private func clearLocalArtifacts(for server: URL) {
        try? keychain.delete(.customHeaders, scope: server.absoluteString)
        clearSessionCookies(for: server)
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
        // Hydrate this server's headers (migrating the pre-#16 global blob on the
        // first launch after the split) before any client is built, so the first
        // request after launch carries the saved headers (#255/#16).
        hydrateCustomHeaders(for: savedURL)
        state = .loggedIn(server: savedURL)
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
