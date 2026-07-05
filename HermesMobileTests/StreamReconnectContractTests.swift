import XCTest
@testable import HermesMobile

/// Contract tests for the riskiest streaming paths: disconnect → reconnect
/// with replayed tokens, server restart mid-stream, and replay of content the
/// client already rendered. Each test drives a real `ChatViewModel` (which
/// owns the replay dedup from PR #211) and a real `ChatStreamCoordinator`
/// through a full scripted wire sequence via `ScriptedSSEStreamingClient`.
final class StreamReconnectContractTests: APIClientTestCase {
    // MARK: - Scenario 1: reconnect with overlapping replayed tokens (#201 regression guard)

    @MainActor
    func testReconnectWithOverlappingReplayRendersEachTokenExactlyOnce() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.transportError("The network connection was lost."))
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.token("charlie "), lastEventID: "stream-123:3"),
                .init(.token("delta."), lastEventID: "stream-123:4"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Planning"}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo "])
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)

        // The transport error schedules an async reconnect; the status probe
        // reports the stream inactive with a replay journal available.
        try await waitUntil { streamClient.startedURLs.count == 2 }

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let query = queryDictionary(of: replayURL)
        XCTAssertEqual(replayURL.path, "/api/chat/stream")
        XCTAssertEqual(query["stream_id"], "stream-123")
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "2")

        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo charlie delta."])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.droppedEventCount, 0)
    }

    // MARK: - Scenario 2: server restart mid-stream (no replay journal)

    @MainActor
    func testServerRestartMidStreamRecoversToConsistentCompletedState() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.transportError("The network connection was lost."))
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                // A restarted server has neither the live stream nor its replay journal.
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": false}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Alpha bravo charlie delta.",
                        "timestamp": 1770000101,
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

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo "])
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)

        // The async reconnect probe finds the stream gone, refreshes the
        // transcript, and completes the response from the server copy.
        try await waitUntil { viewModel.activeStreamID == nil }

        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(
            viewModel.messages.compactMap(\.content),
            ["Keep working", "Alpha bravo charlie delta."]
        )
        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo charlie delta."])
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.streamingAssistantMessageID)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.droppedEventCount, 0)
    }

    // MARK: - Scenario 3: replay arriving after the response already rendered locally

    @MainActor
    func testReplayAfterStreamAlreadyCompletedLocallyIsIgnoredCleanly() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo."), lastEventID: "stream-123:2")
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo."), lastEventID: "stream-123:2"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Planning"}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo."])

        // The app backgrounds after the full text rendered but before the
        // completion events arrive; on foreground the replay re-sends the
        // entire already-rendered response plus the completion.
        viewModel.suspendStreamForBackground()
        await viewModel.reconnectStreamIfNeeded()

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let query = queryDictionary(of: replayURL)
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "2")

        streamClient.playArmedConnectionScript()

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo."])
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.droppedEventCount, 0)
    }

    // MARK: - Scenario 4: active WebUI session messages without message IDs

    @MainActor
    func testActiveSessionWithNilMessageIDsResumesStreamingIntoLoadedAssistantRow() async throws {
        let streamClient = ScriptedSSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100
                      },
                      {
                        "role": "assistant",
                        "content": "Alpha ",
                        "timestamp": 1770000101
                      }
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha "])
        XCTAssertEqual(viewModel.streamingAssistantMessageID, "raw:1")
        XCTAssertTrue(viewModel.isActiveStreamConnectionSuspended)

        await viewModel.reconnectStreamIfNeeded()
        XCTAssertEqual(streamClient.startedURLs.count, 1)

        streamClient.emit(.token("bravo."), lastEventID: "stream-123:1")

        XCTAssertEqual(assistantContents(of: viewModel), ["Alpha bravo."])
        XCTAssertEqual(viewModel.streamingAssistantMessageID, "raw:1")
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertFalse(viewModel.isActiveStreamConnectionSuspended)
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        streamClient: ScriptedSSEStreamingClient,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "workspace": "/tmp/workspace"
            }
            """.utf8)
        )

        let viewModel = ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient()
        )
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }

    @MainActor
    private func assistantContents(of viewModel: ChatViewModel) -> [String] {
        viewModel.messages.filter { $0.role == "assistant" }.compactMap(\.content)
    }

    private func queryDictionary(of url: URL) -> [String: String] {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
