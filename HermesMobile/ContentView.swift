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
                // Cold launch: an App Intent may have queued a deep link before this
                // view appeared (e.g. Action button "New Chat"). Drain it now (#337).
                drainPendingIntentDeepLink()
            }
            .onChange(of: intentRouter.pendingDeepLink) {
                // Warm launch: the intent set the deep link after the view appeared.
                drainPendingIntentDeepLink()
            }
            .onChange(of: authManager.state) {
                // A held conversation link resolves again once sign-in or a server switch
                // changes what it can reach.
                switchServer(pendingLinks.reroute(state: authManager.state, servers: authManager.servers,
                                                  isBotModeEnabled: isBotModeEnabled))
            }
            .task {
                // #246: on cold launch, end any Live Activity left "running" by a
                // run that finished while the app was terminated. #248: this is also
                // the one pass allowed to alert for a recent run that completed or
                // failed, since a relaunch means it ended while not active.
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
                // #489: a bot activity has no server status to reconcile against.
                // #566: a finished webui activity releases its relay registration.
                // #1179: an unpaired Hermes session's is checked once against its host.
                await AgentLiveActivityManager.shared.settleActivitiesFromPreviousLaunch(checking: hermesRunCheck())
            }
            .onChange(of: scenePhase) {
                // Closes the shared Bot socket cleanly on background; Control Center and
                // banners (`.inactive`) keep it. Each Bot screen also suspends on
                // background; the chat, inbox, rooms and editor reconnect on `.active`,
                // and the creators on their next Create (#902).
                if scenePhase == .background { HermesConnections.shared.closeForBackground() }
                guard scenePhase == .active else { return }
                importPendingSharedDraftIfAvailable()
                // #248: the foreground pass stays silent — the in-session run-end
                // paths own notifications while the app is alive.
                Task { await reconcileOrphanedLiveActivities(notifiesOnCompletion: false) }
            }
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        // Only webui runs can be reconciled against a server. A Hermes session's activity
        // (#1014) has no stream status to ask, and orphanedActivities() skips it.
        guard case let .loggedIn(server) = authManager.state, authManager.kind(of: server) == .webui else { return }
        await LiveActivityReconciler.reconcileOrphanedActivities(
            server: server,
            notifiesOnCompletion: notifiesOnCompletion,
            preferenceEnabled: isResponseCompletionNotificationsEnabled
        )
    }

    /// The signed-in active Hermes server's one `session.active_list` read for cold launch
    /// (#1179), over its saved connection; nil on a webui server or without a sign-in. The read is
    /// made only if an unpaired Hermes session's activity needs it.
    private func hermesRunCheck() -> AgentLiveActivityManager.HermesRunCheck? {
        guard case let .loggedIn(server) = authManager.state, authManager.kind(of: server) == .hermes,
              let connection = try? BotConnectionStore().load(server: server) else { return nil }
        return AgentLiveActivityManager.HermesRunCheck(server: server) {
            let wire = BotClient(saved: connection, server: server)
            defer { wire.close() }
            guard (try? await wire.connect()) != nil,
                  let items = (try? await wire.call(.sessionActiveList))?["sessions"].list else { return nil }
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
                             pendingNewChat: $pendingLinks.hermesNewChat,
                             pendingShare: shares.pending, claimShare: { shares.claim($0) },
                             didRouteShare: consumePendingSharedImport, didDeclineShare: releasePendingSharedImport,
                             didAbandonShare: { shares.abandon($0) })
                .id(server)
        case .loggedOut(let server):
            OnboardingView(authManager: authManager, savedServer: server)
        case .loggedIn(let server):
            SessionListView(
                authManager: authManager,
                server: server,
                pendingSharedImport: $shares.pending,
                didRoutePendingSharedImport: consumePendingSharedImport,
                hasWaitingSharedImport: shares.hasWaiting,
                openNextSharedImport: openNextSharedImport,
                pendingDeepLinkedSessionID: $pendingLinks.deepLinkedSessionID,
                requestedNewChat: $pendingLinks.newChatRequest,
                pendingBotDestination: $pendingLinks.bot,
                pendingWebuiPush: $pendingLinks.webuiPush
            )
            // Switching the active server keeps us in `.loggedIn`, so without a
            // per-server identity SwiftUI would reuse the same SessionListView (and
            // its server-bound view model), leaving stale sessions/chat on screen.
            // Keying on the server tears the whole stack down and rebuilds it
            // against the newly active server (#17).
            .id(server)
        }
    }

    private func handleOpenURL(_ url: URL) {
        Task { await AgentLiveActivityManager.shared.dismissFinishedActivity(from: url) }
        pendingLinks.webuiPush = nil
        pendingLinks.hermesSession = nil
        pendingLinks.hermesNewChat = nil
        if let destination = WebuiPushDestination(url: url) {
            switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            return
        }

        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            openNewChat(autoStartsVoiceInput: true)
            return
        }

        // A Hermes server's Profile opens a new session on that server (#1180), switching to it
        // or waiting for its sign-in first.
        if let destination = HermesNewChatDestination(url: url) {
            switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing; one naming a server
        // that didn't parse above opens nothing. A webui server that moved sends its Profile
        // where Review mapped it, unless another place could take it too (#1217).
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

        // A bot link carries its own server, Bot connection and Profile, so it may
        // have to switch servers or wait for sign-in before it can open (#554).
        if let destination = HermesDeepLink.botDestination(from: url) {
            switchServer(pendingLinks.route(destination, state: authManager.state, servers: authManager.servers,
                                            isBotModeEnabled: isBotModeEnabled))
            return
        }

        // A session link that names its server opens there, Hermes or webui, or nowhere when that
        // server isn't usable (#1176); one that doesn't keeps the webui route it always had.
        if let destination = HermesSessionDestination(url: url) {
            switchServer(pendingLinks.open(destination, state: authManager.state, servers: authManager.servers))
            return
        }

        // A bare session link names no server: once a webui server moved, it opens only where it
        // can't be another server's (#1217).
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

    /// Activates the server a held link's route asked for; the rebuilt tree takes the link.
    private func switchServer(_ account: ServerAccount?) {
        if let account { authManager.switchActiveServer(to: account) }
    }

    /// New Chat and New Chat with Voice: a new Hermes session on an active Hermes server, in
    /// the Profile its New Session uses (#1180), else the webui New Chat composer.
    private func openNewChat(autoStartsVoiceInput: Bool) {
        if let hermes = HermesNewChatDestination.onActiveServer(state: authManager.state, servers: authManager.servers,
                                                                autoStartsVoiceInput: autoStartsVoiceInput) {
            switchServer(pendingLinks.open(hermes, state: authManager.state, servers: authManager.servers))
        } else if reachWebuiServer() {
            pendingLinks.newChatRequest = NewChatRequest(autoStartsVoiceInput: autoStartsVoiceInput)
        }
    }

    /// Readies a webui-only entry point (a webui Profile's New Chat in Profile, a legacy
    /// session link) and returns whether it can go ahead. While a Hermes server is active it
    /// switches to the first webui server, as a webui push tap does, and the rebuilt
    /// session list takes the held request. With no webui server it opens nothing: a Hermes-only
    /// user is never asked to add one (#1181). On a webui server, or with nothing configured,
    /// there is nothing to do.
    private func reachWebuiServer() -> Bool {
        enter(WebuiEntryRoute.resolve(active: authManager.state.server, servers: authManager.servers))
    }

    /// Takes `route` and returns whether the webui entry point can go ahead.
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

    /// Keeps a share the Hermes home can't open queued (it has no saved connection, or the list
    /// left before the user discarded a share its draft couldn't take), to be offered again on
    /// the next launch or return to the app.
    private func releasePendingSharedImport(_ reservation: SharedImportReservation) {
        shares.release(reservation, in: HermesShareDraft.containerURL())
    }

    /// Routes a deep link queued by an App Intent through the same `handleOpenURL` parser
    /// used for external URLs, then clears it so it routes exactly once (#337).
    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        shares.reserveNext(in: HermesShareDraft.containerURL(), active: authManager.state.server, servers: authManager.servers)
    }

    private func consumePendingSharedImport(_ reservation: SharedImportReservation) {
        shares.consume(reservation, in: HermesShareDraft.containerURL(), active: authManager.state.server,
                       servers: authManager.servers)
    }

    private func openNextSharedImport() {
        shares.openNext(in: HermesShareDraft.containerURL(), active: authManager.state.server, servers: authManager.servers)
    }
}

/// The shares waiting in the app group, handed to the active server's home one at a time
/// (#1181): the one reserved for it or being moved into a Hermes draft, whether more wait, and
/// whether one was routed since the last Open Next. `ContentView` owns it; a nil directory (no app group) reserves nothing.
struct SharedImportQueue {
    /// The reserved share the active home is opening.
    var pending: SharedImportReservation?
    /// More shares wait behind it, which a webui session list offers in its Open Next banner.
    private(set) var hasWaiting = false
    private var hasRouted = false
    /// The share a Hermes list is moving into its draft (`claim`), offered to no home meanwhile.
    private var moving: SharedImportReservation?

    /// Reserves the next waiting share when the active home opens it now (`SharedImportGate`).
    mutating func reserveNext(in directory: URL?, active: URL?, servers: [ServerAccount]) {
        guard pending == nil, moving == nil, let directory else { return }
        guard SharedImportGate.opensNext(afterRouting: hasRouted, active: active, servers: servers) else {
            return refreshWaiting(in: directory)
        }
        do {
            pending = try HermesShareDraft.reserveNextPendingImport(from: directory)
            refreshWaiting(in: directory)
        } catch {
            pending = nil
            hasWaiting = false
        }
    }

    /// The home routed `reservation`, or the user discarded it after it failed (#1196), so it
    /// leaves the queue, and a Hermes home, which has no Open Next banner, takes the next share
    /// at once.
    mutating func consume(_ reservation: SharedImportReservation, in directory: URL?, active: URL?,
                          servers: [ServerAccount]) {
        hasRouted = true
        settle(reservation)
        guard let directory else { return }
        do {
            try HermesShareDraft.consume(reservation, from: directory)
        } catch {
            // Keep the share recoverable if acknowledgement fails after routing.
            try? HermesShareDraft.release(reservation, in: directory)
            return refreshWaiting(in: directory)
        }
        refreshWaiting(in: directory)
        reserveNext(in: directory, active: active, servers: servers)
    }

    /// Keeps a share the Hermes home can't open queued, to be offered again on the next launch
    /// or return to the app.
    mutating func release(_ reservation: SharedImportReservation, in directory: URL?) {
        settle(reservation)
        guard let directory else { return }
        try? HermesShareDraft.release(reservation, in: directory)
        refreshWaiting(in: directory)
    }

    /// A Hermes list starts moving `reservation` into a draft: no home is offered it again until
    /// the move ends in `consume`, `release` or `abandon`, so a server switch mid-move can't open
    /// it in a second server's draft. False when it isn't the pending share.
    mutating func claim(_ reservation: SharedImportReservation) -> Bool {
        guard pending?.reservationID == reservation.reservationID else { return false }
        moving = pending
        pending = nil
        return true
    }

    /// The move was cut short before the draft took the share, so whichever home is active
    /// opens it again.
    mutating func abandon(_ reservation: SharedImportReservation) {
        guard moving?.reservationID == reservation.reservationID else { return }
        pending = moving
        moving = nil
    }

    /// A webui session list's Open Next.
    mutating func openNext(in directory: URL?, active: URL?, servers: [ServerAccount]) {
        hasWaiting = false
        hasRouted = false
        reserveNext(in: directory, active: active, servers: servers)
    }

    private mutating func settle(_ reservation: SharedImportReservation) {
        if pending?.reservationID == reservation.reservationID { pending = nil }
        if moving?.reservationID == reservation.reservationID { moving = nil }
    }

    private mutating func refreshWaiting(in directory: URL) {
        hasWaiting = (try? HermesShareDraft.hasPendingImport(in: directory)) ?? false
    }
}

/// Where a webui-only entry point goes when the active server may be a Hermes server (#899).
enum WebuiEntryRoute: Equatable {
    /// The active server is a webui server, or nothing is configured: proceed as before.
    case stay
    /// A Hermes server is active: make the first webui server in the registry active.
    case switchServer(ServerAccount)
    /// A Hermes server is active and no webui server is configured.
    case unavailable

    /// `moved` are webui servers an entry point mustn't take (`MovedWebuiRoute`): one that is
    /// active is left like a Hermes server, for the first webui server not among them.
    static func resolve(active: URL?, servers: [ServerAccount], moved: Set<String> = []) -> WebuiEntryRoute {
        guard let active, servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes
                || moved.contains(active.absoluteString) else { return .stay }
        guard let webui = servers.first(where: { $0.kind == .webui && !moved.contains($0.id) }) else { return .unavailable }
        return .switchServer(webui)
    }
}

/// Where a webui server's old entry points go once it moved to Hermes (#707, #1217). The Hermes
/// server it moved to holds its move record (`ServerAccount.movedWebuiServers`), which outlives
/// the webui entry and goes with the destination; without records every route is today's.
///
/// - A webui session link naming a moved server opens on its destination, looked up in every
///   Profile, so it finds where the session actually is rather than where Review mapped its
///   Profile. Only when every Profile was read and none has it does the Sessions list open it on
///   the webui server, while that is configured (`movedFrom`). A link about a run on the webui
///   server (`WebuiPushDestination.opensOnSource`) opens there while it is configured.
/// - A bare `session?id=` link or webui Profile Shortcut names no server. Once a move could own
///   it, it opens only where every candidate agrees, counting each webui server that didn't move,
///   and otherwise opens nothing: the active server never breaks the tie.
enum MovedWebuiRoute {
    /// What a bare link or webui Profile Shortcut does.
    enum Outcome<Destination: Equatable>: Equatable {
        /// No move could own it: the webui route, among webui servers that didn't move.
        case webui(WebuiEntryRoute)
        case hermes(Destination)
        /// More than one place could take it, or the one place can't.
        case refuse
    }

    private struct Move {
        /// The Hermes server holding the record, and the webui server it names, as registry ids.
        let destination: String
        let source: String
        let record: MovedWebuiServer
    }

    /// The Hermes server holding `source`'s move record; nil when it never moved or its
    /// destination was removed.
    static func destination(of source: URL, in servers: [ServerAccount]) -> ServerAccount? {
        servers.first { $0.kind == .hermes && $0.movedWebuiServers.contains { $0.sourceServerID == source.absoluteString } }
    }

    /// `link` as a session link on the Hermes server its webui server moved to, falling back to
    /// that webui server while it is configured; nil when it didn't move, or when `link` is about
    /// a run on it and it is still configured.
    static func session(_ link: WebuiPushDestination, servers: [ServerAccount]) -> HermesSessionDestination? {
        let isConfigured = servers.contains { $0.id == link.server.absoluteString && $0.kind == .webui }
        guard !(link.opensOnSource && isConfigured),
              let destination = destination(of: link.server, in: servers),
              let server = URL(string: destination.id) else { return nil }
        return HermesSessionDestination(server: server, profile: nil, key: link.sessionID,
                                        movedFrom: isConfigured ? link.server : nil)
    }

    /// The link the Sessions list opens when no Profile has `link`'s key: the session on the webui
    /// server it moved from, which opens there and never comes back here. Nil for any other link.
    static func fallback(for link: HermesSessionDestination) -> URL? {
        link.movedFrom.flatMap { WebuiPushDestination(server: $0, sessionID: link.key, opensOnSource: true).url }
    }

    /// A bare `session?id=` link, which any moved server could own. With any move recorded it
    /// opens only when every move went to one Hermes server, at most one of them is still
    /// configured to fall back to, and no webui server stayed unmoved.
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

    /// A webui Profile's New Chat in Profile, which names no server. Each move whose Review named
    /// `profile` sends it where it was mapped: a Hermes Profile, or the webui server it was kept
    /// on, which can't open it once removed. With any such move it opens only where they and every
    /// unmoved webui server agree. With none, the webui route among unmoved webui servers, so a
    /// moved server whose Review didn't name the Profile never takes it.
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

    /// Whether a move's Review named webui Profile `profile`, so a Shortcut saved with it still
    /// resolves after its webui server is removed, and `newChat` decides where it goes.
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

/// Whether the next share waiting in the app group opens now. A webui session list opens the
/// first and offers each later one in its Open Next banner, so a draft in progress is never
/// replaced; a Hermes home has no banner and opens each as it arrives (#1181).
enum SharedImportGate {
    static func opensNext(afterRouting hasRouted: Bool, active: URL?, servers: [ServerAccount]) -> Bool {
        !hasRouted || servers.first(where: { $0.id == active?.absoluteString })?.kind == .hermes
    }
}

/// A signed-in Hermes server's whole app (#899, #709): one navigation stack, full width on iPad
/// too, where chats push, rooted on either side of the home's `[Bots | Sessions]` switch. Each
/// side leads with the session list's header, whose avatar opens Settings on a tap and switches
/// servers on a hold, and takes the home's bar (`HermesHomeChrome`). The home keeps both sides'
/// state, so a switch shows the last roster or rows at once while they refresh. It opens on the
/// side last shown, Sessions at first, and a Bot link (a push tap, a search hit) turns it to Bots,
/// where the inbox opens it. A session link (#1176), a Shortcut's new session (#1180) or a share
/// (#1181) turns it to Sessions, where the list opens it.
struct HermesServerHome: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var pendingBotDestination: BotDestination?
    @Binding var pendingSessionDestination: HermesSessionDestination?
    @Binding var pendingNewChat: HermesNewChatDestination?
    /// The share `ContentView` reserved; the list claims it as it starts moving it into its new
    /// session's draft and routes it once the draft holds it, or once the user discards it after
    /// that move failed. The home declines it without a saved connection, and the list when it
    /// goes before the user discards a failed one, which keeps it queued; a move cut short
    /// abandons it to whichever home is active.
    let pendingShare: SharedImportReservation?
    let claimShare: (SharedImportReservation) -> Bool
    let didRouteShare: (SharedImportReservation) -> Void
    let didDeclineShare: (SharedImportReservation) -> Void
    let didAbandonShare: (SharedImportReservation) -> Void
    @SceneStorage("hermesHome.tab") private var tab = HermesHomeTab.sessions
    @State private var inbox: BotInbox
    /// The Sessions side's list on the saved Bot connection, read again each time a side shows,
    /// so a sign-in changed in Settings or the inbox gets a fresh list.
    @State private var sessions: HermesSessionsSide?
    @State private var isShowingSettings = false
    @State private var settingsTarget: SettingsScrollAnchor?
    @State private var isPresentingAddServer = false

    init(authManager: AuthManager, server: URL, pendingBotDestination: Binding<BotDestination?>,
         pendingSessionDestination: Binding<HermesSessionDestination?>, pendingNewChat: Binding<HermesNewChatDestination?>,
         pendingShare: SharedImportReservation?, claimShare: @escaping (SharedImportReservation) -> Bool,
         didRouteShare: @escaping (SharedImportReservation) -> Void,
         didDeclineShare: @escaping (SharedImportReservation) -> Void,
         didAbandonShare: @escaping (SharedImportReservation) -> Void) {
        self.authManager = authManager
        self.server = server
        _pendingBotDestination = pendingBotDestination
        _pendingSessionDestination = pendingSessionDestination
        _pendingNewChat = pendingNewChat
        self.pendingShare = pendingShare
        self.claimShare = claimShare
        self.didRouteShare = didRouteShare
        self.didDeclineShare = didDeclineShare
        self.didAbandonShare = didAbandonShare
        _inbox = State(initialValue: BotInbox(server: server))
        _sessions = State(initialValue: HermesSessionsSide(server: server))
    }

    var body: some View {
        let identity = HermesServerIdentity(account: authManager.activeServer, server: server)
        let home = HermesHome(title: identity.title, avatar: avatar(identity), tab: $tab)
        NavigationStack {
            Group {
                // Without a saved connection the inbox's welcome sets one up.
                if tab == .sessions, let sessions {
                    HermesSessionListView(entry: sessions.entry, model: sessions.model, home: home,
                                          pendingLink: $pendingSessionDestination, pendingNewChat: $pendingNewChat,
                                          pendingShare: pendingShare, claimShare: claimShare,
                                          didRouteShare: didRouteShare, didDeclineShare: didDeclineShare,
                                          didAbandonShare: didAbandonShare)
                        .id(sessions.entry.id)
                } else {
                    BotsInboxView(server: server, pendingDestination: $pendingBotDestination, home: home, inbox: inbox)
                }
            }
            .onAppear(perform: readConnection)
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(authManager: authManager, server: server, initialScrollTarget: settingsTarget)
            }
        }
        // A Hermes chat's Update sign-in (#942) signs the server out to its sign-in form, which
        // keeps the saved values and focuses the password; saving signs it back in.
        .modifier(HermesUpdateSignInModifier { authManager.hermesSignInRejected(server: server) })
        // A connection the inbox's sheet saved or changed closes no screen, so the switch reads too.
        .onChange(of: tab, readConnection)
        // A bot route lands on the inbox, so Settings (and an Archived screen pushed from it, #1146)
        // closes first, as a Sessions list's pushed screens do when its tab goes.
        .onChange(of: pendingBotDestination, initial: true) {
            if pendingBotDestination != nil { tab = .bots; isShowingSettings = false }
        }
        // A session link lands on the Sessions list the same way, with Add Server closed too, and
        // the list closes what covers its rows; without a saved connection there is no list to
        // open it.
        .onChange(of: pendingSessionDestination, initial: true) {
            guard pendingSessionDestination != nil else { return }
            if sessions == nil { pendingSessionDestination = nil; return }
            tab = .sessions; isShowingSettings = false; isPresentingAddServer = false
        }
        // So does a Shortcut's new session (#1180), which the list opens.
        .onChange(of: pendingNewChat, initial: true) {
            guard pendingNewChat != nil else { return }
            if sessions == nil { pendingNewChat = nil; return }
            tab = .sessions; isShowingSettings = false; isPresentingAddServer = false
        }
        // And a share (#1181), which stays queued while there is no list to open it.
        .onChange(of: pendingShare?.reservationID, initial: true) {
            guard let pendingShare else { return }
            if sessions == nil { didDeclineShare(pendingShare); return }
            tab = .sessions; isShowingSettings = false; isPresentingAddServer = false
        }
        .sheet(isPresented: $isPresentingAddServer) {
            AddServerView(authManager: authManager)
        }
    }

    /// A new list only when the saved record changed: a sign-in changed in Settings keeps its UUID.
    private func readConnection() {
        let saved = try? BotConnectionStore().load(server: server)
        if saved != sessions?.entry.connection { sessions = saved.map { HermesSessionsSide(server: server, connection: $0) } }
    }

    private func avatar(_ identity: HermesServerIdentity) -> SessionsHeader.Avatar {
        SessionsHeader.Avatar(
            initials: identity.initials,
            color: HeaderLogoColor.color(for: identity.colorHex),
            foreground: HeaderLogoColor.prefersDarkForeground(for: identity.colorHex) ? .black : .white,
            servers: AvatarServerSwitcherModel(servers: authManager.servers, activeServerID: authManager.activeServerID),
            openSettings: { settingsTarget = nil; isShowingSettings = true },
            switchToServer: { authManager.switchActiveServer(to: $0) },
            addServer: { isPresentingAddServer = true },
            manageServers: { settingsTarget = .servers; isShowingSettings = true }
        )
    }
}

/// Opens the Hermes server's sign-in form after its host refused the saved password (#942).
/// `HermesServerHome` installs it, so every Hermes chat under it inherits it: opened from the
/// Sessions list, a pushed branch or Archived Sessions. A bot's chat takes the inbox's (#1146). A reference, like
/// `OpenNotificationSettingsAction`, so a pass of the home invalidates no chat reading it.
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

/// The stable action lives in this modifier's state, so the handler capturing the home cannot
/// form a cycle that outlives it. The Bots inbox installs its own for the bot chats it opens.
struct HermesUpdateSignInModifier: ViewModifier {
    let handler: () -> Void
    @State private var action = HermesUpdateSignInAction()

    func body(content: Content) -> some View {
        action.handler = handler
        return content.environment(\.hermesUpdateSignIn, action)
    }
}

/// The Hermes home's Sessions side: its list, opening on the server's pick, and the view model
/// the home keeps across its switch.
@MainActor private struct HermesSessionsSide {
    let entry: HermesSessionListEntry
    let model: SessionListViewModel

    init(server: URL, connection: BotConnection) {
        entry = HermesSessionListEntry(server: server, connection: connection, profile: nil)
        model = HermesSessionListView.model(for: entry)
    }

    /// The side on `server`'s saved connection; nil without one.
    init?(server: URL) {
        guard let connection = try? BotConnectionStore().load(server: server) else { return nil }
        self.init(server: server, connection: connection)
    }
}

/// A Hermes server whose sign-in record is missing or was refused (#899): its connection
/// form is the whole screen, with the address locked and the password focused. The
/// server's avatar is the way out, as on the home: a tap opens Settings, a hold switches
/// servers. Saving a sign-in signs the server back in.
struct HermesServerSignIn: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @State private var isShowingSettings = false
    @State private var settingsTarget: SettingsScrollAnchor?
    @State private var isPresentingAddServer = false

    var body: some View {
        NavigationStack {
            BotConnectionView(server: server, focusesPassword: true, isRoot: true, error: authManager.lastErrorMessage) {
                authManager.hermesSignInSaved(server: server)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HermesServerAvatarButton(authManager: authManager, server: server) {
                        settingsTarget = nil; isShowingSettings = true
                    } addServer: {
                        isPresentingAddServer = true
                    } manageServers: {
                        settingsTarget = .servers; isShowingSettings = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView(authManager: authManager, server: server, initialScrollTarget: settingsTarget)
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

/// How a Hermes server names itself on its screens: its display name, or its host
/// when it has none, and its initials.
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

/// The active Hermes server's avatar, as on the webui home (#283): a tap opens Settings,
/// a hold opens the same server switcher.
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(HeaderLogoColor.prefersDarkForeground(for: identity.colorHex) ? Color.black : Color.white)
                .frame(width: 32, height: 32)
                .background(HeaderLogoColor.color(for: identity.colorHex), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                // On the label, so the initials are never read out as a control of their own.
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens Settings. Long press to switch servers.")
        } primaryAction: {
            openSettings()
        }
    }
}

/// The links `ContentView` holds until their server is active and signed in, and the routing
/// that decides each one's fate: drop it, hold it across a sign-in, or ask for its server first.
/// A route returns the server to activate; `ContentView` switches to it and the rebuilt tree
/// takes the held link. The session list and Hermes home clear a link once they open it.
struct PendingLinks {
    var deepLinkedSessionID: String?
    var newChatRequest: NewChatRequest?
    var webuiPush: WebuiPushDestination?
    /// The bot a deep link named. The session list flips to the Bots inbox, which resolves it
    /// against the live roster (#554).
    var bot: BotDestination?
    /// The Hermes session a link named (#1176). The Hermes home turns to Sessions, whose list
    /// looks it up.
    var hermesSession: HermesSessionDestination?
    /// The new Hermes session a Shortcut asked for (#1180). The Hermes home turns to Sessions,
    /// whose list opens it.
    var hermesNewChat: HermesNewChatDestination?

    /// A webui conversation link replaces whatever other link was waiting.
    @MainActor mutating func open(_ destination: WebuiPushDestination, state: AuthManager.State,
                                  servers: [ServerAccount]) -> ServerAccount? {
        self = PendingLinks()
        return route(destination, state: state, servers: servers)
    }

    /// So does a Hermes session link, so a sign-in it waits for never routes an older link to a
    /// server it doesn't name first (#1176).
    @MainActor mutating func open(_ destination: HermesSessionDestination, state: AuthManager.State,
                                  servers: [ServerAccount]) -> ServerAccount? {
        self = PendingLinks()
        return route(destination, state: state, servers: servers)
    }

    /// So does a Shortcut's new Hermes session (#1180).
    @MainActor mutating func open(_ destination: HermesNewChatDestination, state: AuthManager.State,
                                  servers: [ServerAccount]) -> ServerAccount? {
        self = PendingLinks()
        return route(destination, state: state, servers: servers)
    }

    /// Routes every held conversation link again once a sign-in or server switch changes what
    /// it can reach.
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
        return account
    }

    /// A new Hermes session: dropped when its server is gone, else held while it signs in or activates.
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

    /// A webui conversation link, or, when its server moved to Hermes, that server's session link
    /// (`MovedWebuiRoute`).
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

    /// A bot link: dropped when nothing can be opened (Bot Mode off, server removed, connection
    /// replaced), else held while its server signs in or activates.
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

    /// A Hermes session link: dropped, handed to a webui server's push route, or held while its
    /// server signs in or activates. A link naming a webui server removed after it moved to Hermes
    /// takes the push route, which sends it to its destination (#1217).
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
