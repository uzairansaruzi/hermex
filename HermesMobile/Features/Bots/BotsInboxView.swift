import SwiftUI

@MainActor struct BotsInboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    let server: URL
    let showSessions: () -> Void
    @State private var inbox: BotInbox
    @State private var showingSearch = false
    @State private var searchedProfile: (connectionID: UUID, profileID: String)?
    @State private var showingSetup = false
    @State private var revision = UUID()
    @State private var editSelection: BotProfileEditSelection?
    @State private var creation: BotCreationIntent?
    @State private var roomCreator: BotRoomCreator?
    @State private var createdRoom: BotRoomKey?
    @State private var deleting: BotProfile?
    /// The bot whose chat is open. One destination serves the hero tiles and the
    /// rows, so a row shows no disclosure accessory and tiles sharing a row keep
    /// separate tap targets.
    @State private var openProfile: BotProfile?
    @State private var openRoom: BotRoomKey?
    @State private var searchedRoom: BotRoomKey?
    @State private var expiredRoomToast: String?

    init(server: URL, showSessions: @escaping () -> Void) {
        self.server = server
        self.showSessions = showSessions
        _inbox = State(initialValue: BotInbox(server: server))
    }

    var body: some View {
        let rows = inbox.rows(matching: "")
        List {
            Picker("Screen", selection: Binding(get: { true }, set: { if !$0 { showSessions() } })) {
                Text("Sessions").tag(false)
                Text("Bots").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if inbox.connection != nil {
                if let errorMessage = inbox.errorMessage {
                    Text(errorMessage).font(.callout)
                    Button("Reconnect") { revision = UUID() }
                } else if inbox.link == .connecting && inbox.profiles.isEmpty {
                    Text("Connecting…")
                } else if inbox.profiles.isEmpty && inbox.link == .live {
                    Text("No bots yet. Tap + to create one.")
                }
                if let notice = inbox.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
                if !rows.pinned.isEmpty {
                    // Pinned bots sit above the list as large tiles: as many columns as
                    // there are pinned bots, up to three, so one or two sit centered and
                    // four or more wrap instead of being clipped away.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(rows.pinned.count, 3)), spacing: 24) {
                        ForEach(rows.pinned) { profile in
                            Button { openProfile = profile } label: {
                                BotHeroTile(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { organizeMenu(profile) }
                        }
                    }
                    .padding(.vertical, 20)
                    .listRowSeparator(.hidden)
                }
                ForEach(rows.others) { profile in
                    row(profile, dimmed: false)
                }
                ForEach(rows.hidden) { profile in
                    row(profile, dimmed: true)
                }
                if inbox.hiddenCount > 0 {
                    Button(inbox.showsHidden ? "Hide hidden bots" : "Show hidden bots (\(inbox.hiddenCount))") {
                        inbox.showsHidden.toggle()
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
                if inbox.roomCapabilities.enabled {
                    Section("Groups") {
                        if inbox.roomCapabilities.methods.contains("groups.create") {
                            Button("New Group Chat", systemImage: "plus") {
                                guard let connection = inbox.connection else { return }
                                roomCreator = BotRoomCreator(server: server, connection: connection, roster: inbox.profiles,
                                    onReconciled: { inbox.reconcileRooms($0, connectionID: connection.id) })
                            }
                            .disabled(inbox.link != .live)
                        }
                        ForEach(inbox.rooms, id: \.id) { room in
                            if let key = inbox.roomKey(room) {
                                Button { openRoom = key } label: {
                                    BotRoomInboxRow(room: room, roster: inbox.profiles, avatars: inbox.avatars)
                                }
                                .id(key).buttonStyle(.plain).listRowSeparator(.hidden)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Connect to Hermes", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Use your existing Hermes setup to talk to your bots."))
                Button("Connect to Hermes") { showingSetup = true }
            }
        }
        .overlay(alignment: .bottom) {
            if let expiredRoomToast {
                Text(expiredRoomToast).font(.callout).padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding().accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task(id: expiredRoomToast) {
            guard expiredRoomToast != nil else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            expiredRoomToast = nil
        }
        .listStyle(.plain)
        .navigationTitle("Bots")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search bots and messages", systemImage: "magnifyingglass") { showingSearch = true }
                    .disabled(inbox.connection == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New bot", systemImage: "plus") { creation = .new }
                    .disabled(inbox.link != .live)
            }
            if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bot connection", systemImage: "gearshape") { showingSetup = true }
            }
        }
        .sheet(isPresented: Binding(get: { roomCreator != nil }, set: { if !$0 { roomCreator = nil } }), onDismiss: {
            if let key = createdRoom, key.connectionID == inbox.connection?.id { openRoom = key }
            createdRoom = nil
        }) {
            if let creator = roomCreator {
                BotRoomCreateView(creator: creator, avatars: inbox.avatars) { room in
                    guard inbox.connection?.id == creator.connection.id else { return }
                    inbox.updateRoom(room, connectionID: creator.connection.id)
                    createdRoom = inbox.roomKey(room)
                }
            }
        }
        .sheet(item: $creation) { intent in
            if let connection = inbox.connection {
                BotCreateView(creator: BotCreator(server: server, connection: connection, roster: inbox.profiles,
                                                  source: intent.source, onCreated: { _ in revision = UUID() }))
            }
        }
        .confirmationDialog(Text("Delete “\(deleting?.name ?? "")”?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { profile in
            Button("Delete Bot", role: .destructive) { Task { await inbox.delete(profile) } }
            Button("Hide Instead") { Task { await inbox.setHidden(true, profile) } }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Deletes this bot’s Profile on \(inbox.connection?.name ?? "Hermes"): its instructions, settings, skills, saved keys and chat history. Drafts on this phone are removed too. This cannot be undone. Hiding keeps everything and only removes it from the list.")
        }
        .sheet(isPresented: $showingSearch, onDismiss: openSearchSelection) {
            BotSearchView(inbox: inbox, onSelectRoom: { room in
                searchedRoom = inbox.roomKey(room)
            }) { profile in
                guard let connection = inbox.connection else { return }
                searchedProfile = (connection.id, profile.id)
            }
        }
        .onChange(of: inbox.connection?.id) {
            showingSearch = false
            searchedProfile = nil
            searchedRoom = nil
            openRoom = nil
            editSelection = nil
            creation = nil
            roomCreator?.suspend(); roomCreator = nil; createdRoom = nil
            deleting = nil
        }
        .sheet(isPresented: $showingSetup, onDismiss: { revision = UUID() }) {
            NavigationStack { BotConnectionView(server: server) }
        }
        .navigationDestination(item: $openProfile) { profile in
            if let connection = inbox.connection { chat(profile, connection) }
        }
        .navigationDestination(item: $openRoom) { key in
            if let connection = inbox.connection, connection.id == key.connectionID,
               let room = inbox.rooms.first(where: { $0.id == key.roomID }) {
                BotRoomView(reader: BotRoomReader(key: key, connection: connection, room: room, onExpired: {
                    inbox.expireRoom(key); openRoom = nil
                    expiredRoomToast = String(localized: "This room’s history is no longer available.")
                }, onChanged: { inbox.updateRoom($0, connectionID: key.connectionID) }, onDisbanded: {
                    inbox.removeRoom(key); openRoom = nil
                }), roster: inbox.profiles, avatars: inbox.avatars)
                .id(key)
            }
        }
        .navigationDestination(item: $editSelection) { selection in
            editProfile(selection)
        }
        // The subscription lives while the inbox is on screen and the app is active;
        // returning, refreshing and reconnecting all go through the same open().
        .task(id: revision) { await inbox.open() }
        .refreshable { await inbox.open() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { revision = UUID() }
            else { inbox.close() }
        }
        .onDisappear { inbox.close() }
    }

    /// Resolve the selection again after the sheet closes so a refreshed roster
    /// or changed connection cannot open an old bot under a new identity.
    private func openSearchSelection() {
        defer { searchedProfile = nil; searchedRoom = nil }
        if let key = searchedRoom, key.connectionID == inbox.connection?.id,
           inbox.rooms.contains(where: { $0.id == key.roomID }) { openRoom = key; return }
        guard let selection = searchedProfile, inbox.connection?.id == selection.connectionID else { return }
        openProfile = inbox.profiles.first { $0.id == selection.profileID }
    }

    private func row(_ profile: BotProfile, dimmed: Bool) -> some View {
        Button { openProfile = profile } label: {
            BotInboxRow(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.5 : 1)
        .contextMenu { organizeMenu(profile) }
        .listRowSeparator(.hidden)
        .padding(.vertical, 12)
    }

    private func chat(_ profile: BotProfile, _ connection: BotConnection) -> some View {
        BotChatView(server: server, connection: connection, profile: profile, roster: inbox.profiles, avatars: inbox.avatars)
            .id(profile.id + connection.id.uuidString)
            .onAppear { inbox.markSeen(profile) }
            .onDisappear { inbox.noteReturn(from: profile) }
    }

    @ViewBuilder private func editProfile(_ selection: BotProfileEditSelection) -> some View {
        if let connection = inbox.connection, connection.id == selection.connectionID,
           let profile = inbox.profiles.first(where: { $0.id == selection.profileID }) {
            BotProfileEditorView(server: server, connection: connection, profile: profile,
                                 avatar: inbox.avatars[profile.id]) { revision = UUID() }
                .id(connection.id.uuidString + profile.id)
        } else {
            ContentUnavailableView("Could Not Load Profiles", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    /// Pin and hide write Desktop's own roster fields; both stay inert until the
    /// inbox is live and no write for this bot is in flight.
    private func organizeMenu(_ profile: BotProfile) -> some View {
        Group {
            Button {
                guard let connection = inbox.connection else { return }
                editSelection = BotProfileEditSelection(connectionID: connection.id, profileID: profile.id)
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            Button {
                Task { await inbox.setPinned(!profile.pinned, profile) }
            } label: {
                Label(profile.pinned ? "Unpin" : "Pin", systemImage: profile.pinned ? "pin.slash" : "pin")
            }
            Button {
                Task { await inbox.setHidden(!profile.hidden, profile) }
            } label: {
                Label(profile.hidden ? "Unhide" : "Hide bot", systemImage: profile.hidden ? "eye" : "eye.slash")
            }
            Button { creation = .duplicate(profile) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if inbox.mayDelete(profile) {
                Button(role: .destructive) { deleting = profile } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .disabled(!inbox.mayEdit(profile))
    }
}

/// What the create sheet is for: a fresh bot or a copy of one on this connection.
private enum BotCreationIntent: Identifiable {
    case new, duplicate(BotProfile)
    var id: String { source?.id ?? "" }
    var source: BotProfile? { if case .duplicate(let profile) = self { return profile }; return nil }
}

private struct BotProfileEditSelection: Identifiable, Hashable {
    let connectionID: UUID
    let profileID: String
    var id: String { connectionID.uuidString + "|" + profileID }
}

/// A pinned bot: the avatar large and centered with the name beneath it.
private struct BotHeroTile: View {
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    var body: some View {
        VStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: avatar, size: 84)
            HStack(spacing: 6) {
                Text(profile.name).font(.body).foregroundStyle(.secondary).lineLimit(1)
                if unread { BotUnreadDot() }
            }
        }
        .frame(maxWidth: 132)
        .accessibilityElement(children: .combine)
    }
}

/// One roster row: avatar, name with an optional short Desktop description chip,
/// the last activity, then the canonical preview with a trailing unread mark.
/// The avatar is decorative; VoiceOver reads the text as one element.
private struct BotInboxRow: View {
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    /// A description short enough to read as a role sits beside the name; a
    /// longer one only stands in for the preview when the chat has none.
    private var chip: String? {
        guard let description = profile.description, description.count <= 24,
              profile.preview?.isEmpty == false else { return nil }
        return description
    }
    private var subline: String {
        if let preview = profile.preview, !preview.isEmpty { return preview }
        return profile.description ?? profile.id
    }
    var body: some View {
        HStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: avatar, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    if let chip {
                        Text(chip).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 8)
                    if let date = profile.lastActive {
                        Text(BotInboxDateLabel.text(for: date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(subline).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if unread { BotUnreadDot() }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Static unread mark. It never animates; VoiceOver reads it as "Unread".
private struct BotUnreadDot: View {
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
            .accessibilityLabel("Unread")
    }
}

/// Last-activity label in the roster's style: the time today, the weekday within
/// the past week, otherwise the month and day.
enum BotInboxDateLabel {
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo, date < now {
            return date.formatted(style.weekday(.wide))
        }
        return date.formatted(style.month(.abbreviated).day())
    }
}
