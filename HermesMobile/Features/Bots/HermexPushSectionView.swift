import SwiftUI

/// The single notification home under Settings → Interaction. Push choices belong
/// to this server and device; the caller supplies the existing global alert controls.
@MainActor struct HermexPushSectionView<SharedSettings: View>: View {
    let server: URL
    @State private var provisioner: HermexPushProvisioner
    @State private var isExpanded = false
    @State private var isConfirmingEnable = false
    @State private var isConfirmingDisable = false
    @State private var preferenceTask: Task<Void, Never>?
    private let sharedSettings: SharedSettings

    init(server: URL, @ViewBuilder sharedSettings: () -> SharedSettings) {
        self.server = server
        self.sharedSettings = sharedSettings()
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
                }
            }
            .foregroundStyle(Color.primary)
            .frame(minHeight: 44)
        }
        .transaction { $0.animation = nil }
        .task { await provisioner.reload() }
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
    }

    @ViewBuilder private var pushSettings: some View {
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
                Text("For this iPhone and the selected server. Previews include message text; your iPhone’s notification settings still apply.")
                    .font(AppFont.caption()).foregroundStyle(.secondary)
            }
            if provisioner.phase == .savingPreferences {
                Text("Saving…").font(AppFont.caption()).foregroundStyle(.secondary)
            }
            LabeledContent(String(localized: "Relay"), value: pairing.relayURL.host ?? pairing.relayURL.absoluteString)
                .font(AppFont.subheadline())
            Button(provisioner.phase == .disabling ? String(localized: "Turning off…") : String(localized: "Turn off notifications…"),
                   role: .destructive) { isConfirmingDisable = true }
                .disabled(provisioner.isWorking)
                .frame(minHeight: 44)
        } else if provisioner.connection != nil {
            Button(provisioner.isWorking ? String(localized: "Setting up…") : String(localized: "Turn on notifications…")) {
                isConfirmingEnable = true
            }
            .disabled(provisioner.isWorking)
            .frame(minHeight: 44)
            if provisioner.isWorking || provisioner.failure != nil {
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
        if let failure = provisioner.failure { failureRow(failure) }
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

    private func failureRow(_ failure: HermexPushProvisioner.Failure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(failure.title).font(.footnote.weight(.semibold))
            Text(failure.message).font(.footnote)
        }
        .foregroundStyle(.red)
        .accessibilityElement(children: .combine)
    }
}
