import SwiftUI

/// Search has its own presentation lifetime. Browsing the roster never opens a
/// conversation; only choosing a bot asks the inbox to navigate after dismissal. Messages in a
/// bot's chat are searched on the host (#1146); room messages come from this iPhone's cache.
@MainActor struct BotSearchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let inbox: BotInbox
    let onSelect: (BotProfile) -> Void
    let onSelectRoom: (BotGroupRoom, Int?) -> Void
    @State private var query = ""
    @State private var scope: Scope = .all
    @FocusState private var searchFocused: Bool
    @State private var hits: [BotHistoryCache.Hit] = []
    @State private var botHits: [BotInbox.BotChatHit] = []
    @State private var hitRequest: SearchRequest?
    @State private var searchError = false
    /// Why the host's search of the bots' chats failed.
    @State private var botSearchError: String?
    /// The saved-message search and the host's bot-chat search finish separately.
    @State private var isSearching = false
    @State private var isSearchingBots = false
    let cache: BotHistoryCache

    init(inbox: BotInbox, cache: BotHistoryCache = .shared, query: String = "", onSelectRoom: @escaping (BotGroupRoom, Int?) -> Void = { _, _ in }, onSelect: @escaping (BotProfile) -> Void) {
        self.inbox = inbox; self.cache = cache; self.onSelect = onSelect; self.onSelectRoom = onSelectRoom
        _query = State(initialValue: query)
    }

    private struct SearchRequest: Equatable {
        let query: String
        let connectionID: UUID?
        let profiles: [String]
        let roomIDs: Set<String>?
        let hasLiveRoster: Bool
        let includesMessages: Bool
        let active: Bool
    }
    private var request: SearchRequest {
        SearchRequest(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                      connectionID: inbox.connection?.id, profiles: inbox.profiles.map(\.id), roomIDs: inbox.searchableRoomIDs, hasLiveRoster: inbox.link == .live,
                      includesMessages: scope != .bots, active: scenePhase == .active)
    }
    private var visibleHits: [BotHistoryCache.Hit] { hitRequest == request ? hits : [] }
    private var visibleBotHits: [BotInbox.BotChatHit] { hitRequest == request ? botHits : [] }

    private enum Scope: String, CaseIterable {
        case all, bots, messages
        var title: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .bots: return "Bots"
            case .messages: return "Messages"
            }
        }
    }

    private var matches: [BotProfile] {
        let rows = inbox.rows(matching: query.trimmingCharacters(in: .whitespacesAndNewlines))
        return rows.pinned + rows.others + rows.hidden
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if scope != .messages {
                    ForEach(matches) { profile in
                        Button {
                            searchFocused = false
                            onSelect(profile)
                            dismiss()
                        } label: {
                            result(profile)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(inbox.rooms(matching: request.query), id: \.id) { room in
                        Button {
                            searchFocused = false; onSelectRoom(room, nil); dismiss()
                        } label: {
                            BotRoomInboxRow(room: room, roster: inbox.profiles, avatars: inbox.avatars)
                                .padding(.horizontal, 20)
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty && inbox.rooms(matching: request.query).isEmpty && scope == .bots {
                        ContentUnavailableView("No bots found", systemImage: "magnifyingglass")
                    }
                }
                if scope != .bots {
                    if !request.query.isEmpty {
                        ForEach(visibleBotHits) { hit in
                            if let profile = inbox.profiles.first(where: { $0.id == hit.profileID }) {
                                Button {
                                    searchFocused = false
                                    onSelect(profile)
                                    dismiss()
                                } label: {
                                    // An id match names no message, so it shows as the bot.
                                    if let isFromUser = hit.isFromUser {
                                        botChatResult(hit, isFromUser: isFromUser, profile: profile)
                                    } else {
                                        result(profile)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // One "Searching…" at a time: the saved messages' first, then the host's.
                        if isSearchingBots && !isSearching { status("Searching…") }
                        else if let botSearchError, hitRequest == request {
                            Text(verbatim: botSearchError).font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        }
                    }
                    Text("Messages saved on this iPhone")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 16)
                    if !request.query.isEmpty {
                        ForEach(visibleHits) { hit in
                            if let room = inbox.roomForSearch(hit) {
                                Button {
                                    guard let selected = inbox.selectRoomSearchHit(hit) else { return }
                                    searchFocused = false; onSelectRoom(selected, hit.message.seq); dismiss()
                                } label: { roomMessageResult(hit, room: room) }
                                .buttonStyle(.plain)
                            }
                        }
                        if isSearching { status("Searching…") }
                        else if searchError { status("Could not search saved messages.") }
                        else if visibleHits.isEmpty { status("No saved messages found.") }
                        else if visibleHits.count == BotHistoryCache.maximumHits {
                            status("Showing the first 100 matches. Refine your search to find more.")
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(36)
        .task { searchFocused = true }
        .task(id: request) { await searchMessages() }
    }

    private var searchBar: some View {
        AdaptiveGlassContainer(spacing: 8) { searchControls }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            Button("Close search", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .adaptiveGlass(isInteractive: true, in: Circle())
                .keyboardShortcut(.cancelAction)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { searchFocused = false }
                    .accessibilityLabel("Search bots and messages")
                if !query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") {
                        query = ""
                        searchFocused = true
                    }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .adaptiveGlass(in: Capsule())
            Menu {
                Picker("Search filter", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Search filter")
            .accessibilityValue(Text(scope.title))
            .adaptiveGlass(isInteractive: true, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).padding(.vertical, 16)
    }

    private func status(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
    }

    /// A bot's chat the host matched (#1146): who wrote the message, and the host's snippet.
    private func botChatResult(_ hit: BotInbox.BotChatHit, isFromUser: Bool, profile: BotProfile) -> some View {
        HStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: inbox.avatars[profile.id], size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isFromUser
                         ? String(localized: "You to \(profile.name)") : String(localized: "\(profile.name) to you"))
                        .font(.body).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 8)
                    Text("Message").font(.subheadline).foregroundStyle(.tertiary)
                }
                if let snippet = hit.snippet {
                    Text(SessionSearchExcerpt(hermesSnippet: snippet, query: request.query).highlighted)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func roomMessageResult(_ hit: BotHistoryCache.Hit, room: BotGroupRoom) -> some View {
        HStack(spacing: 14) {
            BotRoomAvatars(room: room, roster: inbox.profiles, avatars: inbox.avatars, size: 32).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: [room.name, hit.message.sender].compactMap { $0 }.joined(separator: " · "))
                        .font(.body).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 8)
                    Text("Message").font(.subheadline).foregroundStyle(.tertiary)
                }
                Text(SessionSearchExcerpt(text: hit.excerpt, query: request.query).highlighted)
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }

    /// Searches room messages saved on this iPhone, showing them as soon as the cache answers, then
    /// each bot's chat on the host (#1146), whose hits and error arrive on their own. The cache's
    /// bot rows are left out: a bot's chat is the host's to search.
    private func searchMessages() async {
        let captured = request
        hits = []; botHits = []; hitRequest = captured; searchError = false; botSearchError = nil
        isSearching = false; isSearchingBots = false
        guard captured.active, captured.includesMessages, !captured.query.isEmpty,
              let connectionID = captured.connectionID else { return }
        isSearching = true; isSearchingBots = true
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        var found: [BotHistoryCache.Hit] = [], localFailed = false
        do {
            found = try await cache.search(captured.query, scope: .init(server: inbox.server, connectionID: connectionID),
                                           roomIDs: captured.roomIDs)
        } catch { localFailed = true }
        guard !Task.isCancelled, captured == request else { return }
        hits = found; searchError = localFailed; isSearching = false
        var bots: [BotInbox.BotChatHit] = [], botFailure: String?
        do { bots = try await inbox.searchBotChats(captured.query) } catch {
            botFailure = (error as? BotFailure ?? .transport).localizedDescription
        }
        guard !Task.isCancelled, captured == request else { return }
        botHits = bots; botSearchError = botFailure; isSearchingBots = false
    }

    private func result(_ profile: BotProfile) -> some View {
        HStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: inbox.avatars[profile.id], size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name).font(.body)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 8)
                    Text("Bot").font(.subheadline).foregroundStyle(.tertiary)
                }
                if let description = profile.description {
                    Text(description).font(.body).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
