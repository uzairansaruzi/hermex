import Foundation
import UserNotifications

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

    /// `checkingPermission` covers the iOS prompt at the start of setup: it blocks re-entry
    /// but names no host step, since none has run yet.
    enum Phase: Equatable { case idle, checkingPermission, enabling(Step), disabling, savingPreferences, refreshing, failed(Failure) }

    let server: URL
    private(set) var pairing: PushPairing?
    private(set) var phase: Phase = .idle
    /// Steps that finished in the current enable run, so the view can show what is done.
    private(set) var completed: Set<Step> = []
    /// iOS notification permission for Hermex is denied, so nothing this server sends can
    /// show. Raised when setup finds it (before any host call) and, on a paired server,
    /// whenever the section checks; cleared once the user allows notifications again.
    private(set) var notificationsOff = false

    /// The saved connection this host is reached with. The screen keeps it current so a
    /// password edit made just above this section is the one provisioning signs in with.
    var connection: BotConnection?
    /// Nil on a build with no Keychain access group to write to, which means push cannot
    /// work at all; the section then reports the step it could not take.
    private let registrar: (any PushPairingEnabling)?
    private let notifications: any ResponseCompletionNotificationScheduling
    private let dashboard: @MainActor (BotConnection) -> BotDashboardClient
    /// The connection this server still has saved, read at the moment state is committed.
    private let connectionID: @MainActor () -> UUID?
    /// Retries while the host is coming back from its restart; injected so tests never sleep.
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void

    /// The main-actor collaborators are built here rather than in default arguments,
    /// which Swift evaluates outside the actor.
    init(server: URL, connection: BotConnection?,
         registrar: (any PushPairingEnabling)? = nil,
         notifications: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler(),
         dashboard: (@MainActor (BotConnection) -> BotDashboardClient)? = nil,
         connectionID: (@MainActor () -> UUID?)? = nil,
         retryDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(5), .seconds(5), .seconds(10)],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.server = server
        self.connection = connection
        self.registrar = registrar ?? PushRegistrar.shared
        self.notifications = notifications
        self.dashboard = dashboard ?? { BotDashboardClient(connection: $0) }
        self.connectionID = connectionID ?? { (try? BotConnectionStore().load(server: server))?.id }
        self.retryDelays = retryDelays
        self.sleep = sleep
        pairing = self.registrar?.pairing(for: server)
    }

    var isWorking: Bool {
        switch phase {
        case .checkingPermission, .enabling, .disabling, .savingPreferences, .refreshing: return true
        case .idle, .failed: return false
        }
    }

    var failure: Failure? { if case .failed(let failure) = phase { return failure }; return nil }

    func isRunning(_ step: Step) -> Bool { phase == .enabling(step) }

    /// Whether the step list belongs on screen: while a host step runs, after a failure, and
    /// after a run that changed the host before stopping (permission revoked mid-run), so
    /// those changes stay visible. Hidden while iOS asks for permission: nothing ran yet.
    var showsSteps: Bool {
        switch phase {
        case .enabling, .failed: return true
        case .checkingPermission: return false
        case .idle, .disabling, .savingPreferences, .refreshing: return !completed.isEmpty
        }
    }

    /// Re-reads local state when Settings returns from editing the connection.
    func reload() async {
        guard !isWorking else { return }
        phase = .refreshing
        await registrar?.finishPendingRegistrations()
        guard !Task.isCancelled else { return }
        connection = try? BotConnectionStore().load(server: server)
        pairing = registrar?.pairing(for: server)
        phase = .idle
        if let pairing, pairing.preferencesNeedSync == true {
            await updatePreferences(pairing.effectivePreferences)
        }
    }

    func updatePreferences(_ preferences: PushPreferences) async {
        guard !isWorking, let expected = pairing, let registrar else { return }
        phase = .savingPreferences
        do {
            try await registrar.updatePreferences(preferences, for: server, expectedPairing: expected)
            guard !Task.isCancelled else { return }
            pairing = registrar.pairing(for: server)
            phase = .idle
        } catch {
            guard !Task.isCancelled else { return }
            pairing = registrar.pairing(for: server)
            phase = .failed(Failure(title: String(localized: "Couldn’t save preferences"),
                                    message: String(localized: "Try again.")))
        }
    }

    /// The view cancels only its presentation of a preference write. The registrar
    /// owns completing the durable transaction after this screen goes away.
    func leaveSettings() {
        if phase == .savingPreferences || phase == .refreshing { phase = .idle }
    }

    /// The whole setup. A host that already answers the pairing route has its relay set
    /// and the plugin loaded, so it is paired as it stands: no install, and no restart
    /// interrupting work. Anything else gets the full sequence, in the order the host
    /// needs it — the relay address before the pairing route will answer, and the plugin
    /// loaded by a restart before that route exists at all. Denied notification permission
    /// stops the run before it signs in, so the host is never touched for a phone that
    /// could not show what it sends.
    func enable() async {
        guard !isWorking else { return }
        guard let connection else { return fail(Step.relayURL.title, HermexPushFailure.noConnection) }
        completed = []
        phase = .checkingPermission
        // Permission comes first: a phone that cannot show a notification must not get as
        // far as reinstalling the plugin and restarting the gateway.
        notificationsOff = !(await notificationsAllowed())
        guard !notificationsOff else { phase = .idle; return }
        var step = Step.relayURL
        phase = .enabling(step)
        let client = dashboard(connection)
        do { try await client.signIn() } catch { return failSignIn(error) }
        do {
            let state: HostState
            do { state = try await hostState(client) } catch { return fail(Step.pair.title, error) }
            var paired: PushPairing
            switch state {
            case .paired(let configured):
                completed.formUnion([.relayURL, .install, .restart])
                step = .pair
                phase = .enabling(step)
                paired = configured
            case .relayUnset:
                // The plugin is there and loaded; it only lacks somewhere to send to. The
                // plugin re-reads the value, so this needs no reinstall and no restart.
                try await client.setEnvironmentValue(HermexPushPlugin.relayURLEnvironmentKey,
                                                     HermexPushPlugin.defaultRelayURL.absoluteString)
                completed.formUnion([.relayURL, .install, .restart])
                step = .pair
                phase = .enabling(step)
                paired = try await pairAfterRestart(client)
            case .notInstalled:
                try await client.setEnvironmentValue(HermexPushPlugin.relayURLEnvironmentKey,
                                                     HermexPushPlugin.defaultRelayURL.absoluteString)
                step = advance(from: step, to: .install)
                try await client.installPlugin(identifier: HermexPushPlugin.installIdentifier)
                try await client.setPlugin(HermexPushPlugin.name, enabled: true)
                step = advance(from: step, to: .restart)
                try await client.restartGateway()
                step = advance(from: step, to: .pair)
                paired = try await pairAfterRestart(client)
            }
            step = advance(from: step, to: .device)
            guard let registrar else { throw PushRegistrarError.unsupportedBuild }
            // Asks for notification permission, mints a device token and registers it at
            // this install's relay. It stores the keys only once the relay has accepted.
            do { try await registrar.enable(paired, for: server) } catch PushRegistrarError.permissionDenied {
                // Permission was revoked while the host was being set up.
                pairing = registrar.pairing(for: server)
                notificationsOff = true
                phase = .idle
                return
            }
            // A run outlives the screen, so the connection or its whole server can be
            // removed while it works. Teardown wins: what was just stored goes again and
            // this phone comes back off the relay.
            guard connectionID() == connection.id else { return await abandon() }
            completed.insert(.device)
            pairing = registrar.pairing(for: server)
            phase = .idle
        } catch {
            // Nothing half-paired: the registrar undoes its own registration, and the host
            // keeps the same key pair, so a retry gets it back.
            pairing = registrar?.pairing(for: server)
            fail(step.title, error)
        }
    }

    /// The way out: stop the host sending, then drop this phone at the relay and wipe its
    /// keys. The host goes first so a failure at either step changes nothing the user has
    /// to unpick — they can simply try again.
    func disable() async {
        guard !isWorking, pairing != nil else { return }
        completed = []
        phase = .disabling
        var step = String(localized: "Disable the plugin")
        do {
            if let connection {
                let client = dashboard(connection)
                do { try await client.signIn() } catch { return failSignIn(error) }
                try await client.setPlugin(HermexPushPlugin.name, enabled: false)
            }
            step = String(localized: "Remove this iPhone from the relay")
            try await registrar?.disable(for: server)
            pairing = registrar?.pairing(for: server)
            phase = .idle
        } catch { fail(step, error) }
    }

    /// Clears the notifications-off state once the user has allowed notifications in iOS
    /// Settings, and on a paired server also raises it, since a phone whose permission
    /// was later denied silently stops showing this server's pushes. It never starts
    /// setup itself: host changes stay behind the confirmation.
    func recheckNotificationPermission() async {
        guard pairing != nil || notificationsOff else { return }
        let denied = await notifications.authorizationStatus() == .denied
        guard !Task.isCancelled else { return }
        notificationsOff = denied
    }

    /// Asks iOS only when the user has never been asked. A refusal, now or earlier, is final
    /// here: iOS shows no second prompt, so only Settings can change it.
    private func notificationsAllowed() async -> Bool {
        switch await notifications.authorizationStatus() {
        case .notDetermined: return await notifications.requestAuthorization()
        case .denied: return false
        case .authorized, .provisional, .ephemeral: return true
        @unknown default: return false
        }
    }

    /// What the pairing route says this host still needs. Only an absent route or an
    /// unset relay mean "not set up yet": a timeout, a server error, or keys this build
    /// cannot read are thrown on instead, because reinstalling and restarting on those
    /// would replace a self-hosted relay and interrupt work over a failure that had
    /// nothing to do with setup.
    private enum HostState { case paired(PushPairing), relayUnset, notInstalled }

    private func hostState(_ client: BotDashboardClient) async throws -> HostState {
        do { return .paired(try await client.pairing()) } catch BotFailure.rejected(let status) {
            switch status {
            case 404: return .notInstalled
            case 409: return .relayUnset
            default: throw BotFailure.rejected(status)
            }
        }
    }

    /// Finishes a run whose connection was removed under it: nothing is stored, and a
    /// device registered moments ago is dropped again, so a removed connection never
    /// leaves this phone on its relay.
    private func abandon() async {
        await registrar?.forget(for: server)
        pairing = nil
        phase = .idle
    }

    /// The restart drops the route for a moment, and a freshly installed plugin only
    /// mounts it once the host has reloaded, so a missing route, a relay address the
    /// plugin has not read yet, and a refused connection are all retried.
    private func pairAfterRestart(_ client: BotDashboardClient) async throws -> PushPairing {
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
        phase = .failed(Failure(title: step, message: Self.message(for: error)))
    }

    /// Sign-in changes nothing on the host, so a connection that fails there really is
    /// unreachable, unlike a later step that may still be finishing when it times out.
    private func failSignIn(_ error: Error) {
        let message = switch error {
        case BotFailure.transport, is URLError:
            String(localized: "Could not reach this Hermes host. Check the connection, then try again.")
        default: Self.message(for: error)
        }
        phase = .failed(Failure(title: String(localized: "Sign in to Hermes"), message: message))
    }

    /// Provisioning speaks for itself rather than borrowing the Bot chat's wording: a step
    /// that failed says what answered — the host, the relay or iOS — because that is what
    /// the user has to act on. The registrar's and relay's errors are switched exhaustively
    /// so a new case cannot fall through to someone else's words.
    static func message(for error: Error) -> String {
        switch error {
        case let failure as HermexPushFailure:
            return failure.errorDescription ?? String(localized: "This step did not finish. Try again.")
        case let failure as PushRegistrarError:
            switch failure {
            case .permissionDenied:
                return String(localized: "Allow notifications for Hermex in iOS Settings, then turn this on again.")
            case .unsupportedBuild:
                return String(localized: "This build of Hermex can’t receive push notifications.")
            case .tokenUnavailable:
                return String(localized: "iOS gave no notification token. Check this iPhone’s internet connection, then try again.")
            case .malformedPairing:
                return message(for: HermexPushFailure.unusablePairing)
            case .pairingChanged, .preferencesUnconfirmed:
                return String(localized: "This step did not finish. Try again.")
            }
        case let failure as PushRelayError:
            switch failure {
            case .http(let statusCode):
                return String(localized: "The relay refused this phone (\(statusCode)). Check the relay address, then try again.")
            case .malformedInstallKey:
                return message(for: HermexPushFailure.unusablePairing)
            case .transport:
                return String(localized: "Could not reach the notification relay. Check this iPhone’s internet connection, then try again.")
            }
        case BotFailure.rejected(401), BotFailure.rejected(403):
            return String(localized: "This Hermes host rejected the saved sign-in. Update the Hermes connection, then try again.")
        case BotFailure.differentHost:
            return BotFailure.differentHost.localizedDescription
        case BotFailure.rejected(let status):
            return String(localized: "This Hermes host refused the step (HTTP \(status)). Check the host’s logs, then try again.")
        case BotFailure.unsupported, BotFailure.wrongIdentity:
            return String(localized: "This Hermes host doesn’t offer the password sign-in push setup needs.")
        case BotFailure.transport, is URLError:
            return String(localized: "The host did not answer in time. It may still be finishing this step — wait a moment, then try again.")
        default:
            return String(localized: "This step did not finish. Try again.")
        }
    }
}
