import SwiftUI
import SwiftData
import UIKit

@MainActor
struct SessionListView: View {
    private static let searchChromeIconVisualSize: CGFloat = 36
    private static let searchChromeIconHitTarget: CGFloat = 44

    @Bindable var authManager: AuthManager
    let server: URL
    @Binding private var pendingSharedImport: SharedImport?
    @Binding private var pendingDeepLinkedSessionID: String?
    @Binding private var requestedNewChat: NewChatRequest?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var viewModel: SessionListViewModel
    @State private var navigationState: SessionNavigationState
    @State private var sessionPendingRename: SessionSummary?
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingProjectCreation: SessionSummary?
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
    @FocusState private var searchFieldIsFocused: Bool
    @AppStorage(SessionSidebarDisclosureSettings.profilesAreExpandedKey)
    private var profilesAreExpanded = SessionSidebarDisclosureSettings.defaultProfilesAreExpanded
    @AppStorage(SessionSidebarDisclosureSettings.projectsAreExpandedKey)
    private var projectsAreExpanded = SessionSidebarDisclosureSettings.defaultProjectsAreExpanded
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) private var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    // Per-server key (#19): the CLI toggle mirrors the active server's
    // `show_cli_sessions`, so its cached value must not leak across servers.
    // Configured in `init`, where the server URL is known.
    @AppStorage private var showsCliSessions: Bool
    @AppStorage private var showsClaudeCodeSessions: Bool
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(GlassPreference.isEnabledKey) private var isGlassEnabled = GlassPreference.defaultIsEnabled
    @AppStorage(SessionIdentitySettings.displayNameKey) private var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) private var identityInitials = ""
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    init(
        authManager: AuthManager,
        server: URL,
        pendingSharedImport: Binding<SharedImport?> = .constant(nil),
        pendingDeepLinkedSessionID: Binding<String?> = .constant(nil),
        requestedNewChat: Binding<NewChatRequest?> = .constant(nil)
    ) {
        self.authManager = authManager
        self.server = server
        _pendingSharedImport = pendingSharedImport
        _pendingDeepLinkedSessionID = pendingDeepLinkedSessionID
        _requestedNewChat = requestedNewChat
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
        navigationContainer
            .sheet(item: $sessionExportShareItem) { item in
                SessionExportShareSheet(fileURL: item.fileURL)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
                    // The temp file lives in its own UUID directory (see
                    // SessionListViewModel.export); remove the directory once
                    // the share sheet is gone, shared and cancelled alike.
                    .onDisappear {
                        try? FileManager.default.removeItem(
                            at: item.fileURL.deletingLastPathComponent()
                        )
                    }
            }
            .sheet(item: $sessionPendingRename) { session in
                SessionRenameSheet(
                    initialTitle: SessionRowView.displayTitle(for: session),
                    isSaving: viewModel.isRenamingSession
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
                .presentationDetents([.height(180), .medium])
            }
            .sheet(item: $sessionPendingProjectCreation) { session in
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject || viewModel.isMovingSession
                ) {
                    sessionPendingProjectCreation = nil
                } onSave: { name, color in
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
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingProjectCreation) {
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject
                ) {
                    isPresentingProjectCreation = false
                } onSave: { name, color in
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
                .presentationDetents([.medium])
            }
            .sheet(item: $projectPendingRename) { project in
                ProjectRenameSheet(
                    project: project,
                    isSaving: viewModel.isRenamingProject
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
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingAddServer) {
                // Reuse #17's add-server flow directly as a power-user shortcut.
                // On success `addServer` switches the active server, which
                // rebuilds this stack via ContentView's `.id(server)` (#283).
                AddServerView(authManager: authManager)
            }
            .task {
                await refreshSessionsAndActiveProfile()
                didCompleteInitialLoad = true
                restoreLastSelectedSessionIfNeeded()
            }
            .task(id: remoteSearchTaskID) {
                await viewModel.searchSessions(query: searchText, content: true, depth: 5)
            }
            .task(id: activeSessionMonitorTaskID) {
                await monitorActiveSessionRows()
            }
            .onAppear {
                openPendingSharedImportIfNeeded()
                openPendingDeepLinkedSessionIfNeeded()
                openRequestedNewChatIfNeeded()
                refreshAfterReturningIfNeeded()
            }
            .onChange(of: pendingSharedImport) {
                openPendingSharedImportIfNeeded()
            }
            .onChange(of: pendingDeepLinkedSessionID) {
                openPendingDeepLinkedSessionIfNeeded()
            }
            .onChange(of: requestedNewChat) {
                openRequestedNewChatIfNeeded()
            }
            .onChange(of: navigationState.destination) { oldValue, newValue in
                if case .newChat = oldValue,
                   case .newChat = newValue {
                    return
                }

                if case .newChat = oldValue {
                    viewModel.removeEmptySidebarPlaceholders()
                }
            }
            .refreshable {
                await refreshSessionsAndActiveProfile()
            }
            .modifier(
                SessionActionConfirmations(
                    viewModel: viewModel,
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
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                sessionListSurface
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
            } detail: {
                NavigationStack {
                    regularWidthDetail
                }
            }
            .navigationSplitViewStyle(.balanced)
            .id(navigationState.rootRevision)
        } else {
            NavigationStack {
                sessionListSurface
                    .navigationDestination(item: navigationDestinationBinding) { destination in
                        navigationDestination(destination)
                    }
            }
        }
    }

    private var sessionListSurface: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemBackground)
                .ignoresSafeArea()

            content

            if !isSearchingSessions {
                newSessionButton
                    .padding(.trailing, 24)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func navigationDestination(_ destination: SessionNavigationDestination) -> some View {
        switch destination {
        case .session(let session):
            ChatView(session: session, server: server, onAPIError: authManager.handleAPIError)
                .id(session.id)
        case .newChat(let route):
            PendingNewChatView(
                initialDraft: route.initialDraft,
                initialAttachments: route.initialAttachments,
                autoStartsVoiceInput: route.autoStartsVoiceInput,
                profileName: route.profileName,
                server: server,
                viewModel: viewModel,
                onAPIError: authManager.handleAPIError,
                onSessionCreated: rememberCreatedSession
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
            case .settings(let scrollTo):
                SettingsView(authManager: authManager, server: server, initialScrollTarget: scrollTo)
            case .tasks:
                TasksView(server: server, onAPIError: authManager.handleAPIError)
            case .skills:
                SkillsView(server: server, onAPIError: authManager.handleAPIError)
            case .memory:
                MemoryView(server: server, onAPIError: authManager.handleAPIError)
            case .insights:
                InsightsView(server: server, onAPIError: authManager.handleAPIError)
            case .archived:
                ArchivedSessionsView(server: server, onAPIError: authManager.handleAPIError)
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
        List {
            header
                .sessionsTopChromeListRow()

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
                    profilesAreExpanded: $profilesAreExpanded,
                    projectsAreExpanded: $projectsAreExpanded,
                    selectedProjectID: $selectedProjectID,
                    projectPendingDeletion: $projectPendingDeletion,
                    projectPendingRename: $projectPendingRename,
                    openDestination: { destination in
                        navigationState.select(destination)
                    },
                    switchActiveProfile: { profile in
                        Task { await switchActiveProfile(profile) }
                    },
                    presentProjectCreation: {
                        isPresentingProjectCreation = true
                    }
                )
            }

            SessionListRowsSection(
                viewModel: viewModel,
                sessions: visibleSessions,
                emptyTitle: emptySessionsTitle,
                emptyDescription: emptySessionsDescription,
                isSearchActive: isSearchingSessions,
                showsMessageCount: showsSessionMessageCount,
                showsWorkspace: showsSessionWorkspace,
                selectedSessionID: horizontalSizeClass == .regular
                    ? navigationState.selectedSessionID
                    : nil,
                actions: sessionRowActions
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
        // Let rows hug their content instead of the 44pt default minimum, so the
        // single-line utility/disclosure rows aren't padded out and stay aligned
        // with the tightly-packed navigation rows.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: $sidebarScrollPosition)
        .background(Color(.systemBackground))
        .scrollDismissesKeyboard(.interactively)
        // Disclosure subrows are real List rows; drive their fold from the List
        // so insert/remove animates. Value-based so it works with @AppStorage.
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: profilesAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: projectsAreExpanded)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: searchChromeIsExpanded ? 0 : 16) {
            HermesHeaderLogo(selectedColor: selectedHeaderLogoColor)
                .frame(width: searchChromeIsExpanded ? 0 : 160, alignment: .leading)
                .opacity(searchChromeIsExpanded ? 0 : 1)
                .clipped()
                .accessibilityHidden(searchChromeIsExpanded)

            searchChrome
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .animation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion), value: searchChromeIsExpanded)
        .animation(SessionListMotion.searchFocusAnimation(reduceMotion: reduceMotion), value: showsSearchClearButton)
        .onChange(of: searchFieldIsFocused) { _, newValue in
            handleSearchFieldFocusChange(newValue)
        }
    }

    private var searchChrome: some View {
        HStack(spacing: searchChromeIsExpanded ? 8 : 4) {
            HapticButton {
                if searchChromeIsExpanded {
                    searchFieldIsFocused = true
                } else {
                    openSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(searchChromeIsExpanded ? .secondary : .primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchChromeIsExpanded ? "Focus session search" : "Search sessions")
            .accessibilityHint("Shows the session search field.")
            .accessibilityHidden(searchChromeIsExpanded)

            searchTextField

            if showsSearchClearButton {
                searchClearButton
                    .transition(.scale.combined(with: .opacity))
            }

            searchTrailingButton
        }
        .padding(.vertical, 2)
        .frame(maxWidth: searchChromeIsExpanded ? .infinity : nil, alignment: .trailing)
        .sessionsChromeGlass(
            isInteractive: true,
            in: Capsule()
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    private var searchTextField: some View {
        TextField("Search sessions", text: $searchText)
            .font(AppFont.subheadline())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFieldIsFocused)
            .submitLabel(.done)
            .lineLimit(1)
            .layoutPriority(1)
            .frame(maxWidth: searchChromeIsExpanded ? .infinity : 0)
            .opacity(searchChromeIsExpanded ? 1 : 0)
            .clipped()
            .accessibilityHidden(!searchChromeIsExpanded)
    }

    private var searchClearButton: some View {
        Button {
            searchText = ""
            searchFieldIsFocused = true
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
    }

    private var searchTrailingButton: some View {
        HapticButton(feedbackStyle: .medium) {
            if searchChromeIsExpanded {
                closeSearch()
            } else {
                navigationState.select(.settings(nil))
            }
        } label: {
            ZStack {
                Text(settingsInitials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(initialsAvatarForegroundColor)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .background(selectedHeaderLogoColor, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .opacity(searchChromeIsExpanded ? 0 : 1)
                    .scaleEffect(searchChromeIsExpanded ? 0.72 : 1)
                    .rotationEffect(.degrees(searchChromeIsExpanded ? -18 : 0))

                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .opacity(searchChromeIsExpanded ? 1 : 0)
                    .scaleEffect(searchChromeIsExpanded ? 1 : 0.72)
                    .rotationEffect(.degrees(searchChromeIsExpanded ? 0 : 18))
            }
            .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchChromeIsExpanded ? "Close search" : "Settings")
        .accessibilityHint(
            searchChromeIsExpanded
                ? "Closes search and clears the current query."
                : "Opens Settings. Long press to switch servers."
        )
        // Long-press the avatar to switch the active server, reusing #17's
        // switch/add actions. Suppressed while search is expanded so the
        // "close search" tap state is untouched (#283). The plain tap above is
        // preserved — `contextMenu` adds long-press without stealing the tap.
        .contextMenu {
            if !searchChromeIsExpanded {
                AvatarServerSwitcherMenu(
                    model: AvatarServerSwitcherModel(
                        servers: authManager.servers,
                        activeServerID: authManager.activeServerID
                    ),
                    switchToServer: { account in
                        authManager.switchActiveServer(to: account)
                    },
                    addServer: { isPresentingAddServer = true },
                    manageServers: { navigationState.select(.settings(.servers)) }
                )
            }
        }
    }

    private var newSessionButton: some View {
        HapticButton(feedbackStyle: .medium) {
            openNewChat()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))

                Text("Chat")
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(newSessionButtonForegroundColor)
            .padding(.horizontal, 22)
            .frame(height: 58)
            // Lock the hit region to the visible capsule so taps in the padding,
            // rounded ends, and icon↔text gap start a new chat instead of falling
            // through to the session row behind the FAB (issue #242).
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

    private var visibleSessions: [SessionSummary] {
        viewModel.visibleSessions(
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

    /// Bottom-of-list entry to the Archived screen (issue #17). Hidden while
    /// searching, offline (cached data cannot fetch archived rows), and when the
    /// server reports zero archived sessions or omits `archived_count` (older
    /// server) — so the list is unchanged for users with nothing archived.
    private var showsArchivedEntry: Bool {
        guard !isSearchingSessions, !viewModel.isViewingCachedData else { return false }
        return (viewModel.archivedCount ?? 0) > 0
    }

    private var archivedEntryRow: some View {
        HapticButton {
            navigationState.select(.archived)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text("Archived Sessions")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let archivedCount = viewModel.archivedCount {
                    Text("\(archivedCount)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

    private var showsSearchClearButton: Bool {
        searchChromeIsExpanded && !searchText.isEmpty
    }

    private func isActiveProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }

        if let activeProfileName = viewModel.activeProfileName {
            return profileName == activeProfileName
        }

        return profile.isActive == true
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

    // The glass tint is dropped on the material/opaque fallback surfaces, so a
    // themed button would otherwise show its contrast-picked foreground over a
    // neutral material (e.g. black-on-dark for a light theme color). Draw a
    // solid header-color fill there so the button stays themed and readable;
    // the liquid-glass surface keeps tinting via `newSessionButtonGlassTint`.
    private var newSessionButtonSolidThemeFill: Color? {
        guard newSessionButtonUsesThemeColor, newSessionButtonSurface != .liquidGlass else {
            return nil
        }

        return selectedHeaderLogoColor
    }

    private var newSessionButtonGlassTint: Color {
        if newSessionButtonUsesThemeColor {
            return selectedHeaderLogoColor
        }

        return colorScheme == .dark ? .white : .black
    }

    private var newSessionButtonForegroundColor: Color {
        if newSessionButtonUsesThemeColor {
            return HeaderLogoColor.prefersDarkForeground(for: headerLogoColorHex) ? .black : .white
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
        let activeSessions = visibleSessions.filter(SessionRowView.isActiveStreaming)
        return ActiveSessionMonitorTaskID(
            streamIDs: SessionListViewModel.activeStreamIDs(in: activeSessions),
            hasActiveRows: !activeSessions.isEmpty,
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    private var sessionRowActions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: {
                Task { await refreshSessionsAndActiveProfile() }
            },
            open: { session in
                selectSession(session)
            },
            togglePinned: { session in
                Task { await togglePinned(session) }
            },
            archive: { session in
                Task { await archive(session) }
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
        await loadSessions()
        await viewModel.loadActiveProfile()
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

        Task {
            await refreshSessionsAndActiveProfile()
        }
    }

    private func monitorActiveSessionRows() async {
        while !Task.isCancelled {
            let taskID = activeSessionMonitorTaskID
            guard taskID.hasActiveRows, !taskID.isViewingCachedData else { return }

            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(
                streamIDs: taskID.streamIDs,
                modelContext: modelContext
            )
            if refreshResult == .reloaded || refreshResult == .failed {
                handleLastError()
            }
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
        await viewModel.load(modelContext: modelContext)
        handleLastError()

        if !viewModel.isViewingCachedData {
            await viewModel.loadProjects()
            handleLastError()
        }
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

    private func archive(_ session: SessionSummary) async {
        let didArchive = await viewModel.archive(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didArchive {
            removeSessionFromNavigation(session)
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
            removeSessionFromNavigation(session)
            SessionHaptics.sessionDeleted(isEnabled: isHapticsEnabled)
        }
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
        guard let sharedImport = pendingSharedImport else {
            return
        }

        pendingSharedImport = nil
        let draft = HermesShareDraft.composerDraft(from: sharedImport.draft)
        guard !draft.isEmpty || !sharedImport.attachments.isEmpty else {
            return
        }

        navigationState.select(
            PendingNewChatRoute(
                initialDraft: draft,
                initialAttachments: sharedImport.attachments
            )
        )
    }

    private func openPendingDeepLinkedSessionIfNeeded() {
        guard let sessionID = pendingDeepLinkedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return
        }

        pendingDeepLinkedSessionID = nil
        if let loadedSession = viewModel.sessions.first(where: { $0.sessionId == sessionID }) {
            selectSession(loadedSession)
            return
        }

        Task {
            if let session = await viewModel.loadSessionForDeepLink(id: sessionID, modelContext: modelContext) {
                selectSession(session)
            }
            handleLastError()
        }
    }

    /// Opens the New Chat composer in response to the "New Chat" App Intents (#337/#338),
    /// mirroring the "+" button. Carries `autoStartsVoiceInput` so the voice variant begins
    /// dictation once the composer appears. The request is cleared so it fires once per
    /// invocation.
    private func openRequestedNewChatIfNeeded() {
        guard let request = requestedNewChat else { return }
        requestedNewChat = nil
        navigationState.select(
            PendingNewChatRoute(
                autoStartsVoiceInput: request.autoStartsVoiceInput,
                profileName: request.profileName
            )
        )
    }

    private func openNewChat() {
        navigationState.select(PendingNewChatRoute())
    }

    private func selectSession(_ session: SessionSummary) {
        navigationState.select(session)
        persistLastSelectedSession()
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
        navigationState.restoreIfNeeded(
            from: viewModel.sessions,
            clearsMissingSelection: viewModel.sessionLoadError == nil
        )
        persistLastSelectedSession()
    }

    private func persistLastSelectedSession() {
        SessionNavigationPersistence.save(navigationState.lastSelectedSessionID, for: server)
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

/// A request from `ContentView` to open the New Chat composer. Carries whether voice
/// dictation should auto-start (the "New Chat with Voice" App Intent, #338) and an optional
/// profile name to pin the new session to (the "New Chat in <Profile>" App Intent, #339).
/// A fresh `id` each time so a repeat invocation re-triggers navigation even if the previous
/// value lingers.
struct NewChatRequest: Equatable {
    let id: UUID
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile; nil uses the server's
    /// active profile (the plain "+" / "New Chat" behavior).
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
    /// When true, the composer auto-starts voice dictation on appear (#338).
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile (#339).
    let profileName: String?

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil
    ) {
        self.initialDraft = initialDraft
        self.initialAttachments = initialAttachments
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
    }

    static func == (lhs: PendingNewChatRoute, rhs: PendingNewChatRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum SessionListUtilityDestination: Hashable, Identifiable {
    /// Optional section to scroll to when Settings opens — "Manage Servers"
    /// passes `.servers`, a plain avatar tap passes `nil` (#283).
    case settings(SettingsScrollAnchor?)
    case tasks
    case skills
    case memory
    case insights
    /// Archived sessions screen (issue #17), also reachable from Settings.
    case archived

    var id: Self { self }
}

private struct SessionSearchTaskID: Hashable {
    let query: String
    let isViewingCachedData: Bool
}

private struct ActiveSessionMonitorTaskID: Hashable {
    let streamIDs: [String]
    let hasActiveRows: Bool
    let isViewingCachedData: Bool
}

private struct PendingNewChatView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    let server: URL
    let viewModel: SessionListViewModel
    let onAPIError: (Error) -> Void
    let onSessionCreated: (SessionSummary) -> Void
    let initialAttachments: [SharedAttachmentImport]
    let autoStartsVoiceInput: Bool
    let profileName: String?

    @State private var createdSession: SessionSummary?
    @State private var draftMessage = ""
    @State private var didStartCreation = false
    @State private var didRequestComposerFocus = false
    @State private var creationErrorMessage: String?
    @FocusState private var composerIsFocused: Bool

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil,
        server: URL,
        viewModel: SessionListViewModel,
        onAPIError: @escaping (Error) -> Void,
        onSessionCreated: @escaping (SessionSummary) -> Void = { _ in }
    ) {
        self.server = server
        self.viewModel = viewModel
        self.onAPIError = onAPIError
        self.onSessionCreated = onSessionCreated
        self.initialAttachments = initialAttachments
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
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
                    initialAttachments: initialAttachments,
                    loadsInitialMessages: false,
                    autoStartsVoiceInput: autoStartsVoiceInput
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
            await createSessionIfNeeded()
        }
    }

    private var pendingContent: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
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
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pendingComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Hermex", text: $draftMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composerIsFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.18), lineWidth: 0.5)
                }
                .submitLabel(.send)

            Button {} label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: Circle())
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
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button("Retry") {
                Task { await retryCreateSession() }
            }
            .font(.footnote.weight(.semibold))
            .disabled(viewModel.isCreatingSession)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func createSessionIfNeeded() async {
        guard !didStartCreation, createdSession == nil else { return }

        didStartCreation = true
        creationErrorMessage = nil
        let session = await viewModel.createSession(modelContext: modelContext, profile: profileName)
        guard !Task.isCancelled else { return }
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if let session {
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
