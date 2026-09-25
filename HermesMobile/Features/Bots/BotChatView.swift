import SwiftUI

@MainActor struct BotChatView: View {
    /// Scroll anchor for the pending request card, so the status line can bring
    /// the user back to it from anywhere in the transcript.
    fileprivate static let requestAnchor = "bot-pending-request"

    @Environment(\.scenePhase) private var scenePhase
    private let mentionAvatars: [String: UIImage]
    /// Called when this chat was opened for a conversation a deep link named and the
    /// bot's canonical chat has since moved on, so the inbox can take the user back
    /// instead of leaving a dead transcript on screen (#554).
    private let onConversationUnavailable: (() -> Void)?
    @State private var model: BotConversation
    @State private var stopAction: BotConversation.StopAction?
    @State private var recoveryID = UUID()
    @State private var followLatch = ChatScrollPolicy.FollowLatch()
    @State private var isNearBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    /// Bumped by the status line's Review action; the transcript scrolls on change.
    @State private var showRequestID = UUID()
    @State private var showingProfileEditor = false
    @State private var showingDelegatedWork = false
    /// Measured composer height; sizes the material fade behind it, as the main chat does.
    @State private var composerHeight: CGFloat = 52
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var window = BotTranscriptWindow()
    /// When the title face's current 15 fps beat began; see `titleFaceMotion`.
    @State private var workingBeat = BotWorkingBeat()

    init(server: URL, connection: BotConnection, profile: BotProfile, roster: [BotProfile],
         avatars: [String: UIImage], conversation: String? = nil,
         onConversationUnavailable: (() -> Void)? = nil) {
        mentionAvatars = avatars
        self.onConversationUnavailable = onConversationUnavailable
        _model = State(initialValue: BotConversation(server: server, connection: connection, profile: profile,
                                                     roster: roster, conversation: conversation, historyCache: .shared,
                                                     liveActivityFeed: .shared))
    }

    init(model: BotConversation, onConversationUnavailable: (() -> Void)? = nil) {
        mentionAvatars = [:]
        self.onConversationUnavailable = onConversationUnavailable
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager over a bounded window, like the Sessions transcript: a
                    // settled reply is a hosted selection document, and a lazy stack
                    // places rows it has not built from an estimate, which strands
                    // the scroll under load (issue #553).
                    VStack(alignment: .leading, spacing: 8) {
                        if window.hasEarlier(count: model.messages.count) {
                            // The window widens in place, so there is no loading state.
                            LoadOlderMessagesButton(isLoading: false) { loadEarlier(proxy: proxy) }
                        }
                        ForEach(model.messages[window.start(count: model.messages.count)...]) { message in
                            settledActivity(anchoredTo: message.id)
                            BotArtifactMessageView(message: message, model: model).id(message.id)
                        }
                        settledActivity(anchoredTo: nil)
                        // The live turn reads like a settled one: prompt, work, then reply.
                        if let prompt = model.liveMessages.first(where: { $0.role == "user" }) {
                            BotArtifactMessageView(message: prompt, model: model)
                        }
                        if model.liveActivity.hasTurnWork {
                            BotActivityBlocksView(
                                id: "bot-live", reasoning: model.liveActivity.reasoning,
                                toolCalls: model.liveActivity.toolCalls, isLive: true
                            )
                        }
                        if let reply = model.liveMessages.first(where: { $0.role == "assistant" }) {
                            BotArtifactMessageView(message: reply, model: model, isLive: true)
                        }
                        if let plan = model.plan {
                            BotPlanRowView(plan: plan).id("bot-plan")
                        }
                        // The blocking request sits where the work stopped, so the
                        // command reads under the tool row that asked for it.
                        if let request = model.pendingRequest {
                            BotPendingRequestCard(
                                request: request, identity: identity,
                                isEnabled: model.mayAnswer, canStop: model.mayStop,
                                isAnswering: model.answeringRequestID != nil,
                                resolution: resolution(for: request),
                                onApprove: approve, onAnswer: answer, onSkip: skip,
                                onCredential: sendCredential,
                                canDecline: model.mayDecline, onDecline: decline,
                                onStop: { stopAction = model.prepareStop() }
                            )
                            .id(BotChatView.requestAnchor)
                        }
                        if let startedAt = model.workingRowStartedAt {
                            ChatWorkingRowView(startedAt: startedAt)
                        }
                        Color.clear.frame(height: 1).id("bot-transcript-bottom")
                    }
                    .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 20 : 16)
                    .padding(.top, 16)
                    .padding(.bottom, 44)
                    // A tapped row must stay under the finger: stop following so
                    // neither the size-change anchor nor the next activity update
                    // moves the reader. Latest brings them back.
                    .chatDisclosureToggled { handleFollowEvent(.userScrollBegin) }
                    .background {
                        ChatScrollObserver(isStreaming: isStreaming, onFollowEvent: handleFollowEvent, onMetrics: updateScrollMetrics)
                            .accessibilityHidden(true)
                    }
                }
                .defaultScrollAnchor(ChatScrollPolicy.initialTranscriptAnchor, for: .initialOffset)
                .onChange(of: model.messages.count, initial: true) { _, count in window.seed(count: count) }
                .defaultScrollAnchor(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: followsLatest), for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { followLatest(proxy) }
                .onChange(of: model.liveMessages.last?.content) { followLatest(proxy) }
                .onChange(of: model.liveActivity.toolCalls.count) { followLatest(proxy) }
                .onChange(of: model.liveActivity.reasoning.count) { followLatest(proxy) }
                .onChange(of: model.connectionState) { followLatest(proxy) }
                // A request that needs the user wins over where they had scrolled.
                .onChange(of: model.pendingRequest?.requestID) { _, id in
                    guard id != nil else { return }
                    handleFollowEvent(.reset)
                    proxy.scrollTo(BotChatView.requestAnchor, anchor: .bottom)
                }
                .onChange(of: showRequestID) { proxy.scrollTo(BotChatView.requestAnchor, anchor: .bottom) }
                .overlay(alignment: .bottom) {
                    if showsScrollToBottomButton {
                        // The safe-area inset already keeps this above the composer.
                        ChatScrollToBottomButton(bottomPadding: 12) {
                            ChatHaptics.scrolledToLatest(isEnabled: isHapticsEnabled)
                            handleFollowEvent(.reset)
                            withAnimation(isStreaming ? nil : ChatMotion.scrollToLatest(reduceMotion: reduceMotion)) {
                                followLatest(proxy)
                            }
                        }
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsScrollToBottomButton)
                .overlay {
                    if model.messages.isEmpty && model.liveMessages.isEmpty && model.pendingRequest == nil {
                        // Recovery with nothing on screen yet is the first load: the
                        // same skeleton as a Sessions chat, not a status line.
                        if model.connectionState == .recovering && !model.hasRecentTranscript {
                            ChatTranscriptLoadingSkeletonView()
                        } else if model.connectionState == .connected {
                            ContentUnavailableView {
                                Image(systemName: "bubble.left.and.bubble.right")
                            } description: {
                                Text("Send a message to start the conversation.")
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
                .adaptiveSoftScrollEdges(.top)
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .navigationTitle(model.profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The bot's face and name sit in one pill beside Back, and that pill is the
            // way into its profile. iOS 26 draws the toolbar glass; older systems get a material.
            ToolbarItem(placement: .topBarLeading) {
                Button { showingProfileEditor = true } label: {
                    HStack(spacing: 8) {
                        BotAvatarView(profile: model.profile,
                                      avatar: BotAvatarStore.shared.images(connectionID: model.connection.id)[model.profile.id],
                                      size: 30, motion: titleFaceMotion, expression: model.titleFace.expression)
                        Text(model.profile.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    }
                    .modifier(BotChatTitlePillFallback())
                }
                .accessibilityLabel(model.profile.name)
                .accessibilityValue(model.titleFace.accessibilityValue ?? "")
                .accessibilityHint(Text("Opens this bot’s profile."))
            }
            if model.delegatedWork.hasWorkers {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDelegatedWork = true
                        Task { await model.delegatedWork.refresh() }
                    } label: {
                        Image(systemName: "person.2")
                            .overlay(alignment: .topTrailing) {
                                Text("\(min(model.delegatedWork.activeCount, 99))")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(.green, in: Capsule())
                                    .offset(x: 7, y: -7)
                            }
                    }
                    .accessibilityLabel("Delegated work, \(model.delegatedWork.activeCount) active workers")
                    .accessibilityHint(Text("Shows worker status, recent output, and interrupt controls."))
                }
            }
            if !model.chatControls.controls.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { BotSessionControlMenu(settings: model.chatControls) }
            }
        }
        .toolbar(removing: .title)
        .navigationDestination(isPresented: $showingProfileEditor) {
            BotProfileEditorView(server: model.server, connection: model.connection, profile: model.profile,
                                 avatar: BotAvatarStore.shared.images(connectionID: model.connection.id)[model.profile.id]) {
                Task { await model.refreshProfile() }
            }
            .id(model.connection.id.uuidString + model.profile.id)
        }
        .sheet(isPresented: $showingDelegatedWork) {
            BotDelegatedWorkView(work: model.delegatedWork)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: recoveryID) {
            if scenePhase == .active { await model.recover() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { recoveryID = UUID(); workingBeat.rearm() }
            else { stopAction = nil; model.suspend() }
        }
        .onChange(of: model.turn) { workingBeat.observe(model.turn, at: Date()) }
        .onDisappear { stopAction = nil; model.suspend() }
        .pushPresence(model.pushPresence)
        .onChange(of: model.linkedRootIsStale) {
            // The link named a conversation this bot has replaced: hand it back to
            // the inbox, which reports it (#554).
            if model.linkedRootIsStale { onConversationUnavailable?() }
        }
        .confirmationDialog("Stop this bot’s current work?", isPresented: Binding(
            get: { stopAction != nil }, set: { if !$0 { stopAction = nil } }
        ), titleVisibility: .visible) {
            if let action = stopAction {
                Button("Stop current work", role: .destructive) {
                    stopAction = nil
                    Task { await model.stop(action) }
                }
            }
        } message: {
            Text("This stops current work in this conversation, including work started in Desktop, clears queued prompts and denies pending approvals. It also stops host speech playback. A command already sent may reach later Desktop work.")
        }

    }

    /// Which bot on which connection, so two hosts with equal Profile names
    /// never produce an anonymous card.
    private var identity: String {
        String(localized: "\(model.profile.name) on \(model.connection.name)")
    }

    /// The verdict for the request on screen, and only that one.
    private func resolution(for request: BotPendingRequest) -> BotRequestResolution? {
        guard let resolution = model.requestResolution, resolution.requestID == request.requestID else { return nil }
        return resolution
    }

    private func approve(_ choice: BotApprovalRequest.Choice) {
        guard let action = model.prepareAnswer() else { return }
        Task { await model.respond(action, choice: choice) }
    }

    private func answer(_ answers: [BotQuestionAnswer]) {
        guard let action = model.prepareAnswer() else { return }
        Task { await model.answerQuestion(action, answers) }
    }

    private func skip() {
        guard let action = model.prepareAnswer() else { return }
        Task { await model.skipQuestion(action) }
    }

    /// The typed value goes straight from the field to the dispatch. An empty
    /// one is the Skip button, which the host reads as a decline.
    private func sendCredential(_ value: String) {
        guard let action = model.prepareAnswer() else { return }
        Task { await model.answerCredential(action, value: value) }
    }

    private func decline() {
        guard let action = model.prepareAnswer() else { return }
        Task { await model.declineDesktopTask(action) }
    }

    @ViewBuilder
    private func settledActivity(anchoredTo anchorID: String?) -> some View {
        ForEach(model.settledActivity.filter { $0.anchorMessageID == anchorID }) { activity in
            BotActivityBlocksView(id: activity.id, reasoning: activity.reasoning, toolCalls: activity.toolCalls)
        }
    }

    private var followsLatest: Bool { followLatch.isFollowing }

    /// Reveals one more page and keeps the message the reader was on at the top,
    /// since the new rows push everything below them down.
    private func loadEarlier(proxy: ScrollViewProxy) {
        let count = model.messages.count
        let firstShown = model.messages[window.start(count: count)...].first?.id
        handleFollowEvent(.userScrollBegin)
        window.loadEarlier()
        guard let firstShown else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(firstShown, anchor: .top)
        }
    }

    private func handleFollowEvent(_ event: ChatScrollPolicy.FollowEvent) {
        let resolved = ChatScrollPolicy.resolveFollow(current: followLatch, event: event)
        if resolved != followLatch { followLatch = resolved }
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        let wasNearBottom = isNearBottom
        isNearBottom = ChatScrollPolicy.isNearBottom(distanceFromBottom: metrics.distanceFromBottom, isStreaming: isStreaming)
        handleFollowEvent(.contentScrolled(
            isAtBottom: ChatScrollPolicy.isAtBottom(distanceFromBottom: metrics.distanceFromBottom),
            isUserScrolling: metrics.isUserInteracting,
            movedAwayFromBottom: metrics.movedAwayFromBottom,
            wasNearBottom: wasNearBottom
        ))
    }

    private var isStreaming: Bool { [.running, .needsAttention, .stopping].contains(model.turn) }

    /// The title face sways for one beat after work starts or the app returns mid-turn,
    /// then holds a still lean; it never moves while the app is inactive. Waiting and
    /// failed faces only blink (`TitleFace.motion`).
    private var titleFaceMotion: BotFaceMotion {
        guard scenePhase == .active else { return .still }
        return model.titleFace.motion(beatStart: workingBeat.start)
    }

    private var showsScrollToBottomButton: Bool {
        ChatScrollPolicy.showsScrollToBottomButton(
            isNearBottom: isNearBottom, isStreaming: isStreaming, isFollowing: followsLatest
        )
    }

    private func followLatest(_ proxy: ScrollViewProxy) {
        guard followsLatest else { return }
        // The stable trailing anchor follows growing output without animating every token.
        proxy.scrollTo("bot-transcript-bottom", anchor: .bottom)
    }

    /// The composer over the same bottom fade the main chat uses, so the two
    /// transcripts end identically. The fade reaches 34 pt above the composer.
    private var composer: some View {
        BotChatComposerView(
            model: model, mentionAvatars: mentionAvatars,
            onStop: { stopAction = model.prepareStop() },
            onReconnect: { recoveryID = UUID() },
            onShowRequest: { showRequestID = UUID() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .background(alignment: .bottom) {
            BottomComposerMaterialFade(composerHeight: composerHeight)
                .frame(height: max(96, composerHeight + 34))
        }
    }
}


/// Before iOS 26 the toolbar draws no glass of its own, so the pill supplies a material.
struct BotChatTitlePillFallback: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

/// The settled messages the Bot transcript builds. The host sends the whole
/// history; drawing only the latest page keeps an eager transcript cheap.
/// Messages that settle after opening stay visible, so a reader scrolled up
/// never loses rows off the top.
struct BotTranscriptWindow: Equatable {
    static let pageSize = 50
    private var openedCount: Int?
    private var earlier = 0

    func start(count: Int) -> Int {
        max(0, min(openedCount ?? count, count) - Self.pageSize - earlier)
    }

    func hasEarlier(count: Int) -> Bool { start(count: count) > 0 }

    mutating func seed(count: Int) {
        if openedCount == nil, count > 0 { openedCount = count }
    }

    mutating func loadEarlier() { earlier += Self.pageSize }
}
