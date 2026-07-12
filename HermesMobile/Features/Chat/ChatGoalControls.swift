import SwiftUI

struct GoalControlsMenu: View {
    let currentGoal: SubmittedGoal?
    let isViewingCachedData: Bool
    let isActionDisabled: Bool
    let onSetGoal: () -> Void
    let onSubmitCommand: (String) -> Void

    var body: some View {
        Menu {
            Button {
                onSetGoal()
            } label: {
                Label("Set Goal", systemImage: "target")
            }
            .disabled(isActionDisabled)

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
