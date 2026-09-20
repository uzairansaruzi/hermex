import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @State private var pendingSharedImport: SharedImportReservation?
    @State private var hasWaitingSharedImport = false
    @State private var hasRoutedSharedImport = false
    @State private var pendingDeepLinkedSessionID: String?
    /// The bot a deep link named, held until the owning server is active and signed
    /// in. The session list flips to the Bots inbox, which resolves it against the
    /// live roster (#554).
    @State private var pendingBotDestination: BotDestination?
    @State private var pendingNewChatRequest: NewChatRequest?
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
                // A held bot link resolves again once sign-in or a server switch
                // changes what it can reach.
                guard let destination = pendingBotDestination else { return }
                routeBot(destination)
            }
            .task {
                // #246: on cold launch, end any Live Activity left "running" by a
                // run that finished while the app was terminated. #248: this is also
                // the one pass allowed to fire a recent run's "response complete"
                // notification, since a relaunch means it finished while not active.
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
                // #489: a bot activity has no server status to reconcile against.
                await AgentLiveActivityManager.shared.endBotActivitiesFromPreviousLaunch()
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                importPendingSharedDraftIfAvailable()
                // #248: the foreground pass stays silent — the in-session completion
                // paths own notifications while the app is alive.
                Task { await reconcileOrphanedLiveActivities(notifiesOnCompletion: false) }
            }
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        guard case let .loggedIn(server) = authManager.state else { return }
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
                pendingBotDestination: $pendingBotDestination
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
        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: true)
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing.
        if HermesDeepLink.isNewChatInProfileURL(url) {
            pendingNewChatRequest = NewChatRequest(
                profileName: HermesDeepLink.profileName(fromNewChatInProfile: url)
            )
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: false)
            return
        }

        // A bot link carries its own server, Bot connection and Profile, so it may
        // have to switch servers or wait for sign-in before it can open (#554).
        if let destination = HermesDeepLink.botDestination(from: url) {
            routeBot(destination)
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            pendingDeepLinkedSessionID = sessionID
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
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

#Preview {
    ContentView(authManager: AuthManager())
}
