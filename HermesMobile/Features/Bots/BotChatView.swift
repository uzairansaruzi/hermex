import SwiftUI

@MainActor struct BotChatView: View {
    /// Scroll anchor for the pending request card, so the status line can bring
    /// the user back to it from anywhere in the transcript.
    fileprivate static let requestAnchor = "bot-pending-request"

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: BotConversation
    @State private var stopAction: BotConversation.StopAction?
    @State private var confirmingDiscard = false
    @State private var recoveryID = UUID()
    @State private var followsLatest = true
    @State private var isAtBottom = true
    /// Bumped by the status line's Review action; the transcript scrolls on change.
    @State private var showRequestID = UUID()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(server: URL, connection: BotConnection, profile: BotProfile) {
        _model = State(initialValue: BotConversation(server: server, connection: connection, profile: profile))
    }

    init(model: BotConversation) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.messages.isEmpty && model.liveMessages.isEmpty && model.connectionState == .connected {
                            Text("No messages yet").foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { message in
                            settledActivity(anchoredTo: message.id)
                            MessageBubbleView(message: message, textOnly: true)
                        }
                        settledActivity(anchoredTo: nil)
                        // The live turn reads like a settled one: prompt, work, then reply.
                        if let prompt = model.liveMessages.first(where: { $0.role == "user" }) {
                            MessageBubbleView(message: prompt, textOnly: true)
                        }
                        if model.liveActivity.hasTurnWork {
                            BotActivityBlocksView(
                                id: "bot-live", reasoning: model.liveActivity.reasoning,
                                toolCalls: model.liveActivity.toolCalls, isLive: true
                            )
                        }
                        if let reply = model.liveMessages.first(where: { $0.role == "assistant" }) {
                            MessageBubbleView(message: reply, textOnly: true)
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
                                onStop: { stopAction = model.prepareStop() }
                            )
                            .id(BotChatView.requestAnchor)
                        }
                        Color.clear.frame(height: 1).id("bot-transcript-bottom")
                    }
                    .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 20 : 16)
                    .padding(.vertical, 16)
                    // A tapped row must stay under the finger: stop following so
                    // neither the size-change anchor nor the next activity update
                    // moves the reader. Latest brings them back.
                    .environment(\.chatDisclosureToggled) { followsLatest = false }
                }
                .defaultScrollAnchor(ChatScrollPolicy.initialTranscriptAnchor, for: .initialOffset)
                .defaultScrollAnchor(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: followsLatest), for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height + geometry.contentInsets.bottom - 48
                } action: { _, atBottom in
                    isAtBottom = atBottom
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { followsLatest = false }
                    if phase == .idle && isAtBottom { followsLatest = true }
                }
                .onChange(of: model.messages.count) { followLatest(proxy) }
                .onChange(of: model.liveMessages.last?.content) { followLatest(proxy) }
                .onChange(of: model.liveActivity.toolCalls.count) { followLatest(proxy) }
                .onChange(of: model.liveActivity.reasoning.count) { followLatest(proxy) }
                .onChange(of: model.connectionState) { followLatest(proxy) }
                // A request that needs the user wins over where they had scrolled.
                .onChange(of: model.pendingRequest?.requestID) { _, id in
                    guard id != nil else { return }
                    followsLatest = true
                    proxy.scrollTo(BotChatView.requestAnchor, anchor: .bottom)
                }
                .onChange(of: showRequestID) { proxy.scrollTo(BotChatView.requestAnchor, anchor: .bottom) }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        Button("Latest", systemImage: "arrow.down") {
                            followsLatest = true
                            followLatest(proxy)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .navigationTitle(model.profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recoveryID) {
            if scenePhase == .active { await model.recover() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { recoveryID = UUID() }
            else { stopAction = nil; model.suspend() }
        }
        .onDisappear { stopAction = nil; model.suspend() }
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
        .confirmationDialog("Discard the held message?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("I checked Desktop; discard held message", role: .destructive) {
                Task { await model.discardUncertainSubmission() }
            }
        } message: {
            Text("First check whether Desktop received this message. Discarding removes the held text from Hermex. It does not stop or resend any work.")
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

    @ViewBuilder
    private func settledActivity(anchoredTo anchorID: String?) -> some View {
        ForEach(model.settledActivity.filter { $0.anchorMessageID == anchorID }) { activity in
            BotActivityBlocksView(id: activity.id, reasoning: activity.reasoning, toolCalls: activity.toolCalls)
        }
    }

    private func followLatest(_ proxy: ScrollViewProxy) {
        guard followsLatest else { return }
        // The stable trailing anchor follows growing output without animating every token.
        proxy.scrollTo("bot-transcript-bottom", anchor: .bottom)
    }

    private var composer: some View {
        BotChatComposerView(
            model: model,
            onStop: { stopAction = model.prepareStop() },
            onReconnect: { recoveryID = UUID() },
            onResolveHeldMessage: { confirmingDiscard = true },
            onShowRequest: { showRequestID = UUID() }
        )
    }
}
