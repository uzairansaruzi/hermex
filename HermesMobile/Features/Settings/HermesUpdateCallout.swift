import SwiftUI
import UIKit

/// The Hermes server card's update callout (#1075, design B): one card in the push section's
/// callout style under the Version row, with an icon, a title, the host's message, a command to
/// copy where the host needs one, and one action. No spinner: a dashed circle carries progress.
/// It shows nothing until the host's check answers, so the server card drives the model's
/// `appear()` and `leaveSettings()`; the model belongs to the server, so an update started here
/// keeps running when Settings closes.
@MainActor struct HermesUpdateCallout: View {
    let model: HermesUpdateModel
    /// The release the server card shows, saved at sign-in and after an update.
    let version: String?
    @State private var isConfirmingUpdate = false

    var body: some View {
        Group {
            if let card { callout(card) }
        }
        .confirmationDialog("Update Hermes?", isPresented: $isConfirmingUpdate, titleVisibility: .visible) {
            // Like push's restart, the run outlives Settings once the host has been asked.
            Button("Update", role: .destructive) { model.apply() }
        } message: {
            Text("Running turns on this host stop and Hermes restarts. Hermex reconnects when it’s back. This can’t be undone.")
        }
    }

    /// `check` and `lookAgain` ask the host's check again; `checkAgain` follows an update that
    /// stopped without an outcome; `update` and `retry` confirm an update first.
    private enum Action { case check, lookAgain, update, retry, checkAgain }

    /// What the callout shows: the update this phone started, else the host's check.
    private struct Card {
        var symbol: String
        var tint: Color
        var title: String
        var message: String?
        var command: String?
        var action: Action?
    }

    private var card: Card? {
        switch model.run {
        case .starting?: return updating
        case .refused(let message, let command)?:
            return Card(symbol: "arrow.up.circle.fill", tint: .blue, title: String(localized: "Update available"),
                        message: message, command: command)
        case .couldNotStart(let message)?:
            return Card(symbol: "exclamationmark.triangle.fill", tint: .red, title: String(localized: "Update failed"),
                        message: message, action: .retry)
        case .following(let machine)?: return card(for: machine.state)
        case nil: return checkCard
        }
    }

    private var updating: Card {
        Card(symbol: "circle.dashed", tint: .secondary, title: String(localized: "Updating…"),
             message: behind.map { String(localized: "Hermes is installing \($0) commits on your host.") }
                ?? String(localized: "Hermes is installing the update on your host."))
    }

    private func card(for state: HermesUpdateMachine.State) -> Card {
        let restart = String(localized: "Restart the dashboard on the host")
        let warning = "exclamationmark.triangle.fill"
        switch state {
        case .applying: return updating
        case .recovering:
            return Card(symbol: "circle.dashed", tint: .secondary, title: String(localized: "Restarting Hermes…"),
                        message: String(localized: "Waiting for Hermes to come back"))
        case .done(let installed):
            return Card(symbol: "checkmark.circle.fill", tint: .green,
                        title: String(localized: "Updated to \(installed ?? version ?? "")"),
                        message: String(localized: "Hermes is back and Hermex reconnected."))
        case .partial(let summary):
            return Card(symbol: warning, tint: .orange, title: String(localized: "Partly updated"),
                        message: summary ?? Self.noSummary, action: .lookAgain)
        case .failed(let summary):
            return Card(symbol: warning, tint: .red, title: String(localized: "Update failed"),
                        message: summary ?? Self.noSummary, action: .retry)
        case .needsDashboardRestart(let running?):
            return Card(symbol: warning, tint: .red, title: restart,
                        message: String(localized: "The update finished, but Hermes still runs \(running). Run this on your host, then check again."),
                        command: Self.dashboardCommand, action: .checkAgain)
        case .needsDashboardRestart(nil):
            return Card(symbol: warning, tint: .red, title: restart,
                        message: String(localized: "The update finished, but Hermes hasn’t answered for 2 minutes. Run this on your host, then check again."),
                        command: Self.dashboardCommand, action: .checkAgain)
        case .stillRunning:
            return Card(symbol: "circle.dashed", tint: .secondary, title: String(localized: "Updating…"),
                        message: String(localized: "Hermes is still updating after 10 minutes. Check again later."),
                        action: .checkAgain)
        }
    }

    private var checkCard: Card? {
        switch model.check {
        case nil: return nil
        case .failed(let message)?:
            return Card(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: String(localized: "Couldn't check for updates"), message: message, action: .lookAgain)
        case .answered(let check, let checkedAt)?:
            if check.updateAvailable {
                let behind = check.behind.flatMap { $0 > 0 ? String(localized: "\($0) commits behind.") : nil }
                    ?? String(localized: "A newer Hermes is available.")
                guard check.canApply else {
                    return Card(symbol: "arrow.up.circle.fill", tint: .blue, title: String(localized: "Update available"),
                                message: behind + " " + String(localized: "This install updates on your host, not from Hermex. Run:"),
                                command: check.hostCommand)
                }
                return Card(symbol: "arrow.up.circle.fill", tint: .blue, title: String(localized: "Update available"),
                            message: behind, action: .update)
            }
            if check.behind == 0 {
                let time = checkedAt.formatted(date: .omitted, time: .shortened)
                return Card(symbol: "checkmark.circle.fill", tint: .green, title: String(localized: "Up to date"),
                            message: String(localized: "Hermes \(version ?? check.currentVersion ?? "") is current. Checked today at \(time)."),
                            action: .check)
            }
            // An install the dashboard can't update (Docker, a package manager, a managed
            // runtime) says how it updates, or a check that couldn't run says why.
            guard check.canApply else {
                return Card(symbol: "arrow.up.circle", tint: .secondary, title: String(localized: "Update Hermes on your host"),
                            message: check.message, command: check.hostCommand, action: .check)
            }
            return Card(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: String(localized: "Couldn't check for updates"), message: check.message, action: .lookAgain)
        }
    }

    /// The commit count from the check the update started from, when the host knew it.
    private var behind: Int? {
        guard case .answered(let check, _)? = model.check, let behind = check.behind, behind > 0 else { return nil }
        return behind
    }

    /// The host's own advice when a manually started dashboard was stopped by the update.
    private static let dashboardCommand = "hermes dashboard"
    private static let noSummary = String(localized: "Hermes didn’t say what went wrong. Its update log on the host has the details.")

    private func label(for action: Action) -> String {
        switch action {
        case .check: return model.isChecking ? String(localized: "Checking…") : String(localized: "Check")
        case .lookAgain: return model.isChecking ? String(localized: "Checking…") : String(localized: "Check again")
        case .update: return String(localized: "Update…")
        case .retry: return String(localized: "Try again…")
        case .checkAgain: return model.isWorking ? String(localized: "Checking…") : String(localized: "Check again")
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .check, .lookAgain: Task { await model.checkNow() }
        case .update, .retry: isConfirmingUpdate = true
        case .checkAgain: model.checkAgain()
        }
    }

    /// The card. With an action and nothing to copy, the whole card is the button, so it stays
    /// a full-width target at every Dynamic Type size; with a command, Copy and the action are
    /// buttons of their own.
    @ViewBuilder private func callout(_ card: Card) -> some View {
        let disabled = model.isWorking || model.isChecking
        let content = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: card.symbol).foregroundStyle(card.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).fontWeight(.semibold).foregroundStyle(Color.primary)
                if let message = card.message { Text(message).foregroundStyle(.secondary) }
                if let command = card.command { commandRow(command) }
                if let action = card.action {
                    if card.command == nil {
                        Text(label(for: action)).foregroundStyle(.tint).padding(.top, 2)
                    } else {
                        Button(label(for: action)) { perform(action) }
                            .buttonStyle(.borderless)
                            .disabled(disabled)
                            .padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(AppFont.footnote())
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        if let action = card.action, card.command == nil {
            Button { perform(action) } label: { content }
                .buttonStyle(.plain)
                .disabled(disabled)
        } else if card.command == nil {
            content.accessibilityElement(children: .combine)
        } else {
            content
        }
    }

    /// The host command in monospace, selectable, with Copy.
    private func commandRow(_ command: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: command)
                .font(AppFont.footnote().monospaced())
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(Color(.systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
    }
}
