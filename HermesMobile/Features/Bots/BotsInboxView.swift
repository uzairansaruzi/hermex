import SwiftData
import SwiftUI

@MainActor struct BotsInboxView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    let server: URL
    private let home: HermesHome?
    @Binding private var pendingDestination: BotDestination?
    @State private var inbox: BotInbox
    @State private var showingSearch = false
    @State private var searchedProfile: (connectionID: UUID, profileID: String)?
    @State private var showingSetup = false
    @State private var updatingSignIn = false
    @State private var revision = UUID()
    @State private var editSelection: BotProfileEditSelection?
    @State private var creation: BotCreationIntent?
    @State private var roomCreator: BotRoomCreator?
    @State private var createdRoom: BotRoomKey?
    @State private var deleting: BotProfile?
    @State private var renamingRoom: BotGroupRoom?
    @State private var roomName = ""
    @State private var disbanding: BotGroupRoom?
    @State private var filing: BotProfile?
    @State private var newSectionName = ""
    @State private var showingSectionOrder = false
    @State private var searchedRoom: BotRoomKey?
    @State private var searchedSequence: Int?
    @State private var roomSequence: Int?
    @State private var toast: String?
    @State private var hasSettled = false
    @State private var screenTarget: BotScreenTarget?
    @State private var hostLacksScreen = false
    @AppStorage private var isScreenEnabled: Bool
    @State private var heldScreens: [String] = []

    init(
        server: URL,
        pendingDestination: Binding<BotDestination?> = .constant(nil)
    ) {
        self.init(server: server, pendingDestination: pendingDestination, home: nil, inbox: BotInbox(server: server))
    }

    init(server: URL, pendingDestination: Binding<BotDestination?>, home: HermesHome?, inbox: BotInbox) {
        self.server = server
        self.home = home
        _pendingDestination = pendingDestination
        _inbox = State(initialValue: inbox)
        _isScreenEnabled = AppStorage(wrappedValue: false, BotScreenSettings.key(for: server))
    }

    init(server: URL, inbox: BotInbox) {
        self.server = server
        home = nil
        _pendingDestination = .constant(nil)
        _inbox = State(initialValue: inbox)
        _isScreenEnabled = AppStorage(wrappedValue: false, BotScreenSettings.key(for: server))
    }

    var body: some View {
        let toasted = navigationSurface
            .focusedSceneValue(\.hermexSceneActions, sceneActions)
            .fullScreenCover(item: $screenTarget) { target in
                ScreenView(profile: target.profile.id, title: target.profile.name, server: server, connection: target.connection,
                           takesOverWhenLive: target.takesOver) {
                    hostLacksScreen = true
                }
            }
            .onChange(of: isScreenEnabled) { if !isScreenEnabled { screenTarget = nil } }
            .onChange(of: ScreenHoldStore.shared.revision, initial: true) {
                heldScreens = ScreenHoldStore.shared.holds(server: server).keys.sorted()
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(AppFont.callout()).padding()
                        .background(.appMaterial(.regularMaterial), in: RoundedRectangle(cornerRadius: 16))
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

    private var usesSplit: Bool {
        HermesHomeLayout.usesSplit(isHome: home != nil, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
    }

    @ViewBuilder private var navigationSurface: some View {
        if usesSplit {
            SessionSplitView(rootRevision: inbox.selection.pick.hashValue, offersHideSidebar: true) {
                list
            } detail: {
                regularWidthDetail
                    .modifier(HermesHomeDetailBar(home: home, search: HermesHomeSearch(label: "Search bots and messages",
                                                                                         isDisabled: inbox.connection == nil,
                                                                                         open: { showingSearch = true }),
                                                  filter: { filterMenu }, newChat: { newChatMenu }))
            }
        } else {
            compactList
        }
    }

    @ViewBuilder private var regularWidthDetail: some View {
        if let profile = inbox.selection.profile, let connection = inbox.connection { chat(profile, connection) }
        else if let key = inbox.selection.room, let connection = inbox.connection, connection.id == key.connectionID,
                let room = inbox.rooms.first(where: { $0.id == key.roomID }) {
            BotRoomView(reader: BotRoomReader(key: key, connection: connection, room: room, initialSequence: roomSequence, onExpired: {
                inbox.expireRoom(key); inbox.selection.room = nil
                toast = String(localized: "This room’s history is no longer available.")
            }, onChanged: { inbox.updateRoom($0, connectionID: key.connectionID) }, onDisbanded: {
                inbox.removeRoom(key); inbox.selection.room = nil
            }), roster: inbox.profiles, avatars: inbox.avatars,
                onUpdateSignIn: { inbox.noteRejectedSignIn(connection); inbox.selection.room = nil; updateSignIn() })
                .id(key)
                .onAppear { UsageReports.shared.record(.bots) }
        } else { ContentUnavailableView("Select a Bot", systemImage: "bubble.left.and.bubble.right") }
    }

    private var compactList: some View {
        list
            .navigationDestination(item: $inbox.selection.profile) { profile in
                if let connection = inbox.connection { chat(profile, connection) }
            }
            .navigationDestination(item: $inbox.selection.room) { key in
                if let connection = inbox.connection, connection.id == key.connectionID,
                   let room = inbox.rooms.first(where: { $0.id == key.roomID }) {
                    BotRoomView(reader: BotRoomReader(key: key, connection: connection, room: room, initialSequence: roomSequence, onExpired: {
                        inbox.expireRoom(key); inbox.selection.room = nil
                        toast = String(localized: "This room’s history is no longer available.")
                    }, onChanged: { inbox.updateRoom($0, connectionID: key.connectionID) }, onDisbanded: {
                        inbox.removeRoom(key); inbox.selection.room = nil
                    }), roster: inbox.profiles, avatars: inbox.avatars,
                        onUpdateSignIn: { inbox.noteRejectedSignIn(connection); inbox.selection.room = nil; updateSignIn() })
                    .id(key)
                    .onAppear { UsageReports.shared.record(.bots) }
                }
            }
            .navigationDestination(item: $editSelection) { selection in
                editProfile(selection)
            }
    }

    private var list: some View {
        AppList(rows: .plain) {
            homeHeader
            if let connection = inbox.connection {
                ForEach(heldScreens, id: \.self) { profile in
                    heldScreenRow(profile, connection)
                }
            }
            if inbox.connection != nil {
                if let message = inbox.errorMessage ?? inbox.routeAdvice {
                    Text(message).font(AppFont.callout())
                    if inbox.needsSignIn {
                        Button("Update sign-in", action: updateSignIn)
                    } else if inbox.needsAddress {
                        if let home {
                            Button("Add Server", action: home.avatar.addServer)
                        } else {
                            Button("Hermes connection") { showingSetup = true }
                        }
                    } else {
                        Button("Reconnect") { revision = UUID() }
                    }
                } else if inbox.isLoadingRoster {
                    ForEach(0..<4, id: \.self) { index in
                        BotInboxSkeletonRow().listRowSeparator(.hidden).padding(.vertical, 12)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Loading bots"))
                            .accessibilityHidden(index > 0)
                    }
                } else if inbox.profiles.isEmpty && inbox.link == .live {
                    home == nil ? Text("No bots yet. Tap + to create one.") : Text("No bots yet. Tap New Chat to create one.")
                }
                if let notice = inbox.notice {
                    Text(notice).font(AppFont.callout()).foregroundStyle(.appSecondary).listRowSeparator(.hidden)
                }
                let pinned = inbox.pinned
                if !pinned.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: min(pinned.count, 3)), spacing: 24) {
                        ForEach(pinned) { chat in
                            switch chat {
                            case .bot(let profile):
                                Menu { organizeMenu(profile) } label: {
                                    BotHeroTile(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile),
                                                status: inbox.liveStatuses[profile.id], statusIsStale: inbox.liveStatusesAreStale)
                                } primaryAction: { inbox.selection.profile = profile }
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
                if home == nil && inbox.hiddenCount > 0 {
                    Button(inbox.showsHidden ? "Hide hidden" : "Show hidden (\(inbox.hiddenCount))") {
                        inbox.showsHidden.toggle()
                    }
                    .font(AppFont.subheadline()).foregroundStyle(.appSecondary)
                    .listRowSeparator(.hidden)
                }
            } else {
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.appCanvas))
        .overlay {
            if inbox.connection == nil {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            homeHeader
                            BotConnectionWelcomeView(isCovered: showingSetup) { showingSetup = true }
                        }
                        .frame(minHeight: geometry.size.height)
                    }
                    .background(Color(uiColor: .appCanvas))
                }
            }
        }
        .modifier(chrome)
    }

    @ViewBuilder private var homeHeader: some View {
        if let home {
            SessionsHeader(logoColor: HeaderLogoColor.color(for: headerLogoColorHex), avatar: home.avatar,
                           searchLabel: "Search bots and messages", isSearchDisabled: inbox.connection == nil,
                           connection: inbox.homeConnection, reconnectNow: inbox.reconnectNow,
                           openSearch: { showingSearch = true })
                .sessionsTopChromeListRow()
        }
    }

    private var chrome: some ViewModifier {
        BotsInboxChrome(home: home, isOffline: inbox.connection == nil, search: { showingSearch = true },
                        openSetup: { showingSetup = true }, filter: { filterMenu }, newChat: { newChatMenu })
    }

    private var newChatMenu: some View {
        Menu {
            Button("New Bot", systemImage: "plus.bubble") { creation = .new }
            Button("New Group Chat", systemImage: "person.2") {
                guard let connection = inbox.connection else { return }
                roomCreator = BotRoomCreator(server: server, connection: connection, roster: inbox.profiles,
                    seatable: inbox.roomCapabilities.seatableProfiles,
                    onReconciled: { inbox.reconcileRooms($0, connectionID: connection.id) })
            }
            .disabled(!inbox.roomCapabilities.enabled || !inbox.roomCapabilities.methods.contains("groups.create"))
            if home == nil && inbox.reorderableSectionNames.count >= 2 {
                Divider()
                Button("Reorder Sections…", systemImage: "arrow.up.arrow.down") { showingSectionOrder = true }
            }
        } label: { Label("New chat", systemImage: home == nil ? "plus" : "square.and.pencil") }
        .disabled(inbox.link != .live)
    }

    private var filterMenu: some View {
        Menu {
            Toggle(isOn: $inbox.showsHidden) {
                Label("Show hidden (\(inbox.hiddenCount))", systemImage: "eye")
            }
            .disabled(inbox.hiddenCount == 0 && !inbox.showsHidden)
            Button("Reorder Sections…", systemImage: "arrow.up.arrow.down") { showingSectionOrder = true }
                .disabled(inbox.reorderableSectionNames.count < 2)
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .disabled(inbox.connection == nil)
    }

    private func openPendingDestination() {
        guard let destination = pendingDestination, destination.server == server else { return }
        inbox.selection = BotInboxSelection()
        guard BotDeepLinkRouter.inboxCanAnswer(
            link: inbox.link, hasConnection: inbox.connection != nil, hasSettled: hasSettled
        ) else { return }
        pendingDestination = nil
        inbox.selection.open(destination, connection: inbox.connection, profiles: inbox.profiles)
        if destination.opensScreen, let profile = inbox.selection.profile { openScreen(profile) }
    }

    private func openSearchSelection() {
        defer { searchedProfile = nil; searchedRoom = nil; searchedSequence = nil }
        if let key = searchedRoom, key.connectionID == inbox.connection?.id,
           inbox.rooms.contains(where: { $0.id == key.roomID }) { roomSequence = searchedSequence; inbox.selection.room = key; return }
        guard let searched = searchedProfile, inbox.connection?.id == searched.connectionID else { return }
        inbox.selection.profile = inbox.profiles.first { $0.id == searched.profileID }
    }

    @ViewBuilder private func chatSections(_ sections: [BotInbox.ChatSection]) -> some View {
        let headed = sections.contains { $0.name != nil }
        ForEach(sections) { section in
            if headed {
                Section {
                    chatRows(section.chats)
                } header: {
                    Group {
                        if let name = section.name { Text(verbatim: name) } else { Text("Other chats") }
                    }
                    .font(AppFont.subheadline(weight: .semibold)).foregroundStyle(.appSecondary)
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
        Button { inbox.selection.profile = profile } label: {
            BotInboxRow(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile),
                        status: inbox.liveStatuses[profile.id], statusIsStale: inbox.liveStatusesAreStale)
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.5 : 1)
        .contextMenu { organizeMenu(profile) }
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

    private func updateSignIn() {
        updatingSignIn = true; showingSetup = true
    }

    @ViewBuilder private func chat(_ profile: BotProfile, _ connection: BotConnection) -> some View {
        if let chat = inbox.selection.chat(server: server, connection: connection) {
            ChatView(hermesSession: chat, continuity: inbox.selection.chatContinuity)
            .modifier(HermesUpdateSignInModifier { inbox.noteRejectedSignIn(connection); inbox.selection.profile = nil; updateSignIn() })
            .id([profile.id, connection.id.uuidString, inbox.selection.conversation ?? ""])
            .onAppear { inbox.markSeen(profile); UsageReports.shared.record(.bots) }
            .onDisappear { inbox.noteReturn(from: profile) }
            .modifier(BotScreenOpenerModifier(isOffered: canOpenScreen) { takingOver in openScreen(profile, takingOver: takingOver) })
        }
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
        roomSequence = nil; inbox.selection.room = key
    }

    private var sceneActions: HermexSceneActions? {
        guard home != nil else { return nil }
        return HermexSceneActions(
            canCreateNewChat: inbox.link == .live,
            createNewChat: { if inbox.link == .live { creation = .new } },
            searchSessions: { if inbox.connection != nil { showingSearch = true } },
            openChat: { position in
                if let chat = ChatShortcutNavigation.chat(atPosition: position, in: keyboardShortcutChats) { open(chat) }
            },
            openAdjacentChat: { offset in
                if let chat = ChatShortcutNavigation.adjacentChat(offset: offset, from: selectedChatID, in: keyboardShortcutChats) {
                    open(chat)
                }
            },
            openScreen: inbox.selection.profile.flatMap { profile in
                canOpenScreen ? { openScreen(profile) } : nil
            }
        )
    }

    private func heldScreenRow(_ profile: String, _ connection: BotConnection) -> some View {
        let bot = inbox.profiles.first { $0.id == profile }
        return HStack {
            Button {
                if let bot { openScreen(bot) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: bot?.name ?? profile).font(AppFont.headline())
                    Text("You hold its screen").font(AppFont.subheadline()).foregroundStyle(.appSecondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Hand Back") {
                Task { await ScreenHolds.handBack(profile: profile, server: server, connection: connection) }
            }
            .buttonStyle(.bordered)
        }
    }

    private var canOpenScreen: Bool {
        isScreenEnabled && !hostLacksScreen
    }

    private func openScreen(_ profile: BotProfile, takingOver: Bool = false) {
        guard canOpenScreen, let connection = inbox.connection else { return }
        screenTarget = BotScreenTarget(profile: profile, connection: connection, takesOver: takingOver)
    }

    private var keyboardShortcutChats: [BotInbox.ChatRow] {
        guard inbox.connection != nil else { return [] }
        return inbox.pinned + inbox.sections.flatMap(\.chats)
    }

    private var selectedChatID: String? {
        if let profile = inbox.selection.profile { return BotInbox.ChatRow.bot(profile).id }
        guard let key = inbox.selection.room, let room = inbox.rooms.first(where: { $0.id == key.roomID }) else { return nil }
        return BotInbox.ChatRow.room(room).id
    }

    private func open(_ chat: BotInbox.ChatRow) {
        switch chat {
        case .bot(let profile): inbox.selection.profile = profile
        case .room(let room): openRoom(room)
        }
    }

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

    @ViewBuilder private func organizeMenu(_ profile: BotProfile) -> some View {
        if canOpenScreen {
            Button { openScreen(profile) } label: {
                Label("Screen", systemImage: "display")
            }
        }
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

    private func sectionMenu(_ profile: BotProfile) -> some View {
        Menu {
            ForEach(inbox.sectionNames) { section in
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
    private func attachPresentations(to content: some View) -> some View {
        content
            .sheet(isPresented: Binding(get: { roomCreator != nil }, set: { if !$0 { roomCreator = nil } }), onDismiss: {
                if let key = createdRoom, key.connectionID == inbox.connection?.id { roomSequence = nil; inbox.selection.room = key }
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
                inbox.selection.room = nil; inbox.selection.conversation = nil
                editSelection = nil
                creation = nil
                roomCreator?.suspend(); roomCreator = nil; createdRoom = nil
                deleting = nil
                renamingRoom = nil; disbanding = nil; filing = nil
                showingSectionOrder = false
                screenTarget = nil; hostLacksScreen = false
            }
            .sheet(isPresented: $showingSectionOrder) {
                BotSectionOrderView(inbox: inbox)
            }
            .sheet(isPresented: $showingSetup, onDismiss: { updatingSignIn = false; revision = UUID() }) {
                NavigationStack {
                    BotConnectionView(server: server, focusesPassword: updatingSignIn) { inbox.signInSaved() }
                }
            }
            .sheet(item: Binding(get: { usesSplit ? editSelection : nil },
                                 set: { editSelection = $0 })) { selection in
                NavigationStack {
                    editProfile(selection)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { editSelection = nil }
                            }
                        }
                }
            }
            .task(id: revision) {
                inbox.offlineCache = modelContext
                await inbox.open(); hasSettled = true; openPendingDestination()
                if let connection = inbox.connection { await ScreenHolds.reconcile(server: server, connection: connection) }
            }
            .onChange(of: inbox.link) { openPendingDestination() }
            .onChange(of: pendingDestination) { openPendingDestination() }
            .refreshable { await inbox.open() }
            .onChange(of: scenePhase) {
                switch scenePhase {
                case .background: inbox.close()
                case .active where inbox.link == .idle: revision = UUID()
                default: break
                }
            }
            .onDisappear { inbox.close() }
            .onChange(of: NetworkPathMonitor.shared.changeCount) { inbox.networkPathDidChange() }
    }
}

private struct BotsInboxChrome<Filter: View, NewChat: View>: ViewModifier {
    let home: HermesHome?
    let isOffline: Bool
    let search: () -> Void
    let openSetup: () -> Void
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat

    init(home: HermesHome?, isOffline: Bool, search: @escaping () -> Void, openSetup: @escaping () -> Void,
         @ViewBuilder filter: () -> Filter, @ViewBuilder newChat: () -> NewChat) {
        self.home = home; self.isOffline = isOffline; self.search = search; self.openSetup = openSetup
        self.filter = filter(); self.newChat = newChat()
    }

    func body(content: Content) -> some View {
        if let home {
            content.modifier(HermesHomeChrome(home: home, search: HermesHomeSearch(label: "Search bots and messages",
                                                                               isDisabled: isOffline, open: search),
                                               filter: { filter }, newChat: { newChat }))
        } else {
            content
                .themedPageBackground()
                .navigationTitle("Bots")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Search bots and messages", systemImage: "magnifyingglass", action: search)
                            .disabled(isOffline)
                    }
                    ToolbarItem(placement: .topBarTrailing) { newChat }
                    if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Bot connection", systemImage: "gearshape", action: openSetup)
                    }
                }
        }
    }
}

private struct BotSectionOrderView: View {
    @Environment(\.dismiss) private var dismiss
    let inbox: BotInbox

    var body: some View {
        let sections = inbox.reorderableSectionNames
        NavigationStack {
            AppList {
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
            .themedPageBackground()
            .navigationTitle("Reorder Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private enum BotCreationIntent: Identifiable {
    case new, duplicate(BotProfile)
    var id: String { source?.id ?? "" }
    var source: BotProfile? { if case .duplicate(let profile) = self { return profile }; return nil }
}

private struct BotScreenTarget: Identifiable {
    let profile: BotProfile
    let connection: BotConnection
    let takesOver: Bool
    var id: String { connection.id.uuidString + "|" + profile.id }
}

private struct BotProfileEditSelection: Identifiable, Hashable {
    let connectionID: UUID
    let profileID: String
    var id: String { connectionID.uuidString + "|" + profileID }
}

private struct BotHeroTile: View {
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    let status: BotLiveStatus?
    let statusIsStale: Bool
    var body: some View {
        VStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: avatar, size: 84)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name).font(AppFont.body()).foregroundStyle(.appSecondary).lineLimit(1)
                    if unread { BotUnreadDot() }
                }
                BotLiveStatusLabel(status: .waiting, font: AppFont.footnote(weight: .semibold), isStale: false)
                    .lineLimit(2).multilineTextAlignment(.center).hidden().accessibilityHidden(true)
                    .overlay(alignment: .top) {
                        if let status {
                            BotLiveStatusLabel(status: status, font: AppFont.footnote(weight: .semibold), isStale: statusIsStale)
                                .lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
            }
        }
        .frame(maxWidth: 132)
        .accessibilityElement(children: .combine)
    }
}

private struct BotRoomHeroTile: View {
    let room: BotGroupRoom
    let roster: [BotProfile]
    let avatars: [String: UIImage]
    var body: some View {
        VStack(spacing: 14) {
            BotRoomAvatars(room: room, roster: roster, avatars: avatars, size: 60).frame(height: 84)
            Text(room.name).font(AppFont.body()).foregroundStyle(.appSecondary).lineLimit(1)
        }
        .frame(maxWidth: 132)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(room.name))
    }
}

private struct BotInboxRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    let status: BotLiveStatus?
    let statusIsStale: Bool
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
                    Text(subline).font(AppFont.body()).foregroundStyle(.appSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if unread { BotUnreadDot() }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var nameAndChip: some View {
        Text(profile.name).font(AppFont.headline()).lineLimit(1)
        if let chip {
            Text(chip).font(AppFont.footnote()).foregroundStyle(.appSecondary).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                .layoutPriority(-1)
        }
    }

    @ViewBuilder private var trailingSlot: some View {
        if let status {
            BotLiveStatusLabel(status: status, font: AppFont.subheadline(weight: .semibold), isStale: statusIsStale)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        } else if let date = profile.lastActive {
            Text(BotInboxDateLabel.text(for: date)).font(AppFont.subheadline()).foregroundStyle(.appSecondary)
        }
    }
}

private struct BotLiveStatusLabel: View {
    let status: BotLiveStatus
    let font: Font
    let isStale: Bool
    var body: some View {
        let (word, tint) = switch status {
        case .working: (String(localized: "Working"), Color("AttentionWorking"))
        case .waiting: (String(localized: "Waiting for you"), Color("AttentionApproval"))
        }
        Text(word).font(font)
            .foregroundStyle(isStale ? AnyShapeStyle(.appSecondary) : AnyShapeStyle(tint))
            .accessibilityLabel(isStale ? String(localized: "Last known: \(word)") : word)
    }
}

private struct BotInboxSkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.fill.tertiary).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "Chief of Staff").font(AppFont.headline())
                    Spacer(minLength: 8)
                    Text(verbatim: "Saturday").font(AppFont.subheadline())
                }
                Text(verbatim: "Reading the latest conversation").font(AppFont.body())
            }
            .redacted(reason: .placeholder)
        }
    }
}

private struct BotUnreadDot: View {
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
            .accessibilityLabel("Unread")
    }
}

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
