import SwiftUI

@MainActor struct BotRoomView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var reader: BotRoomReader
    @State private var revision = UUID()
    @State private var showingProfile = false
    @State private var selectedThread: String?
    @State private var threadSequence: Int?
    let threadID: String?
    @State private var visible = false
    @State private var owner = UUID()
    @State private var followLatch = ChatScrollPolicy.FollowLatch()
    @State private var isNearBottom = true
    @State private var pendingSequence: Int?
    @State private var showRequestID = UUID()
    @State private var dismissedErrors: Set<String> = []
    @State private var window = BotRoomTranscriptWindow()
    private var followsLatest: Bool { followLatch.isFollowing }
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    /// Leaves the room for the inbox's sign-in form, after the host refused the password.
    let onUpdateSignIn: () -> Void

    init(reader: BotRoomReader, roster: [BotProfile], avatars: [String: UIImage], threadID: String? = nil, sequence: Int? = nil, onUpdateSignIn: @escaping () -> Void = {}) {
        _reader = State(initialValue: reader); self.roster = roster; self.avatars = avatars
        self.onUpdateSignIn = onUpdateSignIn; self.threadID = threadID
        _pendingSequence = State(initialValue: sequence ?? (threadID == nil ? reader.initialSequence : nil))
    }

    var body: some View {
        ScrollViewReader { proxy in
            let start = window.start(in: transcriptEvents, keeping: pendingSequence, overview: showsThreadOverview)
            let hasHiddenEvents = start > 0
            let showsWelcome = threadID == nil && reader.showsWelcome
            ScrollView {
                // At least as tall as the visible transcript while a new room shows
                // its welcome, which centres it; taller, and scrolling, only when
                // the welcome is (at accessibility text sizes).
                ZStack {
                    if showsWelcome { Color.clear.containerRelativeFrame(.vertical) }
                    // Eager over a bounded window, like Bot Chat: member replies are
                    // hosted selection documents, and a lazy stack places unbuilt rows
                    // from an estimate, so the jump to a search hit missed on a cold
                    // open (issue #553). The window keeps the build to the newest page.
                    VStack(spacing: 16) {
                        if !showsThreadOverview && (hasHiddenEvents || reader.hasEarlier) {
                            Button("Load earlier") { loadEarlier(proxy: proxy) }
                                .disabled(!hasHiddenEvents && (reader.loadingEarlier || reader.link != .live))
                        }
                        if reader.foreignAuthority {
                            Text("Managed by another Hermes").font(.caption).foregroundStyle(.secondary)
                        }
                        if threadID != nil, reader.threads.first(where: { $0.id == threadID })?.root == nil {
                            Text("Earlier messages not loaded").font(.caption).foregroundStyle(.secondary)
                        }
                        let rows = Array(transcriptEvents[start...])
                        ForEach((showsThreadOverview ? Array(rows.reversed()) : rows).map {
                            BotRoomTranscriptRow(event: $0, isOverview: threadID == nil)
                        }) { row in
                            let event = row.event
                            // Thread identity survives new replies and activity reordering.
                            if threadID == nil, let thread = reader.threads.first(where: { $0.latest.seq == event.seq }) {
                                Button { selectedThread = thread.id } label: {
                                    BotRoomThreadPreview(thread: thread, room: reader.room)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("room-thread-\(thread.id)")
                            } else {
                                BotRoomEventView(
                                    event: event,
                                    room: reader.room,
                                    roster: roster,
                                    avatars: avatars,
                                    transcriptMediaCacheNamespace: "\(reader.key.server.absoluteString)|bot-room:\(reader.room.id)"
                                )
                            }
                        }
                        if showsThreadOverview && (hasHiddenEvents || reader.hasEarlier) {
                            Button("Load earlier") { loadEarlier(proxy: proxy) }
                                .disabled(!hasHiddenEvents && (reader.loadingEarlier || reader.link != .live))
                        }
                        if showsWelcome {
                            BotRoomWelcomeView(room: reader.room, roster: roster, avatars: avatars,
                                               showsPrompt: reader.showsComposer)
                        }
                        Color.clear.frame(height: 0).id("room-actions")
                        ForEach(Array(reader.status.actions.enumerated()), id: \.offset) { _, action in
                            BotRoomActionCard(reader: reader, action: action)
                        }
                        Color.clear.frame(height: 1).id("room-bottom")
                    }
                    .padding(16)
                    // Centred in the reading column; the scroll view stays full width.
                    .frame(maxWidth: ChatReadingWidth.maximumWidth(horizontalPadding: 16))
                    .frame(maxWidth: .infinity)
                    .background {
                        ChatScrollObserver(isStreaming: false, onFollowEvent: handleFollowEvent, onMetrics: updateScrollMetrics)
                            .accessibilityHidden(true)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .defaultScrollAnchor(showsThreadOverview ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(showsThreadOverview ? nil : ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: followsLatest), for: .sizeChanges)
            .onChange(of: availableSearchSequence, initial: true) { _, sequence in
                guard threadID == nil, let sequence else { return }
                if let target = reader.events.first(where: { $0.seq == sequence })?.threadID {
                    threadSequence = sequence; selectedThread = target; pendingSequence = nil
                    return
                }
                handleFollowEvent(.userScrollBegin)
                window.reveal(sequence, in: transcriptEvents, overview: showsThreadOverview)
                proxy.scrollTo(BotRoomTranscriptRow.ID.event(sequence), anchor: .center); pendingSequence = nil
            }
            .task(id: threadID == nil ? nil : availableSearchSequence) {
                guard threadID != nil, let sequence = availableSearchSequence else { return }
                window.reveal(sequence, in: transcriptEvents, overview: showsThreadOverview)
                // A pushed destination lays out after the overview's synchronous
                // search callback. Wait for those materialized rows before jumping.
                await Task.yield()
                guard !Task.isCancelled else { return }
                handleFollowEvent(.userScrollBegin)
                proxy.scrollTo(BotRoomTranscriptRow.ID.event(sequence), anchor: .center); pendingSequence = nil
            }
            .onChange(of: transcriptEvents.last?.seq, initial: true) { seedWindow() }
            .onChange(of: reader.link) { seedWindow() }
            .onChange(of: transcriptEvents.last?.seq) {
                if !showsThreadOverview && pendingSequence == nil && followsLatest { proxy.scrollTo("room-bottom", anchor: .bottom) }
            }
            .onChange(of: showRequestID) { proxy.scrollTo("room-actions", anchor: .top) }
            .overlay(alignment: .bottom) {
                if !showsThreadOverview && !isNearBottom && !transcriptEvents.isEmpty {
                    ChatScrollToBottomButton(bottomPadding: 12) {
                        handleFollowEvent(.reset); proxy.scrollTo("room-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let pill {
                    BotComposerPillView(pill: pill, onReconnect: { revision = UUID() }, onUpdateSignIn: onUpdateSignIn,
                        onShowRequest: { showRequestID = UUID() }, onCancelUpload: {},
                        onDismissError: { if let text = pill.errorText { dismissedErrors.insert(text) } },
                        onRetrySend: { Task { await reader.send(retry: true, threadID: threadID) } })
                }
                if reader.showsComposer { BotRoomComposerView(reader: reader, threadID: threadID, roster: roster, avatars: avatars) }
            }
            .frame(maxWidth: ChatReadingWidth.maximumWidth(horizontalPadding: 16))
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
                        VStack(alignment: .leading, spacing: 0) {
                            if threadID != nil { Text("Thread").font(.headline) }
                            Text(reader.room.name).font(threadID == nil ? .headline : .caption).lineLimit(1)
                        }
                    }
                    .modifier(BotChatTitlePillFallback())
                }
                .accessibilityLabel(reader.room.name)
                .accessibilityHint("Opens this room’s profile.")
            }
        }
        .navigationDestination(isPresented: $showingProfile) {
            BotRoomProfileView(reader: reader, roster: roster, avatars: avatars, onUpdateSignIn: onUpdateSignIn)
        }
        .navigationDestination(item: $selectedThread) { selected in
            BotRoomView(reader: reader, roster: roster, avatars: avatars, threadID: selected,
                        sequence: threadSequence, onUpdateSignIn: onUpdateSignIn)
        }
        .onChange(of: selectedThread) { _, selected in
            if selected == nil { threadSequence = nil }
        }
        .task(id: revision) {
            visible = true
            if scenePhase == .active { await reader.open(owner: owner, preservingLoadedHistory: true) }
        }
        .onChange(of: scenePhase) {
            // Control Center and banners (`.inactive`) keep the room live (#902); the
            // background stops it (#533), and only a stopped room reopens.
            guard visible else { return }
            switch scenePhase {
            case .background: reader.leave(owner: owner, preservingLoadedHistory: true)
            case .active where reader.link == .idle: revision = UUID()
            default: break
            }
        }
        .onDisappear { visible = false; reader.leave(owner: owner, preservingLoadedHistory: true) }
        .onChange(of: reader.feedback) { _, feedback in
            if let feedback { ChatHaptics.botFeedback(feedback.event, isEnabled: isHapticsEnabled) }
        }
        .transcriptLinks()
    }

    private var availableSearchSequence: Int? {
        pendingSequence.flatMap { sequence in reader.events.contains { $0.seq == sequence } ? sequence : nil }
    }

    private var showsThreadOverview: Bool { threadID == nil && !reader.threads.isEmpty }

    /// Thread previews stand in for their latest event. Unthreaded history remains
    /// readable, but never gains a fabricated reply target.
    private var transcriptEvents: [BotRoomEvent] {
        if let threadID { return reader.threads.first { $0.id == threadID }?.events ?? [] }
        return (reader.events.filter { $0.threadID == nil } + reader.threads.map(\.latest))
            .sorted { $0.seq < $1.seq }
    }

    func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func seedWindow() { window.seed(transcriptEvents, live: reader.link == .live, overview: showsThreadOverview) }

    /// Reveals a page of events already in memory, or fetches one from the room
    /// when none are hidden. Chronological detail preserves its first row;
    /// descending overview appends below the reader without changing the offset.
    private func loadEarlier(proxy: ScrollViewProxy) {
        handleFollowEvent(.userScrollBegin)
        let firstEvent = showsThreadOverview ? nil
            : (transcriptEvents.isEmpty ? nil : transcriptEvents[window.start(in: transcriptEvents, overview: showsThreadOverview)])
        let firstShown = firstEvent.map { BotRoomTranscriptRow(event: $0, isOverview: threadID == nil).id }
        Task {
            if !window.showEarlier(in: transcriptEvents, overview: showsThreadOverview) {
                await reader.loadEarlier()
                guard window.showEarlier(in: transcriptEvents, overview: showsThreadOverview) else { return }
            }
            guard let firstShown else { return }
            await Task.yield()
            proxy.scrollTo(firstShown, anchor: .top)
        }
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
            hasActions: !reader.status.actions.isEmpty, mayRetry: reader.mayResend(in: threadID), needsSignIn: reader.needsSignIn,
            errorText: errorTexts.first { !dismissedErrors.contains($0) })
    }
}

/// Stable thread identities in the overview, exact sequence identities in detail
/// and unthreaded history. A reply must not replace its overview row's identity.
struct BotRoomTranscriptRow: Identifiable {
    enum ID: Hashable { case thread(String), event(Int) }
    let event: BotRoomEvent
    let isOverview: Bool
    var id: ID {
        if isOverview, let thread = event.threadID { return .thread(thread) }
        return .event(event.seq)
    }
}

private struct BotRoomThreadPreview: View {
    let thread: BotRoomThread
    let room: BotGroupRoom
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack { author; Spacer(); activity }
                VStack(alignment: .leading) { author; activity }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let root = thread.root {
                Text(root.payload["text"].text ?? "").lineLimit(2)
            } else {
                Text("Earlier messages not loaded").foregroundStyle(.secondary)
            }
            HStack {
                if thread.root == nil {
                    Text("Loaded replies: \(thread.replyCount)")
                } else {
                    Text("Replies: \(thread.replyCount)")
                }
                Spacer()
                Image(systemName: "chevron.forward").accessibilityHidden(true)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    @ViewBuilder private var author: some View {
        if let root = thread.root { Text(root.kind == "message.user" ? String(localized: "You") : root.sender(in: room)) }
        else { Text("Thread") }
    }
    @ViewBuilder private var activity: some View {
        if let time = thread.latest.timestamp, time.isFinite, time > 0 {
            Text(Date(timeIntervalSince1970: time), style: .relative)
        }
    }
}

/// The room events BotRoomView builds: the newest page when the room opens,
/// anchored by sequence number because room history is prepended. History the
/// reader loads stays hidden until asked for, and new events always show, so
/// neither shifts what is on screen. Load earlier reveals hidden events in
/// pages before the room fetches more.
struct BotRoomTranscriptWindow: Equatable {
    static let pageSize = 50
    private var oldestShown: Int?
    // Overview rows reorder when threads receive replies, so their expansion
    // cannot be anchored to a latest-event sequence that can disappear.
    private var overviewCount = Self.pageSize

    /// Index of the first shown event in `events`, which are sorted by sequence.
    /// An anchor outside the events (a reconnect restored a trimmed transcript,
    /// or the room restarted) falls back to the newest page. `keeping` widens the
    /// window to a search hit that is present, so its row is built by the time
    /// the jump runs (#553).
    func start(in events: [BotRoomEvent], keeping sequence: Int? = nil, overview: Bool = false) -> Int {
        let newestPage = max(0, events.count - Self.pageSize)
        let start = overview ? max(0, events.count - overviewCount) : oldestShown.flatMap { oldest in
            Self.contains(oldest, in: events) ? events.firstIndex { $0.seq >= oldest } : nil
        } ?? newestPage
        guard let sequence, let hit = events.firstIndex(where: { $0.seq == sequence }) else { return start }
        return min(start, hit)
    }

    /// Anchors the window on the newest page once the room is live, and again
    /// after the room empties (closed) or its events no longer cover the anchor.
    /// Until then `start` follows the newest page, so the open-time catch-up
    /// after a stale cache restore is not built in full.
    mutating func seed(_ events: [BotRoomEvent], live: Bool, overview: Bool = false) {
        guard !events.isEmpty else { oldestShown = nil; overviewCount = Self.pageSize; return }
        guard !overview else { return }
        guard live else { return }
        if !(oldestShown.map { Self.contains($0, in: events) } ?? false) {
            oldestShown = events[max(0, events.count - Self.pageSize)].seq
        }
    }

    private static func contains(_ sequence: Int, in events: [BotRoomEvent]) -> Bool {
        guard let first = events.first, let last = events.last else { return false }
        return (first.seq...last.seq).contains(sequence)
    }

    /// Keeps a search hit shown after its jump lands.
    mutating func reveal(_ sequence: Int, in events: [BotRoomEvent], overview: Bool = false) {
        guard !events.isEmpty else { return }
        if overview {
            overviewCount = events.count - start(in: events, keeping: sequence, overview: true)
        } else {
            oldestShown = min(events[start(in: events)].seq, sequence)
        }
    }

    /// Shows up to one more page of hidden events; false when none are hidden.
    mutating func showEarlier(in events: [BotRoomEvent], overview: Bool = false) -> Bool {
        let start = start(in: events, overview: overview)
        guard start > 0 else { return false }
        if overview {
            overviewCount = events.count - max(0, start - Self.pageSize)
        } else {
            oldestShown = events[max(0, start - Self.pageSize)].seq
        }
        return true
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
            VStack(alignment: .trailing, spacing: 4) {
                MessageBubbleView(
                    message: ChatMessage(role: "user", content: event.payload["text"].text,
                        timestamp: event.timestamp, messageId: String(event.seq)),
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    contextMenuActions: actions,
                    textOnly: true
                )
                footer
            }
        } else if event.kind == "message.member" {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 8) {
                    BotRoomMemberAvatar(member: event.member(in: room), roster: roster, avatars: avatars, size: 26)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.sender(in: room)).font(.caption).foregroundStyle(.secondary)
                        ResponseTextSelection(identity: messageText, collectsGlyphs: responseIsVisible) {
                            MarkdownRenderer(content: messageText)
                                // The bubble's fill is translucent, so no solid fade matches it.
                                .environment(\.markdownTableEdgeFadeColor, nil)
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
                // Every member message is a finished reply, so each one is timed.
                // Under the bubble, past the avatar, which stays level with the bubble.
                footer.padding(.leading, 34)
            }
        } else {
            Text(event.systemText).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private var messageText: String { event.payload["text"].text ?? "" }

    /// Rooms take the shared reply footer with the time only.
    @ViewBuilder
    private var footer: some View {
        if let timestamp = event.timestamp, timestamp.isFinite, timestamp > 0 {
            BotReplyFooter(isUserMessage: event.kind == "message.user", timestamp: timestamp)
        }
    }

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

/// What a new room opens on: every member's face and name, then, when this
/// phone can write to the room, the invitation to speak. One VoiceOver element.
/// Faces stay still, like the room's other faces (#517).
struct BotRoomWelcomeView: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    let showsPrompt: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 20) {
            if dynamicTypeSize.isAccessibilitySize {
                // Stacked, so full names fit at accessibility text sizes.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(room.members) { member in
                        HStack(spacing: 14) {
                            BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: 44)
                            Text(member.name)
                        }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(Self.rows(of: room.members), id: \.startIndex) { row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { member in
                                VStack(spacing: 6) {
                                    BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: 44)
                                    Text(member.name).font(.caption).lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: 100)
                            }
                        }
                    }
                }
            }
            if showsPrompt {
                Text("Say something to the group")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let names = room.members.map(\.name).formatted(.list(type: .and))
        return showsPrompt ? String(localized: "Group members: \(names). Say something to the group.")
            : String(localized: "Group members: \(names).")
    }

    /// Rows of up to three, balanced so four members make two rows of two.
    private static func rows(of members: [BotGroupRoom.Member]) -> [ArraySlice<BotGroupRoom.Member>] {
        guard !members.isEmpty else { return [] }
        let rowCount = (members.count + 2) / 3
        let perRow = (members.count + rowCount - 1) / rowCount
        return stride(from: 0, to: members.count, by: perRow).map { members[$0..<min($0 + perRow, members.count)] }
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
