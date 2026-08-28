import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class ChatPerformanceInstrumentationTests: APIClientTestCase {
    func testResetStartsWithZeroAndSummaryIsStableAndPayloadFree() throws {
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        XCTAssertTrue(instrumentation.summary.counters.isEmpty)
        XCTAssertTrue(instrumentation.summary.closedIntervals.isEmpty)
        let data = try JSONEncoder().encode(instrumentation.summary)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("prompt"))
        XCTAssertFalse(encoded.contains("http"))
        XCTAssertFalse(encoded.contains("tool_args"))
    }

    func testNamedPhasesCountUnitsAndCloseIntervals() {
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        instrumentation.record(.eventHandling, units: 3)
        instrumentation.record(.drainedUnits, units: 12)
        instrumentation.begin(.streamIntervals)
        instrumentation.end(.streamIntervals)

        XCTAssertEqual(instrumentation.summary.counters[ChatPerformancePhase.eventHandling.rawValue], 3)
        XCTAssertEqual(instrumentation.summary.counters[ChatPerformancePhase.drainedUnits.rawValue], 12)
        XCTAssertEqual(instrumentation.summary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertGreaterThan(instrumentation.summary.intervalDurationsNanoseconds[ChatPerformancePhase.streamIntervals.rawValue] ?? 0, 0)
    }

    func testCountersDoNotRecordNonPositiveUnits() {
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        instrumentation.record(.eventHandling, units: 0)
        instrumentation.record(.eventHandling, units: -1)

        XCTAssertNil(instrumentation.summary.counters[ChatPerformancePhase.eventHandling.rawValue])
    }

    func testUIOwnedPhasesRecordOnceEachInSummaryKeys() {
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        let phases: [ChatPerformancePhase] = [
            .transcriptContentEvaluations,
            .transcriptLayoutPasses,
            .scrollMetricCallbacks,
            .followScrollSchedules,
            .followScrollFires,
            .markdownBlocks,
            .uncachedMathLayouts,
            .streamingMarkdownSplits,
            .fadeDraws,
            .fadeTimelineFrames,
        ]
        for phase in phases {
            instrumentation.record(phase)
            XCTAssertEqual(instrumentation.summary.counters[phase.rawValue], 1)
        }
    }

    func testOwningCoordinatorAndViewModelPathsRecordSuccessCountersAndCloseInterval() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Stable response")),
            .init(.reasoning("Stable reasoning")),
            .init(.toolStarted(ToolStreamEvent(
                eventType: "tool",
                name: "read_file",
                preview: nil,
                args: nil,
                duration: nil,
                isError: nil
            ))),
            .init(.toolCompleted(ToolStreamEvent(
                eventType: "tool_complete",
                name: "read_file",
                preview: nil,
                args: nil,
                duration: 1,
                isError: false
            ))),
            .init(.done(DoneStreamEvent())),
            .init(.streamEnd)
        ]])
        let viewModel = try makeStreamingViewModel(streamClient: streamClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"success-stream"}"#, for: request)
        }
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        let didStart = await viewModel.sendMessage("Run deterministic case")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()

        let summary = instrumentation.summary
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.eventHandling.rawValue] ?? 0, 6)
        XCTAssertEqual(summary.counters[ChatPerformancePhase.streamConnections.rawValue], 1)
        XCTAssertEqual(summary.counters[ChatPerformancePhase.reasoningGroups.rawValue], 1)
        XCTAssertEqual(summary.counters[ChatPerformancePhase.toolStarts.rawValue], 1)
        XCTAssertEqual(summary.counters[ChatPerformancePhase.toolCompletions.rawValue], 1)
        XCTAssertEqual(summary.counters[ChatPerformancePhase.completions.rawValue], 1)
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.finalFlushes.rawValue] ?? 0, 1)
        XCTAssertEqual(summary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Run deterministic case", "Stable response"])
    }

    func testOwningCoordinatorRecoveryPathRecordsErrorPagesAndClosedInterval() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Partial response")),
            .init(.transportError("Connection lost"))
        ]])
        let viewModel = try makeStreamingViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"recovery-stream"}"#, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(#"{"active":false,"stream_id":"recovery-stream","replay_available":false}"#, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {"session":{"session_id":"performance-session","messages":[
                  {"role":"user","content":"Recover this","message_id":"user-1"},
                  {"role":"assistant","content":"Recovered response","message_id":"assistant-1"}
                ]}}
                """, for: request)
            default:
                XCTFail("Unexpected request path")
                throw URLError(.badURL)
            }
        }
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        let didStart = await viewModel.sendMessage("Recover this")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        try await waitUntil { viewModel.activeStreamID == nil }

        let summary = instrumentation.summary
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.errors.rawValue] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.progressRecoveryWrites.rawValue] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.messagePageLoads.rawValue] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.messagePageRows.rawValue] ?? 0, 2)
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.transcriptMappingRows.rawValue] ?? 0, 2)
        XCTAssertGreaterThanOrEqual(summary.counters[ChatPerformancePhase.finalFlushes.rawValue] ?? 0, 1)
        XCTAssertEqual(summary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertEqual(summary.closedIntervals[ChatPerformancePhase.messageLoadIntervals.rawValue], 1)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Recover this", "Recovered response"])
    }

    @MainActor
    private func makeStreamingViewModel(
        streamClient: ScriptedSSEStreamingClient,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "performance-session"),
            server: URL(string: "https://example.test")!,
            client: makeClient(handler: handler),
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
        XCTFail("Timed out waiting for recovery")
    }
}
