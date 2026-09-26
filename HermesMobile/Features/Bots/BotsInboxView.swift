import SwiftUI

@MainActor struct BotsInboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    let server: URL
    /// The bot a deep link named, resolved here because this is where the live roster
    /// is. Cleared once this inbox has settled, whether or not it matched (#554).
    @Binding private var pendingDestination: BotDestination?
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
    @State private var renamingRoom: BotGroupRoom?
    @State private var roomName = ""
    @State private var disbanding: BotGroupRoom?
    /// The bot the "New Section" alert files, and the name being typed for it.
    @State private var filing: BotProfile?
    @State private var newSectionName = ""
    @State private var showingSectionOrder = false
    @State private var selection = BotInboxSelection()
    @State private var searchedRoom: BotRoomKey?
    @State private var searchedSequence: Int?
    @State private var roomSequence: Int?
    /// One-line report for something that is no longer there: a disbanded room, or a
    /// conversation a deep link named that the bot has since replaced.
    @State private var toast: String?
    /// True once `open()` has returned at least once, so "no Bot connection" is a
    /// settled answer to a held deep link rather than a not-loaded-yet one.
    @State private var hasSettled = false

    init(
        server: URL,
        pendingDestination: Binding<BotDestination?> = .constant(nil)
    ) {
        self.server = server
        _pendingDestination = pendingDestination
        _inbox = State(initialValue: BotInbox(server: server))
    }

    var body: some View {
        let toasted = list
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.callout).padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding().accessibilityAddTraits(.updatesFrequently)
                }
            }
            .task(id: toast) {
                guard toast != nil else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                toast = nil
            }
        attachPresentations(to: toasted)
    }

    /// The rows alone. The list, its sheets and its lifecycle each sit in their
    /// own expression: together they were too much for the CI type-checker.
    private var list: some View {
        List {
            if inbox.connection != nil {
                if let message = inbox.errorMessage ?? inbox.routeAdvice {
                    Text(message).font(.callout)
                    Button("Reconnect") { revision = UUID() }
                } else if inbox.isLoadingRoster {
                    // The first row speaks for the set, so VoiceOver hears one
                    // "Loading bots" instead of nothing.
                    ForEach(0..<4, id: \.self) { index in
                        BotInboxSkeletonRow().listRowSeparator(.hidden).padding(.vertical, 12)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Loading bots"))
                            .accessibilityHidden(index > 0)
                    }
                } else if inbox.profiles.isEmpty && inbox.link == .live {
                    Text("No bots yet. Tap + to create one.")
                }
                if let notice = inbox.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
                let pinned = inbox.pinned
                if !pinned.isEmpty {
                    // Pinned chats sit above the list as large tiles: as many columns as
                    // there are pinned chats, up to three, so one or two sit centered and
                    // four or more wrap instead of being clipped away.
                    // Top-aligned, so a tile with a status line under its name keeps its avatar
                    // level with its neighbours'.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: min(pinned.count, 3)), spacing: 24) {
                        ForEach(pinned) { chat in
                            // The grid is one list row, and a row merges every
                            // `.contextMenu` inside it into one, so holding any tile
                            // lifted the whole grid with the first bot's menu. A Menu
                            // with a primary action is its own control: tap opens
                            // the chat, a hold shows this chat's menu.
                            switch chat {
                            case .bot(let profile):
                                Menu { organizeMenu(profile) } label: {
                                    BotHeroTile(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile),
                                                status: inbox.liveStatuses[profile.id])
                                } primaryAction: { selection.profile = profile }
                                .buttonStyle(.plain)
                            case .room(let room):
                                Menu { roomOrganizeMenu(room) } label: {
                                    BotRoomHeroTile(room: room, roster: inbox.profiles, avatars: inbox.avatars)
                                } primaryAction: { openRoom(room) }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 20)
                    .listRowSeparator(.hidden)
                }
                chatSections(inbox.sections)
                if inbox.hiddenCount > 0 {
                    Button(inbox.showsHidden ? "Hide hidden" : "Show hidden (\(inbox.hiddenCount))") {
                        inbox.showsHidden.toggle()
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
            } else {
                // The welcome is an overlay, so it has no list separators or disabled rows.
            }
        }
        .listStyle(.plain)
        .overlay {
            if inbox.connection == nil {
                GeometryReader { geometry in
                    ScrollView {
                        BotConnectionWelcomeView(isCovered: showingSetup) { showingSetup = true }
                            .frame(minHeight: geometry.size.height)
                    }
                    .background(Color(uiColor: .systemBackground))
                }
            }
        }
        // Pushed from the session list's Bots row: the back button and the
        // toolbar are the whole header, so the pinned tiles sit at the top. The
        // title still names the screen for VoiceOver and for a pushed chat's
        // back button; only its visible text is removed.
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search bots and messages", systemImage: "magnifyingglass") { showingSearch = true }
                    .disabled(inbox.connection == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Bot", systemImage: "plus.bubble") { creation = .new }
                    Button("New Group Chat", systemImage: "person.2") {
                        guard let connection = inbox.connection else { return }
                        roomCreator = BotRoomCreator(server: server, connection: connection, roster: inbox.profiles,
                            onReconciled: { inbox.reconcileRooms($0, connectionID: connection.id) })
                    }
                    .disabled(!inbox.roomCapabilities.enabled || !inbox.roomCapabilities.methods.contains("groups.create"))
                    if inbox.reorderableSectionNames.count >= 2 {
                        Divider()
                        Button("Reorder Sections…", systemImage: "arrow.up.arrow.down") { showingSectionOrder = true }
                    }
                } label: { Label("New chat", systemImage: "plus") }
                .disabled(inbox.link != .live)
            }
            if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bot connection", systemImage: "gearshape") { showingSetup = true }
            }
        }
    }


    /// Opens the bot a deep link named, once this inbox has a roster to resolve it
    /// against. A connecting or retrying socket keeps the link pending, so a dropped
    /// socket or a manual Reconnect still routes it. A replaced connection or a
    /// Profile the server no longer has leaves the user on the inbox rather than
    /// guessing (#554).
    private func openPendingDestination() {
        guard let destination = pendingDestination, destination.server == server else { return }
        // A pushed chat closes the inbox socket. Return to the inbox before waiting
        // for its roster, so its appearance task can reconnect and resolve the link.
        selection = BotInboxSelection()
        guard BotDeepLinkRouter.inboxCanAnswer(
            link: inbox.link, hasConnection: inbox.connection != nil, hasSettled: hasSettled
        ) else { return }
        pendingDestination = nil
        selection.open(destination, connection: inbox.connection, profiles: inbox.profiles)
    }

    /// Resolve the selection again after the sheet closes so a refreshed roster
    /// or changed connection cannot open an old bot under a new identity.
    private func openSearchSelection() {
        defer { searchedProfile = nil; searchedRoom = nil; searchedSequence = nil }
        if let key = searchedRoom, key.connectionID == inbox.connection?.id,
           inbox.rooms.contains(where: { $0.id == key.roomID }) { roomSequence = searchedSequence; selection.room = key; return }
        guard let searched = searchedProfile, inbox.connection?.id == searched.connectionID else { return }
        selection.profile = inbox.profiles.first { $0.id == searched.profileID }
    }

    /// The list under the tiles. Headers appear only when a named section is on
    /// screen; without one the unfiled block reads as the flat list it always was.
    @ViewBuilder private func chatSections(_ sections: [BotInbox.ChatSection]) -> some View {
        let headed = sections.contains { $0.name != nil }
        ForEach(sections) { section in
            if headed {
                Section {
                    chatRows(section.chats)
                } header: {
                    // A Desktop name is the user's own text, never a catalog key.
                    Group {
                        if let name = section.name { Text(verbatim: name) } else { Text("Other chats") }
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).textCase(nil)
                    .accessibilityAddTraits(.isHeader)
                }
            } else {
                chatRows(section.chats)
            }
        }
    }

    private func chatRows(_ chats: [BotInbox.ChatRow]) -> some View {
        ForEach(chats) { chat in
            switch chat {
            case .bot(let profile):
                row(profile, dimmed: profile.hidden)
            case .room(let room):
                if let key = inbox.roomKey(room) { roomRow(room, key: key) }
            }
        }
    }

    private func row(_ profile: BotProfile, dimmed: Bool) -> some View {
        Button { selection.profile = profile } label: {
            BotInboxRow(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile),
                        status: inbox.liveStatuses[profile.id])
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.5 : 1)
        .contextMenu { organizeMenu(profile) }
        // The same writes the long-press menu offers, one swipe away. No full
        // swipe: Delete confirms and Pin is a server write, so nothing should fire
        // from a flick.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task { await inbox.setPinned(!profile.pinned, profile) }
            } label: {
                Label(profile.pinned ? "Unpin" : "Pin", systemImage: profile.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
            .disabled(!inbox.mayEdit(profile))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Hide sits at the edge and Delete behind it, so the first thing a
            // short swipe reaches is the reversible one.
            Button {
                Task { await inbox.setHidden(!profile.hidden, profile) }
            } label: {
                Label(profile.hidden ? "Unhide" : "Hide", systemImage: profile.hidden ? "eye" : "eye.slash")
            }
            .tint(.gray)
            .disabled(!inbox.mayEdit(profile))
            if inbox.mayDelete(profile) {
                Button(role: .destructive) { deleting = profile } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .listRowSeparator(.hidden)
        .padding(.vertical, 12)
    }

    private func chat(_ profile: BotProfile, _ connection: BotConnection) -> some View {
        BotChatView(server: server, connection: connection, profile: profile, roster: inbox.profiles,
                    avatars: inbox.avatars, conversation: selection.conversation, onConversationUnavailable: {
                        selection.profile = nil
                        toast = String(localized: "That conversation is no longer available.")
                    })
            // A composite rather than a concatenation: a Profile name and a
            // conversation root are both arbitrary server strings, so joining them
            // could let two destinations share one identity and keep the wrong
            // conversation on screen.
            .id([profile.id, connection.id.uuidString, selection.conversation ?? ""])
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

    /// Kept as its own function with the flags read once: inlined in the list
    /// builder, the row's menus and swipes were too much for the type-checker.
    private func roomRow(_ room: BotGroupRoom, key: BotRoomKey) -> some View {
        let pinned = inbox.isRoomPinned(room)
        let hidden = inbox.isRoomHidden(room)
        return Button { openRoom(room) } label: {
            BotRoomInboxRow(room: room, roster: inbox.profiles, avatars: inbox.avatars)
        }
        .id(key).buttonStyle(.plain).listRowSeparator(.hidden)
        .opacity(hidden ? 0.5 : 1)
        .contextMenu { roomOrganizeMenu(room) }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { inbox.setRoomPinned(!pinned, room) } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { inbox.setRoomHidden(!hidden, room) } label: {
                Label(hidden ? "Unhide" : "Hide", systemImage: hidden ? "eye" : "eye.slash")
            }
            .tint(.gray)
            if inbox.mayDisbandRoom(room) {
                Button(role: .destructive) { disbanding = room } label: {
                    Label("Disband", systemImage: "trash")
                }
            }
        }
    }

    private func openRoom(_ room: BotGroupRoom) {
        guard let key = inbox.roomKey(room) else { return }
        roomSequence = nil; selection.room = key
    }

    /// Pin and hide are this phone's own marks and always apply; Rename and
    /// Disband go to the host and stay inert until the inbox is live and the
    /// host offers them for this room.
    @ViewBuilder private func roomOrganizeMenu(_ room: BotGroupRoom) -> some View {
        Button {
            roomName = room.name; renamingRoom = room
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(!inbox.mayRenameRoom(room))
        Button {
            inbox.setRoomPinned(!inbox.isRoomPinned(room), room)
        } label: {
            Label(inbox.isRoomPinned(room) ? "Unpin" : "Pin", systemImage: inbox.isRoomPinned(room) ? "pin.slash" : "pin")
        }
        Button {
            inbox.setRoomHidden(!inbox.isRoomHidden(room), room)
        } label: {
            Label(inbox.isRoomHidden(room) ? "Unhide" : "Hide group", systemImage: inbox.isRoomHidden(room) ? "eye" : "eye.slash")
        }
        Button(role: .destructive) { disbanding = room } label: {
            Label("Disband", systemImage: "trash")
        }
        .disabled(!inbox.mayDisbandRoom(room))
    }

    /// Pin, hide and the section write Desktop's own roster fields; all stay inert
    /// until the inbox is live and no write for this bot is in flight.
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
            sectionMenu(profile)
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

    /// Desktop's "Move to section": every named section on the roster (the bot's own
    /// one inert), a new one through an alert, and Remove only while the bot is filed.
    private func sectionMenu(_ profile: BotProfile) -> some View {
        Menu {
            ForEach(inbox.sectionNames) { section in
                // A Desktop name is the user's own text, never a catalog key.
                Button { Task { await inbox.moveToSection(profile, section) } } label: { Text(verbatim: section.name) }
                    .disabled(section.id == profile.sectionID && profile.sectionName != nil)
            }
            Divider()
            Button("New Section…", systemImage: "folder.badge.plus") { newSectionName = ""; filing = profile }
            if profile.sectionID != nil {
                Button("Remove from Section", systemImage: "folder.badge.minus") {
                    Task { await inbox.removeFromSection(profile) }
                }
            }
        } label: {
            Label("Move to Section", systemImage: "folder")
        }
    }
}


extension BotsInboxView {
    /// The sheets, dialogs, navigation destinations and open/close lifecycle
    /// the list carries. Split from `body` so the CI type-checker finishes.
    private func attachPresentations(to content: some View) -> some View {
        content
            .sheet(isPresented: Binding(get: { roomCreator != nil }, set: { if !$0 { roomCreator = nil } }), onDismiss: {
                if let key = createdRoom, key.connectionID == inbox.connection?.id { roomSequence = nil; selection.room = key }
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
            .alert("Rename group", isPresented: Binding(
                get: { renamingRoom != nil }, set: { if !$0 { renamingRoom = nil } }
            ), presenting: renamingRoom) { room in
                TextField("Group name", text: $roomName)
                Button("Save") {
                    let name = roomName
                    Task { await inbox.renameRoom(room, to: name) }
                }
            .disabled(!BotRoomRPC.validName(roomName) || roomName == room.name)
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Enter a name of up to 200 characters.")
            }
            .alert("New Section", isPresented: Binding(
                get: { filing != nil }, set: { if !$0 { filing = nil } }
            ), presenting: filing) { profile in
                TextField("Section name", text: $newSectionName)
                Button("Move") {
                    let name = newSectionName
                    Task { await inbox.moveToNewSection(profile, name: name) }
                }
                .disabled(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { profile in
                Text("Move “\(profile.name)” into a new section.")
            }
            .confirmationDialog("Disband this group?", isPresented: Binding(
                get: { disbanding != nil }, set: { if !$0 { disbanding = nil } }
            ), titleVisibility: .visible, presenting: disbanding) { room in
                Button("Disband Group", role: .destructive) { Task { await inbox.disbandRoom(room) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The room and its history will be removed from every device. All bots in it will stop. The room cannot be restored.")
            }
            .sheet(isPresented: $showingSearch, onDismiss: openSearchSelection) {
                BotSearchView(inbox: inbox, onSelectRoom: { room, sequence in
                    searchedRoom = inbox.roomKey(room); searchedSequence = sequence
                }) { profile in
                    guard let connection = inbox.connection else { return }
                    searchedProfile = (connection.id, profile.id)
                }
            }
            .onChange(of: inbox.connection?.id) {
                showingSearch = false
                searchedProfile = nil
                searchedRoom = nil; searchedSequence = nil; roomSequence = nil
                selection.room = nil; selection.conversation = nil
                editSelection = nil
                creation = nil
                roomCreator?.suspend(); roomCreator = nil; createdRoom = nil
                deleting = nil
                renamingRoom = nil; disbanding = nil; filing = nil
                showingSectionOrder = false
            }
            .sheet(isPresented: $showingSectionOrder) {
                BotSectionOrderView(inbox: inbox)
            }
            .sheet(isPresented: $showingSetup, onDismiss: { revision = UUID() }) {
                NavigationStack { BotConnectionView(server: server) }
            }
            .navigationDestination(item: $selection.profile) { profile in
                if let connection = inbox.connection { chat(profile, connection) }
            }
            .navigationDestination(item: $selection.room) { key in
                if let connection = inbox.connection, connection.id == key.connectionID,
                   let room = inbox.rooms.first(where: { $0.id == key.roomID }) {
                    BotRoomView(reader: BotRoomReader(key: key, connection: connection, room: room, initialSequence: roomSequence, onExpired: {
                        inbox.expireRoom(key); selection.room = nil
                        toast = String(localized: "This room’s history is no longer available.")
                    }, onChanged: { inbox.updateRoom($0, connectionID: key.connectionID) }, onDisbanded: {
                        inbox.removeRoom(key); selection.room = nil
                    }), roster: inbox.profiles, avatars: inbox.avatars)
                    .id(key)
                }
            }
            .navigationDestination(item: $editSelection) { selection in
                editProfile(selection)
            }
            // The subscription lives while the inbox is on screen and the app is active;
            // returning, refreshing and reconnecting all go through the same open().
            .task(id: revision) { await inbox.open(); hasSettled = true; openPendingDestination() }
            .onChange(of: inbox.link) { openPendingDestination() }
            .onChange(of: pendingDestination) { openPendingDestination() }
            .onChange(of: selection.profile) { if selection.profile == nil { selection.conversation = nil } }
            .refreshable { await inbox.open() }
            .onChange(of: scenePhase) {
                if scenePhase == .active { revision = UUID() }
                else { inbox.close() }
            }
            .onDisappear { inbox.close() }
    }
}

/// Places Desktop's named sections for this phone's inbox. Every drag saves the
/// whole list at once; Reset to A–Z forgets the placement. The unfiled block is
/// not listed because it always stays last, nor is a section the list never heads.
private struct BotSectionOrderView: View {
    @Environment(\.dismiss) private var dismiss
    let inbox: BotInbox

    var body: some View {
        let sections = inbox.reorderableSectionNames
        NavigationStack {
            List {
                Section {
                    ForEach(sections) { section in
                        Text(verbatim: section.name).lineLimit(1)
                    }
                    .onMove { from, to in
                        var ids = sections.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        inbox.placeReorderableSections(ids)
                    }
                }
                Section {
                    Button("Reset to A–Z") { inbox.resetSectionOrder() }
                        .disabled(inbox.sectionOrder.isEmpty)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
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

/// A pinned bot: the avatar large and centered with the name beneath it, and the
/// live status word under the name while it has one.
private struct BotHeroTile: View {
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    let status: BotLiveStatus?
    var body: some View {
        VStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: avatar, size: 84)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    if unread { BotUnreadDot() }
                }
                if let status {
                    // Two lines, so a long translation at a large size still reads whole.
                    BotLiveStatusLabel(status: status, font: .footnote.weight(.semibold))
                        .lineLimit(2).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: 132)
        .accessibilityElement(children: .combine)
    }
}

/// A pinned room: the member avatars stacked large, the name beneath.
private struct BotRoomHeroTile: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    var body: some View {
        VStack(spacing: 14) {
            BotRoomAvatars(room: room, roster: roster, avatars: avatars, size: 60).frame(height: 84)
            Text(room.name).font(.body).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: 132)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(room.name))
    }
}

/// One roster row: avatar, name with an optional short Desktop description chip,
/// the live status or else the last activity, then the canonical preview with a
/// trailing unread mark. The avatar is decorative; VoiceOver reads the text as one
/// element, status included.
private struct BotInboxRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    let status: BotLiveStatus?
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
                // At accessibility sizes the slot moves under the name, as in Sessions.
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { nameAndChip }
                    trailingSlot
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        nameAndChip
                        Spacer(minLength: 8)
                        trailingSlot
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

    @ViewBuilder private var nameAndChip: some View {
        Text(profile.name).font(.headline).lineLimit(1)
        if let chip {
            Text(chip).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                .layoutPriority(-1)
        }
    }

    /// One line, one meaning, as in Sessions: the live status while the bot has one,
    /// otherwise the last activity.
    @ViewBuilder private var trailingSlot: some View {
        if let status {
            BotLiveStatusLabel(status: status, font: .subheadline.weight(.semibold))
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        } else if let date = profile.lastActive {
            Text(BotInboxDateLabel.text(for: date)).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// A bot's live status as a still, tinted word: the Live Activity's translated
/// "Working" and "Waiting for you" in the Sessions list's attention tints. It never
/// animates; the word carries the meaning without the color.
private struct BotLiveStatusLabel: View {
    let status: BotLiveStatus
    let font: Font
    var body: some View {
        switch status {
        case .working: Text("Working").font(font).foregroundStyle(Color("AttentionWorking"))
        case .waiting: Text("Waiting for you").font(font).foregroundStyle(Color("AttentionApproval"))
        }
    }
}

/// Stand-in for a bot row while the first roster loads: the same avatar and text
/// footprint, redacted. Static, so it costs nothing on screen.
private struct BotInboxSkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.fill.tertiary).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "Chief of Staff").font(.headline)
                    Spacer(minLength: 8)
                    Text(verbatim: "Saturday").font(.subheadline)
                }
                Text(verbatim: "Reading the latest conversation").font(.body)
            }
            .redacted(reason: .placeholder)
        }
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
