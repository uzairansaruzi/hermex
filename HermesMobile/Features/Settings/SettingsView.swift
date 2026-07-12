import SwiftUI
import SwiftData
import UIKit
import UserNotifications

/// A Settings section a deep link can scroll to when the screen opens — the
/// avatar long-press "Manage Servers" shortcut lands on the Servers card (#283).
enum SettingsScrollAnchor: Hashable {
    case servers
}

struct SettingsView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    /// When set, Settings scrolls to this section once on first appear (#283).
    let initialScrollTarget: SettingsScrollAnchor?

    init(authManager: AuthManager, server: URL, initialScrollTarget: SettingsScrollAnchor? = nil) {
        self.authManager = authManager
        self.server = server
        self.initialScrollTarget = initialScrollTarget
        // The CLI-sessions toggle is server-synced (#19): loads adopt the
        // server's `show_cli_sessions`, toggles POST it back, failures revert.
        // Stored per-server so one server's value never leaks into another.
        _cliSessionsSync = State(initialValue: CliSessionsSyncModel(server: server) { value in
            let client = APIClient(baseURL: server)
            _ = try await client.updateSettings(showCliSessions: value)
        } writeClaudeCodeToServer: { value in
            let client = APIClient(baseURL: server)
            _ = try await client.updateSettings(showClaudeCodeSessions: value)
        })
    }

    @ScaledMetric(relativeTo: .body) private var settingsCardSpacing: CGFloat = 18
    @State private var isConfirmingReconfigure = false
    @State private var didScrollToInitialTarget = false
    @State private var isPresentingAddServer = false
    @State private var isConfirmingClearCache = false
    @State private var isClearingCache = false
    @State private var cacheStatusMessage: String?
    @State private var isLoadingServerSettings = false
    @State private var serverVersion: String?
    @State private var serverSettingsError: String?
    @State private var serverUpdateState: UpdatesCheckResponse.WebUIUpdateState?
    @State private var updateApplyPhase: ServerUpdateApplyPhase = .idle
    @State private var isConfirmingUpdate = false
    @State private var updateApplyMessage: String?
    @State private var isCheckingForUpdates = false
    @State private var forcedCheckOutcome: UpdatesCheckResponse.ForcedCheckOutcome?
    @State private var isPresentingForcedCheckResult = false
    @State private var defaultModel: String?
    @State private var defaultProfileName: String?
    @State private var defaultProfileDisplayName: String?
    @State private var isLoadingDefaultModel = false
    @State private var isLoadingDefaultProfile = false
    @State private var showDefaultModelPicker = false
    @State private var showDefaultProfilePicker = false
    @State private var notificationPermissionStatus: UNAuthorizationStatus?
    @State private var notificationStatusMessage: String?
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @AppStorage(ResponseCompletionNotifications.hasRequestedPermissionKey) private var hasRequestedResponseCompletionNotificationPermission = false
    @AppStorage(AgentRunLiveActivityPrivacy.showsResponseExcerptsKey) private var showsLiveActivityResponseExcerpts = false
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) private var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @State private var cliSessionsSync: CliSessionsSyncModel
    @AppStorage(StreamingSendBehavior.storageKey) private var streamingSendBehaviorRawValue = StreamingSendBehavior.steer.rawValue
    @AppStorage(ComposerSTTProviderPreference.storageKey) private var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue
    @AppStorage(ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey) private var showsThinkingAndToolCards = true
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var thinkingCardsStartExpanded = false
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var toolCardsStartExpanded = false
    @AppStorage(ChatTranscriptDisplaySettings.hidesAttachmentPathsKey) private var hidesAttachmentPaths = true
    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey) private var showsAssistantTurnTimestamps = false
    @AppStorage(ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey) private var wrapsCodeBlockLines = false
    @AppStorage(ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey) private var rtlChatLayoutEnabled = ChatTranscriptDisplaySettings.rtlChatLayoutDefaultEnabled
    @AppStorage(StreamedTextAnimationSettings.isEnabledKey) private var isStreamedTextAnimationEnabled = true
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(SessionIdentitySettings.displayNameKey) private var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) private var identityInitials = ""
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: settingsCardSpacing) {
                SettingsCard(title: String(localized: "Identity")) {
                    SessionIdentitySettingsEditor(
                        displayName: $identityDisplayName,
                        initials: identityInitialsBinding,
                        previewInitials: identityPreviewInitials,
                        previewColor: HeaderLogoColor.color(for: headerLogoColorHex),
                        previewForeground: HeaderLogoColor.prefersDarkForeground(for: headerLogoColorHex) ? .black : .white
                    )
                }

                SettingsCard(title: String(localized: "Archived Sessions")) {
                    NavigationLink {
                        ArchivedSessionsView(server: server, onAPIError: authManager.handleAPIError)
                    } label: {
                        SettingsAccessoryRow(title: String(localized: "Archived Sessions"), systemImage: "archivebox")
                    }
                    .buttonStyle(.plain)
                }

                SettingsCard(title: String(localized: "Appearance")) {
                    SettingsPickerRow(
                        title: String(localized: "Theme"),
                        systemImage: "circle.lefthalf.filled",
                        selection: $appThemeRawValue
                    ) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }

                    SettingsDivider()

                    HeaderLogoColorSettings(
                        selectedHex: $headerLogoColorHex,
                        customColor: headerLogoColorBinding
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Tint New Chat & Send"),
                        systemImage: "paintbrush.pointed",
                        isOn: $tintsPrimaryActions
                    )

                    SettingsFootnote(String(localized: "Apply your header color to these primary buttons."))

                    SettingsDivider()

                    AppIconSettingsSection()
                }

                SettingsCard(title: String(localized: "Interaction")) {
                    SettingsToggleRow(
                        title: String(localized: "Haptic Feedback"),
                        systemImage: "iphone.radiowaves.left.and.right",
                        isOn: $isHapticsEnabled
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Response Complete Alerts"),
                        systemImage: "bell",
                        isOn: responseCompletionNotificationBinding
                    )

                    if let notificationStatusText {
                        SettingsFootnote(notificationStatusText)
                    }

                    SettingsDivider()

                    SettingsPickerRow(
                        title: String(localized: "Send While Responding"),
                        systemImage: "arrow.up.message",
                        selection: $streamingSendBehaviorRawValue
                    ) {
                        ForEach(StreamingSendBehavior.allCases) { behavior in
                            Text(behavior.settingsDescription).tag(behavior.rawValue)
                        }
                    }

                    SettingsDivider()

                    SettingsPickerRow(
                        title: String(localized: "Dictation Provider"),
                        systemImage: "mic",
                        selection: $sttProviderPreferenceRawValue
                    ) {
                        ForEach(ComposerSTTProviderPreference.allCases) { preference in
                            Text(preference.title).tag(preference.rawValue)
                        }
                    }

                    SettingsFootnote(String(localized: "On-device only keeps composer dictation audio off your Hermes server."))
                }

                SettingsCard(title: String(localized: "Chat")) {
                    SettingsToggleRow(
                        title: String(localized: "Thinking and Tool Cards"),
                        systemImage: "brain.head.profile",
                        isOn: $showsThinkingAndToolCards
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Expand Thinking by Default"),
                        systemImage: "rectangle.expand.vertical",
                        isOn: $thinkingCardsStartExpanded
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Expand Tools by Default"),
                        systemImage: "wrench.and.screwdriver",
                        isOn: $toolCardsStartExpanded
                    )

                    SettingsFootnote(String(localized: "Thinking and Tool cards start expanded instead of collapsed. Tapping a card still toggles it."))

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Streamed Text Animation"),
                        systemImage: "sparkles",
                        isOn: $isStreamedTextAnimationEnabled
                    )

                    SettingsFootnote(String(localized: "Fades words in as a response streams. Turn off to show text instantly."))

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Response Timestamps"),
                        systemImage: "clock",
                        isOn: $showsAssistantTurnTimestamps
                    )

                    SettingsFootnote(String(localized: "Adds a small marker and the time above each response so back-to-back replies are easier to tell apart."))

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Wrap Code Block Lines"),
                        systemImage: "arrow.turn.down.left",
                        isOn: $wrapsCodeBlockLines
                    )

                    SettingsFootnote(String(localized: "Wraps long lines in code blocks to fit the screen instead of scrolling sideways. You can also tap the wrap button in any code block."))

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Right-to-Left Chat Layout"),
                        systemImage: "text.alignright",
                        isOn: $rtlChatLayoutEnabled
                    )

                    SettingsFootnote(String(localized: "Lays out messages and the composer right-to-left for Arabic, Hebrew, Persian, and Urdu. Code, math, tables, and tool output stay left-to-right. Other screens are unaffected."))

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Hide Attachment Paths"),
                        systemImage: "eye.slash",
                        isOn: $hidesAttachmentPaths
                    )

                    SettingsFootnote(String(localized: "Hides the appended file-path line in your sent messages. Attachments still appear as previews, and the server still receives the paths."))

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Live Activity Excerpts"),
                        systemImage: "lock",
                        isOn: $showsLiveActivityResponseExcerpts
                    )

                    SettingsFootnote(String(localized: "Shows short response text on the Lock Screen and Dynamic Island."))
                }

                SettingsCard(title: String(localized: "Sessions")) {
                    SettingsToggleRow(
                        title: String(localized: "Message Count"),
                        systemImage: "number",
                        isOn: $showsSessionMessageCount
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Workspace"),
                        systemImage: "folder",
                        isOn: $showsSessionWorkspace
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Cron Sessions"),
                        systemImage: "clock.arrow.2.circlepath",
                        isOn: $showsCronSessions
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "CLI Sessions"),
                        systemImage: "terminal",
                        isOn: Binding(
                            get: { cliSessionsSync.showsCliSessions },
                            set: { cliSessionsSync.setShowsCliSessions($0) }
                        )
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Claude Code Sessions"),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        isOn: Binding(
                            get: { cliSessionsSync.showsClaudeCodeSessions },
                            set: { cliSessionsSync.setShowsClaudeCodeSessions($0) }
                        )
                    )
                    .disabled(!cliSessionsSync.showsCliSessions)

                    SettingsDivider()

                    SettingsToggleRow(
                        title: String(localized: "Subagent Sessions"),
                        systemImage: "arrow.triangle.branch",
                        isOn: $showsSubagentSessions
                    )

                    if let syncError = cliSessionsSync.syncErrorMessage
                        ?? cliSessionsSync.claudeCodeSyncErrorMessage {
                        SettingsErrorFootnote(syncError)
                    } else if cliSessionsSync.serverSyncsCliSessions
                        || cliSessionsSync.serverSyncsClaudeCodeSessions {
                        SettingsFootnote(String(localized: "Session visibility is synced with this server, so the WebUI follows it too."))
                    }
                }

                SettingsCard(title: String(localized: "Siri & Shortcuts")) {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: settingsURL) {
                            SettingsAccessoryRow(
                                title: String(localized: "Open Hermex Settings"),
                                systemImage: "gearshape",
                                accessorySystemImage: "arrow.up.forward"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open Hermex Settings")
                    }

                    SettingsFootnote(String(localized: "Run Hermex actions like New Chat from Siri, Spotlight, the Lock Screen, or the iPhone Action button. Open Hermex Settings to manage its Siri & Search options. To assign an action to the Action button, open the iOS Settings app, choose Action Button, then Shortcut, and pick a Hermex action."))
                }

                serversCard
                    .id(SettingsScrollAnchor.servers)

                SettingsCard(title: String(localized: "Active Server")) {
                    HapticButton {
                        showDefaultModelPicker = true
                    } label: {
                        SettingsAccessoryRow(
                            title: String(localized: "Default Model"),
                            value: defaultModelLabel,
                            systemImage: "cpu"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the default model picker.")

                    SettingsDivider()

                    HapticButton {
                        showDefaultProfilePicker = true
                    } label: {
                        SettingsAccessoryRow(
                            title: String(localized: "Default Profile"),
                            value: defaultProfileLabel,
                            systemImage: "person.crop.circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the default profile picker.")

                    SettingsDivider()

                    SettingsValueRow(title: String(localized: "Status")) {
                        serverStatusPill
                    }

                    SettingsDivider()

                    NavigationLink {
                        ProvidersView(server: server)
                    } label: {
                        SettingsAccessoryRow(
                            title: String(localized: "Providers"),
                            systemImage: "key.horizontal"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the provider status screen.")

                    SettingsDivider()

                    NavigationLink {
                        CustomHeadersSettingsView(authManager: authManager)
                    } label: {
                        SettingsAccessoryRow(
                            title: String(localized: "Connection Headers"),
                            systemImage: "list.bullet.rectangle"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the custom request headers editor.")

                    SettingsValueRow(title: String(localized: "Version")) {
                        serverVersionContent
                    }

                    serverUpdateCheckAction
                    serverUpdateNote
                    serverUpdateAction
                }

                SettingsCard(title: String(localized: "App")) {
                    SettingsInfoRow(title: String(localized: "Version"), value: appVersion)
                    SettingsInfoRow(title: String(localized: "Build"), value: appBuild)

                    SettingsDivider()

                    Link(destination: AppConfig.privacyPolicyURL) {
                        SettingsAccessoryRow(
                            title: String(localized: "Privacy Policy"),
                            systemImage: "hand.raised",
                            accessorySystemImage: "arrow.up.forward"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Privacy Policy")

                    SettingsDivider()

                    Link(destination: AppConfig.supportURL) {
                        SettingsAccessoryRow(
                            title: String(localized: "Support"),
                            systemImage: "questionmark.circle",
                            accessorySystemImage: "arrow.up.forward"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Support")
                }

                #if DEBUG
                SettingsCard(title: String(localized: "Developer")) {
                    NavigationLink {
                        StreamingLabView()
                    } label: {
                        SettingsAccessoryRow(title: String(localized: "Streaming Lab"), systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.plain)

                    SettingsFootnote(String(localized: "Debug builds only. Replay a canned reply and tune the streamed-text fade feel live."))
                }
                #endif

                SettingsCard(title: String(localized: "Offline Data")) {
                    SettingsFootnote(cacheStatusMessage ?? String(localized: "Cached sessions and messages are kept for offline viewing. Clearing removes this server's cache only — other servers and the Hermes server are not affected."))

                    SettingsButton(String(localized: "Clear Offline Cache"), role: .destructive, isLoading: isClearingCache) {
                        isConfirmingClearCache = true
                    }
                    .disabled(isClearingCache)
                }

                SettingsCard(title: String(localized: "Account")) {
                    SettingsFootnote(signOutFootnote)

                    SettingsButton(String(localized: "Sign Out of This Server"), role: .destructive) {
                        isConfirmingReconfigure = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Settings")
        .task {
            await loadServerSettings()
            await refreshNotificationPermissionStatus()
        }
        .alert("Clear this server's cache?", isPresented: $isConfirmingClearCache) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                Task {
                    await clearOfflineCache()
                }
            }
        } message: {
            Text("This server's cached sessions and messages will be deleted. Other servers and online server data are not affected.")
        }
        .alert("Update server?", isPresented: $isConfirmingUpdate) {
            Button("Cancel", role: .cancel) {}
            Button("Update") {
                Task {
                    await applyServerUpdate()
                }
            }
        } message: {
            Text("This pulls the latest Hermes server version and restarts it. Active chats may be interrupted briefly; the app reconnects when the server is back.")
        }
        // Result of a manual "Check for updates" tap (#308). The outcome is kept
        // set after dismissal so the title/message read off it without blanking
        // mid-animation; a fresh check overwrites it before re-presenting.
        .alert(
            forcedCheckAlertTitle,
            isPresented: $isPresentingForcedCheckResult
        ) {
            if case .updateAvailable = forcedCheckOutcome {
                // The popup already carries the restart warning, so Update applies
                // directly — no second confirmation dialog (issue #308).
                Button("Update") {
                    Task {
                        await applyServerUpdate()
                    }
                }
                Button("Dismiss", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(forcedCheckAlertMessage)
        }
        .alert("Sign out of this server?", isPresented: $isConfirmingReconfigure) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    // Purge this server's offline cache before signing out, while
                    // the view (and its modelContext) is still alive — sign-out
                    // forgets the active server from the registry, so its cache
                    // would otherwise be orphaned. Mirrors the server-detail
                    // remove path (#18). Best-effort: the cache is server-keyed,
                    // so a leftover row can never surface as another server's.
                    try? CacheStore.clearCache(for: server, in: modelContext)
                    await authManager.signOut()
                    dismiss()
                }
            }
        } message: {
            Text(signOutMessage)
        }
        // The Identity + Header Logo Color controls edit the *active* server (#17):
        // mirror their global @AppStorage value through to that server's registry
        // entry so it survives a switch and a relaunch. The @AppStorage write keeps
        // the live avatar/tint instant; this just persists it per server.
        .onChange(of: identityDisplayName) { syncActiveServerIdentity() }
        .onChange(of: identityInitials) { syncActiveServerIdentity() }
        .onChange(of: headerLogoColorHex) { syncActiveServerIdentity() }
        .sheet(isPresented: $isPresentingAddServer) {
            AddServerView(authManager: authManager)
        }
        .sheet(isPresented: $showDefaultModelPicker) {
            DefaultModelPickerView(
                server: server,
                currentDefaultModel: defaultModel,
                onSave: { model in
                    defaultModel = model
                }
            )
        }
        .sheet(isPresented: $showDefaultProfilePicker) {
            DefaultProfilePickerView(
                server: server,
                currentDefaultProfileName: defaultProfileName,
                onSave: { selection in
                    defaultProfileName = selection.name
                    defaultProfileDisplayName = selection.displayName
                    if let defaultModel = selection.defaultModel, !defaultModel.isEmpty {
                        self.defaultModel = defaultModel
                    }
                }
            )
        }
        .onAppear {
            // Land on the requested section once when opened via a deep link
            // (the avatar's "Manage Servers" → Servers card), not on every
            // re-appear after popping back from a sub-screen (#283).
            guard let initialScrollTarget, !didScrollToInitialTarget else { return }
            didScrollToInitialTarget = true
            DispatchQueue.main.async {
                proxy.scrollTo(initialScrollTarget, anchor: .top)
            }
        }
        }
    }

    @ViewBuilder
    private var serversCard: some View {
        SettingsCard(title: String(localized: "Servers")) {
            ForEach(authManager.servers) { account in
                if account.id != authManager.servers.first?.id {
                    SettingsDivider()
                }

                NavigationLink {
                    ServerDetailView(authManager: authManager, account: account)
                } label: {
                    SettingsServerRow(
                        account: account,
                        isActive: account.id == authManager.activeServerID
                    )
                }
                .buttonStyle(.plain)
            }

            SettingsDivider()

            HapticButton {
                isPresentingAddServer = true
            } label: {
                SettingsAccessoryRow(title: String(localized: "Add Server"), systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Adds another Hermes server.")
        }
    }

    /// The active server's registry entry, or nil while unconfigured.
    private var activeAccount: ServerAccount? {
        authManager.servers.first { $0.id == authManager.activeServerID }
    }

    /// Pushes the current global identity values (which the Identity + Header Logo
    /// Color controls edit) into the active server's registry entry, so per-server
    /// identity follows the active server (#17). Single-server users see no change.
    private func syncActiveServerIdentity() {
        guard let account = activeAccount else { return }
        authManager.updateServerIdentity(
            account,
            displayName: identityDisplayName,
            initials: identityInitials,
            headerLogoColorHex: headerLogoColorHex
        )
    }

    private var signOutFootnote: String {
        authManager.servers.count > 1
            ? String(localized: "Signs out of the active server and switches to another configured server.")
            : String(localized: "Signs out of the active server and returns to onboarding.")
    }

    private var signOutMessage: String {
        authManager.servers.count > 1
            ? String(localized: "You'll switch to another configured server. Sign in again to use this one.")
            : String(localized: "You'll return to onboarding and need the server URL and password to sign back in.")
    }

    @ViewBuilder
    private var serverVersionContent: some View {
        if isLoadingServerSettings {
            ProgressView()
        } else if let serverVersion {
            Text(serverVersion)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text(serverSettingsError ?? String(localized: "Unknown"))
                .foregroundStyle(.secondary)
        }
    }

    private var defaultModelLabel: String {
        if isLoadingDefaultModel {
            return String(localized: "Loading")
        }

        guard let defaultModel, !defaultModel.isEmpty else {
            return String(localized: "Not set")
        }

        return defaultModel
    }

    private var defaultProfileLabel: String {
        if isLoadingDefaultProfile {
            return String(localized: "Loading")
        }

        if let defaultProfileDisplayName, !defaultProfileDisplayName.isEmpty {
            return defaultProfileDisplayName
        }

        guard let defaultProfileName, !defaultProfileName.isEmpty else {
            return String(localized: "Not set")
        }

        return defaultProfileName == "default" ? String(localized: "Default") : defaultProfileName
    }

    @ViewBuilder
    private var serverStatusPill: some View {
        if isLoadingServerSettings {
            SettingsStatusPill(label: String(localized: "Loading"))
        } else if serverSettingsError == nil, serverVersion != nil {
            // Only "Connected" when the latest load actually succeeded — a stale
            // `serverVersion` from an earlier success must not mask a now-failed
            // load (e.g. a restart that never came back).
            SettingsStatusPill(label: String(localized: "Connected"))
        } else {
            SettingsStatusPill(label: serverSettingsError ?? String(localized: "Unknown"), tint: .orange)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown")
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown")
    }

    private var responseCompletionNotificationBinding: Binding<Bool> {
        Binding(
            get: { isResponseCompletionNotificationsEnabled },
            set: { isEnabled in
                if isEnabled {
                    Task {
                        await enableResponseCompletionNotifications()
                    }
                } else {
                    isResponseCompletionNotificationsEnabled = false
                    Task {
                        await refreshNotificationPermissionStatus()
                    }
                }
            }
        )
    }

    private var headerLogoColorBinding: Binding<Color> {
        Binding(
            get: { HeaderLogoColor.color(for: headerLogoColorHex) },
            set: { color in
                if let hex = HeaderLogoColor.hexString(from: color) {
                    headerLogoColorHex = hex
                }
            }
        )
    }

    private var identityInitialsBinding: Binding<String> {
        Binding(
            get: { identityInitials },
            set: { identityInitials = SessionIdentitySettings.normalizedInitials($0) }
        )
    }

    private var identityPreviewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: identityDisplayName,
            storedInitials: identityInitials,
            fallbackFullName: NSFullUserName()
        )
    }

    private var notificationStatusText: String? {
        notificationStatusMessage ?? notificationPermissionStatus.map(notificationPermissionLabel)
    }

    // True while the server is applying/restarting an update. The manual check
    // button is disabled then so a forced check can't race the recovery poll.
    private var isUpdateApplyInFlight: Bool {
        switch updateApplyPhase {
        case .applying, .recovering:
            return true
        case .idle, .blocked, .failed:
            return false
        }
    }

    // The manual "Check for updates" control (#308). Distinct from the passive
    // on-open check: it forces a live git fetch on the server. While a check is in
    // flight it swaps to a "Checking…" spinner; it's disabled during an apply so
    // the two update flows never run at once.
    @ViewBuilder
    private var serverUpdateCheckAction: some View {
        if isCheckingForUpdates {
            updateProgressRow(String(localized: "Checking for updates…"))
        } else {
            SettingsButton(String(localized: "Check for updates")) {
                Task {
                    await checkForUpdatesManually()
                }
            }
            .disabled(isUpdateApplyInFlight)
            .padding(.top, 4)
        }
    }

    private var forcedCheckAlertTitle: String {
        switch forcedCheckOutcome {
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
        switch forcedCheckOutcome {
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

    // Informational only — never a warning. A normal, up-to-date server shows a
    // calm "Up to date"; a server that genuinely lags shows how far behind it is.
    // When the check is disabled, errored, or hasn't loaded, we show nothing here
    // and let the plain version row stand on its own.
    @ViewBuilder
    private var serverUpdateNote: some View {
        if serverVersion != nil, let serverUpdateState {
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
        switch updateApplyPhase {
        case .idle:
            if serverVersion != nil, case .updateAvailable = serverUpdateState {
                updateActionButton(title: String(localized: "Update"))
            }
        case .applying:
            updateProgressRow(String(localized: "Starting update…"))
        case .recovering:
            updateProgressRow(String(localized: "Updating & restarting…"))
        case .blocked:
            VStack(alignment: .leading, spacing: 10) {
                updateMessageRow(systemImage: "clock", tint: .secondary)
                updateActionButton(title: String(localized: "Retry update"))
            }
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                updateMessageRow(systemImage: "exclamationmark.triangle", tint: .orange)
                updateActionButton(title: String(localized: "Retry update"))
            }
        }
    }

    private func updateActionButton(title: String) -> some View {
        SettingsButton(title) {
            isConfirmingUpdate = true
        }
        // Mirror of the check button's `isUpdateApplyInFlight` guard: while a
        // forced check is running, block Update/Retry so apply can't race the
        // in-flight POST /api/updates/check (#308 review).
        .disabled(isCheckingForUpdates)
        .padding(.top, 4)
    }

    private func updateProgressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()

            Text(text)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func updateMessageRow(systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(updateApplyMessage ?? String(localized: "The update could not be applied."))
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadServerSettings() async {
        guard !isLoadingServerSettings else {
            return
        }

        isLoadingServerSettings = true
        isLoadingDefaultModel = true
        isLoadingDefaultProfile = true
        serverSettingsError = nil
        serverUpdateState = nil
        let client = APIClient(baseURL: server)

        do {
            let settings = try await client.settings()
            serverVersion = settings.webuiVersion
            // Server wins on conflict: `show_cli_sessions` is the cross-device
            // truth, the local value is just its offline cache (#19).
            cliSessionsSync.adopt(serverValue: settings.showCliSessions)
            cliSessionsSync.adoptClaudeCode(serverValue: settings.showClaudeCodeSessions)
            if serverVersion == nil {
                serverSettingsError = String(localized: "Unknown")
            }
        } catch {
            authManager.handleAPIError(error)
            serverSettingsError = String(localized: "Unavailable")
        }

        isLoadingServerSettings = false

        do {
            let updates = try await client.updatesCheck()
            serverUpdateState = updates.webuiUpdateState
        } catch {
            // Non-fatal: update availability is optional info. On any failure we
            // degrade to showing the version only, with no indicator.
            serverUpdateState = nil
        }

        do {
            let catalog = try await client.models()
            defaultModel = catalog.defaultModel
        } catch {
            // Non-fatal: default model is optional info
            defaultModel = nil
        }

        isLoadingDefaultModel = false

        do {
            let profiles = try await client.profiles()
            defaultProfileName = profiles.effectiveDefaultProfileName
            defaultProfileDisplayName = profiles.displayName(for: defaultProfileName)
        } catch {
            // Non-fatal: default profile is optional info
            defaultProfileName = nil
            defaultProfileDisplayName = nil
        }

        isLoadingDefaultProfile = false
    }

    private func checkForUpdatesManually() async {
        // Ignore taps while a check is already running or an apply/restart is in
        // flight — both would race the shared `serverUpdateState`.
        guard !isCheckingForUpdates, !isUpdateApplyInFlight else {
            return
        }

        isCheckingForUpdates = true
        let client = APIClient(baseURL: server)

        do {
            let response = try await client.updatesCheckForced()
            // Refresh the passive inline indicator from the fresh result too, so a
            // forced check keeps the on-open note in sync (issue #308).
            serverUpdateState = response.webuiUpdateState
            forcedCheckOutcome = response.forcedCheckOutcome
        } catch {
            authManager.handleAPIError(error)
            forcedCheckOutcome = .error
        }

        isCheckingForUpdates = false
        isPresentingForcedCheckResult = true
    }

    private func applyServerUpdate() async {
        // Never start an apply while a forced check is in flight — the two race
        // the same server-side git state, and the check's completion would
        // overwrite update state / present its popup mid-apply. The inline
        // Update button is also disabled then; this guards the path regardless
        // (e.g. a tap that slips through the confirm dialog). The forced-check
        // popup's own Update is safe: `isCheckingForUpdates` is already false
        // before that popup presents (#308 review).
        guard !isCheckingForUpdates else { return }

        // Allow a fresh attempt only from a resting phase; ignore taps while a
        // request is in flight or the server is mid-restart.
        switch updateApplyPhase {
        case .idle, .blocked, .failed:
            break
        case .applying, .recovering:
            return
        }

        updateApplyPhase = .applying
        updateApplyMessage = nil
        let client = APIClient(baseURL: server)

        let response: UpdatesApplyResponse
        do {
            response = try await client.applyUpdate(target: "webui")
        } catch {
            // The apply call returns before the server restarts, so a failure
            // here is a real pre-restart error (auth, unreachable, decode).
            authManager.handleAPIError(error)
            updateApplyMessage = String(localized: "Could not reach the server to start the update.")
            updateApplyPhase = .failed
            return
        }

        switch response.outcome {
        case .applying:
            updateApplyPhase = .recovering
            await waitForServerToReturn(using: client, previousVersion: serverVersion)
        case .restartBlocked:
            updateApplyMessage = response.displayMessage(
                default: String(localized: "The server is busy with active work. Wait for it to finish, then retry.")
            )
            updateApplyPhase = .blocked
        case .failed:
            updateApplyMessage = response.displayMessage(
                default: String(localized: "The update could not be applied.")
            )
            updateApplyPhase = .failed
        }
    }

    /// Polls the self-restarting server until the restart is confirmed, then
    /// refreshes the version and indicator. Bounded so a slow/stuck restart
    /// never leaves a spinner up.
    ///
    /// Completion requires *proof the restart happened* — the reported version
    /// changed, or the check explicitly reports `.upToDate` — not merely a
    /// reachable server. That avoids finalising against the outgoing process or
    /// on a transient `stale_check` that still claims a non-zero `behind`, while
    /// still letting update-check-disabled servers converge via the new version.
    /// State is refreshed inline (not via the non-reentrant `loadServerSettings`)
    /// so a concurrent load can't make us flip to `.idle` without refreshing.
    private func waitForServerToReturn(using client: APIClient, previousVersion: String?) async {
        let maxAttempts = 30 // ~60s at a 2s cadence — generous for a self-restart.

        for _ in 0..<maxAttempts {
            guard !Task.isCancelled else { return }
            // Wait first: the server flushes the response, then restarts ~2s
            // later, so an immediate probe could hit the outgoing process.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            // One reachable settings call gives us both liveness and the fresh
            // version; a nil result means the restart outage hasn't cleared yet.
            guard let settings = try? await client.settings() else {
                continue
            }

            let newVersion = settings.webuiVersion
            let updateState = (try? await client.updatesCheck())?.webuiUpdateState ?? .unavailable
            let restartConfirmed = (newVersion != nil && newVersion != previousVersion)
                || updateState == .upToDate

            if restartConfirmed {
                serverVersion = newVersion
                serverSettingsError = newVersion == nil ? String(localized: "Unknown") : nil
                serverUpdateState = updateState
                updateApplyPhase = .idle
                updateApplyMessage = nil
                return
            }
        }

        // Didn't confirm the restart in the window. Refresh once so the indicator
        // reflects reality, then surface a distinct, retryable failure — never a
        // silent reset (the `.failed` UI stays visible regardless of the now
        // possibly-nil `serverUpdateState`).
        await loadServerSettings()
        if serverSettingsError != nil {
            updateApplyMessage = String(localized: "The server didn't come back after the update. Check the server, then retry.")
            updateApplyPhase = .failed
        } else if case .updateAvailable = serverUpdateState {
            updateApplyMessage = String(localized: "The update is taking longer than expected to finish. Try again in a moment.")
            updateApplyPhase = .failed
        } else {
            // Server is back and not reporting a pending update — treat as done.
            updateApplyPhase = .idle
            updateApplyMessage = nil
        }
    }

    private func clearOfflineCache() async {
        guard !isClearingCache else {
            return
        }

        isClearingCache = true
        do {
            // Scoped to the active server only, so clearing one server's cache
            // never wipes another configured server's offline data (#18).
            try CacheStore.clearCache(for: server, in: modelContext)
            cacheStatusMessage = String(localized: "This server's offline cache was cleared.")
        } catch {
            cacheStatusMessage = String(localized: "Could not clear offline cache.")
        }
        isClearingCache = false
    }

    private func refreshNotificationPermissionStatus() async {
        let status = await ResponseCompletionNotificationService.authorizationStatus()
        notificationPermissionStatus = status

        if !status.allowsSettingsToggleOn {
            isResponseCompletionNotificationsEnabled = false
        }

        notificationStatusMessage = nil
    }

    private func enableResponseCompletionNotifications() async {
        let currentStatus = await ResponseCompletionNotificationService.authorizationStatus()
        notificationPermissionStatus = currentStatus

        switch currentStatus {
        case .authorized, .provisional, .ephemeral:
            isResponseCompletionNotificationsEnabled = true
            notificationStatusMessage = nil
        case .notDetermined:
            guard !hasRequestedResponseCompletionNotificationPermission else {
                isResponseCompletionNotificationsEnabled = false
                notificationStatusMessage = String(localized: "Permission not requested.")
                return
            }

            hasRequestedResponseCompletionNotificationPermission = true
            let granted = await ResponseCompletionNotificationService.requestAuthorization()
            let updatedStatus = await ResponseCompletionNotificationService.authorizationStatus()
            notificationPermissionStatus = updatedStatus
            isResponseCompletionNotificationsEnabled = granted && updatedStatus.allowsSettingsToggleOn
            notificationStatusMessage = isResponseCompletionNotificationsEnabled ? nil : notificationPermissionLabel(updatedStatus)
        case .denied:
            isResponseCompletionNotificationsEnabled = false
            notificationStatusMessage = notificationPermissionLabel(currentStatus)
        @unknown default:
            isResponseCompletionNotificationsEnabled = false
            notificationStatusMessage = String(localized: "Notifications unavailable.")
        }
    }

    private func notificationPermissionLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return String(localized: "iOS notifications allowed.")
        case .notDetermined:
            return String(localized: "iOS permission not requested.")
        case .denied:
            return String(localized: "iOS notifications disabled.")
        @unknown default:
            return String(localized: "Notifications unavailable.")
        }
    }
}

/// Phases of the in-app "apply webui update" flow (issue #180).
private enum ServerUpdateApplyPhase: Equatable {
    /// No update in flight; show the "Update" button.
    case idle
    /// The apply request is in flight (before the server confirms a restart).
    case applying
    /// Server accepted the update and is restarting; we are polling for it.
    case recovering
    /// Restart was blocked by active chat/agent work; offer a retry.
    case blocked
    /// The update failed (conflict, diverged, unreachable, or timed-out restart).
    case failed
}

private extension UNAuthorizationStatus {
    var allowsSettingsToggleOn: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

private struct SessionIdentitySettingsEditor: View {
    @ScaledMetric(relativeTo: .caption) private var avatarPreviewSize: CGFloat = 36

    @Binding var displayName: String
    @Binding var initials: String
    let previewInitials: String
    let previewColor: Color
    let previewForeground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(previewInitials)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(previewForeground)
                    .frame(width: avatarPreviewSize, height: avatarPreviewSize)
                    .background(previewColor, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sessions Avatar")
                        .font(AppFont.subheadline(weight: .medium))

                    Text("Stored on this device only.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            SettingsTextFieldRow(title: String(localized: "Display Name"), text: $displayName, placeholder: NSFullUserName())

            SettingsDivider()

            SettingsTextFieldRow(title: String(localized: "Initials"), text: $initials, placeholder: previewInitials)
        }
    }
}

private struct SettingsTextFieldRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .words
    var isSecure = false
    var submitLabel: SubmitLabel = .return
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    titleLabel
                    textField
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    titleLabel

                    Spacer(minLength: 12)

                    textField
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 190)
                }
            }
        }
    }

    private var titleLabel: some View {
        Text(title)
            .font(AppFont.subheadline())
    }

    @ViewBuilder
    private var textField: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(AppFont.subheadline())
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled()
        .keyboardType(keyboardType)
        .submitLabel(submitLabel)
        .onSubmit { onSubmit?() }
    }
}

private struct HeaderLogoColorSettings: View {
    @Binding var selectedHex: String
    let customColor: Binding<Color>

    private var selectedColorName: String {
        HeaderLogoColor.displayName(for: selectedHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Header Logo Color")
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(selectedColorName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            HermesHeaderLogo(selectedColor: HeaderLogoColor.color(for: selectedHex))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                ForEach(HeaderLogoColor.presets) { preset in
                    HeaderLogoColorPresetButton(
                        preset: preset,
                        isSelected: HeaderLogoColor.normalizedHex(selectedHex) == preset.hex
                    ) {
                        selectedHex = preset.hex
                    }
                }
            }

            ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                .font(.subheadline)
        }
    }
}

private struct HeaderLogoColorPresetButton: View {
    let preset: HeaderLogoColorPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(preset.color)
                    .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(preset.hex == "#FFFFFF" ? .black : .white)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 34, height: 34)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(preset.name) header logo color"))
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Updates the Sessions header logo color.")
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .body) private var contentSpacing: CGFloat = 12

    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textCase(.uppercase)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: contentSpacing) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color(.secondarySystemBackground).opacity(cardFillOpacity))
            }
            .adaptiveGlass(
                .regular,
                fallbackMaterial: .regularMaterial,
                in: shape
            )
            .overlay {
                shape
                    .stroke(Color.primary.opacity(cardStrokeOpacity), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
    }

    private var cardFillOpacity: Double {
        reduceTransparency ? 1 : 0.34
    }

    private var cardStrokeOpacity: Double {
        colorSchemeContrast == .increased ? 0.16 : 0.06
    }
}

private struct SettingsPickerRow<SelectionValue: Hashable, Options: View>: View {
    let title: String
    let systemImage: String
    @Binding var selection: SelectionValue
    @ViewBuilder let options: Options

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: String,
        systemImage: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self.systemImage = systemImage
        _selection = selection
        self.options = options()
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRowLabel(title: title, systemImage: systemImage)
                        .accessibilityHidden(true)

                    picker
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    SettingsRowLabel(title: title, systemImage: systemImage)
                        .accessibilityHidden(true)

                    Spacer(minLength: 12)

                    picker
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            options
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(Text(title))
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A footnote for inline failures (e.g. the CLI-sessions server write): same
/// footprint as `SettingsFootnote`, plus a warning icon so it reads as an error.
private struct SettingsErrorFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppFont.caption())
                .foregroundStyle(.orange)

            Text(text)
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsValueRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    titleText

                    trailing
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    titleText

                    Spacer(minLength: 16)

                    trailing
                }
            }
        }
        .font(AppFont.subheadline())
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var titleText: some View {
        Text(title)
            .foregroundStyle(.primary)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String
    var valueIsSelectable = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SettingsValueRow(title: title) {
            if valueIsSelectable {
                valueText
                    .textSelection(.enabled)
            } else {
                valueText
            }
        }
    }

    private var valueText: some View {
        Text(value)
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }
}

private struct SettingsAccessoryRow: View {
    let title: String
    var value: String?
    let systemImage: String
    var accessorySystemImage = "chevron.forward"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize, let value {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        leadingLabel
                        Spacer(minLength: 8)
                        accessoryIcon
                    }

                    Text(value)
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 34)
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    leadingLabel

                    Spacer(minLength: 8)

                    if let value {
                        Text(value)
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.trailing)
                    }

                    accessoryIcon
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var leadingLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(AppFont.subheadline(weight: .medium))
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessoryIcon: some View {
        Image(systemName: accessorySystemImage)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
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

private struct SettingsToggleRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowLabel(title: title, systemImage: systemImage)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

private struct SettingsButton: View {
    let title: String
    var role: ButtonRole?
    var isLoading = false
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(_ title: String, role: ButtonRole? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        Button(role: role, action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(role == .destructive ? .red : .primary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background {
                shape.fill((role == .destructive ? Color.red : Color.primary).opacity(0.08))
            }
            .adaptiveGlass(
                .regular,
                isInteractive: true,
                tint: role == .destructive ? .red.opacity(0.08) : nil,
                fallbackMaterial: .thinMaterial,
                in: shape
            )
            .overlay {
                shape
                    .stroke((role == .destructive ? Color.red : Color.primary).opacity(strokeOpacity), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var strokeOpacity: Double {
        colorSchemeContrast == .increased ? 0.24 : 0.12
    }
}

private struct SettingsStatusPill: View {
    let label: String
    var tint: Color = .secondary

    var body: some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 2)
            .opacity(0.72)
    }
}

// MARK: - Multi-server (#17)

/// Small circular avatar (initials + per-server Header Logo Color) for server rows.
private struct ServerAvatarBadge: View {
    let initials: String
    let colorHex: String
    var size: CGFloat = 32

    var body: some View {
        Text(initials)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(HeaderLogoColor.prefersDarkForeground(for: colorHex) ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(HeaderLogoColor.color(for: colorHex), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// One row in the Settings "Servers" list: avatar, name, URL, and an active marker.
private struct SettingsServerRow: View {
    let account: ServerAccount
    let isActive: Bool

    private var hostFallback: String {
        URL(string: account.urlString)?.host ?? account.urlString
    }

    private var name: String {
        account.displayName.isEmpty ? hostFallback : account.displayName
    }

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: account.displayName,
            storedInitials: account.initials,
            fallbackFullName: hostFallback
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            ServerAvatarBadge(initials: previewInitials, colorHex: account.headerLogoColorHex)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(AppFont.subheadline(weight: .medium))
                    .lineLimit(1)

                Text(account.urlString)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isActive {
                SettingsStatusPill(label: String(localized: "Active"))
            }

            Image(systemName: "chevron.forward")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? String(localized: "\(name), \(account.urlString), active server") : String(localized: "\(name), \(account.urlString)"))
        .accessibilityHint("Opens server details to switch, edit, or remove.")
    }
}

/// Reusable per-server identity editor (display name, initials, Header Logo Color),
/// used by the add-server flow and the server detail screen (#17).
private struct ServerIdentityEditor: View {
    @Binding var displayName: String
    @Binding var initials: String
    @Binding var colorHex: String
    /// Host-derived fallback used for the avatar preview when fields are empty.
    let fallbackName: String

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: displayName.isEmpty ? fallbackName : displayName,
            storedInitials: initials,
            fallbackFullName: fallbackName
        )
    }

    private var initialsBinding: Binding<String> {
        Binding(
            get: { initials },
            set: { initials = SessionIdentitySettings.normalizedInitials($0) }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { HeaderLogoColor.color(for: colorHex) },
            set: { if let hex = HeaderLogoColor.hexString(from: $0) { colorHex = hex } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ServerAvatarBadge(initials: previewInitials, colorHex: colorHex, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Server Avatar")
                        .font(AppFont.subheadline(weight: .medium))

                    Text("Stored on this device only.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            SettingsTextFieldRow(
                title: String(localized: "Display Name"),
                text: $displayName,
                placeholder: fallbackName.isEmpty ? String(localized: "Server") : fallbackName
            )

            SettingsDivider()

            SettingsTextFieldRow(title: String(localized: "Initials"), text: initialsBinding, placeholder: previewInitials)

            SettingsDivider()

            HeaderLogoColorSettings(selectedHex: $colorHex, customColor: colorBinding)
        }
    }
}

/// Per-server detail: identity editing, switch-to-active, and remove/sign-out (#17).
private struct ServerDetailView: View {
    @Bindable var authManager: AuthManager
    let account: ServerAccount

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var displayName: String
    @State private var initials: String
    @State private var colorHex: String
    @State private var isConfirmingRemove = false
    @State private var isRemoving = false

    init(authManager: AuthManager, account: ServerAccount) {
        self.authManager = authManager
        self.account = account
        _displayName = State(initialValue: account.displayName)
        _initials = State(initialValue: account.initials)
        _colorHex = State(initialValue: account.headerLogoColorHex)
    }

    private var isActive: Bool { account.id == authManager.activeServerID }
    private var hasOtherServers: Bool { authManager.servers.count > 1 }
    private var hostFallback: String { URL(string: account.urlString)?.host ?? account.urlString }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsCard(title: String(localized: "Server")) {
                    SettingsInfoRow(title: String(localized: "URL"), value: account.urlString, valueIsSelectable: true)

                    SettingsDivider()

                    SettingsValueRow(title: String(localized: "Status")) {
                        SettingsStatusPill(label: isActive ? String(localized: "Active") : String(localized: "Inactive"))
                    }
                }

                SettingsCard(title: String(localized: "Identity")) {
                    ServerIdentityEditor(
                        displayName: $displayName,
                        initials: $initials,
                        colorHex: $colorHex,
                        fallbackName: hostFallback
                    )
                }

                if !isActive {
                    SettingsCard(title: String(localized: "Active Server")) {
                        SettingsFootnote(String(localized: "Makes this the active server. Sessions, chats, and settings reload for it."))

                        SettingsButton(String(localized: "Switch to This Server")) {
                            authManager.switchActiveServer(to: account)
                        }
                    }
                }

                SettingsCard(title: isActive ? String(localized: "Account") : String(localized: "Remove Server")) {
                    SettingsFootnote(removeFootnote)

                    SettingsButton(removeButtonTitle, role: .destructive, isLoading: isRemoving) {
                        isConfirmingRemove = true
                    }
                    .disabled(isRemoving)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .background(Color(.systemBackground))
        .navigationTitle(displayName.isEmpty ? hostFallback : displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Persist identity edits to this server's registry entry. When it's the
        // active server, the registry mirrors them into the global @AppStorage so
        // the avatar / header tint update live (#17).
        .onChange(of: displayName) { persistIdentity() }
        .onChange(of: initials) { persistIdentity() }
        .onChange(of: colorHex) { persistIdentity() }
        .alert(removeAlertTitle, isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button(removeButtonTitle, role: .destructive) {
                Task {
                    let wasActive = isActive
                    isRemoving = true
                    // Purge this server's offline cache *before* removing it, while
                    // the view (and its modelContext) is still alive — removing the
                    // active server flips auth state and tears this stack down on
                    // its own. Best-effort: the cache is server-keyed, so a leftover
                    // row can never surface as another server's content (#18, PR
                    // #286 W2).
                    if let removedServerURL = URL(string: account.urlString) {
                        try? CacheStore.clearCache(for: removedServerURL, in: modelContext)
                    }
                    await authManager.removeServer(account)
                    // Only a non-active removal leaves this view alive to reset its
                    // state and pop; the active-server case is already torn down.
                    if !wasActive {
                        isRemoving = false
                        dismiss()
                    }
                }
            }
        } message: {
            Text(removeAlertMessage)
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

    private var removeButtonTitle: String {
        isActive ? String(localized: "Sign Out of This Server") : String(localized: "Remove Server")
    }

    private var removeAlertTitle: String {
        isActive ? String(localized: "Sign out of this server?") : String(localized: "Remove this server?")
    }

    private var removeFootnote: String {
        if isActive {
            return hasOtherServers
                ? String(localized: "Signs out and switches to another configured server.")
                : String(localized: "Signs out and returns to onboarding.")
        }
        return String(localized: "Removes this server and its saved settings on this device. Your active server is unaffected.")
    }

    private var removeAlertMessage: String {
        if isActive {
            return hasOtherServers
                ? String(localized: "You'll switch to another configured server. Sign in again to use this one.")
                : String(localized: "You'll return to onboarding and need the server URL and password to sign back in.")
        }
        return String(localized: "This removes the server and its saved settings on this device. Your active server is unaffected.")
    }
}

/// Secondary onboarding/auth flow to add another server, collecting URL/password
/// (existing validation + login), custom headers, and per-server identity. Routes
/// through `AuthManager.addServer`, which never disturbs the active server on
/// failure (#17). Presented from Settings and from the session-list avatar
/// long-press switcher (#283).
struct AddServerView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var serverURLString = ""
    @State private var password = ""
    @State private var customHeaders: [CustomHeader] = []
    @State private var needsPassword = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var displayName = ""
    @State private var initials = ""
    @State private var colorHex = HeaderLogoColor.defaultHex

    private var trimmedURL: String {
        serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool { !trimmedURL.isEmpty && !isWorking }

    private var derivedHost: String {
        (try? AuthManager.normalizedServerURL(from: serverURLString))?.host ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SettingsCard(title: String(localized: "Server")) {
                        SettingsTextFieldRow(
                            title: String(localized: "URL"),
                            text: $serverURLString,
                            placeholder: "100.64.0.1:8787",
                            keyboardType: .URL,
                            autocapitalization: .never,
                            submitLabel: .go,
                            onSubmit: { Task { await submit() } }
                        )

                        if needsPassword {
                            SettingsDivider()

                            SettingsTextFieldRow(
                                title: String(localized: "Password"),
                                text: $password,
                                placeholder: String(localized: "Server password"),
                                autocapitalization: .never,
                                isSecure: true,
                                submitLabel: .go,
                                onSubmit: { Task { await submit() } }
                            )
                        }
                    }

                    SettingsCard(title: String(localized: "Connection Headers")) {
                        CustomHeadersEditor(headers: $customHeaders)
                    }

                    SettingsCard(title: String(localized: "Identity")) {
                        ServerIdentityEditor(
                            displayName: $displayName,
                            initials: $initials,
                            colorHex: $colorHex,
                            fallbackName: derivedHost
                        )
                    }

                    statusBanner
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if isWorking {
            SettingsFootnote(String(localized: "Checking server…"))
        } else if needsPassword, errorMessage == nil {
            SettingsFootnote(String(localized: "This server requires a password."))
        }

        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        errorMessage = nil
        isWorking = true
        let outcome = await authManager.addServer(
            serverURLString: serverURLString,
            password: password,
            customHeaders: customHeaders
        )
        isWorking = false

        switch outcome {
        case .needsPassword:
            needsPassword = true
        case .failed:
            errorMessage = authManager.lastErrorMessage
        case let .added(url):
            applyIdentity(to: url)
            dismiss()
        }
    }

    /// Overrides the new server's seeded identity (the registry seeds it from the
    /// previous active server's global defaults) with the add-flow's chosen values.
    private func applyIdentity(to url: URL) {
        guard let account = authManager.servers.first(where: { $0.id == url.absoluteString }) else { return }

        let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (url.host ?? account.displayName)
            : displayName
        let finalInitials = SessionIdentitySettings.displayInitials(
            displayName: finalName,
            storedInitials: initials,
            fallbackFullName: url.host ?? finalName
        )
        authManager.updateServerIdentity(
            account,
            displayName: finalName,
            initials: finalInitials,
            headerLogoColorHex: colorHex
        )
    }
}

#Preview {
    NavigationStack {
        SettingsView(authManager: AuthManager(), server: URL(staticString: "https://webui.example.test"))
    }
}
