import Foundation

/// Supplies this phone's APNs device token. Nil until the push entitlement and
/// `registerForRemoteNotifications` land (#558): pairing still completes and stores the
/// keys, and the relay registration step is skipped rather than failed.
typealias HermexPushDeviceTokenProvider = @MainActor @Sendable () async -> String?

/// Drives one server's push setup: point the Hermes host at a relay, install and enable
/// the `hermex-push` plugin, restart the gateway, read the pairing keys and register this
/// phone. Every step mutates the user's server, so nothing here runs implicitly — the view
/// calls `enable` only from a confirmed action. A failed run leaves nothing half-paired:
/// the keys are wiped again, and the host returns the same pair on the next attempt.
@MainActor @Observable final class HermexPushProvisioner {
    /// The enable sequence, in the order the host needs it, and the labels the progress
    /// list shows. Disable has its own two steps; they are named where they can fail.
    enum Step: String, CaseIterable, Identifiable {
        case relayURL, install, restart, pair, device
        var id: String { rawValue }
        var title: String {
            switch self {
            case .relayURL: return String(localized: "Set the relay address")
            case .install: return String(localized: "Install the plugin")
            case .restart: return String(localized: "Restart the gateway")
            case .pair: return String(localized: "Pair this iPhone")
            case .device: return String(localized: "Register for notifications")
            }
        }
    }

    /// A step that did not finish, in the step's own words, so the user knows what to retry.
    struct Failure: Equatable { let title: String; let message: String }

    enum Phase: Equatable { case idle, enabling(Step), disabling, failed(Failure) }

    let server: URL
    private(set) var pairing: HermexPushPairing?
    private(set) var phase: Phase = .idle
    /// Steps that finished in the current enable run, so the view can show what is done.
    private(set) var completed: Set<Step> = []

    /// The saved connection this host is reached with. The screen keeps it current so a
    /// password edit made just above this section is the one provisioning signs in with.
    var connection: BotConnection?
    private let store: HermexPushPairingStore
    private let relay: HermexPushRelayClient
    private let dashboard: @MainActor (BotConnection) -> BotDashboardClient
    private let deviceToken: HermexPushDeviceTokenProvider
    /// The connection this server still has saved, read at the moment state is committed.
    private let connectionID: @MainActor () -> UUID?
    /// Retries while the host is coming back from its restart; injected so tests never sleep.
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void

    /// The main-actor collaborators are built here rather than in default arguments,
    /// which Swift evaluates outside the actor.
    init(server: URL, connection: BotConnection?,
         store: HermexPushPairingStore? = nil,
         relay: HermexPushRelayClient = HermexPushRelayClient(),
         dashboard: (@MainActor (BotConnection) -> BotDashboardClient)? = nil,
         deviceToken: @escaping HermexPushDeviceTokenProvider = { nil },
         connectionID: (@MainActor () -> UUID?)? = nil,
         retryDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(5), .seconds(5), .seconds(10)],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.server = server
        self.connection = connection
        self.store = store ?? HermexPushPairingStore()
        self.relay = relay
        self.dashboard = dashboard ?? { BotDashboardClient(connection: $0) }
        self.deviceToken = deviceToken
        self.connectionID = connectionID ?? { (try? BotConnectionStore().load(server: server))?.id }
        self.retryDelays = retryDelays
        self.sleep = sleep
        pairing = try? self.store.load(server: server)
    }

    var isWorking: Bool {
        switch phase {
        case .enabling, .disabling: return true
        case .idle, .failed: return false
        }
    }

    var failure: Failure? { if case .failed(let failure) = phase { return failure }; return nil }

    func isRunning(_ step: Step) -> Bool { phase == .enabling(step) }

    /// The whole setup. The relay address has to be set before the pairing route answers,
    /// and the plugin has to be loaded by a restart before that route exists at all.
    func enable(relayURL text: String) async {
        guard !isWorking else { return }
        guard let connection else { return fail(Step.relayURL.title, HermexPushFailure.noConnection) }
        guard let url = HermexPushPairing.relayURL(text) else {
            return fail(Step.relayURL.title, HermexPushFailure.invalidRelayURL)
        }
        completed = []
        var step = Step.relayURL
        phase = .enabling(step)
        let client = dashboard(connection)
        do {
            try await client.signIn()
            try await client.setEnvironmentValue(HermexPushPairing.relayURLEnvironmentKey, url.absoluteString)
            step = advance(from: step, to: .install)
            try await client.installPlugin(identifier: HermexPushPairing.pluginIdentifier)
            try await client.setPlugin(HermexPushPairing.pluginName, enabled: true)
            step = advance(from: step, to: .restart)
            try await client.restartGateway()
            step = advance(from: step, to: .pair)
            var paired = try await pairAfterRestart(client)
            step = advance(from: step, to: .device)
            let token = await deviceToken()
            if let token { try await relay.register(paired, token: token) }
            // A run outlives the screen, so the connection or its whole server can be
            // removed while it works. Teardown wins: the keys are never written and this
            // phone comes back off the relay.
            guard connectionID() == connection.id else { return await abandon(paired, token: token) }
            paired.deviceToken = token
            try store.save(paired, server: server)
            completed.insert(.device)
            pairing = paired
            phase = .idle
        } catch {
            // Nothing half-paired: the host keeps the same key pair, so a retry gets it back.
            try? store.remove(server: server)
            pairing = nil
            fail(step.title, error)
        }
    }

    /// The way out: drop this phone at the relay, disable the plugin on the host, then
    /// wipe the keys. A failure keeps the keys so the user can retry instead of being left
    /// paired at a relay Hermex can no longer address.
    func disable() async {
        guard !isWorking, let paired = pairing else { return }
        completed = []
        phase = .disabling
        var step = String(localized: "Remove this iPhone from the relay")
        do {
            if let token = paired.deviceToken { try await relay.removeDevice(paired, token: token) }
            step = String(localized: "Disable the plugin")
            if let connection {
                let client = dashboard(connection)
                try await client.signIn()
                try await client.setPlugin(HermexPushPairing.pluginName, enabled: false)
            }
            try? store.remove(server: server)
            pairing = nil
            phase = .idle
        } catch { fail(step, error) }
    }

    /// Finishes a run whose connection was removed under it: nothing is stored, and a
    /// device registered moments ago is dropped again, so a removed connection never
    /// leaves this phone on its relay.
    private func abandon(_ paired: HermexPushPairing, token: String?) async {
        if let token { try? await relay.removeDevice(paired, token: token) }
        try? store.remove(server: server)
        pairing = nil
        phase = .idle
    }

    /// The restart drops the route for a moment, and a freshly installed plugin only
    /// mounts it once the host has reloaded, so a missing route, a relay address the
    /// plugin has not read yet, and a refused connection are all retried.
    private func pairAfterRestart(_ client: BotDashboardClient) async throws -> HermexPushPairing {
        var delays = retryDelays.makeIterator()
        while true {
            do { return try await client.pairing() } catch {
                guard Self.isRestarting(error) else { throw error }
                guard let delay = delays.next() else { throw HermexPushFailure.pairingUnavailable }
                try await sleep(delay)
            }
        }
    }

    private static func isRestarting(_ error: Error) -> Bool {
        switch error {
        case BotFailure.rejected(404), BotFailure.rejected(409), BotFailure.rejected(502),
             BotFailure.rejected(503), BotFailure.transport: return true
        default: return error is URLError
        }
    }

    private func advance(from finished: Step, to next: Step) -> Step {
        completed.insert(finished)
        phase = .enabling(next)
        return next
    }

    private func fail(_ step: String, _ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Could not reach this Hermes host. Check the connection, then try again.")
        phase = .failed(Failure(title: step, message: message))
    }
}
