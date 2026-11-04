import SwiftData
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
        // In PR CI SwiftUI sometimes never consults the rows' `.equatable()` (#1516), so
        // identical code fails one run and passes the next. Locally it is reliable.
        try XCTSkipIf(ProcessInfo.processInfo.environment["HERMEX_CI"] != nil,
                      "Local-only until #1516 makes the row skip deterministic")
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

/// What a test changes on a hosted transcript after it is on screen, and the
/// transcript's scroll proxy once `ChatTranscriptReflowTests.captureProxy` asks for it.
@Observable
@MainActor
private final class TranscriptHostControls {
    var dynamicTypeSize = DynamicTypeSize.large
    var proxy: ScrollViewProxy?
    var settledPlan: HermesPlan?
    var settledPlanAfterRenderID: String?
}

/// Hosts the real `ChatTranscriptView` with `ChatView`'s view-model wiring for every
/// input that changes as a reply streams. Follow, scroll, fold and action inputs are
/// fixed, so only the stream can move a row's inputs.
private struct BudgetTranscriptHost: View {
    /// Body passes since the test last cleared it.
    static var passes = 0

    let viewModel: ChatViewModel
    var controls = TranscriptHostControls()

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
            onScrollToBottom: { controls.proxy = $0 },
            onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, _ in },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _, _ in },
            onAskHermex: { _ in },
            onToggleListening: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in },
            settledPlan: controls.settledPlan,
            settledPlanAfterRenderID: controls.settledPlanAfterRenderID
        )
        .environment(\.dynamicTypeSize, controls.dynamicTypeSize)
    }
}

/// `HermesServerHome`'s width branches around the real list, which owns the split at regular
/// width and pushes its chat in this stack at compact width.
private struct WidthCrossingHome: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let list: HermesSessionListView

    var body: some View {
        if horizontalSizeClass == .regular { list } else { NavigationStack { list } }
    }
}

/// A reader parked inside a long reply keeps their place when the column rewraps
/// (#1414): rotation and a text-size change move every row above them, and a raw
/// offset would land them screens away. A reader on a block between rows (a plan)
/// keeps that block. Frames are measured independently of the controller, by
/// scrolling each block to the top through the transcript's proxy.
@MainActor
final class ChatTranscriptReflowTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRewrapKeepsTheReaderAtTheSameShareOfTheirRow() async throws {
        let viewModel = try makeViewModel(turns: 20)
        await viewModel.loadMessages()
        let rows = viewModel.displayedTranscriptMessages.map(\.renderID)
        XCTAssertEqual(rows.count, 40)
        let controls = TranscriptHostControls()
        controls.settledPlan = HermesPlan(.object(["todos": .array([
            .object(["id": .string("a"), "content": .string("Read the replies"), "status": .string("in_progress")])
        ])]))
        controls.settledPlanAfterRenderID = rows[25]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: BudgetTranscriptHost(viewModel: viewModel, controls: controls))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await layOut(window)

        // The transcript hands its proxy to onScrollToBottom when the keyboard shows.
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        await layOut(window)
        let proxy = try XCTUnwrap(controls.proxy)
        let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
        /// The span of the block `id`, bounded by the top of the row after it.
        func span(of id: String, before next: String) async -> (top: CGFloat, height: CGFloat) {
            proxy.scrollTo(next, anchor: .top)
            await layOut(window)
            let nextTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            proxy.scrollTo(id, anchor: .top)
            await layOut(window)
            let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            return (top, nextTop - top - 8)
        }
        /// Parks the reading line 40% into the block `id`, applies `rewrap`, and
        /// returns the share of the rewrapped block above the line.
        func shareAfter(in id: String, before next: String, _ rewrap: () -> Void) async -> CGFloat {
            let parked = await span(of: id, before: next)
            scrollView.setContentOffset(
                CGPoint(x: 0, y: parked.top + 0.4 * parked.height - scrollView.adjustedContentInset.top),
                animated: false
            )
            await layOut(window)
            rewrap()
            await layOut(window)
            let readingLine = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let rewrapped = await span(of: id, before: next)
            return (readingLine - rewrapped.top) / rewrapped.height
        }

        // A long reply halfway up, bounded by the row after it.
        let rotated = await shareAfter(in: rows[21], before: rows[22]) { window.frame = CGRect(x: 0, y: 0, width: 844, height: 390) }
        XCTAssertEqual(rotated, 0.4, accuracy: 0.02, "Rotation moved the reader off their passage")
        let largerText = await shareAfter(in: rows[21], before: rows[22]) { controls.dynamicTypeSize = .xxxLarge }
        XCTAssertEqual(largerText, 0.4, accuracy: 0.02, "A text-size change moved the reader off their passage")
        let onPlan = await shareAfter(in: "hermes-plan", before: rows[26]) { window.frame = CGRect(x: 0, y: 0, width: 390, height: 844) }
        XCTAssertEqual(onPlan, 0.4, accuracy: 0.02, "Rotation moved the reader off the plan they were reading")
    }

    /// A forced-LTR code block must not stretch an RTL reply past its column (#1068):
    /// the prose around it would land off-screen, leaving only the middle of the row.
    func testRightToLeftReplyWithCodeStaysOnScreen() async throws {
        let viewModel = try makeViewModel(turns: 1, reply: "שלום עולם\\n\\n```\\nls -la\\n```\\n\\nעוד טקסט")
        await viewModel.loadMessages()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(
            rootView: BudgetTranscriptHost(viewModel: viewModel).environment(\.layoutDirection, .rightToLeft)
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await layOut(window)

        func replies(in view: UIView) -> [UIView] {
            (view is ResponseSelectionInput ? [view] : []) + view.subviews.flatMap(replies(in:))
        }
        let reply = try XCTUnwrap(replies(in: window).first)
        let frame = reply.convert(reply.bounds, to: window)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, window.bounds.width)
    }

    /// Narrow forced-LTR content (an image thumbnail) still starts at the RTL column's
    /// leading edge, on the right.
    func testNarrowForcedLeftToRightContentHugsTheRightToLeftLeadingEdge() async throws {
        var frame = CGRect.null
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: VStack(alignment: .leading) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            Color.clear.frame(width: 100, height: 10)
                .forcedLeftToRight()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        }
        .environment(\.layoutDirection, .rightToLeft))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await layOut(window)

        XCTAssertEqual(frame.maxX, window.bounds.width, accuracy: 0.5)
    }

    /// An iPad window crossing compact and regular width rebuilds the open chat in the other
    /// navigation branch (#1528). The reader keeps the model, so the history they loaded, and the
    /// passage they were reading, there and back.
    func testCrossingTheWidthClassKeepsTheModelAndTheReadersPlace() async throws {
        let model = try makeViewModel(turns: 20)
        await model.loadMessages()
        model.followLatch.isFollowing = false
        let loaded = model.messages.count
        let hosted = try hostHermesHome(openChatOn: model)
        let window = hosted.window
        defer { window.isHidden = true; window.rootViewController = nil }

        try await parkReader(in: window, onReply: "Answer 12.")
        for (width, sizeClass) in [(CGFloat(932), UIUserInterfaceSizeClass.regular), (430, .compact)] {
            window.traitOverrides.horizontalSizeClass = sizeClass
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            await settle(window) { self.replyAtReadingLine(in: window)?.hasPrefix("Answer 12.") == true }
            XCTAssertEqual(replyAtReadingLine(in: window)?.hasPrefix("Answer 12."), true, "\(sizeClass) moved the reader")
            XCTAssertTrue(hosted.continuity.model === model, "The rebuilt chat made a new model")
            XCTAssertEqual(model.messages.count, loaded, "Crossing the width class dropped loaded history")
            XCTAssertFalse(model.followLatch.isFollowing, "The rebuilt transcript's bottom re-armed follow")
        }
    }

    /// A reader following the live edge is still there after the rebuild.
    func testCrossingTheWidthClassKeepsAFollowerAtTheBottom() async throws {
        let model = try makeViewModel(turns: 20)
        await model.loadMessages()
        let hosted = try hostHermesHome(openChatOn: model)
        let window = hosted.window
        defer { window.isHidden = true; window.rootViewController = nil }
        await settle(window) { self.transcriptScrollView(in: window) != nil }

        window.traitOverrides.horizontalSizeClass = .regular
        window.frame = CGRect(x: 0, y: 0, width: 932, height: 844)
        await settle(window) { self.replyAtReadingLine(in: window)?.hasPrefix("Answer 19.") == true }

        XCTAssertTrue(model.followLatch.isFollowing)
        let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
        let bottomOffset = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        XCTAssertEqual(scrollView.contentOffset.y, bottomOffset, accuracy: 2, "The follower left the live edge")
    }

    /// A split view can build a `ChatView` that appears and leaves while another stays on screen.
    /// The model's stream stops only when the last one leaves, in either order of a swap.
    func testOnlyTheLastViewOnScreenStopsTheChat() throws {
        let model = try makeViewModel(turns: 1)
        let continuity = ChatContinuity()
        let onScreen = UUID(), extra = UUID(), successor = UUID()

        continuity.viewAppeared(onScreen, model: model) { _, _ in }
        continuity.viewAppeared(extra, model: model) { _, _ in }
        XCTAssertFalse(continuity.viewDisappeared(extra), "An extra view leaving stopped the chat under the one on screen")

        // The new view appeared first: the old one leaves it running.
        continuity.viewAppeared(successor, model: model) { _, _ in }
        XCTAssertFalse(continuity.viewDisappeared(onScreen))
        // The chat really closes.
        XCTAssertTrue(continuity.viewDisappeared(successor))
    }

    /// A waiting send that comes back must reach a composer on screen, not the extra view's: its
    /// text would be lost to the screen, and the visible composer's next edit overwrites the draft.
    func testAReturnedWaitingSendReachesTheViewThatStays() throws {
        let model = try makeViewModel(turns: 1)
        let continuity = ChatContinuity()
        let onScreen = UUID(), extra = UUID()
        var reached: [UUID] = []

        continuity.viewAppeared(onScreen, model: model) { _, _ in reached.append(onScreen) }
        continuity.viewAppeared(extra, model: model) { _, _ in reached.append(extra) }
        _ = continuity.viewDisappeared(extra)
        model.onWaitingSendReturned?("Text", .cancelled)

        XCTAssertEqual(reached, [onScreen])
    }

    // MARK: - Helpers

    /// The real Hermes home list, in the branches `HermesServerHome` swaps by width, with a chat
    /// open on `model` as if its view had already appeared and loaded.
    private func hostHermesHome(openChatOn model: ChatViewModel) throws -> (window: UIWindow, continuity: ChatContinuity) {
        let server = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))
        let connection = BotConnection(id: UUID(), name: "Width test", address: server, username: "fixture", password: "fixture-only")
        let entry = HermesSessionListEntry(server: server, connection: connection, profile: "default")
        let wire = HermesSessionListWire()
        let list = SessionListViewModel(server: server, hermes: HermesSessionListSource(
            connection: connection, profile: "default", makeWire: { _ in wire }))
        let navigation = HermesSessionListNavigation()
        navigation.covers.chat = HermesSessionChat(server: server, connection: connection, target: .session(profile: "default", key: "session-abc"))
        let continuity = navigation.covers.chatContinuity
        continuity.viewAppeared(UUID(), model: model) { _, _ in }
        continuity.didLoadMessages = true
        let avatar = SessionsHeader.Avatar(initials: "QA", color: .blue, foreground: .white,
            servers: .init(servers: [], activeServerID: nil), openSettings: {},
            switchToServer: { _ in }, addServer: {}, manageServers: {})
        let home = HermesHome(title: "Width test", avatar: avatar, tab: .constant(.sessions))
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let auth = AuthManager(keychain: InMemoryKeychainStore(), serverRegistry: .inMemory(),
                               hermesConnections: HermesConnections(keychain: InMemoryKeychainStore()))
        let root = WidthCrossingHome(list: HermesSessionListView(entry: entry, model: list, home: home, navigation: navigation))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.traitOverrides.horizontalSizeClass = .compact
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 844)
        window.rootViewController = UIHostingController(rootView: root.modelContainer(container).environment(auth))
        window.makeKeyAndVisible()
        return (window, continuity)
    }

    /// Parks the transcript's reading line inside the reply starting `prefix`.
    private func parkReader(in window: UIWindow, onReply prefix: String) async throws {
        await settle(window) { self.reply(startingWith: prefix, in: window) != nil }
        let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
        let reply = try XCTUnwrap(reply(startingWith: prefix, in: window))
        let frame = reply.convert(reply.bounds, to: scrollView)
        scrollView.setContentOffset(
            CGPoint(x: 0, y: frame.minY + 0.4 * frame.height - scrollView.adjustedContentInset.top),
            animated: false
        )
        await settle(window) { self.replyAtReadingLine(in: window)?.hasPrefix(prefix) == true }
    }

    private func replies(in view: UIView) -> [ResponseSelectionInput] {
        [view as? ResponseSelectionInput].compactMap { $0 } + view.subviews.flatMap(replies(in:))
    }

    private func text(of reply: ResponseSelectionInput) -> String? {
        reply.textRange(from: reply.beginningOfDocument, to: reply.endOfDocument).flatMap(reply.text(in:))
    }

    private func reply(startingWith prefix: String, in window: UIWindow) -> ResponseSelectionInput? {
        replies(in: window).first { text(of: $0)?.hasPrefix(prefix) == true }
    }

    /// The text of the reply under the top of the transcript's visible area.
    private func replyAtReadingLine(in window: UIWindow) -> String? {
        guard let scrollView = transcriptScrollView(in: window) else { return nil }
        let line = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        return replies(in: scrollView)
            .first { let frame = $0.convert($0.bounds, to: scrollView); return frame.minY <= line && line <= frame.maxY }
            .flatMap(text(of:))
    }

    /// Runs the main queue until `condition` holds. The bound only fails a broken test faster;
    /// navigation lands over several turns.
    private func settle(_ window: UIWindow, until condition: @escaping @MainActor () -> Bool) async {
        let landed = expectation(description: "layout landed")
        @MainActor func check(_ remaining: Int) {
            window.layoutIfNeeded()
            if condition() || remaining == 0 { landed.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { check(remaining - 1) } }
        }
        check(250)
        await fulfillment(of: [landed], timeout: 10)
    }

    /// Lets SwiftUI apply pending updates, then lays the window out.
    private func layOut(_ window: UIWindow) async {
        for _ in 0..<3 {
            await Task.yield()
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
        }
    }

    /// The tallest scroll view in the window: the transcript, not a row's own.
    private func transcriptScrollView(in window: UIWindow) -> UIScrollView? {
        func scrollViews(in view: UIView) -> [UIScrollView] {
            [view as? UIScrollView].compactMap { $0 } + view.subviews.flatMap(scrollViews(in:))
        }
        return scrollViews(in: window).max { $0.contentSize.height < $1.contentSize.height }
    }

    /// A webui session of `turns` short prompts, each answered by a five-paragraph
    /// reply that wraps very differently at phone width and at the capped column.
    private func makeViewModel(turns count: Int, reply customReply: String? = nil) throws -> ChatViewModel {
        let paragraph = "This settled reply wraps across many lines at phone width and far fewer at the capped reading width, so a rewrap changes every row height above the reader."
        let reply = customReply ?? (0..<5).map { "Paragraph \($0). " + paragraph }.joined(separator: "\\n\\n")
        let turns = (0..<count).map { index in
            """
            {"role": "user", "content": "Question \(index)", "timestamp": \(1_770_000_000 + index * 10), "message_id": "user-\(index)"},
            {"role": "assistant", "content": "Answer \(index). \(reply)", "timestamp": \(1_770_000_005 + index * 10), "message_id": "assistant-\(index)"}
            """
        }
        let session = #"{"session": {"session_id": "session-abc", "title": "Reflow", "messages": ["#
            + turns.joined(separator: ",") + "]}}"
        MockURLProtocol.requestHandler = { request in apiTestJSONResponse(session, for: request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        return ChatViewModel(
            session: SessionSummary(sessionId: "session-abc", title: "Reflow", workspace: "/tmp/workspace"),
            server: server,
            client: APIClient(baseURL: server, session: URLSession(configuration: configuration)),
            streamClient: PacingSpySSEStreamingClient(),
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient()
        )
    }
}
