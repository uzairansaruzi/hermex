import XCTest
@testable import HermesMobile

@MainActor
final class SSEClientTests: XCTestCase {
    override func tearDown() {
        DelayedSSEURLProtocol.reset()
        super.tearDown()
    }

    func testSSEClientDeliversIncrementalEventsBeforeDone() async throws {
        DelayedSSEURLProtocol.configure(chunks: [
            DelayedSSEChunk(
                text: "event: reasoning\ndata: {\"text\":\"Thinking live.\"}\n\n",
                delayNanoseconds: 20_000_000
            ),
            DelayedSSEChunk(
                text: "event: tool\ndata: {\"name\":\"read_file\",\"preview\":\"Reading file\"}\n\n",
                delayNanoseconds: 20_000_000
            ),
            DelayedSSEChunk(
                text: "event: token\ndata: {\"text\":\"First live token.\"}\n\n",
                delayNanoseconds: 20_000_000
            ),
            DelayedSSEChunk(
                text: "event: done\ndata: {\"usage\":{}}\n\n",
                delayNanoseconds: 250_000_000
            ),
            DelayedSSEChunk(
                text: "event: stream_end\ndata: {}\n\n",
                delayNanoseconds: 10_000_000
            )
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedSSEURLProtocol.self]
        let client = SSEClient(urlSessionConfiguration: configuration)
        let liveEvent = expectation(description: "received live event before done")
        let doneEvent = expectation(description: "received done event")
        var didFulfillLiveEvent = false
        var receivedEvents: [SSEEvent] = []

        client.start(url: URL(string: "https://example.test/api/chat/stream?stream_id=stream-123")!) { event in
            receivedEvents.append(event)

            if !didFulfillLiveEvent {
                switch event {
                case .reasoning, .toolStarted, .toolCompleted, .token, .interimAssistant:
                    didFulfillLiveEvent = true
                    liveEvent.fulfill()
                default:
                    break
                }
            }

            if case .done = event {
                doneEvent.fulfill()
            }
        }

        // Generous deadline: CI runners under parallel-clone load have blown a
        // 1s budget on wall-clock chunk delays that finish in ~0.3s locally (#76).
        await fulfillment(of: [liveEvent], timeout: 5)
        XCTAssertFalse(receivedEvents.contains { event in
            if case .done = event { return true }
            return false
        })

        await fulfillment(of: [doneEvent], timeout: 5)
        client.stop()

        XCTAssertEqual(Array(receivedEvents.prefix(3)), [
            .reasoning("Thinking live."),
            .toolStarted(ToolStreamEvent(
                eventType: nil,
                name: "read_file",
                preview: "Reading file",
                args: nil,
                duration: nil,
                isError: nil
            )),
            .token("First live token.")
        ])
        XCTAssertEqual(
            DelayedSSEURLProtocol.capturedRequest()?.value(forHTTPHeaderField: "Accept"),
            "text/event-stream"
        )
        XCTAssertEqual(
            DelayedSSEURLProtocol.capturedRequest()?.value(forHTTPHeaderField: "Accept-Encoding"),
            "identity"
        )
        XCTAssertEqual(
            DelayedSSEURLProtocol.capturedRequest()?.value(forHTTPHeaderField: "Cache-Control"),
            "no-cache, no-transform"
        )
    }

    func testDecodesToolStartedEventFromUpstreamPayload() {
        let event = SSEEventDecoder.decode(
            eventType: "tool",
            data: """
            {
              "event_type": "tool.started",
              "name": "read_file",
              "preview": "Reading file",
              "args": {
                "path": "/tmp/example.swift",
                "limit": 120,
                "recursive": false
              }
            }
            """
        )

        guard case .toolStarted(let payload) = event else {
            XCTFail("Expected toolStarted, got \(event)")
            return
        }

        XCTAssertEqual(payload.eventType, "tool.started")
        XCTAssertEqual(payload.name, "read_file")
        XCTAssertEqual(payload.preview, "Reading file")
        XCTAssertEqual(payload.args?["path"], .string("/tmp/example.swift"))
        XCTAssertEqual(payload.args?["limit"], .number(120))
        XCTAssertEqual(payload.args?["recursive"], .bool(false))
        XCTAssertNil(payload.duration)
        XCTAssertNil(payload.isError)
        XCTAssertNil(payload.stableID)
    }

    func testDecodesToolCompletedEventFromUpstreamPayload() {
        let event = SSEEventDecoder.decode(
            eventType: "tool_complete",
            data: """
            {
              "event_type": "tool.completed",
              "name": "shell",
              "preview": "Done",
              "args": {
                "cmd": "swift test"
              },
              "duration": 1.25,
              "is_error": true
            }
            """
        )

        guard case .toolCompleted(let payload) = event else {
            XCTFail("Expected toolCompleted, got \(event)")
            return
        }

        XCTAssertEqual(payload.eventType, "tool.completed")
        XCTAssertEqual(payload.name, "shell")
        XCTAssertEqual(payload.preview, "Done")
        XCTAssertEqual(payload.args?["cmd"], .string("swift test"))
        XCTAssertEqual(payload.duration, 1.25)
        XCTAssertEqual(payload.isError, true)
        XCTAssertNil(payload.stableID)
    }

    func testDecodesStableToolIDAliasesFromUpstreamPayload() {
        let aliases = [
            "tid",
            "id",
            "tool_call_id",
            "tool_use_id",
            "call_id"
        ]

        for alias in aliases {
            let event = SSEEventDecoder.decode(
                eventType: "tool",
                data: """
                {
                  "\(alias)": "  \(alias)-123  ",
                  "name": "terminal",
                  "preview": "Running command"
                }
                """
            )

            guard case .toolStarted(let payload) = event else {
                XCTFail("Expected toolStarted for \(alias), got \(event)")
                return
            }

            XCTAssertEqual(payload.stableID, "\(alias)-123", "alias \(alias)")
            XCTAssertEqual(payload.name, "terminal")
            XCTAssertEqual(payload.preview, "Running command")
        }
    }

    func testDecodesReasoningEventFromUpstreamPayload() {
        let event = SSEEventDecoder.decode(
            eventType: "reasoning",
            data: #"{"text":"I need to inspect the file first."}"#
        )

        XCTAssertEqual(event, .reasoning("I need to inspect the file first."))
    }

    func testDecodesInterimAssistantEventFromUpstreamPayload() {
        let event = SSEEventDecoder.decode(
            eventType: "interim_assistant",
            data: #"{"text":"Inspecting repo structure.","already_streamed":false}"#
        )

        XCTAssertEqual(
            event,
            .interimAssistant(InterimAssistantStreamEvent(
                text: "Inspecting repo structure.",
                alreadyStreamed: false
            ))
        )
    }

    func testInterimAssistantPayloadToleratesTypeDrift() {
        let event = SSEEventDecoder.decode(
            eventType: "interim_assistant",
            data: #"{"text":42,"already_streamed":"true"}"#
        )

        XCTAssertEqual(
            event,
            .interimAssistant(InterimAssistantStreamEvent(
                text: "42",
                alreadyStreamed: true
            ))
        )
    }

    func testToolPayloadToleratesMissingFields() {
        let event = SSEEventDecoder.decode(eventType: "tool", data: #"{"name":"tool_without_args"}"#)

        guard case .toolStarted(let payload) = event else {
            XCTFail("Expected toolStarted, got \(event)")
            return
        }

        XCTAssertNil(payload.eventType)
        XCTAssertEqual(payload.name, "tool_without_args")
        XCTAssertNil(payload.preview)
        XCTAssertNil(payload.args)
    }

    func testDecodesDoneEventAsStreamCompletionSignal() {
        let event = SSEEventDecoder.decode(
            eventType: "done",
            data: #"{"session":{"session_id":"abc123"},"usage":{}}"#
        )

        guard case .done(let payload) = event else {
            XCTFail("Expected done event.")
            return
        }

        XCTAssertEqual(payload.session?.sessionId, "abc123")
        XCTAssertEqual(payload.usage, ContextWindowSnapshot(
            contextLength: nil,
            thresholdTokens: nil,
            lastPromptTokens: nil,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil
        ))
    }

    func testDecodesDoneEventUsagePayload() {
        let event = SSEEventDecoder.decode(
            eventType: "done",
            data: """
            {
              "session": {"session_id": "abc123"},
              "usage": {
                "input_tokens": 1200,
                "output_tokens": 300,
                "estimated_cost": 0.0123,
                "context_length": 128000,
                "threshold_tokens": 100000,
                "last_prompt_tokens": 45000
              }
            }
            """
        )

        guard case .done(let payload) = event else {
            XCTFail("Expected done event.")
            return
        }

        XCTAssertEqual(payload.session?.sessionId, "abc123")
        XCTAssertEqual(payload.usage, ContextWindowSnapshot(
            contextLength: 128_000,
            thresholdTokens: 100_000,
            lastPromptTokens: 45_000,
            inputTokens: 1_200,
            outputTokens: 300,
            estimatedCost: 0.0123
        ))
    }

    func testDecodesDoneEventSessionMessages() {
        let event = SSEEventDecoder.decode(
            eventType: "done",
            data: """
            {
              "session": {
                "session_id": "abc123",
                "title": "Approval test",
                "messages": [
                  {
                    "role": "user",
                    "content": "Do it one more time",
                    "message_id": "user-1",
                    "timestamp": 1770000100
                  },
                  {
                    "role": "assistant",
                    "content": "Same result -- approval gate triggered, then completed.",
                    "message_id": "assistant-1",
                    "timestamp": 1770000101
                  }
                ]
              },
              "usage": {}
            }
            """
        )

        guard case .done(let payload) = event else {
            XCTFail("Expected done event.")
            return
        }

        XCTAssertEqual(payload.session?.sessionId, "abc123")
        XCTAssertEqual(payload.session?.title, "Approval test")
        XCTAssertEqual(payload.session?.messages?.compactMap(\.content), [
            "Do it one more time",
            "Same result -- approval gate triggered, then completed."
        ])
    }

    func testDecodesPendingSteerLeftoverEvent() {
        let event = SSEEventDecoder.decode(
            eventType: "pending_steer_leftover",
            data: #"{"session_id":"abc123","text":"follow this constraint"}"#
        )

        XCTAssertEqual(event, .pendingSteerLeftover("follow this constraint"))
    }

    func testDecodesApprovalInitialEventFromApprovalStream() {
        let event = SSEEventDecoder.decode(
            eventType: "initial",
            data: """
            {
              "pending": {
                "approval_id": "approval-1",
                "command": "curl https://example.test/install.sh | bash",
                "description": "High risk command",
                "pattern_keys": ["network_download", "pipe_to_shell"]
              },
              "pending_count": 2
            }
            """
        )

        guard case .approvalPending(let response) = event else {
            XCTFail("Expected approvalPending, got \(event)")
            return
        }

        XCTAssertEqual(response.pending?.approvalId, "approval-1")
        XCTAssertEqual(response.pending?.displayPatternKeys, ["network_download", "pipe_to_shell"])
        XCTAssertEqual(response.pendingCount, 2)
    }

    func testDecodesDirectApprovalEventFromChatStream() {
        let event = SSEEventDecoder.decode(
            eventType: "approval",
            data: """
            {
              "approval_id": "approval-2",
              "command": "python script.py",
              "description": "Run Python",
              "pattern_key": "python_exec"
            }
            """
        )

        guard case .approvalPending(let response) = event else {
            XCTFail("Expected approvalPending, got \(event)")
            return
        }

        XCTAssertEqual(response.pending?.approvalId, "approval-2")
        XCTAssertEqual(response.pending?.displayPatternKeys, ["python_exec"])
        XCTAssertEqual(response.pendingCount, 1)
    }

    func testDecodesTitleEventFromUpstreamPayload() {
        let event = SSEEventDecoder.decode(
            eventType: "title",
            data: #"{"session_id":"abc123","title":"SwiftUI Chat Polish"}"#
        )

        XCTAssertEqual(
            event,
            .title(TitleStreamEvent(sessionId: "abc123", title: "SwiftUI Chat Polish"))
        )
    }

    func testMalformedToolPayloadDoesNotCrashOrSurfaceError() {
        let event = SSEEventDecoder.decode(eventType: "tool_complete", data: "{")

        guard case .toolCompleted(let payload) = event else {
            XCTFail("Expected toolCompleted, got \(event)")
            return
        }

        XCTAssertNil(payload.eventType)
        XCTAssertNil(payload.name)
        XCTAssertNil(payload.preview)
        XCTAssertNil(payload.args)
        XCTAssertNil(payload.duration)
        XCTAssertNil(payload.isError)
        XCTAssertNil(payload.stableID)
    }

    func testMalformedDonePayloadSurfacesTransportError() {
        let event = SSEEventDecoder.decode(eventType: "done", data: "{")

        XCTAssertEqual(event, .transportError("The stream returned a malformed completion event."))
    }

    func testMalformedDoneUsagePayloadSurfacesTransportError() {
        let event = SSEEventDecoder.decode(eventType: "done", data: #"{"usage":"bad"}"#)

        XCTAssertEqual(event, .transportError("The stream returned a malformed completion event."))
    }

    func testMalformedDoneSessionPayloadSurfacesTransportError() {
        let event = SSEEventDecoder.decode(eventType: "done", data: #"{"session":1,"usage":{}}"#)

        XCTAssertEqual(event, .transportError("The stream returned a malformed completion event."))
    }

    func testMalformedErrorPayloadSurfacesExplicitError() {
        let event = SSEEventDecoder.decode(eventType: "error", data: "{")

        XCTAssertEqual(event, .error("The stream returned a malformed error event."))
    }

    func testAppErrorEventDecodesPinnedUpstreamMessageShape() {
        // Pinned upstream `_provider_error_payload`: {message, type, hint, details, session, …}.
        let event = SSEEventDecoder.decode(
            eventType: "apperror",
            data: #"{"message": "Provider exploded", "type": "no_response", "hint": "Check the provider keys.", "details": "Provider exploded", "session_id": "session-abc", "session": {"session_id": "session-abc"}}"#
        )

        XCTAssertEqual(event, .error("Provider exploded"))
    }

    func testAppErrorEventDecodesDocsErrorShape() {
        // API docs describe the payload as {error, type, session, terminal_state?}.
        let event = SSEEventDecoder.decode(
            eventType: "apperror",
            data: #"{"error": "Terminal failure", "type": "tool_limit_reached", "terminal_state": "tool_limit_reached"}"#
        )

        XCTAssertEqual(event, .error("Terminal failure"))
    }

    func testAppErrorEventWithoutMessageFallsBackToGenericError() {
        let event = SSEEventDecoder.decode(eventType: "apperror", data: "{}")

        XCTAssertEqual(event, .error("The stream returned an error."))
    }

    func testMalformedAppErrorPayloadSurfacesExplicitError() {
        let event = SSEEventDecoder.decode(eventType: "apperror", data: "{")

        XCTAssertEqual(event, .error("The stream returned a malformed error event."))
    }

    func testUnknownStreamEventTypeIsIgnored() {
        let event = SSEEventDecoder.decode(
            eventType: "future_server_event",
            data: #"{"text":"new payload"}"#
        )

        XCTAssertEqual(event, .ignored)
    }
}

private struct DelayedSSEChunk {
    let text: String
    let delayNanoseconds: UInt64
}

private final class DelayedSSEURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var chunks: [DelayedSSEChunk] = []
    private static var lastRequest: URLRequest?

    private var loadingTask: Task<Void, Never>?

    static func configure(chunks: [DelayedSSEChunk]) {
        lock.lock()
        self.chunks = chunks
        lastRequest = nil
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        chunks = []
        lastRequest = nil
        lock.unlock()
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let chunks: [DelayedSSEChunk]
        Self.lock.lock()
        Self.lastRequest = request
        chunks = Self.chunks
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/event-stream; charset=utf-8",
                    "Cache-Control": "no-cache"
                ]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        loadingTask = Task { [weak self] in
            guard let self else { return }
            for chunk in chunks {
                guard !Task.isCancelled else { return }
                if chunk.delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: chunk.delayNanoseconds)
                }
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didLoad: Data(chunk.text.utf8))
            }

            guard !Task.isCancelled else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}
