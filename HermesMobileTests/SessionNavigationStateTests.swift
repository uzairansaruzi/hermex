import XCTest
@testable import HermesMobile

final class SessionNavigationStateTests: XCTestCase {
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
            refreshSessionsAndActiveProfile: {
                await recorder.record(.refreshStarted)
            }
        )

        let events = await recorder.snapshot()
        guard let refreshIndex = events.firstIndex(of: .refreshStarted),
              let deepLinkFinishIndex = events.firstIndex(of: .deepLinkFinished)
        else {
            return XCTFail("Expected both refresh and deep-link completion events")
        }

        XCTAssertLessThan(refreshIndex, deepLinkFinishIndex)
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
