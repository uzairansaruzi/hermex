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

enum PushRegistrarError: Error, Equatable {
    /// No `aps-environment` mirror in Info.plist, or a bundle ID the relay does
    /// not accept. A fork signed under another identity lands here.
    case unsupportedBuild
    case permissionDenied
    /// APNs never came back with a token. Almost always no network.
    case tokenUnavailable
    case malformedPairing
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

        if ((try? store.allPairings()) ?? [:]).isEmpty {
            remoteNotifications.unregisterForRemoteNotifications()
            currentToken = nil
        }
    }

    func pairing(for server: URL) -> PushPairing? {
        try? store.pairing(for: server)
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
        Task { await self.reregisterAllPairings(token: token) }
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
        for (server, pairing) in pairings {
            // The user can disable a server at any suspension point below, so the
            // snapshot is only a starting list: what is on disk right now decides.
            guard isStillPaired(pairing, for: server) else { continue }
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
                guard pairing.registeredToken != token, isStillPaired(pairing, for: server) else { continue }
                var updated = pairing
                updated.registeredToken = token
                try store.save(updated, for: server)
            } catch {
                Self.logger.error("Push device registration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Whether the stored pairing is still the one this refresh started from. A
    /// disable in the meantime removes it, and a re-pair mints a new install key;
    /// either way the snapshot must not be written back over the user's choice.
    private func isStillPaired(_ pairing: PushPairing, for server: URL) -> Bool {
        (try? store.pairing(for: server))?.installKey == pairing.installKey
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
