import XCTest
@testable import HermesMobile

final class SessionListCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeDefaults() throws -> UserDefaults {
        let name = "SessionListCardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testEachCardReachesItsThresholdOnTheSharedCounterAndImportTemporarilySuppressesIt() throws {
        for (card, threshold) in [(SessionListCard.tip, 25), (.star, 15)] {
            let defaults = try makeDefaults()
            let rating = RatingPromptState(defaults: defaults, now: now)
            let state = SessionListCardState(card: card, defaults: defaults)
            for _ in 0..<(threshold - 1) { rating.recordCompletedResponse() }
            XCTAssertFalse(eligible(state, rating: rating), "\(card)")
            rating.recordCompletedResponse()
            XCTAssertTrue(eligible(state, rating: rating), "\(card)")
            XCTAssertFalse(state.isEligible(completedResponses: threshold, hasSharedImport: true, ratingPolicy: rating.policy, now: now))
            XCTAssertTrue(eligible(SessionListCardState(card: card, defaults: defaults), rating: RatingPromptState(defaults: defaults, now: now)))
        }
    }

    @MainActor
    func testDismissalLastsUntilTheNextFeatureReleaseAndHidesOnlyThatCard() throws {
        for card in [SessionListCard.tip, .star] {
            let other: SessionListCard = card == .tip ? .star : .tip
            let defaults = try makeDefaults()
            defaults.set(25, forKey: TipJar.completedResponseCountKey)
            let rating = RatingPromptState(defaults: defaults, now: now)
            SessionListCardState(card: card, defaults: defaults, appVersion: "1.8").dismiss()
            XCTAssertFalse(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "1.8"), rating: rating))
            XCTAssertFalse(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "1.8.1"), rating: rating),
                           "A patch update keeps the dismissal")
            XCTAssertTrue(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "1.9"), rating: rating))
            XCTAssertTrue(eligible(SessionListCardState(card: other, defaults: defaults, appVersion: "1.8"), rating: rating))
        }
    }

    @MainActor
    func testOpeningALinkHidesOnlyThatCardForGood() throws {
        for card in [SessionListCard.tip, .star] {
            let other: SessionListCard = card == .tip ? .star : .tip
            let defaults = try makeDefaults()
            defaults.set(25, forKey: TipJar.completedResponseCountKey)
            let rating = RatingPromptState(defaults: defaults, now: now)
            SessionListCardState(card: card, defaults: defaults, appVersion: "1.8").recordLinkOpened()
            XCTAssertFalse(eligible(SessionListCardState(card: card, defaults: defaults, appVersion: "2.0"), rating: rating),
                           "Opening a link hides the card on every later release")
            XCTAssertTrue(eligible(SessionListCardState(card: other, defaults: defaults, appVersion: "1.8"), rating: rating))
        }
    }

    @MainActor
    func testBothCardsWaitSevenDaysAfterARatingRequest() throws {
        let defaults = try makeDefaults()
        defaults.set(now, forKey: RatingPromptSettings.lastRequestDateKey)
        let rating = RatingPromptState(defaults: defaults, now: now)
        for card in [SessionListCard.tip, .star] {
            let state = SessionListCardState(card: card, defaults: defaults)
            XCTAssertFalse(state.isEligible(completedResponses: 25, hasSharedImport: false, ratingPolicy: rating.policy, now: now.addingTimeInterval(7 * RatingPromptPolicy.day - 1)))
            XCTAssertTrue(state.isEligible(completedResponses: 25, hasSharedImport: false, ratingPolicy: rating.policy, now: now.addingTimeInterval(7 * RatingPromptPolicy.day)))
        }
    }

    func testTipCardWinsAndOnlyOneCardShowsPerLaunch() {
        XCTAssertEqual(SessionListCard.choose(tipEligible: true, starEligible: true, shownThisLaunch: nil), .tip)
        // Dismissing the tip card leaves the slot empty until a later launch.
        XCTAssertNil(SessionListCard.choose(tipEligible: false, starEligible: true, shownThisLaunch: .tip))
        // A star card already showing keeps the slot when the tip card becomes eligible mid-launch.
        XCTAssertEqual(SessionListCard.choose(tipEligible: true, starEligible: true, shownThisLaunch: .star), .star)
    }

    @MainActor
    func testReducedMotionSchedulesNothingAndConsumesWelcome() async {
        let greeting = SessionListCardGreeting()
        var frames: [SessionListCardGreeting.Phase] = []
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
            let greeting = SessionListCardGreeting()
            var frames: [SessionListCardGreeting.Phase] = []
            var snapshot: [SessionListCardGreeting.Phase] = []
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
    private func eligible(_ state: SessionListCardState, rating: RatingPromptState) -> Bool {
        state.isEligible(completedResponses: rating.policy.completedResponses, hasSharedImport: false, ratingPolicy: rating.policy, now: now)
    }
}
