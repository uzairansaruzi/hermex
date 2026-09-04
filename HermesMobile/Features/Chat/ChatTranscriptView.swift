import SwiftUI
import UIKit

struct ChatTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrollPositionController = ChatScrollPositionController()

    let isLoading: Bool
    let errorMessage: String?
    let messages: [ChatMessage]
    let displayedTranscriptMessages: [TranscriptMessage]
    let compressionReferenceCard: CompressionReferenceCard?
    let reasoningGroups: [ReasoningGroup]
    let completedToolCallGroupsForAnchor: (String?) -> [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveToolCalls: [ToolCall]
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let activeStreamRecoveryState: ActiveStreamRecoveryState
    /// The pending clarification's id. The card itself is pinned above the
    /// composer by `ChatView`; the transcript only follows its arrival.
    let clarificationPromptID: String?
    let hidesRunStatusAccessibility: Bool
    let showsThinkingAndToolCards: Bool
    /// Start date for the "Working for" tail row; nil hides the row.
    let workingRowStartedAt: Date?
    let showsScrollToBottomButton: Bool
    let shouldFollowLatestMessage: Bool
    /// True while a disclosure toggle animates; suspends the bottom size-change
    /// anchor and follow-driven scrolls so the tapped row stays stationary.
    let isDisclosureSettling: Bool
    let latestTranscriptMessageRole: String?
    let isScrolledNearBottom: Bool
    let activeStreamID: String?
    let streamingScrollTrigger: Int
    let transcriptRelayoutScrollToken: Int
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
    let loadAttachmentData: (String) async -> Data?
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
    /// Settled-turn folds derived by the owner; `.none` when folding is off.
    let turnFolds: TranscriptTurnFolds
    /// Rows that close a settled turn and so carry the time + copy row.
    let terminalReplyRenderIDs: Set<String>
    let expandedTurnKeys: Set<String>
    let onToggleTurnFold: (String) -> Void
    let onDismissKeyboard: () -> Void
    let onScrollToBottom: (ScrollViewProxy) -> Void
    let onScrollToLatestTranscriptMessage: (ScrollViewProxy) -> Void
    let onScrollToLatestContent: (ScrollViewProxy, Bool) -> Void
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    /// Non-nil shows the inline "Commit & Push" button under the latest assistant turn
    /// (issue #315, Slice C, surface B). Nil hides it (non-git chats, no changes, etc.).
    var inlineCommitContext: ChatInlineCommitContext? = nil
    var onInlineCommit: () -> Void = {}
    /// Non-nil shows the turn-end "File changes" recap card under the latest assistant turn
    /// (issue #316, Slice D, surface B). Nil hides it (non-git chats, no changes, streaming).
    var turnChangesSummary: TurnFileChangeSummary? = nil
    var onOpenTurnDiff: () -> Void = {}
    var onOpenTurnFileDiff: (GitFile) -> Void = { _ in }

    var body: some View {
        if isLoading && messages.isEmpty {
            ChatTranscriptLoadingSkeletonView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, messages.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Messages", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await onLoadMessages() }
                }
            }
        } else if messages.isEmpty {
            ContentUnavailableView {
                Image(systemName: "bubble.left.and.bubble.right")
            } description: {
                Text("Send a message to start the conversation.")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onDismissKeyboard()
            }
        } else {
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
                                releasingHold { onScrollToBottom(proxy) }
                            }
                        )
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsScrollToBottomButton)
                .background(Color(.systemBackground))
                .onChange(of: messages.count) {
                    guard isFollowingLatestContent else { return }

                    if latestTranscriptMessageRole == "user" {
                        releasingHold { onScrollToLatestTranscriptMessage(proxy) }
                    } else {
                        releasingHold { onScrollToLatestContent(proxy, true) }
                    }
                }
                .onChange(of: streamingScrollTrigger) {
                    if isFollowingLatestContent {
                        releasingHold { onScrollToLatestContent(proxy, true) }
                    }
                }
                .onChange(of: transcriptRelayoutScrollToken) {
                    // The transcript just changed height without gaining a message —
                    // the server render replacing the cache-first one (#289), or sent
                    // references becoming chips (#388). A reader at the live edge is
                    // put back there (no animation); a reader up in history keeps the
                    // offset they were reading at, the way a disclosure toggle does.
                    guard isFollowingLatestContent else {
                        pinReader(proxy: proxy)
                        return
                    }
                    releasingHold { onScrollToLatestContent(proxy, false) }
                }
                .onChange(of: clarificationPromptID) {
                    // The bar above the composer just grew the bottom inset; keep
                    // the latest content above it for a reader who was following.
                    guard clarificationPromptID != nil, isFollowingLatestContent else { return }
                    releasingHold { onScrollToBottom(proxy) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    if isScrolledNearBottom {
                        releasingHold { onScrollToBottom(proxy) }
                    }
                }
            }
        }
    }

    /// Follow-driven scrolls run only while the latch is on and no disclosure
    /// toggle is mid-animation.
    private var isFollowingLatestContent: Bool {
        shouldFollowLatestMessage && !isDisclosureSettling
    }

    /// Identifies the whole transcript content so a scroll to its top can be
    /// expressed through SwiftUI.
    private let transcriptContentID = "chat-transcript-content"

    /// A tapped row is about to grow or shrink below the reader. Pin the offset
    /// so a default anchor SwiftUI re-applies on the size change (seen at the
    /// exact top after a status-bar scroll) cannot move them. If the pin had to
    /// undo SwiftUI, finish with a SwiftUI-driven scroll to the same place so
    /// its own offset model, and hit-testing of the visible rows, catch up.
    private func pinReader(proxy: ScrollViewProxy) {
        scrollPositionController.holdPosition {
            proxy.scrollTo(transcriptContentID, anchor: .top)
        }
    }

    /// Deliberate scrolls end a disclosure pin first. The pin exists only to
    /// stop SwiftUI moving the reader on its own after a toggle.
    private func releasingHold(_ scroll: () -> Void) {
        scrollPositionController.releaseHold()
        scroll()
    }

    private func transcriptScrollContent(
        proxy: ScrollViewProxy,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        // One clock read per body pass; each row compares its timestamp to it.
        let now = Date()

        return VStack(spacing: transcriptSpacing) {
            olderMessagesButton(proxy: proxy)

            if let compressionReferenceCard, compressionReferenceCard.afterRenderID == nil {
                compressionReferenceCardView(compressionReferenceCard)
            }

            ForEach(displayedTranscriptMessages) { transcriptMessage in
                // Scope live-streaming state to the row that actually displays it.
                // Non-anchor / non-streaming rows receive stable empty/nil values so
                // their inputs don't change on every ~16ms flush; combined with the
                // `.equatable()` wrapper below, SwiftUI then skips re-evaluating their
                // (markdown-heavy) bodies while a response streams in.
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
                        // Turn folds toggle in ChatView, so arm the pin here.
                        pinReader(proxy: proxy)
                        onToggleTurnFold(turnKey)
                    },
                    reasoningGroups: reasoningGroups,
                    toolCallGroups: completedToolCallGroupsForAnchor(transcriptMessage.anchorID),
                    liveReasoningText: isReasoningAnchor ? liveReasoningText : "",
                    reasoningAnchorMessageID: isReasoningAnchor ? reasoningAnchorMessageID : nil,
                    liveReasoningStreamID: isReasoningAnchor ? activeStreamID : nil,
                    liveToolCalls: isToolCallAnchor ? liveToolCalls : [],
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
                    loadAttachmentData: loadAttachmentData,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    actionContext: actionContext,
                    shouldRenderMessageRow: shouldRenderMessageRow,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onToggleListening: onToggleListening,
                    onSelectText: onSelectText,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy
                )
                .equatable()
                .transition(rowEntryTransition(for: transcriptMessage.message, now: now))
                .id(transcriptMessage.renderID)

                if let compressionReferenceCard,
                   compressionReferenceCard.afterRenderID == transcriptMessage.renderID {
                    compressionReferenceCardView(compressionReferenceCard)
                }
            }

            transcriptLooseBlocks
            liveResponseBlocks
            workingRow
            turnChangesCard
            inlineCommitButton

            Color.clear
                .frame(height: 1)
                .id(bottomAnchorID)
                .allowsHitTesting(false)
        }
        .padding(.top, 16)
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, transcriptHorizontalPadding)
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
        .environment(\.chatDisclosureToggled) {
            pinReader(proxy: proxy)
            onDisclosureToggle()
        }
        .id(transcriptContentID)
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

    /// Only rows created moments ago animate in. Cached history, reloads, and
    /// reattached transcripts carry old timestamps and keep `.identity`, so
    /// they never replay an entrance.
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
        max(0, viewportWidth - (transcriptHorizontalPadding * 2))
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
                        isLive: true
                    )
                }
            }

            if activeStreamRecoveryState != .idle {
                StreamRecoveryStatusView(state: activeStreamRecoveryState)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(hidesRunStatusAccessibility)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
    }

    @ViewBuilder
    private var workingRow: some View {
        if let workingRowStartedAt {
            ChatWorkingRowView(startedAt: workingRowStartedAt)
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
            ForEach(reasoningGroups.filter { $0.anchorMessageID == anchorMessageID }) { group in
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

private struct ChatTranscriptMessageBlock: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let transcriptMessage: TranscriptMessage
    let transcriptSpacing: CGFloat
    let showsThinkingAndToolCards: Bool
    /// Nil outside a settled-turn fold. Otherwise says whether this row draws
    /// the fold row and which of its parts are hidden right now.
    let foldState: TranscriptTurnFoldRowState?
    /// Whether this row is the reply that closes a settled turn.
    let isTerminalReply: Bool
    let onToggleTurnFold: (String) -> Void
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveReasoningStreamID: String?
    let liveToolCalls: [ToolCall]
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
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    // Equality over the value inputs only. The closures are pure functions of
    // these values (e.g. `actionContext` is fully determined by
    // `transcriptMessage`), so two blocks that compare equal render identically.
    // This lets `.equatable()` skip re-evaluating rows whose data is unchanged
    // even though their closure props are recreated on every parent body pass.
    static func == (lhs: ChatTranscriptMessageBlock, rhs: ChatTranscriptMessageBlock) -> Bool {
        lhs.transcriptMessage == rhs.transcriptMessage &&
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
            lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace
    }

    var body: some View {
        // Yield nothing when every part is folded away, so the outer stack adds
        // no spacing for an empty row.
        if hasVisibleContent {
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
                }

                if showsBubble {
                    messageRow
                        .transition(foldTransition)
                }
            }
        }
    }

    /// Only folded rows animate in and out; ordinary rows keep no transition
    /// so streaming appends stay instant.
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
                || reasoningGroups.contains { $0.anchorMessageID == transcriptMessage.anchorID })
        return hasArchivedActivity || shouldRenderLiveReasoningBlock || shouldRenderLiveToolActivityGroup
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
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    loadAttachmentData: loadAttachmentData,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onToggleListening: onToggleListening,
                    onSelectText: onSelectText,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy
                )
    }

    @ViewBuilder
    private var reasoningBlocks: some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroups.filter { $0.anchorMessageID == transcriptMessage.anchorID }) { group in
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
                isLive: true
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
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        // Compaction marker messages render as collapsible cards (matching the
        // web UI), never as user bubbles — and without bubble actions, which
        // don't apply to system-emitted markers.
        if let markerKind = ChatMarkerMessageClassifier.classify(message) {
            MarkerMessageCardView(kind: markerKind, content: message.content)
        } else {
            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
                bubble

                if showsMetaRow {
                    ChatMessageMetaRow(
                        isUserMessage: isUserMessage,
                        timeText: metaTimeText,
                        onCopy: actionContext.map { context -> () -> Void in
                            { onCopy(context) }
                        }
                    )
                }
            }
        }
    }

    private var isUserMessage: Bool {
        message.role == "user"
    }

    /// Every user message carries the row; an assistant row only as the reply
    /// that closes a settled turn, and never while it is still streaming.
    private var showsMetaRow: Bool {
        guard metaTimeText != nil || actionContext != nil else { return false }
        return isUserMessage || (isTerminalReply && !isStreaming)
    }

    private var metaTimeText: String? {
        guard showsTimestamps else { return nil }
        return ChatMessageTimestampFormatter.shortTime(forUnixTimestamp: message.timestamp)
    }

    private var bubble: some View {
        MessageBubbleView(
            message: message,
            loadAttachmentImage: loadAttachmentImage,
            loadAttachmentData: loadAttachmentData,
            loadTranscriptMediaImage: loadTranscriptMediaImage,
            loadTranscriptMediaData: loadTranscriptMediaData,
            transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
            localAttachmentPreviews: localAttachmentPreviews,
            onPreviewAttachment: onPreviewAttachment,
            onPreviewTranscriptMedia: onPreviewTranscriptMedia,
            isStreaming: isStreaming,
            liveTokensPerSecond: liveTokensPerSecond,
            contextMenu: actionMenu
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
            onSelectText: onSelectText,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onFork: onFork,
            onCopy: onCopy
        )
    }
}

private struct ChatScrollToBottomButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let bottomPadding: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.primary)
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

private struct LoadOlderMessagesButton: View {
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
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }

                Text(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.separator).opacity(0.32), lineWidth: 0.5)
            )
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
    }
}

/// Decides whether a transcript row is new enough to earn an entrance.
enum ChatTranscriptRowFreshness {
    /// Rows younger than this animate in; older ones render in place.
    static let window: TimeInterval = 3

    /// `timestamp` is epoch seconds, as `ChatMessage.timestamp` is. Missing or
    /// non-finite values are never fresh. The check is symmetric so a server
    /// clock running ahead cannot make reconciled history look freshly born;
    /// rows the app creates itself use the phone clock and always pass.
    static func isFresh(timestamp: Double?, now: Date) -> Bool {
        guard let timestamp, timestamp.isFinite else { return false }
        return abs(now.timeIntervalSince1970 - timestamp) < window
    }
}
