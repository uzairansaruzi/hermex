import Foundation
import LocalAuthentication

struct AppLockCapability: Equatable {
    enum Method: Equatable {
        case faceID
        case touchID
        case passcode
    }

    var method: Method
    var hasPasscode: Bool
}

@MainActor protocol AppLockAuthenticator {
    func capability() -> AppLockCapability
    func authenticate(reason: String) async -> Bool
}

@MainActor @Observable final class AppLock {
    static let shared = AppLock()
    static let enabledKey = "appLockEnabled"
    static let relockDelay: Duration = .seconds(60)

    private enum Phase {
        case active
        case inactive
        case background
    }

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isPasscodeMissing = false
    private(set) var isAuthenticating = false
    private(set) var capability: AppLockCapability

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticator: any AppLockAuthenticator
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    @ObservationIgnored private var didPromptForThisLock = false
    private var phase = Phase.inactive
    private var promptHoldsScene = false

    init(
        defaults: UserDefaults = .standard,
        authenticator: (any AppLockAuthenticator)? = nil,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        let authenticator = authenticator ?? DeviceAppLockAuthenticator()
        let isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.defaults = defaults
        self.authenticator = authenticator
        self.now = now
        self.isEnabled = isEnabled
        isLocked = isEnabled
        capability = isEnabled ? authenticator.capability() : AppLockCapability(method: .passcode, hasPasscode: true)
    }

    var isCovered: Bool {
        guard isEnabled else { return false }
        switch phase {
        case .active: return false
        case .inactive: return !promptHoldsScene
        case .background: return true
        }
    }

    var showsLockWindow: Bool { isLocked || isCovered }

    func sceneWillResignActive() {
        phase = .inactive
    }

    func sceneDidEnterBackground() {
        phase = .background
        promptHoldsScene = false
        backgroundedAt = now()
    }

    @discardableResult
    func sceneDidBecomeActive() -> Task<Void, Never>? {
        phase = .active
        if !isAuthenticating { promptHoldsScene = false }
        if let backgroundedAt, isEnabled, now() - backgroundedAt > Self.relockDelay {
            isLocked = true
            didPromptForThisLock = false
        }
        backgroundedAt = nil

        guard isLocked, !isAuthenticating else { return nil }
        refreshCapability()
        isPasscodeMissing = !capability.hasPasscode
        guard !isPasscodeMissing, !didPromptForThisLock else { return nil }
        didPromptForThisLock = true
        return Task { await unlock() }
    }

    func unlock() async {
        guard isLocked, !isPasscodeMissing, !isAuthenticating else { return }
        didPromptForThisLock = true
        if await authenticate(reason: String(localized: "Unlock Hermex")) {
            isLocked = false
        } else {
            refreshCapability()
            if !capability.hasPasscode { isPasscodeMissing = true }
        }
    }

    func continueWithoutPasscode() {
        guard isPasscodeMissing else { return }
        store(enabled: false)
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isAuthenticating else { return }
        refreshCapability()
        guard capability.hasPasscode else {
            if !enabled { store(enabled: false) }
            return
        }
        let reason = enabled ? String(localized: "Turn on the app lock") : String(localized: "Turn off the app lock")
        if await authenticate(reason: reason) {
            store(enabled: enabled)
        }
    }

    func refreshCapability() {
        let current = authenticator.capability()
        if current != capability { capability = current }
    }

    private func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        promptHoldsScene = true
        let succeeded = await authenticator.authenticate(reason: reason)
        isAuthenticating = false
        if phase == .active { promptHoldsScene = false }
        return succeeded
    }

    private func store(enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if !enabled {
            isLocked = false
            isPasscodeMissing = false
        }
    }
}

struct DeviceAppLockAuthenticator: AppLockAuthenticator {
    func capability() -> AppLockCapability {
        let context = LAContext()
        var biometryError: NSError?
        let canUseBiometry = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError)
            || biometryError?.code == LAError.biometryLockout.rawValue
        var passcodeError: NSError?
        let hasPasscode = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError)
            || passcodeError?.code != LAError.passcodeNotSet.rawValue
        guard canUseBiometry || !hasPasscode else {
            return AppLockCapability(method: .passcode, hasPasscode: hasPasscode)
        }
        let method: AppLockCapability.Method = switch context.biometryType {
        case .faceID: .faceID
        case .touchID: .touchID
        default: .passcode
        }
        return AppLockCapability(method: method, hasPasscode: hasPasscode)
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { succeeded, _ in
                continuation.resume(returning: succeeded)
            }
        }
    }
}
