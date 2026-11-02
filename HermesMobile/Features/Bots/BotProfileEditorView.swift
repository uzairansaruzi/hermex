import PhotosUI
import SwiftUI

@MainActor struct BotProfileEditorView: View {
    @State private var editor: BotProfileEditor
    @State private var capabilitySheet: BotProfileEditor.Field?
    @State private var showsModels = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var showsStudio = false
    @State private var imageError: String?
    /// What the face should do about the last edit; see `BotCreateView`.
    @State private var cue: BotFaceCue?
    @Environment(\.scenePhase) private var scenePhase

    private let colors = BotAvatarColor.palette

    init(server: URL, connection: BotConnection, profile: BotProfile, avatar: UIImage?,
         onSaved: @escaping () -> Void = {}) {
        _editor = State(initialValue: BotProfileEditor(server: server, connection: connection,
                                                       profile: profile, avatar: avatar, onSaved: onSaved))
    }

    init(editor: BotProfileEditor) { _editor = State(initialValue: editor) }

    var body: some View {
        Group {
            switch editor.state {
            case .idle, .loading:
                ProgressView("Loading profiles...")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could Not Load Profiles", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again") { Task { await editor.load() } }
                }
            case .loaded:
                editorBody
            }
        }
        .navigationTitle(editor.profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await editor.save() } }
                    .fontWeight(.semibold)
                    .disabled(!editor.canSave)
            }
        }
        .task { if editor.state == .idle { await editor.load() } }
        .onDisappear { editor.close() }
        .onChange(of: scenePhase) {
            // Control Center and banners (`.inactive`) keep the connection (#902); only an
            // editor without one reloads, and never over unsaved edits.
            if scenePhase == .background {
                editor.suspend()
            } else if scenePhase == .active, !editor.holdsConnection,
                      editor.state == .idle || editor.state == .loading
                        || (editor.state == .loaded && editor.dirtyFields.isEmpty) {
                Task { await editor.load() }
            }
        }
        .sheet(item: $capabilitySheet) { field in capabilityPicker(field) }
        .sheet(isPresented: $showsModels) { modelPicker }
        .fullScreenCover(isPresented: $showsStudio) {
            BotAvatarStudioView(studio: BotAvatarStudio(
                name: editor.profile.id, appearance: editor.draft.appearance, hadPhoto: editor.hasPhoto,
                sendPrompt: editor.holdsConnection ? { [editor] prompt in try await editor.sendAvatarPrompt(prompt) } : nil
            )) { studio in editor.applyStudio(studio); cue = BotFaceCue(.hop) }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .alert("Could not decode this image.", isPresented: Binding(
            get: { imageError != nil }, set: { if !$0 { imageError = nil } }
        )) { Button("OK") { imageError = nil } } message: {
            if let imageError { Text(verbatim: imageError) }
        }
        .alert("Confirm this model change?", isPresented: Binding(
            get: { editor.confirmation != nil }, set: { if !$0, editor.confirmation != nil { editor.declineModelChange() } }
        )) {
            Button("Cancel", role: .cancel) { editor.declineModelChange() }
            Button("Continue") { Task { await editor.confirmModelChange() } }
        } message: {
            if let confirmation = editor.confirmation { Text(verbatim: confirmation.message) }
        }
    }

    private var editorBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                identityHeader
                if !editor.outcomes.isEmpty { saveResults }
                sectionLabel("Identity")
                card {
                    editorField("Display Name", text: Binding(get: { editor.draft.appearance.title }, set: { editor.setTitle($0); cue = BotFaceCue(.glanceDown) }))
                }

                sectionLabel("Appearance")
                characterCard

                sectionLabel("Description")
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description").font(.caption).foregroundStyle(.secondary)
                        TextField("Description", text: Binding(get: { editor.draft.description }, set: { editor.setDescription($0) }), axis: .vertical)
                            .lineLimit(2...4)
                    }
                    .padding(16)
                    Divider().padding(.leading, 16)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Instructions").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { editor.draft.instructions }, set: { editor.setInstructions($0) }))
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                    }
                    .padding(16)
                }
                Text("Saving replaces this Profile’s complete instructions.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 7)

                sectionLabel("Model")
                card { navigationRow(String(localized: "Default Model"), subtitle: editor.draft.model?.providerID,
                                     value: editor.draft.model?.displayName ?? "—",
                                     systemImage: "cpu") { showsModels = true } }

                sectionLabel("Capabilities")
                card {
                    capabilityRow(.skills, systemImage: "sparkles")
                    Divider().padding(.leading, 52)
                    capabilityRow(.toolsets, systemImage: "wrench.and.screwdriver")
                    Divider().padding(.leading, 52)
                    capabilityRow(.mcpServers, systemImage: "server.rack")
                }
                sectionLabel("Server")
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.fill").font(.caption).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(editor.connection.name)
                            Text(editor.connection.address.host ?? editor.connection.address.absoluteString)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 36)
        }
        .background(Color(uiColor: .systemBackground))
        .scrollDismissesKeyboard(.interactively)
        .disabled(editor.isSaving)
        .overlay { if editor.isSaving { ProgressView().padding(18).background(.regularMaterial, in: Circle()) } }
    }

    private var identityHeader: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatar = editor.avatar {
                        Image(uiImage: avatar).resizable().scaledToFit()
                    } else {
                        BotInteractiveFaceView(name: editor.profile.id, appearance: editor.draft.appearance, size: 96, cue: cue)
                    }
                }
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            }
            VStack(spacing: 10) {
                Text(editor.draft.appearance.title.isEmpty ? editor.profile.name : editor.draft.appearance.title)
                    .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                if !editor.draft.description.isEmpty {
                    Text(editor.draft.description).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                Text(verbatim: "\(editor.profile.id) · \(editor.connection.name)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26).padding(.bottom, 12)
    }

    /// The way into the studio, and the one place a photo is chosen or removed.
    private var characterCard: some View {
        card {
            navigationRow(String(localized: "Customize Avatar"), subtitle: nil,
                          value: editor.avatar == nil ? BotAvatarStudio.summary(of: editor.draft.appearance, name: editor.profile.id) : "",
                          systemImage: "face.smiling") { showsStudio = true }
            Divider().padding(.leading, 16)
            navigationRow(String(localized: "Choose Photo"), subtitle: nil, value: "", systemImage: "photo.on.rectangle") {
                showsPhotoPicker = true
            }
            if editor.avatar != nil {
                Divider().padding(.leading, 16)
                Button(role: .destructive) { editor.removeAvatar() } label: {
                    Label("Remove Photo", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                }
            }
        }
    }

    private var saveResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editor.outcomes.values.contains(where: { if case .saved = $0 { return false }; return true })
                 ? String(localized: "Needs Attention") : String(localized: "Saved"))
                .font(.headline)
            ForEach(BotProfileEditor.Field.allCases.filter { editor.outcomes[$0] != nil }) { field in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: resultIcon(editor.outcomes[field]!))
                        .foregroundStyle(resultColor(editor.outcomes[field]!)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.title).font(.subheadline.weight(.semibold))
                        Text(resultText(editor.outcomes[field]!)).font(.caption).foregroundStyle(.secondary)
                        if editor.outcomes[field] == .conflict {
                            Button("Reload") { Task { await editor.reloadAppearance() } }.font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
        .padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .padding(.top, 10)
    }

    private func capabilityRow(_ field: BotProfileEditor.Field, systemImage: String) -> some View {
        let values = capabilities(field)
        return navigationRow(field.title, subtitle: values.filter(\.enabled).map(\.name).prefix(3).joined(separator: ", "),
                             value: "\(values.filter(\.enabled).count)/\(values.count)", systemImage: systemImage) {
            capabilitySheet = field
        }
    }

    private func capabilityPicker(_ field: BotProfileEditor.Field) -> some View {
        NavigationStack {
            List(capabilities(field)) { item in
                Toggle(isOn: Binding(get: { capability(field, id: item.id)?.enabled == true },
                                     set: { editor.setEnabled($0, field: field, id: item.id) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                        if let detail = item.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(field.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { capabilitySheet = nil } } }
        }
        .adaptiveFormPresentation()
    }

    private var modelPicker: some View {
        ModelPickerSheet(
            configuration: ModelPickerConfiguration(
                navigationTitle: "Choose Model", dismissTitle: "Done", dismissPlacement: .topBarTrailing,
                customActionTitle: "Use Custom", requiresCustomProviderID: true,
                showsCustomFavoriteStar: false, showsModelFavoriteStars: false,
                showsCurrentCustomModelGroup: true, showsSavedCustomModelGroup: false, dismissesOnCommit: true
            ),
            modelGroups: editor.modelGroups, selectedModelID: editor.draft.model?.id,
            selectedModelProviderID: editor.draft.model?.providerID,
            isSelected: { editor.draft.model?.matchesSelection(modelID: $0.id, providerID: $0.providerID) == true },
            onSelect: { editor.setModel($0); showsModels = false }
        )
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.subheadline).foregroundStyle(.tertiary).padding(.leading, 10).padding(.top, 24).padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func editorField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, axis: .vertical).lineLimit(1...3)
        }
        .padding(16)
    }

    private func navigationRow(_ title: String, subtitle: String?, value: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func capabilities(_ field: BotProfileEditor.Field) -> [BotProfileCapability] {
        switch field {
        case .skills: return editor.draft.skills
        case .toolsets: return editor.draft.toolsets
        case .mcpServers: return editor.draft.mcpServers
        default: return []
        }
    }

    private func capability(_ field: BotProfileEditor.Field, id: String) -> BotProfileCapability? {
        capabilities(field).first { $0.id == id }
    }

    private func resultIcon(_ outcome: BotProfileEditor.Outcome) -> String {
        switch outcome { case .saved: return "checkmark.circle.fill"; case .conflict: return "arrow.clockwise.circle"; case .confirmationRequired: return "questionmark.circle"; case .failed: return "exclamationmark.circle" }
    }
    private func resultColor(_ outcome: BotProfileEditor.Outcome) -> Color {
        switch outcome { case .saved: return .green; case .confirmationRequired: return .orange; case .conflict, .failed: return .red }
    }
    private func resultText(_ outcome: BotProfileEditor.Outcome) -> String {
        switch outcome {
        case .saved: return String(localized: "Saved")
        case .failed(let message): return message
        case .conflict: return String(localized: "This bot changed in Hermes Desktop. Reload its latest appearance before saving again.")
        case .confirmationRequired: return String(localized: "Needs Attention")
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { photoItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw BotProfileEditorImageError.unsupported }
                try editor.selectAvatar(data)
            } catch { imageError = error.localizedDescription }
        }
    }
}
