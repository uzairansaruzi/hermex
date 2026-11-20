import Foundation
import OSLog
import UIKit

@MainActor protocol RemoteNotificationRegistering {
    func registerForRemoteNotifications()
    func unregisterForRemoteNotifications()
}

@MainActor struct UIApplicationRemoteNotificationRegistrar: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func unregisterForRemoteNotifications() {
        UIApplication.shared.unregisterForRemoteNotifications()
    }
}

@MainActor protocol PushPairingEnabling {
    func enable(_ pairing: PushPairing, for server: URL) async throws
    func disable(for server: URL) async throws
    func forget(for server: URL) async
    func pairing(for server: URL) -> PushPairing?
    func sharesRegistration(for server: URL) throws -> Bool
    func finishPendingRegistrations() async
    func updatePreferences(_ preferences: PushPreferences, for server: URL, expectedPairing: PushPairing) async throws
}

enum PushRegistrarError: Error, Equatable {
    case unsupportedBuild
    case permissionDenied
    case tokenUnavailable
    case malformedPairing
    case pairingChanged
    case preferencesUnconfirmed
}

@MainActor final class PushRegistrar: PushPairingCopying {
    static let shared: PushRegistrar? = {
        guard let store = KeychainPushPairingStore() else { return nil }
        return PushRegistrar(store: store)
    }()

    private static let logger = Logger(subsystem: "com.uzairansar.hermesmobile", category: "push")

    private let store: any PushPairingStoring
    private let relay: any PushRelayRegistering
    private let remoteNotifications: any RemoteNotificationRegistering
    private let authorization: any ResponseCompletionNotificationScheduling
    private let identity: PushBuildIdentity?
    private let tokenTimeout: Duration

    lazy var activities = PushActivityRegistrar(relay: PushRelayClient(), pairing: { [weak self] server in
        self?.pairing(for: server)
    })

    private var registrationTail: Task<Void, Never>?
    private var enablesInFlight: [(server: URL, pairing: PushPairing)] = []
    private var currentToken: String?
    private var pendingLaunchRefresh = false
    private var tokenWaiters: [CheckedContinuation<String, any Error>] = []

    convenience init(store: any PushPairingStoring) {
        self.init(
            store: store,
            relay: PushRelayClient(),
            remoteNotifications: UIApplicationRemoteNotificationRegistrar(),
            authorization: UserNotificationResponseCompletionScheduler(),
            identity: PushBuildIdentity()
        )
    }

    init(
        store: any PushPairingStoring,
        relay: any PushRelayRegistering,
        remoteNotifications: any RemoteNotificationRegistering,
        authorization: any ResponseCompletionNotificationScheduling,
        identity: PushBuildIdentity?,
        tokenTimeout: Duration = .seconds(20)
    ) {
        self.store = store
        self.relay = relay
        self.remoteNotifications = remoteNotifications
        self.authorization = authorization
        self.identity = identity
        self.tokenTimeout = tokenTimeout
    }

    func enable(_ pairing: PushPairing, for server: URL) async throws {
        guard let identity else { throw PushRegistrarError.unsupportedBuild }
        guard pairing.hasWellFormedInstallKey else { throw PushRegistrarError.malformedPairing }
        guard await authorization.requestAuthorization() else { throw PushRegistrarError.permissionDenied }

        let token = try await deviceToken()
        enablesInFlight.append((server, pairing))
        defer {
            if let index = enablesInFlight.firstIndex(where: { $0.server == server && $0.pairing == pairing }) {
                enablesInFlight.remove(at: index)
            }
        }
        try await enqueueRegistrationWork { [self] in
            try await relay.registerDevice(token: token, identity: identity, pairing: pairing)

            var stored = pairing
            stored.registeredToken = token
            do {
                try store.save(stored, for: server)
            } catch {
                await retire(token: token, of: pairing, removedFrom: server)
                throw error
            }
        }
    }

    func forget(for server: URL) async {
        if !enablesInFlight.contains(where: { $0.server == server }), case .success(nil) = Result(catching: { try store.pairing(for: server) }) {
            await activities.forget(server: server)
            return
        }
        try? await enqueueRegistrationWork { [self] in
            if let pairing = try? store.pairing(for: server), let token = pairing.registeredToken,
               (try? isRegistered(token, of: pairing, besides: server)) == false {
                try? await relay.deleteDevice(token: token, pairing: pairing)
            }
            try? store.remove(for: server)
            await activities.forget(server: server)
            unregisterIfUnpaired()
        }
    }

    func disable(for server: URL) async throws {
        try await enqueueRegistrationWork { [self] in
            guard let pairing = try store.pairing(for: server) else { return }
            if let token = pairing.registeredToken, try !isRegistered(token, of: pairing, besides: server) {
                try await relay.deleteDevice(token: token, pairing: pairing)
            }
            try store.remove(for: server)
            await activities.forget(server: server)
            unregisterIfUnpaired()
        }
    }

    private func unregisterIfUnpaired() {
        guard (try? store.allPairings())?.isEmpty == true else { return }
        remoteNotifications.unregisterForRemoteNotifications()
        currentToken = nil
    }

    func pairing(for server: URL) -> PushPairing? {
        try? store.pairing(for: server)
    }

    func sharesRegistration(for server: URL) throws -> Bool {
        guard let pairing = pairing(for: server) else { return false }
        return try enablesInFlight.contains {
            $0.server != server && $0.pairing.installKey == pairing.installKey && $0.pairing.relayURL == pairing.relayURL
        } || !entries(sharing: pairing, besides: server).isEmpty
    }

    private func entries(sharing pairing: PushPairing, besides server: URL) throws -> [PushPairing] {
        try store.allPairings().compactMap { other, stored in
            other != server && stored.installKey == pairing.installKey && stored.relayURL == pairing.relayURL ? stored : nil
        }
    }

    private func isRegistered(_ token: String, of pairing: PushPairing, besides server: URL) throws -> Bool {
        try entries(sharing: pairing, besides: server).contains { $0.registeredToken == token }
    }

    private func retire(token: String, of pairing: PushPairing, removedFrom server: URL) async {
        guard (try? isRegistered(token, of: pairing, besides: server)) == false else { return }
        try? await relay.deleteDevice(token: token, pairing: pairing)
    }

    func copyPairing(from source: URL, to destination: URL, matching install: PushPairing,
                     isConfigured: @escaping @MainActor (URL) -> Bool) async throws -> MovePushPairingOutcome {
        try await enqueueRegistrationWork { [self] in
            guard isConfigured(destination) else { return .unchecked }
            guard try store.pairing(for: destination) == nil else { return .destinationAlreadyPaired }
            guard let stored = try store.pairing(for: source) else { return .sourceUnpaired }
            guard sameInstall(stored, install) else { return .differentInstall }
            try store.save(stored, for: destination)
            return .copied
        }
    }

    func updatePreferences(_ preferences: PushPreferences, for server: URL, expectedPairing: PushPairing) async throws {
        try await enqueueRegistrationWork { [self] in
            guard let identity else { throw PushRegistrarError.unsupportedBuild }
            guard let original = try store.pairing(for: server),
                  sameInstall(original, expectedPairing), let token = original.registeredToken
            else { throw PushRegistrarError.pairingChanged }
            var pending = original
            pending.preferencesNeedSync = true
            try store.save(pending, for: server)
            var updated = original
            updated.preferences = preferences
            updated.preferencesNeedSync = nil
            do {
                try await relay.registerDevice(token: token, identity: identity, pairing: updated)
                guard isStillPaired(original, for: server) else {
                    throw PushRegistrarError.pairingChanged
                }
                try store.save(updated, for: server)
            } catch {
                let updateError = error
                if isStillPaired(original, for: server) {
                    var restored = original
                    restored.preferencesNeedSync = nil
                    do {
                        try await relay.registerDevice(token: token, identity: identity, pairing: restored)
                        if isStillPaired(original, for: server) {
                            try store.save(restored, for: server)
                        }
                    } catch {
                        if isStillPaired(original, for: server) {
                            throw PushRegistrarError.preferencesUnconfirmed
                        }
                    }
                }
                if !isStillPaired(original, for: server) {
                    await retire(token: token, of: original, removedFrom: server)
                    throw PushRegistrarError.pairingChanged
                }
                throw updateError
            }
            await activities.refresh()
        }
    }

    @discardableResult
    private func enqueueRegistrationWork<Result: Sendable>(
        _ work: @escaping @MainActor () async throws -> Result
    ) async throws -> Result {
        let previous = registrationTail
        let task = Task {
            await previous?.value
            return try await work()
        }
        registrationTail = Task { _ = await task.result }
        return try await task.value
    }

    func refreshOnLaunch() {
        guard let pairings = try? store.allPairings(), !pairings.isEmpty else { return }
        pendingLaunchRefresh = true
        remoteNotifications.registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let previous = currentToken
        let isLaunchRefresh = pendingLaunchRefresh
        pendingLaunchRefresh = false
        currentToken = token
        resolveTokenWaiters(with: .success(token))

        guard isLaunchRefresh || (previous != nil && previous != token) else { return }
        let previousRefresh = registrationTail
        registrationTail = Task {
            await previousRefresh?.value
            await self.reregisterAllPairings(token: token)
        }
    }

    func didFailToRegisterForRemoteNotifications(error: any Error) {
        Self.logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        resolveTokenWaiters(with: .failure(PushRegistrarError.tokenUnavailable))
    }

    private func reregisterAllPairings(token: String) async {
        guard let identity, let pairings = try? store.allPairings() else { return }
        for server in pairings.keys {
            guard let pairing = try? store.pairing(for: server) else { continue }
            do {
                try await relay.registerDevice(token: token, identity: identity, pairing: pairing)
                guard isStillPaired(pairing, for: server) else {
                    await retire(token: token, of: pairing, removedFrom: server)
                    continue
                }
                if let previous = pairing.registeredToken, previous != token {
                    try? await relay.deleteDevice(token: previous, pairing: pairing)
                }
                guard isStillPaired(pairing, for: server) else { continue }
                if pairing.registeredToken != token || pairing.preferencesNeedSync == true {
                    var updated = pairing
                    updated.registeredToken = token
                    updated.preferencesNeedSync = nil
                    try store.save(updated, for: server)
                }
                await activities.refresh(republish: true)
            } catch {
                Self.logger.error("Push device registration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func isStillPaired(_ pairing: PushPairing, for server: URL) -> Bool {
        guard let stored = try? store.pairing(for: server) else { return false }
        return sameInstall(stored, pairing)
    }

    private func sameInstall(_ lhs: PushPairing, _ rhs: PushPairing) -> Bool {
        lhs.installKey == rhs.installKey && lhs.relayURL == rhs.relayURL && lhs.previewKey == rhs.previewKey
    }

    func finishPendingRegistrations() async {
        await registrationTail?.value
    }

    private func deviceToken() async throws -> String {
        if let currentToken { return currentToken }
        remoteNotifications.registerForRemoteNotifications()
        if let currentToken { return currentToken }
        let timeout = Task { [tokenTimeout] in
            try await Task.sleep(for: tokenTimeout)
            self.resolveTokenWaiters(with: .failure(PushRegistrarError.tokenUnavailable))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { tokenWaiters.append($0) }
    }

    private func resolveTokenWaiters(with result: Result<String, any Error>) {
        let waiters = tokenWaiters
        tokenWaiters = []
        for waiter in waiters { waiter.resume(with: result) }
    }
}

extension PushRegistrar: PushPairingEnabling {}

@MainActor final class PushActivityRegistrar {
    private struct Desired: Equatable {
        let server: URL
        let sessionID: String
        let token: String
    }
    private struct Route: Equatable {
        let relayURL: URL
        let installKey: String
        let deviceToken: String
        let sessionID: String

        init(_ pairing: PushPairing, deviceToken: String, sessionID: String) {
            relayURL = pairing.relayURL
            installKey = pairing.installKey
            self.deviceToken = deviceToken
            self.sessionID = sessionID
        }
    }
    private struct Registered {
        let desired: Desired
        let pairing: PushPairing
        let deviceToken: String
        var confirmed = true
        var route: Route { Route(pairing, deviceToken: deviceToken, sessionID: desired.sessionID) }
    }
    private let relay: any PushActivityRelaying
    private let pairing: (URL) -> PushPairing?
    private var desired: [String: Desired] = [:]
    private var registered: [String: Registered] = [:]
    private var tail: Task<Void, Never>?
    private var registrationWaiters: [String: [UUID: CheckedContinuation<Bool, Never>]] = [:]

    init(relay: any PushActivityRelaying, pairing: @escaping (URL) -> PushPairing?) {
        self.relay = relay
        self.pairing = pairing
    }

    func isRegistered(_ owner: String) -> Bool {
        guard let record = registered[owner], record.confirmed, desired[owner] == record.desired else { return false }
        return pairing(record.desired.server)?.hasSameRegistration(as: record.pairing) == true
    }

    func register(owner: String, server: URL, sessionID: String, token: String) async {
        let wanted = Desired(server: server, sessionID: sessionID, token: token)
        desired[owner] = wanted
        await enqueue(owner).value
        guard desired[owner] == wanted else { return }
        resolveRegistrationWaiters(owner, registered: isRegistered(owner))
    }

    func awaitRegistration(_ owner: String, limit: Duration) async -> Bool {
        if isRegistered(owner) { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.resolveRegistrationWaiters(owner, registered: false)
        }
        defer { timeout.cancel() }
        if let wanted = desired[owner] {
            let pending = tail
            Task { [weak self] in
                await pending?.value
                guard let self, desired[owner] == wanted else { return }
                resolveRegistrationWaiters(owner, registered: isRegistered(owner))
            }
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: false) }
                registrationWaiters[owner, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.registrationWaiters[owner]?.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func resolveRegistrationWaiters(_ owner: String, registered: Bool) {
        for waiter in (registrationWaiters.removeValue(forKey: owner) ?? [:]).values { waiter.resume(returning: registered) }
    }

    func retire(owner: String, server: URL? = nil, sessionID: String? = nil) async {
        desired[owner] = nil
        if registered[owner] == nil, let server, let sessionID,
           let keys = pairing(server), let device = keys.registeredToken,
           !registered.values.contains(where: { $0.route == Route(keys, deviceToken: device, sessionID: sessionID) }) {
            registered[owner] = Registered(desired: Desired(server: server, sessionID: sessionID, token: ""),
                                           pairing: keys, deviceToken: device)
        }
        await enqueue(owner).value
        resolveRegistrationWaiters(owner, registered: false)
    }

    func forget(server: URL) async {
        let owners = Set(desired.filter { $0.value.server == server }.map(\.key))
            .union(registered.filter { $0.value.desired.server == server }.map(\.key))
        for owner in owners { desired[owner] = nil }
        for owner in owners { await enqueue(owner).value }
    }

    func refresh(republish: Bool = false) async {
        for owner in Set(desired.keys).union(registered.keys) { await enqueue(owner, republish: republish).value }
    }

    private func enqueue(_ owner: String, republish: Bool = false) -> Task<Void, Never> {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            await reconcile(owner, republish: republish)
        }
        tail = task
        return task
    }

    private func reconcile(_ owner: String, republish: Bool) async {
        if let next = desired[owner], let keys = pairing(next.server), let device = keys.registeredToken {
            let route = Route(keys, deviceToken: device, sessionID: next.sessionID)
            for (other, old) in registered where other != owner && desired[other] == nil && old.route == route {
                do {
                    try await relay.deleteActivity(sessionID: old.desired.sessionID, deviceToken: old.deviceToken, pairing: old.pairing)
                    registered[other] = nil
                } catch { return }
            }
        }
        if let old = registered[owner] {
            if desired[owner] == old.desired, pairing(old.desired.server)?.hasSameRegistration(as: old.pairing) == true {
                guard republish || !old.confirmed else { return }
                registered[owner]?.confirmed = false
            } else if desired[owner] == nil, registered.contains(where: { other, record in
                other != owner && record.route == old.route
            }) {
                registered[owner] = nil
            } else {
                do {
                    try await relay.deleteActivity(sessionID: old.desired.sessionID, deviceToken: old.deviceToken, pairing: old.pairing)
                    registered[owner] = nil
                } catch { return }
            }
        }
        guard let next = desired[owner], let keys = pairing(next.server), let device = keys.registeredToken else { return }
        do {
            try await relay.registerActivity(token: next.token, sessionID: next.sessionID, deviceToken: device, pairing: keys)
            registered[owner] = Registered(desired: next, pairing: keys, deviceToken: device)
            if desired[owner] != next || pairing(next.server)?.hasSameRegistration(as: keys) != true {
                try await relay.deleteActivity(sessionID: next.sessionID, deviceToken: device, pairing: keys)
                registered[owner] = nil
            }
        } catch {  }
    }
}
