import Foundation
import Observation
import SwiftData

struct HermesUnservedProfile: Equatable {
    let profile: String
    let hostReason: String?
}

@MainActor protocol HermesChatTurnDelegate: ChatStreamCoordinatorDelegate {
    func hermesTurnDidStart(prompt: HermesQueuedPrompt?)
    func hermesTurnDidComplete(reply: String)
    func hermesReplaceTranscript(_ transcript: HermesChatTranscript)
    func hermesPrependHistory(_ transcript: HermesChatTranscript)
    func hermesHistoryDidFail(_ error: Error, message: String)
    func hermesAttachDidFail(_ error: Error)
    func hermesBotChatWasReplaced()
    func hermesDidIdentify(root: String)
    func hermesApplyUsage(_ usage: ContextWindowSnapshot)
    func hermesApplyModel(_ model: String)
    func hermesConnectionDidChange(failure: String?, unserved: HermesUnservedProfile?, mayRetry: Bool)
    func hermesDraftKeyDidChange(from: ChatDraftKey, to: ChatDraftKey)
    func hermesRequestDidFail(_ message: String)
    func hermesBackgroundDidChange(_ task: HermesBackgroundTask)
    func hermesGoalDidChange(_ goal: SubmittedGoal?)
    func hermesWorkspaceDidChange()
}

struct HermesSessionChat: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let connection: BotConnection
    var target: ConversationTarget
    var parentKey: String? = nil
    var botChatRoot: String? = nil
    var linkedRoot: String? = nil
    var lineageRoot: String? = nil
    var title: String? = nil
    var workspace: String? = nil
    var model: String? = nil
    var bot: BotProfile? = nil
    var autoStartsVoiceInput = false
    var shareNotice: SharedSkipsNotice? = nil

    var policy: HermesChatPolicy { HermesChatPolicy(target: target, botChatRoot: botChatRoot) }

    var isCronRun: Bool {
        guard case .session(_, let key) = target else { return false }
        return key.hasPrefix("cron_") || lineageRoot?.hasPrefix("cron_") == true
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HermesChatTranscript: Equatable {
    var messages: [ChatMessage]
    var toolCallGroups: [ToolCallGroup]
    var reasoningGroups: [ReasoningGroup]
    var compaction: HermesCompaction?
    var hasOlder = false
    var live: [ChatMessage] = []
    var streamingReply: ChatMessage?
    var title: String?
    var newestCoverage: HermesNewestCoverage?

    mutating func anchorTrailingCards() {
        guard let next = (live.first ?? streamingReply)?.messageId else { return }
        toolCallGroups = toolCallGroups.map {
            $0.anchorMessageID == nil ? ToolCallGroup(id: $0.id, anchorMessageID: next, toolCalls: $0.toolCalls) : $0
        }
        reasoningGroups = reasoningGroups.map {
            $0.anchorMessageID == nil ? ReasoningGroup(id: $0.id, anchorMessageID: next, text: $0.text) : $0
        }
    }
}

struct HermesQueuedPrompt: Equatable, Identifiable {
    static let dashboardSlot = "queued"
    let id: String
    let text: String
    var images: [MessageAttachment] = []
}

struct HermesLostTurn: Equatable {
    let admissionID: String
    let generation: Int
    let text: String
}

@MainActor @Observable final class HermesChatTurnCoordinator {
    let engine: HermesConversation
    @ObservationIgnored private weak var delegate: (any HermesChatTurnDelegate)?

    private(set) var activeStreamID: String?
    private(set) var activeRunStartedAt: Date?
    private(set) var latestRunEnding: ChatRunEnding?
    private(set) var successfulResponseCompletion: ChatStreamCoordinator.SuccessfulResponseCompletion?
    private(set) var queuedPrompts: [HermesQueuedPrompt] = []
    private(set) var lostTurn: HermesLostTurn?
    @ObservationIgnored private var runningAdmission: String?
    @ObservationIgnored private var submittingText: String?
    @ObservationIgnored private var queuedImages: [String: [MessageAttachment]] = [:]
    let requests: HermesChatRequests
    let hostNotices: HermesHostNotices
    let sideTasks: HermesChatSideTasks
    let settings: HermesChatSettings
    let slashCommands: HermesSlashCommands
    let activity: HermesChatActivity
    let policy: HermesChatPolicy

    @ObservationIgnored private var turnStartedAt: Double?
    @ObservationIgnored private var hostTurnStartedAt: Double?
    @ObservationIgnored private var hostRunning = false
    @ObservationIgnored private var infoTitle: String?
    private(set) var cwd: String?
    private(set) var terminalBackend: String?
    var latestTurnBase: GitTurnBase? { turnBase?.workspace == workspace ? turnBase : nil }
    private var turnBase: GitTurnBase?
    @ObservationIgnored private var pendingBase: (sha: String, workspace: HermesWorkspaceContext)?
    @ObservationIgnored private var headReader: HermesGitClient?
    @ObservationIgnored private(set) var reportedModel: HermesCall.Model?
    @ObservationIgnored private var compactionPending = false
    private(set) var isCompacting = false
    @ObservationIgnored private var pendingEnding: TranscriptTurnRunOutcome.Ending?
    @ObservationIgnored private var endSeenAt: Date?
    @ObservationIgnored private var completedFailed = false
    @ObservationIgnored private var awaitingStart = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var isSubmittingSend = false
    @ObservationIgnored private var turnsStarted = 0
    @ObservationIgnored private var needsRebuild = false
    @ObservationIgnored private var heldFrames: [BotJSON] = []
    @ObservationIgnored private var replayedReply = ""
    @ObservationIgnored private var deltasInRebuild: Set<Int> = []
    @ObservationIgnored private var promptAccepted = false
    @ObservationIgnored private var promptSent = false
    private let opensNew: Bool
    @ObservationIgnored private var attaching: Task<Void, Never>?
    @ObservationIgnored private var attachGeneration = 0
    private(set) var needsSignIn = false
    @ObservationIgnored private var history = HermesTranscriptHistory()
    @ObservationIgnored private var historyFailure: Error?
    @ObservationIgnored private var historyTurns = 0
    @ObservationIgnored private var savedTurn: SavedTurn?
    @ObservationIgnored private var rebuiltRunningTurn = false
    @ObservationIgnored private var historyRefresh: Task<Void, Never>?
    @ObservationIgnored private var submitsInFlight = 0
    @ObservationIgnored private var followedReplacements = 0
    @ObservationIgnored private var shownReplacements = 0
    @ObservationIgnored private var draftKey: ChatDraftKey
    @ObservationIgnored private let lineageRoot: String?
    @ObservationIgnored let segmentDraftKey: ChatDraftKey?
    private let isNetworkAvailable: @MainActor () -> Bool
    @ObservationIgnored private let previewLimit: Int
    @ObservationIgnored private let liveActivities: (any AgentLiveActivityManaging)?
    @ObservationIgnored private let ratingPromptState: RatingPromptState
    @ObservationIgnored private var liveActivity: (sessionID: String, turn: String, bot: AgentRunActivityBot?,
                                                   pushSessionID: String?)?
    @ObservationIgnored private let writeBotAvatar: (@MainActor (BotProfile, BotDestination) -> String?)?
    @ObservationIgnored private var shownBotLook: BotProfileAppearance?
    @ObservationIgnored private var shownBotPhoto: ObjectIdentifier?
    @ObservationIgnored private var showsLiveActivityExcerpts = false
    @ObservationIgnored private var shownWaiting: AgentLiveActivityEvent?

    init(engine: HermesConversation, botChatRoot: String? = nil, lineageRoot: String? = nil,
         openedBot: BotProfile? = nil,
         liveActivities: (any AgentLiveActivityManaging)? = nil,
         writeBotAvatar: (@MainActor (BotProfile, BotDestination) -> String?)? = nil,
         isNetworkAvailable: @escaping @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied },
         previewLimit: Int = BotArtifactBuffer.maximumBytes,
         ratingPromptState: RatingPromptState? = nil,
         noticeTimer: HermesHostNotices.Timer? = nil) {
        self.engine = engine
        self.previewLimit = previewLimit
        self.ratingPromptState = ratingPromptState ?? .shared
        let policy = HermesChatPolicy(target: engine.target, botChatRoot: botChatRoot)
        self.policy = policy
        self.liveActivities = liveActivities
        self.writeBotAvatar = writeBotAvatar
        self.isNetworkAvailable = isNetworkAvailable
        requests = HermesChatRequests(engine: engine)
        hostNotices = HermesHostNotices(timer: noticeTimer)
        sideTasks = HermesChatSideTasks(engine: engine)
        settings = HermesChatSettings(engine: engine, loadsAvatars: policy == .botChat, openedBot: openedBot)
        slashCommands = HermesSlashCommands(engine: engine, policy: policy)
        activity = HermesChatActivity(wire: engine.wire)
        self.lineageRoot = lineageRoot
        draftKey = engine.target.draftKey(server: engine.server, connectionID: engine.connection.id, lineageRoot: lineageRoot)
        let segmentDraftKey = engine.target.draftKey(server: engine.server, connectionID: engine.connection.id)
        self.segmentDraftKey = segmentDraftKey == draftKey ? nil : segmentDraftKey
        if case .new = engine.target { opensNew = true } else { opensNew = false }
        engine.owner = self
        requests.onOpenChange = { [weak self] in self?.syncLiveActivityWaiting() }
        requests.onFailure = { [weak self] in self?.delegate?.hermesRequestDidFail($0) }
        requests.onNeedsReattach = { [weak self] in self?.reattach() }
        sideTasks.onNeedsReattach = { [weak self] in self?.reattach() }
        slashCommands.onNeedsReattach = { [weak self] in self?.reattach() }
        sideTasks.onBackgroundChange = { [weak self] in self?.delegate?.hermesBackgroundDidChange($0) }
        sideTasks.onGoalChange = { [weak self] in self?.delegate?.hermesGoalDidChange($0) }
        settings.onRosterRead = { [weak self] in self?.botRosterDidChange() }
        settings.onAvatarsChange = { [weak self] in self?.botPictureDidChange() }
        activity.delegatedWork.onWorkersChanged = { [weak self] in self?.syncBotWorkSummary() }
        self.ratingPromptState.register(self, server: engine.server)
    }

    convenience init(_ chat: HermesSessionChat) {
        self.init(engine: HermesConversation(server: chat.server, connection: chat.connection, target: chat.target,
                                             linkedRoot: chat.linkedRoot,
                                             wire: BotClient(saved: chat.connection, server: chat.server,
                                                             profile: chat.target.profile)),
                  botChatRoot: chat.botChatRoot, lineageRoot: chat.lineageRoot, openedBot: chat.bot,
                  liveActivities: AgentLiveActivityManager.shared,
                  writeBotAvatar: BotLiveActivity.writeAvatar)
    }

    private(set) var screenUse: BotScreenUse?

    var botProfile: BotProfile? {
        guard policy == .botChat else { return nil }
        let profile = engine.target.profile
        return settings.bots.first { $0.id == profile } ?? BotProfile(.object(["name": .string(profile)]))
    }

    var mentions: BotMentions? { policy.offersMentions ? settings.mentions : nil }

    var botTurn: BotTurnState {
        guard engine.connectionState == .connected else { return .unknown }
        if activeStreamID != nil { return requests.isWaiting ? .needsAttention : .running }
        return activity.failure != nil ? .interrupted : .idle
    }

    var titleFace: BotTitleFace {
        switch botTurn {
        case .needsAttention: return .waiting
        case .interrupted: return .failed
        case .running: return .working
        case .unknown, .idle: return .resting
        }
    }

    var currentDraftKey: ChatDraftKey { draftKey }

    var stopNeedsConfirmation: Bool { !queuedPrompts.isEmpty || requests.stopWithdrawsAnswers }

    private var isCanonical: Bool { engine.wire.speaksCanonicalProtocol }

    func activate() async {
        if let attaching { await attaching.value; return }
        guard !engine.isActive || (engine.connectionState == .disconnected && !engine.isReconnecting) else { return }
        await startAttach().value
    }

    @discardableResult
    private func startAttach() -> Task<Void, Never> {
        guard !needsSignIn else { return Task {} }
        attachGeneration += 1
        let generation = attachGeneration
        let task = Task { [weak self, engine] in
            guard !Task.isCancelled else { return }
            await engine.activate()
            guard let self, self.attachGeneration == generation else { return }
            self.attaching = nil
        }
        attaching = task
        return task
    }

    func noteReplacedChat() { followedReplacements += 1 }

    func replacedChatNoticeDidShow() { shownReplacements = followedReplacements }

    private func attachForWrite() async throws -> String {
        let followed = followedReplacements, seen = followed == shownReplacements
        await activate()
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw NotSent(underlying: BotFailure.transport)
        }
        guard seen, followedReplacements == followed else {
            throw NotSent(underlying: BotFailure.stale, followedReplacedChat: true)
        }
        return runtime
    }

    private func cancelAttach() {
        attaching?.cancel(); attaching = nil
        attachGeneration += 1
    }

    struct NotSent: Error {
        let underlying: Error
        var duringUpload = false
        var followedReplacedChat = false
    }

    struct BranchRowGone: Error {}
    struct BranchContinuesEarlierSession: Error {}

    struct SavedTurn: Equatable {
        let promptRowID: Int?
        let replyRowID: Int
    }

    struct OutgoingAttachment {
        let name: String
        let mime: String
        let isImage: Bool
        let isClipboardPaste: Bool
        let data: () async throws -> Data
    }

    private(set) var isUploadingAttachments = false
    @ObservationIgnored private var attachmentUpload: Task<(references: [String], images: [UploadedImage], titlePreview: String?), Error>?

    func submit(_ text: String, mode: BotPromptMode, attachments: [OutgoingAttachment] = [],
                beforePrompt: () async throws -> Void = {},
                stillCurrent: @escaping () throws -> Void = {}) async throws -> BotPromptOutcome {
        submitsInFlight += 1
        defer { submitsInFlight -= 1 }
        let runtime = try await attachForWrite()
        guard attachments.isEmpty || mode.startsTurn else { throw NotSent(underlying: BotFailure.unsupported) }
        let attempt = engine.generation
        let references: [String], images: [UploadedImage], titlePreview: String?
        do {
            (references, images, titlePreview) = try await upload(attachments, runtime: runtime, attempt: attempt, canonical: isCanonical)
        } catch {
            throw NotSent(underlying: error, duringUpload: true)
        }
        if mode == .steer || mode == .queue {
            do { try await requests.continueConnection(runtime: runtime, attempt: attempt) } catch { throw NotSent(underlying: error) }
        }
        var head: (sha: String, workspace: HermesWorkspaceContext)?
        if mode == .send, isOnlySubmission, let workspace, workspace.isLocal {
            let sha = try? await headSHA(in: workspace)
            do { try Task.checkCancellation(); try engine.check(attempt) } catch { throw NotSent(underlying: error) }
            head = sha.map { (sha: $0, workspace: workspace) }
        }
        do { try await beforePrompt() } catch { throw NotSent(underlying: error) }
        let prompt = ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let mentionNote = mentions?.annotation(for: text) ?? ""
        let startsBefore = turnsStarted
        if mode == .send {
            isSubmittingSend = true
            submittingText = BotMentions.displayText(prompt + mentionNote)
            if let head, isOnlySubmission, workspace == head.workspace { pendingBase = head }
        }
        if mode == .redirect { requests.isStoppingHere = true }
        var startedTurn = false
        defer {
            if mode == .send {
                isSubmittingSend = false; pendingBase = nil; submittingText = nil
                if !startedTurn, let turnBase, turnBase.turn > startsBefore { self.turnBase = nil }
            }
            if mode == .redirect { requests.isStoppingHere = false }
        }
        var dispatched = false
        let reply: BotJSON
        do {
            reply = try await engine.write(mode.call(runtime: runtime, text: prompt + mentionNote, fence: engine.fence,
                                                     images: images.map(\.stored), titlePreview: titlePreview),
                                           attempt: attempt, runtime: runtime) { try stillCurrent(); dispatched = true; self.promptSent = true }
        } catch {
            if let stale = error as? HermesFenceRefusal { engine.adoptGeneration(stale.generation) }
            if case BotFailure.rejected(4001) = error { reattach() }
            throw dispatched ? error : NotSent(underlying: error)
        }
        let ownTurnStarted = reply["admission_id"].text.map { $0 == runningAdmission } ?? false
        let behind = (activeStreamID != nil && !ownTurnStarted) || lostTurn != nil
        let outcome = mode.outcome(reply, turnRunning: behind, canonical: isCanonical)
        switch outcome {
        case .started:
            startedTurn = true
            if turnsStarted == startsBefore, activeStreamID == nil {
                beginTurn(startedAt: nil, prompt: nil)
                awaitingStart = true
            }
        case .followUpQueued, .redirectQueued:
            if let admission = reply["admission_id"].text, !admission.isEmpty {
                let chips = images.map(\.chip)
                if !chips.isEmpty { queuedImages[admission] = chips }
                if let listed = queuedPrompts.firstIndex(where: { $0.id == admission }) {
                    queuedPrompts[listed].images = chips
                } else {
                    queuedPrompts.append(HermesQueuedPrompt(id: admission, text: prompt, images: chips))
                }
            } else {
                let merged = queuedPrompts.first.map { "\($0.text)\n\n\(prompt)" } ?? prompt
                queuedPrompts = [HermesQueuedPrompt(id: HermesQueuedPrompt.dashboardSlot, text: merged)]
            }
        case .guidanceQueued, .redirected, .voiceStopped:
            break
        case .rejected, .unknown:
            return outcome
        }
        requests.promptAccepted()
        acceptPrompt()
        return outcome
    }

    private var isOnlySubmission: Bool { activeStreamID == nil && submitsInFlight == 1 }

    private func headSHA(in workspace: HermesWorkspaceContext) async throws -> String? {
        guard let http = (engine.wire as? BotClient)?.http else { return nil }
        if headReader?.context != workspace { headReader = HermesGitClient(context: workspace, http: http) }
        return try await headReader?.headSHA()
    }

    struct UploadedImage {
        let stored: BotUploadedImage
        let chip: MessageAttachment
    }

    private func upload(_ attachments: [OutgoingAttachment], runtime: String, attempt: Int,
                        canonical: Bool) async throws -> (references: [String], images: [UploadedImage], titlePreview: String?) {
        guard !attachments.isEmpty else { return ([], [], nil) }
        guard let key = engine.storedKey else { throw BotFailure.stale }
        let context = BotArtifactContext(connectionID: engine.connection.id, profile: engine.target.profile,
                                         sessionID: key, generation: attempt)
        let task = Task { [engine] in
            var references: [String] = [], images: [UploadedImage] = []
            var titlePreview: String?
            for attachment in attachments {
                try engine.check(attempt)
                let data = try await attachment.data()
                if titlePreview == nil, attachment.isClipboardPaste {
                    titlePreview = String(decoding: data.prefix(HermesCompatibility.titlePreviewLimit * 4), as: UTF8.self)
                }
                try engine.check(attempt)
                if attachment.isImage {
                    let stored = try await engine.wire.uploadImage(data: data, filename: attachment.name, context: context)
                    let path = try BotAttachmentUpload.verifiedPath(stored.path)
                    if canonical {
                        images.append(UploadedImage(stored: stored, chip: MessageAttachment(
                            name: attachment.name, path: path, mime: stored.mime, isImage: true)))
                    } else {
                        references.append(BotAttachmentUpload.imageReference(path: path))
                    }
                } else {
                    let call = await BotAttachmentUpload.fileAttach(data: data, runtime: runtime,
                                                                    filename: attachment.name, mime: attachment.mime)
                    let reply = try await engine.write(call, attempt: attempt, runtime: runtime)
                    guard reply["attached"].flag == true, let ref = reply["ref_text"].text, ref.hasPrefix("@file:"),
                          !ref.contains("\n"), !ref.contains("\r") else { throw BotFailure.unsupported }
                    _ = try BotAttachmentUpload.verifiedPath(reply["path"].text)
                    references.append(ref)
                }
            }
            try engine.check(attempt)
            return (references: references, images: images, titlePreview: titlePreview)
        }
        attachmentUpload = task
        isUploadingAttachments = true
        defer { attachmentUpload = nil; isUploadingAttachments = false }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            throw task.isCancelled ? CancellationError() : error
        }
    }

    func cancelAttachmentUpload() { attachmentUpload?.cancel() }

    func attachmentData(path: String, whole: Bool = false, limit: Int? = nil) async throws -> Data {
        guard engine.connectionState == .connected, let key = engine.storedKey else { throw BotFailure.stale }
        let attempt = engine.generation
        let context = BotArtifactContext(connectionID: engine.connection.id, profile: engine.target.profile,
                                         sessionID: key, generation: attempt)
        let data = try await engine.wire.artifactData(path: path, context: context, limit: whole ? nil : min(limit ?? previewLimit, previewLimit))
        try engine.check(attempt)
        return data
    }

    var attachmentLoadKey: Int? {
        engine.connectionState == .connected && engine.storedKey != nil ? engine.generation : nil
    }

    var workspace: HermesWorkspaceContext? {
        guard let cwd, let key = engine.storedKey else { return nil }
        return HermesWorkspaceContext(server: engine.server, profile: engine.target.profile, storedKey: key,
                                      cwd: cwd, terminalBackend: terminalBackend)
    }

    var workspaceFiles: HermesWorkspaceFileClient? {
        guard let workspace, let http = (engine.wire as? BotClient)?.http else { return nil }
        return HermesWorkspaceFileClient(context: workspace, http: http)
    }

    func workspaceGit(showsCachedData: @escaping @MainActor @Sendable () -> Bool) -> HermesGitClient? {
        guard let workspace, let http = (engine.wire as? BotClient)?.http else { return nil }
        return HermesGitClient(context: workspace, http: http, writeMessage: { [weak self] diff, recent, avoid in
            guard let self else { throw BotFailure.stale }
            return try await self.commitMessage(diff: diff, recent: recent, avoid: avoid)
        }, writeOwner: { [weak self] in
            guard let self else { throw BotFailure.stale }
            return try self.gitWriteDispatch(in: workspace, showsCachedData: showsCachedData)
        })
    }

    private func gitWriteDispatch(in workspace: HermesWorkspaceContext,
                                  showsCachedData: @escaping @MainActor @Sendable () -> Bool) throws -> HermesGitClient.Dispatch {
        let attempt = engine.generation
        let check: HermesGitClient.Dispatch = { [weak self] in
            guard let self, self.engine.generation == attempt, self.workspace == workspace, !showsCachedData() else {
                throw BotFailure.stale
            }
            guard self.isIdle else { throw HermesGitRefusal.turnRunning }
        }
        try check()
        return check
    }

    func commitMessage(diff: String, recent: String, avoid: String?) async throws -> String {
        guard engine.connectionState == .connected else { throw BotFailure.stale }
        let reply = try await engine.request(.commitMessage(diff: diff, recentCommits: recent, avoid: avoid,
                                                            sessionID: engine.runtime, profile: engine.target.profile),
                                             attempt: engine.generation)
        return reply["text"].text ?? ""
    }

    func completeFilePaths(_ query: String, as word: BotFilePathSearch.Word) async throws -> [ComposerFilePathSearch.Match] {
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.stale }
        let spelled = switch word {
        case .panel: BotFilePathSearch.panelWord(for: query)
        case .listing: BotFilePathSearch.listingWord(for: query)
        }
        let reply = try await engine.request(.completePath(word: spelled, sessionID: runtime,
                                                           profile: engine.target.profile, timesOutLocally: true),
                                             attempt: engine.generation)
        return BotFilePathSearch.matches(from: reply)
    }

    func searchWorkspaceFiles(_ query: String, in workspace: HermesWorkspaceContext) async throws -> [ComposerFilePathSearch.Match] {
        guard let http = (engine.wire as? BotClient)?.http, !Task.isCancelled else { throw BotFailure.stale }
        let client = BotClient(http: http)
        defer { client.close() }
        try await withTaskCancellationHandler {
            try await client.connect()
        } onCancel: {
            Task { @MainActor in client.close() }
        }
        let reply = try await client.call(.completeWorkspacePath(word: BotFilePathSearch.panelWord(for: query),
                                                                 cwd: workspace.cwd, profile: workspace.profile))
        return BotFilePathSearch.matches(from: reply, browsing: true)
    }

    var isUnstarted: Bool { opensNew && !promptSent && turnsStarted == 0 && history.rows.isEmpty }

    struct ReplyRunning: Error {}

    func folderChoices() async -> [String] {
        let profile = engine.target.profile, attempt = engine.generation
        let tree = try? await engine.request(.projectsTree(profile: profile), attempt: attempt)
        let page = try? await engine.wire.sessionPage(profile: profile, offset: 0, archived: false)
        return HermesFolderCompletion.choices(current: cwd, projects: tree.map(HermesProjectTree.init(reply:)),
                                              sessions: page?.rows ?? [], profile: profile)
    }

    func completeFolder(_ word: String) async -> [String] {
        guard HermesFolderCompletion.completes(word),
              let reply = try? await engine.request(.completeFolder(word: word, profile: engine.target.profile),
                                                    attempt: engine.generation) else { return [] }
        return HermesFolderCompletion.suggestions(from: reply, typed: word).folders
    }

    func moveFolder(to folder: String) async throws {
        guard engine.connectionState == .connected, let runtime = engine.runtime, let key = engine.storedKey
        else { throw BotFailure.stale }
        let idle = { [weak self] in
            guard let self, self.isIdle, !self.hostRunning else { throw ReplyRunning() }
        }
        let reply = isCanonical
            ? try await engine.mutate(.workspace(cwd: folder), attempt: engine.generation, runtime: runtime, stillCurrent: idle)
            : try await engine.write(.sessionWorkspaceMove(profile: engine.target.profile, storedKey: key, cwd: folder),
                                     attempt: engine.generation, runtime: runtime, stillCurrent: idle)
        noteWorkspace(folder: Self.words(reply["cwd"]), backend: nil)
    }

    var attachmentCacheNamespace: String {
        "hermes|\(engine.connection.id.uuidString)|\(engine.target.profile)|\(engine.storedKey ?? "")"
    }

    func speech(for text: String) async throws -> Data {
        try await engine.wire.speech(text: text, profile: engine.target.profile)
    }

    func recoverAfterLostAnswer() {
        guard engine.isActive else { return }
        rebuildAfterGap()
    }

    private func acceptPrompt() {
        guard !promptAccepted else { return }
        promptAccepted = true
        let key = engine.target.draftKey(server: engine.server, connectionID: engine.connection.id, lineageRoot: lineageRoot)
        guard key != draftKey else { return }
        let previous = draftKey
        draftKey = key
        delegate?.hermesDraftKeyDidChange(from: previous, to: key)
    }

    func interrupt() async throws -> Bool {
        guard activeStreamID != nil, !stopRequested else { return false }
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.transport }
        stopRequested = true
        requests.isStoppingHere = true
        defer { requests.isStoppingHere = false }
        let attempt = engine.generation
        let fence = engine.fence
        do {
            if isCanonical {
                for queued in queuedPrompts {
                    _ = try await engine.write(.promptCancel(profile: engine.target.profile, sessionID: runtime, admissionID: queued.id),
                                               attempt: attempt, runtime: runtime)
                    queuedPrompts.removeAll { $0.id == queued.id }
                    queuedImages[queued.id] = nil
                }
            }
            _ = try await engine.write(.sessionInterrupt(sessionID: runtime, fence: fence), attempt: attempt, runtime: runtime)
        } catch {
            if let stale = error as? HermesFenceRefusal { engine.adoptGeneration(stale.generation) }
            stopRequested = false
            throw error
        }
        if !isCanonical { queuedPrompts = [] }
        requests.withdrawAll()
        return true
    }

    func rewind(before rowID: Int, text: String, discardsLaterPrompts: Bool) async throws {
        submitsInFlight += 1
        defer { submitsInFlight -= 1 }
        let runtime = try await attachForWrite()
        let startsBefore = turnsStarted
        isSubmittingSend = true
        defer { isSubmittingSend = false }
        if isCanonical {
            _ = try await mutateOnce(.rewind(targetMessageID: rowID), runtime: runtime)
            history.cut(before: rowID)
            submittingText = BotMentions.displayText(text)
            defer { submittingText = nil }
            var dispatched = false
            let reply: BotJSON
            do {
                reply = try await engine.write(.promptSubmit(sessionID: runtime, text: text, fence: engine.fence),
                                               attempt: engine.generation, runtime: runtime) { dispatched = true }
            } catch {
                if case BotFailure.rejected = error { throw RewoundButNotSent(underlying: error) }
                if !dispatched || error is HermesFenceRefusal { throw RewoundButNotSent(underlying: error) }
                throw error
            }
            switch BotPromptMode.send.outcome(reply, turnRunning: lostTurn != nil, canonical: true) {
            case .started: break
            case .followUpQueued: requests.promptAccepted(); return
            default: throw BotFailure.unsupported
            }
            if turnsStarted == startsBefore, activeStreamID == nil {
                beginTurn(startedAt: nil, prompt: nil)
                awaitingStart = true
            }
            requests.promptAccepted()
            return
        }
        let reply: BotJSON
        do {
            reply = try await writeOnce(.promptRewind(sessionID: runtime, text: text, beforeRowID: rowID, deep: false), runtime: runtime)
        } catch BotSettingFailure.rejected(4033, _) where discardsLaterPrompts {
            reply = try await writeOnce(.promptRewind(sessionID: runtime, text: text, beforeRowID: rowID, deep: true), runtime: runtime)
        }
        guard reply["status"].text == "streaming" else { throw BotFailure.unsupported }
        history.cut(before: rowID)
        if turnsStarted == startsBefore, activeStreamID == nil {
            beginTurn(startedAt: nil, prompt: nil)
            awaitingStart = true
        }
        requests.promptAccepted()
    }

    func undo() async throws {
        let runtime = try await attachForWrite()
        let attempt = engine.generation
        if isCanonical {
            let operation: HermesCall.SessionMutation.Operation
            if case .rewind? = engine.unansweredOperation, let unanswered = engine.unansweredOperation {
                operation = unanswered
            } else {
                guard let prompt = history.rows.last(where: { $0["role"].text == "user" }).flatMap(HermesTranscriptHistory.id)
                else { return }
                operation = .rewind(targetMessageID: prompt)
            }
            let reply = try await mutateOnce(operation, runtime: runtime)
            guard reply["rewound_count"].integer != 0 else { return }
        } else {
            let reply = try await writeOnce(.sessionUndo(runtime: runtime), runtime: runtime)
            guard reply["removed"].integer != 0 else { return }
        }
        activity.newestTurnWasUndone()
        turnBase = nil
        await readNewestRows(attempt: attempt)
        guard attempt == engine.generation, isIdle else { return }
        if let historyFailure { throw historyFailure }
        delegate?.hermesReplaceTranscript(historyTranscript())
    }

    func restoreCheckpoint(_ hash: String, filePath: String?) async throws -> HermesRollbackOutcome {
        let attempt = engine.generation
        let outcome = try await slashCommands.restoreCheckpoint(hash, filePath: filePath)
        guard outcome.success, filePath == nil, outcome.historyRemoved > 0 else { return outcome }
        historyRefresh?.cancel()
        activity.newestTurnWasUndone()
        turnBase = nil
        await readNewestRows(attempt: attempt)
        guard attempt == engine.generation, isIdle else { return outcome }
        if let historyFailure { throw historyFailure }
        delegate?.hermesReplaceTranscript(historyTranscript())
        return outcome
    }

    enum Compression: Equatable {
        case compacted(headline: String?, tokenLine: String?)
        case unchanged(String?)
    }

    func compress(focus: String?) async throws -> Compression {
        let runtime = try await attachForWrite()
        let attempt = engine.generation
        let reply: BotJSON
        do {
            reply = isCanonical
                ? try await mutateOnce(.compress(focus: focus), runtime: runtime)
                : try await writeOnce(.sessionCompress(runtime: runtime, focus: focus, profile: engine.target.profile),
                                      runtime: runtime)
        } catch {
            if !(error is NotSent || error is BotSettingFailure || error is HermesFenceRefusal) { forgetHistoryUntilRebuild() }
            throw error
        }
        if isCanonical {
            let summary = reply["summary"]
            switch reply["status"].text {
            case "noop": return .unchanged([summary["headline"], summary["note"]].lazy.compactMap(Self.words).first)
            case "preview": return .unchanged(Self.words(.string((reply["lines"].list ?? []).compactMap(\.text).joined(separator: "\n"))))
            default:
                guard reply["revision"].integer != nil else { forgetHistoryUntilRebuild(); throw BotFailure.unsupported }
            }
            let compacted = Compression.compacted(headline: Self.words(summary["headline"]), tokenLine: Self.words(summary["token_line"]))
            guard attempt == engine.generation else { return compacted }
            compactionPending = false
            historyRefresh?.cancel()
            history = HermesTranscriptHistory()
            await showCompactedHistory(attempt: attempt)
            return compacted
        }
        engine.adoptStoredKey(reply["info"]["stored_session_id"].text)
        syncLiveActivityPushKey()
        let summary = reply["summary"]
        let reason = [reply["message"], summary["note"], summary["headline"]].lazy.compactMap(Self.words).first
        switch reply["status"].text {
        case "compressed" where reply["removed"].integer != 0:
            break
        case "compressed", "aborted":
            return .unchanged(reason)
        case "pending":
            compactionPending = true
            return .unchanged(reason)
        case nil where reply["lock_held"].flag == true:
            return .unchanged(reason)
        default:
            forgetHistoryUntilRebuild()
            throw BotFailure.unsupported
        }
        let compacted = Compression.compacted(headline: Self.words(summary["headline"]), tokenLine: Self.words(summary["token_line"]))
        guard attempt == engine.generation else { return compacted }
        compactionPending = false
        historyRefresh?.cancel()
        history = HermesTranscriptHistory()
        await showCompactedHistory(attempt: attempt)
        return compacted
    }

    private func showCompactedHistory(attempt: Int) async {
        await readNewestRows(attempt: attempt)
        guard attempt == engine.generation, isIdle else { return }
        if let historyFailure {
            reportHistoryFailure(historyFailure)
        } else {
            delegate?.hermesReplaceTranscript(historyTranscript())
        }
    }

    private func pendingCompactionDidFinish() {
        compactionPending = false
        historyRefresh?.cancel()
        history = HermesTranscriptHistory()
        let attempt = engine.generation
        historyRefresh = Task { [weak self] in await self?.showCompactedHistory(attempt: attempt) }
    }

    private func forgetHistoryUntilRebuild() {
        historyRefresh?.cancel()
        history = HermesTranscriptHistory()
        needsRebuild = true
    }

    private static func words(_ value: BotJSON) -> String? {
        value.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    func branch(through rowID: Int?, name: String?) async throws -> String {
        let runtime = try await attachForWrite()
        if isCanonical {
            let reply = try await mutateOnce(.branch(title: name, throughMessageID: rowID), runtime: runtime)
            guard let key = reply["branched_session_id"].text, !key.isEmpty else { throw BotFailure.unsupported }
            return key
        }
        var count: Int?
        if let rowID {
            let own: BotJSON?
            do {
                guard let key = engine.storedKey else { throw BotFailure.transport }
                own = try await engine.wire.sessionRow(key: key, profile: engine.target.profile)
            } catch {
                throw NotSent(underlying: error)
            }
            guard let own else { throw BranchRowGone() }
            guard HermesBranchParent.standsAlone(own) else { throw BranchContinuesEarlierSession() }
            var stalled = false
            while history.hasOlder {
                let held = history.rows.count
                _ = await loadOlderHistory()
                guard history.rows.count > held || !history.hasOlder || !stalled else { throw NotSent(underlying: BotFailure.transport) }
                stalled = history.rows.count == held
            }
            guard let through = HermesBranchCount.count(through: rowID, in: history.rows) else { throw BranchRowGone() }
            count = through
        }
        let reply = try await writeOnce(.sessionBranch(runtime: runtime, name: name, count: count), runtime: runtime)
        guard let key = reply["stored_session_id"].text, !key.isEmpty else { throw BotFailure.unsupported }
        return key
    }

    private func mutateOnce(_ operation: HermesCall.SessionMutation.Operation, runtime: String) async throws -> BotJSON {
        var dispatched = false
        do {
            return try await engine.mutate(operation, attempt: engine.generation, runtime: runtime) { dispatched = true }
        } catch {
            throw dispatched ? error : NotSent(underlying: error)
        }
    }

    struct RewoundButNotSent: Error { let underlying: Error }

    private func writeOnce(_ call: HermesCall, runtime: String) async throws -> BotJSON {
        var dispatched = false
        do {
            return try await engine.write(call, attempt: engine.generation, runtime: runtime) { dispatched = true }
        } catch {
            if HermesChatSideTasks.isReaped(error) { reattach() }
            throw dispatched ? error : NotSent(underlying: error)
        }
    }

    private func beginTurn(startedAt: Double?, prompt: HermesQueuedPrompt?) {
        if screenUse != nil { screenUse = nil }
        turnsStarted += 1
        let base = isSubmittingSend ? pendingBase : nil
        turnBase = base.map { GitTurnBase(sha: $0.sha, workspace: $0.workspace, turn: turnsStarted) }
        pendingBase = nil
        latestRunEnding = nil; successfulResponseCompletion = nil
        pendingEnding = nil; endSeenAt = nil; awaitingStart = false; stopRequested = false
        savedTurn = nil; completedFailed = false
        hostRunning = true
        turnStartedAt = startedAt
        activeRunStartedAt = Self.date(startedAt) ?? Date()
        activeStreamID = "hermes:\(engine.storedKey ?? ""):\(startedAt.map { String($0) } ?? UUID().uuidString)"
        hostTurnStartedAt = nil
        activity.turnDidStart(showsPrompt: prompt != nil || isSubmittingSend)
        delegate?.hermesTurnDidStart(prompt: prompt)
        delegate?.streamCoordinatorDidStartConnection(isReplay: false)
        let turn = startedAt.map { String($0) } ?? UUID().uuidString
        if let bot = botActivity() {
            liveActivity = (sessionID: bot.key, turn: turn, bot: bot, pushSessionID: bot.pushSessionID)
        } else {
            liveActivity = engine.storedKey.map { key in
                let root = engine.root ?? key
                return (sessionID: "\(AgentRunTapTarget.hermesSessionPrefix)\(engine.target.profile):\(root)", turn: turn,
                        bot: nil, pushSessionID: key)
            }
        }
        startLiveActivity()
    }

    private func ensureTurn() {
        if activeStreamID == nil { beginTurn(startedAt: hostTurnStartedAt, prompt: nil) }
    }

    private func endTime(live: Bool) -> Date? {
        endSeenAt ?? (live ? Date() : nil)
    }

    private func finish(_ ending: TranscriptTurnRunOutcome.Ending, seenAt endedAt: Date? = Date()) {
        endCompaction()
        guard let streamID = activeStreamID else { return }
        endScreenUse()
        let startedAt = turnStartedAt
        endLiveActivity(ending)
        liveActivity = nil
        latestRunEnding = ChatRunEnding(startedAt: activeRunStartedAt ?? Date(), endedAt: endedAt ?? Date(), ending: ending,
                                        endedWhileWatching: endedAt != nil)
        if ending == .completed {
            ratingPromptState.recordCompletedResponse()
            successfulResponseCompletion = .init(streamID: streamID, needsTranscriptRefresh: false)
            delegate?.streamCoordinatorApplyDone(DoneStreamEvent())
        }
        activeStreamID = nil; activeRunStartedAt = nil
        turnStartedAt = nil; pendingEnding = nil; endSeenAt = nil; awaitingStart = false; stopRequested = false
        activity.turnDidEnd()
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        if ending == .completed { delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: false) }
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorDidFinishStream()
        delegate?.streamCoordinatorDidResetRecoveryState()
        if let savedTurn {
            self.savedTurn = nil
            refreshHistory(after: .receipt(savedTurn))
        } else if rebuiltRunningTurn, let startedAt {
            refreshHistory(after: .start(startedAt))
        }
        if completedFailed {
            completedFailed = false
            readFailedTurn()
        }
    }

    private func endScreenUse() {
        if screenUse == .active { screenUse = .ended }
    }

    private func adoptStart(_ startedAt: Double) {
        turnStartedAt = startedAt
        guard let date = Self.date(startedAt) else { return }
        activeRunStartedAt = min(activeRunStartedAt ?? date, date)
    }

    private func applyTitle(_ title: String) {
        guard delegate?.streamCoordinatorUpdateTitle(TitleStreamEvent(sessionId: nil, title: title)) == true,
              let shown = delegate?.streamCoordinatorDisplayTitle, liveActivity?.bot == nil else { return }
        drivenLiveActivity?.update(.sessionTitle(shown))
    }

    private func apply(_ frame: BotJSON, live: Bool = false) {
        let payload = frame["payload"]
        let type = frame["type"].text ?? ""
        if isCompacting, Self.compactionResumeTypes.contains(type) { endCompaction() }
        switch type {
        case "message.start":
            if activeStreamID != nil {
                if awaitingStart { awaitingStart = false; return }
                finish(pendingEnding ?? .completed, seenAt: endTime(live: live))
            }
            var prompt: HermesQueuedPrompt?
            runningAdmission = frame["admission_id"].text
            if let admission = frame["admission_id"].text, !admission.isEmpty {
                if let index = queuedPrompts.firstIndex(where: { $0.id == admission }) {
                    let queued = queuedPrompts.remove(at: index)
                    if !isSubmittingSend || queued.text != submittingText { prompt = queued }
                }
                queuedImages[admission] = nil
            } else if !isSubmittingSend {
                prompt = queuedPrompts.first; queuedPrompts = []
            }
            beginTurn(startedAt: hostTurnStartedAt, prompt: prompt)
        case "message.delta":
            if let seq = frame["seq"].integer, deltasInRebuild.remove(seq) != nil { return }
            guard let text = payload["text"].text, !text.isEmpty else { return }
            ensureTurn()
            drivenLiveActivity?.update(showsLiveActivityExcerpts ? .token(text) : .responding)
            delegate?.streamCoordinatorAppendToken(text)
        case "message.interim":
            ensureTurn()
            let interim = InterimAssistantStreamEvent(text: payload["text"].text, alreadyStreamed: payload["already_streamed"].flag)
            if showsLiveActivityExcerpts, interim.alreadyStreamed != true, let text = interim.text {
                drivenLiveActivity?.update(.interimAssistant(text))
            }
            delegate?.streamCoordinatorAppendInterimAssistant(interim)
        case "reasoning.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return }
            ensureTurn()
            drivenLiveActivity?.update(.reasoning(text))
            delegate?.streamCoordinatorAppendReasoning(text)
        case "tool.start":
            ensureTurn()
            let tool = Self.toolEvent(payload, completed: false)
            if live, tool.name == BotScreenUse.toolName, screenUse != .active { screenUse = .active }
            drivenLiveActivity?.update(.toolStarted(name: tool.name))
            delegate?.streamCoordinatorAppendToolCall(tool)
        case "tool.complete":
            ensureTurn()
            drivenLiveActivity?.update(.toolCompleted)
            delegate?.streamCoordinatorCompleteToolCall(Self.toolEvent(payload, completed: true))
        case "session.title":
            if let key = payload["session_id"].text, key != engine.storedKey { return }
            guard let title = payload["title"].text, !title.isEmpty else { return }
            applyTitle(title)
        case "session.usage":
            if let usage = Self.contextWindow(payload["usage"]) { delegate?.hermesApplyUsage(usage) }
        case "session.info":
            applyInfo(payload, live: live)
        case "session.updated":
            settings.controls.receiveDeferredPickUpdate(payload)
        case "message.complete":
            if frame["admission_id"].text != nil, frame["execution_generation"] == .null { return }
            complete(payload, live: live)
        case "approval.request", "clarify.request":
            if let envelope = HermesCanonicalPrompts.envelope(payload, sessionID: frame["session_id"].text ?? "") {
                requests.receive(envelope)
            }
        case "approval.settled", "clarify.settled":
            guard let id = payload["prompt_id"].text, let kind = frame["type"].text?.split(separator: ".").first else { return }
            requests.cancel(.object(["id": .string(id), "method": .string(String(kind)), "reason": .string("resolved")]))
        case "error":
            endCompaction()
            if let message = payload["message"].text, !message.isEmpty {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            if activeStreamID != nil, !awaitingStart {
                pendingEnding = pendingEnding ?? .failed
            } else {
                finish(.failed, seenAt: endTime(live: live))
            }
        case "request.cancel":
            requests.cancel(payload)
        case "connection.request", "connection.update":
            requests.receiveConnection(payload, opens: frame["type"].text == "connection.request")
        case "todo.updated":
            activity.receivePlan(payload)
            syncBotWorkSummary()
        case "subagent.spawn_requested", "subagent.start", "subagent.progress", "subagent.tool", "subagent.complete":
            activity.delegatedWork.noteSubagentEvent()
        case "status.update":
            switch payload["kind"].text {
            case "compacting", "compressing":
                if !isCompacting { isCompacting = true }
            case "compacted":
                endCompaction()
            case "status" where payload["text"].text == "ready":
                endCompaction()
            default:
                break
            }
            if compactionPending, payload["kind"].text == "compacted" { pendingCompactionDidFinish() }
        case "btw.complete", "background.complete", "session.control.update":
            sideTasks.receive(frame)
        case "notification.show", "notification.clear":
            hostNotices.receive(frame, live: live)
            endDeferredPick(on: frame)
        default:
            break
        }
    }

    private static let compactionResumeTypes: Set<String> = [
        "message.delta", "message.interim", "thinking.delta", "reasoning.delta", "reasoning.available",
        "moa.reference", "moa.aggregating", "moa.progress", "moa.phase",
        "tool.start", "tool.generating", "tool.complete"
    ]

    private func endCompaction() {
        if isCompacting { isCompacting = false }
    }

    private func applyPending(_ rows: BotJSON) {
        let rows = rows.list ?? []
        queuedPrompts = rows.compactMap { row in
            guard row["status"].text == "queued", row["steering"].flag != true,
                  let id = row["admission_id"].text, !id.isEmpty else { return nil }
            return HermesQueuedPrompt(id: id, text: BotMentions.displayText(row["text"].text ?? ""), images: queuedImages[id] ?? [])
        }
        lostTurn = rows.lazy.compactMap { row -> HermesLostTurn? in
            guard row["status"].text == "unknown", let id = row["admission_id"].text, !id.isEmpty,
                  let generation = row["execution_generation"].integer else { return nil }
            return HermesLostTurn(admissionID: id, generation: generation, text: BotMentions.displayText(row["text"].text ?? ""))
        }.first
    }

    func discardLostTurn() async throws {
        guard let lost = lostTurn else { return }
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.transport }
        let fence = HermesCall.Fence(profile: engine.target.profile, generation: lost.generation)
        _ = try await engine.write(.promptResolveUnknown(sessionID: runtime, admissionID: lost.admissionID, fence: fence),
                                   attempt: engine.generation, runtime: runtime) { [weak self] in
            guard self?.lostTurn == lost else { throw BotFailure.stale }
        }
        if lostTurn == lost { lostTurn = nil }
    }

    private func applyInfo(_ info: BotJSON, live: Bool) {
        if let model = info["model"].text, !model.isEmpty { delegate?.hermesApplyModel(model) }
        if info["pending"].list != nil { applyPending(info["pending"]) }
        engine.adoptStoredKey(info["stored_session_id"].text)
        syncLiveActivityPushKey()
        noteInfo(info)
        if let title = info["title"].text, !title.isEmpty, title != infoTitle {
            infoTitle = title
            applyTitle(title)
        }
        requests.applyBypass(info)
        settings.apply(info: info, idle: info["running"].flag.map { !$0 } ?? !hostRunning)
        guard let running = info["running"].flag else { return }
        hostRunning = running
        if running {
            let startedAt = info["turn_started_at"].number
            if activeStreamID == nil { hostTurnStartedAt = startedAt }
            else if turnStartedAt == nil, let startedAt { adoptStart(startedAt) }
        } else {
            hostTurnStartedAt = nil
            endCompaction()
            guard pendingEnding != nil || !awaitingStart else { return }
            finish(pendingEnding ?? (stopRequested ? .cancelled : .completed), seenAt: endTime(live: live))
        }
    }

    private func complete(_ payload: BotJSON, live: Bool) {
        endCompaction()
        guard activeStreamID != nil else {
            turnsStarted += 1
            turnBase = nil
            activity.unseenTurnDidComplete()
            if payload["status"].text == "error" { readFailedTurn() }
            return
        }
        let ending: TranscriptTurnRunOutcome.Ending
        switch payload["status"].text {
        case "interrupted": ending = .cancelled
        case "error": ending = .failed
        default: ending = .completed
        }
        if let reply = payload["text"].text, !reply.isEmpty, ending != .failed || payload["partial"].flag == true {
            delegate?.hermesTurnDidComplete(reply: reply)
        }
        activity.turnDidComplete(payload)
        completedFailed = ending == .failed
        if let usage = Self.contextWindow(payload["usage"]) { delegate?.hermesApplyUsage(usage) }
        let receipt = payload["persisted_turn"]
        if receipt["complete"].flag == true, let reply = receipt["final_assistant_row_id"].integer {
            savedTurn = SavedTurn(promptRowID: receipt["user_row_id"].integer, replyRowID: reply)
        }
        if ending == .cancelled {
            if !isCanonical { queuedPrompts = [] }
            requests.withdrawAll()
        }
        pendingEnding = ending
        if live { endSeenAt = Date() }
        if !hostRunning { finish(ending, seenAt: endSeenAt) }
    }

    private func noteInfo(_ info: BotJSON) {
        noteWorkspace(folder: Self.words(info["cwd"]), backend: Self.words(info["terminal_backend"]))
        if let model = Self.words(info["model"]), let provider = Self.words(info["provider"]) {
            reportedModel = HermesCall.Model(id: model, provider: provider)
        }
    }

    private func noteWorkspace(folder: String?, backend: String?) {
        let folder = folder.flatMap { $0 == cwd ? nil : $0 }
        let backend = backend.flatMap { $0 == terminalBackend ? nil : $0 }
        if let folder { cwd = folder; turnBase = nil }
        if let backend { terminalBackend = backend }
        if folder != nil || backend != nil { delegate?.hermesWorkspaceDidChange() }
    }

    private func reconcile(with snapshot: BotJSON) {
        let running = snapshot["running"].flag ?? snapshot["info"]["running"].flag ?? false
        let startedAt = snapshot["turn_started_at"].number ?? snapshot["inflight"]["started_at"].number
        hostRunning = running
        if snapshot["pending"].list != nil {
            applyPending(snapshot["pending"])
        } else {
            let queued = snapshot["queued"]["user"].text.flatMap { $0.isEmpty ? nil : BotMentions.displayText($0) }
            queuedPrompts = queued.map { [HermesQueuedPrompt(id: HermesQueuedPrompt.dashboardSlot, text: $0)] } ?? []
        }
        requests.didReadSnapshot(HermesCanonicalPrompts.projecting(snapshot, sessionID: engine.runtime ?? ""))
        if let model = snapshot["info"]["model"].text, !model.isEmpty { delegate?.hermesApplyModel(model) }
        noteInfo(snapshot["info"])
        settings.apply(info: snapshot["info"], idle: !running)
        if let title = snapshot["info"]["title"].text, !title.isEmpty { applyTitle(title) }
        let lostFrames = engine.replayWasReset || needsRebuild
        let followedStart = activeStreamID == nil ? nil : turnStartedAt
        if activeStreamID != nil, !running || (startedAt != nil && turnStartedAt != nil && startedAt != turnStartedAt) {
            let failed = HermesTurnOutcome(inflight: snapshot["inflight"]) != nil
            completedFailed = false
            finish(pendingEnding ?? (failed ? .failed : stopRequested ? .cancelled : .completed),
                   seenAt: endTime(live: false))
        }
        let continuing = running && activeStreamID != nil
        if lostFrames, !continuing || followedStart == nil || startedAt == nil { turnBase = nil }
        if running, activeStreamID == nil { beginTurn(startedAt: startedAt, prompt: nil) }
        if running, let startedAt, turnStartedAt == nil { adoptStart(startedAt) }
        if continuing { startLiveActivity() }
        readOutcome(snapshot, in: history, followsTurn: continuing, endedTurnStartedAt: running ? nil : followedStart)
        if lostFrames { rebuild(from: snapshot, running: running) }
    }

    private func readOutcome(_ snapshot: BotJSON, in rows: HermesTranscriptHistory, followsTurn: Bool,
                             endedTurnStartedAt: Double? = nil) {
        let inflight = snapshot["inflight"]
        let promptRowID = inflight["error"] == .null ? nil
            : savedPromptRowID(startedAt: inflight["started_at"].number ?? snapshot["turn_started_at"].number, in: rows)
        let endedPromptRowID = savedPromptRowID(startedAt: endedTurnStartedAt, in: rows)
        activity.readSnapshot(snapshot, promptRowID: promptRowID, followsTurn: followsTurn || endedPromptRowID != nil,
                              followedPromptRowID: endedPromptRowID)
        syncBotWorkSummary()
    }

    private func savedPromptRowID(startedAt: Double?, in rows: HermesTranscriptHistory) -> Int? {
        guard let startedAt else { return nil }
        let messages = HermesTranscriptProjection.project(rows.rows, root: engine.storedKey ?? "").messages
        guard let last = messages.lastIndex(where: TranscriptTurnClassifier.isTurnBoundary),
              let stamp = messages[last].timestamp, stamp >= startedAt else { return nil }
        if let previous = messages[..<last].last(where: TranscriptTurnClassifier.isTurnBoundary),
           previous.timestamp.map({ $0 < startedAt }) != true { return nil }
        return messages[last].rowID
    }

    private func readFailedTurn() {
        guard engine.connectionState == .connected else { return }
        let attempt = engine.generation, turns = turnsStarted
        Task { [weak self] in
            guard let reply = try? await self?.engine.resume(attempt: attempt), let self,
                  attempt == self.engine.generation, turns == self.turnsStarted, self.engine.isCurrent(reply) else { return }
            var rows = self.history
            if HermesTurnOutcome(inflight: reply["inflight"])?.offersRetry == true,
               let fresh = try? await self.newestRows(attempt: attempt) {
                rows.mergeNewest(fresh.rows, reachedStart: fresh.reachedStart)
            }
            guard attempt == self.engine.generation, turns == self.turnsStarted else { return }
            self.readOutcome(reply, in: rows, followsTurn: false)
        }
    }

    func retryWasRefused(at rowID: Int) {
        activity.refuseRetry(at: rowID)
        recoverAfterLostAnswer()
    }

    private func rebuild(from snapshot: BotJSON, running: Bool) {
        needsRebuild = false
        let root = engine.storedKey ?? ""
        var transcript = historyTranscript()
        let inflight = snapshot["inflight"]
        let startedAt = inflight["started_at"].number ?? snapshot["turn_started_at"].number
        if let text = inflight["user"].text, !text.isEmpty {
            let prompt = Self.displayed(ChatMessage(role: "user", content: text, timestamp: startedAt, messageId: "\(root)/live-user"))
            if !Self.holdsPrompt(prompt, in: transcript.messages, startedAt: startedAt) { transcript.live.append(prompt) }
        }
        let reply = inflight["assistant"].text ?? ""
        let row = ChatMessage(role: "assistant", content: reply, timestamp: nil, messageId: "\(root)/live-\(UUID().uuidString)")
        if running { transcript.streamingReply = row } else if !reply.isEmpty { transcript.live.append(row) }
        if !reply.isEmpty {
            deltasInRebuild = Self.heldDeltas(heldFrames, after: engine.sequence, alreadyIn: reply, following: replayedReply)
        }
        transcript.anchorTrailingCards()
        if running { rebuiltRunningTurn = true }
        transcript.title = snapshot["info"]["title"].text.flatMap { $0.isEmpty ? nil : $0 }
        delegate?.hermesReplaceTranscript(transcript)
    }

    private func historyTranscript() -> HermesChatTranscript {
        let projected = HermesTranscriptProjection.project(history.rows, root: engine.storedKey ?? "")
        return HermesChatTranscript(messages: projected.messages.map(Self.displayed), toolCallGroups: projected.toolCallGroups,
                                    reasoningGroups: projected.reasoningGroups, compaction: projected.compaction,
                                    hasOlder: history.hasOlder, newestCoverage: history.newestCoverage)
    }

    private func page(at offset: Int, attempt: Int) async throws -> [BotJSON] {
        try engine.check(attempt)
        guard let key = engine.storedKey else { throw BotFailure.stale }
        let rows = try await engine.wire.sessionMessages(key, profile: engine.target.profile, offset: offset)
        try engine.check(attempt)
        return rows ?? []
    }

    private func newestRows(attempt: Int) async throws -> (rows: [BotJSON], reachedStart: Bool) {
        var rows: [BotJSON] = []
        for _ in 0..<Self.newestPageLimit {
            let page = try await self.page(at: rows.count, attempt: attempt)
            rows = page + rows
            if page.count < HermesREST.transcriptPageSize { return (rows, true) }
            if history.reaches(page) { break }
        }
        return (rows, false)
    }

    private static let newestPageLimit = 5

    private var isIdle: Bool { activeStreamID == nil && submitsInFlight == 0 }

    private func readNewestRows(attempt: Int) async {
        let turns = turnsStarted
        do {
            let fresh = try await newestRows(attempt: attempt)
            history.mergeNewest(fresh.rows, reachedStart: fresh.reachedStart)
            historyTurns = turns
            historyFailure = nil
        } catch {
            guard attempt == engine.generation, !Task.isCancelled else { return }
            historyFailure = error
        }
    }

    private enum EndedTurn {
        case receipt(SavedTurn)
        case start(Double)
    }

    private func refreshHistory(after turn: EndedTurn) {
        let attempt = engine.generation, turns = turnsStarted
        historyRefresh?.cancel()
        historyRefresh = Task { [weak self] in
            guard let fresh = try? await self?.newestRows(attempt: attempt), let self, !Task.isCancelled,
                  attempt == self.engine.generation, turns == self.turnsStarted, self.isIdle else { return }
            var merged = self.history
            merged.mergeNewest(fresh.rows, reachedStart: fresh.reachedStart)
            guard self.holds(turn, in: merged) else { return }
            self.history = merged
            self.historyTurns = turns
            self.historyFailure = nil
            self.rebuiltRunningTurn = false
            self.delegate?.hermesReplaceTranscript(self.historyTranscript())
        }
    }

    private func holds(_ turn: EndedTurn, in rows: HermesTranscriptHistory) -> Bool {
        switch turn {
        case .receipt(let saved):
            return rows.holds(saved.replyRowID) && saved.promptRowID.map(rows.holds) != false
        case .start(let startedAt):
            guard let prompt = savedPromptRowID(startedAt: startedAt, in: rows) else { return false }
            let projected = HermesTranscriptProjection.project(rows.rows, root: engine.storedKey ?? "")
            return projected.messages.last?.rowID != prompt
                && projected.toolCallGroups.allSatisfy { $0.anchorMessageID != nil }
                && projected.reasoningGroups.allSatisfy { $0.anchorMessageID != nil }
        }
    }

    func loadOlderHistory() async -> Bool {
        guard history.hasOlder, engine.connectionState == .connected else { return false }
        let attempt = engine.generation, turns = turnsStarted
        do {
            if historyTurns != turns || !isIdle || history.needsRecount {
                let fresh = try await newestRows(attempt: attempt)
                if turns == turnsStarted, isIdle {
                    history.mergeNewest(fresh.rows, reachedStart: fresh.reachedStart)
                    historyTurns = turns
                    historyFailure = nil
                    delegate?.hermesReplaceTranscript(historyTranscript())
                    guard history.hasOlder else { return false }
                } else if !history.countNewer(in: fresh.rows) {
                    return false
                }
            }
            let offset = history.nextOffset
            let page = try await self.page(at: offset, attempt: attempt)
            guard offset == history.nextOffset else { return false }
            let added = history.prependOlder(page)
            delegate?.hermesPrependHistory(historyTranscript())
            return added
        } catch {
            if attempt == engine.generation, !Task.isCancelled {
                reportHistoryFailure(error)
            }
            return false
        }
    }

    func retryHistoryIfFailed() async {
        guard historyFailure != nil, engine.connectionState == .connected, activeStreamID == nil else { return }
        let attempt = engine.generation
        await readNewestRows(attempt: attempt)
        guard attempt == engine.generation, isIdle else { return }
        if let historyFailure {
            reportHistoryFailure(historyFailure)
        } else {
            delegate?.hermesReplaceTranscript(historyTranscript())
        }
    }

    var hasHistoryFailure: Bool { historyFailure != nil }

    private func reportHistoryFailure(_ error: Error) {
        delegate?.hermesHistoryDidFail(error, message: BotConnectionAdvice.message(for: error, address: engine.connection.address))
    }

    private func rebuildAfterGap() {
        needsRebuild = true
        reattach()
    }

    private func reattach() {
        requests.willLeave()
        cancelAttach()
        engine.suspend()
        startAttach()
    }

    private var drivenLiveActivity: (any AgentLiveActivityManaging)? {
        guard let liveActivities, let id = liveActivity?.sessionID, liveActivities.drivenSessionID == id else { return nil }
        return liveActivities
    }

    private func startLiveActivity() {
        guard let liveActivities, let liveActivity else { return }
        if let bot = liveActivity.bot {
            let title = botProfile.map { BotProfileAppearance(profile: $0).title } ?? engine.target.profile
            liveActivities.startBot(bot, title: title, turn: liveActivity.turn, startedAt: activeRunStartedAt ?? Date())
        } else if let key = liveActivity.pushSessionID {
            let link = HermesDeepLink.sessionURL(for: HermesSessionDestination(
                server: engine.server, profile: engine.target.profile, key: engine.root ?? key))
            liveActivities.startSession(sessionID: liveActivity.sessionID, server: engine.server, destinationURL: link,
                                        pushSessionID: key,
                                        sessionTitle: delegate?.streamCoordinatorDisplayTitle ?? String(localized: "Untitled Session"),
                                        turn: liveActivity.turn, startedAt: activeRunStartedAt ?? Date())
        }
        syncLiveActivityPushKey(always: true)
        shownWaiting = nil
        syncLiveActivityWaiting()
        syncBotWorkSummary()
    }

    private func syncLiveActivityPushKey(always: Bool = false) {
        guard let key = engine.storedKey, always || key != liveActivity?.pushSessionID,
              let driven = drivenLiveActivity else { return }
        liveActivity?.pushSessionID = key
        driven.movePushSession(to: key)
    }

    private func botActivity() -> AgentRunActivityBot? {
        guard case .canonicalChat = engine.target, let profile = botProfile else { return nil }
        let destination = botDestination(profile)
        shownBotLook = BotProfileAppearance(profile: profile)
        shownBotPhoto = settings.avatars[profile.id].map(ObjectIdentifier.init)
        guard var bot = AgentRunActivityBot(destination, avatarFile: writeBotAvatar?(profile, destination)) else { return nil }
        bot.pushSessionID = engine.storedKey
        return bot
    }

    private func botDestination(_ profile: BotProfile) -> BotDestination {
        BotDestination(server: engine.server, connectionID: engine.connection.id, profile: profile.id,
                       conversation: engine.root)
    }

    private func botRosterDidChange() {
        guard liveActivity?.bot != nil, let profile = botProfile, let driven = drivenLiveActivity else { return }
        let look = BotProfileAppearance(profile: profile)
        guard look != shownBotLook else { return }
        shownBotLook = look
        _ = writeBotAvatar?(profile, botDestination(profile))
        driven.update(.sessionTitle(look.title))
    }

    private func botPictureDidChange() {
        guard liveActivity?.bot != nil, let profile = botProfile, let driven = drivenLiveActivity else { return }
        let photo = settings.avatars[profile.id].map(ObjectIdentifier.init)
        guard photo != shownBotPhoto else { return }
        shownBotPhoto = photo
        _ = writeBotAvatar?(profile, botDestination(profile))
        driven.update(.sessionTitle(BotProfileAppearance(profile: profile).title))
    }

    private func syncLiveActivityWaiting() {
        let waiting: AgentLiveActivityEvent?
        if !requests.isWaiting { waiting = nil }
        else if case .approval? = requests.onScreen { waiting = .waitingForApproval }
        else { waiting = .waitingForClarification }
        guard waiting != shownWaiting else { return }
        shownWaiting = waiting
        if let waiting { drivenLiveActivity?.update(waiting) }
    }

    private func syncBotWorkSummary() {
        guard liveActivity?.bot != nil, let driven = drivenLiveActivity else { return }
        driven.update(.workSummary(BotLiveActivity.countChips(plan: activity.plan,
                                                                      workers: activity.delegatedWork.activeCount)))
    }

    private func endLiveActivity(_ ending: TranscriptTurnRunOutcome.Ending) {
        switch ending {
        case .completed:
            drivenLiveActivity?.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
        case .cancelled:
            drivenLiveActivity?.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
        case .failed:
            drivenLiveActivity?.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
        }
    }

    private static func heldDeltas(_ held: [BotJSON], after sequence: Int, alreadyIn reply: String,
                                   following replayed: String) -> Set<Int> {
        var cursor = sequence, joined = replayed, run: [Int] = [], matched: [Int] = []
        for frame in held {
            guard let seq = frame["seq"].integer, seq > cursor else { continue }
            cursor = seq
            let type = frame["type"].text
            if type == "message.start" { break }
            guard type == "message.delta", let text = frame["payload"]["text"].text, !text.isEmpty else { continue }
            joined += text
            guard joined.utf8.count <= reply.utf8.count else { break }
            run.append(seq)
            if reply.utf8.suffix(joined.utf8.count).elementsEqual(joined.utf8) { matched = run }
        }
        return Set(matched)
    }

    private static func replyText(_ frames: [BotJSON]) -> String {
        let start = frames.lastIndex { $0["type"].text == "message.start" }.map { $0 + 1 } ?? frames.startIndex
        return frames[start...].reduce(into: "") { text, frame in
            if frame["type"].text == "message.delta" { text += frame["payload"]["text"].text ?? "" }
        }
    }

    private static func holdsPrompt(_ prompt: ChatMessage, in messages: [ChatMessage], startedAt: Double?) -> Bool {
        guard let settled = messages.last(where: TranscriptTurnClassifier.isTurnBoundary) else { return false }
        guard let startedAt, let stamp = settled.timestamp else {
            return settled.content == prompt.content && settled.attachments == prompt.attachments
        }
        return stamp >= startedAt
    }

    static func displayed(_ message: ChatMessage) -> ChatMessage {
        guard message.role == "user", let content = message.content else { return message }
        let shown = MessageAttachment.hermesReferences(in: content)
        let text = BotMentions.displayText(shown.text)
        guard text != content || !shown.attachments.isEmpty else { return message }
        let chips = shown.attachments
        return ChatMessage(
            role: message.role, content: text, timestamp: message.timestamp, messageId: message.messageId,
            name: message.name, toolCallId: message.toolCallId, toolUseId: message.toolUseId,
            toolCalls: message.toolCalls, contentParts: message.contentParts, reasoning: message.reasoning,
            attachments: chips.isEmpty ? message.attachments : (message.attachments ?? []) + chips,
            displayKind: message.displayKind, displayMetadata: message.displayMetadata, turnTps: message.turnTps,
            turnDuration: message.turnDuration, rowID: message.rowID, isCompacted: message.isCompacted
        )
    }

    private static func toolEvent(_ payload: BotJSON, completed: Bool) -> ToolStreamEvent {
        ToolStreamEvent(
            eventType: completed ? "tool.complete" : "tool.start",
            name: payload["name"].text,
            preview: completed ? payload["result"].toolResultPreview : nil,
            args: payload["args"].argumentDictionary,
            duration: completed ? payload["duration_s"].number : nil,
            isError: nil,
            stableID: payload["tool_id"].text
        )
    }

    static func contextWindow(_ usage: BotJSON) -> ContextWindowSnapshot? {
        guard let used = usage["context_used"].integer, let length = usage["context_max"].integer, length > 0 else { return nil }
        return ContextWindowSnapshot(contextLength: length, thresholdTokens: nil, lastPromptTokens: used,
                                     inputTokens: usage["input"].integer, outputTokens: usage["output"].integer,
                                     estimatedCost: nil)
    }

    private static func date(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return min(Date(timeIntervalSince1970: seconds), Date())
    }
}

extension HermesChatTurnCoordinator: ChatTurnCoordinating {
    var recoveryState: ActiveStreamRecoveryState {
        guard activeStreamID != nil, engine.isActive else { return .idle }
        switch engine.connectionState {
        case .connected: return .idle
        case .recovering: return .checking
        case .disconnected: return isNetworkAvailable() ? .reconnecting : .waitingForNetwork
        }
    }
    var liveTokensPerSecond: Double? { nil }
    var hasCompletedCurrentResponse: Bool { false }
    var isConnectionSuspended: Bool { !engine.isActive }
    var isReplayConnection: Bool { false }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate as? any HermesChatTurnDelegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityExcerpts != shows else { return }
        showsLiveActivityExcerpts = shows
        if !shows { drivenLiveActivity?.update(.clearResponseExcerpt) }
    }

    func prepareForNewResponse() {}

    func suspendActiveStreamConnection() {
        drivenLiveActivity?.markStale()
        requests.willLeave()
        cancelAttach()
        engine.suspend()
    }

    func reconnectIfNeeded(modelContext: ModelContext?) async {
        guard !needsSignIn else { return }
        await activate()
    }

    func networkPathDidChange(modelContext: ModelContext?) async {
        guard !needsSignIn, engine.isActive, attaching == nil, engine.connectionState == .disconnected,
              isNetworkAvailable() else { return }
        engine.suspend()
        await startAttach().value
    }

    func recoverStaleStreamIfNeeded(now: Date, modelContext: ModelContext?) async {}

    func clearReplayConnection() {}
}

extension HermesChatTurnCoordinator: HermesConversationOwner {
    func conversationDidFollowReplacedChat() {
        followedReplacements += 1
        savedTurn = nil; completedFailed = false; queuedPrompts = []; queuedImages = [:]; lostTurn = nil; runningAdmission = nil
        turnBase = nil; screenUse = nil
        finish(.cancelled)
        sideTasks.forgetChat()
        hostNotices.removeAll()
        forgetHistoryUntilRebuild()
        delegate?.hermesBotChatWasReplaced()
    }

    func conversationDidIdentify(root: String) {
        delegate?.hermesDidIdentify(root: root)
    }

    func conversationDidReset() {
        endCompaction()
        requests.reset()
        settings.disconnect()
        activity.delegatedWork.disconnect()
        heldFrames = []; deltasInRebuild = []; replayedReply = ""
    }

    func conversationWillReplay(newRuntime: Bool, newEpoch: Bool) {
        requests.willReplay()
        if newRuntime { activity.dropPlan() }
        if newRuntime || newEpoch { hostNotices.removeAll() }
    }

    func conversationDidReplay(_ reply: BotJSON, frames: [BotJSON]) {
        requests.didReplay(reply, frames: frames)
        defer { requests.willReadSnapshot() }
        let lostFrames = engine.replayWasReset || needsRebuild
        sideTasks.didReplay(frames, lostFrames: lostFrames)
        if lostFrames { activity.dropNotice() }
        guard !lostFrames else {
            frames.forEach { hostNotices.receive($0, live: false); endDeferredPick(on: $0) }
            replayedReply = Self.replyText(frames)
            return
        }
        frames.forEach { apply($0) }
    }

    func conversationDidReadSnapshot(_ snapshot: BotJSON, runtime: String, attempt: Int) async throws {
        guard engine.isCurrent(snapshot) else { throw BotFailure.unsupported }
        if engine.replayWasReset || needsRebuild {
            if compactionPending { history = HermesTranscriptHistory() }
            await readNewestRows(attempt: attempt)
        }
        try engine.check(attempt)
        reconcile(with: snapshot)
    }

    func conversationDidFailToAttach(_ error: Error) {
        if history.newestCoverage == nil { needsRebuild = true }
        delegate?.hermesAttachDidFail(error)
    }

    func conversationDidConnect(runtime: String, attempt: Int) async throws {
        heldFrames = []; deltasInRebuild = []; replayedReply = ""
        needsSignIn = false
        delegate?.hermesConnectionDidChange(failure: nil, unserved: nil, mayRetry: true)
        if let historyFailure {
            reportHistoryFailure(historyFailure)
        }
        sideTasks.didConnect(runtime: runtime, attempt: attempt)
        Task { [settings] in await settings.connect(runtime: runtime, attempt: attempt) }
        Task { [slashCommands] in await slashCommands.connect(runtime: runtime, attempt: attempt) }
        let workers = HermesDelegatedWork.Context(connectionID: engine.connection.id, runtime: runtime, generation: attempt)
        Task { [weak self] in
            guard let self, self.engine.generation == attempt else { return }
            await self.activity.delegatedWork.connect(workers)
        }
    }

    func conversation(didReceive frame: BotJSON, afterGap: Bool) {
        guard !afterGap else {
            sideTasks.receive(frame)
            hostNotices.receive(frame, live: true)
            endDeferredPick(on: frame)
            return rebuildAfterGap()
        }
        apply(frame, live: true)
    }

    func conversationDidLoseFrames() { rebuildAfterGap() }

    private func endDeferredPick(on frame: BotJSON) {
        switch frame["type"].text {
        case "session.updated": settings.controls.holdDeferredPickUpdate(frame["payload"])
        case "notification.show" where frame["payload"]["key"].text == "model_switch.dropped":
            settings.controls.dropDeferredPick()
        default: break
        }
    }

    func conversation(didHold frame: BotJSON) {
        if heldFrames.count < HermesConversation.heldFrameLimit { heldFrames.append(frame) }
        if frame["type"].text == "request.cancel" { requests.holdRequestFrame() }
    }

    func conversation(didReceiveRequest envelope: BotJSON) {
        requests.receive(envelope)
    }

    func conversationWillDisconnect() {
        requests.willLeave()
        requests.disconnect()
        activity.delegatedWork.disconnect()
    }

    func conversationDidDisconnect(_ failure: BotFailure, retrying: Bool) {
        endCompaction()
        endScreenUse()
        drivenLiveActivity?.markStale()
        if failure == .rejected(401) { needsSignIn = true }
        guard !retrying else { return }
        var unserved: HermesUnservedProfile?
        if case .profileNotServed(let profile, let reason) = failure {
            unserved = HermesUnservedProfile(profile: profile, hostReason: reason?.hostText)
        }
        delegate?.hermesConnectionDidChange(failure: BotConnectionAdvice.message(for: failure, address: engine.connection.address),
                                            unserved: unserved, mayRetry: unserved == nil)
    }
}
