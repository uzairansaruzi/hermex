import SwiftData
import SwiftUI

/// The active webui server's sections on its page: connection and update, sessions and the
/// main page's entries, defaults, and offline data. The page's list carries their loads and
/// dialogs (`webuiServerPresentations`), since a section's own modifiers would run per row.
struct WebuiServerSections: View {
    @Bindable var authManager: AuthManager
    @Bindable var model: WebuiServerSettingsModel

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
    @AppStorage(BotModeGate.isEnabledKey) private var isBotModeEnabled = false

    private var server: URL { model.server }

    var body: some View {
        Section(String(localized: "Server")) {
            LabeledContent(String(localized: "URL")) {
                Text(server.absoluteString).textSelection(.enabled)
            }

            LabeledContent(String(localized: "Status")) {
                serverStatusPill
            }

            LabeledContent(String(localized: "Version")) {
                serverVersionContent
            }

            serverUpdateNote
            serverUpdateCheckAction
            serverUpdateAction

            NavigationLink {
                CustomHeadersSettingsView(authManager: authManager)
            } label: {
                SettingsLabel(title: String(localized: "Connection Headers"), systemImage: "list.bullet.rectangle")
            }
            .accessibilityHint("Opens the custom request headers editor.")

            // Not behind the Bot Mode preview gate (#557): this login is what push
            // pairing needs, and push serves this server's webui sessions too.
            NavigationLink {
                BotConnectionView(server: server) { authManager.hermesSignInSaved(server: server) }
            } label: {
                SettingsLabel(
                    title: String(localized: "Hermes connection"),
                    systemImage: "bell.badge",
                    note: String(localized: "Needed for notifications and Bots.")
                )
            }
        }

        Section {
            NavigationLink {
                ArchivedSessionsView(server: server, onAPIError: authManager.handleAPIError)
            } label: {
                SettingsLabel(title: String(localized: "Archived Sessions"), systemImage: "archivebox")
            }

            Toggle(isOn: $showsSessionMessageCount) {
                SettingsLabel(title: String(localized: "Message Count"), systemImage: "number")
            }

            Toggle(isOn: $showsSessionWorkspace) {
                SettingsLabel(title: String(localized: "Workspace"), systemImage: "folder")
            }

            Toggle(isOn: $showsCronSessions) {
                SettingsLabel(title: String(localized: "Cron Sessions"), systemImage: "clock.arrow.2.circlepath")
            }

            Toggle(isOn: Binding(
                get: { model.cliSessionsSync.showsCliSessions },
                set: { model.cliSessionsSync.setShowsCliSessions($0) }
            )) {
                SettingsLabel(title: String(localized: "CLI Sessions"), systemImage: "terminal")
            }

            Toggle(isOn: Binding(
                get: { model.cliSessionsSync.showsClaudeCodeSessions },
                set: { model.cliSessionsSync.setShowsClaudeCodeSessions($0) }
            )) {
                SettingsLabel(title: String(localized: "Claude Code Sessions"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .disabled(!model.cliSessionsSync.showsCliSessions)

            Toggle(isOn: $showsSubagentSessions) {
                SettingsLabel(title: String(localized: "Subagent Sessions"), systemImage: "arrow.triangle.branch")
            }
        } header: {
            Text("Sessions")
        } footer: {
            sessionSyncFootnote
        }

        // Main Page configures only a webui server's home.
        Section {
            Toggle(isOn: $showsTasksSection) {
                SettingsLabel(title: String(localized: "Tasks"), systemImage: "calendar.badge.clock")
            }

            Toggle(isOn: $showsKanbanSection) {
                SettingsLabel(title: String(localized: "Kanban"), systemImage: "rectangle.split.3x1")
            }

            Toggle(isOn: $showsSkillsSection) {
                SettingsLabel(title: String(localized: "Skills"), systemImage: "hammer")
            }

            Toggle(isOn: $showsMemorySection) {
                SettingsLabel(title: String(localized: "Memory"), systemImage: "brain")
            }

            Toggle(isOn: $showsInsightsSection) {
                SettingsLabel(title: String(localized: "Usage"), systemImage: "chart.bar")
            }

            Toggle(isOn: $showsActiveProfileSection) {
                SettingsLabel(title: String(localized: "Active Profile"), systemImage: "person.crop.circle")
            }

            Toggle(isOn: $showsProjectsSection) {
                SettingsLabel(title: String(localized: "Projects"), systemImage: "folder.badge.gearshape")
            }

            Toggle(isOn: $isBotModeEnabled) {
                SettingsLabel(
                    title: String(localized: "Bot Mode (beta)"),
                    systemImage: "cpu",
                    note: String(localized: "Adds a Bots row to this server's home.")
                )
            }
        } header: {
            Text("Main Page")
        } footer: {
            Text("An entry you turn off comes back only from here.")
        }

        Section(String(localized: "Defaults")) {
            Button {
                model.showsDefaultModelPicker = true
            } label: {
                LabeledContent {
                    Text(defaultModelLabel)
                } label: {
                    SettingsLabel(title: String(localized: "Default Model"), systemImage: "cpu")
                }
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Opens the default model picker.")

            Button {
                model.showsDefaultProfilePicker = true
            } label: {
                LabeledContent {
                    Text(defaultProfileLabel)
                } label: {
                    SettingsLabel(title: String(localized: "Default Profile"), systemImage: "person.crop.circle")
                }
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Opens the default profile picker.")

            NavigationLink {
                ProvidersView(server: server)
            } label: {
                SettingsLabel(title: String(localized: "Providers"), systemImage: "key.horizontal")
            }
            .accessibilityHint("Opens the provider status screen.")
        }

        Section {
            Button(role: .destructive) {
                model.isConfirmingClearCache = true
            } label: {
                if model.isClearingCache {
                    ProgressView()
                } else {
                    Text("Clear Offline Cache")
                }
            }
            .disabled(model.isClearingCache)
        } header: {
            Text("Offline Data")
        } footer: {
            Text(model.cacheStatusMessage ?? String(localized: "Clears this server's cache only."))
        }
    }

    @ViewBuilder
    private var sessionSyncFootnote: some View {
        if let syncError = model.cliSessionsSync.syncErrorMessage
            ?? model.cliSessionsSync.claudeCodeSyncErrorMessage {
            Label {
                Text(syncError)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } else if model.cliSessionsSync.serverSyncsCliSessions
            || model.cliSessionsSync.serverSyncsClaudeCodeSessions {
            Text("Synced with this server's WebUI.")
        }
    }

    @ViewBuilder
    private var serverVersionContent: some View {
        if model.isLoadingServerSettings {
            ProgressView()
        } else if let serverVersion = model.serverVersion {
            Text(serverVersion)
                .textSelection(.enabled)
        } else {
            Text(model.serverSettingsError ?? String(localized: "Unknown"))
        }
    }

    @ViewBuilder
    private var serverStatusPill: some View {
        if model.isLoadingServerSettings {
            SettingsStatusPill(label: String(localized: "Loading"))
        } else if model.serverSettingsError == nil, model.serverVersion != nil {
            // Only "Connected" when the latest load actually succeeded — a stale
            // `serverVersion` from an earlier success must not mask a now-failed
            // load (e.g. a restart that never came back).
            SettingsStatusPill(label: String(localized: "Connected"))
        } else {
            SettingsStatusPill(label: model.serverSettingsError ?? String(localized: "Unknown"), tint: .orange)
        }
    }

    private var defaultModelLabel: String {
        if model.isLoadingDefaultModel {
            return String(localized: "Loading")
        }

        guard let defaultModel = model.defaultModel, !defaultModel.isEmpty else {
            return String(localized: "Not set")
        }

        return defaultModel
    }

    private var defaultProfileLabel: String {
        if model.isLoadingDefaultProfile {
            return String(localized: "Loading")
        }

        if let displayName = model.defaultProfileDisplayName, !displayName.isEmpty {
            return displayName
        }

        guard let name = model.defaultProfileName, !name.isEmpty else {
            return String(localized: "Not set")
        }

        return name == "default" ? String(localized: "Default") : name
    }

    // The manual "Check for updates" control (#308). Distinct from the passive
    // on-open check: it forces a live git fetch on the server. While a check is in
    // flight it swaps to a "Checking…" row; it's disabled during an apply so
    // the two update flows never run at once.
    @ViewBuilder
    private var serverUpdateCheckAction: some View {
        if model.isCheckingForUpdates {
            updateProgressRow(String(localized: "Checking for updates…"))
        } else {
            Button(String(localized: "Check for updates")) {
                Task {
                    await model.checkForUpdatesManually()
                }
            }
            .disabled(model.isUpdateApplyInFlight)
        }
    }

    // Informational only — never a warning. A normal, up-to-date server shows a
    // calm "Up to date"; a server that genuinely lags shows how far behind it is.
    // When the check is disabled, errored, or hasn't loaded, we show nothing here
    // and let the plain version row stand on its own.
    @ViewBuilder
    private var serverUpdateNote: some View {
        if model.serverVersion != nil, let serverUpdateState = model.serverUpdateState {
            switch serverUpdateState {
            case .upToDate:
                updateNoteRow(systemImage: "checkmark.circle", tint: .secondary, text: String(localized: "Up to date"))
            case let .updateAvailable(behind):
                updateNoteRow(systemImage: "arrow.up.circle", tint: .blue, text: String(localized: "Update available · \(behind) behind"))
            case .unavailable:
                EmptyView()
            }
        }
    }

    private func updateNoteRow(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(text)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // The in-app "Update" action. Every phase resolves to a concrete UI so there
    // is never a stuck spinner *or* a silent vanish: the initial Update button is
    // gated on the server reporting a pending update, but once a run is underway
    // the progress / blocked / failed UI is driven purely by `updateApplyPhase`.
    // That keeps the message + Retry visible even if a slow/failed restart leaves
    // `serverUpdateState` nil or stale. Success returns to `.idle`, where the
    // refreshed `.upToDate` state removes the button.
    @ViewBuilder
    private var serverUpdateAction: some View {
        switch model.updateApplyPhase {
        case .idle:
            if model.serverVersion != nil, case .updateAvailable = model.serverUpdateState {
                updateActionButton(title: String(localized: "Update"))
            }
        case .applying:
            updateProgressRow(String(localized: "Starting update…"))
        case .recovering:
            updateProgressRow(String(localized: "Updating & restarting…"))
        case .blocked:
            updateMessageRow(systemImage: "clock", tint: .secondary)
            updateActionButton(title: String(localized: "Retry update"))
        case .failed:
            updateMessageRow(systemImage: "exclamationmark.triangle", tint: .orange)
            updateActionButton(title: String(localized: "Retry update"))
        }
    }

    private func updateActionButton(title: String) -> some View {
        Button(title) {
            model.isConfirmingUpdate = true
        }
        // Mirror of the check button's `isUpdateApplyInFlight` guard: while a
        // forced check is running, block Update/Retry so apply can't race the
        // in-flight POST /api/updates/check (#308 review).
        .disabled(model.isCheckingForUpdates)
    }

    private func updateProgressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()

            Text(text)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func updateMessageRow(systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(model.updateApplyMessage ?? String(localized: "The update could not be applied."))
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The active webui server page's load, dialogs, and pickers, on the page's list.
    func webuiServerPresentations(
        _ model: WebuiServerSettingsModel,
        onDefaultProfileSelected: @escaping (DefaultProfileSelection) -> Void
    ) -> some View {
        modifier(WebuiServerPresentations(model: model, onDefaultProfileSelected: onDefaultProfileSelected))
    }
}

private struct WebuiServerPresentations: ViewModifier {
    @Bindable var model: WebuiServerSettingsModel
    let onDefaultProfileSelected: (DefaultProfileSelection) -> Void
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .task {
                await model.load()
            }
            .alert("Clear this server's cache?", isPresented: $model.isConfirmingClearCache) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await model.clearOfflineCache(in: modelContext)
                    }
                }
            } message: {
                Text("This server's cached sessions and messages will be deleted. Other servers and online server data are not affected.")
            }
            .alert("Update server?", isPresented: $model.isConfirmingUpdate) {
                Button("Cancel", role: .cancel) {}
                Button("Update") {
                    Task {
                        await model.applyServerUpdate()
                    }
                }
            } message: {
                Text("This pulls the latest Hermes server version and restarts it. Active chats may be interrupted briefly; the app reconnects when the server is back.")
            }
            // Result of a manual "Check for updates" tap (#308). The outcome is kept
            // set after dismissal so the title/message read off it without blanking
            // mid-animation; a fresh check overwrites it before re-presenting.
            .alert(forcedCheckAlertTitle, isPresented: $model.isPresentingForcedCheckResult) {
                if case .updateAvailable = model.forcedCheckOutcome {
                    // The popup already carries the restart warning, so Update applies
                    // directly — no second confirmation dialog (issue #308).
                    Button("Update") {
                        Task {
                            await model.applyServerUpdate()
                        }
                    }
                    Button("Dismiss", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(forcedCheckAlertMessage)
            }
            .sheet(isPresented: $model.showsDefaultModelPicker) {
                DefaultModelPickerView(
                    server: model.server,
                    currentDefaultModel: model.defaultModel,
                    onSave: { defaultModel in
                        model.defaultModel = defaultModel
                    }
                )
            }
            .sheet(isPresented: $model.showsDefaultProfilePicker) {
                DefaultProfilePickerView(
                    server: model.server,
                    currentDefaultProfileName: model.defaultProfileName,
                    onSave: { selection in
                        onDefaultProfileSelected(selection)
                        model.defaultProfileName = selection.name
                        model.defaultProfileDisplayName = selection.displayName
                        if let defaultModel = selection.defaultModel, !defaultModel.isEmpty {
                            model.defaultModel = defaultModel
                        }
                    }
                )
            }
    }

    private var forcedCheckAlertTitle: String {
        switch model.forcedCheckOutcome {
        case let .updateAvailable(behind):
            return String(localized: "Update available · \(behind) behind")
        case .upToDate:
            return String(localized: "You're up to date")
        case .disabled:
            return String(localized: "Update checks are off")
        case .error, .none:
            return String(localized: "Couldn't check for updates")
        }
    }

    private var forcedCheckAlertMessage: String {
        switch model.forcedCheckOutcome {
        case .updateAvailable:
            return String(localized: "This pulls the latest Hermes server version and restarts it. Active chats may be interrupted briefly; the app reconnects when the server is back.")
        case .upToDate:
            return String(localized: "The Hermes server is running the latest version.")
        case .disabled:
            return String(localized: "Update checks are turned off on this server.")
        case .error, .none:
            return String(localized: "Something went wrong reaching the server. Try again in a moment.")
        }
    }
}

private struct CustomHeadersSettingsView: View {
    @Bindable var authManager: AuthManager
    @State private var headers: [CustomHeader]
    @Environment(\.scenePhase) private var scenePhase

    init(authManager: AuthManager) {
        self.authManager = authManager
        _headers = State(initialValue: authManager.currentCustomHeaders)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CustomHeadersEditor(headers: $headers)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Connection Headers")
        .navigationBarTitleDisplayMode(.inline)
        // Live-refresh the network clients on every edit (cheap, in-memory only)
        // but defer the slow Keychain write until the editor is dismissed so
        // typing never stutters.
        .onChange(of: headers) { _, newValue in
            authManager.updateCustomHeaders(newValue, persist: false)
        }
        .onDisappear {
            authManager.updateCustomHeaders(headers, persist: true)
        }
        // onDisappear doesn't fire when the app is backgrounded or terminated
        // mid-edit, so also flush to the Keychain when the scene leaves active.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                authManager.updateCustomHeaders(headers, persist: true)
            }
        }
    }
}
