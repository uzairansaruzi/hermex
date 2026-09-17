import SwiftUI

/// Search has its own presentation lifetime. Browsing the roster never opens a
/// conversation; only choosing a bot asks the inbox to navigate after dismissal.
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
    @State private var hitRequest: SearchRequest?
    @State private var searchError = false
    @State private var isSearching = false
    @State private var selectedHit: BotHistoryCache.Hit?
    let cache: BotHistoryCache

    init(inbox: BotInbox, cache: BotHistoryCache = .shared, query: String = "", onSelectRoom: @escaping (BotGroupRoom, Int?) -> Void = { _, _ in }, onSelect: @escaping (BotProfile) -> Void) {
        self.inbox = inbox; self.cache = cache; self.onSelect = onSelect; self.onSelectRoom = onSelectRoom
        _query = State(initialValue: query)
    }

    private struct SearchRequest: Equatable {
        let query: String
        let connectionID: UUID?
        let profiles: [String]
        let rooms: [String]
        let hasLiveRoster: Bool
        let includesMessages: Bool
        let active: Bool
    }
    private var request: SearchRequest {
        SearchRequest(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                      connectionID: inbox.connection?.id, profiles: inbox.profiles.map(\.id), rooms: inbox.rooms.map(\.id), hasLiveRoster: inbox.link == .live,
                      includesMessages: scope != .bots, active: scenePhase == .active)
    }
    private var visibleHits: [BotHistoryCache.Hit] { hitRequest == request ? hits : [] }

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
                    Text("Messages saved on this iPhone")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 16)
                    if !request.query.isEmpty {
                        ForEach(visibleHits) { hit in
                            if let roomID = hit.snapshot.roomID,
                               let room = inbox.rooms.first(where: { $0.id == roomID }) {
                                Button {
                                    searchFocused = false; onSelectRoom(room, hit.message.seq); dismiss()
                                } label: { roomMessageResult(hit, room: room) }
                                .buttonStyle(.plain)
                            } else if hit.snapshot.roomID == nil, let profile = profile(for: hit) {
                                Button {
                                    searchFocused = false
                                    selectedHit = hit
                                } label: { messageResult(hit, profile: profile) }
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
        .onChange(of: scenePhase) { if scenePhase != .active { selectedHit = nil } }
        .sheet(item: $selectedHit) { hit in
            if hit.snapshot.scope.connectionID == inbox.connection?.id,
               let profile = profile(for: hit) {
                BotCachedHistoryView(hit: hit, profile: profile)
            }
        }
    }

    @ViewBuilder private var searchBar: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) { searchControls }
        } else { searchControls }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            Button("Close search", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .modifier(BotSearchGlass(shape: .circle))
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
            .modifier(BotSearchGlass(shape: .capsule))
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
            .modifier(BotSearchGlass(shape: .circle))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).padding(.vertical, 16)
    }

    private func status(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
    }

    private func profile(for hit: BotHistoryCache.Hit) -> BotProfile? {
        if let current = inbox.profiles.first(where: { $0.id == hit.snapshot.profileID }) { return current }
        guard inbox.link != .live else { return nil }
        return BotProfile(.object(["name": .string(hit.snapshot.profileID),
                                   "display_name": .string(hit.snapshot.profileName ?? hit.snapshot.profileID)]))
    }

    private func messageResult(_ hit: BotHistoryCache.Hit, profile: BotProfile) -> some View {
        HStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: inbox.avatars[profile.id], size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.message.role == "user"
                         ? String(localized: "You to \(profile.name)") : String(localized: "\(profile.name) to you"))
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

    private func searchMessages() async {
        let captured = request
        hits = []; hitRequest = captured; searchError = false; isSearching = false
        guard captured.active, captured.includesMessages, !captured.query.isEmpty,
              let connectionID = captured.connectionID else { return }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(200))
            let found = try await cache.search(captured.query,
                scope: .init(server: inbox.server, connectionID: connectionID), profileIDs: captured.hasLiveRoster ? Set(captured.profiles) : nil, roomIDs: Set(captured.rooms))
            guard !Task.isCancelled, captured == request else { return }
            hits = found; hitRequest = captured; isSearching = false
        } catch {
            guard !Task.isCancelled, captured == request else { return }
            searchError = true; isSearching = false
        }
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

private struct BotSearchGlass: ViewModifier {
    enum Shape { case circle, capsule }
    let shape: Shape

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if shape == .circle { content.glassEffect(.regular.interactive(), in: Circle()) }
            else { content.glassEffect(.regular, in: Capsule()) }
        } else {
            if shape == .circle { content.background(.regularMaterial, in: Circle()) }
            else { content.background(.regularMaterial, in: Capsule()) }
        }
    }
}
