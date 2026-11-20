import SwiftUI
import UIKit

enum HermesHomeLayout {
    static func usesSplit(isHome: Bool, horizontalSizeClass: UserInterfaceSizeClass?,
                          verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isHome && horizontalSizeClass == .regular && verticalSizeClass != .compact
    }
}

struct SessionSplitView<Sidebar: View, Detail: View>: View {
    let rootRevision: Int
    var offersHideSidebar = false
    var sidebarRequests = 0
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isRoomy = false
    @State private var isCollapsedByUser = false
    @State private var detailColumn = DetailColumnNavigation()
    @State private var detailHasVerticalBar = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .toolbar(removing: offersSidebarToggle ? .sidebarToggle : nil)
                .navigationSplitViewColumnWidth(min: 280, ideal: 380, max: 420)
                .environment(\.splitDetailHasVerticalBar, detailHasVerticalBar)
        } detail: {
            NavigationStack {
                detail
                    .background { DetailColumnNavigationReader(column: detailColumn) }
                    .background {
                        VerticalBarReader { hasVerticalBar in
                            Color.clear.onChange(of: hasVerticalBar, initial: true) { detailHasVerticalBar = hasVerticalBar }
                        }
                    }
                    .toolbar {
                        if offersHideSidebar && columnVisibility.showsSidebar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Hide Sidebar", systemImage: "sidebar.left") {
                                    withAnimation(reduceMotion ? nil : .default) { columnVisibility = .detailOnly }
                                }
                            }
                        } else if offersSidebarToggle {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Show Sidebar", systemImage: "sidebar.left") {
                                    withAnimation(reduceMotion ? nil : .default) { columnVisibility = .doubleColumn }
                                }
                            }
                        }
                    }
            }
            .id(rootRevision)
        }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: Bool.self) { $0.size.width >= NavigationSplitViewVisibility.roomyWidth } action: { isRoomy in
            self.isRoomy = isRoomy
            columnVisibility = .settled(isRoomy: isRoomy, isCollapsedByUser: isCollapsedByUser)
        }
        .onChange(of: columnVisibility) { old, new in
            isCollapsedByUser = new.isCollapsedByUser(after: old, was: isCollapsedByUser)
        }
        .onChange(of: rootRevision) {
            columnVisibility = .settled(isRoomy: isRoomy, isCollapsedByUser: isCollapsedByUser)
            detailColumn.popToRoot()
        }
        .onChange(of: sidebarRequests) {
            if !columnVisibility.showsSidebar { columnVisibility = .doubleColumn }
        }
    }

    private var offersSidebarToggle: Bool { offersHideSidebar && detailHasVerticalBar }
}

@MainActor
private final class DetailColumnNavigation {
    weak var navigationController: UINavigationController?

    func popToRoot() {
        guard let navigationController, navigationController.viewControllers.count > 1 else { return }
        navigationController.popToRootViewController(animated: false)
    }
}

private struct DetailColumnNavigationReader: UIViewControllerRepresentable {
    let column: DetailColumnNavigation

    final class Controller: UIViewController {
        var column: DetailColumnNavigation?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if let navigationController {
                column?.navigationController = navigationController
            }
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.column = column
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}
}

extension NavigationSplitViewVisibility {
    static let roomyWidth: CGFloat = 850

    static func settled(isRoomy: Bool, isCollapsedByUser: Bool) -> Self {
        if isCollapsedByUser { return .detailOnly }
        return isRoomy ? .doubleColumn : .automatic
    }

    var showsSidebar: Bool {
        self == .doubleColumn || self == .all
    }

    func isCollapsedByUser(after old: Self, was wasCollapsed: Bool) -> Bool {
        if showsSidebar { return false }
        return wasCollapsed || (old.showsSidebar && self == .detailOnly)
    }
}

struct SessionListRowActions {
    let retryLoad: () -> Void
    let open: (SessionSummary) -> Void
    let toggleUnread: (SessionSummary) -> Void
    let togglePinned: (SessionSummary) -> Void
    let archive: (SessionSummary) -> Void
    let delete: (SessionSummary) -> Void
    let rename: (SessionSummary) -> Void
    let duplicate: (SessionSummary) -> Void
    let move: (SessionSummary, String?) -> Void
    let createProject: (SessionSummary) -> Void
    let refreshProjects: () -> Void
    let export: (SessionSummary, SessionExportFormat) -> Void
    var addServer: (() -> Void)?
}

enum SessionRowActionPolicy {
    static func offersMutationActions(for session: SessionSummary) -> Bool {
        !session.isSessionReadOnly && session.hermes?.isBotChat != true
    }

    static func offersProjectMove(for session: SessionSummary) -> Bool {
        offersMutationActions(for: session)
    }

    static func offersArchive(for session: SessionSummary) -> Bool {
        offersMutationActions(for: session) && session.archived != true
    }

    static func offersRemoveFromProject(for session: SessionSummary) -> Bool {
        session.hermes == nil
    }

    static func moveTargets(_ projects: [ProjectSummary]) -> [ProjectSummary] {
        projects.filter { project in project.hermes.map { !$0.isAutomatic && $0.folder != nil } ?? true }
    }

    static func offersProjectEditing(_ project: ProjectSummary) -> Bool {
        project.hermes?.isAutomatic != true
    }

    static func exportFormats(for session: SessionSummary) -> [SessionExportFormat] {
        session.hermes == nil ? [.html, .json] : [.json]
    }

    static func canDuplicate(_ session: SessionSummary) -> Bool {
        offersMutationActions(for: session) && !session.requiresExternalImport
    }

    static func canExport(_ session: SessionSummary, isViewingCachedData: Bool) -> Bool {
        !isViewingCachedData && hasServerSessionID(session)
    }

    static func deepLinkURL(
        for session: SessionSummary,
        server: URL,
        isViewingCachedData: Bool,
        isMutating: Bool
    ) -> URL? {
        guard !isMutating, session.hermes?.isBotChat != true,
              canExport(session, isViewingCachedData: isViewingCachedData),
              let sessionID = session.sessionId
        else {
            return nil
        }

        guard session.hermes != nil else { return HermesDeepLink.sessionURL(sessionID: sessionID) }
        return HermesDeepLink.sessionURL(for: HermesSessionDestination(server: server, profile: session.profile, key: sessionID))
    }

}

enum SessionListMotion {
    static func disclosureAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0)
    }

    static func searchChromeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0)
    }

    static func searchFocusAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    static func pressAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18, extraBounce: 0)
    }

    static func sessionMutationAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0)
    }

    static func sessionRowTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    static func disclosureContentTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

struct SessionsHeader: View {
    struct Field {
        let isExpanded: Bool
        let text: Binding<String>
        let isFocused: FocusState<Bool>.Binding
        let close: () -> Void
    }

    struct Avatar {
        let initials: String
        let color: Color
        let foreground: Color
        let servers: AvatarServerSwitcherModel
        let openSettings: () -> Void
        let switchToServer: (ServerAccount) -> Void
        let addServer: () -> Void
        let manageServers: () -> Void
    }

    private static let iconVisualSize: CGFloat = 36
    private static let iconHitTarget: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeBarOwnsSearch) private var barOwnsSearch
    let logoColor: Color
    let avatar: Avatar
    var field: Field?
    var searchLabel: LocalizedStringKey = "Search sessions"
    var isSearchDisabled = false
    var connection = HomeConnectionStatus.Facts()
    var reconnectNow: () -> Void = {}
    let openSearch: () -> Void
    @State private var connectionStatus = DelayedStatusDriver<HomeConnectionStatus>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: isExpanded ? 0 : 16) {
                HermesHeaderLogo(selectedColor: logoColor)
                    .frame(width: isExpanded ? 0 : 160, alignment: .leading)
                    .opacity(isExpanded ? 0 : 1)
                    .clipped()
                    .accessibilityHidden(isExpanded)

                if isExpanded || !barOwnsSearch {
                    pill
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            HomeConnectionStatusLine(driver: connectionStatus, reconnectNow: reconnectNow)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .animation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(SessionListMotion.searchFocusAnimation(reduceMotion: reduceMotion), value: showsClearButton)
        .drivesHomeConnectionStatus(connectionStatus, connection: connection)
    }

    private var isExpanded: Bool { field?.isExpanded == true }

    private var showsClearButton: Bool {
        guard let field else { return false }
        return field.isExpanded && !field.text.wrappedValue.isEmpty
    }

    private var pill: some View {
        HStack(spacing: isExpanded ? 8 : 4) {
            HapticButton {
                if isExpanded, let field {
                    field.isFocused.wrappedValue = true
                } else {
                    openSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isExpanded ? .appSecondary : .appPrimary)
                    .frame(width: Self.iconVisualSize, height: Self.iconVisualSize)
                    .frame(width: Self.iconHitTarget, height: Self.iconHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSearchDisabled)
            .accessibilityLabel(isExpanded ? Text("Focus session search") : Text(searchLabel))
            .accessibilityHint(field == nil ? Text(verbatim: "") : Text("Shows the session search field."))
            .accessibilityHidden(isExpanded)

            if let field {
                textField(field)

                if showsClearButton {
                    clearButton(field)
                        .transition(.scale.combined(with: .opacity))
                }
            } else {
                Color.clear.frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }

            trailingButton
        }
        .padding(.vertical, 2)
        .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .trailing)
        .sessionsChromeGlass(isInteractive: true, in: Capsule())
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    private func textField(_ field: Field) -> some View {
        TextField("Search sessions", text: field.text)
            .font(AppFont.subheadline())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused(field.isFocused)
            .submitLabel(.done)
            .lineLimit(1)
            .layoutPriority(1)
            .frame(maxWidth: isExpanded ? .infinity : 0)
            .opacity(isExpanded ? 1 : 0)
            .clipped()
            .accessibilityHidden(!isExpanded)
    }

    private func clearButton(_ field: Field) -> some View {
        Button {
            field.text.wrappedValue = ""
            field.isFocused.wrappedValue = true
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .frame(width: Self.iconVisualSize, height: Self.iconVisualSize)
                .frame(width: Self.iconHitTarget, height: Self.iconHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
    }

    private var trailingButton: some View {
        HapticButton(feedbackStyle: .medium) {
            if isExpanded, let field {
                field.close()
            } else {
                avatar.openSettings()
            }
        } label: {
            ZStack {
                Text(avatar.initials)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(avatar.foreground)
                    .frame(width: Self.iconVisualSize, height: Self.iconVisualSize)
                    .background(avatar.color, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .opacity(isExpanded ? 0 : 1)
                    .scaleEffect(isExpanded ? 0.72 : 1)
                    .rotationEffect(.degrees(isExpanded ? -18 : 0))

                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.appPrimary)
                    .frame(width: Self.iconVisualSize, height: Self.iconVisualSize)
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.72)
                    .rotationEffect(.degrees(isExpanded ? 0 : 18))
            }
            .frame(width: Self.iconHitTarget, height: Self.iconHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Close search" : "Settings")
        .accessibilityHint(
            isExpanded
                ? "Closes search and clears the current query."
                : "Opens Settings. Long press to switch servers."
        )
        .contextMenu {
            if !isExpanded {
                AvatarServerSwitcherMenu(
                    model: avatar.servers,
                    switchToServer: avatar.switchToServer,
                    addServer: avatar.addServer,
                    manageServers: avatar.manageServers
                )
            }
        }
    }
}

struct SidebarSectionVisibility: Equatable {
    var bots: Bool
    var tasks: Bool
    var kanban: Bool
    var skills: Bool
    var memory: Bool
    var insights: Bool
    var activeProfile: Bool
    var projects: Bool

    static let showAll = SidebarSectionVisibility(
        bots: true,
        tasks: true,
        kanban: true,
        skills: true,
        memory: true,
        insights: true,
        activeProfile: true,
        projects: true
    )

    var showsAnyUtilityLink: Bool {
        bots || tasks || kanban || skills || memory || insights
    }
}

struct SessionSidebarUtilityRows: View {
    private static let rowSpacing: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    let topPadding: CGFloat
    let automatedVisibility: AutomatedSessionVisibility
    let sectionVisibility: SidebarSectionVisibility
    @Binding var profilesAreExpanded: Bool
    @Binding var projectsAreExpanded: Bool
    @Binding var selectedProjectID: String?
    @Binding var projectPendingDeletion: ProjectSummary?
    @Binding var projectPendingRename: ProjectSummary?

    let openDestination: (SessionListUtilityDestination) -> Void
    let switchActiveProfile: (ProfileSummary) -> Void
    let presentProjectCreation: () -> Void

    var body: some View {
        if sectionVisibility.showsAnyUtilityLink {
            utilityLinks
                .padding(.top, topPadding)
                .sessionsScreenListRow()
        }

        if showsActiveProfile {
            activeProfileHeader
                .padding(.top, activeProfileTopPadding)
                .sessionsScreenListRow()

            if profilesAreExpanded {
                activeProfileOptionRows
            }
        }

        if sectionVisibility.projects {
            projectsHeader
                .padding(.top, projectsTopPadding)
                .sessionsScreenListRow()

            if projectsAreExpanded {
                projectOptionRows
            }
        }
    }

    private var showsActiveProfile: Bool {
        sectionVisibility.activeProfile && !viewModel.isSingleProfileMode
    }

    private var activeProfileTopPadding: CGFloat {
        sectionVisibility.showsAnyUtilityLink ? Self.rowSpacing : topPadding
    }

    private var projectsTopPadding: CGFloat {
        sectionVisibility.showsAnyUtilityLink || showsActiveProfile ? Self.rowSpacing : topPadding
    }

    private func disclosureSubrow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 24)
            .padding(.top, Self.rowSpacing)
            .sessionsScreenListRow()
            .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
    }

    private var utilityLinks: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            if sectionVisibility.bots {
                SidebarNavButton(title: String(localized: "Bots"), assetImage: "LucideBot") {
                    openDestination(.bots)
                }
            }

            if sectionVisibility.tasks {
                SidebarNavButton(title: String(localized: "Tasks"), assetImage: "LucideCalendarClock") {
                    openDestination(.tasks)
                }
            }

            if sectionVisibility.kanban {
                SidebarNavButton(title: String(localized: "Kanban"), assetImage: "LucideColumns3") {
                    openDestination(.kanban)
                }
            }

            if sectionVisibility.skills {
                SidebarNavButton(title: String(localized: "Skills"), assetImage: "LucideHammer") {
                    openDestination(.skills)
                }
            }

            if sectionVisibility.memory {
                SidebarNavButton(title: String(localized: "Memory"), assetImage: "LucideBrain") {
                    openDestination(.memory)
                }
            }

            if sectionVisibility.insights {
                SidebarNavButton(title: String(localized: "Usage"), assetImage: "LucideChartColumnIncreasing") {
                    openDestination(.insights)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var activeProfileHeader: some View {
        SidebarDisclosureButton(
            title: String(localized: "Active Profile"),
            assetImage: "LucideUserRoundCog",
            isExpanded: profilesAreExpanded,
            tint: viewModel.activeProfileErrorMessage == nil ? Color(.appText) : .orange
        ) {
            profilesAreExpanded.toggle()
        } accessory: {
            if viewModel.isLoadingActiveProfile {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityLabel(profilesAreExpanded ? "Collapse active profile picker" : "Expand active profile picker")
    }

    @ViewBuilder
    private var activeProfileOptionRows: some View {
        if viewModel.isLoadingActiveProfile && viewModel.profileOptions.isEmpty {
            disclosureSubrow {
                CompactStatusRow(title: String(localized: "Loading profiles..."), systemImage: "person.crop.circle")
            }
        } else if viewModel.profileOptions.isEmpty {
            disclosureSubrow {
                CompactStatusRow(
                    title: viewModel.activeProfileErrorMessage == nil ? String(localized: "No profiles") : String(localized: "Could not load profiles"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        } else {
            ForEach(viewModel.profileOptions) { profile in
                let profileIsActive = isActiveProfile(profile)

                disclosureSubrow {
                    ActiveProfilePickerRow(
                        profile: profile,
                        isSelected: profileIsActive,
                        isSwitching: viewModel.isSwitchingActiveProfile
                            && viewModel.switchingActiveProfileName == profile.normalizedName
                    ) {
                        guard !profileIsActive else { return }
                        switchActiveProfile(profile)
                    }
                    .disabled(
                        viewModel.isViewingCachedData
                            || viewModel.isSwitchingActiveProfile
                            || profile.normalizedName == nil
                    )
                }
            }
        }
    }

    private var projectsHeader: some View {
        HStack(spacing: 8) {
            SidebarDisclosureButton(
                title: String(localized: "Projects"),
                assetImage: "LucideFolder",
                isExpanded: projectsAreExpanded
            ) {
                projectsAreExpanded.toggle()
            } accessory: {
                EmptyView()
            }
            .accessibilityLabel(projectsAreExpanded ? "Collapse projects" : "Expand projects")

            if projectsAreExpanded {
                addProjectButton
            }

            if selectedProjectID != nil {
                HapticButton {
                    withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
                        selectedProjectID = nil
                    }
                } label: {
                    Text("All")
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .background(.appMaterial(.thinMaterial), in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(.appSecondary)
                .buttonStyle(.plain)
                .accessibilityLabel("Show all projects")
                .accessibilityHint("Clears the selected project filter.")
            }
        }
        .padding(.horizontal, 24)
    }

    private var addProjectButton: some View {
        HapticButton {
            presentProjectCreation()
        } label: {
            Image(systemName: "plus")
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add project")
        .accessibilityHint("Creates a new empty project.")
    }

    @ViewBuilder
    private var projectOptionRows: some View {
        if viewModel.isLoadingProjects && viewModel.projects.isEmpty {
            disclosureSubrow {
                CompactStatusRow(title: String(localized: "Loading projects..."), systemImage: "folder")
            }
        } else if viewModel.projects.isEmpty {
            disclosureSubrow {
                CompactStatusRow(title: String(localized: "No projects"), systemImage: "folder")
            }
        } else {
            ForEach(viewModel.projects) { project in
                disclosureSubrow {
                    ProjectFilterRow(
                        project: project,
                        isSelected: selectedProjectID == project.projectId,
                        count: sessionCount(for: project),
                        isViewingCachedData: viewModel.isViewingCachedData,
                        isRenamingProject: viewModel.isRenamingProject,
                        isDeletingProject: viewModel.isDeletingProject
                    ) {
                        guard let projectID = project.projectId else { return }

                        withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
                            selectedProjectID = selectedProjectID == projectID ? nil : projectID
                        }
                    } rename: {
                        projectPendingRename = project
                    } delete: {
                        projectPendingDeletion = project
                    }
                }
            }
        }
    }

    private func isActiveProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }

        if let activeProfileName = viewModel.activeProfileName {
            return profileName == activeProfileName
        }

        return profile.isActive == true
    }

    private func sessionCount(for project: ProjectSummary) -> Int {
        if let hermes = project.hermes { return hermes.sessionCount }
        guard let projectID = project.projectId else { return 0 }
        return viewModel.sessions.filter { session in
            session.projectId == projectID && automatedVisibility.shows(session)
        }.count
    }
}

enum HomeConnectionStatus: Equatable {
    struct Facts: Equatable {
        var keepsRows = false
        var isReconnecting = false
    }

    case reconnecting
    case offline

    static let policy = DelayedStatusPolicy(showAfter: .milliseconds(800))

    init?(_ facts: Facts, isOnline: Bool) {
        guard facts.keepsRows, !isOnline || facts.isReconnecting else { return nil }
        self = isOnline ? .reconnecting : .offline
    }
}

struct HomeConnectionStatusLine: View {
    let driver: DelayedStatusDriver<HomeConnectionStatus>
    let reconnectNow: () -> Void

    var body: some View {
        DelayedStatusView(driver: driver) { status in
            Group {
                switch status {
                case .reconnecting:
                    Button("Reconnecting…", action: reconnectNow)
                        .buttonStyle(.plain)
                        .accessibilityHint("Reconnects now.")
                case .offline:
                    Text("Offline · showing last known status")
                }
            }
            .font(AppFont.footnote())
            .foregroundStyle(.appSecondary)
            .transition(.opacity)
        }
    }
}

extension View {
    func drivesHomeConnectionStatus(_ driver: DelayedStatusDriver<HomeConnectionStatus>,
                                    connection: HomeConnectionStatus.Facts) -> some View {
        modifier(HomeConnectionStatusDriving(driver: driver, connection: connection))
    }
}

private struct HomeConnectionStatusDriving: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let driver: DelayedStatusDriver<HomeConnectionStatus>
    let connection: HomeConnectionStatus.Facts

    func body(content: Content) -> some View {
        let target = HomeConnectionStatus(connection, isOnline: NetworkPathMonitor.shared.isSatisfied)
        content.task(id: target) {
            await driver.run(target: target, policy: HomeConnectionStatus.policy, immediately: target == .offline,
                             animation: reduceMotion ? nil : .easeInOut(duration: 0.2))
        }
    }
}

struct SessionListRowsSection: View {
    let viewModel: SessionListViewModel
    var searchText: String = ""
    let sessions: [SessionSummary]
    let emptyTitle: String
    let emptyDescription: String?
    let isSearchActive: Bool
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions
    var suppressEmptyState = false
    var showsErrorOverRows = false

    var body: some View {
        sessionsHeaderRow
            .padding(.top, isSearchActive ? 16 : 28)
            .sessionsScreenListRow()

        if showsErrorOverRows, let errorMessage = viewModel.hermesRefusalOverRows {
            sessionsErrorRow(message: errorMessage)
                .sessionsScreenListRow()
        }

        if viewModel.isLoading && viewModel.sessions.isEmpty {
            sessionLoadingSkeletonRows
        } else if let errorMessage = viewModel.errorMessage, viewModel.sessions.isEmpty {
            sessionsErrorRow(message: errorMessage)
                .sessionsScreenListRow()
        } else if sessions.isEmpty && !suppressEmptyState {
            SessionListStatusRow(
                title: emptyTitle,
                description: emptyDescription,
                systemImage: "bubble.left"
            )
                .padding(.horizontal, 24)
                .sessionsScreenListRow()
        } else {
            ForEach(sessions) { session in
                SessionInteractiveRow(
                    viewModel: viewModel,
                    session: session,
                    showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace,
                    selectedSessionID: selectedSessionID,
                    actions: actions,
                    searchText: searchText
                )
            }
        }
    }

    private var sessionsHeaderRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !isSearchActive {
                    Text("Sessions")
                        .font(AppFont.title3().bold())
                        .foregroundStyle(.appPrimary)
                }

                Spacer()

                if viewModel.isSearchingRemoteSessions {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching sessions")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var sessionLoadingSkeletonRows: some View {
        ForEach(Array(SessionRowSkeletonConfiguration.loadingRows.enumerated()), id: \.element.id) { index, row in
            SessionRowSkeletonView(
                configuration: row,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace
            )
            .sessionsScreenListRow(insets: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading sessions")
            .accessibilityHidden(index > 0)
        }
        .allowsHitTesting(false)
    }

    private func sessionsErrorRow(message errorMessage: String) -> some View {
        let content = Self.errorContent(for: viewModel.sessionLoadError, fallbackMessage: errorMessage)

        return VStack(alignment: .leading, spacing: 10) {
            SessionListStatusRow(
                title: content.title,
                description: content.description,
                systemImage: "exclamationmark.triangle",
                descriptionLineLimit: 3
            )

            Group {
                if let addServer = actions.addServer, viewModel.sessionLoadError as? BotFailure == .gatewayListener {
                    Button("Add Server", action: addServer)
                } else {
                    Button("Retry", action: actions.retryLoad)
                        .accessibilityLabel("Retry loading sessions")
                        .accessibilityHint("Attempts to reconnect to the server and reload sessions.")
                }
            }
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(.appPrimary)
            .buttonStyle(.plain)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 24)
    }

    static func errorContent(for error: Error?, fallbackMessage: String) -> (title: String, description: String) {
        if let error, !(error is BotFailure), CacheFallbackPolicy.shouldUseCache(for: error) {
            return (
                String(localized: "Cannot reach server"),
                String(localized: "Check that your Mac is awake and cloudflared is running.")
            )
        }

        return (String(localized: "Could not load sessions"), fallbackMessage)
    }

}

struct SessionInteractiveRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    let session: SessionSummary
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions
    var searchText: String = ""

    var body: some View {
        Button {
            actions.open(session)
        } label: {
            SessionRowView(
                session: session,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                isViewingCachedData: viewModel.isViewingCachedData,
                isCachedCopyProvisional: viewModel.isCachedCopyProvisional,
                isUnread: viewModel.isUnread(session),
                attentionState: viewModel.attentionState(for: session),
                isAttentionStale: viewModel.attentionStatesAreStale,
                searchExcerpt: viewModel.searchExcerpt(for: session, searchText: searchText),
                labelsArchived: true,
                profileTag: viewModel.hermesShowsAllProfiles ? session.profile : nil
            )
        }
        .buttonStyle(.plain)
        .id(session.id)
        .background(
            session.sessionId == selectedSessionID
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .transition(SessionListMotion.sessionRowTransition(reduceMotion: reduceMotion))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            sessionLeadingSwipeActions(for: session)
        }
        .swipeActions(
            edge: .trailing,
            allowsFullSwipe: SessionRowActionPolicy.offersArchive(for: session)
                && canShowSessionMutationActions(for: session)
                && !viewModel.isMutating(session)
        ) {
            sessionTrailingSwipeActions(for: session)
        }
        .contextMenu {
            SessionRowContextMenu(
                session: session,
                server: viewModel.server,
                projects: viewModel.projects,
                isViewingCachedData: viewModel.isViewingCachedData,
                isRenamingSession: viewModel.isRenamingSession,
                isCreatingProject: viewModel.isCreatingProject,
                isMovingSession: viewModel.isMovingSession,
                isLoadingProjects: viewModel.isLoadingProjects,
                isMutating: viewModel.isMutating(session),
                isUnread: viewModel.isUnread(session),
                canToggleUnread: viewModel.canToggleUnread(session),
                actions: actions
            )
        }
        .sessionsScreenListRow(insets: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    }

    @ViewBuilder
    private func sessionLeadingSwipeActions(for session: SessionSummary) -> some View {
        if canShowSessionMutationActions(for: session) {
            Button {
                actions.togglePinned(session)
            } label: {
                Label(session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.accentColor)
        }
    }

    @ViewBuilder
    private func sessionTrailingSwipeActions(for session: SessionSummary) -> some View {
        if canShowSessionMutationActions(for: session) {
            if SessionRowActionPolicy.offersArchive(for: session) {
                Button {
                    actions.archive(session)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(viewModel.isMutating(session))
                .tint(.orange)
            }

            Button {
                actions.delete(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.red)
        }
    }

    private func canShowSessionMutationActions(for session: SessionSummary) -> Bool {
        SessionRowActionPolicy.offersMutationActions(for: session)
            && !viewModel.isViewingCachedData
            && hasServerSessionID(session)
    }
}

struct ScheduledSessionsDisclosure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    var searchText: String = ""
    let sessions: [SessionSummary]
    let totalCount: Int
    let isSearchActive: Bool
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    @Binding var userIsExpanded: Bool
    let actions: SessionListRowActions
    let viewAll: () -> Void

    private var isExpanded: Bool { isSearchActive || userIsExpanded }
    private var displayedSessions: [SessionSummary] {
        isSearchActive ? sessions : Array(sessions.prefix(5))
    }

    var body: some View {
        SidebarDisclosureButton(
            title: String(localized: "Scheduled sessions"),
            assetImage: "LucideCalendarClock",
            isExpanded: isExpanded
        ) {
            guard !isSearchActive else { return }
            userIsExpanded.toggle()
        } accessory: {
            Text("\(totalCount)")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.appMaterial(.thinMaterial), in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.top, isSearchActive ? 16 : 12)
        .sessionsScreenListRow()
        .accessibilityLabel(
            isSearchActive
                ? String(localized: "Scheduled sessions")
                : isExpanded
                    ? String(localized: "Collapse scheduled sessions")
                    : String(localized: "Expand scheduled sessions")
        )

        if isExpanded {
            ForEach(displayedSessions) { session in
                SessionInteractiveRow(
                    viewModel: viewModel,
                    session: session,
                    showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace,
                    selectedSessionID: selectedSessionID,
                    actions: actions,
                    searchText: searchText
                )
                .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
            }

            if !isSearchActive && totalCount > 5 {
                HapticButton(action: viewAll) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 24)
                        Text("View all")
                            .font(AppFont.subheadline(weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(AppFont.caption(weight: .semibold))
                    }
                    .foregroundStyle(.appSecondary)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sessionsScreenListRow()
                .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
            }
        }
    }
}

struct NeedsYouSessionsSection: View {
    let viewModel: SessionListViewModel
    let sessions: [SessionSummary]
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions

    var body: some View {
        HStack(spacing: 8) {
            Text("Needs you")
            Spacer(minLength: 0)
            Text("\(sessions.count)")
        }
        .font(AppFont.footnote(weight: .semibold))
        .foregroundStyle(.appSecondary)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Needs you"))
        .accessibilityValue(Text("\(sessions.count) sessions"))
        .accessibilityAddTraits(.isHeader)
        .sessionsScreenListRow()

        ForEach(sessions) { session in
            SessionInteractiveRow(
                viewModel: viewModel,
                session: session,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                selectedSessionID: selectedSessionID,
                actions: actions
            )
        }
    }
}

struct ScheduledSessionsView: View {
    let viewModel: SessionListViewModel
    let showsCronSessions: Bool
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions
    let actionToast: ActionToastState?

    @State private var searchText = ""

    var body: some View {
        AppList(rows: .plain) {
            if sessions.isEmpty {
                SessionListStatusRow(
                    title: searchText.isEmpty
                        ? String(localized: "No sessions yet")
                        : String(localized: "No matching sessions"),
                    description: searchText.isEmpty
                        ? nil
                        : String(localized: "Try another search or project filter."),
                    systemImage: "calendar.badge.clock"
                )
                .padding(.horizontal, 24)
                .sessionsScreenListRow()
            } else {
                ForEach(sessions) { session in
                    SessionInteractiveRow(
                        viewModel: viewModel,
                        session: session,
                        showsMessageCount: showsMessageCount,
                        showsWorkspace: showsWorkspace,
                        selectedSessionID: selectedSessionID,
                        actions: actions,
                        searchText: searchText
                    )
                }
            }
            if viewModel.isHermes && viewModel.hasMoreScheduledSessions && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Load more") { Task { await viewModel.loadMoreHermesScheduledSessions() } }
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appSecondary)
                    .disabled(viewModel.isLoadingMoreScheduledSessions)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .sessionsScreenListRow()
                    .onAppear { Task { await viewModel.loadMoreHermesScheduledSessions() } }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .themedPageBackground()
        .navigationTitle("Scheduled sessions")
        .searchable(text: $searchText, prompt: "Search sessions")
        .task(id: searchText) {
            if viewModel.isHermes { await viewModel.searchSessions(query: searchText) }
        }
        .overlay(alignment: .bottom) {
            if let actionToast {
                ActionToastView(state: actionToast)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
            }
        }
    }

    private var sessions: [SessionSummary] {
        guard showsCronSessions else { return [] }

        return viewModel.visibleSessions(searchText: searchText, selectedProjectID: nil)
            .filter { $0.isCronSession && $0.archived != true }
    }
}

struct SessionRowContextMenu: View {
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    let session: SessionSummary
    let server: URL
    let projects: [ProjectSummary]
    let isViewingCachedData: Bool
    let isRenamingSession: Bool
    let isCreatingProject: Bool
    let isMovingSession: Bool
    let isLoadingProjects: Bool
    let isMutating: Bool
    let isUnread: Bool
    let canToggleUnread: Bool
    let actions: SessionListRowActions

    var body: some View {
        let fullTitle = SessionRowView.displayTitle(for: session)

        Section("Full Title") {
            Text(fullTitle)

            Button {
                UIPasteboard.general.string = fullTitle
                ChatHaptics.copied(isEnabled: isHapticsEnabled)
            } label: {
                Label("Copy Full Title", systemImage: "doc.on.doc")
            }
        }

        Button {
            actions.toggleUnread(session)
        } label: {
            Label(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge")
        }
        .disabled(!canToggleUnread)

        if SessionRowActionPolicy.offersMutationActions(for: session) {
            Button {
                actions.togglePinned(session)
            } label: {
                Label(session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
            .disabled(!canShowSessionMutationActions || isMutating)

            Button {
                actions.rename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(isViewingCachedData || isRenamingSession || !hasServerSessionID(session))

            if SessionRowActionPolicy.canDuplicate(session) {
                Button {
                    actions.duplicate(session)
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                .disabled(isViewingCachedData || session.sessionId == nil || isMutating)
            }

            if SessionRowActionPolicy.offersProjectMove(for: session) {
                Menu {
                    SessionProjectMoveMenu(
                        session: session,
                        projects: projects,
                        isCreatingProject: isCreatingProject,
                        isMovingSession: isMovingSession,
                        isLoadingProjects: isLoadingProjects,
                        actions: actions
                    )
                } label: {
                    Label("Move to Project", systemImage: "folder")
                }
                .disabled(isViewingCachedData || session.sessionId == nil || isMutating)
            }
        }

        exportMenu

        if SessionRowActionPolicy.offersMutationActions(for: session) {
            if SessionRowActionPolicy.offersArchive(for: session) {
                Button {
                    actions.archive(session)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(!canShowSessionMutationActions || isMutating)
            }

            Button(role: .destructive) {
                actions.delete(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canShowSessionMutationActions || isMutating)
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(SessionRowActionPolicy.exportFormats(for: session), id: \.self) { format in
                switch format {
                case .html:
                    Button {
                        actions.export(session, .html)
                    } label: {
                        Label("Export as HTML", systemImage: "doc.richtext")
                    }
                case .json:
                    Button {
                        actions.export(session, .json)
                    } label: {
                        Label("Export as JSON", systemImage: "curlybraces")
                    }
                }
            }

            if let deepLinkURL = SessionRowActionPolicy.deepLinkURL(
                for: session,
                server: server,
                isViewingCachedData: isViewingCachedData,
                isMutating: isMutating
            ) {
                Button {
                    UIPasteboard.general.string = deepLinkURL.absoluteString
                    ChatHaptics.copied(isEnabled: isHapticsEnabled)
                } label: {
                    Label("Copy Deeplink", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(!canExportSession || isMutating)
    }

    private var canShowSessionMutationActions: Bool {
        SessionRowActionPolicy.offersMutationActions(for: session)
            && !isViewingCachedData
            && hasServerSessionID(session)
    }

    private var canExportSession: Bool {
        SessionRowActionPolicy.canExport(session, isViewingCachedData: isViewingCachedData)
    }
}

struct SessionProjectMoveMenu: View {
    let session: SessionSummary
    let projects: [ProjectSummary]
    let isCreatingProject: Bool
    let isMovingSession: Bool
    let isLoadingProjects: Bool
    let actions: SessionListRowActions

    var body: some View {
        let offersRemove = SessionRowActionPolicy.offersRemoveFromProject(for: session)
        let targets = SessionRowActionPolicy.moveTargets(projects)

        if offersRemove {
            Button {
                actions.move(session, nil)
            } label: {
                Label("No project", systemImage: session.projectId == nil ? "checkmark" : "tray")
            }
            .disabled(isMovingSession || session.projectId == nil)
        }

        if !targets.isEmpty {
            if offersRemove {
                Divider()
            }

            ForEach(targets) { project in
                let projectID = project.projectId
                let isSelected = session.projectId == projectID
                let projectName = project.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled Project")

                Button {
                    actions.move(session, projectID)
                } label: {
                    Label(
                        projectName,
                        systemImage: isSelected ? "checkmark" : "folder"
                    )
                }
                .disabled(isMovingSession || projectID == nil || isSelected)
            }
        }

        if offersRemove || !targets.isEmpty {
            Divider()
        }

        Button {
            actions.createProject(session)
        } label: {
            Label("New Project", systemImage: "folder.badge.plus")
        }
        .disabled(isCreatingProject || isMovingSession)

        if projects.isEmpty {
            Button {
                actions.refreshProjects()
            } label: {
                Label("Refresh Projects", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingProjects)
        }
    }
}

struct AvatarServerSwitcherModel: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        let account: ServerAccount
        let displayName: String
        let isActive: Bool
    }

    let entries: [Entry]

    var activeID: String? { entries.first(where: \.isActive)?.id }

    init(servers: [ServerAccount], activeServerID: String?) {
        entries = servers.map { account in
            let hostFallback = URL(string: account.urlString)?.host ?? account.urlString
            let displayName = account.displayName.isEmpty ? hostFallback : account.displayName
            return Entry(
                id: account.id,
                account: account,
                displayName: displayName,
                isActive: account.id == activeServerID
            )
        }
    }
}

struct AvatarServerSwitcherMenu: View {
    let model: AvatarServerSwitcherModel
    let switchToServer: (ServerAccount) -> Void
    let addServer: () -> Void
    let manageServers: () -> Void

    var body: some View {
        Section("Servers") {
            ForEach(model.entries) { entry in
                Button {
                    switchToServer(entry.account)
                } label: {
                    Label(entry.displayName, systemImage: entry.isActive ? "checkmark" : "server.rack")
                }
                .disabled(entry.isActive)
                .accessibilityLabel(
                    entry.isActive
                        ? String(localized: "\(entry.displayName), active server")
                        : String(localized: "Switch to \(entry.displayName)")
                )
            }
        }

        Section {
            Button {
                addServer()
            } label: {
                Label("Add Server…", systemImage: "plus")
            }

            Button {
                manageServers()
            } label: {
                Label("Manage Servers", systemImage: "gearshape")
            }
        }
    }
}

extension View {
    func sessionsScreenListRow(insets: EdgeInsets = EdgeInsets()) -> some View {
        listRowInsets(insets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color(.appCanvas))
    }

    func sessionsTopChromeListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 18, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .zIndex(1)
    }

    func sessionsChromeGlass<S: InsettableShape>(
        isInteractive: Bool = false,
        tint: Color? = nil,
        fallbackMaterial: Material = .ultraThinMaterial,
        in shape: S
    ) -> some View {
        adaptiveGlass(
            .regular,
            isInteractive: isInteractive,
            tint: tint,
            fallbackMaterial: fallbackMaterial,
            in: shape
        )
    }
}

struct SessionExportShareItem: Identifiable {
    let fileURL: URL

    var id: String { fileURL.absoluteString }
}

private func hasServerSessionID(_ session: SessionSummary) -> Bool {
    guard let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }

    return !sessionID.isEmpty
}

struct SessionListFloatingChatButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.975 : 1))
            .opacity(isPressed ? 0.96 : 1)
            .shadow(
                color: .black.opacity(isPressed ? 0.10 : 0.18),
                radius: isPressed ? 8 : 18,
                y: isPressed ? 3 : 8
            )
            .animation(SessionListMotion.pressAnimation(reduceMotion: reduceMotion), value: isPressed)
    }
}

struct SidebarNavButton: View {
    let title: String
    let assetImage: String
    let action: () -> Void

    var body: some View {
        HapticButton(action: action) {
            HStack(spacing: 18) {
                SidebarUtilityIcon(assetImage: assetImage)

                Text(title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.appPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SidebarDisclosureButton<Accessory: View>: View {
    let title: String
    let assetImage: String
    let isExpanded: Bool
    var tint: Color = Color(.appText)
    let action: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HapticButton(action: action) {
            HStack(alignment: .center, spacing: 18) {
                SidebarUtilityIcon(assetImage: assetImage, tint: tint)

                Text(title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.appPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                accessory()

                SidebarDisclosureChevron(isExpanded: isExpanded)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarDisclosureChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.forward")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.appSecondary)
            .frame(width: 24, height: 24)
            .rotationEffect(
                .degrees(RTLLayout.disclosureChevronRotationDegrees(
                    isExpanded: isExpanded,
                    isRightToLeft: layoutDirection == .rightToLeft
                )),
                anchor: .center
            )
            .frame(width: 24, height: 40)
            .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
            .accessibilityHidden(true)
    }
}

struct SidebarUtilityIcon: View {
    let assetImage: String
    var tint: Color = Color(.appText)

    var body: some View {
        Image(assetImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
            .foregroundStyle(tint)
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}

struct SidebarSelectedSubrowIndicator: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(AppFont.caption2(weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color.accentColor, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SidebarSubrowSelectionStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                        }
                }
            }
    }
}

extension View {
    func sidebarSubrowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarSubrowSelectionStyle(isSelected: isSelected))
    }
}

struct ActiveProfilePickerRow: View {
    let profile: ProfileSummary
    let isSelected: Bool
    let isSwitching: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                SidebarUtilityIcon(
                    assetImage: "LucideUserRound",
                    tint: isSelected ? Color.accentColor : Color(.appText)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(AppFont.body())
                        .foregroundStyle(.appPrimary)
                        .lineLimit(1)

                    Text(defaultModelTitle)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    SidebarSelectedSubrowIndicator()
                }
            }
            .frame(minHeight: 44)
            .sidebarSubrowSelectionStyle(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var defaultModelTitle: String {
        let model = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else {
            return String(localized: "Default model unavailable")
        }
        return model
    }

    private var accessibilityLabel: String {
        let state = isSelected ? String(localized: "Active profile") : String(localized: "Profile")
        let switchingState = isSwitching ? String(localized: ", switching in progress") : ""
        return String(localized: "\(state), \(profile.displayName), \(defaultModelTitle)\(switchingState)")
    }
}

struct ProjectFilterRow: View {
    let project: ProjectSummary
    let isSelected: Bool
    let count: Int
    let isViewingCachedData: Bool
    let isRenamingProject: Bool
    let isDeletingProject: Bool
    let action: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 18) {
                    SidebarUtilityIcon(assetImage: "LucideFolder", tint: projectColor)

                    Text(displayName)
                        .font(AppFont.body())
                        .foregroundStyle(.appPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        if count > 0 {
                            Text("\(count)")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(.appSecondary)
                        }

                        if isSelected {
                            SidebarSelectedSubrowIndicator()
                        }
                    }
                }
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(isSelected ? "Clears this project filter." : "Filters sessions to this project.")

            if SessionRowActionPolicy.offersProjectEditing(project) {
                actionsMenu
            }
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                    }
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                rename()
            } label: {
                Label("Rename Project", systemImage: "pencil")
            }
            .disabled(projectActionsAreDisabled)

            Button(role: .destructive) {
                delete()
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
            .disabled(projectActionsAreDisabled)
        } label: {
            Label(String(localized: "Project actions for \(displayName)"), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Project actions for \(displayName)"))
        .accessibilityHint("Shows rename and delete actions for this project.")
    }

    private var displayName: String {
        let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Untitled Project")
        }
        return name
    }

    private var accessibilityValue: String {
        let countTitle = String(localized: "\(count) sessions")
        return isSelected ? String(localized: "Selected, \(countTitle)") : countTitle
    }

    private var projectActionsAreDisabled: Bool {
        isViewingCachedData
            || isRenamingProject
            || isDeletingProject
            || project.projectId == nil
    }

    private var projectColor: Color {
        if let apiColor = Color(hexString: project.color) {
            return apiColor
        }

        switch stableColorSeed % 5 {
        case 0: return .green
        case 1: return .blue
        case 2: return .red
        case 3: return .orange
        default: return .primary
        }
    }

    private var stableColorSeed: Int {
        let source = project.projectId ?? displayName
        return source.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult &+ Int(scalar.value)
        }
    }
}

extension Color {
    init?(hexString: String?) {
        guard let hexString else { return nil }

        var trimmed = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            trimmed.removeFirst()
        }

        let expanded: String
        switch trimmed.count {
        case 3:
            expanded = trimmed.map { "\($0)\($0)" }.joined()
        case 6:
            expanded = trimmed
        default:
            return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct CompactStatusRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(AppFont.body())
                .foregroundStyle(.appSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}

private struct SessionListStatusRow: View {
    let title: String
    let description: String?
    let systemImage: String
    var descriptionLineLimit: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(AppFont.body())
                .foregroundStyle(.appSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.appSecondary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)

                if let description {
                    Text(description)
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(descriptionLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}

struct SessionRowSkeletonView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 8

    let configuration: SessionRowSkeletonConfiguration
    let showsMessageCount: Bool
    let showsWorkspace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: rowContentSpacing) {
            titleArea

            if let metadataLabel {
                Text(verbatim: metadataLabel)
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
                    .lineLimit(metadataLineLimit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: metadataLabel == nil ? 46 : 54)
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private var titleArea: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                titleText
                relativeDateText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleText

                Spacer(minLength: 8)

                relativeDateText
            }
        }
    }

    private var titleText: some View {
        Text(verbatim: configuration.title)
            .font(AppFont.headline(weight: .semibold))
            .foregroundStyle(.appPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var relativeDateText: some View {
        Text(verbatim: configuration.relativeDate)
            .font(AppFont.caption())
            .foregroundStyle(.appSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var rowContentSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 4
    }

    private var metadataLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var metadataLabel: String? {
        let parts = [
            showsMessageCount ? configuration.messageCount : nil,
            showsWorkspace ? configuration.workspace : nil
        ].compactMap(\.self)

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

struct SessionRowSkeletonConfiguration: Identifiable {
    let id: String
    let title: String
    let messageCount: String
    let workspace: String
    let relativeDate: String

    static let loadingRows: [SessionRowSkeletonConfiguration] = [
        SessionRowSkeletonConfiguration(
            id: "recent-build",
            title: "Review latest mobile build notes",
            messageCount: "12 messages",
            workspace: "hermes-mobile",
            relativeDate: "5m"
        ),
        SessionRowSkeletonConfiguration(
            id: "polish-pass",
            title: "Plan the next polish pass",
            messageCount: "8 messages",
            workspace: "design",
            relativeDate: "1h"
        ),
        SessionRowSkeletonConfiguration(
            id: "streaming-check",
            title: "Streaming behavior investigation",
            messageCount: "24 messages",
            workspace: "webui",
            relativeDate: "3h"
        ),
        SessionRowSkeletonConfiguration(
            id: "testflight",
            title: "TestFlight validation checklist",
            messageCount: "6 messages",
            workspace: "release",
            relativeDate: "1d"
        ),
        SessionRowSkeletonConfiguration(
            id: "followup",
            title: "Follow-up implementation details",
            messageCount: "17 messages",
            workspace: "notes",
            relativeDate: "2d"
        )
    ]
}

struct OfflineCacheBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
                .accessibilityHidden(true)

            Text("Offline - viewing cached version")
                .font(AppFont.subheadline())
                .fontWeight(.semibold)

            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
