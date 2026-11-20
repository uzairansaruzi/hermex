import SwiftUI
import SwiftData
import UIKit
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

private extension ActionToast {
    static func gitProgress(_ title: String, systemImage: String, branch: String?) -> ActionToast {
        ActionToast(message: title, systemImage: systemImage, accessibilityLabel: title, tone: .busy, edge: .top,
                    detailLines: [branch].compactMap { $0 }.filter { !$0.isEmpty })
    }

    static func gitResult(_ title: String, succeeded: Bool, branch: String?, detailLines: [String]) -> ActionToast {
        ActionToast(message: title,
                    systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    accessibilityLabel: title, tone: succeeded ? .success : .failure, edge: .top,
                    detailLines: [branch].compactMap { $0 }.filter { !$0.isEmpty } + detailLines)
    }
}

private enum ActiveGitSheet: Identifiable {
    case changes
    case commit
    case branches

    var id: Self { self }
}

private struct TurnReviewKey: Hashable {
    let git: GitWorkspaceAvailabilityViewModel
    let base: GitTurnBase?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.git === rhs.git && lhs.base == rhs.base }
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(git))
        hasher.combine(base)
    }
}

private enum TurnDiffPresentation: Identifiable {
    case turnFiles([GitFile], initial: GitFile?, scope: GitReviewScope)

    init?(_ summary: TurnFileChangeSummary?, initial: GitFile? = nil) {
        guard let summary, !summary.diffFiles.isEmpty else { return nil }
        self = .turnFiles(summary.diffFiles, initial: initial, scope: summary.scope ?? .uncommitted)
    }

    var id: String {
        switch self {
        case .turnFiles(let files, let initial, let scope):
            return "turn:\(scope):" + files.map(\.id).joined(separator: "|") + ":" + (initial?.id ?? "")
        }
    }
}

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
        .background(.appMaterial(.regularMaterial))
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
        .foregroundStyle(.appSecondary)
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
                .background(Color(.appSurface), in: Capsule())
        }
        .disabled(!isReady)
        .accessibilityLabel(String(localized: "Playback speed"))
        .accessibilityValue(speed.title)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.appSecondary)
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
    private let composerMaximumWidth = ChatReadingWidth.maximumWidth(horizontalPadding: 16)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hermesUpdateSignIn) private var updateHermesSignIn
    @Environment(\.openBotScreen) private var openBotScreen
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(AppHaptics.streamingPulseIsEnabledKey) private var isStreamingPulseEnabled = false
    @AppStorage(SessionChatPreferences.dismissKeyboardKey) private var dismissKeyboardAfterSend = false
    @AppStorage(SessionChatPreferences.completionPositionKey) private var completionPositionRawValue = SessionChatPreferences.CompletionPosition.latest.rawValue
    @AppStorage(StreamingSendBehavior.storageKey) private var streamingSendBehaviorRawValue = StreamingSendBehavior.steer.rawValue
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @AppStorage(AgentRunLiveActivityPrivacy.showsResponseExcerptsKey) private var showsLiveActivityResponseExcerpts = false
    @AppStorage(ChatTranscriptDisplaySettings.thinkingAndToolCardsKey) private var thinkingAndToolCards = ThinkingAndToolCards.collapsed
    @AppStorage(ChatTranscriptDisplaySettings.foldsSettledTurnsKey) private var foldsSettledTurns = true
    @AppStorage(ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey) private var rtlChatLayoutEnabled = ChatTranscriptDisplaySettings.rtlChatLayoutDefaultEnabled
    @AppStorage(SectionVisibilitySettings.chatFilesKey) private var showsFilesButton = true
    @AppStorage(SectionVisibilitySettings.chatGitKey) private var showsGitControls = true

    let session: SessionSummary
    let server: URL
    let onAPIError: (Error) -> Void
    let loadsInitialMessages: Bool
    let autoStartsVoiceInput: Bool
    let draftStore: ChatDraftStore
    let draftAttachmentStore: any ChatDraftAttachmentStoring
    let restoresDraftSettings: Bool
    let onConversationStarted: () -> Void
    let isHermesSession: Bool
    let hermesParentKey: String?
    let hermesRowWorkspace: String?
    let isCronRun: Bool
    let onReplaceHermesSession: ((HermesSessionChat) -> Void)?
    private let waitingShortcut: WaitingShortcutText?
    private let hermesTranscriber: ComposerTranscriber?
    private let hermesSessionChatID: String?
    let onOpenHermesSessions: ((HermesSessionListEntry) -> Void)?

    @State private var draftMessage = ""
    @State private var draftQuotes: [ComposerQuote] = []
    @State private var draftRevision = 0
    @State private var isScrolledNearBottom = true
    @State private var completionScrollPolicy = ChatCompletionScrollPolicy()
    @State private var completedResponseRenderID: String?
    @State private var hydratedCompletionStreamID: String?
    @State private var composerFocusRevision = 0
    @State private var followScrollGeneration = 0
    @State private var isDisclosureSettling = false
    @State private var disclosureSettleGeneration = 0
    @State private var transcriptStructureMemo = TranscriptStructureMemo()
    @State private var cacheFirstSnapUntil: Date?
    @State private var pushedSession: SessionSummary?
    @State private var pushedHermesSession: HermesSessionChat?
    @State private var pushedHermesSessionList: HermesSessionListEntry?
    @State private var forkOrigin: ForkOrigin?
    @State private var isOpeningForkParent = false
    @State private var editContext: MessageActionContext?
    @State private var editDraft = ""
    @State private var showEditSheet = false
    @State private var showEditDiscardConfirmation = false
    @State private var regenerateContext: MessageActionContext?
    @State private var showRegenerateDiscardConfirmation = false
    @State private var attachmentPreviewItem: ChatAttachmentPreviewItem?
    @State private var stagedPasteItem: StagedPasteItem?
    @State private var transcriptMediaPreviewItem: TranscriptMediaPreviewItem?
    @State private var transcriptImageGallery: ImageLightboxGallery<TranscriptMediaPreviewItem>?
    @State private var attachmentImageGallery: ImageLightboxGallery<ChatAttachmentPreviewItem>?
    @State private var hermesFilePreviewItem: HermesFilePreviewItem?
    @State private var openedFileReference: FileReference?
    @State private var pendingProfileSelection: ProfileSummary?
    @State private var showProfileNewSessionConfirmation = false
    @State private var pendingClearConfirmation: PendingClearConfirmation?
    @State private var goalDraft = ""
    @State private var showsGoalSheet = false
    @State private var servingProfile: String?
    @State private var activeGitSheet: ActiveGitSheet?
    @State private var pendingBranchCheckout: GitCheckoutTarget?
    @State private var turnDiffPresentation: TurnDiffPresentation?
    @State private var reviewProgress = ReviewProgressStore()
    @State private var viewModel: ChatViewModel
    @State private var continuity: ChatContinuity
    @State private var viewID = UUID()
    @State private var gitAvailabilityViewModel: GitWorkspaceAvailabilityViewModel
    @State private var gitAlert: GitChatAlert?
    @State private var composerHeight = ChatView.restingComposerHeight
    private static let restingComposerHeightKey = "chat.restingComposerHeight"
    @MainActor private static var restingComposerHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: restingComposerHeightKey)
        return saved > 0 ? saved : 52
    }()

    private func rememberRestingComposerHeight(_ height: CGFloat, isResting: Bool) {
        guard isResting, draftMessage.isEmpty, viewModel.pendingAttachments.isEmpty, !showsNewChatControls,
              height != ChatView.restingComposerHeight else { return }
        ChatView.restingComposerHeight = height
        UserDefaults.standard.set(Double(height), forKey: ChatView.restingComposerHeightKey)
    }

    @State private var clarificationBarHeight: CGFloat = 0
    @State private var btwInsetHeight: CGFloat = 0
    @State private var showsBtwFullScreen = false
    @State private var activeRunStatusHeight: CGFloat = 28
    @State private var planStripHeight: CGFloat = 30
    @State private var updateSignInPillHeight: CGFloat = 36
    @State private var textOrigin: ImportedTextOrigin?
    @State private var textBeforeHiddenRemoval: (text: String, origin: ImportedTextOrigin)?
    @State private var shortcutNoticeHeight: CGFloat = 0
    @State private var showsDelegatedWork = false
    @State private var showsBotProfileEditor = false
    @State private var showsChatSettings = false
    @State private var showsModelSettings = false
    @State private var pinnedNoticeStackHeight: CGFloat = 0
    @State private var hostNoticeHeight: CGFloat = 0
    @State private var composerIsFocused = false
    @State private var didHydrateDraft = false
    @State private var hasRequestedSkillsForTranscriptChips = false
    @State private var isRestoringDraftAttachments = false
    @State private var draftAttachmentsAwaitingRestore: [ChatDraftAttachment] = []
    @State private var draftAttachmentsPendingRetry: [ChatDraftAttachment] = []
    @State private var lastSyncedDraftAttachments: [ChatDraftAttachment] = []
    @State private var restoredDraftSettings: ChatDraftSettings?
    @State private var didApplyRestoredDraftSettings = false
    @State private var didCompleteInitialAppearance = false
    @State private var isInitialComposerFocusContentReady = false
    @State private var didApplyInitialComposerFocusPolicy = false
    @State private var shouldRestoreComposerFocusAfterPreview = false
    @State private var responseCompletionNotificationTracker = ResponseCompletionNotificationTracker()
    @State private var pendingNotificationOffer: NotificationOffer.Offer?
    @State private var isOnScreen = false
    @State private var responseCompletionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var activeStreamStatusRefreshTask: Task<Void, Never>?
    @State private var appearanceTask: Task<Void, Never>?
    @State private var initialAttachments: [SharedAttachmentImport]
    @State private var didUploadInitialAttachments = false
    @State private var showsStopConfirmation = false
    private let shareNotice: SharedSkipsNotice?
    @State private var toastState = ActionToastState()

    init(
        session: SessionSummary,
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        initialDraft: String = "",
        initialQuotes: [ComposerQuote] = [],
        initialAttachments: [SharedAttachmentImport] = [],
        shareNotice: SharedSkipsNotice? = nil,
        loadsInitialMessages: Bool = true,
        autoStartsVoiceInput: Bool = false,
        draftStore: ChatDraftStore? = nil,
        draftAttachmentStore: (any ChatDraftAttachmentStoring)? = nil,
        restoresDraftSettings: Bool = false,
        onConversationStarted: @escaping () -> Void = {},
        hermesSession: HermesSessionChat? = nil,
        onReplaceHermesSession: ((HermesSessionChat) -> Void)? = nil,
        onOpenHermesSessions: ((HermesSessionListEntry) -> Void)? = nil,
        onHermesDraftKeyChange: ((ChatDraftKey) -> Void)? = nil,
        waitingShortcut: WaitingShortcutText? = nil,
        continuity: ChatContinuity? = nil
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
        isHermesSession = hermesSession != nil
        hermesSessionChatID = hermesSession?.id.uuidString
        hermesParentKey = hermesSession?.parentKey
        hermesRowWorkspace = hermesSession?.workspace
        isCronRun = hermesSession?.isCronRun == true
        self.onReplaceHermesSession = onReplaceHermesSession
        hermesTranscriber = hermesSession.map { HermesTranscription.transcriber(for: $0) }
        self.onOpenHermesSessions = onOpenHermesSessions
        self.waitingShortcut = waitingShortcut
        _draftMessage = State(initialValue: initialDraft)
        _draftQuotes = State(initialValue: initialQuotes)
        _initialAttachments = State(initialValue: initialAttachments)
        self.shareNotice = shareNotice
        let continuity = continuity ?? ChatContinuity()
        _continuity = State(initialValue: continuity)
        let model = continuity.model ?? ChatViewModel(
            session: session,
            server: server,
            showsLiveActivityResponseExcerpts: UserDefaults.standard.bool(
                forKey: AgentRunLiveActivityPrivacy.showsResponseExcerptsKey
            ),
            draftAttachmentStore: resolvedDraftAttachmentStore,
            draftStore: self.draftStore,
            backend: hermesSession.map { .hermes(HermesChatTurnCoordinator($0)) } ?? .webui
        )
        model.hermesBotChatRoot = hermesSession?.botChatRoot
        model.hermesLineageRoot = hermesSession?.lineageRoot
        model.onHermesDraftKeyChange = onHermesDraftKeyChange
        _viewModel = State(initialValue: model)
        _isScrolledNearBottom = State(initialValue: model.followLatch.isFollowing)
        _gitAvailabilityViewModel = State(initialValue: GitWorkspaceAvailabilityViewModel(
            session: session,
            server: server
        ))
    }

    init(hermesSession: HermesSessionChat, onReplace: ((HermesSessionChat) -> Void)? = nil,
         onOpenSessions: ((HermesSessionListEntry) -> Void)? = nil,
         onDraftKeyChange: ((ChatDraftKey) -> Void)? = nil, waitingShortcut: WaitingShortcutText? = nil,
         continuity: ChatContinuity? = nil) {
        self.init(
            session: SessionSummary(title: hermesSession.title, model: hermesSession.model,
                                    profile: hermesSession.target.profile),
            server: hermesSession.server,
            onAPIError: { _ in },
            shareNotice: hermesSession.shareNotice,
            autoStartsVoiceInput: hermesSession.autoStartsVoiceInput,
            hermesSession: hermesSession,
            onReplaceHermesSession: onReplace,
            onOpenHermesSessions: onOpenSessions,
            onHermesDraftKeyChange: onDraftKeyChange,
            waitingShortcut: waitingShortcut,
            continuity: continuity
        )
    }

    private var messageComposer: some View {
        MessageComposerView(
            draftMessage: $draftMessage,
            quotes: persistedQuotesBinding,
            isFocused: Binding(
                get: { composerIsFocused },
                set: { value in
                    if composerIsFocused != value { composerFocusRevision += 1 }
                    composerIsFocused = value
                }
            ),
            isSending: viewModel.isStartingChat || viewModel.isSendingVoiceNote || viewModel.isHermesSubmissionUncertain
                || viewModel.isUndoingExchange || viewModel.hermesRequests?.answeringRequestID != nil
                || viewModel.isCachedCopyProvisional,
            isCompressingSession: viewModel.isCompressingSession,
            isWaitingForStream: viewModel.activeStreamID != nil,
            isCancellingStream: viewModel.isCancellingStream,
            access: ChatComposerAccess(session: session, isViewingCachedData: viewModel.showsOfflineCache,
                                       offersWaitingSend: viewModel.offersWaitingSend,
                                       hasWaitingSend: viewModel.waitingSend != nil),
            errorMessage: viewModel.sendErrorMessage,
            errorFixPrompt: viewModel.sendErrorRuntimeStale?.fixPrompt,
            onFixError: viewModel.errorUnserved == nil ? nil : { servingProfile = viewModel.errorUnserved?.profile },
            configurationErrorMessage: viewModel.composerConfigurationErrorMessage
                ?? viewModel.hermesSettings?.controls.errorMessage,
            contextWindowSnapshot: viewModel.contextWindowSnapshot,
            gitViewModel: gitAvailabilityViewModel,
            modelGroups: viewModel.composerModelGroups,
            selectedModelID: viewModel.selectedModelID,
            selectedModelProviderID: viewModel.selectedModelProviderID,
            selectedModelTitle: viewModel.selectedModelTitle,
            workspaceRoots: viewModel.workspaceRoots,
            selectedWorkspacePath: viewModel.selectedWorkspacePath,
            workspaceSuggestions: viewModel.workspaceSuggestions,
            workspaceManagementServer: isHermesSession ? nil : server,
            personalitySuggestions: viewModel.personalitySuggestions,
            skillSuggestions: viewModel.composerSkillSuggestions,
            hasLoadedSkillSuggestions: isHermesSession || viewModel.hasLoadedSkillSlashSuggestions,
            agentCommands: viewModel.composerAgentCommands,
            profileOptions: viewModel.composerProfileOptions,
            isSingleProfileMode: viewModel.composerIsSingleProfileMode,
            selectedProfileName: viewModel.selectedProfileName,
            selectedProfileTitle: viewModel.selectedProfileTitle,
            selectedReasoningEffort: viewModel.composerReasoningEffort,
            supportedReasoningEfforts: viewModel.composerSupportedReasoningEfforts,
            supportsReasoningEffort: viewModel.supportsReasoningEffort,
            showsReasoningControl: viewModel.showsReasoningEffortControl,
            isUpdatingConfiguration: viewModel.isUpdatingComposerConfiguration
                || viewModel.hermesSettings?.controls.isApplying == true || viewModel.pendingHermesFolder != nil,
            pendingAttachments: viewModel.pendingAttachments,
            isUploadingAttachment: viewModel.isUploadingAttachment || isRestoringDraftAttachments,
            attachmentUploadCount: viewModel.attachmentUploadCount,
            attachmentUploadGeneration: viewModel.attachmentUploadGeneration,
            isSendingVoiceNote: viewModel.isSendingVoiceNote,
            autoStartsVoiceInput: autoStartsVoiceInput,
            apiClient: viewModel.client,
            sessionID: session.sessionId,
            server: server,
            searchFilePaths: viewModel.offersFilePathSearch ? { await viewModel.searchFilePaths($0) } : nil,
            chipFilePaths: viewModel.fileChipPaths,
            botMentions: viewModel.hermesBotChat?.mentions,
            mentionAvatars: viewModel.hermesBotChat?.settings.avatars ?? [:],
            filePathSearch: viewModel.filePathSearch,
            uploadAttachmentErrorMessage: viewModel.uploadAttachmentErrorMessage,
            steerFailure: viewModel.steerFailureMessage.map { message in
                ComposerRetryableStatus(message: message) {
                    Task { await sendDraftMessage(behavior: .steer) }
                }
            },
            streamingSendBehavior: StreamingSendBehavior.storedValue(streamingSendBehaviorRawValue),
            onSend: { behavior in
                Task { await sendDraftMessage(behavior: behavior) }
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
                await viewModel.selectReasoningEffort(effort)
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
            onHeightChange: { height, isResting in
                composerHeight = height
                rememberRestingComposerHeight(height, isResting: isResting)
            },
            onPhotoMediaSelected: { media in
                Task { await handlePhotoSelection(media) }
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
                if let file = removedAttachment?.draftFileName {
                    syncDraftAttachments()
                    Task { await viewModel.deleteDraftAttachmentCopy(named: file, attachmentID: id) }
                }
            },
            onPreviewAttachment: { attachment in
                if ComposerLargePaste.isStagedPaste(attachment) {
                    return presentPreviewRestoringComposerFocusIfNeeded {
                        stagedPasteItem = StagedPasteItem(
                            attachment: attachment,
                            isSending: viewModel.stagedFilesAreSending || isRestoringDraftAttachments
                        )
                    }
                }
                let pending = viewModel.pendingAttachments
                guard let index = pending.firstIndex(where: { $0.id == attachment.id }) else {
                    return presentAttachmentPreview([ChatAttachmentPreviewItem(pending: attachment)], at: 0)
                }
                presentAttachmentPreview(pending.map(ChatAttachmentPreviewItem.init(pending:)), at: index)
            },
            onDismissUploadAttachmentError: {
                viewModel.setUploadAttachmentError(nil)
            },
            onDismissError: viewModel.errorUnserved != nil || viewModel.sendErrorRuntimeStale != nil
                ? nil : { viewModel.clearComposerErrors() },
            onSelectFileReference: { path in
                viewModel.recordFileChipReference(path)
            },
            onFileReferenceCandidatesChange: { draft in
                await viewModel.loadFileChipReferences(draft: draft)
            },
            onDraftEdit: { text in
                viewModel.clearComposerErrors()
                persistDraftEdit(text)
            },
            recallLastSentText: { viewModel.lastSentText },
            onPasteLargeText: isHermesSession ? { text in
                viewModel.stagePastedText(text)
            } : nil,
            onOpenFileReference: { path in
                openedFileReference = FileReference(path: path, line: nil, column: nil)
            },
            onSelectGitBranch: { target in
                Task { await performGitCheckout(target) }
            },
            onCreateGitBranch: { target in
                Task { await performGitCheckout(target) }
            },
            onRefreshGitBranches: {
                Task { await gitAvailabilityViewModel.loadBranches() }
            },
            showsSessionControls: !isHermesSession,
            slashScope: viewModel.hermesSlashCommands?.scope ?? .webui,
            hostSlashCompletion: viewModel.hermesSlashCommands?.completion,
            onCompleteHostSlashArgument: { text in
                await viewModel.hermesSlashCommands?.complete(text)
            },
            showsModelAndProfileControls: isHermesSession,
            configurationNotice: viewModel.composerConfigurationNotice,
            sentReasoningEffort: viewModel.composerSentReasoningEffort,
            fastMode: viewModel.composerFastMode,
            mayChangeFastMode: viewModel.composerMayChangeFastMode,
            onSelectFastMode: { enabled in
                Task {
                    if await viewModel.selectFastMode(enabled) {
                        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                    }
                }
            },
            isChatSettingsPresented: $showsChatSettings,
            isModelSettingsPresented: $showsModelSettings,
            modelConfirmationControls: viewModel.hermesSettings?.controls,
            approvals: viewModel.composerApprovals,
            onSetYolo: { enabled in
                Task { await viewModel.setSessionApprovalBypass(enabled) }
            },
            onSelectApprovalMode: { mode in
                Task { await viewModel.selectApprovalMode(mode) }
            },
            showsNewChatControls: showsNewChatControls,
            uploadsAttachmentsOnSend: isHermesSession,
            onCancelAttachmentUpload: viewModel.isSendingAttachments ? { viewModel.cancelAttachmentUpload() } : nil,
            hermesTranscriber: hermesTranscriber
        )
        .environment(\.layoutDirection, chatLayoutDirection)
        .background(
            NavigationAppearanceCompletionObserver(action: handleInitialAppearanceCompletion)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    private func presentTranscriptMediaPreview(
        _ reference: TranscriptMediaReference,
        in replyMedia: [TranscriptMediaReference]
    ) {
        presentPreviewRestoringComposerFocusIfNeeded {
            if isHermesSession, reference.isHermesDocumentCandidate || reference.isHTMLReportCandidate {
                hermesFilePreviewItem = HermesFilePreviewItem(reference: reference)
                return
            }
            if reference.opensInImageLightbox {
                transcriptImageGallery = ImageLightboxGallery(tapped: reference, in: replyMedia)
            } else {
                transcriptMediaPreviewItem = TranscriptMediaPreviewItem(reference: reference)
            }
        }
    }

    private func presentSentAttachmentPreview(
        _ tapped: MessageAttachmentPreview,
        among siblings: [MessageAttachmentPreview]
    ) {
        let attachment = tapped.attachment
        guard isHermesSession, let path = attachment.path, !path.isEmpty else {
            let pageable = siblings.filter { !isHermesSession || $0.attachment.path?.isEmpty != false }
            guard let index = pageable.firstIndex(where: { $0.attachment == attachment }) else {
                let item = ChatAttachmentPreviewItem(message: attachment, localData: tapped.localData)
                return presentAttachmentPreview([item], at: 0)
            }
            let items = pageable.map { ChatAttachmentPreviewItem(message: $0.attachment, localData: $0.localData) }
            return presentAttachmentPreview(items, at: index)
        }
        presentPreviewRestoringComposerFocusIfNeeded {
            hermesFilePreviewItem = HermesFilePreviewItem(
                reference: TranscriptMediaReference(rawReference: path), name: attachment.name,
                isSentAttachment: true
            )
        }
    }

    private func presentAttachmentPreview(_ items: [ChatAttachmentPreviewItem], at index: Int) {
        let item = items[index]
        presentPreviewRestoringComposerFocusIfNeeded {
            if item.inferredIsImage {
                attachmentImageGallery = ImageLightboxGallery(tapped: item, siblings: items, isImage: \.inferredIsImage)
            } else {
                attachmentPreviewItem = item
            }
        }
    }

    private func transcriptImageLightbox(
        for gallery: ImageLightboxGallery<TranscriptMediaPreviewItem>
    ) -> some View {
        ImageLightboxPager(gallery: gallery) { item, page in
            TranscriptMediaImageLightbox(
                server: server,
                files: transcriptMediaFiles,
                item: item,
                page: page,
                onAPIError: onAPIError
            )
        }
    }

    private func transcriptMediaPreviewView(for item: TranscriptMediaPreviewItem) -> some View {
        TranscriptMediaPreviewView(
            server: server,
            files: transcriptMediaFiles,
            item: item,
            onAPIError: onAPIError
        )
    }

    private func hermesFilePreviewData(for item: HermesFilePreviewItem) async throws -> Data {
        if item.isSentAttachment { return try await viewModel.hermesAttachmentData(path: item.reference.rawReference) }
        switch item.reference.source {
        case let .localPath(path):
            return try await viewModel.hermesAttachmentData(path: path)
        case let .remoteURL(url):
            do {
                return try await BotArtifactDownload.data(session: APIClient.sharedPublicMediaSession,
                                                          request: URLRequest(url: url))
            } catch is BotFailure { throw BotArtifactFailure.unavailable }
        }
    }

    private func handleTranscriptLink(_ url: URL) -> OpenURLAction.Result? {
        let root = isHermesSession ? browsableHermesWorkspace?.cwd : session.workspace
        if let reference = FileReference.parse(url.absoluteString, workspaceRoot: root) {
            openedFileReference = reference
            return .handled
        }
        guard isHermesSession,
              let path = FileReference.absoluteMediaPath(url.absoluteString, workspaceRoot: root)
        else { return nil }
        let report = TranscriptMediaReference(rawReference: path)
        guard report.isHTMLReportCandidate else { return nil }
        presentPreviewRestoringComposerFocusIfNeeded {
            hermesFilePreviewItem = HermesFilePreviewItem(reference: report)
        }
        return .handled
    }

    private func fileReferenceSheet(for reference: FileReference) -> some View {
        NavigationStack {
            FilePreviewView(
                files: workspaceFiles,
                entry: WorkspaceEntry(name: reference.name, path: reference.path),
                initialLine: reference.line,
                onAPIError: onAPIError,
                onAddToPrompt: reviewCommentHook,
                onReturnToChat: { openedFileReference = nil }
            )
            .id(reference)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { openedFileReference = nil }
                }
            }
        }
    }

    private var transcriptMediaSessionID: String? {
        guard let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

    private var browsableHermesWorkspace: HermesWorkspaceContext? {
        viewModel.hermesWorkspace.flatMap { $0.isLocal ? $0 : nil }
    }

    private var workspaceFiles: (any WorkspaceFileClient)? {
        guard isHermesSession else { return WebUIWorkspaceFileClient(session: session, server: server) }
        return browsableHermesWorkspace == nil ? nil : viewModel.hermesWorkspaceFiles
    }

    private var transcriptMediaFiles: (any WorkspaceFileClient)? {
        if isHermesSession { return viewModel.hermesWorkspaceFiles }
        return transcriptMediaSessionID.map { WebUIWorkspaceFileClient(sessionID: $0, workspace: session.workspace, server: server) }
    }

    private var transcriptMediaCacheNamespace: String {
        viewModel.hermesAttachmentCacheNamespace
            ?? "\(server.absoluteString)|\(transcriptMediaSessionID ?? "local:\(session.id)")"
    }

    private func webuiApprovalInset(_ prompt: ApprovalPromptState, maximumExpandedHeight: CGFloat) -> some View {
        ApprovalRequestInset(
            content: prompt.requestContent,
            maximumExpandedHeight: maximumExpandedHeight,
            isResponding: viewModel.isRespondingToApproval,
            isStopping: viewModel.isCancellingStream,
            errorMessage: viewModel.approvalErrorMessage,
            isHapticsEnabled: isHapticsEnabled,
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
            },
            onStop: {
                Task { await cancelStream() }
            },
            onDismissKeyboard: dismissKeyboard,
            onFootprintChange: { height in
                clarificationBarHeight = height
            }
        )
        .id(prompt.id)
        .padding(.horizontal, 16)
        .padding(.bottom, composerHeight + 8)
        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
    }

    private func hermesApprovalInset(
        _ approval: BotApprovalRequest,
        requests: HermesChatRequests,
        maximumExpandedHeight: CGFloat
    ) -> some View {
        ApprovalRequestInset(
            content: approval.requestContent(pendingCount: requests.approvalCount),
            maximumExpandedHeight: maximumExpandedHeight,
            isResponding: !requests.mayAnswer,
            isStopping: viewModel.isCancellingStream,
            errorMessage: requests.errorMessage,
            summary: requests.summaryPresentation(for: approval, workingDirectory: viewModel.hermesWorkspace?.cwd),
            isHapticsEnabled: isHapticsEnabled,
            onChoice: { choice in
                guard let action = requests.prepareAnswer(),
                      let answer = BotApprovalRequest.Choice(rawValue: choice.rawValue) else { return }
                Task {
                    if await requests.respond(action, choice: answer) {
                        ChatHaptics.approvalSubmitted(choice, isEnabled: isHapticsEnabled)
                    }
                }
            },
            onSkipAll: {
                guard let action = requests.prepareAnswer() else { return }
                Task {
                    if await requests.skipApprovals(action) {
                        ChatHaptics.approvalBypassEnabled(isEnabled: isHapticsEnabled)
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
        .id(approval.requestID)
        .padding(.horizontal, 16)
        .padding(.bottom, composerHeight + 8)
        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
    }

    private var chatScaffold: some View {
        GeometryReader { viewport in
            let clarificationMaximumHeight = max(
                0,
                viewport.size.height - composerHeight - 16
            )

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    if viewModel.showsOfflineCache {
                        ChatOfflineCacheBanner()
                    }

                    listenPlaybackBar

                    messageContent
                        .environment(\.layoutDirection, chatLayoutDirection)
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: viewModel.showsListenPlaybackBar)

                composerAccessoryStack

                clarificationInset(maximumExpandedHeight: clarificationMaximumHeight)

                messageComposer
                    .frame(maxWidth: composerMaximumWidth)
                    .environment(\.composerViewportIsShort, viewport.size.height < ComposerTextInputHeight.shortViewportHeight)

                ActionToastView(state: toastState)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.bottom, composerHeight + 8)
                    .zIndex(9)
            }
        }
        .overlay(alignment: .top) {
            ActionToastView(state: toastState, edge: .top)
                .padding(.horizontal, 16)
                .padding(.top, 10)
        }
        .themedPageBackground()
        .navigationTitle(viewModel.hermesBotChat?.botProfile?.name ?? displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: viewModel.hermesBotChat == nil ? nil : .title)
        .modifier(ChatNavigationBackground())
        .accessibilityIdentifier("chat-detail:\(viewModel.displayTitle)")
        .pushPresence(viewModel.pushPresence)
    }

    private var chatLifecycle: some View {
        chatScaffold
            .task(id: didCompleteInitialAppearance) {
                await handleInitialAppearanceTask()
            }
            .task {
                guard let skipped = shareNotice?.take(), let toast = ActionToast(sharedSkips: skipped) else { return }
                toastState.show(toast)
            }
            .onChange(of: scenePhase) {
                handleScenePhaseChange(scenePhase)
            }
            .onChange(of: NetworkPathMonitor.shared.changeCount) {
                handleNetworkPathChange()
            }
            .onChange(of: viewModel.activeStreamID) {
                if viewModel.activeStreamID != nil, let previousTurnKey = viewModel.latestRunOutcome?.turnKey {
                    viewModel.expandedTurnKeys.remove(previousTurnKey)
                }
                handleActiveStreamChange()
            }
            .onChange(of: viewModel.transcriptRelayoutScrollToken) {
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
            .onChange(of: screenShortcut.map(ObjectIdentifier.init)) {
                if isOnScreen { ScreenShortcut.shared.offer(screenShortcut, from: viewID) }
            }
            .onDisappear {
                isOnScreen = false
                ScreenShortcut.shared.withdraw(viewID)
                toastState.dismiss()
                composerFocusRevision += 1
                completionScrollPolicy.readerDidInteract()
                hydratedCompletionStreamID = nil
                let chatLeft = continuity.viewDisappeared(viewID)
                if chatLeft {
                    parkQueuedMessages()
                    viewModel.leaveWaitingSend()
                }
                flushDraftsBestEffort()
                appearanceTask?.cancel()
                appearanceTask = nil
                activeStreamStatusRefreshTask?.cancel()
                activeStreamStatusRefreshTask = nil
                if chatLeft {
                    viewModel.cancelPastedTextStaging()
                    viewModel.stopListening()
                    viewModel.suspendStreamForNavigation()
                    viewModel.cleanupPollingTasks()
                }
                gitAvailabilityViewModel.suspendPullRequestReads()
            }
            .onAppear {
                continuity.viewAppeared(viewID, model: viewModel) { [composerText = $draftMessage, toast = toastState] text, reason in
                    composerText.wrappedValue = text
                    if reason == .expired {
                        let notice = String(localized: "Not sent after 10 minutes offline. Your message is back in the composer.")
                        toast.show(ActionToast(message: notice, systemImage: "clock", accessibilityLabel: notice))
                    }
                }
                viewModel.protectDraftAttachments(for: draftKey)
                isOnScreen = true
                ScreenShortcut.shared.offer(screenShortcut, from: viewID)
                gitAvailabilityViewModel.resumePullRequestReads()
                appearanceTask?.cancel()
                appearanceTask = Task {
                    await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
                    guard !Task.isCancelled else { return }
                    if didCompleteInitialAppearance {
                        await viewModel.refreshApprovalBypassState()
                    }
                    guard !Task.isCancelled else { return }

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
            .onChange(of: viewModel.runEndTrigger) {
                guard viewModel.runEndTrigger > 0 else { return }
                handleRunEnd()
            }
            .onChange(of: viewModel.streamingHapticPulseTrigger, handleStreamingHapticPulse)
    }

    private var chatContent: some View {
        chatLifecycle
            .verticalBarToolbar { hasVerticalBar in
                if let botChat = viewModel.hermesBotChat {
                    ToolbarItem(placement: .topBarLeading) {
                        HermesBotChatPill(turn: botChat) { showsBotProfileEditor = true }
                    }
                } else {
                    ToolbarItem(placement: .principal) {
                        Button { showsChatSettings = true } label: {
                            ChatToolbarTitleLabel(title: displayTitle, subtitle: headerSubtitle)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Chat settings"))
                    }
                }

                if #available(iOS 27.1, *), hasVerticalBar {
                    chatActionRailItems
                } else {
                    if showsTrailingActions {
                        ToolbarItem(placement: .topBarTrailing) {
                            ChatToolbarActionCluster {
                                if showsBotChatSettingsButton { ChatToolbarActionSlot { botChatSettingsButton } }
                                if viewModel.showsGoalControls { ChatToolbarActionSlot { goalControlMenu } }
                                if showsFilesLink { ChatToolbarActionSlot { filesLink } }
                                if showsGitMenu { ChatToolbarActionSlot { gitActionsMenu } }
                                if let screenShortcut { ChatToolbarActionSlot { screenButton(screenShortcut) } }
                            }
                        }
                    }
                    delegatedWorkToolbarItem
                }
            }
            .navigationDestination(item: $pushedSession) { session in
                ChatView(session: session, server: server, onAPIError: onAPIError)
            }
            .navigationDestination(item: $pushedHermesSession) { chat in
                ChatView(hermesSession: chat, onReplace: { pushedHermesSession = $0 }, onOpenSessions: onOpenHermesSessions)
                    .modifier(SessionScreenModifier(chat: chat))
                    .id(chat.id)
            }
            .navigationDestination(item: $pushedHermesSessionList) { entry in
                HermesSessionListView(entry: entry).id(entry.id)
            }
            .navigationDestination(isPresented: $showsBotProfileEditor) { botProfileEditor }
            .onChange(of: showsBotProfileEditor) { _, isShown in
                if !isShown, let botChat = viewModel.hermesBotChat { Task { await botChat.settings.refreshProfiles() } }
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
            .sheet(item: $stagedPasteItem) { item in
                StagedPasteSheet(
                    item: item,
                    load: { await viewModel.stagedPasteText(item.attachment) },
                    save: { await viewModel.saveStagedPaste(item.attachment, text: $0) }
                )
            }
            .onChange(of: stagedPasteItem == nil) { _, isDismissed in
                if isDismissed {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .sheet(item: $transcriptMediaPreviewItem, content: transcriptMediaPreviewView)
            .fullScreenCover(item: $attachmentImageGallery) { gallery in
                ImageLightboxPager(gallery: gallery) { item, page in
                    ChatAttachmentImageLightbox(
                        session: session,
                        server: server,
                        item: item,
                        page: page,
                        onAPIError: onAPIError
                    )
                }
            }
            .onChange(of: attachmentImageGallery == nil) { _, isDismissed in
                if isDismissed {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .sheet(item: $hermesFilePreviewItem) { item in
                BotArtifactPreview(reference: item.reference, title: item.name) {
                    try await hermesFilePreviewData(for: item)
                }
            }
            .onChange(of: hermesFilePreviewItem == nil) { _, isDismissed in
                if isDismissed {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .fullScreenCover(item: $transcriptImageGallery, content: transcriptImageLightbox)
            .onChange(of: transcriptImageGallery == nil) { _, isDismissed in
                if isDismissed {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .onChange(of: transcriptMediaPreviewItem == nil) { _, isDismissed in
                if isDismissed {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .sheet(item: $openedFileReference, content: fileReferenceSheet)
            .onChange(of: viewModel.hermesWorkspace) {
                openedFileReference = nil
                pendingBranchCheckout = nil
                activeGitSheet = nil
                turnDiffPresentation = nil
                gitAvailabilityViewModel.retire()
                if let gitToastID = toastState.toast(at: .top)?.id { toastState.dismiss(gitToastID) }
                gitAlert = nil
                Task { await loadInitialGitAvailability() }
            }
            .sheet(item: $activeGitSheet, onDismiss: runPendingBranchCheckout, content: gitSheet)
            .sheet(item: $turnDiffPresentation, content: turnDiffSheet)
            .onChange(of: presentsWorkspaceSheet) { _, isPresented in
                if isPresented {
                    shouldRestoreComposerFocusAfterPreview = composerIsFocused
                    composerIsFocused = false
                } else {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .alert(item: $gitAlert, content: gitAlertPresentation)
            .fullScreenCover(isPresented: $showsBtwFullScreen) { btwFullScreen }
            .onChange(of: viewModel.hermesSideTasks?.btw == nil) { _, isClosed in
                if isClosed { showsBtwFullScreen = false }
            }
            .sheet(isPresented: $showsDelegatedWork) {
                if let work = viewModel.hermesActivity?.delegatedWork {
                    HermesDelegatedWorkView(work: work)
                        .themedPageBackground()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $servingProfile, content: serveEveryProfileSheet)
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
                    editDraft: $editDraft,
                    onSubmit: {
                        if let context = editContext {
                            Task { await submitEdit(context) }
                        }
                    }
                )
            }
    }

    var body: some View {
        chatContent
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
                        if isHermesSession {
                            startHermesSession(in: profile, replacing: false)
                        } else {
                            Task { await switchProfile(profile, startNewSession: true) }
                        }
                    }
                }
            } message: {
                Text(profileSwitchWarningMessage)
            }
            .modifier(
                ClearConversationAlertModifier(
                    pending: $pendingClearConfirmation,
                    isHapticsEnabled: isHapticsEnabled,
                    onConfirm: confirmClearConversation
                )
            )
            .notificationOfferAlert($pendingNotificationOffer)
            .modifier(HermesModelConfirmationModifier(
                controls: showsModelSettings ? nil : viewModel.hermesSettings?.controls
            ))
            .modifier(HermesPersonalityConfirmationModifier(
                settings: viewModel.hermesSettings, profile: viewModel.selectedProfileTitle,
                onConfirm: confirmHermesPersonality
            ))
            .modifier(HermesRollbackConfirmationModifier(
                pending: viewModel.pendingHermesRollback, onCancel: viewModel.cancelHermesRollback,
                onConfirm: confirmHermesRollback
            ))
            .alert(
                Text(verbatim: viewModel.pendingHermesFolder.map { String(localized: "Move to \($0.lastPathComponentFallback)?") } ?? ""),
                isPresented: Binding(get: { viewModel.pendingHermesFolder != nil },
                                     set: { if !$0 { viewModel.cancelHermesFolderMove() } }),
                presenting: viewModel.pendingHermesFolder
            ) { folder in
                Button("Cancel", role: .cancel) {}
                Button("Move") {
                    Task {
                        if await viewModel.confirmHermesFolderMove(folder) {
                            ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                        }
                    }
                }
            } message: { folder in
                Text(verbatim: String(localized: "Hermes will work in \(folder) from now on. Files aren't moved."))
            }
            .modifier(StopConfirmationModifier(isPresented: $showsStopConfirmation) {
                Task { await stopStream() }
            })
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
            isViewingCachedData: viewModel.isViewingCachedData,
            hidesSync: !gitAvailabilityViewModel.supportsSync
        )
    }

    @ViewBuilder
    private func gitSheet(_ sheet: ActiveGitSheet) -> some View {
        switch sheet {
        case .changes:
            GitWorkspaceView(
                git: gitAvailabilityViewModel.git,
                progress: reviewProgress,
                onAPIError: onAPIError,
                onAddToPrompt: reviewCommentHook,
                onReturnToChat: closeGitPresentation
            )
        case .commit:
            GitCommitView(
                git: gitAvailabilityViewModel.git,
                writesDisabled: gitWriteAvailability.writesDisabled,
                onAPIError: onAPIError,
                onCommitted: {
                    Task { await gitAvailabilityViewModel.refreshAfterExternalMutation() }
                }
            )
        case .branches:
            GitBranchPickerSheet(
                branches: gitAvailabilityViewModel.branches,
                currentBranch: gitAvailabilityViewModel.currentBranchName,
                isLoading: gitAvailabilityViewModel.isLoadingBranches,
                isSwitching: gitAvailabilityViewModel.isSwitchingBranch,
                allowsCreate: gitAvailabilityViewModel.supportsSync,
                onSelect: closeBranchPicker(checkingOut:),
                onCreate: closeBranchPicker(checkingOut:),
                onRefresh: { Task { await gitAvailabilityViewModel.loadBranches() } }
            )
            .themedPageBackground()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func closeBranchPicker(checkingOut target: GitCheckoutTarget) {
        pendingBranchCheckout = target
        activeGitSheet = nil
    }

    private func runPendingBranchCheckout() {
        guard let target = pendingBranchCheckout else { return }
        pendingBranchCheckout = nil
        Task { await performGitCheckout(target) }
    }

    @ViewBuilder
    private func turnDiffSheet(_ presentation: TurnDiffPresentation) -> some View {
        switch presentation {
        case .turnFiles(let files, let initial, let scope):
            GitDiffView(
                git: gitAvailabilityViewModel.git,
                files: files,
                initialFile: initial,
                scope: scope,
                progress: reviewProgress,
                onAPIError: onAPIError,
                onAddToPrompt: reviewCommentHook,
                onReturnToChat: closeGitPresentation
            )
        }
    }

    private var reviewCommentHook: ((String) -> Void)? {
        guard !session.isSessionReadOnly else { return nil }
        return { markdown in
            draftMessage = ReviewCommentComposer.appending(markdown, to: draftMessage)
            persistDraftEdit(draftMessage)
        }
    }

    private var presentsWorkspaceSheet: Bool {
        activeGitSheet != nil || turnDiffPresentation != nil || openedFileReference != nil
    }

    private func closeGitPresentation() {
        activeGitSheet = nil
        turnDiffPresentation = nil
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
            hidesSync: gitWriteAvailability.hidesSync,
            pullRequest: gitAvailabilityViewModel.pullRequest,
            isRunningAction: gitAvailabilityViewModel.isRunningGitAction,
            branchesDisabled: session.isSessionReadOnly || viewModel.activeStreamID != nil
                || gitAvailabilityViewModel.isWriteLocked
                || gitAvailabilityViewModel.isLoadingBranches || gitAvailabilityViewModel.isSwitchingBranch,
            onBranches: gitAvailabilityViewModel.supportsBranches ? { activeGitSheet = .branches } : nil,
            onTap: {
                HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
                gitAvailabilityViewModel.refreshPullRequest()
            },
            onOpenPullRequest: { SafariView.present($0) },
            onCopyPullRequestLink: { UIPasteboard.general.string = $0.absoluteString },
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

    private var inlineCommitContext: ChatInlineCommitContext? {
        guard ChatGitControlsVisibilityPolicy.showsInlineCommitButton(
            showsGitControls: showsGitControls,
            hasRepository: gitAvailabilityViewModel.hasRepository,
            supportsWrites: gitAvailabilityViewModel.supportsWrites,
            isStreaming: viewModel.activeStreamID != nil,
            latestMessageRole: latestTranscriptMessageRole,
            hasCommittableChanges: gitAvailabilityViewModel.hasCommittableChanges,
            isCommitting: gitAvailabilityViewModel.isCommitting
        ) else { return nil }
        return ChatInlineCommitContext(
            runningPhase: gitAvailabilityViewModel.commitPhase,
            isDisabled: gitWriteAvailability.writesDisabled || gitAvailabilityViewModel.isWriteLocked
        )
    }

    private var turnChangesRecapSummary: TurnFileChangeSummary? {
        guard ChatGitControlsVisibilityPolicy.showsTurnChangesRecap(
            showsGitControls: showsGitControls,
            hasRepository: gitAvailabilityViewModel.hasRepository,
            isStreaming: viewModel.activeStreamID != nil,
            latestMessageRole: latestTranscriptMessageRole
        ), let rows = gitAvailabilityViewModel.turnChangeRows(since: viewModel.hermesTurnBase) else { return nil }
        let git = gitAvailabilityViewModel.git
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: viewModel.latestTurnToolCalls,
            files: rows.files,
            scope: git?.isHermes == true ? rows.scope : nil,
            rowPath: { git?.rowPath(forToolPath: $0) ?? $0 }
        )
        return summary.hasChanges ? summary : nil
    }

    private var turnReviewKey: TurnReviewKey {
        TurnReviewKey(git: gitAvailabilityViewModel, base: viewModel.activeStreamID == nil ? viewModel.hermesTurnBase : nil)
    }

    private func presentTurnDiff(for summary: TurnFileChangeSummary?) {
        guard let presentation = TurnDiffPresentation(summary) else { return }
        turnDiffPresentation = presentation
    }

    @MainActor
    private func performQuickCommit(push: Bool) async {
        let git = gitAvailabilityViewModel
        guard !git.isCommitting, !git.isWriteLocked else { return }

        let toastID = toastState.show(.gitProgress(GitCommitPhase.generatingMessage.progressTitle,
                                                   systemImage: GitCommitPhase.generatingMessage.systemImage,
                                                   branch: git.currentBranchName))

        let outcome = await git.quickCommit(push: push) { phase in
            toastState.update(toastID, to: .gitProgress(phase.progressTitle, systemImage: phase.systemImage,
                                                        branch: git.currentBranchName))
        }

        switch outcome {
        case .success(let result):
            var detailLines: [String] = []
            if let sha = result.shortSHA { detailLines.append(String(localized: "Commit \(sha)")) }
            if result.truncatedMessage { detailLines.append(String(localized: "Diff was large; message may be partial.")) }
            if let pushError = result.pushFailureMessage {
                detailLines.append(String(localized: "Push failed: \(pushError)"))
            }
            toastState.update(toastID, to: .gitResult(
                result.pushFailureMessage != nil
                    ? String(localized: "Committed — push failed")
                    : (result.didPush ? String(localized: "Commit & push complete") : String(localized: "Commit complete")),
                succeeded: result.pushFailureMessage == nil,
                branch: result.branch,
                detailLines: detailLines
            ))
            ChatHaptics.gitActionFinished(succeeded: result.pushFailureMessage == nil, isEnabled: isHapticsEnabled)
        case .nothingToCommit:
            toastState.dismiss(toastID)
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            gitAlert = .error(String(localized: "There are no changes to commit."))
        case .tooManyChanges:
            toastState.dismiss(toastID)
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            gitAlert = .error(git.actionErrorMessage
                ?? String(localized: "Too many changes to quick-commit. Commit in smaller batches, or use git directly."))
        case .failure:
            toastState.dismiss(toastID)
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            if let message = git.actionErrorMessage {
                gitAlert = .error(message)
            }
        case .retired:
            toastState.dismiss(toastID)
        }
    }

    @MainActor
    private func performGitCheckout(_ target: GitCheckoutTarget, stashingChanges: Bool = false) async {
        let git = gitAvailabilityViewModel
        let outcome = await git.checkout(target, stashingChanges: stashingChanges)
        if outcome == .retired || git.isRetired {
            return
        } else if outcome == .requiresStash {
            gitAlert = .dirtyCheckout(target)
        } else if let message = git.actionErrorMessage {
            gitAlert = .error(message)
        }
    }

    @MainActor
    private func performGitRemoteAction(_ action: GitRemoteAction) async {
        let git = gitAvailabilityViewModel
        let toastID = toastState.show(.gitProgress(action.progressTitle, systemImage: action.systemImage,
                                                   branch: git.currentBranchName))

        let succeeded = await git.performRemoteAction(action)
        guard !git.isRetired else {
            toastState.dismiss(toastID)
            return
        }
        if succeeded {
            toastState.update(toastID, to: .gitResult(
                action.successTitle,
                succeeded: true,
                branch: git.currentBranchName,
                detailLines: [git.lastActionMessage]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            ))
            ChatHaptics.gitActionFinished(succeeded: true, isEnabled: isHapticsEnabled)
        } else {
            toastState.dismiss(toastID)
            ChatHaptics.gitActionFinished(succeeded: false, isEnabled: isHapticsEnabled)
            if let message = git.actionErrorMessage {
                gitAlert = .error(message)
            }
        }
    }

    private var pushConfirmationMessage: String {
        guard gitAvailabilityViewModel.git?.isHermes == true else {
            return String(localized: "Push the current branch to its configured upstream remote?")
        }
        let branch = gitAvailabilityViewModel.currentBranchName
        return String(localized: "Push \(branch) to its upstream remote, or to origin as a new upstream branch if it has none?")
    }

    private func gitAlertPresentation(_ alert: GitChatAlert) -> Alert {
        switch alert {
        case .confirmRemote(let action):
            return Alert(
                title: Text(action == .pull ? "Pull Remote Changes?" : "Push Local Commits?"),
                message: Text(action == .pull
                    ? String(localized: "Pull uses fast-forward only and will not create a merge commit.")
                    : pushConfirmationMessage),
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

    private func clarificationInset(maximumExpandedHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if let requests = viewModel.hermesRequests {
                btwInset(maximumExpandedHeight: maximumExpandedHeight)
                if case .approval(let approval)? = hermesInsetRequest {
                    hermesApprovalInset(approval, requests: requests, maximumExpandedHeight: maximumExpandedHeight)
                } else if let request = hermesInsetRequest {
                    hermesRequestInset(request, requests: requests, maximumExpandedHeight: maximumExpandedHeight)
                }
            } else if let clarificationPrompt = viewModel.clarificationPrompt {
                ClarificationRequestInset(
                    prompt: clarificationPrompt,
                    maximumExpandedHeight: maximumExpandedHeight,
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
            } else if let approvalPrompt = viewModel.approvalPrompt {
                webuiApprovalInset(approvalPrompt, maximumExpandedHeight: maximumExpandedHeight)
            }
        }
        .zIndex(9)
        .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: requestInsetID)
        .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: viewModel.hermesSideTasks?.btw?.id)
    }

    @ViewBuilder
    private func btwInset(maximumExpandedHeight: CGFloat) -> some View {
        if let sideTasks = viewModel.hermesSideTasks, let btw = sideTasks.btw {
            Group {
                if hermesInsetRequest == nil {
                    HermesBtwCard(
                        btw: btw,
                        maximumExpandedHeight: maximumExpandedHeight,
                        onExpand: { showsBtwFullScreen = true },
                        onClose: sideTasks.closeBtw
                    )
                } else {
                    HermesBtwBar(btw: btw, onExpand: { showsBtwFullScreen = true }, onClose: sideTasks.closeBtw)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                btwInsetHeight = height
            }
            .id(btw.id)
            .padding(.horizontal, 16)
            .padding(.bottom, composerHeight + 8 + (hermesInsetRequest == nil ? 0 : clarificationBarHeight + 8))
            .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var btwFullScreen: some View {
        if let sideTasks = viewModel.hermesSideTasks, let btw = sideTasks.btw {
            HermesBtwFullScreen(
                btw: btw,
                sessionTitle: displayTitle,
                runStatus: btwRunStatus,
                onCollapse: { showsBtwFullScreen = false },
                onClose: {
                    showsBtwFullScreen = false
                    sideTasks.closeBtw()
                }
            )
        }
    }

    private var btwRunStatus: ChatActiveRunStatusKind? {
        ChatActiveRunStatusPolicy.presentation(
            isStartingChat: viewModel.isStartingChat,
            hasActiveStream: viewModel.activeStreamID != nil,
            activeStreamRecoveryState: viewModel.activeStreamRecoveryState,
            isCancellingStream: viewModel.isCancellingStream,
            isScrolledNearBottom: false,
            activeRunStartedAt: nil,
            isWaitingForUser: viewModel.isWaitingForUser
        )?.kind
    }

    private func hermesRequestInset(
        _ request: BotPendingRequest,
        requests: HermesChatRequests,
        maximumExpandedHeight: CGFloat
    ) -> some View {
        HermesRequestInset(
            request: request,
            identity: viewModel.hermesRequestIdentity ?? "",
            maximumExpandedHeight: maximumExpandedHeight,
            isEnabled: requests.mayAnswer,
            isAnswering: requests.answeringRequestID != nil,
            isStopping: viewModel.isCancellingStream,
            resolution: requests.onScreenResolution,
            isHapticsEnabled: isHapticsEnabled,
            onAnswer: { answers in
                guard let action = requests.prepareAnswer() else { return }
                Task {
                    if await requests.answerQuestion(action, answers) {
                        ChatHaptics.clarificationSubmitted(isEnabled: isHapticsEnabled)
                    }
                }
            },
            onSkip: {
                guard let action = requests.prepareAnswer() else { return }
                Task { await requests.skipQuestion(action) }
            },
            onCredential: { value in
                guard let action = requests.prepareAnswer() else { return }
                Task { await requests.answerCredential(action, value: value) }
            },
            onConnection: { answer in
                guard let action = requests.prepareAnswer() else { return }
                Task { await requests.respondToConnection(action, answer) }
            },
            onStop: {
                Task { await cancelStream() }
            },
            onDismissKeyboard: dismissKeyboard,
            onFootprintChange: { height in
                clarificationBarHeight = height
            }
        )
        .id(request.requestID)
        .padding(.horizontal, 16)
        .padding(.bottom, composerHeight + 8)
        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
    }

    private var hermesInsetRequest: BotPendingRequest? {
        viewModel.hermesRequests?.onScreen
    }

    private var requestInsetID: String? {
        hermesInsetRequest?.requestID ?? viewModel.clarificationPrompt?.id ?? viewModel.approvalPrompt?.id
    }

    @ViewBuilder
    private var composerAccessoryStack: some View {
        if composerAccessoryVisibleItemCount > 0 {
            VStack(spacing: composerAccessoryVerticalSpacing) {
                if let hostNotices = viewModel.hermesHostNotices, let notice = hostNotices.shown {
                    HostNoticeRow(notice: notice, waitingCount: hostNotices.waitingCount) {
                        hostNotices.dismiss(notice)
                    }
                    .id(notice.id)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        hostNoticeHeight = height
                    }
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if !composerLocalNotices.isEmpty {
                    PinnedLocalNoticeStack(notices: composerLocalNotices)
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            pinnedNoticeStackHeight = height
                        }
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if let activeRunStatusPresentation {
                    ChatActiveRunStatusView(presentation: activeRunStatusPresentation)
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            activeRunStatusHeight = height
                        }
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if let pinnedPlan {
                    HermesPlanStrip(plan: pinnedPlan) { height in
                        planStripHeight = height
                    }
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if viewModel.hermesNeedsSignIn {
                    BotComposerPillView(pill: .updateSignIn, onUpdateSignIn: { updateHermesSignIn() })
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            updateSignInPillHeight = height
                        }
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if showsShortcutNotice {
                    shortcutNotice
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            shortcutNoticeHeight = height
                        }
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal)
            .frame(maxWidth: composerMaximumWidth)
            .padding(.bottom, composerHeight + 8 + clarificationFootprintHeight)
            .zIndex(8)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: composerAccessoryVisibleItemCount)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: activeRunStatusPresentation?.kind)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: composerLocalNotices)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsHostNotice)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: pinnedPlan == nil)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsShortcutNotice)
        }
    }

    private var showsShortcutNotice: Bool { showsShortcutProvenance || waitingShortcut != nil }

    private var showsHostNotice: Bool { viewModel.hermesHostNotices?.shown != nil }

    private var shownTextOrigin: ImportedTextOrigin? {
        if let removed = textBeforeHiddenRemoval { return removed.origin }
        guard let textOrigin, !draftMessage.isEmpty else { return nil }
        return textOrigin
    }

    private var showsShortcutProvenance: Bool { shownTextOrigin != nil }

    private var shortcutNotice: some View {
        ShortcutTextNotice(
            origin: shownTextOrigin,
            hasHiddenCharacters: HiddenPromptCharacters.contains(in: draftMessage),
            canUndoRemoval: textBeforeHiddenRemoval != nil,
            removeHiddenCharacters: {
                guard let origin = shownTextOrigin else { return }
                let before = draftMessage
                persistDraftEdit(HiddenPromptCharacters.removing(from: before))
                draftMessage = HiddenPromptCharacters.removing(from: before)
                textBeforeHiddenRemoval = (before, origin)
            },
            undoRemoval: {
                guard let before = textBeforeHiddenRemoval else { return }
                persistDraftEdit(before.text)
                draftMessage = before.text
                textOrigin = before.origin
                draftStore.setTextOrigin(before.origin, for: draftKey)
            },
            waiting: waitingShortcut,
            dismiss: dismissShortcutNotice
        )
    }

    private func dismissShortcutNotice() {
        textOrigin = nil
        textBeforeHiddenRemoval = nil
        draftStore.setTextOrigin(nil, for: draftKey)
    }

    @ViewBuilder private var botProfileEditor: some View {
        if let botChat = viewModel.hermesBotChat, let profile = botChat.botProfile {
            let connection = botChat.engine.connection
            BotProfileEditorView(server: botChat.engine.server, connection: connection, profile: profile,
                                 avatar: botChat.settings.avatars[profile.id])
                .id(connection.id.uuidString + profile.id)
        }
    }

    private var delegatedWork: HermesDelegatedWork? {
        viewModel.isViewingCachedData ? nil : viewModel.hermesActivity?.delegatedWork
    }

    private var showsBotChatSettingsButton: Bool { viewModel.hermesBotChat != nil }

    private var showsFilesLink: Bool {
        showsFilesButton && (!isHermesSession || browsableHermesWorkspace != nil
                             || hermesRowWorkspace != nil && viewModel.hermesWorkspace == nil)
    }

    private var showsGitMenu: Bool { showsGitControls && gitAvailabilityViewModel.hasRepository }

    private var showsTrailingActions: Bool {
        showsBotChatSettingsButton || viewModel.showsGoalControls || showsFilesLink || showsGitMenu
            || screenShortcut != nil
    }

    private var botChatSettingsButton: some View {
        Button { showsChatSettings = true } label: {
            Label("Chat settings", systemImage: "slider.horizontal.3")
        }
        .accessibilityLabel("Chat settings")
    }

    private var filesLink: some View {
        NavigationLink {
            FileBrowserView(
                files: workspaceFiles,
                search: viewModel.workspaceFileSearch,
                onAPIError: onAPIError,
                onAddToPrompt: reviewCommentHook
            )
        } label: {
            Label("Files", systemImage: "folder")
        }
        .disabled(viewModel.isViewingCachedData || isHermesSession && browsableHermesWorkspace == nil)
        .accessibilityLabel("Files")
    }

    @available(iOS 27.1, *)
    @ToolbarContentBuilder
    private var chatActionRailItems: some ToolbarContent {
        if showsBotChatSettingsButton {
            ToolbarItem(placement: .topBarTrailing) { botChatSettingsButton }
        }
        if viewModel.showsGoalControls {
            ToolbarItem(placement: .topBarTrailing) { goalControlMenu }
                .axisBehavior(.verticalPreferred)
        }
        if showsFilesLink {
            ToolbarItem(placement: .topBarTrailing) { filesLink }
        }
        if showsGitMenu {
            ToolbarItem(placement: .topBarTrailing) { gitActionsMenu }
                .axisBehavior(.verticalPreferred)
        }
        if let screenShortcut {
            ToolbarItem(placement: .topBarTrailing) { screenButton(screenShortcut) }
        }
        if let work = delegatedWork, work.activeCount > 0 {
            ToolbarItem(placement: .topBarTrailing) {
                HermesDelegatedWorkButton(count: work.activeCount, action: openDelegatedWork)
            }
            .axisBehavior(.verticalPreferred)
        }
    }

    @ToolbarContentBuilder
    private var delegatedWorkToolbarItem: some ToolbarContent {
        if let work = delegatedWork, work.activeCount > 0 {
            if #available(iOS 26, *), showsTrailingActions { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) {
                HermesDelegatedWorkButton(count: work.activeCount, action: openDelegatedWork)
            }
        }
    }

    private func openDelegatedWork() {
        guard let work = delegatedWork else { return }
        showsDelegatedWork = true
        Task { await work.refresh() }
    }

    private var pinnedPlan: HermesPlan? {
        viewModel.isViewingCachedData ? nil : viewModel.hermesActivity?.pinnedPlan
    }

    private var settledPlanAfterRenderID: String? {
        viewModel.hermesActivity?.settledPlan?.afterRenderID(in: displayedTranscriptMessages)
    }

    private var hermesTurnOutcome: HermesTurnOutcomeRow? {
        guard let activity = viewModel.hermesActivity, activity.failure != nil || activity.notice?.warning != nil else { return nil }
        return HermesTurnOutcomeRow(
            failure: activity.failure, notice: activity.notice,
            offersRetry: activity.retryTarget != nil, mayRetry: viewModel.mayRetryHermesTurn,
            onRetry: {
                Task {
                    await viewModel.retryHermesFailedTurn()
                    if let unsent = viewModel.takeUnsentHermesEdit() { restoreUnsentEdit(unsent) }
                }
            }
        )
    }

    private var screenShortcut: BotScreenOpener? {
        viewModel.errorUnserved == nil ? openBotScreen : nil
    }

    private func screenButton(_ open: BotScreenOpener) -> some View {
        Button { open(takingOver: false) } label: {
            Label("Screen", systemImage: "display")
        }
        .accessibilityLabel("Screen")
    }

    private var botScreenCard: BotScreenCard? {
        guard let openBotScreen, !viewModel.isViewingCachedData, let use = viewModel.hermesScreenUse else { return nil }
        return BotScreenCard(use: use, open: { openBotScreen(takingOver: false) }, takeOver: { openBotScreen(takingOver: true) })
    }

    @ViewBuilder
    private func serveEveryProfileSheet(_ profile: String) -> some View {
        if let connection = try? BotConnectionStore().load(server: server) {
            NavigationStack {
                ServeEveryProfileView(connection: connection, server: server, profile: profile) {
                    servingProfile = nil
                    Task { await loadMessages() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { servingProfile = nil } }
                }
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        let structure = transcriptStructure
        ChatTranscriptView(
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            errorMayRetry: viewModel.errorMayRetry,
            errorHostReason: viewModel.errorUnserved?.hostReason,
            onServeEveryProfile: viewModel.errorUnserved == nil ? nil : { servingProfile = viewModel.errorUnserved?.profile },
            messages: viewModel.messages,
            displayedTranscriptMessages: displayedTranscriptMessages,
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
            clarificationPromptID: requestInsetID,
            hidesRunStatusAccessibility: activeRunStatusPresentation != nil,
            showsThinkingAndToolCards: thinkingAndToolCards.showsCards,
            workingRowStartedAt: workingRowStartedAt,
            isCompacting: viewModel.isCompacting,
            requestWithdrawal: viewModel.hermesRequests?.withdrawal,
            showsScrollToBottomButton: showsScrollToBottomButton,
            shouldFollowLatestMessage: shouldFollowLatestMessage,
            isDisclosureSettling: isDisclosureSettling,
            latestTranscriptMessageRole: latestTranscriptMessageRole,
            isScrolledNearBottom: isScrolledNearBottom,
            activeStreamID: viewModel.activeStreamID,
            streamingScrollTrigger: { viewModel.streamingScrollTrigger },
            transcriptRelayoutScrollToken: viewModel.transcriptRelayoutScrollToken,
            completedResponseRenderID: completedResponseRenderID,
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
            attachmentAudio: AttachmentAudioSource(
                load: { path in await viewModel.attachmentRawData(path: path) },
                isHost: isHermesSession,
                loadKey: viewModel.attachmentLoadKey
            ),
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
            turnFolds: structure.folds,
            terminalReplyRenderIDs: structure.terminalReplyRenderIDs,
            expandedTurnKeys: viewModel.expandedTurnKeys,
            onToggleTurnFold: toggleTurnFold,
            onDismissKeyboard: dismissKeyboard,
            onScrollToBottom: scrollToBottom,
            onScrollToLatestTranscriptMessage: { proxy in
                scrollToLatestTranscriptMessage(proxy)
            },
            onScrollToLatestContent: { proxy, animated in
                scrollToLatestContent(proxy, animated: animated)
            },
            onPreviewAttachment: presentSentAttachmentPreview,
            onPreviewTranscriptMedia: presentTranscriptMediaPreview,
            onAskHermex: addSelectedPassageToDraft,
            onToggleListening: { context in
                viewModel.toggleListening(to: context)
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
                turnDiffPresentation = TurnDiffPresentation(turnChangesRecapSummary, initial: file)
            },
            forkOrigin: shownForkOrigin,
            onOpenForkParent: openForkParent,
            settledPlan: viewModel.hermesActivity?.settledPlan?.plan,
            settledPlanAfterRenderID: settledPlanAfterRenderID,
            turnOutcome: hermesTurnOutcome,
            screenCard: botScreenCard,
            queuedPrompts: viewModel.queuedPromptMessages,
            lostTurn: viewModel.lostTurn,
            onDiscardLostTurn: { Task { await viewModel.discardLostTurn() } },
            isCronRun: isCronRun,
            onCopyQueuedPrompt: { text in
                UIPasteboard.general.string = text
                ChatHaptics.copied(isEnabled: isHapticsEnabled)
            },
            waitingSend: viewModel.waitingSendMessage,
            onCancelWaitingSend: viewModel.cancelWaitingSend,
            continuity: continuity,
            delegatedWork: delegatedWork,
            onOpenDelegatedWork: openDelegatedWork
        )
        .onChange(of: viewModel.latestRunOutcome) {
            handleLatestRunOutcomeChange(viewModel.latestRunOutcome)
        }
        .task(id: session.sessionId) {
            await resolveForkOrigin()
        }
        .task(id: turnReviewKey) { [turnReviewKey] in
            await turnReviewKey.git.loadTurnReview(since: turnReviewKey.base)
        }
        .onChange(of: viewModel.messages.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty { endSessionOpenSignpost() }
        }
        .environment(\.composerChipCatalog, viewModel.composerChipCatalog)
        .transcriptLinks(perform: handleTranscriptLink)
        .environment(\.chatWorkspaceRoot, viewModel.transcriptWorkspaceRoot(listedFolder: hermesRowWorkspace) ?? session.workspace)
        .environment(\.resolvesBareMediaPaths, isHermesSession)
        .environment(\.previewsHermesDocuments, isHermesSession)
        .transcriptHTMLReports(loadKey: viewModel.attachmentLoadKey, load: isHermesSession ? { [viewModel] reference in
            try await viewModel.transcriptHTMLReportData(for: reference)
        } : nil)
        .task(id: transcriptSkillReferenceCount) {
            await loadSkillSuggestionsForTranscriptChipsIfNeeded()
        }
        .task(id: transcriptFileChipScanToken) {
            await viewModel.loadFileChipReferences(draft: draftMessage)
        }
    }

    private var transcriptFileChipScanToken: [Int] {
        [viewModel.messages.count, viewModel.transcriptRevision, viewModel.fileChipScopeRevision,
         viewModel.showsOfflineCache ? 1 : 0]
    }

    private var transcriptSkillReferenceCount: Int {
        guard !hasRequestedSkillsForTranscriptChips, !viewModel.hasLoadedSkillSlashSuggestions,
              !viewModel.showsOfflineCache else {
            return 0
        }

        return viewModel.messages.reduce(into: 0) { count, message in
            guard message.role == "user",
                  ComposerChipTokenizer.mayContainReference(message.content ?? "")
            else { return }
            count += 1
        }
    }

    private func loadSkillSuggestionsForTranscriptChipsIfNeeded() async {
        guard transcriptSkillReferenceCount > 0 else { return }

        await viewModel.loadSkillSlashSuggestions()

        hasRequestedSkillsForTranscriptChips = true
    }

    private var chatLayoutDirection: LayoutDirection {
        ChatTranscriptDisplaySettings.chatLayoutDirection(rtlEnabled: rtlChatLayoutEnabled)
    }

    private var shouldFollowLatestMessage: Bool {
        viewModel.followLatch.isFollowing
    }

    private var isFollowingLatestContent: Bool {
        shouldFollowLatestMessage && !isDisclosureSettling
    }

    private var showsScrollToBottomButton: Bool {
        ChatScrollPolicy.showsScrollToBottomButton(
            isNearBottom: isScrolledNearBottom,
            isStreaming: viewModel.activeStreamID != nil, isFollowing: shouldFollowLatestMessage
        )
    }

    private var workingRowStartedAt: Date? {
        ChatWorkingRowPolicy.startedAt(
            activeRunStartedAt: viewModel.activeRunStartedAt,
            isCancellingStream: viewModel.isCancellingStream,
            hasPendingClarificationPrompt: viewModel.clarificationPrompt != nil || viewModel.approvalPrompt != nil
                || viewModel.isWaitingForUser
        )
    }

    private var transcriptBottomInsetHeight: CGFloat {
        max(96, composerHeight + 44 + composerAccessorySpacerHeight + clarificationFootprintHeight)
    }

    private var scrollToBottomButtonBottomPadding: CGFloat {
        composerHeight + 12 + composerAccessorySpacerHeight + clarificationFootprintHeight
    }

    private var clarificationFootprintHeight: CGFloat {
        let request = requestInsetID == nil ? 0 : clarificationBarHeight + 8
        return request + (viewModel.hermesSideTasks?.btw == nil ? 0 : btwInsetHeight + 8)
    }

    private var pinnedNoticeSpacerHeight: CGFloat {
        composerLocalNotices.isEmpty ? 0 : pinnedNoticeStackHeight
    }

    private var composerLocalNotices: [String] {
        var notices = viewModel.pinnedLocalNotices
        if let queuedMessagesReceipt = viewModel.queuedMessagesReceipt {
            notices.append(queuedMessagesReceipt)
        }
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
            isScrolledNearBottom: isScrolledNearBottom,
            activeRunStartedAt: workingRowStartedAt,
            isWaitingForUser: viewModel.isWaitingForUser,
            isCompacting: viewModel.isCompacting
        )
    }

    private var composerAccessorySpacerHeight: CGFloat {
        var height = pinnedNoticeSpacerHeight
        if showsHostNotice {
            height += hostNoticeHeight
        }
        if activeRunStatusPresentation != nil {
            height += activeRunStatusHeight + composerAccessoryVerticalSpacing
        }
        if pinnedPlan != nil {
            height += planStripHeight
        }
        if viewModel.hermesNeedsSignIn {
            height += updateSignInPillHeight
        }
        if showsShortcutNotice {
            height += shortcutNoticeHeight
        }

        let visibleItemCount = composerAccessoryVisibleItemCount
        if visibleItemCount > 1 {
            height += CGFloat(visibleItemCount - 1) * composerAccessoryVerticalSpacing
        }
        return height
    }

    private var composerAccessoryVisibleItemCount: Int {
        var count = 0
        if showsHostNotice {
            count += 1
        }
        if !composerLocalNotices.isEmpty {
            count += 1
        }
        if activeRunStatusPresentation != nil {
            count += 1
        }
        if pinnedPlan != nil {
            count += 1
        }
        if viewModel.hermesNeedsSignIn {
            count += 1
        }
        if showsShortcutNotice {
            count += 1
        }
        return count
    }

    private var displayTitle: String {
        viewModel.displayTitle
    }

    private var headerSubtitle: String? {
        ChatToolbarSubtitleResolver.subtitle(
            workspacePath: viewModel.selectedWorkspacePath ?? hermesRowWorkspace,
            profileTitle: viewModel.selectedProfileTitle
        )
    }

    private var showsNewChatControls: Bool {
        ChatComposerNewChatPolicy.showsControls(
            hasMessages: !viewModel.messages.isEmpty,
            serverMessageCount: session.messageCount,
            isStreaming: viewModel.activeStreamID != nil
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

    private var transcriptStructure: TranscriptStructureMemo.Structure {
        let activityAnchorIDs: Set<String> = thinkingAndToolCards.showsCards
            ? Set(viewModel.displayedReasoningGroups.compactMap(\.anchorMessageID))
                .union(viewModel.completedToolCallGroups.compactMap(\.anchorMessageID))
                .union(viewModel.hermesCachedWorkAnchorIDs)
            : []
        let inputs = TranscriptStructureMemo.Inputs(
            structureRevision: viewModel.transcriptStructureRevision,
            activityAnchorIDs: activityAnchorIDs,
            foldsSettledTurns: foldsSettledTurns,
            isStreamActive: viewModel.activeStreamID != nil,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID,
            latestRunOutcome: viewModel.latestRunOutcome
        )
        return transcriptStructureMemo.structure(for: inputs) {
            TranscriptStructureMemo.Structure(
                folds: foldsSettledTurns ? TranscriptTurnFolds.derive(
                    transcriptMessages: transcriptMessages,
                    messages: viewModel.messages,
                    messageOffset: viewModel.messagesOffset,
                    activityAnchorIDs: activityAnchorIDs,
                    rendersBubble: shouldRenderMessageRow,
                    isStreamActive: inputs.isStreamActive,
                    streamingAssistantMessageID: inputs.streamingAssistantMessageID,
                    latestRunOutcome: inputs.latestRunOutcome
                ) : .none,
                terminalReplyRenderIDs: TranscriptMessageMetaPolicy.terminalReplyRenderIDs(
                    transcriptMessages: transcriptMessages,
                    messages: viewModel.messages,
                    messageOffset: viewModel.messagesOffset,
                    rendersBubble: shouldRenderMessageRow,
                    isStreamActive: inputs.isStreamActive,
                    streamingAssistantMessageID: inputs.streamingAssistantMessageID
                )
            )
        }
    }

    private func toggleTurnFold(_ turnKey: String) {
        handleDisclosureToggle()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            if !viewModel.expandedTurnKeys.insert(turnKey).inserted {
                viewModel.expandedTurnKeys.remove(turnKey)
            }
        }
    }

    private func handleLatestRunOutcomeChange(_ outcome: TranscriptTurnRunOutcome?) {
        guard let outcome, outcome.ending != .completed else { return }
        viewModel.expandedTurnKeys.insert(outcome.turnKey)
    }

    private var latestTranscriptMessageID: String? {
        transcriptMessages.last?.id
    }

    private var latestTranscriptMessageRole: String? {
        transcriptMessages.last?.message.role
    }

    private var needsInitialMessages: Bool {
        loadsInitialMessages && !continuity.didLoadMessages
    }

    private func prepareInitialAppearance() {
        viewModel.setShowsLiveActivityResponseExcerpts(showsLiveActivityResponseExcerpts)
        if needsInitialMessages {
            viewModel.prepareInitialMessageLoad(modelContext: modelContext)
        }
    }

    private func handleInitialAppearanceTask() async {
        await hydrateDraftIfNeeded()
        prepareInitialAppearance()

        guard didCompleteInitialAppearance else { return }

        async let chatStartup: Void = performInitialAsyncWork()
        async let gitAvailability: Void = loadInitialGitAvailability()
        async let draftAttachments: Void = restoreDraftAttachmentsIfNeeded()
        _ = await (chatStartup, gitAvailability, draftAttachments)
    }

    private func performInitialAsyncWork() async {
        guard !Task.isCancelled else { return }
        let draftSettingsInteractionGeneration = viewModel.composerConfigurationInteractionGeneration

        if needsInitialMessages {
            await loadMessages(appliesInitialFocus: false, usesInitialPrefetch: true)
            guard !Task.isCancelled else { return }
            continuity.didLoadMessages = viewModel.errorMessage == nil
            if viewModel.messages.isEmpty { endSessionOpenSignpost() }
        }
        if initialAttachments.isEmpty {
            isInitialComposerFocusContentReady = true
            applyInitialComposerFocusPolicyIfNeeded()
        }
        async let approvalBypassRefresh: Void = viewModel.refreshApprovalBypassState()
        await viewModel.loadComposerConfiguration()
        if !Task.isCancelled {
            await applyRestoredDraftSettingsIfNeeded(
                expectedInteractionGeneration: draftSettingsInteractionGeneration
            )
        }
        await approvalBypassRefresh
        guard !Task.isCancelled else { return }

        await uploadInitialAttachmentsIfNeeded()
        guard !Task.isCancelled else { return }

        isInitialComposerFocusContentReady = true
        applyInitialComposerFocusPolicyIfNeeded()
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func endSessionOpenSignpost() {
        let sessionID = hermesSessionChatID ?? session.sessionId
        let messages = viewModel.messages.count
        DispatchQueue.main.async {
            SessionOpenSignpost.end(sessionID: sessionID, messages: messages)
        }
    }

    private func loadInitialGitAvailability() async {
        let availabilityViewModel = if isHermesSession {
            GitWorkspaceAvailabilityViewModel(git: browsableHermesWorkspace == nil ? nil : viewModel.hermesWorkspaceGit)
        } else {
            GitWorkspaceAvailabilityViewModel(session: session, server: server)
        }
        gitAvailabilityViewModel = availabilityViewModel
        await availabilityViewModel.loadIfNeeded()
    }

    private var goalControlMenu: some View {
        GoalControlsMenu(
            currentGoal: viewModel.currentGoal,
            isViewingCachedData: viewModel.isViewingCachedData,
            isSetGoalDisabled: isGoalActionDisabled,
            isActionDisabled: isHermesSession
                ? viewModel.isViewingCachedData || viewModel.isSubmittingGoal
                : isGoalActionDisabled,
            onSetGoal: {
                showsGoalSheet = true
            },
            onSubmitCommand: { command in
                Task { await submitGoalCommand(command) }
            },
            automations: viewModel.hermesSideTasks?.automations ?? [],
            allowsAutomationChanges: viewModel.hermesSideTasks?.controlsAutomations == true,
            isAutomationDisabled: viewModel.isViewingCachedData || viewModel.hermesSideTasks?.isChangingAutomation == true
                || viewModel.hermesSideTasks?.canChangeAutomations == false,
            onChangeAutomation: { viewModel.hermesSideTasks?.ask($0) }
        )
        .modifier(HermesAutomationConfirmationModifier(
            sideTasks: viewModel.hermesSideTasks, onConfirm: { control in
                Task { await viewModel.confirmHermesAutomation(control) }
            }
        ))
    }

    private var isGoalActionDisabled: Bool {
        viewModel.isViewingCachedData || viewModel.activeStreamID != nil || viewModel.isSubmittingGoal
    }

    private func loadMessages(appliesInitialFocus: Bool = true, usesInitialPrefetch: Bool = false) async {
        await viewModel.loadMessages(modelContext: modelContext, usesInitialPrefetch: usesInitialPrefetch)
        await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
        if appliesInitialFocus {
            applyInitialComposerFocusPolicyIfNeeded()
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func loadOlderMessages() async -> Bool {
        viewModel.followLatch.isFollowing = false

        let signpost = performanceSignposter.beginInterval("Load Earlier")
        let didLoad = await viewModel.loadOlderMessages(modelContext: modelContext)
        let messages = viewModel.messages.count
        DispatchQueue.main.async {
            performanceSignposter.endInterval("Load Earlier", signpost, "messages=\(messages, privacy: .public)")
        }
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

    private func confirmClearConversation(_ pending: PendingClearConfirmation) {
        Task { await clearConversation(pending) }
    }

    private func confirmHermesPersonality(_ name: String) {
        Task {
            let result = await viewModel.confirmHermesPersonality(name)
            handleSlashExecutionResult(result, parsedCommand: SlashCommandCatalog.command(named: "personality"),
                                       submittedDraft: "", submittedDraftRevision: draftRevision, consumesDraft: false)
        }
    }

    private func confirmHermesRollback(_ request: HermesRollbackRequest) {
        Task {
            let result = await viewModel.confirmHermesRollback(request)
            handleSlashExecutionResult(result, parsedCommand: SlashCommandCatalog.hermesCommand(named: "rollback"),
                                       submittedDraft: "", submittedDraftRevision: draftRevision, consumesDraft: false)
        }
    }

    private func clearConversation(_ pending: PendingClearConfirmation) async {
        let result = await viewModel.clearConversationFromSlashCommand(modelContext: modelContext)
        handleSlashExecutionResult(
            result,
            parsedCommand: SlashCommandCatalog.command(named: "clear"),
            submittedDraft: pending.draft,
            submittedDraftRevision: pending.draftRevision
        )

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendDraftMessage(behavior: StreamingSendBehavior?) async {
        viewModel.clearSteerFailure()
        let submittedContent = ComposerDraftContent(text: draftMessage, quotes: draftQuotes)
        let submittedDraft = submittedContent.text
        let outboundMessage = ComposerQuoteMessageFormatter.message(
            text: submittedDraft,
            quotes: submittedContent.quotes
        )
        let submittedDraftRevision = draftRevision
        let shouldRestoreFocusAfterSend = composerIsFocused
        let submittedFocusRevision = composerFocusRevision
        let applySubmissionFocus = {
            if isOnScreen, let focus = ChatSendFocusPolicy.focusAfterSubmission(
                succeeded: true, dismissKeyboard: dismissKeyboardAfterSend,
                wasFocused: shouldRestoreFocusAfterSend,
                submittedRevision: submittedFocusRevision, currentRevision: composerFocusRevision,
                hasNewDraft: draftRevision != submittedDraftRevision
            ), !focus || canFocusComposer {
                composerIsFocused = focus
            }
        }

        if isHermesSession, submittedContent.quotes.isEmpty,
           let result = await viewModel.runHermesSlashCommand(submittedDraft, modelContext: modelContext) {
            let name = BotSlashCatalog.invocation(in: submittedDraft)?.name ?? ""
            handleSlashExecutionResult(
                result,
                parsedCommand: SlashCommandCatalog.hermesCommand(named: name),
                submittedDraft: submittedDraft,
                submittedDraftRevision: submittedDraftRevision
            )
            if let unsent = viewModel.takeUnsentHermesEdit() {
                if draftRevision == submittedDraftRevision {
                    draftMessage = unsent
                    persistDraftEdit(unsent)
                } else {
                    restoreUnsentEdit(unsent)
                }
            }
            if let lastError = viewModel.lastError {
                onAPIError(lastError)
            }
            return
        }

        let parsedCommand = SlashCommandExecutor.parse(submittedDraft)?.command
        if submittedContent.quotes.isEmpty,
           submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
           !isHermesSession {
            if parsedCommand?.handler == .clientSide(.clear), viewModel.clearConversationRefusal == nil {
                pendingClearConfirmation = PendingClearConfirmation(
                    draft: submittedDraft,
                    draftRevision: submittedDraftRevision
                )
                return
            }
            let result = await SlashCommandExecutor.execute(
                text: submittedDraft,
                viewModel: viewModel,
                modelContext: modelContext
            )
            handleSlashExecutionResult(
                result,
                parsedCommand: parsedCommand,
                submittedDraft: submittedDraft,
                submittedDraftRevision: submittedDraftRevision
            )

            if result != .sendAsMessage {
                if !result.isSuccessfulSubmission {
                    await openCompressionContinuationIfNeeded()
                }
                if result.isSuccessfulSubmission {
                    switch parsedCommand?.handler {
                    case .serverSide(.queue), .serverSide(.steer), .serverSide(.interrupt):
                        applySubmissionFocus()
                    default:
                        break
                    }
                }
                if let lastError = viewModel.lastError {
                    onAPIError(lastError)
                }
                return
            }
        }

        let outcome: ChatSendOutcome
        if viewModel.activeStreamID != nil {
            let behavior = behavior ?? StreamingSendBehavior.storedValue(streamingSendBehaviorRawValue)
            if ChatScrollPolicy.streamingSendReArmsFollow(behavior) {
                prepareTranscriptForExplicitSend()
            }
            let result = await viewModel.submitStreamingMessage(outboundMessage, behavior: behavior)
            handleSlashExecutionResult(
                result,
                parsedCommand: SlashCommandCatalog.command(named: Self.slashCommandName(for: behavior)),
                submittedDraft: submittedDraft,
                submittedQuotes: submittedContent.quotes,
                submittedDraftRevision: submittedDraftRevision,
                consumesDraft: result.isSuccessfulSubmission
            )
            outcome = result.isSuccessfulSubmission ? .started : .kept
        } else {
            outcome = await sendStandardMessage(
                submittedContent,
                outboundMessage: outboundMessage,
                submittedDraftRevision: submittedDraftRevision
            )
        }

        switch outcome {
        case .kept:
            await openCompressionContinuationIfNeeded()
        case .started:
            ChatHaptics.messageSent(isEnabled: isHapticsEnabled)
            applySubmissionFocus()
        case .waiting:
            applySubmissionFocus()
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
            offerNotificationsIfNeeded()
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendStandardMessage(
        _ submittedContent: ComposerDraftContent,
        outboundMessage: String,
        submittedDraftRevision: Int
    ) async -> ChatSendOutcome {
        let hasStagedAttachments = !viewModel.pendingAttachments.isEmpty
        let trimmedMessage = outboundMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty || hasStagedAttachments else {
            return .kept
        }
        let isPlainText = submittedContent.quotes.isEmpty && !hasStagedAttachments && !trimmedMessage.hasPrefix("/")

        prepareTranscriptForExplicitSend()

        let sendReconciliation = ChatDraftSendReconciliation.outcome(
            draftRecords: lastSyncedDraftAttachments,
            stagedAttachmentIDs: Set(viewModel.pendingAttachments.map(\.id))
        )
        draftStore.setContent(submittedContent, for: draftKey)
        draftMessage = ""
        draftQuotes = []

        let outcome = await viewModel.send(outboundMessage, isPlainText: isPlainText, modelContext: modelContext)
        let didStart = outcome != .kept
        if outcome == .started { onConversationStarted() }
        if didStart {
            draftAttachmentsPendingRetry = sendReconciliation.retained
            if textOrigin != nil { dismissShortcutNotice() }
        }
        let resolvedContent = draftStore.resolveSubmission(
            submitted: submittedContent,
            current: ComposerDraftContent(text: draftMessage, quotes: draftQuotes),
            didStart: didStart,
            draftWasEdited: draftRevision != submittedDraftRevision,
            preserveRejectedSubmission: viewModel.isCompressionRotated,
            for: draftKey
        )
        draftMessage = resolvedContent.text
        draftQuotes = resolvedContent.quotes
        if didStart {
            syncDraftAttachments()
            if outcome == .started { offerNotificationsIfNeeded() }
        }

        return outcome
    }

    private func openCompressionContinuationIfNeeded() async {
        guard isOnScreen, !Task.isCancelled else { return }
        draftStore.setContent(ComposerDraftContent(text: draftMessage, quotes: draftQuotes), for: draftKey)
        syncDraftAttachments()
        if let continuation = await viewModel.compressionContinuationForNavigation(
            from: draftKey, isCurrent: { isOnScreen },
            prepareDraftForHandoff: {
                draftStore.setContent(ComposerDraftContent(text: draftMessage, quotes: draftQuotes), for: draftKey)
                syncDraftAttachments()
            }
        ) {
            if textOrigin != nil { dismissShortcutNotice() }
            draftMessage = ""
            draftQuotes = []
            draftAttachmentsPendingRetry = []
            lastSyncedDraftAttachments = []
            viewModel.clearPendingAttachments()
            pushedSession = continuation
        }
    }

    private func offerNotificationsIfNeeded() {
        guard isOnScreen else { return }
        Task {
            guard let offer = await NotificationOffer.claim(server: server, isCurrent: { isOnScreen }) else { return }
            pendingNotificationOffer = offer
        }
    }

    private func handleSlashExecutionResult(
        _ result: SlashCommandExecutionResult,
        parsedCommand: SlashCommand?,
        submittedDraft: String,
        submittedQuotes: [ComposerQuote] = [],
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
                    ComposerDraftContent(text: submittedDraft, quotes: submittedQuotes),
                    submittedDraftRevision: submittedDraftRevision
                )
            }
        case .openedSession(let session):
            pushedSession = session
            if consumesDraft {
                reconcileConsumedDraft(
                    ComposerDraftContent(text: submittedDraft, quotes: submittedQuotes),
                    submittedDraftRevision: submittedDraftRevision
                )
            }
        case .openedHermesSession(let chat):
            pushedHermesSession = chat
            if consumesDraft {
                reconcileConsumedDraft(
                    ComposerDraftContent(text: submittedDraft, quotes: submittedQuotes),
                    submittedDraftRevision: submittedDraftRevision
                )
            }
        case .replacedHermesSession(let chat):
            if consumesDraft {
                reconcileConsumedDraft(
                    ComposerDraftContent(text: submittedDraft, quotes: submittedQuotes),
                    submittedDraftRevision: submittedDraftRevision
                )
            }
            if let onReplaceHermesSession { onReplaceHermesSession(chat) } else { pushedHermesSession = chat }
        case .openedHermesSessionList(let entry):
            if consumesDraft {
                reconcileConsumedDraft(
                    ComposerDraftContent(text: submittedDraft, quotes: submittedQuotes),
                    submittedDraftRevision: submittedDraftRevision
                )
            }
            if let onOpenHermesSessions { onOpenHermesSessions(entry) } else { pushedHermesSessionList = entry }
        case .prefill(let text):
            if draftRevision == submittedDraftRevision {
                draftMessage = text
                persistDraftEdit(text)
            }
        case .unsupported(let friendlyMessage):
            viewModel.setSendErrorMessage(friendlyMessage)
            if consumesDraft {
                reconcileConsumedDraft(
                    ComposerDraftContent(text: submittedDraft, quotes: submittedQuotes),
                    submittedDraftRevision: submittedDraftRevision,
                    preserveRejectedSubmission: viewModel.isCompressionRotated
                )
            }
        case .needsSubArg:
            viewModel.setSendErrorMessage(String(localized: "Choose a slash command or continue typing."))
        case .sendAsMessage, .notDelivered:
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

    private static func slashCommandName(for behavior: StreamingSendBehavior) -> String {
        switch behavior {
        case .steer:
            "steer"
        case .interrupt:
            "interrupt"
        case .queue:
            "queue"
        }
    }

    private var draftKey: ChatDraftKey {
        if let hermesDraftKey = viewModel.hermesDraftKey { return hermesDraftKey }
        let normalizedSessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = normalizedSessionID.flatMap { $0.isEmpty ? nil : $0 } ?? session.id
        return .session(
            server: server,
            sessionID: sessionID
        )
    }

    private func persistDraftEdit(_ text: String) {
        viewModel.clearSteerFailure()
        textBeforeHiddenRemoval = nil
        if text.isEmpty, textOrigin != nil { dismissShortcutNotice() }
        draftRevision &+= 1
        draftStore.setContent(
            ComposerDraftContent(text: text, quotes: draftQuotes),
            for: draftKey
        )
    }

    private var persistedQuotesBinding: Binding<[ComposerQuote]> {
        Binding(
            get: { draftQuotes },
            set: { newValue in
                draftQuotes = newValue
                draftRevision &+= 1
                draftStore.setContent(
                    ComposerDraftContent(text: draftMessage, quotes: newValue),
                    for: draftKey
                )
            }
        )
    }

    private func hydrateDraftIfNeeded() async {
        viewModel.protectDraftAttachments(for: draftKey)
        guard !didHydrateDraft else { return }
        await viewModel.adoptHermesSegmentDraft()
        await draftStore.markUsed(draftKey)
        let textBeforeHydration = draftMessage
        let quotesBeforeHydration = draftQuotes
        var persistedDraft = await draftStore.draft(for: draftKey)
        viewModel.protectDraftAttachments(for: draftKey, restoring: persistedDraft?.attachments ?? [])
        viewModel.restoreSubmissionMark(persistedDraft?.botSubmissionUncertain == true)
        guard !Task.isCancelled,
              draftMessage == textBeforeHydration,
              draftQuotes == quotesBeforeHydration
        else { return }

        let returnedWaitingSend = viewModel.waitingSend == nil ? persistedDraft?.waitingSend?.text : nil
        if returnedWaitingSend != nil { persistedDraft = draftStore.returnWaitingSend(for: draftKey) }
        if textBeforeHydration.isEmpty {
            if let persistedDraft, !persistedDraft.text.isEmpty {
                draftMessage = persistedDraft.text
            }
        } else {
            if let returnedWaitingSend { draftMessage = returnedWaitingSend + "\n\n" + textBeforeHydration }
            draftStore.setDraft(draftMessage, for: draftKey)
        }
        if quotesBeforeHydration.isEmpty {
            draftQuotes = persistedDraft?.quotes ?? []
        } else {
            draftStore.setQuotes(quotesBeforeHydration, for: draftKey)
        }
        didHydrateDraft = true
        textOrigin = persistedDraft?.textOrigin

        restoredDraftSettings = persistedDraft?.settings
        lastSyncedDraftAttachments = persistedDraft?.attachments ?? []
        if let persistedDraft, !persistedDraft.attachments.isEmpty {
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

    private func restoreDraftAttachments(_ records: [ChatDraftAttachment]) async {
        var pendingRetry: [ChatDraftAttachment] = []
        var unrecoverableCount = 0
        var wasCancelled = false

        for (offset, record) in records.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                pendingRetry.append(contentsOf: records[offset...])
                break
            }
            if viewModel.pendingAttachments.contains(where: { $0.id == record.id }) { continue }
            guard let fileName = record.file else {
                unrecoverableCount += 1
                continue
            }

            let data: Data
            do {
                data = try await draftAttachmentStore.data(named: fileName)
            } catch {
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
        syncDraftAttachments()

        guard !wasCancelled else { return }
        if !pendingRetry.isEmpty || unrecoverableCount > 0 {
            viewModel.setUploadAttachmentError(
                draftRestoreFailureMessage(retryCount: pendingRetry.count, droppedCount: unrecoverableCount)
            )
        }
    }

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

    private func syncDraftAttachments() {
        guard didHydrateDraft, !isRestoringDraftAttachments else { return }
        let pendingRecords = viewModel.pendingAttachments
            .map(ChatDraftAttachment.init(pending:))
            .filter { $0.file != nil }
        let retryRecords = draftAttachmentsPendingRetry.filter { retry in
            !pendingRecords.contains(where: { $0.id == retry.id })
        }
        let records = pendingRecords + retryRecords
        draftStore.setAttachments(records, replacing: lastSyncedDraftAttachments, for: draftKey)
        lastSyncedDraftAttachments = records
    }

    private func syncDraftSettings(_ settings: ChatDraftSettings) {
        guard didHydrateDraft, restoresDraftSettings else { return }
        draftStore.setSettings(settings, for: draftKey)
    }

    private var currentComposerSettings: ChatDraftSettings {
        ChatDraftSettings(
            modelID: viewModel.selectedModelID,
            modelProviderID: viewModel.selectedModelProviderID,
            reasoningEffort: viewModel.selectedReasoningEffort,
            profileName: viewModel.selectedProfileName,
            workspacePath: viewModel.selectedWorkspacePath
        )
    }

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
        _ submittedContent: ComposerDraftContent,
        submittedDraftRevision: Int,
        preserveRejectedSubmission: Bool = false
    ) {
        if textOrigin != nil { dismissShortcutNotice() }
        let resolvedContent = draftStore.resolveConsumedInput(
            submitted: submittedContent,
            current: ComposerDraftContent(text: draftMessage, quotes: draftQuotes),
            draftWasEdited: draftRevision != submittedDraftRevision,
            preserveRejectedSubmission: preserveRejectedSubmission,
            for: draftKey
        )
        draftMessage = resolvedContent.text
        draftQuotes = resolvedContent.quotes
    }

    private func addSelectedPassageToDraft(_ passage: String) {
        guard !passage.isEmpty else { return }
        persistedQuotesBinding.wrappedValue = draftQuotes + [ComposerQuote(text: passage)]
        requestComposerFocusIfPossible()
    }

    private func parkQueuedMessages() {
        let queued = viewModel.takeQueuedMessages()
        guard !queued.isEmpty,
              let parked = draftStore.parkQueuedMessages(queued, for: draftKey)
        else { return }
        draftRevision &+= 1
        draftMessage = parked.text
        lastSyncedDraftAttachments = parked.attachments
        viewModel.appendPendingAttachments(queued.flatMap(\.attachments))
    }

    private func flushDraftsBestEffort() {
        Task {
            try? await draftStore.flush()
        }
    }

    private func cancelStream() async {
        if viewModel.stopNeedsConfirmation {
            showsStopConfirmation = true
            return
        }
        await stopStream()
    }

    private func stopStream() async {
        let didCancel = await viewModel.cancelActiveStream()
        if didCancel {
            ChatHaptics.streamCancelled(isEnabled: isHapticsEnabled)
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func forkFromMessage(_ context: MessageActionContext) async {
        if isHermesSession {
            if let branch = await viewModel.forkHermesSession(from: context) { pushedHermesSession = branch }
            return
        }
        let session = await viewModel.forkFromMessage(context, modelContext: modelContext)

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if let session {
            pushedSession = session
        }
    }

    private var shownForkOrigin: ForkOrigin? {
        isHermesSession ? viewModel.hermesForkOrigin : forkOrigin
    }

    private func resolveForkOrigin() async {
        if isHermesSession {
            await viewModel.checkHermesForkParent(hermesParentKey)
            return
        }
        guard let parentID = ForkOrigin.parentSessionID(of: session) else {
            forkOrigin = nil
            return
        }
        let parent = try? CacheStore.cachedSession(id: parentID, serverURL: server, in: modelContext)
        forkOrigin = ForkOrigin.resolve(session: session, parent: parent)
    }

    private func openForkParent() {
        guard let forkOrigin = shownForkOrigin, !isOpeningForkParent else { return }
        if isHermesSession {
            pushedHermesSession = forkOrigin.parent.flatMap(viewModel.hermesChat(opening:))
            return
        }
        if let parent = forkOrigin.parent {
            pushedSession = parent
            return
        }

        isOpeningForkParent = true
        Task {
            let parent = await viewModel.loadForkParent(id: forkOrigin.parentSessionID)
            isOpeningForkParent = false
            if let lastError = viewModel.lastError {
                onAPIError(lastError)
            }
            if let parent {
                pushedSession = parent
            }
        }
    }

    private func handleProfileSelection(_ profile: ProfileSummary) {
        viewModel.markComposerConfigurationInteraction()
        if viewModel.isSelectedProfile(profile) {
            return
        }

        if viewModel.messages.isEmpty {
            if isHermesSession {
                startHermesSession(in: profile, replacing: true)
            } else {
                Task { await switchProfile(profile, startNewSession: false) }
            }
        } else {
            pendingProfileSelection = profile
            showProfileNewSessionConfirmation = true
        }
    }

    private func startHermesSession(in profile: ProfileSummary, replacing: Bool) {
        pendingProfileSelection = nil
        guard let name = profile.normalizedName, let chat = viewModel.newHermesSessionChat(profile: name) else { return }
        HermesProfilePreference.save(name, for: server)
        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
        if replacing, let onReplaceHermesSession {
            Task {
                await viewModel.handOffHermesDraft(to: chat)
                onReplaceHermesSession(chat)
            }
        } else {
            pushedHermesSession = chat
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
            pushedSession = session
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

    private func handlePhotoSelection(_ media: [HermexPickedMedia]) async {
        for item in media {
            guard !Task.isCancelled else { return }
            await viewModel.uploadAttachment(
                data: item.data,
                filename: item.filename,
                previewData: item.data
            )
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
              size > (isHermesSession ? BotAttachmentUpload.maximumFileBytes : PendingAttachment.maximumUploadBytes)
        else {
            return
        }
        if isHermesSession { throw BotAttachmentFailure.limit }

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
            if isHermesSession {
                viewModel.suspendStreamForBackground()
            } else if viewModel.activeStreamID != nil {
                beginResponseCompletionBackgroundTask()
            }
        case .active:
            scrollToHydratedCompletionIfReady()
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

    private func handleNetworkPathChange() {
        Task {
            await viewModel.networkPathDidChange(modelContext: modelContext)

            if let lastError = viewModel.lastError {
                onAPIError(lastError)
            }
        }
    }

    private func handleActiveStreamChange() {
        guard let activeStreamID = viewModel.activeStreamID else {
            activeStreamStatusRefreshTask?.cancel()
            activeStreamStatusRefreshTask = nil

            if responseCompletionNotificationTracker.shouldEndBackgroundTaskOnStreamInactive(
                runEndTrigger: viewModel.runEndTrigger
            ) {
                endResponseCompletionBackgroundTask()
            }

            Task { await gitAvailabilityViewModel.refreshAfterExternalMutation() }
            return
        }


        completionScrollPolicy.begin(streamID: activeStreamID, isFollowing: shouldFollowLatestMessage)
        hydratedCompletionStreamID = nil
        completedResponseRenderID = nil
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

        ChatHaptics.assistantResponseCompleted(isEnabled: isHapticsEnabled)
    }

    private func handleRunEnd() {
        guard let runEndContext = responseCompletionNotificationTracker.completionContext(
            runEndTrigger: viewModel.runEndTrigger,
            sceneIsActive: scenePhase == .active
        ) else {
            return
        }
        let outcome = viewModel.runEndOutcome
        let runEndTrigger = viewModel.runEndTrigger
        let completion = viewModel.successfulResponseCompletion
        let hermesLink = viewModel.hermesSessionLink

        Task { @MainActor in
            if outcome == .completed, completion?.needsTranscriptRefresh == true {
                await loadMessages()
            }

            let isLatestRunEnd = { viewModel.runEndTrigger == runEndTrigger }
            if isLatestRunEnd(), outcome == .completed {
                hydratedCompletionStreamID = completion?.streamID
                scrollToHydratedCompletionIfReady()
            }
            await ResponseCompletionNotificationService.scheduleRunEndedIfAllowed(
                outcome,
                sessionID: hermesLink?.key ?? session.sessionId,
                hermesProfile: hermesLink?.profile,
                title: viewModel.displayTitle,
                server: server,
                preferenceEnabled: isResponseCompletionNotificationsEnabled,
                sceneIsActive: runEndContext.sceneIsActive,
                isCurrent: isLatestRunEnd
            )
            if isLatestRunEnd() {
                endResponseCompletionBackgroundTask()
            }
        }
    }

    private func scrollToHydratedCompletionIfReady() {
        guard isOnScreen, viewModel.activeStreamID == nil,
              viewModel.errorMessage == nil,
              let streamID = hydratedCompletionStreamID,
              viewModel.successfulResponseCompletion?.streamID == streamID,
              let finalRenderID = ChatCompletionScrollPolicy.finalResponseRenderID(
                  in: displayedTranscriptMessages, terminalReplyRenderIDs: transcriptStructure.terminalReplyRenderIDs
              ),
              completionScrollPolicy.consumeCompletion(
                  streamID: streamID,
                  enabled: SessionChatPreferences.CompletionPosition.storedValue(completionPositionRawValue) == .beginning,
                  sceneIsActive: scenePhase == .active
              ) else { return }
        hydratedCompletionStreamID = nil
        viewModel.followLatch.isFollowing = false
        completedResponseRenderID = finalRenderID
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
        guard !viewModel.messages.isEmpty || !viewModel.queuedPromptMessages.isEmpty || viewModel.lostTurn != nil
            || viewModel.waitingSendMessage != nil || (delegatedWork?.activeCount ?? 0) > 0 else { return }

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
            if !isUserInitiated, !isFollowingLatestContent { return }

            let isCacheFirstSnapWindow = cacheFirstSnapUntil.map { Date() < $0 } ?? false
            if animated, !isCacheFirstSnapWindow, viewModel.activeStreamID == nil {
                withAnimation(ChatMotion.scrollToLatest(reduceMotion: reduceMotion)) {
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
        completionScrollPolicy.observe(event)
        switch event {
        case .userScrollBegin, .reset:
            completedResponseRenderID = nil
        case .contentScrolled(_, let isUserScrolling, let movedAway, _):
            if isUserScrolling || movedAway { completedResponseRenderID = nil }
        default:
            break
        }
        let resolved = ChatScrollPolicy.resolveFollow(current: viewModel.followLatch, event: event)
        if resolved != viewModel.followLatch {
            viewModel.followLatch = resolved
        }
    }

    private func handleDisclosureToggle() {
        completionScrollPolicy.readerDidInteract()
        completedResponseRenderID = nil
        ChatHaptics.disclosureToggled(isEnabled: isHapticsEnabled)
        suspendBottomAnchorForDisclosure()
    }

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
        if let unsent = viewModel.takeUnsentHermesEdit() {
            restoreUnsentEdit(unsent)
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
        if let unsent = viewModel.takeUnsentHermesEdit() { restoreUnsentEdit(unsent) }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func restoreUnsentEdit(_ text: String) {
        let draft = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : "\(draftMessage)\n\n\(text)"
        draftMessage = draft
        persistDraftEdit(draft)
    }

    private var editDiscardWarningMessage: String {
        guard let context = editContext else { return "" }
        let messagesAfter = transcriptMessagesAfter(context)
        return withHermesCutNote(String(localized: "Editing this message will discard \(messagesAfter) later messages."))
    }

    private var regenerateDiscardWarningMessage: String {
        guard let context = regenerateContext else { return "" }
        let messagesAfter = transcriptMessagesAfter(context)
        return withHermesCutNote(String(localized: "Regenerating this response will discard \(messagesAfter) later messages."))
    }

    private func withHermesCutNote(_ warning: String) -> String {
        guard isHermesSession else { return warning }
        return warning + "\n\n" + String(localized: "The Hermes host removes them for every app. It can't be undone.")
    }

    private var profileSwitchWarningMessage: String {
        guard let profile = pendingProfileSelection else {
            return String(localized: "Switching profiles starts a separate session so this transcript is not retagged.")
        }

        return String(localized: "Switch to \(profile.displayName) and start a new session. This keeps the current transcript on its original profile.")
    }

    private func transcriptMessagesAfter(_ context: MessageActionContext) -> Int {
        viewModel.transcriptMessagesAfter(context)
    }
}

struct ChatToolbarTitleLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.appPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsSubtitle, let subtitle {
                Text(subtitle)
                    .font(AppFont.caption2())
                    .foregroundStyle(.appSecondary)
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
        .frame(minHeight: 44)
        .modifier(LegacyToolbarClusterStyle())
        .accessibilityElement(children: .contain)
    }
}

private struct LegacyToolbarClusterStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .padding(.horizontal, 4)
                .background(
                    Color(.appSurface).opacity(colorScheme == .dark ? 0.24 : 0.42),
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
                        .stroke(Color(.appSeparator).opacity(colorScheme == .dark ? 0.38 : 0.24), lineWidth: 0.5)
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
            .font(AppFont.body())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

enum ChatToolbarSubtitleResolver {
    static func subtitle(workspacePath: String?, profileTitle: String?) -> String? {
        let workspace = nonEmpty(workspacePath)?.lastPathComponentFallback
        let profile = nonEmpty(profileTitle).flatMap { $0 == "Profile" ? nil : $0 }
        let parts = [workspace, profile].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PendingClearConfirmation: Equatable {
    let draft: String
    let draftRevision: Int
}

private struct ClearConversationAlertModifier: ViewModifier {
    @Binding var pending: PendingClearConfirmation?
    let isHapticsEnabled: Bool
    let onConfirm: (PendingClearConfirmation) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Clear Conversation?",
            isPresented: Binding(
                get: { pending != nil },
                set: { isPresented in
                    if !isPresented {
                        pending = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pending = nil
            }
            Button("Clear", role: .destructive) {
                guard let confirmed = pending else { return }
                ChatHaptics.destructiveConfirmationAccepted(isEnabled: isHapticsEnabled)
                pending = nil
                onConfirm(confirmed)
            }
        } message: {
            Text("This deletes every message in this conversation on the server. It cannot be undone.")
        }
    }
}

private struct StopConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onStop: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Stop this response?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Stop", role: .destructive, action: onStop)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Queued messages are discarded and the pending approval is denied.")
        }
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
        case .executed, .openedSession, .openedHermesSession, .replacedHermesSession, .openedHermesSessionList:
            true
        case .sendAsMessage, .unsupported, .needsSubArg, .notDelivered, .prefill:
            false
        }
    }
}

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

struct ChatNavigationBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .toolbarBackground(Color(uiColor: .appCanvas), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

struct HermesModelConfirmationModifier: ViewModifier {
    let controls: BotChatControls?

    func body(content: Content) -> some View {
        content.confirmationDialog("Change chat model?", isPresented: Binding(
            get: { controls?.confirmation != nil },
            set: { if !$0 { controls?.cancelConfirmation() } }
        ), titleVisibility: .visible) {
            if let controls, let confirmation = controls.confirmation {
                Button("Change model") {
                    controls.cancelConfirmation()
                    Task { await controls.confirm(confirmation) }
                }
                .disabled(!controls.mayChangeModel)
            }
            Button("Cancel", role: .cancel) { controls?.cancelConfirmation() }
        } message: {
            if let confirmation = controls?.confirmation { Text(confirmation.message) }
        }
    }
}

private struct HermesAutomationConfirmationModifier: ViewModifier {
    let sideTasks: HermesChatSideTasks?
    let onConfirm: (BotSessionControl) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Change session control?", isPresented: Binding(
            get: { sideTasks?.pendingAutomation != nil },
            set: { if !$0 { sideTasks?.cancelAutomation() } }
        ), titleVisibility: .visible) {
            if let control = sideTasks?.pendingAutomation {
                Button(control.actionTitle) { onConfirm(control) }
            }
            Button("Cancel", role: .cancel) { sideTasks?.cancelAutomation() }
        } message: {
            if let control = sideTasks?.pendingAutomation { Text(control.consequence) }
        }
    }
}

private struct HermesPersonalityConfirmationModifier: ViewModifier {
    let settings: HermesChatSettings?
    let profile: String
    let onConfirm: (String) -> Void

    func body(content: Content) -> some View {
        let clears = settings?.pendingPersonality == "none"
        let title: LocalizedStringKey = clears ? "Clear the personality for \(profile)?" : "Change the personality for \(profile)?"
        let confirm: LocalizedStringKey = clears ? "Clear" : "Change"
        let message: LocalizedStringKey = clears
            ? "New chats in \(profile) start without one on every device, and this chat switches now."
            : "New chats in \(profile) use it on every device, and this chat switches now."
        content.alert(
            title,
            isPresented: Binding(
                get: { settings?.pendingPersonality != nil },
                set: { if !$0 { settings?.cancelPersonality() } }
            )
        ) {
            Button("Cancel", role: .cancel) { settings?.cancelPersonality() }
            if let name = settings?.pendingPersonality {
                Button(confirm) {
                    settings?.cancelPersonality()
                    onConfirm(name)
                }
            }
        } message: {
            Text(message)
        }
    }
}

private struct HermesRollbackConfirmationModifier: ViewModifier {
    let pending: HermesRollbackRequest?
    let onCancel: () -> Void
    let onConfirm: (HermesRollbackRequest) -> Void

    func body(content: Content) -> some View {
        content.alert(
            Text(verbatim: pending.map { String(localized: "Restore checkpoint \($0.checkpoint.number)?") } ?? ""),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { onCancel() } }),
            presenting: pending
        ) { request in
            Button("Cancel", role: .cancel) { onCancel() }
            Button("Restore", role: .destructive) { onConfirm(request) }
        } message: { request in
            Text(verbatim: Self.message(request))
        }
    }

    private static func message(_ request: HermesRollbackRequest) -> String {
        let checkpoint = [ChatViewModel.checkpointTime(request.checkpoint.timestamp), request.checkpoint.message]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let consequence = request.filePath.map {
            String(localized: "\($0) goes back to how it was at this checkpoint. Its current content is overwritten.")
        } ?? String(localized: "Files the agent changed since this checkpoint go back to how they were. Edits you made yourself are kept. If the newest turn made these changes, it is removed from the chat.")
        return checkpoint.isEmpty ? consequence : "\(checkpoint)\n\n\(consequence)"
    }
}

private struct HermesFilePreviewItem: Identifiable {
    let id = UUID()
    let reference: TranscriptMediaReference
    var name: String? = nil
    var isSentAttachment = false
}
