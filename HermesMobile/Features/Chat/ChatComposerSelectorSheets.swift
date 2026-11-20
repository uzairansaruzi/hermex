import SwiftUI

struct ChatSettingsSheet<WorkspacePicker: View, ProfileControl: View>: View {
    let workspaceTitle: String
    let isWorkspaceDisabled: Bool
    let profileNote: String?
    let contextSnapshot: ContextWindowSnapshot?
    @ViewBuilder let workspacePicker: () -> WorkspacePicker
    @ViewBuilder let profileControl: () -> ProfileControl

    @Environment(\.dismiss) private var dismiss
    @State private var showsWorkspacePicker = false

    var body: some View {
        NavigationStack {
            AppList {
                Button { showsWorkspacePicker = true } label: {
                    LabeledContent {
                        Text(workspaceTitle).lineLimit(1).truncationMode(.middle)
                    } label: {
                        Label("Workspace", systemImage: "folder")
                    }
                }
                .disabled(isWorkspaceDisabled)

                LabeledContent {
                    profileControl()
                } label: {
                    Label {
                        Text("Profile")
                        if let profileNote { Text(profileNote) }
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }

                LabeledContent {
                    ContextWindowIndicatorView(snapshot: contextSnapshot)
                } label: {
                    Label {
                        Text("Context")
                        if let contextSnapshot { Text(ContextWindowFormatter.tokensLabel(from: contextSnapshot)) }
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                    }
                }
            }
            .themedPageBackground()
            .navigationTitle("Chat settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsWorkspacePicker) { workspacePicker() }
        }
        .themedPageBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

enum ModelSettingsRow: Equatable {
    case model
    case thinking
    case fast
    case approvals
}

enum ModelSettingsRowStatus: Equatable {
    case failed(String)
    case notice(String)

    static func resolve(
        row: ModelSettingsRow,
        lastChanged: ModelSettingsRow?,
        isUpdating: Bool,
        errorMessage: String?,
        notice: String?
    ) -> Self? {
        guard row == lastChanged, !isUpdating else { return nil }
        if let errorMessage { return .failed(errorMessage) }
        if let notice { return .notice(notice) }
        return nil
    }
}

struct ModelSettingsSheet<AllModels: View>: View {
    let selection: ComposerModelEffortSelection
    let providerName: String?
    let favorites: [ModelCatalogOption]
    let recents: [ModelCatalogOption]
    let isDisabled: Bool
    let isUpdating: Bool
    let errorMessage: String?
    let notice: String?
    let fastMode: Bool?
    let mayChangeFastMode: Bool
    let approvals: ComposerApprovals?
    let onSelectModel: (ModelCatalogOption) -> Void
    let onSelectEffort: (String) async -> Bool
    let onSelectFastMode: (Bool) -> Void
    let onSetYolo: (Bool) -> Void
    let onSelectApprovalMode: (HermesApprovalMode) -> Void
    let allModelsPicker: (@escaping (ModelCatalogOption) -> Void) -> AllModels

    @Environment(\.dismiss) private var dismiss
    @State private var showsAllModels = false
    @State private var lastChanged: ModelSettingsRow?
    @State private var levelSender = ThinkingLevelSender()

    private var shownSelection: ComposerModelEffortSelection {
        levelSender.pendingLevel.map(selection.replacingEffort(with:)) ?? selection
    }

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    currentModelRow
                    if selection.showsEffortControl { thinkingRow }
                    if let fastMode { fastRow(isOn: fastMode) }
                    if let approvals { approvalsRow(approvals) }
                }

                if !favorites.isEmpty {
                    Section {
                        ForEach(favorites, id: \.self, content: modelRow)
                    } header: {
                        HStack {
                            Text("Favorites")
                            Spacer(minLength: 8)
                            Button("All models") { showsAllModels = true }
                                .font(AppFont.caption(weight: .semibold))
                                .textCase(nil)
                        }
                    }
                }

                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.self, content: modelRow)
                    }
                }
            }
            .themedPageBackground()
            .navigationTitle("Model settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsAllModels) { allModelsPicker(select) }
        }
        .themedPageBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var currentModelRow: some View {
        Button { showsAllModels = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    glyph(for: shownSelection.model)
                    Text(verbatim: ModelDisplayNames.displayLabel(
                        for: shownSelection.model.id,
                        displayName: shownSelection.model.displayName
                    ))
                        .foregroundStyle(.appPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.appTertiary)
                }
                Text(verbatim: [providerName, shownSelection.committedEffort == nil ? nil : shownSelection.effortTitle]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
                    .lineLimit(1)
                statusLine(for: .model)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("All models"))
    }

    @ViewBuilder
    private var thinkingRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let only = selection.staticEffort {
                LabeledContent("Thinking", value: only.title)
            } else {
                ThinkingControl(selection: shownSelection, isDisabled: isDisabled, isCovered: showsAllModels) { level in
                    guard !isUpdating || levelSender.isSending else { return }
                    lastChanged = .thinking
                    levelSender.request(level, send: onSelectEffort)
                }
                .allowsHitTesting(!isUpdating || levelSender.isSending)
            }
            statusLine(for: .thinking)
        }
    }

    private func fastRow(isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Fast", isOn: Binding(get: { isOn }, set: { enabled in
                lastChanged = .fast
                onSelectFastMode(enabled)
            }))
            .disabled(isDisabled || !(mayChangeFastMode || isUpdating))
            .allowsHitTesting(!isUpdating)
            statusLine(for: .fast)
        }
    }

    private func approvalsRow(_ approvals: ComposerApprovals) -> some View {
        NavigationLink {
            ApprovalChoicesView(
                approvals: approvals,
                isDisabled: isDisabled,
                status: approvalsStatus(approvals),
                onSetYolo: { enabled in
                    lastChanged = .approvals
                    onSetYolo(enabled)
                },
                onSelectMode: { mode in
                    lastChanged = .approvals
                    onSelectApprovalMode(mode)
                }
            )
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Approvals") {
                    if let value = approvals.value { Text(verbatim: value) }
                }
                ModelSettingsStatusLine(status: approvalsStatus(approvals))
            }
        }
    }

    private func approvalsStatus(_ approvals: ComposerApprovals) -> ModelSettingsRowStatus? {
        ModelSettingsRowStatus.resolve(
            row: .approvals, lastChanged: lastChanged, isUpdating: approvals.isChanging,
            errorMessage: approvals.errorMessage, notice: nil
        )
    }

    private func isCurrent(_ option: ModelCatalogOption) -> Bool {
        option.matchesSelection(modelID: selection.model.id, providerID: selection.modelProviderID)
    }

    private func modelRow(_ option: ModelCatalogOption) -> some View {
        let isCurrent = isCurrent(option)
        return Button { select(option) } label: {
            HStack(spacing: 10) {
                glyph(for: option)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: ModelDisplayNames.displayLabel(for: option.id, displayName: option.displayName))
                        .foregroundStyle(.appPrimary)
                        .lineLimit(1)
                    Text(verbatim: option.id)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(AppFont.body(weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .allowsHitTesting(!isUpdating)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private func glyph(for option: ModelCatalogOption) -> some View {
        if ProviderGlyphKind.resolve(providerID: option.providerID ?? option.id.modelIDProviderPrefix) != nil {
            ProviderGlyph(providerID: option.providerID ?? option.id.modelIDProviderPrefix)
                .frame(width: 17, height: 17)
        }
    }

    private func select(_ option: ModelCatalogOption) {
        guard !isCurrent(option) else { return }
        lastChanged = .model
        onSelectModel(option)
    }

    private func statusLine(for row: ModelSettingsRow) -> some View {
        ModelSettingsStatusLine(status: ModelSettingsRowStatus.resolve(
            row: row, lastChanged: lastChanged, isUpdating: isUpdating, errorMessage: errorMessage, notice: notice
        ))
    }
}

private struct ModelSettingsStatusLine: View {
    let status: ModelSettingsRowStatus?

    var body: some View {
        switch status {
        case .failed(let message):
            Text(verbatim: message).font(AppFont.caption()).foregroundStyle(.red)
        case .notice(let message):
            Text(verbatim: message).font(AppFont.caption()).foregroundStyle(.appSecondary)
        case nil:
            EmptyView()
        }
    }
}

private struct ApprovalChoicesView: View {
    let approvals: ComposerApprovals
    let isDisabled: Bool
    let status: ModelSettingsRowStatus?
    let onSetYolo: (Bool) -> Void
    let onSelectMode: (HermesApprovalMode) -> Void

    @State private var confirmsOff = false

    var body: some View {
        AppList {
            Section {
                Toggle(isOn: Binding(get: { approvals.isYoloOn }, set: onSetYolo)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "YOLO")
                        Text("This chat runs commands without asking")
                            .font(AppFont.caption())
                            .foregroundStyle(.appSecondary)
                    }
                }
                .disabled((isDisabled && !approvals.canTurnOffYolo) || approvals.isChanging || approvals.isYoloLocked)
            } appFooter: {
                if approvals.isYoloLocked {
                    Text("The host runs without approval prompts, so this chat can't turn YOLO off.")
                }
            }

            if approvals.offersModes {
                Section("All chats in this Profile") {
                    modeRow(.smart, description: "Automatically assess actions and ask when needed")
                    modeRow(.manual, description: "Ask before actions that require approval")
                    modeRow(.off, description: "Run without approval prompts")
                        .confirmationDialog("Turn off approval prompts?", isPresented: $confirmsOff, titleVisibility: .visible) {
                            Button("Turn Off Approvals", role: .destructive) { onSelectMode(.off) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Every chat in this Profile will run commands without asking.")
                        }
                }
            }

            if status != nil {
                ModelSettingsStatusLine(status: status)
            }
        }
        .themedPageBackground()
        .navigationTitle("Approvals")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modeRow(_ mode: HermesApprovalMode, description: LocalizedStringKey) -> some View {
        let isCurrent = approvals.mode == mode.rawValue
        return Button {
            guard !isCurrent else { return }
            if mode == .off { confirmsOff = true } else { onSelectMode(mode) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ComposerApprovals.title(for: mode)).foregroundStyle(.appPrimary)
                    Text(description).font(AppFont.caption()).foregroundStyle(.appSecondary)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(AppFont.body(weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || approvals.isChanging)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

struct ComposerWorkspacePickerSheet: View {
    var allowsCustomPath = false
    let workspaceRoots: [WorkspaceRoot]
    let selectedWorkspacePath: String?
    let suggestions: [String]
    var managementServer: URL?
    let onLoadSuggestions: (String) async -> Void
    let onSelect: (String) async -> Void
    var onRegistryChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var prefix = ""
    @State private var acceptedWorkspacePath: String?
    @State private var showsManagerSheet = false

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    TextField("Workspace path", text: $prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } appFooter: {
                    if allowsCustomPath {
                        Text("Change the working directory for this chat. The host must accept the path before it changes.")
                    } else {
                        Text("Suggestions are limited to trusted workspace roots from the server.")
                    }
                }

                if allowsCustomPath, !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section { workspaceButton(path: prefix.trimmingCharacters(in: .whitespacesAndNewlines), name: nil) }
                }

                if let effectiveSelectedWorkspacePath, !effectiveSelectedWorkspacePath.isEmpty {
                    Section("Current") {
                        workspaceButton(path: effectiveSelectedWorkspacePath, name: String(localized: "Current Workspace"))
                    }
                }

                if !savedWorkspaceRows.isEmpty {
                    Section("Saved Workspaces") {
                        ForEach(savedWorkspaceRows) { row in
                            workspaceButton(path: row.path, name: row.name)
                        }
                    }
                }

                if !suggestionRows.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestionRows, id: \.self) { path in
                            workspaceButton(path: path, name: nil)
                        }
                    }
                }

                if savedWorkspaceRows.isEmpty && suggestionRows.isEmpty {
                    ContentUnavailableView {
                        Label("No Workspaces", systemImage: "folder")
                    } description: {
                        Text("Try typing a path under your home folder or an existing workspace root.")
                    }
                }
            }
            .themedPageBackground()
            .navigationTitle("Choose Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if managementServer != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Manage") {
                            showsManagerSheet = true
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task(id: prefix) {
                if !prefix.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                await onLoadSuggestions(prefix)
            }
            .sheet(isPresented: $showsManagerSheet) {
                if let managementServer {
                    WorkspaceManagerView(server: managementServer) {
                        await onRegistryChanged()
                    }
                    .adaptiveFormPresentation()
                }
            }
        }
        .adaptiveFormPresentation()
    }

    private func workspaceButton(path: String, name: String?) -> some View {
        Button {
            guard acceptedWorkspacePath == nil else { return }
            acceptedWorkspacePath = path
            dismiss()
            Task {
                await onSelect(path)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: path == effectiveSelectedWorkspacePath ? "checkmark.circle.fill" : "folder")
                    .foregroundStyle(path == effectiveSelectedWorkspacePath ? Color.accentColor : Color(.appTextSecondary))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name?.isEmpty == false ? name ?? path.lastPathComponentFallback : path.lastPathComponentFallback)
                        .font(AppFont.body())
                        .foregroundStyle(.appPrimary)

                    Text(path)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(acceptedWorkspacePath != nil)
    }

    private var savedWorkspaceRows: [WorkspacePickerRow] {
        workspaceRoots.compactMap { root in
            guard let path = root.path, !path.isEmpty else { return nil }
            return WorkspacePickerRow(path: path, name: root.name)
        }
        .deduplicated()
    }

    private var suggestionRows: [String] {
        let savedPaths = Set(savedWorkspaceRows.map(\.path))
        var seen = Set<String>()
        return suggestions.compactMap { path in
            guard !path.isEmpty,
                  !savedPaths.contains(path),
                  path != effectiveSelectedWorkspacePath,
                  seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private var effectiveSelectedWorkspacePath: String? {
        acceptedWorkspacePath ?? selectedWorkspacePath
    }
}

private struct WorkspacePickerRow: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String?
}

private extension Array where Element == WorkspacePickerRow {
    func deduplicated() -> [WorkspacePickerRow] {
        var seen = Set<String>()
        return filter { seen.insert($0.path).inserted }
    }
}

extension String {
    var lastPathComponentFallback: String {
        let component = (self as NSString).lastPathComponent
        return component.isEmpty ? self : component
    }
}
