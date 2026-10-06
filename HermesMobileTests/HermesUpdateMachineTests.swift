import XCTest
@testable import HermesMobile

/// An update of a Hermes host from Settings (#1075), as scripted sequences of what the host
/// answers, in the shapes `scripts/local-hermes` answered at the pin (0.21.5, ca678285).
final class HermesUpdateMachineTests: XCTestCase {
    /// The receipt an earlier update left on the host.
    private let earlier = HermesUpdateReceipt(outcome: .success, startedAt: "2026-10-01T09:00:00+00:00", postVersion: "0.21.5")
    private let pid = 4242

    private func receipt(_ outcome: HermesUpdateReceipt.Outcome, version: String? = "0.22.0") -> HermesUpdateReceipt {
        HermesUpdateReceipt(outcome: outcome, startedAt: "2026-10-06T18:00:00+00:00", postVersion: version)
    }

    private func running(lines: [String] = []) -> HermesUpdateMachine.Event {
        .status(HermesUpdateStatus(running: true, pid: pid, lines: lines, receipt: earlier))
    }

    /// After the dashboard restarted: it no longer tracks the process, and reports an exit
    /// code from the log marker or a receipt, which can be an earlier run's.
    private func respawned(_ receipt: HermesUpdateReceipt?, exitCode: Int? = 0, lines: [String] = []) -> HermesUpdateMachine.Event {
        .status(HermesUpdateStatus(running: false, exitCode: exitCode, pid: nil, lines: lines, receipt: receipt))
    }

    /// Feeds `steps` to a run that started at zero, and records the state after each.
    private func play(_ steps: [(seconds: Int, event: HermesUpdateMachine.Event)],
                      into machine: inout HermesUpdateMachine) -> [HermesUpdateMachine.State] {
        steps.map { step in
            machine.handle(step.event, at: .seconds(step.seconds))
            return machine.state
        }
    }

    private func newRun() -> HermesUpdateMachine { HermesUpdateMachine(baseline: earlier, pid: pid, at: .zero) }

    func testACleanRunUpdatesRestartsAndEndsOnTheInstalledRelease() {
        var machine = newRun()
        XCTAssertEqual(machine.nextRead, .status)

        let states = play([
            (3, running()), (6, .unreachable), (9, .unreachable),
            (12, respawned(receipt(.success))), (15, .health(version: "0.22.0"))
        ], into: &machine)

        XCTAssertEqual(states, [.applying, .recovering, .recovering, .applying, .done(version: "0.22.0")])
        XCTAssertNil(machine.nextRead, "Done reads nothing more")
    }

    func testAReceiptThatSaysSuccessIsDoneOnlyOnceHealthAnswersOnItsRelease() {
        var machine = newRun()

        let states = play([
            (3, respawned(receipt(.success))), (6, .unreachable), (9, .health(version: "0.21.5")),
            (12, .health(version: "0.22.0"))
        ], into: &machine)

        XCTAssertEqual(states, [.applying, .recovering, .applying, .done(version: "0.22.0")],
                       "The old release answering is not done")
    }

    func testAProxysErrorsMidRunAreTheRestartNotAFailure() {
        var machine = newRun()

        // A dropped connection, then Cloudflare's 530 and a proxy's 502, all read as no answer.
        let states = play([(3, running()), (6, .unreachable), (60, .unreachable), (110, .unreachable), (113, running())],
                          into: &machine)

        XCTAssertEqual(states, [.applying, .recovering, .recovering, .recovering, .applying])
        XCTAssertEqual(machine.nextRead, .status)
    }

    func testAMissingStatusAfterTheRestartReadsTheReceipt() {
        var machine = newRun()

        let states = play([
            (3, running()), (6, .unreachable), (9, .statusMissing), (12, .receipt(nil)), (15, .receipt(earlier)),
            (18, .receipt(receipt(.success)))
        ], into: &machine)

        XCTAssertEqual(states, [.applying, .recovering, .applying, .applying, .applying, .applying])
        XCTAssertEqual(machine.nextRead, .health)
        machine.handle(.health(version: "0.22.0"), at: .seconds(21))
        XCTAssertEqual(machine.state, .done(version: "0.22.0"))
    }

    func testANullExitCodeOrAnEarlierRunsReceiptKeepsWaitingForThisRunsReceipt() {
        var machine = newRun()

        let states = play([
            (3, respawned(nil, exitCode: nil)),
            // Exit 0 inferred from the earlier run's receipt after the restart: not this run's.
            (6, respawned(earlier, exitCode: 0)),
            (9, respawned(receipt(.success)))
        ], into: &machine)

        XCTAssertEqual(states, [.applying, .applying, .applying])
        XCTAssertEqual(machine.nextRead, .health, "Only this run's receipt ends the wait")
    }

    func testAPartialOrFailedReceiptEndsOnTheHostsOwnWords() {
        let partialLines = ["→ Pulled 12 commits", "⚠ Update partially complete — Node.js dependencies for web did not refresh.",
                            "  Code and Python deps are updated, but the dashboard/TUI may", "=== hermes-update completed 0f ==="]
        var partial = newRun()
        partial.handle(respawned(receipt(.partial), exitCode: 1, lines: partialLines), at: .seconds(3))
        XCTAssertEqual(partial.state, .partial(summary: "Update partially complete — Node.js dependencies for web did not refresh."))

        let failedLines = ["→ Fetching updates…", "✗ Merge conflict between local commits and upstream — update stopped, nothing was changed."]
        var failed = newRun()
        failed.handle(.status(HermesUpdateStatus(running: false, exitCode: 1, pid: pid, lines: failedLines, receipt: receipt(.failed))),
                      at: .seconds(3))
        XCTAssertEqual(failed.state, .failed(summary: "Merge conflict between local commits and upstream — update stopped, nothing was changed."))

        var refused = newRun()
        refused.handle(respawned(receipt(.refused), exitCode: nil, lines: ["Hermes is managed by Termux APT."]), at: .seconds(3))
        XCTAssertEqual(refused.state, .failed(summary: "Hermes is managed by Termux APT."), "A run the update refused is a failure")

        var unexplained = newRun()
        unexplained.handle(.receipt(receipt(.failed)), at: .seconds(3))
        XCTAssertEqual(unexplained.state, .failed(summary: nil))
    }

    func testAnExitCodeCountsOnlyWhileTheDashboardStillTracksTheProcess() {
        var failed = newRun()
        failed.handle(.status(HermesUpdateStatus(running: false, exitCode: 75, pid: pid, lines: ["Another hermes update is running (pid 9)."],
                                                 receipt: earlier)), at: .seconds(3))
        XCTAssertEqual(failed.state, .failed(summary: "Another hermes update is running (pid 9)."))

        var nothingToDo = newRun()
        nothingToDo.handle(.status(HermesUpdateStatus(running: false, exitCode: 0, pid: pid, receipt: earlier)), at: .seconds(3))
        XCTAssertEqual(nothingToDo.nextRead, .health, "Exit 0 without a receipt waits on any release")
        nothingToDo.handle(.health(version: "0.21.5"), at: .seconds(6))
        XCTAssertEqual(nothingToDo.state, .done(version: "0.21.5"))
    }

    func testADashboardSilentForTwoMinutesNeedsARestartOnTheHost() {
        var machine = newRun()

        let states = play([(3, running()), (6, .unreachable), (60, .unreachable), (110, .unreachable), (122, .unreachable),
                           (123, .unreachable)], into: &machine)

        XCTAssertEqual(states, [.applying, .recovering, .recovering, .recovering, .recovering, .needsDashboardRestart(running: nil)],
                       "Two minutes from the last answer")
        XCTAssertNil(machine.nextRead)
    }

    func testADashboardBackOnAnotherReleaseForTwoMinutesNeedsARestartOnTheHost() {
        var machine = newRun()

        let states = play([
            (3, respawned(receipt(.success))), (6, .health(version: "0.21.5")), (60, .health(version: "0.21.5")),
            (110, .health(version: "0.21.5")), (122, .health(version: "0.21.5")), (123, .health(version: "0.21.5"))
        ], into: &machine)

        XCTAssertEqual(states, [.applying, .applying, .applying, .applying, .applying, .needsDashboardRestart(running: "0.21.5")])
    }

    func testTimeTheAppWasntWatchingCountsAsOneRead() {
        // Locked for 12 minutes while the update finished: the first read decides.
        var locked = newRun()
        let states = play([(3, running()), (723, respawned(receipt(.success))), (726, .health(version: "0.22.0"))], into: &locked)
        XCTAssertEqual(states, [.applying, .applying, .done(version: "0.22.0")], "Not still running at the ceiling")

        // A read in flight when the app was suspended fails on resume: one read, not 2 minutes' silence.
        var suspended = newRun()
        let silent = play([(3, running()), (303, .unreachable), (306, running())], into: &suspended)
        XCTAssertEqual(silent, [.applying, .recovering, .applying])

        // The same holds for a dashboard on the old release, waited on across a gap.
        var away = newRun()
        let back = play([(3, respawned(receipt(.success))), (6, .health(version: "0.21.5")), (400, .health(version: "0.21.5"))],
                        into: &away)
        XCTAssertEqual(back, [.applying, .applying, .applying])
    }

    func testCheckAgainOnASilentDashboardReadsOnceAndAnAnswerWatchesAgain() {
        var machine = newRun()
        _ = play([(3, running()), (6, .unreachable), (60, .unreachable), (110, .unreachable), (125, .unreachable)], into: &machine)
        XCTAssertEqual(machine.state, .needsDashboardRestart(running: nil))

        machine.checkAgain()
        XCTAssertEqual(machine.nextRead, .status)
        machine.handle(.unreachable, at: .seconds(203))
        XCTAssertEqual(machine.state, .needsDashboardRestart(running: nil), "Still silent: the card stands")
        XCTAssertNil(machine.nextRead)

        machine.checkAgain()
        let states = play([(400, respawned(receipt(.success))), (403, .health(version: "0.22.0"))], into: &machine)
        XCTAssertEqual(states, [.applying, .done(version: "0.22.0")], "Restarted on the host, then checked again")
    }

    func testTheCeilingStopsOnWhatTheHostLastSaid() {
        var answering = newRun()
        let states = play(stride(from: 30, through: 600, by: 30).map { (seconds: $0, event: running()) }, into: &answering)
        XCTAssertEqual(states.last, .stillRunning)
        XCTAssertEqual(Array(states.dropLast()), Array(repeating: .applying, count: 19))

        answering.checkAgain()
        answering.handle(running(), at: .seconds(603))
        XCTAssertEqual(answering.state, .applying, "Check again watches a running update again")

        var silent = newRun()
        silent.handle(.unreachable, at: .seconds(3))
        silent.expire()
        XCTAssertEqual(silent.state, .needsDashboardRestart(running: nil))
    }

    func testARunThatFinishesAtTheCeilingStillWaitsForItsRelease() {
        var machine = newRun()
        _ = play(stride(from: 30, through: 570, by: 30).map { (seconds: $0, event: running()) }, into: &machine)

        machine.handle(respawned(receipt(.success)), at: .seconds(600))
        XCTAssertEqual(machine.state, .applying)
        XCTAssertEqual(machine.nextRead, .health)
        machine.handle(.health(version: "0.22.0"), at: .seconds(603))
        XCTAssertEqual(machine.state, .done(version: "0.22.0"))
    }
}
