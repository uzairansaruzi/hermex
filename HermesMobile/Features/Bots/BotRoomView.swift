import SwiftUI

@MainActor struct BotRoomView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var reader: BotRoomReader
    @State private var revision = UUID()
    @State private var showingProfile = false
    @State private var visible = false
    @State private var owner = UUID()
    @State private var followLatch = ChatScrollPolicy.FollowLatch()
    @State private var isNearBottom = true
    @State private var pendingSequence: Int?
    @State private var showRequestID = UUID()
    @State private var dismissedErrors: Set<String> = []
    private var followsLatest: Bool { followLatch.isFollowing }
    let roster: [BotProfile]
    let avatars: [String: UIImage]

    init(reader: BotRoomReader, roster: [BotProfile], avatars: [String: UIImage]) {
        _reader = State(initialValue: reader); self.roster = roster; self.avatars = avatars
        _pendingSequence = State(initialValue: reader.initialSequence)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager: member replies are hosted selection documents, and a lazy
                // stack places unbuilt rows from an estimate, so the jump to a
                // search hit missed on a cold open (issue #553). History pages
                // in through Load earlier, which bounds what this builds.
                VStack(spacing: 16) {
                    if reader.hasEarlier {
                        // The new page pushes everything below it down, so bring the
                        // event the reader was on back to the top afterwards.
                        Button("Load earlier") {
                            handleFollowEvent(.userScrollBegin)
                            let firstShown = reader.events.first?.seq
                            Task {
                                await reader.loadEarlier()
                                guard let firstShown, reader.events.first?.seq != firstShown else { return }
                                await Task.yield()
                                proxy.scrollTo(firstShown, anchor: .top)
                            }
                        }
                            .disabled(reader.loadingEarlier || reader.link != .live)
                    }
                    if reader.foreignAuthority {
                        Text("Managed by another Hermes").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(reader.events) { event in
                        BotRoomEventView(
                            event: event,
                            room: reader.room,
                            roster: roster,
                            avatars: avatars,
                            transcriptMediaCacheNamespace: "\(reader.key.server.absoluteString)|bot-room:\(reader.room.id)"
                        )
                    }
                    if reader.events.isEmpty && reader.link == .live {
                        Text("No messages yet.").foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 0).id("room-actions")
                    ForEach(Array(reader.status.actions.enumerated()), id: \.offset) { _, action in
                        BotRoomActionCard(reader: reader, action: action)
                    }
                    Color.clear.frame(height: 1).id("room-bottom")
                }
                .padding(16)
                .background {
                    ChatScrollObserver(isStreaming: false, onFollowEvent: handleFollowEvent, onMetrics: updateScrollMetrics)
                        .accessibilityHidden(true)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: followsLatest), for: .sizeChanges)
            .onChange(of: pendingSequence.flatMap { sequence in
                reader.events.contains(where: { $0.seq == sequence }) ? sequence : nil
            }) { _, sequence in
                if let sequence {
                    handleFollowEvent(.userScrollBegin)
                    proxy.scrollTo(sequence, anchor: .center); pendingSequence = nil
                }
            }
            .onChange(of: reader.events.last?.seq) {
                if pendingSequence == nil && followsLatest { proxy.scrollTo("room-bottom", anchor: .bottom) }
            }
            .onChange(of: showRequestID) { proxy.scrollTo("room-actions", anchor: .top) }
            .overlay(alignment: .bottom) {
                if !isNearBottom && !reader.events.isEmpty {
                    ChatScrollToBottomButton(bottomPadding: 12) {
                        handleFollowEvent(.reset); proxy.scrollTo("room-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let pill {
                    BotComposerPillView(pill: pill, onReconnect: { revision = UUID() },
                        onShowRequest: { showRequestID = UUID() }, onCancelUpload: {},
                        onDismissError: { if let text = pill.errorText { dismissedErrors.insert(text) } },
                        onRetrySend: { Task { await reader.send(retry: true) } })
                }
                if reader.showsComposer { BotRoomComposerView(reader: reader, roster: roster, avatars: avatars) }
            }
        }
        .task(id: pill?.errorText) {
            guard let text = pill?.errorText else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            dismissedErrors.insert(text)
        }
        .onChange(of: errorTexts) { _, current in dismissedErrors.formIntersection(current) }
        .onChange(of: reader.busy) { _, busy in if busy { dismissedErrors = [] } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingProfile = true } label: {
                    HStack(spacing: 8) {
                        BotRoomAvatars(room: reader.room, roster: roster, avatars: avatars, size: 30)
                        Text(reader.room.name).font(.headline).lineLimit(1)
                    }
                    .modifier(BotChatTitlePillFallback())
                }
                .accessibilityLabel(reader.room.name)
                .accessibilityHint("Opens this room’s profile.")
            }
        }
        .navigationDestination(isPresented: $showingProfile) {
            BotRoomProfileView(reader: reader, roster: roster, avatars: avatars)
        }
        .task(id: revision) {
            visible = true
            if scenePhase == .active { await reader.open(owner: owner) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active && visible { revision = UUID() }
            else if visible { reader.leave(owner: owner) }
        }
        .onDisappear { visible = false; reader.leave(owner: owner) }
    }

    func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func handleFollowEvent(_ event: ChatScrollPolicy.FollowEvent) {
        let next = ChatScrollPolicy.resolveFollow(current: followLatch, event: event)
        if next != followLatch { followLatch = next }
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        let wasNearBottom = isNearBottom
        isNearBottom = ChatScrollPolicy.isNearBottom(distanceFromBottom: metrics.distanceFromBottom, isStreaming: false)
        handleFollowEvent(.contentScrolled(
            isAtBottom: ChatScrollPolicy.isAtBottom(distanceFromBottom: metrics.distanceFromBottom),
            isUserScrolling: metrics.isUserInteracting,
            movedAwayFromBottom: metrics.movedAwayFromBottom, wasNearBottom: wasNearBottom))
    }

    private var errorTexts: [String] {
        [reader.commandMessage, reader.errorMessage].compactMap { $0 }
    }

    private var pill: BotComposerPill? {
        BotComposerPill.room(link: reader.link, blocked: reader.status.blocked,
            hasActions: !reader.status.actions.isEmpty, mayRetry: reader.mayResend,
            errorText: errorTexts.first { !dismissedErrors.contains($0) })
    }
}

private struct BotRoomEventView: View {
    let event: BotRoomEvent
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let transcriptMediaCacheNamespace: String
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var responseIsVisible = false

    var body: some View {
        if event.kind == "message.user" {
            MessageBubbleView(
                message: ChatMessage(role: "user", content: event.payload["text"].text,
                    timestamp: event.timestamp, messageId: String(event.seq)),
                transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                contextMenuActions: actions,
                textOnly: true
            )
        } else if event.kind == "message.member" {
            HStack(alignment: .bottom, spacing: 8) {
                BotRoomMemberAvatar(member: event.member(in: room), roster: roster, avatars: avatars, size: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.sender(in: room)).font(.caption).foregroundStyle(.secondary)
                    ResponseTextSelection(identity: messageText, collectsGlyphs: responseIsVisible) {
                        MarkdownRenderer(content: messageText)
                    }
                    .onGeometryChange(for: Bool.self) { geometry in
                        guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return true }
                        return viewport.intersects(CGRect(origin: .zero, size: geometry.size))
                    } action: { responseIsVisible = $0 }
                        .padding(12).background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
                        .chatMessageContextMenu(actions, longPress: false)
                }
                Spacer(minLength: 20)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(event.systemText).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private var messageText: String { event.payload["text"].text ?? "" }

    private var actions: [ChatMessageActionItem] {
        BotMessageActions.items(copyText: messageText, isHapticsEnabled: isHapticsEnabled)
    }
}

struct BotRoomAvatars: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let size: CGFloat
    var body: some View {
        HStack(spacing: -size * 0.4) {
            ForEach(Array(room.members.prefix(3))) { member in
                BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: size)
            }
            if room.members.isEmpty {
                BotRoomMemberAvatar(member: nil, roster: roster, avatars: avatars, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

struct BotRoomMemberAvatar: View {
    let member: BotGroupRoom.Member?
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let size: CGFloat
    var body: some View {
        let profile = roster.first { $0.id == member?.profile }
        if let profile {
            BotAvatarView(profile: profile, avatar: avatars[profile.id], size: size, motion: .still)
        } else if let placeholder = BotProfile(.object(["name": .string("unknown")])) {
            BotAvatarView(profile: placeholder, avatar: nil, size: size, motion: .still)
        }
    }
}

/// Uses the inbox row's avatar/name/time layout; identity is supplied by its caller.
struct BotRoomInboxRow: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    var body: some View {
        HStack(spacing: 14) {
            BotRoomAvatars(room: room, roster: roster, avatars: avatars, size: 32).frame(width: 44)
            Text(room.name).font(.headline)
            Spacer(minLength: 8)
            if let date = room.updatedAt {
                Text(BotInboxDateLabel.text(for: date)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
