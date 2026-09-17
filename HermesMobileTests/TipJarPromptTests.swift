import XCTest
@testable import HermesMobile

final class TipJarPromptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeDefaults() throws -> UserDefaults {
        let name = "TipJarPromptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testSharedCounterReachesThresholdAndImportTemporarilySuppressesCard() throws {
        let defaults = try makeDefaults()
        let rating = RatingPromptState(defaults: defaults, now: now)
        let tip = TipJarPromptState(defaults: defaults)
        for _ in 0..<24 { rating.recordCompletedResponse() }
        XCTAssertFalse(eligible(tip, rating: rating))
        rating.recordCompletedResponse()
        XCTAssertTrue(eligible(tip, rating: rating))
        XCTAssertFalse(tip.isEligible(completedResponses: 25, hasSharedImport: true, ratingPolicy: rating.policy, now: now))
        XCTAssertTrue(eligible(tip, rating: rating))
        XCTAssertTrue(eligible(TipJarPromptState(defaults: defaults), rating: RatingPromptState(defaults: defaults, now: now)))
    }

    @MainActor
    func testDismissalSurvivesNewStateAndDoesNotClaimTip() throws {
        let defaults = try makeDefaults()
        defaults.set(25, forKey: TipJar.completedResponseCountKey)
        TipJarPromptState(defaults: defaults).dismiss()
        XCTAssertFalse(eligible(TipJarPromptState(defaults: defaults), rating: RatingPromptState(defaults: defaults, now: now)))
        XCTAssertFalse(defaults.bool(forKey: TipJar.linkOpenedKey))
    }

    @MainActor
    func testSettingsOrCardLinkPermanentlySuppressesCardAndRecordsOnlyLinkIntent() throws {
        let defaults = try makeDefaults()
        defaults.set(25, forKey: TipJar.completedResponseCountKey)
        let tip = TipJarPromptState(defaults: defaults)
        tip.recordLinkOpened()
        tip.recordLinkOpened()
        XCTAssertFalse(eligible(TipJarPromptState(defaults: defaults), rating: RatingPromptState(defaults: defaults, now: now)))
        XCTAssertTrue(defaults.bool(forKey: TipJar.linkOpenedKey))
    }

    @MainActor
    func testRatingCooldownAndTipDisplayOrdering() throws {
        let defaults = try makeDefaults()
        defaults.set(25, forKey: TipJar.completedResponseCountKey)
        defaults.set(now.addingTimeInterval(-10 * RatingPromptPolicy.day), forKey: RatingPromptSettings.firstLaunchDateKey)
        let rating = RatingPromptState(defaults: defaults, now: now)
        let tip = TipJarPromptState(defaults: defaults)
        defaults.set(now, forKey: RatingPromptSettings.lastRequestDateKey)
        XCTAssertFalse(eligible(tip, rating: rating))
        XCTAssertFalse(tip.isEligible(completedResponses: 25, hasSharedImport: false, ratingPolicy: rating.policy, now: now.addingTimeInterval(7 * RatingPromptPolicy.day - 1)))
        XCTAssertTrue(tip.isEligible(completedResponses: 25, hasSharedImport: false, ratingPolicy: rating.policy, now: now.addingTimeInterval(7 * RatingPromptPolicy.day)))
        defaults.removeObject(forKey: RatingPromptSettings.lastRequestDateKey)
        XCTAssertTrue(rating.canRequest(at: now))
        rating.recordTipCardShown()
        tip.dismiss()
        XCTAssertFalse(rating.requestIfEligible(moment: .foreground, isSessionListVisible: true, hasActiveStream: false, now: now) { XCTFail("Tip display must win for the whole launch") })
    }

    @MainActor
    func testWelcomeThenIdleGesturesRepeatEveryThreeAndAHalfSeconds() async {
        let greeting = TipJarGreetingState()
        var frames: [TipJarGreetingState.Phase] = []
        var elapsed = Duration.zero
        var changes: [(TipJarGreetingState.Phase, Duration)] = []
        await greeting.play(reduceMotion: false, wait: { duration in
            if frames.count == 23 { throw CancellationError() }
            elapsed += duration
        }, display: { frames.append($0); changes.append(($0, elapsed)) })
        XCTAssertEqual(Array(frames.prefix(7)), [.neutral, .blink, .neutral, .hop, .neutral, .blink, .neutral])
        let idle = Array(changes.dropFirst(7).filter { $0.0 != .neutral })
        XCTAssertEqual(idle.map { $0.0 }, [.blink, .glanceDown, .curious, .blink, .happy, .glanceDown, .blink, .glanceDown])
        for pair in zip(idle, idle.dropFirst()) {
            XCTAssertEqual(pair.1.1 - pair.0.1, .milliseconds(3500))
        }
        XCTAssertEqual(frames.last, .neutral)

        frames = []
        await greeting.play(reduceMotion: false, wait: { _ in
            if frames.count == 3 { throw CancellationError() }
        }, display: { frames.append($0) })
        XCTAssertEqual(frames, [.neutral, .blink, .neutral], "Returning resumes idle gestures without another hop")
    }

    @MainActor
    func testReducedMotionSchedulesNothingAndConsumesWelcome() async {
        let greeting = TipJarGreetingState()
        var frames: [TipJarGreetingState.Phase] = []
        await greeting.play(reduceMotion: true, wait: { _ in XCTFail("No motion should be scheduled") }, display: { frames.append($0) })
        XCTAssertEqual(frames, [.neutral])
        frames = []
        await greeting.play(reduceMotion: false, wait: { duration in
            XCTAssertEqual(duration, .milliseconds(3500), "Enabling motion resumes idle, not the welcome")
            throw CancellationError()
        }, display: { frames.append($0) })
        XCTAssertEqual(frames, [.neutral])
    }

    @MainActor
    func testCancellationDuringWelcomeOrIdleCannotDisplayAnotherFrame() async {
        // Covers pre-blink, airborne, neutral waiting, and holding the downward glance.
        for cancellationPause in [1, 4, 7, 10] {
            let greeting = TipJarGreetingState()
            var frames: [TipJarGreetingState.Phase] = []
            var snapshot: [TipJarGreetingState.Phase] = []
            var pauseCount = 0
            let task = Task {
                await greeting.play(reduceMotion: false, wait: { _ in
                    pauseCount += 1
                    if pauseCount == cancellationPause {
                        snapshot = frames
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }, display: { frames.append($0) })
            }
            await task.value
            XCTAssertEqual(pauseCount, cancellationPause)
            XCTAssertEqual(frames, snapshot)
        }
    }

    @MainActor
    private func eligible(_ tip: TipJarPromptState, rating: RatingPromptState) -> Bool {
        tip.isEligible(completedResponses: rating.policy.completedResponses, hasSharedImport: false, ratingPolicy: rating.policy, now: now)
    }
}
