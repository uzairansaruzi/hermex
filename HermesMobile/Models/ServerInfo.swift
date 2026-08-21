import Foundation

struct HealthResponse: Decodable {
    let status: String?
    let sessions: Int?
    let activeStreams: Int?
    let uptimeSeconds: Double?
}

struct AuthStatusResponse: Decodable {
    let authEnabled: Bool?
    let loggedIn: Bool?
    /// Finer-grained capabilities newer servers report. All optional so older
    /// servers that omit them decode unchanged. `password_auth_enabled == false`
    /// (and only an explicit false) marks a passkey-only server we can't sign
    /// into yet (#255); a missing value means "unknown" → treat as today.
    let passwordAuthEnabled: Bool?
    let passkeysEnabled: Bool?
    let passwordlessEnabled: Bool?
    /// Set when the server offers single sign-on. `is_auth_enabled()` upstream
    /// covers password, OIDC *and* trusted-header, so "auth on, password off"
    /// on its own never meant passkeys (#3).
    let oidcEnabled: Bool?
    /// Set when an identity proxy in front of the server authenticates the
    /// request (Cloudflare Access, Authentik). Present only when that mode is
    /// on, so nil means "not that kind of server".
    let trustedAuthEnabled: Bool?

    /// The server already considers this client signed in. Trusted-header
    /// deployments authenticate at the proxy, so there is no credential for the
    /// app to send and no login step to perform.
    var isAlreadySignedIn: Bool { loggedIn == true }

    init(
        authEnabled: Bool? = nil,
        loggedIn: Bool? = nil,
        passwordAuthEnabled: Bool? = nil,
        passkeysEnabled: Bool? = nil,
        passwordlessEnabled: Bool? = nil,
        oidcEnabled: Bool? = nil,
        trustedAuthEnabled: Bool? = nil
    ) {
        self.authEnabled = authEnabled
        self.loggedIn = loggedIn
        self.passwordAuthEnabled = passwordAuthEnabled
        self.passkeysEnabled = passkeysEnabled
        self.passwordlessEnabled = passwordlessEnabled
        self.oidcEnabled = oidcEnabled
        self.trustedAuthEnabled = trustedAuthEnabled
    }
}

struct LoginResponse: Decodable {
    let ok: Bool?
    let message: String?
    let error: String?
}
