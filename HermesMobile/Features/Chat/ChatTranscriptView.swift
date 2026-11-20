import SwiftUI
import UIKit

enum ChatReadingWidth {
    static let maximum: CGFloat = 768

    static func contentWidth(viewportWidth: CGFloat, horizontalPadding: CGFloat) -> CGFloat {
        min(max(0, viewportWidth - 2 * horizontalPadding), maximum)
    }

    static func maximumWidth(horizontalPadding: CGFloat) -> CGFloat {
        maximum + 2 * horizontalPadding
    }
}

struct ChatTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrollPositionController = ChatScrollPositionController()
    @State private var recoveryChip = DelayedStatusDriver<ActiveStreamRecoveryState>()

    let isLoading: Bool
    let errorMessage: String?
    var errorMayRetry = true
    var errorHostReason: String?
    var onServeEveryProfile: (() -> Void)?
    let messages: [ChatMessage]
    let displayedTranscriptMessages: [TranscriptMessage]
    let compressionReferenceCard: CompressionReferenceCard?
    let reasoningGroupsByAnchorID: [String?: [ReasoningGroup]]
    let completedToolCallGroupsForAnchor: (String?) -> [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveToolCalls: [ToolCall]
    let isReplayingLiveToolCalls: Bool
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let activeStreamRecoveryState: ActiveStreamRecoveryState
    let clarificationPromptID: String?
    let hidesRunStatusAccessibility: Bool
    let showsThinkingAndToolCards: Bool
    let workingRowStartedAt: Date?
    let isCompacting: Bool
    let requestWithdrawal: BotRequestWithdrawal?
    let showsScrollToBottomButton: Bool
    let shouldFollowLatestMessage: Bool
    let isDisclosureSettling: Bool
    let latestTranscriptMessageRole: String?
    let isScrolledNearBottom: Bool
    let activeStreamID: String?
    let streamingScrollTrigger: () -> Int
    let transcriptRelayoutScrollToken: Int
    let completedResponseRenderID: String?
    let bottomAnchorID: String
    let transcriptSpacing: CGFloat
    let transcriptBottomInsetHeight: CGFloat
    let scrollToBottomButtonBottomPadding: CGFloat
    let localAttachmentPreviews: [String: [String: Data]]
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasOlderMessages: Bool
    let isLoadingOlderMessages: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let attachmentAudio: AttachmentAudioSource?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onLoadMessages: () async -> Void
    let onLoadOlderMessages: () async -> Bool
    let onUpdateScrollMetrics: (ChatScrollMetrics) -> Void
    let onFollowEvent: (ChatScrollPolicy.FollowEvent) -> Void
    let onDisclosureToggle: () -> Void
    let turnFolds: TranscriptTurnFolds
    let terminalReplyRenderIDs: Set<String>
    let expandedTurnKeys: Set<String>
    let onToggleTurnFold: (String) -> Void
    let onDismissKeyboard: () -> Void
    let onScrollToBottom: (ScrollViewProxy) -> Void
    let onScrollToLatestTranscriptMessage: (ScrollViewProxy) -> Void
    let onScrollToLatestContent: (ScrollViewProxy, Bool) -> Void
    let onPreviewAttachment: (MessageAttachmentPreview, [MessageAttachmentPreview]) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference, [TranscriptMediaReference]) -> Void
    let onAskHermex: (String) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    var inlineCommitContext: ChatInlineCommitContext? = nil
    var onInlineCommit: () -> Void = {}
    var turnChangesSummary: TurnFileChangeSummary? = nil
    var onOpenTurnDiff: () -> Void = {}
    var onOpenTurnFileDiff: (GitFile) -> Void = { _ in }
    var forkOrigin: ForkOrigin? = nil
    var onOpenForkParent: () -> Void = {}
    var settledPlan: HermesPlan? = nil
    var settledPlanAfterRenderID: String? = nil
    var turnOutcome: HermesTurnOutcomeRow? = nil
    var screenCard: BotScreenCard? = nil
    var queuedPrompts: [ChatMessage] = []
    var lostTurn: ChatLostTurn? = nil
    var onDiscardLostTurn: () -> Void = {}
    var isCronRun = false
    var onCopyQueuedPrompt: (String) -> Void = { _ in }
    var waitingSend: ChatMessage? = nil
    var onCancelWaitingSend: () -> Void = {}
    var continuity: ChatContinuity? = nil

    var delegatedWork: HermesDelegatedWork? = nil
    var onOpenDelegatedWork: () -> Void = {}

    enum Placeholder: Equatable {
        case loading
        case loadFailed(String)
        case startPrompt

        init?(isLoading: Bool, errorMessage: String?, isEmpty: Bool, showsTurnOutcome: Bool,
              showsQueuedPrompt: Bool, showsDelegatedWork: Bool = false) {
            guard isEmpty else { return nil }
            if isLoading {
                self = .loading
            } else if let errorMessage {
                self = .loadFailed(errorMessage)
            } else if showsTurnOutcome || showsQueuedPrompt || showsDelegatedWork {
                return nil
            } else {
                self = .startPrompt
            }
        }
    }

    var body: some View {
        switch Placeholder(isLoading: isLoading, errorMessage: errorMessage, isEmpty: messages.isEmpty,
                           showsTurnOutcome: turnOutcome != nil,
                           showsQueuedPrompt: !queuedPrompts.isEmpty || lostTurn != nil || waitingSend != nil,
                           showsDelegatedWork: (delegatedWork?.activeCount ?? 0) > 0) {
        case .loading?:
            ChatTranscriptLoadingSkeletonView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed(let errorMessage)?:
            ContentUnavailableView {
                Label("Could Not Load Messages", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                if errorMayRetry {
                    Button("Try Again") {
                        Task { await onLoadMessages() }
                    }
                }
                if let onServeEveryProfile {
                    Button("Fix on This Phone", action: onServeEveryProfile)
                        .buttonStyle(.borderedProminent)
                }
                if let errorHostReason {
                    HostReasonDisclosure(text: errorHostReason)
                }
            }
        case .startPrompt?:
            Color.clear.overlay {
                ContentUnavailableView {
                    Image(systemName: "bubble.left.and.bubble.right")
                } description: {
                    Text("Send a message to start the conversation.")
                }
                .padding(.bottom, transcriptBottomInsetHeight)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onDismissKeyboard()
            }
            .overlay(alignment: .top) {
                if let forkOrigin {
                    ForkOriginRowView(origin: forkOrigin, onOpen: onOpenForkParent)
                        .frame(maxWidth: ChatReadingWidth.maximum)
                        .padding(.horizontal, transcriptHorizontalPadding)
                        .padding(.top, 16)
                }
            }
        case nil:
            transcriptScrollView
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let viewportWidth = max(0, viewport.size.width)
                let contentWidth = transcriptContentWidth(for: viewportWidth)

                ZStack(alignment: .bottom) {
                    ScrollView {
                        transcriptScrollContent(
                            proxy: proxy,
                            viewportWidth: viewportWidth,
                            contentWidth: contentWidth
                        )
                    }
                    .defaultScrollAnchor(
                        ChatScrollPolicy.initialTranscriptAnchor,
                        for: .initialOffset
                    )
                    .defaultScrollAnchor(
                        ChatScrollPolicy.sizeChangeAnchor(
                            shouldFollowLatestMessage: shouldFollowLatestMessage,
                            isDisclosureSettling: isDisclosureSettling
                        ),
                        for: .sizeChanges
                    )
                    .frame(width: viewportWidth)
                    .refreshable {
                        if hasOlderMessages {
                            await loadOlderMessagesPreservingPosition(proxy: proxy)
                        } else {
                            await onLoadMessages()
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear
                            .frame(height: transcriptBottomInsetHeight)
                            .accessibilityHidden(true)
                    }
                    .adaptiveSoftScrollEdges()
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onDismissKeyboard()
                        }
                    )

                    if showsScrollToBottomButton {
                        ChatScrollToBottomButton(
                            bottomPadding: scrollToBottomButtonBottomPadding,
                            onTap: {
                                releasingHold {
                                    scrollPositionController.stopMomentum()
                                    onScrollToBottom(proxy)
                                }
                            }
                        )
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsScrollToBottomButton)
                .background(Color(.appCanvas))
                .background {
                    StreamingFollowTrigger(trigger: streamingScrollTrigger) {
                        if isFollowingLatestContent {
                            releasingHold { onScrollToLatestContent(proxy, true) }
                        }
                    }
                }
                .task(id: completedResponseRenderID) {
                    guard let renderID = completedResponseRenderID else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    releasingHold { proxy.scrollTo(renderID, anchor: .top) }
                }
                .onChange(of: messages.count) {
                    guard isFollowingLatestContent else { return }

                    if latestTranscriptMessageRole == "user" {
                        releasingHold { onScrollToLatestTranscriptMessage(proxy) }
                    } else {
                        releasingHold { onScrollToLatestContent(proxy, true) }
                    }
                }
                .onChange(of: transcriptRelayoutScrollToken) {
                    guard isFollowingLatestContent else {
                        pinReader(proxy: proxy)
                        return
                    }
                    releasingHold { onScrollToLatestContent(proxy, false) }
                }
                .onChange(of: queuedPrompts.map(\.content) + [lostTurn.map { _ in "lost" }, waitingSend?.content]) {
                    followLiveEndChange(proxy: proxy)
                }
                .onChange(of: delegatedWork?.activeCount) {
                    followLiveEndChange(proxy: proxy)
                }
                .onChange(of: clarificationPromptID) {
                    guard clarificationPromptID != nil, isFollowingLatestContent else { return }
                    releasingHold { onScrollToBottom(proxy) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    if isScrolledNearBottom {
                        releasingHold { onScrollToBottom(proxy) }
                    }
                }
                .onAppear {
                    scrollPositionController.resyncToTop = { [transcriptContentID] in
                        proxy.scrollTo(transcriptContentID, anchor: .top)
                    }
                    continuity?.transcriptAppeared(scrollPositionController, isFollowing: shouldFollowLatestMessage)
                }
                .onDisappear { continuity?.transcriptDisappeared(scrollPositionController) }
            }
        }
    }

    private func followLiveEndChange(proxy: ScrollViewProxy) {
        guard isFollowingLatestContent else {
            pinReader(proxy: proxy)
            return
        }
        releasingHold { onScrollToLatestContent(proxy, false) }
    }

    private var isFollowingLatestContent: Bool {
        shouldFollowLatestMessage && !isDisclosureSettling
    }

    private let transcriptContentID = "chat-transcript-content"

    fileprivate static let contentCoordinateSpace = "chat-transcript-content-space"
    private static let planRowID = "hermes-plan"
    private static let compressionCardFrameID = "compression-reference-card"

    private func pinReader(proxy: ScrollViewProxy) {
        scrollPositionController.holdPosition {
            proxy.scrollTo(transcriptContentID, anchor: .top)
        }
    }

    private func releasingHold(_ scroll: () -> Void) {
        scrollPositionController.releaseHold()
        scroll()
    }

    private func transcriptScrollContent(
        proxy: ScrollViewProxy,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        let now = Date()
        let layout = ChatScrollPositionController.Layout(contentWidth: contentWidth, dynamicTypeSize: dynamicTypeSize)
        let isFollowing = isFollowingLatestContent

        return VStack(spacing: transcriptSpacing) {
            if let forkOrigin {
                ForkOriginRowView(origin: forkOrigin, onOpen: onOpenForkParent)
            }

            olderMessagesButton(proxy: proxy)

            if let compressionReferenceCard, compressionReferenceCard.afterRenderID == nil {
                compressionReferenceCardView(compressionReferenceCard)
                    .reportsReflowFrame(Self.compressionCardFrameID, to: scrollPositionController, layout: layout, isFollowing: isFollowing)
            }

            ForEach(displayedTranscriptMessages) { transcriptMessage in
                let isReasoningAnchor = reasoningAnchorMessageID == transcriptMessage.anchorID
                let isToolCallAnchor = toolCallAnchorMessageID == transcriptMessage.anchorID
                let isStreamingRow = streamingAssistantMessageID != nil
                    && transcriptMessage.message.messageId == streamingAssistantMessageID
                let foldState = turnFolds.rowState(
                    for: transcriptMessage.renderID,
                    expandedTurnKeys: expandedTurnKeys
                )

                ChatTranscriptMessageBlock(
                    transcriptMessage: transcriptMessage,
                    transcriptSpacing: transcriptSpacing,
                    showsThinkingAndToolCards: showsThinkingAndToolCards,
                    foldState: foldState,
                    isTerminalReply: terminalReplyRenderIDs.contains(transcriptMessage.renderID),
                    onToggleTurnFold: { turnKey in
                        pinReader(proxy: proxy)
                        onToggleTurnFold(turnKey)
                    },
                    reasoningGroups: reasoningGroupsByAnchorID[transcriptMessage.anchorID] ?? [],
                    toolCallGroups: completedToolCallGroupsForAnchor(transcriptMessage.anchorID),
                    liveReasoningText: isReasoningAnchor ? liveReasoningText : "",
                    reasoningAnchorMessageID: isReasoningAnchor ? reasoningAnchorMessageID : nil,
                    liveReasoningStreamID: isReasoningAnchor ? activeStreamID : nil,
                    liveToolCalls: isToolCallAnchor ? liveToolCalls : [],
                    isReplayingLiveToolCalls: isToolCallAnchor && isReplayingLiveToolCalls,
                    toolCallAnchorMessageID: isToolCallAnchor ? toolCallAnchorMessageID : nil,
                    streamingAssistantMessageID: isStreamingRow ? streamingAssistantMessageID : nil,
                    liveTokensPerSecond: isStreamingRow ? liveTokensPerSecond : nil,
                    localAttachmentPreviews: localAttachmentPreviews[transcriptMessage.message.id],
                    listeningMessageID: listeningMessageID,
                    isViewingCachedData: isViewingCachedData,
                    hasActiveStream: activeStreamID != nil,
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    attachmentAudio: attachmentAudio,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    actionContext: actionContext,
                    shouldRenderMessageRow: shouldRenderMessageRow,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onAskHermex: onAskHermex,
                    onToggleListening: onToggleListening,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy,
                    isCronRun: isCronRun
                )
                .equatable()
                .reportsReflowFrame(transcriptMessage.renderID, to: scrollPositionController, layout: layout, isFollowing: isFollowing)
                .transition(rowEntryTransition(for: transcriptMessage.message, now: now))
                .id(transcriptMessage.renderID)

                if let compressionReferenceCard,
                   compressionReferenceCard.afterRenderID == transcriptMessage.renderID {
                    compressionReferenceCardView(compressionReferenceCard)
                        .reportsReflowFrame(Self.compressionCardFrameID, to: scrollPositionController, layout: layout, isFollowing: isFollowing)
                }

                if let settledPlan, settledPlanAfterRenderID == transcriptMessage.renderID {
                    HermesPlanRowView(plan: settledPlan)
                        .reportsReflowFrame(Self.planRowID, to: scrollPositionController, layout: layout, isFollowing: isFollowing)
                        .id(Self.planRowID)
                }
            }

            transcriptLooseBlocks
            liveResponseBlocks
            if let delegatedWork, delegatedWork.activeCount > 0 {
                HermesDelegatedWorkInlineView(work: delegatedWork, onOpen: onOpenDelegatedWork)
                    .equatable()
            }
            screenCard
            workingRow
            turnOutcome
            if let requestWithdrawal {
                BotRequestWithdrawalNote(withdrawal: requestWithdrawal)
            }
            turnChangesCard
            inlineCommitButton
            if let lostTurn {
                ChatLostTurnRow(turn: lostTurn, onDiscard: onDiscardLostTurn)
                    .reportsReflowFrame(ChatLostTurn.rowID, to: scrollPositionController, layout: layout, isFollowing: isFollowing)
                    .id(ChatLostTurn.rowID)
            }
            ForEach(queuedPrompts) { queuedPrompt in
                ChatQueuedPromptRow(message: queuedPrompt, onCopy: onCopyQueuedPrompt)
                    .reportsReflowFrame(queuedPrompt.id, to: scrollPositionController, layout: layout, isFollowing: isFollowing)
                    .id(queuedPrompt.id)
            }
            if let waitingSend {
                ChatWaitingSendRow(message: waitingSend, onCancel: onCancelWaitingSend)
                    .reportsReflowFrame(waitingSend.id, to: scrollPositionController, layout: layout, isFollowing: isFollowing)
                    .id(waitingSend.id)
            }

            Color.clear
                .frame(height: 1)
                .id(bottomAnchorID)
                .allowsHitTesting(false)
        }
        .padding(.top, 16)
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, transcriptHorizontalPadding)
        .frame(width: viewportWidth, alignment: .center)
        .clipped()
        .chatDisclosureToggled {
            pinReader(proxy: proxy)
            onDisclosureToggle()
        }
        .task(id: activeStreamRecoveryState) {
            let state = activeStreamRecoveryState
            await recoveryChip.run(
                target: state == .idle ? nil : state,
                immediately: state == .waitingForNetwork,
                animation: ChatMotion.quickState(reduceMotion: reduceMotion)
            )
        }
        .id(transcriptContentID)
        .coordinateSpace(.named(Self.contentCoordinateSpace))
        .background {
            ZStack {
                ChatScrollObserver(
                    isStreaming: activeStreamID != nil,
                    scrollPositionController: scrollPositionController,
                    onFollowEvent: onFollowEvent
                ) { metrics in
                    onUpdateScrollMetrics(metrics)
                }

                ChatVerticalScrollAxisGuard()
            }
            .accessibilityHidden(true)
        }
    }

    private func rowEntryTransition(for message: ChatMessage, now: Date) -> AnyTransition {
        guard ChatTranscriptRowFreshness.isFresh(timestamp: message.timestamp, now: now) else {
            return .identity
        }

        return ChatMotion.freshRowTransition(isUserRow: message.role == "user", reduceMotion: reduceMotion)
    }

    private func compressionReferenceCardView(_ card: CompressionReferenceCard) -> some View {
        MarkerMessageCardView(kind: .compressionReference, content: card.referenceText)
    }

    private var transcriptHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
    }

    private func transcriptContentWidth(for viewportWidth: CGFloat) -> CGFloat {
        ChatReadingWidth.contentWidth(viewportWidth: viewportWidth, horizontalPadding: transcriptHorizontalPadding)
    }

    @ViewBuilder
    private func olderMessagesButton(proxy: ScrollViewProxy) -> some View {
        if hasOlderMessages {
            LoadOlderMessagesButton(isLoading: isLoadingOlderMessages) {
                Task { await loadOlderMessagesPreservingPosition(proxy: proxy) }
            }
        }
    }

    private func loadOlderMessagesPreservingPosition(proxy: ScrollViewProxy) async {
        let capturedExactPosition = scrollPositionController.capture()
        let renderID = displayedTranscriptMessages.first?.renderID
        let didLoad = await onLoadOlderMessages()
        guard didLoad else {
            scrollPositionController.cancelPreservation()
            return
        }

        if capturedExactPosition,
           scrollPositionController.restoreAfterPrepend() {
            return
        }

        guard let renderID else { return }

        await Task.yield()
        proxy.scrollTo(renderID, anchor: .top)
    }

    @ViewBuilder
    private var transcriptLooseBlocks: some View {
        reasoningBlocks(anchorMessageID: nil)
        toolCallGroups(anchorMessageID: nil)
    }

    @ViewBuilder
    private var liveResponseBlocks: some View {
        if let activeStreamID {
            if showsThinkingAndToolCards {
                if hasLiveReasoningText,
                   !hasDisplayedTranscriptMessage(anchorID: reasoningAnchorMessageID) {
                    ReasoningBlockView(
                        text: liveReasoningText,
                        liveStreamID: activeStreamID
                    )
                }

                if !liveToolCalls.isEmpty,
                   !hasDisplayedTranscriptMessage(anchorID: toolCallAnchorMessageID) {
                    ToolActivityGroupView(
                        group: ToolCallGroup.live(
                            anchorMessageID: toolCallAnchorMessageID,
                            toolCalls: liveToolCalls
                        ),
                        isLive: true,
                        isReplaying: isReplayingLiveToolCalls
                    )
                }
            }
        }

        DelayedStatusView(driver: recoveryChip) { state in
            StreamRecoveryStatusView(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(hidesRunStatusAccessibility)
                .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var workingRow: some View {
        if let workingRowStartedAt {
            ChatWorkingRowView(startedAt: workingRowStartedAt, isCompacting: isCompacting)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(hidesRunStatusAccessibility)
        }
    }

    @ViewBuilder
    private var turnChangesCard: some View {
        if let summary = turnChangesSummary {
            GitTurnChangesCard(
                summary: summary,
                onOpenAll: onOpenTurnDiff,
                onOpenFile: onOpenTurnFileDiff
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var inlineCommitButton: some View {
        if let context = inlineCommitContext {
            GitInlineCommitButton(
                runningPhase: context.runningPhase,
                isDisabled: context.isDisabled,
                action: onInlineCommit
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasLiveReasoningText: Bool {
        !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasDisplayedTranscriptMessage(anchorID: String?) -> Bool {
        guard let anchorID else { return false }

        return displayedTranscriptMessages.contains { $0.anchorID == anchorID }
    }

    @ViewBuilder
    private func reasoningBlocks(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroupsByAnchorID[anchorMessageID] ?? []) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private func toolCallGroups(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(completedToolCallGroupsForAnchor(anchorMessageID)) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }
}

struct StreamingFollowTrigger: View {
    let trigger: () -> Int
    let onFire: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: trigger()) { onFire() }
    }
}

struct ChatTranscriptMessageBlock: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let transcriptMessage: TranscriptMessage
    let transcriptSpacing: CGFloat
    let showsThinkingAndToolCards: Bool
    let foldState: TranscriptTurnFoldRowState?
    let isTerminalReply: Bool
    let onToggleTurnFold: (String) -> Void
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveReasoningStreamID: String?
    let liveToolCalls: [ToolCall]
    let isReplayingLiveToolCalls: Bool
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let attachmentAudio: AttachmentAudioSource?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onPreviewAttachment: (MessageAttachmentPreview, [MessageAttachmentPreview]) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference, [TranscriptMediaReference]) -> Void
    let onAskHermex: (String) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    var isCronRun = false

    static func == (lhs: ChatTranscriptMessageBlock, rhs: ChatTranscriptMessageBlock) -> Bool {
        let isEqual = lhs.transcriptMessage == rhs.transcriptMessage &&
            lhs.transcriptSpacing == rhs.transcriptSpacing &&
            lhs.showsThinkingAndToolCards == rhs.showsThinkingAndToolCards &&
            lhs.foldState == rhs.foldState &&
            lhs.isTerminalReply == rhs.isTerminalReply &&
            lhs.reasoningGroups == rhs.reasoningGroups &&
            lhs.toolCallGroups == rhs.toolCallGroups &&
            lhs.liveReasoningText == rhs.liveReasoningText &&
            lhs.reasoningAnchorMessageID == rhs.reasoningAnchorMessageID &&
            lhs.liveReasoningStreamID == rhs.liveReasoningStreamID &&
            lhs.liveToolCalls == rhs.liveToolCalls &&
            lhs.isReplayingLiveToolCalls == rhs.isReplayingLiveToolCalls &&
            lhs.toolCallAnchorMessageID == rhs.toolCallAnchorMessageID &&
            lhs.streamingAssistantMessageID == rhs.streamingAssistantMessageID &&
            lhs.liveTokensPerSecond == rhs.liveTokensPerSecond &&
            lhs.localAttachmentPreviews == rhs.localAttachmentPreviews &&
            lhs.listeningMessageID == rhs.listeningMessageID &&
            lhs.isViewingCachedData == rhs.isViewingCachedData &&
            lhs.hasActiveStream == rhs.hasActiveStream &&
            lhs.isRegeneratingMessage == rhs.isRegeneratingMessage &&
            lhs.isEditingMessage == rhs.isEditingMessage &&
            lhs.isForkingMessage == rhs.isForkingMessage &&
            lhs.attachmentAudio == rhs.attachmentAudio &&
            lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace &&
            lhs.isCronRun == rhs.isCronRun
        RenderProbe.hit(.transcriptMessageBlockCompared)
        if !isEqual {
            RenderProbe.hit(.transcriptMessageBlockUnequal)
        }
        return isEqual
    }

    var body: some View {
        let _ = RenderProbe.hit(.transcriptMessageBlock, renderID: transcriptMessage.renderID)
        let foldedQuestions = Self.foldedQuestionLines(
            in: toolCallGroups,
            foldState: foldState,
            showsThinkingAndToolCards: showsThinkingAndToolCards
        )
        if hasVisibleContent || !foldedQuestions.isEmpty {
            VStack(alignment: .leading, spacing: transcriptSpacing) {
                if let fold = foldState?.fold {
                    TranscriptTurnFoldRowView(
                        fold: fold,
                        isExpanded: foldState?.isExpanded == true,
                        onToggle: { onToggleTurnFold(fold.turnKey) }
                    )
                }

                if showsActivity {
                    Group {
                        reasoningBlocks
                        liveReasoningBlock
                        toolActivityGroups
                        liveToolActivityGroup
                    }
                    .transition(foldTransition)
                } else if !foldedQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(foldedQuestions) { line in
                            ClarifyAnswerLineView(line: line)
                        }
                    }
                    .transition(foldTransition)
                }

                if showsBubble {
                    messageRow
                        .transition(foldTransition)
                }
            }
        }
    }

    private var foldTransition: AnyTransition {
        foldState == nil ? .identity : ChatMotion.disclosureTransition(reduceMotion: reduceMotion)
    }

    private var showsActivity: Bool {
        foldState?.hidesActivity != true
    }

    private var showsBubble: Bool {
        foldState?.hidesBubble != true && shouldRenderMessageRow(transcriptMessage.message)
    }

    private var rendersActivity: Bool {
        let hasArchivedActivity = showsThinkingAndToolCards
            && (!toolCallGroups.isEmpty
                || !reasoningGroups.isEmpty)
        return hasArchivedActivity || shouldRenderLiveReasoningBlock || shouldRenderLiveToolActivityGroup
    }

    static func foldedQuestionLines(
        in toolCallGroups: [ToolCallGroup],
        foldState: TranscriptTurnFoldRowState?,
        showsThinkingAndToolCards: Bool
    ) -> [ClarifyResult.Line] {
        guard showsThinkingAndToolCards, foldState?.hidesActivity == true else { return [] }
        return ClarifyResult.lines(in: toolCallGroups)
    }

    private var hasVisibleContent: Bool {
        foldState?.fold != nil || (showsActivity && rendersActivity) || showsBubble
    }

    private var messageRow: some View {
                ChatTranscriptMessageRow(
                    message: transcriptMessage.message,
                    visibleIndex: transcriptMessage.loadedIndex,
                    actionContext: actionContext(transcriptMessage.message, transcriptMessage.loadedIndex),
                    isTerminalReply: isTerminalReply,
                    localAttachmentPreviews: localAttachmentPreviews,
                    listeningMessageID: listeningMessageID,
                    isViewingCachedData: isViewingCachedData,
                    hasActiveStream: hasActiveStream,
                    isStreaming: ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
                        hasActiveStream: hasActiveStream,
                        messageRole: transcriptMessage.message.role,
                        messageID: transcriptMessage.message.messageId,
                        streamingAssistantMessageID: streamingAssistantMessageID
                    ),
                    liveTokensPerSecond: liveTokensPerSecond,
                    transcriptSpacing: transcriptSpacing,
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    attachmentAudio: attachmentAudio,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onAskHermex: onAskHermex,
                    onToggleListening: onToggleListening,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy,
                    isCronRun: isCronRun
                )
    }

    @ViewBuilder
    private var reasoningBlocks: some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroups) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private var liveReasoningBlock: some View {
        if shouldRenderLiveReasoningBlock {
            ReasoningBlockView(
                text: liveReasoningText,
                liveStreamID: liveReasoningStreamID
            )
        }
    }

    @ViewBuilder
    private var toolActivityGroups: some View {
        if showsThinkingAndToolCards {
            ForEach(toolCallGroups) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }

    @ViewBuilder
    private var liveToolActivityGroup: some View {
        if shouldRenderLiveToolActivityGroup {
            ToolActivityGroupView(
                group: ToolCallGroup.live(
                    anchorMessageID: toolCallAnchorMessageID,
                    toolCalls: liveToolCalls
                ),
                isLive: true,
                isReplaying: isReplayingLiveToolCalls
            )
        }
    }

    private var shouldRenderLiveReasoningBlock: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            reasoningAnchorMessageID == transcriptMessage.anchorID &&
            !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldRenderLiveToolActivityGroup: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            toolCallAnchorMessageID == transcriptMessage.anchorID &&
            !liveToolCalls.isEmpty
    }
}

private struct ChatQueuedPromptRow: View {
    let message: ChatMessage
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MessageBubbleView(message: message, transcriptMediaCacheNamespace: "", isQueued: true)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text("Queued"))
            ChatMessageMetaRow(isUserMessage: true, timeText: String(localized: "Queued"),
                               onCopy: { onCopy(message.content ?? "") })
        }
    }
}

struct ChatLostTurn: Equatable {
    static let rowID = "hermes-lost-turn"
    let prompt: ChatMessage?
}

private struct ChatLostTurnRow: View {
    let turn: ChatLostTurn
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let prompt = turn.prompt {
                MessageBubbleView(message: prompt, transcriptMediaCacheNamespace: "")
                    .accessibilityElement(children: .combine)
            }
            HStack(spacing: 10) {
                Text("Lost during restart")
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.orange)
                Button("Discard", action: onDiscard)
                    .font(AppFont.caption(weight: .semibold))
                    .chatMinimumHitTarget(horizontalPadding: 12, verticalPadding: 14, in: Rectangle())
                    .accessibilityLabel(Text("Discard lost reply"))
            }
            .padding(.horizontal, 2)
            Text("Hermes restarted before this reply finished. Messages queued after it wait until you discard it.")
                .font(AppFont.caption())
                .foregroundStyle(.appSecondary)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 2)
        }
    }
}

private struct ChatWaitingSendRow: View {
    let message: ChatMessage
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MessageBubbleView(message: message, transcriptMediaCacheNamespace: "", isQueued: true)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text("Waiting for connection"))
            HStack(spacing: 10) {
                Text("Waiting for connection")
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.appSecondary)
                    .accessibilityHidden(true)
                Button("Cancel", action: onCancel)
                    .font(AppFont.caption(weight: .semibold))
                    .chatMinimumHitTarget(horizontalPadding: 12, verticalPadding: 14, in: Rectangle())
                    .accessibilityLabel(Text("Cancel waiting message"))
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct ChatTranscriptMessageRow: View {
    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey) private var showsTimestamps = ChatTranscriptDisplaySettings.defaultShowsTimestamps

    let message: ChatMessage
    let visibleIndex: Int
    let actionContext: MessageActionContext?
    let isTerminalReply: Bool
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isStreaming: Bool
    let liveTokensPerSecond: Double?
    let transcriptSpacing: CGFloat
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let attachmentAudio: AttachmentAudioSource?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let onPreviewAttachment: (MessageAttachmentPreview, [MessageAttachmentPreview]) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference, [TranscriptMediaReference]) -> Void
    let onAskHermex: (String) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    let isCronRun: Bool

    var body: some View {
        if let markerKind = ChatMarkerMessageClassifier.classify(message) {
            MarkerMessageCardView(kind: markerKind, content: message.content)
        } else if let completion = HermesDelegationCompletion(message) {
            HermesDelegationCompletionCard(completion: completion)
        } else if isCronRun, let prompt = CronRunPrompt(message) {
            VStack(alignment: .trailing, spacing: metaRowSpacing) {
                CronRunPromptCard(prompt: prompt, onCopy: actionContext.map { context in { onCopy(context) } })
                if let metaTimeText {
                    ChatMessageMetaRow(isUserMessage: true, timeText: metaTimeText, onCopy: nil)
                }
            }
        } else {
            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: metaRowSpacing) {
                bubble

                if showsMetaRow {
                    ChatMessageMetaRow(
                        isUserMessage: isUserMessage,
                        timeText: metaTimeText,
                        onCopy: actionContext.map { context -> () -> Void in
                            { onCopy(context) }
                        },
                        actionMenu: isUserMessage ? nil : actionMenu
                    )
                }
            }
        }
    }

    private var isUserMessage: Bool {
        message.role == "user"
    }

    private var metaRowSpacing: CGFloat {
        isUserMessage ? 4 : transcriptSpacing - (28 - 13) / 2
    }

    private var showsMetaRow: Bool {
        TranscriptMessageMetaPolicy.showsRow(
            hasActions: actionContext != nil, hasTimestamp: metaTimeText != nil
        )
    }

    private var metaTimeText: String? {
        guard !message.isSteerMessage else { return nil }
        guard showsTimestamps, isUserMessage || (isTerminalReply && !isStreaming) else { return nil }
        return ChatMessageTimestampFormatter.shortTime(forUnixTimestamp: message.timestamp)
    }

    private var bubble: some View {
        MessageBubbleView(
            message: message,
            loadAttachmentImage: loadAttachmentImage,
            attachmentAudio: attachmentAudio,
            loadTranscriptMediaImage: loadTranscriptMediaImage,
            loadTranscriptMediaData: loadTranscriptMediaData,
            transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
            localAttachmentPreviews: localAttachmentPreviews,
            onPreviewAttachment: onPreviewAttachment,
            onPreviewTranscriptMedia: onPreviewTranscriptMedia,
            isStreaming: isStreaming,
            liveTokensPerSecond: liveTokensPerSecond,
            onAskHermex: onAskHermex,
            contextMenuActions: isUserMessage && !message.isSteerMessage ? (actionMenu?.items ?? []) : []
        )
    }

    private var actionMenu: ChatMessageActionMenu? {
        guard let actionContext else { return nil }
        return ChatMessageActionMenu(
            context: actionContext,
            listeningMessageID: listeningMessageID,
            isViewingCachedData: isViewingCachedData,
            hasActiveStream: hasActiveStream,
            isRegeneratingMessage: isRegeneratingMessage,
            isEditingMessage: isEditingMessage,
            isForkingMessage: isForkingMessage,
            onToggleListening: onToggleListening,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onFork: onFork,
            onCopy: onCopy
        )
    }
}

struct ChatScrollToBottomButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let bottomPadding: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.appPrimary)
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    fallbackMaterial: .regularMaterial,
                    in: Circle()
                )
                .chatMinimumHitTarget(in: Circle())
        }
        .buttonStyle(.chatTactile(
            .icon,
            shadow: ChatTactileButtonStyle.Shadow(
                color: .black,
                opacity: colorScheme == .dark ? 0.32 : 0.16,
                radius: 8,
                y: 4,
                pressedOpacity: colorScheme == .dark ? 0.18 : 0.08,
                pressedRadius: 3,
                pressedY: 2
            )
        ))
        .padding(.bottom, bottomPadding)
        .accessibilityLabel("Scroll to latest message")
    }
}

struct LoadOlderMessagesButton: View {
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.up")
                        .font(AppFont.caption(weight: .semibold))
                        .accessibilityHidden(true)
                }

                Text(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
                    .font(AppFont.caption(weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .foregroundStyle(.appPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.appMaterial(.regularMaterial), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.appSeparator).opacity(0.32), lineWidth: 0.5)
            )
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
    }
}

enum ChatTranscriptRowFreshness {
    static let window: TimeInterval = 3

    static func isFresh(timestamp: Double?, now: Date) -> Bool {
        guard let timestamp, timestamp.isFinite else { return false }
        return abs(now.timeIntervalSince1970 - timestamp) < window
    }
}

private extension View {
    func reportsReflowFrame(
        _ id: String,
        to controller: ChatScrollPositionController,
        layout: ChatScrollPositionController.Layout,
        isFollowing: Bool
    ) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(ChatTranscriptView.contentCoordinateSpace))
        } action: { frame in
            controller.rowFrameChanged(id: id, frame: frame, layout: layout, isFollowing: isFollowing)
        }
        .onDisappear { controller.forgetRow(id: id) }
    }
}
