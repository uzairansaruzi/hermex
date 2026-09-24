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
/// column a root selection re-identifies; the hosted `UISplitViewController`'s
/// display mode shows what the selection does to the sidebar's visibility.
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

    func testRootSelectionClosesASidebarOpenedOverThePortraitDetail() throws {
        let log = SplitColumnCreationLog()
        let (host, window) = try hostSplitView(log: log, size: CGSize(width: 834, height: 1_194))
        defer { tearDown(window) }
        let split = try XCTUnwrap(splitViewController(in: host))
        XCTAssertEqual(split.displayMode, .secondaryOnly)
        split.show(.primary)
        host.view.layoutIfNeeded()
        XCTAssertNotEqual(split.displayMode, .secondaryOnly)

        host.rootView = splitView(rootRevision: 1, log: log)
        host.view.layoutIfNeeded()
        // The split view applies the new visibility on the next main-queue turn.
        let applied = expectation(description: "visibility applied")
        DispatchQueue.main.async { applied.fulfill() }
        wait(for: [applied], timeout: 1)

        XCTAssertEqual(split.displayMode, .secondaryOnly, "Picking a root must close a sidebar the user opened")
        XCTAssertEqual(log.sidebar, 1)
    }

    /// The hosted test above covers the portrait wiring. A collapsed sidebar can't be
    /// told apart from `.automatic` in an iPhone-idiom host, so the policy pins it.
    func testRootSelectionHidesAnOpenedSidebarButKeepsACollapsedOne() {
        XCTAssertEqual(NavigationSplitViewVisibility.all.afterRootSelection, .automatic)
        XCTAssertEqual(NavigationSplitViewVisibility.doubleColumn.afterRootSelection, .automatic)
        XCTAssertEqual(NavigationSplitViewVisibility.automatic.afterRootSelection, .automatic)
        XCTAssertEqual(NavigationSplitViewVisibility.detailOnly.afterRootSelection, .detailOnly)
    }

    private func hostSplitView(
        log: SplitColumnCreationLog,
        size: CGSize
    ) throws -> (UIHostingController<ProbeSplitView>, UIWindow) {
        let host = UIHostingController(rootView: splitView(rootRevision: 0, log: log))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.traitOverrides.horizontalSizeClass = .regular
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (host, window)
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
            SplitColumnProbe { log.sidebar += 1 }
        } detail: {
            SplitColumnProbe { log.detail += 1 }
        }
    }
}

private typealias ProbeSplitView = SessionSplitView<SplitColumnProbe, SplitColumnProbe>

@MainActor
private final class SplitColumnCreationLog {
    var sidebar = 0
    var detail = 0
}

private struct SplitColumnProbe: UIViewRepresentable {
    let onCreate: @MainActor () -> Void

    func makeUIView(context: Context) -> UIView {
        onCreate()
        return UIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
