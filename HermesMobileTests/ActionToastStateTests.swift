import XCTest
@testable import HermesMobile

/// The Undo toast's timing rules (#865): one toast at a time, a fixed display
/// time, and no timeout while VoiceOver runs. A parked sleeper stands in for
/// the clock, so no test waits on real time.
@MainActor
final class ActionToastStateTests: XCTestCase {
    func testAutoDismissFiresWhenTheDisplayTimeEnds() async {
        let sleeper = ParkedSleeper()
        let parked = expectation(description: "dismissal waiting on the clock")
        sleeper.didPark = { _ in parked.fulfill() }
        let state = ActionToastState(sleep: sleeper.sleep, isVoiceOverRunning: { false })
        let toast = makeToast()

        state.show(toast)
        await fulfillment(of: [parked], timeout: 5)

        XCTAssertEqual(state.toast?.id, toast.id)
        XCTAssertTrue(state.dismissesAutomatically)
        XCTAssertEqual(sleeper.durations, [.seconds(4)])

        let dismissed = expectation(description: "toast dismissed")
        withObservationTracking { _ = state.toast } onChange: { dismissed.fulfill() }
        sleeper.resume(0)
        await fulfillment(of: [dismissed], timeout: 5)

        XCTAssertNil(state.toast)
    }

    func testShowingASecondToastReplacesTheFirstAndCancelsItsDismissal() async {
        let sleeper = ParkedSleeper()
        let firstParked = expectation(description: "first dismissal parked")
        let secondParked = expectation(description: "second dismissal parked")
        let firstCancelled = expectation(description: "first dismissal cancelled")
        sleeper.didPark = { call in (call == 0 ? firstParked : secondParked).fulfill() }
        sleeper.didCancel = { call in
            XCTAssertEqual(call, 0, "Only the replaced toast's dismissal is cancelled")
            firstCancelled.fulfill()
        }
        let state = ActionToastState(sleep: sleeper.sleep, isVoiceOverRunning: { false })
        let first = makeToast(message: "First")
        let second = makeToast(message: "Second")

        state.show(first)
        await fulfillment(of: [firstParked], timeout: 5)
        state.show(second)
        await fulfillment(of: [firstCancelled, secondParked], timeout: 5)

        XCTAssertEqual(state.toast?.id, second.id)

        let dismissed = expectation(description: "second toast dismissed")
        withObservationTracking { _ = state.toast } onChange: { dismissed.fulfill() }
        sleeper.resume(1)
        await fulfillment(of: [dismissed], timeout: 5)

        XCTAssertNil(state.toast)
    }

    func testVoiceOverKeepsTheToastUntilTheUserActs() async {
        let sleeper = ParkedSleeper()
        var voiceOverIsRunning = true
        let state = ActionToastState(sleep: sleeper.sleep, isVoiceOverRunning: { voiceOverIsRunning })
        let toast = makeToast()

        state.show(toast)

        XCTAssertEqual(state.toast?.id, toast.id)
        XCTAssertFalse(state.dismissesAutomatically, "The view shows a close control instead")

        // Main-actor tasks start in the order they were made, so a later toast
        // shown without VoiceOver reaching the clock first proves the VoiceOver
        // toast scheduled no dismissal.
        let parked = expectation(description: "later dismissal parked")
        sleeper.didPark = { _ in parked.fulfill() }
        voiceOverIsRunning = false
        state.show(makeToast(message: "Later"))
        await fulfillment(of: [parked], timeout: 5)

        XCTAssertEqual(sleeper.durations, [.seconds(4)])
        XCTAssertTrue(state.dismissesAutomatically)
    }

    func testActionRunsOnceAndRemovesTheToast() {
        let state = ActionToastState(sleep: { _ in }, isVoiceOverRunning: { true })
        var actionCount = 0
        let toast = makeToast { actionCount += 1 }
        state.show(toast)

        state.performAction(of: toast)
        state.performAction(of: toast)

        XCTAssertEqual(actionCount, 1)
        XCTAssertNil(state.toast)
    }

    func testBusyToastStaysUntilUpdatedThenDismissesOnTheResultClock() async {
        let sleeper = ParkedSleeper()
        let parked = expectation(description: "result dismissal parked")
        sleeper.didPark = { _ in parked.fulfill() }
        let state = ActionToastState(sleep: sleeper.sleep, isVoiceOverRunning: { false })

        let id = state.show(ActionToast(message: "Pushing...", systemImage: "arrow.up.circle",
                                        accessibilityLabel: "Pushing...", tone: .busy))
        state.update(id, to: ActionToast(message: "Push complete", systemImage: "checkmark.circle.fill",
                                         accessibilityLabel: "Push complete", tone: .success,
                                         detailLines: ["main"]))
        await fulfillment(of: [parked], timeout: 5)

        // Main-actor tasks start in the order they were made, so a busy clock
        // would have reached the sleeper before the result's did.
        XCTAssertEqual(sleeper.durations, [.seconds(6)], "Only the result has a clock, and its detail earns six seconds")
        XCTAssertEqual(state.toast?.id, id)

        let dismissed = expectation(description: "result dismissed")
        withObservationTracking { _ = state.toast } onChange: { dismissed.fulfill() }
        sleeper.resume(0)
        await fulfillment(of: [dismissed], timeout: 5)

        XCTAssertNil(state.toast)
    }

    func testUpdateKeepsTheToastWhileShowReplacesIt() {
        let state = ActionToastState(sleep: { _ in }, isVoiceOverRunning: { true })
        let busy = state.show(ActionToast(message: "Committing...", systemImage: "smallcircle.filled.circle",
                                          accessibilityLabel: "Committing...", tone: .busy))

        state.update(busy, to: makeToast(message: "Pushing..."))
        XCTAssertEqual(state.toast?.id, busy, "An update keeps the toast, and VoiceOver's focus on it")
        XCTAssertEqual(state.toast?.message, "Pushing...")

        let undo = state.show(makeToast(message: "Archived"))
        XCTAssertNotEqual(undo, busy)

        // The Git operation finishes after the Undo toast replaced its toast.
        state.update(busy, to: makeToast(message: "Push complete"))
        state.dismiss(busy)
        XCTAssertEqual(state.toast?.id, undo)
        XCTAssertEqual(state.toast?.message, "Archived")

        // A toast swiped away stays gone when its operation reports late.
        state.dismiss(undo)
        state.update(undo, to: makeToast(message: "Push complete"))
        XCTAssertNil(state.toast)
    }

    /// Chat shows Git feedback at the top and notices over the composer from one state, so a
    /// notice such as an expired waiting send (#1407) takes over from a busy Git toast and a late
    /// Git result can't bring the top toast back.
    func testAToastShowsOnlyAtItsOwnEdgeAndANoticeAtTheOtherEdgeReplacesIt() {
        let state = ActionToastState(sleep: { _ in }, isVoiceOverRunning: { true })
        let git = state.show(ActionToast(message: "Pushing...", systemImage: "arrow.up.circle",
                                         accessibilityLabel: "Pushing...", tone: .busy, edge: .top))
        XCTAssertEqual(state.toast(at: .top)?.id, git)
        XCTAssertNil(state.toast(at: .bottom))

        let notice = state.show(ActionToast(message: "Not sent", systemImage: "clock", accessibilityLabel: "Not sent"))
        state.update(git, to: ActionToast(message: "Push complete", systemImage: "checkmark.circle.fill",
                                          accessibilityLabel: "Push complete", tone: .success, edge: .top))

        XCTAssertNil(state.toast(at: .top))
        XCTAssertEqual(state.toast(at: .bottom)?.id, notice)
    }

    private func makeToast(
        message: String = "Archived",
        action: @escaping @MainActor () -> Void = {}
    ) -> ActionToast {
        ActionToast(
            message: message,
            systemImage: "archivebox",
            accessibilityLabel: "Planning, \(message)",
            actionTitle: "Undo",
            action: action
        )
    }
}

/// A toast leaves on a sideways drag past a quarter of its width or a sideways
/// flick (#1410); a vertical drag never dismisses it.
final class ActionToastDismissPolicyTests: XCTestCase {
    func testDismissesOnAQuarterWidthOrAFlickButNotAVerticalDrag() {
        let width: CGFloat = 360

        XCTAssertTrue(ActionToastDismissPolicy.shouldDismiss(
            translation: CGSize(width: 95, height: 4), velocity: .zero, width: width))
        XCTAssertTrue(ActionToastDismissPolicy.shouldDismiss(
            translation: CGSize(width: -30, height: 2), velocity: CGSize(width: -900, height: 0), width: width))
        XCTAssertFalse(ActionToastDismissPolicy.shouldDismiss(
            translation: CGSize(width: 60, height: 3), velocity: CGSize(width: 100, height: 0), width: width),
            "A short, slow drag springs back")
        XCTAssertFalse(ActionToastDismissPolicy.shouldDismiss(
            translation: CGSize(width: 100, height: 240), velocity: CGSize(width: 900, height: 1500), width: width),
            "A mostly vertical drag is a scroll, not a dismissal")
        XCTAssertFalse(ActionToastDismissPolicy.shouldDismiss(
            translation: CGSize(width: 40, height: 0), velocity: CGSize(width: -900, height: 0), width: width),
            "A flick back toward the start cancels the swipe")
    }
}

/// Stands in for `Task.sleep`: each call parks until the test resumes it, and
/// throws `CancellationError` when its task is cancelled, like the real sleep.
@MainActor
private final class ParkedSleeper {
    private(set) var durations: [Duration] = []
    private var parked: [Int: CheckedContinuation<Void, Error>] = [:]
    var didPark: ((Int) -> Void)?
    var didCancel: ((Int) -> Void)?

    func sleep(_ duration: Duration) async throws {
        let call = durations.count
        durations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                parked[call] = continuation
                didPark?(call)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(call) }
        }
    }

    func resume(_ call: Int) {
        parked.removeValue(forKey: call)?.resume()
    }

    private func cancel(_ call: Int) {
        guard let continuation = parked.removeValue(forKey: call) else { return }
        continuation.resume(throwing: CancellationError())
        didCancel?(call)
    }
}
