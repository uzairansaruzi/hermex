import Foundation
import LocalAuthentication

/// What the device can unlock Hermex with right now.
struct AppLockCapability: Equatable {
    enum Method: Equatable {
        case faceID
        case touchID
        case passcode
    }

    /// What the Settings label and the Unlock button name.
    var method: Method
    /// iOS can't authenticate at all without a device passcode.
    var hasPasscode: Bool
}

/// Face ID, Touch ID or the device passcode. `AppLock` asks through this so tests can fake it.
@MainActor protocol AppLockAuthenticator {
    func capability() -> AppLockCapability
    /// Prompts once; true only when the device owner authenticated.
    func authenticate(reason: String) async -> Bool
}

/// The optional app lock (#885): one Settings toggle, off by default, app-wide rather than
/// per server, so it lives in `UserDefaults`. `AppLockSceneDelegate` feeds it the scene's
/// phases and shows its window whenever `showsLockWindow` is true.
///
/// - With the lock on, a cold launch is locked, and so is becoming active more than
///   `relockDelay` after entering the background. The time runs on `ContinuousClock`, so the
///   phone sleeping counts and changing the clock doesn't. Inactive and back (Control
///   Center, the Face ID sheet) never locks.
/// - While on, the scene is covered whenever it isn't active, so the app switcher snapshot
///   and Control Center show the app icon instead of a chat. The lock's own Face ID or
///   passcode sheet doesn't cover.
/// - When locked, it prompts once by itself as the scene becomes active; after a cancel or
///   failure only the Unlock button tries again.
/// - Turning the lock on or off needs a successful authentication. It can't be turned on
///   without a device passcode. If the passcode is removed while it's on, the lock says so and
///   Continue turns it off: it never opens silently.
/// - It is a cover, not a gate: the app stays mounted behind it, so streams, Live Activities
///   and reconnects keep running, and deep links, App Intents, notification taps and share
///   handoffs land behind it. While locked, keyboard commands are off, "New Chat with Voice"
///   holds dictation, and push presence reports no chat on screen.
/// - It can't cover other processes: notifications, Live Activities and the share sheet still
///   show their content, as the Settings footer says.
@MainActor @Observable final class AppLock {
    static let shared = AppLock()
    static let enabledKey = "appLockEnabled"
    /// Background time after which becoming active locks again.
    static let relockDelay: Duration = .seconds(60)

    private enum Phase {
        case active
        case inactive
        case background
    }

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    /// The lock is on but the device has no passcode, so nothing can unlock it.
    private(set) var isPasscodeMissing = false
    private(set) var isAuthenticating = false
    private(set) var capability: AppLockCapability

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticator: any AppLockAuthenticator
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    @ObservationIgnored private var didPromptForThisLock = false
    private var phase = Phase.inactive
    /// A prompt of ours may be holding the scene inactive: set when one starts, cleared once
    /// the scene is active with no prompt running, or in the background.
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
        // With the lock off, Settings asks when it appears; nothing touches LocalAuthentication at launch.
        capability = isEnabled ? authenticator.capability() : AppLockCapability(method: .passcode, hasPasscode: true)
    }

    /// The scene isn't active and the lock is on.
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

    /// Locks if the scene was in the background too long, then prompts if this lock hasn't yet.
    /// Returns that prompt so tests can wait for it.
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
        // Checked on every return, so a passcode set again brings the lock back.
        isPasscodeMissing = !capability.hasPasscode
        guard !isPasscodeMissing, !didPromptForThisLock else { return nil }
        didPromptForThisLock = true
        return Task { await unlock() }
    }

    /// The Unlock button, and the automatic prompt.
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

    /// Continue on the "can't lock" note: the passcode is gone, so the lock turns off.
    func continueWithoutPasscode() {
        guard isPasscodeMissing else { return }
        store(enabled: false)
    }

    /// The Settings toggle. Authenticates first, and leaves the lock as it was on failure.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isAuthenticating else { return }
        refreshCapability()
        guard capability.hasPasscode else {
            // Nothing can authenticate without a passcode, and only the owner can remove one.
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

/// `LocalAuthentication` with a fresh `LAContext` per call, so one attempt's result never
/// carries into the next.
struct DeviceAppLockAuthenticator: AppLockAuthenticator {
    func capability() -> AppLockCapability {
        let context = LAContext()
        var biometryError: NSError?
        let canUseBiometry = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError)
            || biometryError?.code == LAError.biometryLockout.rawValue
        var passcodeError: NSError?
        let hasPasscode = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError)
            || passcodeError?.code != LAError.passcodeNotSet.rawValue
        // Without a passcode biometry can't be enrolled, so name the hardware, as iOS Settings does.
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

    /// Face ID or Touch ID, falling back to the passcode.
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { succeeded, _ in
                continuation.resume(returning: succeeded)
            }
        }
    }
}
