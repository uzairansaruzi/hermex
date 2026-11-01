import SwiftUI

/// Sets, replaces or removes one key in `profile`'s `.env` (#1318); a nil `key` asks for a custom
/// key's name too. The value lives only in this view's state: it goes out once in the write's body
/// and is cleared when the view closes. `onCancel`, when the form is a sheet's root, shows Cancel;
/// `onDone` closes the sheet after a write the host accepted. Neither Cancel nor Back is offered
/// while a write is in flight, so the sheet never closes under one.
struct APIKeyForm: View {
    let key: HermesEnvKey?
    let profile: String
    let model: APIKeysModel
    var onCancel: (() -> Void)?
    let onDone: () -> Void

    @State private var customName = ""
    @State private var value = ""
    @State private var isWriting = false
    @State private var isConfirmingRemove = false
    @State private var failure: String?

    private var name: String { key?.name ?? customName.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Trimmed, since a pasted key often ends in a newline.
    private var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            if key == nil {
                Section("Name") {
                    TextField("Name", text: $customName, prompt: Text(verbatim: "MY_API_KEY"))
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
            }

            if let preview = key?.preview {
                Section("Current") {
                    Text(verbatim: preview)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                SecureField("New value", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Saved on the server in Profile “\(profile)”. Hermex doesn't keep a copy.")
            }

            if key?.isSet == true {
                Section {
                    Button("Remove Key", role: .destructive) { isConfirmingRemove = true }
                }
            }
        }
        .disabled(isWriting)
        .interactiveDismissDisabled(isWriting)
        .navigationTitle(key?.title ?? String(localized: "Custom Key"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWriting)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(isWriting)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    write { try await model.save(name, value: trimmedValue, profile: profile) }
                }
                .disabled(name.isEmpty || trimmedValue.isEmpty || isWriting)
            }
        }
        .alert(Text("Remove \(name)?"), isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                write { try await model.remove(name, profile: profile) }
            }
        } message: {
            Text("Chats on Profile “\(profile)” that use it stop working until a key is set again.")
        }
        .alert("Couldn't Update Key", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(verbatim: failure ?? "")
        }
        .onDisappear { value = "" }
    }

    /// Runs one write, then closes the sheet, or shows the host's refusal and keeps the value.
    private func write(_ operation: @escaping @MainActor () async throws -> Void) {
        isWriting = true
        Task {
            do {
                try await operation()
                value = ""
                onDone()
            } catch {
                failure = error.localizedDescription
            }
            isWriting = false
        }
    }
}

/// The Add Key sheet (#1318): a custom key and every key the host knows, by category. An advanced
/// key shows only in search results; a key the Profile already sets carries a checkmark and opens
/// to be replaced.
struct APIKeyPicker: View {
    let keys: [HermesEnvKey]
    let profile: String
    let model: APIKeysModel
    let onDone: () -> Void

    @State private var query = ""

    private var sections: [HermesEnvKey.Section] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return HermesEnvKey.sections(keys.filter { !$0.isAdvanced }) }
        return HermesEnvKey.sections(keys.filter { key in
            [key.name, key.title, key.description ?? ""].contains { $0.localizedStandardContains(query) }
        })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Custom Key…") {
                        APIKeyForm(key: nil, profile: profile, model: model, onDone: onDone)
                    }
                }

                ForEach(sections) { section in
                    Section(section.category.title) {
                        ForEach(section.keys) { key in
                            NavigationLink {
                                APIKeyForm(key: key, profile: profile, model: model, onDone: onDone)
                            } label: {
                                APIKeyRow(key: key) {
                                    if key.isSet {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel(Text("Already set"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Add Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
            }
        }
    }
}
