import SwiftUI
import XCTest
@testable import HermesMobile

final class SessionNavigationStateTests: XCTestCase {
    func testPushFallbackStaysOnListInsteadOfRestoringPreviousChat() {
        let previous = SessionSummary(sessionId: "old", title: "Old")
        var state = SessionNavigationState(lastSelectedSessionID: "old")
        state.select(previous)
        let oldRevision = state.rootRevision
        state.openSessionList()
        state.restoreIfNeeded(from: [previous])
        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
        XCTAssertGreaterThan(state.rootRevision, oldRevision)
    }

    func testSelectingSessionUpdatesDestinationAndRestorationID() {
        let session = SessionSummary(sessionId: "session-1", title: "One")
        var state = SessionNavigationState()

        state.select(session)

        XCTAssertEqual(state.destination, .session(session))
        XCTAssertEqual(state.selectedSessionID, "session-1")
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testRestoreSelectsStoredSessionWhenItStillExists() {
        let first = SessionSummary(sessionId: "session-1", title: "One")
        let second = SessionSummary(sessionId: "session-2", title: "Two")
        var state = SessionNavigationState(lastSelectedSessionID: "session-2")

        state.restoreIfNeeded(from: [first, second])

        XCTAssertEqual(state.destination, .session(second))
        XCTAssertEqual(state.lastSelectedSessionID, "session-2")
    }

    func testRestoreClearsStoredSelectionWhenSessionNoLongerExists() {
        var state = SessionNavigationState(lastSelectedSessionID: "missing")

        state.restoreIfNeeded(from: [SessionSummary(sessionId: "session-1")])

        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testRestorePreservesStoredSelectionWhenSessionListIsNotAuthoritative() {
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")

        state.restoreIfNeeded(from: [], clearsMissingSelection: false)

        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testRestoreSkipsWhileDeepLinkIsPendingAndKeepsStoredSelection() {
        let stored = SessionSummary(sessionId: "stored")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")

        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: "deep-linked")

        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "stored")
    }

    func testRestoreSkipsAfterPendingDeepLinkIsConsumedWhileLoadIsInFlight() {
        let stored = SessionSummary(sessionId: "stored")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")

        let deepLinkedSessionID = state.beginDeepLinkedSessionLoad(id: "deep-linked")
        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: nil)

        XCTAssertEqual(deepLinkedSessionID, "deep-linked")
        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "stored")

        state.finishDeepLinkedSessionLoad(id: deepLinkedSessionID)
        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: nil)

        XCTAssertEqual(state.destination, .session(stored))
    }

    func testRestoreProceedsWhenPendingDeepLinkIDIsBlank() {
        let stored = SessionSummary(sessionId: "stored")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")

        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: "   ")

        XCTAssertEqual(state.destination, .session(stored))
    }

    func testInitialRefreshStartsBeforeDelayedDeepLinkFinishes() async {
        let recorder = SessionInitialLoadEventRecorder()

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {
                await recorder.record(.deepLinkStarted)
                try? await Task.sleep(nanoseconds: 50_000_000)
                await recorder.record(.deepLinkFinished)
            },
            loadSessions: {
                await recorder.record(.refreshStarted)
            },
            restoreSelection: {},
            loadProjects: {},
            loadActiveProfile: {}
        )

        let events = await recorder.snapshot()
        guard let refreshIndex = events.firstIndex(of: .refreshStarted),
              let deepLinkFinishIndex = events.firstIndex(of: .deepLinkFinished)
        else {
            return XCTFail("Expected both refresh and deep-link completion events")
        }

        XCTAssertLessThan(refreshIndex, deepLinkFinishIndex)
    }

    /// Over a tunnel each held request is a round trip, so restore must not
    /// wait for projects or the profile, and neither of those waits for the other.
    @MainActor
    func testInitialLoadRestoresBeforeProjectsAndProfileAndLoadsThemTogether() async {
        let log = InitialLoadLog()
        let projects = HeldInitialLoad()
        let profile = HeldInitialLoad()
        let restoredWithBothLoadsInFlight = expectation(description: "restore while projects and profile are held")
        restoredWithBothLoadsInFlight.expectedFulfillmentCount = 2

        let initialLoad = Task { @MainActor in
            await SessionListInitialLoad.run(
                resolvePendingDeepLink: { log.events.append("deepLink") },
                loadSessions: { log.events.append("sessions") },
                restoreSelection: { log.events.append("restore") },
                loadProjects: {
                    restoredWithBothLoadsInFlight.fulfill()
                    await projects.wait()
                    log.events.append("projects")
                },
                loadActiveProfile: {
                    restoredWithBothLoadsInFlight.fulfill()
                    await profile.wait()
                    log.events.append("profile")
                }
            )
        }

        await fulfillment(of: [restoredWithBothLoadsInFlight], timeout: 5)
        XCTAssertEqual(Set(log.events), ["deepLink", "sessions", "restore"])
        XCTAssertEqual(log.events.last, "restore")

        profile.release()
        projects.release()
        await initialLoad.value
        XCTAssertEqual(Set(log.events.suffix(2)), ["projects", "profile"])
    }

    func testExplicitNewChatRouteOverridesStoredSelection() {
        let route = PendingNewChatRoute(initialDraft: "Shared draft")
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")
        state.select(route)

        state.restoreIfNeeded(from: [SessionSummary(sessionId: "session-1")])

        XCTAssertEqual(state.destination, .newChat(route))
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testExplicitSessionRouteOverridesStoredSelection() {
        let stored = SessionSummary(sessionId: "stored")
        let deepLinked = SessionSummary(sessionId: "deep-linked")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")
        state.select(deepLinked)

        state.restoreIfNeeded(from: [stored])

        XCTAssertEqual(state.destination, .session(deepLinked))
        XCTAssertEqual(state.lastSelectedSessionID, "deep-linked")
    }

    func testCreatedSessionRemainsSelectedWhileNewChatRouteOwnsItsDraft() {
        let route = PendingNewChatRoute(initialDraft: "Shared draft")
        let created = SessionSummary(sessionId: "created-session")
        var state = SessionNavigationState()
        state.select(route)
        XCTAssertTrue(state.isCreatingNewChat)

        state.remember(created)

        XCTAssertEqual(state.destination, .newChat(route))
        XCTAssertEqual(state.selectedSessionID, "created-session")
        XCTAssertEqual(state.lastSelectedSessionID, "created-session")
        XCTAssertFalse(state.isCreatingNewChat)
    }

    func testSelectingAnotherNewChatRouteStartsFreshCreationState() {
        let firstRoute = PendingNewChatRoute()
        let secondRoute = PendingNewChatRoute()
        var state = SessionNavigationState()
        state.select(firstRoute)
        state.remember(SessionSummary(sessionId: "created-session"))

        state.select(secondRoute)

        XCTAssertEqual(state.destination, .newChat(secondRoute))
        XCTAssertNil(state.selectedSessionID)
        XCTAssertTrue(state.isCreatingNewChat)
    }

    func testReturningFromContentfulNewChatSuppressesPlaceholdersThenRefreshesSessions() {
        let route = PendingNewChatRoute()
        var state = SessionNavigationState()
        state.select(route)
        state.remember(SessionSummary(sessionId: "created-session"))
        let oldDestination = state.destination
        state.clearDestination()
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: oldDestination,
            to: state.destination,
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.suppressedPlaceholders, .refreshedSessions])
    }

    func testReturningFromEmptyNewChatSuppressesPlaceholderThenRefreshesSessions() {
        let route = PendingNewChatRoute()
        var state = SessionNavigationState()
        state.select(route)
        let oldDestination = state.destination
        state.clearDestination()
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: oldDestination,
            to: state.destination,
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.suppressedPlaceholders, .refreshedSessions])
    }

    func testReplacingNewChatRouteDoesNotRefreshSessions() {
        let firstRoute = PendingNewChatRoute()
        let secondRoute = PendingNewChatRoute()
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: .newChat(firstRoute),
            to: .newChat(secondRoute),
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testReturningFromSessionRefreshesSessionsWithoutSuppressingPlaceholders() {
        var state = SessionNavigationState()
        state.select(SessionSummary(sessionId: "session-1"))
        let oldDestination = state.destination
        state.clearDestination()
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: oldDestination,
            to: state.destination,
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.refreshedSessions])
    }

    func testSwitchingBetweenSessionsRefreshesSessions() {
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: .session(SessionSummary(sessionId: "session-1")),
            to: .session(SessionSummary(sessionId: "session-2")),
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.refreshedSessions])
    }

    func testReturningFromUtilityDestinationRefreshesSessions() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.archived)
        let oldDestination = state.destination
        state.clearDestination()
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: oldDestination,
            to: state.destination,
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.refreshedSessions])
    }

    func testOpeningTheFirstDestinationRefreshesNothing() {
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: nil,
            to: .session(SessionSummary(sessionId: "session-1")),
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testUnchangedDestinationRefreshesNothing() {
        let destination = SessionNavigationDestination.session(SessionSummary(sessionId: "session-1"))
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: destination,
            to: destination,
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testActiveRowPollPausesWhileChatCoversCompactList() {
        let chat = SessionNavigationDestination.session(SessionSummary(sessionId: "streaming"))

        XCTAssertTrue(activeRowMonitorID(isRegularWidth: false, destination: nil).shouldPoll)
        XCTAssertFalse(activeRowMonitorID(isRegularWidth: false, destination: chat).shouldPoll)
        XCTAssertFalse(
            activeRowMonitorID(isRegularWidth: false, destination: .utility(.archived)).shouldPoll
        )
        // Scheduled sessions renders live rows, so its badges keep updating.
        XCTAssertTrue(
            activeRowMonitorID(isRegularWidth: false, destination: .utility(.scheduled)).shouldPoll
        )
        // On regular width the sidebar stays on screen beside the chat.
        XCTAssertTrue(activeRowMonitorID(isRegularWidth: true, destination: chat).shouldPoll)
    }

    func testActiveRowPollRestartsWhenReturningToCompactList() {
        let chat = SessionNavigationDestination.session(SessionSummary(sessionId: "streaming"))

        // A different task ID is what makes SwiftUI restart the paused poll.
        XCTAssertNotEqual(
            activeRowMonitorID(isRegularWidth: false, destination: chat),
            activeRowMonitorID(isRegularWidth: false, destination: nil)
        )
        // Selecting another chat on regular width keeps the running poll.
        XCTAssertEqual(
            activeRowMonitorID(isRegularWidth: true, destination: chat),
            activeRowMonitorID(isRegularWidth: true, destination: nil)
        )
    }

    func testActiveRowPollStillSkipsIdleAndCachedLists() {
        XCTAssertFalse(activeRowMonitorID(hasActiveRows: false).shouldPoll)
        XCTAssertFalse(activeRowMonitorID(isViewingCachedData: true).shouldPoll)
        XCTAssertEqual(ActiveSessionMonitorTaskID.pollInterval, .seconds(3))
    }

    @MainActor
    func testReturnToCompactListTicksOnceAfterReloadingRows() async {
        var events: [String] = []
        var streamIDs = ["before-reload"]

        await SessionListReturnRefresh.run(
            refreshSessions: {
                events.append("reload")
                streamIDs = ["after-reload"]
            },
            monitorTaskID: {
                ActiveSessionMonitorTaskID(
                    streamIDs: streamIDs,
                    hasActiveRows: true,
                    isViewingCachedData: false,
                    isRegularWidth: false,
                    destination: nil
                )
            },
            refreshActiveRows: { taskID in
                events.append("tick:\(taskID.streamIDs.joined())")
            }
        )

        // The tick runs right away, on the rows the reload found, rather than
        // leaving stale Approval or Input badges up until the poll's first tick.
        XCTAssertEqual(events, ["reload", "tick:after-reload"])
    }

    @MainActor
    func testReturnSkipsTheTickWhenThePollNeverPaused() async {
        for monitorID in [
            activeRowMonitorID(isRegularWidth: true),
            activeRowMonitorID(hasActiveRows: false),
            activeRowMonitorID(isViewingCachedData: true),
        ] {
            var ticks = 0
            await SessionListReturnRefresh.run(
                refreshSessions: {},
                monitorTaskID: { monitorID },
                refreshActiveRows: { _ in ticks += 1 }
            )
            XCTAssertEqual(ticks, 0)
        }
    }

    private func activeRowMonitorID(
        hasActiveRows: Bool = true,
        isViewingCachedData: Bool = false,
        isRegularWidth: Bool = false,
        destination: SessionNavigationDestination? = nil
    ) -> ActiveSessionMonitorTaskID {
        ActiveSessionMonitorTaskID(
            streamIDs: ["stream-1"],
            hasActiveRows: hasActiveRows,
            isViewingCachedData: isViewingCachedData,
            isRegularWidth: isRegularWidth,
            destination: destination
        )
    }

    func testRemovingSelectedSessionClearsDestinationAndRestorationID() {
        let session = SessionSummary(sessionId: "session-1")
        var state = SessionNavigationState()
        state.select(session)

        state.remove(sessionID: "session-1")

        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testRemovingRememberedSessionPreservesDifferentVisibleDestination() {
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")
        state.select(SessionListUtilityDestination.tasks)

        state.remove(sessionID: "session-1")

        XCTAssertEqual(state.destination, .utility(.tasks))
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testUtilityDestinationRemainsSelectedAcrossLayoutReevaluation() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.settings(nil))

        let reevaluatedState = state

        XCTAssertEqual(reevaluatedState.destination, .utility(.settings(nil)))
        XCTAssertNil(reevaluatedState.selectedSessionID)
    }

    func testKanbanIsSelectableAsAUtilityDestination() {
        var state = SessionNavigationState()

        state.select(SessionListUtilityDestination.kanban)

        XCTAssertEqual(state.destination, .utility(.kanban))
        XCTAssertNil(state.selectedSessionID)
    }

    func testReselectingRootDestinationAdvancesNavigationRevision() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.skills)
        let firstRevision = state.rootRevision

        state.select(SessionListUtilityDestination.skills)

        XCTAssertEqual(state.destination, .utility(.skills))
        XCTAssertGreaterThan(state.rootRevision, firstRevision)
    }

    func testReadableContentWidthsKeepSecondaryAndWorkspaceSurfacesDistinct() {
        XCTAssertEqual(AdaptiveReadableContentWidth.secondaryDestination, 800)
        XCTAssertEqual(AdaptiveReadableContentWidth.workspace, 1_000)
        XCTAssertLessThan(
            AdaptiveReadableContentWidth.secondaryDestination,
            AdaptiveReadableContentWidth.workspace
        )
    }

    func testPersistenceUsesIndependentKeysPerServer() throws {
        let suiteName = "SessionNavigationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstServer = try XCTUnwrap(URL(string: "https://first.example.com"))
        let secondServer = try XCTUnwrap(URL(string: "https://second.example.com"))

        SessionNavigationPersistence.save("first-session", for: firstServer, defaults: defaults)
        SessionNavigationPersistence.save("second-session", for: secondServer, defaults: defaults)

        XCTAssertEqual(
            SessionNavigationPersistence.load(for: firstServer, defaults: defaults),
            "first-session"
        )
        XCTAssertEqual(
            SessionNavigationPersistence.load(for: secondServer, defaults: defaults),
            "second-session"
        )
    }
}

private enum DestinationReturnEvent: Equatable {
    case suppressedPlaceholders
    case refreshedSessions
}

@MainActor
private final class InitialLoadLog {
    var events: [String] = []
}

/// Holds a scripted load open until the test releases it.
@MainActor
private final class HeldInitialLoad {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SessionInitialLoadEventRecorder {
    enum Event: Equatable {
        case deepLinkStarted
        case refreshStarted
        case deepLinkFinished
    }

    private var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }

    func snapshot() -> [Event] {
        events
    }
}

/// Hosts the regular-width shell in a real window. Creation counts show which
/// column a root selection re-identifies; the detail column's navigation stack
/// shows what it pops and keeps; probe views entering and leaving the window mark
/// when the sidebar and pushed screens actually change, so tests wait on those
/// events rather than on a number of main-queue turns.
@MainActor
final class SessionSplitViewIdentityTests: XCTestCase {
    func testRootSelectionRebuildsOnlyTheDetailColumn() throws {
        let log = SplitColumnCreationLog()
        let (host, window) = try hostSplitView(log: log, size: CGSize(width: 1_194, height: 834))
        defer { tearDown(window) }
        XCTAssertEqual(log.sidebar, 1)
        XCTAssertEqual(log.detail, 1)

        host.rootView = splitView(rootRevision: 1, log: log)
        host.view.layoutIfNeeded()

        XCTAssertEqual(log.sidebar, 1, "A root selection must not rebuild the sidebar")
        XCTAssertEqual(log.detail, 2, "A root selection must reset the detail stack")
    }

    /// Pins the visibility policy the split view applies on a root selection. The
    /// portrait close is not hosted: UISplitViewController's display-mode change did
    /// not settle reliably on CI's parallel test clones, and a collapsed sidebar can't
    /// be told apart from `.automatic` in an iPhone-idiom host anyway.
    func testRootSelectionHidesAnOpenedSidebarButKeepsACollapsedOne() {
        XCTAssertEqual(NavigationSplitViewVisibility.all.afterRootSelection, .automatic)
        XCTAssertEqual(NavigationSplitViewVisibility.doubleColumn.afterRootSelection, .automatic)
        XCTAssertEqual(NavigationSplitViewVisibility.automatic.afterRootSelection, .automatic)
        XCTAssertEqual(NavigationSplitViewVisibility.detailOnly.afterRootSelection, .detailOnly)
    }

    /// Settings subpages (`NavigationLink`) and file or fork screens
    /// (`navigationDestination`) push inside the detail column; a root selection
    /// must pop them along with the old root (#116), and the new root can push again.
    func testRootSelectionPopsAScreenPushedInsideTheDetail() throws {
        let log = DetailPushLog()
        let host = UIHostingController(rootView: pushingSplitView(rootRevision: 0, log: log))
        let window = try hostWindow(host, size: CGSize(width: 1_194, height: 834))
        defer { tearDown(window) }
        let detailStack = try waitForPushedScreen(log: log) { try push(from: log, in: host) }
        XCTAssertEqual(detailStack.viewControllers.count, 2)

        let oldScreenLeft = expectation(description: "old root's screen left the window")
        oldScreenLeft.assertForOverFulfill = false
        log.pushedScreenMoved = { isOnScreen in
            if !isOnScreen { oldScreenLeft.fulfill() }
        }
        let newRootAppeared = expectation(description: "new root appeared")
        newRootAppeared.assertForOverFulfill = false
        log.rootDidAppear = { newRootAppeared.fulfill() }
        host.rootView = pushingSplitView(rootRevision: 1, log: log)
        host.view.layoutIfNeeded()
        wait(for: [oldScreenLeft, newRootAppeared], timeout: 2)
        log.pushedScreenMoved = { _ in }
        log.rootDidAppear = {}

        XCTAssertEqual(detailStack.viewControllers.count, 1, "A root selection must pop screens pushed inside the old detail")
        XCTAssertEqual(log.roots, 2, "A root selection must reset the detail stack")
        XCTAssertEqual(log.sidebar, 1, "A root selection must not rebuild the sidebar")

        _ = try waitForPushedScreen(log: log) { try push(from: log, in: host) }
        XCTAssertEqual(detailStack.viewControllers.count, 2, "The new root must still push")
    }

    /// A deep link can select a root that pushes as soon as it appears, even while the
    /// old root's screen still covers it. The selection pops only the old screen.
    func testRootSelectionKeepsAScreenTheNewRootPushes() throws {
        let log = DetailPushLog()
        let host = UIHostingController(rootView: pushingSplitView(rootRevision: 0, log: log))
        let window = try hostWindow(host, size: CGSize(width: 1_194, height: 834))
        defer { tearDown(window) }
        let detailStack = try waitForPushedScreen(log: log) { try push(from: log, in: host) }
        let oldScreen = try XCTUnwrap(detailStack.topViewController)

        _ = try waitForPushedScreen(log: log) {
            host.rootView = pushingSplitView(rootRevision: 1, log: log, pushesOnAppear: true)
            host.view.layoutIfNeeded()
        }
        // Main-queue work the selection deferred ran before this turn.
        let deferredWorkRan = expectation(description: "deferred work ran")
        DispatchQueue.main.async { deferredWorkRan.fulfill() }
        wait(for: [deferredWorkRan], timeout: 1)

        XCTAssertFalse(detailStack.viewControllers.contains(oldScreen), "A root selection must pop the old root's screen")
        XCTAssertEqual(detailStack.viewControllers.count, 2, "A root selection must keep the new root's own push")
    }

    /// Runs `change` and returns the detail column's navigation controller once the
    /// screen it pushes is on screen.
    private func waitForPushedScreen(
        log: DetailPushLog,
        after change: () throws -> Void
    ) throws -> UINavigationController {
        let pushed = expectation(description: "screen pushed")
        pushed.assertForOverFulfill = false
        log.pushedScreenMoved = { isOnScreen in
            if isOnScreen { pushed.fulfill() }
        }
        try change()
        wait(for: [pushed], timeout: 2)
        log.pushedScreenMoved = { _ in }
        return try XCTUnwrap(log.pushedScreen.flatMap(owningNavigationController))
    }

    private func push(from log: DetailPushLog, in host: UIViewController) throws {
        let push = try XCTUnwrap(log.push)
        push()
        host.view.layoutIfNeeded()
    }

    private func owningNavigationController(of view: UIView) -> UINavigationController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller.navigationController }
            responder = next
        }
        return nil
    }

    private func pushingSplitView(
        rootRevision: Int,
        log: DetailPushLog,
        pushesOnAppear: Bool = false
    ) -> PushingSplitView {
        SessionSplitView(rootRevision: rootRevision) {
            SplitColumnProbe { log.sidebar += 1 }
        } detail: {
            PushingDetailProbe(log: log, pushesOnAppear: pushesOnAppear)
        }
    }

    private func hostWindow(_ host: UIViewController, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.traitOverrides.horizontalSizeClass = .regular
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return window
    }

    private func hostSplitView(
        log: SplitColumnCreationLog,
        size: CGSize
    ) throws -> (UIHostingController<ProbeSplitView>, UIWindow) {
        let host = UIHostingController(rootView: splitView(rootRevision: 0, log: log))
        return (host, try hostWindow(host, size: size))
    }

    private func tearDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func splitViewController(in root: UIViewController) -> UISplitViewController? {
        if let split = root as? UISplitViewController { return split }
        return root.children.lazy.compactMap { self.splitViewController(in: $0) }.first
    }

    private func splitView(rootRevision: Int, log: SplitColumnCreationLog) -> ProbeSplitView {
        SessionSplitView(rootRevision: rootRevision) {
            SplitColumnProbe(onCreate: { log.sidebar += 1 })
        } detail: {
            SplitColumnProbe { log.detail += 1 }
        }
    }
}

private typealias ProbeSplitView = SessionSplitView<SplitColumnProbe, SplitColumnProbe>
private typealias PushingSplitView = SessionSplitView<SplitColumnProbe, PushingDetailProbe>

@MainActor
private final class DetailPushLog {
    var sidebar = 0
    var roots = 0
    /// Pushes a screen from the detail root that appeared last.
    var push: (() -> Void)?
    var rootDidAppear: () -> Void = {}
    weak var pushedScreen: UIView?
    var pushedScreenMoved: (Bool) -> Void = { _ in }
}

/// A detail root that pushes a screen the way Settings and the file browser do.
private struct PushingDetailProbe: View {
    let log: DetailPushLog
    let pushesOnAppear: Bool
    @State private var isPushed = false

    var body: some View {
        SplitColumnProbe { log.roots += 1 }
            .onAppear {
                log.push = { isPushed = true }
                if pushesOnAppear { isPushed = true }
                log.rootDidAppear()
            }
            .navigationDestination(isPresented: $isPushed) {
                SplitColumnProbe(
                    onCreate: {},
                    onWindowChange: { log.pushedScreenMoved($0) },
                    onMake: { log.pushedScreen = $0 }
                )
            }
    }
}

@MainActor
private final class SplitColumnCreationLog {
    var sidebar = 0
    var detail = 0
}

/// Reports when SwiftUI creates it and when its view enters or leaves the window.
private struct SplitColumnProbe: UIViewRepresentable {
    let onCreate: @MainActor () -> Void
    var onWindowChange: @MainActor (Bool) -> Void = { _ in }
    var onMake: @MainActor (UIView) -> Void = { _ in }

    func makeUIView(context: Context) -> WindowReportingView {
        onCreate()
        let view = WindowReportingView()
        view.onWindowChange = onWindowChange
        onMake(view)
        return view
    }

    func updateUIView(_ view: WindowReportingView, context: Context) {
        view.onWindowChange = onWindowChange
    }
}

private final class WindowReportingView: UIView {
    var onWindowChange: @MainActor (Bool) -> Void = { _ in }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange(window != nil)
    }
}
