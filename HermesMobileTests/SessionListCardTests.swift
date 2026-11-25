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

    func testUsageReportsCardWinsThenTipAndOnlyOneCardShowsPerLaunch() {
        XCTAssertEqual(SessionListCard.choose(eligible: [.usageReports, .tip, .star], shownThisLaunch: nil), .usageReports)
        XCTAssertEqual(SessionListCard.choose(eligible: [.tip, .star], shownThisLaunch: nil), .tip)
        XCTAssertNil(SessionListCard.choose(eligible: [.tip, .star], shownThisLaunch: .usageReports))
        XCTAssertNil(SessionListCard.choose(eligible: [.star], shownThisLaunch: .tip))
        XCTAssertEqual(SessionListCard.choose(eligible: [.usageReports, .tip, .star], shownThisLaunch: .star), .star)
    }

    func testAPluginUpdateOutranksEveryCardEvenOneAlreadyShownThisLaunch() {
        XCTAssertEqual(SessionListCard.choose(eligible: [.pluginUpdate, .usageReports, .tip, .star], shownThisLaunch: nil), .pluginUpdate)
        XCTAssertEqual(SessionListCard.choose(eligible: [.pluginUpdate, .tip], shownThisLaunch: .tip), .pluginUpdate)
    }

    @MainActor
    func testADismissedPluginUpdateStaysHiddenUntilANewerVersionIsOfferedOnThatServer() throws {
        let defaults = try makeDefaults()
        let serverA = URL(string: "https://a.example.com")!
        let serverB = URL(string: "https://b.example.com")!
        let loaded = try XCTUnwrap(HermexPushPluginVersion("0.7.2"))
        let offers = HermexPushUpdateOffers(defaults: defaults)
        offers.record(.newer(loaded: loaded, target: "aaa111"), for: serverA)
        offers.record(.newer(loaded: loaded, target: "aaa111"), for: serverB)

        offers.dismiss(try XCTUnwrap(offers.cardOffer(for: serverA)), for: serverA)

        XCTAssertNil(offers.cardOffer(for: serverA))
        XCTAssertNotNil(offers.offer(for: serverA), "Settings still badges a dismissed update")
        XCTAssertNotNil(offers.cardOffer(for: serverB), "Dismissing on one server leaves another's card")

        let relaunched = HermexPushUpdateOffers(defaults: defaults)
        relaunched.record(.newer(loaded: loaded, target: "aaa111"), for: serverA)
        XCTAssertNil(relaunched.cardOffer(for: serverA), "The dismissal outlives the launch")
        relaunched.record(.available(loaded: loaded), for: serverA)
        XCTAssertNotNil(relaunched.cardOffer(for: serverA), "Falling below this build's minimum is a new offer")
        relaunched.record(.newer(loaded: loaded, target: "bbb222"), for: serverA)
        XCTAssertNotNil(relaunched.cardOffer(for: serverA), "A newer plugin brings the card back")
    }

    @MainActor
    func testUsageReportsCardAsksFromFiveResponsesUntilAnswered() throws {
        let defaults = try makeDefaults()
        let reports = UsageReports(defaults: defaults, servers: { [] })
        let policy = RatingPromptState(defaults: defaults, now: now).policy
        func eligible(_ responses: Int, sharedImport: Bool = false) -> Bool {
            SessionListCard.usageReportsEligible(question: reports.consent.question(), completedResponses: responses,
                                                 hasSharedImport: sharedImport, ratingPolicy: policy, now: now)
        }
        XCTAssertFalse(eligible(4))
        XCTAssertTrue(eligible(5))
        XCTAssertTrue(eligible(500), "Someone past the threshold when the card ships is asked too")
        XCTAssertFalse(eligible(5, sharedImport: true))
        reports.decline()
        XCTAssertFalse(eligible(5), "No thanks never asks again")
    }

    func testUsageReportsReaskOnlyForANewerFormatAfterAllowing() {
        XCTAssertEqual(UsageReportConsent().question(currentVersion: 1), .allow)
        XCTAssertNil(UsageReportConsent(acceptedVersion: 1).question(currentVersion: 1))
        XCTAssertEqual(UsageReportConsent(acceptedVersion: 1).question(currentVersion: 2),
                       .moreFields(UsageReport.fieldsAdded(after: 1)))
        XCTAssertNil(UsageReportConsent(acceptedVersion: 1, declinedVersion: 2).question(currentVersion: 2),
                     "No thanks on the re-prompt keeps the old format and doesn't ask again")
        XCTAssertNil(UsageReportConsent(declinedVersion: 1).question(currentVersion: 2),
                     "A first No thanks is permanent")
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
