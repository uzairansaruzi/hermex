import SwiftUI

/// A Hermes server's Sessions list (#1046): the server, its saved connection, and the Profile the
/// list opens on, searching `query` when a chat's `/resume` opened it (#1053). The home's list
/// (#709) opens on no Profile, which takes the server's pick or the host's `current`.
struct HermesSessionListEntry: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let connection: BotConnection
    let profile: String?
    var query = ""

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A Hermes server's sessions in one Profile, or in every Profile with each row tagged (#709)
/// (#1046): the webui list's rows, live states and row menu, on a `SessionListViewModel` with a
/// Hermes backend. It is the Sessions side of the Hermes home (#709), where `home` gives it the
/// home's chrome and its Tasks, Kanban, Skills, Memory and Usage rows, or pushed from a chat's
/// `/sessions`; either way it sits on a stack it brings no navigation container to, and a row
/// opens in the main chat on top of it. Its socket listens while it is on screen, rests
/// while a chat covers it, and closes when it leaves or the app goes to the background. Rows
/// rename, pin, archive (with Undo and an Archived screen), delete and export as JSON (#1048), and
/// duplicate (#1051).
/// Its project rows are the host's folder-based project lanes (#1052): a pick filters the list to
/// one lane, and a row's Move to Project changes the session's working folder. Its search (#1053)
/// filters the loaded rows at once and then adds the host's matches, which reach past the loaded
/// pages; a bot's Bot Chat among them opens in that bot. Every page it reads goes to the offline
/// cache, which it shows, read-only under the offline banner, while the host can't be reached (#1054).
struct HermesSessionListView: View {

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsWorkspace = true
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SectionVisibilitySettings.tasksKey) private var showsTasks = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) private var showsKanban = true
    @AppStorage(SectionVisibilitySettings.skillsKey) private var showsSkills = true
    @AppStorage(SectionVisibilitySettings.memoryKey) private var showsMemory = true
    @AppStorage(SectionVisibilitySettings.insightsKey) private var showsInsights = true
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    private let entry: HermesSessionListEntry
    private let home: HermesHome?
    @State private var viewModel: SessionListViewModel
    /// The chat a row or New Session opened.
    @State private var chat: HermesSessionChat?
    @State private var renaming: SessionSummary?
    @State private var deleting: SessionSummary?
    @State private var exported: SessionExportShareItem?
    @State private var showingArchived = false
    @State private var actionToast = ActionToastState()
    /// The project lane the list shows; nil shows every session.
    @State private var selectedProjectID: String?
    @State private var creatingProject: HermesProjectCreation?
    @State private var renamingProject: ProjectSummary?
    @State private var deletingProject: ProjectSummary?
    @State private var moving: HermesProjectMove?
    /// The Move to Project a project created from a row's Move menu still needs, asked once the
    /// sheet is gone.
    @State private var movingAfterCreation: HermesProjectMove?
    @State private var searchText: String
    /// The home's header has grown its search pill into a field (`SessionsHeader`).
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFieldFocused: Bool
    /// The Tasks, Skills, Memory or Usage screen a home row pushed, and whether Kanban is pushed.
    @State private var tasks: HermesTasksEntry?
    @State private var skills: HermesSkillsEntry?
    @State private var memory: HermesMemoryEntry?
    @State private var insights: HermesInsightsEntry?
    @State private var showingKanban = false

    /// The list a chat's `/sessions` pushed.
    init(entry: HermesSessionListEntry) {
        self.init(entry: entry, model: Self.model(for: entry), home: nil)
    }

    /// The Sessions side of the Hermes home, on a `model` the home keeps across its switch, so a
    /// switch back shows the last rows at once (#709).
    init(entry: HermesSessionListEntry, model: SessionListViewModel, home: HermesHome?) {
        self.entry = entry
        self.home = home
        _searchText = State(initialValue: entry.query)
        _viewModel = State(initialValue: model)
    }

    /// The list's view model, reading `entry`'s server through its saved connection.
    static func model(for entry: HermesSessionListEntry) -> SessionListViewModel {
        let server = entry.server
        return SessionListViewModel(server: server, hermes: HermesSessionListSource(
            connection: entry.connection, profile: entry.profile, makeWire: { BotClient(saved: $0, server: server) }
        ))
    }

    var body: some View {
        List {
            if let home {
                SessionsHeader(
                    logoColor: HeaderLogoColor.color(for: headerLogoColorHex), avatar: home.avatar,
                    field: SessionsHeader.Field(isExpanded: isSearchExpanded, text: $searchText,
                                                isFocused: $isSearchFieldFocused, close: closeSearch),
                    openSearch: openSearch
                )
                .sessionsTopChromeListRow()
            }
            if viewModel.isViewingCachedData {
                OfflineCacheBanner()
                    .padding(.top, 16)
                    .sessionsScreenListRow()
            }
            SessionSidebarUtilityRows(
                viewModel: viewModel, topPadding: 10, automatedVisibility: .showAll, sectionVisibility: sectionVisibility,
                profilesAreExpanded: .constant(false), projectsAreExpanded: $projectsAreExpanded,
                selectedProjectID: $selectedProjectID, projectPendingDeletion: $deletingProject,
                projectPendingRename: $renamingProject, openDestination: open, switchActiveProfile: { _ in },
                presentProjectCreation: { creatingProject = HermesProjectCreation(folder: "") }
            )
            SessionListRowsSection(
                viewModel: viewModel,
                searchText: searchText,
                sessions: viewModel.visibleSessions(searchText: searchText, selectedProjectID: selectedProjectID),
                emptyTitle: emptyTitle,
                emptyDescription: isSearching ? String(localized: "Try another search or project filter.") : nil,
                isSearchActive: false,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                selectedSessionID: nil,
                actions: actions
            )
            // A search reads the host's whole list, so it pages nothing in.
            if showsLoadMore && !isSearching { loadMoreRow }
            // The cache holds no archived rows to show, and the Archived screen lists one Profile.
            if !viewModel.isViewingCachedData && !viewModel.hermesShowsAllProfiles { archivedRow }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: projectsAreExpanded)
        .overlay(alignment: .bottom) {
            ActionToastView(state: actionToast)
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .refreshable { await viewModel.refreshHermes(modelContext: modelContext) }
        // Debounced inside; a new query or Profile cancels the search in flight.
        .task(id: SearchScope(profile: profile, showsAll: viewModel.hermesShowsAllProfiles, text: searchText)) {
            await viewModel.searchSessions(query: searchText)
        }
        .modifier(chrome)
        // Keyed by the chat, so a Profile picked in an empty chat replaces its screen (#1015).
        .navigationDestination(item: $chat) { chat in
            // `/sessions` and `/resume` in the chat come back here, in the chat's Profile, searching
            // what they name.
            ChatView(hermesSession: chat, onReplace: { self.chat = $0 }, onOpenSessions: { opened in
                self.chat = nil
                if let listed = opened.profile, listed != profile || viewModel.hermesShowsAllProfiles {
                    Task { await viewModel.selectHermesProfile(listed) }
                }
                searchText = opened.query
                if !opened.query.isEmpty && home != nil { isSearchExpanded = true }
            })
            .id(chat.id)
        }
        .navigationDestination(isPresented: $showingArchived) {
            if let profile {
                ArchivedSessionsView(server: entry.server, hermes: .saved(entry.connection, server: entry.server, profile: profile))
            }
        }
        .navigationDestination(item: $tasks) { entry in
            TasksView(server: entry.server, onAPIError: { _ in }, client: entry.client, newTaskProfile: entry.newTaskProfile)
                .id(entry.id)
        }
        .navigationDestination(item: $skills) { entry in
            SkillsView(client: entry.client, profile: entry.client.profile, onAPIError: { _ in })
                .id(entry.id)
        }
        .navigationDestination(item: $memory) { entry in
            MemoryView(server: entry.server, client: entry.client, profile: entry.client.profile, onAPIError: { _ in })
                .id(entry.id)
        }
        .navigationDestination(item: $insights) { entry in
            InsightsView(client: entry.client, profile: entry.client.profile, onAPIError: { _ in })
                .id(entry.id)
        }
        .navigationDestination(isPresented: $showingKanban) {
            KanbanView(server: entry.server, hermes: HermesConnections.shared.connection(for: entry.connection, server: entry.server))
        }
        .sheet(item: $renaming, onDismiss: { viewModel.clearRenameError() }) { session in
            SessionRenameSheet(initialTitle: SessionRowView.displayTitle(for: session), isSaving: viewModel.isRenamingSession,
                               errorMessage: viewModel.renameErrorMessage) {
                renaming = nil
            } onSave: { title in
                Task { if await rename(session, to: title) { renaming = nil } }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $exported) { item in
            SessionExportShareSheet(fileURL: item.fileURL)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
                // Each export has its own temp directory (`SessionListViewModel.export`).
                .onDisappear { try? FileManager.default.removeItem(at: item.fileURL.deletingLastPathComponent()) }
        }
        .sheet(item: $creatingProject, onDismiss: {
            viewModel.clearProjectSheetError()
            moving = movingAfterCreation
            movingAfterCreation = nil
        }) { creation in
            ProjectCreationSheet(
                existingProjectCount: viewModel.projects.count, isSaving: viewModel.isCreatingProject,
                folder: ProjectFolderField(initialPath: creation.folder) { await viewModel.completeHermesFolder($0) },
                errorMessage: viewModel.projectSheetErrorMessage
            ) {
                creatingProject = nil
            } onSave: { name, color, folder in
                Task {
                    guard let saved = await viewModel.createHermesProject(named: name, color: color, folder: folder ?? "") else { return }
                    movingAfterCreation = creation.move(intoProjectNamed: name, savedOn: saved, isBusy: creation.session
                        .map { viewModel.attentionState(for: $0) != nil } ?? false)
                    creatingProject = nil
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $renamingProject, onDismiss: { viewModel.clearProjectSheetError() }) { project in
            ProjectRenameSheet(project: project, isSaving: viewModel.isRenamingProject,
                               errorMessage: viewModel.projectSheetErrorMessage) {
                renamingProject = nil
            } onSave: { name, color in
                Task { if await viewModel.rename(project, named: name, color: color) { renamingProject = nil } }
            }
            .presentationDetents([.medium])
        }
        .alert(Text(verbatim: moving?.title ?? ""), isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
               presenting: moving) { move in
            Button("Cancel", role: .cancel) {}
            Button("Move") { Task { await self.move(move) } }
        } message: { move in
            Text(verbatim: move.message)
        }
        .modifier(SessionActionConfirmations(
            viewModel: viewModel, sessionPendingDeletion: $deleting, projectPendingDeletion: $deletingProject,
            deleteSession: { session in Task { await delete(session) } },
            deleteProject: { project in Task { _ = await viewModel.delete(project) } }
        ))
        .task { await viewModel.openHermes(modelContext: modelContext) }
        .onDisappear {
            actionToast.dismiss()
            if chat == nil { viewModel.closeHermes() } else { viewModel.pauseHermes() }
        }
        // A lane the host no longer lists (deleted here or on Desktop, or another Profile's) clears.
        .onChange(of: viewModel.projects) {
            if let selectedProjectID, !viewModel.projects.contains(where: { $0.projectId == selectedProjectID }) {
                self.selectedProjectID = nil
            }
        }
        .onChange(of: chat) { old, new in
            if case .session(_, let key)? = old?.target, new?.id != old?.id { viewModel.noteHermesReturn(from: key) }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background: viewModel.closeHermes()
            // Control Center and banners (`.inactive`) keep the socket; only a closed list reopens.
            case .active where chat == nil && !isCoveredByScreen && !viewModel.isHermesConnected:
                Task { await viewModel.openHermes(modelContext: modelContext) }
            default: break
            }
        }
    }

    /// The listed Profile, and the one New Session opens in; nil until a home list without a
    /// pick has asked the host.
    private var profile: String? { viewModel.hermesProfile ?? entry.profile }

    /// A screen this list pushed covers it, so the socket stays closed until it returns.
    private var isCoveredByScreen: Bool {
        showingArchived || showingKanban || tasks != nil || skills != nil || memory != nil || insights != nil
    }

    /// The home's Tasks, Kanban, Skills, Memory and Usage rows, as Settings shows them (#709), and
    /// the project lanes of the one listed Profile. A search drops the links but keeps the lanes,
    /// so the lane it searches in stays in view and can change.
    private var sectionVisibility: SidebarSectionVisibility {
        let isHome = home != nil && !isSearchExpanded
        return SidebarSectionVisibility(
            bots: false, tasks: isHome && showsTasks, kanban: isHome && showsKanban, skills: isHome && showsSkills,
            memory: isHome && showsMemory, insights: isHome && showsInsights, activeProfile: false,
            projects: !viewModel.hermesShowsAllProfiles
        )
    }

    /// Pushes a home row's screen: Tasks, Skills, Memory and Usage on the listed Profile (the one
    /// New Session opens in, on a list of every Profile), Kanban for the whole host.
    private func open(_ destination: SessionListUtilityDestination) {
        let server = entry.server, connection = entry.connection
        if destination == .kanban { showingKanban = true; return }
        guard let profile else { return }
        switch destination {
        case .tasks:
            tasks = HermesTasksEntry(server: server, client: HermesCronClient(saved: connection, server: server), newTaskProfile: profile)
        case .skills:
            skills = HermesSkillsEntry(client: HermesSkillsClient(saved: connection, server: server, profile: profile))
        case .memory:
            memory = HermesMemoryEntry(server: server, client: HermesMemoryClient(saved: connection, server: server, profile: profile))
        case .insights:
            insights = HermesInsightsEntry(client: HermesInsightsClient(saved: connection, server: server, profile: profile))
        default:
            break
        }
    }

    /// The home's chrome, or the pushed list's own title and toolbar.
    private var chrome: some ViewModifier {
        HermesSessionListChrome(home: home, searchText: $searchText, profileMenu: { profileMenu },
                                filter: { profileFilter }, newSession: { newSessionButton })
    }

    private func openSearch() {
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) { isSearchExpanded = true }
        isSearchFieldFocused = true
    }

    private func closeSearch() {
        searchText = ""
        isSearchFieldFocused = false
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) { isSearchExpanded = false }
    }

    private var newSessionButton: some View {
        Button("New Session", systemImage: "square.and.pencil") {
            guard let profile else { return }
            chat = HermesSessionChat(server: entry.server, connection: entry.connection, target: .new(profile: profile))
        }
        .disabled(viewModel.isViewingCachedData || profile == nil)
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var emptyTitle: String {
        if isSearching { return String(localized: "No matching sessions") }
        return selectedProjectID == nil ? String(localized: "No sessions yet") : String(localized: "No sessions in this project")
    }

    /// The pushed list's Profile menu, named for what it lists.
    private var profileMenu: some View {
        Menu {
            profilePicker
        } label: {
            // A Profile name is the user's own text, never a catalog key.
            if viewModel.hermesShowsAllProfiles {
                Text("All Profiles").lineLimit(1)
            } else {
                Text(verbatim: profile ?? "").lineLimit(1)
                    .accessibilityLabel(Text("Profile: \(profile ?? "")"))
            }
        }
    }

    /// The home's filter button, which holds the same picker.
    private var profileFilter: some View {
        Menu {
            profilePicker
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityValue(viewModel.hermesShowsAllProfiles ? Text("All Profiles") : Text(verbatim: profile ?? ""))
    }

    /// Every Profile's sessions, each row tagged with its Profile (#709), or one Profile's. Picking
    /// a Profile lists it and makes it the server's pick, which the composer's Profile chip shares
    /// (#1015); All Profiles keeps the pick for New Session.
    private var profilePicker: some View {
        let listed = viewModel.hermesProfiles.isEmpty ? [profile].compactMap(\.self) : viewModel.hermesProfiles
        return Picker("Profile", selection: Binding<String?>(get: { viewModel.hermesShowsAllProfiles ? nil : profile }, set: { picked in
            Task {
                if let picked { await viewModel.selectHermesProfile(picked) } else { await viewModel.showAllHermesProfiles() }
            }
        })) {
            Text("All Profiles").tag(String?.none)
            ForEach(listed, id: \.self) {
                Text(verbatim: $0).tag(Optional($0))
            }
        }
        .disabled(profile == nil)
    }

    /// More pages may hold rows this list shows: any, or the selected lane's that the host
    /// named and the loaded pages lack.
    private var showsLoadMore: Bool {
        guard viewModel.hasMoreSessions else { return false }
        return selectedProjectID.map(viewModel.hermesLaneIsShort) ?? true
    }

    /// The list's end: the next page loads as it comes into view, or in a lane every page
    /// until the lane is whole, and a tap tries again after a failed one. Keyed by the lane,
    /// so picking another lane loads its pages too. A lane picked while another page was
    /// loading starts its own once that page's rows are in; a failed page changes no rows, so
    /// it never retries on its own.
    private var loadMoreRow: some View {
        Button("Load more") { Task { await loadMore() } }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .disabled(viewModel.isLoadingMoreSessions)
            .frame(maxWidth: .infinity, minHeight: 44)
            .sessionsScreenListRow()
            .onAppear { Task { await loadMore() } }
            .onChange(of: viewModel.sessions.count) {
                guard let selectedProjectID else { return }
                Task { await viewModel.fillHermesLane(selectedProjectID) }
            }
            .id(selectedProjectID)
    }

    private func loadMore() async {
        if let selectedProjectID { await viewModel.fillHermesLane(selectedProjectID) }
        else { await viewModel.loadMoreHermesSessions() }
    }

    /// The Profile's archived sessions, hidden Bot Chats included, where they are restored.
    private var archivedRow: some View {
        Button {
            showingArchived = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Archived Sessions")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityHint("Shows archived sessions.")
        .sessionsScreenListRow()
    }

    /// Opening a row, Mark as Read or Unread, and the row actions `SessionRowActionPolicy`
    /// offers a Hermes row; Duplicate opens the copy (#1051). Move to Project asks first,
    /// and its New Project starts on the session's folder, then asks to move it there if it
    /// was saved on another. A bot's Bot Chat, which only a search lists, opens in that bot
    /// through the app's bot route, as a notification's tap does (#1053).
    private var actions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: { Task { await viewModel.openHermes(modelContext: modelContext) } },
            open: { session in
                if let bot = session.hermesBot(on: entry.server, connectionID: entry.connection.id) {
                    AppIntentRouter.shared.requestDeepLink(HermesDeepLink.botURL(for: bot))
                    return
                }
                // A row of every Profile's cache, before the host settled one, opens in its own.
                guard let listed = profile ?? session.profile,
                      let opened = session.hermesChat(on: entry.server, connection: entry.connection, listedIn: listed) else { return }
                viewModel.beginViewing(session)
                chat = opened
            },
            toggleUnread: { viewModel.toggleUnread($0) },
            togglePinned: { session in Task { await togglePinned(session) } },
            archive: { session in Task { await archive(session) } },
            delete: { deleting = $0 },
            rename: { session in
                viewModel.clearRenameError()
                renaming = session
            },
            duplicate: { session in Task { await duplicate(session) } },
            move: { session, projectID in
                guard let project = viewModel.projects.first(where: { $0.projectId == projectID }),
                      let folder = project.hermes?.folder else { return }
                moving = HermesProjectMove(session: session, projectName: project.name ?? folder, folder: folder,
                                           isBusy: viewModel.attentionState(for: session) != nil)
            },
            createProject: { session in creatingProject = HermesProjectCreation(folder: session.workspace ?? "", session: session) },
            refreshProjects: { Task { await viewModel.openHermes(modelContext: modelContext) } },
            export: { session, format in
                Task { if let url = await viewModel.export(session, format: format) { exported = SessionExportShareItem(fileURL: url) } }
            }
        )
    }

    private var mutationAnimation: Animation? { SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion) }

    private func togglePinned(_ session: SessionSummary) async {
        if await viewModel.setPinned(session.pinned != true, for: session, animation: mutationAnimation) {
            SessionHaptics.pinStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    /// "Archived · Undo" once the host confirms (#865); Undo restores the row in place.
    private func archive(_ session: SessionSummary) async {
        guard await viewModel.archive(session, animation: mutationAnimation) else { return }
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

    /// "Moved · Undo" once the host confirms; Undo moves the session back to the folder it left.
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

    /// Opens the copy once the host has it (#1051).
    private func duplicate(_ session: SessionSummary) async {
        guard let profile, let copy = await viewModel.duplicate(session),
              let opened = copy.hermesChat(on: entry.server, connection: entry.connection, listedIn: profile) else { return }
        chat = opened
    }

    private func delete(_ session: SessionSummary) async {
        if await viewModel.delete(session, animation: mutationAnimation) {
            SessionHaptics.sessionDeleted(isEnabled: isHapticsEnabled)
        }
    }

    private func rename(_ session: SessionSummary, to title: String) async -> Bool {
        let renamed = await viewModel.rename(session, to: title)
        if renamed, title != session.title { SessionHaptics.sessionRenamed(isEnabled: isHapticsEnabled) }
        return renamed
    }
}

/// What a search runs against: a new query, Profile or All Profiles cancels the one in flight.
private struct SearchScope: Hashable {
    let profile: String?
    let showsAll: Bool
    let text: String
}

/// The Sessions list's title and toolbar. As the Hermes home's Sessions side it takes the home's
/// bar, with the Profile filter and New Session at its ends, and searches from its header; pushed,
/// it is titled "Sessions" with its Profile menu and New Session at the top right and a search
/// field under them.
private struct HermesSessionListChrome<ProfileMenu: View, Filter: View, NewSession: View>: ViewModifier {
    let home: HermesHome?
    @Binding var searchText: String
    let profileMenu: ProfileMenu
    let filter: Filter
    let newSession: NewSession

    init(home: HermesHome?, searchText: Binding<String>, @ViewBuilder profileMenu: () -> ProfileMenu,
         @ViewBuilder filter: () -> Filter, @ViewBuilder newSession: () -> NewSession) {
        self.home = home; _searchText = searchText; self.profileMenu = profileMenu(); self.filter = filter()
        self.newSession = newSession()
    }

    func body(content: Content) -> some View {
        if let home {
            content.modifier(HermesHomeChrome(home: home, filter: { filter }, newChat: { newSession }))
        } else {
            content
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .navigationTitle("Sessions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { profileMenu }
                    ToolbarItem(placement: .topBarTrailing) { newSession }
                }
        }
    }
}

/// The Tasks screen a home row pushed on a Hermes host (#1040, #709), with the client it reads
/// through and the Profile a new Task starts in.
struct HermesTasksEntry: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let client: HermesCronClient
    let newTaskProfile: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The Skills screen a home row pushed on a Hermes host (#1069, #709), with the client for the
/// Profile it lists.
struct HermesSkillsEntry: Hashable, Identifiable {
    let id = UUID()
    let client: HermesSkillsClient

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The Memory screen a home row pushed on a Hermes host (#1073, #709), with the client it reads
/// the Profile's memory through.
struct HermesMemoryEntry: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let client: HermesMemoryClient

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The Usage screen a home row pushed on a Hermes host (#1074, #709), with the client for the
/// Profile it reads.
struct HermesInsightsEntry: Hashable, Identifiable {
    let id = UUID()
    let client: HermesInsightsClient

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A project sheet opened for a new Hermes project (#1052), on `folder` (the session's own when
/// it came from a row's Move menu).
struct HermesProjectCreation: Identifiable {
    let id = UUID()
    let folder: String
    /// The session whose Move menu opened the sheet; nil from the list's New Project.
    var session: SessionSummary?

    /// The Move to Project that puts `session` in the project just saved on `folder`, which asks
    /// first as any other does. Nil from the list's New Project, or when the session works in
    /// `folder` itself, which makes it the project's. A session under `folder` is asked too: a
    /// project on a deeper folder may still claim it.
    func move(intoProjectNamed name: String, savedOn folder: String, isBusy: Bool) -> HermesProjectMove? {
        guard let session, session.workspace != folder else { return nil }
        return HermesProjectMove(session: session, projectName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 folder: folder, isBusy: isBusy)
    }
}

/// A Move to Project waiting on its confirmation (#1052), with copy that says what it does: Hermes
/// works in the project's folder from then on, and no file moves. A busy session moves mid-turn.
struct HermesProjectMove: Identifiable {
    let session: SessionSummary
    let projectName: String
    let folder: String
    /// A reply runs, or waits on an answer, in the session.
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
    /// The Hermes session this row opens (#1046): its own `id`, which on a legacy compression
    /// chain is the tip, in the row's Profile, else the listed one. Nil for a webui row.
    func hermesTarget(listedIn profile: String) -> ConversationTarget? {
        guard hermes != nil, let key = sessionId, !key.isEmpty else { return nil }
        return .session(profile: self.profile.flatMap { $0.isEmpty ? nil : $0 } ?? profile, key: key)
    }

    /// The chat this Hermes row opens on `connection`, carrying the parent the row names, so a
    /// branch shows its "Forked from" row (#1051). Nil for a webui row.
    func hermesChat(on server: URL, connection: BotConnection, listedIn profile: String) -> HermesSessionChat? {
        hermesTarget(listedIn: profile).map {
            HermesSessionChat(server: server, connection: connection, target: $0, parentKey: parentSessionId)
        }
    }

    /// The bot whose Bot Chat this row is (#1053): the Sessions list opens it there, so one chat
    /// never has two screens and two read marks. Nil for any other row.
    func hermesBot(on server: URL, connectionID: UUID) -> BotDestination? {
        guard hermes?.isBotChat == true, let profile, !profile.isEmpty else { return nil }
        return BotDestination(server: server, connectionID: connectionID, profile: profile)
    }
}
