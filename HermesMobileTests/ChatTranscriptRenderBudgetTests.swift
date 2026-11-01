import SwiftUI
import XCTest
@testable import HermesMobile

/// The streaming transcript's render budget: once a reply is streaming, a text-only
/// reveal tick re-renders the streaming row and none of the settled rows above it.
/// Settled rows skip their bodies through `ChatTranscriptMessageBlock`'s `.equatable()`;
/// a new non-`Equatable` input, or a value handed to every row, breaks that and makes
/// every row re-render per tick. Counts come from `RenderProbe`. Ticks are driven by
/// hand and each one is laid out before the next; nothing sleeps.
@MainActor
final class ChatTranscriptRenderBudgetTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTextOnlyTicksReRenderOnlyTheStreamingRow() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let ticks = ManualRevealTicks()
        let viewModel = try makeViewModel(settledReplies: 20, streamClient: streamClient, revealTick: ticks.tick)
        await viewModel.loadMessages()
        let settledRenderIDs = viewModel.displayedTranscriptMessages.map(\.renderID)
        XCTAssertEqual(settledRenderIDs.count, 40, "Each settled turn must show its prompt and reply")

        // Start with nothing focused: a text view an earlier test left focused keeps the keyboard up.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let window = host(BudgetTranscriptHost(viewModel: viewModel))
        defer { window.isHidden = true; window.rootViewController = nil }

        // Stream start adds the prompt and reply rows and may re-render every row;
        // it is outside the budget, so the window opens after the first tick lays out.
        let didStart = await viewModel.sendMessage("Stream a long reply")
        XCTAssertTrue(didStart)
        try await revealTick(1, text: "word1 ", streamClient: streamClient, ticks: ticks, viewModel: viewModel, window: window)
        let streamingRenderID = try XCTUnwrap(
            viewModel.displayedTranscriptMessages.last { $0.message.messageId == viewModel.streamingAssistantMessageID }?.renderID
        )
        RenderProbe.reset()
        BudgetTranscriptHost.passes = 0

        for tick in 2...31 {
            try await revealTick(tick, text: "word\(tick) ", streamClient: streamClient, ticks: ticks, viewModel: viewModel, window: window)
        }

        let streamingEvaluations = RenderProbe.count(renderID: streamingRenderID)
        XCTAssertGreaterThan(streamingEvaluations, 0, "The streaming row must render, or the budget proves nothing")
        let settledEvaluations = settledRenderIDs.reduce(0) { $0 + RenderProbe.count(renderID: $1) }
        let settledRowsRendered = settledRenderIDs.filter { RenderProbe.count(renderID: $0) > 0 }.count
        // Where a failure comes from. A passing run here compares each row a few times
        // per tick, and the streaming row's comparisons find its change. No comparisons
        // means SwiftUI never consulted `==`; comparisons without unequal ones mean a
        // settled row re-ran on a dependency of its own. Host passes count the ticks
        // that reached the transcript through its parent.
        XCTAssertEqual(
            settledEvaluations, 0,
            "Text-only ticks re-rendered \(settledRowsRendered) of \(settledRenderIDs.count) settled rows "
                + "(streaming row: \(streamingEvaluations), host passes: \(BudgetTranscriptHost.passes)); "
                + "row comparisons: \(RenderProbe.count(.transcriptMessageBlockCompared)), "
                + "unequal: \(RenderProbe.count(.transcriptMessageBlockUnequal))"
        )
    }

    // MARK: - Helpers

    /// Emits `text`, releases reveal tick `number`, waits until the reply shows the
    /// text, and lays the window out so SwiftUI renders that tick.
    private func revealTick(
        _ number: Int,
        text: String,
        streamClient: PacingSpySSEStreamingClient,
        ticks: ManualRevealTicks,
        viewModel: ChatViewModel,
        window: UIWindow
    ) async throws {
        streamClient.emit(.token(text))
        let requested = ticks.expectRequest(number)
        guard await XCTWaiter().fulfillment(of: [requested], timeout: 5) == .completed else {
            return XCTFail("Reveal tick \(number) was never requested")
        }
        ticks.fire()
        let returned = ticks.expectReturn(number)
        guard await XCTWaiter().fulfillment(of: [returned], timeout: 5) == .completed else {
            return XCTFail("Reveal tick \(number) never returned")
        }
        let reply = try XCTUnwrap(viewModel.messages.last { $0.role == "assistant" }?.content)
        XCTAssertTrue(reply.hasSuffix(text), "Tick \(number) must reveal its text")
        window.rootViewController?.view.setNeedsLayout()
        window.layoutIfNeeded()
    }

    /// Hosts `view` in a window on the test host's scene, like the app's own windows.
    private func host(_ view: some View) -> UIWindow {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// A webui session whose load returns `settledReplies` settled prompt/reply turns.
    private func makeViewModel(
        settledReplies: Int,
        streamClient: PacingSpySSEStreamingClient,
        revealTick: @escaping @Sendable () async throws -> Void
    ) throws -> ChatViewModel {
        let turns = (0..<settledReplies).map { index in
            """
            {"role": "user", "content": "Question \(index)", "timestamp": \(1_770_000_000 + index * 10), "message_id": "user-\(index)"},
            {"role": "assistant", "content": "## Answer \(index)\\n\\nSettled **markdown** with `code` and a list:\\n\\n- one\\n- two", "timestamp": \(1_770_000_005 + index * 10), "message_id": "assistant-\(index)"}
            """
        }
        let session = #"{"session": {"session_id": "session-abc", "title": "Budget", "messages": ["#
            + turns.joined(separator: ",") + "]}}"
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
            default:
                return apiTestJSONResponse(session, for: request)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        return ChatViewModel(
            session: SessionSummary(sessionId: "session-abc", title: "Budget", workspace: "/tmp/workspace"),
            server: server,
            client: APIClient(baseURL: server, session: URLSession(configuration: configuration)),
            streamClient: streamClient,
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient(),
            streamingScrollCoalescingDelayNanoseconds: 1_000_000,
            streamingRevealTick: revealTick
        )
    }
}

/// Hosts the real `ChatTranscriptView` with `ChatView`'s view-model wiring for every
/// input that changes as a reply streams. Follow, scroll, fold and action inputs are
/// fixed, so only the stream can move a row's inputs.
private struct BudgetTranscriptHost: View {
    /// Body passes since the test last cleared it.
    static var passes = 0

    let viewModel: ChatViewModel

    var body: some View {
        let _ = Self.passes += 1
        let transcript = viewModel.displayedTranscriptMessages
        ChatTranscriptView(
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            messages: viewModel.messages,
            displayedTranscriptMessages: transcript,
            compressionReferenceCard: viewModel.compressionReferenceCard,
            reasoningGroupsByAnchorID: viewModel.reasoningGroupsByAnchorID,
            completedToolCallGroupsForAnchor: { viewModel.completedToolCallGroupsForAnchor($0) },
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
            showsThinkingAndToolCards: true,
            workingRowStartedAt: nil,
            requestWithdrawal: nil,
            showsScrollToBottomButton: false,
            shouldFollowLatestMessage: false,
            isDisclosureSettling: false,
            latestTranscriptMessageRole: transcript.last?.message.role,
            isScrolledNearBottom: true,
            activeStreamID: viewModel.activeStreamID,
            streamingScrollTrigger: { viewModel.streamingScrollTrigger },
            transcriptRelayoutScrollToken: viewModel.transcriptRelayoutScrollToken,
            completedResponseRenderID: nil,
            bottomAnchorID: "bottom",
            transcriptSpacing: 8,
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
            transcriptMediaCacheNamespace: "render-budget",
            actionContext: { viewModel.actionContext(for: $0, visibleIndex: $1) },
            shouldRenderMessageRow: { $0.content?.isEmpty == false },
            onLoadMessages: {},
            onLoadOlderMessages: { false },
            onUpdateScrollMetrics: { _ in },
            onFollowEvent: { _ in },
            onDisclosureToggle: {},
            turnFolds: .none,
            terminalReplyRenderIDs: TranscriptMessageMetaPolicy.terminalReplyRenderIDs(
                transcriptMessages: transcript,
                messages: viewModel.messages,
                messageOffset: viewModel.messagesOffset,
                rendersBubble: { $0.content?.isEmpty == false },
                isStreamActive: viewModel.activeStreamID != nil,
                streamingAssistantMessageID: viewModel.streamingAssistantMessageID
            ),
            expandedTurnKeys: [],
            onToggleTurnFold: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { _ in },
            onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, _ in },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _, _ in },
            onAskHermex: { _ in },
            onToggleListening: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in }
        )
    }
}
