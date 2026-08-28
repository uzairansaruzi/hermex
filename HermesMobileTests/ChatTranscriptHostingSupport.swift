import SwiftUI
import UIKit
@testable import HermesMobile

enum HostedLayoutResult: Equatable {
    case hosted
    case unavailable(String)
}

@MainActor
enum ChatTranscriptHostingSupport {
    static let bottomAnchorID = "chat-bottom-anchor"

    static func transcriptView(
        from viewModel: ChatViewModel,
        followScroll: Bool = true
    ) -> ChatTranscriptView {
        ChatTranscriptView(
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            messages: viewModel.messages,
            displayedTranscriptMessages: viewModel.displayedTranscriptMessages,
            compressionReferenceCard: viewModel.compressionReferenceCard,
            reasoningGroups: viewModel.displayedReasoningGroups,
            completedToolCallGroupsForAnchor: { anchorMessageID in
                viewModel.completedToolCallGroupsForAnchor(anchorMessageID)
            },
            liveReasoningText: viewModel.liveReasoningText,
            reasoningAnchorMessageID: viewModel.reasoningAnchorMessageID,
            liveToolCalls: viewModel.liveToolCalls,
            toolCallAnchorMessageID: viewModel.toolCallAnchorMessageID,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID,
            liveTokensPerSecond: viewModel.liveTokensPerSecond,
            activeStreamRecoveryState: viewModel.activeStreamRecoveryState,
            clarificationPrompt: viewModel.clarificationPrompt,
            isRespondingToClarification: viewModel.isRespondingToClarification,
            clarificationErrorMessage: viewModel.clarificationErrorMessage,
            hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: true,
            showsAssistantTypingIndicator: ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
                hasActiveStream: viewModel.activeStreamID != nil,
                isCancellingStream: viewModel.isCancellingStream,
                hasStreamingAssistantMessage: viewModel.hasStreamingAssistantMessageContent,
                hasPendingClarificationPrompt: viewModel.clarificationPrompt != nil,
                liveReasoningText: viewModel.liveReasoningText,
                hasLiveToolCalls: !viewModel.liveToolCalls.isEmpty,
                showsThinkingAndToolCards: true
            ),
            showsScrollToBottomButton: false,
            shouldFollowLatestMessage: followScroll,
            latestTranscriptMessageRole: viewModel.displayedTranscriptMessages.last?.message.role,
            isScrolledNearBottom: true,
            activeStreamID: viewModel.activeStreamID,
            streamingScrollTrigger: viewModel.streamingScrollTrigger,
            cacheFirstReconcileScrollToken: viewModel.cacheFirstReconcileScrollToken,
            bottomAnchorID: bottomAnchorID,
            transcriptMessageSpacing: 10,
            transcriptBlockSpacing: 6,
            transcriptBottomInsetHeight: 96,
            scrollToBottomButtonBottomPadding: 12,
            localAttachmentPreviews: viewModel.localAttachmentPreviews,
            listeningMessageID: viewModel.listeningMessageID,
            isViewingCachedData: viewModel.isViewingCachedData,
            hasOlderMessages: viewModel.hasOlderMessages,
            isLoadingOlderMessages: viewModel.isLoadingOlderMessages,
            isRegeneratingMessage: viewModel.isRegeneratingMessage,
            isEditingMessage: viewModel.isEditingMessage,
            isForkingMessage: viewModel.isForkingMessage,
            loadAttachmentImage: { _ in nil },
            loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "https://example.test|performance-session",
            actionContext: { _, _ in nil },
            shouldRenderMessageRow: { message in
                if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return true
                }
                return message.role == "user" && message.attachments?.isEmpty == false
            },
            onLoadMessages: {},
            onLoadOlderMessages: { await viewModel.loadOlderMessages() },
            onUpdateScrollMetrics: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { proxy in
                scrollWithoutAnimation(proxy, id: bottomAnchorID)
            },
            onScrollToLatestTranscriptMessage: { proxy in
                if let id = viewModel.displayedTranscriptMessages.last?.id {
                    scrollWithoutAnimation(proxy, id: id)
                } else {
                    scrollWithoutAnimation(proxy, id: bottomAnchorID)
                }
            },
            onScrollToLatestContent: { proxy, _ in
                scrollWithoutAnimation(proxy, id: bottomAnchorID)
            },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in },
            onSubmitClarification: { _ in },
            onSelectText: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in }
        )
    }

    static func host(
        _ view: ChatTranscriptView,
        animationsEnabled: Bool = false
    ) -> (UIWindow, UIHostingController<ChatTranscriptView>) {
        if !animationsEnabled {
            UIView.setAnimationsEnabled(false)
        }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        host.view.frame = window.bounds
        window.rootViewController = host
        if animationsEnabled {
            window.makeKeyAndVisible()
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                window.makeKeyAndVisible()
            }
        }
        return (window, host)
    }

    static func applySnapshot(
        _ view: ChatTranscriptView,
        to host: UIHostingController<ChatTranscriptView>,
        animationsEnabled: Bool = false
    ) {
        if animationsEnabled {
            host.rootView = view
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            host.rootView = view
        }
    }

    /// Returns `.hosted` after a successful layout, or `.unavailable(reason)` on timeout / empty bounds / layout-loop cap.
    static func layoutPass(
        window: UIWindow,
        host: UIHostingController<ChatTranscriptView>,
        timeout: TimeInterval
    ) -> HostedLayoutResult {
        if timeout <= 0 {
            return .unavailable("timeout")
        }

        let startPasses = ChatPerformanceInstrumentation.shared.summary.counters[
            ChatPerformancePhase.transcriptLayoutPasses.rawValue
        ] ?? 0
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            window.setNeedsLayout()
            window.layoutIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))

            let passes = ChatPerformanceInstrumentation.shared.summary.counters[
                ChatPerformancePhase.transcriptLayoutPasses.rawValue
            ] ?? 0
            if passes - startPasses > 10_000 {
                return .unavailable("layout-loop")
            }

            let evaluations = ChatPerformanceInstrumentation.shared.summary.counters[
                ChatPerformancePhase.transcriptContentEvaluations.rawValue
            ] ?? 0
            let hasBounds = host.view.bounds.width > 0 && host.view.bounds.height > 0
            if host.view.window != nil, hasBounds, (evaluations >= 1 || passes > startPasses) {
                return .hosted
            }
        }

        if host.view.window == nil {
            return .unavailable("hosting-exception")
        }
        if host.view.bounds.width <= 0 || host.view.bounds.height <= 0 {
            return .unavailable("empty-bounds")
        }
        return .hosted
    }

    private static func scrollWithoutAnimation(_ proxy: ScrollViewProxy, id: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}
