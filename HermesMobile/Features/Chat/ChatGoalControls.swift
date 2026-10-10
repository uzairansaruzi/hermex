import SwiftUI

struct GoalControlsMenu: View {
    let currentGoal: SubmittedGoal?
    let isViewingCachedData: Bool
    /// Disables Set Goal.
    let isSetGoalDisabled: Bool
    /// Disables the commands: Status, Pause, Resume, Mark Done, Clear and Stop.
    let isActionDisabled: Bool
    let onSetGoal: () -> Void
    let onSubmitCommand: (String) -> Void
    /// A Hermes session's loop and heartbeat (#1142), a section each below the goal's commands.
    let automations: [BotSessionControl]
    /// Whether the host takes Pause and Resume for them; without it they only show their state.
    let allowsAutomationChanges: Bool
    let isAutomationDisabled: Bool
    /// Asks for one's Pause or Resume, which the chat confirms before sending.
    let onChangeAutomation: (BotSessionControl) -> Void

    var body: some View {
        Menu {
            Button {
                onSetGoal()
            } label: {
                Label("Set Goal", systemImage: "target")
            }
            .disabled(isSetGoalDisabled)

            Divider()

            commandButton(String(localized: "Status"), systemImage: "list.bullet.clipboard", command: "status")
            commandButton(String(localized: "Pause"), systemImage: "pause.circle", command: "pause")
            commandButton(String(localized: "Resume"), systemImage: "play.circle", command: "resume")

            Divider()

            commandButton(String(localized: "Mark Done"), systemImage: "checkmark.circle", command: "done")
            commandButton(String(localized: "Clear"), systemImage: "xmark.circle", command: "clear")

            Button(role: .destructive) {
                onSubmitCommand("stop")
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .disabled(isActionDisabled)

            ForEach(automations) { control in
                automationSection(control)
            }
        } label: {
            Label("Goal", systemImage: goalIconName)
        }
        .disabled(isViewingCachedData)
        .accessibilityLabel("Goal controls")
    }

    private var goalIconName: String {
        switch currentGoal?.status?.lowercased() {
        case "active":
            return "target"
        case "paused":
            return "pause.circle"
        case "done":
            return "checkmark.circle"
        case "cleared":
            return "xmark.circle"
        default:
            return "target"
        }
    }

    /// "Loop · Active" over its Pause, or the state alone when nothing can change it.
    @ViewBuilder
    private func automationSection(_ control: BotSessionControl) -> some View {
        let status = switch control.status {
        case "active": String(localized: "Active")
        case "paused": String(localized: "Paused")
        default: control.status
        }
        // Both halves are localized already; the separator is not words.
        let title = Text(verbatim: "\(control.kind.title) · \(status)")
        if allowsAutomationChanges, control.action != nil {
            Section {
                Button {
                    onChangeAutomation(control)
                } label: {
                    Label(control.actionTitle, systemImage: control.status == "paused" ? "play.circle" : "pause.circle")
                }
                .disabled(isAutomationDisabled)
            } header: {
                title
            }
        } else {
            Section { title }
        }
    }

    private func commandButton(_ title: String, systemImage: String, command: String) -> some View {
        Button {
            onSubmitCommand(command)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(isActionDisabled)
    }
}

struct GoalSubmissionSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var goalDraft: String
    let isSubmitting: Bool
    let onSubmit: (String) -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $goalDraft)
                .font(.body)
                .padding()
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Set Goal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Set") {
                            let submittedGoal = goalDraft
                            dismiss()
                            onSubmit(submittedGoal)
                        }
                        .disabled(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }
}
