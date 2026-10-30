import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// The render budget for #1405: during a stream, only the active reply's bodies
/// re-evaluate per reveal tick. The transcript's `.equatable()` rows promise
/// that settled markdown rows skip every tick; `RenderProbe` counts the bodies
/// themselves, so a new non-`Equatable` input fails here before a long chat
/// janks. Ticks are driven by hand through the pacing seams; nothing sleeps.
@MainActor
final class ChatTranscriptRenderBudgetTests: XCTestCase {
    private static let settledReplyCount = 20
    private static let tickCount = 30

    override func tearDown() {
        RenderProbe.reset()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRenderProbeCountsNamesRenderIDsAndResets() {
        RenderProbe.reset()

        RenderProbe.hit("TestBody")
        RenderProbe.hit("TestBody")
        RenderProbe.hit("TestBody", renderID: "row-a")
        RenderProbe.hit("TestBody", renderID: "row-a")
        RenderProbe.hit("TestBody", renderID: "row-b")

        XCTAssertEqual(RenderProbe.count("TestBody"), 5)
        XCTAssertEqual(RenderProbe.count("TestBody", renderID: "row-a"), 2)
        XCTAssertEqual(RenderProbe.count("TestBody", renderID: "row-b"), 1)
        XCTAssertEqual(RenderProbe.count("TestBody", renderID: "row-c"), 0)

        RenderProbe.reset()
        XCTAssertEqual(RenderProbe.count("TestBody"), 0)
        XCTAssertEqual(RenderProbe.count("TestBody", renderID: "row-a"), 0)
    }

    func testTextOnlyTicksReEvaluateOnlyTheActiveRow() async throws {
        RenderProbe.reset()
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(streamClient: streamClient, revealTick: ticks.tick)

        // Settle twenty text-only turns before the window opens.
        for index in 1...Self.settledReplyCount {
            try await settleTurn(
                "Settled reply \(index).\n\nA paragraph with **bold** and `code` \(index). ",
                turn: "Turn \(index)",
                viewModel: viewModel,
                streamClient: streamClient,
                ticks: ticks
            )
        }
        let settledRenderIDs = viewModel.displayedTranscriptMessages.map(\.renderID)
        XCTAssertEqual(settledRenderIDs.count, Self.settledReplyCount * 2, "each turn is a prompt row and a reply row")

        let window = try hostTranscript(viewModel: viewModel, workspace: "/tmp/workspace")
        defer { window.isHidden = true; window.rootViewController = nil }

        // Layout settles the first evaluation of every row.
        for _ in 0..<5 {
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
        }

        // Open the stream and let its start invalidation (hasActiveStream flips
        // for every row) consume its one re-evaluation before the budget window.
        let didStart = await viewModel.sendMessage("Turn \(Self.settledReplyCount + 1)")
        XCTAssertTrue(didStart)
        await waitForStreamActive(viewModel)
        streamClient.emit(.token("Streaming reply one "))
        await waitForTickRequest(ticks, 1)
        ticks.fire()
        await waitForTickReturn(ticks, 1)
        flushLayout(window)

        // The budget window: only reveal ticks from here on.
        RenderProbe.reset()
        for tick in 2...(Self.tickCount + 1) {
            streamClient.emit(.token("word \(tick) "))
            await waitForTickRequest(ticks, tick)
            ticks.fire()
            await waitForTickReturn(ticks, tick)
            flushLayout(window)
        }

        let streamingMessageID = try XCTUnwrap(viewModel.streamingAssistantMessageID)
        let activeRenderID = try XCTUnwrap(
            viewModel.displayedTranscriptMessages
                .first { $0.message.messageId == streamingMessageID }?.renderID,
            "the streaming reply must be on screen for this to test anything"
        )

        // Not vacuous: the active row is evaluated, and its markdown and host
        // update with it.
        XCTAssertGreaterThan(
            RenderProbe.count("ChatTranscriptMessageBlock", renderID: activeRenderID),
            0,
            "the active row must re-evaluate per tick for this test to mean anything"
        )
        XCTAssertGreaterThan(RenderProbe.count("MarkdownRenderer"), 0)
        XCTAssertGreaterThan(
            RenderProbe.count("ResponseTextSelection"),
            0,
            "the active reply's selection host must update per tick for this test to mean anything"
        )

        // The budget: zero settled-row evaluations across the whole window.
        for renderID in settledRenderIDs where renderID != activeRenderID {
            XCTAssertEqual(
                RenderProbe.count("ChatTranscriptMessageBlock", renderID: renderID),
                0,
                "settled row \(renderID) re-evaluated during the stream"
            )
            XCTAssertEqual(
                RenderProbe.count("MessageBubbleView", renderID: renderID),
                0,
                "settled row \(renderID)'s bubble re-evaluated during the stream"
            )
        }
    }

    // MARK: - Helpers

    /// One scripted turn, end to end: a prompt, one streamed reply, done.
    private func settleTurn(
        _ reply: String,
        turn: String,
        viewModel: ChatViewModel,
        streamClient: PacingSpySSEStreamingClient,
        ticks: ManualRevealTicks
    ) async throws {
        let didStart = await viewModel.sendMessage(turn)
        XCTAssertTrue(didStart)

        streamClient.emit(.token(reply))
        await waitForTickRequest(ticks, ticks.requestCount + 1)
        ticks.fire()
        await waitForTickReturn(ticks, ticks.requestCount)

        streamClient.emit(.done(DoneStreamEvent()))
        let target = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await nextAssistantContent(of: viewModel) { $0.contains(target) }
    }

    private func makeViewModel(
        streamClient: PacingSpySSEStreamingClient,
        revealTick: @escaping @Sendable () async throws -> Void
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            default:
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Render budget", "messages": []}}"#,
                    for: request
                )
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(
                #"{"session_id": "session-abc", "title": "Render budget", "workspace": "/tmp/workspace"}"#.utf8
            )
        )

        return ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient(),
            streamingScrollCoalescingDelayNanoseconds: 1_000_000,
            streamingRevealTick: revealTick
        )
    }

    /// Hosts the real `ChatTranscriptView` over the scripted view model, the way
    /// `ChatView` builds it: the view model's values, inert actions.
    private func hostTranscript(viewModel: ChatViewModel, workspace: String) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(
            rootView: RenderBudgetTranscriptHost(viewModel: viewModel)
                .environment(\.chatWorkspaceRoot, workspace)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// Forces pending SwiftUI updates synchronously; never sleeps.
    private func flushLayout(_ window: UIWindow) {
        window.rootViewController?.view.setNeedsLayout()
        window.layoutIfNeeded()
    }

    private func waitForStreamActive(_ viewModel: ChatViewModel) async {
        while viewModel.activeStreamID == nil {
            let changed = XCTestExpectation(description: "stream became active")
            withObservationTracking { _ = viewModel.activeStreamID } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 5) == .completed else {
                XCTFail("The stream never became active")
                return
            }
        }
    }

    private func waitForTickRequest(
        _ ticks: ManualRevealTicks,
        _ number: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let requested = ticks.expectRequest(number)
        guard await XCTWaiter().fulfillment(of: [requested], timeout: 5) == .completed else {
            return XCTFail("Reveal tick \(number) was never requested", file: file, line: line)
        }
    }

    private func waitForTickReturn(
        _ ticks: ManualRevealTicks,
        _ number: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let returned = ticks.expectReturn(number)
        guard await XCTWaiter().fulfillment(of: [returned], timeout: 5) == .completed else {
            return XCTFail("Reveal tick \(number) never returned", file: file, line: line)
        }
    }

    /// Waits on observation, not a poll, for the last assistant content
    /// matching `predicate`, and returns it.
    private func nextAssistantContent(
        of viewModel: ChatViewModel,
        where predicate: (String) -> Bool
    ) async -> String? {
        while true {
            if let content = viewModel.messages.last(where: { $0.role == "assistant" })?.content,
               predicate(content) {
                return content
            }
            let changed = XCTestExpectation(description: "assistant content changed")
            withObservationTracking { _ = viewModel.messages } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 5) == .completed else {
                XCTFail("Assistant content never matched")
                return viewModel.messages.last(where: { $0.role == "assistant" })?.content
            }
        }
    }
}

/// Mirrors `ChatView.messageContent`: the transcript over the scripted view
/// model, with every action inert. Reading the view model here is what carries
/// each reveal tick's mutation into the transcript.
@MainActor
private struct RenderBudgetTranscriptHost: View {
    let viewModel: ChatViewModel

    var body: some View {
        ChatTranscriptView(
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            messages: viewModel.messages,
            displayedTranscriptMessages: viewModel.displayedTranscriptMessages,
            compressionReferenceCard: viewModel.compressionReferenceCard,
            reasoningGroupsByAnchorID: viewModel.reasoningGroupsByAnchorID,
            completedToolCallGroupsForAnchor: { anchorMessageID in
                viewModel.completedToolCallGroupsForAnchor(anchorMessageID)
            },
            liveReasoningText: viewModel.liveReasoningText,
            reasoningAnchorMessageID: viewModel.reasoningAnchorMessageID,
            liveToolCalls: viewModel.liveToolCalls,
            isReplayingLiveToolCalls: viewModel.isActiveStreamReplayConnection,
            toolCallAnchorMessageID: viewModel.toolCallAnchorMessageID,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID,
            liveTokensPerSecond: viewModel.liveTokensPerSecond,
            activeStreamRecoveryState: viewModel.activeStreamRecoveryState,
            clarificationPromptID: nil,
            hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: false,
            workingRowStartedAt: nil,
            requestWithdrawal: nil,
            showsScrollToBottomButton: false,
            shouldFollowLatestMessage: true,
            isDisclosureSettling: false,
            latestTranscriptMessageRole: viewModel.messages.last?.role,
            isScrolledNearBottom: true,
            activeStreamID: viewModel.activeStreamID,
            streamingScrollTrigger: { viewModel.streamingScrollTrigger },
            transcriptRelayoutScrollToken: viewModel.transcriptRelayoutScrollToken,
            completedResponseRenderID: nil,
            bottomAnchorID: "render-budget-bottom",
            transcriptSpacing: 14,
            transcriptBottomInsetHeight: 0,
            scrollToBottomButtonBottomPadding: 0,
            localAttachmentPreviews: viewModel.localAttachmentPreviews,
            listeningMessageID: viewModel.listeningMessageID,
            isViewingCachedData: viewModel.isViewingCachedData,
            hasOlderMessages: viewModel.hasOlderMessages,
            isLoadingOlderMessages: viewModel.isLoadingOlderMessages,
            isRegeneratingMessage: viewModel.isRegeneratingMessage,
            isEditingMessage: viewModel.isEditingMessage,
            isForkingMessage: viewModel.isForkingMessage,
            loadAttachmentImage: { _ in nil },
            attachmentAudio: nil,
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "render-budget.test",
            actionContext: { _, _ in nil },
            shouldRenderMessageRow: { _ in true },
            onLoadMessages: {},
            onLoadOlderMessages: { false },
            onUpdateScrollMetrics: { _ in },
            onFollowEvent: { _ in },
            onDisclosureToggle: {},
            turnFolds: .none,
            terminalReplyRenderIDs: [],
            expandedTurnKeys: [],
            onToggleTurnFold: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { _ in },
            onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, _ in },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onAskHermex: { _ in },
            onToggleListening: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in }
        )
    }
}
