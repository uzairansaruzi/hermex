import SwiftUI

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
    private var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AppForm {
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
                        .foregroundStyle(.appSecondary)
                }
            }

            Section {
                SecureField("New value", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } appFooter: {
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
        .themedPageBackground()
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
            AppList {
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
            .themedPageBackground()
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
