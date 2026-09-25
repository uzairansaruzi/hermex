#if DEBUG
import Foundation

/// Debug-only sign-in from launch environment variables, so an agent driving a
/// simulator is never blocked on the login screen. `scripts/sim-login <udid>`
/// reads the credentials from the macOS Keychain and passes them through
/// `SIMCTL_CHILD_*`; see `DEVELOPMENT.md`. Both logins go through the normal
/// paths, so credentials land in the simulator's Keychain as a manual login would.
///
/// - `HERMEX_DEV_SERVER_URL`, `HERMEX_DEV_PASSWORD`: the webui server.
/// - `HERMEX_DEV_BOT_ADDRESS`, `HERMEX_DEV_BOT_USERNAME`, `HERMEX_DEV_BOT_PASSWORD`:
///   the Bot connection saved under that server. Also turns Bot Mode on.
@MainActor
enum DevAutoLogin {
    /// The sign-in under way, if any. It is owned here rather than by the calling
    /// view task, because the root view is rebuilt during launch and a cancelled
    /// view task would cancel the login requests with it.
    private static var inFlight: Task<Void, Never>?

    /// Called from the root view's `.task(id: authManager.state)`, so an expired
    /// session signs back in. Concurrent calls share one attempt. A failed login
    /// leaves the state unchanged and is therefore not retried.
    static func run(
        authManager: AuthManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        if let inFlight { return await inFlight.value }
        let task = Task { await signIn(authManager: authManager, environment: environment) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private static func signIn(authManager: AuthManager, environment: [String: String]) async {
        guard let serverText = environment["HERMEX_DEV_SERVER_URL"],
              let server = try? AuthManager.normalizedServerURL(from: serverText) else { return }

        // The Bot connection is saved first so the Bots inbox finds it on first load.
        await connectBot(server: server, environment: environment)

        if case .loggedIn = authManager.state { return }
        await authManager.configure(
            serverURLString: serverText,
            password: environment["HERMEX_DEV_PASSWORD"] ?? ""
        )
        if let message = authManager.lastErrorMessage {
            NSLog("DevAutoLogin: server login failed: %@", message)
        }
    }

    private static func connectBot(server: URL, environment: [String: String]) async {
        let store = BotConnectionStore()
        guard let addressText = environment["HERMEX_DEV_BOT_ADDRESS"],
              let username = environment["HERMEX_DEV_BOT_USERNAME"],
              let password = environment["HERMEX_DEV_BOT_PASSWORD"] else { return }
        // Turning Bot Mode off keeps the saved connection, so the gate is restored either way.
        if (try? store.load(server: server)) != nil {
            UserDefaults.standard.set(true, forKey: BotModeGate.isEnabledKey)
            return
        }
        do {
            let address = try BotConnection.address(addressText)
            var connection = BotConnection(id: UUID(), name: address.host ?? "Hermes",
                                           address: address, username: username, password: password)
            let wire = BotClient(connection: connection)
            defer { wire.close() }
            try await wire.connect()
            connection.hermesVersion = wire.serverVersion
            connection.installID = wire.serverInstallID
            try store.save(connection, server: server)
            UserDefaults.standard.set(true, forKey: BotModeGate.isEnabledKey)
        } catch {
            NSLog("DevAutoLogin: bot login failed: %@", String(describing: error))
        }
    }
}
#endif
