import XCTest
@testable import HermesMobile

@MainActor final class HermexOverlayLifecycleTests: XCTestCase {
    func testPresentationRequiresMatchingGenerationToBecomePresented() {
        var lifecycle = HermexOverlayLifecycle()
        guard let generation = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }

        XCTAssertFalse(lifecycle.completePresentation(generation: generation - 1),
                        "A stale generation must not complete presentation")
        XCTAssertEqual(lifecycle.phase, .entering)

        XCTAssertTrue(lifecycle.completePresentation(generation: generation))
        XCTAssertEqual(lifecycle.phase, .presented)
    }

    func testDismissalRunsDeferredActionExactlyOnceAfterMatchingExit() {
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        var runCount = 0
        guard let dismissGeneration = lifecycle.beginDismissal(after: { runCount += 1 }) else {
            return XCTFail("An enabled action must be accepted while presented")
        }
        XCTAssertEqual(lifecycle.phase, .dismissing)
        XCTAssertEqual(runCount, 0, "The action must not run before exit completes")

        guard case .completed(let action, let reopened) = lifecycle.completeDismissal(generation: dismissGeneration) else {
            return XCTFail("The matching generation must complete dismissal")
        }
        XCTAssertEqual(lifecycle.phase, .hidden)
        XCTAssertNil(reopened, "No reopen was ever requested, so completion must not hand one back")
        action?()
        XCTAssertEqual(runCount, 1)

        // Completing again for the same, now-stale generation must not run the action twice.
        if case .completed(let again, _) = lifecycle.completeDismissal(generation: dismissGeneration) {
            again?()
        }
        XCTAssertEqual(runCount, 1)
    }

    func testRepeatedDismissRequestDoesNotReplaceOrDuplicatePendingAction() {
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        var firstCount = 0
        var secondCount = 0
        guard let dismissGeneration = lifecycle.beginDismissal(after: { firstCount += 1 }) else {
            return XCTFail("The first action must be accepted")
        }
        XCTAssertNil(lifecycle.beginDismissal(after: { secondCount += 1 }),
                      "A second request while already dismissing must be rejected")

        guard case .completed(let action, _) = lifecycle.completeDismissal(generation: dismissGeneration) else {
            return XCTFail("The original generation must still complete")
        }
        action?()
        XCTAssertEqual(firstCount, 1, "Only the first accepted action may run")
        XCTAssertEqual(secondCount, 0, "The rejected second action must never run")
    }

    func testStaleExitCompletionCannotHideRePresentedOverlay() {
        var lifecycle = HermexOverlayLifecycle()
        guard let firstEntry = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: firstEntry))
        guard let staleDismissGeneration = lifecycle.beginDismissal() else {
            return XCTFail("Dismissal from presented must be accepted")
        }

        // A newer presentation begins before the stale dismissal ever completes. No action was
        // deferred on this plain dismissal, so the re-presentation must supersede it.
        guard let secondEntry = lifecycle.beginPresentation() else {
            return XCTFail("Re-presentation over a plain (action-less) dismissal must be accepted")
        }
        XCTAssertEqual(lifecycle.phase, .entering)
        XCTAssertNotEqual(secondEntry, staleDismissGeneration)

        if case .completed = lifecycle.completeDismissal(generation: staleDismissGeneration) {
            XCTFail("A stale dismissal must never complete against a newer presentation")
        }
        XCTAssertEqual(lifecycle.phase, .entering, "The newer presentation must stay untouched")
    }

    func testOwnerCancellationDropsPendingActionAndReturnsHidden() {
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        var runCount = 0
        guard let dismissGeneration = lifecycle.beginDismissal(after: { runCount += 1 }) else {
            return XCTFail("Dismissal with an action must be accepted while presented")
        }

        lifecycle.cancelOwner()
        XCTAssertEqual(lifecycle.phase, .hidden)

        if case .completed(let action, _) = lifecycle.completeDismissal(generation: dismissGeneration) {
            action?()
        }
        XCTAssertEqual(runCount, 0, "A cancelled owner must drop its pending action")
    }

    func testActionsAreAcceptedOnlyWhilePresented() {
        var lifecycle = HermexOverlayLifecycle()
        var runCount = 0

        XCTAssertNil(lifecycle.beginDismissal(after: { runCount += 1 }),
                      "An action cannot be accepted from .hidden")

        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertNil(lifecycle.beginDismissal(after: { runCount += 1 }),
                      "An action cannot be accepted while still .entering")

        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))
        guard let dismissGeneration = lifecycle.beginDismissal(after: { runCount += 1 }) else {
            return XCTFail("An action must be accepted once .presented")
        }
        if case .completed(let action, _) = lifecycle.completeDismissal(generation: dismissGeneration) {
            action?()
        }
        XCTAssertEqual(runCount, 1)
    }

    func testBeginPresentationIsRejectedWhileEnteringOrPresented() {
        var lifecycle = HermexOverlayLifecycle()
        guard let firstGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }

        XCTAssertNil(lifecycle.beginPresentation(),
                      "A duplicate open request while .entering must be rejected, not restart the transition")
        XCTAssertEqual(lifecycle.phase, .entering)

        XCTAssertTrue(lifecycle.completePresentation(generation: firstGeneration))
        XCTAssertNil(lifecycle.beginPresentation(),
                      "A duplicate open request while .presented must be rejected, not restart the transition")
        XCTAssertEqual(lifecycle.phase, .presented)
    }

    func testBeginPresentationSupersedesAPlainDismissalWithNoDeferredAction() {
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        guard let dismissGeneration = lifecycle.beginDismissal() else {
            return XCTFail("A plain dismissal must be accepted while presented")
        }
        XCTAssertEqual(lifecycle.phase, .dismissing)

        guard let reopenGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Re-presenting over a plain (action-less) dismissal must be accepted")
        }
        XCTAssertNotEqual(reopenGeneration, dismissGeneration,
                           "Re-opening a plain dismissal must supersede it with a new generation")
        XCTAssertEqual(lifecycle.phase, .entering)

        if case .completed = lifecycle.completeDismissal(generation: dismissGeneration) {
            XCTFail("The superseded dismissal generation must never complete")
        }
    }

    func testBeginPresentationIsRejectedWhileDismissingWithADeferredActionSoItRunsExactlyOnce() {
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        var runCount = 0
        guard let dismissGeneration = lifecycle.beginDismissal(after: { runCount += 1 }) else {
            return XCTFail("Dismissal with an action must be accepted while presented")
        }
        XCTAssertEqual(lifecycle.phase, .dismissing)

        XCTAssertNil(lifecycle.beginPresentation(),
                      "Re-presenting while a deferred action is pending must be rejected (no generation to " +
                      "complete against yet), so the exit can finish — but queued as a reopen, not dropped")
        XCTAssertEqual(lifecycle.phase, .dismissing, "The rejected request must leave the in-flight exit untouched")

        guard case .completed(let action, let reopened) = lifecycle.completeDismissal(generation: dismissGeneration) else {
            return XCTFail("The original exit must still be able to complete")
        }
        action?()
        XCTAssertEqual(runCount, 1, "The deferred action must run exactly once")
        XCTAssertNotNil(reopened,
                         "The queued reopen must hand back a fresh generation once the action-bearing exit completes")
        XCTAssertEqual(lifecycle.phase, .entering,
                        "A queued reopen must move straight into a fresh entering transition, never surfacing .hidden")
    }

    func testQueuedReopenRunsTheDeferredActionOnceThenCompletesAFreshPresentationGeneration() {
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        var runCount = 0
        guard let dismissGeneration = lifecycle.beginDismissal(after: { runCount += 1 }) else {
            return XCTFail("Dismissal with an action must be accepted while presented")
        }

        XCTAssertNil(lifecycle.beginPresentation(), "The reopen request itself never returns a generation directly")
        XCTAssertNil(lifecycle.beginPresentation(),
                      "A duplicate reopen request while one is already queued must stay a no-op, not re-queue or restart anything")

        guard case .completed(let action, let reopened) = lifecycle.completeDismissal(generation: dismissGeneration) else {
            return XCTFail("The original exit must still complete")
        }
        XCTAssertEqual(runCount, 0, "The action must not have run before the lifecycle hands it back")
        action?()
        XCTAssertEqual(runCount, 1, "The deferred action must run exactly once")

        guard let reopenGeneration = reopened else {
            return XCTFail("A queued reopen must hand back a fresh generation to complete against")
        }
        XCTAssertNotEqual(reopenGeneration, dismissGeneration,
                           "The reopen must be a new generation, not the completed dismissal's own")
        XCTAssertEqual(lifecycle.phase, .entering)

        XCTAssertTrue(lifecycle.completePresentation(generation: reopenGeneration),
                       "The fresh reopen generation must be able to complete into .presented like any other entry")
        XCTAssertEqual(lifecycle.phase, .presented)
    }

    func testPlainDismissalAfterQueuedReopenCancelsOnlyTheReopenNotTheOriginalAction() {
        // Approved contract: if the owner asks to plainly dismiss again after a reopen has been
        // queued but before the original action-bearing exit completes, only the queued reopen is
        // cancelled — the original deferred action still runs exactly once, and completion settles
        // into .hidden like an ordinary dismissal.
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        var runCount = 0
        guard let dismissGeneration = lifecycle.beginDismissal(after: { runCount += 1 }) else {
            return XCTFail("Dismissal with an action must be accepted while presented")
        }
        XCTAssertNil(lifecycle.beginPresentation(), "The reopen request must queue instead of returning a generation")

        XCTAssertNil(lifecycle.beginDismissal(),
                      "A later plain dismissal while already dismissing is still not its own new transition")
        XCTAssertEqual(lifecycle.phase, .dismissing, "Cancelling the queued reopen must not touch the in-flight exit")

        guard case .completed(let action, let reopened) = lifecycle.completeDismissal(generation: dismissGeneration) else {
            return XCTFail("The original exit must still complete")
        }
        action?()
        XCTAssertEqual(runCount, 1, "The original deferred action must still run exactly once")
        XCTAssertNil(reopened, "A later plain dismissal must cancel the queued reopen, not let it survive")
        XCTAssertEqual(lifecycle.phase, .hidden,
                        "With the reopen cancelled, completion must land on .hidden like any ordinary dismissal")
    }

    func testOwnerCancellationDropsAQueuedReopenAlongsideThePendingAction() {
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        XCTAssertTrue(lifecycle.completePresentation(generation: entryGeneration))

        var runCount = 0
        guard let dismissGeneration = lifecycle.beginDismissal(after: { runCount += 1 }) else {
            return XCTFail("Dismissal with an action must be accepted while presented")
        }
        XCTAssertNil(lifecycle.beginPresentation(), "The reopen request must queue instead of returning a generation")

        lifecycle.cancelOwner()
        XCTAssertEqual(lifecycle.phase, .hidden)

        if case .completed = lifecycle.completeDismissal(generation: dismissGeneration) {
            XCTFail("A cancelled owner invalidates the generation — the stale dismissal must never complete")
        }
        XCTAssertEqual(runCount, 0, "A cancelled owner must drop both its pending action and any queued reopen")
    }

    func testPlainDismissalIsAcceptedWhileEntering() {
        // Approved contract T3: a dismissal request during `.entering` cancels pending entry work
        // and proceeds to `.dismissing` — unlike an action, which only fires once `.presented`.
        var lifecycle = HermexOverlayLifecycle()
        guard let entryGeneration = lifecycle.beginPresentation() else {
            return XCTFail("Presentation from .hidden must be accepted")
        }
        guard let dismissGeneration = lifecycle.beginDismissal() else {
            return XCTFail("A plain dismiss-only request must be accepted while .entering")
        }
        XCTAssertEqual(lifecycle.phase, .dismissing)
        XCTAssertFalse(lifecycle.completePresentation(generation: entryGeneration),
                        "Entry must not complete once dismissal has begun")
        guard case .completed = lifecycle.completeDismissal(generation: dismissGeneration) else {
            return XCTFail("The dismissal must still complete")
        }
        XCTAssertEqual(lifecycle.phase, .hidden)
    }
}
