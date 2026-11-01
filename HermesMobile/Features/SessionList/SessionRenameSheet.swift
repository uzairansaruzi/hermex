import SwiftUI

struct SessionRenameSheet: View {
    let isSaving: Bool
    /// Why the server refused the last title, shown under the field so the sheet stays open
    /// with it; a Hermes host's own message (#1048).
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var sessionTitle: String
    @FocusState private var titleIsFocused: Bool

    init(
        initialTitle: String,
        isSaving: Bool,
        errorMessage: String? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.isSaving = isSaving
        self.errorMessage = errorMessage
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
                } footer: {
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(.red)
                    }
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
            .onChange(of: errorMessage) {
                if let errorMessage { AccessibilityNotification.Announcement(errorMessage).post() }
            }
        }
        .adaptiveFormPresentation()
    }

    private var trimmedSessionTitle: String {
        sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
