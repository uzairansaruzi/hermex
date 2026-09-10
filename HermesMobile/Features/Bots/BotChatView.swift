import SwiftUI

@MainActor struct BotChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: BotConversation
    @State private var stopAction: BotConversation.StopAction?
    @State private var confirmingDiscard = false
    @State private var recoveryID = UUID()
    @State private var followsLatest = true
    @State private var isAtBottom = true
    @FocusState private var composerFocused: Bool

    init(server: URL, connection: BotConnection, profile: BotProfile) {
        _model = State(initialValue: BotConversation(server: server, connection: connection, profile: profile))
    }

    init(model: BotConversation) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.connection.name + " / " + model.profile.id)
                    .font(.footnote).foregroundStyle(.secondary)
                Text(connectionLabel).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if model.messages.isEmpty && model.liveMessages.isEmpty && model.connectionState == .connected {
                            Text("No messages yet").foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { message in BotMessageRow(message: message) }
                        ForEach(model.liveMessages) { message in BotMessageRow(message: message) }
                        Color.clear.frame(height: 1).id("bot-transcript-bottom")
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
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
                .onChange(of: model.connectionState) { followLatest(proxy) }
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

    private func followLatest(_ proxy: ScrollViewProxy) {
        guard followsLatest else { return }
        // The stable trailing anchor follows growing output without animating every token.
        proxy.scrollTo("bot-transcript-bottom", anchor: .bottom)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if model.uncertainSend {
                Text("Send outcome unknown. Check the conversation in Desktop before sending again.").font(.footnote)
                if model.connectionState == .connected {
                    Button("Resolve held message…") { confirmingDiscard = true }.font(.footnote)
                }
            } else if model.turn == .needsAttention {
                Text("Needs attention. Answer the request in Hermes Desktop on this same connection.").font(.footnote)
            }
            if model.connectionState == .disconnected {
                Button("Reconnect") { recoveryID = UUID() }
            }
            TextField("Message bot", text: Binding(get: { model.draft }, set: { model.editDraft($0) }), axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .disabled(model.uncertainSend || model.turn == .submitting)
                .accessibilityLabel("Message bot")
            HStack {
                Text(turnLabel).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if model.mayStop {
                    Button("Stop…", systemImage: "stop.fill") { stopAction = model.prepareStop() }
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    Button("Send", systemImage: "arrow.up") { Task { await model.send() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!model.maySend || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .connected: return String(localized: "Connected")
        case .recovering: return String(localized: "Loading current conversation…")
        case .disconnected: return String(localized: "Disconnected · Last loaded conversation")
        }
    }

    private var turnLabel: String {
        switch model.turn {
        case .idle: return String(localized: "Ready")
        case .running: return String(localized: "Working")
        case .needsAttention: return String(localized: "Needs attention")
        case .submitting: return String(localized: "Sending…")
        case .stopping: return String(localized: "Stopping…")
        case .uncertain: return String(localized: "Outcome unknown")
        case .interrupted: return String(localized: "Work was interrupted. The saved conversation is loaded.")
        case .unknown: return String(localized: "Checking current work…")
        }
    }
}

private struct BotMessageRow: View {
    let message: ChatMessage
    var body: some View {
        if message.role == "user" {
            Text(message.content ?? "")
                .textSelection(.enabled)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            // Coalesced snapshots render synchronously: the deferred streaming
            // renderer can leave the trailing viewport blank as its height changes.
            MarkdownRenderer(content: message.content ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
