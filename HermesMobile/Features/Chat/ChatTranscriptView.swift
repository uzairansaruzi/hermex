import SwiftUI
import UIKit

struct ChatTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var chatBackgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @State private var disclosurePositionPreserver = ChatScrollPositionPreserver()

    let isLoading: Bool
    let errorMessage: String?
    let messages: [ChatMessage]
    let displayedTranscriptMessages: [TranscriptMessage]
    let compressionReferenceCard: CompressionReferenceCard?
    let reasoningGroups: [ReasoningGroup]
    let completedToolCallGroupsForAnchor: (String?) -> [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    /// True while the turn is semantically in its reasoning step (phase
    /// model — holds across intra-step token pauses, settles when a tool call
    /// or answer text arrives). Drives the thinking orb / beam. Sourced from
    /// `ChatViewModel.isReasoningPhaseActive`.
    let isReasoningActive: Bool
    /// Duration of the most recently completed reasoning stint in the open
    /// turn ("Thought for Ns" on the live block once it settles). Historical
    /// blocks always render nil. Sourced from
    /// `ChatViewModel.lastReasoningDuration`.
    let lastReasoningDuration: TimeInterval?
    /// True while the turn is semantically in its tool step; keeps the live
    /// tool capsule animating between a tool completing and the next event.
    /// Sourced from `ChatViewModel.isToolPhaseActive`.
    let isToolPhaseActive: Bool
    /// True once the assistant's answer text has begun streaming for this turn
    /// (`ChatViewModel.isAnswerPhaseActive`). Drives the activity fold.
    let isAnswerStreaming: Bool
    let liveToolCalls: [ToolCall]
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let activeStreamRecoveryState: ActiveStreamRecoveryState
    let clarificationPrompt: ClarificationPromptState?
    let isRespondingToClarification: Bool
    let clarificationErrorMessage: String?
    let hidesRunStatusAccessibility: Bool
    let showsThinkingAndToolCards: Bool
    let showsAssistantTypingIndicator: Bool
    let showsScrollToBottomButton: Bool
    let shouldFollowLatestMessage: Bool
    let latestTranscriptMessageRole: String?
    let isScrolledNearBottom: Bool
    let activeStreamID: String?
    let streamingScrollTrigger: Int
    let cacheFirstReconcileScrollToken: Int
    let bottomAnchorID: String
    let transcriptMessageSpacing: CGFloat
    let transcriptBlockSpacing: CGFloat
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
    let onDismissKeyboard: () -> Void
    let onScrollToBottom: (ScrollViewProxy) -> Void
    let onScrollToLatestTranscriptMessage: (ScrollViewProxy) -> Void
    let onScrollToLatestContent: (ScrollViewProxy, Bool) -> Void
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onSubmitClarification: (String) -> Void
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
        Group {
            if isLoading && messages.isEmpty && clarificationPrompt == nil {
                ChatTranscriptLoadingSkeletonView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, messages.isEmpty, clarificationPrompt == nil {
                ContentUnavailableView {
                    Label("Could Not Load Messages", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await onLoadMessages() }
                    }
                }
            } else if messages.isEmpty && clarificationPrompt == nil {
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
        .background(chatPalette.chatBackground)
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
                        .environment(\.preserveActivityExpansionPosition) {
                            disclosurePositionPreserver.preserveCurrentVerticalOffset(
                                // The visible spring is ~0.5s, but cold tall
                                // Markdown can deliver its final content-size
                                // correction later. Hold through that tail;
                                // any user drag cancels immediately.
                                for: reduceMotion ? 0.35 : 1.25
                            )
                        }
                        .environment(\.activityDisclosureViewportHeight, viewport.size.height)
                    }
                    .defaultScrollAnchor(
                        ChatScrollPolicy.initialTranscriptAnchor,
                        for: .initialOffset
                    )
                    .defaultScrollAnchor(
                        ChatScrollPolicy.sizeChangeAnchor(
                            shouldFollowLatestMessage: shouldFollowLatestMessage,
                            hasActiveStream: activeStreamID != nil
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
                            guard clarificationPrompt == nil else { return }
                            onDismissKeyboard()
                        }
                    )

                    if showsScrollToBottomButton {
                        ChatScrollToBottomButton(
                            bottomPadding: scrollToBottomButtonBottomPadding,
                            onTap: {
                                onScrollToBottom(proxy)
                            }
                        )
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsScrollToBottomButton)
                .background(chatPalette.chatBackground)
                .onChange(of: messages.count) {
                    guard shouldFollowLatestMessage else { return }

                    if latestTranscriptMessageRole == "user" {
                        onScrollToLatestTranscriptMessage(proxy)
                    } else {
                        onScrollToLatestContent(proxy, true)
                    }
                }
                .onChange(of: streamingScrollTrigger) {
                    if shouldFollowLatestMessage {
                        onScrollToLatestContent(proxy, true)
                    }
                }
                .onChange(of: cacheFirstReconcileScrollToken) {
                    // Cache-first reconcile (#289): the server transcript just replaced
                    // the lighter cached render, so snap back to the bottom (no
                    // animation) unless the reader has scrolled away in the meantime.
                    guard shouldFollowLatestMessage else { return }
                    onScrollToLatestContent(proxy, false)
                }
                .onChange(of: clarificationPrompt?.id) {
                    guard clarificationPrompt != nil, shouldFollowLatestMessage else { return }
                    onScrollToBottom(proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    if isScrolledNearBottom {
                        onScrollToBottom(proxy)
                    }
                }
            }
        }
    }

    private func transcriptScrollContent(
        proxy: ScrollViewProxy,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        VStack(spacing: transcriptMessageSpacing) {
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

                ChatTranscriptMessageBlock(
                    transcriptMessage: transcriptMessage,
                    transcriptBlockSpacing: transcriptBlockSpacing,
                    showsThinkingAndToolCards: showsThinkingAndToolCards,
                    reasoningGroups: reasoningGroups,
                    toolCallGroups: completedToolCallGroupsForAnchor(transcriptMessage.anchorID),
                    liveReasoningText: isReasoningAnchor ? liveReasoningText : "",
                    reasoningAnchorMessageID: isReasoningAnchor ? reasoningAnchorMessageID : nil,
                    isReasoningActive: isReasoningAnchor && isReasoningActive,
                    lastReasoningDuration: isReasoningAnchor ? lastReasoningDuration : nil,
                    isToolPhaseActive: isToolCallAnchor && isToolPhaseActive,
                    isAnswerStreaming: (isToolCallAnchor || isReasoningAnchor) && isAnswerStreaming,
                    // Scoped like the live props above it. Only the live row
                    // consumes this (it gates `animatesFold`), but passing the
                    // global flag to every row meant one scroll-proximity flip
                    // changed every row's inputs, defeating `.equatable()` and
                    // re-running every markdown-heavy body at once — a
                    // transcript-wide re-parse on the main thread, which is what
                    // made expanding a card stutter on a long chat.
                    isScrolledNearBottom: (isReasoningAnchor || isToolCallAnchor || isStreamingRow)
                        && isScrolledNearBottom,
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
                .id(transcriptMessage.renderID)

                if let compressionReferenceCard,
                   compressionReferenceCard.afterRenderID == transcriptMessage.renderID {
                    compressionReferenceCardView(compressionReferenceCard)
                }
            }

            transcriptLooseBlocks
            liveResponseBlocks
            inlineClarificationCard
            typingIndicator
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
        .background {
            ZStack {
                ChatScrollObserver(isStreaming: activeStreamID != nil) { metrics in
                    onUpdateScrollMetrics(metrics)
                }

                ChatScrollPositionPreserverView(controller: disclosurePositionPreserver)

                ChatVerticalScrollAxisGuard()
            }
            .accessibilityHidden(true)
        }
    }

    private func compressionReferenceCardView(_ card: CompressionReferenceCard) -> some View {
        MarkerMessageCardView(kind: .compressionReference, content: card.referenceText)
    }

    private var transcriptHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
    }

    private var chatPalette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(chatBackgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
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
        let renderID = displayedTranscriptMessages.first?.renderID
        let didLoad = await onLoadOlderMessages()
        guard didLoad, let renderID else { return }

        await Task.yield()
        if reduceMotion {
            proxy.scrollTo(renderID, anchor: .top)
        } else {
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                proxy.scrollTo(renderID, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var transcriptLooseBlocks: some View {
        reasoningBlocks(anchorMessageID: nil)
        toolCallGroups(anchorMessageID: nil)
    }

    @ViewBuilder
    private var liveResponseBlocks: some View {
        if activeStreamID != nil {
            if showsThinkingAndToolCards {
                liveActivityFold
            }

            if activeStreamRecoveryState != .idle {
                StreamRecoveryStatusView(state: activeStreamRecoveryState)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(hidesRunStatusAccessibility)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
    }

    /// Live thinking + tool blocks, folding into one summary row when a
    /// semantic final-answer token arrives. Legacy unphased streams stay open
    /// until completion rather than guessing that progress prose is final.
    ///
    /// **Deliberately not wrapped in `ActivityContainerView`.** The unified
    /// container is an end-of-turn presentation: it exists to make a settled
    /// turn's work read as one object once you go back and open it. While the
    /// turn is still running these blocks are live, independently-collapsing
    /// status surfaces, and boxing them changes what the reader is watching
    /// mid-stream.
    @ViewBuilder
    private var liveActivityFold: some View {
        let showsReasoning = hasLiveReasoningText
            && !hasDisplayedTranscriptMessage(anchorID: reasoningAnchorMessageID)
        let showsTools = !liveToolCalls.isEmpty
            && !hasDisplayedTranscriptMessage(anchorID: toolCallAnchorMessageID)

        if showsReasoning || showsTools {
            TurnActivityFoldView(
                isCollapsed: isAnswerStreaming,
                animatesFold: isScrolledNearBottom
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if showsReasoning {
                        ReasoningBlockView(
                            text: liveReasoningText,
                            isStreaming: isReasoningActive,
                            completedDuration: lastReasoningDuration,
                            preservesViewportOnExpand: true
                        )
                    }

                    if showsTools {
                        ToolActivityGroupView(
                            group: ToolCallGroup.live(
                                anchorMessageID: toolCallAnchorMessageID,
                                toolCalls: liveToolCalls
                            ),
                            isPhaseActive: isToolPhaseActive
                        )
                    }
                }
            } summary: { isExpanded, toggle in
                TurnActivitySummaryRow(
                    reasoningDuration: lastReasoningDuration,
                    toolCalls: liveToolCalls,
                    hasReasoning: showsReasoning,
                    isExpanded: isExpanded,
                    onTap: toggle
                )
            }
        }
    }

    @ViewBuilder
    private var inlineClarificationCard: some View {
        if let clarificationPrompt {
            ClarificationRequestCard(
                prompt: clarificationPrompt,
                isResponding: isRespondingToClarification,
                errorMessage: clarificationErrorMessage,
                onSubmit: onSubmitClarification
            )
            .id(clarificationPrompt.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var typingIndicator: some View {
        if showsAssistantTypingIndicator {
            AssistantTypingIndicatorView()
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
            .padding(.top, 2)
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
                ReasoningBlockView(
                    text: group.text,
                    preservesViewportOnExpand: true
                )
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
    let transcriptMessage: TranscriptMessage
    let transcriptBlockSpacing: CGFloat
    let showsThinkingAndToolCards: Bool
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    /// See `ChatTranscriptView.isReasoningActive` — scoped to the anchor row.
    let isReasoningActive: Bool
    /// See `ChatTranscriptView.lastReasoningDuration` — scoped to the anchor row.
    let lastReasoningDuration: TimeInterval?
    /// See `ChatTranscriptView.isToolPhaseActive` — scoped to the anchor row.
    let isToolPhaseActive: Bool
    /// See `ChatTranscriptView.isAnswerStreaming` — scoped to the anchor row.
    let isAnswerStreaming: Bool
    /// See `ChatTranscriptView.isScrolledNearBottom`; gates the fold animation
    /// so a collapse the reader cannot see is applied instantly instead.
    let isScrolledNearBottom: Bool
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
            lhs.transcriptBlockSpacing == rhs.transcriptBlockSpacing &&
            lhs.showsThinkingAndToolCards == rhs.showsThinkingAndToolCards &&
            lhs.reasoningGroups == rhs.reasoningGroups &&
            lhs.toolCallGroups == rhs.toolCallGroups &&
            lhs.liveReasoningText == rhs.liveReasoningText &&
            lhs.reasoningAnchorMessageID == rhs.reasoningAnchorMessageID &&
            lhs.isReasoningActive == rhs.isReasoningActive &&
            lhs.lastReasoningDuration == rhs.lastReasoningDuration &&
            lhs.isToolPhaseActive == rhs.isToolPhaseActive &&
            lhs.isAnswerStreaming == rhs.isAnswerStreaming &&
            lhs.isScrolledNearBottom == rhs.isScrolledNearBottom &&
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
        VStack(alignment: .leading, spacing: transcriptBlockSpacing) {
            activityFold

            if shouldRenderMessageRow(transcriptMessage.message) {
                ChatTranscriptMessageRow(
                    message: transcriptMessage.message,
                    visibleIndex: transcriptMessage.loadedIndex,
                    actionContext: actionContext(transcriptMessage.message, transcriptMessage.loadedIndex),
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
                // Guards the answer's markdown against the activity fold, its
                // sibling in this VStack — see the type's doc comment.
                .equatable()
            }
        }
    }

    /// The turn's thinking and tool activity, folded into one summary row once
    /// the answer starts streaming. Reconciled/historical rows mount already
    /// collapsed so the post-stream rebuild is invisible — see
    /// `TurnActivityFoldView`.
    ///
    /// The unified container is applied to **settled turns only**. It is an
    /// end-of-turn presentation: going back and opening a finished turn should
    /// read as one object. A turn that is still running keeps independent
    /// blocks, because those are live status surfaces the reader is watching
    /// change, not a record to review.
    @ViewBuilder
    private var activityFold: some View {
        if hasAnyActivity {
            TurnActivityFoldView(
                isCollapsed: isHistorical || isAnswerStreaming,
                initiallyCollapsed: isHistorical,
                animatesFold: !isHistorical && isScrolledNearBottom
            ) {
                if isHistorical {
                    ActivityContainerView(spacing: transcriptBlockSpacing) {
                        activitySections
                    }
                } else {
                    VStack(alignment: .leading, spacing: transcriptBlockSpacing) {
                        activitySections
                    }
                }
            } summary: { isExpanded, toggle in
                TurnActivitySummaryRow(
                    reasoningDuration: lastReasoningDuration,
                    toolCalls: summaryToolCalls,
                    hasReasoning: hasAnyReasoning,
                    isExpanded: isExpanded,
                    onTap: toggle
                )
            }
        }
    }

    /// A settled turn: this row is not the one the live stream is feeding, so
    /// its activity is reconstructed and must mount already folded.
    ///
    /// Deliberately per-row, not `!hasActiveStream`: that flag is global, so a
    /// session-wide "a stream is running" would un-fold *every* past turn the
    /// moment a new message is sent, then snap them all shut at `done`.
    private var isHistorical: Bool {
        !isLiveTurnRow
    }

    /// Whether the live stream is currently attached to this row.
    private var isLiveTurnRow: Bool {
        hasActiveStream
            && (reasoningAnchorMessageID == transcriptMessage.anchorID
                || toolCallAnchorMessageID == transcriptMessage.anchorID
                || streamingAssistantMessageID != nil)
    }

    private var hasAnyReasoning: Bool {
        shouldRenderLiveReasoningBlock
            || (showsThinkingAndToolCards
                && reasoningGroups.contains { $0.anchorMessageID == transcriptMessage.anchorID })
    }

    private var summaryToolCalls: [ToolCall] {
        if shouldRenderLiveToolActivityGroup { return liveToolCalls }
        return toolCallGroups.flatMap(\.toolCalls)
    }

    private var hasAnyActivity: Bool {
        hasAnyReasoning || !summaryToolCalls.isEmpty
    }

    @ViewBuilder
    private var reasoningBlocks: some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroups.filter { $0.anchorMessageID == transcriptMessage.anchorID }) { group in
                ReasoningBlockView(
                    text: group.text,
                    drawsOwnChrome: !isHistorical,
                    preservesViewportOnExpand: true
                )
            }
        }
    }

    @ViewBuilder
    private var liveReasoningBlock: some View {
        if shouldRenderLiveReasoningBlock {
            ReasoningBlockView(
                text: liveReasoningText,
                isStreaming: isReasoningActive,
                completedDuration: lastReasoningDuration,
                drawsOwnChrome: !isHistorical,
                preservesViewportOnExpand: true
            )
        }
    }

    @ViewBuilder
    private var toolActivityGroups: some View {
        if showsThinkingAndToolCards {
            ForEach(toolCallGroups) { group in
                ToolActivityGroupView(
                    group: group,
                    drawsOwnChrome: !isHistorical,
                    preparesHistoricalDisclosure: isHistorical
                )
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
                isPhaseActive: isToolPhaseActive,
                drawsOwnChrome: !isHistorical
            )
        }
    }

    /// The turn's blocks as container sections, with a hairline between each.
    ///
    /// The dividers are emitted between *rendered* sections rather than after
    /// every block, so a turn with only thinking (or only tools) gets no
    /// trailing rule. `hasReasoningSections` and `hasToolSections` mirror the
    /// same conditions the block builders above check.
    @ViewBuilder
    private var activitySections: some View {
        reasoningBlocks
        liveReasoningBlock

        // The divider is container furniture: it separates sections inside one
        // surface. A live turn's blocks are separate cards with their own
        // borders, so a rule between them would just be a second line.
        if isHistorical, hasReasoningSections, hasToolSections {
            ActivitySectionDivider()
        }

        toolActivityGroups
        liveToolActivityGroup
    }

    private var hasReasoningSections: Bool {
        let hasArchived = showsThinkingAndToolCards
            && reasoningGroups.contains { $0.anchorMessageID == transcriptMessage.anchorID }
        return hasArchived || shouldRenderLiveReasoningBlock
    }

    private var hasToolSections: Bool {
        let hasArchived = showsThinkingAndToolCards && !toolCallGroups.isEmpty
        return hasArchived || shouldRenderLiveToolActivityGroup
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

/// The answer bubble for one transcript row.
///
/// **Equatable is load-bearing.** This sits in the same `VStack` as
/// `activityFold`, so expanding or collapsing a turn's activity re-runs the
/// enclosing row body — and without a guard here, that re-runs this body too
/// and `Markdown(content)` re-parses the whole answer from scratch on the main
/// thread, mid-animation. On a long answer that is the stutter. The outer
/// `.equatable()` only stops *other* rows from invalidating; it cannot stop a
/// sibling inside the same row.
private struct ChatTranscriptMessageRow: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        // Closures are excluded deliberately: they are recreated on every
        // parent evaluation and would make this always-unequal, silently
        // restoring the re-parse. They capture the view model, which is a
        // reference type, so a stale capture still reads current state.
        lhs.message == rhs.message &&
            lhs.visibleIndex == rhs.visibleIndex &&
            lhs.actionContext == rhs.actionContext &&
            lhs.localAttachmentPreviews == rhs.localAttachmentPreviews &&
            lhs.listeningMessageID == rhs.listeningMessageID &&
            lhs.isViewingCachedData == rhs.isViewingCachedData &&
            lhs.hasActiveStream == rhs.hasActiveStream &&
            lhs.isStreaming == rhs.isStreaming &&
            lhs.liveTokensPerSecond == rhs.liveTokensPerSecond &&
            lhs.isRegeneratingMessage == rhs.isRegeneratingMessage &&
            lhs.isEditingMessage == rhs.isEditingMessage &&
            lhs.isForkingMessage == rhs.isForkingMessage &&
            lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace
    }

    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    let message: ChatMessage
    let visibleIndex: Int
    let actionContext: MessageActionContext?
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
        } else if let actionContext {
            bubble
                .contextMenu {
                    ChatMessageActionMenu(
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
                        onCopy: { context in
                            ChatHaptics.messageCopied(isEnabled: isHapticsEnabled)
                            onCopy(context)
                        }
                    )
                }
        } else {
            bubble
        }
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
            liveTokensPerSecond: liveTokensPerSecond
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
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
    }
}
