import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftData

enum ListenPlaybackPhase: Equatable {
    case idle
    case loading
    case playing
    case paused
}

enum ListenPlaybackSpeed: Double, CaseIterable, Identifiable {
    case half = 0.5
    case normal = 1
    case oneAndHalf = 1.5
    case double = 2

    static let storageKey = "Chat.listenPlaybackSpeed"
    static let defaultValue: ListenPlaybackSpeed = .normal

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .half:
            return "0.5x"
        case .normal:
            return "1x"
        case .oneAndHalf:
            return "1.5x"
        case .double:
            return "2x"
        }
    }

    static func stored(in userDefaults: UserDefaults) -> ListenPlaybackSpeed {
        let storedValue = userDefaults.double(forKey: storageKey)
        return allCases.first { abs($0.rawValue - storedValue) < 0.001 } ?? defaultValue
    }
}

struct ListenNowPlayingSnapshot: Equatable {
    let title: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let speed: ListenPlaybackSpeed
    let isPlaying: Bool
}

@MainActor
protocol ListenRemoteControlControlling {
    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    )
    func update(_ snapshot: ListenNowPlayingSnapshot)
    func clear()
}

@MainActor
final class ListenRemoteControlController: ListenRemoteControlControlling {
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    deinit {
        commandTargets.forEach { command, target in
            command.removeTarget(target)
            command.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    ) {
        clearCommandTargets()

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandTargets.append((commandCenter.playCommand, commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in play() }
            return .success
        }))

        commandCenter.pauseCommand.isEnabled = true
        commandTargets.append((commandCenter.pauseCommand, commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in pause() }
            return .success
        }))

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandTargets.append((commandCenter.togglePlayPauseCommand, commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in togglePlayPause() }
            return .success
        }))

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandTargets.append((
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changePlaybackPositionCommand.addTarget { event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                Task { @MainActor in changePlaybackPosition(event.positionTime) }
                return .success
            }
        ))
    }

    func update(_ snapshot: ListenNowPlayingSnapshot) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: "Hermex",
            MPMediaItemPropertyPlaybackDuration: max(0, snapshot.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, snapshot.elapsedTime),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.speed.rawValue : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.speed.rawValue
        ]
        MPNowPlayingInfoCenter.default().playbackState = snapshot.isPlaying ? .playing : .paused
    }

    func clear() {
        clearCommandTargets()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func clearCommandTargets() {
        commandTargets.forEach { command, target in
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
    }
}

struct ApprovalPromptState: Equatable, Identifiable {
    var id: String {
        "\(sessionID)-\(pending.id)"
    }

    let sessionID: String
    let pending: PendingApproval
    let pendingCount: Int

    var patternKeys: [String] {
        pending.displayPatternKeys
    }

    var scopeLine: AttributedString? {
        ApprovalScope.line(
            keys: patternKeys, description: pending.description, command: pending.command, toolName: nil, host: .webui
        )
    }
}

struct ClarificationPromptState: Equatable, Identifiable {
    var id: String {
        "\(sessionID)-\(pending.id)"
    }

    let sessionID: String
    let pending: PendingClarification
    let pendingCount: Int

    var question: String {
        pending.displayQuestion
    }

    var choices: [String] {
        pending.displayChoices
    }
}

struct ProfileSwitchOutcome: Equatable {
    let session: SessionSummary?
}

struct ChatPollingIntervals {
    let approvalNanoseconds: UInt64
    let clarificationNanoseconds: UInt64
    let backgroundNanoseconds: UInt64
    var sleep: @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }

    static let standard = ChatPollingIntervals(
        approvalNanoseconds: 1_500_000_000,
        clarificationNanoseconds: 1_500_000_000,
        backgroundNanoseconds: 3_000_000_000
    )
}

struct HermesWaitingSend: Equatable {
    static let lifetime: TimeInterval = 10 * 60

    let send: ChatDraft.WaitingSend
    let key: ChatDraftKey
    var triedAttach: Int?
    var delivery: Delivery?

    enum Delivery: Equatable {
        case sending, paused, left
    }

    func hasExpired(at now: Date) -> Bool {
        now.timeIntervalSince(send.createdAt) >= Self.lifetime
    }

    static func waitsForConnection(_ notSent: HermesChatTurnCoordinator.NotSent) -> Bool {
        guard !notSent.duringUpload, !notSent.followedReplacedChat else { return false }
        return notSent.underlying as? BotFailure == .transport || notSent.underlying is URLError
    }

    enum Return: Equatable {
        case cancelled, expired, left, notSent
    }
}

struct HermesWaitingSendClock {
    var now: @MainActor () -> Date
    var sleep: @MainActor (TimeInterval) async throws -> Void

    static let live = HermesWaitingSendClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}

enum ChatSendOutcome: Equatable {
    case started, kept, waiting
}

enum ChatBackend {
    case webui
    case hermes(HermesChatTurnCoordinator)
}

enum ActiveStreamRecoveryState: Equatable {
    case idle
    case checking
    case reconnecting
    case waitingForNetwork
}

enum ChatServerLinkNotice: Equatable {
    case connecting
    case lost
    case stopped
}

@MainActor
@Observable
final class ChatViewModel {
    private static let messagePageLimit = 50

    private(set) var messages: [ChatMessage] = [] {
        didSet {
            guard !patchesStreamingReplyInPlace else { return }
            recomputeDisplayedTranscriptMessages()
            if hermesTurn != nil, !Self.onlyRepliesChanged(from: oldValue, to: messages) { updateHermesRewindableMessageIDs() }
        }
    }
    private var hermesRewindableMessageIDs: Set<String> = []
    var lastSentText: String? { ComposerRecall.lastSentText(in: messages) }
    private(set) var displayedTranscriptMessages: [TranscriptMessage] = []
    private(set) var transcriptStructureRevision = 0
    @ObservationIgnored private var patchesStreamingReplyInPlace = false
    private(set) var isLoading = false
    private(set) var isLoadingOlderMessages = false
    private(set) var isStartingChat = false
    private(set) var isSendingVoiceNote = false
    private(set) var isForkingMessage = false
    private(set) var hermesForkOrigin: ForkOrigin?
    @ObservationIgnored private var needsHermesForkCheck = false
    @ObservationIgnored private var isCheckingHermesForkParent = false
    private(set) var isEditingMessage = false
    private(set) var isRegeneratingMessage = false
    private var isChangingHermesHistory: Bool { isEditingMessage || isRegeneratingMessage }
    private(set) var isUndoingExchange = false
    private(set) var isCompressingSession = false
    private(set) var isCancellingStream = false
    private(set) var isViewingCachedData = false {
        didSet { if !isViewingCachedData { isCachedCopyProvisional = false } }
    }
    private(set) var isCachedCopyProvisional = false
    @ObservationIgnored private var needsReplacedChatNotice = false
    var showsOfflineCache: Bool { isViewingCachedData && !isCachedCopyProvisional }
    var activeStreamID: String? { turn.activeStreamID }
    var successfulResponseCompletion: ChatStreamCoordinator.SuccessfulResponseCompletion? {
        turn.successfulResponseCompletion
    }
    var activeRunStartedAt: Date? { turn.activeRunStartedAt }
    private(set) var latestRunOutcome: TranscriptTurnRunOutcome?
    var activeStreamRecoveryState: ActiveStreamRecoveryState { turn.recoveryState }
    var serverLinkNotice: ChatServerLinkNotice? { turn.serverLinkNotice }
    var liveTokensPerSecond: Double? { turn.liveTokensPerSecond }
    private(set) var errorMessage: String? { didSet { errorMayRetry = true; errorUnserved = nil } }
    private(set) var errorMayRetry = true
    private(set) var errorUnserved: HermesUnservedProfile?
    private(set) var sendErrorMessage: String? {
        didSet {
            sendErrorIsFromStreamRecovery = false
            errorUnserved = nil
            if sendErrorMessage != oldValue, sendErrorRuntimeStale != nil { sendErrorRuntimeStale = nil }
        }
    }
    @ObservationIgnored private var sendErrorIsFromStreamRecovery = false
    private(set) var sendErrorRuntimeStale: AgentRuntimeStale?
    private(set) var messageActionErrorMessage: String?
    private(set) var cacheErrorMessage: String?

    private(set) var isClearingConversation = false
    private(set) var lastError: Error?
    private(set) var displayTitle: String
    private(set) var listeningMessageID: String?
    private(set) var streamingScrollTrigger = 0
    private(set) var transcriptRelayoutScrollToken = 0
    private var hasPrimedInitialCachedMessages = false
    @ObservationIgnored private var initialSessionPrefetch: InitialSessionPrefetch?
    @ObservationIgnored private var pendingStreamingScrollTriggerTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAssistantText = ""
    @ObservationIgnored private var heldStreamingFragmentLastTick = false
    @ObservationIgnored private var pendingReasoningChunks: [String] = []
    @ObservationIgnored private var pendingStreamingContentFlushTask: Task<Void, Never>?
    private(set) var completedToolCallGroups: [ToolCallGroup] = []
    private var completedToolCallGroupLookup = ToolCallGroupAnchorLookup()
    private(set) var completedReasoningGroups: [ReasoningGroup] = [] {
        didSet { recomputeDisplayedTranscriptMessages() }
    }
    private(set) var displayedReasoningGroups: [ReasoningGroup] = []
    private(set) var reasoningGroupsByAnchorID: [String?: [ReasoningGroup]] = [:]
    @ObservationIgnored private var reasoningCandidateCache = ReasoningCandidateCache()
    func completedToolCallGroupsForAnchor(_ anchorMessageID: String?) -> [ToolCallGroup] {
        completedToolCallGroupLookup.groups(anchorMessageID: anchorMessageID)
    }

    var latestTurnToolCalls: [ToolCall] {
        let turnAnchors = Set(
            TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset)
        )
        var calls = completedToolCallGroups
            .filter { group in group.anchorMessageID.map(turnAnchors.contains) ?? false }
            .flatMap(\.toolCalls)
        calls.append(contentsOf: liveToolCalls)
        return calls
    }

    private func recomputeDisplayedTranscriptMessages() {
        transcriptStructureRevision &+= 1
        let reasoningGroups = Self.reasoningDisplayGroups(
            messages: messages,
            messageOffset: messagesOffset,
            archivedGroups: completedReasoningGroups,
            cache: &reasoningCandidateCache
        )
        if reasoningGroups != displayedReasoningGroups {
            displayedReasoningGroups = reasoningGroups
            reasoningGroupsByAnchorID = Dictionary(grouping: reasoningGroups, by: \.anchorMessageID)
        }
        let renderedActivityAnchorIDs = Self.transcriptActivityAnchorIDs(
            reasoningGroups: displayedReasoningGroups,
            toolCallGroups: completedToolCallGroups
        )
        displayedTranscriptMessages = Self.transcriptMessages(
            from: messages,
            messageOffset: messagesOffset,
            preservingEmptyAssistantID: streamingAssistantMessageID,
            renderedActivityAnchorIDs: renderedActivityAnchorIDs
        )
        recomputeCompressionReferenceCard()
    }
    private(set) var compressionReferenceCard: CompressionReferenceCard?
    @ObservationIgnored private var compressionAnchorMetadata: CompressionAnchorMetadata?
    @ObservationIgnored private var hermesCompaction: HermesCompaction?
    @ObservationIgnored private var hermesCache: ModelContext?
    @ObservationIgnored private var hermesCacheRoot: String?
    var followLatch = ChatScrollPolicy.FollowLatch()
    var expandedTurnKeys: Set<String> = []
    @ObservationIgnored var hermesBotChatRoot: String?
    @ObservationIgnored var hermesLineageRoot: String?
    @ObservationIgnored private var hermesCacheEpoch: Int?
    private func applyCompressionAnchorMetadata(from session: SessionDetail?) {
        compressionAnchorMetadata = CompressionAnchorMetadata(from: session)
        recomputeCompressionReferenceCard()
    }
    private func clearCompressionAnchorMetadata() {
        compressionAnchorMetadata = nil
        compressionReferenceCard = nil
    }
    private func recomputeCompressionReferenceCard() {
        let card = hermesCompaction.map {
            Self.hermesCompressionReferenceCard($0, messages: messages, transcriptMessages: displayedTranscriptMessages)
        } ?? Self.compressionReferenceCard(
            messages: messages,
            messagesOffset: messagesOffset,
            transcriptMessages: displayedTranscriptMessages,
            metadata: compressionAnchorMetadata
        )
        guard compressionReferenceCard != card else { return }

        compressionReferenceCard = card
    }
    private(set) var liveToolCalls: [ToolCall] = []
    private(set) var liveReasoningText = ""
    private(set) var streamingAssistantMessageID: String? {
        didSet {
            guard oldValue != streamingAssistantMessageID else { return }
            recomputeDisplayedTranscriptMessages()
        }
    }
    private(set) var toolCallAnchorMessageID: String?
    private(set) var reasoningAnchorMessageID: String?
    private(set) var messagesOffset = 0 {
        didSet { recomputeDisplayedTranscriptMessages() }
    }
    private(set) var hasOlderMessages = false
    private(set) var contextWindowSnapshot: ContextWindowSnapshot?
    private(set) var responseCompletionHapticTrigger = 0
    private(set) var runEndTrigger = 0
    private(set) var runEndOutcome: ResponseCompletionOutcome = .completed
    @ObservationIgnored private var runEndRecordedAt: Date?
    private(set) var streamingHapticPulseTrigger = 0
    private var streamingHapticPulseThrottle = ChatHaptics.StreamingPulseThrottle()
    private(set) var responseCompletionNeedsTranscriptRefresh = false
    private(set) var modelCatalogGroups: [ModelCatalogGroup] = []
    private(set) var agentCommands: [AgentCommand] = []
    private(set) var workspaceRoots: [WorkspaceRoot] = []
    private(set) var workspaceSuggestions: [String] = []
    private(set) var personalitySuggestions: [String] = ["none"]
    private(set) var skillSlashSuggestions: [SkillSlashSuggestion] = []
    private(set) var skillChipCatalog: ComposerChipCatalog = .empty
    private(set) var fileChipPaths: Set<String> = []
    private(set) var composerChipCatalog: ComposerChipCatalog = .empty
    @ObservationIgnored let filePathSearch = ComposerFilePathSearch()
    @ObservationIgnored private var fileChipReferenceLoad: Task<Void, Never>?
    @ObservationIgnored private var fileChipReferenceLoadGeneration = 0
    @ObservationIgnored private var checkedFileChipCandidates: Set<String> = []
    private(set) var fileChipScopeRevision = 0
    private(set) var transcriptRevision = 0
    private static let fileChipDirectoryLimit = 20
    private(set) var profileOptions: [ProfileSummary] = []
    private(set) var isSingleProfileMode = false
    private(set) var selectedProfileName: String?
    private(set) var selectedReasoningEffort: String?
    private(set) var supportedReasoningEfforts: [String]?
    private(set) var supportsReasoningEffort: Bool?
    private var reasoningGatingFetchToken = 0
    var showsReasoningEffortControl: Bool {
        if let hermesSettings { return hermesSettings.showsEffort }
        return ReasoningEffortOption.showsEffortControl(
            supportsReasoningEffort: supportsReasoningEffort,
            supportedEfforts: supportedReasoningEfforts
        )
    }
    private(set) var isLoadingComposerConfiguration = false
    private(set) var isUpdatingComposerConfiguration = false
    private(set) var composerConfigurationErrorMessage: String?
    var pendingAttachments: [PendingAttachment] { attachmentCoordinator.pendingAttachments }
    var isUploadingAttachment: Bool { attachmentCoordinator.isUploadingAttachment || isSendingAttachments }
    var isSendingAttachments: Bool { hermesTurn?.isUploadingAttachments == true }
    var attachmentUploadCount: Int { attachmentCoordinator.uploadInFlightCount }
    var attachmentUploadGeneration: Int { attachmentCoordinator.uploadStartGeneration }
    var uploadAttachmentErrorMessage: String? { attachmentCoordinator.uploadAttachmentErrorMessage }
    var localAttachmentPreviews: [String: [String: Data]] { attachmentCoordinator.localAttachmentPreviews }
    private(set) var pinnedLocalNotices: [String] = []
    var queuedMessagesReceipt: String? {
        guard !queuedSlashMessages.isEmpty else { return nil }
        return String(localized: "Queued, sends when this run finishes")
    }
    var queuedPromptMessages: [ChatMessage] {
        (hermesTurn?.queuedPrompts ?? []).map { Self.hermesPromptRow($0, id: "hermes-queued-prompt-\($0.id)", timestamp: nil) }
    }

    var lostTurn: ChatLostTurn? {
        guard let lost = hermesTurn?.lostTurn else { return nil }
        let last = messages.last
        let shown = last?.role == "user" && last?.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            == lost.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatLostTurn(prompt: shown ? nil : HermesChatTurnCoordinator.displayed(ChatMessage(
            role: "user", content: lost.text, timestamp: nil, messageId: "hermes-lost-turn-\(lost.admissionID)"
        )))
    }

    func discardLostTurn() async {
        guard let hermesTurn, !isDiscardingLostTurn else { return }
        isDiscardingLostTurn = true
        defer { isDiscardingLostTurn = false }
        do { try await hermesTurn.discardLostTurn() } catch {
            if error as? BotFailure == .stale { return }
            sendErrorMessage = String(localized: "Couldn’t discard the lost reply. Try again.")
        }
    }
    private var isDiscardingLostTurn = false
    private(set) var steeringConfirmationNotice: String?
    private(set) var steerFailureMessage: String?
    var approvalPrompt: ApprovalPromptState? { pendingActionCoordinator.approvalPrompt }
    var isRespondingToApproval: Bool { pendingActionCoordinator.isRespondingToApproval }
    var approvalErrorMessage: String? { pendingActionCoordinator.approvalErrorMessage }
    var isSessionApprovalBypassEnabled: Bool {
        hermesRequests?.approvalBypass ?? pendingActionCoordinator.isSessionApprovalBypassEnabled
    }
    var composerApprovals: ComposerApprovals {
        if let requests = hermesRequests {
            return ComposerApprovals(
                isYoloOn: requests.approvalBypass, offersModes: true, mode: requests.approvalMode,
                mayTurnOffYolo: requests.mayTurnOffApprovalBypass,
                isChanging: requests.isChangingApprovalBypass, errorMessage: requests.errorMessage
            )
        }
        return ComposerApprovals(
            isYoloOn: pendingActionCoordinator.isSessionApprovalBypassEnabled, offersModes: false, mode: nil,
            mayTurnOffYolo: true,
            isChanging: pendingActionCoordinator.isChangingApprovalBypass,
            errorMessage: pendingActionCoordinator.approvalBypassErrorMessage
        )
    }

    func setSessionApprovalBypass(_ enabled: Bool) async {
        if let requests = hermesRequests {
            await requests.setApprovalBypass(enabled)
        } else {
            await pendingActionCoordinator.setApprovalBypass(enabled)
        }
    }

    func selectApprovalMode(_ mode: HermesApprovalMode) async {
        await hermesRequests?.setApprovalMode(mode)
    }

    var clarificationPrompt: ClarificationPromptState? { pendingActionCoordinator.clarificationPrompt }
    var isRespondingToClarification: Bool { pendingActionCoordinator.isRespondingToClarification }
    var clarificationErrorMessage: String? { pendingActionCoordinator.clarificationErrorMessage }
    private(set) var currentGoal: SubmittedGoal?
    private(set) var isSubmittingGoal = false
    private(set) var goalErrorMessage: String?
    private(set) var hasActivatedGoalCommand = false

    private let sessionID: String?
    @ObservationIgnored private var chatSendGeneration = 0
    @ObservationIgnored private var compressionContinuation: SessionSummary?
    @ObservationIgnored private var compressionContinuationID: String?
    private(set) var isCompressionRotated = false
    @ObservationIgnored private var compressionRejectionMessage: String?
    @ObservationIgnored private var didHandOffCompressionDraft = false
    private var currentWorkspace: String? {
        didSet {
            guard currentWorkspace != oldValue else { return }
            resetFileChipReferences()
        }
    }
    private var currentModel: String?
    private var currentModelProvider: String?
    private var currentProfile: String?
    private let isCLISession: Bool
    private let server: URL
    var hermesSessionLink: HermesSessionDestination? {
        guard let engine = hermesTurn?.engine,
              let key = HermesDeepLink.normalizedSessionID(engine.storedKey ?? sessionID) else { return nil }
        return HermesSessionDestination(server: server, profile: engine.target.profile, key: key)
    }

    var pushPresence: PushPresence.Viewer? {
        (hermesSessionLink?.key ?? sessionID).map { PushPresence.Viewer(server: server, sessionID: $0) }
    }
    let client: APIClient
    private let streamCoordinator: ChatStreamCoordinator
    private let turn: any ChatTurnCoordinating
    private let hermesTurn: HermesChatTurnCoordinator?
    private let drafts: ChatDraftStore
    private let pendingActionCoordinator: ChatPendingActionCoordinator
    private let attachmentCoordinator: ChatAttachmentCoordinator
    private let btwStreamClient: SSEStreamingClient
    private let liveActivityManager: any AgentLiveActivityManaging
    private let listenAudioSession: any ListenAudioSessionControlling
    private let listenRemoteControlCenter: any ListenRemoteControlControlling
    private let userDefaults: UserDefaults
    private let pollingIntervals: ChatPollingIntervals
    private let steeringConfirmationDismissDelay: @Sendable () async throws -> Void
    @ObservationIgnored private var steeringConfirmationDismissTask: Task<Void, Never>?
    private let streamingScrollCoalescingDelayNanoseconds: UInt64
    private let streamingRevealTick: @Sendable () async throws -> Void
    private let listenAudioPlayerFactory: @MainActor (Data) throws -> any ListenAudioPlaying
    private let renderOnDeviceSpeech: @MainActor (String) async throws -> Data
    private let listenSpeedChangeSettleDelay: @Sendable () async throws -> Void
    @ObservationIgnored private(set) var listenNowPlayingRefreshTask: Task<Void, Never>?
    private let synthesizeListenAudio: @MainActor (String) async throws -> Data?
    private var listenAudioPlayer: (any ListenAudioPlaying)?
    private var activeListenPlayerID: ObjectIdentifier?
    @ObservationIgnored private(set) var listenPreparationTask: Task<Void, Never>?
    private var activeListenRequestID: UUID?
    private var listenPlaybackTitle = String(localized: "Hermex response")
    private(set) var listenPlaybackPhase: ListenPlaybackPhase = .idle
    private(set) var listenPlaybackElapsedTime: TimeInterval = 0
    private(set) var listenPlaybackDuration: TimeInterval = 0
    private(set) var listenPlaybackScrubTime: TimeInterval?
    private(set) var listenPlaybackSpeed: ListenPlaybackSpeed
    @ObservationIgnored private var listenPlaybackTicker: Timer?
    private var showsLiveActivityResponseExcerpts: Bool
    private var hasCompletedCurrentResponse: Bool { turn.hasCompletedCurrentResponse }
    private var isStreamConnectionSuspended: Bool { turn.isConnectionSuspended }
    var isActiveStreamConnectionSuspended: Bool { turn.isConnectionSuspended }
    private var hasLoadedPersonalitySuggestions = false
    private var personalitySuggestionsLoad: Task<Void, Never>?
    private(set) var hasLoadedSkillSlashSuggestions = false
    private var skillSlashSuggestionsLoad: Task<Void, Never>?
    private var queuedSlashMessages: [QueuedSlashMessage] = []
    private var isDrainingQueuedSlashMessage = false
    @ObservationIgnored private var queueHandOverCount = 0
    private var activeBtwStreamID: String?
    private var activeBtwMessageID: String?
    private var activeBtwQuestion: String?
    private var activeBtwAnswer = ""
    private var backgroundPromptsByTaskID: [String: String] = [:]
    @ObservationIgnored private var backgroundPollTask: Task<Void, Never>?
    private var isRefreshingCompletedResponseTitle = false
    var isActiveStreamReplayConnection: Bool { turn.isReplayConnection }
    private var activeStreamReplayMatchedPrefixLength = 0
    private var activeStreamReplayMatchedInterimLength = 0
    private var activeStreamReplayMatchedReasoningLength = 0
    private var activeStreamReplayLoadedReasoningText = ""
    private var activeStreamReplayLoadedToolCalls: [ToolCall] = []
    private var activeStreamReplayLoadedToolMatchIndex = 0
    private var activeStreamReplayPendingLoadedToolMatchIndex: Int?
    private var activeStreamReplayToolMatchIndex = 0
    private var activeStreamReplayPendingToolMatchIndex: Int?
    private var latestServerLoadHadAssistantResponseAfterLatestUser = false
    private var needsComposerConfigurationReload = false
    private var pendingExplicitModelPick = false
    private(set) var composerConfigurationInteractionGeneration = 0

    init(
        session: SessionSummary,
        server: URL,
        client: APIClient? = nil,
        streamClient: SSEStreamingClient? = nil,
        approvalStreamClient: SSEStreamingClient? = nil,
        clarifyStreamClient: SSEStreamingClient? = nil,
        btwStreamClient: SSEStreamingClient? = nil,
        liveActivityManager: (any AgentLiveActivityManaging)? = nil,
        showsLiveActivityResponseExcerpts: Bool = false,
        pollingIntervals: ChatPollingIntervals = .standard,
        steeringConfirmationDismissDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        },
        streamingScrollCoalescingDelayNanoseconds: UInt64 = 16_000_000,
        streamingRevealTick: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 50_000_000)
        },
        renderOnDeviceSpeech: @escaping @MainActor (String) async throws -> Data = { try await OnDeviceSpeech.render($0) },
        listenSpeedChangeSettleDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        },
        listenAudioSession: (any ListenAudioSessionControlling)? = nil,
        listenRemoteControlCenter: (any ListenRemoteControlControlling)? = nil,
        listenAudioPlayerFactory: (@MainActor (Data) throws -> any ListenAudioPlaying)? = nil,
        synthesizeListenAudio: (@MainActor (String) async throws -> Data?)? = nil,
        draftAttachmentStore: any ChatDraftAttachmentStoring = ChatDraftAttachmentStore.shared,
        draftStore: ChatDraftStore? = nil,
        userDefaults: UserDefaults = .standard,
        backend: ChatBackend = .webui,
        waitingSendClock: HermesWaitingSendClock = .live
    ) {
        sessionID = session.sessionId
        currentWorkspace = session.workspace
        currentModel = session.model
        currentModelProvider = session.modelProvider
        currentProfile = session.profile
        isCLISession = session.isCliSession == true
        self.server = server
        let resolvedClient = client ?? APIClient(baseURL: server)
        let resolvedStreamClient = streamClient ?? SSEClient()
        let resolvedLiveActivityManager = liveActivityManager ?? AgentLiveActivityManager.shared
        self.client = resolvedClient
        let streamCoordinator = ChatStreamCoordinator(
            client: resolvedClient,
            streamClient: resolvedStreamClient,
            liveActivityManager: resolvedLiveActivityManager,
            showsLiveActivityResponseExcerpts: showsLiveActivityResponseExcerpts
        )
        self.streamCoordinator = streamCoordinator
        let backendSpeech: @MainActor (String) async throws -> Data?
        switch backend {
        case .webui:
            hermesTurn = nil
            turn = streamCoordinator
            backendSpeech = { try await resolvedClient.listenSpeech(for: $0) }
        case .hermes(let coordinator):
            hermesTurn = coordinator
            turn = coordinator
            backendSpeech = { try await coordinator.speech(for: $0) }
            currentProfile = coordinator.settings.profile
            selectedProfileName = coordinator.settings.profile
            coordinator.setShowsLiveActivityResponseExcerpts(showsLiveActivityResponseExcerpts)
        }
        self.drafts = draftStore ?? .shared
        self.waitingSendClock = waitingSendClock
        self.pendingActionCoordinator = ChatPendingActionCoordinator(
            client: resolvedClient,
            approvalStreamClient: approvalStreamClient ?? SSEClient(),
            clarifyStreamClient: clarifyStreamClient ?? SSEClient(),
            pollingIntervals: pollingIntervals
        )
        self.attachmentCoordinator = ChatAttachmentCoordinator(
            client: resolvedClient,
            draftAttachmentStore: draftAttachmentStore,
            draftStore: draftStore,
            uploadsOnSend: hermesTurn != nil
        )
        self.btwStreamClient = btwStreamClient ?? SSEClient()
        self.liveActivityManager = resolvedLiveActivityManager
        self.showsLiveActivityResponseExcerpts = showsLiveActivityResponseExcerpts
        self.pollingIntervals = pollingIntervals
        self.steeringConfirmationDismissDelay = steeringConfirmationDismissDelay
        self.streamingScrollCoalescingDelayNanoseconds = streamingScrollCoalescingDelayNanoseconds
        self.streamingRevealTick = streamingRevealTick
        self.renderOnDeviceSpeech = renderOnDeviceSpeech
        self.listenSpeedChangeSettleDelay = listenSpeedChangeSettleDelay
        self.listenAudioSession = listenAudioSession ?? ListenAudioSessionController()
        self.listenRemoteControlCenter = listenRemoteControlCenter ?? ListenRemoteControlController()
        self.userDefaults = userDefaults
        self.listenPlaybackSpeed = ListenPlaybackSpeed.stored(in: userDefaults)
        self.listenAudioPlayerFactory = listenAudioPlayerFactory
            ?? { try ListenAudioPlayer(data: $0) }
        self.synthesizeListenAudio = synthesizeListenAudio ?? backendSpeech
        displayTitle = Self.displayTitle(from: session.title)
        turn.attach(delegate: self)
        self.pendingActionCoordinator.delegate = self
        self.attachmentCoordinator.delegate = self
        hermesTurn?.slashCommands.onSkills = { [weak self] in self?.applySkillSlashSuggestions($0) }
    }

    deinit {
        backgroundPollTask?.cancel()
        steeringConfirmationDismissTask?.cancel()
        pendingStreamingScrollTriggerTask?.cancel()
        pendingStreamingContentFlushTask?.cancel()
        listenPreparationTask?.cancel()
        listenPlaybackTicker?.invalidate()
        initialSessionPrefetch?.task.cancel()
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityResponseExcerpts != shows else { return }

        showsLiveActivityResponseExcerpts = shows
        turn.setShowsLiveActivityResponseExcerpts(shows)
    }

    var showsListenPlaybackBar: Bool {
        listenPlaybackPhase != .idle
    }

    var listenPlaybackDisplayTime: TimeInterval {
        listenPlaybackScrubTime ?? listenPlaybackElapsedTime
    }

    nonisolated static func resetActiveStreamSnapshotsForTesting() {
        ActiveChatStreamSnapshotStore.shared.removeAll()
    }

    func awaitPendingStreamingScrollTriggerForTesting() async {
        await pendingStreamingScrollTriggerTask?.value
    }

    struct ActiveStreamMessageMerge {
        let messages: [ChatMessage]
        let streamingAssistantMessageID: String?
        let usedSnapshotMessagesOffset: Bool
    }

    var selectedModelID: String? {
        hermesSettings?.selectedModel?.id ?? currentModel
    }

    var selectedModelProviderID: String? {
        hermesSettings.map { $0.selectedModel?.providerID } ?? currentModelProvider
    }

    var composerModelGroups: [ModelCatalogGroup] {
        hermesSettings?.controls.catalog.groups ?? modelCatalogGroups
    }

    var composerProfileOptions: [ProfileSummary] {
        hermesSettings?.profileOptions ?? profileOptions
    }

    var composerIsSingleProfileMode: Bool {
        guard let hermesTurn else { return isSingleProfileMode }
        return !hermesTurn.policy.picksProfile || hermesTurn.settings.profiles.count <= 1
    }

    var composerConfigurationNotice: String? {
        guard let pending = hermesSettings?.controls.pendingModel else { return nil }
        return String(localized: "Switches to \(ModelDisplayNames.displayLabel(for: pending.id, displayName: pending.displayName)) after this response.")
    }

    var hermesSettings: HermesChatSettings? { hermesTurn?.settings }
    var hermesBotChat: HermesChatTurnCoordinator? { hermesTurn?.policy == .botChat ? hermesTurn : nil }

    var hermesScreenUse: BotScreenUse? { hermesTurn?.screenUse }

    var composerReasoningEffort: String? {
        hermesSettings.map { $0.controls.effort } ?? selectedReasoningEffort
    }

    var composerSupportedReasoningEfforts: [String]? {
        hermesSettings?.effortLevels ?? supportedReasoningEfforts
    }

    var composerSentReasoningEffort: String? { hermesSettings?.sentEffort }

    var composerFastMode: Bool? { hermesSettings?.fast }

    var composerMayChangeFastMode: Bool { hermesSettings?.mayChangeFast == true }

    func selectFastMode(_ enabled: Bool) async -> Bool {
        await hermesSettings?.select(fast: enabled) ?? false
    }

    var selectedWorkspacePath: String? {
        hermesTurn.map(\.cwd) ?? currentWorkspace
    }

    var selectedProfileTitle: String {
        let profileName = selectedProfileName ?? currentProfile
        guard let profileName, !profileName.isEmpty else {
            return String(localized: "Profile")
        }

        if let option = composerProfileOptions.first(where: { $0.name == profileName }) {
            return option.displayName
        }

        return profileName == "default" ? String(localized: "Default") : profileName
    }

    var selectedModelTitle: String {
        guard let model = selectedModelID, !model.isEmpty else {
            return String(localized: "Model")
        }

        let catalogName = composerModelGroups
            .flatMap(\.allModels)
            .firstMatchingSelection(modelID: selectedModelID, providerID: selectedModelProviderID)?
            .displayName

        return catalogName ?? Self.compactModelTitle(model)
    }

    func isSelectedProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }
        return profileName == (Self.nonEmpty(selectedProfileName) ?? Self.nonEmpty(currentProfile))
    }

    private func scheduleStreamingScrollTrigger() {
        guard pendingStreamingScrollTriggerTask == nil else { return }

        let delay = streamingScrollCoalescingDelayNanoseconds
        pendingStreamingScrollTriggerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }

            self.pendingStreamingScrollTriggerTask = nil
            guard !Task.isCancelled else { return }

            self.streamingScrollTrigger += 1
        }
    }

    private func cancelPendingStreamingScrollTrigger() {
        pendingStreamingScrollTriggerTask?.cancel()
        pendingStreamingScrollTriggerTask = nil
    }

    private func scheduleStreamingContentFlush() {
        guard pendingStreamingContentFlushTask == nil else { return }

        let tick = streamingRevealTick
        pendingStreamingContentFlushTask = Task { @MainActor [weak self] in
            try? await tick()
            guard let self, !Task.isCancelled else { return }

            self.pendingStreamingContentFlushTask = nil
            self.revealStreamingContentTick()
        }
    }

    private func revealStreamingContentTick() {
        let signpost = performanceSignposter.beginInterval("Stream Batch Apply")
        var didMutate = false
        if flushAssistantTokens(throughRevealGate: true) {
            didMutate = true
        }
        if flushReasoningChunks() {
            didMutate = true
        }

        if didMutate {
            scheduleStreamingScrollTrigger()
        }

        if heldStreamingFragmentLastTick {
            scheduleStreamingContentFlush()
        }
        performanceSignposter.endInterval(
            "Stream Batch Apply", signpost,
            "mutated=\(didMutate ? 1 : 0, privacy: .public) forced=0"
        )
    }

    private func cancelPendingStreamingContentFlush() {
        pendingStreamingContentFlushTask?.cancel()
        pendingStreamingContentFlushTask = nil
    }

    private func resetPendingStreamingContentBuffers() {
        cancelPendingStreamingContentFlush()
        pendingAssistantText = ""
        heldStreamingFragmentLastTick = false
        pendingReasoningChunks = []
        activeStreamReplayMatchedPrefixLength = 0
        activeStreamReplayMatchedReasoningLength = 0
    }

    func flushPendingStreamingContent() {
        let signpost = performanceSignposter.beginInterval("Stream Batch Apply")
        cancelPendingStreamingContentFlush()

        var didMutate = false
        if flushAssistantTokens() {
            didMutate = true
        }
        if flushReasoningChunks() {
            didMutate = true
        }

        if didMutate {
            scheduleStreamingScrollTrigger()
        }
        performanceSignposter.endInterval(
            "Stream Batch Apply", signpost,
            "mutated=\(didMutate ? 1 : 0, privacy: .public) forced=1"
        )
    }

    private var requestProfileName: String? {
        Self.nonEmpty(selectedProfileName) ?? Self.nonEmpty(currentProfile)
    }

    private var requestModelProvider: String? {
        Self.nonEmpty(currentModelProvider)
    }

    private func explicitModelPickForChatStart() -> Bool {
        pendingExplicitModelPick && Self.nonEmpty(currentModel) != nil
    }

    private func completeExplicitModelPickForChatStart(_ explicitModelPick: Bool) {
        if explicitModelPick {
            pendingExplicitModelPick = false
        }
    }

    func loadComposerConfiguration() async {
        guard hermesTurn == nil else { return }
        if isLoadingComposerConfiguration {
            needsComposerConfigurationReload = true
            return
        }

        isLoadingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isLoadingComposerConfiguration = false }

        repeat {
            needsComposerConfigurationReload = false

            let initialState = composerConfigurationState
            let result = await ChatComposerConfigLoader(client: client)
                .loadConfiguration(from: initialState)

            guard composerConfigurationState == initialState else {
                needsComposerConfigurationReload = true
                continue
            }

            applyComposerConfigurationState(result.state)

            if let error = result.configurationError {
                lastError = error
                composerConfigurationErrorMessage = error.localizedDescription
            }
        } while needsComposerConfigurationReload
    }

    func refreshModelCatalogForPickerOpen() async {
        if let hermesSettings {
            await hermesSettings.controls.reload()
            return
        }
        if let response = try? await client.models() {
            let groups = response.catalogGroups
            if !groups.isEmpty {
                modelCatalogGroups = groups
            }
        }

        if let live = try? await client.modelsLive() {
            modelCatalogGroups = modelCatalogGroups.mergingLiveModels(from: live)
        }
    }

    private var composerConfigurationState: ChatComposerConfigState {
        ChatComposerConfigState(
            currentWorkspace: currentWorkspace,
            currentModel: currentModel,
            currentModelProvider: currentModelProvider,
            currentProfile: currentProfile,
            selectedProfileName: selectedProfileName,
            selectedReasoningEffort: selectedReasoningEffort,
            supportedReasoningEfforts: supportedReasoningEfforts,
            supportsReasoningEffort: supportsReasoningEffort,
            modelCatalogGroups: modelCatalogGroups,
            agentCommands: agentCommands,
            workspaceRoots: workspaceRoots,
            workspaceSuggestions: workspaceSuggestions,
            profileOptions: profileOptions,
            isSingleProfileMode: isSingleProfileMode
        )
    }

    private func applyComposerConfigurationState(_ state: ChatComposerConfigState) {
        currentWorkspace = state.currentWorkspace
        currentModel = state.currentModel
        currentModelProvider = state.currentModelProvider
        currentProfile = state.currentProfile
        selectedProfileName = state.selectedProfileName
        selectedReasoningEffort = state.selectedReasoningEffort
        supportedReasoningEfforts = state.supportedReasoningEfforts
        supportsReasoningEffort = state.supportsReasoningEffort
        modelCatalogGroups = state.modelCatalogGroups
        agentCommands = state.agentCommands
        workspaceRoots = state.workspaceRoots
        workspaceSuggestions = state.workspaceSuggestions
        profileOptions = state.profileOptions
        isSingleProfileMode = state.isSingleProfileMode
    }

    func refreshApprovalBypassState() async {
        await pendingActionCoordinator.refreshApprovalBypassState()
    }

    @discardableResult
    func selectComposerModel(
        _ option: ModelCatalogOption,
        recordsInteraction: Bool = true
    ) async -> Bool {
        if recordsInteraction {
            composerConfigurationInteractionGeneration &+= 1
        }
        if let hermesSettings {
            return await hermesSettings.select(option)
        }
        guard !option.matchesSelection(modelID: currentModel, providerID: currentModelProvider) else {
            return false
        }

        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change models.")
            return false
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing models.")
            return false
        }

        guard let sessionID else {
            composerConfigurationErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: currentWorkspace,
                model: option.id,
                modelProvider: option.providerID
            )

            currentModel = response.session?.model ?? option.id
            currentModelProvider = response.session?.modelProvider ?? option.providerID
            currentWorkspace = response.session?.workspace ?? currentWorkspace
            pendingExplicitModelPick = true
            await refreshReasoningEffortGating()
            return true
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return false
        }
    }

    func refreshReasoningEffortGating() async {
        guard !isViewingCachedData else { return }

        reasoningGatingFetchToken += 1
        let token = reasoningGatingFetchToken

        guard let response = try? await client.reasoning(
            model: Self.nonEmpty(currentModel),
            provider: Self.nonEmpty(currentModelProvider)
        ) else {
            if token == reasoningGatingFetchToken {
                supportedReasoningEfforts = nil
                supportsReasoningEffort = nil
            }
            return
        }

        guard token == reasoningGatingFetchToken else { return }

        supportedReasoningEfforts = response.normalizedSupportedEfforts
        supportsReasoningEffort = response.supportsReasoningEffort

        if let selected = Self.nonEmpty(selectedReasoningEffort)?.lowercased(),
           let supported = supportedReasoningEfforts,
           !supported.contains(selected),
           let serverEffort = Self.nonEmpty(response.effectiveEffort) {
            selectedReasoningEffort = serverEffort
        }
    }

    func refreshWorkspaceRoots() async {
        guard !isViewingCachedData else { return }

        do {
            let response = try await client.workspaces()
            workspaceRoots = response.workspaces ?? []
            workspaceSuggestions = workspaceRoots.compactMap(\.path)
        } catch {
            lastError = error
        }
    }

    func loadWorkspaceSuggestions(prefix: String) async {
        if let hermesTurn, !isViewingCachedData {
            await loadHermesFolderSuggestions(prefix: prefix, on: hermesTurn)
            return
        }
        guard !isViewingCachedData else {
            workspaceSuggestions = workspaceRoots.compactMap(\.path)
            return
        }

        do {
            let response = try await client.workspaceSuggestions(prefix: prefix)
            guard !Task.isCancelled else { return }
            workspaceSuggestions = response.suggestions ?? []
        } catch {
            guard !Task.isCancelled else { return }
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
        }
    }

    func loadPersonalitySuggestions() async {
        guard !hasLoadedPersonalitySuggestions, !showsOfflineCache else { return }
        if let hermesSettings {
            guard let personalities = try? await hermesSettings.personalities() else { return }
            personalitySuggestions = ["none"] + personalities.map(\.name)
            hasLoadedPersonalitySuggestions = true
            return
        }

        let load: Task<Void, Never>
        if let existing = personalitySuggestionsLoad {
            load = existing
        } else {
            load = Task { [weak self] in
                guard let self else { return }
                do {
                    self.personalitySuggestions = (try await self.client.personalities()).slashAutocompleteNames
                    self.hasLoadedPersonalitySuggestions = true
                } catch {
                    self.lastError = error
                    self.composerConfigurationErrorMessage = error.localizedDescription
                    if self.personalitySuggestions.isEmpty {
                        self.personalitySuggestions = ["none"]
                    }
                }
                self.personalitySuggestionsLoad = nil
            }
            personalitySuggestionsLoad = load
        }

        await load.value
    }

    func loadSkillSlashSuggestions() async {
        guard hermesTurn == nil, !hasLoadedSkillSlashSuggestions, !showsOfflineCache else { return }

        let load: Task<Void, Never>
        if let existing = skillSlashSuggestionsLoad {
            load = existing
        } else {
            load = Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await self.client.skills()
                    self.applySkillSlashSuggestions(
                        SlashSkillFormatter.suggestions(from: response.skills ?? [])
                    )
                    self.hasLoadedSkillSlashSuggestions = true
                } catch {
                    self.lastError = error
                }
                self.skillSlashSuggestionsLoad = nil
            }
            skillSlashSuggestionsLoad = load
        }

        await load.value
    }

    @discardableResult
    func selectWorkspacePath(
        _ path: String,
        recordsInteraction: Bool = true
    ) async -> Bool {
        if recordsInteraction {
            composerConfigurationInteractionGeneration &+= 1
        }
        if hermesTurn != nil { return await selectHermesFolder(path) }
        let workspace = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return false }

        guard workspace != currentWorkspace else {
            return false
        }

        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change workspace.")
            return false
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing workspace.")
            return false
        }

        guard let sessionID else {
            composerConfigurationErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let previousWorkspace = currentWorkspace
        currentWorkspace = workspace
        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: workspace,
                model: currentModel,
                modelProvider: currentModelProvider
            )

            currentWorkspace = response.session?.workspace ?? workspace
            currentModel = response.session?.model ?? currentModel
            currentModelProvider = response.session?.modelProvider ?? currentModelProvider
            return true
        } catch {
            currentWorkspace = previousWorkspace
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return false
        }
    }

    private(set) var pendingHermesFolder: String?
    @ObservationIgnored private var hermesFolderChoices: [String]?

    private func selectHermesFolder(_ path: String) async -> Bool {
        var folder = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        guard let hermesTurn, !folder.isEmpty, folder != hermesTurn.cwd, canChangeHermesFolder() else { return false }
        guard hermesTurn.isUnstarted else {
            pendingHermesFolder = folder
            return false
        }
        return await moveHermesFolder(folder, on: hermesTurn)
    }

    func cancelHermesFolderMove() { pendingHermesFolder = nil }

    func confirmHermesFolderMove(_ folder: String) async -> Bool {
        pendingHermesFolder = nil
        guard let hermesTurn, canChangeHermesFolder() else { return false }
        return await moveHermesFolder(folder, on: hermesTurn)
    }

    private func canChangeHermesFolder() -> Bool {
        if isViewingCachedData {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change workspace.")
            return false
        }
        if activeStreamID != nil {
            composerConfigurationErrorMessage = Self.waitToChangeWorkspace
            return false
        }
        return true
    }

    private static var waitToChangeWorkspace: String {
        String(localized: "Wait for the current response to finish before changing workspace.")
    }

    private func moveHermesFolder(_ folder: String, on hermes: HermesChatTurnCoordinator) async -> Bool {
        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        defer { isUpdatingComposerConfiguration = false }
        do {
            try await hermes.moveFolder(to: folder)
            return true
        } catch BotSettingFailure.rejected(4017, _) {
            composerConfigurationErrorMessage = String(localized: "Hermes can't find the folder \(folder), so the session didn't move.")
        } catch is HermesChatTurnCoordinator.ReplyRunning {
            composerConfigurationErrorMessage = Self.waitToChangeWorkspace
        } catch {
            composerConfigurationErrorMessage = error.localizedDescription
        }
        return false
    }

    private func loadHermesFolderSuggestions(prefix: String, on hermes: HermesChatTurnCoordinator) async {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if HermesFolderCompletion.completes(typed) {
            let folders = await hermes.completeFolder(typed)
            guard !Task.isCancelled else { return }
            workspaceSuggestions = folders
            return
        }
        if typed.isEmpty { hermesFolderChoices = nil }
        let choices: [String]
        if let hermesFolderChoices {
            choices = hermesFolderChoices
        } else {
            choices = await hermes.folderChoices()
            guard !Task.isCancelled else { return }
            hermesFolderChoices = choices
        }
        workspaceSuggestions = typed.isEmpty ? choices : choices.filter { $0.localizedCaseInsensitiveContains(typed) }
    }

    func switchProfile(
        _ profile: ProfileSummary,
        startNewSession: Bool,
        recordsInteraction: Bool = true
    ) async -> ProfileSwitchOutcome? {
        if recordsInteraction {
            composerConfigurationInteractionGeneration &+= 1
        }
        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change profiles.")
            return nil
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing profiles.")
            return nil
        }

        guard let profileName = profile.normalizedName else {
            composerConfigurationErrorMessage = String(localized: "The server did not provide a profile name.")
            return nil
        }

        if !startNewSession, isSelectedProfile(profile) {
            return nil
        }

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.switchProfile(name: profileName)
            profileOptions = response.profiles ?? profileOptions
            selectedProfileName = response.active ?? profileName
            currentProfile = selectedProfileName

            if let defaultWorkspace = response.defaultWorkspace, !defaultWorkspace.isEmpty {
                currentWorkspace = defaultWorkspace
            }

            if let defaultModel = response.defaultModel, !defaultModel.isEmpty {
                currentModel = defaultModel
                currentModelProvider = Self.nonEmpty(profile.provider)
            }
            pendingExplicitModelPick = false

            await loadComposerConfiguration()

            guard startNewSession else {
                return ProfileSwitchOutcome(session: nil)
            }

            let newSessionResponse = try await client.createSession(
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName
            )

            guard let session = newSessionResponse.session else {
                composerConfigurationErrorMessage = String(localized: "The server did not return the new profile session.")
                return nil
            }

            return ProfileSwitchOutcome(session: SessionSummary(from: session))
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func selectReasoningEffort(
        _ effort: String,
        recordsInteraction: Bool = true
    ) async -> Bool {
        if recordsInteraction {
            composerConfigurationInteractionGeneration &+= 1
        }
        let selectedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedEffort.isEmpty else { return false }

        if let hermesSettings {
            guard selectedEffort != hermesSettings.controls.effort else { return false }
            return await hermesSettings.select(effort: selectedEffort)
        }

        guard selectedEffort != selectedReasoningEffort else {
            return false
        }

        guard !isViewingCachedData else {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to change reasoning.")
            return false
        }

        guard activeStreamID == nil else {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before changing reasoning.")
            return false
        }

        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            composerConfigurationErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.saveReasoningEffort(
                selectedEffort,
                sessionID: sessionID
            )
            selectedReasoningEffort = response.effectiveEffort ?? selectedEffort
            return true
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return false
        }
    }

    func restoreDraftSettings(
        _ rawSettings: ChatDraftSettings,
        expectedInteractionGeneration: Int
    ) async {
        guard canContinueDraftSettingsRestore(expectedInteractionGeneration) else { return }
        guard messages.isEmpty, activeStreamID == nil else { return }
        let settings = rawSettings.normalized()

        if let profileName = settings.profileName {
            guard let option = profileOptions.first(where: { $0.normalizedName == profileName }) else {
                return
            }
            if !isSelectedProfile(option) {
                let outcome = await switchProfile(
                    option,
                    startNewSession: false,
                    recordsInteraction: false
                )
                guard outcome != nil,
                      canContinueDraftSettingsRestore(expectedInteractionGeneration),
                      isSelectedProfile(option) else {
                    return
                }
            }
        }

        guard canContinueDraftSettingsRestore(expectedInteractionGeneration) else { return }
        if let modelID = settings.modelID,
           let option = modelCatalogGroups
               .flatMap(\.allModels)
               .firstMatchingSelection(modelID: modelID, providerID: settings.modelProviderID),
           !option.matchesSelection(modelID: currentModel, providerID: currentModelProvider) {
            _ = await selectComposerModel(option, recordsInteraction: false)
            guard canContinueDraftSettingsRestore(expectedInteractionGeneration) else { return }
        }

        if let workspace = settings.workspacePath,
           workspace != currentWorkspace,
           workspaceRoots.contains(where: { $0.path == workspace }) {
            _ = await selectWorkspacePath(workspace, recordsInteraction: false)
            guard canContinueDraftSettingsRestore(expectedInteractionGeneration) else { return }
        }

        if let effort = settings.reasoningEffort,
           effort != selectedReasoningEffort,
           showsReasoningEffortControl {
            let supportedEfforts = supportedReasoningEfforts
            if supportedEfforts == nil || supportedEfforts?.contains(effort.lowercased()) == true {
                _ = await selectReasoningEffort(effort, recordsInteraction: false)
            }
        }
    }

    func markComposerConfigurationInteraction() {
        composerConfigurationInteractionGeneration &+= 1
    }

    private func canContinueDraftSettingsRestore(_ expectedInteractionGeneration: Int) -> Bool {
        !Task.isCancelled
            && composerConfigurationInteractionGeneration == expectedInteractionGeneration
    }

    @discardableResult
    func uploadAttachment(data: Data, filename: String, previewData: Data? = nil) async -> PendingAttachment? {
        await attachmentCoordinator.uploadAttachment(
            data: data,
            filename: filename,
            previewData: previewData
        )
    }

    @discardableResult
    func stagePastedText(_ text: String) -> Task<PendingAttachment?, Never> {
        attachmentCoordinator.stagePastedText(text)
    }

    func cancelPastedTextStaging() {
        attachmentCoordinator.cancelPastedTextStaging()
    }

    var stagedFilesAreSending: Bool { isSubmittingHermesPrompt || isHermesSubmissionUncertain }

    func stagedPasteText(_ attachment: PendingAttachment) async -> StagedPasteText? {
        await attachmentCoordinator.stagedPasteText(attachment)
    }

    func saveStagedPaste(_ attachment: PendingAttachment, text: String) async -> String? {
        guard !stagedFilesAreSending else { return StagedPasteText.sendingNotice }
        return await attachmentCoordinator.replaceStagedPaste(attachment, with: text)
    }

    @discardableResult
    func reuploadDraftAttachment(_ draftAttachment: ChatDraftAttachment, data: Data) async -> PendingAttachment? {
        await attachmentCoordinator.reuploadDraftAttachment(data: data, draftAttachment: draftAttachment)
    }

    func clearPendingAttachments() {
        attachmentCoordinator.clearPendingAttachments()
    }

    func protectDraftAttachments(for key: ChatDraftKey, restoring records: [ChatDraftAttachment] = []) {
        attachmentCoordinator.protectDraft(key)
        attachmentCoordinator.protectRestoringAttachments(records)
    }

    func deleteDraftAttachmentCopy(named file: String, attachmentID: UUID) async {
        await attachmentCoordinator.deleteDraftCopy(named: file, attachmentID: attachmentID)
    }

    func removePendingAttachment(id: UUID) {
        attachmentCoordinator.removePendingAttachment(id: id)
    }

    func appendPendingAttachments(_ attachments: [PendingAttachment]) {
        attachmentCoordinator.appendPendingAttachments(attachments)
    }

    func setUploadAttachmentError(_ message: String?) {
        attachmentCoordinator.setUploadAttachmentError(message)
    }

    func attachmentImageData(path: String) async -> Data? {
        guard let hermesTurn else { return await attachmentCoordinator.attachmentImageData(path: path) }
        guard let data = try? await hermesTurn.attachmentData(path: path) else { return nil }
        return await ImagePreviewDownsampler.previewDataAsync(
            from: data,
            maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
        ) ?? data
    }

    func hermesAttachmentData(path: String) async throws -> Data {
        guard let hermesTurn else { throw BotFailure.stale }
        return try await hermesTurn.attachmentData(path: path)
    }

    var hermesAttachmentCacheNamespace: String? { hermesTurn?.attachmentCacheNamespace }

    var hermesWorkspace: HermesWorkspaceContext? { hermesTurn?.workspace }

    func transcriptWorkspaceRoot(listedFolder: String?) -> String? {
        guard let hermesTurn else { return nil }
        return hermesTurn.workspace?.cwd ?? listedFolder
    }

    var hermesTurnBase: GitTurnBase? { hermesTurn?.latestTurnBase }

    var hermesWorkspaceFiles: HermesWorkspaceFileClient? { hermesTurn?.workspaceFiles }

    var workspaceFileSearch: FileWorkspaceSearch? {
        guard let hermesTurn, let workspace = hermesTurn.workspace, workspace.isLocal else { return nil }
        return { [weak hermesTurn] query in
            guard let hermesTurn, hermesTurn.workspace == workspace else { throw BotFailure.stale }
            let rows = try await hermesTurn.searchWorkspaceFiles(query, in: workspace)
            guard hermesTurn.workspace == workspace else { throw BotFailure.stale }
            return rows
        }
    }

    var hermesWorkspaceGit: HermesGitClient? {
        hermesTurn?.workspaceGit { [weak self] in self?.isViewingCachedData ?? true }
    }

    func attachmentRawData(path: String) async -> Data? {
        guard let hermesTurn else { return await attachmentCoordinator.attachmentRawData(path: path) }
        return try? await hermesTurn.attachmentData(path: path)
    }

    var attachmentLoadKey: Int? {
        guard let hermesTurn else { return 0 }
        return hermesTurn.attachmentLoadKey
    }

    func transcriptMediaThumbnailData(for reference: TranscriptMediaReference) async -> Data? {
        guard let hermesTurn else { return await attachmentCoordinator.transcriptMediaThumbnailData(for: reference) }
        guard reference.isRasterImageCandidate,
              let data = await hermesTranscriptMediaData(for: reference, from: hermesTurn, whole: false) else { return nil }
        return await ImagePreviewDownsampler.previewDataAsync(
            from: data,
            maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
        ) ?? data
    }

    func transcriptMediaData(for reference: TranscriptMediaReference) async -> Data? {
        guard let hermesTurn else { return await attachmentCoordinator.transcriptMediaData(for: reference) }
        return await hermesTranscriptMediaData(for: reference, from: hermesTurn, whole: true)
    }

    func transcriptHTMLReportData(for reference: TranscriptMediaReference) async throws -> Data {
        guard let hermesTurn else { throw BotFailure.stale }
        switch reference.source {
        case let .localPath(path):
            return try await hermesTurn.attachmentData(path: path, limit: HTMLReport.inlineByteLimit)
        case let .remoteURL(url):
            return try await BotArtifactDownload.data(session: APIClient.sharedPublicMediaSession,
                                                      request: URLRequest(url: url), limit: HTMLReport.inlineByteLimit)
        }
    }

    private func hermesTranscriptMediaData(for reference: TranscriptMediaReference, from turn: HermesChatTurnCoordinator,
                                           whole: Bool) async -> Data? {
        switch reference.source {
        case let .localPath(path): return try? await turn.attachmentData(path: path, whole: whole)
        case let .remoteURL(url): return try? await client.remoteTranscriptMediaData(from: url)
        }
    }

    func loadMessages(modelContext: ModelContext? = nil, usesInitialPrefetch: Bool = false) async {
        if let hermesTurn {
            if let modelContext { hermesCache = modelContext }
            showCachedHermesTranscriptBeforeAttach(hermesTurn)
            await loadHermesSession(hermesTurn, unasked: usesInitialPrefetch)
            return
        }
        guard let sessionID else {
            errorMessage = String(localized: "The server did not provide a session ID.")
            return
        }

        let prefetchedSession = takeInitialSessionPrefetch(usable: usesInitialPrefetch)

        resetPendingStreamingContentBuffers()
        latestServerLoadHadAssistantResponseAfterLatestUser = false
        let streamLoadPreparation = streamCoordinator.prepareForSessionLoad()
        isLoading = true
        errorMessage = nil
        cacheErrorMessage = nil
        lastError = nil
        defer { isLoading = false }

        let previousMessages = messages
        let previousMessagesOffset = messagesOffset
        let usesPrimedInitialCache = hasPrimedInitialCachedMessages && !previousMessages.isEmpty
        hasPrimedInitialCachedMessages = false
        let cacheFirstPlaceholder: [ChatMessage]
        if previousMessages.isEmpty, let modelContext {
            cacheFirstPlaceholder = renderCachedMessagesBeforeReload(
                sessionID: sessionID,
                modelContext: modelContext
            )
        } else if usesPrimedInitialCache {
            cacheFirstPlaceholder = previousMessages
        } else {
            cacheFirstPlaceholder = []
        }
        let renderedCacheFirst = !cacheFirstPlaceholder.isEmpty

        do {
            let response: SessionResponse
            if let prefetchedSession {
                response = try await withTaskCancellationHandler {
                    try await prefetchedSession.value.session
                } onCancel: {
                    prefetchedSession.cancel()
                }
            } else {
                response = try await Self.requestNewestTranscriptWindow(client: client, sessionID: sessionID)
            }
            let session = response.session
            let loadedMessages = session?.messages ?? []
            let loadedActiveStreamID = session?.activeStreamId?.trimmingCharacters(in: .whitespacesAndNewlines)
            var reloadedMessages = loadedMessages
            if let modelContext {
                do {
                    let cachedMessages = try CacheStore.cachedMessages(
                        serverURL: server,
                        sessionID: sessionID,
                        in: modelContext,
                        limit: Self.messagePageLimit
                    )
                    reloadedMessages = Self.mergingLoadedMessages(
                        loadedMessages,
                        withLocalOptimisticMessages: cachedMessages
                    )
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }
            if streamCoordinator.shouldPreserveLocalOptimisticMessages(
                for: streamLoadPreparation,
                loadedActiveStreamID: loadedActiveStreamID
            ) {
                reloadedMessages = Self.mergingLoadedMessages(
                    reloadedMessages,
                    withLocalOptimisticMessages: previousMessages,
                    knownMessageIDsBeforeLoad: Set(previousMessages.compactMap(\.messageId))
                )
            }
            applyCompressionAnchorMetadata(from: session)
            applyReloadedMessages(
                reloadedMessages,
                from: session,
                previousMessages: previousMessages,
                previousMessagesOffset: previousMessagesOffset
            )
            if renderedCacheFirst {
                transcriptRelayoutScrollToken += 1
            }
            latestServerLoadHadAssistantResponseAfterLatestUser = Self.hasAssistantResponseAfterLatestUser(
                in: messages
            )
            responseCompletionNeedsTranscriptRefresh = false
            isViewingCachedData = false
            contextWindowSnapshot = ContextWindowSnapshot(
                contextLength: session?.contextLength,
                thresholdTokens: session?.thresholdTokens,
                lastPromptTokens: session?.lastPromptTokens,
                inputTokens: session?.inputTokens,
                outputTokens: session?.outputTokens,
                estimatedCost: session?.estimatedCost
            )
            if let modelContext {
                do {
                    try CacheStore.cacheMessages(messages, serverURL: server, sessionID: sessionID, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }
            if let title = session?.title {
                displayTitle = Self.displayTitle(from: title)
            }
            setCompletedToolCallGroups(ToolCallGroup.groups(
                persistedToolCalls: session?.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            ))
            completedReasoningGroups = []
            liveToolCalls = []
            liveReasoningText = ""
            pinnedLocalNotices = []
            toolCallAnchorMessageID = nil
            reasoningAnchorMessageID = nil
            attachmentCoordinator.removeAllLocalPreviews()
            streamCoordinator.reconcileSessionLoad(
                loadedActiveStreamID: loadedActiveStreamID,
                preparation: streamLoadPreparation,
                usedCacheFallback: false,
                runStartedAt: Self.activeRunStartDate(
                    pendingStartedAt: session?.pendingStartedAt,
                    messages: messages
                )
            )
        } catch {
            lastError = error
            latestServerLoadHadAssistantResponseAfterLatestUser = false
            if CacheFallbackPolicy.shouldUseCache(for: error), let modelContext {
                do {
                    let cachedMessages = try CacheStore.cachedMessages(
                        serverURL: server,
                        sessionID: sessionID,
                        in: modelContext,
                        limit: Self.messagePageLimit
                    )
                    if !cachedMessages.isEmpty {
                        clearCompressionAnchorMetadata()
                        messages = cachedMessages
                        transcriptRevision &+= 1
                        latestServerLoadHadAssistantResponseAfterLatestUser = Self.hasAssistantResponseAfterLatestUser(
                            in: messages
                        )
                        responseCompletionNeedsTranscriptRefresh = false
                        messagesOffset = 0
                        hasOlderMessages = false
                        isViewingCachedData = true
                        contextWindowSnapshot = nil
                        errorMessage = nil
                        setCompletedToolCallGroups([])
                        completedReasoningGroups = []
                        liveToolCalls = []
                        liveReasoningText = ""
                        pinnedLocalNotices = []
                        toolCallAnchorMessageID = nil
                        reasoningAnchorMessageID = nil
                        streamingAssistantMessageID = nil
                        attachmentCoordinator.removeAllLocalPreviews()
                        streamCoordinator.reconcileSessionLoad(
                            loadedActiveStreamID: nil,
                            preparation: streamLoadPreparation,
                            usedCacheFallback: true
                        )
                    } else {
                        if renderedCacheFirst {
                            revertCacheFirstPlaceholder(
                                cacheFirstPlaceholder,
                                to: previousMessages,
                                previousMessagesOffset: previousMessagesOffset
                            )
                        }
                        isViewingCachedData = false
                        errorMessage = error.localizedDescription
                    }
                } catch {
                    if renderedCacheFirst {
                        revertCacheFirstPlaceholder(
                            cacheFirstPlaceholder,
                            to: previousMessages,
                            previousMessagesOffset: previousMessagesOffset
                        )
                    }
                    cacheErrorMessage = error.localizedDescription
                    isViewingCachedData = false
                    errorMessage = lastError?.localizedDescription
                }
            } else {
                if renderedCacheFirst {
                    revertCacheFirstPlaceholder(
                        cacheFirstPlaceholder,
                        to: previousMessages,
                        previousMessagesOffset: previousMessagesOffset
                    )
                }
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func prepareInitialMessageLoad(modelContext: ModelContext) {
        if let hermesTurn {
            hermesCache = modelContext
            return showCachedHermesTranscriptBeforeAttach(hermesTurn)
        }
        guard let sessionID else { return }

        if initialSessionPrefetch == nil {
            initialSessionPrefetch = InitialSessionPrefetch(
                activeStreamID: activeStreamID,
                task: Task { [client] in
                    let session = try await Self.requestNewestTranscriptWindow(client: client, sessionID: sessionID)
                    return InitialSessionPrefetch.Response(session: session)
                }
            )
        }

        isLoading = true
        guard messages.isEmpty else { return }

        let cachedMessages = renderCachedMessagesBeforeReload(
            sessionID: sessionID,
            modelContext: modelContext
        )
        hasPrimedInitialCachedMessages = !cachedMessages.isEmpty
    }

    @discardableResult
    private func takeInitialSessionPrefetch(usable: Bool) -> Task<InitialSessionPrefetch.Response, Error>? {
        guard let prefetch = initialSessionPrefetch else { return nil }
        initialSessionPrefetch = nil
        guard usable, prefetch.activeStreamID == activeStreamID else {
            prefetch.task.cancel()
            return nil
        }
        return prefetch.task
    }

    private struct InitialSessionPrefetch {
        struct Response: @unchecked Sendable {
            let session: SessionResponse
        }

        let activeStreamID: String?
        let task: Task<Response, Error>
    }

    private static func requestNewestTranscriptWindow(
        client: APIClient,
        sessionID: String
    ) async throws -> SessionResponse {
        try await client.session(
            id: sessionID,
            includeMessages: true,
            messageLimit: messagePageLimit,
            expandRenderable: true
        )
    }

    private func renderCachedMessagesBeforeReload(
        sessionID: String,
        modelContext: ModelContext
    ) -> [ChatMessage] {
        let signpost = performanceSignposter.beginInterval("Transcript Apply")
        defer {
            performanceSignposter.endInterval("Transcript Apply", signpost, "messages=\(self.messages.count, privacy: .public)")
        }

        let cachedMessages: [ChatMessage]
        do {
            cachedMessages = try CacheStore.cachedMessages(
                serverURL: server,
                sessionID: sessionID,
                in: modelContext,
                limit: Self.messagePageLimit
            )
        } catch {
            return []
        }

        guard !cachedMessages.isEmpty else { return [] }

        messages = cachedMessages
        transcriptRevision &+= 1
        messagesOffset = 0
        hasOlderMessages = false
        isViewingCachedData = false
        return cachedMessages
    }

    private func revertCacheFirstPlaceholder(
        _ placeholder: [ChatMessage],
        to previousMessages: [ChatMessage],
        previousMessagesOffset: Int
    ) {
        guard messages == placeholder else { return }
        messages = previousMessages
        transcriptRevision &+= 1
        messagesOffset = previousMessagesOffset
        hasOlderMessages = previousMessagesOffset > 0
    }

    @discardableResult
    func loadOlderMessages(modelContext: ModelContext? = nil) async -> Bool {
        if let hermesTurn {
            guard !isLoadingOlderMessages, hasOlderMessages else { return false }
            isLoadingOlderMessages = true
            defer { isLoadingOlderMessages = false }
            return await hermesTurn.loadOlderHistory()
        }
        guard let sessionID else {
            errorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard !isLoadingOlderMessages, hasOlderMessages else {
            return false
        }

        guard messagesOffset > 0 else {
            hasOlderMessages = false
            return false
        }

        resetPendingStreamingContentBuffers()
        let messageBefore = messagesOffset
        isLoadingOlderMessages = true
        errorMessage = nil
        cacheErrorMessage = nil
        lastError = nil
        defer { isLoadingOlderMessages = false }

        do {
            let response = try await client.session(
                id: sessionID,
                includeMessages: true,
                messageLimit: Self.messagePageLimit,
                messageBefore: messageBefore
            )
            guard let session = response.session else {
                hasOlderMessages = false
                return false
            }

            let olderMessages = session.messages ?? []
            let mergedMessages = Self.prependingOlderMessages(olderMessages, to: messages)
            let didAddMessages = mergedMessages.count > messages.count
            applyCompressionAnchorMetadata(from: session)
            messages = mergedMessages
            transcriptRevision &+= 1
            latestServerLoadHadAssistantResponseAfterLatestUser = Self.hasAssistantResponseAfterLatestUser(
                in: messages
            )
            responseCompletionNeedsTranscriptRefresh = false
            updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
            isViewingCachedData = false
            contextWindowSnapshot = ContextWindowSnapshot(
                contextLength: session.contextLength,
                thresholdTokens: session.thresholdTokens,
                lastPromptTokens: session.lastPromptTokens,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                estimatedCost: session.estimatedCost
            )
            if let title = session.title {
                displayTitle = Self.displayTitle(from: title)
            }
            currentWorkspace = session.workspace ?? currentWorkspace
            currentModel = session.model ?? currentModel
            currentModelProvider = session.modelProvider ?? currentModelProvider
            currentProfile = session.profile ?? currentProfile
            setCompletedToolCallGroups(ToolCallGroup.groups(
                persistedToolCalls: session.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            ))
            completedReasoningGroups = []

            if let modelContext {
                do {
                    try CacheStore.cacheMessages(messages, serverURL: server, sessionID: sessionID, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }

            return didAddMessages
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
            return false
        }
    }

    func actionContext(for message: ChatMessage, visibleIndex: Int) -> MessageActionContext? {
        guard !message.isSteerMessage else { return nil }
        return MessageActionContext(
            message: message,
            visibleIndex: visibleIndex,
            messagesOffset: messagesOffset,
            offersHistoryActions: hermesTurn.map { $0.policy.offersHistoryActions && hermesRewindableMessageIDs.contains(message.id) }
                ?? true,
            offersFork: hermesTurn.map { $0.policy.offersHistoryActions && message.rowID != nil } ?? true
        )
    }

    func transcriptMessagesAfter(_ context: MessageActionContext) -> Int {
        guard let index = displayedTranscriptMessages.firstIndex(where: { $0.message.id == context.messageID }) else { return 0 }
        return max(0, displayedTranscriptMessages.count - 1 - index)
    }

    nonisolated static func precedingUserMessageText(
        in messages: [ChatMessage],
        beforeVisibleIndex visibleIndex: Int
    ) -> String? {
        guard !messages.isEmpty, visibleIndex > 0 else { return nil }

        let startIndex = min(visibleIndex - 1, messages.count - 1)
        guard startIndex >= 0 else { return nil }

        for index in stride(from: startIndex, through: 0, by: -1) {
            let message = messages[index]
            guard message.role == "user", !message.isSteerMessage else { continue }

            let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                return text
            }
        }

        return nil
    }

    nonisolated static func mergingLoadedMessages(
        _ loadedMessages: [ChatMessage],
        withLocalOptimisticMessages candidateMessages: [ChatMessage],
        knownMessageIDsBeforeLoad: Set<String>? = nil
    ) -> [ChatMessage] {
        let localUserMessages = candidateMessages.filter { candidateMessage in
            isLocalOptimisticUserMessage(candidateMessage)
                && !loadedMessagesContainEquivalentUserMessage(
                    loadedMessages,
                    localMessage: candidateMessage,
                    knownMessageIDsBeforeLoad: knownMessageIDsBeforeLoad
                )
        }

        guard !localUserMessages.isEmpty else {
            return loadedMessages
        }

        return localUserMessages.reduce(into: loadedMessages) { partialMessages, localMessage in
            insertLocalOptimisticMessage(localMessage, into: &partialMessages)
        }
    }

    nonisolated private static func prependingOlderMessages(
        _ olderMessages: [ChatMessage],
        to currentMessages: [ChatMessage]
    ) -> [ChatMessage] {
        guard !olderMessages.isEmpty else { return currentMessages }

        var seenIDs = Set(currentMessages.map(\.id))
        var uniqueOlderMessages: [ChatMessage] = []
        uniqueOlderMessages.reserveCapacity(olderMessages.count)

        for message in olderMessages {
            guard seenIDs.insert(message.id).inserted else { continue }
            uniqueOlderMessages.append(message)
        }

        return uniqueOlderMessages + currentMessages
    }

    private func applyReloadedMessages(
        _ reloadedMessages: [ChatMessage],
        from session: SessionDetail?,
        previousMessages: [ChatMessage],
        previousMessagesOffset: Int
    ) {
        let signpost = performanceSignposter.beginInterval("Transcript Apply")
        defer {
            performanceSignposter.endInterval("Transcript Apply", signpost, "messages=\(self.messages.count, privacy: .public)")
        }

        let reloadedMessagesOffset = Self.resolvedMessagesOffset(
            from: session,
            loadedMessageCount: reloadedMessages.count
        )

        if let expandedMessages = Self.mergingReloadedMessages(
            reloadedMessages,
            intoCurrentMessages: previousMessages,
            currentMessagesOffset: previousMessagesOffset,
            reloadedMessagesOffset: reloadedMessagesOffset
        ) {
            messages = expandedMessages
            transcriptRevision &+= 1
            messagesOffset = previousMessagesOffset
            hasOlderMessages = previousMessagesOffset > 0
            return
        }

        if let trimmedMessages = Self.trimmingReloadedMessages(
            reloadedMessages,
            toPreserveCurrentMessages: previousMessages,
            currentMessagesOffset: previousMessagesOffset,
            reloadedMessagesOffset: reloadedMessagesOffset
        ) {
            messages = trimmedMessages
            transcriptRevision &+= 1
            messagesOffset = previousMessagesOffset
            hasOlderMessages = previousMessagesOffset > 0 || session?.messagesTruncated == true
            return
        }

        messages = reloadedMessages
        transcriptRevision &+= 1
        updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
    }

    nonisolated private static func mergingReloadedMessages(
        _ reloadedMessages: [ChatMessage],
        intoCurrentMessages currentMessages: [ChatMessage],
        currentMessagesOffset: Int,
        reloadedMessagesOffset: Int
    ) -> [ChatMessage]? {
        guard currentMessagesOffset < reloadedMessagesOffset,
              let firstReloadedMessage = reloadedMessages.first,
              let overlapIndex = currentMessages.firstIndex(where: { $0.id == firstReloadedMessage.id }),
              overlapIndex > currentMessages.startIndex
        else {
            return nil
        }

        return Array(currentMessages[..<overlapIndex]) + reloadedMessages
    }

    nonisolated private static func trimmingReloadedMessages(
        _ reloadedMessages: [ChatMessage],
        toPreserveCurrentMessages currentMessages: [ChatMessage],
        currentMessagesOffset: Int,
        reloadedMessagesOffset: Int
    ) -> [ChatMessage]? {
        guard reloadedMessagesOffset < currentMessagesOffset,
              let firstCurrentMessage = currentMessages.first
        else {
            return nil
        }

        let overlapIndex = currentMessagesOffset - reloadedMessagesOffset
        guard reloadedMessages.indices.contains(overlapIndex),
              reloadedMessages[overlapIndex].id == firstCurrentMessage.id
        else {
            return nil
        }

        return Array(reloadedMessages[overlapIndex...])
    }

    private func updateOlderMessagePagination(from session: SessionDetail?, loadedMessageCount: Int) {
        let resolvedOffset = Self.resolvedMessagesOffset(
            from: session,
            loadedMessageCount: loadedMessageCount
        )
        messagesOffset = resolvedOffset
        hasOlderMessages = resolvedOffset > 0 || session?.messagesTruncated == true
    }

    nonisolated private static func resolvedMessagesOffset(
        from session: SessionDetail?,
        loadedMessageCount: Int
    ) -> Int {
        if let messagesOffset = session?.messagesOffset {
            return max(0, messagesOffset)
        }

        guard session?.messagesTruncated == true,
              let messageCount = session?.messageCount
        else {
            return 0
        }

        return max(0, messageCount - loadedMessageCount)
    }

    nonisolated static func mergingLoadedMessages(
        _ loadedMessages: [ChatMessage],
        withActiveStreamSnapshot snapshot: ActiveChatStreamSnapshot
    ) -> ActiveStreamMessageMerge {
        guard !snapshot.messages.isEmpty else {
            return ActiveStreamMessageMerge(
                messages: loadedMessages,
                streamingAssistantMessageID: latestAssistantMessageID(in: loadedMessages),
                usedSnapshotMessagesOffset: false
            )
        }

        guard let snapshotAssistantMessageID = snapshot.streamingAssistantMessageID,
              let snapshotAssistant = snapshot.messages.first(where: { $0.messageId == snapshotAssistantMessageID })
        else {
            if loadedMessages.isEmpty {
                return ActiveStreamMessageMerge(
                    messages: snapshot.messages,
                    streamingAssistantMessageID: latestAssistantMessageID(in: snapshot.messages),
                    usedSnapshotMessagesOffset: true
                )
            }

            return ActiveStreamMessageMerge(
                messages: loadedMessages,
                streamingAssistantMessageID: latestAssistantMessageID(in: loadedMessages),
                usedSnapshotMessagesOffset: false
            )
        }

        guard !loadedMessages.isEmpty else {
            return ActiveStreamMessageMerge(
                messages: snapshot.messages,
                streamingAssistantMessageID: snapshotAssistant.messageId,
                usedSnapshotMessagesOffset: true
            )
        }

        var mergedMessages = loadedMessages
        let latestUserIndex = mergedMessages.lastIndex(where: TranscriptTurnClassifier.isTurnBoundary)
        let assistantSearchRange: Range<Int>
        if let latestUserIndex {
            assistantSearchRange = mergedMessages.index(after: latestUserIndex)..<mergedMessages.endIndex
        } else {
            assistantSearchRange = mergedMessages.startIndex..<mergedMessages.endIndex
        }

        if let assistantIndex = assistantSearchRange.reversed().first(where: { mergedMessages[$0].role == "assistant" }) {
            let loadedAssistant = mergedMessages[assistantIndex]
            mergedMessages[assistantIndex] = ChatMessage(
                role: loadedAssistant.role,
                content: reconciledActiveStreamContent(
                    loadedContent: loadedAssistant.content,
                    snapshotContent: snapshotAssistant.content
                ),
                timestamp: loadedAssistant.timestamp ?? snapshotAssistant.timestamp,
                messageId: loadedAssistant.messageId ?? snapshotAssistant.messageId,
                name: loadedAssistant.name ?? snapshotAssistant.name,
                toolCallId: loadedAssistant.toolCallId ?? snapshotAssistant.toolCallId,
                toolUseId: loadedAssistant.toolUseId ?? snapshotAssistant.toolUseId,
                toolCalls: loadedAssistant.toolCalls ?? snapshotAssistant.toolCalls,
                contentParts: loadedAssistant.contentParts ?? snapshotAssistant.contentParts,
                reasoning: loadedAssistant.reasoning ?? snapshotAssistant.reasoning,
                attachments: loadedAssistant.attachments ?? snapshotAssistant.attachments,
                turnTps: loadedAssistant.turnTps ?? snapshotAssistant.turnTps
            )
            return ActiveStreamMessageMerge(
                messages: mergedMessages,
                streamingAssistantMessageID: mergedMessages[assistantIndex].messageId,
                usedSnapshotMessagesOffset: false
            )
        }

        if !messagesContainEquivalentMessage(mergedMessages, candidate: snapshotAssistant) {
            mergedMessages.append(snapshotAssistant)
        }

        return ActiveStreamMessageMerge(
            messages: mergedMessages,
            streamingAssistantMessageID: snapshotAssistant.messageId,
            usedSnapshotMessagesOffset: false
        )
    }

    nonisolated private static func reconciledActiveStreamContent(
        loadedContent: String?,
        snapshotContent: String?
    ) -> String? {
        let loaded = loadedContent ?? ""
        let snapshot = snapshotContent ?? ""

        if loaded.isEmpty {
            return snapshotContent
        }

        if snapshot.isEmpty {
            return loadedContent
        }

        if loaded.hasPrefix(snapshot) {
            return loadedContent
        }

        if snapshot.hasPrefix(loaded) {
            return snapshotContent
        }

        return loadedContent
    }

    nonisolated private static func messagesContainEquivalentMessage(
        _ messages: [ChatMessage],
        candidate: ChatMessage
    ) -> Bool {
        if let candidateID = candidate.messageId,
           messages.contains(where: { $0.messageId == candidateID }) {
            return true
        }

        let candidateContent = candidate.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidateContent?.isEmpty == false else { return false }

        return messages.contains { message in
            message.role == candidate.role &&
                message.content?.trimmingCharacters(in: .whitespacesAndNewlines) == candidateContent
        }
    }

    nonisolated private static func activeRunStartDate(
        pendingStartedAt: Double?,
        messages: [ChatMessage]
    ) -> Date? {
        if let pendingStartedAt, pendingStartedAt > 0 {
            return Date(timeIntervalSince1970: pendingStartedAt)
        }

        guard let latestUserTimestamp = messages
            .last(where: TranscriptTurnClassifier.isTurnBoundary)?
            .timestamp,
            latestUserTimestamp > 0
        else {
            return nil
        }

        return Date(timeIntervalSince1970: latestUserTimestamp)
    }

    nonisolated static func hasAssistantResponseAfterLatestUser(in messages: [ChatMessage]) -> Bool {
        guard !messages.isEmpty else { return false }

        let searchRange: Range<Int>
        if let latestUserIndex = messages.lastIndex(where: TranscriptTurnClassifier.isTurnBoundary) {
            searchRange = messages.index(after: latestUserIndex)..<messages.endIndex
        } else {
            searchRange = messages.startIndex..<messages.endIndex
        }

        return messages[searchRange].contains { message in
            guard message.role == "assistant" else { return false }
            return hasAssistantResponseContent(message)
        }
    }

    nonisolated private static func hasAssistantResponseContent(_ message: ChatMessage) -> Bool {
        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        if message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        if message.toolCalls?.isEmpty == false {
            return true
        }

        return hasAssistantContentParts(message.contentParts)
    }

    nonisolated private static func hasAssistantContentParts(_ parts: [JSONValue]?) -> Bool {
        guard let parts else { return false }

        return parts.contains { part in
            switch part {
            case .string(let value):
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case .object(let object):
                if case .string(let type)? = object["type"] {
                    switch type {
                    case "tool_use", "thinking", "reasoning", "redacted_thinking":
                        return true
                    case "text":
                        if case .string(let text)? = object["text"] {
                            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        }
                    default:
                        break
                    }
                }

                return false
            case .number, .bool, .array, .null:
                return false
            }
        }
    }

    nonisolated private static func remappedAnchorMessageID(
        _ anchorMessageID: String?,
        from snapshotStreamingAssistantMessageID: String?,
        to restoredStreamingAssistantMessageID: String?
    ) -> String? {
        guard let anchorMessageID,
              anchorMessageID == snapshotStreamingAssistantMessageID,
              snapshotStreamingAssistantMessageID != restoredStreamingAssistantMessageID
        else {
            return anchorMessageID
        }

        return restoredStreamingAssistantMessageID ?? anchorMessageID
    }

    nonisolated private static func isLocalOptimisticUserMessage(_ message: ChatMessage) -> Bool {
        message.role == "user" && message.messageId?.hasPrefix("local-") == true
    }

    nonisolated private static func loadedMessagesContainEquivalentUserMessage(
        _ loadedMessages: [ChatMessage],
        localMessage: ChatMessage,
        knownMessageIDsBeforeLoad: Set<String>?
    ) -> Bool {
        let localContent = normalizedUserMessageContent(localMessage.content)
        let localAttachmentKeys = attachmentKeys(for: localMessage)

        return loadedMessages.contains { loadedMessage in
            guard loadedMessage.role == "user" else { return false }

            if loadedMessage.messageId == localMessage.messageId {
                return true
            }

            guard loadedMessage.isSteerMessage == localMessage.isSteerMessage else {
                return false
            }

            guard normalizedUserMessageContent(loadedMessage.content) == localContent else {
                return false
            }

            if !localAttachmentKeys.isEmpty {
                let loadedAttachmentKeys = attachmentKeys(for: loadedMessage)
                guard !loadedAttachmentKeys.isEmpty,
                      loadedAttachmentKeys.isSuperset(of: localAttachmentKeys)
                else {
                    return false
                }
            }

            if let loadedMessageID = loadedMessage.messageId,
               let knownMessageIDsBeforeLoad,
               knownMessageIDsBeforeLoad.contains(loadedMessageID) {
                return false
            }

            guard let localTimestamp = localMessage.timestamp,
                  let loadedTimestamp = loadedMessage.timestamp
            else {
                return true
            }

            return loadedTimestamp >= localTimestamp - 300
        }
    }

    nonisolated private static func insertLocalOptimisticMessage(
        _ localMessage: ChatMessage,
        into messages: inout [ChatMessage]
    ) {
        if !messages.contains(where: { $0.role == "user" }),
           let firstAssistantIndex = messages.firstIndex(where: { $0.role == "assistant" }) {
            messages.insert(localMessage, at: firstAssistantIndex)
            return
        }

        guard let localTimestamp = localMessage.timestamp,
              let insertionIndex = messages.firstIndex(where: { loadedMessage in
                  guard let loadedTimestamp = loadedMessage.timestamp else { return false }
                  return loadedTimestamp > localTimestamp
              })
        else {
            messages.append(localMessage)
            return
        }

        messages.insert(localMessage, at: insertionIndex)
    }

    nonisolated private static func latestAssistantMessageID(in messages: [ChatMessage]) -> String? {
        messages.last(where: { $0.role == "assistant" })?.messageId
    }

    nonisolated private static func latestAssistantAnchorID(in messages: [ChatMessage], messageOffset: Int?) -> String? {
        guard let index = messages.lastIndex(where: { $0.role == "assistant" }) else {
            return nil
        }

        return TranscriptTurnClassifier.anchorID(
            for: messages[index],
            at: index,
            messageOffset: messageOffset
        )
    }

    nonisolated static func deduplicatedReasoningTexts(_ texts: [String]) -> [String] {
        var seen: Set<String> = []

        return texts.compactMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let key = trimmed
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    nonisolated private static func normalizedUserMessageContent(_ content: String?) -> String {
        guard let content else { return "" }

        let withoutAttachments = MessageAttachment
            .contentWithoutAttachedFilesMarker(in: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let steerStripped = ChatMessage.strippedSteerText(from: withoutAttachments)
            ?? withoutAttachments
        return steerStripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func attachmentKeys(for message: ChatMessage) -> Set<String> {
        Set((message.attachments ?? []).compactMap(\.identityKey))
    }

    func sendMessage(_ draft: String, modelContext: ModelContext? = nil) async -> Bool {
        await send(draft, modelContext: modelContext) == .started
    }

    func send(_ draft: String, isPlainText: Bool = false, modelContext: ModelContext? = nil) async -> ChatSendOutcome {
        let waitingOwner = isPlainText ? waitingSendGeneration : nil
        guard !isViewingCachedData else {
            if let waitingOwner, offersWaitingSend, let hermesTurn {
                return await holdForConnection(draft, on: hermesTurn, owner: waitingOwner)
            }
            if !isCachedCopyProvisional { sendErrorMessage = String(localized: "Reconnect to the server to send a message.") }
            return .kept
        }

        guard !isClearingConversation else {
            sendErrorMessage = String(localized: "Wait for the conversation to finish clearing.")
            return .kept
        }

        if let hermesTurn {
            return await submitHermesPrompt(draft, mode: .send, to: hermesTurn, waitingOwner: waitingOwner)
        }

        guard !isCompressionRotated else {
            sendErrorMessage = compressionRejectionMessage
            if compressionContinuation == nil, let id = compressionContinuationID, let sessionID {
                isStartingChat = true
                defer { isStartingChat = false }
                await resolveCompressionContinuation(id: id, from: sessionID,
                                                     profile: Self.compressionProfile(currentProfile),
                                                     generation: chatSendGeneration)
            }
            return .kept
        }

        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !attachmentCoordinator.pendingAttachments.isEmpty else { return .kept }

        guard let sessionID else {
            sendErrorMessage = String(localized: "The server did not provide a session ID.")
            return .kept
        }

        let localMessageID = "local-\(UUID().uuidString)"
        let attachmentPreparation = attachmentCoordinator.prepareForSend(localMessageID: localMessageID)
        let messageForAPI = attachmentPreparation.chatMessageText(draft: message)
        let displayText = message.isEmpty ? messageForAPI : message

        let didStart = await performChatSend(
            sessionID: sessionID,
            localMessageID: localMessageID,
            displayContent: displayText,
            messageForAPI: messageForAPI,
            messageAttachments: attachmentPreparation.messageAttachments,
            apiPayloads: attachmentPreparation.apiPayloads,
            attachmentsToRestoreOnFailure: attachmentPreparation.attachments,
            modelContext: modelContext,
            allowsCompressionContinuation: true
        )
        if didStart {
            for attachment in attachmentPreparation.attachments {
                guard let fileName = attachment.draftFileName else { continue }
                await attachmentCoordinator.deleteDraftCopy(named: fileName, attachmentID: attachment.id)
            }
        }
        return didStart ? .started : .kept
    }

    func compressionContinuationForNavigation(
        from sourceKey: ChatDraftKey, isCurrent: @MainActor () -> Bool,
        prepareDraftForHandoff: @MainActor () -> Void = {}
    ) async -> SessionSummary? {
        guard !didHandOffCompressionDraft,
              let continuation = compressionContinuation, let id = continuation.sessionId,
              let sessionID, sourceKey == .session(server: server, sessionID: sessionID),
              isCurrent(), !Task.isCancelled else { return nil }
        let generation = chatSendGeneration
        let targetKey = ChatDraftKey.session(server: server, sessionID: id)
        let existing = await drafts.draft(for: targetKey)
        guard generation == chatSendGeneration, compressionContinuation?.sessionId == id,
              isCurrent(), !Task.isCancelled,
              Self.compressionProfile(continuation.profile) == Self.compressionProfile(currentProfile) else { return nil }
        guard existing?.isEmpty != false else { return nil }
        prepareDraftForHandoff()
        drafts.moveDraft(from: sourceKey, to: targetKey)
        didHandOffCompressionDraft = true
        lastError = nil
        sendErrorMessage = nil
        return continuation
    }

    var isHermesSession: Bool { hermesTurn != nil }

    @ObservationIgnored private var isSubmittingHermesPrompt = false
    private(set) var isHermesSubmissionUncertain = false
    @ObservationIgnored private(set) var submissionMarkRelease: Task<Void, Never>?
    private(set) var waitingSend: HermesWaitingSend?
    @ObservationIgnored private var waitingSendGeneration = 0
    @ObservationIgnored private var isHoldingWaitingSend = false
    @ObservationIgnored private var waitingSendDeadline: Task<Void, Never>?
    @ObservationIgnored private let waitingSendClock: HermesWaitingSendClock
    @ObservationIgnored var onWaitingSendReturned: ((String, HermesWaitingSend.Return) -> Void)?

    var hermesDraftKey: ChatDraftKey? { hermesTurn?.currentDraftKey }
    @ObservationIgnored var onHermesDraftKeyChange: ((ChatDraftKey) -> Void)?

    var stopNeedsConfirmation: Bool { hermesTurn?.stopNeedsConfirmation == true }

    var hermesRequests: HermesChatRequests? { hermesTurn?.requests }

    var isWaitingForUser: Bool { hermesRequests?.isWaiting == true }

    var isCompacting: Bool { hermesTurn?.isCompacting == true }

    var hermesHostNotices: HermesHostNotices? { hermesTurn?.hostNotices }

    var hermesNeedsSignIn: Bool { hermesTurn?.needsSignIn == true }

    var hermesSideTasks: HermesChatSideTasks? { hermesTurn?.sideTasks }

    var showsGoalControls: Bool {
        hasActivatedGoalCommand || hermesSideTasks?.automations.isEmpty == false
    }

    func confirmHermesAutomation(_ control: BotSessionControl) async {
        guard let sideTasks = hermesSideTasks else { return }
        do {
            try await sideTasks.confirmAutomation(control)
        } catch let error where error is HermesChatTurnCoordinator.NotSent || HermesChatSideTasks.isReaped(error) {
            sendErrorMessage = String(localized: "Reconnect to the server to manage goals.")
        } catch BotFailure.stale {
            sendErrorMessage = BotFailure.stale.localizedDescription
        } catch let refusal as BotSettingFailure {
            sendErrorMessage = refusal.localizedDescription
        } catch {
            sendErrorMessage = BotSettingFailure.unknownOutcome.localizedDescription
        }
    }

    var hermesActivity: HermesChatActivity? { hermesTurn?.activity }

    func newHermesSessionChat(profile: String) -> HermesSessionChat? {
        hermesTurn.map { HermesSessionChat(server: $0.engine.server, connection: $0.engine.connection,
                                           target: .new(profile: profile)) }
    }

    private func hermesSessionList(searching query: String) -> SlashCommandExecutionResult {
        guard let hermesTurn else { return .unsupported(friendlyMessage: SlashCommandExecutor.unsupportedMessage(for: "sessions")) }
        return .openedHermesSessionList(HermesSessionListEntry(server: hermesTurn.engine.server, connection: hermesTurn.engine.connection,
                                                               profile: hermesTurn.settings.profile, query: query))
    }

    private func resumeHermesSession(named rawName: String) async -> SlashCommandExecutionResult {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hermesTurn, !name.isEmpty else { return hermesSessionList(searching: name) }
        let engine = hermesTurn.engine
        let profile = hermesTurn.settings.profile
        let byID = HermesSessionDestination(server: engine.server, profile: profile, key: name)
        if case .found(let session)? = try? await HermesSessionLookup.resolve(byID, on: engine.wire), session.hermes?.isBotChat != true,
           let chat = session.hermesChat(on: engine.server, connection: engine.connection, listedIn: profile) {
            return session.sessionId == engine.storedKey ? .executed(message: nil) : .openedHermesSession(chat)
        }
        let results = (try? await engine.wire.searchSessions(query: name, profile: profile)) ?? []
        let titled = results.filter { $0.row.title?.compare(name, options: .caseInsensitive) == .orderedSame }
        guard titled.count == 1, let match = titled.first?.row, !match.isBotChat else { return hermesSessionList(searching: name) }
        if match.id == engine.storedKey { return .executed(message: nil) }
        return .openedHermesSession(HermesSessionChat(server: engine.server, connection: engine.connection,
                                                      target: .session(profile: match.profile ?? profile, key: match.id),
                                                      parentKey: match.parentSessionID, lineageRoot: match.lineageRootID))
    }

    func handOffHermesDraft(to chat: HermesSessionChat) async {
        guard let key = hermesDraftKey else { return }
        let target = chat.target.draftKey(server: chat.server, connectionID: chat.connection.id, lineageRoot: chat.lineageRoot)
        guard await drafts.draft(for: target) == nil else { return }
        drafts.moveDraft(from: key, to: target)
    }

    func adoptHermesSegmentDraft() async {
        guard let hermesTurn, let segment = hermesTurn.segmentDraftKey else { return }
        let key = hermesTurn.currentDraftKey
        guard await drafts.draft(for: key) == nil, await drafts.draft(for: segment) != nil else { return }
        drafts.moveDraft(from: segment, to: key)
    }

    var hermesRequestIdentity: String? {
        hermesTurn.map { String(localized: "\($0.engine.target.profile) on \($0.engine.connection.name)") }
    }

    private func loadHermesSession(_ hermes: HermesChatTurnCoordinator, unasked: Bool) async {
        isLoading = messages.isEmpty
        if !(unasked && hermes.resumeWasRefused) { errorMessage = nil }
        defer { isLoading = false }
        let retriesHistory = hermes.hasHistoryFailure
        if unasked { await hermes.reconnectIfNeeded(modelContext: nil) } else { await hermes.activate() }
        if retriesHistory { await hermes.retryHistoryIfFailed() }
    }

    private func submitHermesPrompt(
        _ draft: String,
        mode: BotPromptMode,
        to hermes: HermesChatTurnCoordinator,
        shown: String? = nil,
        waitingOwner: Int? = nil,
        delivering: Int? = nil
    ) async -> ChatSendOutcome {
        guard delivering != nil || !isHoldingWaitingSend else {
            sendErrorMessage = String(localized: "Reconnect to the server to send a message.")
            return .kept
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = mode.startsTurn && shown == nil && delivering == nil ? attachmentCoordinator.pendingAttachments : []
        guard !text.isEmpty || !files.isEmpty, !isHermesSubmissionUncertain else { return .kept }
        sendErrorMessage = nil
        lastError = nil
        if !files.isEmpty { attachmentCoordinator.setUploadAttachmentError(nil) }
        let promptID = "local-\(UUID().uuidString)"
        let prompt = ChatMessage(
            role: "user", content: shown ?? text, timestamp: Date().timeIntervalSince1970, messageId: promptID,
            attachments: files.isEmpty ? nil : files.map {
                MessageAttachment(name: $0.name, mime: $0.mime, size: $0.size, isImage: $0.isImage)
            }
        )
        attachmentCoordinator.keepLocalPreviews(of: files, forMessageID: promptID)
        if mode == .send {
            isStartingChat = true
            archiveLiveActivityForNewTurn()
            messages.append(prompt)
        }
        defer { if mode == .send { isStartingChat = false } }

        var marked = false
        let outcome: BotPromptOutcome
        do {
            isSubmittingHermesPrompt = true
            defer { isSubmittingHermesPrompt = false }
            outcome = try await hermes.submit(text, mode: mode, attachments: attachmentCoordinator.outgoingAttachments(files)) {
                [drafts] in
                let key = hermes.currentDraftKey
                _ = await drafts.draft(for: key)
                drafts.setBotSubmissionUncertain(true, for: key)
                marked = true
                try await drafts.flush()
            } stillCurrent: { [weak self] in
                guard let delivering else { return }
                guard self?.waitingSendGoes(delivering) == true else { throw BotFailure.stale }
            }
        } catch {
            rollbackOptimisticMessage(id: promptID)
            if let notSent = error as? HermesChatTurnCoordinator.NotSent {
                if marked { drafts.setBotSubmissionUncertain(false, for: hermes.currentDraftKey) }
                if let delivering, HermesWaitingSend.waitsForConnection(notSent) || !waitingSendGoes(delivering) {
                    return .waiting
                }
                if mode == .send, files.isEmpty, HermesWaitingSend.waitsForConnection(notSent),
                   let waitingOwner, !hermes.needsSignIn {
                    return await holdForConnection(draft, on: hermes, owner: waitingOwner)
                }
                if notSent.duringUpload {
                    sendErrorMessage = Self.uploadFailureMessage(notSent.underlying)
                } else if notSent.followedReplacedChat {
                    sendErrorMessage = Self.notSentToReplacedChat
                } else {
                    sendErrorMessage = String(localized: "Reconnect to the server to send a message.")
                }
            } else if error is HermesFenceRefusal {
                drafts.setBotSubmissionUncertain(false, for: hermes.currentDraftKey)
                sendErrorMessage = String(localized: "The reply moved on before your message reached it. Send it again.")
            } else if mode.definitelyRejected(error) {
                drafts.setBotSubmissionUncertain(false, for: hermes.currentDraftKey)
                sendErrorMessage = String(localized: "Hermes did not accept this message. Your draft is still here.")
            } else {
                sendErrorMessage = String(localized: "Hermes did not confirm this message. Your draft is still here.")
                holdForLostAnswer(hermes)
            }
            return .kept
        }
        if outcome != .unknown { drafts.setBotSubmissionUncertain(false, for: hermes.currentDraftKey) }

        switch outcome {
        case .started:
            if mode != .send { messages.append(prompt) }
        case .voiceStopped:
            rollbackOptimisticMessage(id: promptID)
        case .followUpQueued, .redirectQueued:
            rollbackOptimisticMessage(id: promptID)
        case .guidanceQueued:
            appendLocalSteerEcho(text)
            showSteeringConfirmation(String(localized: "Steering hint delivered."))
        case .redirected:
            flushPendingStreamingContent()
            streamingAssistantMessageID = nil
            messages.append(prompt)
        case .rejected:
            rollbackOptimisticMessage(id: promptID)
            if mode == .steer {
                steerFailureMessage = String(localized: "Couldn't steer")
            } else {
                sendErrorMessage = String(localized: "Hermes did not accept this message. Your draft is still here.")
            }
            return .kept
        case .unknown:
            rollbackOptimisticMessage(id: promptID)
            sendErrorMessage = String(localized: "Hermes did not confirm this message. Your draft is still here.")
            holdForLostAnswer(hermes)
            return .kept
        }
        await attachmentCoordinator.consumeSentAttachments(files)
        return .started
    }

    private func holdForLostAnswer(_ hermes: HermesChatTurnCoordinator) {
        isHermesSubmissionUncertain = true
        hermes.recoverAfterLostAnswer()
    }

    func restoreSubmissionMark(_ uncertain: Bool) {
        guard uncertain, let hermesTurn, hermesTurn.engine.connectionState != .connected else { return }
        isHermesSubmissionUncertain = true
    }

    private func releaseSubmissionMark() {
        guard let key = hermesDraftKey, !isSubmittingHermesPrompt else { return }
        isHermesSubmissionUncertain = false
        submissionMarkRelease = Task { [weak self, drafts] in
            guard await drafts.draft(for: key)?.botSubmissionUncertain == true,
                  self?.isSubmittingHermesPrompt == false else { return }
            drafts.setBotSubmissionUncertain(false, for: key)
        }
    }

    var offersWaitingSend: Bool {
        guard let hermesTurn else { return false }
        return showsOfflineCache && waitingSend == nil && activeStreamID == nil && !isHermesSubmissionUncertain
            && !hermesTurn.needsSignIn && attachmentCoordinator.pendingAttachments.isEmpty
    }

    var waitingSendMessage: ChatMessage? {
        guard let waitingSend, waitingSend.delivery == nil else { return nil }
        return ChatMessage(role: "user", content: waitingSend.send.text, timestamp: nil, messageId: "hermes-waiting-send")
    }

    private func holdForConnection(_ draft: String, on hermes: HermesChatTurnCoordinator, owner: Int) async -> ChatSendOutcome {
        let notHeld = String(localized: "Reconnect to the server to send a message.")
        guard waitingSend == nil, !isHoldingWaitingSend else {
            sendErrorMessage = notHeld
            return .kept
        }
        isHoldingWaitingSend = true
        defer { isHoldingWaitingSend = false }
        let send = ChatDraft.WaitingSend(text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                         createdAt: waitingSendClock.now())
        let key = hermes.currentDraftKey
        drafts.holdWaitingSend(send, replacing: draft, for: key)
        let isSaved = (try? await drafts.flush()) != nil
        guard isSaved, waitingSendGeneration == owner else {
            onWaitingSendReturned?(drafts.returnWaitingSend(for: key)?.text ?? send.text, .notSent)
            sendErrorMessage = notHeld
            return .kept
        }
        waitingSendGeneration += 1
        waitingSend = HermesWaitingSend(send: send, key: key)
        sendErrorMessage = nil
        let remaining = HermesWaitingSend.lifetime - waitingSendClock.now().timeIntervalSince(send.createdAt)
        waitingSendDeadline?.cancel()
        waitingSendDeadline = Task { [weak self, sleep = waitingSendClock.sleep] in
            do { try await sleep(remaining) } catch { return }
            guard let self, self.waitingSend?.send == send, self.waitingSend?.delivery == nil else { return }
            self.returnWaitingSend(.expired)
        }
        deliverWaitingSendIfReady()
        return .waiting
    }

    private func waitingSendGoes(_ generation: Int) -> Bool {
        waitingSendGeneration == generation && waitingSend?.hasExpired(at: waitingSendClock.now()) == false
    }

    func cancelWaitingSend() {
        guard let waitingSend, waitingSend.delivery == nil else { return }
        returnWaitingSend(.cancelled)
    }

    func leaveWaitingSend() {
        waitingSendGeneration += 1
        guard var waiting = waitingSend else { return }
        if waiting.delivery == nil {
            returnWaitingSend(.left)
        } else {
            waiting.delivery = .left
            waitingSend = waiting
        }
    }

    private func pauseWaitingSend() {
        guard var waiting = waitingSend, waiting.delivery == .sending else { return }
        waitingSendGeneration += 1
        waiting.delivery = .paused
        waitingSend = waiting
    }

    private func returnWaitingSend(_ reason: HermesWaitingSend.Return) {
        guard let waiting = waitingSend else { return }
        waitingSend = nil
        waitingSendGeneration += 1
        waitingSendDeadline?.cancel(); waitingSendDeadline = nil
        let draft = drafts.returnWaitingSend(for: hermesDraftKey ?? waiting.key)
        onWaitingSendReturned?(draft?.text ?? waiting.send.text, reason)
    }

    private func deliverWaitingSendIfReady() {
        guard var waiting = waitingSend, waiting.delivery == nil, let hermes = hermesTurn,
              hermes.engine.connectionState == .connected, !isViewingCachedData, !isHermesSubmissionUncertain,
              waiting.triedAttach != hermes.engine.generation else { return }
        guard !waiting.hasExpired(at: waitingSendClock.now()) else { return returnWaitingSend(.expired) }
        guard waiting.key == hermes.currentDraftKey else { return returnWaitingSend(.notSent) }
        let generation = waitingSendGeneration
        waiting.delivery = .sending
        waiting.triedAttach = hermes.engine.generation
        waitingSend = waiting
        Task { [weak self] in
            guard let self else { return }
            let outcome = self.waitingSendGoes(generation)
                ? await self.submitHermesPrompt(waiting.send.text, mode: .send, to: hermes, delivering: generation)
                : .waiting
            self.finishWaitingSend(outcome)
        }
    }

    private func finishWaitingSend(_ outcome: ChatSendOutcome) {
        guard var waiting = waitingSend else { return }
        switch outcome {
        case .started:
            waitingSend = nil
            waitingSendGeneration += 1
            waitingSendDeadline?.cancel(); waitingSendDeadline = nil
            drafts.removeWaitingSend(for: hermesDraftKey ?? waiting.key)
        case .waiting where waiting.hasExpired(at: waitingSendClock.now()):
            returnWaitingSend(.expired)
        case .waiting where waiting.delivery == .left:
            returnWaitingSend(.left)
        case .waiting:
            waiting.delivery = nil
            waitingSend = waiting
            deliverWaitingSendIfReady()
        case .kept:
            returnWaitingSend(.notSent)
        }
    }

    private static func uploadFailureMessage(_ error: Error) -> String {
        if error is CancellationError || error as? BotFailure == .stale {
            return String(localized: "Upload cancelled. Your message and attachments are still here.")
        }
        if let error = error as? BotAttachmentFailure { return error.localizedDescription }
        return String(localized: "Couldn't upload the attachments. Your message and attachments are still here.")
    }

    func cancelAttachmentUpload() {
        hermesTurn?.cancelAttachmentUpload()
    }

    private func submitHermesStreamingMessage(
        _ draft: String,
        behavior: StreamingSendBehavior,
        to hermes: HermesChatTurnCoordinator
    ) async -> SlashCommandExecutionResult {
        let mode: BotPromptMode
        switch behavior == .steer && !attachmentCoordinator.pendingAttachments.isEmpty ? .queue : behavior {
        case .steer: mode = activeStreamID == nil ? .send : .steer
        case .queue: mode = activeStreamID == nil ? .send : .queue
        case .interrupt: mode = activeStreamID == nil ? .send : .redirect
        }
        return await submitHermesPrompt(draft, mode: mode, to: hermes) == .started ? .executed(message: nil) : .notDelivered
    }

    @discardableResult
    func sendVoiceNote(audioData: Data, filename: String, modelContext: ModelContext? = nil) async -> Bool {
        guard hermesTurn == nil else { return false }
        guard !isSendingVoiceNote, !isStartingChat else { return false }
        guard !isViewingCachedData else {
            setUploadAttachmentError(String(localized: "Reconnect to the server to send a voice note."))
            return false
        }
        guard !audioData.isEmpty else { return false }
        guard audioData.count <= PendingAttachment.maximumUploadBytes else {
            setUploadAttachmentError(PendingAttachment.uploadTooLargeMessage(filename: filename))
            return false
        }
        guard let sessionID else {
            setUploadAttachmentError(String(localized: "The server did not provide a session ID."))
            return false
        }

        isSendingVoiceNote = true
        setUploadAttachmentError(nil)
        sendErrorMessage = nil
        lastError = nil
        defer { isSendingVoiceNote = false }

        let transcript: String
        do {
            let response = try await client.transcribeAudio(data: audioData, filename: filename)
            if let serverError = response.error?.trimmingCharacters(in: .whitespacesAndNewlines),
               !serverError.isEmpty {
                setUploadAttachmentError(serverError)
                return false
            }
            let text = (response.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setUploadAttachmentError(String(localized: "Couldn't transcribe that voice note. Try recording again."))
                return false
            }
            transcript = text
        } catch {
            lastError = error
            setUploadAttachmentError(error.localizedDescription)
            return false
        }

        guard let pending = await attachmentCoordinator.uploadStandaloneAttachment(
            data: audioData,
            filename: filename
        ) else {
            return false
        }

        let messageAttachment = MessageAttachment(
            name: pending.name,
            path: pending.path,
            mime: pending.mime,
            size: pending.size,
            isImage: pending.isImage
        )
        let localMessageID = "local-\(UUID().uuidString)"
        return await performChatSend(
            sessionID: sessionID,
            localMessageID: localMessageID,
            displayContent: transcript,
            messageForAPI: transcript,
            messageAttachments: [messageAttachment],
            apiPayloads: [pending.toJSONValue()],
            attachmentsToRestoreOnFailure: [],
            modelContext: modelContext
        )
    }

    private func performChatSend(
        sessionID: String,
        localMessageID: String,
        displayContent: String,
        messageForAPI: String,
        messageAttachments: [MessageAttachment],
        apiPayloads: [JSONValue]?,
        attachmentsToRestoreOnFailure: [PendingAttachment],
        modelContext: ModelContext?,
        allowsCompressionContinuation: Bool = false
    ) async -> Bool {
        guard !isCompressionRotated else {
            restorePendingAttachments(attachmentsToRestoreOnFailure)
            sendErrorMessage = compressionRejectionMessage
            return false
        }
        chatSendGeneration += 1
        let generation = chatSendGeneration
        let profile = Self.compressionProfile(currentProfile)
        isStartingChat = true
        sendErrorMessage = nil
        lastError = nil
        archiveLiveActivityForNewTurn()
        streamCoordinator.prepareForNewResponse()
        responseCompletionNeedsTranscriptRefresh = false
        defer { if generation == chatSendGeneration { isStartingChat = false } }

        let optimisticMessage = ChatMessage(
            role: "user",
            content: displayContent,
            timestamp: Date().timeIntervalSince1970,
            messageId: localMessageID,
            attachments: messageAttachments.isEmpty ? nil : messageAttachments
        )
        messages.append(optimisticMessage)

        cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)

        do {
            #if DEBUG
            if let failure = APIError.takeLaunchArgumentStaleRuntimeFailure() { throw failure }
            #endif
            let explicitModelPick = explicitModelPickForChatStart()
            let sentAt = Date()
            let response = try await client.startChat(
                sessionID: sessionID,
                message: messageForAPI,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick,
                attachments: apiPayloads
            )

            guard let streamID = response.streamId else {
                rollbackOptimisticMessage(id: localMessageID)
                cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
                restorePendingAttachments(attachmentsToRestoreOnFailure)
                if allowsCompressionContinuation {
                    drafts.retainRejectedAttachments(attachmentsToRestoreOnFailure.map(ChatDraftAttachment.init(pending:)),
                                                     for: .session(server: server, sessionID: sessionID))
                }
                guard generation == chatSendGeneration, !Task.isCancelled else { return false }
                sendErrorMessage = response.error ?? String(localized: "The server did not return a stream ID.")
                return false
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            streamCoordinator.start(
                streamID: streamID,
                runStartedAt: response.runStartedAt(sentAt: sentAt)
            )
            return true
        } catch {
            rollbackOptimisticMessage(id: localMessageID)
            cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
            restorePendingAttachments(attachmentsToRestoreOnFailure)
            if allowsCompressionContinuation {
                drafts.retainRejectedAttachments(attachmentsToRestoreOnFailure.map(ChatDraftAttachment.init(pending:)),
                                                 for: .session(server: server, sessionID: sessionID))
            }
            if case .http(409, _) = error as? APIError,
               (error as? APIError)?.serverCode == "session_rotated" {
                isCompressionRotated = true
                compressionRejectionMessage = error.localizedDescription
            }
            guard generation == chatSendGeneration, !Task.isCancelled else { return false }
            if allowsCompressionContinuation,
               let rotation = (error as? APIError)?.sessionRotation,
               rotation.continuationSessionID != sessionID {
                lastError = error
                sendErrorMessage = error.localizedDescription
                compressionContinuationID = rotation.continuationSessionID
                await resolveCompressionContinuation(id: rotation.continuationSessionID, from: sessionID,
                                                     profile: profile, generation: generation)
                return false
            }
            if let apiError = error as? APIError, apiError.serverCode != "session_rotated",
               let streamID = apiError.activeStreamID {
                await loadMessages(modelContext: modelContext)
                guard generation == chatSendGeneration, !Task.isCancelled else { return false }
                _ = restoreActiveStreamSnapshotIfAvailable(streamID: streamID)
                streamingAssistantMessageID = TranscriptTurnClassifier
                    .currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset)
                    .first
                streamCoordinator.start(streamID: streamID)
                return false
            }
            lastError = error
            sendErrorMessage = error.localizedDescription
            sendErrorRuntimeStale = (error as? APIError)?.agentRuntimeStale
            return false
        }
    }

    private func resolveCompressionContinuation(id: String, from sessionID: String,
                                                profile: String, generation: Int) async {
        do {
            let response = try await client.session(id: id, includeMessages: false, messageLimit: nil)
            guard generation == chatSendGeneration, !Task.isCancelled else { return }
            if let detail = response.session,
               let id = detail.sessionId, id != sessionID,
               APIError.SessionRotation(continuationSessionID: id) != nil,
               Self.compressionProfile(detail.profile) == profile,
               Self.compressionProfile(currentProfile) == profile {
                compressionContinuation = SessionSummary(from: detail)
            }
        } catch {
            guard generation == chatSendGeneration, !Task.isCancelled else { return }
            lastError = error
            sendErrorMessage = error.localizedDescription
        }
    }

    private static func compressionProfile(_ profile: String?) -> String {
        nonEmpty(profile) ?? "default"
    }

    func submitGoal(args rawArgs: String, modelContext: ModelContext? = nil) async -> Bool {
        guard !isViewingCachedData else {
            goalErrorMessage = String(localized: "Reconnect to the server to manage goals.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        let args = rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !args.isEmpty else { return false }

        if let hermesTurn {
            return await submitHermesGoal(args, to: hermesTurn)
        }

        guard let sessionID else {
            goalErrorMessage = String(localized: "The server did not provide a session ID.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        guard activeStreamID == nil else {
            goalErrorMessage = String(localized: "Wait for the current response to finish before changing goals.")
            sendErrorMessage = goalErrorMessage
            return false
        }

        isSubmittingGoal = true
        goalErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isSubmittingGoal = false }

        do {
            let response = try await client.submitGoal(
                sessionID: sessionID,
                args: args,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName
            )

            currentGoal = response.goal

            if response.ok == false || response.action?.lowercased() == "error" {
                goalErrorMessage = response.displayMessage ?? String(localized: "Goal request failed.")
                sendErrorMessage = goalErrorMessage
                return false
            }

            hasActivatedGoalCommand = true

            guard response.kickoffPromptText != nil else {
                if let message = response.displayMessage {
                    appendLocalNoticeMessage(message)
                }
                return true
            }

            return await attachGoalKickoffStream(
                noticeMessage: response.displayMessage,
                modelContext: modelContext
            )
        } catch {
            lastError = error
            goalErrorMessage = error.localizedDescription
            sendErrorMessage = goalErrorMessage
            return false
        }
    }

    private func submitHermesGoal(_ args: String, to hermes: HermesChatTurnCoordinator) async -> Bool {
        func fail(_ message: String) -> Bool {
            goalErrorMessage = message
            sendErrorMessage = message
            return false
        }
        guard activeStreamID == nil || HermesChatSideTasks.isGoalControl(args) else {
            return fail(String(localized: "Wait for the current response to finish before changing goals."))
        }
        guard !isHermesSubmissionUncertain else {
            return fail(String(localized: "Wait for Hermes to confirm the last message before changing goals."))
        }

        isSubmittingGoal = true
        goalErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isSubmittingGoal = false }

        let reply: HermesGoalReply
        do {
            reply = try await hermes.sideTasks.dispatchGoal(args)
        } catch let error where error is HermesChatTurnCoordinator.NotSent || HermesChatSideTasks.isReaped(error) {
            return fail(String(localized: "Reconnect to the server to manage goals."))
        } catch let refusal as BotSettingFailure {
            return fail(refusal.localizedDescription)
        } catch {
            return fail(String(localized: "Hermes did not confirm the goal command. Check the goal before trying again."))
        }

        hasActivatedGoalCommand = true
        func notify(_ text: String) {
            if activeStreamID == nil { appendLocalNoticeMessage(text) } else { pinLocalNoticeMessage(text) }
        }
        switch reply {
        case .exec(let output):
            notify(output)
            return true
        case .send(let notice, let message, let display):
            if let notice { notify(notice) }
            let mode: BotPromptMode = activeStreamID == nil ? .send : .queue
            guard await submitHermesPrompt(message, mode: mode, to: hermes, shown: display ?? message) == .started else {
                return fail(String(localized: "Hermes did not confirm the goal command. Check the goal before trying again."))
            }
            return true
        }
    }

    private func attachGoalKickoffStream(noticeMessage: String?, modelContext: ModelContext?) async -> Bool {
        await loadMessages(modelContext: modelContext)

        if let errorMessage {
            goalErrorMessage = errorMessage
            sendErrorMessage = errorMessage
            return false
        }

        guard let streamID = activeStreamID else {
            if let noticeMessage {
                appendLocalNoticeMessage(noticeMessage)
            }
            return true
        }

        if streamingAssistantMessageID == nil {
            restoreActiveStreamSnapshotIfAvailable(streamID: streamID)
        }
        if streamingAssistantMessageID == nil {
            streamingAssistantMessageID = Self.latestAssistantMessageID(in: messages)
        }
        if let noticeMessage {
            pinLocalNoticeMessage(noticeMessage)
        }

        streamCoordinator.start(streamID: streamID)
        return true
    }

    private func rollbackOptimisticMessage(id: String) {
        messages.removeAll { $0.messageId == id }
        attachmentCoordinator.removeLocalPreviews(messageID: id)
    }

    private func restorePendingAttachments(_ attachments: [PendingAttachment]) {
        attachmentCoordinator.restorePendingAttachments(attachments)
    }

    private func cacheCurrentMessages(sessionID: String, modelContext: ModelContext?) {
        guard let modelContext else { return }

        do {
            try CacheStore.cacheMessages(messages, serverURL: server, sessionID: sessionID, in: modelContext)
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    func cacheCompletedResponse(modelContext: ModelContext) {
        guard let sessionID else { return }
        cacheCurrentMessages(sessionID: sessionID, modelContext: modelContext)
    }

    func clearTranscript() {
        cancelPendingStreamingScrollTrigger()
        resetPendingStreamingContentBuffers()
        clearCompressionAnchorMetadata()
        messages = []
        transcriptRevision &+= 1
        messagesOffset = 0
        hasOlderMessages = false
        setCompletedToolCallGroups([])
        completedReasoningGroups = []
        liveToolCalls = []
        liveReasoningText = ""
        pinnedLocalNotices = []
        dismissSteeringConfirmation()
        streamingAssistantMessageID = nil
        toolCallAnchorMessageID = nil
        reasoningAnchorMessageID = nil
        attachmentCoordinator.removeAllLocalPreviews()
        sendErrorMessage = nil
    }

    func executeSlashCommand(
        _ command: SlashCommand,
        args: String = "",
        modelContext: ModelContext? = nil
    ) async -> SlashCommandExecutionResult {
        switch command.handler {
        case .clientSide(let action):
            switch action {
            case .clear:
                return await clearConversationFromSlashCommand(modelContext: modelContext)
            case .stop:
                await cancelActiveStream()
                return .executed(message: nil)
            case .new:
                if let hermesTurn {
                    return newHermesSessionChat(profile: hermesTurn.settings.profile).map { .openedHermesSession($0) } ?? .notDelivered
                }
                return await createSessionFromSlashCommand()
            case .help:
                return .executed(message: Self.slashCommandHelpText)
            case .sessions:
                return hermesSessionList(searching: "")
            case .resume:
                return await resumeHermesSession(named: args)
            }
        case .serverSide(let action):
            return await executeServerSideSlashCommand(action, args: args)
        case .unsupported:
            return .unsupported(friendlyMessage: SlashCommandExecutor.unsupportedMessage(for: command.name))
        }
    }

    private func executeServerSideSlashCommand(
        _ action: ServerSideAction,
        args: String
    ) async -> SlashCommandExecutionResult {
        switch action {
        case .model:
            return await switchModelFromSlashCommand(args)
        case .workspace:
            return await switchWorkspaceFromSlashCommand(args)
        case .reasoning:
            return await switchReasoningFromSlashCommand(args)
        case .title:
            return await renameSessionFromSlashCommand(args)
        case .personality:
            return await setPersonalityFromSlashCommand(args)
        case .skills:
            return await searchSkillsFromSlashCommand(args)
        case .branch:
            return await branchSessionFromSlashCommand(args)
        case .undo:
            return await undoLastExchangeFromSlashCommand()
        case .retry:
            return await retryLastTurnFromSlashCommand()
        case .compress:
            return await compressSessionFromSlashCommand(args)
        case .queue:
            return await queueMessageFromSlashCommand(args)
        case .steer:
            return await steerResponseFromSlashCommand(args)
        case .interrupt:
            return await interruptResponseFromSlashCommand(args)
        case .status:
            return .executed(message: statusMessageFromSlashCommand())
        case .btw:
            return await askBtwFromSlashCommand(args)
        case .background:
            return await startBackgroundFromSlashCommand(args)
        case .goal:
            return await submitGoalFromSlashCommand(args)
        case .yolo:
            return await toggleHermesApprovalBypassFromSlashCommand()
        case .rollback:
            return await rollbackFromSlashCommand(args)
        }
    }

    func submitStreamingMessage(
        _ draft: String,
        behavior: StreamingSendBehavior
    ) async -> SlashCommandExecutionResult {
        if let hermesTurn {
            return await submitHermesStreamingMessage(draft, behavior: behavior, to: hermesTurn)
        }
        switch behavior {
        case .steer:
            return await steerResponseFromSlashCommand(draft)
        case .interrupt:
            return await interruptResponseFromSlashCommand(draft)
        case .queue:
            return await queueMessageFromSlashCommand(draft)
        }
    }

    private func queueMessageFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /queue <message>"))
        }

        guard activeStreamID != nil else {
            let sent = await sendMessage(message)
            return sent ? .executed(message: nil) : .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the queued message."))
        }

        enqueueQueuedSlashMessage(message, attachments: attachmentCoordinator.consumePendingAttachments())
        return .executed(message: nil)
    }

    private func steerResponseFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /steer <message>"))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard let steeredStreamID = activeStreamID else {
            let sent = await sendMessage(message)
            return sent ? .executed(message: nil) : .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the steering message."))
        }

        let steeredAttachments = attachmentCoordinator.pendingAttachments
        let steerText = PendingAttachment.steerMessageText(draft: message, attachments: steeredAttachments)

        switch await client.steerChat(sessionID: sessionID, text: steerText) {
        case .delivered:
            appendLocalSteerEcho(steerText)
            showSteeringConfirmation(String(localized: "Steering hint delivered."))
            takeSteeredAttachments(steeredAttachments)
            for attachment in steeredAttachments {
                guard let fileName = attachment.draftFileName else { continue }
                await attachmentCoordinator.deleteDraftCopy(named: fileName, attachmentID: attachment.id)
            }
            return .executed(message: nil)
        case .refused(let transportError):
            if let transportError {
                lastError = transportError
            }
            if activeStreamID == steeredStreamID {
                let title = String(localized: "Couldn't steer")
                steerFailureMessage = transportError.map { "\(title)\n\($0.localizedDescription)" } ?? title
                return .notDelivered
            }
            if let transportError {
                sendErrorMessage = transportError.localizedDescription
                return .notDelivered
            }
            enqueueQueuedSlashMessage(message, attachments: takeSteeredAttachments(steeredAttachments), atFront: true)
        case .serverQueued:
            enqueueQueuedSlashMessage(message, attachments: takeSteeredAttachments(steeredAttachments))
        case .runEnded:
            enqueueQueuedSlashMessage(message, attachments: takeSteeredAttachments(steeredAttachments), atFront: true)
            await streamCoordinator.refreshTranscriptIfCompleted(streamID: steeredStreamID)
        }

        drainQueuedSlashMessageIfIdle()
        return .executed(message: nil)
    }

    @discardableResult
    private func takeSteeredAttachments(_ steered: [PendingAttachment]) -> [PendingAttachment] {
        guard !steered.isEmpty else { return [] }
        let steeredIDs = Set(steered.map(\.id))
        let staged = attachmentCoordinator.pendingAttachments
        attachmentCoordinator.replacePendingAttachments(staged.filter { !steeredIDs.contains($0.id) })
        return staged.filter { steeredIDs.contains($0.id) }
    }

    func clearSteerFailure() {
        guard steerFailureMessage != nil else { return }
        steerFailureMessage = nil
    }

    func clearComposerErrors() {
        if sendErrorMessage != nil, errorUnserved == nil, sendErrorRuntimeStale == nil { sendErrorMessage = nil }
        if composerConfigurationErrorMessage != nil { composerConfigurationErrorMessage = nil }
        hermesSettings?.controls.clearError()
    }

    private func appendLocalSteerEcho(_ text: String) {
        messages.append(ChatMessage(
            role: "user",
            content: text,
            timestamp: Date().timeIntervalSince1970,
            messageId: "local-steer-\(UUID().uuidString)",
            displayKind: ChatMessage.steerDisplayKind
        ))
    }

    private func interruptResponseFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /interrupt <message>"))
        }
        if let hermesTurn {
            return await submitHermesStreamingMessage(message, behavior: .interrupt, to: hermesTurn)
        }

        guard activeStreamID != nil else {
            let sent = await sendMessage(message)
            return sent ? .executed(message: nil) : .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the interrupt message."))
        }

        enqueueQueuedSlashMessage(message, attachments: attachmentCoordinator.consumePendingAttachments(), atFront: true)
        let handOverCount = queueHandOverCount
        await cancelActiveStream()

        guard queueHandOverCount == handOverCount else { return .executed(message: nil) }

        if activeStreamID != nil {
            return .executed(message: Self.interruptQueuedFallbackNotice)
        }

        return .executed(message: String(localized: "Interrupted the current response and queued your message to send next."))
    }

    private static var interruptQueuedFallbackNotice: String {
        String(localized: "Could not stop the current response yet, so the interrupt message was queued for the next turn.")
    }

    private func statusMessageFromSlashCommand() -> String {
        let running = activeStreamID == nil ? String(localized: "No") : String(localized: "Yes")
        let queued = queuedSlashMessages.count
        let backgroundTasks = backgroundPromptsByTaskID.count
        let profile = selectedProfileName ?? currentProfile ?? "default"
        let workspace = currentWorkspace ?? String(localized: "Unknown")
        let model = currentModel ?? String(localized: "Unknown")
        let provider = currentModelProvider ?? providerFromModel(model) ?? String(localized: "Unknown")
        let messageCount = messages.filter { $0.role != "tool" }.count
        let tokens = statusTokenLine()

        return String(localized: """
        Session status:

        - Session ID: \(sessionID ?? "Unknown")
        - Title: \(displayTitle)
        - Model: \(model)
        - Provider: \(provider)
        - Profile: \(profile)
        - Workspace: \(workspace)
        - Agent running: \(running)
        - Queued messages: \(queued)
        - Background tasks: \(backgroundTasks)
        - Messages loaded: \(messageCount)
        - Tokens: \(tokens)
        """)
    }

    private func askBtwFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let question = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /btw <question>"))
        }

        if let hermesTurn {
            return await askHermesBtw(question, sideTasks: hermesTurn.sideTasks)
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to ask a side question."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "/btw is available for WebUI sessions only."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before using /btw."))
        }

        guard activeBtwStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current /btw answer to finish first."))
        }

        do {
            let response = try await client.startBtw(sessionID: sessionID, question: question)
            if let error = response.error, !error.isEmpty {
                return .unsupported(friendlyMessage: error)
            }

            guard let streamID = response.streamId, !streamID.isEmpty else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return a /btw stream."))
            }

            startBtwStream(streamID: streamID, question: question)
            return .executed(message: nil)
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func startBackgroundFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let prompt = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /background <prompt>"))
        }

        if let hermesTurn {
            return await startHermesBackground(prompt, sideTasks: hermesTurn.sideTasks)
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to start a background task."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "/background is available for WebUI sessions only."))
        }

        do {
            let response = try await client.startBackground(sessionID: sessionID, prompt: prompt)
            if let error = response.error, !error.isEmpty {
                return .unsupported(friendlyMessage: error)
            }

            guard let taskID = response.taskId, !taskID.isEmpty else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return a background task."))
            }

            backgroundPromptsByTaskID[taskID] = prompt
            startBackgroundPollingIfNeeded(parentSessionID: sessionID)
            return .executed(message: String(localized: "Background task started. I'll add the result here when it completes."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func askHermesBtw(_ question: String, sideTasks: HermesChatSideTasks) async -> SlashCommandExecutionResult {
        guard !sideTasks.isAsking else {
            return notDelivered(String(localized: "Wait for the current /btw answer to finish first."))
        }
        do {
            try await sideTasks.ask(question)
        } catch HermesSideTaskFailure.notSent {
            return notDelivered(String(localized: "Reconnect to the server to ask a side question."))
        } catch {
            return notDelivered(String(localized: "Hermes did not accept this side question."))
        }
        return .executed(message: nil)
    }

    private func startHermesBackground(_ prompt: String, sideTasks: HermesChatSideTasks) async -> SlashCommandExecutionResult {
        do {
            try await sideTasks.startBackground(prompt)
        } catch HermesSideTaskFailure.notSent {
            return notDelivered(String(localized: "Reconnect to the server to start a background task."))
        } catch HermesSideTaskFailure.refused {
            return notDelivered(String(localized: "Hermes did not start the background task."))
        } catch {
            return notDelivered(String(localized: "Hermes did not confirm the background task. It may still run, but its result can't show here."))
        }
        return .executed(message: nil)
    }

    private func notDelivered(_ message: String) -> SlashCommandExecutionResult {
        sendErrorMessage = message
        return .notDelivered
    }

    var hermesSlashCommands: HermesSlashCommands? { hermesTurn?.slashCommands }

    var composerAgentCommands: [AgentCommand] {
        hermesTurn?.slashCommands.commands ?? agentCommands
    }

    var composerSkillSuggestions: [SkillSlashSuggestion] {
        hermesTurn?.slashCommands.catalog.skills ?? skillSlashSuggestions
    }

    func runHermesSlashCommand(_ draft: String, modelContext: ModelContext? = nil) async -> SlashCommandExecutionResult? {
        guard let hermesTurn, let invocation = BotSlashCatalog.invocation(in: draft) else { return nil }
        return await runHermesSlashCommand(invocation, line: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                           on: hermesTurn, followsAlias: false, modelContext: modelContext)
    }

    private func runHermesSlashCommand(
        _ invocation: BotSlashInvocation,
        line: String,
        on hermes: HermesChatTurnCoordinator,
        followsAlias: Bool,
        modelContext: ModelContext?
    ) async -> SlashCommandExecutionResult? {
        let slash = hermes.slashCommands
        let name = invocation.name
        let reply: HermesSlashReply
        do {
            switch slash.route(name) {
            case .refused(let message):
                return .unsupported(friendlyMessage: message)
            case .appOwned(let command):
                return await executeSlashCommand(command, args: invocation.argument, modelContext: modelContext)
            case .skill(let skill):
                reply = try await slash.expand(skill, argument: invocation.argument, typed: line)
            case .text where !followsAlias:
                return nil
            case .host, .text:
                guard !line.contains(where: \.isNewline) else {
                    return notDelivered(String(localized: "Run /\(name) on one line."))
                }
                reply = try await slash.run(line)
            }
        } catch {
            return hermesSlashFailure(error, name: name)
        }

        switch reply {
        case .notice(let text):
            notifyLocally(text)
            return .executed(message: nil)
        case .send(let message, let shown, let notice):
            if let notice { notifyLocally(notice) }
            let mode: BotPromptMode = activeStreamID == nil ? .send : .queue
            return await submitHermesPrompt(message, mode: mode, to: hermes, shown: shown) == .started ? .executed(message: nil) : .notDelivered
        case .prefill(let message, let notice):
            if let notice { notifyLocally(notice) }
            return .prefill(message)
        case .alias(let target):
            let line = invocation.argument.isEmpty ? "/\(target)" : "/\(target) \(invocation.argument)"
            guard !followsAlias, let next = BotSlashCatalog.invocation(in: line) else {
                return notDelivered(String(localized: "/\(name) points to another alias, so Hermex didn't run it."))
            }
            return await runHermesSlashCommand(next, line: line, on: hermes, followsAlias: true, modelContext: modelContext)
        }
    }

    private func hermesSlashFailure(_ error: Error, name: String) -> SlashCommandExecutionResult {
        switch error {
        case let notSent as HermesChatTurnCoordinator.NotSent where notSent.followedReplacedChat:
            return notDelivered(Self.notSentToReplacedChat)
        case is HermesChatTurnCoordinator.NotSent:
            return notDelivered(String(localized: "Reconnect to the server to run /\(name)."))
        case BotSettingFailure.rejected(_, let message):
            guard messages.contains(where: { $0.role == "user" }) else {
                return notDelivered(String(localized: "Send a message first, then run /\(name)."))
            }
            return notDelivered(message)
        case BotFailure.rejected:
            return notDelivered(String(localized: "Hermes did not accept /\(name)."))
        default:
            return notDelivered(String(localized: "Hermes did not confirm /\(name). Check before running it again."))
        }
    }

    private func notifyLocally(_ text: String) {
        if activeStreamID == nil { appendLocalNoticeMessage(text) } else { pinLocalNoticeMessage(text) }
    }

    private func toggleHermesApprovalBypassFromSlashCommand() async -> SlashCommandExecutionResult {
        guard let requests = hermesRequests else {
            return .unsupported(friendlyMessage: SlashCommandExecutor.unsupportedMessage(for: "yolo"))
        }
        if requests.approvalBypass, !requests.mayTurnOffApprovalBypass {
            return notDelivered(String(localized: "This Hermes host approves every command itself, so approvals can't be turned back on from here."))
        }
        sendErrorMessage = nil
        guard let enabled = await requests.toggleApprovalBypass() else {
            return sendErrorMessage == nil
                ? notDelivered(String(localized: "Reconnect to the server to run /\("yolo")."))
                : .notDelivered
        }
        notifyLocally(enabled
                      ? String(localized: "Approvals are skipped in this chat. Run /yolo again to turn them back on.")
                      : String(localized: "Approvals are back on in this chat."))
        return .executed(message: nil)
    }

    private func submitGoalFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let goalArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let didSubmit = await submitGoal(args: goalArgs.isEmpty ? "status" : goalArgs)
        if didSubmit { return .executed(message: nil) }
        if hermesTurn != nil { return .notDelivered }
        return .unsupported(friendlyMessage: goalErrorMessage ?? String(localized: "Could not submit the goal command."))
    }

    private func switchModelFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let requestedModel = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedModel.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /model <id>"))
        }

        if let hermesSettings {
            return await switchHermesModelFromSlashCommand(requestedModel, settings: hermesSettings)
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard canRunConfigurationSlashCommand(String(localized: "change models")) else {
            return .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? String(localized: "Model switching is unavailable."))
        }

        let match = modelOption(matching: requestedModel)

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: currentWorkspace,
                model: match?.id ?? requestedModel,
                modelProvider: match?.providerID
            )

            currentModel = response.session?.model ?? match?.id ?? requestedModel
            currentModelProvider = response.session?.modelProvider ?? match?.providerID ?? currentModelProvider
            currentWorkspace = response.session?.workspace ?? currentWorkspace
            pendingExplicitModelPick = true
            await refreshReasoningEffortGating()
            return .executed(message: nil)
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func switchHermesModelFromSlashCommand(_ requestedModel: String,
                                                   settings: HermesChatSettings) async -> SlashCommandExecutionResult {
        guard let option = settings.model(matching: requestedModel) else {
            return .unsupported(friendlyMessage: String(localized: "This host doesn't offer a model named \(requestedModel)."))
        }
        guard !option.matchesSelection(modelID: selectedModelID, providerID: selectedModelProviderID) else {
            return .executed(message: nil)
        }
        if await settings.select(option) || settings.controls.confirmation != nil { return .executed(message: nil) }
        return .unsupported(friendlyMessage: settings.controls.errorMessage
                            ?? String(localized: "Wait for this chat to connect before changing models."))
    }

    private func switchWorkspaceFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let requestedWorkspace = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedWorkspace.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /workspace <path>"))
        }
        if hermesTurn != nil { return await switchHermesFolderFromSlashCommand(requestedWorkspace) }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard canRunConfigurationSlashCommand(String(localized: "change workspace")) else {
            return .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? String(localized: "Workspace switching is unavailable."))
        }

        let workspace = workspacePath(matching: requestedWorkspace) ?? requestedWorkspace

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.updateSession(
                id: sessionID,
                workspace: workspace,
                model: currentModel,
                modelProvider: currentModelProvider
            )

            currentWorkspace = response.session?.workspace ?? workspace
            currentModel = response.session?.model ?? currentModel
            currentModelProvider = response.session?.modelProvider ?? currentModelProvider
            workspaceSuggestions = workspaceRoots.compactMap(\.path)
            return .executed(message: nil)
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func switchHermesFolderFromSlashCommand(_ path: String) async -> SlashCommandExecutionResult {
        composerConfigurationErrorMessage = nil
        if await selectWorkspacePath(path) || pendingHermesFolder != nil { return .executed(message: nil) }
        guard let refusal = composerConfigurationErrorMessage else { return .executed(message: nil) }
        composerConfigurationErrorMessage = nil
        return notDelivered(refusal)
    }

    private func switchReasoningFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let reasoning = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hermesSettings {
            return await switchHermesReasoningFromSlashCommand(reasoning, settings: hermesSettings)
        }
        guard !reasoning.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /reasoning show|hide|none|minimal|low|medium|high|xhigh"))
        }

        guard canRunConfigurationSlashCommand(String(localized: "change reasoning")) else {
            return .unsupported(friendlyMessage: composerConfigurationErrorMessage ?? String(localized: "Reasoning changes are unavailable."))
        }

        isUpdatingComposerConfiguration = true
        composerConfigurationErrorMessage = nil
        sendErrorMessage = nil
        lastError = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            if Self.reasoningDisplayArgs.contains(reasoning) {
                _ = try await client.saveReasoningDisplay(reasoning)
            } else if Self.reasoningEffortArgs.contains(reasoning) {
                guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sessionID.isEmpty else {
                    let message = String(localized: "The server did not provide a session ID.")
                    composerConfigurationErrorMessage = message
                    return .unsupported(friendlyMessage: message)
                }
                let response = try await client.saveReasoningEffort(
                    reasoning,
                    sessionID: sessionID
                )
                selectedReasoningEffort = response.effectiveEffort ?? reasoning
            } else {
                return .unsupported(friendlyMessage: String(localized: "Unknown reasoning level: \(reasoning)."))
            }
            return .executed(message: nil)
        } catch {
            lastError = error
            composerConfigurationErrorMessage = error.localizedDescription
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func renameSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let title = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .executed(message: String(localized: "Current title: **\(displayTitle)**\n\nUse `/title <text>` to rename this session."))
        }
        if let hermesTurn { return await renameHermesSessionFromSlashCommand(title, on: hermesTurn) }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before renaming the session."))
        }

        lastError = nil
        sendErrorMessage = nil

        do {
            let response = try await client.renameSession(id: sessionID, title: title)
            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }
            displayTitle = Self.displayTitle(from: response.session?.title ?? title)
            return .executed(message: String(localized: "Title set to **\(displayTitle)**."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func renameHermesSessionFromSlashCommand(
        _ title: String,
        on hermes: HermesChatTurnCoordinator
    ) async -> SlashCommandExecutionResult {
        sendErrorMessage = nil
        do {
            let kept = try await hermes.slashCommands.rename(title)
            applyLiveActivitySessionTitle(kept)
            return .executed(message: String(localized: "Title set to **\(displayTitle)**."))
        } catch let error where HermesChatSideTasks.isReaped(error) {
            return notDelivered(String(localized: "Reconnect to the server to run /\("title")."))
        } catch BotSettingFailure.rejected(_, let message) {
            return notDelivered(message)
        } catch {
            return hermesSlashFailure(error, name: "title")
        }
    }

    private func setPersonalityFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        let requestedPersonality = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hermesSettings {
            return await askHermesPersonalityFromSlashCommand(requestedPersonality, settings: hermesSettings)
        }
        guard !requestedPersonality.isEmpty else {
            return await personalityListMessage()
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before changing personality."))
        }

        let normalized = requestedPersonality.lowercased()
        let name = Self.personalityClearArgs.contains(normalized) ? "" : requestedPersonality

        lastError = nil
        sendErrorMessage = nil

        do {
            let response = try await client.setPersonality(sessionID: sessionID, name: name)
            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }

            if name.isEmpty || response.personality == nil {
                return .executed(message: String(localized: "Personality cleared."))
            }

            return .executed(message: String(localized: "Personality set to **\(response.personality ?? name)**."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func personalityListMessage() async -> SlashCommandExecutionResult {
        do {
            let personalities = (try await client.personalities()).personalities ?? []
            return Self.personalityListMessage(personalities.compactMap { personality in
                guard let name = personality.name, !name.isEmpty else { return nil }
                return (name, personality.description ?? "")
            })
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private static func personalityListMessage(
        _ personalities: [(name: String, description: String)]
    ) -> SlashCommandExecutionResult {
        guard !personalities.isEmpty else {
            return .executed(message: String(localized: "No personalities are configured on the server."))
        }
        let list = personalities.map { personality in
            personality.description.isEmpty
                ? "- **\(personality.name)**"
                : "- **\(personality.name)** - \(personality.description)"
        }
        .joined(separator: "\n")
        return .executed(message: String(localized: "Available personalities:\n\n\(list)\n\nUse `/personality <name>` or `/personality none`."))
    }

    private func switchHermesReasoningFromSlashCommand(
        _ level: String,
        settings: HermesChatSettings
    ) async -> SlashCommandExecutionResult {
        let ladder = settings.effortLevels
        guard !level.isEmpty else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /reasoning \(ladder.joined(separator: "|"))"))
        }
        guard HermesModelCatalog.effortLevels.contains(level) else {
            if Self.hermesReasoningDisplayArgs.contains(level) {
                return .unsupported(friendlyMessage: String(localized: "On a Hermes host, /reasoning \(level) changes display settings for every client, so Hermex doesn't send it."))
            }
            return .unsupported(friendlyMessage: String(localized: "Unknown reasoning level: \(level)."))
        }
        guard settings.showsEffort else {
            return .unsupported(friendlyMessage: String(localized: "This model doesn't take a reasoning level."))
        }
        guard ladder.contains(level) else {
            return .unsupported(friendlyMessage: String(localized: "This model can't turn reasoning off."))
        }
        guard level != settings.controls.effort else { return .executed(message: nil) }
        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before changing reasoning."))
        }
        if await settings.select(effort: level) { return .executed(message: nil) }
        return .unsupported(friendlyMessage: settings.controls.errorMessage
                            ?? String(localized: "Wait for this chat to connect before changing reasoning."))
    }

    private func askHermesPersonalityFromSlashCommand(
        _ requested: String,
        settings: HermesChatSettings
    ) async -> SlashCommandExecutionResult {
        guard !requested.isEmpty else {
            do {
                return Self.personalityListMessage(try await settings.personalities())
            } catch {
                return .unsupported(friendlyMessage: error.localizedDescription)
            }
        }
        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before changing personality."))
        }
        settings.ask(personality: Self.personalityClearArgs.contains(requested.lowercased()) ? "none" : requested)
        return .executed(message: nil)
    }

    private(set) var pendingHermesRollback: HermesRollbackRequest?

    func cancelHermesRollback() { pendingHermesRollback = nil }

    private func rollbackFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        guard let hermes = hermesTurn else {
            return .unsupported(friendlyMessage: SlashCommandExecutor.unsupportedMessage(for: "rollback"))
        }
        guard let command = HermesRollbackCommand(args) else {
            return .unsupported(friendlyMessage: String(localized: "Usage: /rollback [diff N | N [file]]"))
        }
        let slash = hermes.slashCommands
        sendErrorMessage = nil
        do {
            switch command {
            case .list:
                guard let checkpoints = try await slash.checkpoints() else { return checkpointsOff() }
                notifyLocally(Self.checkpointList(checkpoints))
            case .diff(let ref):
                guard let checkpoints = try await slash.checkpoints() else { return checkpointsOff() }
                guard let checkpoint = HermesCheckpoint.named(ref, in: checkpoints) else { return noCheckpoint(ref) }
                let diff = try await slash.checkpointDiff(checkpoint.hash)
                notifyLocally(Self.checkpointDiff(stat: diff.stat, diff: diff.diff))
            case .restore(let ref, let filePath):
                if filePath == nil {
                    if slash.policy == .botChat { return .unsupported(friendlyMessage: String(localized: "A bot’s chat can’t be rewound.")) }
                    if activeStreamID != nil { return notDelivered(String(localized: "Wait for the current reply to finish.")) }
                }
                guard let checkpoints = try await slash.checkpoints() else { return checkpointsOff() }
                guard let checkpoint = HermesCheckpoint.named(ref, in: checkpoints) else { return noCheckpoint(ref) }
                pendingHermesRollback = HermesRollbackRequest(checkpoint: checkpoint, filePath: filePath)
            }
            return .executed(message: nil)
        } catch {
            return notDelivered(hermesRollbackFailure(error))
        }
    }

    func confirmHermesRollback(_ request: HermesRollbackRequest) async -> SlashCommandExecutionResult {
        pendingHermesRollback = nil
        guard let hermes = hermesTurn else { return .notDelivered }
        let wholeTree = request.filePath == nil
        let reconnect = String(localized: "Reconnect to the server to run /\("rollback").")
        if wholeTree {
            guard !isHermesSubmissionUncertain else { return notDelivered(reconnect) }
            guard activeStreamID == nil, !isUndoingExchange else {
                return notDelivered(String(localized: "Wait for the current reply to finish."))
            }
            isUndoingExchange = true
        }
        defer { if wholeTree { isUndoingExchange = false } }
        sendErrorMessage = nil
        let outcome: HermesRollbackOutcome
        do {
            outcome = try await hermes.restoreCheckpoint(request.checkpoint.hash, filePath: request.filePath)
        } catch BotSettingFailure.rejected(let code, let message) {
            return notDelivered(hermesRollbackFailure(BotSettingFailure.rejected(code, message)))
        } catch {
            return notDelivered(wholeTree ? hermesHistoryFailure(error, on: hermes, reconnect: reconnect) : hermesRollbackFailure(error))
        }
        guard outcome.success else {
            return notDelivered(outcome.error ?? String(localized: "Hermes couldn’t restore this checkpoint."))
        }
        notifyLocally(Self.rollbackNotice(outcome, request))
        return .executed(message: nil)
    }

    private func noCheckpoint(_ ref: String) -> SlashCommandExecutionResult {
        notDelivered(String(localized: "There’s no checkpoint \(ref). Run /rollback to see the list."))
    }

    private func checkpointsOff() -> SlashCommandExecutionResult {
        notifyLocally(String(localized: "Checkpoints are off on this Hermes host."))
        return .executed(message: nil)
    }

    private func hermesRollbackFailure(_ error: Error) -> String {
        switch error {
        case let notSent as HermesChatTurnCoordinator.NotSent where notSent.followedReplacedChat:
            return Self.notSentToReplacedChat
        case is HermesChatTurnCoordinator.NotSent:
            return String(localized: "Reconnect to the server to run /\("rollback").")
        case _ where HermesSlashCommands.isGoneRuntime(error):
            return String(localized: "Reconnect to the server to run /\("rollback").")
        case BotSettingFailure.rejected(4009, _), BotSettingFailure.rejected(4001, "session_busy"):
            return String(localized: "Wait for the current reply to finish.")
        case BotSettingFailure.rejected(_, let message):
            return message
        default:
            return String(localized: "Hermes did not confirm /\("rollback"). Check before running it again.")
        }
    }

    static func checkpointList(_ checkpoints: [HermesCheckpoint]) -> String {
        guard !checkpoints.isEmpty else { return String(localized: "This chat’s folder has no checkpoints yet.") }
        let rows = checkpoints.map { checkpoint in
            ["\(checkpoint.number). `\(checkpoint.shortHash)`", checkpointTime(checkpoint.timestamp), checkpoint.message]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return ([String(localized: "Checkpoints, newest first:")] + rows
                + ["", String(localized: "Run /rollback diff N to see a checkpoint’s changes, or /rollback N [file] to restore it.")])
            .joined(separator: "\n")
    }

    static func checkpointTime(_ timestamp: String) -> String {
        ISO8601DateFormatter().date(from: timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? timestamp
    }

    static func checkpointDiff(stat: String, diff: String) -> String {
        let diff = diff.trimmingCharacters(in: .newlines)
        guard !diff.trimmingCharacters(in: .whitespaces).isEmpty || !stat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "No changes since this checkpoint.")
        }
        var fence = "```"
        while diff.contains(fence) { fence += "`" }
        return [HermesSlashReply.verbatim(stat), diff.isEmpty ? "" : "\(fence)diff\n\(diff)\n\(fence)"]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func rollbackNotice(_ outcome: HermesRollbackOutcome, _ request: HermesRollbackRequest) -> String {
        let hash = "`\(request.checkpoint.shortHash)`"
        var lines: [String]
        if let file = request.filePath.map({ "`\($0)`" }) {
            lines = [String(localized: "Restored \(file) to checkpoint \(hash).")]
        } else {
            lines = [String(localized: "Restored the agent’s changes to checkpoint \(hash).")]
        }
        if !outcome.restoredFiles.isEmpty {
            lines.append(String(localized: "Restored: \(outcome.restoredFiles.map { "`\($0)`" }.joined(separator: ", "))"))
        }
        if !outcome.skippedUserEdits.isEmpty {
            lines.append(String(localized: "Kept your edits to: \(outcome.skippedUserEdits.map { "`\($0)`" }.joined(separator: ", "))"))
        }
        if outcome.historyRemoved > 0 { lines.append(String(localized: "The newest turn was removed from the chat.")) }
        return lines.joined(separator: "\n\n")
    }

    func confirmHermesPersonality(_ name: String) async -> SlashCommandExecutionResult {
        guard let settings = hermesSettings else { return .notDelivered }
        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before changing personality."))
        }
        let profile = selectedProfileTitle
        do {
            try await settings.setPersonality(name)
            return .executed(message: name == "none"
                             ? String(localized: "Personality cleared for **\(profile)**.")
                             : String(localized: "Personality for **\(profile)** set to **\(name)**."))
        } catch {
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func searchSkillsFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        do {
            let suggestions = try await skillSuggestionsForSlashCommand()
            if let invocation = SlashSkillFormatter.invocation(from: args, suggestions: suggestions) {
                let sent = await sendMessage(SlashSkillFormatter.messageText(for: invocation))
                if sent {
                    return .executed(message: nil)
                }
                return .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the skill message."))
            }

            return .executed(message: SlashSkillFormatter.message(for: suggestions, query: SlashSkillFormatter.skillQuery(from: args)))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    func executeSkillShortcutCommand(name: String, args: String) async -> SlashCommandExecutionResult? {
        do {
            let suggestions = try await skillSuggestionsForSlashCommand()
            guard let skill = SlashSkillFormatter.skill(named: name, in: suggestions) else {
                return nil
            }

            let message = args.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return .executed(message: SlashSkillFormatter.detailMessage(for: skill))
            }

            let commandText = "/\(skill.slashName) \(message)"
            let sent = await sendMessage(commandText)
            if sent {
                return .executed(message: nil)
            }
            return .unsupported(friendlyMessage: sendErrorMessage ?? String(localized: "Could not send the skill message."))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func skillSuggestionsForSlashCommand() async throws -> [SkillSlashSuggestion] {
        if hasLoadedSkillSlashSuggestions {
            return skillSlashSuggestions
        }

        let response = try await client.skills()
        let suggestions = SlashSkillFormatter.suggestions(from: response.skills ?? [])
        applySkillSlashSuggestions(suggestions)
        hasLoadedSkillSlashSuggestions = true
        return suggestions
    }

    private func applySkillSlashSuggestions(_ suggestions: [SkillSlashSuggestion]) {
        let previousCatalog = skillChipCatalog
        skillSlashSuggestions = suggestions
        skillChipCatalog = ComposerChipCatalog(skills: suggestions)
        composerChipCatalog = skillChipCatalog.withFilePaths(fileChipPaths)

        if skillChipCatalog != previousCatalog {
            transcriptRelayoutScrollToken += 1
        }
    }

    private enum FileReferenceSource {
        case webui(sessionID: String)
        case hermes(HermesChatTurnCoordinator)
    }

    private var fileReferenceSource: FileReferenceSource? {
        if let hermesTurn { return hermesTurn.workspace?.isLocal == true ? .hermes(hermesTurn) : nil }
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return .webui(sessionID: sessionID)
    }

    var offersFilePathSearch: Bool { fileReferenceSource != nil }

    func searchFilePaths(_ query: String) async {
        switch fileReferenceSource {
        case .webui(let sessionID):
            await filePathSearch.search(query, sessionID: sessionID, apiClient: client)
        case .hermes(let turn):
            await filePathSearch.search(query) { try await turn.completeFilePaths($0, as: .panel) }
        case nil:
            return
        }
    }

    func recordFileChipReference(_ path: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        checkedFileChipCandidates.insert(path)
        guard !fileChipPaths.contains(path) else { return }

        fileChipPaths.insert(path)
        composerChipCatalog = skillChipCatalog.withFilePaths(fileChipPaths)
        transcriptRelayoutScrollToken += 1
    }

    func loadFileChipReferences(draft: String) async {
        while let existing = fileChipReferenceLoad {
            await existing.value
        }

        guard !showsOfflineCache, let source = fileReferenceSource else { return }
        let candidates = fileChipReferenceCandidates(draft: draft)
        guard !candidates.isEmpty else { return }

        let scope = fileChipScopeRevision
        fileChipReferenceLoadGeneration &+= 1
        let loadGeneration = fileChipReferenceLoadGeneration
        let load = Task { [weak self] in
            guard let self else { return }
            await self.confirmFileChipReferences(candidates, source: source, scope: scope)
            guard loadGeneration == self.fileChipReferenceLoadGeneration else { return }
            self.fileChipReferenceLoad = nil
        }
        fileChipReferenceLoad = load
        await load.value
    }

    private func resetFileChipReferences(reloadingOpenQuery: Bool = false) {
        filePathSearch.reset(reloadingOpenQuery: reloadingOpenQuery)
        checkedFileChipCandidates.removeAll()
        fileChipReferenceLoad?.cancel()
        fileChipReferenceLoad = nil
        fileChipReferenceLoadGeneration &+= 1

        fileChipScopeRevision &+= 1
        guard !fileChipPaths.isEmpty else { return }

        fileChipPaths.removeAll()
        composerChipCatalog = skillChipCatalog.withFilePaths(fileChipPaths)
        transcriptRelayoutScrollToken += 1
    }

    private func fileChipReferenceCandidates(draft: String) -> [String] {
        var candidates: [String] = []
        var seen: Set<String> = []

        for text in [draft] + messages.filter({ $0.role == "user" }).map({ $0.content ?? "" }) {
            for candidate in ComposerChipTokenizer.fileReferenceCandidates(in: text, isComplete: true) {
                guard !checkedFileChipCandidates.contains(candidate),
                      !fileChipPaths.contains(candidate),
                      seen.insert(candidate).inserted
                else {
                    continue
                }
                candidates.append(candidate)
            }
        }

        return candidates
    }

    private func confirmFileChipReferences(
        _ candidates: [String],
        source: FileReferenceSource,
        scope: Int
    ) async {
        var wantedByDirectory: [String: Set<String>] = [:]
        var directories: [String] = []
        for candidate in candidates {
            let directory = FileTree.parentPath(of: candidate)
            if wantedByDirectory[directory] == nil { directories.append(directory) }
            wantedByDirectory[directory, default: []].insert(candidate)
        }

        var start = directories.startIndex
        while start < directories.endIndex {
            let end = directories.index(
                start,
                offsetBy: Self.fileChipDirectoryLimit,
                limitedBy: directories.endIndex
            ) ?? directories.endIndex
            let batch = directories[start..<end]
            start = end

            var confirmed: Set<String> = []
            var settled: Set<String> = []

            for directory in batch {
                guard !Task.isCancelled, !showsOfflineCache else { return }
                guard let wanted = wantedByDirectory[directory] else { continue }
                guard let lookup = try? await listedFileReferences(wanted, in: directory, source: source) else {
                    continue
                }

                confirmed.formUnion(lookup.listed)
                settled.formUnion(lookup.answered)
            }

            guard !Task.isCancelled, scope == fileChipScopeRevision else { return }

            apply(confirmed: confirmed, settled: settled)
        }
    }

    private func listedFileReferences(
        _ wanted: Set<String>,
        in directory: String,
        source: FileReferenceSource
    ) async throws -> (listed: Set<String>, answered: Set<String>) {
        switch source {
        case .webui(let sessionID):
            let entries = try await filePathSearch.entries(in: directory, sessionID: sessionID, apiClient: client)
            return (wanted.intersection(entries.map(\.path)), wanted)
        case .hermes(let turn):
            var listed: Set<String> = []
            var answered: Set<String> = []
            for candidate in wanted.sorted() {
                guard !Task.isCancelled else { throw CancellationError() }
                guard let entries = try? await turn.completeFilePaths(candidate, as: .listing) else { continue }
                answered.insert(candidate)
                if entries.contains(where: { $0.path == candidate }) {
                    listed.insert(candidate)
                }
            }
            return (listed, answered)
        }
    }

    private func apply(confirmed: Set<String>, settled: Set<String>) {
        checkedFileChipCandidates.formUnion(settled)

        let recovered = confirmed.subtracting(fileChipPaths)
        guard !recovered.isEmpty else { return }

        fileChipPaths.formUnion(recovered)
        composerChipCatalog = skillChipCatalog.withFilePaths(fileChipPaths)
        transcriptRelayoutScrollToken += 1
    }

    private func branchSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        if let hermesTurn { return await branchHermesSession(named: args, on: hermesTurn) }
        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to fork a conversation."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before forking."))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        let title = args.trimmingCharacters(in: .whitespacesAndNewlines)

        isForkingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        sendErrorMessage = nil
        defer { isForkingMessage = false }

        do {
            let response = try await client.branchSession(
                id: sessionID,
                title: title.isEmpty ? nil : title
            )

            guard let forkedSessionID = response.sessionId else {
                return .unsupported(
                    friendlyMessage: response.error ?? String(localized: "The server did not return the forked session ID.")
                )
            }

            let forkedResponse = try await client.session(
                id: forkedSessionID,
                includeMessages: false,
                messageLimit: nil
            )

            guard let forkedSessionDetail = forkedResponse.session else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return the forked session."))
            }

            return .openedSession(SessionSummary(from: forkedSessionDetail))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func createSessionFromSlashCommand() async -> SlashCommandExecutionResult {
        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to start a new session."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before starting a new session."))
        }

        isUpdatingComposerConfiguration = true
        lastError = nil
        sendErrorMessage = nil
        composerConfigurationErrorMessage = nil
        defer { isUpdatingComposerConfiguration = false }

        do {
            let response = try await client.createSession(
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName
            )

            guard let session = response.session else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return the new session."))
            }

            return .openedSession(SessionSummary(from: session))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func compressSessionFromSlashCommand(_ args: String) async -> SlashCommandExecutionResult {
        if let hermesTurn { return await compressHermesSession(focus: args, on: hermesTurn) }

        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to compress context."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before compressing context."))
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        let focusTopic = args.trimmingCharacters(in: .whitespacesAndNewlines)

        isCompressingSession = true
        lastError = nil
        sendErrorMessage = nil
        messageActionErrorMessage = nil
        defer { isCompressingSession = false }

        do {
            let response = try await client.compressSession(
                id: sessionID,
                focusTopic: focusTopic.isEmpty ? nil : focusTopic
            )

            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }

            guard let session = response.session else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return the compressed session."))
            }

            applyCompressionAnchorMetadata(from: session)
            messages = session.messages ?? []
            transcriptRevision &+= 1
            updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
            isViewingCachedData = false
            let snapshot = ContextWindowSnapshot(
                contextLength: session.contextLength,
                thresholdTokens: session.thresholdTokens,
                lastPromptTokens: session.lastPromptTokens,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                estimatedCost: session.estimatedCost
            )
            contextWindowSnapshot = snapshot.replacingTokensUsed(response.summary?.compressedTokenEstimate)
            if let title = session.title {
                displayTitle = Self.displayTitle(from: title)
            }
            currentWorkspace = session.workspace ?? currentWorkspace
            currentModel = session.model ?? currentModel
            currentModelProvider = session.modelProvider ?? currentModelProvider
            currentProfile = session.profile ?? currentProfile
            setCompletedToolCallGroups(ToolCallGroup.groups(
                persistedToolCalls: session.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            ))
            completedReasoningGroups = []
            liveToolCalls = []
            liveReasoningText = ""
            streamingAssistantMessageID = nil
            toolCallAnchorMessageID = nil
            reasoningAnchorMessageID = nil
            streamCoordinator.prepareForNewResponse()
            responseCompletionNeedsTranscriptRefresh = false
            attachmentCoordinator.removeAllLocalPreviews()

            return .executed(message: Self.compressionNote(
                headline: response.summary?.headline, tokenLine: response.summary?.tokenLine, focus: response.focusTopic
            ))
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    static func compressionNote(headline: String?, tokenLine: String?, focus: String?) -> String {
        let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = [headline, tokenLine, focus.flatMap { $0.isEmpty ? nil : String(localized: "Focus: \($0)") }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return details.isEmpty ? String(localized: "Context compressed.") : String(localized: "Context compressed.\n\n\(details)")
    }

    var clearConversationRefusal: String? {
        if isViewingCachedData {
            return String(localized: "Reconnect to the server to clear the conversation.")
        }

        if isCLISession {
            return String(localized: "Clearing the conversation is available for WebUI sessions only.")
        }

        if activeStreamID != nil {
            return String(localized: "Wait for the current response to finish before clearing the conversation.")
        }

        if isClearingConversation {
            return String(localized: "Wait for the conversation to finish clearing.")
        }

        if sessionID == nil {
            return String(localized: "The server did not provide a session ID.")
        }

        return nil
    }

    func clearConversationFromSlashCommand(modelContext: ModelContext?) async -> SlashCommandExecutionResult {
        if let hermesTurn { return .replacedHermesSession(clearedHermesChat(hermesTurn)) }

        if let refusal = clearConversationRefusal {
            return .unsupported(friendlyMessage: refusal)
        }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        lastError = nil
        sendErrorMessage = nil
        isClearingConversation = true
        defer { isClearingConversation = false }

        do {
            let response = try await client.clearSession(id: sessionID)
            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }

            clearTranscript()
            displayTitle = Self.displayTitle(from: response.session?.title)
            liveActivityManager.update(.sessionTitle(displayTitle))

            if let modelContext {
                do {
                    try CacheStore.cacheMessages([], serverURL: server, sessionID: sessionID, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                    sendErrorMessage = String(localized: "Cleared on the server, but the offline copy of this conversation could not be updated.")
                }
            }

            return .executed(message: nil)
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func undoLastExchangeFromSlashCommand() async -> SlashCommandExecutionResult {
        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to undo messages."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "Undo is available for WebUI sessions only."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before undoing messages."))
        }

        if let hermesTurn { return await undoHermesExchange(on: hermesTurn) }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        lastError = nil
        sendErrorMessage = nil

        do {
            let response = try await client.undoSession(id: sessionID)
            if let error = response.error {
                return .unsupported(friendlyMessage: error)
            }

            await loadMessages()
            if let lastError {
                return .unsupported(friendlyMessage: lastError.localizedDescription)
            }

            return .executed(message: nil)
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func retryLastTurnFromSlashCommand() async -> SlashCommandExecutionResult {
        guard !isViewingCachedData else {
            return .unsupported(friendlyMessage: String(localized: "Reconnect to the server to retry messages."))
        }

        guard !isCLISession else {
            return .unsupported(friendlyMessage: String(localized: "Retry is available for WebUI sessions only."))
        }

        guard activeStreamID == nil else {
            return .unsupported(friendlyMessage: String(localized: "Wait for the current response to finish before retrying messages."))
        }

        if let hermesTurn { return await retryHermesTurn(on: hermesTurn) }

        guard let sessionID else {
            return .unsupported(friendlyMessage: String(localized: "The server did not provide a session ID."))
        }

        isStartingChat = true
        lastError = nil
        sendErrorMessage = nil
        archiveLiveReasoningIfNeeded()
        archiveLiveToolCallsIfNeeded()
        liveReasoningText = ""
        liveToolCalls = []
        reasoningAnchorMessageID = nil
        toolCallAnchorMessageID = nil
        streamCoordinator.prepareForNewResponse()
        responseCompletionNeedsTranscriptRefresh = false
        defer { isStartingChat = false }

        do {
            let retryResponse = try await client.retrySession(id: sessionID)
            if let error = retryResponse.error {
                return .unsupported(friendlyMessage: error)
            }

            let lastUserText = retryResponse.lastUserText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !lastUserText.isEmpty else {
                return .unsupported(friendlyMessage: String(localized: "The server did not return a message to retry."))
            }

            let sessionResponse = try await client.session(
                id: sessionID,
                includeMessages: true,
                messageLimit: Self.messagePageLimit
            )
            if let session = sessionResponse.session {
                messages = session.messages ?? []
                updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
                setCompletedToolCallGroups(ToolCallGroup.groups(
                    persistedToolCalls: session.toolCalls ?? [],
                    messages: messages,
                    messageOffset: messagesOffset
                ))
                completedReasoningGroups = []
            } else {
                await loadMessages()
                if let lastError {
                    return .unsupported(friendlyMessage: lastError.localizedDescription)
                }
            }

            liveToolCalls = []
            liveReasoningText = ""
            toolCallAnchorMessageID = nil
            reasoningAnchorMessageID = nil
            attachmentCoordinator.removeAllLocalPreviews()

            let explicitModelPick = explicitModelPickForChatStart()
            let sentAt = Date()
            let chatResponse = try await client.startChat(
                sessionID: sessionID,
                message: lastUserText,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick
            )

            guard let streamID = chatResponse.streamId else {
                return .unsupported(friendlyMessage: chatResponse.error ?? String(localized: "The server did not return a stream ID after retrying."))
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            messages.append(
                ChatMessage(
                    role: "user",
                    content: lastUserText,
                    timestamp: Date().timeIntervalSince1970,
                    messageId: "local-\(UUID().uuidString)"
                )
            )

            streamCoordinator.start(
                streamID: streamID,
                runStartedAt: chatResponse.runStartedAt(sentAt: sentAt)
            )
            return .executed(message: nil)
        } catch {
            lastError = error
            return .unsupported(friendlyMessage: error.localizedDescription)
        }
    }

    private func canRunConfigurationSlashCommand(_ actionDescription: String) -> Bool {
        if isViewingCachedData {
            composerConfigurationErrorMessage = String(localized: "Reconnect to the server to \(actionDescription).")
            return false
        }

        if activeStreamID != nil {
            composerConfigurationErrorMessage = String(localized: "Wait for the current response to finish before you \(actionDescription).")
            return false
        }

        return true
    }

    private func modelOption(matching query: String) -> ModelCatalogOption? {
        let normalizedQuery = query.lowercased()
        let options = modelCatalogGroups.flatMap(\.allModels)

        if let exact = options.first(where: { $0.id.lowercased() == normalizedQuery }) {
            return exact
        }

        return options.first {
            $0.id.lowercased().contains(normalizedQuery) ||
            $0.displayName.lowercased().contains(normalizedQuery)
        }
    }

    private func workspacePath(matching query: String) -> String? {
        let normalizedQuery = query.lowercased()
        let roots = workspaceRoots.compactMap { root -> (path: String, name: String?)? in
            guard let path = root.path, !path.isEmpty else { return nil }
            return (path, root.name)
        }

        if let exact = roots.first(where: { $0.path.lowercased() == normalizedQuery }) {
            return exact.path
        }

        return roots.first {
            $0.path.lowercased().contains(normalizedQuery) ||
            ($0.name?.lowercased().contains(normalizedQuery) == true)
        }?.path
    }

    @discardableResult
    func appendLocalAssistantMessage(_ text: String) -> String? {
        appendLocalMessage(text, role: "local_assistant", idPrefix: "local-slash")
    }

    @discardableResult
    func appendLocalNoticeMessage(_ text: String) -> String? {
        appendLocalMessage(text, role: "local_notice", idPrefix: "local-notice")
    }

    func pinLocalNoticeMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinnedLocalNotices.append(trimmed)
    }

    private func showSteeringConfirmation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        steeringConfirmationDismissTask?.cancel()
        steeringConfirmationNotice = trimmed
        let dismissDelay = steeringConfirmationDismissDelay
        steeringConfirmationDismissTask = Task { @MainActor [weak self] in
            do {
                try await dismissDelay()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismissSteeringConfirmation()
        }
    }

    private func dismissSteeringConfirmation() {
        steeringConfirmationDismissTask?.cancel()
        steeringConfirmationDismissTask = nil
        steeringConfirmationNotice = nil
    }

    private func appendLocalMessage(_ text: String, role: String, idPrefix: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let messageID = "\(idPrefix)-\(UUID().uuidString)"
        messages.append(
            ChatMessage(
                role: role,
                content: trimmed,
                timestamp: Date().timeIntervalSince1970,
                messageId: messageID
            )
        )
        scheduleStreamingScrollTrigger()
        return messageID
    }

    private func updateLocalMessage(id: String, content: String) {
        guard let index = messages.firstIndex(where: { $0.messageId == id }) else { return }
        let existing = messages[index]
        messages[index] = ChatMessage(
            role: existing.role,
            content: content,
            timestamp: existing.timestamp,
            messageId: existing.messageId,
            name: existing.name,
            toolCallId: existing.toolCallId,
            toolUseId: existing.toolUseId,
            toolCalls: existing.toolCalls,
            contentParts: existing.contentParts,
            reasoning: existing.reasoning,
            attachments: existing.attachments,
            turnTps: existing.turnTps
        )
        scheduleStreamingScrollTrigger()
    }

    func setSendErrorMessage(_ message: String?) {
        sendErrorMessage = message
    }

    func forkFromMessage(_ context: MessageActionContext, modelContext: ModelContext? = nil) async -> SessionSummary? {
        guard !isViewingCachedData else {
            messageActionErrorMessage = String(localized: "Reconnect to the server to fork a conversation.")
            return nil
        }

        guard activeStreamID == nil else {
            messageActionErrorMessage = String(localized: "Wait for the current response to finish before forking.")
            return nil
        }

        guard let sessionID else {
            messageActionErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        isForkingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        defer { isForkingMessage = false }

        do {
            let response = try await client.branchSession(
                id: sessionID,
                keepCount: context.keepCountThroughMessage
            )

            guard let forkedSessionID = response.sessionId else {
                messageActionErrorMessage = response.error ?? String(localized: "The server did not return the forked session ID.")
                return nil
            }

            let forkedResponse = try await client.session(
                id: forkedSessionID,
                includeMessages: false,
                messageLimit: nil
            )

            guard let forkedSessionDetail = forkedResponse.session else {
                messageActionErrorMessage = String(localized: "The server did not return the forked session.")
                return nil
            }

            let forkedSession = SessionSummary(from: forkedSessionDetail)
            if let modelContext {
                do {
                    try CacheStore.cacheSession(forkedSession, serverURL: server, in: modelContext)
                } catch {
                    cacheErrorMessage = error.localizedDescription
                }
            }
            return forkedSession
        } catch {
            lastError = error
            messageActionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func forkHermesSession(from context: MessageActionContext) async -> HermesSessionChat? {
        guard let hermesTurn else { return nil }
        guard !isViewingCachedData else {
            messageActionErrorMessage = String(localized: "Reconnect to the server to fork a conversation.")
            return nil
        }
        guard activeStreamID == nil else {
            messageActionErrorMessage = String(localized: "Wait for the current response to finish before forking.")
            return nil
        }
        guard let rowID = messages.first(where: { $0.id == context.messageID })?.rowID else {
            messageActionErrorMessage = String(localized: "This message can’t be changed any more.")
            return nil
        }
        isForkingMessage = true
        messageActionErrorMessage = nil
        defer { isForkingMessage = false }
        do {
            return hermesBranchChat(try await hermesTurn.branch(through: rowID, name: nil), on: hermesTurn)
        } catch {
            messageActionErrorMessage = hermesBranchFailure(error)
            return nil
        }
    }

    private func branchHermesSession(named rawName: String, on hermes: HermesChatTurnCoordinator) async -> SlashCommandExecutionResult {
        guard !isViewingCachedData else { return notDelivered(String(localized: "Reconnect to the server to fork a conversation.")) }
        guard activeStreamID == nil else {
            return notDelivered(String(localized: "Wait for the current response to finish before forking."))
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        isForkingMessage = true
        sendErrorMessage = nil
        defer { isForkingMessage = false }
        do {
            return .openedHermesSession(hermesBranchChat(try await hermes.branch(through: nil, name: name.isEmpty ? nil : name),
                                                         on: hermes))
        } catch {
            return notDelivered(hermesBranchFailure(error))
        }
    }

    private func hermesBranchChat(_ key: String, on hermes: HermesChatTurnCoordinator) -> HermesSessionChat {
        HermesSessionChat(server: hermes.engine.server, connection: hermes.engine.connection,
                          target: .session(profile: hermes.engine.target.profile, key: key), parentKey: hermes.engine.storedKey)
    }

    private func hermesBranchFailure(_ error: Error) -> String {
        switch error {
        case let notSent as HermesChatTurnCoordinator.NotSent where notSent.followedReplacedChat:
            return Self.notSentToReplacedChat
        case is HermesChatTurnCoordinator.NotSent, BotSettingFailure.rejected(4001, _):
            return String(localized: "Reconnect to the server to fork a conversation.")
        case BotSettingFailure.rejected(4008, _):
            return String(localized: "Send a message first, then run /\("branch").")
        case BotSettingFailure.rejected(_, let message):
            return message
        case is HermesChatTurnCoordinator.BranchRowGone:
            return String(localized: "This message can’t be changed any more.")
        case is HermesChatTurnCoordinator.BranchContinuesEarlierSession:
            return String(localized: "This session continues an earlier one, so Fork From Here isn’t available. Run /\("branch") to copy the whole conversation.")
        default:
            return String(localized: "The server did not return the forked session ID.")
        }
    }

    func checkHermesForkParent(_ parentKey: String?) async {
        needsHermesForkCheck = parentKey != nil
        await resolveHermesForkOrigin()
    }

    private func resolveHermesForkOrigin() async {
        guard let hermesTurn, needsHermesForkCheck, !isCheckingHermesForkParent,
              hermesTurn.engine.connectionState == .connected, let key = hermesTurn.engine.storedKey else { return }
        let engine = hermesTurn.engine
        isCheckingHermesForkParent = true
        defer { isCheckingHermesForkParent = false }
        do {
            let parent = try await HermesBranchParent.row(of: key, profile: engine.target.profile, on: engine.wire)
            needsHermesForkCheck = false
            hermesForkOrigin = parent.map { ForkOrigin(parentSessionID: $0.id, parent: $0.summary(in: engine.target.profile)) }
        } catch {
        }
    }

    func hermesChat(opening session: SessionSummary) -> HermesSessionChat? {
        guard let hermesTurn else { return nil }
        let engine = hermesTurn.engine
        return session.hermesChat(on: engine.server, connection: engine.connection, listedIn: engine.target.profile)
    }

    func loadForkParent(id parentSessionID: String) async -> SessionSummary? {
        messageActionErrorMessage = nil
        lastError = nil
        let missingMessage = String(localized: "The original chat is no longer on this server.")

        do {
            let response = try await client.session(id: parentSessionID, includeMessages: false, messageLimit: nil)
            guard let parentDetail = response.session else {
                messageActionErrorMessage = missingMessage
                return nil
            }
            return SessionSummary(from: parentDetail)
        } catch {
            if let apiError = error as? APIError, Self.isMissingForkParent(apiError) {
                messageActionErrorMessage = missingMessage
            } else {
                lastError = error
                messageActionErrorMessage = error.localizedDescription
            }
            return nil
        }
    }

    private static func isMissingForkParent(_ error: APIError) -> Bool {
        guard case .http(let statusCode, _) = error else { return false }
        return statusCode == 404 || (statusCode == 409 && error.serverCode == "session_profile_mismatch")
    }

    func editMessage(_ context: MessageActionContext, newText: String, modelContext: ModelContext? = nil) async -> Bool {
        var edited = false
        defer {
            let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            if hermesTurn != nil, !edited, !text.isEmpty { unsentHermesEdit = text }
        }

        guard context.role == .user else {
            messageActionErrorMessage = String(localized: "Only user messages can be edited.")
            return false
        }

        guard !isViewingCachedData else {
            messageActionErrorMessage = String(localized: "Reconnect to the server to edit a message.")
            return false
        }

        guard activeStreamID == nil else {
            messageActionErrorMessage = String(localized: "Wait for the current response to finish before editing.")
            return false
        }

        if let hermesTurn {
            edited = await editHermesMessage(context, newText: newText, on: hermesTurn)
            return edited
        }

        guard let sessionID else {
            messageActionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        let editedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedText.isEmpty else {
            messageActionErrorMessage = String(localized: "The edited message cannot be empty.")
            return false
        }

        isEditingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        defer { isEditingMessage = false }

        do {
            let truncateResponse = try await client.truncateSession(
                id: sessionID,
                keepCount: context.fullHistoryIndex
            )

            if let session = truncateResponse.session {
                messages = session.messages ?? []
                updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
                setCompletedToolCallGroups(ToolCallGroup.groups(
                    persistedToolCalls: session.toolCalls ?? [],
                    messages: messages,
                    messageOffset: messagesOffset
                ))
                completedReasoningGroups = []
                liveToolCalls = []
                liveReasoningText = ""
                toolCallAnchorMessageID = nil
                reasoningAnchorMessageID = nil

                if let modelContext {
                    do {
                        try CacheStore.cacheMessages(messages, serverURL: server, sessionID: sessionID, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }

            let explicitModelPick = explicitModelPickForChatStart()
            let sentAt = Date()
            let chatResponse = try await client.startChat(
                sessionID: sessionID,
                message: editedText,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick
            )

            guard let streamID = chatResponse.streamId else {
                messageActionErrorMessage = chatResponse.error ?? String(localized: "The server did not return a stream ID after editing.")
                return false
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            messages.append(
                ChatMessage(
                    role: "user",
                    content: editedText,
                    timestamp: Date().timeIntervalSince1970,
                    messageId: "local-\(UUID().uuidString)"
                )
            )

            streamCoordinator.prepareForNewResponse()
            responseCompletionNeedsTranscriptRefresh = false
            streamCoordinator.start(
                streamID: streamID,
                runStartedAt: chatResponse.runStartedAt(sentAt: sentAt)
            )
            return true
        } catch {
            lastError = error
            messageActionErrorMessage = error.localizedDescription
            return false
        }
    }

    func regenerateAssistantResponse(
        _ context: MessageActionContext,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        guard context.role == .assistant else {
            messageActionErrorMessage = String(localized: "Only assistant messages can be regenerated.")
            return false
        }

        guard !isViewingCachedData else {
            messageActionErrorMessage = String(localized: "Reconnect to the server to regenerate a response.")
            return false
        }

        guard activeStreamID == nil else {
            messageActionErrorMessage = String(localized: "Wait for the current response to finish before regenerating.")
            return false
        }

        if let hermesTurn { return await regenerateHermesResponse(context, on: hermesTurn) }

        guard let sessionID else {
            messageActionErrorMessage = String(localized: "The server did not provide a session ID.")
            return false
        }

        guard let userText = Self.precedingUserMessageText(in: messages, beforeVisibleIndex: context.visibleIndex) else {
            messageActionErrorMessage = String(localized: "Load older messages before regenerating this response.")
            return false
        }

        isRegeneratingMessage = true
        messageActionErrorMessage = nil
        lastError = nil
        stopListening()
        defer { isRegeneratingMessage = false }

        do {
            let truncateResponse = try await client.truncateSession(
                id: sessionID,
                keepCount: context.fullHistoryIndex
            )

            if let session = truncateResponse.session {
                messages = session.messages ?? []
                updateOlderMessagePagination(from: session, loadedMessageCount: messages.count)
                setCompletedToolCallGroups(ToolCallGroup.groups(
                    persistedToolCalls: session.toolCalls ?? [],
                    messages: messages,
                    messageOffset: messagesOffset
                ))
                completedReasoningGroups = []
                liveToolCalls = []
                liveReasoningText = ""
                toolCallAnchorMessageID = nil
                reasoningAnchorMessageID = nil

                if let modelContext {
                    do {
                        try CacheStore.cacheMessages(messages, serverURL: server, sessionID: sessionID, in: modelContext)
                    } catch {
                        cacheErrorMessage = error.localizedDescription
                    }
                }
            }

            let explicitModelPick = explicitModelPickForChatStart()
            let sentAt = Date()
            let chatResponse = try await client.startChat(
                sessionID: sessionID,
                message: userText,
                workspace: currentWorkspace,
                model: currentModel,
                modelProvider: requestModelProvider,
                profile: requestProfileName,
                explicitModelPick: explicitModelPick
            )

            guard let streamID = chatResponse.streamId else {
                messageActionErrorMessage = chatResponse.error ?? String(localized: "The server did not return a stream ID after regenerating.")
                return false
            }

            completeExplicitModelPickForChatStart(explicitModelPick)
            streamCoordinator.prepareForNewResponse()
            responseCompletionNeedsTranscriptRefresh = false
            streamCoordinator.start(
                streamID: streamID,
                runStartedAt: chatResponse.runStartedAt(sentAt: sentAt)
            )
            return true
        } catch {
            lastError = error
            messageActionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func compressHermesSession(focus: String, on hermes: HermesChatTurnCoordinator) async -> SlashCommandExecutionResult {
        let reconnect = String(localized: "Reconnect to the server to compress context.")
        let busy = String(localized: "Already compressing; try again shortly.")
        guard !isHermesSubmissionUncertain else { return notDelivered(reconnect) }
        guard activeStreamID == nil else { return notDelivered(String(localized: "Wait for the current reply to finish.")) }
        guard !isCompressingSession else { return notDelivered(busy) }
        let focus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        isCompressingSession = true
        defer { isCompressingSession = false }
        sendErrorMessage = nil
        do {
            switch try await hermes.compress(focus: focus.isEmpty ? nil : focus) {
            case .compacted(let headline, let tokenLine):
                return .executed(message: Self.compressionNote(headline: headline, tokenLine: tokenLine, focus: focus))
            case .unchanged(let reason):
                return notDelivered(reason ?? busy)
            }
        } catch {
            return notDelivered(hermesHistoryFailure(error, on: hermes, reconnect: reconnect))
        }
    }

    private func clearedHermesChat(_ hermes: HermesChatTurnCoordinator) -> HermesSessionChat {
        let chosen = hermes.settings.selectedModel.flatMap { option in
            option.providerID.map { HermesCall.Model(id: option.id, provider: $0) }
        }
        return HermesSessionChat(server: hermes.engine.server, connection: hermes.engine.connection,
                                 target: .new(profile: hermes.settings.profile, cwd: hermes.cwd,
                                              model: chosen ?? hermes.reportedModel))
    }

    @ObservationIgnored private var unsentHermesEdit: String?

    func takeUnsentHermesEdit() -> String? {
        defer { unsentHermesEdit = nil }
        return unsentHermesEdit
    }

    private func editHermesMessage(_ context: MessageActionContext, newText: String,
                                   on hermes: HermesChatTurnCoordinator) async -> Bool {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            messageActionErrorMessage = String(localized: "The edited message cannot be empty.")
            return false
        }
        guard !isChangingHermesHistory else { return false }
        guard let rowID = hermesRewindPrompt(for: context)?.rowID else {
            messageActionErrorMessage = String(localized: "This message can’t be changed any more.")
            return false
        }
        isEditingMessage = true
        defer { isEditingMessage = false }
        messageActionErrorMessage = await rewindHermesTranscript(
            before: rowID, sending: text, on: hermes, reconnect: String(localized: "Reconnect to the server to edit a message.")
        )
        return messageActionErrorMessage == nil
    }

    private func regenerateHermesResponse(_ context: MessageActionContext, on hermes: HermesChatTurnCoordinator) async -> Bool {
        guard !isChangingHermesHistory else { return false }
        guard let prompt = hermesRewindPrompt(for: context), let rowID = prompt.rowID else {
            messageActionErrorMessage = String(localized: "This message can’t be changed any more.")
            return false
        }
        isRegeneratingMessage = true
        stopListening()
        defer { isRegeneratingMessage = false }
        messageActionErrorMessage = await rewindHermesTranscript(
            before: rowID, sending: Self.hermesPromptText(prompt), on: hermes,
            reconnect: String(localized: "Reconnect to the server to regenerate a response.")
        )
        return messageActionErrorMessage == nil
    }

    private func retryHermesTurn(on hermes: HermesChatTurnCoordinator) async -> SlashCommandExecutionResult {
        guard let prompt = messages.last(where: Self.opensHermesTurn) else {
            return notDelivered(String(localized: "Send a message first, then run /\("retry")."))
        }
        guard Self.isHermesRewindable(prompt), let rowID = prompt.rowID else {
            return notDelivered(String(localized: "This message can’t be changed any more."))
        }
        guard !isChangingHermesHistory else { return notDelivered(String(localized: "Wait for the current reply to finish.")) }
        isRegeneratingMessage = true
        stopListening()
        defer { isRegeneratingMessage = false }
        if let failure = await rewindHermesTranscript(before: rowID, sending: Self.hermesPromptText(prompt), on: hermes,
                                                      reconnect: String(localized: "Reconnect to the server to retry messages.")) {
            return notDelivered(failure)
        }
        return .executed(message: nil)
    }

    var mayRetryHermesTurn: Bool {
        guard let hermesTurn, hermesTurn.activity.retryTarget != nil else { return false }
        return hermesTurn.engine.connectionState == .connected && activeStreamID == nil && !isStartingChat
            && !isHermesSubmissionUncertain && !isViewingCachedData
    }

    func retryHermesFailedTurn() async {
        guard mayRetryHermesTurn, let hermes = hermesTurn, let target = hermes.activity.retryTarget else { return }
        stopListening()
        sendErrorMessage = await rewindHermesTranscript(
            before: target.rowID, sending: target.text, on: hermes,
            reconnect: String(localized: "Reconnect to the server to retry messages."), retrying: target
        )
    }

    private func undoHermesExchange(on hermes: HermesChatTurnCoordinator) async -> SlashCommandExecutionResult {
        let reconnect = String(localized: "Reconnect to the server to undo messages.")
        guard !isHermesSubmissionUncertain else { return notDelivered(reconnect) }
        guard !isUndoingExchange else { return notDelivered(String(localized: "Wait for the current reply to finish.")) }
        isUndoingExchange = true
        defer { isUndoingExchange = false }
        sendErrorMessage = nil
        do {
            try await hermes.undo()
            return .executed(message: nil)
        } catch {
            return notDelivered(hermesHistoryFailure(error, on: hermes, reconnect: reconnect))
        }
    }

    private func rewindHermesTranscript(before rowID: Int, sending text: String, on hermes: HermesChatTurnCoordinator,
                                        reconnect: String, retrying: HermesChatActivity.RetryTarget? = nil) async -> String? {
        guard !isHermesSubmissionUncertain else { return reconnect }
        sendErrorMessage = nil
        lastError = nil
        let first = messages.firstIndex { $0.rowID == rowID } ?? messages.lastIndex(where: Self.opensHermesTurn).flatMap {
            retrying?.showsPrompt == true && messages[$0].rowID == nil ? $0 : nil
        }
        let cut = first.map { Set(messages[$0...].map(\.id)) } ?? []
        let discardsLaterPrompts = first.map { messages[$0...].dropFirst().contains(where: Self.opensHermesTurn) } ?? false
        isStartingChat = true
        defer { isStartingChat = false }
        do {
            try await hermes.rewind(before: rowID, text: text, discardsLaterPrompts: discardsLaterPrompts)
        } catch is HermesChatTurnCoordinator.RewoundButNotSent {
            removeCutRows(cut, insertingPrompt: nil)
            unsentHermesEdit = text
            return String(localized: "The later messages were removed, but your edited message wasn’t sent. It’s in the message box: send it again.")
        } catch {
            if retrying != nil, case BotSettingFailure.rejected(4018, _) = error { hermes.retryWasRefused(at: rowID) }
            return hermesHistoryFailure(error, on: hermes, reconnect: reconnect)
        }
        removeCutRows(cut, insertingPrompt: HermesChatTurnCoordinator.displayed(ChatMessage(
            role: "user", content: text, timestamp: Date().timeIntervalSince1970, messageId: "local-\(UUID().uuidString)"
        )))
        return nil
    }

    private func removeCutRows(_ cut: Set<String>, insertingPrompt prompt: ChatMessage?) {
        let start = messages.firstIndex { cut.contains($0.id) } ?? messages.endIndex
        var next = messages.filter { !cut.contains($0.id) }
        if let prompt { next.insert(prompt, at: min(start, next.endIndex)) }
        messages = next
        transcriptRevision &+= 1
        setCompletedToolCallGroups(completedToolCallGroups.filter { $0.anchorMessageID.map { !cut.contains($0) } ?? false })
        completedReasoningGroups = completedReasoningGroups.filter { $0.anchorMessageID.map { !cut.contains($0) } ?? false }
    }

    private func hermesHistoryFailure(_ error: Error, on hermes: HermesChatTurnCoordinator, reconnect: String) -> String {
        switch error {
        case let notSent as HermesChatTurnCoordinator.NotSent where notSent.followedReplacedChat:
            return Self.notSentToReplacedChat
        case BotSettingFailure.rejected(4001, "session_busy"):
            return String(localized: "Wait for the current reply to finish.")
        case BotSettingFailure.rejected(4001, "invalid_params"):
            return String(localized: "This message can’t be changed any more.")
        case is HermesFenceRefusal:
            return String(localized: "This chat changed on the server. Reopen it and try again.")
        case is HermesChatTurnCoordinator.NotSent, BotSettingFailure.rejected(4001, _):
            return reconnect
        case BotSettingFailure.rejected(4009, _):
            return String(localized: "Wait for the current reply to finish.")
        case BotSettingFailure.rejected(4018, _):
            return String(localized: "This message can’t be changed any more.")
        case BotSettingFailure.rejected(4033, _):
            return String(localized: "This chat changed on the server. Reopen it and try again.")
        case BotSettingFailure.rejected(_, let message):
            return message
        default:
            holdForLostAnswer(hermes)
            return String(localized: "The server did not confirm the change.")
        }
    }

    private func hermesRewindPrompt(for context: MessageActionContext) -> ChatMessage? {
        let index = messages.indices.contains(context.visibleIndex) && messages[context.visibleIndex].id == context.messageID
            ? context.visibleIndex : messages.firstIndex { $0.id == context.messageID }
        guard let index, let prompt = messages[...index].last(where: Self.opensHermesTurn),
              Self.isHermesRewindable(prompt) else { return nil }
        return prompt
    }

    private func updateHermesRewindableMessageIDs() {
        var ids = Set<String>()
        var rewindable = false
        for message in messages {
            if Self.opensHermesTurn(message) { rewindable = Self.isHermesRewindable(message) }
            if rewindable, message.role == "assistant" || Self.opensHermesTurn(message) { ids.insert(message.id) }
        }
        if ids != hermesRewindableMessageIDs { hermesRewindableMessageIDs = ids }
    }

    private nonisolated static func onlyRepliesChanged(from old: [ChatMessage], to new: [ChatMessage]) -> Bool {
        guard old.count == new.count else { return false }
        for (before, after) in zip(old, new) where before != after {
            let sameReply = before.role == "assistant" && after.role == "assistant"
            guard sameReply, let id = before.messageId, id == after.messageId else { return false }
        }
        return true
    }

    private nonisolated static func opensHermesTurn(_ message: ChatMessage) -> Bool {
        message.role == "user" && !message.isSteerMessage
    }

    private nonisolated static func isHermesRewindable(_ prompt: ChatMessage) -> Bool {
        prompt.rowID != nil && !prompt.isCompacted && prompt.attachments?.isEmpty != false
            && !hermesPromptText(prompt).isEmpty
    }

    private nonisolated static func hermesPromptText(_ prompt: ChatMessage) -> String {
        (prompt.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func cancelActiveStream() async -> Bool {
        guard activeStreamID != nil else { return false }

        isCancellingStream = true
        sendErrorMessage = nil
        lastError = nil
        defer { isCancellingStream = false }

        if let hermesTurn {
            do {
                return try await hermesTurn.interrupt()
            } catch is HermesFenceRefusal {
                sendErrorMessage = String(localized: "The reply moved on before Stop reached it. Tap Stop again.")
                return false
            } catch {
                sendErrorMessage = String(localized: "The server could not stop the current response.")
                return false
            }
        }

        do {
            guard let response = try await streamCoordinator.cancelActiveStream() else { return false }
            if response.ok == false {
                sendErrorMessage = response.error ?? String(localized: "The server could not stop the current response.")
                return false
            }

            return true
        } catch {
            lastError = error
            sendErrorMessage = error.localizedDescription
            return false
        }
    }

    func clearMessageActionError() {
        messageActionErrorMessage = nil
    }

    func toggleListening(to context: MessageActionContext) {
        guard context.role == .assistant else { return }

        guard let listenText = context.listenText else {
            messageActionErrorMessage = String(localized: "There is no assistant text to listen to.")
            return
        }

        if listeningMessageID == context.messageID {
            stopListening()
            return
        }

        stopListening()
        listeningMessageID = context.messageID
        beginListenPlaybackPreparation(for: context)

        let usesServerSpeech = ServerTTSPolicy.shouldUseServerTTS(for: listenText, onHermes: hermesTurn != nil)
        let requestID = UUID()
        activeListenRequestID = requestID
        listenPreparationTask = Task { [weak self, synthesizeListenAudio, renderOnDeviceSpeech] in
            if usesServerSpeech, !Task.isCancelled, let audio = try? await synthesizeListenAudio(listenText) {
                guard let self, !Task.isCancelled, self.activeListenRequestID == requestID else { return }
                if self.startListenAudioPlayback(audio) { return }
            }
            guard !Task.isCancelled else { return }
            let audio = try? await renderOnDeviceSpeech(listenText)
            guard let self, !Task.isCancelled, self.activeListenRequestID == requestID else { return }
            if let audio, self.startListenAudioPlayback(audio) { return }
            self.finishListening()
        }
    }

    func stopListening() {
        listenPreparationTask?.cancel()
        listenPreparationTask = nil
        activeListenRequestID = nil

        listenAudioPlayer?.stop()
        finishListening()
    }

    func toggleListenPlaybackPlayPause() {
        switch listenPlaybackPhase {
        case .playing:
            pauseListenPlayback()
        case .paused:
            resumeListenPlayback()
        case .idle, .loading:
            break
        }
    }

    func setListenPlaybackSpeed(_ speed: ListenPlaybackSpeed) {
        guard listenPlaybackSpeed != speed else { return }
        listenPlaybackSpeed = speed
        userDefaults.set(speed.rawValue, forKey: ListenPlaybackSpeed.storageKey)
        listenAudioPlayer?.rate = Float(speed.rawValue)
        updateListenNowPlaying()
        listenNowPlayingRefreshTask?.cancel()
        let settle = listenSpeedChangeSettleDelay
        listenNowPlayingRefreshTask = Task { @MainActor [weak self] in
            guard (try? await settle()) != nil, !Task.isCancelled else { return }
            self?.updateListenNowPlaying()
        }
    }

    func scrubListenPlayback(to time: TimeInterval) {
        listenPlaybackScrubTime = boundedListenPlaybackTime(time)
    }

    func setListenPlaybackScrubbing(_ scrubbing: Bool) {
        if scrubbing {
            listenPlaybackScrubTime = listenPlaybackElapsedTime
        } else if let target = listenPlaybackScrubTime {
            seekListenPlayback(to: target)
            listenPlaybackScrubTime = nil
        }
    }

    func refreshListenPlaybackProgressAfterSceneActivation() {
        guard listenPlaybackPhase == .playing || listenPlaybackPhase == .paused else { return }

        updateListenPlaybackProgressFromPlayer()
        if listenPlaybackPhase == .playing {
            startListenPlaybackTicker()
        }
    }

    func suspendStreamForBackground() {
        pauseWaitingSend()
        suspendActiveStreamConnection()
    }

    func suspendStreamForNavigation() {
        suspendActiveStreamConnection()
    }

    func cleanupPollingTasks() {
        stopBackgroundPolling(clearTrackedPrompts: true)
        pendingActionCoordinator.stopMonitoring(clearPrompt: true)
        takeInitialSessionPrefetch(usable: false)
    }

    private func suspendActiveStreamConnection() {
        turn.suspendActiveStreamConnection()
    }

    func reconnectStreamIfNeeded(modelContext: ModelContext? = nil) async {
        if hermesTurn != nil, let modelContext { hermesCache = modelContext }
        await turn.reconnectIfNeeded(modelContext: modelContext)
    }

    func networkPathDidChange(modelContext: ModelContext? = nil) async {
        if hermesTurn != nil, let modelContext { hermesCache = modelContext }
        await turn.networkPathDidChange(modelContext: modelContext)
    }

    func refreshTranscriptIfActiveStreamCompleted(
        streamID expectedStreamID: String,
        modelContext: ModelContext? = nil
    ) async {
        await streamCoordinator.refreshTranscriptIfCompleted(
            streamID: expectedStreamID,
            modelContext: modelContext
        )
    }

    func recoverStaleActiveStreamIfNeeded(
        now: Date = Date(),
        modelContext: ModelContext? = nil
    ) async {
        await turn.recoverStaleStreamIfNeeded(now: now, modelContext: modelContext)
    }

    private var hasRunningLiveToolCall: Bool {
        liveToolCalls.contains { !$0.isCompleted }
    }

    private func saveActiveStreamSnapshotIfNeeded() {
        guard let sessionID,
              let activeStreamID,
              !hasCompletedCurrentResponse
        else { return }

        ActiveChatStreamSnapshotStore.shared.save(
            ActiveChatStreamSnapshot(
                messages: messages,
                messagesOffset: messagesOffset,
                displayTitle: displayTitle,
                completedToolCallGroups: completedToolCallGroups,
                completedReasoningGroups: completedReasoningGroups,
                liveToolCalls: liveToolCalls,
                liveReasoningText: liveReasoningText,
                activeStreamLastEventID: streamCoordinator.lastEventID,
                streamingAssistantMessageID: streamingAssistantMessageID,
                toolCallAnchorMessageID: toolCallAnchorMessageID,
                reasoningAnchorMessageID: reasoningAnchorMessageID,
                contextWindowSnapshot: contextWindowSnapshot,
                localAttachmentPreviews: attachmentCoordinator.localAttachmentPreviews,
                pinnedLocalNotices: pinnedLocalNotices
            ),
            server: server,
            sessionID: sessionID,
            streamID: activeStreamID
        )
    }

    @discardableResult
    private func restoreActiveStreamSnapshotIfAvailable(streamID: String) -> ChatStreamSnapshotRestoreResult {
        guard let sessionID,
              let snapshot = ActiveChatStreamSnapshotStore.shared.snapshot(
                server: server,
                sessionID: sessionID,
                streamID: streamID
              )
        else { return .notRestored }

        let merge = Self.mergingLoadedMessages(messages, withActiveStreamSnapshot: snapshot)
        messages = merge.messages
        if merge.usedSnapshotMessagesOffset {
            messagesOffset = snapshot.messagesOffset
            hasOlderMessages = snapshot.messagesOffset > 0
        }
        displayTitle = displayTitle.isEmpty ? snapshot.displayTitle : displayTitle
        setCompletedToolCallGroups(snapshot.completedToolCallGroups)
        completedReasoningGroups = snapshot.completedReasoningGroups
        liveToolCalls = snapshot.liveToolCalls
        liveReasoningText = snapshot.liveReasoningText
        streamingAssistantMessageID = merge.streamingAssistantMessageID ?? snapshot.streamingAssistantMessageID
        toolCallAnchorMessageID = Self.remappedAnchorMessageID(
            snapshot.toolCallAnchorMessageID,
            from: snapshot.streamingAssistantMessageID,
            to: streamingAssistantMessageID
        )
        reasoningAnchorMessageID = Self.remappedAnchorMessageID(
            snapshot.reasoningAnchorMessageID,
            from: snapshot.streamingAssistantMessageID,
            to: streamingAssistantMessageID
        )
        contextWindowSnapshot = contextWindowSnapshot ?? snapshot.contextWindowSnapshot
        attachmentCoordinator.mergeLocalAttachmentPreviews(snapshot.localAttachmentPreviews)
        pinnedLocalNotices = snapshot.pinnedLocalNotices
        scheduleStreamingScrollTrigger()
        return ChatStreamSnapshotRestoreResult(
            didRestoreSnapshot: true,
            lastEventID: snapshot.activeStreamLastEventID
        )
    }

    private func removeActiveStreamSnapshot(streamID: String?) {
        guard let sessionID,
              let streamID
        else { return }

        ActiveChatStreamSnapshotStore.shared.remove(
            server: server,
            sessionID: sessionID,
            streamID: streamID
        )
    }

    @discardableResult
    func respondToApproval(_ choice: ApprovalChoice) async -> Bool {
        await pendingActionCoordinator.respondToApproval(choice)
    }

    @discardableResult
    func skipApprovalsForCurrentSession() async -> Bool {
        await pendingActionCoordinator.skipApprovalsForCurrentSession()
    }

    func applyApprovalUpdate(_ update: ApprovalPendingResponse, sessionID: String) {
        pendingActionCoordinator.applyApprovalUpdate(update, sessionID: sessionID)
    }

    @discardableResult
    func respondToClarification(_ responseText: String) async -> Bool {
        await pendingActionCoordinator.respondToClarification(responseText)
    }

    func applyClarificationUpdate(_ update: ClarificationPendingResponse, sessionID: String) {
        pendingActionCoordinator.applyClarificationUpdate(update, sessionID: sessionID)
    }

    private func startBtwStream(streamID: String, question: String) {
        activeBtwStreamID = streamID
        activeBtwQuestion = question
        activeBtwAnswer = ""
        activeBtwMessageID = appendLocalAssistantMessage(Self.btwMessageText(question: question, answer: nil, isLoading: true))

        btwStreamClient.start(url: client.chatStreamURL(streamID: streamID)) { [weak self] event in
            self?.handleBtwStreamEvent(event)
        }
    }

    private func handleBtwStreamEvent(_ event: SSEEvent) {
        switch event {
        case .token(let text):
            activeBtwAnswer += text
            updateActiveBtwMessage(isLoading: true)
        case .interimAssistant(let payload):
            guard payload.alreadyStreamed != true else { break }
            let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { break }
            if activeBtwAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activeBtwAnswer = text
            } else {
                activeBtwAnswer += "\n\n\(text)"
            }
            updateActiveBtwMessage(isLoading: true)
        case .done:
            updateActiveBtwMessage(isLoading: false)
        case .approvalPending, .clarificationPending:
            break
        case .streamEnd, .cancelled:
            finishBtwStream()
        case .error(let message):
            activeBtwAnswer = "Error: \(message)"
            updateActiveBtwMessage(isLoading: false)
            finishBtwStream()
        case .transportError(let message):
            activeBtwAnswer = "Error: \(message)"
            updateActiveBtwMessage(isLoading: false)
            finishBtwStream()
        case .heartbeat, .ignored, .reasoning, .toolStarted, .toolCompleted, .title, .metering, .pendingSteerLeftover:
            break
        }
    }

    private func updateActiveBtwMessage(isLoading: Bool) {
        guard let activeBtwMessageID, let activeBtwQuestion else { return }
        updateLocalMessage(
            id: activeBtwMessageID,
            content: Self.btwMessageText(
                question: activeBtwQuestion,
                answer: activeBtwAnswer,
                isLoading: isLoading
            )
        )
    }

    private func finishBtwStream() {
        btwStreamClient.stop()
        activeBtwStreamID = nil
        activeBtwMessageID = nil
        activeBtwQuestion = nil
        activeBtwAnswer = ""
    }

    private func stopBackgroundPolling(clearTrackedPrompts: Bool) {
        backgroundPollTask?.cancel()
        backgroundPollTask = nil
        if clearTrackedPrompts {
            backgroundPromptsByTaskID.removeAll()
        }
    }

    private func startBackgroundPollingIfNeeded(parentSessionID: String) {
        guard backgroundPollTask == nil else { return }

        let pollingInterval = pollingIntervals.backgroundNanoseconds, waitInterval = pollingIntervals.sleep
        backgroundPollTask = Task { @MainActor [weak self] in
            pollingLoop: while !Task.isCancelled {
                do {
                    guard let self,
                          !self.backgroundPromptsByTaskID.isEmpty
                    else { break pollingLoop }

                    do {
                        let response = try await self.client.backgroundStatus(sessionID: parentSessionID)
                        self.handleBackgroundResults(response.results ?? [])
                    } catch {
                        self.lastError = error
                    }

                    guard !Task.isCancelled, !self.backgroundPromptsByTaskID.isEmpty else {
                        break pollingLoop
                    }
                }

                await waitInterval(pollingInterval)
            }

            if !Task.isCancelled {
                self?.backgroundPollTask = nil
            }
        }
    }

    private func handleBackgroundResults(_ results: [BackgroundResult]) {
        for result in results {
            let prompt: String
            if let taskID = result.taskId,
               let trackedPrompt = backgroundPromptsByTaskID.removeValue(forKey: taskID) {
                prompt = trackedPrompt
            } else if let resultPrompt = result.prompt, !resultPrompt.isEmpty {
                prompt = resultPrompt
            } else {
                prompt = "Background task"
            }

            appendLocalAssistantMessage(
                Self.backgroundResultText(
                    prompt: prompt,
                    answer: result.answer
                )
            )
        }
    }

    @discardableResult
    private func appendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        guard payload.alreadyStreamed != true else { return false }

        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return false }

        flushPendingStreamingContent()

        if let streamingAssistantMessageID,
           let index = messages.firstIndex(where: { $0.messageId == streamingAssistantMessageID }) {
            let existing = messages[index]
            let currentContent = existing.content ?? ""
            let textToAppend = deduplicatedReplayText(
                text,
                existingContent: currentContent,
                matchedPrefixLength: &activeStreamReplayMatchedInterimLength
            )
            guard !textToAppend.isEmpty else { return false }

            let shouldAppendReplaySuffixDirectly = isActiveStreamReplayConnection && textToAppend != text
            let shouldUseSeparator = currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && !shouldAppendReplaySuffixDirectly
            let separator = shouldUseSeparator ? "\n\n" : ""
            messages[index] = ChatMessage(
                role: existing.role,
                content: currentContent + separator + textToAppend,
                timestamp: existing.timestamp,
                messageId: existing.messageId,
                name: existing.name,
                toolCallId: existing.toolCallId,
                toolUseId: existing.toolUseId,
                toolCalls: existing.toolCalls,
                contentParts: existing.contentParts,
                reasoning: existing.reasoning,
                attachments: existing.attachments,
                turnTps: existing.turnTps
            )
            scheduleStreamingScrollTrigger()
            return true
        }

        return appendAssistantToken(text)
    }

    private func applyCompletedStreamSession(_ completedSession: SessionDetail) {
        if let completedSessionID = completedSession.sessionId,
           let sessionID,
           completedSessionID != sessionID {
            return
        }

        applyCompressionAnchorMetadata(from: completedSession)

        var didApplyCompletedTranscript = false
        if let completedMessages = completedSession.messages,
           !completedMessages.isEmpty {
            let previousMessages = messages
            let previousMessagesOffset = messagesOffset
            let reloadedMessages = Self.mergingLoadedMessages(
                completedMessages,
                withLocalOptimisticMessages: messages
            )
            applyReloadedMessages(
                reloadedMessages,
                from: completedSession,
                previousMessages: previousMessages,
                previousMessagesOffset: previousMessagesOffset
            )
            didApplyCompletedTranscript = true
        }

        if let title = completedSession.title {
            applyLiveActivitySessionTitle(title)
        }

        currentWorkspace = completedSession.workspace ?? currentWorkspace
        currentModel = completedSession.model ?? currentModel
        currentModelProvider = completedSession.modelProvider ?? currentModelProvider
        currentProfile = completedSession.profile ?? currentProfile

        contextWindowSnapshot = ContextWindowSnapshot(
            contextLength: completedSession.contextLength,
            thresholdTokens: completedSession.thresholdTokens,
            lastPromptTokens: completedSession.lastPromptTokens,
            inputTokens: completedSession.inputTokens,
            outputTokens: completedSession.outputTokens,
            estimatedCost: completedSession.estimatedCost
        )
        if didApplyCompletedTranscript || completedSession.toolCalls != nil {
            let rebuiltToolCallGroups = ToolCallGroup.groups(
                persistedToolCalls: completedSession.toolCalls ?? [],
                messages: messages,
                messageOffset: messagesOffset
            )
            if !liveToolCalls.isEmpty {
                let fallbackAnchorMessageID = currentTurnToolCallFallbackAnchorMessageID()
                setCompletedToolCallGroups(ToolCallGroup.coalescingByAssistantTurn(
                    ToolCallGroup.merging(
                        primaryGroups: rebuiltToolCallGroups,
                        fallbackGroups: [
                            ToolCallGroup(
                                id: "completed-live-tools-\(fallbackAnchorMessageID ?? "unanchored")",
                                anchorMessageID: fallbackAnchorMessageID,
                                toolCalls: liveToolCalls
                            )
                        ]
                    ),
                    messages: messages,
                    messageOffset: messagesOffset
                ))
            } else {
                setCompletedToolCallGroups(rebuiltToolCallGroups)
            }
            liveToolCalls = []
        }

        if didApplyCompletedTranscript {
            completedReasoningGroups = []
            liveReasoningText = ""
            toolCallAnchorMessageID = nil
            reasoningAnchorMessageID = nil
            attachmentCoordinator.removeAllLocalPreviews()
            scheduleStreamingScrollTrigger()
        }
    }

    private func setCompletedToolCallGroups(_ groups: [ToolCallGroup]) {
        let lookup = ToolCallGroupAnchorLookup(groups: groups)
        guard completedToolCallGroups != groups else { return }

        completedToolCallGroups = groups
        completedToolCallGroupLookup = lookup
        recomputeDisplayedTranscriptMessages()
    }

    private func appendCompletedToolCallGroup(_ group: ToolCallGroup) {
        setCompletedToolCallGroups(completedToolCallGroups + [group])
    }

    private func archiveLiveToolCallsIfNeeded() {
        guard !liveToolCalls.isEmpty else { return }

        appendCompletedToolCallGroup(
            ToolCallGroup(
                anchorMessageID: toolCallAnchorMessageID,
                toolCalls: liveToolCalls
            )
        )
    }

    private func currentTurnToolCallFallbackAnchorMessageID() -> String? {
        if let toolCallAnchorMessageID,
           messages.enumerated().contains(where: { index, message in
               TranscriptTurnClassifier.anchorID(for: message, at: index, messageOffset: messagesOffset) == toolCallAnchorMessageID
           }) {
            return toolCallAnchorMessageID
        }

        return TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset).first
            ?? Self.latestAssistantAnchorID(in: messages, messageOffset: messagesOffset)
    }

    private func archiveLiveActivityForNewTurn() {
        archiveLiveReasoningIfNeeded()
        archiveLiveToolCallsIfNeeded()
        liveReasoningText = ""
        liveToolCalls = []
        reasoningAnchorMessageID = nil
        toolCallAnchorMessageID = nil
    }

    private func archiveLiveReasoningIfNeeded() {
        guard !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        completedReasoningGroups.append(
            ReasoningGroup(
                anchorMessageID: reasoningAnchorMessageID,
                text: liveReasoningText
            )
        )
    }

    @discardableResult
    private func ensureStreamingAssistantMessage() -> String {
        if let streamingAssistantMessageID {
            return streamingAssistantMessageID
        }

        let messageID = "stream-\(UUID().uuidString)"
        streamingAssistantMessageID = messageID
        messages.append(
            ChatMessage(
                role: "assistant",
                content: "",
                timestamp: Date().timeIntervalSince1970,
                messageId: messageID
            )
        )
        return messageID
    }

    @discardableResult
    private func appendReasoning(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        _ = ensureStreamingAssistantMessage()
        let remainder: String
        if isActiveStreamReplayConnection {
            let effectiveContent = activeStreamReplayLoadedReasoningText
                + liveReasoningText
                + pendingReasoningChunks.joined()
            remainder = deduplicatedReplayText(
                text,
                existingContent: effectiveContent,
                matchedPrefixLength: &activeStreamReplayMatchedReasoningLength
            )
        } else {
            remainder = text
        }
        guard !remainder.isEmpty else { return false }

        pendingReasoningChunks.append(remainder)
        scheduleStreamingContentFlush()
        return true
    }

    @discardableResult
    private func flushReasoningChunks() -> Bool {
        guard !pendingReasoningChunks.isEmpty else { return false }

        let appendedText = pendingReasoningChunks.joined()
        pendingReasoningChunks = []

        let messageID = ensureStreamingAssistantMessage()
        if reasoningAnchorMessageID == nil {
            reasoningAnchorMessageID = messageID
        }

        liveReasoningText += appendedText
        return true
    }

    @discardableResult
    private func appendToolCall(_ payload: ToolStreamEvent) -> Bool {
        let messageID = ensureStreamingAssistantMessage()
        if toolCallAnchorMessageID == nil {
            toolCallAnchorMessageID = messageID
        }

        if let duplicateLoadedIndex = duplicateLoadedReplayToolStartIndex(for: payload) {
            activeStreamReplayPendingLoadedToolMatchIndex = duplicateLoadedIndex
            return false
        }

        if let duplicateReplayIndex = duplicateReplayToolStartIndex(for: payload) {
            activeStreamReplayPendingToolMatchIndex = duplicateReplayIndex
            return false
        }

        liveToolCalls.append(
            ToolCall(
                id: payload.stableID ?? "live-tool-\(UUID().uuidString)",
                name: payload.name,
                preview: payload.preview,
                args: payload.args
            )
        )
        scheduleStreamingScrollTrigger()
        return true
    }

    @discardableResult
    private func completeToolCall(_ payload: ToolStreamEvent) -> Bool {
        let messageID = ensureStreamingAssistantMessage()
        if toolCallAnchorMessageID == nil {
            toolCallAnchorMessageID = messageID
        }

        if duplicateLoadedReplayToolCompletion(for: payload) {
            return false
        }

        if let duplicateReplayIndex = duplicateReplayToolCompletionIndex(for: payload) {
            let wasAlreadyCompleted = liveToolCalls[duplicateReplayIndex].isCompleted
            activeStreamReplayToolMatchIndex = duplicateReplayIndex + 1
            activeStreamReplayPendingToolMatchIndex = nil

            guard !wasAlreadyCompleted else { return false }

            liveToolCalls[duplicateReplayIndex] = liveToolCalls[duplicateReplayIndex].applyingCompletionPayload(payload)
            scheduleStreamingScrollTrigger()
            return true
        }

        activeStreamReplayPendingToolMatchIndex = nil

        guard let index = liveToolCallCompletionIndex(for: payload) else {
            liveToolCalls.append(
                ToolCall(
                    id: payload.stableID ?? "live-tool-\(UUID().uuidString)",
                    name: payload.name,
                    preview: payload.preview,
                    args: payload.args,
                    duration: payload.duration,
                    isError: payload.isError,
                    isCompleted: true
                )
            )
            scheduleStreamingScrollTrigger()
            return true
        }

        liveToolCalls[index] = liveToolCalls[index].applyingCompletionPayload(payload)
        scheduleStreamingScrollTrigger()
        return true
    }

    private func duplicateReplayToolStartIndex(for payload: ToolStreamEvent) -> Int? {
        guard isActiveStreamReplayConnection else { return nil }

        if let stableIndex = stableReplayToolIndex(for: payload) {
            return stableIndex
        }

        guard activeStreamReplayToolMatchIndex < liveToolCalls.count else { return nil }

        let index = activeStreamReplayToolMatchIndex
        return liveToolCalls[index].matchesReplayToolStart(payload) ? index : nil
    }

    private func duplicateReplayToolCompletionIndex(for payload: ToolStreamEvent) -> Int? {
        guard isActiveStreamReplayConnection else { return nil }

        if let stableIndex = stableReplayToolIndex(for: payload) {
            return stableIndex
        }

        if let pendingIndex = activeStreamReplayPendingToolMatchIndex,
           pendingIndex < liveToolCalls.count,
           liveToolCalls[pendingIndex].matchesReplayToolCompletion(payload) {
            return pendingIndex
        }

        guard activeStreamReplayToolMatchIndex < liveToolCalls.count else { return nil }

        let index = activeStreamReplayToolMatchIndex
        guard liveToolCalls[index].isCompleted,
              liveToolCalls[index].matchesReplayToolCompletion(payload)
        else {
            return nil
        }

        return index
    }

    private func duplicateLoadedReplayToolStartIndex(for payload: ToolStreamEvent) -> Int? {
        guard isActiveStreamReplayConnection else { return nil }

        if let stableID = payload.stableID?.nonEmptyReplayMatchText,
           let index = activeStreamReplayLoadedToolCalls.firstIndex(where: { $0.matchesStableToolID(stableID) }) {
            return index
        }

        guard activeStreamReplayLoadedToolMatchIndex < activeStreamReplayLoadedToolCalls.count else {
            return nil
        }

        let index = activeStreamReplayLoadedToolMatchIndex
        return activeStreamReplayLoadedToolCalls[index].matchesReplayToolStart(payload) ? index : nil
    }

    private func duplicateLoadedReplayToolCompletion(for payload: ToolStreamEvent) -> Bool {
        guard isActiveStreamReplayConnection else { return false }

        let index: Int?
        if let stableID = payload.stableID?.nonEmptyReplayMatchText {
            index = activeStreamReplayLoadedToolCalls.firstIndex { $0.matchesStableToolID(stableID) }
        } else if let pendingIndex = activeStreamReplayPendingLoadedToolMatchIndex,
                  pendingIndex < activeStreamReplayLoadedToolCalls.count,
                  activeStreamReplayLoadedToolCalls[pendingIndex].matchesReplayToolCompletion(payload) {
            index = pendingIndex
        } else if activeStreamReplayLoadedToolMatchIndex < activeStreamReplayLoadedToolCalls.count,
                  activeStreamReplayLoadedToolCalls[activeStreamReplayLoadedToolMatchIndex]
                    .matchesReplayToolCompletion(payload) {
            index = activeStreamReplayLoadedToolMatchIndex
        } else {
            index = nil
        }

        guard let index else { return false }
        activeStreamReplayLoadedToolMatchIndex = max(activeStreamReplayLoadedToolMatchIndex, index + 1)
        activeStreamReplayPendingLoadedToolMatchIndex = nil
        return true
    }

    private func loadedReplayReasoningText() -> String {
        guard let streamingAssistantMessageID,
              let message = messages.first(where: { $0.messageId == streamingAssistantMessageID })
        else { return "" }

        return Self.reasoningTexts(from: message).joined(separator: "\n")
    }

    private func loadedReplayToolCalls() -> [ToolCall] {
        let currentTurnAnchors = Set(
            TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(
                in: messages,
                messageOffset: messagesOffset
            )
        )
        return completedToolCallGroups
            .filter { group in
                group.anchorMessageID.map(currentTurnAnchors.contains) ?? false
            }
            .flatMap(\.toolCalls)
    }

    private func stableReplayToolIndex(for payload: ToolStreamEvent) -> Int? {
        guard let stableID = payload.stableID?.nonEmptyReplayMatchText else { return nil }

        return liveToolCalls.firstIndex { toolCall in
            toolCall.matchesStableToolID(stableID)
        }
    }

    private func liveToolCallCompletionIndex(for payload: ToolStreamEvent) -> Int? {
        if let stableID = payload.stableID?.nonEmptyReplayMatchText,
           let stableIndex = liveToolCalls.lastIndex(where: { toolCall in
               !toolCall.isCompleted && toolCall.matchesStableToolID(stableID)
           }) {
            return stableIndex
        }

        return liveToolCalls.lastIndex { toolCall in
            !toolCall.isCompleted && (payload.name == nil || toolCall.name == payload.name)
        }
    }

    @discardableResult
    private func appendAssistantToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }

        let remainder: String
        if isActiveStreamReplayConnection {
            let messageID = ensureStreamingAssistantMessage()
            let flushedContent = messages.first(where: { $0.messageId == messageID })?.content ?? ""
            let effectiveContent = flushedContent + pendingAssistantText
            remainder = deduplicatedReplayToken(token, existingContent: effectiveContent)
        } else {
            _ = ensureStreamingAssistantMessage()
            remainder = token
        }
        guard !remainder.isEmpty else { return false }

        pendingAssistantText += remainder
        scheduleStreamingContentFlush()
        if !isActiveStreamReplayConnection,
           streamingHapticPulseThrottle.shouldPulse(at: Date().timeIntervalSinceReferenceDate) {
            streamingHapticPulseTrigger += 1
        }
        return true
    }

    @discardableResult
    private func flushAssistantTokens(throughRevealGate: Bool = false) -> Bool {
        guard !pendingAssistantText.isEmpty else { return false }

        let appendedContent: String
        if throughRevealGate {
            let (shown, held) = StreamingRevealGate.cut(
                pendingAssistantText,
                heldPreviousTick: heldStreamingFragmentLastTick
            )
            pendingAssistantText = held
            heldStreamingFragmentLastTick = !held.isEmpty
            guard !shown.isEmpty else { return false }
            appendedContent = shown
        } else {
            appendedContent = pendingAssistantText
            pendingAssistantText = ""
            heldStreamingFragmentLastTick = false
        }

        let messageID = ensureStreamingAssistantMessage()
        if !liveReasoningText.isEmpty && reasoningAnchorMessageID == nil {
            reasoningAnchorMessageID = messageID
        }
        if !liveToolCalls.isEmpty && toolCallAnchorMessageID == nil {
            toolCallAnchorMessageID = messageID
        }

        if let index = messages.firstIndex(where: { $0.messageId == messageID }) {
            let existing = messages[index]
            replaceStreamingReply(at: index, with: ChatMessage(
                role: existing.role,
                content: (existing.content ?? "") + appendedContent,
                timestamp: existing.timestamp,
                messageId: existing.messageId,
                name: existing.name,
                toolCallId: existing.toolCallId,
                toolUseId: existing.toolUseId,
                toolCalls: existing.toolCalls,
                contentParts: existing.contentParts,
                reasoning: existing.reasoning,
                attachments: existing.attachments,
                turnTps: existing.turnTps
            ))
            return true
        }

        messages.append(
            ChatMessage(
                role: "assistant",
                content: appendedContent,
                timestamp: Date().timeIntervalSince1970,
                messageId: messageID
            )
        )
        return true
    }

    private func replaceStreamingReply(at index: Int, with reply: ChatMessage) {
        guard let row = textOnlyTranscriptRow(replacing: messages[index], at: index, with: reply) else {
            messages[index] = reply
            return
        }

        patchesStreamingReplyInPlace = true
        defer { patchesStreamingReplyInPlace = false }
        messages[index] = reply
        let patched = displayedTranscriptMessages[row]
        displayedTranscriptMessages[row] = TranscriptMessage(
            loadedIndex: patched.loadedIndex,
            renderID: patched.renderID,
            anchorID: patched.anchorID,
            message: reply
        )
        recomputeCompressionReferenceCard()
    }

    private func textOnlyTranscriptRow(replacing old: ChatMessage, at index: Int, with new: ChatMessage) -> Int? {
        guard old.role == "assistant", new.role == "assistant", old.messageId == new.messageId,
              Self.hasTranscriptMessageRowContent(old),
              Self.reasoningTexts(from: new).isEmpty,
              let row = displayedTranscriptMessages.lastIndex(where: { $0.loadedIndex == index })
        else { return nil }

        let anchorID = displayedTranscriptMessages[row].anchorID
        guard !completedReasoningGroups.contains(where: { $0.anchorMessageID == anchorID }) else { return nil }
        return row
    }

    private func deduplicatedReplayToken(_ token: String, existingContent: String) -> String {
        guard isActiveStreamReplayConnection, !existingContent.isEmpty else {
            resetActiveStreamReplayTokenState()
            return token
        }

        let matchedPrefixLength = min(activeStreamReplayMatchedPrefixLength, existingContent.count)
        let expectedReplayRemainder = String(existingContent.dropFirst(matchedPrefixLength))
        if expectedReplayRemainder.hasPrefix(token) {
            activeStreamReplayMatchedPrefixLength = matchedPrefixLength + token.count
            if activeStreamReplayMatchedPrefixLength >= existingContent.count {
                resetActiveStreamReplayTokenState()
            }
            return ""
        }

        if token.hasPrefix(expectedReplayRemainder) {
            resetActiveStreamReplayTokenState()
            return String(token.dropFirst(expectedReplayRemainder.count))
        }

        if existingContent.hasSuffix(token) || existingContent.hasPrefix(token) {
            resetActiveStreamReplayTokenState()
            return ""
        }

        if token.hasPrefix(existingContent) {
            resetActiveStreamReplayTokenState()
            return String(token.dropFirst(existingContent.count))
        }

        let maximumOverlap = min(existingContent.count, token.count)
        guard maximumOverlap > 0 else {
            resetActiveStreamReplayTokenState()
            return token
        }

        for overlapLength in stride(from: maximumOverlap, through: 1, by: -1) {
            let contentSuffix = existingContent.suffix(overlapLength)
            let tokenPrefix = token.prefix(overlapLength)
            if contentSuffix == tokenPrefix {
                resetActiveStreamReplayTokenState()
                return String(token.dropFirst(overlapLength))
            }
        }

        resetActiveStreamReplayTokenState()
        return token
    }

    private func deduplicatedReplayText(
        _ text: String,
        existingContent: String,
        matchedPrefixLength: inout Int
    ) -> String {
        guard isActiveStreamReplayConnection, !existingContent.isEmpty else {
            matchedPrefixLength = 0
            return text
        }

        let matchedLength = min(matchedPrefixLength, existingContent.count)
        let expectedReplayRemainder = String(existingContent.dropFirst(matchedLength))
        if expectedReplayRemainder.hasPrefix(text) {
            matchedPrefixLength = matchedLength + text.count
            if matchedPrefixLength >= existingContent.count {
                matchedPrefixLength = 0
            }
            return ""
        }

        if text.hasPrefix(expectedReplayRemainder) {
            matchedPrefixLength = 0
            return String(text.dropFirst(expectedReplayRemainder.count))
        }

        if existingContent.hasSuffix(text) || existingContent.hasPrefix(text) {
            matchedPrefixLength = 0
            return ""
        }

        if text.hasPrefix(existingContent) {
            matchedPrefixLength = 0
            return String(text.dropFirst(existingContent.count))
        }

        let maximumOverlap = min(existingContent.count, text.count)
        guard maximumOverlap > 0 else {
            matchedPrefixLength = 0
            return text
        }

        for overlapLength in stride(from: maximumOverlap, through: 1, by: -1) {
            let contentSuffix = existingContent.suffix(overlapLength)
            let textPrefix = text.prefix(overlapLength)
            if contentSuffix == textPrefix {
                matchedPrefixLength = 0
                return String(text.dropFirst(overlapLength))
            }
        }

        matchedPrefixLength = 0
        return text
    }

    private func resetActiveStreamReplayTokenState() {
        turn.clearReplayConnection()
        activeStreamReplayMatchedPrefixLength = 0
    }

    private func flushPinnedLocalNoticesToTranscript() {
        let notices = pinnedLocalNotices
        pinnedLocalNotices.removeAll()
        for notice in notices {
            appendLocalNoticeMessage(notice)
        }
    }

    private func enqueueQueuedSlashMessage(
        _ text: String,
        attachments: [PendingAttachment],
        atFront: Bool = false
    ) {
        let message = QueuedSlashMessage(text: text, attachments: attachments)
        if atFront {
            queuedSlashMessages.insert(message, at: 0)
        } else {
            queuedSlashMessages.append(message)
        }
    }

    func takeQueuedMessages() -> [QueuedSlashMessage] {
        guard !queuedSlashMessages.isEmpty else { return [] }
        let queued = queuedSlashMessages
        queuedSlashMessages.removeAll()
        queueHandOverCount &+= 1
        pinnedLocalNotices.removeAll { $0 == Self.interruptQueuedFallbackNotice }
        return queued
    }

    private func drainQueuedSlashMessageIfIdle() {
        guard activeStreamID == nil,
              !isStartingChat,
              !isDrainingQueuedSlashMessage,
              !queuedSlashMessages.isEmpty
        else { return }

        let next = queuedSlashMessages.removeFirst()
        isDrainingQueuedSlashMessage = true

        Task { @MainActor in
            let savedAttachments = attachmentCoordinator.pendingAttachments
            attachmentCoordinator.replacePendingAttachments(next.attachments)
            let sent = await sendMessage(next.text)
            if !sent {
                queuedSlashMessages.insert(next, at: 0)
            }
            let nextAttachmentIDs = Set(next.attachments.map(\.id))
            let stagedDuringSend = attachmentCoordinator.pendingAttachments.filter {
                !nextAttachmentIDs.contains($0.id)
            }
            attachmentCoordinator.replacePendingAttachments(savedAttachments + stagedDuringSend)
            isDrainingQueuedSlashMessage = false
            if sent, activeStreamID == nil {
                drainQueuedSlashMessageIfIdle()
            }
        }
    }

    @discardableResult
    private func updateTitle(_ payload: TitleStreamEvent) -> Bool {
        if let payloadSessionID = payload.sessionId, payloadSessionID != sessionID {
            return false
        }

        guard let title = payload.title else { return false }
        applyLiveActivitySessionTitle(title)
        return true
    }

    private func refreshCompletedResponseTitleIfNeeded() {
        guard !isRefreshingCompletedResponseTitle else { return }
        guard let sessionID else { return }

        isRefreshingCompletedResponseTitle = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRefreshingCompletedResponseTitle = false }

            do {
                let response = try await client.session(id: sessionID, includeMessages: false, messageLimit: nil)
                if let title = response.session?.title {
                    applyLiveActivitySessionTitle(title)
                }
            } catch {
            }
        }
    }

    private func applyLiveActivitySessionTitle(_ title: String) {
        displayTitle = Self.displayTitle(from: hermesTurn == nil ? title : hermesHeaderTitle(title))
        guard hermesTurn == nil else { return }
        liveActivityManager.update(.sessionTitle(displayTitle))
    }

    private func hermesHeaderTitle(_ title: String) -> String? {
        MessageAttachment.hermesTitle(title)
            ?? messages.first { $0.role == "user" }?.attachments?.first?.name
    }

    private func finishListening() {
        activeListenPlayerID = nil
        activeListenRequestID = nil
        listenAudioPlayer = nil
        listeningMessageID = nil
        clearListenPlaybackState()
        listenAudioSession.deactivate()
    }

    private func beginListenPlaybackPreparation(for context: MessageActionContext) {
        listenPlaybackTitle = String(localized: "Hermex response \(context.visibleIndex + 1)")
        listenPlaybackPhase = .loading
        listenPlaybackElapsedTime = 0
        listenPlaybackDuration = 0
        listenPlaybackScrubTime = nil
        stopListenPlaybackTicker()
        listenRemoteControlCenter.clear()
    }

    private func clearListenPlaybackState() {
        listenPlaybackPhase = .idle
        listenPlaybackElapsedTime = 0
        listenPlaybackDuration = 0
        listenPlaybackScrubTime = nil
        stopListenPlaybackTicker()
        listenRemoteControlCenter.clear()
    }

    private func startListenAudioPlayback(_ audioData: Data) -> Bool {
        guard let player = try? listenAudioPlayerFactory(audioData) else {
            return false
        }

        let playerID = ObjectIdentifier(player)
        player.onFinish = { [weak self] in
            self?.handleListenPlayerCompletion(for: playerID)
        }
        player.prepareToPlay()
        player.rate = Float(listenPlaybackSpeed.rawValue)

        listenAudioSession.activate()
        guard player.play() else {
            listenAudioSession.deactivate()
            return false
        }

        listenPlaybackScrubTime = nil
        configureListenRemoteControls()
        listenAudioPlayer = player
        activeListenPlayerID = playerID
        listenPlaybackPhase = .playing
        startListenPlaybackTicker()
        updateListenPlaybackProgressFromPlayer()
        updateListenNowPlaying()
        return true
    }

    private func pauseListenPlayback() {
        guard listenPlaybackPhase == .playing, let player = listenAudioPlayer else { return }
        player.pause()
        updateListenPlaybackProgressFromPlayer()
        listenPlaybackPhase = .paused
        stopListenPlaybackTicker()
        updateListenNowPlaying()
    }

    private func resumeListenPlayback() {
        guard listenPlaybackPhase == .paused, let player = listenAudioPlayer else { return }
        player.rate = Float(listenPlaybackSpeed.rawValue)
        listenAudioSession.activate()
        guard player.play() else { return }
        listenPlaybackPhase = .playing
        startListenPlaybackTicker()
        updateListenPlaybackProgressFromPlayer()
        updateListenNowPlaying()
    }

    private func seekListenPlayback(to time: TimeInterval) {
        guard let player = listenAudioPlayer else { return }
        let boundedTime = boundedListenPlaybackTime(time)
        player.currentTime = boundedTime
        listenPlaybackElapsedTime = boundedTime
        updateListenNowPlaying()
    }

    private func boundedListenPlaybackTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        let upperBound = listenPlaybackDuration > 0 ? listenPlaybackDuration : max(time, 0)
        return min(max(0, time), upperBound)
    }

    private func startListenPlaybackTicker() {
        stopListenPlaybackTicker()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateListenPlaybackProgressFromPlayer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        listenPlaybackTicker = timer
    }

    private func stopListenPlaybackTicker() {
        listenPlaybackTicker?.invalidate()
        listenPlaybackTicker = nil
    }

    private func updateListenPlaybackProgressFromPlayer() {
        guard listenPlaybackScrubTime == nil, let player = listenAudioPlayer else { return }
        listenPlaybackElapsedTime = boundedListenPlaybackTime(player.currentTime)
        listenPlaybackDuration = max(0, player.duration)
    }

    private func configureListenRemoteControls() {
        listenRemoteControlCenter.configure(
            play: { [weak self] in self?.resumeListenPlayback() },
            pause: { [weak self] in self?.pauseListenPlayback() },
            togglePlayPause: { [weak self] in self?.toggleListenPlaybackPlayPause() },
            changePlaybackPosition: { [weak self] position in self?.seekListenPlayback(to: position) }
        )
    }

    private func updateListenNowPlaying() {
        guard listenPlaybackPhase == .playing || listenPlaybackPhase == .paused else { return }
        listenRemoteControlCenter.update(ListenNowPlayingSnapshot(
            title: listenPlaybackTitle,
            duration: listenPlaybackDuration,
            elapsedTime: listenPlaybackElapsedTime,
            speed: listenPlaybackSpeed,
            isPlaying: listenPlaybackPhase == .playing
        ))
    }

    private func handleListenPlayerCompletion(for playerID: ObjectIdentifier) {
        guard playerID == activeListenPlayerID else { return }
        finishListening()
    }

    private func statusTokenLine() -> String {
        guard let contextWindowSnapshot else {
            return String(localized: "Unavailable")
        }

        let input = contextWindowSnapshot.inputTokens ?? 0
        let output = contextWindowSnapshot.outputTokens ?? 0
        let total = input + output
        let cost = contextWindowSnapshot.estimatedCost ?? 0

        if total == 0 && cost == 0 {
            return String(localized: "No token usage available")
        }

        let inputText = Self.formatTokenCount(input)
        let outputText = Self.formatTokenCount(output)
        guard cost > 0 else {
            return String(localized: "\(inputText) in / \(outputText) out")
        }

        return String(localized: "\(inputText) in / \(outputText) out (~\(cost.formattedCost()))")
    }

    private func providerFromModel(_ model: String) -> String? {
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count > 1 else { return nil }
        return parts[0]
    }

    private static func formatTokenCount(_ value: Int) -> String {
        value.formatted(.number)
    }

    private static func displayTitle(from title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedTitle, !trimmedTitle.isEmpty else {
            return String(localized: "Untitled Session")
        }
        return trimmedTitle
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func compactModelTitle(_ modelID: String) -> String {
        let raw = modelID.split(separator: ":").last.map(String.init) ?? modelID
        let suffix = raw.split(separator: "/").last.map(String.init) ?? raw
        return suffix.replacingOccurrences(of: "gpt-", with: "GPT-", options: [.caseInsensitive])
    }

    private static let reasoningDisplayArgs: Set<String> = ["show", "hide", "on", "off"]
    private static let reasoningEffortArgs: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh"]
    private static let personalityClearArgs: Set<String> = ["none", "default", "clear"]
    private static let hermesReasoningDisplayArgs: Set<String> = [
        "show", "hide", "on", "off", "full", "all", "clamp", "collapse", "short"
    ]

    private static func btwMessageText(question: String, answer: String?, isLoading: Bool) -> String {
        let trimmedAnswer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: String
        if trimmedAnswer.isEmpty {
            body = isLoading ? "..." : String(localized: "No answer produced.")
        } else {
            body = trimmedAnswer
        }

        return """
        **BTW** \(question)

        \(body)
        """
    }

    private static let hermesBackgroundCardPrefix = "local-background-"

    @ObservationIgnored private var hermesHistoryGroupIDs: Set<String> = []
    private(set) var hermesCachedWorkAnchorIDs: Set<String> = []

    static let hermesTranscriptBase = 1_000_000

    nonisolated static func hermesMessagesOffset(keeping shown: [ChatMessage], at offset: Int, in next: [ChatMessage]) -> Int {
        guard let first = shown.first?.messageId,
              let index = next.firstIndex(where: { $0.messageId == first }) else { return hermesTranscriptBase }
        return max(0, offset - index)
    }

    private static func hermesKeepingOwnRows(of shown: [ChatMessage], in rows: [ChatMessage]) -> [ChatMessage] {
        var own: [(after: String?, row: ChatMessage)] = []
        var previous: String?
        for message in shown {
            if message.messageId?.hasPrefix(hermesBackgroundCardPrefix) == true || message.role?.hasPrefix("local_") == true {
                own.append((previous, message))
            } else {
                previous = message.messageId ?? ""
            }
        }
        guard !own.isEmpty else { return rows }
        var following: [String: [ChatMessage]] = [:]
        for (after, row) in own { if let after { following[after, default: []].append(row) } }
        var next = own.filter { $0.after == nil }.map(\.row)
        for row in rows {
            next.append(row)
            if let id = row.messageId, let mine = following.removeValue(forKey: id) { next += mine }
        }
        return next + own.filter { $0.after.map { following[$0] != nil } == true }.map(\.row)
    }

    private static func hermesBackgroundCard(_ task: HermesBackgroundTask, timestamp: Double?) -> ChatMessage {
        let body: String
        switch task.state {
        case .running: body = String(localized: "Running in the background…")
        case .finished(let text): body = text
        case .unavailable: body = String(localized: "Result unavailable.")
        }
        return ChatMessage(role: "local_assistant", content: backgroundResultText(prompt: task.prompt, answer: body),
                           timestamp: timestamp, messageId: hermesBackgroundCardPrefix + task.id)
    }

    private static func backgroundResultText(prompt: String, answer: String?) -> String {
        let trimmedAnswer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = trimmedAnswer.isEmpty ? String(localized: "No answer produced.") : trimmedAnswer
        let summary = prompt.count > 80 ? "\(prompt.prefix(80))..." : prompt

        return """
        **Background** \(summary)

        \(body)
        """
    }

    private static let slashCommandHelpText = String(localized: """
    Available mobile commands:

    `/help` - Show this command list.
    `/clear` - Clear this conversation on the server. Asks first.
    `/stop` - Stop the current response.
    `/new` - Open a fresh session.
    `/model <id>` - Switch this session's model.
    `/workspace <path>` - Switch this session's workspace.
    `/reasoning <level>` - Set reasoning display or effort.
    `/title <text>` - Rename this session.
    `/personality <name>` - Set or clear this session's personality.
    `/skills [query]` - Search available skills.
    `/queue <message>` - Queue a message for the next turn.
    `/steer <message>` - Steer the active response.
    `/interrupt <message>` - Stop the active response and send a new message.
    `/status` - Show session status.
    `/btw <question>` - Ask a side question without changing this chat.
    `/background <prompt>` - Run a parallel task and post the result here.
    `/bg <prompt>` - Alias for `/background`.
    `/branch [name]` - Fork this conversation.
    `/fork [name]` - Alias for `/branch`.
    `/compress [focus]` - Compress this session's context.
    `/compact [focus]` - Alias for `/compress`.
    `/undo` - Undo the last exchange.
    `/retry` - Retry the last turn.
    """)
}

extension ChatViewModel: ChatPendingActionCoordinatorDelegate {
    var pendingActionSessionID: String? { sessionID }
    var pendingActionHasActiveStream: Bool { activeStreamID != nil }
    var pendingActionIsStreamConnectionSuspended: Bool { isStreamConnectionSuspended }

    func pendingActionCoordinatorWillSubmitAction() {
        sendErrorMessage = nil
        lastError = nil
    }

    func pendingActionCoordinatorDidFailAction(_ error: Error) {
        lastError = error
        sendErrorMessage = error.localizedDescription
    }
}

extension ChatViewModel: ChatAttachmentCoordinatorDelegate {
    var attachmentSessionID: String? { sessionID }
    var attachmentIsViewingCachedData: Bool { isViewingCachedData }

    func attachmentCoordinatorWillUpload() {
        lastError = nil
    }

    func attachmentCoordinatorDidFail(_ error: Error) {
        lastError = error
    }
}

extension ChatViewModel: ChatStreamCoordinatorDelegate {
    var streamCoordinatorSessionID: String? { sessionID }
    var streamCoordinatorDisplayTitle: String { displayTitle }
    var streamCoordinatorHasRunningLiveToolCall: Bool { hasRunningLiveToolCall }
    var streamCoordinatorHasPendingPrompt: Bool {
        pendingActionCoordinator.hasPendingPrompt
    }
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool {
        latestServerLoadHadAssistantResponseAfterLatestUser
    }
    var streamCoordinatorStreamingAssistantMessageID: String? {
        get { streamingAssistantMessageID }
        set {
            if newValue == nil {
                flushPendingStreamingContent()
            }
            streamingAssistantMessageID = newValue
        }
    }

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async {
        await loadMessages(modelContext: modelContext)
    }

    func streamCoordinatorLatestAssistantMessageID() -> String? {
        Self.latestAssistantMessageID(in: messages)
    }

    func streamCoordinatorStartAuxiliaryMonitoring() {
        pendingActionCoordinator.startMonitoring()
    }

    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool) {
        pendingActionCoordinator.stopMonitoringForStreamTransition(clearClarification: clearPrompt)
    }

    func streamCoordinatorSaveSnapshotIfNeeded() {
        flushPendingStreamingContent()
        saveActiveStreamSnapshotIfNeeded()
    }

    @discardableResult
    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> ChatStreamSnapshotRestoreResult {
        restoreActiveStreamSnapshotIfAvailable(streamID: streamID)
    }

    func streamCoordinatorRemoveSnapshot(streamID: String?) {
        removeActiveStreamSnapshot(streamID: streamID)
    }

    func streamCoordinatorFlushPinnedLocalNoticesToTranscript() {
        flushPinnedLocalNoticesToTranscript()
    }

    func streamCoordinatorDrainQueuedSlashMessageIfIdle() {
        drainQueuedSlashMessageIfIdle()
    }

    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded() {
        refreshCompletedResponseTitleIfNeeded()
    }

    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool) {
        responseCompletionNeedsTranscriptRefresh = needsTranscriptRefresh
        responseCompletionHapticTrigger += 1
        recordRunEnd(.completed)
    }

    func streamCoordinatorDidFinishStream() {
        flushPendingStreamingContent()
        dismissSteeringConfirmation()
        clearSteerFailure()
        responseCompletionNeedsTranscriptRefresh = false
        if let ending = turn.latestRunEnding {
            if ending.endedAt != runEndRecordedAt, let outcome = ResponseCompletionOutcome(ending: ending.ending) {
                recordRunEnd(outcome)
            }
            latestRunOutcome = TranscriptTurnRunOutcome(
                turnKey: TranscriptTurnClassifier.latestTurnKey(in: messages, messageOffset: messagesOffset),
                startedAt: ending.startedAt,
                endedAt: ending.endedWhileWatching ? ending.endedAt : nil,
                ending: ending.ending
            )
        }
    }

    func streamCoordinatorDidReceiveErrorMessage(_ message: String) {
        sendErrorMessage = message
    }

    private func recordRunEnd(_ outcome: ResponseCompletionOutcome) {
        runEndRecordedAt = turn.latestRunEnding?.endedAt
        runEndOutcome = outcome
        runEndTrigger += 1
    }

    func streamCoordinatorDidReceiveRecoveryError(_ error: Error) {
        lastError = error
        sendErrorMessage = error.localizedDescription
        sendErrorIsFromStreamRecovery = true
    }

    func streamCoordinatorDidConfirmRecovery() {
        guard sendErrorIsFromStreamRecovery else { return }
        sendErrorMessage = nil
    }

    func streamCoordinatorDidStartConnection(isReplay: Bool) {
        if !isReplay {
            streamingHapticPulseThrottle.reset()
        }
        activeStreamReplayMatchedPrefixLength = 0
        activeStreamReplayMatchedInterimLength = 0
        activeStreamReplayMatchedReasoningLength = 0
        activeStreamReplayLoadedReasoningText = isReplay ? loadedReplayReasoningText() : ""
        activeStreamReplayLoadedToolCalls = isReplay ? loadedReplayToolCalls() : []
        activeStreamReplayLoadedToolMatchIndex = 0
        activeStreamReplayPendingLoadedToolMatchIndex = nil
        activeStreamReplayToolMatchIndex = 0
        activeStreamReplayPendingToolMatchIndex = nil
    }

    func streamCoordinatorDidResetRecoveryState() {
        activeStreamReplayMatchedPrefixLength = 0
        activeStreamReplayMatchedInterimLength = 0
        activeStreamReplayMatchedReasoningLength = 0
        activeStreamReplayLoadedReasoningText = ""
        activeStreamReplayLoadedToolCalls = []
        activeStreamReplayLoadedToolMatchIndex = 0
        activeStreamReplayPendingLoadedToolMatchIndex = nil
        activeStreamReplayToolMatchIndex = 0
        activeStreamReplayPendingToolMatchIndex = nil
    }

    @discardableResult
    func streamCoordinatorAppendToken(_ text: String) -> Bool {
        appendAssistantToken(text)
    }

    @discardableResult
    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        appendInterimAssistant(payload)
    }

    @discardableResult
    func streamCoordinatorAppendReasoning(_ text: String) -> Bool {
        appendReasoning(text)
    }

    @discardableResult
    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool {
        appendToolCall(payload)
    }

    @discardableResult
    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool {
        completeToolCall(payload)
    }

    @discardableResult
    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool {
        updateTitle(payload)
    }

    @discardableResult
    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool {
        flushPendingStreamingContent()
        let currentStreamingAssistantID = streamingAssistantMessageID
        let hasCompletedTranscript = payload.session?.messages?.isEmpty == false
        if let completedSession = payload.session {
            applyCompletedStreamSession(completedSession)
        }
        if let usage = payload.usage {
            contextWindowSnapshot = usage
        }
        if let finalTokensPerSecond = payload.usage?.tokensPerSecond,
           finalTokensPerSecond.isFinite,
           finalTokensPerSecond > 0,
           let currentStreamingAssistantID {
            let currentAssistantIndex = messages.firstIndex(where: { $0.messageId == currentStreamingAssistantID })
                ?? TranscriptTurnClassifier
                    .currentTurnAssistantAnchorIDs(in: messages, messageOffset: messagesOffset)
                    .last
                    .flatMap { currentAssistantAnchorID in
                        messages.indices.first { index in
                            TranscriptTurnClassifier.anchorID(
                                for: messages[index],
                                at: index,
                                messageOffset: messagesOffset
                            ) == currentAssistantAnchorID
                        }
                    }
            guard let index = currentAssistantIndex else {
                return hasCompletedTranscript
            }
            let message = messages[index]
            messages[index] = ChatMessage(
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                messageId: message.messageId,
                name: message.name,
                toolCallId: message.toolCallId,
                toolUseId: message.toolUseId,
                toolCalls: message.toolCalls,
                contentParts: message.contentParts,
                reasoning: message.reasoning,
                attachments: message.attachments,
                turnTps: finalTokensPerSecond
            )
        }
        return hasCompletedTranscript
    }

    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse) {
        guard let sessionID else { return }
        applyApprovalUpdate(update, sessionID: sessionID)
    }

    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse) {
        guard let sessionID else { return }
        applyClarificationUpdate(update, sessionID: sessionID)
    }

    @discardableResult
    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }

        enqueueQueuedSlashMessage(message, attachments: [])
        appendLocalNoticeMessage(String(localized: "Steering hint was not consumed before the response ended, so it was queued for the next turn."))
        return true
    }
}

extension ChatViewModel: HermesChatTurnDelegate {
    func hermesTurnDidStart(prompt: HermesQueuedPrompt?) {
        flushPendingStreamingContent()
        archiveLiveActivityForNewTurn()
        streamingAssistantMessageID = nil
        responseCompletionNeedsTranscriptRefresh = false
        if let prompt {
            messages.append(Self.hermesPromptRow(prompt, id: "local-\(UUID().uuidString)", timestamp: Date().timeIntervalSince1970))
        }
    }

    private static func hermesPromptRow(_ prompt: HermesQueuedPrompt, id: String, timestamp: Double?) -> ChatMessage {
        HermesChatTurnCoordinator.displayed(ChatMessage(
            role: "user", content: prompt.text, timestamp: timestamp, messageId: id,
            attachments: prompt.images.isEmpty ? nil : prompt.images
        ))
    }

    func hermesTurnDidComplete(reply: String) {
        flushPendingStreamingContent()
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = streamingAssistantMessageID.flatMap { id in messages.first { $0.messageId == id }?.content } ?? ""
        guard !text.isEmpty, !shown.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(text) else { return }
        appendInterimAssistant(InterimAssistantStreamEvent(text: text, alreadyStreamed: false))
        flushPendingStreamingContent()
    }

    func hermesReplaceTranscript(_ transcript: HermesChatTranscript) {
        if isViewingCachedData {
            let isBotChat = if case .canonicalChat = hermesTurn?.engine.target { true } else { false }
            guard transcript.newestCoverage != nil || isCachedCopyProvisional && !isBotChat else { return }
            isViewingCachedData = false
        }
        hermesCachedWorkAnchorIDs = []
        resetPendingStreamingContentBuffers()
        let next = Self.hermesKeepingOwnRows(of: messages, in: transcript.messages + transcript.live)
            + (transcript.streamingReply.map { [$0] } ?? [])
        messagesOffset = Self.hermesMessagesOffset(keeping: messages, at: messagesOffset, in: next)
        messages = next
        transcriptRevision &+= 1
        hasOlderMessages = transcript.hasOlder
        setCompletedToolCallGroups(transcript.toolCallGroups)
        completedReasoningGroups = transcript.reasoningGroups
        hermesHistoryGroupIDs = Set(transcript.toolCallGroups.map(\.id) + transcript.reasoningGroups.map(\.id))
        hermesCompaction = transcript.compaction
        recomputeCompressionReferenceCard()
        liveToolCalls = []
        liveReasoningText = ""
        toolCallAnchorMessageID = nil
        reasoningAnchorMessageID = nil
        streamingAssistantMessageID = transcript.streamingReply?.messageId
        if let title = transcript.title { applyLiveActivitySessionTitle(title) }
        if needsReplacedChatNotice, transcript.newestCoverage != nil {
            needsReplacedChatNotice = false
            appendLocalNoticeMessage(String(localized: "Hermes started a new Bot Chat. The earlier conversation is in Sessions under its new name."))
            hermesTurn?.replacedChatNoticeDidShow()
            if case .canonicalChat(let profile) = hermesTurn?.engine.target, let root = hermesCacheRoot {
                removeCachedBotChats(exceptRoot: root, profile: profile)
            }
        }
        if !messages.isEmpty { transcriptRelayoutScrollToken += 1 }
        cacheHermesHistory(transcript)
        deliverWaitingSendIfReady()
    }

    func hermesPrependHistory(_ transcript: HermesChatTranscript) {
        let shown = Set(messages.compactMap(\.messageId))
        let next = Array(transcript.messages.prefix { $0.messageId.map(shown.contains) != true }) + messages
        messagesOffset = Self.hermesMessagesOffset(keeping: messages, at: messagesOffset, in: next)
        messages = next
        transcriptRevision &+= 1
        hasOlderMessages = transcript.hasOlder
        setCompletedToolCallGroups(transcript.toolCallGroups
            + completedToolCallGroups.filter { !hermesHistoryGroupIDs.contains($0.id) })
        completedReasoningGroups = transcript.reasoningGroups
            + completedReasoningGroups.filter { !hermesHistoryGroupIDs.contains($0.id) }
        hermesHistoryGroupIDs = Set(transcript.toolCallGroups.map(\.id) + transcript.reasoningGroups.map(\.id))
        hermesCompaction = transcript.compaction
        recomputeCompressionReferenceCard()
        cacheHermesHistory(transcript)
    }

    func hermesHistoryDidFail(_ error: Error, message: String) {
        guard !showCachedHermesTranscript(after: error) else { return }
        errorMessage = message
    }

    func hermesAttachDidFail(_ error: Error) {
        showCachedHermesTranscript(after: error)
    }

    func hermesBotChatWasReplaced() {
        messages = []
        hasOlderMessages = false
        latestRunOutcome = nil
        transcriptRevision &+= 1
        isViewingCachedData = false
        needsReplacedChatNotice = true
        if waitingSend != nil {
            leaveWaitingSend()
            sendErrorMessage = Self.notSentToReplacedChat
        }
    }

    private static var notSentToReplacedChat: String {
        String(localized: "Not sent: Hermes started a new Bot Chat.")
    }

    func hermesDidIdentify(root: String) {
        guard let engine = hermesTurn?.engine else { return }
        hermesCacheEpoch = CacheStore.hermesCacheEpoch(serverURL: engine.server)
        guard case .canonicalChat(let profile) = engine.target else { return }
        let cachedRoot = hermesCacheRoot ?? hermesCache.flatMap {
            try? CacheStore.cachedHermesBotChatRoot(serverURL: engine.server, connectionID: engine.connection.id,
                                                    profile: profile, in: $0)
        }
        if let cachedRoot, cachedRoot != root, !needsReplacedChatNotice {
            hermesTurn?.noteReplacedChat()
            hermesBotChatWasReplaced()
        }
        hermesCacheRoot = root
        guard !needsReplacedChatNotice else { return }
        removeCachedBotChats(exceptRoot: root, profile: profile)
    }

    private func removeCachedBotChats(exceptRoot root: String, profile: String) {
        guard let hermesCache, let engine = hermesTurn?.engine else { return }
        do {
            try CacheStore.removeHermesBotChats(exceptRoot: root, serverURL: engine.server, connectionID: engine.connection.id,
                                                profile: profile, in: hermesCache)
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func showCachedHermesTranscript(after error: Error) -> Bool {
        let usesCache = CacheFallbackPolicy.shouldUseCache(for: error)
        guard isCachedCopyProvisional else { return usesCache && showCachedHermesTranscript(provisional: false) }
        isCachedCopyProvisional = false
        if case .canonicalChat = hermesTurn?.engine.target { return false }
        guard !usesCache else { return true }
        messages = []
        transcriptRevision &+= 1
        isViewingCachedData = false
        return false
    }

    private func showCachedHermesTranscriptBeforeAttach(_ hermes: HermesChatTurnCoordinator) {
        let engine = hermes.engine
        let isBotChat = if case .canonicalChat = engine.target { true } else { false }
        if engine.connectionState == .connected {
            if isBotChat && hermes.hasHistoryFailure { showCachedHermesTranscript(provisional: false) }
            return
        }
        guard hermes.needsSignIn || engine.isActive && engine.connectionState == .disconnected else {
            showCachedHermesTranscript(provisional: true)
            return
        }
        if isBotChat { showCachedHermesTranscript(provisional: false) }
    }

    @discardableResult
    private func showCachedHermesTranscript(provisional: Bool) -> Bool {
        guard messages.isEmpty, let scope = hermesCacheScope() else { return false }
        var cached: [ChatMessage] = []
        var workAnchorIDs: Set<String> = []
        do {
            for readScope in [scope.scope, scope.fallback].compactMap({ $0 }) where cached.isEmpty {
                (cached, workAnchorIDs) = try CacheStore.cachedHermesTranscript(
                    serverURL: scope.server, scope: readScope, in: scope.context, limit: HermesREST.transcriptPageSize)
            }
        } catch {
            cacheErrorMessage = error.localizedDescription
            return false
        }
        guard !cached.isEmpty else { return false }
        messagesOffset = Self.hermesTranscriptBase
        messages = cached
        transcriptRevision &+= 1
        hasOlderMessages = false
        isViewingCachedData = true
        isCachedCopyProvisional = provisional
        errorMessage = nil
        setCompletedToolCallGroups([])
        completedReasoningGroups = []
        hermesHistoryGroupIDs = []
        hermesCachedWorkAnchorIDs = workAnchorIDs
        hermesCompaction = nil
        recomputeCompressionReferenceCard()
        transcriptRelayoutScrollToken += 1
        return true
    }

    private func cacheHermesHistory(_ transcript: HermesChatTranscript) {
        guard let scope = hermesCacheScope(), hermesCacheEpoch == CacheStore.hermesCacheEpoch(serverURL: scope.server) else { return }
        do {
            let workAnchorIDs = Set(transcript.toolCallGroups.compactMap(\.anchorMessageID)
                + transcript.reasoningGroups.compactMap(\.anchorMessageID))
            try CacheStore.cacheHermesMessages(transcript.messages, workAnchorIDs: workAnchorIDs,
                                               newestCoverage: transcript.newestCoverage,
                                               serverURL: scope.server, scope: scope.scope, in: scope.context)
            if let sameRoot = scope.sameRoot, let coverage = transcript.newestCoverage {
                try CacheStore.dropHermesMessagesTheHostCut(from: transcript.messages, newestCoverage: coverage,
                                                            serverURL: scope.server, scope: sameRoot, in: scope.context)
            }
        } catch {
            cacheErrorMessage = error.localizedDescription
        }
    }

    private func hermesCacheScope() -> (context: ModelContext, server: URL, scope: String, fallback: String?, sameRoot: String?)? {
        guard let hermesCache, let engine = hermesTurn?.engine else { return nil }
        switch engine.target {
        case .session(let profile, let key):
            if let hermesBotChatRoot {
                let connection = engine.connection.id
                let bot = CacheStore.hermesBotChatScope(connectionID: connection, profile: profile, root: hermesBotChatRoot)
                return (hermesCache, engine.server,
                        CacheStore.hermesArchivedBotChatScope(connectionID: connection, profile: profile, root: hermesBotChatRoot),
                        bot, bot)
            }
            let root = hermesCacheRoot
                ?? (try? CacheStore.hermesLineageRoot(forKey: key, profile: profile, serverURL: engine.server, in: hermesCache))
                ?? hermesLineageRoot ?? key
            hermesCacheRoot = root
            return (hermesCache, engine.server, CacheStore.hermesScope(profile: profile, lineageRoot: root), nil, nil)
        case .canonicalChat(let profile):
            guard let root = hermesCacheRoot ?? engine.root
                ?? (try? CacheStore.cachedHermesBotChatRoot(serverURL: engine.server, connectionID: engine.connection.id,
                                                            profile: profile, in: hermesCache)) else { return nil }
            hermesCacheRoot = root
            let connection = engine.connection.id
            return (hermesCache, engine.server, CacheStore.hermesBotChatScope(connectionID: connection, profile: profile, root: root),
                    nil, CacheStore.hermesArchivedBotChatScope(connectionID: connection, profile: profile, root: root))
        case .new:
            return nil
        }
    }

    func hermesApplyUsage(_ usage: ContextWindowSnapshot) {
        guard contextWindowSnapshot != usage else { return }
        contextWindowSnapshot = usage
    }

    func hermesApplyModel(_ model: String) {
        guard currentModel != model else { return }
        currentModel = model
    }

    func hermesConnectionDidChange(failure: String?, unserved: HermesUnservedProfile?, mayRetry: Bool) {
        guard let failure else {
            if errorMessage != nil { errorMessage = nil }
            if sendErrorIsFromStreamRecovery { sendErrorMessage = nil }
            releaseSubmissionMark()
            deliverWaitingSendIfReady()
            if needsHermesForkCheck { Task { [weak self] in await self?.resolveHermesForkOrigin() } }
            return
        }
        if messages.isEmpty {
            errorMessage = failure
            errorMayRetry = mayRetry
            errorUnserved = unserved
        } else {
            sendErrorMessage = failure
            sendErrorIsFromStreamRecovery = true
            errorUnserved = unserved
        }
    }

    func hermesDraftKeyDidChange(from: ChatDraftKey, to: ChatDraftKey) {
        drafts.moveDraft(from: from, to: to)
        onHermesDraftKeyChange?(to)
    }

    func hermesRequestDidFail(_ message: String) {
        sendErrorMessage = message
    }

    func hermesBackgroundDidChange(_ task: HermesBackgroundTask) {
        let id = Self.hermesBackgroundCardPrefix + task.id
        if let index = messages.firstIndex(where: { $0.messageId == id }) {
            messages[index] = Self.hermesBackgroundCard(task, timestamp: messages[index].timestamp)
        } else {
            messages.append(Self.hermesBackgroundCard(task, timestamp: Date().timeIntervalSince1970))
        }
        scheduleStreamingScrollTrigger()
    }

    func hermesGoalDidChange(_ goal: SubmittedGoal?) {
        currentGoal = goal
        if goal != nil { hasActivatedGoalCommand = true }
    }

    func hermesWorkspaceDidChange() {
        resetFileChipReferences(reloadingOpenQuery: true)
    }
}

struct ActiveChatStreamSnapshot: Equatable {
    let messages: [ChatMessage]
    let messagesOffset: Int
    let displayTitle: String
    let completedToolCallGroups: [ToolCallGroup]
    let completedReasoningGroups: [ReasoningGroup]
    let liveToolCalls: [ToolCall]
    let liveReasoningText: String
    let activeStreamLastEventID: String?
    let streamingAssistantMessageID: String?
    let toolCallAnchorMessageID: String?
    let reasoningAnchorMessageID: String?
    let contextWindowSnapshot: ContextWindowSnapshot?
    let localAttachmentPreviews: [String: [String: Data]]
    let pinnedLocalNotices: [String]
}

private struct ActiveChatStreamSnapshotKey: Hashable {
    let server: String
    let sessionID: String
    let streamID: String
}

private final class ActiveChatStreamSnapshotStore {
    static let shared = ActiveChatStreamSnapshotStore()

    private let lock = NSLock()
    private var snapshots: [ActiveChatStreamSnapshotKey: ActiveChatStreamSnapshot] = [:]

    private init() {}

    func save(
        _ snapshot: ActiveChatStreamSnapshot,
        server: URL,
        sessionID: String,
        streamID: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[key(server: server, sessionID: sessionID, streamID: streamID)] = snapshot
    }

    func snapshot(server: URL, sessionID: String, streamID: String) -> ActiveChatStreamSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[key(server: server, sessionID: sessionID, streamID: streamID)]
    }

    func remove(server: URL, sessionID: String, streamID: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeValue(forKey: key(server: server, sessionID: sessionID, streamID: streamID))
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeAll()
    }

    private func key(server: URL, sessionID: String, streamID: String) -> ActiveChatStreamSnapshotKey {
        ActiveChatStreamSnapshotKey(
            server: server.absoluteString,
            sessionID: sessionID,
            streamID: streamID
        )
    }
}

struct QueuedSlashMessage {
    let text: String
    let attachments: [PendingAttachment]
}

struct ReasoningGroup: Identifiable, Equatable {
    let id: String
    let anchorMessageID: String?
    let text: String

    init(id: String = UUID().uuidString, anchorMessageID: String?, text: String) {
        self.id = id
        self.anchorMessageID = anchorMessageID
        self.text = text
    }
}

struct TranscriptMessage: Identifiable, Equatable {
    let loadedIndex: Int
    let renderID: String
    let anchorID: String
    let message: ChatMessage

    var id: String { renderID }
}

struct CompressionReferenceCard: Equatable {
    let referenceText: String
    let afterRenderID: String?
}

struct MessageActionContext: Equatable, Identifiable {
    var id: String { messageID }

    enum Role: Equatable {
        case user
        case assistant
    }

    let role: Role
    let visibleIndex: Int
    let fullHistoryIndex: Int
    let keepCountThroughMessage: Int
    let messageID: String
    let copyText: String
    let listenText: String?
    let offersHistoryActions: Bool
    let offersFork: Bool

    init?(message: ChatMessage, visibleIndex: Int, messagesOffset: Int?, offersHistoryActions: Bool = true,
          offersFork: Bool = true) {
        guard visibleIndex >= 0 else { return nil }

        switch message.role {
        case "user":
            role = .user
        case "assistant":
            role = .assistant
        default:
            return nil
        }

        let content = message.content ?? ""
        guard !content.isEmpty else { return nil }

        self.visibleIndex = visibleIndex
        fullHistoryIndex = max(0, messagesOffset ?? 0) + visibleIndex
        keepCountThroughMessage = fullHistoryIndex + 1
        messageID = message.id
        copyText = content
        listenText = role == .assistant ? SpeechTextNormalizer.normalizedAssistantText(content) : nil
        self.offersHistoryActions = offersHistoryActions
        self.offersFork = offersFork
    }
}

extension ChatViewModel {
    nonisolated static func reasoningDisplayGroups(
        messages: [ChatMessage],
        messageOffset: Int? = nil,
        archivedGroups: [ReasoningGroup]
    ) -> [ReasoningGroup] {
        var cache = ReasoningCandidateCache()
        return reasoningDisplayGroups(
            messages: messages,
            messageOffset: messageOffset,
            archivedGroups: archivedGroups,
            cache: &cache
        )
    }

    nonisolated static func reasoningDisplayGroups(
        messages: [ChatMessage],
        messageOffset: Int?,
        archivedGroups: [ReasoningGroup],
        cache: inout ReasoningCandidateCache
    ) -> [ReasoningGroup] {
        let turnKeysByMessageID = TranscriptTurnClassifier.assistantTurnKeysByAnchorID(
            messages,
            messageOffset: messageOffset
        )
        let assistantMessagesByID = messages.enumerated().reduce(into: [String: ChatMessage]()) { result, entry in
            let message = entry.element
            guard message.role == "assistant" else { return }
            result[TranscriptTurnClassifier.anchorID(for: message, at: entry.offset, messageOffset: messageOffset)] = message
        }
        var candidates: [ReasoningDisplayCandidate] = []
        var order = 0

        for group in archivedGroups {
            let visibleText = group.anchorMessageID.flatMap { assistantMessagesByID[$0]?.content }
            appendReasoningCandidate(
                cacheID: "archived:\(group.id)",
                text: group.text,
                anchorMessageID: group.anchorMessageID,
                turnKey: group.anchorMessageID.flatMap { turnKeysByMessageID[$0] } ?? "archived:\(group.anchorMessageID ?? group.id)",
                visibleText: visibleText,
                order: &order,
                candidates: &candidates,
                cache: &cache
            )
        }

        for (messageIndex, message) in messages.enumerated() where message.role == "assistant" {
            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: messageIndex,
                messageOffset: messageOffset
            )
            let turnKey = turnKeysByMessageID[anchorID] ?? "message:\(anchorID)"
            for text in reasoningTexts(from: message) {
                appendReasoningCandidate(
                    cacheID: "message:\(anchorID)",
                    text: text,
                    anchorMessageID: anchorID,
                    turnKey: turnKey,
                    visibleText: message.content,
                    order: &order,
                    candidates: &candidates,
                    cache: &cache
                )
            }
        }
        cache.finishPass()

        var latestCandidateIndexByKey: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            latestCandidateIndexByKey["\(candidate.turnKey)::\(candidate.dedupeKey)"] = index
        }

        return candidates.enumerated().compactMap { index, candidate in
            let key = "\(candidate.turnKey)::\(candidate.dedupeKey)"
            guard latestCandidateIndexByKey[key] == index else { return nil }

            return ReasoningGroup(
                id: "reasoning-\(candidate.anchorMessageID ?? "unanchored")-\(candidate.order)",
                anchorMessageID: candidate.anchorMessageID,
                text: candidate.text
            )
        }
    }

    nonisolated static func transcriptMessages(
        from messages: [ChatMessage],
        messageOffset: Int? = nil,
        preservingEmptyAssistantID: String? = nil,
        renderedActivityAnchorIDs: Set<String>? = nil
    ) -> [TranscriptMessage] {
        transcriptMessages(
            from: messages,
            messageOffset: messageOffset,
            hidingStreamingAssistantID: nil,
            preservingEmptyAssistantID: preservingEmptyAssistantID,
            renderedActivityAnchorIDs: renderedActivityAnchorIDs
        )
    }

    nonisolated static func transcriptMessages(
        from messages: [ChatMessage],
        messageOffset: Int? = nil,
        hidingStreamingAssistantID streamingAssistantID: String?,
        preservingEmptyAssistantID: String? = nil,
        renderedActivityAnchorIDs: Set<String>? = nil
    ) -> [TranscriptMessage] {
        let offset = max(0, messageOffset ?? 0)
        let activityAnchorIDs = renderedActivityAnchorIDs ?? transcriptActivityAnchorIDs(
            reasoningGroups: reasoningDisplayGroups(
                messages: messages,
                messageOffset: messageOffset,
                archivedGroups: []
            ),
            toolCallGroups: ToolCallGroup.groups(
                persistedToolCalls: [],
                messages: messages,
                messageOffset: messageOffset
            )
        )
        var transcriptMessages: [TranscriptMessage] = []
        transcriptMessages.reserveCapacity(messages.count)

        for (loadedIndex, message) in messages.enumerated() {
            guard message.role != "tool" else { continue }
            guard !TranscriptTurnClassifier.isToolResultOnlyMessage(message) else { continue }
            if let streamingAssistantID, message.messageId == streamingAssistantID {
                continue
            }

            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: loadedIndex,
                messageOffset: messageOffset
            )
            guard anchorID == preservingEmptyAssistantID
                || activityAnchorIDs.contains(anchorID)
                || hasTranscriptMessageRowContent(message)
            else {
                continue
            }
            let absoluteIndex = offset + loadedIndex
            let renderID = "transcript:\(absoluteIndex)"

            transcriptMessages.append(TranscriptMessage(
                loadedIndex: loadedIndex,
                renderID: renderID,
                anchorID: anchorID,
                message: message
            ))
        }

        return transcriptMessages
    }

    nonisolated private static func transcriptActivityAnchorIDs(
        reasoningGroups: [ReasoningGroup],
        toolCallGroups: [ToolCallGroup]
    ) -> Set<String> {
        Set(reasoningGroups.compactMap(\.anchorMessageID))
            .union(toolCallGroups.compactMap(\.anchorMessageID))
    }

    nonisolated private static func hasTranscriptMessageRowContent(_ message: ChatMessage) -> Bool {
        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        return message.role == "user" && message.attachments?.isEmpty == false
    }

    nonisolated static func hermesCompressionReferenceCard(
        _ compaction: HermesCompaction,
        messages: [ChatMessage],
        transcriptMessages: [TranscriptMessage]
    ) -> CompressionReferenceCard {
        let anchor = compaction.anchorMessageID.flatMap { id in messages.firstIndex { $0.messageId == id } }
        let afterRenderID = anchor.flatMap { index in transcriptMessages.last { $0.loadedIndex <= index }?.renderID }
        return CompressionReferenceCard(referenceText: compaction.referenceText, afterRenderID: afterRenderID)
    }

    nonisolated static func compressionReferenceCard(
        messages: [ChatMessage],
        messagesOffset: Int,
        transcriptMessages: [TranscriptMessage],
        metadata: CompressionAnchorMetadata?
    ) -> CompressionReferenceCard? {
        guard let resolution = CompressionAnchorResolver.resolve(
            messages: messages,
            messagesOffset: messagesOffset,
            metadata: metadata
        ) else {
            return nil
        }

        switch resolution.placement {
        case .top:
            return CompressionReferenceCard(referenceText: resolution.referenceText, afterRenderID: nil)
        case .afterLoadedMessageIndex(let loadedIndex):
            let afterRenderID = transcriptMessages.last { $0.loadedIndex <= loadedIndex }?.renderID
            return CompressionReferenceCard(referenceText: resolution.referenceText, afterRenderID: afterRenderID)
        }
    }

    nonisolated private static func appendReasoningCandidate(
        cacheID: String,
        text: String,
        anchorMessageID: String?,
        turnKey: String,
        visibleText: String?,
        order: inout Int,
        candidates: inout [ReasoningDisplayCandidate],
        cache: inout ReasoningCandidateCache
    ) {
        let derived = cache.derived(id: cacheID, reasoning: text, visibleText: visibleText) {
            strippedVisibleAssistantEcho(fromReasoning: text, visibleText: visibleText).map { stripped in
                ReasoningCandidateCache.Derived(text: stripped, dedupeKey: normalizedReasoningKey(stripped))
            }
        }
        guard let derived else { return }

        candidates.append(
            ReasoningDisplayCandidate(
                order: order,
                anchorMessageID: anchorMessageID,
                turnKey: turnKey,
                text: derived.text,
                dedupeKey: derived.dedupeKey
            )
        )
        order += 1
    }

    nonisolated private static func reasoningTexts(from message: ChatMessage) -> [String] {
        if let partsText = reasoningText(fromContentParts: message.contentParts) {
            return [partsText]
        }

        if let reasoning = nonEmptyReasoningText(message.reasoning) {
            return [reasoning]
        }

        if let contentReasoning = reasoningText(fromContent: message.content) {
            return [contentReasoning]
        }

        return []
    }

    nonisolated private static func reasoningText(fromContentParts parts: [JSONValue]?) -> String? {
        guard let parts else { return nil }

        let text = parts.compactMap { part -> String? in
            guard case .object(let object) = part,
                  let type = jsonStringValue(object["type"]),
                  type == "thinking" || type == "reasoning"
            else {
                return nil
            }

            return jsonStringValue(object["thinking"])
                ?? jsonStringValue(object["reasoning"])
                ?? jsonStringValue(object["text"])
        }
        .joined(separator: "\n")

        return nonEmptyReasoningText(text)
    }

    nonisolated private static func reasoningText(fromContent content: String?) -> String? {
        guard let content = nonEmptyReasoningText(content) else { return nil }

        if let text = leadingDelimitedText(in: content, open: "<think>", close: "</think>") {
            return text
        }

        if let text = leadingDelimitedText(in: content, open: "<|channel|>thought", close: "<channel|>") {
            return text
        }

        return leadingDelimitedText(in: content, open: "<|turn|>thinking\n", close: "<turn|>")
    }

    nonisolated private static func leadingDelimitedText(in content: String, open: String, close: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(open),
              let closeRange = trimmed.range(of: close, range: trimmed.index(trimmed.startIndex, offsetBy: open.count)..<trimmed.endIndex)
        else {
            return nil
        }

        let text = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: open.count)..<closeRange.lowerBound])
        return nonEmptyReasoningText(text)
    }

    nonisolated private static func strippedVisibleAssistantEcho(
        fromReasoning reasoning: String,
        visibleText: String?
    ) -> String? {
        var output = reasoning
        let visibleParagraphs = visibleText?
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 } ?? []

        for paragraph in visibleParagraphs {
            output = output.replacingOccurrences(of: paragraph, with: "")
        }

        return nonEmptyReasoningText(output)
    }

    nonisolated private static func normalizedReasoningKey(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func nonEmptyReasoningText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func jsonStringValue(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null, nil:
            return nil
        }
    }
}

private struct ReasoningDisplayCandidate {
    let order: Int
    let anchorMessageID: String?
    let turnKey: String
    let text: String
    let dedupeKey: String
}

struct ReasoningCandidateCache {
    struct Derived {
        let text: String
        let dedupeKey: String
    }

    private struct Entry {
        let reasoning: String
        let visibleText: String?
        let derived: Derived?
    }

    private var previousPass: [String: Entry] = [:]
    private var currentPass: [String: Entry] = [:]

    mutating func derived(
        id: String,
        reasoning: String,
        visibleText: String?,
        derive: () -> Derived?
    ) -> Derived? {
        let entry: Entry
        if let cached = previousPass[id], cached.reasoning == reasoning, cached.visibleText == visibleText {
            entry = cached
        } else {
            entry = Entry(reasoning: reasoning, visibleText: visibleText, derived: derive())
        }
        currentPass[id] = entry
        return entry.derived
    }

    mutating func finishPass() {
        previousPass = currentPass
        currentPass = [:]
    }
}

private extension ToolCall {
    func matchesStableToolID(_ stableID: String) -> Bool {
        id.nonEmptyStableToolID == stableID
    }

    func matchesReplayToolStart(_ payload: ToolStreamEvent) -> Bool {
        matchesReplayToolIdentity(payload)
    }

    func matchesReplayToolCompletion(_ payload: ToolStreamEvent) -> Bool {
        matchesReplayToolIdentity(payload)
    }

    private func matchesReplayToolIdentity(_ payload: ToolStreamEvent) -> Bool {
        if let payloadStableID = payload.stableID?.nonEmptyReplayMatchText,
           let stableID = id.nonEmptyStableToolID {
            return stableID == payloadStableID
        }

        var didCompareStableField = false

        if let payloadName = payload.name?.nonEmptyReplayMatchText {
            didCompareStableField = true
            guard name?.nonEmptyReplayMatchText == payloadName else { return false }
        }

        if let payloadArgs = payload.args {
            didCompareStableField = true
            guard args == payloadArgs else { return false }
        }

        if didCompareStableField {
            return true
        }

        guard let payloadPreview = payload.preview?.nonEmptyReplayMatchText,
              let preview = preview?.nonEmptyReplayMatchText
        else {
            return false
        }

        return preview == payloadPreview
    }

    func applyingCompletionPayload(_ payload: ToolStreamEvent) -> ToolCall {
        ToolCall(
            id: id.nonEmptyStableToolID == nil ? payload.stableID ?? id : id,
            presentationID: presentationID,
            name: payload.name ?? name,
            preview: payload.preview ?? preview,
            args: payload.args ?? args,
            duration: payload.duration,
            isError: payload.isError,
            isCompleted: true,
            startedAt: startedAt
        )
    }
}

private extension String {
    var nonEmptyReplayMatchText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nonEmptyStableToolID: String? {
        guard let stableID = nonEmptyReplayMatchText,
              !stableID.hasPrefix("live-tool-"),
              !stableID.hasPrefix("message-tool-"),
              !stableID.hasPrefix("persisted-tool-")
        else {
            return nil
        }

        return stableID
    }
}

struct SpeechTextNormalizer {
    static func normalizedAssistantText(_ text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: #"^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s{0,3}[-*+]\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s{0,3}>\s?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            }

        let normalized = lines
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.isEmpty ? nil : normalized
    }
}

enum ServerTTSPolicy {
    static let maximumTextLength = 5000
    static let maximumHermesTextLength = 4000
    static let defaultVoice = "en-US-AriaNeural"

    static func shouldUseServerTTS(for text: String, onHermes: Bool = false) -> Bool {
        onHermes ? text.unicodeScalars.count <= maximumHermesTextLength : text.count <= maximumTextLength
    }
}

@MainActor
protocol ListenAudioPlaying: AnyObject {
    var onFinish: (@MainActor () -> Void)? { get set }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var rate: Float { get set }

    func prepareToPlay()
    @discardableResult
    func play() -> Bool
    func pause()
    func stop()
}

@MainActor
final class ListenAudioPlayer: NSObject, ListenAudioPlaying {
    private let player: AVAudioPlayer
    var onFinish: (@MainActor () -> Void)?
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var duration: TimeInterval { player.duration }
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
        player.enableRate = true
    }

    func prepareToPlay() {
        player.prepareToPlay()
    }

    @discardableResult
    func play() -> Bool {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
    }
}

extension ListenAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.onFinish?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.onFinish?()
        }
    }
}

enum OnDeviceSpeech {
    static func render(_ text: String) async throws -> Data {
        let render = OnDeviceSpeechRender(text: text)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { render.start(resuming: $0) }
        } onCancel: {
            render.cancel()
        }
    }
}

private final class OnDeviceSpeechRender: @unchecked Sendable {
    private let text: String
    private let synthesizer = AVSpeechSynthesizer()
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("listen-\(UUID().uuidString).caf")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var isCancelled = false
    private var file: AVAudioFile?

    init(text: String) {
        self.text = text
    }

    func start(resuming continuation: CheckedContinuation<Data, Error>) {
        let cancelled = lock.withLock {
            if !isCancelled { self.continuation = continuation }
            return isCancelled
        }
        guard !cancelled else { return continuation.resume(throwing: CancellationError()) }
        synthesizer.write(AVSpeechUtterance(string: text)) { [weak self] buffer in
            self?.receive(buffer)
        }
    }

    func cancel() {
        let continuation = lock.withLock {
            isCancelled = true
            return takeContinuation()
        }
        guard let continuation else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finish(continuation, with: .failure(CancellationError()))
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let buffer = buffer as? AVAudioPCMBuffer else { return }
        let ending: (CheckedContinuation<Data, Error>, Result<Void, Error>)? = lock.withLock {
            guard continuation != nil else { return nil }
            let outcome: Result<Void, Error>
            if buffer.frameLength == 0 {
                outcome = file == nil ? .failure(CocoaError(.fileNoSuchFile)) : .success(())
            } else {
                do {
                    try write(buffer)
                    return nil
                } catch {
                    outcome = .failure(error)
                }
            }
            return takeContinuation().map { ($0, outcome) }
        }
        if let (continuation, outcome) = ending { finish(continuation, with: outcome) }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ], commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        }
        try file?.write(from: buffer)
    }

    private func takeContinuation() -> CheckedContinuation<Data, Error>? {
        defer { continuation = nil }
        return continuation
    }

    private func finish(_ continuation: CheckedContinuation<Data, Error>, with outcome: Result<Void, Error>) {
        lock.withLock { file = nil }
        defer { try? FileManager.default.removeItem(at: url) }
        continuation.resume(with: outcome.flatMap { Result { try Data(contentsOf: url, options: .alwaysMapped) } })
    }
}

enum ListenAudioSessionConfiguration {
    static let category = AVAudioSession.Category.playback
    static let mode = AVAudioSession.Mode.spokenAudio
    static let deactivationOptions = AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation
}

@MainActor
protocol ListenAudioSessionControlling {
    func activate()
    func deactivate()
}

@MainActor
final class ListenAudioSessionController: ListenAudioSessionControlling {
    func activate() {
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            ListenAudioSessionConfiguration.category,
            mode: ListenAudioSessionConfiguration.mode
        )
        try? session.setActive(true)
    }

    func deactivate() {
        guard !ComposerAudioCaptureState.shared.isCapturing else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: ListenAudioSessionConfiguration.deactivationOptions
        )
    }
}
