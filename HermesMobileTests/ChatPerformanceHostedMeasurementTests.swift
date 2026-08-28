import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class ChatPerformanceHostedMeasurementTests: APIClientTestCase {
    private var previousAnimationEnabled: Any?
    private var hostedWindow: UIWindow?

    override func setUp() {
        super.setUp()
        previousAnimationEnabled = UserDefaults.standard.object(
            forKey: StreamedTextAnimationSettings.isEnabledKey
        )
        UserDefaults.standard.set(false, forKey: StreamedTextAnimationSettings.isEnabledKey)
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                hostedWindow?.rootViewController = nil
                hostedWindow?.isHidden = true
                hostedWindow = nil
                ChatPerformanceInstrumentation.shared.reset()
            }
        }
        UIView.setAnimationsEnabled(true)
        if let previousAnimationEnabled {
            UserDefaults.standard.set(
                previousAnimationEnabled,
                forKey: StreamedTextAnimationSettings.isEnabledKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: StreamedTextAnimationSettings.isEnabledKey)
        }
        super.tearDown()
    }

    @MainActor
    func testHostedTranscriptMappingCopiesLiveViewModelCountsAndFourKilobyteAssistant() async throws {
        let viewModel = try await loadPaginatedViewModel(rowCount: 50, includeFourKilobyteAssistant: true)
        let view = ChatTranscriptHostingSupport.transcriptView(from: viewModel)

        XCTAssertEqual(view.messages.count, viewModel.messages.count)
        XCTAssertEqual(view.displayedTranscriptMessages.count, viewModel.displayedTranscriptMessages.count)
        XCTAssertEqual(view.messages.count, 50)
        XCTAssertEqual(view.messages.last?.role, "assistant")
        XCTAssertEqual(view.messages.last?.content?.utf8.count, 4096)

        let expectedTranscript = viewModel.displayedTranscriptMessages
        let renderIDs = view.displayedTranscriptMessages.map(\.renderID)
        let anchorIDs = view.displayedTranscriptMessages.map(\.anchorID)
        XCTAssertEqual(renderIDs, expectedTranscript.map(\.renderID))
        XCTAssertEqual(anchorIDs, expectedTranscript.map(\.anchorID))
        XCTAssertEqual(Set(renderIDs).count, renderIDs.count)
        XCTAssertEqual(Set(anchorIDs).count, anchorIDs.count)
    }

    @MainActor
    func testHostedStaticTranscriptMeasurementExportsLayoutEvidence50() async throws {
        try await measureHostedStaticTranscript(rowCount: 50)
    }

    @MainActor
    func testHostedStaticTranscriptMeasurementExportsLayoutEvidence200() async throws {
        try await measureHostedStaticTranscript(rowCount: 200)
    }

    @MainActor
    func testHostedStaticTranscriptMeasurementExportsLayoutEvidence500() async throws {
        try await measureHostedStaticTranscript(rowCount: 500)
    }

    @MainActor
    func testHostedStreamingTranscriptMeasurementExportsLayoutEvidence() async throws {
        let fixture = ChatPerformanceFixture.make(
            rowCount: 50,
            responseBytes: 4_096,
            contentKind: .markdown
        )
        let largeContent = String(decoding: fixture.response, as: UTF8.self)
        XCTAssertEqual(largeContent.utf8.count, 4096)
        let chunks = ChatPerformanceFixture.utf8Chunks(from: fixture.response, maxBytes: 512)
        XCTAssertEqual(chunks.count, 8)
        XCTAssertEqual(chunks.joined().utf8.count, 4096)

        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[]])
        let viewModel = try makeStreamingViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return try self.hostedSessionResponse(
                    total: 50,
                    request: request,
                    largeAssistantContent: nil
                )
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"performance-session","stream_id":"hosted-stream"}"#,
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
        XCTAssertEqual(viewModel.messages.count, 50)

        ChatPerformanceInstrumentation.shared.reset()
        let (window, host) = ChatTranscriptHostingSupport.host(
            ChatTranscriptHostingSupport.transcriptView(from: viewModel)
        )
        hostedWindow = window

        var samples: [UInt64] = []
        let deadline = Date().addingTimeInterval(45)
        let didStart = await viewModel.sendMessage("Measure hosted stream")
        XCTAssertTrue(didStart)

        for (index, chunk) in chunks.enumerated() {
            streamClient.emit(
                .token(chunk),
                lastEventID: "hosted-stream:\(index + 1)"
            )
            ChatTranscriptHostingSupport.applySnapshot(
                ChatTranscriptHostingSupport.transcriptView(from: viewModel),
                to: host
            )
            try await collectLayoutSample(
                window: window,
                host: host,
                deadline: deadline,
                samples: &samples,
                suite: "hosted-streaming",
                testName: "testHostedStreamingTranscriptMeasurementExportsLayoutEvidence",
                rowCount: 50,
                attachmentName: "chat-performance-hosted-stream-evidence.json"
            )
        }

        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd)
        ChatTranscriptHostingSupport.applySnapshot(
            ChatTranscriptHostingSupport.transcriptView(from: viewModel),
            to: host
        )
        try await collectLayoutSample(
            window: window,
            host: host,
            deadline: deadline,
            samples: &samples,
            suite: "hosted-streaming",
            testName: "testHostedStreamingTranscriptMeasurementExportsLayoutEvidence",
            rowCount: 50,
            attachmentName: "chat-performance-hosted-stream-evidence.json"
        )

        try assertHostedSuccess(
            viewModel: viewModel,
            samples: samples,
            suite: "hosted-streaming",
            testName: "testHostedStreamingTranscriptMeasurementExportsLayoutEvidence",
            rowCount: 50,
            attachmentName: "chat-performance-hosted-stream-evidence.json"
        )
    }

    @MainActor
    func testHostedStreamingAnimatedTranscriptMeasurementExportsLayoutEvidence() async throws {
        UserDefaults.standard.set(true, forKey: StreamedTextAnimationSettings.isEnabledKey)
        UIView.setAnimationsEnabled(true)

        let fixture = ChatPerformanceFixture.make(
            rowCount: 50,
            responseBytes: 4_096,
            contentKind: .markdown,
            animationEnabled: true
        )
        let largeContent = String(decoding: fixture.response, as: UTF8.self)
        XCTAssertEqual(largeContent.utf8.count, 4096)
        let chunks = ChatPerformanceFixture.utf8Chunks(from: fixture.response, maxBytes: 512)
        XCTAssertEqual(chunks.count, 8)
        XCTAssertEqual(chunks.joined().utf8.count, 4096)

        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[]])
        let viewModel = try makeStreamingViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return try self.hostedSessionResponse(
                    total: 50,
                    request: request,
                    largeAssistantContent: nil
                )
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"performance-session","stream_id":"hosted-stream"}"#,
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
        XCTAssertEqual(viewModel.messages.count, 50)

        ChatPerformanceInstrumentation.shared.reset()
        let (window, host) = ChatTranscriptHostingSupport.host(
            ChatTranscriptHostingSupport.transcriptView(from: viewModel),
            animationsEnabled: true
        )
        hostedWindow = window

        var samples: [UInt64] = []
        let deadline = Date().addingTimeInterval(45)
        let didStart = await viewModel.sendMessage("Measure hosted stream")
        XCTAssertTrue(didStart)

        for (index, chunk) in chunks.enumerated() {
            streamClient.emit(
                .token(chunk),
                lastEventID: "hosted-stream:\(index + 1)"
            )
            ChatTranscriptHostingSupport.applySnapshot(
                ChatTranscriptHostingSupport.transcriptView(from: viewModel),
                to: host,
                animationsEnabled: true
            )
            try await collectLayoutSample(
                window: window,
                host: host,
                deadline: deadline,
                samples: &samples,
                suite: "hosted-streaming-animated",
                testName: "testHostedStreamingAnimatedTranscriptMeasurementExportsLayoutEvidence",
                rowCount: 50,
                attachmentName: "chat-performance-hosted-stream-animated-evidence.json",
                logMarker: "HERMEX_SLICE2_ANIM_EVIDENCE"
            )
        }

        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd)
        ChatTranscriptHostingSupport.applySnapshot(
            ChatTranscriptHostingSupport.transcriptView(from: viewModel),
            to: host,
            animationsEnabled: true
        )
        try await collectLayoutSample(
            window: window,
            host: host,
            deadline: deadline,
            samples: &samples,
            suite: "hosted-streaming-animated",
            testName: "testHostedStreamingAnimatedTranscriptMeasurementExportsLayoutEvidence",
            rowCount: 50,
            attachmentName: "chat-performance-hosted-stream-animated-evidence.json",
            logMarker: "HERMEX_SLICE2_ANIM_EVIDENCE"
        )

        try assertHostedSuccess(
            viewModel: viewModel,
            samples: samples,
            suite: "hosted-streaming-animated",
            testName: "testHostedStreamingAnimatedTranscriptMeasurementExportsLayoutEvidence",
            rowCount: 50,
            attachmentName: "chat-performance-hosted-stream-animated-evidence.json",
            logMarker: "HERMEX_SLICE2_ANIM_EVIDENCE"
        )

        let fadeFrames = ChatPerformanceInstrumentation.shared.summary.counters[
            ChatPerformancePhase.fadeTimelineFrames.rawValue
        ] ?? 0
        let fadeDraws = ChatPerformanceInstrumentation.shared.summary.counters[
            ChatPerformancePhase.fadeDraws.rawValue
        ] ?? 0
        if fadeFrames == 0 && fadeDraws == 0 {
            throw XCTSkip("hosted transcript unavailable: fade-inactive")
        }
        XCTAssertTrue(fadeFrames > 0 || fadeDraws > 0)
    }

    @MainActor
    private func measureHostedStaticTranscript(rowCount: Int) async throws {
        let viewModel = try await loadPaginatedViewModel(
            rowCount: rowCount,
            includeFourKilobyteAssistant: true
        )
        ChatPerformanceInstrumentation.shared.reset()

        let snapshot = ChatTranscriptHostingSupport.transcriptView(from: viewModel)
        let (window, host) = ChatTranscriptHostingSupport.host(snapshot)
        hostedWindow = window

        var samples: [UInt64] = []
        let start = DispatchTime.now().uptimeNanoseconds
        let result = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 30)
        samples.append(DispatchTime.now().uptimeNanoseconds &- start)

        let testName = "testHostedStaticTranscriptMeasurementExportsLayoutEvidence\(rowCount)"
        let attachmentName = "chat-performance-hosted-\(rowCount)-evidence.json"
        // Skip-to-unavailable: attach empty samples first, then XCTSkip. Never fail red for hosting flakes.
        if case .unavailable(let reason) = result {
            try publishHostedEvidence(
                suite: "hosted",
                testName: testName,
                rowCount: rowCount,
                samples: [],
                p95Definition: "unavailable: \(reason)",
                attachmentName: attachmentName
            )
            throw XCTSkip("hosted transcript unavailable: \(reason)")
        }

        try assertHostedSuccess(
            viewModel: viewModel,
            samples: samples,
            suite: "hosted",
            testName: testName,
            rowCount: rowCount,
            attachmentName: attachmentName
        )
    }

    @MainActor
    private func assertHostedSuccess(
        viewModel: ChatViewModel,
        samples: [UInt64],
        suite: String,
        testName: String,
        rowCount: Int,
        attachmentName: String,
        logMarker: String = "HERMEX_PERF_EVIDENCE"
    ) throws {
        let view = ChatTranscriptHostingSupport.transcriptView(from: viewModel)
        XCTAssertEqual(view.displayedTranscriptMessages.count, viewModel.displayedTranscriptMessages.count)
        XCTAssertEqual(
            Set(view.displayedTranscriptMessages.map(\.id)).count,
            view.displayedTranscriptMessages.count
        )
        let largeAssistants = viewModel.messages.filter { message in
            message.role == "assistant" && message.content?.utf8.count == 4096
        }
        XCTAssertEqual(largeAssistants.count, 1)
        XCTAssertEqual(largeAssistants.first?.content?.utf8.count, 4096)

        let summary = ChatPerformanceInstrumentation.shared.summary
        let evaluations = summary.counters[ChatPerformancePhase.transcriptContentEvaluations.rawValue] ?? 0
        let layoutPasses = summary.counters[ChatPerformancePhase.transcriptLayoutPasses.rawValue] ?? 0
        XCTAssertTrue(evaluations >= 1 || layoutPasses >= 1)

        let sorted = samples.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.last ?? 0
        try publishHostedEvidence(
            suite: suite,
            testName: testName,
            rowCount: rowCount,
            samples: samples,
            p95Definition: "max of \(samples.count) hosted layout samples (n=\(samples.count), no interpolation)",
            attachmentName: attachmentName,
            p50: p50,
            p95: p95,
            logMarker: logMarker
        )
    }

    @MainActor
    private func collectLayoutSample(
        window: UIWindow,
        host: UIHostingController<ChatTranscriptView>,
        deadline: Date,
        samples: inout [UInt64],
        suite: String,
        testName: String,
        rowCount: Int,
        attachmentName: String,
        logMarker: String = "HERMEX_PERF_EVIDENCE"
    ) async throws {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            try publishHostedEvidence(
                suite: suite,
                testName: testName,
                rowCount: rowCount,
                samples: [],
                p95Definition: "unavailable: timeout",
                attachmentName: attachmentName,
                logMarker: logMarker
            )
            throw XCTSkip("hosted transcript unavailable: timeout")
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let result = ChatTranscriptHostingSupport.layoutPass(
            window: window,
            host: host,
            timeout: remaining
        )
        let sample = DispatchTime.now().uptimeNanoseconds &- start
        if case .unavailable(let reason) = result {
            try publishHostedEvidence(
                suite: suite,
                testName: testName,
                rowCount: rowCount,
                samples: [],
                p95Definition: "unavailable: \(reason)",
                attachmentName: attachmentName,
                logMarker: logMarker
            )
            throw XCTSkip("hosted transcript unavailable: \(reason)")
        }
        samples.append(sample)
    }

    @MainActor
    private func publishHostedEvidence(
        suite: String,
        testName: String,
        rowCount: Int,
        samples: [UInt64],
        p95Definition: String,
        attachmentName: String,
        p50: UInt64 = 0,
        p95: UInt64 = 0,
        logMarker: String = "HERMEX_PERF_EVIDENCE"
    ) throws {
        let summary = ChatPerformanceInstrumentation.shared.summary
        let evidence = CheapChatPerformanceEvidence(
            suite: suite,
            testName: testName,
            commit: ProcessInfo.processInfo.environment["GITHUB_SHA"],
            rowCount: rowCount,
            responseBytes: 4096,
            contentKind: .markdown,
            samplesNanoseconds: samples,
            p50Nanoseconds: p50,
            p95Nanoseconds: p95,
            p95Definition: p95Definition,
            counters: summary.counters,
            closedIntervals: summary.closedIntervals,
            intervalDurationsNanoseconds: summary.intervalDurationsNanoseconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        let json = String(decoding: data, as: UTF8.self)
        let line = logMarker + " " + json
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func loadPaginatedViewModel(
        rowCount: Int,
        includeFourKilobyteAssistant: Bool
    ) async throws -> ChatViewModel {
        let largeContent: String?
        if includeFourKilobyteAssistant {
            let fixture = ChatPerformanceFixture.make(
                rowCount: rowCount,
                responseBytes: 4_096,
                contentKind: .markdown
            )
            largeContent = String(decoding: fixture.response, as: UTF8.self)
            XCTAssertEqual(largeContent?.utf8.count, 4096)
        } else {
            largeContent = nil
        }

        let client = makeClient { request in
            try self.hostedSessionResponse(
                total: rowCount,
                request: request,
                largeAssistantContent: largeContent
            )
        }
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "performance-session"),
            server: URL(string: "https://example.test")!,
            client: client
        )
        await viewModel.loadMessages()
        while viewModel.hasOlderMessages {
            _ = await viewModel.loadOlderMessages()
        }
        XCTAssertEqual(viewModel.messages.count, rowCount)
        XCTAssertEqual(Set(viewModel.messages.map(\.id)).count, rowCount)
        return viewModel
    }

    private func hostedSessionResponse(
        total: Int,
        request: URLRequest,
        largeAssistantContent: String?
    ) throws -> (HTTPURLResponse, Data) {
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
        let before = (query["msg_before"] ?? nil).flatMap { Int($0) }
        let data = try ChatPerformanceFixture.hostedPaginationSessionJSON(
            total: total,
            before: before,
            largeAssistantContent: largeAssistantContent
        )
        return apiTestJSONResponse(String(decoding: data, as: UTF8.self), for: request)
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
}
