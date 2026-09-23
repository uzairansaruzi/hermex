import Foundation
import OSLog
import UIKit

/// Asking UIKit for a device token. Wrapped so the registrar is testable without
/// a running application.
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

/// What setting a Hermes host up for push (#557) needs from the registrar. A protocol so
/// the Hermes connection screen can be exercised without UIKit or a Keychain access group.
@MainActor protocol PushPairingEnabling {
    func enable(_ pairing: PushPairing, for server: URL) async throws
    func disable(for server: URL) async throws
    /// Teardown that always leaves nothing behind, even when the relay cannot be
    /// reached. Removing a connection or a whole server may not depend on the network.
    func forget(for server: URL) async
    func pairing(for server: URL) -> PushPairing?
    func finishPendingRegistrations() async
    func updatePreferences(_ preferences: PushPreferences, for server: URL, expectedPairing: PushPairing) async throws
}

enum PushRegistrarError: Error, Equatable {
    /// No `aps-environment` mirror in Info.plist, or a bundle ID the relay does
    /// not accept. A fork signed under another identity lands here.
    case unsupportedBuild
    case permissionDenied
    /// APNs never came back with a token. Almost always no network.
    case tokenUnavailable
    case malformedPairing
    case pairingChanged
    case preferencesUnconfirmed
}

/// Owns this device's APNs registration across every paired server.
///
/// One phone has one device token but may be paired with several servers, each
/// with its own install at (possibly) its own relay, so every token change has to
/// be reported to all of them. Registration is never requested before a pairing
/// exists — an unpaired user is never prompted and never mints a token — but once
/// one does, the token is re-registered on every launch: the relay revokes a
/// device on its own when Apple reports the token invalid, so a past registration
/// is not something the app may assume still holds.
@MainActor final class PushRegistrar {
    /// Nil only when the build has no shared Keychain access group to write to,
    /// which means push cannot work at all on this build.
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

    // Preference writes and token refreshes share a queue: a delayed refresh must
    // never replace a newly accepted choice with an older snapshot.
    private var registrationTail: Task<Void, Never>?
    private var currentToken: String?
    private var pendingLaunchRefresh = false
    private var tokenWaiters: [CheckedContinuation<String, any Error>] = []

    /// The live collaborators. Default arguments cannot build them: they would be
    /// evaluated outside the main actor.
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

    // MARK: - Pairing lifecycle

    /// Completes a pairing: asks for notification permission, gets a device token
    /// and registers it at that install's relay. The pairing is stored only after
    /// the relay accepts, so a half-finished enable leaves nothing behind.
    func enable(_ pairing: PushPairing, for server: URL) async throws {
        guard let identity else { throw PushRegistrarError.unsupportedBuild }
        guard pairing.hasWellFormedInstallKey else { throw PushRegistrarError.malformedPairing }
        guard await authorization.requestAuthorization() else { throw PushRegistrarError.permissionDenied }

        let token = try await deviceToken()
        try await relay.registerDevice(token: token, identity: identity, pairing: pairing)

        var stored = pairing
        stored.registeredToken = token
        do {
            try store.save(stored, for: server)
        } catch {
            // The relay has already accepted this device. With no keys on disk
            // nothing could ever revoke it, so undo the registration before
            // reporting the failure rather than leave a phone that cannot be
            // unpaired.
            try? await relay.deleteDevice(token: token, pairing: pairing)
            throw error
        }
    }

    /// Teardown for a connection or server the user removed. Unlike `disable(for:)` this
    /// never fails: the keys go whether or not the relay could be told, because the user
    /// has already thrown the connection away and an unreachable relay must not leave
    /// credentials behind. The relay drops the device on its own once Apple reports the
    /// token invalid.
    func forget(for server: URL) async {
        if let pairing = try? store.pairing(for: server), let token = pairing.registeredToken {
            try? await relay.deleteDevice(token: token, pairing: pairing)
        }
        try? store.remove(for: server)
        await activities.forget(server: server)
        if ((try? store.allPairings()) ?? [:]).isEmpty {
            remoteNotifications.unregisterForRemoteNotifications()
            currentToken = nil
        }
    }

    /// Removes this device from that install's relay, then wipes its keys. The
    /// relay call comes first on purpose: dropping the install key while the relay
    /// still holds the device would leave a phone that keeps buzzing with no way
    /// left to address it. A failure here throws and changes nothing, so the user
    /// can retry.
    func disable(for server: URL) async throws {
        guard let pairing = try store.pairing(for: server) else { return }
        if let token = pairing.registeredToken {
            try await relay.deleteDevice(token: token, pairing: pairing)
        }
        try store.remove(for: server)
        await activities.forget(server: server)

        if ((try? store.allPairings()) ?? [:]).isEmpty {
            remoteNotifications.unregisterForRemoteNotifications()
            currentToken = nil
        }
    }

    func pairing(for server: URL) -> PushPairing? {
        try? store.pairing(for: server)
    }

    /// Finishes an accepted preference transaction even if its screen closes. Only
    /// the screen's state update is cancelled; relay and Keychain must agree.
    func updatePreferences(_ preferences: PushPreferences, for server: URL, expectedPairing: PushPairing) async throws {
        let previous = registrationTail
        let task = Task { [self] in
            await previous?.value
            guard let identity else { throw PushRegistrarError.unsupportedBuild }
            guard let original = try store.pairing(for: server),
                  sameInstall(original, expectedPairing), let token = original.registeredToken
            else { throw PushRegistrarError.pairingChanged }
            // Journal uncertainty first. If Keychain is unavailable, do not change
            // the relay; if the process ends later, reload can still reconcile.
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
                        // Even a transport failure may have reached the relay.
                        // Confirm rollback before clearing the durable marker.
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
                    try? await relay.deleteDevice(token: token, pairing: original)
                    throw PushRegistrarError.pairingChanged
                }
                throw updateError
            }
            await activities.refresh()
        }
        registrationTail = Task { _ = await task.result }
        try await task.value
    }

    /// Called once at launch. Only a server that already paired gets a token
    /// request; the rest of the work happens when the token arrives.
    func refreshOnLaunch() {
        guard let pairings = try? store.allPairings(), !pairings.isEmpty else { return }
        pendingLaunchRefresh = true
        remoteNotifications.registerForRemoteNotifications()
    }

    // MARK: - APNs callbacks

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let previous = currentToken
        let isLaunchRefresh = pendingLaunchRefresh
        pendingLaunchRefresh = false
        currentToken = token
        resolveTokenWaiters(with: .success(token))

        // Two deliveries need every pairing re-registered: the launch refresh,
        // because the relay may have revoked this device on its own; and a token
        // iOS rotated under us, because each relay still holds the dead one. A
        // first token minted for an in-flight `enable` needs neither — that call
        // registers its own pairing, and no other pairing's token changed.
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

    // MARK: - Internals

    /// Re-registers every paired install and retires the token each one was last
    /// registered with. A relay that is down leaves the stored pairing alone: the
    /// next launch tries again, and a wiped pairing would silently unpair a user
    /// over a transient network error.
    private func reregisterAllPairings(token: String) async {
        guard let identity, let pairings = try? store.allPairings() else { return }
        for server in pairings.keys {
            // Read after earlier writes finish, rather than restoring stale preferences.
            guard let pairing = try? store.pairing(for: server) else { continue }
            do {
                try await relay.registerDevice(token: token, identity: identity, pairing: pairing)
                guard isStillPaired(pairing, for: server) else {
                    // Disabled while that call was in flight. Retire the device we
                    // just registered; otherwise the phone keeps receiving pushes
                    // for a server whose keys are gone.
                    try? await relay.deleteDevice(token: token, pairing: pairing)
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

    /// Whether the stored pairing is still the one this refresh started from. A
    /// disable in the meantime removes it, and a re-pair mints a new install key;
    /// either way the snapshot must not be written back over the user's choice.
    private func isStillPaired(_ pairing: PushPairing, for server: URL) -> Bool {
        guard let stored = try? store.pairing(for: server) else { return false }
        return sameInstall(stored, pairing)
    }

    private func sameInstall(_ lhs: PushPairing, _ rhs: PushPairing) -> Bool {
        lhs.installKey == rhs.installKey && lhs.relayURL == rhs.relayURL && lhs.previewKey == rhs.previewKey
    }

    /// Waits for queued device writes, also used by deterministic registration tests.
    func finishPendingRegistrations() async {
        await registrationTail?.value
    }

    /// The token arrives through the app delegate, not from a call, so a first
    /// pairing has to wait for it. The timeout keeps a phone with no network from
    /// leaving the Enable action spinning forever.
    private func deviceToken() async throws -> String {
        if let currentToken { return currentToken }
        remoteNotifications.registerForRemoteNotifications()
        // Nothing can interleave before the continuation below, but a token that
        // is already in hand by now makes the wait pointless.
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

/// `PushRegistrar` already is this seam; the protocol only exists so tests can stand in.
extension PushRegistrar: PushPairingEnabling {}

/// Serializes activity PUT/DELETE calls, including retirement during an in-flight
/// PUT. An old owner's cleanup completes before a new owner can register the same
/// session. No task reads a mutable "active server" after suspension.
@MainActor final class PushActivityRegistrar {
    private struct Desired: Equatable {
        let server: URL
        let sessionID: String
        let token: String
    }
    private struct Registered {
        let desired: Desired
        let pairing: PushPairing
        let deviceToken: String
        var confirmed = true
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
        // A rotated token queued its own PUT, and that call settles the waiters.
        guard desired[owner] == wanted else { return }
        resolveRegistrationWaiters(owner, registered: isRegistered(owner))
    }

    /// Waits for `owner`'s relay registration to settle, including an activity token
    /// ActivityKit has not issued yet: true once the relay confirmed it, false when it
    /// fails, is retired, is cancelled, or does not settle within `limit`. Lets a
    /// suspending app keep a Live Activity's live state through a handoff that lands a
    /// moment later (#635).
    func awaitRegistration(_ owner: String, limit: Duration) async -> Bool {
        if isRegistered(owner) { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.resolveRegistrationWaiters(owner, registered: false)
        }
        defer { timeout.cancel() }
        if let wanted = desired[owner] {
            // The token is in hand, so its PUT is queued, finished, or failed.
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
        // A persisted activity may end before this process ever saw its token. Its
        // cleanup must never delete a newer activity's route, registered or queued.
        if registered[owner] == nil, let server, let sessionID,
           let keys = pairing(server), let device = keys.registeredToken,
           !registered.values.contains(where: { $0.desired.server == server && $0.desired.sessionID == sessionID }),
           !desired.values.contains(where: { $0.server == server && $0.sessionID == sessionID }) {
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
        // Failed retirement must block a replacement on that route; otherwise a
        // retry of the old DELETE could revoke the replacement's token.
        if let next = desired[owner] {
            for (other, old) in registered where other != owner && desired[other] == nil
                && old.desired.server == next.server && old.desired.sessionID == next.sessionID {
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
            } else {
                do {
                    try await relay.deleteActivity(sessionID: old.desired.sessionID, deviceToken: old.deviceToken, pairing: old.pairing)
                    registered[owner] = nil
                } catch { return } // Keep the receipt so a refresh can retry cleanup.
            }
        }
        guard let next = desired[owner], let keys = pairing(next.server), let device = keys.registeredToken else { return }
        do {
            try await relay.registerActivity(token: next.token, sessionID: next.sessionID, deviceToken: device, pairing: keys)
            registered[owner] = Registered(desired: next, pairing: keys, deviceToken: device)
            if desired[owner] != next || pairing(next.server)?.hasSameRegistration(as: keys) != true {
                // No later queued PUT can run until this stale registration is removed.
                try await relay.deleteActivity(sessionID: next.sessionID, deviceToken: device, pairing: keys)
                registered[owner] = nil
            }
        } catch { /* No confirmed registration means suspend remains honestly stale. */ }
    }
}
