import SwiftUI

/// The Notifications section of the Hermes connection screen. One confirmed action sets
/// this server's Hermes host up for push and pairs this iPhone; the same section is the
/// way back out. It appears only once a connection is saved, because every step of the
/// setup runs against that host with that login.
@MainActor struct HermexPushSectionView: View {
    let connection: BotConnection
    @State private var provisioner: HermexPushProvisioner
    @State private var isConfirmingEnable = false
    @State private var isConfirmingDisable = false

    init(server: URL, connection: BotConnection) {
        self.connection = connection
        _provisioner = State(initialValue: HermexPushProvisioner(server: server, connection: connection))
    }

    var body: some View {
        Section {
            if let pairing = provisioner.pairing {
                LabeledContent(String(localized: "Relay"), value: pairing.relayURL.host ?? pairing.relayURL.absoluteString)
                Button(provisioner.isWorking ? String(localized: "Turning off…") : String(localized: "Turn off notifications…"),
                       role: .destructive) { isConfirmingDisable = true }
                    .disabled(provisioner.isWorking)
            } else {
                Button(provisioner.isWorking ? String(localized: "Setting up…") : String(localized: "Turn on notifications…")) {
                    isConfirmingEnable = true
                }
                .disabled(provisioner.isWorking)
                if provisioner.isWorking || provisioner.failure != nil {
                    ForEach(HermexPushProvisioner.Step.allCases) { step in stepRow(step) }
                }
            }
            if let failure = provisioner.failure { failureRow(failure) }
        } header: {
            Text("Notifications")
        } footer: {
            Text(provisioner.pairing == nil
                 ? "Hermex sets this Hermes host up for push and pairs this iPhone with its relay. Your host encrypts every notification’s text: the relay only ever sees ciphertext."
                 : "This iPhone is paired with this server’s Hermes host. Its keys are stored in the Keychain for this server alone.")
        }
        .onChange(of: connection) { _, updated in provisioner.connection = updated }
        .confirmationDialog("Set this Hermes host up for push?", isPresented: $isConfirmingEnable, titleVisibility: .visible) {
            // Deliberately not cancelled when the screen closes: the host has already been
            // asked to change, so the run finishes and the keys land instead of leaving a
            // configured host and an unpaired phone. Reopening reads the stored result.
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
