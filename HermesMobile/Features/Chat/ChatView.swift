import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

private enum GitChatAlert: Identifiable {
    case confirmRemote(GitRemoteAction)
    case dirtyCheckout(GitCheckoutTarget)
    case error(String)

    var id: String {
        switch self {
        case .confirmRemote(let action): "remote:\(action.rawValue)"
        case .dirtyCheckout(let target): "checkout:\(target.id)"
        case .error(let message): "error:\(message)"
        }
    }
}

private enum ActiveGitSheet: Identifiable {
    case changes
    case commit

    var id: Self { self }
}

/// What the per-turn diff sheet shows (issue #316): every changed file in the turn, or a
/// single file's diff (a recap-card row tap).
private enum TurnDiffPresentation: Identifiable {
    case turnFiles([GitFile])
    case file(GitFile)

    var id: String {
        switch self {
        case .turnFiles(let files): return "turn:" + files.map(\.id).joined(separator: "|")
        case .file(let file): return "file:" + file.id
        }
    }
}

/// Reports the first completed UIKit appearance transition for a SwiftUI destination.
/// `NavigationStack` does not expose push completion directly, while `viewDidAppear`
/// and the transition coordinator remain synchronized with system animation speed.
struct NavigationAppearanceCompletionObserver: UIViewControllerRepresentable {
    let action: @MainActor () -> Void

    func makeUIViewController(context: Context) -> NavigationAppearanceObserverViewController {
        NavigationAppearanceObserverViewController(action: action)
    }

    func updateUIViewController(
        _ uiViewController: NavigationAppearanceObserverViewController,
        context: Context
    ) {
        uiViewController.action = action
    }
}

@MainActor
final class NavigationAppearanceObserverViewController: UIViewController {
    var action: @MainActor () -> Void

    private var isAwaitingTransitionCompletion = false
    private var didReportAppearance = false

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        guard !didReportAppearance, let coordinator = transitionCoordinator else { return }
        isAwaitingTransitionCompletion = true
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            isAwaitingTransitionCompletion = false
            guard !context.isCancelled else { return }
            reportAppearanceIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isAwaitingTransitionCompletion else { return }
        reportAppearanceIfNeeded()
    }

    private func reportAppearanceIfNeeded() {
        guard !didReportAppearance else { return }
        didReportAppearance = true
        action()
    }
}

private struct ListenPlaybackBar: View {
    let phase: ListenPlaybackPhase
    let displayTime: TimeInterval
    let duration: TimeInterval
    let speed: ListenPlaybackSpeed
    let onTogglePlayPause: () -> Void
    let onStop: () -> Void
    let onScrub: (TimeInterval) -> Void
    let onScrubbingChanged: (Bool) -> Void
    let onSpeedChange: (ListenPlaybackSpeed) -> Void

    private var isReady: Bool {
        phase == .playing || phase == .paused
    }

    private var isPlaying: Bool {
        phase == .playing
    }

    private var boundedDisplayTime: TimeInterval {
        min(max(0, displayTime), max(duration, 0))
    }

    private var sliderUpperBound: TimeInterval {
        max(duration, 0.01)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                playPauseButton

                VStack(alignment: .leading, spacing: 4) {
                    scrubber
                    timeRow
                }
                .frame(maxWidth: .infinity)

                speedMenu
                stopButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var playPauseButton: some View {
        if phase == .loading {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.accentColor)
            }
            .frame(width: 34, height: 34)
            .accessibilityLabel(String(localized: "Preparing audio"))
        } else {
            Button(action: onTogglePlayPause) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.chatTactile(.icon))
            .disabled(!isReady)
            .accessibilityLabel(isPlaying ? String(localized: "Pause audio") : String(localized: "Play audio"))
        }
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { boundedDisplayTime },
                set: { onScrub($0) }
            ),
            in: 0...sliderUpperBound,
            onEditingChanged: onScrubbingChanged
        )
        .tint(Color.accentColor)
        .disabled(!isReady || duration <= 0)
        .accessibilityLabel(String(localized: "Playback position"))
    }

    private var timeRow: some View {
        HStack(spacing: 8) {
            Text(AudioDurationFormatter.string(from: boundedDisplayTime))
            Text("/")
            Text(AudioDurationFormatter.string(from: duration))
            Spacer(minLength: 0)
        }
        .font(AppFont.caption2().monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(AudioDurationFormatter.string(from: boundedDisplayTime)) of \(AudioDurationFormatter.string(from: duration))"))
    }

    private var speedMenu: some View {
        Menu {
            ForEach(ListenPlaybackSpeed.allCases) { option in
                Button {
                    onSpeedChange(option)
                } label: {
                    HStack {
                        Text(option.title)
                        if option == speed {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(speed.title)
                .font(AppFont.caption().weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 36, minHeight: 30)
                .padding(.horizontal, 6)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .disabled(!isReady)
        .accessibilityLabel(String(localized: "Playback speed"))
        .accessibilityValue(speed.title)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .accessibilityLabel(String(localized: "Stop audio"))
    }
}

struct ChatView: View {
    private let bottomAnchorID = "chat-bottom-anchor"
    private let transcriptSpacing: CGFloat = 8
    private let composerAccessoryVerticalSpacing: CGFloat = 8
    private let activeRunStatusSpacerHeight: CGFloat = 36
    private let approvalBypassStatusSpacerHeight: CGFloat = 38

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(AppHaptics.streamingPulseIsEnabledKey) private var isStreamingPulseEnabled = false
    @AppStorage(StreamingSendBehavior.storageKey) private var streamingSendBehaviorRawValue = StreamingSendBehavior.steer.rawValue
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @AppStorage(AgentRunLiveActivityPrivacy.showsResponseExcerptsKey) private var showsLiveActivityResponseExcerpts = false
    @AppStorage(ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey) private var showsThinkingAndToolCards = true
    @AppStorage(ChatTranscriptDisplaySettings.foldsSettledTurnsKey) private var foldsSettledTurns = true
    @AppStorage(ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey) private var rtlChatLayoutEnabled = ChatTranscriptDisplaySettings.rtlChatLayoutDefaultEnabled
    @AppStorage(SectionVisibilitySettings.chatFilesKey) private var showsFilesButton = true
    @AppStorage(SectionVisibilitySettings.chatGitKey) private var showsGitControls = true

    let session: SessionSummary
    let server: URL
    let onAPIError: (Error) -> Void
    let loadsInitialMessages: Bool
    /// When true, the composer auto-starts voice dictation on appear — set by the
    /// "New Chat with Voice" App Intent (#338). Defaults to false for normal opens.
    let autoStartsVoiceInput: Bool
    let draftStore: ChatDraftStore
    /// Store holding the durable app-owned copies of staged attachments.
    let draftAttachmentStore: any ChatDraftAttachmentStoring
    /// True only for the pending-new-chat flow: after the composer configuration
    /// loads, the restored draft's settings snapshot is applied (each value
    /// revalidated against the live server configuration). Existing sessions
    /// load their configuration from the server and never re-apply a snapshot.
    let restoresDraftSettings: Bool
    let onConversationStarted: () -> Void

    @State private var draftMessage = ""
    @State private var draftRevision = 0
    @State private var isScrolledNearBottom = true
    @State private var followLatch = ChatScrollPolicy.FollowLatch()
    @State private var followScrollGeneration = 0
    /// While true the transcript's bottom size-change anchor and follow-driven
    /// scrolls are suspended so a disclosure toggle grows or shrinks in place.
    @State private var isDisclosureSettling = false
    @State private var disclosureSettleGeneration = 0
    /// Settled turns the user has opened, plus failed or stopped turns, which
    /// start open. Keyed by turn so paging older messages in does not shift them.
    @State private var expandedTurnKeys: Set<String> = []
    /// While set and in the future, auto-follow scrolls snap instead of animating, so
    /// the cache-first → network reconcile re-pins to the bottom without a jump (#289).
    @State private var cacheFirstSnapUntil: Date?
    @State private var forkedSession: SessionSummary?
    @State private var editContext: MessageActionContext?
    @State private var editDraft = ""
    @State private var showEditSheet = false
    @State private var showEditDiscardConfirmation = false
    @State private var regenerateContext: MessageActionContext?
    @State private var showRegenerateDiscardConfirmation = false
    @State private var selectableResponseText: SelectableTextPresentation?
    @State private var attachmentPreviewItem: ChatAttachmentPreviewItem?
    @State private var transcriptMediaPreviewItem: TranscriptMediaPreviewItem?
    @State private var pendingProfileSelection: ProfileSummary?
    @State private var showProfileNewSessionConfirmation = false
    @State private var goalDraft = ""
    @State private var showsGoalSheet = false
    @State private var activeGitSheet: ActiveGitSheet?
    @State private var turnDiffPresentation: TurnDiffPresentation?
    @State private var viewModel: ChatViewModel
    @State private var gitAvailabilityViewModel: GitWorkspaceAvailabilityViewModel
    @State private var gitToastState = GitActionToastState()
    @State private var gitAlert: GitChatAlert?
    @State private var composerHeight: CGFloat = 52
    /// Measured height of the collapsed clarification bar, the request's only
    /// layout footprint; the expanded card overlays the transcript instead.
    @State private var clarificationBarHeight: CGFloat = 0
    @State private var composerIsFocused = false
    @State private var didHydrateDraft = false
    /// Whether this chat has already asked the server for its skills on the
    /// transcript's behalf, so a request that failed does not repeat with every
    /// later transcript update.
    @State private var hasRequestedSkillsForTranscriptChips = false
    /// True from the moment hydration finds persisted attachment records until
    /// their restore pass finishes. It gates `syncDraftAttachments` across the
    /// whole window, so the not-yet-rebuilt composer strip can never overwrite
    /// the persisted set.
    @State private var isRestoringDraftAttachments = false
    /// Records hydration found, handed to the restore pass that runs alongside
    /// the transcript load rather than in front of it.
    @State private var draftAttachmentsAwaitingRestore: [ChatDraftAttachment] = []
    /// Restored attachment records whose re-upload failed; they stay in the
    /// draft for a later retry and are unioned into every attachment sync.
    @State private var draftAttachmentsPendingRetry: [ChatDraftAttachment] = []
    @State private var lastSyncedDraftAttachments: [ChatDraftAttachment] = []
    @State private var restoredDraftSettings: ChatDraftSettings?
    @State private var didApplyRestoredDraftSettings = false
    @State private var didCompleteInitialAppearance = false
    @State private var isInitialComposerFocusContentReady = false
    @State private var didApplyInitialComposerFocusPolicy = false
    @State private var shouldRestoreComposerFocusAfterPreview = false
    @State private var responseCompletionNotificationTracker = ResponseCompletionNotificationTracker()
    @State private var responseCompletionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var activeStreamStatusRefreshTask: Task<Void, Never>?
    @State private var initialAttachments: [SharedAttachmentImport]
    @State private var didUploadInitialAttachments = false

    init(
        session: SessionSummary,
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        loadsInitialMessages: Bool = true,
        autoStartsVoiceInput: Bool = false,
        draftStore: ChatDraftStore? = nil,
        draftAttachmentStore: (any ChatDraftAttachmentStoring)? = nil,
        restoresDraftSettings: Bool = false,
        onConversationStarted: @escaping () -> Void = {}
    ) {
        self.session = session
        self.server = server
        self.onAPIError = onAPIError
        self.loadsInitialMessages = loadsInitialMessages
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.draftStore = draftStore ?? .shared
        let resolvedDraftAttachmentStore = draftAttachmentStore ?? ChatDraftAttachmentStore.shared
        self.draftAttachmentStore = resolvedDraftAttachmentStore
        self.restoresDraftSettings = restoresDraftSettings
        self.onConversationStarted = onConversationStarted
        _draftMessage = State(initialValue: initialDraft)
        _initialAttachments = State(initialValue: initialAttachments)
        _viewModel = State(initialValue: ChatViewModel(
            session: session,
            server: server,
            showsLiveActivityResponseExcerpts: UserDefaults.standard.bool(
                forKey: AgentRunLiveActivityPrivacy.showsResponseExcerptsKey
            ),
            draftAttachmentStore: resolvedDraftAttachmentStore
        ))
        _gitAvailabilityViewModel = State(initialValue: GitWorkspaceAvailabilityViewModel(
            session: session,
            server: server
        ))
    }

    // Extracted from `body` so the type-checker doesn't have to solve the whole composer
    // call alongside the rest of the screen in one expression (#316 pushed it over the
    // "unable to type-check in reasonable time" limit).
    private var messageComposer: some View {
        MessageComposerView(
            draftMessage: persistedDraftBinding,
            isFocused: $composerIsFocused,
            isSending: viewModel.isStartingChat || viewModel.isSendingVoiceNote,
            isCompressingSession: viewModel.isCompressingSession,
            isWaitingForStream: viewModel.activeStreamID != nil,
            isCancellingStream: viewModel.isCancellingStream,
            readOnlyMessage: composerReadOnlyMessage,
            errorMessage: viewModel.sendErrorMessage,
            configurationErrorMessage: viewModel.composerConfigurationErrorMessage,
            contextWindowSnapshot: viewModel.contextWindowSnapshot,
            gitViewModel: gitAvailabilityViewModel,
            modelGroups: viewModel.modelCatalogGroups,
            selectedModelID: viewModel.selectedModelID,
            selectedModelProviderID: viewModel.selectedModelProviderID,
            selectedModelTitle: viewModel.selectedModelTitle,
            workspaceRoots: viewModel.workspaceRoots,
            selectedWorkspacePath: viewModel.selectedWorkspacePath,
            workspaceSuggestions: viewModel.workspaceSuggestions,
            workspaceManagementServer: server,
            personalitySuggestions: viewModel.personalitySuggestions,
            skillSuggestions: viewModel.skillSlashSuggestions,
            hasLoadedSkillSuggestions: viewModel.hasLoadedSkillSlashSuggestions,
            agentCommands: viewModel.agentCommands,
            profileOptions: viewModel.profileOptions,
            isSingleProfileMode: viewModel.isSingleProfileMode,
            selectedProfileName: viewModel.selectedProfileName,
            selectedProfileTitle: viewModel.selectedProfileTitle,
            selectedReasoningEffort: viewModel.selectedReasoningEffort,
            supportedReasoningEfforts: viewModel.supportedReasoningEfforts,
            supportsReasoningEffort: viewModel.supportsReasoningEffort,
            showsReasoningControl: viewModel.showsReasoningEffortControl,
            isUpdatingConfiguration: viewModel.isUpdatingComposerConfiguration,
            pendingAttachments: viewModel.pendingAttachments,
            // An in-flight draft restore counts as an upload in progress: until
            // it finishes, the composer does not yet hold the attachments the
            // user expects this message to carry.
            isUploadingAttachment: viewModel.isUploadingAttachment || isRestoringDraftAttachments,
            attachmentUploadCount: viewModel.attachmentUploadCount,
            attachmentUploadGeneration: viewModel.attachmentUploadGeneration,
            isSendingVoiceNote: viewModel.isSendingVoiceNote,
            autoStartsVoiceInput: autoStartsVoiceInput,
            apiClient: viewModel.client,
            uploadAttachmentErrorMessage: viewModel.uploadAttachmentErrorMessage,
            onSend: {
                Task { await sendDraftMessage() }
            },
            onSendVoiceNote: { data, filename in
                Task { await sendVoiceNote(audioData: data, filename: filename) }
            },
            onCancel: {
                Task { await cancelStream() }
            },
            onSelectModel: { option in
                Task {
                    let didSelect = await viewModel.selectComposerModel(option)
                    if didSelect {
                        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                    }
                }
            },
            onModelPickerOpen: {
                await viewModel.refreshModelCatalogForPickerOpen()
            },
            onSelectReasoningEffort: { effort in
                Task {
                    let didSelect = await viewModel.selectReasoningEffort(effort)
                    if didSelect {
                        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                    }
                }
            },
            onLoadWorkspaceSuggestions: { prefix in
                await viewModel.loadWorkspaceSuggestions(prefix: prefix)
            },
            onWorkspaceRegistryChanged: {
                await viewModel.refreshWorkspaceRoots()
            },
            onLoadPersonalitySuggestions: {
                await viewModel.loadPersonalitySuggestions()
            },
            onLoadSkillSuggestions: {
                await viewModel.loadSkillSlashSuggestions()
            },
            onSelectWorkspace: { path in
                let didSelect = await viewModel.selectWorkspacePath(path)
                if didSelect {
                    ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                }
            },
            onSelectProfile: { profile in
                handleProfileSelection(profile)
            },
            onHeightChange: { height in
                composerHeight = height
            },
            onPhotoItemSelected: { item in
                Task { await handlePhotoSelection(item) }
            },
            onFileURLsSelected: { urls in
                Task { await handleSelectedFileURLs(urls) }
            },
            onPasteFileProviders: { providers in
                Task { await handlePastedFileProviders(providers) }
            },
            onPasteFileURLs: { urls in
                Task { await handlePastedFileURLs(urls) }
            },
            onPasteImageProviders: { providers in
                Task { await handlePastedImageProviders(providers) }
            },
            onPasteImages: { images in
                Task { await handlePastedImages(images) }
            },
            onRemoveAttachment: { id in
                let removedAttachment = viewModel.pendingAttachments.first(where: { $0.id == id })
                viewModel.removePendingAttachment(id: id)
                // Explicit discard: the record drops out of the draft via the
                // observation sync; delete its now-unreferenced local copy.
                if let file = removedAttachment?.draftFileName {
                    Task { await draftAttachmentStore.delete(named: file) }
                }
            },
            onPreviewAttachment: { attachment in
                presentPreviewRestoringComposerFocusIfNeeded {
                    attachmentPreviewItem = ChatAttachmentPreviewItem(pending: attachment)
                }
            },
            onDismissUploadAttachmentError: {
                viewModel.setUploadAttachmentError(nil)
            },
            onSelectGitBranch: { target in
                Task { await performGitCheckout(target) }
            },
            onCreateGitBranch: { target in
                Task { await performGitCheckout(target) }
            },
            onRefreshGitBranches: {
                Task { await gitAvailabilityViewModel.loadBranches() }
            }
        )
        // The composer flips wholesale with the transcript under the RTL
        // toggle (#259): input, placeholder, and chrome mirror together.
        .environment(\.layoutDirection, chatLayoutDirection)
        .background(
            NavigationAppearanceCompletionObserver(action: handleInitialAppearanceCompletion)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    private var composerReadOnlyMessage: String? {
        Self.composerReadOnlyMessage(
            for: session,
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    static func composerReadOnlyMessage(
        for session: SessionSummary,
        isViewingCachedData: Bool
    ) -> String? {
        if isViewingCachedData {
            return String(localized: "Reconnect to send messages.")
        }
        if session.isSessionReadOnly {
            return String(localized: "Read-only")
        }
        return nil
    }

    private func transcriptMediaPreviewView(for item: TranscriptMediaPreviewItem) -> some View {
        TranscriptMediaPreviewView(
            server: server,
            sessionID: transcriptMediaSessionID,
            item: item,
            onAPIError: onAPIError
        )
    }

    private var transcriptMediaSessionID: String? {
        guard let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

    private var transcriptMediaCacheNamespace: String {
        "\(server.absoluteString)|\(transcriptMediaSessionID ?? "local:\(session.id)")"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if viewModel.isViewingCachedData {
                    ChatOfflineCacheBanner()
                }

                listenPlaybackBar

                messageContent
                    // Scope RTL to the chat transcript only (#259): the offline
                    // banner above stays in the app's default direction.
                    .environment(\.layoutDirection, chatLayoutDirection)
            }
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: viewModel.showsListenPlaybackBar)

            BottomComposerMaterialFade(composerHeight: composerHeight)

            composerAccessoryStack

            clarificationInset

            messageComposer

            if let approvalPrompt = viewModel.approvalPrompt {
                ApprovalRequestOverlay(
                    prompt: approvalPrompt,
                    isResponding: viewModel.isRespondingToApproval,
                    errorMessage: viewModel.approvalErrorMessage,
                    onChoice: { choice in
                        Task {
                            let didRespond = await viewModel.respondToApproval(choice)
                            if didRespond {
                                ChatHaptics.approvalSubmitted(choice, isEnabled: isHapticsEnabled)
                            }
                        }
                    },
                    onSkipAll: {
                        Task {
                            let didSkip = await viewModel.skipApprovalsForCurrentSession()
                            if didSkip {
                                ChatHaptics.approvalBypassEnabled(isEnabled: isHapticsEnabled)
                            }
                        }
                    }
                )
                .zIndex(10)
            }
        }
        .overlay(alignment: .top) {
            GitActionToastOverlay(state: gitToastState)
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chat-detail:\(viewModel.displayTitle)")
        .task(id: didCompleteInitialAppearance) {
            await handleInitialAppearanceTask()
        }
        .onChange(of: scenePhase) {
                handleScenePhaseChange(scenePhase)
            }
            .onChange(of: viewModel.activeStreamID) {
                handleActiveStreamChange()
            }
            .onChange(of: viewModel.transcriptRelayoutScrollToken) {
                // Open a brief snap window so the cache-first reconcile re-pin (and any
                // message-count auto-follow racing it) lands without an animated jump (#289).
                cacheFirstSnapUntil = Date().addingTimeInterval(0.35)
            }
            .onChange(of: viewModel.isUploadingAttachment) { _, isUploading in
                if !isUploading {
                    applyInitialComposerFocusPolicyIfNeeded()
                }
            }
            .onChange(of: viewModel.uploadAttachmentErrorMessage) { _, newValue in
                if newValue == nil {
                    applyInitialComposerFocusPolicyIfNeeded()
                }
            }
            .modifier(
                ChatDraftSyncModifier(
                    pendingAttachments: viewModel.pendingAttachments,
                    composerSettings: currentComposerSettings,
                    onAttachmentsChange: syncDraftAttachments,
                    onSettingsChange: syncDraftSettings
                )
            )
            .onChange(of: showsLiveActivityResponseExcerpts) {
                viewModel.setShowsLiveActivityResponseExcerpts(showsLiveActivityResponseExcerpts)
            }
            .onDisappear {
                flushDraftsBestEffort()
                activeStreamStatusRefreshTask?.cancel()
                activeStreamStatusRefreshTask = nil
                viewModel.stopListening()
                viewModel.suspendStreamForNavigation()
                viewModel.cleanupPollingTasks()
            }
            .onAppear {
                Task {
                    await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)

                    if viewModel.activeStreamID != nil {
                        handleActiveStreamChange()
                    }

                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                }
            }
            .onChange(of: viewModel.responseCompletionHapticTrigger) {
                guard viewModel.responseCompletionHapticTrigger > 0 else { return }
                handleResponseCompletionSideEffects()
            }
            .onChange(of: viewModel.streamingHapticPulseTrigger, handleStreamingHapticPulse)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ChatToolbarTitleLabel(
                        title: displayTitle,
                        subtitle: headerSubtitle
                    )
                }

                ToolbarItem(placement: .topBarTrailing) {
                    ChatToolbarActionCluster {
                        if viewModel.hasActivatedGoalCommand {
                            ChatToolbarActionSlot {
                                goalControlMenu
                            }
                        }

                        if showsFilesButton {
                            ChatToolbarActionSlot {
                                NavigationLink {
                                    FileBrowserView(session: session, server: server, onAPIError: onAPIError)
                                } label: {
                                    Label("Files", systemImage: "folder")
                                }
                                .disabled(viewModel.isViewingCachedData)
                                .accessibilityLabel("Files")
                            }
                        }

                        if showsGitControls, gitAvailabilityViewModel.hasRepository {
                            ChatToolbarActionSlot {
                                gitActionsMenu
                            }
                        }
                    }
                }
            }
            .navigationDestination(item: $forkedSession) { session in
                ChatView(session: session, server: server, onAPIError: onAPIError)
            }
            .fullScreenCover(item: $selectableResponseText) { selectableText in
                SelectableTextPresentationView(selection: selectableText)
            }
            .sheet(item: $attachmentPreviewItem) { item in
                ChatAttachmentPreviewView(
                    session: session,
                    server: server,
                    item: item,
                    onAPIError: onAPIError
                )
            }
            .onChange(of: attachmentPreviewItem == nil) { _, isDismissed in
                if isDismissed {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .sheet(item: $transcriptMediaPreviewItem, content: transcriptMediaPreviewView)
            .sheet(item: $activeGitSheet, content: gitSheet)
            .sheet(item: $turnDiffPresentation, content: turnDiffSheet)
            .alert(item: $gitAlert, content: gitAlertPresentation)
            .sheet(isPresented: $showsGoalSheet) {
                GoalSubmissionSheet(
                    goalDraft: $goalDraft,
                    isSubmitting: viewModel.isSubmittingGoal,
                    onSubmit: { submittedGoal in
                        Task { await submitGoalDraft(submittedGoal) }
                    }
                )
            }
            .sheet(isPresented: $showEditSheet) {
                EditMessageSheet(
                    originalText: editContext?.copyText ?? "",
                    editDraft: $editDraft,
                    onSubmit: {
                        if let context = editContext {
                            Task { await submitEdit(context) }
                        }
                    }
                )
            }
            .alert(
                "Discard Later Messages?",
                isPresented: $showEditDiscardConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    editContext = nil
                    editDraft = ""
                }
                Button("Discard & Edit", role: .destructive) {
                    ChatHaptics.destructiveConfirmationAccepted(isEnabled: isHapticsEnabled)
                    showEditSheet = true
                }
            } message: {
                Text(editDiscardWarningMessage)
            }
            .alert(
                "Discard Later Messages?",
                isPresented: $showRegenerateDiscardConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    regenerateContext = nil
                }
                Button("Discard & Regenerate", role: .destructive) {
                    if let context = regenerateContext {
                        ChatHaptics.destructiveConfirmationAccepted(isEnabled: isHapticsEnabled)
                        Task { await submitRegenerate(context) }
                    }
                }
            } message: {
                Text(regenerateDiscardWarningMessage)
            }
            .alert(
                "Start New Session?",
                isPresented: $showProfileNewSessionConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    pendingProfileSelection = nil
                }
                Button("Start New Session") {
                    if let profile = pendingProfileSelection {
                        Task { await switchProfile(profile, startNewSession: true) }
                    }
                }
            } message: {
                Text(profileSwitchWarningMessage)
            }
            .alert(
                "Message Action Failed",
                isPresented: Binding(
                    get: { viewModel.messageActionErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.clearMessageActionError()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.clearMessageActionError()
                }
            } message: {
                Text(viewModel.messageActionErrorMessage ?? "")
            }
    }

    @ViewBuilder
    private var listenPlaybackBar: some View {
        if viewModel.showsListenPlaybackBar {
            ListenPlaybackBar(
                phase: viewModel.listenPlaybackPhase,
                displayTime: viewModel.listenPlaybackDisplayTime,
                duration: viewModel.listenPlaybackDuration,
                speed: viewModel.listenPlaybackSpeed,
                onTogglePlayPause: {
                    viewModel.toggleListenPlaybackPlayPause()
                },
                onStop: {
                    viewModel.stopListening()
                },
                onScrub: { time in
                    viewModel.scrubListenPlayback(to: time)
                },
                onScrubbingChanged: { isScrubbing in
                    viewModel.setListenPlaybackScrubbing(isScrubbing)
                },
                onSpeedChange: { speed in
                    viewModel.setListenPlaybackSpeed(speed)
                }
            )
            .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
        }
    }

    private var gitWriteAvailability: GitWriteAvailability {
        GitWriteAvailability(
            isStreaming: viewModel.activeStreamID != nil,
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    @ViewBuilder
    private func gitSheet(_ sheet: ActiveGitSheet) -> some View {
        switch sheet {
        case .changes:
            GitWorkspaceView(session: session, server: server, onAPIError: onAPIError)
        case .commit:
            GitCommitView(
                session: session,
                server: server,
                writesDisabled: gitWriteAvailability.writesDisabled,
                onAPIError: onAPIError,
                onCommitted: {
                    Task { await gitAvailabilityViewModel.refreshAfterExternalMutation() }
                }
            )
        }
    }

    @ViewBuilder
    private func turnDiffSheet(_ presentation: TurnDiffPresentation) -> some View {
        switch presentation {
        case .turnFiles(let files):
            GitTurnDiffSheet(session: session, server: server, files: files, onAPIError: onAPIError)
        case .file(let file):
            GitDiffView(session: session, server: server, file: file, onAPIError: onAPIError)
        }
    }

    private var gitActionsMenu: some View {
        GitActionsMenuButton(
            presentation: GitToolbarPresentation(
                hasRepository: gitAvailabilityViewModel.hasRepository,
                isLoading: gitAvailabilityViewModel.isLoading || gitAvailabilityViewModel.isStatusLoading,
                info: gitAvailabilityViewModel.gitInfo,
                status: gitAvailabilityViewModel.status,
                statusFailed: gitAvailabilityViewModel.statusError != nil
            ),
            isEnabled: !viewModel.isViewingCachedData,
            fetchDisabled: gitWriteAvailability.fetchDisabled,
            writesDisabled: gitWriteAvailability.writesDisabled,
            isRunningAction: gitAvailabilityViewModel.isRunningGitAction,
            onTap: {
                HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            },
            onChanges: {
                activeGitSheet = .changes
            },
            onStageEdit: {
                activeGitSheet = .commit
            },
            onCommit: {
                Task { await performQuickCommit(push: false) }
            },
            onCommitAndPush: {
                Task { await performQuickCommit(push: true) }
            },
            onFetch: {
                Task { await performGitRemoteAction(.fetch) }
            },
            onPull: {
                gitAlert = .confirmRemote(.pull)
            },
            onPush: {
                gitAlert = .confirmRemote(.push)
            }
        )
    }

    /// Inputs for the inline "Commit & Push" button shown under the latest assistant turn.
    /// Only for git workspaces, when the latest message is an assistant turn (not while a
    /// response streams), and there is something to commit (or a commit is in flight).
    private var inlineCommitContext: ChatInlineCommitContext? {
        guard ChatGitControlsVisibilityPolicy.showsInlineCommitButton(
            showsGitControls: showsGitControls,
            hasRepository: gitAvailabilityViewModel.hasRepository,
            isStreaming: viewModel.activeStreamID != nil,
            latestMessageRole: latestTranscriptMessageRole,
            hasCommittableChanges: gitAvailabilityViewModel.hasCommittableChanges,
            isCommitting: gitAvailabilityViewModel.isCommitting
        ) else { return nil }
        return ChatInlineCommitContext(
            runningPhase: gitAvailabilityViewModel.commitPhase,
            isDisabled: gitWriteAvailability.writesDisabled
        )
    }

    /// Turn-end "File changes" recap card for the latest assistant turn (#316). Only for git
    /// workspaces once the response finishes (status has refreshed) and the latest turn
    /// actually changed files.
    private var turnChangesRecapSummary: TurnFileChangeSummary? {
        guard ChatGitControlsVisibilityPolicy.showsTurnChangesRecap(
            showsGitControls: showsGitControls,
            hasRepository: gitAvailabilityViewModel.hasRepository,
            isStreaming: viewModel.activeStreamID != nil,
            latestMessageRole: latestTranscriptMessageRole
        ) else { return nil }
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: viewModel.latestTurnToolCalls,
            status: gitAvailabilityViewModel.status
        )
        return summary.hasChanges ? summary : nil
    }

    /// Present the per-turn diff sheet for every changed file the turn has a status match
    /// for. No-op when there is nothing diffable yet (e.g. status still refreshing).
    private func presentTurnDiff(for summary: TurnFileChangeSummary?) {
        let files = summary?.diffFiles ?? []
        guard !files.isEmpty else { return }
        turnDiffPresentation = .turnFiles(files)
    }

    @MainActor
    private func performQuickCommit(push: Bool) async {
        guard !gitAvailabilityViewModel.isCommitting else { return }

        let branch = gitAvailabilityViewModel.currentBranchName
        gitToastState.showProgress(GitActionProgress(
            title: GitCommitPhase.generatingMessage.progressTitle,
            subtitle: branch
        ))

        let outcome = await gitAvailabilityViewModel.quickCommit(push: push) { phase in
            gitToastState.showProgress(GitActionProgress(
                title: phase.progressTitle,
                subtitle: gitAvailabilityViewModel.currentBranchName
            ))
        }

        switch outcome {
        case .success(let result):
            var detailLines: [String] = []
            if let sha = result.shortSHA { detailLines.append(String(localized: "Commit \(sha)")) }
            if result.truncatedMessage { detailLines.append(String(localized: "Diff was large; message may be partial.")) }
            if let pushError = result.pushFailureMessage {
                // The commit landed but the requested push failed — report partial success
                // so the user knows the local commit is safe and only the push needs retrying.
                detailLines.append(String(localized: "Push failed: \(pushError)"))
            }
            gitToastState.showSuccess(GitActionSuccess(
                title: result.pushFailureMessage != nil
                    ? String(localized: "Committed — push failed")
                    : (result.didPush ? String(localized: "Commit & push complete") : String(localized: "Commit complete")),
                subtitle: result.branch,
                detailLines: detailLines
            ))
            ChatHaptics.gitActionFinished(succeeded: result.pushFailureMessage == nil, isEnabled: isHapticsEnabled)
        case .nothingToCommit:
            gitToastState.dismissProgress()
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            gitAlert = .error(String(localized: "There are no changes to commit."))
        case .tooManyChanges:
            // Status was truncated (>500 files): the commit was blocked to avoid silently
            // dropping files 501+. Always surface a message — falling back to a hardcoded
            // string if the view model ever leaves actionErrorMessage unset — because a
            // blocked commit with no feedback would be the very silent failure this guards
            // against. (Kept separate from .failure, which intentionally stays quiet when its
            // busy/no-session guard returns with no message.) No success toast/SHA.
            gitToastState.dismissProgress()
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            gitAlert = .error(gitAvailabilityViewModel.actionErrorMessage
                ?? String(localized: "Too many changes to quick-commit. Commit in smaller batches, or use git directly."))
        case .failure:
            gitToastState.dismissProgress()
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            if let message = gitAvailabilityViewModel.actionErrorMessage {
                gitAlert = .error(message)
            }
        }
    }

    @MainActor
    private func performGitCheckout(_ target: GitCheckoutTarget, stashingChanges: Bool = false) async {
        let outcome = await gitAvailabilityViewModel.checkout(target, stashingChanges: stashingChanges)
        if outcome == .requiresStash {
            gitAlert = .dirtyCheckout(target)
        } else if let message = gitAvailabilityViewModel.actionErrorMessage {
            // Surface real failures and partial successes (branch switched but the
            // stashed changes could not be restored) — the view model sets
            // actionErrorMessage in both cases and clears it on every new checkout.
            gitAlert = .error(message)
        }
    }

    @MainActor
    private func performGitRemoteAction(_ action: GitRemoteAction) async {
        gitToastState.showProgress(GitActionProgress(
            title: action.progressTitle,
            subtitle: gitAvailabilityViewModel.currentBranchName
        ))

        if await gitAvailabilityViewModel.performRemoteAction(action) {
            gitToastState.showSuccess(GitActionSuccess(
                title: action.successTitle,
                subtitle: gitAvailabilityViewModel.currentBranchName,
                detailLines: [gitAvailabilityViewModel.lastActionMessage]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            ))
            ChatHaptics.gitActionFinished(succeeded: true, isEnabled: isHapticsEnabled)
        } else {
            gitToastState.dismissProgress()
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            if let message = gitAvailabilityViewModel.actionErrorMessage {
                gitAlert = .error(message)
            }
        }
    }

    private func gitAlertPresentation(_ alert: GitChatAlert) -> Alert {
        switch alert {
        case .confirmRemote(let action):
            return Alert(
                title: Text(action == .pull ? "Pull Remote Changes?" : "Push Local Commits?"),
                message: Text(action == .pull
                    ? "Pull uses fast-forward only and will not create a merge commit."
                    : "Push the current branch to its configured upstream remote?"),
                primaryButton: .default(Text(action == .pull ? "Pull" : "Push")) {
                    Task { await performGitRemoteAction(action) }
                },
                secondaryButton: .cancel()
            )
        case .dirtyCheckout(let target):
            return Alert(
                title: Text("Uncommitted Changes"),
                message: Text("This workspace has uncommitted changes. Save them temporarily, switch branches, then restore any saved changes for the destination branch."),
                primaryButton: .default(Text("Stash & Switch")) {
                    Task { await performGitCheckout(target, stashingChanges: true) }
                },
                secondaryButton: .cancel()
            )
        case .error(let message):
            return Alert(
                title: Text("Git Action Failed"),
                message: Text(message),
                dismissButton: .default(Text("OK")) {
                    gitAvailabilityViewModel.clearActionError()
                }
            )
        }
    }

    /// The pending clarification, pinned above the composer. Sits in the same
    /// bottom stack as the composer so it rides the keyboard with it.
    private var clarificationInset: some View {
        ZStack(alignment: .bottom) {
            if let clarificationPrompt = viewModel.clarificationPrompt {
                ClarificationRequestInset(
                    prompt: clarificationPrompt,
                    isResponding: viewModel.isRespondingToClarification,
                    isStopping: viewModel.isCancellingStream,
                    errorMessage: viewModel.clarificationErrorMessage,
                    isHapticsEnabled: isHapticsEnabled,
                    onSubmit: { response in
                        Task {
                            let didRespond = await viewModel.respondToClarification(response)
                            if didRespond {
                                ChatHaptics.clarificationSubmitted(isEnabled: isHapticsEnabled)
                            }
                        }
                    },
                    onStop: {
                        Task { await cancelStream() }
                    },
                    onDismissKeyboard: dismissKeyboard,
                    onFootprintChange: { height in
                        clarificationBarHeight = height
                    }
                )
                .id(clarificationPrompt.id)
                .padding(.horizontal, 16)
                .padding(.bottom, composerHeight + 8)
                .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
        .zIndex(9)
        .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: viewModel.clarificationPrompt?.id)
    }

    @ViewBuilder
    private var composerAccessoryStack: some View {
        if composerAccessoryVisibleItemCount > 0 {
            VStack(spacing: composerAccessoryVerticalSpacing) {
                if !composerLocalNotices.isEmpty {
                    PinnedLocalNoticeStack(notices: composerLocalNotices)
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if let activeRunStatusPresentation {
                    ChatActiveRunStatusView(presentation: activeRunStatusPresentation)
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if showsApprovalBypassStatus {
                    ApprovalBypassStatusPill()
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, composerHeight + 8 + clarificationFootprintHeight)
            .allowsHitTesting(false)
            .zIndex(8)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: composerAccessoryVisibleItemCount)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: activeRunStatusPresentation)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: composerLocalNotices)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsApprovalBypassStatus)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        let reasoningGroups = viewModel.displayedReasoningGroups
        ChatTranscriptView(
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            messages: viewModel.messages,
            displayedTranscriptMessages: displayedTranscriptMessages,
            compressionReferenceCard: viewModel.compressionReferenceCard,
            reasoningGroups: reasoningGroups,
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
            clarificationPromptID: viewModel.clarificationPrompt?.id,
            hidesRunStatusAccessibility: activeRunStatusPresentation != nil,
            showsThinkingAndToolCards: showsThinkingAndToolCards,
            workingRowStartedAt: workingRowStartedAt,
            showsScrollToBottomButton: showsScrollToBottomButton,
            shouldFollowLatestMessage: shouldFollowLatestMessage,
            isDisclosureSettling: isDisclosureSettling,
            latestTranscriptMessageRole: latestTranscriptMessageRole,
            isScrolledNearBottom: isScrolledNearBottom,
            activeStreamID: viewModel.activeStreamID,
            streamingScrollTrigger: viewModel.streamingScrollTrigger,
            transcriptRelayoutScrollToken: viewModel.transcriptRelayoutScrollToken,
            bottomAnchorID: bottomAnchorID,
            transcriptSpacing: transcriptSpacing,
            transcriptBottomInsetHeight: transcriptBottomInsetHeight,
            scrollToBottomButtonBottomPadding: scrollToBottomButtonBottomPadding,
            localAttachmentPreviews: viewModel.localAttachmentPreviews,
            listeningMessageID: viewModel.listeningMessageID,
            isViewingCachedData: viewModel.isViewingCachedData,
            hasOlderMessages: viewModel.hasOlderMessages,
            isLoadingOlderMessages: viewModel.isLoadingOlderMessages,
            isRegeneratingMessage: viewModel.isRegeneratingMessage,
            isEditingMessage: viewModel.isEditingMessage,
            isForkingMessage: viewModel.isForkingMessage,
            loadAttachmentImage: { path in
                await viewModel.attachmentImageData(path: path)
            },
            loadAttachmentData: { path in
                await viewModel.attachmentRawData(path: path)
            },
            loadTranscriptMediaImage: { reference in
                await viewModel.transcriptMediaThumbnailData(for: reference)
            },
            loadTranscriptMediaData: { reference in
                await viewModel.transcriptMediaData(for: reference)
            },
            transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
            actionContext: { message, visibleIndex in
                viewModel.actionContext(for: message, visibleIndex: visibleIndex)
            },
            shouldRenderMessageRow: shouldRenderMessageRow,
            onLoadMessages: {
                await loadMessages()
            },
            onLoadOlderMessages: {
                await loadOlderMessages()
            },
            onUpdateScrollMetrics: updateScrollMetrics,
            onFollowEvent: handleFollowEvent,
            onDisclosureToggle: handleDisclosureToggle,
            turnFolds: turnFolds(reasoningGroups: reasoningGroups),
            terminalReplyRenderIDs: terminalReplyRenderIDs,
            expandedTurnKeys: expandedTurnKeys,
            onToggleTurnFold: toggleTurnFold,
            onDismissKeyboard: dismissKeyboard,
            onScrollToBottom: scrollToBottom,
            onScrollToLatestTranscriptMessage: { proxy in
                scrollToLatestTranscriptMessage(proxy)
            },
            onScrollToLatestContent: { proxy, animated in
                scrollToLatestContent(proxy, animated: animated)
            },
            onPreviewAttachment: { attachment, localData in
                presentPreviewRestoringComposerFocusIfNeeded {
                    attachmentPreviewItem = ChatAttachmentPreviewItem(message: attachment, localData: localData)
                }
            },
            onPreviewTranscriptMedia: { reference in
                transcriptMediaPreviewItem = TranscriptMediaPreviewItem(reference: reference)
            },
            onToggleListening: { context in
                viewModel.toggleListening(to: context)
            },
            onSelectText: { context in
                selectableResponseText = SelectableTextPresentation(context: context)
            },
            onRegenerate: beginRegenerateResponse,
            onEdit: beginEditMessage,
            onFork: { context in
                Task { await forkFromMessage(context) }
            },
            onCopy: { context in
                UIPasteboard.general.string = context.copyText
                ChatHaptics.copied(isEnabled: isHapticsEnabled)
            },
            inlineCommitContext: inlineCommitContext,
            onInlineCommit: {
                Task { await performQuickCommit(push: true) }
            },
            turnChangesSummary: turnChangesRecapSummary,
            onOpenTurnDiff: {
                presentTurnDiff(for: turnChangesRecapSummary)
            },
            onOpenTurnFileDiff: { file in
                turnDiffPresentation = .file(file)
            }
        )
        // Off the main body chain, which is at the type-checker's limit.
        .onChange(of: viewModel.latestRunOutcome) {
            handleLatestRunOutcomeChange(viewModel.latestRunOutcome)
        }
        .environment(\.skillChipCatalog, viewModel.skillChipCatalog)
        .task(id: transcriptSkillReferenceCount) {
            await loadSkillSuggestionsForTranscriptChipsIfNeeded()
        }
    }

    /// How many sent messages look like they name a skill.
    ///
    /// It is both the trigger and the task's identity, so a cache-first
    /// transcript that swaps in the server's messages still warms the list when
    /// the count of messages did not change but their text did. Zero once the
    /// list has loaded or this chat has already asked, which is what keeps the
    /// scan off the streaming path.
    private var transcriptSkillReferenceCount: Int {
        guard !hasRequestedSkillsForTranscriptChips, !viewModel.hasLoadedSkillSlashSuggestions else {
            return 0
        }

        return viewModel.messages.reduce(into: 0) { count, message in
            guard message.role == "user",
                  ComposerChipTokenizer.mayContainReference(message.content ?? "")
            else { return }
            count += 1
        }
    }

    /// A sent message draws its skill reference as a chip only for skills the
    /// app has heard of, so a transcript that names one warms the skill list the
    /// way a restored draft does — and a chat that never mentions a skill still
    /// costs no skills request.
    private func loadSkillSuggestionsForTranscriptChipsIfNeeded() async {
        guard transcriptSkillReferenceCount > 0 else { return }

        await viewModel.loadSkillSlashSuggestions()

        // One ask per chat. A skills request that failed must not turn every
        // later transcript update into another one; typing `/` in the composer
        // still retries on the reader's behalf. Set after the wait so a
        // cancelled task leaves the chat free to ask again.
        hasRequestedSkillsForTranscriptChips = true
    }

    /// The chat-canvas layout direction. Driven by the manual Settings → Chat
    /// RTL toggle (#259); applied only to the transcript + composer so the
    /// sidebar, settings, and navigation chrome stay in the default direction.
    private var chatLayoutDirection: LayoutDirection {
        ChatTranscriptDisplaySettings.chatLayoutDirection(rtlEnabled: rtlChatLayoutEnabled)
    }

    private var shouldFollowLatestMessage: Bool {
        followLatch.isFollowing
    }

    /// Automatic follows run only while the latch is on and no disclosure
    /// toggle is mid-animation.
    private var isFollowingLatestContent: Bool {
        shouldFollowLatestMessage && !isDisclosureSettling
    }

    private var showsScrollToBottomButton: Bool {
        !isScrolledNearBottom && (viewModel.activeStreamID == nil || !shouldFollowLatestMessage)
    }

    private var workingRowStartedAt: Date? {
        ChatWorkingRowPolicy.startedAt(
            activeRunStartedAt: viewModel.activeRunStartedAt,
            isCancellingStream: viewModel.isCancellingStream,
            hasPendingClarificationPrompt: viewModel.clarificationPrompt != nil
        )
    }

    private var transcriptBottomInsetHeight: CGFloat {
        max(96, composerHeight + 44 + composerAccessorySpacerHeight + clarificationFootprintHeight)
    }

    private var scrollToBottomButtonBottomPadding: CGFloat {
        composerHeight + 12 + composerAccessorySpacerHeight + clarificationFootprintHeight
    }

    /// Bar height plus its gap above the composer while a clarification is
    /// pending. Constant across expand and collapse, so the transcript never
    /// moves while the card animates.
    private var clarificationFootprintHeight: CGFloat {
        viewModel.clarificationPrompt == nil ? 0 : clarificationBarHeight + 8
    }

    private var pinnedNoticeSpacerHeight: CGFloat {
        composerLocalNotices.isEmpty ? 0 : CGFloat(composerLocalNotices.count) * 60
    }

    private var composerLocalNotices: [String] {
        var notices = viewModel.pinnedLocalNotices
        if let steeringConfirmationNotice = viewModel.steeringConfirmationNotice {
            notices.append(steeringConfirmationNotice)
        }
        return notices
    }

    private var activeRunStatusPresentation: ChatActiveRunStatusPresentation? {
        ChatActiveRunStatusPolicy.presentation(
            isStartingChat: viewModel.isStartingChat,
            hasActiveStream: viewModel.activeStreamID != nil,
            activeStreamRecoveryState: viewModel.activeStreamRecoveryState,
            isCancellingStream: viewModel.isCancellingStream,
            isScrolledNearBottom: isScrolledNearBottom
        )
    }

    private var showsApprovalBypassStatus: Bool {
        viewModel.isSessionApprovalBypassEnabled && viewModel.approvalPrompt == nil
    }

    private var composerAccessorySpacerHeight: CGFloat {
        var height = pinnedNoticeSpacerHeight
        if activeRunStatusPresentation != nil {
            height += activeRunStatusSpacerHeight
        }
        if showsApprovalBypassStatus {
            height += approvalBypassStatusSpacerHeight
        }

        let visibleItemCount = composerAccessoryVisibleItemCount
        if visibleItemCount > 1 {
            height += CGFloat(visibleItemCount - 1) * composerAccessoryVerticalSpacing
        }
        return height
    }

    private var composerAccessoryVisibleItemCount: Int {
        var count = 0
        if !composerLocalNotices.isEmpty {
            count += 1
        }
        if activeRunStatusPresentation != nil {
            count += 1
        }
        if showsApprovalBypassStatus {
            count += 1
        }
        return count
    }

    private var displayTitle: String {
        viewModel.displayTitle
    }

    private var headerSubtitle: String? {
        ChatToolbarSubtitleResolver.subtitle(
            workspacePath: viewModel.selectedWorkspacePath,
            profileTitle: viewModel.selectedProfileTitle
        )
    }

    private func shouldRenderMessageRow(_ message: ChatMessage) -> Bool {
        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        return message.role == "user" && message.attachments?.isEmpty == false
    }

    private var transcriptMessages: [TranscriptMessage] {
        viewModel.displayedTranscriptMessages
    }

    private var displayedTranscriptMessages: [TranscriptMessage] {
        transcriptMessages
    }

    /// Settled-turn folds for the current transcript. Activity anchors count
    /// only while thinking and tool cards are shown, so a turn with nothing
    /// visible to hide gets no row.
    private func turnFolds(reasoningGroups: [ReasoningGroup]) -> TranscriptTurnFolds {
        guard foldsSettledTurns else { return .none }

        let activityAnchorIDs: Set<String> = showsThinkingAndToolCards
            ? Set(reasoningGroups.compactMap(\.anchorMessageID))
                .union(viewModel.completedToolCallGroups.compactMap(\.anchorMessageID))
            : []

        return TranscriptTurnFolds.derive(
            transcriptMessages: transcriptMessages,
            messages: viewModel.messages,
            messageOffset: viewModel.messagesOffset,
            activityAnchorIDs: activityAnchorIDs,
            rendersBubble: shouldRenderMessageRow,
            isStreamActive: viewModel.activeStreamID != nil,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID,
            latestRunOutcome: viewModel.latestRunOutcome
        )
    }

    /// Rows that get the time + copy row as the reply closing a settled turn.
    private var terminalReplyRenderIDs: Set<String> {
        TranscriptMessageMetaPolicy.terminalReplyRenderIDs(
            transcriptMessages: transcriptMessages,
            messages: viewModel.messages,
            messageOffset: viewModel.messagesOffset,
            rendersBubble: shouldRenderMessageRow,
            isStreamActive: viewModel.activeStreamID != nil,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID
        )
    }

    private func toggleTurnFold(_ turnKey: String) {
        handleDisclosureToggle()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            if !expandedTurnKeys.insert(turnKey).inserted {
                expandedTurnKeys.remove(turnKey)
            }
        }
    }

    /// Failed or stopped turns start open so the work that went wrong is in view.
    private func handleLatestRunOutcomeChange(_ outcome: TranscriptTurnRunOutcome?) {
        guard let outcome, outcome.ending != .completed else { return }
        expandedTurnKeys.insert(outcome.turnKey)
    }

    private var latestTranscriptMessageID: String? {
        transcriptMessages.last?.id
    }

    private var latestTranscriptMessageRole: String? {
        transcriptMessages.last?.message.role
    }

    private func prepareInitialAppearance() {
        viewModel.setShowsLiveActivityResponseExcerpts(showsLiveActivityResponseExcerpts)
        if loadsInitialMessages {
            viewModel.prepareInitialMessageLoad(modelContext: modelContext)
        }
    }

    private func handleInitialAppearanceTask() async {
        await hydrateDraftIfNeeded()
        prepareInitialAppearance()

        guard ChatInitialAppearancePolicy.shouldBeginAsyncWork(
            hasCompletedAppearance: didCompleteInitialAppearance
        ) else {
            return
        }

        async let chatStartup: Void = performInitialAsyncWork()
        async let gitAvailability: Void = loadInitialGitAvailability()
        async let draftAttachments: Void = restoreDraftAttachmentsIfNeeded()
        _ = await (chatStartup, gitAvailability, draftAttachments)
    }

    private func performInitialAsyncWork() async {
        guard !Task.isCancelled else { return }
        let draftSettingsInteractionGeneration = viewModel.composerConfigurationInteractionGeneration

        if loadsInitialMessages {
            await loadMessages(appliesInitialFocus: false)
            guard !Task.isCancelled else { return }
        }
        if initialAttachments.isEmpty {
            isInitialComposerFocusContentReady = true
            applyInitialComposerFocusPolicyIfNeeded()
        }
        await viewModel.loadComposerConfiguration()
        guard !Task.isCancelled else { return }

        await applyRestoredDraftSettingsIfNeeded(
            expectedInteractionGeneration: draftSettingsInteractionGeneration
        )
        guard !Task.isCancelled else { return }

        await viewModel.refreshApprovalBypassState()
        guard !Task.isCancelled else { return }

        await uploadInitialAttachmentsIfNeeded()
        guard !Task.isCancelled else { return }

        isInitialComposerFocusContentReady = true
        applyInitialComposerFocusPolicyIfNeeded()
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func loadInitialGitAvailability() async {
        let availabilityViewModel = GitWorkspaceAvailabilityViewModel(session: session, server: server)
        gitAvailabilityViewModel = availabilityViewModel
        await availabilityViewModel.loadIfNeeded()
    }

    private var goalControlMenu: some View {
        GoalControlsMenu(
            currentGoal: viewModel.currentGoal,
            isViewingCachedData: viewModel.isViewingCachedData,
            isActionDisabled: isGoalActionDisabled,
            onSetGoal: {
                showsGoalSheet = true
            },
            onSubmitCommand: { command in
                Task { await submitGoalCommand(command) }
            }
        )
    }

    private var isGoalActionDisabled: Bool {
        viewModel.isViewingCachedData || viewModel.activeStreamID != nil || viewModel.isSubmittingGoal
    }

    private func loadMessages(appliesInitialFocus: Bool = true) async {
        await viewModel.loadMessages(modelContext: modelContext)
        await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
        if appliesInitialFocus {
            applyInitialComposerFocusPolicyIfNeeded()
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func loadOlderMessages() async -> Bool {
        followLatch.isFollowing = false

        let didLoad = await viewModel.loadOlderMessages(modelContext: modelContext)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        return didLoad
    }

    private func submitGoalDraft(_ submittedGoal: String) async {
        await submitGoal(submittedGoal, clearsDraftOnSuccess: true)
    }

    private func submitGoalCommand(_ command: String) async {
        await submitGoal(command, clearsDraftOnSuccess: false)
    }

    private func submitGoal(_ args: String, clearsDraftOnSuccess: Bool) async {
        prepareTranscriptForExplicitSend()

        let didSubmit = await viewModel.submitGoal(args: args, modelContext: modelContext)
        if didSubmit, clearsDraftOnSuccess {
            goalDraft = ""
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendDraftMessage() async {
        let submittedDraft = draftMessage
        let submittedDraftRevision = draftRevision
        let shouldRestoreFocusAfterSend = composerIsFocused

        if submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            let parsedCommand = SlashCommandExecutor.parse(submittedDraft)?.command
            let result = await SlashCommandExecutor.execute(text: submittedDraft, viewModel: viewModel)
            handleSlashExecutionResult(
                result,
                parsedCommand: parsedCommand,
                submittedDraft: submittedDraft,
                submittedDraftRevision: submittedDraftRevision
            )

            if result != .sendAsMessage {
                if let lastError = viewModel.lastError {
                    onAPIError(lastError)
                }
                return
            }
        }

        let didStart: Bool
        if viewModel.activeStreamID != nil {
            prepareTranscriptForExplicitSend()
            let result = await viewModel.submitStreamingMessage(
                submittedDraft,
                behavior: StreamingSendBehavior.storedValue(streamingSendBehaviorRawValue)
            )
            handleSlashExecutionResult(
                result,
                parsedCommand: SlashCommandCatalog.command(named: streamingSendBehaviorCommandName),
                submittedDraft: submittedDraft,
                submittedDraftRevision: submittedDraftRevision,
                consumesDraft: result.isSuccessfulSubmission
            )
            didStart = result.isSuccessfulSubmission
        } else {
            didStart = await sendStandardMessage(
                submittedDraft,
                submittedDraftRevision: submittedDraftRevision
            )
        }

        if didStart {
            ChatHaptics.messageSent(isEnabled: isHapticsEnabled)
            if shouldRestoreFocusAfterSend {
                requestComposerFocusIfPossible()
            } else {
                composerIsFocused = false
            }
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendVoiceNote(audioData: Data, filename: String) async {
        prepareTranscriptForExplicitSend()

        let didSend = await viewModel.sendVoiceNote(
            audioData: audioData,
            filename: filename,
            modelContext: modelContext
        )

        if didSend {
            onConversationStarted()
            ChatHaptics.messageSent(isEnabled: isHapticsEnabled)
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendStandardMessage(
        _ submittedDraft: String,
        submittedDraftRevision: Int
    ) async -> Bool {
        guard !submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        prepareTranscriptForExplicitSend()

        // Reconcile against what the composer actually staged, not against the
        // draft's whole record set. A record that is not staged — awaiting a
        // re-upload retry, or not yet reached by an in-flight restore — was
        // never carried by this send, so its durable copy must survive.
        let sendReconciliation = ChatDraftSendReconciliation.outcome(
            draftRecords: lastSyncedDraftAttachments,
            stagedAttachmentIDs: Set(viewModel.pendingAttachments.map(\.id))
        )
        draftStore.setDraft(submittedDraft, for: draftKey)
        draftMessage = ""

        let didStart = await viewModel.sendMessage(submittedDraft, modelContext: modelContext)
        if didStart {
            onConversationStarted()
            draftAttachmentsPendingRetry = sendReconciliation.retained
        }
        draftMessage = draftStore.resolveSubmission(
            submittedText: submittedDraft,
            currentText: draftMessage,
            didStart: didStart,
            draftWasEdited: draftRevision != submittedDraftRevision,
            for: draftKey
        )
        if didStart {
            // `resolveSubmission` cleared the draft's attachment records; put
            // back the ones the send never carried so they retry on a later
            // open. Deterministic here rather than waiting on the observation
            // sync that the emptied composer strip will also trigger.
            syncDraftAttachments()
        }

        return didStart
    }

    private func handleSlashExecutionResult(
        _ result: SlashCommandExecutionResult,
        parsedCommand: SlashCommand?,
        submittedDraft: String,
        submittedDraftRevision: Int,
        consumesDraft: Bool = true
    ) {
        switch result {
        case .executed(let message):
            if let message {
                if shouldRenderAsLocalNotice(parsedCommand) {
                    if viewModel.activeStreamID == nil {
                        viewModel.appendLocalNoticeMessage(message)
                    } else {
                        viewModel.pinLocalNoticeMessage(message)
                    }
                } else {
                    viewModel.appendLocalAssistantMessage(message)
                }
            }
            if consumesDraft {
                reconcileConsumedDraft(
                    submittedDraft,
                    submittedDraftRevision: submittedDraftRevision
                )
            }
        case .openedSession(let session):
            forkedSession = session
            if consumesDraft {
                reconcileConsumedDraft(
                    submittedDraft,
                    submittedDraftRevision: submittedDraftRevision
                )
            }
        case .unsupported(let friendlyMessage):
            viewModel.setSendErrorMessage(friendlyMessage)
            if consumesDraft {
                reconcileConsumedDraft(
                    submittedDraft,
                    submittedDraftRevision: submittedDraftRevision
                )
            }
        case .needsSubArg:
            viewModel.setSendErrorMessage(String(localized: "Choose a slash command or continue typing."))
        case .sendAsMessage:
            break
        }
    }

    private func shouldRenderAsLocalNotice(_ command: SlashCommand?) -> Bool {
        command?.handler == .serverSide(.compress) ||
            command?.handler == .serverSide(.queue) ||
            command?.handler == .serverSide(.steer) ||
            command?.handler == .serverSide(.interrupt) ||
            command?.handler == .serverSide(.background)
    }

    private var streamingSendBehaviorCommandName: String {
        switch StreamingSendBehavior.storedValue(streamingSendBehaviorRawValue) {
        case .steer:
            "steer"
        case .interrupt:
            "interrupt"
        case .queue:
            "queue"
        }
    }

    private var draftKey: ChatDraftKey {
        let normalizedSessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = normalizedSessionID.flatMap { $0.isEmpty ? nil : $0 } ?? session.id
        return .session(
            server: server,
            sessionID: sessionID
        )
    }

    private var persistedDraftBinding: Binding<String> {
        Binding(
            get: { draftMessage },
            set: { newValue in
                draftMessage = newValue
                draftRevision &+= 1
                draftStore.setDraft(newValue, for: draftKey)
            }
        )
    }

    private func hydrateDraftIfNeeded() async {
        guard !didHydrateDraft else { return }
        let textBeforeHydration = draftMessage
        let persistedDraft = await draftStore.draft(for: draftKey)
        guard !Task.isCancelled, draftMessage == textBeforeHydration else { return }

        if textBeforeHydration.isEmpty {
            if let persistedDraft, !persistedDraft.text.isEmpty {
                draftMessage = persistedDraft.text
            }
        } else {
            draftStore.setDraft(textBeforeHydration, for: draftKey)
        }
        didHydrateDraft = true

        restoredDraftSettings = persistedDraft?.settings
        lastSyncedDraftAttachments = persistedDraft?.attachments ?? []
        if let persistedDraft, !persistedDraft.attachments.isEmpty {
            // Hold the sync gate now and restore later: re-uploading staged
            // files is network work and must not delay the transcript.
            isRestoringDraftAttachments = true
            draftAttachmentsAwaitingRestore = persistedDraft.attachments
        }
    }

    private func restoreDraftAttachmentsIfNeeded() async {
        let records = draftAttachmentsAwaitingRestore
        guard !records.isEmpty else { return }
        draftAttachmentsAwaitingRestore = []
        await restoreDraftAttachments(records)
    }

    /// Rebuilds the composer's staged attachments from a persisted draft by
    /// re-uploading each record's durable local copy against this session. The
    /// persisted server path is never trusted: uploads live in a per-session
    /// inbox the server deletes with the session, so only the app-owned copy
    /// is a sound restore source. Records whose copy is missing are dropped
    /// (with a notice); records whose re-upload fails stay in the draft and
    /// retry on a later open. The rest of the draft loads either way.
    private func restoreDraftAttachments(_ records: [ChatDraftAttachment]) async {
        var pendingRetry: [ChatDraftAttachment] = []
        var unrecoverableCount = 0
        var wasCancelled = false

        for (offset, record) in records.enumerated() {
            if Task.isCancelled {
                // Leaving the chat mid-restore is not a restore failure. Every
                // record from here on is untried, so carry the whole remainder
                // into the retry set: the sync below is authoritative, and
                // anything missing from it would be dropped from the draft and
                // later swept from disk.
                wasCancelled = true
                pendingRetry.append(contentsOf: records[offset...])
                break
            }
            guard let fileName = record.file else {
                // Tolerate an older or partially corrupt record that predates
                // the durable-staging invariant.
                unrecoverableCount += 1
                continue
            }

            let data: Data
            do {
                data = try await draftAttachmentStore.data(named: fileName)
            } catch {
                // Only a copy that is genuinely gone is dropped. Any other
                // read failure keeps the record so a later open can retry it.
                switch ChatDraftAttachmentReadFailure.classify(error) {
                case .unrecoverable:
                    unrecoverableCount += 1
                case .transient:
                    pendingRetry.append(record)
                }
                continue
            }

            if await viewModel.reuploadDraftAttachment(record, data: data) == nil {
                pendingRetry.append(record)
            }
        }

        isRestoringDraftAttachments = false
        draftAttachmentsPendingRetry = pendingRetry
        // Authoritative sync after restore: persists the restored set plus the
        // retry union, and drops unrecoverable records from the draft.
        syncDraftAttachments()

        // Report only a real restore outcome. A cancelled pass has nothing to
        // say, and its view is going away regardless.
        guard !wasCancelled else { return }
        if !pendingRetry.isEmpty || unrecoverableCount > 0 {
            viewModel.setUploadAttachmentError(
                draftRestoreFailureMessage(retryCount: pendingRetry.count, droppedCount: unrecoverableCount)
            )
        }
    }

    /// Copy uses catalog plural variations rather than a hand-branched
    /// singular/plural, so languages whose plural rules differ from English
    /// still read correctly. The mixed case avoids a two-number sentence.
    private func draftRestoreFailureMessage(retryCount: Int, droppedCount: Int) -> String {
        switch (retryCount > 0, droppedCount > 0) {
        case (true, false):
            return String(localized: "Couldn't restore \(retryCount) saved attachments yet. They're still saved in this draft.")
        case (false, true):
            return String(localized: "\(droppedCount) saved attachments are no longer available and were removed from this draft.")
        default:
            return String(localized: "Some saved attachments couldn't be restored. Check this draft's attachments before sending.")
        }
    }

    /// Mirrors the composer's staged attachments into the persisted draft.
    /// Restored records whose re-upload failed are unioned back in so a
    /// mid-restore or post-restore sync can't silently drop them. Gated during
    /// hydration/restore so an empty or partial composer never overwrites the
    /// persisted set.
    private func syncDraftAttachments() {
        guard didHydrateDraft, !isRestoringDraftAttachments else { return }
        // Only records backed by a durable copy are persisted. Without one the
        // record could never be restored, and keeping it would hold the draft
        // alive just to report the attachment as lost on the next open.
        let pendingRecords = viewModel.pendingAttachments
            .map(ChatDraftAttachment.init(pending:))
            .filter { $0.file != nil }
        let retryRecords = draftAttachmentsPendingRetry.filter { retry in
            !pendingRecords.contains(where: { $0.id == retry.id })
        }
        let records = pendingRecords + retryRecords
        lastSyncedDraftAttachments = records
        draftStore.setAttachments(records, for: draftKey)
    }

    /// Snapshots the effective composer settings into the draft whenever they
    /// change. Only new-chat contexts snapshot: an existing session's
    /// configuration is owned by the server and is never re-applied from a
    /// draft, so persisting it would just store choices at rest that nothing
    /// reads. Snapshotting here is what lets an abandoned new chat carry its
    /// model/workspace/profile/reasoning picks to the next new chat.
    private func syncDraftSettings(_ settings: ChatDraftSettings) {
        guard didHydrateDraft, restoresDraftSettings else { return }
        draftStore.setSettings(settings, for: draftKey)
    }

    /// The composer choices that make up a draft's settings snapshot, as one
    /// Equatable value so a single `onChange` covers all five.
    private var currentComposerSettings: ChatDraftSettings {
        ChatDraftSettings(
            modelID: viewModel.selectedModelID,
            modelProviderID: viewModel.selectedModelProviderID,
            reasoningEffort: viewModel.selectedReasoningEffort,
            profileName: viewModel.selectedProfileName,
            workspacePath: viewModel.selectedWorkspacePath
        )
    }

    /// New-chat only. The view owns the one-shot restore trigger while the
    /// model owns validation, interaction fencing, and profile ordering.
    private func applyRestoredDraftSettingsIfNeeded(
        expectedInteractionGeneration: Int
    ) async {
        guard restoresDraftSettings, !didApplyRestoredDraftSettings else { return }
        didApplyRestoredDraftSettings = true
        guard let settings = restoredDraftSettings, !Task.isCancelled else { return }
        await viewModel.restoreDraftSettings(
            settings,
            expectedInteractionGeneration: expectedInteractionGeneration
        )
    }

    private func reconcileConsumedDraft(
        _ submittedDraft: String,
        submittedDraftRevision: Int
    ) {
        draftMessage = draftStore.resolveConsumedInput(
            submittedText: submittedDraft,
            currentText: draftMessage,
            draftWasEdited: draftRevision != submittedDraftRevision,
            for: draftKey
        )
    }

    private func flushDraftsBestEffort() {
        Task {
            try? await draftStore.flush()
        }
    }

    private func cancelStream() async {
        let didCancel = await viewModel.cancelActiveStream()
        if didCancel {
            ChatHaptics.streamCancelled(isEnabled: isHapticsEnabled)
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func forkFromMessage(_ context: MessageActionContext) async {
        let session = await viewModel.forkFromMessage(context, modelContext: modelContext)

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if let session {
            forkedSession = session
        }
    }

    private func handleProfileSelection(_ profile: ProfileSummary) {
        viewModel.markComposerConfigurationInteraction()
        if viewModel.isSelectedProfile(profile) {
            return
        }

        if viewModel.messages.isEmpty {
            Task { await switchProfile(profile, startNewSession: false) }
        } else {
            pendingProfileSelection = profile
            showProfileNewSessionConfirmation = true
        }
    }

    private func switchProfile(_ profile: ProfileSummary, startNewSession: Bool) async {
        let outcome = await viewModel.switchProfile(
            profile,
            startNewSession: startNewSession,
            recordsInteraction: false
        )
        pendingProfileSelection = nil

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if outcome != nil {
            ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
        }

        if let session = outcome?.session {
            forkedSession = session
        }
    }

    private func uploadInitialAttachmentsIfNeeded() async {
        guard !didUploadInitialAttachments, !initialAttachments.isEmpty else {
            return
        }

        didUploadInitialAttachments = true
        for attachment in initialAttachments {
            await viewModel.uploadAttachment(
                data: attachment.data,
                filename: attachment.filename,
                previewData: previewData(for: attachment)
            )
        }
    }

    private func previewData(for attachment: SharedAttachmentImport) -> Data? {
        if let typeIdentifier = attachment.typeIdentifier,
           UTType(typeIdentifier)?.conforms(to: .image) == true {
            return attachment.data
        }

        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        let fileExtension = URL(fileURLWithPath: attachment.filename).pathExtension.lowercased()
        return imageExtensions.contains(fileExtension) ? attachment.data : nil
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                viewModel.setUploadAttachmentError(String(localized: "Could not read the selected photo."))
                return
            }
            let filename = "image_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).jpg"
            await viewModel.uploadAttachment(data: data, filename: filename, previewData: data)
        } catch {
            viewModel.setUploadAttachmentError(error.localizedDescription)
        }
    }

    private func handleSelectedFileURLs(_ urls: [URL]) async {
        let fileURLs = urls.filter(\.isFileURL)

        guard !fileURLs.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Select a file to attach it."))
            return
        }

        for url in fileURLs {
            do {
                let file = try loadPastedFile(from: url, suggestedName: nil)
                await viewModel.uploadAttachment(data: file.data, filename: file.filename)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func handlePastedFileProviders(_ providers: [NSItemProvider]) async {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied file to attach it."))
            return
        }

        for provider in fileProviders {
            do {
                let file = try await loadPastedFile(from: provider)
                await viewModel.uploadAttachment(data: file.data, filename: file.filename)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func handlePastedImageProviders(_ providers: [NSItemProvider]) async {
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }

        guard !imageProviders.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied image to attach it."))
            return
        }

        for provider in imageProviders {
            do {
                let image = try await loadPastedImage(from: provider)
                await viewModel.uploadAttachment(data: image.data, filename: image.filename, previewData: image.data)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func handlePastedImages(_ images: [UIImage]) async {
        guard !images.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied image to attach it."))
            return
        }

        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData() else {
                viewModel.setUploadAttachmentError(String(localized: "Could not read the pasted image."))
                continue
            }

            await viewModel.uploadAttachment(data: data, filename: pastedImageFilename(), previewData: data)
        }
    }

    private func loadPastedFile(from provider: NSItemProvider) async throws -> PastedFile {
        let suggestedName = provider.suggestedName

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url = pastedFileURL(from: item) else {
                    continuation.resume(throwing: PastedFileError.unreadableURL)
                    return
                }

                do {
                    let file = try loadPastedFile(from: url, suggestedName: suggestedName)
                    continuation.resume(returning: file)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func handlePastedFileURLs(_ urls: [URL]) async {
        let fileURLs = urls.filter(\.isFileURL)

        guard !fileURLs.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied file to attach it."))
            return
        }

        for url in fileURLs {
            do {
                let file = try loadPastedFile(from: url, suggestedName: nil)
                await viewModel.uploadAttachment(data: file.data, filename: file.filename)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func loadPastedFile(from url: URL, suggestedName: String?) throws -> PastedFile {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try validateAttachmentSize(for: url)
        let data = try Data(contentsOf: url)
        let filename = url.lastPathComponent.isEmpty
            ? suggestedName ?? "pasted-file"
            : url.lastPathComponent
        return PastedFile(data: data, filename: filename)
    }

    private func validateAttachmentSize(for url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize,
              size > PendingAttachment.maximumUploadBytes
        else {
            return
        }

        let filename = url.lastPathComponent.isEmpty ? String(localized: "Selected file") : url.lastPathComponent
        throw PastedFileError.fileTooLarge(filename: filename)
    }

    private func loadPastedImage(from provider: NSItemProvider) async throws -> PastedFile {
        let suggestedName = provider.suggestedName
        let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image)
        } ?? UTType.image.identifier

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(throwing: PastedFileError.unreadableImage)
                    return
                }

                continuation.resume(
                    returning: PastedFile(
                        data: data,
                        filename: pastedImageFilename(suggestedName: suggestedName)
                    )
                )
            }
        }
    }

    private func pastedImageFilename(suggestedName: String? = nil) -> String {
        if let suggestedName,
           !suggestedName.isEmpty,
           !URL(fileURLWithPath: suggestedName).pathExtension.isEmpty {
            return suggestedName
        }

        return "image_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).jpg"
    }

    private func pastedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }

        return nil
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase != .active {
            flushDraftsBestEffort()
        }

        switch phase {
        case .background:
            if viewModel.activeStreamID != nil {
                beginResponseCompletionBackgroundTask()
            }
        case .active:
            viewModel.refreshListenPlaybackProgressAfterSceneActivation()
            endResponseCompletionBackgroundTask()
            Task {
                await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)

                if let lastError = viewModel.lastError {
                    onAPIError(lastError)
                }
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleActiveStreamChange() {
        guard let activeStreamID = viewModel.activeStreamID else {
            activeStreamStatusRefreshTask?.cancel()
            activeStreamStatusRefreshTask = nil

            if responseCompletionNotificationTracker.shouldEndBackgroundTaskOnStreamInactive(
                completionTrigger: viewModel.responseCompletionHapticTrigger
            ) {
                endResponseCompletionBackgroundTask()
            }

            // The agent may have edited files this turn, so refresh git state (status,
            // ahead/behind, branch) once the response finishes — keeps the toolbar badge,
            // Changes row, and commit surfaces in sync without re-entering the chat.
            // Run unconditionally: refreshAfterExternalMutation re-checks /api/git-info first,
            // so it also detects a repo the agent just created (git init/clone) mid-turn.
            Task { await gitAvailabilityViewModel.refreshAfterExternalMutation() }
            return
        }

        // A new turn starting folds the previous one, even one that opened
        // itself after failing or being stopped.
        if let previousTurnKey = viewModel.latestRunOutcome?.turnKey {
            expandedTurnKeys.remove(previousTurnKey)
        }

        startActiveStreamStatusRefreshTask(streamID: activeStreamID)
    }

    private func startActiveStreamStatusRefreshTask(streamID: String) {
        activeStreamStatusRefreshTask?.cancel()
        activeStreamStatusRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard viewModel.activeStreamID == streamID else { return }

                if viewModel.isActiveStreamConnectionSuspended {
                    continue
                }

                await viewModel.recoverStaleActiveStreamIfNeeded(modelContext: modelContext)

                guard viewModel.activeStreamID == streamID else { return }
            }
        }
    }

    private func handleResponseCompletionSideEffects() {
        if !viewModel.responseCompletionNeedsTranscriptRefresh {
            viewModel.cacheCompletedResponse(modelContext: modelContext)
        }

        guard let completionContext = responseCompletionNotificationTracker.completionContext(
            completionTrigger: viewModel.responseCompletionHapticTrigger,
            sceneIsActive: scenePhase == .active
        ) else {
            return
        }

        ChatHaptics.assistantResponseCompleted(isEnabled: isHapticsEnabled)

        Task { @MainActor in
            defer { endResponseCompletionBackgroundTask() }

            if viewModel.responseCompletionNeedsTranscriptRefresh {
                await loadMessages()
            }

            await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
                sessionID: session.sessionId,
                preferenceEnabled: isResponseCompletionNotificationsEnabled,
                completedNormally: true,
                sceneIsActive: completionContext.sceneIsActive
            )
        }
    }

    private func beginResponseCompletionBackgroundTask() {
        guard responseCompletionBackgroundTask == .invalid else { return }

        let taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "Hermes response completion") {
            Task { @MainActor in
                endResponseCompletionBackgroundTask()
                viewModel.suspendStreamForBackground()
            }
        }

        responseCompletionBackgroundTask = taskIdentifier
        if taskIdentifier == .invalid {
            viewModel.suspendStreamForBackground()
        }
    }

    private func endResponseCompletionBackgroundTask() {
        guard responseCompletionBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(responseCompletionBackgroundTask)
        responseCompletionBackgroundTask = .invalid
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Deliberate jump to the latest content. Snap without animation while a
        // response is streaming so the tap lands immediately instead of racing
        // the short follow animations already chasing incoming tokens.
        ChatHaptics.scrolledToLatest(isEnabled: isHapticsEnabled)
        scrollToLatestContent(
            proxy,
            animated: viewModel.activeStreamID == nil,
            isUserInitiated: true
        )
    }

    private func scrollToLatestTranscriptMessage(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        isUserInitiated: Bool = false
    ) {
        guard let latestTranscriptMessageID else { return }

        scheduleFollowScroll(
            proxy,
            targetID: latestTranscriptMessageID,
            anchor: .bottom,
            animated: animated,
            isUserInitiated: isUserInitiated
        )
    }

    private func scrollToLatestContent(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        isUserInitiated: Bool = false
    ) {
        guard !viewModel.messages.isEmpty else { return }

        scheduleFollowScroll(
            proxy,
            targetID: bottomAnchorID,
            anchor: .bottom,
            animated: animated,
            isUserInitiated: isUserInitiated
        )
    }

    private func scheduleFollowScroll(
        _ proxy: ScrollViewProxy,
        targetID: String,
        anchor: UnitPoint,
        animated: Bool,
        isUserInitiated: Bool
    ) {
        // Explicit jumps re-arm the follow latch; automatic follows (streaming
        // tokens, new rows) only run while the latch is already on and no
        // disclosure toggle is settling.
        if isUserInitiated {
            handleFollowEvent(.reset)
        } else if !isFollowingLatestContent {
            return
        }

        followScrollGeneration += 1
        let generation = followScrollGeneration

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled, generation == followScrollGeneration else { return }
            // Re-check at fire time: a drag or a disclosure toggle may have
            // begun during the delay.
            if !isUserInitiated, !isFollowingLatestContent { return }

            // Snap (no animation) while inside the cache-first reconcile window so the
            // taller server transcript replacing the cached one doesn't animate a jump
            // (#289). Evaluated at fire time so it's robust to onChange ordering.
            let isCacheFirstSnapWindow = cacheFirstSnapUntil.map { Date() < $0 } ?? false
            if animated, !isCacheFirstSnapWindow {
                // While streaming, follow with the short cadence-synced curve so
                // back-to-back triggers retarget smoothly; otherwise keep the
                // regular follow-scroll feel.
                let animation = viewModel.activeStreamID != nil
                    ? ChatMotion.streamingFollow(reduceMotion: reduceMotion)
                    : ChatMotion.scrollToLatest(reduceMotion: reduceMotion)
                withAnimation(animation) {
                    proxy.scrollTo(targetID, anchor: anchor)
                }
            } else {
                proxy.scrollTo(targetID, anchor: anchor)
            }
        }
    }

    private func dismissKeyboard() {
        composerIsFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var canFocusComposer: Bool {
        !viewModel.isViewingCachedData
            && !viewModel.isUploadingAttachment
            && viewModel.uploadAttachmentErrorMessage == nil
    }

    private func handleInitialAppearanceCompletion() {
        didCompleteInitialAppearance = true
        applyInitialComposerFocusPolicyIfNeeded()
    }

    private func applyInitialComposerFocusPolicyIfNeeded() {
        guard !didApplyInitialComposerFocusPolicy else { return }
        guard didCompleteInitialAppearance, isInitialComposerFocusContentReady else { return }

        if !viewModel.messages.isEmpty {
            didApplyInitialComposerFocusPolicy = true
            return
        }

        guard viewModel.errorMessage == nil, canFocusComposer else { return }
        didApplyInitialComposerFocusPolicy = true
        requestComposerFocusIfPossible()
    }

    private func presentPreviewRestoringComposerFocusIfNeeded(_ present: () -> Void) {
        shouldRestoreComposerFocusAfterPreview = composerIsFocused
        if composerIsFocused {
            composerIsFocused = false
        }
        present()
    }

    private func restoreComposerFocusAfterPreviewIfNeeded() {
        guard shouldRestoreComposerFocusAfterPreview else { return }
        shouldRestoreComposerFocusAfterPreview = false
        requestComposerFocusIfPossible()
    }

    private func requestComposerFocusIfPossible() {
        guard canFocusComposer else { return }

        Task { @MainActor in
            await Task.yield()
            guard canFocusComposer else { return }
            composerIsFocused = true
        }
    }

    private func handleFollowEvent(_ event: ChatScrollPolicy.FollowEvent) {
        let resolved = ChatScrollPolicy.resolveFollow(current: followLatch, event: event)
        if resolved != followLatch {
            followLatch = resolved
        }
    }

    /// Suspends follow scrolls and the bottom anchor through a disclosure
    /// animation; the transcript view pins the offset itself. The latch is
    /// untouched, so the next streaming trigger catches up once the toggle has
    /// settled.
    private func handleDisclosureToggle() {
        ChatHaptics.disclosureToggled(isEnabled: isHapticsEnabled)
        suspendBottomAnchorForDisclosure()
    }

    /// One tick per view-model bump; the view model already throttles and skips replay.
    private func handleStreamingHapticPulse() {
        ChatHaptics.streamingPulse(isEnabled: isHapticsEnabled && isStreamingPulseEnabled)
    }

    private func suspendBottomAnchorForDisclosure() {
        disclosureSettleGeneration += 1
        let generation = disclosureSettleGeneration
        isDisclosureSettling = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ChatScrollPolicy.disclosureAnchorSuspension))
            guard generation == disclosureSettleGeneration else { return }
            isDisclosureSettling = false
        }
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        let isStreaming = viewModel.activeStreamID != nil
        let isNearBottom = ChatScrollPolicy.isNearBottom(
            distanceFromBottom: metrics.distanceFromBottom,
            isStreaming: isStreaming
        )
        let wasNearBottom = isScrolledNearBottom
        isScrolledNearBottom = isNearBottom
        handleFollowEvent(.contentScrolled(
            isAtBottom: ChatScrollPolicy.isAtBottom(distanceFromBottom: metrics.distanceFromBottom),
            isUserScrolling: metrics.isUserInteracting,
            movedAwayFromBottom: metrics.movedAwayFromBottom,
            wasNearBottom: wasNearBottom
        ))
    }

    private func prepareTranscriptForExplicitSend() {
        handleFollowEvent(.reset)
    }

    private func beginEditMessage(_ context: MessageActionContext) {
        editDraft = context.copyText
        editContext = context
        let messagesAfter = transcriptMessagesAfter(context)
        if messagesAfter > 0 {
            showEditDiscardConfirmation = true
        } else {
            showEditSheet = true
        }
    }

    private func submitEdit(_ context: MessageActionContext) async {
        editContext = nil
        showEditDiscardConfirmation = false

        let success = await viewModel.editMessage(context, newText: editDraft, modelContext: modelContext)

        if success {
            editDraft = ""
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func beginRegenerateResponse(_ context: MessageActionContext) {
        regenerateContext = context
        let messagesAfter = transcriptMessagesAfter(context)
        if messagesAfter > 0 {
            showRegenerateDiscardConfirmation = true
        } else {
            Task { await submitRegenerate(context) }
        }
    }

    private func submitRegenerate(_ context: MessageActionContext) async {
        regenerateContext = nil
        showRegenerateDiscardConfirmation = false

        _ = await viewModel.regenerateAssistantResponse(context, modelContext: modelContext)

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private var editDiscardWarningMessage: String {
        guard let context = editContext else { return "" }
        let messagesAfter = transcriptMessagesAfter(context)
        return String(localized: "Editing this message will discard \(messagesAfter) later messages.")
    }

    private var regenerateDiscardWarningMessage: String {
        guard let context = regenerateContext else { return "" }
        let messagesAfter = transcriptMessagesAfter(context)
        return String(localized: "Regenerating this response will discard \(messagesAfter) later messages.")
    }

    private var profileSwitchWarningMessage: String {
        guard let profile = pendingProfileSelection else {
            return String(localized: "Switching profiles starts a separate session so this transcript is not retagged.")
        }

        return String(localized: "Switch to \(profile.displayName) and start a new session. This keeps the current transcript on its original profile.")
    }

    private func transcriptMessagesAfter(_ context: MessageActionContext) -> Int {
        guard let index = transcriptMessages.firstIndex(where: { $0.id == context.messageID }) else {
            return 0
        }

        return max(0, transcriptMessages.count - 1 - index)
    }
}

struct ChatToolbarTitleLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsSubtitle, let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var showsSubtitle: Bool {
        !dynamicTypeSize.isAccessibilitySize
    }

    private var accessibilityLabel: String {
        guard let subtitle else { return title }
        return "\(title), \(subtitle)"
    }
}

struct ChatToolbarActionCluster<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .modifier(LegacyToolbarClusterStyle())
        .accessibilityElement(children: .contain)
    }
}

/// On iOS 26+ the navigation toolbar already renders this trailing item inside a
/// Liquid Glass pill, so styling the cluster ourselves stacked a second capsule
/// and produced the double border reported in #333. Below iOS 26 the system
/// supplies no pill, so we keep the original material capsule there.
private struct LegacyToolbarClusterStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .background(
                    Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.24 : 0.42),
                    in: Capsule()
                )
                .adaptiveGlass(
                    .regular,
                    isInteractive: false,
                    fallbackMaterial: .ultraThinMaterial,
                    in: Capsule()
                )
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color(.separator).opacity(colorScheme == .dark ? 0.38 : 0.24), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct ChatToolbarActionSlot<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .labelStyle(.iconOnly)
            .font(.body)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

enum ChatToolbarSubtitleResolver {
    static func subtitle(workspacePath: String?, profileTitle: String?) -> String? {
        if let workspace = nonEmpty(workspacePath) {
            return workspace.lastPathComponentFallback
        }

        guard let profile = nonEmpty(profileTitle), profile != "Profile" else {
            return nil
        }

        return profile
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PastedFile {
    let data: Data
    let filename: String
}

private enum PastedFileError: LocalizedError {
    case unreadableURL
    case unreadableImage
    case fileTooLarge(filename: String)

    var errorDescription: String? {
        switch self {
        case .unreadableURL:
            String(localized: "Could not read the pasted file.")
        case .unreadableImage:
            String(localized: "Could not read the pasted image.")
        case .fileTooLarge(let filename):
            PendingAttachment.uploadTooLargeMessage(filename: filename)
        }
    }
}

private extension SlashCommandExecutionResult {
    var isSuccessfulSubmission: Bool {
        switch self {
        case .executed, .openedSession:
            true
        case .sendAsMessage, .unsupported, .needsSubArg:
            false
        }
    }
}

/// Mirrors composer state into the persisted draft. Extracted from `ChatView`'s
/// modifier chain: folding these two observers into one modifier keeps the
/// chain within the Swift type-checker's budget.
private struct ChatDraftSyncModifier: ViewModifier {
    let pendingAttachments: [PendingAttachment]
    let composerSettings: ChatDraftSettings
    let onAttachmentsChange: () -> Void
    let onSettingsChange: (ChatDraftSettings) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: pendingAttachments) { _, _ in
                onAttachmentsChange()
            }
            .onChange(of: composerSettings) { _, newSettings in
                onSettingsChange(newSettings)
            }
    }
}
