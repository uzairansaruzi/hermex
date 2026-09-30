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
    struct Failure: Equatable {
        let title: String
        let message: String
        var remedy: Remedy = .none

        /// What the section offers beside a failure (#851). `updatePlugin`: keys an old
        /// plugin sent, which updating it fixes. `retryUpdate`: the update itself stopped,
        /// so the plugin card shows it instead of the red row.
        enum Remedy { case none, updatePlugin, retryUpdate }
    }

    /// The plugin update's host steps (#851), in order, and how the card names them.
    enum PluginUpdateStep: CaseIterable {
        case reinstall, restart, check
        var progress: String {
            switch self {
            case .reinstall: return String(localized: "Step 1 of 3 · Reinstalling the plugin")
            case .restart: return String(localized: "Step 2 of 3 · Restarting the gateway")
            case .check: return String(localized: "Step 3 of 3 · Checking the plugin version")
            }
        }
        var failureTitle: String {
            switch self {
            case .reinstall: return String(localized: "Couldn’t reinstall the plugin")
            case .restart: return String(localized: "Couldn’t restart the gateway")
            case .check: return String(localized: "Couldn’t check the plugin version")
            }
        }
    }

    /// Where this host's hermex-push stands against `HermexPushPlugin.newestVersion`, as the
    /// host last answered (#851). Kept in memory only: the section asks again each time it
    /// appears, so "restart needed" never rests on what this iPhone remembers.
    enum PluginUpdate: Equatable {
        /// Behind the newest; `loaded` is nil for a plugin too old to report its version.
        case available(loaded: HermexPushPluginVersion?)
        /// The newest is on disk, but the dashboard runs the old code until it restarts.
        case restartNeeded
        /// An update or check just brought it to the newest. Shown until Settings closes.
        case upToDate(HermexPushPluginVersion)
        /// The update changed the host, but reading its version failed; the card offers
        /// the read again, never a second reinstall and restart.
        case checkFailed(Failure)
    }

    /// The card at the top of the section: the plugin's standing, the update's progress,
    /// or the step where the update stopped.
    enum PluginCard: Equatable { case status(PluginUpdate), updating(PluginUpdateStep), failed(Failure) }

    /// `checkingPermission` covers the iOS prompt at the start of setup: it blocks re-entry
    /// but names no host step, since none has run yet. `tested` holds the relay's answer to
    /// the Settings test notification until the next action replaces it.
    enum Phase: Equatable {
        case idle, checkingPermission, enabling(Step), disabling, savingPreferences, refreshing, sendingTest
        case updatingPlugin(PluginUpdateStep), checkingPlugin
        case tested(PushRelayTestOutcome)
        case failed(Failure)
    }

    let server: URL
    private(set) var pairing: PushPairing?
    private(set) var phase: Phase = .idle
    /// Steps that finished in the current enable run, so the view can show what is done.
    private(set) var completed: Set<Step> = []
    /// Whether setup, rather than the plugin update or its check, made the last host run,
    /// so a failure lists setup's steps only when setup is what stopped.
    private var setupRanLast = false
    /// iOS notification permission for Hermex is denied, so nothing this server sends can
    /// show. Raised when setup finds it (before any host call) and, on a paired server,
    /// whenever the section checks; cleared once the user allows notifications again.
    private(set) var notificationsOff = false
    private(set) var pluginUpdate: PluginUpdate?

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
    /// Posts Settings' test notification to this pairing's relay; injected so tests never
    /// reach one.
    private let testSender: @MainActor (PushPairing) async -> PushRelayTestOutcome
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
         testSender: (@MainActor (PushPairing) async -> PushRelayTestOutcome)? = nil,
         retryDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(5), .seconds(5), .seconds(10)],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.server = server
        self.connection = connection
        self.registrar = registrar ?? PushRegistrar.shared
        self.notifications = notifications
        self.dashboard = dashboard ?? { BotDashboardClient(saved: $0, server: server) }
        self.connectionID = connectionID ?? { (try? BotConnectionStore().load(server: server))?.id }
        self.testSender = testSender ?? { await PushRelayClient().sendTestNotification(pairing: $0) }
        self.retryDelays = retryDelays
        self.sleep = sleep
        pairing = self.registrar?.pairing(for: server)
    }

    var isWorking: Bool {
        switch phase {
        case .checkingPermission, .enabling, .disabling, .savingPreferences, .refreshing, .sendingTest,
             .updatingPlugin, .checkingPlugin: return true
        case .idle, .tested, .failed: return false
        }
    }

    /// A step's failure, or the test notification's. Both show in the same red row, except
    /// the plugin update's own, which its card shows (`pluginCard`).
    var failure: Failure? {
        switch phase {
        case .failed(let failure): return failure
        case .tested(let outcome): return Self.testFailure(for: outcome)
        default: return nil
        }
    }

    var pluginCard: PluginCard? {
        switch phase {
        case .updatingPlugin(let step): return .updating(step)
        case .failed(let failure) where failure.remedy == .retryUpdate: return .failed(failure)
        default: return pluginUpdate.map(PluginCard.status)
        }
    }

    var testDelivered: Bool { phase == .tested(.delivered) }

    /// The test needs a banner this iPhone can show: with Reply Notifications off the relay
    /// skips it yet still answers accepted, and with iOS notifications off nothing shows.
    var canSendTest: Bool {
        !isWorking && !notificationsOff && pairing?.effectivePreferences.replies == true
    }

    func isRunning(_ step: Step) -> Bool { phase == .enabling(step) }

    /// Whether the step list belongs on screen: while a host step runs, after setup fails,
    /// and after a run that changed the host before stopping (permission revoked mid-run), so
    /// those changes stay visible. Hidden while iOS asks for permission: nothing ran yet.
    /// The plugin update's failures leave it hidden; its card and the red row name them.
    var showsSteps: Bool {
        switch phase {
        case .enabling: return true
        case .failed: return setupRanLast
        case .checkingPermission: return false
        case .idle, .disabling, .savingPreferences, .refreshing, .sendingTest, .tested,
             .updatingPlugin, .checkingPlugin: return !completed.isEmpty
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
        // A removed connection leaves no host to update.
        if connection == nil { pluginUpdate = nil }
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
    /// owns completing the durable transaction after this screen goes away. A test result
    /// and a finished plugin update are cleared too; a test still in flight keeps the
    /// phase, so it stays one request.
    func leaveSettings() {
        switch phase {
        case .savingPreferences, .refreshing, .tested: phase = .idle
        default: break
        }
        if case .upToDate = pluginUpdate { pluginUpdate = nil }
    }

    /// Settings' end-to-end check: one `reply` through this server's relay, to Apple, and
    /// on to every iPhone paired with the host. One call is one request, and a second call
    /// while it runs sends nothing. It says nothing about the host → relay leg.
    func sendTestNotification() async {
        guard canSendTest, let pairing else { return }
        phase = .sendingTest
        phase = .tested(await testSender(pairing))
    }

    /// Nil for delivered. Every other answer names what refused it: this iPhone's
    /// connection, Apple, the relay, or the relay's hosting (#834 answered in Cloudflare's
    /// words, not the relay's JSON). Never the Hermes host: the test does not touch it.
    private static func testFailure(for outcome: PushRelayTestOutcome) -> Failure? {
        let message: String
        switch outcome {
        case .delivered:
            return nil
        case .unreachable:
            message = String(localized: "Couldn’t reach the relay. Check this iPhone’s internet connection, then try again.")
        case .unusablePairing:
            message = Self.message(for: HermexPushFailure.unusablePairing)
        case .rejected(_, "apns_rejected"?):
            message = String(localized: "Apple refused the test notification. Turn notifications off and on again for this server.")
        case .rejected(let status, "delivery_retry"?), .rejected(let status, "temporarily_unavailable"?),
             .rejected(let status, "event_limit"?):
            message = String(localized: "The relay couldn’t deliver the test right now (HTTP \(status)). Try again in a few minutes.")
        case .rejected(let status, nil):
            message = String(localized: "The relay’s hosting refused the request (HTTP \(status)). The relay may be over its daily limit or switched off.")
        case .rejected(let status, _):
            message = String(localized: "The relay couldn’t deliver (HTTP \(status)).")
        }
        return Failure(title: String(localized: "Test notification failed"), message: message,
                       remedy: outcome == .unusablePairing ? .updatePlugin : .none)
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
        setupRanLast = true
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
            // Its install enables the plugin again, so the update goes with the pairing.
            pluginUpdate = nil
            phase = .idle
        } catch { fail(step, error) }
    }

    /// The section's one passive read (#851), each time it appears on a paired server: the
    /// pairing route's `plugin_version`, then the hub only when that is behind. Reads alone,
    /// so no confirmation; a host that doesn't answer leaves the card as it was.
    func checkPlugin() async {
        guard pairing != nil, let connection, !isUpdatingPlugin else { return }
        guard let standing = try? await pluginStanding(dashboard(connection)), !Task.isCancelled,
              pairing != nil, !isUpdatingPlugin else { return }
        // A plugin already on the newest needs no card; only an update run says so.
        if case .upToDate = standing { pluginUpdate = nil } else { pluginUpdate = standing }
    }

    /// "Check again" once the host has been restarted, or after a failed read: one read,
    /// whose answer replaces the card. A failure goes to the red row and leaves the card
    /// standing, except a card that is itself a failed read, which takes the newer answer.
    func checkPluginAgain() async {
        guard !isWorking, let connection else { return }
        setupRanLast = false
        phase = .checkingPlugin
        do {
            pluginUpdate = try await pluginStanding(dashboard(connection))
            phase = .idle
        } catch {
            guard case .checkFailed = pluginUpdate else { return fail(PluginUpdateStep.check.failureTitle, error) }
            pluginUpdate = .checkFailed(Self.checkFailure(error))
            phase = .idle
        }
    }

    /// Settings' plugin update (#851), from a confirmed tap only: turn hermex-push off,
    /// reinstall it over itself (cloned again from `main`, which turns it back on), restart
    /// the gateway, then read what the host has loaded. Current Hermes asks at a terminal
    /// before it replaces an enabled plugin that declares Python packages, and refuses the
    /// dashboard's reinstall; a disabled one skips that question, and enabling it runs
    /// Hermes's own dependency admission. The keys stay in `plugin-data`, so a paired phone
    /// stays paired; an update started from a pairing failure ends here too, since pairing
    /// waits for its own tap.
    /// The dashboard that serves the pairing route and runs Bot turns loads plugins only
    /// when it starts, and no route restarts it, so "restart needed" is the usual end.
    func updatePlugin() async {
        guard !isWorking else { return }
        setupRanLast = false
        guard let connection else {
            phase = .failed(Failure(title: PluginUpdateStep.reinstall.failureTitle,
                                    message: Self.message(for: HermexPushFailure.noConnection), remedy: .retryUpdate))
            return
        }
        completed = []
        var step = PluginUpdateStep.reinstall
        phase = .updatingPlugin(step)
        let client = dashboard(connection)
        do { try await client.signIn() } catch { return failSignIn(error, remedy: .retryUpdate) }
        do {
            var turnedOff = false
            do {
                try await client.setPlugin(HermexPushPlugin.name, enabled: false)
                turnedOff = true
                try await client.installPlugin(identifier: HermexPushPlugin.installIdentifier)
            } catch {
                // Turning a plugin off only edits the host's config, so the running gateway keeps
                // it; turning it back on keeps the next restart from dropping push. A disable that
                // failed may still have landed, so it is undone too; enabling an enabled plugin is a
                // no-op. Only a confirmed disable is reported as left off.
                let failure = error
                do { try await client.setPlugin(HermexPushPlugin.name, enabled: true) } catch {
                    if turnedOff { throw HermexPushFailure.pluginLeftOff }
                    throw failure
                }
                throw failure
            }
            step = .restart
            phase = .updatingPlugin(step)
            try await client.restartGateway()
            step = .check
            phase = .updatingPlugin(step)
            pluginUpdate = try await afterRestart { try await self.pluginStanding(client) }
            phase = .idle
        } catch where step == .check {
            // The host already took the reinstall and the restart; only the read is left to retry.
            pluginUpdate = .checkFailed(Self.checkFailure(error))
            phase = .idle
        } catch {
            phase = .failed(Failure(title: step.failureTitle, message: Self.message(for: error), remedy: .retryUpdate))
        }
    }

    private static func checkFailure(_ error: Error) -> Failure {
        Failure(title: PluginUpdateStep.check.failureTitle, message: message(for: error))
    }

    private var isUpdatingPlugin: Bool {
        switch phase {
        case .updatingPlugin, .checkingPlugin: return true
        default: return false
        }
    }

    /// Where the host's plugin stands. The hub is read only for a loaded plugin that is
    /// behind: its on-disk version tells a copy waiting for a restart from one that still
    /// needs updating. A host without the hub, or one that fails it, reads as the latter.
    private func pluginStanding(_ client: BotDashboardClient) async throws -> PluginUpdate {
        let loaded = try await client.loadedPluginVersion()
        if let loaded, loaded >= HermexPushPlugin.newestVersion { return .upToDate(loaded) }
        if let installed = try? await client.installedPluginVersion(), installed >= HermexPushPlugin.newestVersion {
            return .restartNeeded
        }
        return .available(loaded: loaded)
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
        pluginUpdate = nil
        phase = .idle
    }

    /// The restart drops the route for a moment, and a freshly installed plugin only
    /// mounts it once the host has reloaded, so a missing route, a relay address the
    /// plugin has not read yet, and a refused connection are all retried.
    private func pairAfterRestart(_ client: BotDashboardClient) async throws -> PushPairing {
        try await afterRestart { try await client.pairing() }
    }

    /// Runs `read` until the host answers it or the retry schedule runs out.
    private func afterRestart<T>(_ read: () async throws -> T) async throws -> T {
        var delays = retryDelays.makeIterator()
        while true {
            do { return try await read() } catch {
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

    /// A failure whose words send the user to update the plugin also offers that update.
    private func fail(_ step: String, _ error: Error) {
        phase = .failed(Failure(title: step, message: Self.message(for: error),
                                remedy: Self.needsNewerPlugin(error) ? .updatePlugin : .none))
    }

    /// Keys an old plugin sent, the errors `message(for:)` answers with "Update the
    /// hermex-push plugin."
    private static func needsNewerPlugin(_ error: Error) -> Bool {
        switch error {
        case HermexPushFailure.unusablePairing, PushRegistrarError.malformedPairing,
             PushRelayError.malformedInstallKey: return true
        default: return false
        }
    }

    /// Sign-in changes nothing on the host, so a connection that fails there really is
    /// unreachable, unlike a later step that may still be finishing when it times out.
    private func failSignIn(_ error: Error, remedy: Failure.Remedy = .none) {
        let message = switch error {
        case BotFailure.transport, is URLError:
            String(localized: "Could not reach this Hermes host. Check the connection, then try again.")
        default: Self.message(for: error)
        }
        phase = .failed(Failure(title: String(localized: "Sign in to Hermes"), message: message, remedy: remedy))
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
        case BotFailure.blocked, BotFailure.browserSignIn:
            return error.localizedDescription
        case BotFailure.rejected(let status):
            return String(localized: "This Hermes host refused the step (HTTP \(status)). Check the host’s logs, then try again.")
        case BotFailure.unsupported, BotFailure.wrongIdentity, BotFailure.notDashboard:
            return String(localized: "This Hermes host doesn’t offer the password sign-in push setup needs.")
        case BotFailure.transport, is URLError:
            return String(localized: "The host did not answer in time. It may still be finishing this step — wait a moment, then try again.")
        default:
            return String(localized: "This step did not finish. Try again.")
        }
    }
}
