import SwiftUI

/// A Hermes server's API Keys page (#1318), opened from its Settings page: the keys one Profile's
/// `.env` sets, by category, each opening to be replaced or removed, and **+** to add another.
struct APIKeysView: View {
    @State private var model: APIKeysModel
    @State private var sheet: APIKeySheet?

    init(connection: BotConnection, server: URL) {
        _model = State(initialValue: APIKeysModel(client: HermesEnvironmentClient(saved: connection, server: server)))
    }

    var body: some View {
        List {
            if let profile = model.profile {
                profileSection(profile)
            }
            content
        }
        .settingsPage(String(localized: "API Keys"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let profile = model.profile { sheet = .add(profile: profile) }
                } label: {
                    Label("Add Key", systemImage: "plus")
                }
                .disabled(!model.isLoaded)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add(let profile):
                APIKeyPicker(keys: model.keys, profile: profile, model: model) { self.sheet = nil }
            case .edit(let key, let profile):
                NavigationStack {
                    APIKeyForm(key: key, profile: profile, model: model, onCancel: { self.sheet = nil }) { self.sheet = nil }
                }
            }
        }
    }

    /// The Profile the page lists, a menu of the others when the host has more than one.
    private func profileSection(_ profile: String) -> some View {
        Section {
            if model.profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { profile }, set: { name in Task { await model.select(name) } })) {
                    ForEach(model.profiles, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .pickerStyle(.menu)
            } else {
                LabeledContent("Profile") { Text(verbatim: profile) }
            }
        } footer: {
            Text("Keys in this Profile's .env file. Keys the host gets from its environment or a sign-in still work but aren't listed.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading keys…")
            }
            .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Keys", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            let sections = model.setSections
            if sections.isEmpty, let profile = model.profile {
                ContentUnavailableView {
                    Label("No keys in \(profile)'s .env", systemImage: "key")
                } actions: {
                    Button("Add Key") { sheet = .add(profile: profile) }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(sections) { section in
                Section(section.category.title) {
                    ForEach(section.keys) { key in
                        Button {
                            if let profile = model.profile { sheet = .edit(key, profile: profile) }
                        } label: {
                            APIKeyRow(key: key) {
                                if let preview = key.preview {
                                    Text(verbatim: preview)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
        }
    }
}

/// What the API Keys page presents, each naming the Profile it writes to.
private enum APIKeySheet: Identifiable {
    case add(profile: String)
    case edit(HermesEnvKey, profile: String)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let key, _): "edit-" + key.name
        }
    }
}

/// One key's row: its title, the variable name under a provider's label, and `trailing`.
struct APIKeyRow<Trailing: View>: View {
    let key: HermesEnvKey
    @ViewBuilder let trailing: Trailing

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            Text(verbatim: key.title)
                .font(key.hasLabel ? .body : .body.monospaced())
                .foregroundStyle(.primary)
            if key.hasLabel {
                Text(verbatim: key.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
