import Foundation
import UserNotifications

@MainActor @Observable final class HermexPushProvisioner {
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

    struct Failure: Equatable {
        let title: String
        let message: String
        var remedy: Remedy = .none

        enum Remedy { case none, updatePlugin, retryUpdate, retryRestart }
    }

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

    enum PluginUpdate: Equatable {
        case available(loaded: HermexPushPluginVersion?)
        case newer(loaded: HermexPushPluginVersion, target: String)
        case restartNeeded(loaded: HermexPushPluginVersion?)
        case setupNeedsRestart
        case restartTimedOut
        case upToDate(HermexPushPluginVersion)
        case checkFailed(Failure)
    }

    enum PluginCard: Equatable { case status(PluginUpdate), updating(PluginUpdateStep), restarting, failed(Failure) }

    enum Phase: Equatable {
        case idle, checkingPermission, enabling(Step), disabling, savingPreferences, refreshing, sendingTest
        case updatingPlugin(PluginUpdateStep), checkingPlugin, restartingHermes
        case tested(PushRelayTestOutcome)
        case failed(Failure)
    }

    let server: URL
    private(set) var pairing: PushPairing?
    private(set) var phase: Phase = .idle
    private(set) var completed: Set<Step> = []
    private var setupRanLast = false
    private(set) var notificationsOff = false
    private(set) var pluginUpdate: PluginUpdate?
    private(set) var servesWebapp = false
    private var pluginCheckGeneration = 0

    var connection: BotConnection?
    private let registrar: (any PushPairingEnabling)?
    private let notifications: any ResponseCompletionNotificationScheduling
    private let dashboard: @MainActor (BotConnection) -> BotDashboardClient
    private let connectionID: @MainActor () -> UUID?
    private let testSender: @MainActor (PushPairing) async -> PushRelayTestOutcome
    private let retryDelays: [Duration]
    private let restartDelays: [Duration]
    private let minimumPlugin: HermexPushPluginVersion
    private let hostListing: @MainActor (BotDashboardClient) async -> HermexPushHostListing?
    private let offers: HermexPushUpdateOffers
    private let sleep: @Sendable (Duration) async throws -> Void

    init(server: URL, connection: BotConnection?,
         registrar: (any PushPairingEnabling)? = nil,
         notifications: any ResponseCompletionNotificationScheduling = UserNotificationResponseCompletionScheduler(),
         dashboard: (@MainActor (BotConnection) -> BotDashboardClient)? = nil,
         connectionID: (@MainActor () -> UUID?)? = nil,
         testSender: (@MainActor (PushPairing) async -> PushRelayTestOutcome)? = nil,
         retryDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(5), .seconds(5), .seconds(10)],
         restartDelays: [Duration] = [.seconds(2), .seconds(2), .seconds(3), .seconds(3), .seconds(5), .seconds(5),
                                      .seconds(10), .seconds(10), .seconds(10), .seconds(10)],
         minimumPlugin: HermexPushPluginVersion = HermexPushPlugin.minimumVersion,
         hostListing: (@MainActor (BotDashboardClient) async -> HermexPushHostListing?)? = nil,
         offers: HermexPushUpdateOffers? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.server = server
        self.connection = connection
        self.registrar = registrar ?? PushRegistrar.shared
        self.notifications = notifications
        self.dashboard = dashboard ?? { BotDashboardClient(saved: $0, server: server) }
        self.connectionID = connectionID ?? { (try? BotConnectionStore().load(server: server))?.id }
        self.testSender = testSender ?? { await PushRelayClient().sendTestNotification(pairing: $0) }
        self.retryDelays = retryDelays
        self.restartDelays = restartDelays
        self.minimumPlugin = minimumPlugin
        self.hostListing = hostListing ?? { try? await $0.hostListing() }
        self.offers = offers ?? .shared
        self.sleep = sleep
        pairing = self.registrar?.pairing(for: server)
    }

    var isWorking: Bool {
        switch phase {
        case .checkingPermission, .enabling, .disabling, .savingPreferences, .refreshing, .sendingTest,
             .updatingPlugin, .checkingPlugin, .restartingHermes: return true
        case .idle, .tested, .failed: return false
        }
    }

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
        case .restartingHermes: return .restarting
        case .failed(let failure) where failure.remedy == .retryUpdate || failure.remedy == .retryRestart: return .failed(failure)
        default: return pluginUpdate.map(PluginCard.status)
        }
    }

    var testDelivered: Bool { phase == .tested(.delivered) }

    var canSendTest: Bool {
        !isWorking && !notificationsOff && pairing?.effectivePreferences.replies == true
    }

    func isRunning(_ step: Step) -> Bool { phase == .enabling(step) }

    var showsSteps: Bool {
        switch phase {
        case .enabling: return true
        case .failed: return setupRanLast
        case .checkingPermission: return false
        case .idle, .disabling, .savingPreferences, .refreshing, .sendingTest, .tested,
             .updatingPlugin, .checkingPlugin, .restartingHermes: return !completed.isEmpty
        }
    }

    func reload() async {
        guard !isWorking else { return }
        phase = .refreshing
        await registrar?.finishPendingRegistrations()
        guard !Task.isCancelled else { return }
        connection = try? BotConnectionStore().load(server: server)
        pairing = registrar?.pairing(for: server)
        if connection == nil {
            pluginUpdate = nil
            offers.clear(server)
        }
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

    func leaveSettings() {
        switch phase {
        case .savingPreferences, .refreshing, .tested: phase = .idle
        default: break
        }
        if case .upToDate = pluginUpdate { pluginUpdate = nil }
    }

    func sendTestNotification() async {
        guard canSendTest, let pairing else { return }
        phase = .sendingTest
        phase = .tested(await testSender(pairing))
    }

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

    func enable() async { await setUp(mayInstall: true) }

    private func setUp(mayInstall: Bool) async {
        guard !isWorking else { return }
        setupRanLast = true
        guard let connection else { return fail(Step.relayURL.title, HermexPushFailure.noConnection) }
        completed = []
        phase = .checkingPermission
        notificationsOff = !(await notificationsAllowed())
        guard !notificationsOff else { phase = .idle; return }
        var step = Step.relayURL
        phase = .enabling(step)
        let client = dashboard(connection)
        do { try await signIn(client) } catch { return failSignIn(error) }
        do {
            let state: HostState
            do { state = try await hostState(client) } catch HermexPushRouteMissing.notMounted {
                return awaitDashboardRestart()
            } catch { return fail(Step.pair.title, error) }
            var paired: PushPairing
            switch state {
            case .paired(let configured):
                completed.formUnion([.relayURL, .install, .restart])
                step = .pair
                phase = .enabling(step)
                paired = configured
            case .relayUnset:
                try await client.setEnvironmentValue(HermexPushPlugin.relayURLEnvironmentKey,
                                                     HermexPushPlugin.defaultRelayURL.absoluteString)
                completed.formUnion([.relayURL, .install, .restart])
                step = .pair
                phase = .enabling(step)
                paired = try await pairAfterRestart(client)
            case .notInstalled where !mayInstall:
                return fail(Step.pair.title, HermexPushFailure.pairingUnavailable)
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
            do { try await registrar.enable(paired, for: server) } catch PushRegistrarError.permissionDenied {
                pairing = registrar.pairing(for: server)
                notificationsOff = true
                phase = .idle
                return
            }
            guard connectionID() == connection.id else { return await abandon() }
            completed.insert(.device)
            pairing = registrar.pairing(for: server)
            if pluginUpdate == .setupNeedsRestart { pluginUpdate = nil }
            phase = .idle
        } catch HermexPushRouteMissing.notMounted {
            awaitDashboardRestart()
        } catch {
            pairing = registrar?.pairing(for: server)
            fail(step.title, error)
        }
    }

    var sharesHostPairing: Bool { (try? registrar?.sharesRegistration(for: server)) == true }

    private struct HostPairingShared: Error {}

    func disable() async {
        guard !isWorking, pairing != nil else { return }
        completed = []
        phase = .disabling
        var step = String(localized: "Disable the plugin")
        do {
            if let connection, try registrar?.sharesRegistration(for: server) != true {
                let client = dashboard(connection)
                do { try await signIn(client) } catch { return failSignIn(error) }
                do {
                    try await client.setPlugin(HermexPushPlugin.name, enabled: false) {
                        if try self.registrar?.sharesRegistration(for: self.server) == true { throw HostPairingShared() }
                    }
                } catch is HostPairingShared {}
            }
            step = String(localized: "Remove this iPhone from the relay")
            try await registrar?.disable(for: server)
            pairing = registrar?.pairing(for: server)
            pluginUpdate = nil
            offers.clear(server)
            phase = .idle
        } catch { fail(step, error) }
    }

    func checkPlugin() async {
        guard pairing != nil, let connection, !isUpdatingPlugin else { return }
        let generation = pluginCheckGeneration
        guard let standing = try? await pluginStanding(dashboard(connection)), !Task.isCancelled,
              pairing != nil, !isUpdatingPlugin, generation == pluginCheckGeneration else { return }
        offers.record(standing, for: server)
        if case .upToDate = standing { pluginUpdate = nil } else { pluginUpdate = standing }
    }

    func checkPluginAgain() async {
        guard !isWorking, let connection else { return }
        if pluginUpdate == .setupNeedsRestart { return await setUp(mayInstall: false) }
        pluginCheckGeneration &+= 1
        setupRanLast = false
        phase = .checkingPlugin
        do {
            pluginUpdate = accept(try await pluginStanding(dashboard(connection)))
        } catch {
            switch pluginUpdate {
            case .restartTimedOut? where Self.isUnreachable(error): break
            case .checkFailed?, .restartTimedOut?: pluginUpdate = .checkFailed(Self.checkFailure(error))
            default: return fail(PluginUpdateStep.check.failureTitle, error)
            }
        }
        phase = .idle
    }

    func updatePlugin() async {
        guard !isWorking else { return }
        pluginCheckGeneration &+= 1
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
        do { try await signIn(client) } catch { return failSignIn(error, remedy: .retryUpdate) }
        do {
            var turnedOff = false
            do {
                try await client.setPlugin(HermexPushPlugin.name, enabled: false)
                turnedOff = true
                try await client.installPlugin(identifier: HermexPushPlugin.installIdentifier)
            } catch {
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
            pluginUpdate = accept(try await afterRestart { try await self.pluginStanding(client) })
            phase = .idle
        } catch where step == .check {
            pluginUpdate = .checkFailed(Self.checkFailure(error))
            phase = .idle
        } catch {
            phase = .failed(Failure(title: step.failureTitle, message: Self.message(for: error), remedy: .retryUpdate))
        }
    }

    private func signIn(_ client: BotDashboardClient) async throws {
        try await client.signIn()
        servesWebapp = client.servesWebapp
    }

    func canRestart(_ loaded: HermexPushPluginVersion?) -> Bool {
        HermexPushPlugin.canRestart(loaded) && !servesWebapp
    }

    func restartHermes() async {
        guard !isWorking, let connection, case .restartNeeded(let loaded)? = pluginUpdate,
              canRestart(loaded) else { return }
        pluginCheckGeneration &+= 1
        setupRanLast = false
        completed = []
        phase = .restartingHermes
        let client = dashboard(connection)
        do { try await signIn(client) } catch { return failSignIn(error, remedy: .retryRestart) }
        guard canRestart(loaded) else { phase = .idle; return }
        do { try await client.restartHermes() } catch BotFailure.transport, is URLError {
        } catch BotFailure.stale where client.servesWebapp {
            servesWebapp = true
            phase = .idle
            return
        } catch {
            phase = .failed(Failure(title: String(localized: "Couldn’t restart Hermes"), message: Self.message(for: error),
                                    remedy: .retryRestart))
            return
        }
        let answer = await HermesRestartWait.lastAnswer(after: restartDelays, sleep: sleep) { () async -> Result<PluginUpdate, Error>? in
            guard await client.answersStatus() else { return nil }
            do { return .success(try await self.pluginStanding(client)) } catch where !Self.isUnreachable(error) {
                return .failure(error)
            } catch { return nil }
        } isFinal: { answer in
            switch answer {
            case .success(.upToDate), .success(.newer): return true
            default: return false
            }
        }
        switch answer {
        case .success(let standing)?: pluginUpdate = accept(standing)
        case .failure(let error)?: pluginUpdate = .checkFailed(Self.checkFailure(error))
        case nil: pluginUpdate = .restartTimedOut
        }
        phase = .idle
    }

    private static func checkFailure(_ error: Error) -> Failure {
        Failure(title: PluginUpdateStep.check.failureTitle, message: message(for: error))
    }

    private var isUpdatingPlugin: Bool {
        switch phase {
        case .updatingPlugin, .checkingPlugin, .restartingHermes: return true
        default: return false
        }
    }

    private func accept(_ standing: PluginUpdate) -> PluginUpdate {
        offers.record(standing, for: server)
        return standing
    }

    private func pluginStanding(_ client: BotDashboardClient) async throws -> PluginUpdate {
        let loaded: HermexPushPluginVersion?
        do { loaded = try await client.loadedPluginVersion() } catch HermexPushRouteMissing.notMounted { loaded = nil }
        servesWebapp = client.servesWebapp
        if let loaded, loaded >= minimumPlugin {
            guard let listing = await hostListing(client) else { return .upToDate(loaded) }
            if let installed = listing.installed, installed > loaded { return .restartNeeded(loaded: loaded) }
            return listing.updateTarget.map { .newer(loaded: loaded, target: $0) } ?? .upToDate(loaded)
        }
        if let installed = try? await client.installedPluginVersion(), installed >= minimumPlugin {
            return .restartNeeded(loaded: loaded)
        }
        return .available(loaded: loaded)
    }

    func recheckNotificationPermission() async {
        guard pairing != nil || notificationsOff else { return }
        let denied = await notifications.authorizationStatus() == .denied
        guard !Task.isCancelled else { return }
        notificationsOff = denied
    }

    private func notificationsAllowed() async -> Bool {
        switch await notifications.authorizationStatus() {
        case .notDetermined: return await notifications.requestAuthorization()
        case .denied: return false
        case .authorized, .provisional, .ephemeral: return true
        @unknown default: return false
        }
    }

    private enum HostState { case paired(PushPairing), relayUnset, notInstalled }

    private func hostState(_ client: BotDashboardClient) async throws -> HostState {
        do { return .paired(try await client.pairing()) } catch BotFailure.rejected(409) {
            return .relayUnset
        } catch HermexPushRouteMissing.pluginOff {
            return .notInstalled
        } catch HermexPushRouteMissing.notMounted {
            switch try await client.hasPluginOnDisk() {
            case false?: return .notInstalled
            case true?: throw HermexPushRouteMissing.notMounted
            case nil: throw BotFailure.rejected(404)
            }
        }
    }

    private func awaitDashboardRestart() {
        pairing = registrar?.pairing(for: server)
        pluginUpdate = .setupNeedsRestart
        phase = .idle
    }

    private func abandon() async {
        await registrar?.forget(for: server)
        pairing = nil
        pluginUpdate = nil
        offers.clear(server)
        phase = .idle
    }

    private func pairAfterRestart(_ client: BotDashboardClient) async throws -> PushPairing {
        try await afterRestart { try await client.pairing() }
    }

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
        case BotFailure.rejected(404), BotFailure.rejected(409), HermexPushRouteMissing.pluginOff: return true
        default: return isUnreachable(error)
        }
    }

    private static func isUnreachable(_ error: Error) -> Bool {
        switch error {
        case BotFailure.rejected(502), BotFailure.rejected(503), BotFailure.transport: return true
        default: return error is URLError
        }
    }

    private func advance(from finished: Step, to next: Step) -> Step {
        completed.insert(finished)
        phase = .enabling(next)
        return next
    }

    private func fail(_ step: String, _ error: Error) {
        phase = .failed(Failure(title: step, message: Self.message(for: error),
                                remedy: Self.needsNewerPlugin(error) ? .updatePlugin : .none))
    }

    private static func needsNewerPlugin(_ error: Error) -> Bool {
        switch error {
        case HermexPushFailure.unusablePairing, PushRegistrarError.malformedPairing,
             PushRelayError.malformedInstallKey: return true
        default: return false
        }
    }

    private func failSignIn(_ error: Error, remedy: Failure.Remedy = .none) {
        let message = switch error {
        case BotFailure.transport, is URLError:
            String(localized: "Could not reach this Hermes host. Check the connection, then try again.")
        default: Self.message(for: error)
        }
        phase = .failed(Failure(title: String(localized: "Sign in to Hermes"), message: message, remedy: remedy))
    }

    static func message(for error: Error) -> String {
        switch error {
        case let failure as HermexPushFailure:
            return failure.errorDescription ?? String(localized: "This step did not finish. Try again.")
        case is HermexPushRouteMissing:
            return message(for: HermexPushFailure.pairingUnavailable)
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
        case BotFailure.blocked, BotFailure.browserSignIn, BotFailure.signInExpired, BotFailure.signInChanged,
             BotFailure.outdated, BotFailure.gatewayListener:
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
