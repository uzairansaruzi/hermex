import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @State private var shares = SharedImportQueue()
    @State private var pendingLinks = PendingLinks()
    @State private var didCheckInitialPendingShare = false
    @State private var intentRouter = AppIntentRouter.shared
    @AppStorage(BotModeGate.isEnabledKey) private var isBotModeEnabled = false

    var body: some View {
        content
            .moveToHermesNotices(authManager)
            .onOpenURL(perform: handleOpenURL)
            .task {
                guard !didCheckInitialPendingShare else { return }
                didCheckInitialPendingShare = true
                importPendingSharedDraftIfAvailable()
                drainPendingIntentDeepLink()
                await UsageReports.shared.appBecameActive()
            }
            .onChange(of: intentRouter.pendingDeepLink) {
                drainPendingIntentDeepLink()
            }
            .onChange(of: authManager.state) {
                switchServer(pendingLinks.reroute(state: authManager.state, servers: authManager.servers,
                                                  isBotModeEnabled: isBotModeEnabled))
                shares.endReview()
                switchServer(shares.shortcutRoute(state: authManager.state, servers: authManager.servers))
            }
            .onChange(of: shares.pending?.reservationID) {
                switchServer(shares.shortcutRoute(state: authManager.state, servers: authManager.servers))
            }
            .alert((unopenableShortcut?.sharedImport.shortcut?.origin ?? .shortcut).cantOpenTitle,
                   isPresented: Binding(get: { unopenableShortcut != nil }, set: { isPresented in
                guard !isPresented, let share = unopenableShortcut else { return }
                Task { @MainActor in
                    if shares.pending?.reservationID == share.reservationID { releasePendingSharedImport(share) }
                }
            }), presenting: unopenableShortcut) { share in
                Button("Discard", role: .destructive) { consumePendingSharedImport(share) }
                Button("Not Now", role: .cancel) { releasePendingSharedImport(share) }
            } message: { _ in
                Text("The server for this text was removed from Hermex, so it can’t open.")
            }
            .task {
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
                await AgentLiveActivityManager.shared.settleActivitiesFromPreviousLaunch(checking: hermesRunCheck())
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background { HermesConnections.shared.closeForBackground() }
                guard scenePhase == .active else { return }
                Task { await UsageReports.shared.appBecameActive() }
                importPendingSharedDraftIfAvailable()
                Task {
                    await reconcileOrphanedLiveActivities(notifiesOnCompletion: false)
                    await AgentLiveActivityManager.shared.endFinishedRuns(checking: hermesRunCheck())
                }
            }
            .onChange(of: NetworkPathMonitor.shared.changeCount) {
                guard scenePhase != .background, NetworkPathMonitor.shared.isSatisfied else { return }
                HermesConnections.shared.networkPathDidChange()
            }
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        guard case let .loggedIn(server) = authManager.state, authManager.kind(of: server) == .webui else { return }
        await LiveActivityReconciler.reconcileOrphanedActivities(
            server: server,
            notifiesOnCompletion: notifiesOnCompletion,
            preferenceEnabled: isResponseCompletionNotificationsEnabled
        )
    }

    private func hermesRunCheck() -> AgentLiveActivityManager.HermesRunCheck? {
        guard case let .loggedIn(server) = authManager.state, authManager.kind(of: server) == .hermes,
              let connection = try? BotConnectionStore().load(server: server) else { return nil }
        return AgentLiveActivityManager.HermesRunCheck(server: server) { profile in
            let wire = BotClient(saved: connection, server: server)
            defer { wire.close() }
            guard (try? await wire.connect()) != nil,
                  let items = (try? await wire.call(.sessionActiveList(profile: profile)))?["sessions"].list else { return nil }
            return LeftoverLiveActivitySettlement.runningKeys(items)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .unconfigured:
            OnboardingView(authManager: authManager)
        case .loggedOut(let server) where authManager.kind(of: server) == .hermes:
            HermesServerSignIn(authManager: authManager, server: server)
                .id(server)
        case .loggedIn(let server) where authManager.kind(of: server) == .hermes:
            HermesServerHome(authManager: authManager, server: server, pendingBotDestination: $pendingLinks.bot,
                             pendingSessionDestination: $pendingLinks.hermesSession,
                             pendingNewChat: $pendingLinks.hermesNewChat, pendingUsage: $pendingLinks.hermesUsage,
                             pendingShare: shares.offered(to: server), claimShare: { shares.claim($0) },
                             didRouteShare: consumePendingSharedImport, didDeclineShare: releasePendingSharedImport,
                             didAbandonShare: { shares.abandon($0) }, shortcutReview: shortcutReview)
                .id(server)
        case .loggedOut(let server):
            OnboardingView(authManager: authManager, savedServer: server)
        case .loggedIn(let server):
            SessionListView(
                authManager: authManager,
                server: server,
                pendingSharedImport: Binding(get: { shares.offered(to: server) }, set: { shares.pending = $0 }),
                didRoutePendingSharedImport: consumePendingSharedImport,
                hasWaitingSharedImport: shares.hasWaiting,
                openNextSharedImport: openNextSharedImport,
                pendingDeepLinkedSessionID: $pendingLinks.deepLinkedSessionID,
                requestedNewChat: $pendingLinks.newChatRequest,
                pendingBotDestination: $pendingLinks.bot,
                pendingWebuiPush: $pendingLinks.webuiPush
            )
            .id(server)
        }
    }

    private func handleOpenURL(_ url: URL) {
        Task { await AgentLiveActivityManager.shared.dismissFinishedActivity(from: url) }
        pendingLinks.webuiPush = nil
        pendingLinks.hermesSession = nil
        pendingLinks.hermesNewChat = nil
        pendingLinks.hermesUsage = nil
        pendingLinks.botWidget = nil
        if let destination = WebuiPushDestination(url: url) {
            switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            return
        }

        if HermesDeepLink.isNewChatVoiceURL(url) {
            openNewChat(autoStartsVoiceInput: true)
            return
        }

        if let destination = HermesNewChatDestination(url: url) {
            switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            return
        }

        if HermesDeepLink.isWebuiNewChatInProfileURL(url) {
            let profile = HermesDeepLink.profileName(fromNewChatInProfile: url)
            switch MovedWebuiRoute.newChat(inProfile: profile, active: authManager.state.server,
                                           servers: authManager.servers) {
            case .webui(let route):
                if enter(route) { pendingLinks.newChatRequest = NewChatRequest(profileName: profile) }
            case .hermes(let destination):
                switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            case .refuse:
                break
            }
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            openNewChat(autoStartsVoiceInput: false)
            return
        }

        if let destination = HermesDeepLink.botDestination(from: url) {
            switchServer(pendingLinks.route(destination, state: authManager.state, servers: authManager.servers,
                                            isBotModeEnabled: isBotModeEnabled))
            return
        }

        if let destination = BotWidgetDestination(url: url) {
            UsageReports.shared.record(.homeWidget)
            switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers,
                                           isBotModeEnabled: isBotModeEnabled))
            return
        }

        if let usage = HermesUsageDestination(url: url) {
            UsageReports.shared.record(.homeWidget)
            if usage.opens(state: authManager.state, servers: authManager.servers) { pendingLinks.hermesUsage = usage }
            return
        }

        if let destination = HermesSessionDestination(url: url) {
            switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            switch MovedWebuiRoute.bareSession(sessionID, active: authManager.state.server, servers: authManager.servers) {
            case .webui(let route):
                if enter(route) { pendingLinks.deepLinkedSessionID = sessionID }
            case .hermes(let destination):
                switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            case .refuse:
                break
            }
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
    }

    private func switchServer(_ account: ServerAccount?) {
        if let account { authManager.switchActiveServer(to: account) }
    }

    private func openNewChat(autoStartsVoiceInput: Bool) {
        if let hermes = HermesNewChatDestination.onActiveServer(state: authManager.state, servers: authManager.servers,
                                                                autoStartsVoiceInput: autoStartsVoiceInput) {
            switchServer(pendingLinks.open(hermes, state: authManager.state, servers: authManager.servers))
        } else if reachWebuiServer() {
            pendingLinks.newChatRequest = NewChatRequest(autoStartsVoiceInput: autoStartsVoiceInput)
        }
    }

    private func reachWebuiServer() -> Bool {
        enter(WebuiEntryRoute.resolve(active: authManager.state.server, servers: authManager.servers))
    }

    private func enter(_ route: WebuiEntryRoute) -> Bool {
        switch route {
        case .stay:
            return true
        case .switchServer(let account):
            authManager.switchActiveServer(to: account)
            return true
        case .unavailable:
            return false
        }
    }

    private func releasePendingSharedImport(_ reservation: SharedImportReservation) {
        shares.release(reservation, in: HermesShareDraft.containerURL())
    }

    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        shares.reserveNext(in: HermesShareDraft.containerURL(), active: authManager.state.server, servers: authManager.servers)
    }

    private func consumePendingSharedImport(_ reservation: SharedImportReservation) {
        if reservation.sharedImport.shortcut == nil { UsageReports.shared.record(.shareExtension) }
        shares.consume(reservation, in: HermesShareDraft.containerURL(), active: authManager.state.server,
                       servers: authManager.servers)
    }

    private func openNextSharedImport() {
        shares.openNext(in: HermesShareDraft.containerURL(), active: authManager.state.server, servers: authManager.servers)
    }

    private var shortcutReview: ShortcutTextReview {
        ShortcutTextReview(
            chat: shares.reviewing, hasWaiting: shares.hasWaitingShortcutText,
            begin: { shares.beginReview(in: $0) },
            replace: { shares.moveReview(from: $0, to: $1) },
            end: { shares.endReview(in: $0, directory: HermesShareDraft.containerURL(), active: authManager.state.server,
                                    servers: authManager.servers) },
            discardNext: { shares.discardNextShortcutText(in: HermesShareDraft.containerURL()) }
        )
    }

    private var unopenableShortcut: SharedImportReservation? {
        shares.unopenableShortcut(servers: authManager.servers)
    }
}

struct SharedImportQueue {
    var pending: SharedImportReservation?
    private(set) var hasWaiting = false
    private(set) var reviewing: UUID?
    private(set) var hasWaitingShortcutText = false
    private var hasRouted = false
    private var moving: SharedImportReservation?

    mutating func reserveNext(in directory: URL?, active: URL?, servers: [ServerAccount]) {
        guard pending == nil, moving == nil, let directory else { return }
        var kinds: SharedImportKinds = reviewing == nil ? .shortcutTexts : []
        if SharedImportGate.opensNext(afterRouting: hasRouted, active: active, servers: servers) { kinds.insert(.shares) }
        guard !kinds.isEmpty else { return refreshWaiting(in: directory) }
        do {
            pending = try HermesShareDraft.reserveNextPendingImport(from: directory, kinds: kinds)
            refreshWaiting(in: directory)
        } catch {
            pending = nil
            hasWaiting = false
            hasWaitingShortcutText = false
        }
    }

    mutating func consume(_ reservation: SharedImportReservation, in directory: URL?, active: URL?,
                          servers: [ServerAccount]) {
        hasRouted = true
        settle(reservation)
        guard let directory else { return }
        do {
            try HermesShareDraft.consume(reservation, from: directory)
        } catch {
            try? HermesShareDraft.release(reservation, in: directory)
            return refreshWaiting(in: directory)
        }
        refreshWaiting(in: directory)
        reserveNext(in: directory, active: active, servers: servers)
    }

    mutating func release(_ reservation: SharedImportReservation, in directory: URL?) {
        settle(reservation)
        guard let directory else { return }
        try? HermesShareDraft.release(reservation, in: directory)
        refreshWaiting(in: directory)
    }

    mutating func claim(_ reservation: SharedImportReservation) -> Bool {
        guard pending?.reservationID == reservation.reservationID else { return false }
        moving = pending
        pending = nil
        return true
    }

    mutating func abandon(_ reservation: SharedImportReservation) {
        guard moving?.reservationID == reservation.reservationID else { return }
        pending = moving
        moving = nil
    }

    mutating func openNext(in directory: URL?, active: URL?, servers: [ServerAccount]) {
        hasWaiting = false
        hasRouted = false
        reserveNext(in: directory, active: active, servers: servers)
    }

    mutating func beginReview(in chat: UUID) {
        reviewing = chat
    }

    mutating func endReview(in chat: UUID, directory: URL?, active: URL?, servers: [ServerAccount]) {
        guard reviewing == chat else { return }
        reviewing = nil
        reserveNext(in: directory, active: active, servers: servers)
    }

    mutating func moveReview(from chat: UUID, to replacement: UUID) {
        guard reviewing == chat else { return }
        reviewing = replacement
    }

    mutating func endReview() {
        reviewing = nil
    }

    mutating func discardNextShortcutText(in directory: URL?) {
        guard let directory else { return }
        if let next = try? HermesShareDraft.reserveNextPendingImport(from: directory, kinds: .shortcutTexts) {
            try? HermesShareDraft.consume(next, from: directory)
        }
        refreshWaiting(in: directory)
    }

    func offered(to server: URL) -> SharedImportReservation? {
        guard let shortcut = pending?.sharedImport.shortcut else { return pending }
        return shortcut.opens(on: server) ? pending : nil
    }

    @MainActor func shortcutRoute(state: AuthManager.State, servers: [ServerAccount]) -> ServerAccount? {
        guard let shortcut = pending?.sharedImport.shortcut,
              case .switchServer(let account) = shortcut.newChat(in: servers)?.route(state: state, servers: servers)
        else { return nil }
        return account
    }

    func unopenableShortcut(servers: [ServerAccount]) -> SharedImportReservation? {
        guard let shortcut = pending?.sharedImport.shortcut, shortcut.newChat(in: servers) == nil else { return nil }
        return pending
    }

    private mutating func settle(_ reservation: SharedImportReservation) {
        if pending?.reservationID == reservation.reservationID { pending = nil }
        if moving?.reservationID == reservation.reservationID { moving = nil }
    }

    private mutating func refreshWaiting(in directory: URL) {
        hasWaiting = (try? HermesShareDraft.hasPendingImport(in: directory)) ?? false
        hasWaitingShortcutText = hasWaiting
            && (try? HermesShareDraft.hasPendingImport(in: directory, kinds: .shortcutTexts)) == true
    }
}

struct ShortcutTextReview {
    var chat: UUID?
    var hasWaiting = false
    var begin: (UUID) -> Void = { _ in }
    var replace: (UUID, UUID) -> Void = { _, _ in }
    var end: (UUID) -> Void = { _ in }
    var discardNext: () -> Void = {}

    func waiting(in id: UUID) -> WaitingShortcutText? {
        guard chat == id, hasWaiting else { return nil }
        return WaitingShortcutText(openNext: { end(id) }, discard: discardNext)
    }
}

enum WebuiEntryRoute: Equatable {
    case stay
    case switchServer(ServerAccount)
    case unavailable

    static func resolve(active: URL?, servers: [ServerAccount], moved: Set<String> = []) -> WebuiEntryRoute {
        guard let active, servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes
                || moved.contains(active.absoluteString) else { return .stay }
        guard let webui = servers.first(where: { $0.kind == .webui && !moved.contains($0.id) }) else { return .unavailable }
        return .switchServer(webui)
    }
}

enum MovedWebuiRoute {
    enum Outcome<Destination: Equatable>: Equatable {
        case webui(WebuiEntryRoute)
        case hermes(Destination)
        case refuse
    }

    private struct Move {
        let destination: String
        let source: String
        let record: MovedWebuiServer
    }

    static func destination(of source: URL, in servers: [ServerAccount]) -> ServerAccount? {
        servers.first { $0.kind == .hermes && $0.movedWebuiServers.contains { $0.sourceServerID == source.absoluteString } }
    }

    static func session(_ link: WebuiPushDestination, servers: [ServerAccount]) -> HermesSessionDestination? {
        let isConfigured = servers.contains { $0.id == link.server.absoluteString && $0.kind == .webui }
        guard !(link.opensOnSource && isConfigured),
              let destination = destination(of: link.server, in: servers),
              let server = URL(string: destination.id) else { return nil }
        return HermesSessionDestination(server: server, profile: nil, key: link.sessionID,
                                        movedFrom: isConfigured ? link.server : nil)
    }

    static func fallback(for link: HermesSessionDestination) -> URL? {
        link.movedFrom.flatMap { WebuiPushDestination(server: $0, sessionID: link.key, opensOnSource: true).url }
    }

    static func bareSession(_ key: String, active: URL?, servers: [ServerAccount]) -> Outcome<HermesSessionDestination> {
        let moves = moves(in: servers)
        guard !moves.isEmpty else { return .webui(WebuiEntryRoute.resolve(active: active, servers: servers)) }
        let destinations = Set(moves.map(\.destination))
        let retained = Set(moves.map(\.source).filter { id in servers.contains { $0.id == id && $0.kind == .webui } })
        guard unmovedWebui(in: servers, moves: moves).isEmpty, destinations.count == 1, retained.count <= 1,
              let server = destinations.first.flatMap(URL.init(string:)) else { return .refuse }
        return .hermes(HermesSessionDestination(server: server, profile: nil, key: key,
                                                movedFrom: retained.first.flatMap(URL.init(string:))))
    }

    static func newChat(inProfile profile: String?, active: URL?,
                        servers: [ServerAccount]) -> Outcome<HermesNewChatDestination> {
        enum Place: Hashable {
            case hermes(server: String, profile: String)
            case webui(String)
        }
        let moves = moves(in: servers)
        var places = Set<Place>()
        for move in moves {
            switch profile.flatMap(move.record.destination(ofProfile:)) {
            case .hermes(let mapped)?: places.insert(.hermes(server: move.destination, profile: mapped))
            case .keepOnWebui?: places.insert(.webui(move.source))
            case nil: break
            }
        }
        guard !places.isEmpty else {
            return .webui(WebuiEntryRoute.resolve(active: active, servers: servers, moved: Set(moves.map(\.source))))
        }
        places.formUnion(unmovedWebui(in: servers, moves: moves).map { .webui($0.id) })
        guard places.count == 1, let place = places.first else { return .refuse }
        switch place {
        case .hermes(let server, let mapped):
            guard let url = URL(string: server) else { return .refuse }
            return .hermes(HermesNewChatDestination(server: url, profile: mapped))
        case .webui(let id):
            guard let account = servers.first(where: { $0.id == id && $0.kind == .webui }) else { return .refuse }
            return .webui(active?.absoluteString == id ? .stay : .switchServer(account))
        }
    }

    static func names(profile: String, in servers: [ServerAccount]) -> Bool {
        moves(in: servers).contains { $0.record.destination(ofProfile: profile) != nil }
    }

    private static func moves(in servers: [ServerAccount]) -> [Move] {
        servers.filter { $0.kind == .hermes }.flatMap { server in
            server.movedWebuiServers.map { Move(destination: server.id, source: $0.sourceServerID, record: $0) }
        }
    }

    private static func unmovedWebui(in servers: [ServerAccount], moves: [Move]) -> [ServerAccount] {
        let moved = Set(moves.map(\.source))
        return servers.filter { $0.kind == .webui && !moved.contains($0.id) }
    }
}

enum SharedImportGate {
    static func opensNext(afterRouting hasRouted: Bool, active: URL?, servers: [ServerAccount]) -> Bool {
        !hasRouted || servers.first(where: { $0.id == active?.absoluteString })?.kind == .hermes
    }
}

enum HermesSettingsPresentation {
    case sheet, pushed

    init(usesSplit: Bool) {
        self = usesSplit ? .sheet : .pushed
    }

    func afterWidthChange(usesSplit: Bool) -> Self {
        usesSplit ? .sheet : self
    }
}

struct HermesServerHome: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var pendingBotDestination: BotDestination?
    @Binding var pendingSessionDestination: HermesSessionDestination?
    @Binding var pendingNewChat: HermesNewChatDestination?
    @Binding var pendingUsage: HermesUsageDestination?
    let pendingShare: SharedImportReservation?
    let claimShare: (SharedImportReservation) -> Bool
    let didRouteShare: (SharedImportReservation) -> Void
    let didDeclineShare: (SharedImportReservation) -> Void
    let didAbandonShare: (SharedImportReservation) -> Void
    let shortcutReview: ShortcutTextReview
    @SceneStorage("hermesHome.tab") private var tab = HermesHomeTab.sessions
    @State private var inbox: BotInbox
    @State private var sessions: HermesSessionsSide?
    @State private var settings: HermesSettingsPresentation?
    @State private var isPresentingAddServer = false

    init(authManager: AuthManager, server: URL, pendingBotDestination: Binding<BotDestination?>,
         pendingSessionDestination: Binding<HermesSessionDestination?>, pendingNewChat: Binding<HermesNewChatDestination?>,
         pendingUsage: Binding<HermesUsageDestination?> = .constant(nil),
         pendingShare: SharedImportReservation?, claimShare: @escaping (SharedImportReservation) -> Bool,
         didRouteShare: @escaping (SharedImportReservation) -> Void,
         didDeclineShare: @escaping (SharedImportReservation) -> Void,
         didAbandonShare: @escaping (SharedImportReservation) -> Void,
         shortcutReview: ShortcutTextReview = ShortcutTextReview()) {
        self.authManager = authManager
        self.server = server
        _pendingBotDestination = pendingBotDestination
        _pendingSessionDestination = pendingSessionDestination
        _pendingNewChat = pendingNewChat
        _pendingUsage = pendingUsage
        self.pendingShare = pendingShare
        self.claimShare = claimShare
        self.didRouteShare = didRouteShare
        self.didDeclineShare = didDeclineShare
        self.didAbandonShare = didAbandonShare
        self.shortcutReview = shortcutReview
        _inbox = State(initialValue: BotInbox(server: server))
        _sessions = State(initialValue: (try? BotConnectionStore().load(server: server)).map { HermesSessionsSide(server: server, connection: $0) })
    }

    var body: some View {
        let identity = HermesServerIdentity(account: authManager.activeServer, server: server)
        let home = HermesHome(title: identity.title, avatar: avatar(identity), tab: $tab, isSidebar: usesSplit)
        Group {
            if usesSplit {
                homeContent(home)
            } else {
                NavigationStack {
                    homeContent(home)
                        .navigationDestination(isPresented: isPresenting(.pushed)) {
                            SettingsView(authManager: authManager, server: server)
                        }
                }
            }
        }
        .sheet(isPresented: isPresenting(.sheet), onDismiss: readConnection) {
            NavigationStack {
                SettingsView(authManager: authManager, server: server)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { settings = nil }
                        }
                    }
            }
        }
        .onChange(of: usesSplit, initial: true) { settings = settings?.afterWidthChange(usesSplit: usesSplit) }
        .modifier(HermesUpdateSignInModifier { authManager.hermesSignInRejected(server: server) })
        .onChange(of: tab) {
            readConnection()
            guard !usesSplit else { return }
            if tab == .sessions { inbox.selection = BotInboxSelection() } else { sessions?.navigation.covers.bringForward() }
        }
        .onChange(of: pendingBotDestination, initial: true) {
            if pendingBotDestination != nil { tab = .bots; settings = nil }
        }
        .onChange(of: pendingSessionDestination, initial: true) {
            guard pendingSessionDestination != nil else { return }
            if sessions == nil { pendingSessionDestination = nil; return }
            tab = .sessions; settings = nil; isPresentingAddServer = false
        }
        .onChange(of: pendingNewChat, initial: true) {
            guard pendingNewChat != nil else { return }
            if sessions == nil { pendingNewChat = nil; return }
            tab = .sessions; settings = nil; isPresentingAddServer = false
        }
        .onChange(of: pendingUsage, initial: true) {
            guard let pendingUsage else { return }
            if sessions?.entry.connection.id != pendingUsage.connectionID { self.pendingUsage = nil; return }
            tab = .sessions; settings = nil; isPresentingAddServer = false
        }
        .onChange(of: pendingShare?.reservationID, initial: true) {
            guard let pendingShare else { return }
            if sessions == nil { didDeclineShare(pendingShare); return }
            tab = .sessions; settings = nil; isPresentingAddServer = false
        }
        .sheet(isPresented: $isPresentingAddServer) {
            AddServerView(authManager: authManager)
        }
    }

    private var usesSplit: Bool {
        HermesHomeLayout.usesSplit(isHome: true, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
    }

    private func isPresenting(_ presentation: HermesSettingsPresentation) -> Binding<Bool> {
        Binding(get: { settings == presentation }, set: { if !$0 { settings = nil } })
    }

    @ViewBuilder private func homeContent(_ home: HermesHome) -> some View {
        Group {
            if tab == .sessions, let sessions {
                HermesSessionListView(entry: sessions.entry, model: sessions.model, home: home,
                                      navigation: sessions.navigation,
                                      pendingLink: $pendingSessionDestination, pendingNewChat: $pendingNewChat,
                                      pendingUsage: $pendingUsage,
                                      pendingShare: pendingShare, claimShare: claimShare,
                                      didRouteShare: didRouteShare, didDeclineShare: didDeclineShare,
                                      didAbandonShare: didAbandonShare, shortcutReview: shortcutReview,
                                      isCoveredByHome: { settings != nil || isPresentingAddServer })
                    .id(sessions.entry.id)
            } else {
                BotsInboxView(server: server, pendingDestination: $pendingBotDestination, home: home, inbox: inbox)
            }
        }
        .onAppear(perform: readConnection)
    }

    private func readConnection() {
        let saved = try? BotConnectionStore().load(server: server)
        guard saved != sessions?.entry.connection else { return }
        if let reviewing = shortcutReview.chat { shortcutReview.end(reviewing) }
        sessions = saved.map { HermesSessionsSide(server: server, connection: $0) }
    }

    private func avatar(_ identity: HermesServerIdentity) -> SessionsHeader.Avatar {
        SessionsHeader.Avatar(
            initials: identity.initials,
            color: HeaderLogoColor.color(for: identity.colorHex),
            foreground: HeaderLogoColor.prefersDarkForeground(for: identity.colorHex) ? .black : .white,
            servers: AvatarServerSwitcherModel(servers: authManager.servers, activeServerID: authManager.activeServerID),
            openSettings: { settings = HermesSettingsPresentation(usesSplit: usesSplit) },
            switchToServer: { authManager.switchActiveServer(to: $0) },
            addServer: { isPresentingAddServer = true },
            manageServers: { settings = HermesSettingsPresentation(usesSplit: usesSplit) }
        )
    }
}

final class HermesUpdateSignInAction {
    var handler: () -> Void = {}

    func callAsFunction() { handler() }
}

private struct HermesUpdateSignInKey: EnvironmentKey {
    static let defaultValue = HermesUpdateSignInAction()
}

extension EnvironmentValues {
    var hermesUpdateSignIn: HermesUpdateSignInAction {
        get { self[HermesUpdateSignInKey.self] }
        set { self[HermesUpdateSignInKey.self] = newValue }
    }
}

struct HermesUpdateSignInModifier: ViewModifier {
    let handler: () -> Void
    @State private var action = HermesUpdateSignInAction()

    func body(content: Content) -> some View {
        action.handler = handler
        return content.environment(\.hermesUpdateSignIn, action)
    }
}

@MainActor private struct HermesSessionsSide {
    let entry: HermesSessionListEntry
    let model: SessionListViewModel
    let navigation = HermesSessionListNavigation()

    init(server: URL, connection: BotConnection) {
        entry = HermesSessionListEntry(server: server, connection: connection, profile: nil)
        model = HermesSessionListView.model(for: entry)
    }
}

struct HermesServerSignIn: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @State private var isShowingSettings = false
    @State private var isPresentingAddServer = false

    var body: some View {
        NavigationStack {
            BotConnectionView(server: server, focusesPassword: true, isRoot: true, error: authManager.lastErrorMessage) {
                authManager.hermesSignInSaved(server: server)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HermesServerAvatarButton(authManager: authManager, server: server) {
                        isShowingSettings = true
                    } addServer: {
                        isPresentingAddServer = true
                    } manageServers: {
                        isShowingSettings = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView(authManager: authManager, server: server)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { isShowingSettings = false } }
                    }
            }
        }
        .sheet(isPresented: $isPresentingAddServer) {
            AddServerView(authManager: authManager)
        }
    }
}

private struct HermesServerIdentity {
    let title: String
    let host: String
    let initials: String
    let colorHex: String

    init(account: ServerAccount?, server: URL) {
        host = server.host ?? server.absoluteString
        let name = account?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = name.isEmpty ? host : name
        initials = SessionIdentitySettings.displayInitials(
            displayName: title, storedInitials: account?.initials ?? "", fallbackFullName: host
        )
        colorHex = account?.headerLogoColorHex ?? HeaderLogoColor.defaultHex
    }

}

private struct HermesServerAvatarButton: View {
    @Bindable var authManager: AuthManager
    let server: URL
    let openSettings: () -> Void
    let addServer: () -> Void
    let manageServers: () -> Void

    var body: some View {
        let identity = HermesServerIdentity(account: authManager.activeServer, server: server)
        Menu {
            AvatarServerSwitcherMenu(
                model: AvatarServerSwitcherModel(servers: authManager.servers, activeServerID: authManager.activeServerID),
                switchToServer: { authManager.switchActiveServer(to: $0) },
                addServer: addServer,
                manageServers: manageServers
            )
        } label: {
            Text(identity.initials)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(HeaderLogoColor.prefersDarkForeground(for: identity.colorHex) ? Color.black : Color.white)
                .frame(width: 32, height: 32)
                .background(HeaderLogoColor.color(for: identity.colorHex), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens Settings. Long press to switch servers.")
        } primaryAction: {
            openSettings()
        }
    }
}

struct PendingLinks {
    var deepLinkedSessionID: String?
    var newChatRequest: NewChatRequest?
    var webuiPush: WebuiPushDestination?
    var bot: BotDestination?
    var hermesSession: HermesSessionDestination?
    var hermesNewChat: HermesNewChatDestination?
    var hermesUsage: HermesUsageDestination?
    var botWidget: BotWidgetDestination?

    @MainActor mutating func open(_ destination: WebuiPushDestination, state: AuthManager.State,
                                  servers: [ServerAccount]) -> ServerAccount? {
        self = PendingLinks()
        return route(destination, state: state, servers: servers)
    }

    @MainActor mutating func open(_ destination: HermesSessionDestination, state: AuthManager.State,
                                  servers: [ServerAccount]) -> ServerAccount? {
        self = PendingLinks()
        return route(destination, state: state, servers: servers)
    }

    @MainActor mutating func open(_ destination: HermesNewChatDestination, state: AuthManager.State,
                                  servers: [ServerAccount]) -> ServerAccount? {
        self = PendingLinks()
        return route(destination, state: state, servers: servers)
    }

    @MainActor mutating func open(
        _ destination: BotWidgetDestination, state: AuthManager.State, servers: [ServerAccount], isBotModeEnabled: Bool,
        botConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID
    ) -> ServerAccount? {
        self = PendingLinks()
        guard let account = servers.first(where: { URL(string: $0.urlString).map(BotHistoryCache.Scope.key) == destination.serverKey }),
              let server = URL(string: account.urlString) else { return nil }
        if let connectionID = botConnectionID(server) {
            let bot = BotDestination(server: server, connectionID: connectionID, profile: destination.profile)
            return route(bot, state: state, servers: servers, isBotModeEnabled: isBotModeEnabled,
                         botConnectionID: botConnectionID)
        }
        guard account.kind == .hermes else { return nil }
        botWidget = destination
        return state.server == server ? nil : account
    }

    @MainActor mutating func reroute(
        state: AuthManager.State, servers: [ServerAccount], isBotModeEnabled: Bool,
        botConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID
    ) -> ServerAccount? {
        var account: ServerAccount?
        if let webuiPush { account = route(webuiPush, state: state, servers: servers) ?? account }
        if let bot {
            account = route(bot, state: state, servers: servers, isBotModeEnabled: isBotModeEnabled,
                            botConnectionID: botConnectionID) ?? account
        }
        if let hermesSession { account = route(hermesSession, state: state, servers: servers) ?? account }
        if let hermesNewChat { account = route(hermesNewChat, state: state, servers: servers) ?? account }
        if let hermesUsage, !hermesUsage.opens(state: state, servers: servers) { self.hermesUsage = nil }
        if let botWidget { account = reroute(botWidget, state: state, servers: servers, isBotModeEnabled: isBotModeEnabled,
                                             botConnectionID: botConnectionID) ?? account }
        return account
    }

    @MainActor private mutating func reroute(
        _ destination: BotWidgetDestination, state: AuthManager.State, servers: [ServerAccount], isBotModeEnabled: Bool,
        botConnectionID: @MainActor (URL) -> UUID?
    ) -> ServerAccount? {
        botWidget = nil
        guard let server = state.server, BotHistoryCache.Scope.key(server) == destination.serverKey else { return nil }
        guard let connectionID = botConnectionID(server) else {
            botWidget = destination
            return nil
        }
        return route(BotDestination(server: server, connectionID: connectionID, profile: destination.profile),
                     state: state, servers: servers, isBotModeEnabled: isBotModeEnabled, botConnectionID: botConnectionID)
    }

    @MainActor private mutating func route(_ destination: HermesNewChatDestination, state: AuthManager.State,
                                           servers: [ServerAccount]) -> ServerAccount? {
        switch destination.route(state: state, servers: servers) {
        case .ignore:
            hermesNewChat = nil
        case .waitForSignIn, .open:
            hermesNewChat = destination
        case .switchServer(let account):
            hermesNewChat = destination
            return account
        }
        return nil
    }

    @MainActor private mutating func route(_ destination: WebuiPushDestination, state: AuthManager.State,
                                           servers: [ServerAccount]) -> ServerAccount? {
        if let moved = MovedWebuiRoute.session(destination, servers: servers) {
            webuiPush = nil
            return route(moved, state: state, servers: servers)
        }
        switch destination.route(state: state, servers: servers) {
        case .ignore:
            webuiPush = nil
        case .waitForSignIn, .open:
            webuiPush = destination
        case .switchServer(let account):
            webuiPush = destination
            return account
        }
        return nil
    }

    @MainActor mutating func route(
        _ destination: BotDestination, state: AuthManager.State, servers: [ServerAccount], isBotModeEnabled: Bool,
        botConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID
    ) -> ServerAccount? {
        switch BotDeepLinkRouter.resolve(destination, state: state, servers: servers,
                                         isBotModeEnabled: isBotModeEnabled, botConnectionID: botConnectionID) {
        case .ignore:
            bot = nil
        case .waitForSignIn(let destination), .open(let destination):
            bot = destination
        case .switchServer(let account, let destination):
            bot = destination
            return account
        }
        return nil
    }

    @MainActor private mutating func route(_ destination: HermesSessionDestination, state: AuthManager.State,
                                           servers: [ServerAccount]) -> ServerAccount? {
        switch HermesSessionLinkRouter.resolve(destination, state: state, servers: servers) {
        case .ignore:
            hermesSession = nil
            if MovedWebuiRoute.destination(of: destination.server, in: servers) != nil {
                return route(WebuiPushDestination(server: destination.server, sessionID: destination.key),
                             state: state, servers: servers)
            }
        case .webui(let push):
            hermesSession = nil
            return open(push, state: state, servers: servers)
        case .waitForSignIn(let destination), .open(let destination):
            hermesSession = destination
        case .switchServer(let account, let destination):
            hermesSession = destination
            return account
        }
        return nil
    }
}

#Preview {
    ContentView(authManager: AuthManager())
}
