import SwiftUI
import SwiftData
import UIKit
import StoreKit

struct SessionListForegroundRefresh: Equatable {
    private(set) var isPending = false

    mutating func appReturned(didCompleteInitialLoad: Bool, isLoading: Bool) -> Bool {
        isPending = true
        return consumeIfReady(didCompleteInitialLoad: didCompleteInitialLoad, isLoading: isLoading)
    }

    mutating func consumeIfReady(didCompleteInitialLoad: Bool, isLoading: Bool) -> Bool {
        guard isPending, didCompleteInitialLoad, !isLoading else { return false }
        isPending = false
        return true
    }
}

struct SessionListArchiveToastRoute: Equatable {
    enum Host: Equatable {
        case list
        case scheduled
    }

    private(set) var host = Host.list
    private var startedCount = 0
    private var newestShown = 0

    mutating func archiveStarted() -> Int {
        startedCount += 1
        return startedCount
    }

    mutating func archiveConfirmed(
        _ number: Int,
        swipedOn: Host,
        destination: SessionNavigationDestination?,
        isRegularWidth: Bool
    ) -> Host? {
        guard number > newestShown else { return nil }

        func isShowing(_ candidate: Host) -> Bool {
            switch candidate {
            case .list:
                return isRegularWidth || destination == nil
            case .scheduled:
                return destination == .utility(.scheduled)
            }
        }

        let otherHost: Host = swipedOn == .list ? .scheduled : .list
        guard let chosen = [swipedOn, otherHost].first(where: isShowing) else { return nil }
        newestShown = number
        host = chosen
        return chosen
    }

    mutating func noticeShown(destination: SessionNavigationDestination?) {
        host = destination == .utility(.scheduled) ? .scheduled : .list
    }
}

@MainActor
struct SessionListView: View {

    @Bindable var authManager: AuthManager
    let server: URL
    private let draftStore: ChatDraftStore
    @Binding private var pendingSharedImport: SharedImportReservation?
    private let didRoutePendingSharedImport: (SharedImportReservation) -> Void
    private let hasWaitingSharedImport: Bool
    private let openNextSharedImport: () -> Void
    @Binding private var pendingDeepLinkedSessionID: String?
    @Binding private var requestedNewChat: NewChatRequest?
    @Binding private var pendingBotDestination: BotDestination?
    @Binding private var pendingWebuiPush: WebuiPushDestination?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var wasBackgrounded = false
    @State private var foregroundRefresh = SessionListForegroundRefresh()
    @State private var ratingRequestID: UUID?
    @State private var ratingMoment: RatingPromptMoment = .coldLaunch
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var viewModel: SessionListViewModel
    @State private var navigationState: SessionNavigationState
    @State private var sessionPendingRename: SessionSummary?
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingProjectCreation: SessionSummary?
    @State private var sessionOpenTask: Task<Void, Never>?
    @State private var openingSignpostSessionID: String?
    @State private var sessionExportShareItem: SessionExportShareItem?
    @State private var isPresentingProjectCreation = false
    @State private var isPresentingAddServer = false
    @State private var projectPendingDeletion: ProjectSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var isSearchFocused = false
    @State private var searchChromeIsExpanded = false
    @State private var selectedProjectID: String?
    @State private var sidebarScrollPosition: String?
    @State private var didCompleteInitialLoad = false
    @State private var returnRefreshID: UUID?
    @State private var opensNotificationSettingsOnReturn = false
    @State private var actionToast = ActionToastState()
    @State private var archiveToastRoute = SessionListArchiveToastRoute()
    @FocusState private var searchFieldIsFocused: Bool
    @AppStorage(SessionSidebarDisclosureSettings.profilesAreExpandedKey)
    private var profilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.scheduledSessionsAreExpandedKey)
    private var scheduledSessionsAreExpanded = SessionSidebarDisclosureSettings.defaultScheduledSessionsAreExpanded
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) private var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @AppStorage(SectionVisibilitySettings.tasksKey) private var showsTasksSection = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) private var showsKanbanSection = true
    @AppStorage(SectionVisibilitySettings.skillsKey) private var showsSkillsSection = true
    @AppStorage(SectionVisibilitySettings.memoryKey) private var showsMemorySection = true
    @AppStorage(SectionVisibilitySettings.insightsKey) private var showsInsightsSection = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey) private var showsActiveProfileSection = true
    @AppStorage(SectionVisibilitySettings.projectsKey) private var showsProjectsSection = true
    @AppStorage private var showsCliSessions: Bool
    @AppStorage private var showsClaudeCodeSessions: Bool
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(AppAppearanceSettings.accentHexKey) private var accentHex: String?
    @AppStorage(GlassPreference.isEnabledKey) private var isGlassEnabled = GlassPreference.defaultIsEnabled
    @AppStorage(SessionIdentitySettings.displayNameKey) private var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) private var identityInitials = ""
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(BotModeGate.isEnabledKey) private var isBotModeEnabled = false

    init(
        authManager: AuthManager,
        server: URL,
        pendingSharedImport: Binding<SharedImportReservation?> = .constant(nil),
        didRoutePendingSharedImport: @escaping (SharedImportReservation) -> Void = { _ in },
        hasWaitingSharedImport: Bool = false,
        openNextSharedImport: @escaping () -> Void = {},
        pendingDeepLinkedSessionID: Binding<String?> = .constant(nil),
        requestedNewChat: Binding<NewChatRequest?> = .constant(nil),
        pendingBotDestination: Binding<BotDestination?> = .constant(nil),
        pendingWebuiPush: Binding<WebuiPushDestination?> = .constant(nil),
        draftStore: ChatDraftStore? = nil
    ) {
        self.authManager = authManager
        self.server = server
        _pendingSharedImport = pendingSharedImport
        self.didRoutePendingSharedImport = didRoutePendingSharedImport
        self.hasWaitingSharedImport = hasWaitingSharedImport
        self.openNextSharedImport = openNextSharedImport
        self.draftStore = draftStore ?? .shared
        _pendingDeepLinkedSessionID = pendingDeepLinkedSessionID
        _requestedNewChat = requestedNewChat
        _pendingBotDestination = pendingBotDestination
        _pendingWebuiPush = pendingWebuiPush
        _viewModel = State(initialValue: SessionListViewModel(server: server))
        _navigationState = State(
            initialValue: SessionNavigationState(
                lastSelectedSessionID: SessionNavigationPersistence.load(for: server)
            )
        )
        _showsCliSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsCliSessions(for: server),
            SessionRowDisplaySettings.showCliSessionsKey(for: server)
        )
        _showsClaudeCodeSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsClaudeCodeSessions(for: server),
            SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: server)
        )
    }

    var body: some View {
        routedNavigationContainer
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    wasBackgrounded = true
                }
                if phase == .active, wasBackgrounded {
                    wasBackgrounded = false
                    if foregroundRefresh.appReturned(
                        didCompleteInitialLoad: didCompleteInitialLoad,
                        isLoading: viewModel.isLoading
                    ) {
                        refreshAfterReturningIfNeeded()
                    }
                    ratingMoment = .foreground
                    ratingRequestID = UUID()
                } else if phase != .active {
                    ratingRequestID = nil
                }
            }
            .task(id: ratingRequestID) {
                guard ratingRequestID != nil else { return }
                await RatingPromptState.shared.requestWhenQuiet(
                    moment: ratingMoment,
                    server: server,
                    isSessionListVisible: {
                        if let card = SessionListCard.current(hasSharedImport: hasSharedImport), isQuietSessionListVisible {
                            RatingPromptState.shared.recordCardShown(card)
                        }
                        return isQuietSessionListVisible
                    },
                    loadSessions: { try await APIClient(baseURL: server).sessions(includeArchived: true).sessions },
                    request: { requestReview() }
                )
            }
            .onChange(of: isBotModeEnabled) {
                if !isBotModeEnabled, navigationState.destination == .utility(.bots) {
                    navigationState.clearDestination()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if hasWaitingSharedImport {
                    waitingSharedImportBanner
                }
            }
            .sheet(item: $sessionExportShareItem) { item in
                FileShareSheet(fileURL: item.fileURL)
                    .themedPageBackground()
                    .presentationDetents([.medium, .large])
                    .adaptiveFormPresentation()
                    .ignoresSafeArea()
                    .onDisappear {
                        try? FileManager.default.removeItem(
                            at: item.fileURL.deletingLastPathComponent()
                        )
                    }
            }
            .sheet(item: $sessionPendingRename, onDismiss: { viewModel.clearRenameError() }) { session in
                SessionRenameSheet(
                    initialTitle: SessionRowView.displayTitle(for: session),
                    isSaving: viewModel.isRenamingSession,
                    errorMessage: viewModel.renameErrorMessage
                ) {
                    sessionPendingRename = nil
                } onSave: { title in
                    Task {
                        guard let session = sessionPendingRename else { return }

                        let didRename = await rename(session, to: title)
                        if didRename {
                            sessionPendingRename = nil
                        }
                    }
                }
                .themedPageBackground()
                .presentationDetents([.height(180), .medium])
            }
            .sheet(item: $sessionPendingProjectCreation, onDismiss: { viewModel.clearProjectSheetError() }) { session in
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject || viewModel.isMovingSession,
                    errorMessage: viewModel.projectSheetErrorMessage
                ) {
                    sessionPendingProjectCreation = nil
                } onSave: { name, color, _ in
                    Task {
                        let didMove = await viewModel.createProject(
                            named: name,
                            color: color,
                            moving: session,
                            modelContext: modelContext
                        )
                        handleLastError()

                        if didMove {
                            sessionPendingProjectCreation = nil
                        }
                    }
                }
                .themedPageBackground()
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingProjectCreation, onDismiss: { viewModel.clearProjectSheetError() }) {
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject,
                    errorMessage: viewModel.projectSheetErrorMessage
                ) {
                    isPresentingProjectCreation = false
                } onSave: { name, color, _ in
                    Task {
                        let didCreate = await viewModel.createEmptyProject(
                            named: name,
                            color: color,
                            modelContext: modelContext
                        )
                        handleLastError()

                        if didCreate {
                            isPresentingProjectCreation = false
                        }
                    }
                }
                .themedPageBackground()
                .presentationDetents([.medium])
            }
            .sheet(item: $projectPendingRename, onDismiss: { viewModel.clearProjectSheetError() }) { project in
                ProjectRenameSheet(
                    project: project,
                    isSaving: viewModel.isRenamingProject,
                    errorMessage: viewModel.projectSheetErrorMessage
                ) {
                    projectPendingRename = nil
                } onSave: { name, color in
                    Task {
                        let didRename = await viewModel.rename(project, named: name, color: color)
                        handleLastError()

                        if didRename {
                            projectPendingRename = nil
                        }
                    }
                }
                .themedPageBackground()
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingAddServer) {
                AddServerView(authManager: authManager)
            }
            .task {
                await SessionListInitialLoad.run(
                    resolvePendingDeepLink: {
                        await openPendingDeepLinkedSessionIfNeeded()
                    },
                    loadSessions: {
                        await loadSessionRows()
                    },
                    restoreSelection: {
                        didCompleteInitialLoad = true
                        restoreLastSelectedSessionIfNeeded()
                    },
                    loadProjects: {
                        await loadProjectsIfLive()
                    },
                    loadActiveProfile: {
                        await viewModel.loadActiveProfile()
                    }
                )
            }
            .task(id: pendingWebuiPush) {
                await openPendingWebuiPush()
            }
            .task(id: remoteSearchTaskID) {
                await viewModel.searchSessions(query: searchText, content: true, depth: 5)
            }
            .task(id: activeSessionMonitorTaskID) {
                await monitorActiveSessionRows()
            }
            .task(id: returnRefreshID) {
                guard returnRefreshID != nil else { return }
                await SessionListReturnRefresh.run(
                    refreshSessions: { await refreshSessionsAndActiveProfile() },
                    monitorTaskID: { activeSessionMonitorTaskID },
                    refreshActiveRows: { taskID in await refreshActiveSessionRows(taskID) }
                )
            }
            .onAppear {
                openPendingSharedImportIfNeeded()
                openRequestedNewChatIfNeeded()
                refreshAfterReturningIfNeeded()
            }
            .onDisappear {
                ratingRequestID = nil
                cancelSessionOpening()
                viewModel.invalidateSessionOpening()
                actionToast.dismiss()
            }
            .onChange(of: viewModel.isLoading) {
                refreshAfterForegroundReturnIfReady()
            }
            .onChange(of: viewModel.sessions.count, initial: true) { LaunchSignpost.end(rows: viewModel.sessions.count) }
            .onChange(of: didCompleteInitialLoad) {
                refreshAfterForegroundReturnIfReady()
            }
            .onChange(of: pendingSharedImport) {
                openPendingSharedImportIfNeeded()
            }
            .onChange(of: pendingDeepLinkedSessionID) {
                Task { await openPendingDeepLinkedSessionIfNeeded() }
            }
            .onChange(of: requestedNewChat) {
                openRequestedNewChatIfNeeded()
            }
            .onChange(of: showsProjectsSection) {
                guard !showsProjectsSection else { return }
                selectedProjectID = nil
            }
            .onChange(of: navigationState.destination) { oldValue, newValue in
                if case .session(let previous)? = oldValue,
                   oldValue?.selectedSessionID != newValue?.selectedSessionID {
                    viewModel.noteReturn(from: previous)
                }
                if case .session(let current)? = newValue {
                    viewModel.beginViewing(current)
                }
                ratingRequestID = nil
                if oldValue != nil, newValue == nil {
                    ratingMoment = .returnedToSessionList
                    ratingRequestID = UUID()
                }
                SessionListDestinationReturn.run(
                    from: oldValue,
                    to: newValue,
                    suppressEmptyPlaceholders: viewModel.removeEmptySidebarPlaceholders,
                    refreshSessions: refreshAfterReturningIfNeeded
                )
            }
            .modifier(
                SessionActionConfirmations(
                    viewModel: viewModel,
                    showFailure: { message in
                        archiveToastRoute.noticeShown(destination: navigationState.destination)
                        actionToast.show(.failure(message))
                    },
                    sessionPendingDeletion: $sessionPendingDeletion,
                    projectPendingDeletion: $projectPendingDeletion,
                    deleteSession: { session in
                        Task { await delete(session) }
                    },
                    deleteProject: { project in
                        Task { await delete(project) }
                    }
                )
            )
            .focusedSceneValue(\.hermexSceneActions, sceneActions)
    }

    private var hasSharedImport: Bool { hasWaitingSharedImport || pendingSharedImport != nil }

    private var isQuietSessionListVisible: Bool {
        guard case .loggedIn(let activeServer) = authManager.state, activeServer == server else { return false }
        return scenePhase == .active && didCompleteInitialLoad
            && navigationState.destination == nil
            && pendingDeepLinkedSessionID == nil && requestedNewChat == nil
            && pendingSharedImport == nil && !hasWaitingSharedImport
            && !isSearchingSessions && !viewModel.isViewingCachedData
            && sessionExportShareItem == nil && sessionPendingRename == nil
            && sessionPendingProjectCreation == nil && sessionPendingDeletion == nil
            && projectPendingRename == nil && projectPendingDeletion == nil
            && !isPresentingProjectCreation && !isPresentingAddServer
            && !viewModel.isCreatingSession
    }

    private var waitingSharedImportBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.appSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Another shared item is waiting")
                    .font(AppFont.subheadline(weight: .semibold))
                Text("Open it when you are done with this draft.")
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
            }

            Spacer(minLength: 0)

            Button("Open Next", action: openNextSharedImport)
                .font(AppFont.subheadline(weight: .semibold))
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.appSurface))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
    }

    private var routedNavigationContainer: some View {
        navigationContainer
            .task { showBotsForPendingDestination() }
            .onChange(of: pendingBotDestination) { showBotsForPendingDestination() }
            .openNotificationSettings { showNotificationSettings() }
    }

    private func showNotificationSettings() {
        guard !usesSplit, navigationState.destination != nil else {
            selectDestination(.notificationSettings)
            return
        }
        opensNotificationSettingsOnReturn = true
        navigationState.clearDestination()
    }

    private func showBotsForPendingDestination() {
        guard isBotModeEnabled, let destination = pendingBotDestination, destination.server == server,
              navigationState.destination != .utility(.bots) else {
            return
        }
        selectDestination(.bots)
    }

    private var usesSplit: Bool {
        HermesHomeLayout.usesSplit(isHome: true, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if usesSplit {
            SessionSplitView(rootRevision: navigationState.rootRevision) {
                sessionListSurface
            } detail: {
                regularWidthDetail
            }
        } else {
            NavigationStack {
                sessionListSurface
                    .navigationDestination(item: navigationDestinationBinding) { destination in
                        navigationDestination(destination)
                    }
                    .onAppear {
                        guard opensNotificationSettingsOnReturn else { return }
                        opensNotificationSettingsOnReturn = false
                        selectDestination(.notificationSettings)
                    }
            }
        }
    }

    private var sessionListSurface: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.appCanvas)
                .ignoresSafeArea()

            content

            VStack(alignment: .trailing, spacing: 10) {
                if archiveToastRoute.host == .list {
                    ActionToastView(state: actionToast)
                        .padding(.bottom, isSearchingSessions ? 22 : 0)
                }

                if !isSearchingSessions {
                    newSessionButton
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
        }
        .onAppear { MoveToHermesNotices.shared.noteChatList(of: server.absoluteString, onScreen: true) }
        .onDisappear { MoveToHermesNotices.shared.noteChatList(of: server.absoluteString, onScreen: false) }
    }

    @ViewBuilder
    private var regularWidthDetail: some View {
        if let destination = navigationState.destination {
            navigationDestination(destination)
        } else {
            ContentUnavailableView {
                Label("Select a Chat", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Choose a session from the sidebar or start a new chat.")
            } actions: {
                Button("New Chat", action: openNewChat)
                    .buttonStyle(.appProminent)
            }
        }
    }

    @ViewBuilder
    private func navigationDestination(_ destination: SessionNavigationDestination) -> some View {
        switch destination {
        case .session(let session):
            ChatView(
                session: session,
                server: server,
                onAPIError: authManager.handleAPIError,
                draftStore: draftStore,
                continuity: navigationState.chatContinuity
            )
                .id(session.id)
        case .newChat(let route):
            PendingNewChatView(
                initialDraft: route.initialDraft,
                initialAttachments: route.initialAttachments,
                shareNotice: route.shareNotice,
                autoStartsVoiceInput: route.autoStartsVoiceInput,
                profileName: route.profileName,
                projectID: route.projectID,
                server: server,
                viewModel: viewModel,
                onAPIError: authManager.handleAPIError,
                onSessionCreated: rememberCreatedSession,
                draftStore: draftStore
            )
            .id(route.id)
        case .utility(let destination):
            utilityDestination(destination)
        }
    }

    @ViewBuilder
    private func utilityDestination(_ destination: SessionListUtilityDestination) -> some View {
        Group {
            switch destination {
            case .settings:
                SettingsView(
                    authManager: authManager,
                    server: server,
                    onDefaultProfileSelected: viewModel.adoptDefaultProfileSelection
                )
            case .notificationSettings:
                SettingsNotificationsPage(server: server)
            case .bots:
                BotsInboxView(server: server, pendingDestination: $pendingBotDestination)
            case .tasks:
                TasksView(server: server, onAPIError: authManager.handleAPIError)
            case .kanban:
                KanbanView(server: server, onAPIError: authManager.handleAPIError)
            case .skills:
                SkillsView(server: server, onAPIError: authManager.handleAPIError)
            case .memory:
                MemoryView(server: server, onAPIError: authManager.handleAPIError)
            case .insights:
                InsightsView(server: server, onAPIError: authManager.handleAPIError)
            case .archived:
                ArchivedSessionsView(server: server, onAPIError: authManager.handleAPIError)
            case .scheduled:
                ScheduledSessionsView(
                    viewModel: viewModel,
                    showsCronSessions: showsCronSessions,
                    showsMessageCount: showsSessionMessageCount,
                    showsWorkspace: showsSessionWorkspace,
                    selectedSessionID: usesSplit
                        ? navigationState.selectedSessionID
                        : nil,
                    actions: sessionRowActions(toastHost: .scheduled),
                    actionToast: archiveToastRoute.host == .scheduled ? actionToast : nil
                )
                .onDisappear {
                    if archiveToastRoute.host == .scheduled {
                        actionToast.dismiss()
                    }
                }
            }
        }
        .adaptiveSecondaryNavigationTitle()
    }

    private var navigationDestinationBinding: Binding<SessionNavigationDestination?> {
        Binding(
            get: { navigationState.destination },
            set: { destination in
                guard destination == nil else { return }
                navigationState.clearDestination()
            }
        )
    }

    private var content: some View {
        let groups = scheduledSessionGroups
        return AppList(rows: .plain) {
            header
                .sessionsTopChromeListRow()

            SessionListCardSlot(hasSharedImport: hasSharedImport)

            MoveToHermesBanner(serverID: server.absoluteString)

            if viewModel.isViewingCachedData {
                OfflineCacheBanner()
                    .padding(.top, 16)
                    .sessionsScreenListRow()
            }

            if !isSearchingSessions {
                SessionSidebarUtilityRows(
                    viewModel: viewModel,
                    topPadding: 10,
                    automatedVisibility: automatedSessionVisibility,
                    sectionVisibility: sidebarSectionVisibility,
                    profilesAreExpanded: $profilesAreExpanded,
                    projectsAreExpanded: $projectsAreExpanded,
                    selectedProjectID: $selectedProjectID,
                    projectPendingDeletion: $projectPendingDeletion,
                    projectPendingRename: $projectPendingRename,
                    openDestination: selectDestination,
                    switchActiveProfile: { profile in
                        Task { await switchActiveProfile(profile) }
                    },
                    presentProjectCreation: {
                        isPresentingProjectCreation = true
                    }
                )
            }

            if groups.showsDisclosure(isSearchActive: isSearchingSessions) {
                ScheduledSessionsDisclosure(
                    viewModel: viewModel,
                    searchText: searchText,
                    sessions: groups.scheduled,
                    totalCount: groups.totalScheduledCount,
                    isSearchActive: isSearchingSessions,
                    showsMessageCount: showsSessionMessageCount,
                    showsWorkspace: showsSessionWorkspace,
                    selectedSessionID: usesSplit
                        ? navigationState.selectedSessionID
                        : nil,
                    userIsExpanded: $scheduledSessionsAreExpanded,
                    actions: sessionRowActions(),
                    viewAll: { selectDestination(.scheduled) }
                )
            }

            SessionListRowsSection(
                viewModel: viewModel,
                searchText: searchText,
                sessions: groups.ordinary,
                emptyTitle: emptySessionsTitle,
                emptyDescription: emptySessionsDescription,
                isSearchActive: isSearchingSessions,
                showsMessageCount: showsSessionMessageCount,
                showsWorkspace: showsSessionWorkspace,
                selectedSessionID: usesSplit
                    ? navigationState.selectedSessionID
                    : nil,
                actions: sessionRowActions(),
                suppressEmptyState: !groups.scheduled.isEmpty
            )

            if showsArchivedEntry {
                archivedEntryRow
                    .sessionsScreenListRow()
            }

            Color.clear
                .frame(height: 104)
                .sessionsScreenListRow()
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
        .refreshable {
            await refreshSessionsAndActiveProfile()
        }
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: $sidebarScrollPosition)
        .background(Color(.appCanvas))
        .scrollDismissesKeyboard(.interactively)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: profilesAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: projectsAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: scheduledSessionsAreExpanded)
    }

    private var header: some View {
        SessionsHeader(
            logoColor: selectedHeaderLogoColor,
            avatar: SessionsHeader.Avatar(
                initials: settingsInitials,
                color: selectedHeaderLogoColor,
                foreground: initialsAvatarForegroundColor,
                servers: AvatarServerSwitcherModel(servers: authManager.servers, activeServerID: authManager.activeServerID),
                openSettings: { selectDestination(.settings) },
                switchToServer: { account in authManager.switchActiveServer(to: account) },
                addServer: { isPresentingAddServer = true },
                manageServers: { selectDestination(.settings) }
            ),
            field: SessionsHeader.Field(
                isExpanded: searchChromeIsExpanded, text: $searchText, isFocused: $searchFieldIsFocused, close: closeSearch
            ),
            openSearch: openSearch
        )
        .onChange(of: searchFieldIsFocused) { _, newValue in
            handleSearchFieldFocusChange(newValue)
        }
    }

    private var newSessionButton: some View {
        HapticButton(feedbackStyle: .medium) {
            openNewChat()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(AppFont.title3(weight: .semibold))

                Text("Chat")
                    .font(AppFont.headline(weight: .semibold))
            }
            .foregroundStyle(newSessionButtonForegroundColor)
            .padding(.horizontal, 22)
            .frame(height: 58)
            .contentShape(Capsule())
            .background {
                if let fill = newSessionButtonSolidThemeFill {
                    Capsule().fill(fill)
                }
            }
            .sessionsChromeGlass(
                isInteractive: true,
                tint: newSessionButtonGlassTint,
                fallbackMaterial: .regularMaterial,
                in: Capsule()
            )
        }
        .buttonStyle(SessionListFloatingChatButtonStyle())
        .disabled(viewModel.isViewingCachedData || navigationState.isCreatingNewChat)
        .opacity(viewModel.isViewingCachedData ? 0.45 : 1)
        .accessibilityLabel("New Session")
    }

    private var scheduledSessionGroups: ScheduledSessionGroups {
        viewModel.scheduledSessionGroups(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedSessionVisibility
        )
    }

    private var automatedSessionVisibility: AutomatedSessionVisibility {
        AutomatedSessionVisibility(
            showsCron: showsCronSessions,
            showsCli: showsCliSessions,
            showsClaudeCode: showsClaudeCodeSessions,
            showsSubagents: showsSubagentSessions
        )
    }

    private var sidebarSectionVisibility: SidebarSectionVisibility {
        SidebarSectionVisibility(
            bots: isBotModeEnabled,
            tasks: showsTasksSection,
            kanban: showsKanbanSection,
            skills: showsSkillsSection,
            memory: showsMemorySection,
            insights: showsInsightsSection,
            activeProfile: showsActiveProfileSection,
            projects: showsProjectsSection
        )
    }

    private var showsArchivedEntry: Bool {
        guard !isSearchingSessions, !viewModel.isViewingCachedData else { return false }
        return (viewModel.archivedCount ?? 0) > 0
    }

    private var archivedEntryRow: some View {
        HapticButton {
            selectDestination(.archived)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(AppFont.body())
                    .foregroundStyle(.appSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text("Archived Sessions")
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(.appSecondary)
                    .lineLimit(1)

                if let archivedCount = viewModel.archivedCount {
                    Text("\(archivedCount)")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(.appSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.appMaterial(.thinMaterial), in: Capsule())
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.appSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityHint("Shows archived sessions.")
    }

    private var emptySessionsTitle: String {
        if hasActiveSessionFilter {
            return String(localized: "No matching sessions")
        }

        return String(localized: "No sessions yet")
    }

    private var emptySessionsDescription: String? {
        if hasActiveSessionFilter {
            return String(localized: "Try another search or project filter.")
        }

        return String(localized: "Tap Chat to start.")
    }

    private var hasActiveSessionFilter: Bool {
        selectedProjectID != nil || !normalizedSearchText.isEmpty
    }

    private var settingsInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: identityDisplayName,
            storedInitials: identityInitials,
            fallbackFullName: NSFullUserName()
        )
    }

    private var selectedHeaderLogoColor: Color {
        HeaderLogoColor.color(for: headerLogoColorHex)
    }

    private var newSessionButtonTint: (fill: Color, label: Color) {
        PrimaryActionTintSettings.colors(accentHex: accentHex, serverHex: headerLogoColorHex)
    }

    private var newSessionButtonUsesThemeColor: Bool {
        PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions,
            controlIsEnabled: !viewModel.isViewingCachedData
        )
    }

    private var newSessionButtonSurface: AdaptiveGlassSurface {
        AdaptiveGlassSurface.resolve(
            liquidGlassAvailable: GlassPreference.isLiquidGlassSupported,
            isGlassEnabled: isGlassEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    private var newSessionButtonSolidThemeFill: Color? {
        guard newSessionButtonUsesThemeColor, newSessionButtonSurface != .liquidGlass else {
            return nil
        }

        return newSessionButtonTint.fill
    }

    private var newSessionButtonGlassTint: Color {
        if newSessionButtonUsesThemeColor {
            return newSessionButtonTint.fill
        }

        return colorScheme == .dark ? .white : .black
    }

    private var newSessionButtonForegroundColor: Color {
        if newSessionButtonUsesThemeColor {
            return newSessionButtonTint.label
        }

        return colorScheme == .dark ? .black : .white
    }

    private var initialsAvatarForegroundColor: Color {
        HeaderLogoColor.prefersDarkForeground(for: headerLogoColorHex) ? .black : .white
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearchingSessions: Bool {
        isSearchVisible || isSearchFocused
    }

    private var remoteSearchTaskID: SessionSearchTaskID {
        SessionSearchTaskID(query: normalizedSearchText, isViewingCachedData: viewModel.isViewingCachedData)
    }

    private var activeSessionMonitorTaskID: ActiveSessionMonitorTaskID {
        let activeSessions = viewModel.visibleActiveSessions(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedSessionVisibility
        )
        return ActiveSessionMonitorTaskID(
            streamIDs: SessionListViewModel.activeStreamIDs(in: activeSessions),
            hasActiveRows: !activeSessions.isEmpty,
            isViewingCachedData: viewModel.isViewingCachedData,
            isRegularWidth: usesSplit,
            destination: navigationState.destination
        )
    }

    private func sessionRowActions(toastHost: SessionListArchiveToastRoute.Host = .list) -> SessionListRowActions {
        SessionListRowActions(
            retryLoad: {
                Task { await refreshSessionsAndActiveProfile() }
            },
            open: { session in
                startOpeningSession(session)
            },
            toggleUnread: { session in
                viewModel.toggleUnread(session)
            },
            togglePinned: { session in
                Task { await togglePinned(session) }
            },
            archive: { session in
                Task { await archive(session, toastHost: toastHost) }
            },
            delete: { session in
                sessionPendingDeletion = session
            },
            rename: { session in
                sessionPendingRename = session
            },
            duplicate: { session in
                Task { await duplicate(session) }
            },
            move: { session, projectID in
                Task { await move(session, to: projectID) }
            },
            createProject: { session in
                sessionPendingProjectCreation = session
            },
            refreshProjects: {
                Task { await viewModel.loadProjects() }
            },
            export: { session, format in
                Task { await export(session, format: format) }
            }
        )
    }

    private func refreshSessionsAndActiveProfile() async {
        await loadSessionRows()
        guard !Task.isCancelled else { return }
        await SessionListInitialLoad.loadProjectsAndActiveProfile(
            loadProjects: { await loadProjectsIfLive() },
            loadActiveProfile: { await viewModel.loadActiveProfile() }
        )
    }

    private func closeSearch() {
        searchText = ""
        searchFieldIsFocused = false
        isSearchFocused = false

        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) {
            searchChromeIsExpanded = false
            isSearchVisible = false
        }
    }

    private func openSearch() {
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) {
            isSearchVisible = true
            searchChromeIsExpanded = true
        }
        searchFieldIsFocused = true
    }

    private var sceneActions: HermexSceneActions {
        HermexSceneActions(
            canCreateNewChat: !viewModel.isViewingCachedData && !navigationState.isCreatingNewChat,
            createNewChat: openNewChatFromKeyboard,
            searchSessions: openSearchFromKeyboard,
            openChat: openChatFromKeyboard(atPosition:),
            openAdjacentChat: openAdjacentChatFromKeyboard(offset:)
        )
    }

    private var keyboardShortcutChats: [SessionSummary] {
        scheduledSessionGroups.ordinary
    }

    private func openChatFromKeyboard(atPosition position: Int) {
        guard let chat = ChatShortcutNavigation.chat(atPosition: position, in: keyboardShortcutChats) else { return }
        startOpeningSession(chat)
    }

    private func openAdjacentChatFromKeyboard(offset: Int) {
        guard let chat = ChatShortcutNavigation.adjacentChat(
            offset: offset,
            from: viewModel.openingSessionID ?? navigationState.selectedSessionID,
            in: keyboardShortcutChats
        ) else { return }
        startOpeningSession(chat)
    }

    private func openNewChatFromKeyboard() {
        guard !viewModel.isViewingCachedData, !navigationState.isCreatingNewChat else { return }
        openNewChat()
    }

    private func openSearchFromKeyboard() {
        searchFieldIsFocused = false

        if !usesSplit {
            navigationState.clearDestination()
        }

        Task { @MainActor in
            await Task.yield()
            openSearch()
        }
    }

    private func handleSearchFieldFocusChange(_ isFocused: Bool) {
        guard isFocused else {
            isSearchFocused = false
            return
        }

        guard searchChromeIsExpanded || isSearchVisible else {
            searchFieldIsFocused = false
            isSearchFocused = false
            return
        }

        isSearchFocused = true
    }

    private func refreshAfterReturningIfNeeded() {
        guard didCompleteInitialLoad else { return }
        returnRefreshID = UUID()
    }

    private func refreshAfterForegroundReturnIfReady() {
        guard foregroundRefresh.consumeIfReady(
            didCompleteInitialLoad: didCompleteInitialLoad,
            isLoading: viewModel.isLoading
        ) else { return }
        refreshAfterReturningIfNeeded()
    }

    private func monitorActiveSessionRows() async {
        while !Task.isCancelled {
            let taskID = activeSessionMonitorTaskID
            guard taskID.shouldPoll else { return }

            do {
                try await Task.sleep(for: ActiveSessionMonitorTaskID.pollInterval)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            await refreshActiveSessionRows(taskID)
        }
    }

    private func refreshActiveSessionRows(_ taskID: ActiveSessionMonitorTaskID) async {
        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(
            streamIDs: taskID.streamIDs,
            modelContext: modelContext
        )
        if refreshResult == .reloaded || refreshResult == .failed {
            handleLastError()
        }
    }

    @MainActor
    private func switchActiveProfile(_ profile: ProfileSummary) async {
        let didSwitch = await viewModel.switchActiveProfile(profile)
        handleLastError()

        guard didSwitch else { return }

        withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
            profilesAreExpanded = false
        }

        await loadSessions()
    }

    private func loadSessions() async {
        await loadSessionRows()
        guard !Task.isCancelled else { return }
        await loadProjectsIfLive()
    }

    private func loadSessionRows() async {
        await viewModel.load(modelContext: modelContext)
        guard !Task.isCancelled else { return }
        handleLastError()
    }

    private func loadProjectsIfLive() async {
        guard !viewModel.isViewingCachedData else { return }
        await viewModel.loadProjects()
        guard !Task.isCancelled else { return }
        handleLastError()
    }

    private func togglePinned(_ session: SessionSummary) async {
        let didChangePinState = await viewModel.setPinned(
            !(session.pinned ?? false),
            for: session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didChangePinState {
            SessionHaptics.pinStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    private func archive(_ session: SessionSummary, toastHost: SessionListArchiveToastRoute.Host) async {
        let archiveNumber = archiveToastRoute.archiveStarted()
        let didArchive = await viewModel.archive(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didArchive {
            removeSessionFromNavigation(session)
            SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
            let shownOn = archiveToastRoute.archiveConfirmed(
                archiveNumber,
                swipedOn: toastHost,
                destination: navigationState.destination,
                isRegularWidth: usesSplit
            )
            if shownOn != nil {
                showArchiveUndoToast(for: session)
            }
        }
    }

    private func showArchiveUndoToast(for session: SessionSummary) {
        let message = String(localized: "Archived")
        actionToast.show(
            ActionToast(
                message: message,
                systemImage: "archivebox",
                accessibilityLabel: String.localizedStringWithFormat(
                    String(localized: "%@, %@"),
                    SessionRowView.displayTitle(for: session),
                    message
                ),
                actionTitle: String(localized: "Undo"),
                action: {
                    Task { await undoArchive(session) }
                }
            )
        )
    }

    private func undoArchive(_ session: SessionSummary) async {
        let didUnarchive = await viewModel.unarchive(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didUnarchive {
            SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    private func delete(_ session: SessionSummary) async {
        let didDelete = await viewModel.delete(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didDelete {
            await draftStore.discardDraft(for: draftKey(for: session))
            removeSessionFromNavigation(session)
            SessionHaptics.sessionDeleted(isEnabled: isHapticsEnabled)
        }
    }

    private func draftKey(for session: SessionSummary) -> ChatDraftKey {
        let normalizedSessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = normalizedSessionID.flatMap { $0.isEmpty ? nil : $0 } ?? session.id
        return .session(server: server, sessionID: sessionID)
    }

    private func rename(_ session: SessionSummary, to title: String) async -> Bool {
        let didChangeTitle = normalizedTitle(title) != normalizedTitle(session.title)
        let didRename = await viewModel.rename(session, to: title, modelContext: modelContext)
        handleLastError()

        if didRename, didChangeTitle {
            SessionHaptics.sessionRenamed(isEnabled: isHapticsEnabled)
        }

        return didRename
    }

    private func duplicate(_ session: SessionSummary) async {
        let duplicatedSession = await viewModel.duplicate(session, modelContext: modelContext)
        handleLastError()

        if let duplicatedSession {
            selectSession(duplicatedSession)
        }
    }

    private func move(_ session: SessionSummary, to projectID: String?) async {
        await viewModel.move(session, to: projectID, modelContext: modelContext)
        handleLastError()
    }

    private func export(_ session: SessionSummary, format: SessionExportFormat) async {
        let fileURL = await viewModel.export(session, format: format)
        handleLastError()

        if let fileURL {
            sessionExportShareItem = SessionExportShareItem(fileURL: fileURL)
        }
    }

    private func delete(_ project: ProjectSummary) async {
        let deletedProjectID = project.projectId
        let didDelete = await viewModel.delete(project, modelContext: modelContext)
        handleLastError()

        if didDelete, selectedProjectID == deletedProjectID {
            selectedProjectID = nil
        }
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError {
            authManager.handleAPIError(lastError)
        }
    }

    private func openPendingSharedImportIfNeeded() {
        guard let reservation = pendingSharedImport else {
            return
        }

        let sharedImport = reservation.sharedImport
        let draft = HermesShareDraft.composerDraft(from: sharedImport.draft)
        guard !draft.isEmpty || !sharedImport.attachments.isEmpty else {
            didRoutePendingSharedImport(reservation)
            return
        }

        selectDestination(
            PendingNewChatRoute(
                initialDraft: draft,
                initialAttachments: sharedImport.attachments,
                shareNotice: SharedSkipsNotice(sharedImport.skipped)
            )
        )
        didRoutePendingSharedImport(reservation)
    }

    private func openPendingWebuiPush() async {
        guard let destination = pendingWebuiPush, destination.server == server,
              authManager.state == .loggedIn(server: server), !Task.isCancelled else { return }
        cancelSessionOpening()
        viewModel.invalidateSessionOpening()
        navigationState.openSessionList()
        persistLastSelectedSession()
        let revision = navigationState.rootRevision
        let session = await viewModel.loadSessionForDeepLink(
            id: destination.sessionID, modelContext: modelContext, isPush: true)
        guard !Task.isCancelled, pendingWebuiPush == destination,
              authManager.state == .loggedIn(server: server) else { return }
        guard navigationState.rootRevision == revision else {
            pendingWebuiPush = nil
            return
        }
        handleLastError()
        guard authManager.state == .loggedIn(server: server) else { return }
        pendingWebuiPush = nil
        if let session { selectSession(session) }
    }

    private func openPendingDeepLinkedSessionIfNeeded() async {
        guard !Task.isCancelled else { return }

        while let sessionID = navigationState.beginDeepLinkedSessionLoad(
            id: pendingDeepLinkedSessionID
        ) {
            pendingDeepLinkedSessionID = nil
            await openDeepLinkedSession(id: sessionID)
            navigationState.finishDeepLinkedSessionLoad(id: sessionID)
            guard !Task.isCancelled else { return }
        }
    }

    private func openDeepLinkedSession(id sessionID: String) async {
        if let loadedSession = viewModel.sessions.first(where: { $0.sessionId == sessionID }) {
            selectSession(loadedSession)
            return
        }

        let session = await viewModel.loadSessionForDeepLink(id: sessionID, modelContext: modelContext)
        guard !Task.isCancelled else { return }
        if let session {
            selectSession(session)
        }
        handleLastError()
    }

    private func openRequestedNewChatIfNeeded() {
        guard let request = requestedNewChat else { return }
        requestedNewChat = nil
        selectDestination(
            PendingNewChatRoute(
                autoStartsVoiceInput: request.autoStartsVoiceInput,
                profileName: request.profileName
            )
        )
    }

    private func openNewChat() {
        selectDestination(PendingNewChatRoute(projectID: selectedProjectID))
    }

    private func selectSession(_ session: SessionSummary) {
        selectDestination(session)
        persistLastSelectedSession()
    }

    private func selectDestination(_ session: SessionSummary) {
        viewModel.invalidateSessionOpening()
        navigationState.select(session)
    }

    private func selectDestination(_ route: PendingNewChatRoute) {
        viewModel.invalidateSessionOpening()
        navigationState.select(route)
    }

    private func selectDestination(_ utility: SessionListUtilityDestination) {
        viewModel.invalidateSessionOpening()
        navigationState.select(utility)
    }

    private func startOpeningSession(_ session: SessionSummary) {
        cancelSessionOpening()
        SessionOpenSignpost.begin(sessionID: session.sessionId)
        openingSignpostSessionID = session.sessionId
        sessionOpenTask = Task { await openSession(session) }
    }

    private func cancelSessionOpening() {
        sessionOpenTask?.cancel()
        sessionOpenTask = nil
        if let openingSignpostSessionID {
            SessionOpenSignpost.end(sessionID: openingSignpostSessionID, messages: nil)
        }
        openingSignpostSessionID = nil
    }

    private func openSession(_ session: SessionSummary) async {
        let sessionToOpen = await viewModel.sessionForOpening(session, modelContext: modelContext)
        guard !Task.isCancelled else { return }

        openingSignpostSessionID = nil
        if let sessionToOpen {
            selectSession(sessionToOpen)
        } else {
            SessionOpenSignpost.end(sessionID: session.sessionId, messages: nil)
        }
    }

    private func rememberCreatedSession(_ session: SessionSummary) {
        navigationState.remember(session)
        persistLastSelectedSession()
    }

    private func removeSessionFromNavigation(_ session: SessionSummary) {
        navigationState.remove(sessionID: session.sessionId)
        persistLastSelectedSession()
    }

    private func restoreLastSelectedSessionIfNeeded() {
        guard pendingWebuiPush == nil else { return }
        navigationState.restoreIfNeeded(
            from: viewModel.sessions,
            clearsMissingSelection: viewModel.sessionLoadError == nil,
            pendingDeepLinkedSessionID: pendingDeepLinkedSessionID
        )
        persistLastSelectedSession()
    }

    private func persistLastSelectedSession() {
        SessionNavigationPersistence.save(navigationState.lastSelectedSessionID, for: server)
    }

}

enum SessionListInitialLoad {
    @MainActor
    static func run(
        resolvePendingDeepLink: @escaping @MainActor () async -> Void,
        loadSessions: @escaping @MainActor () async -> Void,
        restoreSelection: @MainActor () -> Void,
        loadProjects: @escaping @MainActor () async -> Void,
        loadActiveProfile: @escaping @MainActor () async -> Void
    ) async {
        async let sessions: Void = loadSessions()
        await resolvePendingDeepLink()
        await sessions
        guard !Task.isCancelled else { return }
        restoreSelection()
        await loadProjectsAndActiveProfile(loadProjects: loadProjects, loadActiveProfile: loadActiveProfile)
    }

    @MainActor
    static func loadProjectsAndActiveProfile(
        loadProjects: @escaping @MainActor () async -> Void,
        loadActiveProfile: @escaping @MainActor () async -> Void
    ) async {
        async let activeProfile: Void = loadActiveProfile()
        await loadProjects()
        await activeProfile
    }
}

enum SessionListReturnRefresh {
    @MainActor
    static func run(
        refreshSessions: @MainActor () async -> Void,
        monitorTaskID: @MainActor () -> ActiveSessionMonitorTaskID,
        refreshActiveRows: @MainActor (ActiveSessionMonitorTaskID) async -> Void
    ) async {
        await refreshSessions()
        guard !Task.isCancelled else { return }
        let taskID = monitorTaskID()
        guard taskID.needsTickOnReturn else { return }
        await refreshActiveRows(taskID)
    }
}

enum SessionListDestinationReturn {
    static func run(
        from oldValue: SessionNavigationDestination?,
        to newValue: SessionNavigationDestination?,
        suppressEmptyPlaceholders: () -> Void,
        refreshSessions: () -> Void
    ) {
        guard let oldValue, oldValue != newValue else { return }
        if case .newChat = oldValue, case .newChat = newValue { return }

        if case .newChat = oldValue {
            suppressEmptyPlaceholders()
        }
        refreshSessions()
    }
}

struct HermesHeaderLogo: View {
    let selectedColor: Color

    private static let aspectRatio = 643.0 / 185.0

    var body: some View {
        ZStack {
            Image("hermes-fill-mask")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(selectedColor)

            Image("hermes-shading-overlay")
                .resizable()
                .scaledToFit()
                .blendMode(.multiply)

            Image("hermes-highlight")
                .resizable()
                .scaledToFit()
                .blendMode(.screen)

            Image("hermes-outline-shadow")
                .resizable()
                .scaledToFit()
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .compositingGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HERMEX")
    }
}

struct NewChatRequest: Equatable {
    let id: UUID
    let autoStartsVoiceInput: Bool
    let profileName: String?

    init(autoStartsVoiceInput: Bool = false, profileName: String? = nil) {
        self.id = UUID()
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
    }
}

struct PendingNewChatRoute: Identifiable, Hashable {
    let id = UUID()
    let initialDraft: String
    let initialAttachments: [SharedAttachmentImport]
    let shareNotice: SharedSkipsNotice?
    let autoStartsVoiceInput: Bool
    let profileName: String?
    let projectID: String?

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        shareNotice: SharedSkipsNotice? = nil,
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil,
        projectID: String? = nil
    ) {
        self.initialDraft = initialDraft
        self.initialAttachments = initialAttachments
        self.shareNotice = shareNotice
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
        self.projectID = projectID
    }

    static func == (lhs: PendingNewChatRoute, rhs: PendingNewChatRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum SessionListUtilityDestination: Hashable, Identifiable {
    case settings
    case notificationSettings
    case bots
    case tasks
    case kanban
    case skills
    case memory
    case insights
    case archived
    case scheduled

    var id: Self { self }
}

private struct SessionSearchTaskID: Hashable {
    let query: String
    let isViewingCachedData: Bool
}

struct ActiveSessionMonitorTaskID: Hashable {
    static let pollInterval: Duration = .seconds(3)

    let streamIDs: [String]
    let hasActiveRows: Bool
    let isViewingCachedData: Bool
    let isListVisible: Bool
    let isRegularWidth: Bool

    init(
        streamIDs: [String],
        hasActiveRows: Bool,
        isViewingCachedData: Bool,
        isRegularWidth: Bool,
        destination: SessionNavigationDestination?
    ) {
        self.streamIDs = streamIDs
        self.hasActiveRows = hasActiveRows
        self.isViewingCachedData = isViewingCachedData
        self.isRegularWidth = isRegularWidth
        isListVisible = isRegularWidth || destination == nil || destination == .utility(.scheduled)
    }

    var shouldPoll: Bool {
        hasActiveRows && isListVisible && !isViewingCachedData
    }

    var needsTickOnReturn: Bool {
        shouldPoll && !isRegularWidth
    }
}

private struct PendingNewChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    let server: URL
    let viewModel: SessionListViewModel
    let onAPIError: (Error) -> Void
    let onSessionCreated: (SessionSummary) -> Void
    let initialAttachments: [SharedAttachmentImport]
    let shareNotice: SharedSkipsNotice?
    let autoStartsVoiceInput: Bool
    let profileName: String?
    let projectID: String?
    let draftStore: ChatDraftStore

    @State private var attachmentLease: ChatDraftAttachmentLease?
    @State private var createdSession: SessionSummary?
    @State private var draftMessage = ""
    @State private var draftQuotes: [ComposerQuote] = []
    @State private var didStartCreation = false
    @State private var didStartConversation = false
    @State private var didRequestComposerFocus = false
    @State private var creationErrorMessage: String?
    @FocusState private var composerIsFocused: Bool

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        shareNotice: SharedSkipsNotice? = nil,
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil,
        projectID: String? = nil,
        server: URL,
        viewModel: SessionListViewModel,
        onAPIError: @escaping (Error) -> Void,
        onSessionCreated: @escaping (SessionSummary) -> Void = { _ in },
        draftStore: ChatDraftStore? = nil
    ) {
        self.server = server
        self.viewModel = viewModel
        self.onAPIError = onAPIError
        self.onSessionCreated = onSessionCreated
        self.initialAttachments = initialAttachments
        self.shareNotice = shareNotice
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
        self.projectID = projectID
        self.draftStore = draftStore ?? .shared
        _draftMessage = State(initialValue: initialDraft)
    }

    var body: some View {
        Group {
            if let createdSession {
                ChatView(
                    session: createdSession,
                    server: server,
                    onAPIError: onAPIError,
                    initialDraft: draftMessage,
                    initialQuotes: draftQuotes,
                    initialAttachments: initialAttachments,
                    shareNotice: shareNotice,
                    loadsInitialMessages: false,
                    autoStartsVoiceInput: autoStartsVoiceInput,
                    draftStore: draftStore,
                    restoresDraftSettings: true,
                    onConversationStarted: markConversationStarted
                )
            } else {
                pendingContent
            }
        }
        .background(
            NavigationAppearanceCompletionObserver(action: requestPendingComposerFocus)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .task {
            await prepareNewChat()
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                flushDraftsBestEffort()
            }
        }
        .onDisappear {
            restoreAbandonedDraftIfNeeded()
            flushDraftsBestEffort()
        }
    }

    private var pendingContent: some View {
        ZStack(alignment: .bottom) {
            Color(.appCanvas)
                .ignoresSafeArea()

            ContentUnavailableView {
                Image(systemName: "bubble.left.and.bubble.right")
            } description: {
                Text("Send a message to start the conversation.")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                composerIsFocused = false
            }

            VStack(spacing: 10) {
                if let creationErrorMessage {
                    pendingErrorBanner(creationErrorMessage)
                }

                pendingComposer
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .themedPageBackground()
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pendingComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Hermex", text: persistedDraftBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composerIsFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.appMaterial(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color(.appSeparator).opacity(0.18), lineWidth: 0.5)
                }
                .submitLabel(.send)

            Button {} label: {
                Image(systemName: "arrow.up")
                    .font(AppFont.headline(weight: .bold))
                    .foregroundStyle(Color(.appTextSecondary))
                    .frame(width: 44, height: 44)
                    .background(Color(.appFillTertiary), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("Send")
        }
    }

    private func pendingErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)

            Text(message)
                .font(AppFont.footnote())
                .foregroundStyle(.appSecondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button("Retry") {
                Task { await retryCreateSession() }
            }
            .font(AppFont.footnote(weight: .semibold))
            .disabled(viewModel.isCreatingSession)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.appMaterial(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func createSessionIfNeeded() async {
        guard !didStartCreation, createdSession == nil else { return }

        didStartCreation = true
        creationErrorMessage = nil
        let session = await viewModel.createSession(
            modelContext: modelContext,
            profile: profileName,
            projectID: projectID
        )
        guard !Task.isCancelled else { return }
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if let session {
            let sessionKey = draftKey(for: session)
            draftStore.setDraft(draftMessage, for: draftKey)
            let movedDraft = draftStore.moveDraft(from: draftKey, to: sessionKey)
            draftMessage = movedDraft.text
            draftQuotes = movedDraft.quotes
            SessionHaptics.sessionCreated(isEnabled: isHapticsEnabled)
            onSessionCreated(session)
            createdSession = session
        } else {
            creationErrorMessage = viewModel.actionErrorMessage
                ?? viewModel.lastError?.localizedDescription
                ?? String(localized: "Could not start a new chat.")
            viewModel.clearActionError()
            didStartCreation = false
        }
    }

    private func retryCreateSession() async {
        didStartCreation = false
        creationErrorMessage = nil
        viewModel.clearActionError()
        await createSessionIfNeeded()
    }

    private var draftKey: ChatDraftKey {
        .newChat(server: server)
    }

    private func draftKey(for session: SessionSummary) -> ChatDraftKey {
        let normalizedSessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = normalizedSessionID.flatMap { $0.isEmpty ? nil : $0 } ?? session.id
        return .session(server: server, sessionID: sessionID)
    }

    private var persistedDraftBinding: Binding<String> {
        Binding(
            get: { draftMessage },
            set: { newValue in
                draftMessage = newValue
                draftStore.setDraft(newValue, for: draftKey)
            }
        )
    }

    private func prepareNewChat() async {
        await hydrateDraft()
        guard !Task.isCancelled else { return }
        await createSessionIfNeeded()
    }

    private func hydrateDraft() async {
        if attachmentLease == nil { attachmentLease = draftStore.makeAttachmentLease(key: draftKey) }
        await draftStore.markUsed(draftKey)
        let textBeforeHydration = draftMessage
        let persistedDraft = await draftStore.draft(for: draftKey)
        guard !Task.isCancelled, draftMessage == textBeforeHydration else { return }

        if textBeforeHydration.isEmpty {
            if let persistedDraft, !persistedDraft.text.isEmpty {
                draftMessage = persistedDraft.text
            }
        } else {
            draftStore.setDraft(textBeforeHydration, for: draftKey)
        }
    }

    private func flushDraftsBestEffort() {
        Task {
            try? await draftStore.flush()
        }
    }

    private func markConversationStarted() {
        didStartConversation = true
    }

    private func restoreAbandonedDraftIfNeeded() {
        guard let createdSession else { return }
        draftMessage = draftStore.restoreAbandonedNewChatDraft(
            from: draftKey(for: createdSession),
            to: draftKey,
            didStartConversation: didStartConversation
        )?.text ?? draftMessage
    }

    private func requestPendingComposerFocus() {
        guard !didRequestComposerFocus else { return }
        didRequestComposerFocus = true

        Task { @MainActor in
            await Task.yield()
            guard createdSession == nil else { return }
            composerIsFocused = true
        }
    }
}

#Preview("Hermes Header Logo") {
    VStack(spacing: 16) {
        ForEach(HeaderLogoColor.presets.prefix(4)) { preset in
            HermesHeaderLogo(selectedColor: preset.color)
                .frame(width: 220)
        }
    }
    .padding(24)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
