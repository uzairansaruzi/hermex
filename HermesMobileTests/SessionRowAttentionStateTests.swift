import XCTest
@testable import HermesMobile

/// The session row's attention state: the pure precedence rule, and the bound
/// on how often the list asks the server about it.
final class SessionRowAttentionStateTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
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
            SessionRowView.effectiveAttentionState(for: streaming, attentionState: nil),
            .working
        )
        XCTAssertNil(
            SessionRowView.effectiveAttentionState(
                for: SessionSummary(sessionId: "s"),
                attentionState: nil
            )
        )
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

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> SessionListViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))

        return SessionListViewModel(
            server: server,
            client: APIClient(baseURL: server, session: session)
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
