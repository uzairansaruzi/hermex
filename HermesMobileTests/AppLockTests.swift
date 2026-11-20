import XCTest
@testable import HermesMobile

@MainActor
final class AppLockTests: XCTestCase {
    private let authenticator = FakeAppLockAuthenticator()
    private let clock = ManualClock()

    func testColdLaunchLocksOnlyWhenTheLockIsOn() {
        XCTAssertTrue(makeLock(enabled: true).isLocked)

        let off = makeLock(enabled: false)
        XCTAssertFalse(off.isLocked)
        XCTAssertNil(off.sceneDidBecomeActive(), "With the lock off nothing prompts")
        off.sceneWillResignActive()
        off.sceneDidEnterBackground()
        XCTAssertFalse(off.showsLockWindow, "With the lock off nothing covers the app")
        XCTAssertEqual(authenticator.reasons, [])
    }

    func testReturningAfterMoreThanAMinuteInTheBackgroundLocksAndPromptsAgain() async {
        let lock = await unlockedLock()

        lock.sceneWillResignActive()
        lock.sceneDidEnterBackground()
        clock.advance(by: .seconds(59))
        XCTAssertNil(lock.sceneDidBecomeActive())
        XCTAssertFalse(lock.isLocked)

        lock.sceneWillResignActive()
        lock.sceneDidEnterBackground()
        clock.advance(by: .seconds(61))
        await lock.sceneDidBecomeActive()?.value
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(authenticator.reasons.count, 2, "A new lock prompts once by itself")
    }

    func testInactiveThenActiveNeverLocks() async {
        let lock = await unlockedLock()

        lock.sceneWillResignActive()
        clock.advance(by: .seconds(600))
        lock.sceneDidBecomeActive()

        XCTAssertFalse(lock.isLocked)
    }

    func testTheCoverShowsExactlyWhileTheSceneIsNotActive() async {
        let lock = await unlockedLock()
        XCTAssertFalse(lock.showsLockWindow)

        lock.sceneWillResignActive()
        XCTAssertTrue(lock.isCovered)
        XCTAssertTrue(lock.showsLockWindow)
        lock.sceneDidEnterBackground()
        XCTAssertTrue(lock.showsLockWindow)
        lock.sceneDidBecomeActive()
        XCTAssertFalse(lock.isCovered)
        XCTAssertFalse(lock.showsLockWindow)

        lock.sceneWillResignActive()
        lock.sceneDidEnterBackground()
        clock.advance(by: .seconds(61))
        await lock.sceneDidBecomeActive()?.value
        XCTAssertTrue(lock.isLocked, "The automatic prompt was cancelled")
        XCTAssertFalse(lock.isCovered)
        lock.sceneWillResignActive()
        XCTAssertTrue(lock.isCovered)
    }

    func testItsOwnPromptNeverShowsTheCover() async {
        let lock = makeLock(enabled: true)
        authenticator.duringPrompt = { lock.sceneWillResignActive() }
        authenticator.answers = [true]
        await lock.sceneDidBecomeActive()?.value

        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.showsLockWindow, "Unlocking doesn't swap the lock for the blank cover")

        lock.sceneDidBecomeActive()
        lock.sceneWillResignActive()
        XCTAssertTrue(lock.showsLockWindow, "Once active again, going inactive covers as usual")
    }

    func testAuthenticationUnlocksAndTheAutomaticPromptRunsOncePerLock() async {
        let lock = makeLock(enabled: true)

        authenticator.answers = [false]
        await lock.sceneDidBecomeActive()?.value
        XCTAssertTrue(lock.isLocked, "A cancel or failure keeps the lock up")

        lock.sceneWillResignActive()
        XCTAssertNil(lock.sceneDidBecomeActive(), "No prompt loop after a cancel")
        XCTAssertEqual(authenticator.reasons.count, 1)

        authenticator.answers = [true]
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(authenticator.reasons, ["Unlock Hermex", "Unlock Hermex"])
    }

    func testTurningTheLockOnOrOffNeedsAuthentication() async {
        let defaults = makeDefaults()
        let lock = makeLock(enabled: false, defaults: defaults)
        lock.sceneDidBecomeActive()

        authenticator.answers = [false]
        await lock.setEnabled(true)
        XCTAssertFalse(lock.isEnabled, "A failed prompt leaves the toggle as it was")

        authenticator.answers = [true]
        await lock.setEnabled(true)
        XCTAssertTrue(lock.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: AppLock.enabledKey))
        XCTAssertFalse(lock.isLocked, "Turning it on doesn't lock the user out now")

        authenticator.answers = [false]
        await lock.setEnabled(false)
        XCTAssertTrue(lock.isEnabled)

        authenticator.answers = [true]
        await lock.setEnabled(false)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: AppLock.enabledKey))
        XCTAssertEqual(authenticator.reasons, [
            "Turn on the app lock", "Turn on the app lock", "Turn off the app lock", "Turn off the app lock",
        ])
    }

    func testWithoutAPasscodeTheLockCanOnlyBeTurnedOff() async {
        authenticator.capabilityValue.hasPasscode = false
        let off = makeLock(enabled: false)
        await off.setEnabled(true)
        XCTAssertFalse(off.isEnabled)
        XCTAssertFalse(off.capability.hasPasscode)

        let on = makeLock(enabled: true)
        await on.setEnabled(false)
        XCTAssertFalse(on.isEnabled)
        XCTAssertEqual(authenticator.reasons, [])
    }

    func testAPasscodeRemovedWhileOnShowsTheNoteAndContinueTurnsTheLockOff() {
        let defaults = makeDefaults()
        let lock = makeLock(enabled: true, defaults: defaults)
        authenticator.capabilityValue.hasPasscode = false

        XCTAssertNil(lock.sceneDidBecomeActive())
        XCTAssertTrue(lock.isPasscodeMissing)
        XCTAssertTrue(lock.showsLockWindow, "It never opens silently")

        lock.continueWithoutPasscode()
        XCTAssertFalse(lock.showsLockWindow)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: AppLock.enabledKey))
        XCTAssertEqual(authenticator.reasons, [])
    }

    func testPushPresenceReportsNoChatOnScreenWhileLocked() async {
        let lock = makeLock(enabled: true)
        let presence = PushPresence(appLock: lock)
        let viewer = PushPresence.Viewer(server: URL(string: "https://alpha.example.test")!, sessionID: "s1")
        presence.enter(viewer, owner: UUID())

        XCTAssertNil(presence.viewer, "Quiet the Open Chat mustn't hide banners for a chat behind the lock")

        authenticator.answers = [true]
        await lock.sceneDidBecomeActive()?.value
        XCTAssertEqual(presence.viewer, viewer)
    }

    private func makeLock(enabled: Bool, defaults: UserDefaults? = nil) -> AppLock {
        let defaults = defaults ?? makeDefaults()
        defaults.set(enabled, forKey: AppLock.enabledKey)
        let clock = clock
        return AppLock(defaults: defaults, authenticator: authenticator, now: { clock.now })
    }

    private func unlockedLock() async -> AppLock {
        let lock = makeLock(enabled: true)
        authenticator.answers = [true]
        await lock.sceneDidBecomeActive()?.value
        XCTAssertFalse(lock.isLocked)
        return lock
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppLockTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return UserDefaults(suiteName: suiteName)!
    }
}

@MainActor
private final class FakeAppLockAuthenticator: AppLockAuthenticator {
    var capabilityValue = AppLockCapability(method: .faceID, hasPasscode: true)
    var answers: [Bool] = []
    var duringPrompt: (() -> Void)?
    private(set) var reasons: [String] = []

    func capability() -> AppLockCapability { capabilityValue }

    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        duringPrompt?()
        return answers.isEmpty ? false : answers.removeFirst()
    }
}

private final class ManualClock {
    private(set) var now = ContinuousClock.now

    func advance(by duration: Duration) {
        now += duration
    }
}
