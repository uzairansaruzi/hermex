import Foundation
import XCTest
@testable import HermesMobile

final class ChatPerformanceMeasurementTests: APIClientTestCase {
    @MainActor
    func testCheapBoundedMeasurementCapturesSamplesWithoutPacingSleeps() throws {
        let fixture = ChatPerformanceFixture.make(
            rowCount: 50,
            responseBytes: 4_096,
            contentKind: .markdown
        )
        var samples: [UInt64] = []

        for _ in 0..<2 {
            _ = ChatViewModel.transcriptMessages(from: fixture.messages, messageOffset: 0)
        }
        ChatPerformanceInstrumentation.shared.reset()
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let mapped = ChatViewModel.transcriptMessages(from: fixture.messages, messageOffset: 0)
            samples.append(DispatchTime.now().uptimeNanoseconds &- start)
            XCTAssertEqual(mapped.count, fixture.messages.count)
        }

        let sortedSamples = samples.sorted()
        XCTAssertEqual(sortedSamples.count, 3)
        XCTAssertGreaterThanOrEqual(sortedSamples[1], sortedSamples[0])
        XCTAssertGreaterThanOrEqual(sortedSamples[2], sortedSamples[1])

        // n=3: p50 is the median (sorted[1]); p95 is the max. No interpolation.
        let summary = ChatPerformanceInstrumentation.shared.summary
        let evidence = CheapChatPerformanceEvidence(
            suite: "cheap",
            testName: "testCheapBoundedMeasurementCapturesSamplesWithoutPacingSleeps",
            commit: ProcessInfo.processInfo.environment["GITHUB_SHA"],
            rowCount: fixture.scenario.rowCount,
            responseBytes: fixture.scenario.responseBytes,
            contentKind: fixture.scenario.contentKind,
            samplesNanoseconds: samples,
            p50Nanoseconds: sortedSamples[1],
            p95Nanoseconds: sortedSamples[2],
            p95Definition: "max of 3 samples (n=3, no interpolation)",
            counters: summary.counters,
            closedIntervals: summary.closedIntervals,
            intervalDurationsNanoseconds: summary.intervalDurationsNanoseconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        let json = String(decoding: data, as: UTF8.self)
        let line = "HERMEX_PERF_EVIDENCE " + json
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "chat-performance-evidence.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRealPaginationSeamLoadsAllBoundedFixtureSizesWithoutDuplicates() async throws {
        for total in [50, 200, 500] {
            var requests: [(before: Int?, limit: Int?)] = []
            let client = makeClient { request in
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
                let before = (query["msg_before"] ?? nil).flatMap { Int($0) }
                let limit = (query["msg_limit"] ?? nil).flatMap { Int($0) }
                requests.append((before, limit))

                let pageEnd = before ?? total
                let pageStart = max(0, pageEnd - 50)
                let rows = (pageStart..<pageEnd).map(Self.messageJSON)
                let payload: [String: Any] = [
                    "session": [
                        "session_id": "performance-session",
                        "messages": rows,
                        "_messages_truncated": pageStart > 0,
                        "_messages_offset": pageStart
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return apiTestJSONResponse(String(decoding: data, as: UTF8.self), for: request)
            }
            let viewModel = ChatViewModel(
                session: SessionSummary(sessionId: "performance-session"),
                server: URL(string: "https://example.test")!,
                client: client
            )

            ChatPerformanceInstrumentation.shared.reset()
            await viewModel.loadMessages()
            while viewModel.hasOlderMessages {
                _ = await viewModel.loadOlderMessages()
            }

            XCTAssertEqual(viewModel.messages.count, total)
            XCTAssertEqual(Set(viewModel.messages.map { $0.id }).count, total)
            XCTAssertEqual(viewModel.messages.map { $0.id }, viewModel.messages.map { $0.id }.sorted { lhs, rhs in
                let left = Int(lhs.split(separator: "-").last!)!
                let right = Int(rhs.split(separator: "-").last!)!
                return left < right
            })
            XCTAssertEqual(viewModel.messagesOffset, 0)
            XCTAssertEqual(requests.first?.limit, 50)
            XCTAssertTrue(requests.dropFirst().allSatisfy { $0.limit == 50 && $0.before != nil })
            XCTAssertGreaterThanOrEqual(
                ChatPerformanceInstrumentation.shared.summary.counters[
                    ChatPerformancePhase.messagePageLoads.rawValue
                ] ?? 0,
                1
            )
        }
    }

    @MainActor
    func testFixtureDrivenReplayPreservesOrderingDeduplicationAndFinalFlush() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.transportError("Connection lost"))
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.token("charlie."), lastEventID: "stream-123:3"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeStreamingViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"stream-123"}"#, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(#"{"active":false,"stream_id":"stream-123","replay_available":true}"#, for: request)
            case "/api/session":
                return apiTestJSONResponse(#"{"session":{"session_id":"performance-session"}}"#, for: request)
            default:
                XCTFail("Unexpected request path")
                throw URLError(.badURL)
            }
        }

        ChatPerformanceInstrumentation.shared.reset()
        let replayStart = DispatchTime.now().uptimeNanoseconds
        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        try await waitUntil { streamClient.startedURLs.count == 2 }
        streamClient.playArmedConnectionScript()
        let replayNanoseconds = DispatchTime.now().uptimeNanoseconds &- replayStart

        XCTAssertEqual(viewModel.messages.compactMap { $0.content }, ["Keep working", "Alpha bravo charlie."])
        XCTAssertEqual(Set(viewModel.messages.map { $0.id }).count, viewModel.messages.count)
        XCTAssertEqual(viewModel.activeStreamID, nil)
        XCTAssertEqual(ChatPerformanceInstrumentation.shared.summary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 2)

        let assistantContent = viewModel.messages.compactMap { $0.content }.last ?? ""
        let summary = ChatPerformanceInstrumentation.shared.summary
        let evidence = CheapChatPerformanceEvidence(
            suite: "replay",
            testName: "testFixtureDrivenReplayPreservesOrderingDeduplicationAndFinalFlush",
            commit: ProcessInfo.processInfo.environment["GITHUB_SHA"],
            rowCount: viewModel.messages.count,
            responseBytes: assistantContent.utf8.count,
            contentKind: .plain,
            samplesNanoseconds: [replayNanoseconds],
            p50Nanoseconds: replayNanoseconds,
            p95Nanoseconds: replayNanoseconds,
            p95Definition: "single replay wall-clock sample (n=1)",
            counters: summary.counters,
            closedIntervals: summary.closedIntervals,
            intervalDurationsNanoseconds: summary.intervalDurationsNanoseconds
        )
        XCTAssertEqual(evidence.rowCount, 2)
        XCTAssertEqual(evidence.responseBytes, 20)
        XCTAssertEqual(evidence.contentKind, .plain)
        XCTAssertEqual(evidence.samplesNanoseconds, [replayNanoseconds])
        XCTAssertEqual(evidence.p50Nanoseconds, replayNanoseconds)
        XCTAssertEqual(evidence.p95Nanoseconds, replayNanoseconds)
        XCTAssertEqual(evidence.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        let json = String(decoding: data, as: UTF8.self)
        let line = "HERMEX_PERF_EVIDENCE " + json
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "chat-performance-replay-evidence.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testFixtureDrivenCancellationAndErrorCloseIntervalsAfterSynchronousFlush() async throws {
        let cancellationClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Partial response"))
        ]])
        let cancellationViewModel = try makeStreamingViewModel(streamClient: cancellationClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"cancel-stream"}"#, for: request)
            case "/api/chat/cancel":
                return apiTestJSONResponse(#"{"ok":true,"cancelled":true}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        ChatPerformanceInstrumentation.shared.reset()
        let didStartCancellation = await cancellationViewModel.sendMessage("Cancel this")
        XCTAssertTrue(didStartCancellation)
        cancellationClient.playArmedConnectionScript()
        _ = try await cancellationViewModel.cancelActiveStream()
        let cancellationSummary = ChatPerformanceInstrumentation.shared.summary
        XCTAssertEqual(cancellationSummary.counters[ChatPerformancePhase.cancellations.rawValue], 1)
        XCTAssertEqual(cancellationSummary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertEqual(cancellationViewModel.messages.compactMap { $0.content }, ["Cancel this", "Partial response"])

        let errorClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Before error")),
            .init(.error("Scripted stream error"))
        ]])
        let errorViewModel = try makeStreamingViewModel(streamClient: errorClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"error-stream"}"#, for: request)
        }

        ChatPerformanceInstrumentation.shared.reset()
        let didStartError = await errorViewModel.sendMessage("Handle error")
        XCTAssertTrue(didStartError)
        errorClient.playArmedConnectionScript()
        let errorSummary = ChatPerformanceInstrumentation.shared.summary
        XCTAssertEqual(errorSummary.counters[ChatPerformancePhase.errors.rawValue], 1)
        XCTAssertGreaterThanOrEqual(errorSummary.counters[ChatPerformancePhase.finalFlushes.rawValue] ?? 0, 1)
        XCTAssertEqual(errorSummary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertEqual(errorViewModel.messages.compactMap { $0.content }, ["Handle error", "Before error"])
    }

    @MainActor
    func testMappingMatrixMeasuresHistoricalRowsPlusCompletedAssistantResponse() throws {
        var cells: [CheapChatPerformanceEvidence] = []
        for rowCount in ChatPerformanceFixture.rowCounts {
            for responseBytes in ChatPerformanceFixture.responseByteLengths {
                let fixture = ChatPerformanceFixture.make(
                    rowCount: rowCount,
                    responseBytes: responseBytes,
                    contentKind: .markdown
                )
                let largeContent = String(decoding: fixture.response, as: UTF8.self)
                XCTAssertEqual(fixture.response.count, responseBytes)
                XCTAssertEqual(largeContent.utf8.count, responseBytes)

                var messages = fixture.messages
                messages.append(
                    ChatMessage(
                        role: "assistant",
                        content: largeContent,
                        timestamp: Double(rowCount),
                        messageId: "performance-mapping-assistant-\(rowCount)-\(responseBytes)"
                    )
                )

                var samples: [UInt64] = []
                for _ in 0..<2 {
                    _ = ChatViewModel.transcriptMessages(from: messages, messageOffset: 0)
                }
                ChatPerformanceInstrumentation.shared.reset()
                for _ in 0..<3 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let mapped = ChatViewModel.transcriptMessages(from: messages, messageOffset: 0)
                    samples.append(DispatchTime.now().uptimeNanoseconds &- start)
                    XCTAssertEqual(mapped.count, messages.count)
                    XCTAssertEqual(mapped.last?.message.content?.utf8.count, responseBytes)
                }

                let sortedSamples = samples.sorted()
                XCTAssertEqual(sortedSamples.count, 3)
                let summary = ChatPerformanceInstrumentation.shared.summary
                let evidence = CheapChatPerformanceEvidence(
                    suite: "mapping",
                    testName: "testMappingMatrixMeasuresHistoricalRowsPlusCompletedAssistantResponse",
                    commit: ProcessInfo.processInfo.environment["GITHUB_SHA"],
                    rowCount: rowCount,
                    responseBytes: responseBytes,
                    contentKind: .markdown,
                    samplesNanoseconds: samples,
                    p50Nanoseconds: sortedSamples[1],
                    p95Nanoseconds: sortedSamples[2],
                    p95Definition: "max of 3 samples (n=3, no interpolation)",
                    counters: summary.counters,
                    closedIntervals: summary.closedIntervals,
                    intervalDurationsNanoseconds: summary.intervalDurationsNanoseconds
                )
                try publishEvidence(evidence)
                cells.append(evidence)
            }
        }

        XCTAssertEqual(cells.count, 9)
        try attachJSONArray(cells, name: "chat-performance-matrix-mapping.json")
    }

    @MainActor
    func testStreamingMatrixMeasuresScriptedTokensThroughRealPaginationSeam() async throws {
        var cells: [CheapChatPerformanceEvidence] = []
        for rowCount in ChatPerformanceFixture.rowCounts {
            for responseBytes in ChatPerformanceFixture.responseByteLengths {
                let fixture = ChatPerformanceFixture.make(
                    rowCount: rowCount,
                    responseBytes: responseBytes,
                    contentKind: .markdown
                )
                let largeContent = String(decoding: fixture.response, as: UTF8.self)
                XCTAssertEqual(largeContent.utf8.count, responseBytes)
                let chunks = Self.utf8TokenChunks(from: fixture.response)
                XCTAssertEqual(chunks.joined().utf8.count, responseBytes)
                XCTAssertFalse(chunks.isEmpty)
                XCTAssertTrue(chunks.dropLast().allSatisfy { $0.utf8.count == 256 })
                XCTAssertLessThanOrEqual(chunks.last?.utf8.count ?? 0, 256)

                var script = chunks.enumerated().map { index, chunk in
                    ScriptedSSEStreamingClient.ScriptedEvent(
                        .token(chunk),
                        lastEventID: "stream-matrix-\(rowCount)-\(responseBytes):\(index + 1)"
                    )
                }
                script.append(.init(.done(DoneStreamEvent())))
                script.append(.init(.streamEnd))

                let streamClient = ScriptedSSEStreamingClient(connectionScripts: [script])
                let viewModel = try makeStreamingViewModel(streamClient: streamClient) { request in
                    switch request.url?.path {
                    case "/api/session":
                        return try self.paginationSessionResponse(total: rowCount, request: request)
                    case "/api/chat/start":
                        return apiTestJSONResponse(
                            #"{"session_id":"performance-session","stream_id":"stream-matrix"}"#,
                            for: request
                        )
                    default:
                        XCTFail("Unexpected request path \(request.url?.path ?? "nil")")
                        throw URLError(.badURL)
                    }
                }

                await viewModel.loadMessages()
                while viewModel.hasOlderMessages {
                    _ = await viewModel.loadOlderMessages()
                }
                XCTAssertEqual(viewModel.messages.count, rowCount)
                XCTAssertEqual(Set(viewModel.messages.map { $0.id }).count, rowCount)

                ChatPerformanceInstrumentation.shared.reset()
                let streamStart = DispatchTime.now().uptimeNanoseconds
                let didStart = await viewModel.sendMessage("Measure stream")
                XCTAssertTrue(didStart)
                streamClient.playArmedConnectionScript()
                let streamNanoseconds = DispatchTime.now().uptimeNanoseconds &- streamStart

                XCTAssertEqual(viewModel.messages.last?.role, "assistant")
                XCTAssertEqual(viewModel.messages.last?.content?.utf8.count, responseBytes)
                XCTAssertEqual(viewModel.messages.last?.content, largeContent)
                XCTAssertEqual(Set(viewModel.messages.map { $0.id }).count, viewModel.messages.count)
                XCTAssertNil(viewModel.activeStreamID)
                XCTAssertEqual(
                    viewModel.displayedTranscriptMessages,
                    ChatViewModel.transcriptMessages(
                        from: viewModel.messages,
                        messageOffset: viewModel.messagesOffset
                    )
                )
                let renderIDs = viewModel.displayedTranscriptMessages.map(\.renderID)
                XCTAssertEqual(Set(renderIDs).count, renderIDs.count)

                let summary = ChatPerformanceInstrumentation.shared.summary
                XCTAssertGreaterThanOrEqual(
                    summary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue] ?? 0,
                    1
                )
                XCTAssertFalse(summary.counters.isEmpty)
                let mappingRows = summary.counters[ChatPerformancePhase.transcriptMappingRows.rawValue] ?? 0
                let baselineMappingRows = try XCTUnwrap(
                    Self.streamingBaselineTranscriptMappingRows(
                        rowCount: rowCount,
                        responseBytes: responseBytes
                    )
                )
                let structuralFloor = (rowCount + 1) + (rowCount + 2)
                XCTAssertLessThan(mappingRows, baselineMappingRows)
                XCTAssertGreaterThanOrEqual(mappingRows, structuralFloor + chunks.count)

                let evidence = CheapChatPerformanceEvidence(
                    suite: "streaming",
                    testName: "testStreamingMatrixMeasuresScriptedTokensThroughRealPaginationSeam",
                    commit: ProcessInfo.processInfo.environment["GITHUB_SHA"],
                    rowCount: rowCount,
                    responseBytes: responseBytes,
                    contentKind: .markdown,
                    samplesNanoseconds: [streamNanoseconds],
                    p50Nanoseconds: streamNanoseconds,
                    p95Nanoseconds: streamNanoseconds,
                    p95Definition: "single streaming wall-clock sample (n=1)",
                    counters: summary.counters,
                    closedIntervals: summary.closedIntervals,
                    intervalDurationsNanoseconds: summary.intervalDurationsNanoseconds
                )
                try publishEvidence(evidence)
                cells.append(evidence)
            }
        }

        XCTAssertEqual(cells.count, 9)
        try attachJSONArray(cells, name: "chat-performance-matrix-streaming.json")
    }

    func testFixtureContentGroupingAndExpansionKeepAnchorsStable() {
        for contentKind in [ChatPerformanceContentKind.markdown, .math, .reasoning, .tool] {
            let fixture = ChatPerformanceFixture.make(
                rowCount: 4,
                responseBytes: 4_096,
                contentKind: contentKind,
                toolState: contentKind == .tool ? .expanded : .none
            )
            let transcript = ChatViewModel.transcriptMessages(from: fixture.messages)

            XCTAssertEqual(transcript.map { $0.anchorID }, fixture.messages.filter { $0.role != "tool" }.map { $0.id })
            XCTAssertEqual(transcript.map { $0.id }, transcript.map { $0.id }.sorted())
            XCTAssertEqual(transcript.count, contentKind == .tool ? 0 : fixture.messages.count)
            XCTAssertTrue(fixture.messages.allSatisfy { message in
                message.content?.isEmpty == false || message.reasoning?.isEmpty == false
            })
            switch contentKind {
            case .markdown:
                XCTAssertTrue(fixture.messages.allSatisfy { $0.content?.contains("**Stable**") == true })
            case .math:
                XCTAssertTrue(fixture.messages.allSatisfy { $0.content?.contains("$") == true })
            case .reasoning:
                XCTAssertEqual(
                    ChatViewModel.reasoningDisplayGroups(messages: fixture.messages, archivedGroups: []).count,
                    2
                )
            case .tool:
                XCTAssertTrue(transcript.isEmpty)
            default:
                XCTFail("Unexpected content kind in grouping fixture")
            }
        }

        var transcriptIDsByToolState: [[String]] = []
        var anchorIDsByToolState: [[String]] = []

        for toolState in [ChatPerformanceToolState.collapsed, .expanded] {
            let fixture = ChatPerformanceFixture.make(
                rowCount: 4,
                responseBytes: 4_096,
                contentKind: .tool,
                toolState: toolState
            )
            let messages = [
                ChatMessage(
                    role: "user",
                    content: "Run the tools",
                    timestamp: 0,
                    messageId: "tool-user"
                ),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    timestamp: 1,
                    messageId: "tool-assistant",
                    toolCalls: [
                        .object([
                            "id": .string("call-1"),
                            "function": .object([
                                "name": .string("read_file"),
                                "arguments": .string("{\"path\":\"notes.txt\"}")
                            ])
                        ]),
                        .object([
                            "id": .string("call-2"),
                            "function": .object([
                                "name": .string("search_files"),
                                "arguments": .string("{\"path\":\"Sources\"}")
                            ])
                        ])
                    ]
                ),
                ChatMessage(
                    role: "tool",
                    content: fixture.messages[0].content,
                    timestamp: 2,
                    messageId: "tool-result-1",
                    toolCallId: "call-1"
                ),
                ChatMessage(
                    role: "tool",
                    content: fixture.messages[1].content,
                    timestamp: 3,
                    messageId: "tool-result-2",
                    toolCallId: "call-2"
                )
            ]
            let groups = ToolCallGroup.groups(
                persistedToolCalls: [],
                messages: messages,
                messageOffset: nil
            )
            let transcript = ChatViewModel.transcriptMessages(from: messages)
            guard let group = groups.first else {
                XCTFail("Expected one grouped tool activity")
                continue
            }

            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(fixture.scenario.toolState, toolState)
            XCTAssertEqual(group.toolCalls.map { $0.id }, ["call-1", "call-2"])
            XCTAssertEqual(group.toolCalls.map { $0.name }, ["read_file", "search_files"])
            XCTAssertTrue(group.toolCalls.allSatisfy { toolCall in
                (toolCall.preview ?? "").hasSuffix(" output") == (toolState == .expanded)
            })
            XCTAssertEqual(
                group.toolCalls.map { $0.preview },
                [fixture.messages[0].content, fixture.messages[1].content]
            )
            XCTAssertEqual(group.anchorMessageID, "tool-assistant")
            XCTAssertEqual(group.anchorMessageID, transcript.last?.anchorID)
            XCTAssertEqual(transcript.map { $0.anchorID }, ["tool-user", "tool-assistant"])

            transcriptIDsByToolState.append(transcript.map { $0.id })
            anchorIDsByToolState.append(transcript.map { $0.anchorID })
        }

        XCTAssertEqual(transcriptIDsByToolState.count, 2)
        XCTAssertEqual(anchorIDsByToolState.count, 2)
        guard transcriptIDsByToolState.count == 2,
              anchorIDsByToolState.count == 2
        else {
            return
        }
        XCTAssertEqual(transcriptIDsByToolState[0], transcriptIDsByToolState[1])
        XCTAssertEqual(anchorIDsByToolState[0], anchorIDsByToolState[1])

        let streaming = [
            ChatMessage(role: "user", content: "Question", timestamp: 1, messageId: "user-1"),
            ChatMessage(role: "assistant", content: "Partial", timestamp: 2, messageId: "stream-1")
        ]
        let completed = [
            ChatMessage(role: "user", content: "Question", timestamp: 1, messageId: "user-1"),
            ChatMessage(role: "assistant", content: "Complete", timestamp: 2, messageId: "assistant-1")
        ]
        let streamingTranscript = ChatViewModel.transcriptMessages(from: streaming)
        let completedTranscript = ChatViewModel.transcriptMessages(from: completed)
        XCTAssertEqual(streamingTranscript.map { $0.id }, completedTranscript.map { $0.id })
        XCTAssertEqual(streamingTranscript.first?.anchorID, "user-1")
        XCTAssertEqual(streamingTranscript.last?.anchorID, "stream-1")
        XCTAssertEqual(completedTranscript.last?.anchorID, "assistant-1")
    }

    private static func messageJSON(index: Int) -> [String: Any] {
        [
            "role": index.isMultiple(of: 2) ? "user" : "assistant",
            "content": "Deterministic pagination row \(index)",
            "_ts": Double(index),
            "message_id": "performance-message-\(index)"
        ]
    }

    @MainActor
    private func makeStreamingViewModel(
        streamClient: ScriptedSSEStreamingClient,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        let client = makeClient(handler: handler)
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "performance-session"),
            server: URL(string: "https://example.test")!,
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

    private func publishEvidence(_ evidence: CheapChatPerformanceEvidence) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        let json = String(decoding: data, as: UTF8.self)
        let line = "HERMEX_PERF_EVIDENCE " + json
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func attachJSONArray(_ cells: [CheapChatPerformanceEvidence], name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cells)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func paginationSessionResponse(
        total: Int,
        request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
        let before = (query["msg_before"] ?? nil).flatMap { Int($0) }
        let pageEnd = before ?? total
        let pageStart = max(0, pageEnd - 50)
        let rows = (pageStart..<pageEnd).map(Self.messageJSON)
        let payload: [String: Any] = [
            "session": [
                "session_id": "performance-session",
                "messages": rows,
                "_messages_truncated": pageStart > 0,
                "_messages_offset": pageStart
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return apiTestJSONResponse(String(decoding: data, as: UTF8.self), for: request)
    }

    private static func utf8TokenChunks(from data: Data, maxBytes: Int = 256) -> [String] {
        var chunks: [String] = []
        var offset = 0
        while offset < data.count {
            var end = min(offset + maxBytes, data.count)
            var advanced = false
            while end > offset {
                if let text = String(data: data.subdata(in: offset..<end), encoding: .utf8) {
                    chunks.append(text)
                    offset = end
                    advanced = true
                    break
                }
                end -= 1
            }
            if !advanced {
                offset += 1
            }
        }
        return chunks
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
        XCTFail("Timed out waiting for scripted stream recovery")
    }

    private static func streamingBaselineTranscriptMappingRows(rowCount: Int, responseBytes: Int) -> Int? {
        switch (rowCount, responseBytes) {
        case (50, 4_096): return 935
        case (50, 16_384): return 3_431
        case (50, 65_536): return 13_415
        case (200, 4_096): return 3_635
        case (200, 16_384): return 13_331
        case (200, 65_536): return 52_115
        case (500, 4_096): return 9_035
        case (500, 16_384): return 33_131
        case (500, 65_536): return 129_515
        default: return nil
        }
    }
}
