import SwiftUI

/// The single notification home under Settings → Interaction. Push choices belong
/// to this server and device; the caller supplies the existing global alert controls.
@MainActor struct HermexPushSectionView<SharedSettings: View>: View {
    let server: URL
    @Environment(\.scenePhase) private var scenePhase
    @State private var provisioner: HermexPushProvisioner
    @State private var isExpanded = false
    @State private var isConfirmingEnable = false
    @State private var isConfirmingDisable = false
    @State private var isConfirmingUpdate = false
    @State private var preferenceTask: Task<Void, Never>?
    private let sharedSettings: SharedSettings

    /// `startsExpanded` opens the section for the chat's one-time notification offer (#863).
    init(server: URL, startsExpanded: Bool = false, @ViewBuilder sharedSettings: () -> SharedSettings) {
        self.server = server
        self.sharedSettings = sharedSettings()
        _isExpanded = State(initialValue: startsExpanded)
        _provisioner = State(initialValue: HermexPushProvisioner(
            server: server, connection: try? BotConnectionStore().load(server: server)))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Push · Current server")
                    .font(AppFont.caption()).foregroundStyle(.secondary)
                pushSettings
                Divider()
                Text("On this iPhone · All servers")
                    .font(AppFont.caption()).foregroundStyle(.secondary)
                sharedSettings
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell").foregroundStyle(Color.secondary)
                    .frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notifications").font(AppFont.subheadline(weight: .medium))
                    Text(provisioner.pairing == nil
                         ? String(localized: "Push off · Current server")
                         : String(localized: "Push on · Current server"))
                        .font(AppFont.caption()).foregroundStyle(Color.secondary)
                    if let card = provisioner.pluginCard { pluginLine(card) }
                }
            }
            .foregroundStyle(Color.primary)
            .frame(minHeight: 44)
        }
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
            Text("This iPhone is removed from the relay, the plugin is disabled on your Hermes host, and the keys stored on this iPhone are deleted.")
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
    }

    @ViewBuilder private var pushSettings: some View {
        if let card = provisioner.pluginCard { pluginCallout(card) }
        if let pairing = provisioner.pairing {
            if pairing.preferencesNeedSync == true {
                Text("Preferences aren’t confirmed. Try again to sync this iPhone with the relay.")
                    .font(AppFont.caption()).foregroundStyle(.secondary)
                Button("Try again.") {
                    preferenceTask = Task { await provisioner.updatePreferences(pairing.effectivePreferences) }
                }
                .disabled(provisioner.isWorking)
                .frame(minHeight: 44)
            } else {
                preferenceToggle(String(localized: "Reply Notifications"), keyPath: \.replies)
                Divider()
                preferenceToggle(String(localized: "Subagent Notifications"), keyPath: \.muteSubagents, inverted: true)
                Divider()
                preferenceToggle(String(localized: "Show Previews"), keyPath: \.previews)
                Divider()
                preferenceToggle(String(localized: "Quiet the Open Chat"), keyPath: \.presenceSuppression)
                Text("For this iPhone and the selected server. Quiet the Open Chat hides banners for the chat on screen, except approvals, questions and errors. Previews include message text; your iPhone’s notification settings still apply.")
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
                notificationsOffRow(title: nil, message: String(localized: "Notifications are off for Hermex, so this server’s notifications can’t show on this iPhone."))
            }
        } else if provisioner.connection != nil {
            Button(provisioner.isWorking ? String(localized: "Setting up…") : String(localized: "Turn on notifications…")) {
                isConfirmingEnable = true
            }
            .disabled(provisioner.isWorking)
            .frame(minHeight: 44)
            if provisioner.notificationsOff {
                notificationsOffRow(title: String(localized: "Notifications are off for Hermex"),
                                    message: String(localized: "Allow notifications for Hermex in iOS Settings, then turn this on again."))
            }
            if provisioner.showsSteps {
                ForEach(HermexPushProvisioner.Step.allCases) { step in stepRow(step) }
            }
            Text("Hermex sets this Hermes host up for push and pairs this iPhone with its relay. Your host encrypts every notification’s text: the relay only ever sees ciphertext.")
                .font(AppFont.caption()).foregroundStyle(.secondary)
        }
        // Also available after pairing, so an expired sign-in can be repaired
        // without searching through the server's detail screen.
        NavigationLink {
            BotConnectionView(server: server)
        } label: {
            HStack {
                Text(provisioner.connection == nil ? String(localized: "Connect Hermes…") : String(localized: "Hermes connection"))
                Spacer()
                Image(systemName: "chevron.forward")
                    .foregroundStyle(Color.secondary).accessibilityHidden(true)
            }
            .font(AppFont.subheadline()).frame(minHeight: 44)
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(provisioner.isWorking)
        if let failure = provisioner.failure {
            switch failure.remedy {
            case .none: failureRow(failure)
            case .updatePlugin: failureCallout(failure, action: String(localized: "Update plugin…"))
            case .retryUpdate: EmptyView() // The plugin card at the top shows it.
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
        Text("Sends one test through the relay to every iPhone paired with this Hermes host. It checks the relay, Apple and this iPhone, not your host’s connection to the relay.")
            .font(AppFont.caption()).foregroundStyle(.secondary)
        if !pairing.effectivePreferences.replies {
            Text("Turn on Reply Notifications to send a test.")
                .font(AppFont.caption()).foregroundStyle(.secondary)
        } else if provisioner.testDelivered {
            Label {
                Text("Sent. Apple accepted the test; it should arrive in a few seconds.")
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

    /// The plugin update (#851) as design C's card at the top of the section: one card for
    /// every state, in the notifications-off row's style. No spinner: a dashed circle and
    /// the running step's name carry progress.
    @ViewBuilder private func pluginCallout(_ card: HermexPushProvisioner.PluginCard) -> some View {
        let newest = HermexPushPlugin.newestVersion.description
        switch card {
        case .status(.available(let loaded)):
            callout("arrow.up.circle.fill", tint: .blue, title: Text("Plugin update available"),
                    message: loaded.map { Text("Your Hermes host has hermex-push \($0.description) loaded. The newest is \(newest).") }
                        ?? Text("Your Hermes host has an older hermex-push loaded. The newest is \(newest)."),
                    action: String(localized: "Update plugin…")) { isConfirmingUpdate = true }
        case .updating(let step):
            callout("circle.dashed", tint: .secondary, title: Text("Updating the plugin…"), message: Text(step.progress))
        case .status(.restartNeeded):
            callout("arrow.clockwise.circle.fill", tint: .orange, title: Text("Restart Hermes to finish"),
                    message: Text("The new plugin is installed, but Hermes loads plugins only when it starts. Restart `hermes dashboard` on your host, then check again. Hermex can’t restart it from this iPhone."),
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

    /// A failure the plugin update answers: the update's own, or keys an old plugin sent.
    /// Either way the action asks for the same confirmation before the host changes.
    private func failureCallout(_ failure: HermexPushProvisioner.Failure, action: String) -> some View {
        callout("exclamationmark.triangle.fill", tint: .red, title: Text(failure.title), message: Text(failure.message),
                action: action) { isConfirmingUpdate = true }
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

    /// The collapsed label's second line: the card's state in a few words, so every card that
    /// asks for an action shows without opening the section. "Up to date" needs no line.
    @ViewBuilder private func pluginLine(_ card: HermexPushProvisioner.PluginCard) -> some View {
        switch card {
        case .status(.available), .failed:
            captionLine("arrow.up.circle.fill", tint: .blue, text: String(localized: "Plugin update available"), textTint: .blue)
        case .updating:
            captionLine("circle.dashed", tint: .secondary, text: String(localized: "Updating plugin…"), textTint: .secondary)
        case .status(.restartNeeded):
            captionLine("arrow.clockwise.circle.fill", tint: .orange, text: String(localized: "Restart Hermes to finish"),
                        textTint: .secondary)
        case .status(.checkFailed(let failure)):
            captionLine("exclamationmark.triangle.fill", tint: .red, text: failure.title, textTint: .secondary)
        case .status(.upToDate):
            EmptyView()
        }
    }

    private func captionLine(_ symbol: String, tint: Color, text: String, textTint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).foregroundStyle(textTint)
        }
        .font(AppFont.caption())
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
