import StoreKit
import SwiftUI

struct HermesSessionListEntry: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let connection: BotConnection
    let profile: String?
    var query = ""

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HermesSessionListView: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) private var showsCronSessions = true
    @AppStorage private var showsCliSessions: Bool
    @AppStorage(SessionSidebarDisclosureSettings.scheduledSessionsAreExpandedKey)
    private var scheduledSessionsAreExpanded = SessionSidebarDisclosureSettings.defaultScheduledSessionsAreExpanded
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SectionVisibilitySettings.tasksKey) private var showsTasks = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) private var showsKanban = true
    @AppStorage(SectionVisibilitySettings.skillsKey) private var showsSkills = true
    @AppStorage(SectionVisibilitySettings.memoryKey) private var showsMemory = true
    @AppStorage(SectionVisibilitySettings.insightsKey) private var showsInsights = true
    @AppStorage(SectionVisibilitySettings.projectsKey) private var showsProjects = true
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    private let entry: HermesSessionListEntry
    private let home: HermesHome?
    @Binding private var pendingLink: HermesSessionDestination?
    @Binding private var pendingNewChat: HermesNewChatDestination?
    @Binding private var pendingUsage: HermesUsageDestination?
    private let pendingShare: SharedImportReservation?
    private let claimShare: (SharedImportReservation) -> Bool
    private let didRouteShare: (SharedImportReservation) -> Void
    private let didDeclineShare: (SharedImportReservation) -> Void
    private let didAbandonShare: (SharedImportReservation) -> Void
    private let shortcutReview: ShortcutTextReview
    private let isCoveredByHome: () -> Bool
    @State private var shareTransfer: Task<Void, Never>?
    @State private var failedShare: HermesShareFailure?
    @State private var viewModel: SessionListViewModel
    @State private var navigation: HermesSessionListNavigation
    @State private var actionToast = ActionToastState()
    @FocusState private var isSearchFieldFocused: Bool
    @State private var searchRequests = 0
    @State private var draftRows: Set<ChatDraftStore.DraftRow> = []
    @State private var draftReads = 0
    @State private var wasBackgrounded = false
    @State private var ratingRequestID: UUID?
    @State private var ratingMoment: RatingPromptMoment = .coldLaunch

    init(entry: HermesSessionListEntry) {
        self.init(entry: entry, model: Self.model(for: entry), home: nil)
    }

    init(entry: HermesSessionListEntry, model: SessionListViewModel, home: HermesHome?,
         navigation: HermesSessionListNavigation? = nil,
         pendingLink: Binding<HermesSessionDestination?> = .constant(nil),
         pendingNewChat: Binding<HermesNewChatDestination?> = .constant(nil),
         pendingUsage: Binding<HermesUsageDestination?> = .constant(nil),
         pendingShare: SharedImportReservation? = nil,
         claimShare: @escaping (SharedImportReservation) -> Bool = { _ in false },
         didRouteShare: @escaping (SharedImportReservation) -> Void = { _ in },
         didDeclineShare: @escaping (SharedImportReservation) -> Void = { _ in },
         didAbandonShare: @escaping (SharedImportReservation) -> Void = { _ in },
         shortcutReview: ShortcutTextReview = ShortcutTextReview(),
         isCoveredByHome: @escaping () -> Bool = { false }) {
        _navigation = State(initialValue: navigation ?? HermesSessionListNavigation(searchText: entry.query))
        self.entry = entry
        self.home = home
        _pendingLink = pendingLink
        _pendingNewChat = pendingNewChat
        _pendingUsage = pendingUsage
        self.pendingShare = pendingShare
        self.claimShare = claimShare
        self.didRouteShare = didRouteShare
        self.didDeclineShare = didDeclineShare
        self.didAbandonShare = didAbandonShare
        self.shortcutReview = shortcutReview
        self.isCoveredByHome = isCoveredByHome
        _viewModel = State(initialValue: model)
        _showsCliSessions = AppStorage(wrappedValue: true, SessionRowDisplaySettings.showCliSessionsKey(for: entry.server))
    }

    private var covers: HermesSessionListCovers {
        get { navigation.covers }
        nonmutating set { navigation.covers = newValue }
    }
    private var selectedProjectID: String? {
        get { navigation.selectedProjectID }
        nonmutating set { navigation.selectedProjectID = newValue }
    }
    private var statusFilter: HermesSessionStatusFilter {
        get { navigation.statusFilter }
        nonmutating set { navigation.statusFilter = newValue }
    }
    private var searchText: String {
        get { navigation.searchText }
        nonmutating set { navigation.searchText = newValue }
    }
    private var isSearchExpanded: Bool {
        get { navigation.isSearchExpanded }
        nonmutating set { navigation.isSearchExpanded = newValue }
    }

    static func model(for entry: HermesSessionListEntry) -> SessionListViewModel {
        let server = entry.server
        return SessionListViewModel(server: server, hermes: HermesSessionListSource(
            connection: entry.connection, profile: entry.profile, makeWire: { BotClient(saved: $0, server: server) }
        ))
    }

    private var sessionRows: some View {
        let groups = scheduledSessionGroups
        return AppList(rows: .plain) {
            if let home {
                SessionsHeader(
                    logoColor: HeaderLogoColor.color(for: headerLogoColorHex), avatar: home.avatar,
                    field: SessionsHeader.Field(isExpanded: isSearchExpanded, text: $navigation.searchText,
                                                isFocused: $isSearchFieldFocused, close: closeSearch),
                    connection: viewModel.hermesConnection, reconnectNow: viewModel.reconnectNow,
                    openSearch: openSearch
                )
                .sessionsTopChromeListRow()
                .id(HomeHeaderScroll.headerID)
                SessionListCardSlot(hasSharedImport: pendingShare != nil)
                MoveToHermesBanner(serverID: entry.server.absoluteString)
            }
            if viewModel.showsOfflineCache {
                OfflineCacheBanner()
                    .padding(.top, 16)
                    .sessionsScreenListRow()
            }
            SessionSidebarUtilityRows(
                viewModel: viewModel, topPadding: 10, automatedVisibility: .showAll, sectionVisibility: sectionVisibility,
                profilesAreExpanded: .constant(false), projectsAreExpanded: $projectsAreExpanded,
                selectedProjectID: $navigation.selectedProjectID, projectPendingDeletion: $navigation.covers.deletingProject,
                projectPendingRename: $navigation.covers.renamingProject, openDestination: open, switchActiveProfile: { _ in },
                presentProjectCreation: { covers.creatingProject = HermesProjectCreation(folder: "") }
            )
            if !groups.needsYou.isEmpty {
                NeedsYouSessionsSection(
                    viewModel: viewModel, sessions: groups.needsYou, showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace, selectedSessionID: usesSplit ? selectedSessionID : nil, actions: actions
                )
            }
            if groups.showsDisclosure(isSearchActive: isSearching) {
                ScheduledSessionsDisclosure(
                    viewModel: viewModel, searchText: searchText, sessions: groups.scheduled,
                    totalCount: groups.totalScheduledCount, isSearchActive: isSearching,
                    showsMessageCount: showsMessageCount, showsWorkspace: showsWorkspace,
                    selectedSessionID: usesSplit ? selectedSessionID : nil,
                    userIsExpanded: $scheduledSessionsAreExpanded, actions: actions,
                    viewAll: {
                        prepareRootSelection()
                        covers.showingScheduled = true
                    }
                )
            }
            SessionListRowsSection(
                viewModel: viewModel,
                searchText: searchText,
                sessions: groups.ordinary,
                emptyTitle: emptyTitle,
                emptyDescription: emptyDescription,
                isSearchActive: false,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                selectedSessionID: usesSplit ? selectedSessionID : nil,
                actions: actions,
                suppressEmptyState: !groups.scheduled.isEmpty || !groups.needsYou.isEmpty,
                showsErrorOverRows: true
            )
            if showsLoadMore && !isSearching { loadMoreRow }
            if !viewModel.isViewingCachedData && !viewModel.hermesShowsAllProfiles && viewModel.archivedCount != 0 { archivedRow }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Color(.appCanvas))
        .modifier(chrome)
        .modifier(HomeHeaderScroll(requests: searchRequests))
    }

    var body: some View {
        navigationSurface
        .focusedSceneValue(\.hermexSceneActions, sceneActions)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: projectsAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: scheduledSessionsAreExpanded)
        .overlay(alignment: .bottom) {
            ActionToastView(state: actionToast)
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .refreshable { await viewModel.refreshHermes(modelContext: modelContext) }
        .task(id: SearchScope(profile: profile, showsAll: viewModel.hermesShowsAllProfiles, text: searchText, showingScheduled: covers.showingScheduled)) {
            guard !covers.showingScheduled else { return }
            await viewModel.searchSessions(query: searchText)
        }
        .onChange(of: SearchScope(profile: profile, showsAll: viewModel.hermesShowsAllProfiles, text: searchText, showingScheduled: false)) {
            if usesSplit && covers.showingScheduled { covers.showingScheduled = false }
        }
        .sheet(item: $navigation.covers.renaming, onDismiss: { viewModel.clearRenameError() }) { session in
            SessionRenameSheet(initialTitle: SessionRowView.displayTitle(for: session), isSaving: viewModel.isRenamingSession,
                               errorMessage: viewModel.renameErrorMessage) {
                covers.renaming = nil
            } onSave: { title in
                Task { if await rename(session, to: title) { covers.renaming = nil } }
            }
            .themedPageBackground()
            .presentationDetents([.medium])
        }
        .sheet(item: $navigation.covers.exported) { item in
            FileShareSheet(fileURL: item.fileURL)
                .themedPageBackground()
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
                .onDisappear { try? FileManager.default.removeItem(at: item.fileURL.deletingLastPathComponent()) }
        }
        .sheet(item: $navigation.covers.creatingProject, onDismiss: {
            viewModel.clearProjectSheetError()
            covers.moving = covers.movingAfterCreation
            covers.movingAfterCreation = nil
        }) { creation in
            ProjectCreationSheet(
                existingProjectCount: viewModel.projects.count, isSaving: viewModel.isCreatingProject,
                folder: ProjectFolderField(initialPath: creation.folder) { await viewModel.completeHermesFolder($0) },
                errorMessage: viewModel.projectSheetErrorMessage
            ) {
                covers.creatingProject = nil
            } onSave: { name, color, folder in
                Task {
                    guard let saved = await viewModel.createHermesProject(named: name, color: color, folder: folder ?? "") else { return }
                    covers.movingAfterCreation = creation.move(intoProjectNamed: name, savedOn: saved, isBusy: creation.session
                        .map { viewModel.attentionState(for: $0) != nil } ?? false)
                    covers.creatingProject = nil
                }
            }
            .themedPageBackground()
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $navigation.covers.renamingProject, onDismiss: { viewModel.clearProjectSheetError() }) { project in
            ProjectRenameSheet(project: project, isSaving: viewModel.isRenamingProject,
                               errorMessage: viewModel.projectSheetErrorMessage) {
                covers.renamingProject = nil
            } onSave: { name, color in
                Task { if await viewModel.rename(project, named: name, color: color) { covers.renamingProject = nil } }
            }
            .themedPageBackground()
            .presentationDetents([.medium])
        }
        .alert(Text(verbatim: covers.moving?.title ?? ""), isPresented: Binding(get: { covers.moving != nil }, set: { if !$0 { covers.moving = nil } }),
               presenting: covers.moving) { move in
            Button("Cancel", role: .cancel) {}
            Button("Move") { Task { await self.move(move) } }
        } message: { move in
            Text(verbatim: move.message)
        }
        .alert(failedShare?.share.sharedImport.shortcut.map(\.origin.cantOpenTitle) ?? Text("Couldn’t Add Shared Files"),
               isPresented: Binding(get: { failedShare != nil }, set: { if !$0 { queueFailedShareAgain() } }),
               presenting: failedShare) { failure in
            Button(failure.share.sharedImport.shortcut == nil ? "Discard Share" : "Discard", role: .destructive) {
                failedShare = nil
                didRouteShare(failure.share)
            }
        } message: { failure in
            Text(verbatim: failure.reason + "\n\n" + (failure.share.sharedImport.shortcut == nil
                ? String(localized: "Nothing was added. Discard deletes this saved share from Hermex.")
                : String(localized: "Nothing was sent. Discard deletes this text from Hermex.")))
        }
        .modifier(SessionActionConfirmations(
            viewModel: viewModel, showFailure: { actionToast.show(.failure($0)) }, sessionPendingDeletion: $navigation.covers.deleting, projectPendingDeletion: $navigation.covers.deletingProject,
            deleteSession: { session in Task { await delete(session) } },
            deleteProject: { project in Task { _ = await viewModel.delete(project) } }
        ))
        .task { await viewModel.openHermes(modelContext: modelContext) }
        .task(id: DraftRead(filter: statusFilter, chatCloses: draftReads)) {
            guard statusFilter == .draft else { return }
            let rows = await ChatDraftStore.shared.hermesSessionDraftKeys(server: entry.server, connectionID: entry.connection.id)
            if !Task.isCancelled { draftRows = rows }
        }
        .onChange(of: pendingLink, initial: true) { if pendingLink != nil { covers.accept(pendingLink, on: entry.server) } }
        .task(id: pendingLink) { await openPendingLink() }
        .onChange(of: pendingUsage, initial: true) { if pendingUsage != nil { covers.bringForward() } }
        .task(id: UsageReadiness(link: pendingUsage, isLive: viewModel.isHermesLive)) { await openPendingUsage() }
        .onChange(of: NewChatReadiness(request: pendingNewChat, share: pendingShare?.reservationID, profile: profile,
                                       isLive: viewModel.isHermesLive, isTransferringShare: shareTransfer != nil),
                  initial: true) {
            openPendingNewChat()
            openPendingShare()
        }
        .onDisappear {
            ratingRequestID = nil
            shareTransfer?.cancel()
            shareTransfer = nil
            queueFailedShareAgain()
            actionToast.dismiss()
            if usesSplit { viewModel.closeHermes() } else { covers.listDisappeared(viewModel) }
        }
        .onChange(of: showsProjects, initial: true) { if !showsProjects { selectedProjectID = nil } }
        .onChange(of: ProfileScope(profile: viewModel.hermesProfile, showsAll: viewModel.hermesShowsAllProfiles)) { old, new in
            if old.profile != nil || old.showsAll != new.showsAll { statusFilter = .all }
        }
        .onChange(of: viewModel.projects) {
            if let selectedProjectID, !viewModel.projects.contains(where: { $0.projectId == selectedProjectID }) {
                self.selectedProjectID = nil
            }
        }
        .onChange(of: covers.chat) { old, new in
            if case .session(_, let key)? = old?.target, new?.id != old?.id { viewModel.noteHermesReturn(from: key) }
            if old != nil, new?.id != old?.id { draftReads += 1 }
            if let new, new.id != old?.id { SessionOpenSignpost.begin(sessionID: new.id.uuidString) }
            if let old, new?.id != old.id { shortcutReview.end(old.id) }
            ratingRequestID = nil
            if old != nil, new == nil { requestRating(at: .returnedToSessionList) }
        }
        .onChange(of: viewModel.sessions.count, initial: true) { LaunchSignpost.end(rows: viewModel.sessions.count) }
        .onChange(of: scenePhase) {
            if scenePhase == .background { wasBackgrounded = true }
            if scenePhase == .active, wasBackgrounded {
                wasBackgrounded = false
                requestRating(at: .foreground)
            } else if scenePhase != .active {
                ratingRequestID = nil
            }
            switch scenePhase {
            case .background: viewModel.closeHermes()
            case .active where covers.reopensOnForeground(usesSplit: usesSplit) && !viewModel.isHermesConnected:
                Task { await viewModel.openHermes(modelContext: modelContext) }
            default: break
            }
        }
        .onChange(of: NetworkPathMonitor.shared.changeCount) { viewModel.networkPathDidChange() }
        .task(id: RatingCheck(request: ratingRequestID, isLive: viewModel.isHermesLive)) {
            guard ratingRequestID != nil, viewModel.isHermesLive else { return }
            await RatingPromptState.shared.requestWhenQuiet(
                moment: ratingMoment,
                server: entry.server,
                isSessionListVisible: {
                    if let card = SessionListCard.current(hasSharedImport: pendingShare != nil), isQuietSessionListVisible {
                        RatingPromptState.shared.recordCardShown(card)
                    }
                    return isQuietSessionListVisible
                },
                loadSessions: { await viewModel.hermesHostIsIdle() == true ? [] : nil },
                request: { requestReview() }
            )
            if !Task.isCancelled { ratingRequestID = nil }
        }
    }

    private func requestRating(at moment: RatingPromptMoment) {
        guard home != nil else { return }
        ratingMoment = moment
        ratingRequestID = UUID()
    }

    private var isQuietSessionListVisible: Bool {
        home != nil && scenePhase == .active && viewModel.isHermesLive && !isCoveredByHome()
            && covers.chat == nil && !covers.isCoveredByScreen
            && pendingLink == nil && pendingNewChat == nil && pendingUsage == nil
            && pendingShare == nil && shareTransfer == nil && failedShare == nil
            && !isSearchExpanded && !isSearching && !viewModel.isCreatingSession
            && covers.renaming == nil && covers.deleting == nil && covers.exported == nil
            && covers.creatingProject == nil && covers.renamingProject == nil && covers.deletingProject == nil
            && covers.moving == nil
    }

    private var usesSplit: Bool {
        HermesHomeLayout.usesSplit(isHome: home != nil, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
    }

    private var selectedSessionID: String? {
        covers.selectedSessionID
    }

    private func prepareRootSelection() {
        pendingUsage = nil
        if usesSplit { covers.bringForward() }
    }

    @ViewBuilder private var navigationSurface: some View {
        if usesSplit {
            SessionSplitView(rootRevision: covers.detailIdentity.hashValue, offersHideSidebar: true,
                             sidebarRequests: searchRequests) {
                sessionRows
            } detail: {
                regularWidthDetail
                    .modifier(HermesHomeDetailBar(home: home, search: HermesHomeSearch(label: "Search sessions", open: openSearch),
                                                  filter: { profileFilter }, newChat: { newSessionButton }))
            }
        } else {
            compactSessionRows
        }
    }

    private var compactSessionRows: some View {
        sessionRows
        .navigationDestination(item: $navigation.covers.chat) { chat in
            ChatView(hermesSession: covers.building(chat), onReplace: { replace(chat, with: $0) }, onOpenSessions: { opened in
                self.covers.chat = nil
                if let listed = opened.profile, listed != profile || viewModel.hermesShowsAllProfiles {
                    Task { await viewModel.selectHermesProfile(listed) }
                }
                searchText = opened.query
                if !opened.query.isEmpty && home != nil { isSearchExpanded = true }
            }, onDraftKeyChange: identifyChat(chat), waitingShortcut: shortcutReview.waiting(in: chat.id),
            continuity: covers.chatContinuity)
            .modifier(SessionScreenModifier(chat: chat))
            .id(chat.id)
        }
        .navigationDestination(isPresented: $navigation.covers.showingScheduled) {
            scheduledSessions
                .task { await viewModel.openHermes(modelContext: modelContext) }
                .onDisappear { covers.scheduledDisappeared(viewModel) }
        }
        .navigationDestination(isPresented: $navigation.covers.showingArchived) {
            if let profile {
                ArchivedSessionsView(server: entry.server, hermes: .saved(entry.connection, server: entry.server, profile: profile))
            }
        }
        .navigationDestination(item: $navigation.covers.tasks) { entry in
            TasksView(server: entry.server, onAPIError: { _ in }, client: entry.client, newTaskProfile: entry.newTaskProfile)
                .id(entry.id)
        }
        .navigationDestination(item: $navigation.covers.skills) { entry in
            SkillsView(client: entry.client, profile: entry.client.profile, onAPIError: { _ in })
                .id(entry.id)
        }
        .navigationDestination(item: $navigation.covers.memory) { entry in
            MemoryView(server: entry.server, client: entry.client, profile: entry.client.profile, onAPIError: { _ in })
                .id(entry.id)
        }
        .navigationDestination(item: $navigation.covers.insights) { entry in
            InsightsView(client: entry.client, profile: entry.client.profile, limitsScope: entry.limitsScope, onAPIError: { _ in })
                .id(entry.id)
        }
        .navigationDestination(isPresented: $navigation.covers.showingKanban) {
            KanbanView(server: entry.server, hermes: HermesConnections.shared.connection(for: entry.connection, server: entry.server),
                       mine: profile)
        }
    }

    private func identifyChat(_ chat: HermesSessionChat) -> (ChatDraftKey) -> Void {
        { [weak navigation, id = chat.id] in navigation?.covers.identifyChat(id, draftKey: $0) }
    }

    @ViewBuilder private var regularWidthDetail: some View {
        if let chat = covers.chat {
            ChatView(hermesSession: covers.building(chat), onReplace: { replace(chat, with: $0) }, onOpenSessions: { opened in
                covers.chat = nil
                if let listed = opened.profile, listed != profile || viewModel.hermesShowsAllProfiles {
                    Task { await viewModel.selectHermesProfile(listed) }
                }
                searchText = opened.query
                if !opened.query.isEmpty { isSearchExpanded = true }
            }, onDraftKeyChange: identifyChat(chat), waitingShortcut: shortcutReview.waiting(in: chat.id),
            continuity: covers.chatContinuity).modifier(SessionScreenModifier(chat: chat)).id(chat.id)
        } else if let entry = covers.tasks {
            TasksView(server: entry.server, onAPIError: { _ in }, client: entry.client, newTaskProfile: entry.newTaskProfile).id(entry.id)
        } else if let entry = covers.skills {
            SkillsView(client: entry.client, profile: entry.client.profile, onAPIError: { _ in }).id(entry.id)
        } else if let entry = covers.memory {
            MemoryView(server: entry.server, client: entry.client, profile: entry.client.profile, onAPIError: { _ in }).id(entry.id)
        } else if let entry = covers.insights {
            InsightsView(client: entry.client, profile: entry.client.profile, limitsScope: entry.limitsScope,
                         onAPIError: { _ in }).id(entry.id)
        } else if covers.showingKanban {
            KanbanView(server: entry.server, hermes: HermesConnections.shared.connection(for: entry.connection, server: entry.server),
                       mine: profile)
                .id(profile)
        } else if covers.showingScheduled {
            scheduledSessions
        } else if covers.showingArchived, let profile {
            ArchivedSessionsView(server: entry.server, hermes: .saved(entry.connection, server: entry.server, profile: profile))
        } else {
            ContentUnavailableView {
                Label("Select a Chat", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Choose a session from the sidebar or start a new chat.")
            } actions: {
                Button("New Chat", action: openNewSession)
                    .buttonStyle(.appProminent)
                    .disabled(!canOpenNewSession || !viewModel.isHermesLive)
            }
        }
    }

    private var scheduledSessions: some View {
        ScheduledSessionsView(viewModel: viewModel, showsCronSessions: showsCronSessions,
                              showsMessageCount: showsMessageCount, showsWorkspace: showsWorkspace,
                              selectedSessionID: nil, actions: actions, actionToast: actionToast)
    }

    private var profile: String? { viewModel.hermesProfile ?? entry.profile }

    private var sectionVisibility: SidebarSectionVisibility {
        let isHome = home != nil && !isSearchExpanded
        return SidebarSectionVisibility(
            bots: false, tasks: isHome && showsTasks, kanban: isHome && showsKanban, skills: isHome && showsSkills,
            memory: isHome && showsMemory, insights: isHome && showsInsights, activeProfile: false,
            projects: showsProjects && !viewModel.hermesShowsAllProfiles
        )
    }

    private func open(_ destination: SessionListUtilityDestination) {
        prepareRootSelection()
        let server = entry.server, connection = entry.connection
        if destination == .kanban { covers.showingKanban = true; return }
        guard let profile else { return }
        switch destination {
        case .tasks:
            covers.tasks = HermesTasksEntry(server: server, client: HermesCronClient(saved: connection, server: server), newTaskProfile: profile)
        case .skills:
            covers.skills = HermesSkillsEntry(client: HermesSkillsClient(saved: connection, server: server, profile: profile))
        case .memory:
            covers.memory = HermesMemoryEntry(server: server, client: HermesMemoryClient(saved: connection, server: server, profile: profile))
        case .insights:
            covers.insights = HermesInsightsEntry(server: server, connection: connection, profile: profile)
        default:
            break
        }
    }

    private var chrome: some ViewModifier {
        HermesSessionListChrome(home: home, searchText: $navigation.searchText, isSearchPresented: $navigation.isSearchExpanded,
                                connection: viewModel.hermesConnection, reconnectNow: viewModel.reconnectNow,
                                openSearch: openSearch, profileMenu: { profileMenu }, filter: { profileFilter }, newSession: { newSessionButton })
    }

    private func openSearch() {
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) { isSearchExpanded = true }
        if home != nil { searchRequests += 1 }
        Task { @MainActor in
            await Task.yield()
            isSearchFieldFocused = true
        }
    }

    private func closeSearch() {
        searchText = ""
        isSearchFieldFocused = false
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) { isSearchExpanded = false }
    }

    private var newSessionButton: some View {
        Button("New Session", systemImage: "square.and.pencil", action: openNewSession)
            .disabled(!canOpenNewSession)
    }

    private var canOpenNewSession: Bool { !viewModel.isViewingCachedData && profile != nil }

    private func openNewSession() {
        guard canOpenNewSession, let profile else { return }
        let cwd = viewModel.hermesNewSessionFolder(lane: showsProjects ? selectedProjectID : nil)
        prepareRootSelection()
        covers.chat = HermesSessionChat(server: entry.server, connection: entry.connection, target: .new(profile: profile, cwd: cwd))
    }

    private var sceneActions: HermexSceneActions {
        HermexSceneActions(
            canCreateNewChat: canOpenNewSession,
            createNewChat: openNewSession,
            searchSessions: openSearchFromKeyboard,
            openChat: { position in
                if let session = ChatShortcutNavigation.chat(atPosition: position, in: keyboardShortcutSessions) { actions.open(session) }
            },
            openAdjacentChat: { offset in
                if let session = ChatShortcutNavigation.adjacentChat(offset: offset, from: selectedSessionID, in: keyboardShortcutSessions) {
                    actions.open(session)
                }
            }
        )
    }

    private var keyboardShortcutSessions: [SessionSummary] {
        let groups = scheduledSessionGroups
        return groups.needsYou + groups.ordinary
    }

    private var scheduledSessionGroups: ScheduledSessionGroups {
        viewModel.scheduledSessionGroups(searchText: searchText, selectedProjectID: selectedProjectID,
                                         automatedVisibility: automatedVisibility, statusFilter: statusFilter,
                                         draftRows: draftRows)
    }

    private var automatedVisibility: AutomatedSessionVisibility {
        var automated = AutomatedSessionVisibility.showAll
        automated.showsCron = showsCronSessions
        automated.showsCli = showsCliSessions
        return automated
    }

    private func openSearchFromKeyboard() {
        isSearchFieldFocused = false
        if !usesSplit { covers.bringForward() }
        Task { @MainActor in
            await Task.yield()
            openSearch()
        }
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var emptyTitle: String {
        if isSearching { return String(localized: "No matching sessions") }
        switch statusFilter {
        case .working: return String(localized: "No working chats")
        case .unread: return String(localized: "No unread chats")
        case .draft: return String(localized: "No drafts")
        case .all: break
        }
        return selectedProjectID == nil ? String(localized: "No sessions yet") : String(localized: "No sessions in this project")
    }

    private var emptyDescription: String? {
        if isSearching { return String(localized: "Try another search or project filter.") }
        return statusFilter == .all ? nil : String(localized: "Only chats already loaded are filtered.")
    }

    private var profileMenu: some View {
        Menu {
            profilePicker
            statusSection
        } label: {
            if viewModel.hermesShowsAllProfiles {
                Text("All Profiles").lineLimit(1)
            } else {
                Text(verbatim: profile ?? "").lineLimit(1)
                    .accessibilityLabel(Text("Profile: \(profile ?? "")"))
            }
        }
    }

    private var profileFilter: some View {
        Menu {
            profilePicker
            statusSection
        } label: {
            Label("Filter", systemImage: statusFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityValue(Text(verbatim: filterValue))
    }

    private var filterValue: String {
        let listed = viewModel.hermesShowsAllProfiles ? String(localized: "All Profiles") : (profile ?? "")
        return statusFilter == .all ? listed : listed + ", " + statusFilter.title
    }

    private var statusSection: some View {
        HermesStatusFilterSection(viewModel: viewModel, selectedProjectID: selectedProjectID,
                                  automatedVisibility: automatedVisibility, statusFilter: statusFilter,
                                  pick: pickStatus, markAll: markAllRead)
    }

    private func pickStatus(_ picked: HermesSessionStatusFilter) {
        statusFilter = statusFilter == picked ? .all : picked
    }

    private func markAllRead(_ rows: [SessionSummary]) {
        Task {
            let marked = await viewModel.markAllHermesRead(rows: rows)
            guard marked > 0 else { return }
            let message = String(localized: "Marked \(marked) chats as read")
            actionToast.show(ActionToast(message: message, systemImage: "checkmark.circle.fill",
                                         accessibilityLabel: message, tone: .success))
            AccessibilityNotification.Announcement(message).post()
        }
    }

    @ViewBuilder private var profilePicker: some View {
        let listed = viewModel.hermesProfiles.isEmpty ? [profile].compactMap(\.self) : viewModel.hermesProfiles
        let picked = viewModel.hermesShowsAllProfiles ? nil : profile
        Section {
            Toggle(isOn: Binding(get: { picked == nil }, set: { _ in pickProfile(nil) })) { Text("All Profiles") }
            ForEach(listed, id: \.self) { name in
                Toggle(isOn: Binding(get: { picked == name }, set: { _ in pickProfile(name) })) {
                    Text(verbatim: name)
                    if let model = viewModel.hermesProfileModels[name] { Text(verbatim: model) }
                }
            }
        }
        .disabled(profile == nil)
    }

    private func pickProfile(_ picked: String?) {
        Task {
            if let picked { await viewModel.selectHermesProfile(picked) } else { await viewModel.showAllHermesProfiles() }
        }
    }

    private var showsLoadMore: Bool {
        guard viewModel.hasMoreSessions else { return false }
        return selectedProjectID.map(viewModel.hermesLaneIsShort) ?? true
    }

    private var loadMoreRow: some View {
        Button("Load more") { Task { await loadMore() } }
            .font(AppFont.subheadline())
            .foregroundStyle(.appSecondary)
            .disabled(viewModel.isLoadingMoreSessions)
            .frame(maxWidth: .infinity, minHeight: 44)
            .sessionsScreenListRow()
            .onAppear { if statusFilter == .all { Task { await loadMore() } } }
            .onChange(of: viewModel.sessions.count) {
                guard statusFilter == .all, let selectedProjectID else { return }
                Task { await viewModel.fillHermesLane(selectedProjectID) }
            }
            .onChange(of: statusFilter) {
                if statusFilter == .all { Task { await loadMore() } }
            }
            .id(selectedProjectID)
    }

    private func loadMore() async {
        if let selectedProjectID { await viewModel.fillHermesLane(selectedProjectID) }
        else { await viewModel.loadMoreHermesSessions() }
    }

    private var archivedRow: some View {
        Button {
            prepareRootSelection()
            covers.showingArchived = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Archived Sessions")
                    .font(AppFont.subheadline(weight: .medium))
                    .lineLimit(1)
                if let archivedCount = viewModel.archivedCount {
                    Text("\(archivedCount)")
                        .font(AppFont.footnote(weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.appMaterial(.thinMaterial), in: Capsule())
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(AppFont.caption(weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.appSecondary)
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityHint("Shows archived sessions.")
        .sessionsScreenListRow()
    }

    private var actions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: { Task { await viewModel.openHermes(modelContext: modelContext) } },
            open: { session in
                if let bot = session.hermesBot(on: entry.server, connectionID: entry.connection.id) {
                    AppIntentRouter.shared.requestDeepLink(HermesDeepLink.botURL(for: bot))
                    return
                }
                guard let listed = profile ?? session.profile,
                      let opened = session.hermesChat(on: entry.server, connection: entry.connection, listedIn: listed) else { return }
                viewModel.beginViewing(session)
                prepareRootSelection()
                covers.chat = opened
            },
            toggleUnread: { viewModel.toggleUnread($0) },
            togglePinned: { session in Task { await togglePinned(session) } },
            archive: { session in Task { await archive(session) } },
            delete: { covers.deleting = $0 },
            rename: { session in
                viewModel.clearRenameError()
                covers.renaming = session
            },
            duplicate: { session in Task { await duplicate(session) } },
            move: { session, projectID in
                guard let project = viewModel.projects.first(where: { $0.projectId == projectID }),
                      let folder = project.hermes?.folder else { return }
                covers.moving = HermesProjectMove(session: session, projectName: project.name ?? folder, folder: folder,
                                           isBusy: viewModel.attentionState(for: session) != nil)
            },
            createProject: { session in covers.creatingProject = HermesProjectCreation(folder: session.workspace ?? "", session: session) },
            refreshProjects: { Task { await viewModel.openHermes(modelContext: modelContext) } },
            export: { session, format in
                let generation = covers.generation
                Task {
                    if let url = await viewModel.export(session, format: format) {
                        covers.present(SessionExportShareItem(fileURL: url), startedAt: generation)
                    }
                }
            },
            addServer: home?.avatar.addServer
        )
    }

    private func openPendingLink() async {
        guard let link = pendingLink, link.server == entry.server else { return }
        let wire = BotClient(saved: entry.connection, server: entry.server)
        defer { wire.close() }
        let outcome: HermesSessionLookup.Outcome
        do {
            try await wire.connect()
            outcome = try await HermesSessionLookup.resolve(link, on: wire)
        } catch {
            if !Task.isCancelled, error as? BotFailure != .rejected(401), pendingLink == link { pendingLink = nil }
            return
        }
        guard !Task.isCancelled, pendingLink == link else { return }
        covers.accept(link, on: entry.server)
        pendingLink = nil
        switch outcome {
        case .found(let session):
            if let bot = session.hermesBot(on: entry.server, connectionID: entry.connection.id) {
                AppIntentRouter.shared.requestDeepLink(HermesDeepLink.botURL(for: bot))
            } else if let profile = session.profile,
                      let opened = session.hermesChat(on: entry.server, connection: entry.connection, listedIn: profile) {
                viewModel.beginViewing(session)
                prepareRootSelection()
                covers.chat = opened
            }
        case .gone:
            if let fallback = MovedWebuiRoute.fallback(for: link) {
                AppIntentRouter.shared.requestDeepLink(fallback)
                return
            }
            let server = home?.title ?? entry.server.host ?? entry.server.absoluteString
            showLinkNotice(String(localized: "That chat is no longer on \(server)."))
        case .ambiguous:
            showLinkNotice(String(localized: "That chat is in more than one Profile. Open it from Sessions."))
        case .room:
            break
        }
    }

    private func openPendingUsage() async {
        guard let link = pendingUsage, viewModel.isHermesLive else { return }
        let profiles = await viewModel.readHostProfiles()
        guard !Task.isCancelled, pendingUsage == link else { return }
        pendingUsage = nil
        guard link.serverKey == BotHistoryCache.Scope.key(entry.server), link.connectionID == entry.connection.id,
              profiles?.contains(link.profile) == true else { return }
        prepareRootSelection()
        covers.insights = HermesInsightsEntry(server: entry.server, connection: entry.connection, profile: link.profile)
    }

    private func openPendingNewChat() {
        if covers.open(pendingNewChat, on: entry, listed: profile, isLive: viewModel.isHermesLive) { pendingNewChat = nil }
    }

    private func replace(_ chat: HermesSessionChat, with replacement: HermesSessionChat) {
        shortcutReview.replace(chat.id, replacement.id)
        covers.chat = replacement
    }

    private func openPendingShare() {
        guard shareTransfer == nil, let share = pendingShare,
              let opening = covers.open(share, on: entry, listed: profile, isLive: viewModel.isHermesLive) else {
            return
        }
        guard case .chat(let chat) = opening else { return didRouteShare(share) }
        guard share.sharedImport.shortcut?.profile != nil else { return move(share, into: chat) }
        shareTransfer = Task {
            let confirmed = await share.confirmingProfile(of: chat, readProfiles: viewModel.readHostProfiles)
            guard !Task.isCancelled else { return }
            shareTransfer = nil
            switch confirmed {
            case .chat?:
                move(share, into: chat)
            case .missingProfile(let name)?:
                guard claimShare(share) else { return }
                let server = home?.title ?? entry.server.host ?? entry.server.absoluteString
                failedShare = HermesShareFailure(
                    share: share, reason: String(localized: "The Profile “\(name)” no longer exists on \(server).")
                )
            case .nothing?, nil:
                didDeclineShare(share)
            }
        }
    }

    private func move(_ share: SharedImportReservation, into chat: HermesSessionChat) {
        guard claimShare(share) else { return }
        let isShortcut = share.sharedImport.shortcut != nil
        if isShortcut { shortcutReview.begin(chat.id) }
        shareTransfer = Task {
            do {
                try await share.transfer(into: chat, route: didRouteShare)
                if !Task.isCancelled {
                    covers.bringForward()
                    covers.chat = chat
                } else if isShortcut {
                    shortcutReview.end(chat.id)
                }
            } catch is CancellationError {
                didAbandonShare(share)
                if isShortcut { shortcutReview.end(chat.id) }
            } catch {
                if Task.isCancelled {
                    didDeclineShare(share)
                } else {
                    covers.bringForward()
                    failedShare = HermesShareFailure(share: share, error: error)
                }
                if isShortcut { shortcutReview.end(chat.id) }
            }
            if !Task.isCancelled { shareTransfer = nil }
        }
    }

    private func queueFailedShareAgain() {
        guard let failedShare else { return }
        self.failedShare = nil
        didDeclineShare(failedShare.share)
    }

    private func showLinkNotice(_ message: String) {
        actionToast.show(ActionToast(message: message, systemImage: "exclamationmark.triangle", accessibilityLabel: message))
    }

    private var mutationAnimation: Animation? { SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion) }

    private func togglePinned(_ session: SessionSummary) async {
        if await viewModel.setPinned(session.pinned != true, for: session, animation: mutationAnimation) {
            SessionHaptics.pinStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    private func archive(_ session: SessionSummary) async {
        guard await viewModel.archive(session, animation: mutationAnimation) else { return }
        covers.closeChat(for: session)
        SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
        let message = String(localized: "Archived")
        actionToast.show(ActionToast(
            message: message, systemImage: "archivebox",
            accessibilityLabel: String.localizedStringWithFormat(String(localized: "%@, %@"),
                                                                 SessionRowView.displayTitle(for: session), message),
            actionTitle: String(localized: "Undo"),
            action: {
                Task {
                    if await viewModel.unarchive(session, animation: mutationAnimation) {
                        SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
                    }
                }
            }
        ))
    }

    private func move(_ move: HermesProjectMove) async {
        guard let previous = await viewModel.moveHermesSession(move.session, toFolder: move.folder) else { return }
        let message = String(localized: "Moved")
        actionToast.show(ActionToast(
            message: message, systemImage: "folder",
            accessibilityLabel: String.localizedStringWithFormat(String(localized: "%@, %@"),
                                                                 SessionRowView.displayTitle(for: move.session), message),
            actionTitle: String(localized: "Undo"),
            action: { Task { _ = await viewModel.moveHermesSession(move.session, toFolder: previous) } }
        ))
    }

    private func duplicate(_ session: SessionSummary) async {
        guard let profile, let copy = await viewModel.duplicate(session),
              let opened = copy.hermesChat(on: entry.server, connection: entry.connection, listedIn: profile) else { return }
        prepareRootSelection()
        covers.chat = opened
    }

    private func delete(_ session: SessionSummary) async {
        if await viewModel.delete(session, animation: mutationAnimation) {
            covers.closeChat(for: session)
            SessionHaptics.sessionDeleted(isEnabled: isHapticsEnabled)
        }
    }

    private func rename(_ session: SessionSummary, to title: String) async -> Bool {
        let renamed = await viewModel.rename(session, to: title)
        if renamed, title != session.title { SessionHaptics.sessionRenamed(isEnabled: isHapticsEnabled) }
        return renamed
    }
}

enum HermesShareOpening: Equatable {
    case chat(HermesSessionChat)
    case nothing
    case missingProfile(String)
}

extension SharedImportReservation {
    @MainActor func hermesOpening(on entry: HermesSessionListEntry, listed: String?, isLive: Bool) -> HermesShareOpening? {
        guard let shortcut = sharedImport.shortcut else {
            guard var chat = HermesNewChatDestination(server: entry.server, profile: nil)
                .chat(on: entry, listed: listed, isLive: isLive) else { return nil }
            chat.shareNotice = SharedSkipsNotice(sharedImport.skipped)
            let isEmpty = HermesShareDraft.composerDraft(from: sharedImport.draft).isEmpty && sharedImport.attachments.isEmpty
            return isEmpty ? .nothing : .chat(chat)
        }
        guard shortcut.opens(on: entry.server) else { return nil }
        guard Date().timeIntervalSince(createdAt) < HermesShareDraft.shortcutTextLifetime else { return .nothing }
        return HermesNewChatDestination(server: entry.server, profile: shortcut.profile)
            .chat(on: entry, listed: listed, isLive: isLive).map { .chat($0) }
    }

    @MainActor func confirmingProfile(of chat: HermesSessionChat,
                                      readProfiles: () async -> [String]?) async -> HermesShareOpening? {
        guard let named = sharedImport.shortcut?.profile else { return .chat(chat) }
        guard let profiles = await readProfiles(), !profiles.isEmpty else { return nil }
        return profiles.contains(named) ? .chat(chat) : .missingProfile(named)
    }

    @MainActor func transfer(into chat: HermesSessionChat, drafts: ChatDraftStore = .shared,
                             route: (Self) -> Void) async throws {
        try await moveIntoDraft(of: chat, drafts: drafts)
        route(self)
    }

    @MainActor func moveIntoDraft(of chat: HermesSessionChat, drafts: ChatDraftStore = .shared) async throws {
        let key = chat.target.draftKey(server: chat.server, connectionID: chat.connection.id, lineageRoot: chat.lineageRoot)
        let draft = await drafts.draft(for: key)
        var files: [(data: Data, name: String, mime: String, image: Bool)] = []
        if draft?.sharedImportIDs.contains(occurrenceID) != true {
            let staged = draft?.attachments ?? []
            var room = HermexAttachmentPickerPolicy.maximumBotAttachments - staged.count
            var bytes = staged.reduce(0) { $0 + ($1.size ?? BotAttachmentUpload.maximumFileBytes) }
            for attachment in sharedImport.attachments {
                let prepared: (data: Data, name: String, mime: String, image: Bool)
                do {
                    prepared = try await Task.detached {
                        try BotAttachmentUpload.prepare(data: attachment.data, filename: attachment.filename)
                    }.value
                } catch {
                    throw error as? BotAttachmentFailure ?? .unreadable
                }
                guard room > 0, prepared.data.count <= BotAttachmentUpload.maximumFileBytes,
                      bytes + prepared.data.count <= BotAttachmentUpload.maximumTotalBytes else {
                    throw BotAttachmentFailure.limit
                }
                room -= 1
                bytes += prepared.data.count
                files.append(prepared)
            }
            try Task.checkCancellation()
        }
        let text = sharedImport.shortcut == nil ? HermesShareDraft.composerDraft(from: sharedImport.draft) : sharedImport.draft
        try await drafts.appendShare(occurrenceID, text: text, files: files, to: key,
                                     maximumFileBytes: BotAttachmentUpload.maximumFileBytes,
                                     origin: sharedImport.shortcut?.origin) { attachments in
            guard attachments.count <= HermexAttachmentPickerPolicy.maximumBotAttachments,
                  attachments.reduce(0, { $0 + ($1.size ?? BotAttachmentUpload.maximumFileBytes) })
                    <= BotAttachmentUpload.maximumTotalBytes else { throw BotAttachmentFailure.limit }
        }
    }
}

struct HermesShareFailure {
    let share: SharedImportReservation
    let reason: String

    init(share: SharedImportReservation, reason: String) {
        self.share = share
        self.reason = reason
    }

    init(share: SharedImportReservation, error: Error) {
        self.share = share
        switch error {
        case BotAttachmentFailure.limit, ChatDraftStorageError.attachmentLimit:
            reason = String(localized: "You can attach up to 8 files per message, 25 MB each and 50 MB total. Share fewer or smaller files and try again.")
        case BotAttachmentFailure.unreadable:
            reason = String(localized: "One of the files couldn’t be read.")
        default:
            reason = String(localized: "Hermex couldn’t save the files on this iPhone.")
        }
    }
}

private struct NewChatReadiness: Equatable {
    let request: HermesNewChatDestination?
    let share: String?
    let profile: String?
    let isLive: Bool
    let isTransferringShare: Bool
}

private struct UsageReadiness: Equatable {
    let link: HermesUsageDestination?
    let isLive: Bool
}

private struct RatingCheck: Hashable {
    let request: UUID?
    let isLive: Bool
}

private struct SearchScope: Hashable {
    let profile: String?
    let showsAll: Bool
    let text: String
    let showingScheduled: Bool
}

private struct ProfileScope: Equatable {
    let profile: String?
    let showsAll: Bool
}

private struct HermesStatusFilterSection: View {
    let viewModel: SessionListViewModel
    let selectedProjectID: String?
    let automatedVisibility: AutomatedSessionVisibility
    let statusFilter: HermesSessionStatusFilter
    let pick: (HermesSessionStatusFilter) -> Void
    let markAll: ([SessionSummary]) -> Void

    var body: some View {
        let unread = viewModel.unreadRowsInScope(selectedProjectID: selectedProjectID, automatedVisibility: automatedVisibility)
        Section {
            ForEach(HermesSessionStatusFilter.choices, id: \.self) { status in
                Toggle(isOn: Binding(get: { statusFilter == status }, set: { _ in pick(status) })) {
                    Text(verbatim: status.title)
                }
            }
            Button("Mark \(unread.count) Chats as Read", systemImage: "checkmark.circle") { markAll(unread) }
                .disabled(unread.isEmpty || viewModel.isMarkingAllRead)
        }
    }
}

private struct DraftRead: Hashable {
    let filter: HermesSessionStatusFilter
    let chatCloses: Int
}

private struct HomeHeaderScroll: ViewModifier {
    static let headerID = "home-header"
    let requests: Int

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: requests) { proxy.scrollTo(Self.headerID, anchor: .top) }
        }
    }
}

private struct HermesSessionListChrome<ProfileMenu: View, Filter: View, NewSession: View>: ViewModifier {
    let home: HermesHome?
    @Binding var searchText: String
    @Binding var isSearchPresented: Bool
    let connection: HomeConnectionStatus.Facts
    let reconnectNow: () -> Void
    let openSearch: () -> Void
    let profileMenu: ProfileMenu
    let filter: Filter
    let newSession: NewSession

    init(home: HermesHome?, searchText: Binding<String>, isSearchPresented: Binding<Bool>,
         connection: HomeConnectionStatus.Facts, reconnectNow: @escaping () -> Void,
         openSearch: @escaping () -> Void, @ViewBuilder profileMenu: () -> ProfileMenu, @ViewBuilder filter: () -> Filter,
         @ViewBuilder newSession: () -> NewSession) {
        self.home = home; _searchText = searchText; _isSearchPresented = isSearchPresented
        self.connection = connection; self.reconnectNow = reconnectNow; self.openSearch = openSearch
        self.profileMenu = profileMenu(); self.filter = filter(); self.newSession = newSession()
    }

    func body(content: Content) -> some View {
        if let home {
            content.modifier(HermesHomeChrome(home: home, search: HermesHomeSearch(label: "Search sessions", open: openSearch),
                                               filter: { filter }, newChat: { newSession }))
        } else {
            content
                .searchable(text: $searchText, isPresented: $isSearchPresented,
                            placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .themedPageBackground()
                .navigationTitle("Sessions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        SessionsToolbarTitle(connection: connection, reconnectNow: reconnectNow)
                    }
                    ToolbarItem(placement: .topBarTrailing) { profileMenu }
                    ToolbarItem(placement: .topBarTrailing) { newSession }
                }
        }
    }
}

private struct SessionsToolbarTitle: View {
    let connection: HomeConnectionStatus.Facts
    let reconnectNow: () -> Void
    @State private var connectionStatus = DelayedStatusDriver<HomeConnectionStatus>()

    var body: some View {
        VStack(spacing: 0) {
            Text("Sessions").font(AppFont.headline()).accessibilityAddTraits(.isHeader)
            HomeConnectionStatusLine(driver: connectionStatus, reconnectNow: reconnectNow)
        }
        .drivesHomeConnectionStatus(connectionStatus, connection: connection)
    }
}

enum HermesSessionStatusFilter: Equatable, CaseIterable {
    case all, working, unread, draft

    static let choices: [HermesSessionStatusFilter] = [.working, .unread, .draft]

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .working: return String(localized: "Working")
        case .unread: return String(localized: "Unread")
        case .draft: return String(localized: "Draft")
        }
    }
}

@Observable final class HermesSessionListNavigation {
    var covers: HermesSessionListCovers
    var selectedProjectID: String?
    var statusFilter = HermesSessionStatusFilter.all
    var searchText: String
    var isSearchExpanded = false

    init(_ covers: HermesSessionListCovers = HermesSessionListCovers(), searchText: String = "") {
        self.covers = covers
        self.searchText = searchText
    }
}

struct HermesSessionListCovers {
    var chat: HermesSessionChat? {
        didSet {
            guard chat?.id != oldValue?.id else { return }
            chatDraftKey = nil
            chatContinuity = ChatContinuity()
        }
    }
    private var chatDraftKey: ChatDraftKey?
    private(set) var chatContinuity = ChatContinuity()
    var renaming: SessionSummary?
    var deleting: SessionSummary?
    var exported: SessionExportShareItem?
    var showingScheduled = false
    var showingArchived = false
    var creatingProject: HermesProjectCreation?
    var renamingProject: ProjectSummary?
    var deletingProject: ProjectSummary?
    var moving: HermesProjectMove?
    var movingAfterCreation: HermesProjectMove?
    var tasks: HermesTasksEntry?
    var skills: HermesSkillsEntry?
    var memory: HermesMemoryEntry?
    var insights: HermesInsightsEntry?
    var showingKanban = false

    var isCoveredByScreen: Bool {
        showingScheduled || showingArchived || showingKanban || tasks != nil || skills != nil || memory != nil || insights != nil
    }

    func reopensOnForeground(usesSplit: Bool) -> Bool {
        usesSplit || (chat == nil && (showingScheduled || !isCoveredByScreen))
    }

    @MainActor func listDisappeared(_ list: SessionListViewModel) {
        if chat != nil { list.pauseHermes() } else if !showingScheduled { list.closeHermes() }
    }

    @MainActor func scheduledDisappeared(_ list: SessionListViewModel) {
        if chat != nil || showingScheduled { list.pauseHermes() }
    }

    var detailIdentity: String {
        let destination = chat?.id.uuidString ?? tasks?.id.uuidString ?? skills?.id.uuidString
            ?? memory?.id.uuidString ?? insights?.id.uuidString
            ?? (showingKanban ? "kanban" : showingScheduled ? "scheduled" : showingArchived ? "archived" : "empty")
        return "\(generation)|\(destination)"
    }

    private(set) var generation = 0

    mutating func accept(_ link: HermesSessionDestination?, on server: URL) {
        guard link?.server == server else { return }
        bringForward()
    }

    @MainActor mutating func open(_ request: HermesNewChatDestination?, on entry: HermesSessionListEntry, listed: String?,
                                  isLive: Bool) -> Bool {
        guard let request, request.server == entry.server else { return false }
        bringForward()
        guard let chat = request.chat(on: entry, listed: listed, isLive: isLive) else { return false }
        self.chat = chat
        return true
    }

    @MainActor mutating func open(_ share: SharedImportReservation, on entry: HermesSessionListEntry, listed: String?,
                                  isLive: Bool) -> HermesShareOpening? {
        bringForward()
        return share.hermesOpening(on: entry, listed: listed, isLive: isLive)
    }

    mutating func identifyChat(_ id: UUID, draftKey: ChatDraftKey) {
        guard let chat, chat.id == id, draftKey.serverID == chat.server.absoluteString,
              case .hermesSession(let connectionID, let profile, .some, _) = draftKey.context,
              connectionID == chat.connection.id, profile == chat.target.profile else { return }
        chatDraftKey = draftKey
    }

    func building(_ chat: HermesSessionChat) -> HermesSessionChat {
        guard chat.id == self.chat?.id, case .new(let profile, _, _) = chat.target,
              case .hermesSession(_, _, let key?, _)? = chatDraftKey?.context else { return chat }
        var named = chat
        named.target = .session(profile: profile, key: key)
        named.autoStartsVoiceInput = false
        return named
    }

    private var selectedSessionKey: String? {
        if case .hermesSession(_, _, let key, _)? = chatDraftKey?.context { return key }
        if case .session(_, let key)? = chat?.target { return key }
        return nil
    }

    var selectedSessionID: String? { chat?.lineageRoot ?? selectedSessionKey }

    mutating func closeChat(for row: SessionSummary) {
        guard let chat, let key = selectedSessionKey,
              row.profile == chat.target.profile,
              row.sessionId == key || row.hermes?.lineageRoot == (chat.lineageRoot ?? key) else { return }
        self.chat = nil
    }

    mutating func bringForward() {
        let next = generation + 1
        self = Self()
        generation = next
    }

    mutating func present(_ export: SessionExportShareItem, startedAt generation: Int) {
        if generation == self.generation { exported = export }
    }
}

struct HermesTasksEntry: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let client: HermesCronClient
    let newTaskProfile: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HermesSkillsEntry: Hashable, Identifiable {
    let id = UUID()
    let client: HermesSkillsClient

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HermesMemoryEntry: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let client: HermesMemoryClient

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HermesInsightsEntry: Hashable, Identifiable {
    let id = UUID()
    let client: HermesInsightsClient
    let limitsScope: ProviderLimitsPublisher.Scope

    @MainActor init(server: URL, connection: BotConnection, profile: String) {
        client = HermesInsightsClient(saved: connection, server: server, profile: profile)
        limitsScope = ProviderLimitsPublisher.Scope(server: server, connectionID: connection.id, profile: profile)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct HermesProjectCreation: Identifiable {
    let id = UUID()
    let folder: String
    var session: SessionSummary?

    func move(intoProjectNamed name: String, savedOn folder: String, isBusy: Bool) -> HermesProjectMove? {
        guard let session, session.workspace != folder else { return nil }
        return HermesProjectMove(session: session, projectName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 folder: folder, isBusy: isBusy)
    }
}

struct HermesProjectMove: Identifiable {
    let session: SessionSummary
    let projectName: String
    let folder: String
    let isBusy: Bool

    var id: String { session.id }
    var title: String { String(localized: "Move to \(projectName)?") }
    var message: String {
        isBusy
            ? String(localized: "Hermes will work in \(folder) from now on, including the reply that's running now. Files aren't moved.")
            : String(localized: "Hermes will work in \(folder) from now on. Files aren't moved.")
    }
}

extension SessionSummary {
    func hermesTarget(listedIn profile: String) -> ConversationTarget? {
        guard hermes != nil, let key = sessionId, !key.isEmpty else { return nil }
        return .session(profile: self.profile.flatMap { $0.isEmpty ? nil : $0 } ?? profile, key: key)
    }

    func hermesChat(on server: URL, connection: BotConnection, listedIn profile: String) -> HermesSessionChat? {
        hermesTarget(listedIn: profile).map {
            HermesSessionChat(server: server, connection: connection, target: $0, parentKey: parentSessionId,
                              botChatRoot: hermes?.botChatRoot, lineageRoot: hermes?.lineageRoot,
                              title: MessageAttachment.hermesTitle(title), workspace: workspace, model: model)
        }
    }

    func hermesBot(on server: URL, connectionID: UUID) -> BotDestination? {
        guard hermes?.isBotChat == true, let profile, !profile.isEmpty else { return nil }
        return BotDestination(server: server, connectionID: connectionID, profile: profile)
    }
}
