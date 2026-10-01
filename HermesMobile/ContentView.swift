import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @State private var pendingSharedImport: SharedImportReservation?
    @State private var hasWaitingSharedImport = false
    @State private var hasRoutedSharedImport = false
    @State private var pendingDeepLinkedSessionID: String?
    @State private var pendingWebuiPush: WebuiPushDestination?
    /// The bot a deep link named, held until the owning server is active and signed
    /// in. The session list flips to the Bots inbox, which resolves it against the
    /// live roster (#554).
    @State private var pendingBotDestination: BotDestination?
    @State private var pendingNewChatRequest: NewChatRequest?
    /// Shown when a new chat, session link or share arrives while a Hermes server is
    /// active and no webui server is configured to take it (#899).
    @State private var isShowingNoWebuiServer = false
    /// The share that alert offers to discard; nil for a new chat or session link.
    @State private var unroutableShare: SharedImportReservation?
    @State private var didCheckInitialPendingShare = false
    @State private var intentRouter = AppIntentRouter.shared
    @AppStorage(BotModeGate.isEnabledKey) private var isBotModeEnabled = false

    var body: some View {
        content
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
                if let destination = pendingWebuiPush { routeWebuiPush(destination) }
                if let destination = pendingBotDestination { routeBot(destination) }
            }
            .task {
                // #246: on cold launch, end any Live Activity left "running" by a
                // run that finished while the app was terminated. #248: this is also
                // the one pass allowed to alert for a recent run that completed or
                // failed, since a relaunch means it ended while not active.
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
                // #489: a bot activity has no server status to reconcile against.
                // #566: a finished webui activity releases its relay registration.
                await AgentLiveActivityManager.shared.settleActivitiesFromPreviousLaunch()
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                importPendingSharedDraftIfAvailable()
                // #248: the foreground pass stays silent — the in-session run-end
                // paths own notifications while the app is alive.
                Task { await reconcileOrphanedLiveActivities(notifiesOnCompletion: false) }
            }
            .alert("Add a WebUI server to start a chat.", isPresented: $isShowingNoWebuiServer) {
                if let share = unroutableShare {
                    Button("Discard", role: .destructive) { settleUnroutableShare(share, discarding: true) }
                    Button("Cancel", role: .cancel) { settleUnroutableShare(share, discarding: false) }
                } else {
                    Button("OK", role: .cancel) {}
                }
            }
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        // Live Activities follow webui runs; a Hermes server has none to reconcile.
        guard case let .loggedIn(server) = authManager.state, authManager.kind(of: server) == .webui else { return }
        await LiveActivityReconciler.reconcileOrphanedActivities(
            server: server,
            notifiesOnCompletion: notifiesOnCompletion,
            preferenceEnabled: isResponseCompletionNotificationsEnabled
        )
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
            HermesServerHome(authManager: authManager, server: server, pendingBotDestination: $pendingBotDestination)
                .id(server)
        case .loggedOut(let server):
            OnboardingView(authManager: authManager, savedServer: server)
        case .loggedIn(let server):
            SessionListView(
                authManager: authManager,
                server: server,
                pendingSharedImport: $pendingSharedImport,
                didRoutePendingSharedImport: consumePendingSharedImport,
                hasWaitingSharedImport: hasWaitingSharedImport,
                openNextSharedImport: openNextSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest,
                pendingBotDestination: $pendingBotDestination,
                pendingWebuiPush: $pendingWebuiPush
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
        pendingWebuiPush = nil
        if let destination = WebuiPushDestination(url: url) {
            pendingBotDestination = nil
            pendingDeepLinkedSessionID = nil
            pendingNewChatRequest = nil
            routeWebuiPush(destination)
            return
        }

        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            if reachWebuiServer() { pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: true) }
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing.
        if HermesDeepLink.isNewChatInProfileURL(url) {
            if reachWebuiServer() {
                pendingNewChatRequest = NewChatRequest(
                    profileName: HermesDeepLink.profileName(fromNewChatInProfile: url)
                )
            }
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            if reachWebuiServer() { pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: false) }
            return
        }

        // A bot link carries its own server, Bot connection and Profile, so it may
        // have to switch servers or wait for sign-in before it can open (#554).
        if let destination = HermesDeepLink.botDestination(from: url) {
            routeBot(destination)
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            if reachWebuiServer() { pendingDeepLinkedSessionID = sessionID }
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
    }

    private func routeWebuiPush(_ destination: WebuiPushDestination) {
        switch destination.route(state: authManager.state, servers: authManager.servers) {
        case .ignore:
            pendingWebuiPush = nil
        case .waitForSignIn, .open:
            pendingWebuiPush = destination
        case .switchServer(let account):
            pendingWebuiPush = destination
            authManager.switchActiveServer(to: account)
        }
    }

    /// Applies the router's verdict for a bot deep link: drop it when nothing can be
    /// opened (Bot Mode off, server removed, connection replaced), hold it across a
    /// sign-in, or activate its server first and let the rebuilt tree route it.
    private func routeBot(_ destination: BotDestination) {
        let outcome = BotDeepLinkRouter.resolve(
            destination,
            state: authManager.state,
            servers: authManager.servers,
            isBotModeEnabled: isBotModeEnabled
        )

        switch outcome {
        case .ignore:
            pendingBotDestination = nil
        case .waitForSignIn(let destination), .open(let destination):
            pendingBotDestination = destination
        case .switchServer(let account, let destination):
            pendingBotDestination = destination
            authManager.switchActiveServer(to: account)
        }
    }

    /// Readies a webui-only entry point (a new-chat intent or link, a session link, a
    /// share) and returns whether it can go ahead. While a Hermes server is active it
    /// switches to the first webui server, as a webui push tap does, and the rebuilt
    /// session list takes the held request. With no webui server it shows why and returns
    /// false. On a webui server, or with nothing configured, there is nothing to do.
    private func reachWebuiServer() -> Bool {
        switch WebuiEntryRoute.resolve(active: authManager.state.server, servers: authManager.servers) {
        case .stay:
            return true
        case .switchServer(let account):
            authManager.switchActiveServer(to: account)
            return true
        case .unavailable:
            isShowingNoWebuiServer = true
            return false
        }
    }

    /// Deletes a share no webui server can take, or keeps it queued to be offered again on
    /// the next launch or return to the app. Either way nothing was routed, so the next
    /// queued share is offered the same way rather than waiting behind it.
    private func settleUnroutableShare(_ reservation: SharedImportReservation, discarding: Bool) {
        unroutableShare = nil
        if pendingSharedImport?.reservationID == reservation.reservationID { pendingSharedImport = nil }
        guard let directory = HermesShareDraft.containerURL() else { return }
        if discarding {
            try? HermesShareDraft.consume(reservation, from: directory)
        } else {
            try? HermesShareDraft.release(reservation, in: directory)
        }
        refreshWaitingSharedImport(in: directory)
    }

    /// Routes a deep link queued by an App Intent through the same `handleOpenURL` parser
    /// used for external URLs, then clears it so it routes exactly once (#337).
    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        guard pendingSharedImport == nil else {
            return
        }

        guard let directory = HermesShareDraft.containerURL() else {
            return
        }

        guard !hasRoutedSharedImport else {
            refreshWaitingSharedImport(in: directory)
            return
        }

        do {
            pendingSharedImport = try HermesShareDraft.reserveNextPendingImport(from: directory)
            refreshWaitingSharedImport(in: directory)
            if let reservation = pendingSharedImport, !reachWebuiServer() { unroutableShare = reservation }
        } catch {
            pendingSharedImport = nil
            hasWaitingSharedImport = false
        }
    }

    private func consumePendingSharedImport(_ reservation: SharedImportReservation) {
        hasRoutedSharedImport = true

        defer {
            if pendingSharedImport?.reservationID == reservation.reservationID {
                pendingSharedImport = nil
            }
        }

        guard let directory = HermesShareDraft.containerURL() else {
            return
        }

        do {
            try HermesShareDraft.consume(reservation, from: directory)
        } catch {
            // Keep the share recoverable if acknowledgement fails after routing.
            try? HermesShareDraft.release(reservation, in: directory)
        }
        refreshWaitingSharedImport(in: directory)
    }

    private func openNextSharedImport() {
        hasWaitingSharedImport = false
        hasRoutedSharedImport = false
        importPendingSharedDraftIfAvailable()
    }

    private func refreshWaitingSharedImport(in directory: URL) {
        hasWaitingSharedImport = (try? HermesShareDraft.hasPendingImport(in: directory)) ?? false
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

    static func resolve(active: URL?, servers: [ServerAccount]) -> WebuiEntryRoute {
        guard let active, servers.first(where: { $0.id == active.absoluteString })?.kind == .hermes else { return .stay }
        guard let webui = servers.first(where: { $0.kind == .webui }) else { return .unavailable }
        return .switchServer(webui)
    }
}

/// A signed-in Hermes server's whole app (#899): its Bots inbox as the root of one
/// navigation stack, full width on iPad too, where chats push. The server's avatar
/// takes the inbox gear's place: a tap opens Settings, a hold switches servers.
struct HermesServerHome: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @Binding var pendingBotDestination: BotDestination?
    @State private var isShowingSettings = false
    @State private var settingsTarget: SettingsScrollAnchor?
    @State private var isPresentingAddServer = false

    var body: some View {
        NavigationStack {
            BotsInboxView(server: server, pendingDestination: $pendingBotDestination,
                          home: HermesServerIdentity(account: authManager.activeServer, server: server).inboxHome) {
                HermesServerAvatarButton(authManager: authManager, server: server) {
                    settingsTarget = nil; isShowingSettings = true
                } addServer: {
                    isPresentingAddServer = true
                } manageServers: {
                    settingsTarget = .servers; isShowingSettings = true
                }
            }
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(authManager: authManager, server: server, initialScrollTarget: settingsTarget)
            }
        }
        .sheet(isPresented: $isPresentingAddServer) {
            AddServerView(authManager: authManager)
        }
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

    /// The host line is left out when the name already is the host.
    var inboxHome: BotsInboxHome { BotsInboxHome(title: title, subtitle: title == host ? nil : host) }
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

#Preview {
    ContentView(authManager: AuthManager())
}
