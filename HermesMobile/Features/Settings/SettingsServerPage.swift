import SwiftData
import SwiftUI

/// One server's page (#1252): its identity, then its connection and sessions, then the way to
/// switch to it, sign out of it, or remove it. The active server's sections load from it;
/// another server shows only what this iPhone saved.
struct SettingsServerPage: View {
    @Bindable var authManager: AuthManager
    let account: ServerAccount
    let onDefaultProfileSelected: (DefaultProfileSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var displayName: String
    @State private var initials: String
    @State private var colorHex: String
    @State private var isConfirmingRemove = false
    @State private var isConfirmingSignOut = false
    @State private var isRemoving = false
    /// Set only while this is the active webui server, the one kind whose page loads settings.
    @State private var webui: WebuiServerSettingsModel?
    /// The active Hermes server's saved connection, read on appear (#899): its username shows
    /// on the connection row, and Archived Sessions reads through it (#1048).
    @State private var hermesConnection: BotConnection?
    @State private var moveRequest: MoveToHermesRequest?

    init(
        authManager: AuthManager,
        account: ServerAccount,
        onDefaultProfileSelected: @escaping (DefaultProfileSelection) -> Void
    ) {
        self.authManager = authManager
        self.account = account
        self.onDefaultProfileSelected = onDefaultProfileSelected
        _displayName = State(initialValue: account.displayName)
        _initials = State(initialValue: account.initials)
        _colorHex = State(initialValue: account.headerLogoColorHex)
        if account.id == authManager.activeServerID, account.kind == .webui, let server = URL(string: account.urlString) {
            _webui = State(initialValue: WebuiServerSettingsModel(server: server, onAPIError: authManager.handleAPIError))
        }
    }

    private var server: URL? { URL(string: account.urlString) }
    private var isActive: Bool { account.id == authManager.activeServerID }
    private var hasOtherServers: Bool { authManager.servers.count > 1 }
    private var hostFallback: String { server?.host ?? account.urlString }
    /// The active Hermes server, whose page shows its sign-in, release, and update standing.
    private var activeHermesServer: URL? { isActive && account.kind == .hermes ? server : nil }

    var body: some View {
        let page = List {
            Section(String(localized: "Identity")) {
                ServerIdentityEditor(
                    displayName: $displayName,
                    initials: $initials,
                    colorHex: $colorHex,
                    fallbackName: hostFallback
                )
            }

            if let webui {
                WebuiServerSections(authManager: authManager, model: webui)
            } else if let server = activeHermesServer {
                hermesSections(server: server)
            } else {
                inactiveServerSection
            }

            if account.kind == .webui {
                MoveToHermesSection(authManager: authManager, account: account, request: $moveRequest)
            }

            accountSections
        }
        .settingsPage(displayName.isEmpty ? hostFallback : displayName)
        // Persist identity edits to this server's registry entry. When it's the
        // active server, the registry mirrors them into the global @AppStorage so
        // the avatar / header tint update live (#17).
        .onChange(of: displayName) { persistIdentity() }
        .onChange(of: initials) { persistIdentity() }
        .onChange(of: colorHex) { persistIdentity() }
        .task {
            guard let server = activeHermesServer else { return }
            // A Hermes server has no webui to load from, so no webui 401 can sign it out (#899).
            hermesConnection = try? BotConnectionStore().load(server: server)
            let updates = HermesUpdateModel.for(server: server)
            updates.onUpdated = { version in
                authManager.hermesServerUpdated(server: server, to: version)
            }
            await updates.appear()
        }
        .onDisappear {
            if let server = activeHermesServer { HermesUpdateModel.for(server: server).leaveSettings() }
        }
        .sheet(item: $moveRequest) { MoveToHermesSheet(auth: authManager, sourceID: account.id, entry: $0.entry) }
        .alert(removeAlertTitle, isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button(removeButtonTitle, role: .destructive) {
                Task { await remove() }
            }
        } message: {
            Text(removeAlertMessage)
        }
        .alert("Sign out of this server?", isPresented: $isConfirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    // Purge this server's offline cache before signing out, while
                    // the view (and its modelContext) is still alive. Best-effort:
                    // the cache is server-keyed, so a leftover row can never surface
                    // as another server's.
                    if let server { try? CacheStore.clearCache(for: server, in: modelContext) }
                    await authManager.signOut()
                    dismiss()
                }
            }
        } message: {
            Text("Deletes this server's saved sign-in and shows its sign-in form.")
        }

        if let webui {
            page.webuiServerPresentations(webui, onDefaultProfileSelected: onDefaultProfileSelected)
        } else {
            page
        }
    }

    /// The active Hermes server's sign-in, with its headers, the release saved at that sign-in,
    /// and the host's update standing (#1075).
    @ViewBuilder
    private func hermesSections(server: URL) -> some View {
        Section {
            LabeledContent(String(localized: "URL")) {
                Text(account.urlString).textSelection(.enabled)
            }

            NavigationLink {
                BotConnectionView(server: server) { authManager.hermesSignInSaved(server: server) }
            } label: {
                LabeledContent {
                    Text(hermesConnection?.username ?? "")
                } label: {
                    SettingsLabel(title: String(localized: "Hermes connection"), systemImage: "person.badge.key")
                }
            }

            if let version = account.serverVersion {
                LabeledContent(String(localized: "Version"), value: version)
            }

            HermesUpdateCallout(model: HermesUpdateModel.for(server: server), version: account.serverVersion)
        } header: {
            Text("Server")
        } footer: {
            if hermesConnection?.hasNoCredentials == true {
                OpenDashboardWarning()
            }
        }

        if let hermesConnection {
            Section(String(localized: "Sessions")) {
                NavigationLink {
                    ArchivedSessionsView(server: server, hermes: .saved(hermesConnection, server: server, profile: nil))
                } label: {
                    SettingsLabel(title: String(localized: "Archived Sessions"), systemImage: "archivebox")
                }
            }
        }
    }

    /// A server that isn't active shows what this iPhone saved for it, and its Hermes sign-in.
    @ViewBuilder
    private var inactiveServerSection: some View {
        Section {
            LabeledContent(String(localized: "URL")) {
                Text(account.urlString).textSelection(.enabled)
            }

            LabeledContent(String(localized: "Status")) {
                SettingsStatusPill(label: String(localized: "Inactive"))
            }

            // Not behind the Bot Mode preview gate (#557): this login is what push pairing
            // needs. On a Hermes server it is the server's own sign-in, and saving it signs a
            // signed-out server back in (#899).
            if let server {
                NavigationLink {
                    BotConnectionView(server: server) { authManager.hermesSignInSaved(server: server) }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Hermes connection"),
                        systemImage: account.kind == .hermes ? "person.badge.key" : "bell.badge",
                        note: account.kind == .hermes ? nil : String(localized: "Needed for notifications and Bots.")
                    )
                }
            }
        } header: {
            Text("Server")
        }
    }

    @ViewBuilder
    private var accountSections: some View {
        if !isActive {
            Section {
                Button(String(localized: "Switch to This Server")) {
                    authManager.switchActiveServer(to: account)
                }
            }
        }

        // Signing out keeps a Hermes server and shows its sign-in form (#899); a webui
        // server's sign-out removes it, below.
        if activeHermesServer != nil {
            Section {
                Button(String(localized: "Sign Out of This Server"), role: .destructive) {
                    isConfirmingSignOut = true
                }
            } footer: {
                Text("Deletes the saved sign-in; the server stays.")
            }
        }

        Section {
            Button(role: .destructive) {
                isConfirmingRemove = true
            } label: {
                if isRemoving {
                    ProgressView()
                } else {
                    Text(removeButtonTitle)
                }
            }
            .disabled(isRemoving)
        } footer: {
            Text(removeFootnote)
        }
    }

    private func persistIdentity() {
        authManager.updateServerIdentity(
            account,
            displayName: displayName,
            initials: initials,
            headerLogoColorHex: colorHex
        )
    }

    private func remove() async {
        let wasActive = isActive
        isRemoving = true
        // Purge this server's offline cache *before* removing it, while
        // the view (and its modelContext) is still alive — removing the
        // active server flips auth state and tears this stack down on
        // its own. Best-effort: the cache is server-keyed, so a leftover
        // row can never surface as another server's content (#18, PR
        // #286 W2).
        if let server {
            try? CacheStore.clearCache(for: server, in: modelContext)
            await ChatDraftStore.shared.discardDrafts(for: server)
        }
        await authManager.removeServer(account)
        // Only a non-active removal leaves this view alive to reset its
        // state and pop; the active-server case is already torn down.
        if !wasActive {
            isRemoving = false
            dismiss()
        }
    }

    /// Whether this page's remove button signs out of the active webui server, which also
    /// removes it. An active Hermes server is removed here under that name instead, because
    /// its Sign Out keeps the server and shows its sign-in form (#899).
    private var signsOut: Bool { isActive && account.kind == .webui }

    private var removeButtonTitle: String {
        signsOut ? String(localized: "Sign Out of This Server") : String(localized: "Remove Server")
    }

    private var removeAlertTitle: String {
        if signsOut { return String(localized: "Sign out of this server?") }
        if moveRemovalMessage != nil { return String(localized: "Remove \(displayName.isEmpty ? hostFallback : displayName)?") }
        return String(localized: "Remove this server?")
    }

    /// What removing a server a move involves leaves behind and keeps routing (S2, S3).
    private var moveRemovalMessage: String? {
        MoveToHermesRemoval.message(for: account, servers: authManager.servers)
    }

    private var removeFootnote: String {
        signsOut
            ? String(localized: "Signs out and removes this server from this iPhone.")
            : String(localized: "Removes this server from this iPhone.")
    }

    private var removeAlertMessage: String {
        guard let moved = moveRemovalMessage else { return usualRemovalMessage }
        // S2 replaces the usual copy for a webui server; a destination keeps it and adds S3.
        return signsOut || isActive || account.kind == .hermes ? usualRemovalMessage + " " + moved : moved
    }

    private var usualRemovalMessage: String {
        if signsOut {
            return hasOtherServers
                ? String(localized: "You'll switch to another configured server. Sign in again to use this one.")
                : String(localized: "You'll return to onboarding and need the server URL and password to sign back in.")
        }
        if isActive { return activeHermesRemovalText }
        return String(localized: "This removes the server and its saved settings on this device. Your active server is unaffected.")
    }

    private var activeHermesRemovalText: String {
        hasOtherServers
            ? String(localized: "Removes this server, its saved sign-in and its Bot data on this device, then switches to another configured server.")
            : String(localized: "Removes this server, its saved sign-in and its Bot data on this device, then returns to onboarding.")
    }
}

/// A webui server's Move to Hermes section (#1218): A1 before a move, then where it stands (1A):
/// moving, paused, finished with its report waiting for Done, or moved. Each sets the request
/// the page opens the guided sheet for.
private struct MoveToHermesSection: View {
    @Bindable var authManager: AuthManager
    let account: ServerAccount
    @Binding var request: MoveToHermesRequest?
    private let notices = MoveToHermesNotices.shared

    var body: some View {
        Section {
            if let notice = notices.card(forSource: account.id, in: authManager.servers) {
                status(notice)
            } else {
                if let host = savedHost {
                    LabeledContent(String(localized: "Hermes host"), value: String(localized: "\(host) (saved sign-in)"))
                }
                Button(String(localized: "Move to Hermes…")) { request = MoveToHermesRequest(entry: .start) }
            }
        } header: {
            Text("Move to Hermes")
        } footer: {
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let notice = notices.card(forSource: account.id, in: authManager.servers) {
            if case .moved = notice.stage {
                Text(notice.report.map {
                    String(localized: "Last counted \($0.recordedAt.formatted(date: .abbreviated, time: .omitted)). Sending here too can split a conversation.")
                } ?? String(localized: "Sending here too can split a conversation."))
            }
        } else {
            Text("Moving brings chats, pins and drafts to Hermes.")
        }
    }

    /// The host this server's saved Hermes sign-in names, as the move would show it.
    private var savedHost: String? {
        guard let url = URL(string: account.id),
              let saved = try? BotConnectionStore(keychain: authManager.keychain).load(server: url) else { return nil }
        let id = MoveToHermesRunner.destinationID(for: saved)
        if let configured = authManager.servers.first(where: { $0.id == id }) { return MoveToHermesModel.name(configured) }
        return saved.name.isEmpty ? (saved.address.host ?? saved.address.absoluteString) : saved.name
    }

    @ViewBuilder
    private func status(_ notice: MoveToHermesNotice) -> some View {
        let destination = MoveToHermesModel.name(notice.destination)
        let counts = notice.inHermes.flatMap { inHermes in notice.total.map { String(localized: "\(inHermes) of \($0) in \(destination)") } }
        switch notice.stage {
        case .running:
            Text("Moving to \(destination)")
        case .paused(let canResume):
            LabeledContent(String(localized: "Paused"), value: counts ?? "")
            if canResume { Button(String(localized: "Resume")) { request = MoveToHermesRequest(entry: .resume) } }
            Button(String(localized: "Details")) { request = MoveToHermesRequest(entry: .details) }
        case .finished:
            LabeledContent(String(localized: "Finished"), value: counts ?? "")
            Button(String(localized: "See Report")) { request = MoveToHermesRequest(entry: .details) }
        case .moved:
            LabeledContent(String(localized: "Moved to"), value: destination)
            LabeledContent(String(localized: "May be only here"), value: onlyHere(notice.report))
            Button(String(localized: "Copy Missing Chats Again…")) { request = MoveToHermesRequest(entry: .copyMissingAgain) }
        }
    }

    /// Chats the last count left only here, or unknown: never zero when the move couldn't count.
    private func onlyHere(_ report: MovedWebuiReport?) -> String {
        guard let remaining = report?.remaining, let unchecked = report?.unchecked else { return String(localized: "Not counted") }
        return String(localized: "\(remaining + unchecked) chats")
    }
}

private struct MoveToHermesRequest: Identifiable {
    let entry: MoveToHermesEntry
    var id: String { "\(entry)" }
}
