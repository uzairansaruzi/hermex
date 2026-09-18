import XCTest
@testable import HermesMobile

final class ClarificationTests: XCTestCase {
    override func tearDown() {
        ClarificationMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testClarificationPendingDecodesUpstreamShapeTolerantly() throws {
        let response = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data("""
            {
              "pending": {
                "clarify_id": "clarify-1",
                "question": "Which branch should I use?",
                "choices_offered": ["main", 42, true],
                "session_id": "session-abc",
                "kind": "clarify",
                "requested_at": "1716150000.0",
                "timeout_seconds": "120",
                "expires_at": 1716150120.0,
                "future_field": {"ignored": true}
              },
              "pending_count": "2"
            }
            """.utf8)
        )

        XCTAssertEqual(response.pending?.clarifyId, "clarify-1")
        XCTAssertEqual(response.pending?.question, "Which branch should I use?")
        XCTAssertEqual(response.pending?.choicesOffered, ["main", "42.0", "true"])
        XCTAssertEqual(response.pending?.sessionId, "session-abc")
        XCTAssertEqual(response.pending?.kind, "clarify")
        XCTAssertEqual(response.pending?.requestedAt, 1_716_150_000)
        XCTAssertEqual(response.pending?.timeoutSeconds, 120)
        XCTAssertEqual(response.pending?.expiresAt, 1_716_150_120)
        XCTAssertEqual(response.pendingCount, 2)
    }

    func testClarificationPendingDecodesNullAndMissingOptionals() throws {
        let noPending = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data(#"{"pending": null}"#.utf8)
        )
        XCTAssertNil(noPending.pending)
        XCTAssertNil(noPending.pendingCount)

        let minimal = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data(#"{"pending":{"question":"Answer this."}}"#.utf8)
        )
        XCTAssertEqual(minimal.pending?.displayQuestion, "Answer this.")
        XCTAssertEqual(minimal.pending?.displayChoices, [])
    }

    func testClarificationAPIUsesVerifiedRoutesAndBodies() async throws {
        var requestCount = 0
        var respondBody: [String: Any]?
        let client = makeClient { request in
            requestCount += 1

            switch requestCount {
            case 1:
                XCTAssertEqual(request.url?.path, "/api/clarify/pending")
                XCTAssertEqual(request.httpMethod, "GET")

                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
                XCTAssertEqual(query["session_id"], "session-abc")

                return jsonResponse("""
                {
                  "pending": {
                    "clarify_id": "clarify-1",
                    "question": "Pick one",
                    "choices_offered": ["A", "B"],
                    "session_id": "session-abc"
                  }
                }
                """, for: request)
            case 2:
                XCTAssertEqual(request.url?.path, "/api/clarify/respond")
                XCTAssertEqual(request.httpMethod, "POST")
                respondBody = try XCTUnwrap(jsonBody(from: request))
                return jsonResponse(#"{"ok": true, "response": "A"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let pending = try await client.clarifyPending(sessionID: "session-abc")
        XCTAssertEqual(pending.pending?.clarifyId, "clarify-1")
        XCTAssertEqual(pending.pending?.displayChoices, ["A", "B"])

        let response = try await client.respondClarification(
            sessionID: "session-abc",
            response: "A",
            clarifyID: "clarify-1"
        )

        XCTAssertEqual(respondBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(respondBody?["response"] as? String, "A")
        XCTAssertEqual(respondBody?["clarify_id"] as? String, "clarify-1")
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.response, "A")
        XCTAssertEqual(client.clarifyStreamURL(sessionID: "session-abc").path, "/api/clarify/stream")
    }

    func testClarificationRespondResponseDecodesStaleFieldsTolerantly() throws {
        let stale = try JSONDecoder().decode(
            ClarificationRespondResponse.self,
            from: Data(#"{"ok": false, "error": "Clarification prompt expired or not found.", "stale": true}"#.utf8)
        )
        XCTAssertEqual(stale.ok, false)
        XCTAssertEqual(stale.stale, true)
        XCTAssertNil(stale.staleCleared)
        XCTAssertNil(stale.relayed)

        let cleared = try JSONDecoder().decode(
            ClarificationRespondResponse.self,
            from: Data(#"{"ok": true, "response": "A", "stale_cleared": "true", "relayed": 1}"#.utf8)
        )
        XCTAssertEqual(cleared.ok, true)
        XCTAssertEqual(cleared.staleCleared, true)
        XCTAssertEqual(cleared.relayed, true)
        XCTAssertNil(cleared.stale)
    }

    @MainActor
    func testClarificationStale409DismissesPromptWithFriendlyExpiredMessage() async throws {
        let streamClient = ClarificationSpySSEStreamingClient()
        let approvalStreamClient = ClarificationSpySSEStreamingClient()
        let clarifyStreamClient = ClarificationSpySSEStreamingClient()
        var didRefreshPendingAfterStale = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return jsonResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/clarify/respond":
                return jsonResponse(
                    #"{"ok": false, "error": "Clarification prompt expired or not found. The agent may have already proceeded.", "stale": true}"#,
                    statusCode: 409,
                    for: request
                )
            case "/api/clarify/pending":
                didRefreshPendingAfterStale = true
                return jsonResponse(#"{"pending": null}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Continue")
        XCTAssertTrue(didStart)
        clarifyStreamClient.emit(.clarificationPending(ClarificationPendingResponse(
            pending: PendingClarification(
                clarifyId: "clarify-1",
                question: "Which branch?",
                sessionId: "session-abc"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToClarification("Use main")

        // Expired prompt: the stale card dismisses with a friendly explanation
        // instead of sticking around behind a generic failure (issue #25).
        XCTAssertFalse(didRespond)
        XCTAssertNil(viewModel.clarificationPrompt)
        XCTAssertNil(viewModel.clarificationErrorMessage)
        XCTAssertEqual(
            viewModel.sendErrorMessage,
            PendingPromptExpiredError(prompt: .clarification).localizedDescription
        )
        XCTAssertTrue(didRefreshPendingAfterStale)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    func testSSEDecoderHandlesClarifyAndInitialEvents() {
        let clarify = SSEEventDecoder.decode(
            eventType: "clarify",
            data: """
            {
              "pending": {
                "clarify_id": "clarify-2",
                "question": "Choose deployment target",
                "choices_offered": ["iPhone", "iPad"],
                "session_id": "session-abc"
              },
              "pending_count": 1
            }
            """
        )

        guard case .clarificationPending(let clarifyResponse) = clarify else {
            XCTFail("Expected clarificationPending, got \(clarify)")
            return
        }

        XCTAssertEqual(clarifyResponse.pending?.clarifyId, "clarify-2")
        XCTAssertEqual(clarifyResponse.pending?.displayChoices, ["iPhone", "iPad"])
        XCTAssertEqual(clarifyResponse.pendingCount, 1)

        let initial = SSEEventDecoder.decode(
            eventType: "initial",
            data: """
            {
              "pending": {
                "question": "What should I do next?",
                "choices_offered": ["Run tests", "Stop"]
              },
              "pending_count": 1
            }
            """
        )

        guard case .clarificationPending(let initialResponse) = initial else {
            XCTFail("Expected clarificationPending initial event, got \(initial)")
            return
        }

        XCTAssertEqual(initialResponse.pending?.displayQuestion, "What should I do next?")
        XCTAssertEqual(initialResponse.pending?.displayChoices, ["Run tests", "Stop"])
    }

    @MainActor
    func testChatViewModelClarificationStreamPublishesPromptAndResponds() async throws {
        let streamClient = ClarificationSpySSEStreamingClient()
        let approvalStreamClient = ClarificationSpySSEStreamingClient()
        let clarifyStreamClient = ClarificationSpySSEStreamingClient()
        var respondBody: [String: Any]?
        var didFetchPendingAfterResponse = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return jsonResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/clarify/respond":
                respondBody = try XCTUnwrap(jsonBody(from: request))
                return jsonResponse(#"{"ok": true, "response": "Use main"}"#, for: request)
            case "/api/clarify/pending":
                didFetchPendingAfterResponse = true
                return jsonResponse(#"{"pending": null}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Continue")

        XCTAssertTrue(didStart)
        XCTAssertEqual(streamClient.startedURLs.first?.path, "/api/chat/stream")
        XCTAssertEqual(approvalStreamClient.startedURLs.first?.path, "/api/approval/stream")
        XCTAssertEqual(clarifyStreamClient.startedURLs.first?.path, "/api/clarify/stream")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(clarifyStreamClient.startedURLs.first), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "session_id" })?
                .value,
            "session-abc"
        )

        clarifyStreamClient.emit(.clarificationPending(ClarificationPendingResponse(
            pending: PendingClarification(
                clarifyId: "clarify-1",
                question: "Which branch?",
                choicesOffered: ["main", "release"],
                sessionId: "session-abc",
                kind: "clarify",
                requestedAt: 1_716_150_000,
                timeoutSeconds: 120,
                expiresAt: 1_716_150_120
            ),
            pendingCount: 1
        )))

        XCTAssertEqual(viewModel.clarificationPrompt?.sessionID, "session-abc")
        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "clarify-1")
        XCTAssertEqual(viewModel.clarificationPrompt?.question, "Which branch?")
        XCTAssertEqual(viewModel.clarificationPrompt?.choices, ["main", "release"])

        await viewModel.respondToClarification("  Use main  ")

        XCTAssertEqual(respondBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(respondBody?["response"] as? String, "Use main")
        XCTAssertEqual(respondBody?["clarify_id"] as? String, "clarify-1")
        XCTAssertTrue(didFetchPendingAfterResponse)
        XCTAssertNil(viewModel.clarificationPrompt)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testClarificationResponseFailureKeepsPromptAndPublishesActionError() async throws {
        let streamClient = ClarificationSpySSEStreamingClient()
        let approvalStreamClient = ClarificationSpySSEStreamingClient()
        let clarifyStreamClient = ClarificationSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return jsonResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            case "/api/clarify/respond":
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Continue")
        XCTAssertTrue(didStart)
        clarifyStreamClient.emit(.clarificationPending(ClarificationPendingResponse(
            pending: PendingClarification(
                clarifyId: "clarify-1",
                question: "Which branch?",
                sessionId: "session-abc"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToClarification("Use main")

        XCTAssertFalse(didRespond)
        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "clarify-1")
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(viewModel.clarificationErrorMessage, viewModel.sendErrorMessage)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testClarificationForDifferentSessionDoesNotRenderOverCurrentChat() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return jsonResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
        }

        let didStart = await viewModel.sendMessage("Continue")
        XCTAssertTrue(didStart)

        viewModel.applyClarificationUpdate(
            ClarificationPendingResponse(
                pending: PendingClarification(
                    clarifyId: "other-clarify",
                    question: "Other session?",
                    sessionId: "other-session"
                ),
                pendingCount: 1
            ),
            sessionID: "other-session"
        )

        XCTAssertNil(viewModel.clarificationPrompt)

        viewModel.applyClarificationUpdate(
            ClarificationPendingResponse(
                pending: PendingClarification(
                    clarifyId: "current-clarify",
                    question: "Current session?",
                    sessionId: "session-abc"
                ),
                pendingCount: 1
            ),
            sessionID: "session-abc"
        )

        XCTAssertEqual(viewModel.clarificationPrompt?.pending.clarifyId, "current-clarify")
    }

    @MainActor
    private func makeViewModel(
        streamClient: SSEStreamingClient? = nil,
        approvalStreamClient: SSEStreamingClient? = nil,
        clarifyStreamClient: SSEStreamingClient? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        ClarificationMockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClarificationMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)
        let session = try makeSession()

        return ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: streamClient ?? ClarificationSpySSEStreamingClient(),
            approvalStreamClient: approvalStreamClient ?? ClarificationSpySSEStreamingClient(),
            clarifyStreamClient: clarifyStreamClient ?? ClarificationSpySSEStreamingClient()
        )
    }

    private func makeSession() throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "workspace": "/tmp/workspace",
              "model": "gpt-5.4"
            }
            """.utf8)
        )
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        ClarificationMockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClarificationMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }
}

private final class ClarificationSpySSEStreamingClient: SSEStreamingClient {
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    private var onEvent: (@MainActor (SSEEvent) -> Void)?

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

private final class ClarificationMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
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

private func jsonResponse(_ json: String, statusCode: Int = 200, for request: URLRequest) -> (HTTPURLResponse, Data) {
    let url = request.url ?? URL(string: "https://example.test")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(json.utf8))
}

private func jsonBody(from request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(bodyData(from: request))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func bodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 {
            return nil
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }

    return data
}
