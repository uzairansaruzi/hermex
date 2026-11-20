import ActivityKit
import XCTest
@testable import HermesMobile

@MainActor
final class LiveActivityTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!

    override func tearDown() {
        LiveActivityURLProtocol.handler = nil
        super.tearDown()
    }

    func testSanitizesLiveActivityText() {
        let title = AgentRunActivitySanitizer.sessionTitle("  A very long Hermes session title with\nmultiple lines and extra words  ")
        let activity = AgentRunActivitySanitizer.activityLine("Reading /Users/example/project/Secrets.swift\nwith details")
        let excerpt = AgentRunActivitySanitizer.responseExcerpt(String(repeating: "A", count: 180))

        XCTAssertFalse(title.contains("\n"))
        XCTAssertLessThanOrEqual(title.count, AgentRunActivitySanitizer.maximumSessionTitleCharacters)
        XCTAssertFalse(activity.contains("\n"))
        XCTAssertLessThanOrEqual(activity.count, AgentRunActivitySanitizer.maximumActivityCharacters)
        XCTAssertLessThanOrEqual(excerpt.count, AgentRunActivitySanitizer.maximumExcerptCharacters)
    }

    func testLiveActivityReusePolicyRequiresMatchingSessionAndStream() {
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertTrue(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: " stream-1 ",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-1"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "session-abc",
                existingStreamID: nil,
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
        XCTAssertFalse(
            AgentLiveActivityReusePolicy.canReuseActivity(
                existingSessionID: "other-session",
                existingStreamID: "stream-1",
                requestedSessionID: "session-abc",
                requestedStreamID: "stream-2"
            )
        )
    }

    func testAlertPolicyAlertsOnlyOnEnteringWaitingWhenTheRelayCannot() {
        func alerts(_ previous: AgentRunActivityStatus, _ next: AgentRunActivityStatus,
                    paired: Bool = false, active: Bool = false) -> Bool {
            AgentLiveActivityAlertPolicy.alerts(previous: previous, next: next, canReceivePush: paired, appIsActive: active)
        }

        XCTAssertTrue(alerts(.runningCommand, .waitingForApproval))
        XCTAssertTrue(alerts(.thinking, .waitingForClarification))
        XCTAssertTrue(alerts(.waitingForApproval, .waitingForClarification), "a new kind of ask is a new alert")
        XCTAssertFalse(alerts(.waitingForApproval, .waitingForApproval), "a repeated waiting event stays silent")
        XCTAssertFalse(alerts(.waitingForClarification, .waitingForClarification))
        XCTAssertFalse(alerts(.runningCommand, .waitingForApproval, paired: true), "the relay banners a paired server")
        XCTAssertFalse(alerts(.runningCommand, .waitingForApproval, active: true), "no alert in the foreground")
        XCTAssertFalse(alerts(.waitingForApproval, .runningCommand), "leaving waiting is silent")
        XCTAssertFalse(alerts(.runningCommand, .waiting), "the relay's generic waiting is never a local write")
        XCTAssertFalse(alerts(.responding, .complete))

        let waiting = AgentRunActivityStateReducer.waitingForApproval(
            state: AgentRunActivityStateReducer.initialState(sessionID: "s", sessionTitle: "Build", startedAt: Date())
        )
        let stale = AgentRunActivityStateReducer.stale(state: waiting)
        XCTAssertFalse(alerts(stale.status, AgentRunActivityStateReducer.waitingForApproval(state: stale).status))
    }

    func testPendingAlertSurvivesASameStatusWriteAndDropsWhenTheAskEnds() {
        func pending(_ owed: AgentRunActivityStatus?, _ previous: AgentRunActivityStatus,
                     _ next: AgentRunActivityStatus, paired: Bool = false,
                     active: Bool = false) -> AgentRunActivityStatus? {
            AgentLiveActivityAlertPolicy.pending(owed, previous: previous, next: next,
                                                 canReceivePush: paired, appIsActive: active)
        }

        let owed = pending(nil, .runningCommand, .waitingForApproval)
        XCTAssertEqual(owed, .waitingForApproval)
        XCTAssertEqual(pending(owed, .waitingForApproval, .waitingForApproval), .waitingForApproval,
                       "a chips write keeps the ask owed")
        XCTAssertNil(pending(nil, .waitingForApproval, .waitingForApproval), "a delivered ask never re-alerts")
        XCTAssertEqual(pending(owed, .waitingForApproval, .waitingForClarification), .waitingForClarification)
        XCTAssertNil(pending(owed, .waitingForApproval, .runningCommand), "answering the ask drops it")
        XCTAssertNil(pending(owed, .waitingForApproval, .waitingForApproval, active: true),
                     "opening the app drops it")
    }

    func testWidgetTapRoutesWebuiSessionThroughItsOwningServer() throws {
        let owner = URL(string: "https://other.example:8787")!
        let sessionID = "session & /?=✓"
        let attributes = AgentRunActivityAttributes(
            sessionID: "original-session", sessionTitle: "Run", startedAt: .now, server: owner
        )
        let url = try XCTUnwrap(AgentRunTapTarget.url(attributes: attributes, sessionID: sessionID, activityID: "activity-970"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "activity" })?.value, "activity-970",
            "Widget taps must identify the exact activity to dismiss")
        XCTAssertEqual(url.host, "webui-push")
        XCTAssertNil(HermesDeepLink.sessionID(from: url), "An owned activity must never use the active-server route")
        let destination = try XCTUnwrap(WebuiPushDestination(url: url))
        XCTAssertEqual(destination.server, owner)
        XCTAssertEqual(destination.sessionID, sessionID)
        let account = ServerAccount(id: owner.absoluteString, urlString: owner.absoluteString,
                                    displayName: "", initials: "", headerLogoColorHex: "",
                                    createdAt: .now, updatedAt: .now)
        XCTAssertEqual(destination.route(state: .loggedIn(server: server), servers: [account]), .switchServer(account))
        XCTAssertEqual(destination.route(state: .loggedOut(server: server), servers: [account]), .switchServer(account))
        XCTAssertEqual(destination.route(state: .loggedOut(server: owner), servers: [account]), .waitForSignIn)
        XCTAssertEqual(destination.route(state: .loggedIn(server: owner), servers: [account]), .open)
        XCTAssertEqual(destination.route(state: .loggedIn(server: server), servers: []), .ignore)
    }

    func testWidgetTapKeepsLegacyActivitySessionLink() throws {
        let data = Data(#"{"sessionID":"legacy","sessionTitle":"Run","startedAt":0}"#.utf8)
        let attributes = try JSONDecoder().decode(AgentRunActivityAttributes.self, from: data)
        XCTAssertNil(attributes.server)
        let url = try XCTUnwrap(AgentRunTapTarget.url(attributes: attributes, sessionID: "legacy", activityID: "legacy-activity"))
        XCTAssertEqual(url.absoluteString, "\(HermesDeepLink.scheme)://session?id=legacy&activity=legacy-activity")
        XCTAssertEqual(HermesDeepLink.sessionID(from: url), "legacy")
        XCTAssertNil(WebuiPushDestination(url: url))
    }

    func testWidgetTapKeepsBotDestinationAheadOfWebuiSession() throws {
        let destination = BotDestination(server: server, connectionID: UUID(), profile: "Research & review")
        let botURL = try XCTUnwrap(HermesDeepLink.botURL(for: destination))
        let bot = AgentRunActivityBot(key: "bot-key", destinationURL: botURL)
        let attributes = AgentRunActivityAttributes(
            sessionID: "bot-session", sessionTitle: "Bot", startedAt: .now, bot: bot,
            server: URL(string: "https://other.example")!
        )
        let url = try XCTUnwrap(AgentRunTapTarget.url(attributes: attributes, sessionID: "bot-session", activityID: "bot-activity"))
        XCTAssertEqual(AgentRunTapTarget.activityID(from: url), "bot-activity")
        XCTAssertEqual(HermesDeepLink.botDestination(from: url), destination)
    }

    func testTapDismissalRequiresExactActivityIdentityAndFinishedState() {
        for status: AgentRunActivityStatus in [.complete, .failed, .cancelled] {
            let state = AgentRunActivityStateReducer.final(
                status: status, activity: "Finished",
                state: AgentRunActivityStateReducer.initialState(sessionID: "session", sessionTitle: "Run")
            )
            XCTAssertTrue(AgentLiveActivityTapPolicy.shouldDismiss(
                requestedID: "tapped", activityID: "tapped", isFinal: state.isFinal, activityState: .active
            ), "Finished \(status) should dismiss")
        }
        for status: AgentRunActivityStatus in [.responding, .waiting, .waitingForApproval, .waitingForClarification] {
            var state = AgentRunActivityStateReducer.initialState(sessionID: "session", sessionTitle: "Run")
            state.status = status
            for systemState: ActivityState in [.active, .stale] {
                XCTAssertFalse(AgentLiveActivityTapPolicy.shouldDismiss(
                    requestedID: "tapped", activityID: "tapped", isFinal: state.isFinal, activityState: systemState
                ), "Unfinished \(status) must stay, even when stale")
            }
        }
        XCTAssertTrue(AgentLiveActivityTapPolicy.shouldDismiss(
            requestedID: "tapped", activityID: "tapped", isFinal: false, activityState: .ended
        ), "A relay-ended card can still carry non-final content")
        for requestedID: String? in [nil, "", "unknown"] {
            XCTAssertFalse(AgentLiveActivityTapPolicy.shouldDismiss(
                requestedID: requestedID, activityID: "tapped", isFinal: true, activityState: .ended
            ))
        }
    }

    func testCompactIslandQuietsWorkAndKeepsAsksAndOutcomesThroughStaleness() {
        let expected: [(AgentRunActivityStatus, fresh: AgentRunCompactPresentation, stale: AgentRunCompactPresentation)] = [
            (.starting, .working, .staleWork),
            (.thinking, .working, .staleWork),
            (.usingTool, .working, .staleWork),
            (.searchingFiles, .working, .staleWork),
            (.readingFiles, .working, .staleWork),
            (.runningCommand, .working, .staleWork),
            (.responding, .working, .staleWork),
            (.waiting, .waiting, .waiting),
            (.waitingForApproval, .approval, .approval),
            (.waitingForClarification, .clarification, .clarification),
            (.complete, .complete, .complete),
            (.failed, .failed, .failed),
            (.cancelled, .cancelled, .cancelled),
        ]
        let base = AgentRunActivityStateReducer.initialState(sessionID: "session", sessionTitle: "Run")
        for (status, fresh, stale) in expected {
            var state = base
            state.status = status
            XCTAssertEqual(AgentRunCompactPresentation(state: state), fresh, "\(status)")
            state.isStale = true
            XCTAssertEqual(AgentRunCompactPresentation(state: state), stale, "stale \(status)")
        }
    }

    func testSessionDeepLinkURLPercentEncodesSessionID() throws {
        let sessionID = "session & /?=✓"
        let url = try XCTUnwrap(HermesDeepLink.sessionURL(sessionID: sessionID))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "id", value: sessionID)])
        XCTAssertFalse(url.absoluteString.contains(sessionID))
    }

    func testChatViewModelLiveActivityLifecycleUsesInjectedManager() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Run the tests")
        XCTAssertTrue(didStart)
        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-123")
        ])

        streamClient.emit(.reasoning("I should inspect failures."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: nil,
            name: "shell_command",
            preview: nil,
            args: nil,
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.token("Done."))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: nil,
            name: "shell_command",
            preview: nil,
            args: nil,
            duration: 1.2,
            isError: false
        )))
        streamClient.emit(.done(DoneStreamEvent()))

        XCTAssertEqual(manager.updates, [
            .reasoning("I should inspect failures."),
            .toolStarted(name: "shell_command"),
            .toolCompleted
        ])
        XCTAssertEqual(manager.ends.last, SpyAgentLiveActivityManager.End(
            status: .complete,
            activity: "Response complete",
            errorSummary: nil
        ))
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
    }

    func testChatViewModelRunEndTriggerCoversFailedAndCompletedRunsButNotStoppedOnes() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        LiveActivityURLProtocol.handler = { request in
            if request.url?.path == "/api/session" {
                return Self.jsonResponse(#"{"session":{"session_id":"session-abc","title":"Deploy notes"}}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }
        let viewModel = ChatViewModel(
            session: try Self.sessionSummary(id: "session-abc", title: "Deploy notes"),
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: LiveActivitySpySSEClient(),
            clarifyStreamClient: LiveActivitySpySSEClient(),
            liveActivityManager: SpyAgentLiveActivityManager()
        )

        let failedRunStarted = await viewModel.sendMessage("Use the broken provider")
        XCTAssertTrue(failedRunStarted)
        streamClient.emit(.error("No API key"))
        streamClient.emit(.error("A late duplicate"))
        XCTAssertEqual(viewModel.runEndTrigger, 1)
        XCTAssertEqual(viewModel.runEndOutcome, .failed)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 0, "A failure is not a completion")

        let stoppedRunStarted = await viewModel.sendMessage("Try again")
        XCTAssertTrue(stoppedRunStarted)
        streamClient.emit(.cancelled)
        XCTAssertEqual(viewModel.runEndTrigger, 1, "Whoever stopped the run already knows")

        let completedRunStarted = await viewModel.sendMessage("Once more")
        XCTAssertTrue(completedRunStarted)
        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(viewModel.runEndTrigger, 2)
        XCTAssertEqual(viewModel.runEndOutcome, .completed)
        streamClient.emit(.streamEnd)
        XCTAssertEqual(viewModel.runEndTrigger, 2, "The teardown after done is the same run")

        let secondFailedRunStarted = await viewModel.sendMessage("And again")
        XCTAssertTrue(secondFailedRunStarted)
        streamClient.emit(.error("No API key"))
        XCTAssertEqual(viewModel.runEndOutcome, .failed)

        let bareEndRunStarted = await viewModel.sendMessage("Last one")
        XCTAssertTrue(bareEndRunStarted)
        streamClient.emit(.streamEnd)
        XCTAssertEqual(viewModel.runEndTrigger, 4)
        XCTAssertEqual(viewModel.runEndOutcome, .completed)
    }

    func testChatViewModelSuppressesLiveActivityResponseExcerptsByDefault() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Private live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Keep response text private")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Private token."))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Private interim.", alreadyStreamed: false)))

        XCTAssertTrue(manager.updates.isEmpty)
        XCTAssertTrue(viewModel.messages.contains { $0.content?.contains("Private token.") == true })
    }

    func testDisablingLiveActivityResponseExcerptsClearsActiveExcerpt() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Toggle live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager,
            showsLiveActivityResponseExcerpts: true
        )

        let didStart = await viewModel.sendMessage("Toggle response text")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Visible token."))
        viewModel.setShowsLiveActivityResponseExcerpts(false)

        XCTAssertEqual(manager.updates, [
            .token("Visible token."),
            .clearResponseExcerpt
        ])
    }

    func testFollowupMessageStartsNewLiveActivityAfterCompletedResponse() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")
        var nextStreamNumber = 1

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            let streamID = "stream-\(nextStreamNumber)"
            nextStreamNumber += 1
            return Self.jsonResponse(#"{"stream_id":"\#(streamID)","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStartFirstResponse = await viewModel.sendMessage("Run the first answer")
        XCTAssertTrue(didStartFirstResponse)
        streamClient.emit(.token("First answer."))
        streamClient.emit(.done(DoneStreamEvent()))

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)

        let didStartFollowup = await viewModel.sendMessage("Follow up")
        XCTAssertTrue(didStartFollowup)

        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-1"),
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-2")
        ])
        XCTAssertEqual(viewModel.activeStreamID, "stream-2")
    }

    func testTitleStreamEventUpdatesLiveActivityTitle() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Untitled Session")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Name this run")
        XCTAssertTrue(didStart)

        streamClient.emit(.title(TitleStreamEvent(sessionId: "session-abc", title: "Generated Search Plan")))

        XCTAssertEqual(viewModel.displayTitle, "Generated Search Plan")
        XCTAssertEqual(manager.updates, [
            .sessionTitle("Generated Search Plan")
        ])
    }

    func testDoneSessionTitleUpdatesLiveActivityBeforeCompletion() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Untitled Session")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Finish with a generated title")
        XCTAssertTrue(didStart)

        streamClient.emit(.done(DoneStreamEvent(session: try Self.sessionDetail(id: "session-abc", title: "Generated Finish Plan"))))

        XCTAssertEqual(viewModel.displayTitle, "Generated Finish Plan")
        XCTAssertEqual(manager.updates, [
            .sessionTitle("Generated Finish Plan")
        ])
        XCTAssertEqual(manager.ends.last, SpyAgentLiveActivityManager.End(
            status: .complete,
            activity: "Response complete",
            errorSummary: nil
        ))
    }

    func testStreamEndWithoutDoneStillCompletesLiveActivity() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")

        LiveActivityURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Run the tests")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Done."))
        streamClient.emit(.streamEnd)

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)
    }

    func testStatusRefreshCompletionEndsLiveActivityFromCompletedTranscript() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")
        var requestPaths: [String] = []

        LiveActivityURLProtocol.handler = { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/start":
                return Self.jsonResponse(#"{"stream_id":"stream-123","session_id":"session-abc"}"#, for: request)
            case "/api/chat/stream/status":
                return Self.jsonResponse(#"{"active":false,"stream_id":"stream-123"}"#, for: request)
            case "/api/session":
                return Self.jsonResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Live work",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Completed from transcript refresh.",
                        "timestamp": 1770000110,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: nil,
            name: "shell_command",
            preview: nil,
            args: nil,
            duration: nil,
            isError: nil
        )))

        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Completed from transcript refresh."
        ])
        XCTAssertEqual(requestPaths, ["/api/chat/start", "/api/chat/stream/status", "/api/session"])
    }

    func testForegroundReconnectCompletionEndsLiveActivityAndAllowsFollowupStream() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let approvalStreamClient = LiveActivitySpySSEClient()
        let clarifyStreamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()
        let session = try Self.sessionSummary(id: "session-abc", title: "Live work")
        var nextStreamNumber = 1

        LiveActivityURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                let streamID = "stream-\(nextStreamNumber)"
                nextStreamNumber += 1
                return Self.jsonResponse(#"{"stream_id":"\#(streamID)","session_id":"session-abc"}"#, for: request)
            case "/api/chat/stream/status":
                return Self.jsonResponse(#"{"active":false,"stream_id":"stream-1","replay_available":false}"#, for: request)
            case "/api/session":
                return Self.jsonResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Live work",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Completed after foreground reconnect.",
                        "timestamp": 1770000110,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let viewModel = ChatViewModel(
            session: session,
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            liveActivityManager: manager
        )

        let didStartFirstResponse = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStartFirstResponse)
        streamClient.emit(.reasoning("Thinking about the final answer."))
        viewModel.suspendStreamForBackground()

        await viewModel.reconnectStreamIfNeeded()

        XCTAssertTrue(manager.didMarkStale)
        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(
                status: .complete,
                activity: "Response complete",
                errorSummary: nil
            )
        ])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 2)

        let didStartFollowup = await viewModel.sendMessage("Follow up")
        XCTAssertTrue(didStartFollowup)
        XCTAssertEqual(manager.starts, [
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-1"),
            SpyAgentLiveActivityManager.Start(sessionID: "session-abc", sessionTitle: "Live work", streamID: "stream-2")
        ])
        XCTAssertEqual(viewModel.activeStreamID, "stream-2")
    }

    func testDroppedConnectionWithoutReplayRecordsFailedRunEnd() async throws {
        let baseURL = URL(string: "https://example.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityURLProtocol.self]
        let client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let streamClient = LiveActivitySpySSEClient()
        let manager = SpyAgentLiveActivityManager()

        LiveActivityURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return Self.jsonResponse(#"{"stream_id":"stream-1","session_id":"session-abc"}"#, for: request)
            case "/api/chat/stream/status":
                return Self.jsonResponse(#"{"active":false,"stream_id":"stream-1","replay_available":false}"#, for: request)
            case "/api/session":
                return Self.jsonResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Deploy notes",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let viewModel = ChatViewModel(
            session: try Self.sessionSummary(id: "session-abc", title: "Deploy notes"),
            server: baseURL,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: LiveActivitySpySSEClient(),
            clarifyStreamClient: LiveActivitySpySSEClient(),
            liveActivityManager: manager
        )

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.transportError("The network connection was lost."))
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(manager.ends, [
            SpyAgentLiveActivityManager.End(status: .failed, activity: "Response failed", errorSummary: nil)
        ])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.runEndTrigger, 1)
        XCTAssertEqual(viewModel.runEndOutcome, .failed)
    }

    private static func sessionSummary(id: String, title: String) throws -> SessionSummary {
        let data = Data(#"{"session_id":"\#(id)","title":"\#(title)"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionSummary.self, from: data)
    }

    private static func sessionDetail(id: String, title: String) throws -> SessionDetail {
        let data = Data(#"{"session_id":"\#(id)","title":"\#(title)"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: data)
    }

    private static func jsonResponse(_ json: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static let reconcilerServer = URL(string: "https://a.example.test")!

    private func statusResponse(active: Bool, terminalState: String? = nil) -> ChatStreamStatusResponse {
        ChatStreamStatusResponse(
            active: active,
            streamId: nil,
            replayAvailable: nil,
            journal: terminalState.map { RunJournalStatus(terminal: true, terminalState: $0) }
        )
    }

    @MainActor
    func testReconcilerEndsOnlyStreamsTheServerReportsInactive() async {
        var ended: [String] = []
        let now = Date(timeIntervalSince1970: 10_000)

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "done", sessionID: "s-done", sessionTitle: "Title", updatedAt: now, server: Self.reconcilerServer),
                OrphanedLiveActivity(streamID: "running", sessionID: "s-running", sessionTitle: "Title", updatedAt: now, server: Self.reconcilerServer),
                OrphanedLiveActivity(streamID: "errored", sessionID: "s-errored", sessionTitle: "Title", updatedAt: now, server: Self.reconcilerServer)
            ],
            server: Self.reconcilerServer,
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { streamID in
                switch streamID {
                case "done": self.statusResponse(active: false)
                case "running": self.statusResponse(active: true)
                default: nil
                }
            },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { _, _ in }
        )

        XCTAssertEqual(ended, ["done"])
    }

    @MainActor
    func testReconcilerEndsButDoesNotNotifyStaleCompletion() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(
                    streamID: "stale",
                    sessionID: "s-stale",
                    sessionTitle: "Title",
                    updatedAt: now.addingTimeInterval(-(LiveActivityReconciler.recentCompletionWindow + 1)),
                    server: Self.reconcilerServer
                )
            ],
            server: Self.reconcilerServer,
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { orphan, _ in notified.append(orphan.sessionID) }
        )

        XCTAssertEqual(ended, ["stale"])
        XCTAssertTrue(notified.isEmpty)
    }

    @MainActor
    func testReconcilerDoesNotNotifyWhenAnotherPathAlreadyFinalized() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "dup", sessionID: "s-dup", sessionTitle: "Title", updatedAt: now, server: Self.reconcilerServer)
            ],
            server: Self.reconcilerServer,
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in false },
            notify: { orphan, _ in notified.append(orphan.sessionID) }
        )

        XCTAssertTrue(notified.isEmpty)
    }

    @MainActor
    func testReconcilerForegroundPassEndsOrphansButNeverNotifies() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "recent", sessionID: "s-recent", sessionTitle: "Title", updatedAt: now, server: Self.reconcilerServer)
            ],
            server: Self.reconcilerServer,
            now: now,
            notifiesOnCompletion: false,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { orphan, _ in notified.append(orphan.sessionID) }
        )

        XCTAssertEqual(ended, ["recent"])
        XCTAssertTrue(notified.isEmpty)
    }

    @MainActor
    func testReconcilerDoesNotNotifyFutureDatedCompletion() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "future", sessionID: "s-future", sessionTitle: "Title", updatedAt: now.addingTimeInterval(120), server: Self.reconcilerServer)
            ],
            server: Self.reconcilerServer,
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false) },
            endOrphan: { _, _ in true },
            notify: { orphan, _ in notified.append(orphan.sessionID) }
        )

        XCTAssertTrue(notified.isEmpty)
    }

    @MainActor
    func testReconciledOutcomeMapsTerminalStateToStatus() {
        func status(_ terminalState: String?) -> AgentRunActivityStatus {
            LiveActivityReconciler.reconciledOutcome(forTerminalState: terminalState).status
        }
        XCTAssertEqual(status("completed"), .complete)
        XCTAssertEqual(status("errored"), .failed)
        XCTAssertEqual(status("interrupted-by-crash"), .failed)
        XCTAssertEqual(status("lost-worker-bookkeeping"), .failed)
        XCTAssertEqual(status("interrupted-by-user"), .cancelled)
        XCTAssertEqual(status("running"), .complete)
        XCTAssertEqual(status("unknown"), .complete)
        XCTAssertEqual(status(nil), .complete)
        XCTAssertEqual(status("a-state-we-have-never-seen"), .complete)
    }

    @MainActor
    func testReconcilerNotifiesCompletedAndFailedButNotCancelledRunsOnColdLaunch() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var ended: [String] = []
        var notified: [String: ResponseCompletionOutcome] = [:]

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "failed", sessionID: "s-failed", sessionTitle: "Title", updatedAt: now.addingTimeInterval(-60), server: Self.reconcilerServer),
                OrphanedLiveActivity(streamID: "done", sessionID: "s-done", sessionTitle: "Title", updatedAt: now.addingTimeInterval(-60), server: Self.reconcilerServer),
                OrphanedLiveActivity(streamID: "stopped", sessionID: "s-stopped", sessionTitle: "Title", updatedAt: now.addingTimeInterval(-60), server: Self.reconcilerServer)
            ],
            server: Self.reconcilerServer,
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { streamID in
                switch streamID {
                case "failed": self.statusResponse(active: false, terminalState: "errored")
                case "done": self.statusResponse(active: false, terminalState: "completed")
                default: self.statusResponse(active: false, terminalState: "interrupted-by-user")
                }
            },
            endOrphan: { orphan, _ in ended.append(orphan.streamID); return true },
            notify: { orphan, outcome in notified[orphan.sessionID] = outcome }
        )

        XCTAssertEqual(ended.sorted(), ["done", "failed", "stopped"])
        XCTAssertEqual(notified, ["s-done": .completed, "s-failed": .failed])
    }

    @MainActor
    func testReconcilerNeverNotifiesForAnotherServersOrphan() async {
        let now = Date(timeIntervalSince1970: 10_000)
        var notified: [String] = []

        await LiveActivityReconciler.reconcileOrphanedActivities(
            orphans: [
                OrphanedLiveActivity(streamID: "own", sessionID: "s-own", sessionTitle: "Title", updatedAt: now,
                                     server: Self.reconcilerServer),
                OrphanedLiveActivity(streamID: "other", sessionID: "s-other", sessionTitle: "Title", updatedAt: now,
                                     server: URL(string: "https://b.example.test")!),
                OrphanedLiveActivity(streamID: "legacy", sessionID: "s-legacy", sessionTitle: "Title", updatedAt: now,
                                     server: nil)
            ],
            server: Self.reconcilerServer,
            now: now,
            notifiesOnCompletion: true,
            streamStatus: { _ in self.statusResponse(active: false, terminalState: "completed") },
            endOrphan: { _, _ in true },
            notify: { orphan, _ in notified.append(orphan.sessionID) }
        )

        XCTAssertEqual(notified, ["s-own"])
    }

    @MainActor
    func testActiveConnectedStreamIDTracksLiveConnectionLifecycle() {
        let manager = AgentLiveActivityManager()

        manager.start(sessionID: "session-1", server: server, sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        manager.markStale()
        XCTAssertNil(manager.activeConnectedStreamID)

        manager.start(sessionID: "session-1", server: server, sessionTitle: "Title", streamID: "stream-abc")
        XCTAssertEqual(manager.activeConnectedStreamID, "stream-abc")

        manager.end(status: .complete, activity: "Response complete")
        XCTAssertNil(manager.activeConnectedStreamID)
    }

    @MainActor
    func testReusingAnActivityAdoptsTheEarliestKnownStart() throws {
        let manager = AgentLiveActivityManager()
        let discoveredAt = Date(timeIntervalSince1970: 1_000)
        let serverStart = discoveredAt.addingTimeInterval(-95)

        manager.start(
            sessionID: "session-1",
            server: server,
            sessionTitle: "Title",
            streamID: "stream-abc",
            startedAt: discoveredAt
        )
        XCTAssertEqual(manager.currentStateForTesting()?.startedAt, discoveredAt)

        manager.start(
            sessionID: "session-1",
            server: server,
            sessionTitle: "Title",
            streamID: "stream-abc",
            startedAt: serverStart
        )
        XCTAssertEqual(manager.currentStateForTesting()?.startedAt, serverStart)

        manager.start(
            sessionID: "session-1",
            server: server,
            sessionTitle: "Title",
            streamID: "stream-abc",
            startedAt: discoveredAt.addingTimeInterval(30)
        )
        XCTAssertEqual(manager.currentStateForTesting()?.startedAt, serverStart)
    }

    @MainActor
    func testSameIDsOnAnotherServerStartAFreshActivity() throws {
        let manager = AgentLiveActivityManager()
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let laterStart = firstStart.addingTimeInterval(60)
        manager.start(sessionID: "session-1", server: server, sessionTitle: "Title",
                      streamID: "stream-abc", startedAt: firstStart)
        manager.start(sessionID: "session-1", server: URL(string: "https://other.example")!, sessionTitle: "Title",
                      streamID: "stream-abc", startedAt: laterStart)
        XCTAssertEqual(manager.currentStateForTesting()?.startedAt, laterStart,
                       "Reusing would keep the first server's earlier start")
    }

    @MainActor
    func testRepeatedReasoningJoinsTheThrottleAndStillClearsStale() throws {
        let manager = AgentLiveActivityManager()
        manager.start(sessionID: "session-1", server: server, sessionTitle: "Title", streamID: "stream-abc")

        for _ in 0..<100 { manager.update(.reasoning("step")) }
        XCTAssertEqual(manager.immediateWriteCountForTesting, 1)

        manager.markStale()
        manager.update(.reasoning("step"))
        manager.update(.reasoning("step"))
        let state = try XCTUnwrap(manager.currentStateForTesting())
        XCTAssertEqual(state.status, .thinking)
        XCTAssertFalse(state.isStale)
        XCTAssertEqual(manager.immediateWriteCountForTesting, 3, "stale mark and the one clearing it")
    }

    @MainActor
    func testTokensStopRewritingTheExcerptOnceItsPrefixIsFull() throws {
        let manager = AgentLiveActivityManager()
        manager.start(sessionID: "session-1", server: server, sessionTitle: "Title", streamID: "stream-abc")

        for _ in 0..<1_000 { manager.update(.token("word ")) }
        let full = try XCTUnwrap(manager.currentStateForTesting())
        XCTAssertEqual(full.responseExcerpt,
                       AgentRunActivitySanitizer.responseExcerpt(String(repeating: "word ", count: 1_000)))

        for _ in 0..<1_000 { manager.update(.token("more ")) }
        XCTAssertEqual(manager.currentStateForTesting(), full)

        manager.update(.reasoning("step"))
        manager.update(.token("more "))
        var state = try XCTUnwrap(manager.currentStateForTesting())
        XCTAssertEqual(state.status, .responding)
        XCTAssertEqual(state.currentActivity, String(localized: "Writing response"))
        XCTAssertEqual(state.responseExcerpt, full.responseExcerpt)

        manager.update(.toolCompleted)
        manager.update(.token("more "))
        XCTAssertEqual(manager.currentStateForTesting()?.currentActivity, String(localized: "Writing response"))

        manager.markStale()
        manager.update(.token("more "))
        state = try XCTUnwrap(manager.currentStateForTesting())
        XCTAssertFalse(state.isStale)

        manager.update(.clearResponseExcerpt)
        manager.update(.token("next"))
        XCTAssertEqual(manager.currentStateForTesting()?.responseExcerpt, "next")
    }

    @MainActor
    func testLeadingWhitespaceDoesNotFillTheExcerptBuffer() throws {
        let manager = AgentLiveActivityManager()
        manager.start(sessionID: "session-1", server: server, sessionTitle: "Title", streamID: "stream-abc")

        for _ in 0..<1_000 { manager.update(.token(" \n\t")) }
        manager.update(.token("Hello"))
        let state = try XCTUnwrap(manager.currentStateForTesting())
        XCTAssertEqual(state.status, .responding)
        XCTAssertEqual(state.responseExcerpt, "Hello")
    }

    func testAHermesSessionPushesUnderItsStoredKey() {
        let hermes = AgentRunActivityAttributes(sessionID: "hermes:default:root", sessionTitle: "Run", startedAt: .now,
                                                server: server, pushSessionID: "tip")
        XCTAssertEqual(hermes.pushTarget, AgentRunActivityPushTarget(server: server, sessionID: "tip"))
        let older = AgentRunActivityAttributes(sessionID: "hermes:default:tip", sessionTitle: "Run", startedAt: .now,
                                               server: server)
        XCTAssertNil(older.pushTarget)
        let webui = AgentRunActivityAttributes(sessionID: "webui-session", sessionTitle: "Run", startedAt: .now, server: server)
        XCTAssertEqual(webui.pushTarget, AgentRunActivityPushTarget(server: server, sessionID: "webui-session"))
    }

    func testAHermesActivityFromThePreviousBuildStillDecodes() throws {
        let data = Data(#"{"sessionID":"hermes:default:tip","sessionTitle":"Run","streamID":"1790000000.5","startedAt":0,"server":"https://webui.example"}"#.utf8)
        let older = try JSONDecoder().decode(AgentRunActivityAttributes.self, from: data)
        XCTAssertEqual(older.server, server)
        XCTAssertNil(older.destinationURL)
        XCTAssertNil(older.pushSessionID)

        let link = try XCTUnwrap(HermesDeepLink.sessionURL(for: HermesSessionDestination(server: server, profile: "default", key: "tip")))
        let current = AgentRunActivityAttributes(sessionID: "hermes:default:tip", sessionTitle: "Run", startedAt: .now,
                                                 server: server, destinationURL: link, pushSessionID: "tip-2")
        let copy = try JSONDecoder().decode(AgentRunActivityAttributes.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(copy.destinationURL, link)
        XCTAssertEqual(copy.pushSessionID, "tip-2")
    }

    func testAHermesSessionsPushesFollowItsStoredKey() throws {
        let manager = AgentLiveActivityManager()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        manager.startSession(sessionID: "hermes:default:root", server: server, destinationURL: nil, pushSessionID: "tip",
                             sessionTitle: "Run", turn: "1000.0", startedAt: startedAt)
        XCTAssertEqual(manager.drivenSessionID, "hermes:default:root")
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip")

        manager.movePushSession(to: "tip-2")
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip-2")
        manager.movePushSession(to: " ")
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip-2")

        manager.update(.toolStarted(name: "terminal"))
        manager.startSession(sessionID: "hermes:default:root", server: server, destinationURL: nil, pushSessionID: "tip-3",
                             sessionTitle: "Run", turn: "1000.0", startedAt: startedAt)
        XCTAssertEqual(manager.currentStateForTesting()?.status, .runningCommand, "the same activity, not a new one")
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip-3")
    }

    func testColdLaunchAdoptsAPairedHermesSessionsActivity() throws {
        let attributes = AgentRunActivityAttributes(sessionID: "hermes:default:root", sessionTitle: "Run",
                                                    streamID: "1000.0", startedAt: Date(timeIntervalSince1970: 1_000),
                                                    server: server, pushSessionID: "tip")
        let running = AgentRunActivityStateReducer.initialState(sessionID: "hermes:default:root", sessionTitle: "Run")
        let final = AgentRunActivityStateReducer.final(status: .complete, activity: "Done", state: running)
        let manager = AgentLiveActivityManager()
        XCTAssertFalse(manager.restoreOwnership(attributes: attributes, state: final))
        XCTAssertTrue(manager.restoreOwnership(attributes: attributes, state: running))
        XCTAssertEqual(manager.drivenSessionID, "hermes:default:root")
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip")
    }

    func testTheLiveListRunsEveryListedSessionThatIsNotIdle() {
        let items: [BotJSON] = [("a", "working"), ("b", "waiting"), ("c", "starting"), ("d", "streaming"),
                                ("e", "resuming"), ("f", "idle")].map { key, status in
            .object(["id": .string("runtime-\(key)"), "session_key": .string(key), "status": .string(status)])
        } + [.object(["id": .string("runtime-g"), "session_key": .string("g")]),
             .object(["id": .string("runtime-h"), "status": .string("working")])]
        XCTAssertEqual(LeftoverLiveActivitySettlement.runningKeys(items), ["a", "b", "c", "d", "e", "g"])
    }

    func testColdLaunchChecksUnpairedHermesRunsOnceAgainstTheLiveList() async throws {
        let paired = URL(string: "https://paired.example")!
        let other = URL(string: "https://other.example")!
        func hermes(_ id: String, key: String?, on server: URL, finished: Bool = false) -> LeftoverLiveActivity {
            LeftoverLiveActivity(id: id, attributes: AgentRunActivityAttributes(
                sessionID: "hermes:default:\(key ?? id)", sessionTitle: "Run", startedAt: .now, server: server,
                pushSessionID: key, requestedPush: server == paired ? true : nil), isFinished: finished)
        }
        func bot(_ id: String, on server: URL) throws -> LeftoverLiveActivity {
            var bot = try XCTUnwrap(AgentRunActivityBot(BotDestination(server: server, connectionID: UUID(), profile: "triage")))
            bot.pushSessionID = "bot-tip"
            return LeftoverLiveActivity(id: id, attributes: AgentRunActivityAttributes(
                sessionID: bot.key, sessionTitle: "Triage", startedAt: .now, bot: bot), isFinished: false)
        }
        let leftovers = [
            hermes("paired", key: "k-paired", on: paired),
            hermes("working", key: "k-working", on: server),
            hermes("waiting", key: "k-waiting", on: server),
            hermes("idle", key: "k-idle", on: server),
            hermes("absent", key: "k-absent", on: server),
            hermes("k-older", key: nil, on: server),
            hermes("other", key: "k-working", on: other),
            hermes("finished", key: "k-finished", on: server, finished: true),
            try bot("bot-paired", on: paired),
            try bot("bot-unpaired", on: server),
            LeftoverLiveActivity(id: "webui", attributes: AgentRunActivityAttributes(
                sessionID: "webui-session", sessionTitle: "Run", startedAt: .now, server: server), isFinished: false),
            LeftoverLiveActivity(id: "webui-finished", attributes: AgentRunActivityAttributes(
                sessionID: "webui-session", sessionTitle: "Run", startedAt: .now, server: server), isFinished: true)
        ]
        var reads = 0
        let actions = await LeftoverLiveActivitySettlement.actions(
            for: leftovers, isPaired: { $0 == paired }, hermesServer: server,
            runningKeys: { reads += 1; return ["k-working", "k-waiting", "k-older"] }
        )
        XCTAssertEqual(actions, [.adopt, .keep, .keep, .endComplete, .endComplete, .keep, .keep, .retire,
                                 .adopt, .end, .keep, .retire])
        XCTAssertEqual(reads, 1, "one live-list read for every unpaired Hermes run")
    }

    func testColdLaunchLeavesHermesRunsTheLiveListCannotSettle() async {
        let unpaired = LeftoverLiveActivity(id: "unpaired", attributes: AgentRunActivityAttributes(
            sessionID: "hermes:default:tip", sessionTitle: "Run", startedAt: .now, server: server, pushSessionID: "tip",
            requestedPush: true), isFinished: false)
        var reads = 0
        let failed = await LeftoverLiveActivitySettlement.actions(
            for: [unpaired], isPaired: { _ in false }, hermesServer: server, runningKeys: { reads += 1; return nil })
        XCTAssertEqual(failed, [.keep])
        XCTAssertEqual(reads, 1)

        let cases: [(paired: URL?, hermes: URL?)] = [(server, server), (nil, nil), (nil, URL(string: "https://other.example")!)]
        for (pairedServer, hermesServer) in cases {
            let actions = await LeftoverLiveActivitySettlement.actions(
                for: [unpaired], isPaired: { $0 == pairedServer }, hermesServer: hermesServer,
                runningKeys: { reads += 1; return [] })
            XCTAssertEqual(actions, [pairedServer == nil ? .keep : .adopt])
        }
        XCTAssertEqual(reads, 1, "nothing to check, so nothing read")

        let keyless = LeftoverLiveActivity(id: "keyless", attributes: AgentRunActivityAttributes(
            sessionID: "hermes:default", sessionTitle: "Run", startedAt: .now, server: server), isFinished: false)
        let unknown = await LeftoverLiveActivitySettlement.actions(
            for: [keyless], isPaired: { _ in false }, hermesServer: server, runningKeys: { ["tip"] })
        XCTAssertEqual(unknown, [.keep])
    }

    func testColdLaunchChecksAHermesRunStartedBeforePairingAgainstTheLiveList() async {
        func hermes(_ key: String, requestedPush: Bool?) -> LeftoverLiveActivity {
            LeftoverLiveActivity(id: key, attributes: AgentRunActivityAttributes(
                sessionID: "hermes:default:\(key)", sessionTitle: "Run", startedAt: .now, server: server,
                pushSessionID: key, requestedPush: requestedPush), isFinished: false)
        }
        var reads = 0
        let actions = await LeftoverLiveActivitySettlement.actions(
            for: [hermes("pushed", requestedPush: true), hermes("local-running", requestedPush: nil),
                  hermes("local-done", requestedPush: nil)],
            isPaired: { _ in true }, hermesServer: server,
            runningKeys: { reads += 1; return ["pushed", "local-running"] }
        )
        XCTAssertEqual(actions, [.adopt, .keep, .endComplete])
        XCTAssertEqual(reads, 1)
    }

    func testAMovedKeySurvivesARelaunch() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LiveActivityTests-\(UUID())"))
        let before = AgentLiveActivityManager(pushKeys: LiveActivityPushKeys(defaults: defaults))
        before.startSession(sessionID: "hermes:default:root", server: server, destinationURL: nil, pushSessionID: "tip",
                            sessionTitle: "Run", turn: "1000.0", startedAt: .now)
        before.movePushSession(to: "tip-2")

        let relaunched = AgentLiveActivityManager(pushKeys: LiveActivityPushKeys(defaults: defaults))
        func attributes(on server: URL) -> AgentRunActivityAttributes {
            AgentRunActivityAttributes(sessionID: "hermes:default:root", sessionTitle: "Run", streamID: "1000.0",
                                       startedAt: .now, server: server, pushSessionID: "tip")
        }
        let other = relaunched.leftover(id: "other", attributes: attributes(on: URL(string: "https://other.example")!),
                                        isFinished: false)
        XCTAssertEqual(other.pushSessionID, "tip")

        let leftover = relaunched.leftover(id: "moved", attributes: attributes(on: server), isFinished: false)
        var ended: [LeftoverLiveActivityAction] = []
        await relaunched.settle([leftover], checking: AgentLiveActivityManager.HermesRunCheck(server: server) { ["tip-2"] },
                                isFinished: { _ in false }, adopt: { _ in false }, end: { ended.append($1) })
        XCTAssertEqual(ended, [], "the host still runs the moved key")

        let running = AgentRunActivityStateReducer.initialState(sessionID: "hermes:default:root", sessionTitle: "Run")
        XCTAssertTrue(relaunched.restoreOwnership(attributes: attributes(on: server), state: running))
        XCTAssertEqual(relaunched.drivenPushSessionIDForTesting, "tip-2")
    }
}

@MainActor
private final class SpyAgentLiveActivityManager: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let sessionTitle: String
        let streamID: String?
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var starts: [Start] = []
    private(set) var updates: [AgentLiveActivityEvent] = []
    private(set) var didMarkStale = false
    private(set) var ends: [End] = []

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {
        starts.append(Start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID))
    }

    func update(_ event: AgentLiveActivityEvent) {
        updates.append(event)
    }

    func markStale() {
        didMarkStale = true
    }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}

private final class LiveActivitySpySSEClient: SSEStreamingClient {
    private var onEvent: (@MainActor (SSEEvent) -> Void)?
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
    }

    @MainActor
    func emit(_ event: SSEEvent) {
        onEvent?(event)
    }
}

private final class LiveActivityURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
