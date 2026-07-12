import SwiftUI

struct SessionRenameSheet: View {
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var sessionTitle: String
    @FocusState private var titleIsFocused: Bool

    init(
        initialTitle: String,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        _sessionTitle = State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session title", text: $sessionTitle)
                        .textInputAutocapitalization(.sentences)
                        .focused($titleIsFocused)
                        .disabled(isSaving)
                }
            }
            .navigationTitle("Rename Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(trimmedSessionTitle)
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(trimmedSessionTitle.isEmpty || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                titleIsFocused = true
            }
        }
        .adaptiveFormPresentation()
    }

    private var trimmedSessionTitle: String {
        sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
