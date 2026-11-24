import SwiftUI

@MainActor struct HermexPushSettingsPage<SharedSections: View>: View {
    let server: URL
    let offersPluginUpdate: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var provisioner: HermexPushProvisioner
    @State private var isConfirmingEnable = false
    @State private var isConfirmingDisable = false
    @State private var isConfirmingUpdate = false
    @State private var hasOfferedUpdate = false
    @State private var isConfirmingRestart = false
    @State private var preferenceTask: Task<Void, Never>?
    private let sharedSections: SharedSections

    init(server: URL, offersPluginUpdate: Bool = false, @ViewBuilder sharedSections: () -> SharedSections) {
        self.server = server
        self.offersPluginUpdate = offersPluginUpdate
        self.sharedSections = sharedSections()
        _provisioner = State(initialValue: HermexPushProvisioner(
            server: server, connection: try? BotConnectionStore().load(server: server)))
    }

    var body: some View {
        AppList {
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
            guard offersPluginUpdate, !hasOfferedUpdate, !Task.isCancelled else { return }
            hasOfferedUpdate = true
            switch provisioner.pluginCard {
            case .status(.available)?, .status(.newer)?: isConfirmingUpdate = true
            default: break
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await provisioner.recheckNotificationPermission() }
        }
        .onDisappear {
            preferenceTask?.cancel()
            preferenceTask = nil
            provisioner.leaveSettings()
        }
        .confirmationDialog("Set this Hermes host up for push?", isPresented: $isConfirmingEnable, titleVisibility: .visible) {
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
            Button("Update plugin") { Task { await provisioner.updatePlugin() } }
        } message: {
            Text(provisioner.pairing == nil
                 ? String(localized: "Your Hermes host downloads hermex-push again from GitHub and restarts its gateway, interrupting work running there. To finish, you’ll likely need to restart Hermes on the host yourself.")
                 : String(localized: "Your Hermes host downloads hermex-push again from GitHub and restarts its gateway, interrupting work running there. This iPhone stays paired. To finish, you’ll likely need to restart Hermes on the host yourself."))
        }
        .confirmationDialog("Restart Hermes?", isPresented: $isConfirmingRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await provisioner.restartHermes() } }
        } message: {
            Text("Bot turns running on this host stop. Hermex reconnects when Hermes is back.")
        }
    }

    @ViewBuilder private var pushSettings: some View {
        if let card = provisioner.pluginCard { pluginCallout(card) }
        if let pairing = provisioner.pairing {
            if pairing.preferencesNeedSync == true {
                Text("Not synced with the relay yet.")
                    .font(AppFont.caption()).foregroundStyle(.appSecondary)
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
                    .font(AppFont.caption()).foregroundStyle(.appSecondary)
            }
            if provisioner.phase == .savingPreferences {
                Text("Saving…").font(AppFont.caption()).foregroundStyle(.appSecondary)
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
                .font(AppFont.caption()).foregroundStyle(.appSecondary)
        }
        NavigationLink(provisioner.connection == nil ? String(localized: "Connect Hermes…") : String(localized: "Hermes connection")) {
            BotConnectionView(server: server)
        }
        .disabled(provisioner.isWorking)
        if let failure = provisioner.failure {
            switch failure.remedy {
            case .none: failureRow(failure)
            case .updatePlugin: failureCallout(failure, action: String(localized: "Update plugin…"))
            case .retryUpdate, .retryRestart: EmptyView()
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

    @ViewBuilder private func testNotificationRows(_ pairing: PushPairing) -> some View {
        Button(provisioner.phase == .sendingTest ? String(localized: "Sending…") : String(localized: "Send Test Notification")) {
            Task { await provisioner.sendTestNotification() }
        }
        .disabled(!provisioner.canSendTest)
        .frame(minHeight: 44)
        Text("Reaches every paired iPhone; doesn’t test your host.")
            .font(AppFont.caption()).foregroundStyle(.appSecondary)
        if !pairing.effectivePreferences.replies {
            Text("Turn on Reply Notifications to send a test.")
                .font(AppFont.caption()).foregroundStyle(.appSecondary)
        } else if provisioner.testDelivered {
            Label {
                Text("Sent. It should arrive in a few seconds.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(AppFont.caption())
        }
    }

    private func stepRow(_ step: HermexPushProvisioner.Step) -> some View {
        let isDone = provisioner.completed.contains(step)
        let isRunning = provisioner.isRunning(step)
        return HStack(spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : (isRunning ? "circle.dashed" : "circle"))
                .foregroundStyle(isDone ? Color.green : Color(.appTextSecondary))
            Text(step.title).fontWeight(isRunning ? .semibold : .regular)
        }
        .font(AppFont.footnote())
        .foregroundStyle(isDone || isRunning ? Color(.appText) : Color(.appTextSecondary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isDone ? String(localized: "\(step.title): done")
                                 : (isRunning ? String(localized: "\(step.title): working")
                                    : String(localized: "\(step.title): waiting"))))
    }

    @ViewBuilder private func notificationsOffRow(title: String?, message: String) -> some View {
        if let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString) {
            Link(destination: settingsURL) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "bell.slash").foregroundStyle(.appSecondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).fontWeight(.semibold).foregroundStyle(Color(.appText)) }
                        Text(message).foregroundStyle(.appSecondary)
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

    @ViewBuilder private func pluginCallout(_ card: HermexPushProvisioner.PluginCard) -> some View {
        let minimum = HermexPushPlugin.minimumVersion.description
        switch card {
        case .status(.available(let loaded)):
            callout("arrow.up.circle.fill", tint: .blue, title: Text("Plugin update available"),
                    message: loaded.map { Text("Your Hermes host has hermex-push \($0.description) loaded. This version of Hermex needs \(minimum) or newer.") }
                        ?? Text("Your Hermes host has an older hermex-push. This version of Hermex needs \(minimum) or newer."),
                    action: String(localized: "Update plugin…")) { isConfirmingUpdate = true }
        case .status(.newer(let loaded, _)):
            callout("arrow.up.circle", tint: .blue, title: Text("Plugin update available"),
                    message: Text("Your Hermes host found a newer hermex-push than the \(loaded.description) it runs."),
                    action: String(localized: "Update plugin…")) { isConfirmingUpdate = true }
        case .updating(let step):
            callout("circle.dashed", tint: Color(.appTextSecondary), title: Text("Updating the plugin…"), message: Text(step.progress))
        case .status(.restartNeeded(let loaded)) where provisioner.canRestart(loaded):
            callout("arrow.clockwise.circle.fill", tint: .orange, title: Text("Restart Hermes to finish"),
                    message: Text("Hermes loads the new plugin when it restarts."),
                    action: String(localized: "Restart Hermes…")) { isConfirmingRestart = true }
        case .status(.restartNeeded), .status(.setupNeedsRestart):
            callout("arrow.clockwise.circle.fill", tint: .orange, title: Text("Restart Hermes to finish"),
                    message: provisioner.servesWebapp ? Text("Restart the Hermes gateway on your host, then check again.")
                        : Text("Restart `hermes dashboard` on your host, then check again."),
                    action: provisioner.phase == .checkingPlugin ? String(localized: "Checking…") : String(localized: "Check again")) {
                Task { await provisioner.checkPluginAgain() }
            }
        case .restarting:
            callout("circle.dashed", tint: Color(.appTextSecondary), title: Text("Restarting Hermes…"),
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

    private func failureCallout(_ failure: HermexPushProvisioner.Failure, action: String) -> some View {
        callout("exclamationmark.triangle.fill", tint: .red, title: Text(failure.title), message: Text(failure.message),
                action: action) {
            if failure.remedy == .retryRestart { isConfirmingRestart = true } else { isConfirmingUpdate = true }
        }
    }

    @ViewBuilder private func callout(_ symbol: String, tint: Color, title: Text, message: Text,
                                      action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        let card = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.fontWeight(.semibold).foregroundStyle(Color(.appText))
                message.foregroundStyle(.appSecondary)
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
            Text(failure.title).font(AppFont.footnote(weight: .semibold))
            Text(failure.message).font(AppFont.footnote())
        }
        .foregroundStyle(.red)
        .accessibilityElement(children: .combine)
    }
}
