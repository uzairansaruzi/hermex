import XCTest
import UserNotifications
@testable import HermesMobile

@MainActor
final class NotificationOfferTests: XCTestCase {
    private let server = URL(string: "https://a.example.com")!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationOfferTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testOffersLocalAlertsWhenTheServerCannotPair() {
        for status: UNAuthorizationStatus in [.notDetermined, .authorized, .provisional] {
            XCTAssertEqual(decide(authorization: status), .localAlerts, "status \(status.rawValue)")
        }
    }

    func testOffersPushWhenTheServerCanPair() {
        XCTAssertEqual(decide(canPair: true), .push)
    }

    func testClaimMarksTheOfferMadeSoItIsAskedOnce() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .notDetermined)

        let first = await claim(scheduler: scheduler, canPair: true)
        let second = await claim(scheduler: scheduler, canPair: true)

        XCTAssertEqual(first, .push)
        XCTAssertTrue(defaults.bool(forKey: "notificationOffer.hasOffered"))
        XCTAssertNil(second)
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 0)
    }

    func testClaimLeavesTheFlagUnsetWhenThereIsNothingToOffer() async {
        let offer = await claim(scheduler: SpyResponseCompletionNotificationScheduler(status: .denied))

        XCTAssertNil(offer)
        XCTAssertFalse(defaults.bool(forKey: "notificationOffer.hasOffered"))
    }

    func testClaimLeavesTheFlagUnsetWhenTheChatIsGone() async {
        var isOnScreen = true
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized) {
            isOnScreen = false
        }

        let offer = await NotificationOffer.claim(
            server: server,
            defaults: defaults,
            isCurrent: { isOnScreen },
            isPushPaired: { _ in false },
            canPair: { _ in false },
            scheduler: scheduler
        )

        XCTAssertNil(offer)
        XCTAssertFalse(defaults.bool(forKey: "notificationOffer.hasOffered"))
    }

    func testClaimSkipsKeychainReadsThatCannotChangeTheAnswer() async {
        var reads: [String] = []
        func claimCountingReads(status: UNAuthorizationStatus, isPaired: Bool) async -> NotificationOffer.Offer? {
            await NotificationOffer.claim(
                server: server,
                defaults: defaults,
                isPushPaired: { _ in reads.append("pairing"); return isPaired },
                canPair: { _ in reads.append("connection"); return true },
                scheduler: SpyResponseCompletionNotificationScheduler(status: status)
            )
        }

        let denied = await claimCountingReads(status: .denied, isPaired: false)
        XCTAssertNil(denied)
        XCTAssertEqual(reads, [])

        let paired = await claimCountingReads(status: .authorized, isPaired: true)
        XCTAssertNil(paired)
        XCTAssertEqual(reads, ["pairing"])
    }

    func testClaimSkipsThePermissionCheckWhenLocalAlertsAreOn() async {
        defaults.set(true, forKey: ResponseCompletionNotifications.isEnabledKey)
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let offer = await claim(scheduler: scheduler)

        XCTAssertNil(offer)
        XCTAssertEqual(scheduler.authorizationStatusCallCount, 0)
    }

    private func decide(
        hasOffered: Bool = false,
        localAlertsEnabled: Bool = false,
        authorization: UNAuthorizationStatus = .notDetermined,
        isPaired: Bool = false,
        canPair: Bool = false
    ) -> NotificationOffer.Offer? {
        NotificationOffer.decide(
            hasOffered: hasOffered,
            localAlertsEnabled: localAlertsEnabled,
            authorization: authorization,
            isPaired: isPaired,
            canPair: canPair
        )
    }

    private func claim(
        scheduler: SpyResponseCompletionNotificationScheduler,
        canPair: Bool = false
    ) async -> NotificationOffer.Offer? {
        await NotificationOffer.claim(
            server: server,
            defaults: defaults,
            isPushPaired: { _ in false },
            canPair: { _ in canPair },
            scheduler: scheduler
        )
    }
}
