import SwiftUI

/// Settings → Notifications (#1252): push for this server and device first, then the
/// sections the caller supplies for alerts that apply on this iPhone to every server.
@MainActor struct HermexPushSettingsPage<SharedSections: View>: View {
    let server: URL
    @Environment(\.scenePhase) private var scenePhase
    @State private var provisioner: HermexPushProvisioner
    @State private var isConfirmingEnable = false
    @State private var isConfirmingDisable = false
    @State private var isConfirmingUpdate = false
    @State private var isConfirmingRestart = false
    @State private var preferenceTask: Task<Void, Never>?
    private let sharedSections: SharedSections

    init(server: URL, @ViewBuilder sharedSections: () -> SharedSections) {
        self.server = server
        self.sharedSections = sharedSections()
        _provisioner = State(initialValue: HermexPushProvisioner(
            server: server, connection: try? BotConnectionStore().load(server: server)))
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        List { sharedSections }
            .settingsPage(String(localized: "Notifications"))
        #else
        List {
            Section {
                pushSettings
            } header: {
                Text("Push · Current server")
            }

            sharedSections
        }
        .settingsPage(String(localized: "Notifications"))
        .transaction { $0.animation = nil }
        .task {
            await provisioner.reload()
            await provisioner.checkPlugin()
        }
        // Runs on appear and on every return to the app, so allowing notifications in
        // iOS Settings clears the notice without re-running setup.
        .task(id: scenePhase) {
            if scenePhase == .active { await provisioner.recheckNotificationPermission() }
        }
        .onDisappear {
            preferenceTask?.cancel()
            preferenceTask = nil
            provisioner.leaveSettings()
        }
        .confirmationDialog("Set this Hermes host up for push?", isPresented: $isConfirmingEnable, titleVisibility: .visible) {
            // Provisioning changes the host, so the existing owner finishes that
            // transaction even if Settings closes before it returns.
            Button("Set up push") { Task { await provisioner.enable() } }
        } message: {
            Text("If this host is not set up yet, Hermex installs the hermex-push plugin on it and restarts its gateway, interrupting work running there. A host that is already set up is only paired. Nothing happens until you tap this.")
        }
        .confirmationDialog("Turn off notifications for this server?", isPresented: $isConfirmingDisable, titleVisibility: .visible) {
            Button("Turn off notifications", role: .destructive) { Task { await provisioner.disable() } }
        } message: {
            Text(provisioner.sharesHostPairing
                 ? String(localized: "Another entry for this Hermes host still gets its notifications, so the plugin and the relay stay as they are. Only the keys stored on this iPhone for this server are deleted.")
                 : String(localized: "This iPhone is removed from the relay, the plugin is disabled on your Hermes host, and the keys stored on this iPhone are deleted."))
        }
        .confirmationDialog("Update the hermex-push plugin?", isPresented: $isConfirmingUpdate, titleVisibility: .visible) {
            // Like setup, the run outlives the screen: the host has already been asked to change.
            Button("Update plugin") { Task { await provisioner.updatePlugin() } }
        } message: {
            // An update offered by a pairing failure has no pairing to keep.
            Text(provisioner.pairing == nil
                 ? String(localized: "Your Hermes host downloads hermex-push again from GitHub and restarts its gateway, interrupting work running there. To finish, you’ll likely need to restart Hermes on the host yourself.")
                 : String(localized: "Your Hermes host downloads hermex-push again from GitHub and restarts its gateway, interrupting work running there. This iPhone stays paired. To finish, you’ll likely need to restart Hermes on the host yourself."))
        }
        .confirmationDialog("Restart Hermes?", isPresented: $isConfirmingRestart, titleVisibility: .visible) {
            // Like the update, the run outlives the screen: the host has already been asked to restart.
            Button("Restart", role: .destructive) { Task { await provisioner.restartHermes() } }
        } message: {
            Text("Bot turns running on this host stop. Hermex reconnects when Hermes is back.")
        }
        #endif
    }

    @ViewBuilder private var pushSettings: some View {
        if let card = provisioner.pluginCard { pluginCallout(card) }
        if let pairing = provisioner.pairing {
            if pairing.preferencesNeedSync == true {
                Text("Not synced with the relay yet.")
                    .font(AppFont.caption()).foregroundStyle(.secondary)
                Button("Try again.") {
                    preferenceTask = Task { await provisioner.updatePreferences(pairing.effectivePreferences) }
                }
                .disabled(provisioner.isWorking)
                .frame(minHeight: 44)
            } else {
                preferenceToggle(String(localized: "Reply Notifications"), keyPath: \.replies)
                preferenceToggle(String(localized: "Subagent Notifications"), keyPath: \.muteSubagents, inverted: true)
                preferenceToggle(String(localized: "Show Previews"), keyPath: \.previews)
                preferenceToggle(String(localized: "Quiet the Open Chat"), keyPath: \.presenceSuppression)
                Text("Previews include message text.")
                    .font(AppFont.caption()).foregroundStyle(.secondary)
            }
            if provisioner.phase == .savingPreferences {
                Text("Saving…").font(AppFont.caption()).foregroundStyle(.secondary)
            }
            testNotificationRows(pairing)
            LabeledContent(String(localized: "Relay"), value: pairing.relayURL.host ?? pairing.relayURL.absoluteString)
                .font(AppFont.subheadline())
            Button(provisioner.phase == .disabling ? String(localized: "Turning off…") : String(localized: "Turn off notifications…"),
                   role: .destructive) { isConfirmingDisable = true }
                .disabled(provisioner.isWorking)
                .frame(minHeight: 44)
            if provisioner.notificationsOff {
                notificationsOffRow(title: nil, message: String(localized: "Notifications are off for Hermex in iOS Settings."))
            }
        } else if provisioner.connection != nil {
            Button(provisioner.isWorking ? String(localized: "Setting up…") : String(localized: "Turn on notifications…")) {
                isConfirmingEnable = true
            }
            .disabled(provisioner.isWorking)
            .frame(minHeight: 44)
            if provisioner.notificationsOff {
                notificationsOffRow(title: String(localized: "Notifications are off for Hermex"),
                                    message: String(localized: "Allow them in iOS Settings, then try again."))
            }
            if provisioner.showsSteps {
                ForEach(HermexPushProvisioner.Step.allCases) { step in stepRow(step) }
            }
            Text("The relay only ever sees encrypted text.")
                .font(AppFont.caption()).foregroundStyle(.secondary)
        }
        // Also available after pairing, so an expired sign-in can be repaired
        // without searching through the server's detail screen.
        NavigationLink(provisioner.connection == nil ? String(localized: "Connect Hermes…") : String(localized: "Hermes connection")) {
            BotConnectionView(server: server)
        }
        .disabled(provisioner.isWorking)
        if let failure = provisioner.failure {
            switch failure.remedy {
            case .none: failureRow(failure)
            case .updatePlugin: failureCallout(failure, action: String(localized: "Update plugin…"))
            case .retryUpdate, .retryRestart: EmptyView() // The plugin card at the top shows it.
            }
        }
    }

    private func preferenceToggle(_ title: String, keyPath: WritableKeyPath<PushPreferences, Bool>, inverted: Bool = false) -> some View {
        Toggle(title, isOn: Binding(
            get: { (provisioner.pairing?.effectivePreferences[keyPath: keyPath] ?? true) != inverted },
            set: { value in
                guard let pairing = provisioner.pairing, !provisioner.isWorking else { return }
                var preferences = pairing.effectivePreferences
                preferences[keyPath: keyPath] = value != inverted
                preferenceTask = Task { await provisioner.updatePreferences(preferences) }
            }
        ))
        .font(AppFont.subheadline(weight: .medium))
        .toggleStyle(.switch)
        .disabled(provisioner.isWorking)
        .frame(minHeight: 44)
    }

    /// Settings' end-to-end push check (#874). No spinner: the label says "Sending…" while
    /// the one request runs. A failure shows in the red row at the bottom of the section.
    @ViewBuilder private func testNotificationRows(_ pairing: PushPairing) -> some View {
        Button(provisioner.phase == .sendingTest ? String(localized: "Sending…") : String(localized: "Send Test Notification")) {
            Task { await provisioner.sendTestNotification() }
        }
        .disabled(!provisioner.canSendTest)
        .frame(minHeight: 44)
        Text("Reaches every paired iPhone; doesn’t test your host.")
            .font(AppFont.caption()).foregroundStyle(.secondary)
        if !pairing.effectivePreferences.replies {
            Text("Turn on Reply Notifications to send a test.")
                .font(AppFont.caption()).foregroundStyle(.secondary)
        } else if provisioner.testDelivered {
            Label {
                Text("Sent. It should arrive in a few seconds.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(AppFont.caption())
        }
    }

    /// Progress without motion: a finished step is checked, the running one is named, and
    /// the rest stay quiet. No spinner, so a slow host never repaints the screen.
    private func stepRow(_ step: HermexPushProvisioner.Step) -> some View {
        let isDone = provisioner.completed.contains(step)
        let isRunning = provisioner.isRunning(step)
        return HStack(spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : (isRunning ? "circle.dashed" : "circle"))
                .foregroundStyle(isDone ? Color.green : .secondary)
            Text(step.title).fontWeight(isRunning ? .semibold : .regular)
        }
        .font(.footnote)
        .foregroundStyle(isDone || isRunning ? Color.primary : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isDone ? String(localized: "\(step.title): done")
                                 : (isRunning ? String(localized: "\(step.title): working")
                                    : String(localized: "\(step.title): waiting"))))
    }

    /// Denied iOS permission, kept apart from the red step failure because no host step
    /// ran. The whole row opens Hermex's notification page in iOS Settings.
    @ViewBuilder private func notificationsOffRow(title: String?, message: String) -> some View {
        if let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString) {
            Link(destination: settingsURL) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "bell.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).fontWeight(.semibold).foregroundStyle(Color.primary) }
                        Text(message).foregroundStyle(.secondary)
                        Text("Open Settings").foregroundStyle(.tint).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .font(AppFont.footnote())
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    /// The plugin update (#851) and the restart that finishes it (#934) as design C's card at
    /// the top of the section: one card for every state, in the notifications-off row's style.
    /// No spinner: a dashed circle and the running step's name carry progress.
    @ViewBuilder private func pluginCallout(_ card: HermexPushProvisioner.PluginCard) -> some View {
        let newest = HermexPushPlugin.newestVersion.description
        switch card {
        case .status(.available(let loaded)):
            callout("arrow.up.circle.fill", tint: .blue, title: Text("Plugin update available"),
                    message: loaded.map { Text("Your Hermes host has hermex-push \($0.description) loaded. The newest is \(newest).") }
                        ?? Text("Your Hermes host has an older hermex-push. The newest is \(newest)."),
                    action: String(localized: "Update plugin…")) { isConfirmingUpdate = true }
        case .updating(let step):
            callout("circle.dashed", tint: .secondary, title: Text("Updating the plugin…"), message: Text(step.progress))
        case .status(.restartNeeded(let loaded)) where HermexPushPlugin.canRestart(loaded):
            // The loaded plugin has the restart route, so restarting is the card's one action.
            callout("arrow.clockwise.circle.fill", tint: .orange, title: Text("Restart Hermes to finish"),
                    message: Text("Hermes loads the new plugin when it restarts."),
                    action: String(localized: "Restart Hermes…")) { isConfirmingRestart = true }
        case .status(.restartNeeded), .status(.setupNeedsRestart):
            callout("arrow.clockwise.circle.fill", tint: .orange, title: Text("Restart Hermes to finish"),
                    message: Text("Restart `hermes dashboard` on your host, then check again."),
                    action: provisioner.phase == .checkingPlugin ? String(localized: "Checking…") : String(localized: "Check again")) {
                Task { await provisioner.checkPluginAgain() }
            }
        case .restarting:
            callout("circle.dashed", tint: .secondary, title: Text("Restarting Hermes…"),
                    message: Text("Waiting for Hermes to come back"))
        case .status(.restartTimedOut):
            callout("exclamationmark.triangle.fill", tint: .red, title: Text("Hermes didn’t come back"),
                    message: Text("If it stopped, start `hermes dashboard` on your host."),
                    action: provisioner.phase == .checkingPlugin ? String(localized: "Checking…") : String(localized: "Check again")) {
                Task { await provisioner.checkPluginAgain() }
            }
        case .status(.upToDate(let version)):
            callout("checkmark.circle.fill", tint: .green, title: Text("Plugin up to date"),
                    message: Text("hermex-push \(version.description) is loaded on your host."))
        case .status(.checkFailed(let failure)):
            callout("exclamationmark.triangle.fill", tint: .red, title: Text(failure.title), message: Text(failure.message),
                    action: provisioner.phase == .checkingPlugin ? String(localized: "Checking…") : String(localized: "Check again")) {
                Task { await provisioner.checkPluginAgain() }
            }
        case .failed(let failure):
            failureCallout(failure, action: String(localized: "Try again"))
        }
    }

    /// A failure the plugin update answers (the update's own, or keys an old plugin sent) or
    /// a restart that never ran. The action asks for that step's confirmation again before
    /// the host changes.
    private func failureCallout(_ failure: HermexPushProvisioner.Failure, action: String) -> some View {
        callout("exclamationmark.triangle.fill", tint: .red, title: Text(failure.title), message: Text(failure.message),
                action: action) {
            if failure.remedy == .retryRestart { isConfirmingRestart = true } else { isConfirmingUpdate = true }
        }
    }

    /// The card itself. With an action, the whole card is the button, so it stays a
    /// full-width target at every Dynamic Type size.
    @ViewBuilder private func callout(_ symbol: String, tint: Color, title: Text, message: Text,
                                      action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        let card = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.fontWeight(.semibold).foregroundStyle(Color.primary)
                message.foregroundStyle(.secondary)
                if let action { Text(action).foregroundStyle(.tint).padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .font(AppFont.footnote())
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        if action != nil {
            Button(action: perform) { card }
                .buttonStyle(.plain)
                .disabled(provisioner.isWorking)
        } else {
            card.accessibilityElement(children: .combine)
        }
    }

    private func failureRow(_ failure: HermexPushProvisioner.Failure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(failure.title).font(.footnote.weight(.semibold))
            Text(failure.message).font(.footnote)
        }
        .foregroundStyle(.red)
        .accessibilityElement(children: .combine)
    }
}
