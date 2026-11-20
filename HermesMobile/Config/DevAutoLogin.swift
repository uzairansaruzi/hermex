#if DEBUG
import Foundation

@MainActor
enum DevAutoLogin {
    private static var inFlight: Task<Void, Never>?
    private static var didOpenHermesServer = false

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

        await connectBot(server: server, environment: environment)

        switch authManager.state {
        case .loggedIn:
            break
        case .loggedOut(let active) where authManager.kind(of: active) == .hermes:
            break
        case .loggedOut, .unconfigured:
            await authManager.configure(
                serverURLString: serverText,
                password: environment["HERMEX_DEV_PASSWORD"] ?? ""
            )
            if let message = authManager.lastErrorMessage {
                NSLog("DevAutoLogin: server login failed: %@", message)
            }
        }

        if environment["HERMEX_DEV_HERMES_SERVER"] == "1", !didOpenHermesServer {
            didOpenHermesServer = true
            await openHermesServer(authManager: authManager, environment: environment)
        }
    }

    private static func openHermesServer(authManager: AuthManager, environment: [String: String]) async {
        guard let addressText = environment["HERMEX_DEV_BOT_ADDRESS"],
              let username = environment["HERMEX_DEV_BOT_USERNAME"],
              let password = environment["HERMEX_DEV_BOT_PASSWORD"],
              let address = try? BotConnection.address(addressText) else { return }
        UserDefaults.standard.set(true, forKey: BotModeGate.isEnabledKey)
        if let account = authManager.servers.first(where: { $0.id == address.absoluteString }) {
            authManager.switchActiveServer(to: account)
            return
        }
        do {
            var connection = BotConnection(id: UUID(), name: address.host ?? "Hermes",
                                           address: address, username: username, password: password)
            let wire = BotClient(connection: connection)
            defer { wire.close() }
            try await wire.connect()
            connection.hermesVersion = wire.serverVersion
            connection.installID = wire.serverInstallID
            if !authManager.addHermesServer(connection) {
                NSLog("DevAutoLogin: adding the Hermes server failed: %@", authManager.lastErrorMessage ?? "Bot Mode is off")
            }
            authManager.moveOffer = nil
        } catch {
            NSLog("DevAutoLogin: Hermes server login failed: %@", String(describing: error))
        }
    }

    private static func connectBot(server: URL, environment: [String: String]) async {
        let store = BotConnectionStore()
        guard let addressText = environment["HERMEX_DEV_BOT_ADDRESS"],
              let username = environment["HERMEX_DEV_BOT_USERNAME"],
              let password = environment["HERMEX_DEV_BOT_PASSWORD"] else { return }
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
