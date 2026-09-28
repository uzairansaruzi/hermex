import XCTest
@testable import HermesMobile

/// The session row's attention state: the pure precedence rule, and the bound
/// on how often the list asks the server about it.
final class SessionRowAttentionStateTests: XCTestCase {
    private let unreadSuite = "SessionRowAttentionStateTests." + UUID().uuidString
    private lazy var unreadDefaults = UserDefaults(suiteName: unreadSuite)!

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        unreadDefaults.removePersistentDomain(forName: unreadSuite)
        super.tearDown()
    }

    // MARK: - Resolver

    func testApprovalBeatsInputAndWorking() {
        let streaming = SessionSummary(sessionId: "s", activeStreamId: "stream-1")

        XCTAssertEqual(
            SessionRowAttentionState.resolve(
                session: streaming,
                hasPendingApproval: true,
                hasPendingClarification: true
            ),
            .approval
        )
    }

    func testInputBeatsWorking() {
        let streaming = SessionSummary(sessionId: "s", isStreaming: true)

        XCTAssertEqual(
            SessionRowAttentionState.resolve(
                session: streaming,
                hasPendingApproval: false,
                hasPendingClarification: true
            ),
            .input
        )
    }

    func testActiveStreamWithNothingPendingResolvesToWorking() {
        let streaming = SessionSummary(sessionId: "s", isStreaming: true)

        XCTAssertEqual(
            SessionRowAttentionState.resolve(
                session: streaming,
                hasPendingApproval: false,
                hasPendingClarification: false
            ),
            .working
        )
    }

    func testIdleSessionWithNothingPendingResolvesToReady() {
        XCTAssertNil(
            SessionRowAttentionState.resolve(
                session: SessionSummary(sessionId: "s"),
                hasPendingApproval: false,
                hasPendingClarification: false
            )
        )
    }

    /// The resolver is pure: the "only ask about streaming rows" bound lives in
    /// the view model, not here.
    func testPendingApprovalOnIdleSessionStillResolvesToApproval() {
        XCTAssertEqual(
            SessionRowAttentionState.resolve(
                session: SessionSummary(sessionId: "s"),
                hasPendingApproval: true,
                hasPendingClarification: false
            ),
            .approval
        )
    }

    // MARK: - Row presentation

    /// VoiceOver reads the state once, in place of the old "Streaming" label.
    func testAccessibilityStateLabelsReadTheAttentionState() {
        let session = SessionSummary(sessionId: "s", pinned: true, activeStreamId: "stream-1")

        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(
                for: session,
                isViewingCachedData: false,
                attentionState: .approval
            ),
            ["Waiting for approval", "Pinned"]
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(
                for: session,
                isViewingCachedData: false,
                attentionState: .input
            ),
            ["Needs input", "Pinned"]
        )
    }

    /// A screen that does not poll (Archived) passes no state, and a streaming
    /// row still reads and shows Working.
    func testRowWithoutSuppliedStateFallsBackToTheSessionsOwnStream() {
        let streaming = SessionSummary(sessionId: "s", activeStreamId: "stream-1")

        XCTAssertEqual(
            SessionRowView.effectiveAttentionState(
                for: streaming,
                attentionState: nil,
                isViewingCachedData: false
            ),
            .working
        )
        XCTAssertNil(
            SessionRowView.effectiveAttentionState(
                for: SessionSummary(sessionId: "s"),
                attentionState: nil,
                isViewingCachedData: false
            )
        )
    }

    /// A cached summary keeps the stream fields it was captured with, so an
    /// offline row must not say the agent is working.
    func testCachedRowDoesNotFallBackToWorking() {
        let streaming = SessionSummary(sessionId: "s", activeStreamId: "stream-1")

        XCTAssertNil(
            SessionRowView.effectiveAttentionState(
                for: streaming,
                attentionState: nil,
                isViewingCachedData: true
            )
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: streaming, isViewingCachedData: true),
            ["Cached"]
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(for: streaming, isViewingCachedData: false),
            ["Working"]
        )
    }

    func testCachedRowCanReadUnreadWithoutHidingTheCachedState() {
        let session = SessionSummary(sessionId: "s", lastMessageAt: 200)

        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(
                for: session, isViewingCachedData: true, isUnread: true
            ),
            ["Unread", "Cached"]
        )
        XCTAssertEqual(
            SessionRowView.accessibilityStateLabels(
                for: session, isViewingCachedData: false,
                attentionState: .approval, isUnread: true
            ),
            ["Waiting for approval"]
        )
    }

    @MainActor
    func testUnreadSeedsExistingRowsAndOnlyShowsSettledNewerReplies() async throws {
        let responses = LockedQueue([
            #"{"sessions":[{"session_id":"done","title":"Done","last_message_at":100},{"session_id":"working","title":"Working","last_message_at":100,"is_streaming":true},{"session_id":"pending","title":"Pending","last_message_at":100,"has_pending_user_message":true}]}"#,
            #"{"sessions":[{"session_id":"done","title":"Done","last_message_at":200},{"session_id":"working","title":"Working","last_message_at":200,"is_streaming":true},{"session_id":"pending","title":"Pending","last_message_at":200,"has_pending_user_message":true},{"session_id":"new","title":"New","last_message_at":200}]}"#,
            #"{"sessions":[{"session_id":"done","title":"Done","last_message_at":200},{"session_id":"working","title":"Working","last_message_at":300,"is_streaming":false},{"session_id":"pending","title":"Pending","last_message_at":300,"has_pending_user_message":false},{"session_id":"new","title":"New","last_message_at":200}]}"#
        ])
        let viewModel = try makeViewModel { request in
            apiTestJSONResponse(responses.next(), for: request)
        }

        await viewModel.load()
        XCTAssertTrue(viewModel.sessions.allSatisfy { !viewModel.isUnread($0) })

        await viewModel.load()
        XCTAssertTrue(viewModel.isUnread(try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "done" })))
        XCTAssertFalse(viewModel.isUnread(try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "working" })))
        XCTAssertFalse(viewModel.isUnread(try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "pending" })))
        XCTAssertFalse(viewModel.isUnread(try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "new" })))

        await viewModel.load()
        XCTAssertTrue(viewModel.isUnread(try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "working" })))
        XCTAssertTrue(viewModel.isUnread(try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "pending" })))
    }

    @MainActor
    func testOpeningAndReturningMarksOnlyTheViewedReply() async throws {
        let responses = LockedQueue([100, 200, 300, 400, 500].map {
            "{\"sessions\":[{\"session_id\":\"chat\",\"title\":\"Chat\",\"last_message_at\":\($0)}]}"
        })
        let viewModel = try makeViewModel { request in
            apiTestJSONResponse(responses.next(), for: request)
        }

        await viewModel.load()
        await viewModel.load()
        viewModel.beginViewing(viewModel.sessions[0])
        XCTAssertFalse(viewModel.isUnread(viewModel.sessions[0]))

        await viewModel.load()
        XCTAssertFalse(viewModel.isUnread(viewModel.sessions[0]), "a reply while chat is open is seen")

        viewModel.noteReturn(from: viewModel.sessions[0])
        await viewModel.load()
        XCTAssertFalse(viewModel.isUnread(viewModel.sessions[0]), "the first list load after return is seen")

        await viewModel.load()
        XCTAssertTrue(viewModel.isUnread(viewModel.sessions[0]), "later replies are unread again")
    }

    @MainActor
    func testFailedReturnRefreshDoesNotMarkALaterReplyRead() async throws {
        let responses = LockedQueue([
            #"{"sessions":[{"session_id":"chat","title":"Chat","last_message_at":100}]}"#,
            #"{"sessions":[{"session_id":"chat","title":"Chat","last_message_at":200}]}"#,
            #"{"error":"offline"}"#,
            #"{"sessions":[{"session_id":"chat","title":"Chat","last_message_at":300}]}"#
        ])
        let viewModel = try makeViewModel { request in
            let body = responses.next()
            return apiTestJSONResponse(body, for: request, status: body.contains("offline") ? 500 : 200)
        }

        await viewModel.load()
        viewModel.beginViewing(viewModel.sessions[0])
        await viewModel.load()
        viewModel.noteReturn(from: viewModel.sessions[0])

        let didLoad = await viewModel.load()
        XCTAssertFalse(didLoad)
        await viewModel.load()

        XCTAssertTrue(viewModel.isUnread(viewModel.sessions[0]))
    }

    @MainActor
    func testOverlappingReturnRefreshesKeepTheViewedReplyRead() async throws {
        let calls = LockedCounter()
        let firstStarted = expectation(description: "first return refresh started")
        let secondStarted = expectation(description: "overlapping refresh started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            let timestamp: Int
            switch calls.increment() {
            case 1:
                timestamp = 100
            case 2:
                firstStarted.fulfill()
                releaseFirst.wait()
                timestamp = 200
            case 3:
                secondStarted.fulfill()
                releaseSecond.wait()
                timestamp = 300
            default:
                timestamp = 400
            }
            return apiTestJSONResponse(
                "{\"sessions\":[{\"session_id\":\"chat\",\"title\":\"Chat\",\"last_message_at\":\(timestamp)}]}",
                for: request
            )
        }

        await viewModel.load()
        viewModel.beginViewing(viewModel.sessions[0])
        viewModel.noteReturn(from: viewModel.sessions[0])

        let first = Task { await viewModel.load() }
        await fulfillment(of: [firstStarted], timeout: 5)
        let second = Task { await viewModel.load() }
        await fulfillment(of: [secondStarted], timeout: 5)

        releaseFirst.signal()
        let firstLoaded = await first.value
        XCTAssertTrue(firstLoaded)
        releaseSecond.signal()
        let secondLoaded = await second.value
        XCTAssertTrue(secondLoaded)
        XCTAssertFalse(viewModel.isUnread(viewModel.sessions[0]))

        await viewModel.load()
        XCTAssertTrue(viewModel.isUnread(viewModel.sessions[0]), "a later refresh is outside the return window")
    }

    @MainActor
    func testReturningFromAnotherSessionDoesNotInheritAnEarlierReturnMark() async throws {
        let calls = LockedCounter()
        let firstStarted = expectation(description: "first session return refresh started")
        let secondStarted = expectation(description: "second session return refresh started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            let aTime: Int
            let bTime: Int
            switch calls.increment() {
            case 1:
                (aTime, bTime) = (100, 100)
            case 2:
                firstStarted.fulfill()
                releaseFirst.wait()
                (aTime, bTime) = (200, 100)
            default:
                secondStarted.fulfill()
                releaseSecond.wait()
                (aTime, bTime) = (300, 200)
            }
            return apiTestJSONResponse(
                "{\"sessions\":[{\"session_id\":\"a\",\"title\":\"A\",\"last_message_at\":\(aTime)},{\"session_id\":\"b\",\"title\":\"B\",\"last_message_at\":\(bTime)}]}",
                for: request
            )
        }

        await viewModel.load()
        let a = try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "a" })
        let b = try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "b" })
        viewModel.beginViewing(a)
        viewModel.noteReturn(from: a)
        let first = Task { await viewModel.load() }
        await fulfillment(of: [firstStarted], timeout: 5)

        viewModel.beginViewing(b)
        viewModel.noteReturn(from: b)
        let second = Task { await viewModel.load() }
        await fulfillment(of: [secondStarted], timeout: 5)

        releaseSecond.signal()
        let secondLoaded = await second.value
        XCTAssertTrue(secondLoaded)
        let currentA = try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "a" })
        let currentB = try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "b" })
        XCTAssertTrue(viewModel.isUnread(currentA), "A's later reply was not seen while viewing B")
        XCTAssertFalse(viewModel.isUnread(currentB), "B's reply belongs to the second return")

        releaseFirst.signal()
        let firstLoaded = await first.value
        XCTAssertFalse(firstLoaded)
        XCTAssertTrue(viewModel.isUnread(currentA))
    }

    @MainActor
    func testLoadStartedBeforeReturnCannotReplaceTheReturnSnapshot() async throws {
        let calls = LockedCounter()
        let priorStarted = expectation(description: "prior refresh started")
        let returnStarted = expectation(description: "return refresh started")
        let releasePrior = DispatchSemaphore(value: 0)
        let releaseReturn = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            let timestamp: Int
            switch calls.increment() {
            case 1:
                timestamp = 100
            case 2:
                priorStarted.fulfill()
                releasePrior.wait()
                timestamp = 200
            default:
                returnStarted.fulfill()
                releaseReturn.wait()
                timestamp = 300
            }
            return apiTestJSONResponse(
                "{\"sessions\":[{\"session_id\":\"chat\",\"title\":\"Chat\",\"last_message_at\":\(timestamp)}]}",
                for: request
            )
        }

        await viewModel.load()
        viewModel.beginViewing(viewModel.sessions[0])
        let prior = Task { await viewModel.load() }
        await fulfillment(of: [priorStarted], timeout: 5)
        viewModel.noteReturn(from: viewModel.sessions[0])
        let returned = Task { await viewModel.load() }
        await fulfillment(of: [returnStarted], timeout: 5)

        releaseReturn.signal()
        let returnLoaded = await returned.value
        XCTAssertTrue(returnLoaded)
        releasePrior.signal()
        let priorLoaded = await prior.value
        XCTAssertFalse(priorLoaded)
        XCTAssertEqual(viewModel.sessions[0].lastMessageAt, 300)
        XCTAssertFalse(viewModel.isUnread(viewModel.sessions[0]))
    }

    @MainActor
    func testUnreadToggleAndSuccessfulLoadPrune() async throws {
        let responses = LockedQueue([
            #"{"sessions":[{"session_id":"keep","title":"Keep","last_message_at":100},{"session_id":"gone","title":"Gone","last_message_at":100}]}"#,
            #"{"sessions":[{"session_id":"keep","title":"Keep","last_message_at":100}]}"#
        ])
        let viewModel = try makeViewModel { request in
            apiTestJSONResponse(responses.next(), for: request)
        }

        await viewModel.load()
        let keep = try XCTUnwrap(viewModel.sessions.first { $0.sessionId == "keep" })
        viewModel.toggleUnread(keep)
        XCTAssertTrue(viewModel.isUnread(keep))
        viewModel.toggleUnread(keep)
        XCTAssertFalse(viewModel.isUnread(keep))
        viewModel.toggleUnread(keep)
        XCTAssertTrue(viewModel.isUnread(keep))

        await viewModel.load()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        XCTAssertEqual(SessionUnreadStore(defaults: unreadDefaults).load(for: server).keys.sorted(), ["keep"])
        XCTAssertTrue(viewModel.isUnread(viewModel.sessions[0]))
    }

    func testUnreadStoreScopesEqualSessionIDsByServer() throws {
        let store = SessionUnreadStore(defaults: unreadDefaults)
        let first = try XCTUnwrap(URL(string: "https://first.test"))
        let second = try XCTUnwrap(URL(string: "https://second.test"))

        store.save(["same": 100], for: first)
        store.save(["same": 200], for: second)
        XCTAssertEqual(store.load(for: first), ["same": 100])
        XCTAssertEqual(store.load(for: second), ["same": 200])

        store.remove(for: first)
        XCTAssertTrue(store.load(for: first).isEmpty)
        XCTAssertEqual(store.load(for: second), ["same": 200])
    }

    // MARK: - View model bound

    @MainActor
    func testRefreshChecksPendingStateOncePerStreamingSessionAndSkipsIdleRows() async throws {
        let counts = RequestCounts()
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? ""
            let sessionID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "session_id" })?
                .value

            counts.record(path: path, sessionID: sessionID)

            switch path {
            case "/api/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"session_id": "waiting", "title": "Waiting", "active_stream_id": "stream-waiting"},
                    {"session_id": "busy", "title": "Busy", "active_stream_id": "stream-busy"},
                    {"session_id": "idle", "title": "Idle"}
                  ]
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(#"{"active": true}"#, for: request)
            case "/api/approval/pending":
                guard sessionID == "waiting" else {
                    return apiTestJSONResponse(#"{"pending": null}"#, for: request)
                }

                return apiTestJSONResponse("""
                {"pending": {"approval_id": "ap-1", "command": "rm -rf build"}, "pending_count": 1}
                """, for: request)
            case "/api/clarify/pending":
                return apiTestJSONResponse(#"{"pending": null}"#, for: request)
            default:
                XCTFail("Unexpected request to \(path)")
                return apiTestJSONResponse("{}", for: request)
            }
        }

        let loaded = await viewModel.load()
        XCTAssertTrue(loaded)

        let result = await viewModel.refreshActiveSessionStatesIfNeeded(
            streamIDs: ["stream-waiting", "stream-busy"]
        )

        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(
            viewModel.attentionStatesBySessionID,
            ["waiting": .approval, "busy": .working]
        )
        XCTAssertEqual(viewModel.attentionState(for: SessionSummary(sessionId: "waiting")), .approval)
        XCTAssertEqual(viewModel.attentionState(for: SessionSummary(sessionId: "busy")), .working)
        XCTAssertNil(viewModel.attentionState(for: SessionSummary(sessionId: "idle")))

        // Exactly one probe of each kind per streaming session, and none at all
        // for the session without an active stream.
        XCTAssertEqual(counts.count(path: "/api/approval/pending", sessionID: "waiting"), 1)
        XCTAssertEqual(counts.count(path: "/api/approval/pending", sessionID: "busy"), 1)
        XCTAssertEqual(counts.count(path: "/api/approval/pending", sessionID: "idle"), 0)
        XCTAssertEqual(counts.count(path: "/api/clarify/pending", sessionID: "waiting"), 1)
        XCTAssertEqual(counts.count(path: "/api/clarify/pending", sessionID: "busy"), 1)
        XCTAssertEqual(counts.count(path: "/api/clarify/pending", sessionID: "idle"), 0)
    }

    /// A reload that drops a session's stream must drop its attention entry, or
    /// a finished row would keep claiming it wants something.
    @MainActor
    func testReloadClearsAttentionStateForSessionsThatStoppedStreaming() async throws {
        let sessionsResponses = LockedQueue([
            """
            {"sessions": [{"session_id": "waiting", "title": "Waiting", "active_stream_id": "stream-waiting"}]}
            """,
            """
            {"sessions": [{"session_id": "waiting", "title": "Waiting"}]}
            """
        ])
        let viewModel = try makeViewModel { request in
            switch request.url?.path ?? "" {
            case "/api/sessions":
                return apiTestJSONResponse(sessionsResponses.next(), for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse("""
                {"pending": {"approval_id": "ap-1"}, "pending_count": 1}
                """, for: request)
            case "/api/clarify/pending":
                return apiTestJSONResponse(#"{"pending": null}"#, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(#"{"active": true}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }

        await viewModel.load()
        await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-waiting"])
        XCTAssertEqual(viewModel.attentionStatesBySessionID, ["waiting": .approval])

        await viewModel.load()

        XCTAssertTrue(viewModel.attentionStatesBySessionID.isEmpty)
    }

    /// A probe that fails is not an answer. A tick that cannot reach the server
    /// keeps the row's known Approval instead of demoting it to Working.
    @MainActor
    func testFailedApprovalProbeKeepsTheKnownApprovalState() async throws {
        let approvalProbes = LockedCounter()
        let viewModel = try makeViewModel { request in
            switch request.url?.path ?? "" {
            case "/api/sessions":
                return apiTestJSONResponse("""
                {"sessions": [{"session_id": "waiting", "title": "Waiting", "active_stream_id": "stream-waiting"}]}
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(#"{"active": true}"#, for: request)
            case "/api/approval/pending":
                guard approvalProbes.increment() == 1 else {
                    return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
                }

                return apiTestJSONResponse("""
                {"pending": {"approval_id": "ap-1"}, "pending_count": 1}
                """, for: request)
            case "/api/clarify/pending":
                return apiTestJSONResponse(#"{"pending": null}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }

        await viewModel.load()
        await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-waiting"])
        XCTAssertEqual(viewModel.attentionStatesBySessionID, ["waiting": .approval])

        await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-waiting"])

        XCTAssertEqual(viewModel.attentionStatesBySessionID, ["waiting": .approval])
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        unreadStore: SessionUnreadStore? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> SessionListViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))

        return SessionListViewModel(
            server: server,
            client: APIClient(baseURL: server, session: session),
            unreadStore: unreadStore ?? SessionUnreadStore(defaults: unreadDefaults)
        )
    }
}

/// Request tallies written from the mock's loading queue and read from the test,
/// so counting needs no sleeps.
private final class RequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(path: String, sessionID: String?) {
        lock.lock()
        defer { lock.unlock() }

        counts["\(path)|\(sessionID ?? "")", default: 0] += 1
    }

    func count(path: String, sessionID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        return counts["\(path)|\(sessionID)"] ?? 0
    }
}

/// Counts calls from the mock's loading queue, so a handler can answer the
/// first probe differently from the ones after it.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Returns the new count, so `== 1` means "this was the first call".
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }

        value += 1
        return value
    }
}

/// Scripted responses handed out in order, repeating the last one.
private final class LockedQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard values.count > 1 else { return values[0] }
        return values.removeFirst()
    }
}
