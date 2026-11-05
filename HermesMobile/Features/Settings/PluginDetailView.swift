import SwiftUI

/// One installed plugin's page (#1582): what it is, and its manifest's settings as a native form. It
/// reads its row from the model by key, so it always shows what the host last reported.
struct PluginDetailView: View {
    let key: String
    let model: PluginsModel

    private var plugin: HermesPlugin? { model.plugins.first { $0.key == key } }

    var body: some View {
        AppList {
            if let notice = model.notice { Section { PluginNoticeRow(notice: notice) } }
            if let plugin {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: plugin.name).font(.headline)
                        if !plugin.summary.isEmpty {
                            Text(verbatim: plugin.summary).font(.footnote).foregroundStyle(.appSecondary)
                        }
                    }
                    LabeledContent(String(localized: "Key")) { Text(verbatim: plugin.key).textSelection(.enabled) }
                    if !plugin.version.isEmpty {
                        LabeledContent(String(localized: "Version")) { Text(verbatim: plugin.version) }
                    }
                    if plugin.hasUpdate, let version = plugin.updateVersion {
                        LabeledContent(String(localized: "Update available")) { Text(verbatim: version) }
                    }
                    LabeledContent(String(localized: "Source")) { Text(verbatim: plugin.origin) }
                }
                if !plugin.settings.isEmpty {
                    PluginSettingsForm(plugin: plugin, model: model)
                }
            } else {
                ContentUnavailableView("This Plugin Is Gone", systemImage: "puzzlepiece.extension")
                    .listRowBackground(Color.clear)
            }
        }
        .listSectionSpacing(.compact)
        .themedPageBackground()
        .navigationTitle(plugin?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// A plugin's settings for all six field types. Only changed fields are sent, and a field the host
/// refuses says why. Secrets save on their own, straight to the Profile's `.env`.
private struct PluginSettingsForm: View {
    let plugin: HermesPlugin
    let model: PluginsModel

    @State private var drafts: [String: String]
    @State private var isSaving = false
    @State private var refusal: String?

    init(plugin: HermesPlugin, model: PluginsModel) {
        self.plugin = plugin
        self.model = model
        _drafts = State(initialValue: Self.drafts(for: plugin))
    }

    private static func drafts(for plugin: HermesPlugin) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plugin.settings.map { ($0.key, $0.text) })
    }

    private var problems: [String: String] {
        var problems: [String: String] = [:]
        for field in plugin.settings {
            if case .invalid(let message) = field.parse(drafts[field.key] ?? "") { problems[field.key] = message }
        }
        return problems
    }

    /// The fields whose draft now means something other than what's saved.
    private var changes: [String: BotJSON] {
        var changes: [String: BotJSON] = [:]
        for field in plugin.settings {
            if case .value(let value) = field.parse(drafts[field.key] ?? ""), value != field.value {
                changes[field.key] = value
            }
        }
        return changes
    }

    var body: some View {
        Section {
            ForEach(plugin.settings) { field in
                PluginSettingRow(field: field, plugin: plugin, text: binding(for: field), problem: problems[field.key], model: model)
            }
            if plugin.settings.contains(where: { if case .secret = $0.kind { false } else { true } }) {
                if let refusal {
                    Text(verbatim: refusal).font(.footnote).foregroundStyle(.red)
                }
                Button(isSaving ? String(localized: "Saving…") : String(localized: "Save Settings")) {
                    Task { await save() }
                }
                .disabled(changes.isEmpty || !problems.isEmpty || isSaving)
            }
        } header: {
            Text("Settings")
        }
        .onChange(of: plugin.settings) { old, new in reconcile(old, with: new) }
    }

    /// A field nobody has edited follows what the host now says. One being edited keeps its draft,
    /// so saving a secret or a slow save never loses other work.
    private func reconcile(_ old: [HermesPluginSetting], with new: [HermesPluginSetting]) {
        for field in new {
            let previous = old.first { $0.key == field.key }?.text
            if drafts[field.key] == nil || drafts[field.key] == previous { drafts[field.key] = field.text }
        }
    }

    private func binding(for field: HermesPluginSetting) -> Binding<String> {
        Binding(get: { drafts[field.key] ?? "" }, set: { drafts[field.key] = $0; refusal = nil })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        refusal = await model.saveSettings(plugin, values: changes)
    }
}

private struct PluginSettingRow: View {
    let field: HermesPluginSetting
    let plugin: HermesPlugin
    @Binding var text: String
    let problem: String?
    let model: PluginsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if !field.description.isEmpty {
                Text(verbatim: field.description).font(.footnote).foregroundStyle(.appSecondary)
            }
            if let problem {
                Text(verbatim: problem).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    /// The label with its required mark, as VoiceOver and the row both read it.
    private var label: String {
        field.isRequired ? String(localized: "\(field.label) (required)") : field.label
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .string:
            LabeledContent {
                TextField(label, text: $text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } label: {
                Text(verbatim: label)
            }
        case .number:
            LabeledContent {
                TextField(label, text: $text)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
            } label: {
                Text(verbatim: label)
            }
        case .boolean:
            Toggle(isOn: Binding(get: { text == "true" }, set: { text = $0 ? "true" : "false" })) {
                Text(verbatim: label)
            }
        case .choice(let choices):
            Picker(selection: $text) {
                if text.isEmpty { Text("Not set").tag("") }
                ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
            } label: {
                Text(verbatim: label)
            }
            .pickerStyle(.menu)
        case .json:
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: label)
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 64)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text(verbatim: label))
            }
        case .secret(let env, let isSet):
            PluginSecretField(label: label, env: env, isSet: isSet, plugin: plugin, model: model)
        }
    }
}

/// A secret: whether it's set, never its value. A value goes out once and isn't kept here.
private struct PluginSecretField: View {
    let label: String
    let env: String
    let isSet: Bool
    let plugin: HermesPlugin
    let model: PluginsModel

    @State private var value = ""
    @State private var isSaving = false
    @State private var failure: String?
    @State private var isConfirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text(isSet ? String(localized: "Set") : String(localized: "Not set"))
            } label: {
                Text(verbatim: label)
            }
            Text(verbatim: env).font(.caption.monospaced()).foregroundStyle(.appSecondary)
            SecureField(isSet ? String(localized: "Replace the key") : String(localized: "Paste the key"), text: $value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let failure {
                Text(verbatim: failure).font(.footnote).foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                // Borderless so each button takes only its own taps, not the whole row's.
                Button("Save Key") { Task { await set(value) } }
                    .buttonStyle(.borderless)
                    .disabled(value.isEmpty || isSaving)
                if isSet {
                    Button("Remove Key", role: .destructive) { isConfirmingRemove = true }
                        .buttonStyle(.borderless)
                        .disabled(isSaving)
                }
            }
        }
        .alert("Remove \(env)?", isPresented: $isConfirmingRemove) {
            Button("Remove", role: .destructive) { Task { await set(nil) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes it from this Profile's .env on the host, and the plugin can't use it until you add it again.")
        }
    }

    private func set(_ newValue: String?) async {
        isSaving = true
        defer { isSaving = false }
        failure = nil
        do {
            try await model.setSecret(env, value: newValue, of: plugin)
            value = ""
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// An update the host held back: the abilities it adds, or what its scan found. Nothing changed, and
/// nothing changes until the user accepts. A dangerous result offers only Close.
struct PluginUpdateReviewSheet: View {
    let review: PluginsModel.UpdateReview
    let model: PluginsModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    Text(verbatim: review.plugin.name).font(.headline)
                }
                switch review.reason {
                case .newAbilities(let abilities):
                    Section {
                        Text("This update gives the plugin new abilities. Nothing changes until you accept.").font(.footnote)
                        ForEach(abilities, id: \.self) { Text(verbatim: $0).font(.footnote) }
                    }
                case .scan(let canOverride, let findings):
                    Section {
                        Text(canOverride
                             ? String(localized: "Hermes's security scan flagged this update. Nothing changes unless you update anyway.")
                             : String(localized: "Hermes's security scan found this update dangerous, so it can't be applied."))
                            .font(.footnote)
                    }
                    Section(String(localized: "Findings")) {
                        ForEach(findings) { finding in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: finding.description).font(.footnote)
                                Text(verbatim: [finding.severity, finding.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.appSecondary)
                            }
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .themedPageBackground()
            .navigationTitle(String(localized: "Review Update"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(acceptTitle == nil ? String(localized: "Close") : String(localized: "Cancel")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let acceptTitle {
                    Button {
                        model.accept(review)
                    } label: {
                        Text(verbatim: acceptTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.appProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.appMaterial(.bar))
                }
            }
        }
    }

    /// What accepting says, or nil when it can't be accepted.
    private var acceptTitle: String? {
        switch review.reason {
        case .newAbilities: String(localized: "Accept and Update")
        case .scan(true, _): String(localized: "Update Anyway")
        case .scan(false, _): nil
        }
    }
}
