import SwiftUI
import UIKit

@MainActor struct HermesUpdateCallout: View {
    let model: HermesUpdateModel
    let version: String?
    @State private var isConfirmingUpdate = false

    var body: some View {
        Group {
            if let card { callout(card) }
        }
        .confirmationDialog(movesBack ? "Move Hermes Back?" : "Update Hermes?", isPresented: $isConfirmingUpdate,
                            titleVisibility: .visible) {
            Button(movesBack ? "Move Back" : "Update", role: .destructive) { model.apply() }
        } message: {
            Text(movesBack
                 ? "Hermes moves back to an older release. Running turns on this host stop and Hermes restarts. Hermex reconnects when it’s back."
                 : "Running turns on this host stop and Hermes restarts. Hermex reconnects when it’s back. This can’t be undone.")
        }
    }

    private enum Action { case check, lookAgain, update, moveBack, retry, checkAgain }

    private var movesBack: Bool {
        guard case .answered(let check, _)? = model.check else { return false }
        return check.offer == .moveBack
    }

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
        Card(symbol: "circle.dashed", tint: Color(.appTextSecondary), title: String(localized: "Updating…"),
             message: behind.map { String(localized: "Hermes is installing \($0) commits on your host.") }
                ?? String(localized: "Hermes is installing the update on your host."))
    }

    private func card(for state: HermesUpdateMachine.State) -> Card {
        let restart = String(localized: "Restart the dashboard on the host")
        let warning = "exclamationmark.triangle.fill"
        switch state {
        case .applying: return updating
        case .recovering:
            return Card(symbol: "circle.dashed", tint: Color(.appTextSecondary), title: String(localized: "Restarting Hermes…"),
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
            return Card(symbol: "circle.dashed", tint: Color(.appTextSecondary), title: String(localized: "Updating…"),
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
            let newer = String(localized: "Newer than the latest release")
            if check.offer == .held {
                return Card(symbol: "checkmark.circle.fill", tint: Color(.appTextSecondary), title: newer, message: check.message, action: .check)
            }
            if check.offer == .moveBack {
                return check.canApply
                    ? Card(symbol: "arrow.uturn.backward.circle", tint: Color(.appTextSecondary), title: newer, message: check.message, action: .moveBack)
                    : Card(symbol: "arrow.uturn.backward.circle", tint: Color(.appTextSecondary), title: newer, message: check.message, command: check.hostCommand)
            }
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
            guard check.canApply else {
                return Card(symbol: "arrow.up.circle", tint: Color(.appTextSecondary), title: String(localized: "Update Hermes on your host"),
                            message: check.message, command: check.hostCommand, action: .check)
            }
            return Card(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: String(localized: "Couldn't check for updates"), message: check.message, action: .lookAgain)
        }
    }

    private var behind: Int? {
        guard case .answered(let check, _)? = model.check, let behind = check.behind, behind > 0 else { return nil }
        return behind
    }

    private static let dashboardCommand = "hermes dashboard"
    private static let noSummary = String(localized: "Hermes didn’t say what went wrong. Its update log on the host has the details.")

    private func label(for action: Action) -> String {
        switch action {
        case .check: return model.isChecking ? String(localized: "Checking…") : String(localized: "Check")
        case .lookAgain: return model.isChecking ? String(localized: "Checking…") : String(localized: "Check again")
        case .update: return String(localized: "Update…")
        case .moveBack: return String(localized: "Move back…")
        case .retry: return String(localized: "Try again…")
        case .checkAgain: return model.isWorking ? String(localized: "Checking…") : String(localized: "Check again")
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .check, .lookAgain: Task { await model.checkNow() }
        case .update, .moveBack, .retry: isConfirmingUpdate = true
        case .checkAgain: model.checkAgain()
        }
    }

    @ViewBuilder private func callout(_ card: Card) -> some View {
        let disabled = model.isWorking || model.isChecking
        let content = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: card.symbol).foregroundStyle(card.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).fontWeight(.semibold).foregroundStyle(Color(.appText))
                if let message = card.message { Text(message).foregroundStyle(.appSecondary) }
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

    private func commandRow(_ command: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: command)
                .font(AppFont.footnote().monospaced())
                .foregroundStyle(Color(.appText))
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
        .background(Color(.appCanvas).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
    }
}
