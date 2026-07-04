import SwiftUI

struct ComposerModelPickerSheet: View {
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    let favoriteModelKeys: [ModelFavoriteKey]
    let recentModelKeys: [ModelFavoriteKey]
    let onSelect: (ModelCatalogOption) -> Void
    let onToggleFavorite: (ModelCatalogOption) -> Void
    let onDeleteSavedCustom: (ModelCatalogOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var customModelID = ""
    @State private var customProviderID = ""
    @State private var sectionExpansion = ComposerModelPickerSectionExpansionState()

    private let currentCustomGroupID = "current-custom-model"
    private let savedCustomGroupID = "saved-custom-models"

    var body: some View {
        NavigationStack {
            List {
                customModelEntry
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)

                ForEach(filteredModelGroups) { group in
                    modelGroupDisclosure(group)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                if filteredModelGroups.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search models"
            )
            .onAppear {
                initializeCustomProviderIfNeeded()
                sectionExpansion.updateSearchText(searchText)
            }
            .onChange(of: searchText) { _, newValue in
                sectionExpansion.updateSearchText(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var customModelEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 7) {
                TextField("Exact model ID", text: $customModelID)
                    .font(.system(size: 14, weight: .regular))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 8) {
                    TextField("Provider ID", text: $customProviderID)
                        .font(.system(size: 14, weight: .regular))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if !providerChoices.isEmpty {
                        Menu {
                            ForEach(providerChoices) { provider in
                                Button(provider.name) {
                                    customProviderID = provider.id
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .font(.system(size: 18, weight: .regular))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose provider ID")
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    guard let customOption else { return }
                    onSelect(customOption)
                    dismiss()
                } label: {
                    Label("Use Custom", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(customOption == nil)

                Button {
                    guard let customOption else { return }
                    onToggleFavorite(customOption)
                } label: {
                    Image(systemName: isCustomOptionFavorite ? "star.fill" : "star")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isCustomOptionFavorite ? Color.yellow : Color(.tertiaryLabel))
                .disabled(customOption == nil)
                .accessibilityLabel(isCustomOptionFavorite ? "Remove custom model from favorites" : "Add custom model to favorites")

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func modelGroupDisclosure(_ group: ModelCatalogGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { sectionExpansion.isExpanded(groupID: group.id) },
                set: { isExpanded in
                    sectionExpansion.setExpanded(isExpanded, groupID: group.id)
                }
            )
        ) {
            VStack(spacing: 1) {
                Divider()
                    .padding(.leading, 10)

                LazyVStack(spacing: 1) {
                    ForEach(group.models, id: \.self) { option in
                        modelOptionRow(option, allowsDelete: group.id == savedCustomGroupID)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(group.models.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .tint(Color(.secondaryLabel))
    }

    private func modelOptionRow(_ option: ModelCatalogOption, allowsDelete: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelect(option)
                dismiss()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isSelected(option) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(isSelected(option) ? Color.accentColor : Color(.tertiaryLabel))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.displayName)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if option.id != option.displayName {
                            Text(option.id)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if let providerID = option.providerID, !providerID.isEmpty {
                            Text(providerID)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onToggleFavorite(option)
            } label: {
                Image(systemName: isFavorite(option) ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isFavorite(option) ? Color.yellow : Color(.tertiaryLabel))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite(option) ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")

            if allowsDelete {
                Button {
                    onDeleteSavedCustom(option)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.red)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete saved custom model \(option.displayName)")
            }
        }
        .padding(.leading, 2)
        .padding(.vertical, 3)
    }

    private func isFavorite(_ option: ModelCatalogOption) -> Bool {
        favoriteModelKeys.contains(option.favoriteKey)
    }

    private var isCustomOptionFavorite: Bool {
        customOption.map(isFavorite) ?? false
    }

    private func isSelected(_ option: ModelCatalogOption) -> Bool {
        option.matchesSelection(modelID: selectedModelID, providerID: selectedModelProviderID)
    }

    private var filteredModelGroups: [ModelCatalogGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseGroups: [ModelCatalogGroup]

        if query.isEmpty {
            baseGroups = modelGroups
        } else {
            baseGroups = modelGroups.compactMap { group in
                let filteredModels = group.models.filter { option in
                    matches(option, query: query)
                }

                guard !filteredModels.isEmpty else { return nil }

                return ModelCatalogGroup(
                    id: group.id,
                    name: group.name,
                    providerID: group.providerID,
                    models: filteredModels
                )
            }
        }

        return customModelGroups + baseGroups
    }

    private var customModelGroups: [ModelCatalogGroup] {
        var groups: [ModelCatalogGroup] = []

        if let selectedCustomOption,
           !storedCustomOptions.contains(where: { $0.favoriteKey == selectedCustomOption.favoriteKey }) {
            groups.append(
                ModelCatalogGroup(
                    id: currentCustomGroupID,
                    name: String(localized: "Current Custom"),
                    providerID: nil,
                    models: [selectedCustomOption]
                )
            )
        }

        if !storedCustomOptions.isEmpty {
            groups.append(
                ModelCatalogGroup(
                    id: savedCustomGroupID,
                    name: String(localized: "Saved Custom"),
                    providerID: nil,
                    models: storedCustomOptions
                )
            )
        }

        return groups
    }

    private var storedCustomOptions: [ModelCatalogOption] {
        let catalogKeys = Set(modelGroups.flatMap(\.models).map(\.favoriteKey))
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<ModelFavoriteKey>()
        var result: [ModelCatalogOption] = []

        func append(_ option: ModelCatalogOption?) {
            guard let option,
                  !catalogKeys.contains(option.favoriteKey),
                  seen.insert(option.favoriteKey).inserted,
                  query.isEmpty || matches(option, query: query) else { return }
            result.append(option)
        }

        for option in ModelFavoritesStore.visibleFavoriteOptions(in: modelGroups, favoriteKeys: favoriteModelKeys) {
            append(option)
        }
        for option in ModelRecentsStore.visibleRecentOptions(
            in: modelGroups,
            recentKeys: recentModelKeys,
            favoriteKeys: favoriteModelKeys
        ) {
            append(option)
        }

        return result
    }

    private var customOption: ModelCatalogOption? {
        let modelID = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = customProviderID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !modelID.isEmpty, !providerID.isEmpty else { return nil }
        return ModelCatalogOption(id: modelID, displayName: modelID, providerID: providerID)
    }

    private var selectedCustomOption: ModelCatalogOption? {
        guard let selectedModelID, !selectedModelID.isEmpty else { return nil }
        let catalogOptions = modelGroups.flatMap(\.models)
        if catalogOptions.firstMatchingSelection(
            modelID: selectedModelID,
            providerID: selectedModelProviderID
        ) != nil {
            return nil
        }

        let option = ModelCatalogOption(
            id: selectedModelID,
            displayName: selectedModelID,
            providerID: selectedModelProviderID
        )
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || matches(option, query: query) else { return nil }
        return option
    }

    private var providerChoices: [ModelProviderChoice] {
        var seen = Set<String>()
        var result: [ModelProviderChoice] = []

        for group in modelGroups {
            guard let providerID = group.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !providerID.isEmpty,
                  seen.insert(providerID.lowercased()).inserted else { continue }
            result.append(ModelProviderChoice(id: providerID, name: group.name))
        }

        if let selectedModelProviderID = selectedModelProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedModelProviderID.isEmpty,
           seen.insert(selectedModelProviderID.lowercased()).inserted {
            result.insert(
                ModelProviderChoice(id: selectedModelProviderID, name: selectedModelProviderID),
                at: 0
            )
        }

        return result
    }

    private func initializeCustomProviderIfNeeded() {
        guard customProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        customProviderID = selectedModelProviderID ?? providerChoices.first?.id ?? ""
    }

    private func matches(_ option: ModelCatalogOption, query: String) -> Bool {
        option.displayName.localizedCaseInsensitiveContains(query)
            || option.id.localizedCaseInsensitiveContains(query)
            || (option.providerID?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

private struct ModelProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ComposerWorkspacePickerSheet: View {
    let workspaceRoots: [WorkspaceRoot]
    let selectedWorkspacePath: String?
    let suggestions: [String]
    /// Server base URL used to open the registry manager; nil hides the
    /// Manage affordance (e.g. offline cached mode).
    var managementServer: URL?
    let onLoadSuggestions: (String) async -> Void
    let onSelect: (String) async -> Void
    /// Called after the registry manager closes having changed the registry,
    /// so the owner can refetch `workspaceRoots`.
    var onRegistryChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var prefix = ""
    @State private var acceptedWorkspacePath: String?
    @State private var showsManagerSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Workspace path", text: $prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Suggestions are limited to trusted workspace roots from the server.")
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
                }
            }
        }
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
                    .foregroundStyle(path == effectiveSelectedWorkspacePath ? Color.accentColor : Color(.secondaryLabel))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name?.isEmpty == false ? name ?? path.lastPathComponentFallback : path.lastPathComponentFallback)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
