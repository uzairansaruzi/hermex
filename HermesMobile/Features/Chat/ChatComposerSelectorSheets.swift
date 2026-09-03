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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var customModelID = ""
    @State private var customProviderID = ""
    @State private var sectionExpansion = ComposerModelPickerSectionExpansionState()
    @State private var overflowExpansion = ModelPickerOverflowExpansionState()

    private let currentCustomGroupID = "current-custom-model"
    private let savedCustomGroupID = "saved-custom-models"

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredModelGroups) { group in
                    modelGroupDisclosure(group)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                customModelEntry
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)

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
                expandPrimaryProviderSections()
                sectionExpansion.updateSearchText(searchText)
            }
            .onChange(of: modelGroups) {
                expandPrimaryProviderSections()
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
        .adaptiveFormPresentation()
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    /// Custom entry uses the same type scale and row geometry as the model
    /// rows above it (body text, 48pt rows, 12pt radius) so it reads as part
    /// of the same list rather than a separate form.
    private var customModelEntry: some View {
        DisclosureGroup("Custom Model") {
            VStack(spacing: 6) {
                TextField("Exact model ID", text: $customModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .modifier(CustomModelFieldStyle())

                HStack(spacing: 8) {
                    TextField("Provider ID", text: $customProviderID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !providerChoices.isEmpty {
                        Menu {
                            ForEach(providerChoices) { provider in
                                Button(provider.name) {
                                    customProviderID = provider.id
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Choose provider ID")
                    }
                }
                .modifier(CustomModelFieldStyle())

                HStack(spacing: 12) {
                    Button {
                        guard let customOption else { return }
                        selectAndDismiss(customOption)
                    } label: {
                        HStack {
                            Label("Use Custom", systemImage: "plus")
                                .font(.body.weight(.semibold))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    favoriteStar(
                        isFavorite: isCustomOptionFavorite,
                        isInverted: customOption != nil,
                        isEnabled: customOption != nil,
                        removeLabel: Text("Remove custom model from favorites"),
                        addLabel: Text("Add custom model to favorites")
                    ) {
                        guard let customOption else { return }
                        onToggleFavorite(customOption)
                    }
                }
                .foregroundStyle(customOption == nil ? Color(.tertiaryLabel) : Color(.systemBackground))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(
                    customOption == nil ? Color.clear : Color.primary,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .disabled(customOption == nil)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 2)
    }

    /// Trailing star shared by model rows and the custom entry. Monochrome:
    /// it follows the row's foreground instead of the system yellow.
    private func favoriteStar(
        isFavorite: Bool,
        isInverted: Bool,
        isEnabled: Bool = true,
        removeLabel: Text,
        addLabel: Text,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.body)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(starColor(isFavorite: isFavorite, isInverted: isInverted, isEnabled: isEnabled))
        .accessibilityLabel(isFavorite ? removeLabel : addLabel)
    }

    private func starColor(isFavorite: Bool, isInverted: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return Color(.tertiaryLabel) }
        if isInverted { return Color(.systemBackground) }
        return isFavorite ? Color.primary : Color(.tertiaryLabel)
    }

    private func modelGroupDisclosure(_ group: ModelCatalogGroup) -> some View {
        let displayedModels = overflowExpansion.displayedModels(in: group)
        let totalModelCount = group.allModels.count

        return DisclosureGroup(
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
                    ForEach(displayedModels, id: \.self) { option in
                        modelOptionRow(option, allowsDelete: group.id == savedCustomGroupID)
                    }
                }

                if shouldShowOverflowToggle(for: group) {
                    Divider()
                        .padding(.leading, 10)

                    overflowToggle(for: group)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                if ProviderGlyphKind.resolve(providerID: group.providerID) != nil {
                    ProviderGlyph(providerID: group.providerID)
                        .frame(width: 17, height: 17)
                }

                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .textCase(.uppercase)

                Text(
                    totalModelCount > group.models.count
                        ? "\(displayedModels.count) / \(totalModelCount)"
                        : "\(displayedModels.count)"
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        Text("Showing \(displayedModels.count) of \(totalModelCount) models")
                    )

                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .tint(Color(.secondaryLabel))
    }

    private func shouldShowOverflowToggle(for group: ModelCatalogGroup) -> Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !group.extraModels.isEmpty
    }

    private func overflowToggle(for group: ModelCatalogGroup) -> some View {
        let isExpanded = overflowExpansion.isExpanded(groupID: group.id)

        return Button {
            overflowExpansion.setExpanded(!isExpanded, groupID: group.id)
        } label: {
            HStack(spacing: 8) {
                Text(
                    isExpanded
                        ? String(localized: "Show fewer models")
                        : String(localized: "Show all models")
                )
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .padding(.leading, 28)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelOptionRow(_ option: ModelCatalogOption, allowsDelete: Bool) -> some View {
        let selected = isSelected(option)

        return HStack(spacing: 12) {
            Button {
                selectAndDismiss(option)
            } label: {
                HStack(spacing: 12) {
                    Text(option.displayName)
                        .font(.body)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    if selected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: option.displayName))
            .accessibilityAddTraits(selected ? .isSelected : [])

            favoriteStar(
                isFavorite: isFavorite(option),
                isInverted: selected,
                removeLabel: Text("Remove \(option.displayName) from favorites"),
                addLabel: Text("Add \(option.displayName) to favorites")
            ) {
                onToggleFavorite(option)
            }
        }
        .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
        .padding(.horizontal, 12)
        .background(
            selected ? Color.primary : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contextMenu {
            Button {
                onToggleFavorite(option)
            } label: {
                Label(
                    isFavorite(option) ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite(option) ? "star.slash" : "star"
                )
            }

            if allowsDelete {
                Button(role: .destructive) {
                    onDeleteSavedCustom(option)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func selectAndDismiss(_ option: ModelCatalogOption) {
        onSelect(option)
        dismiss()
    }

    private func isFavorite(_ option: ModelCatalogOption) -> Bool {
        favoriteModelKeys.contains(option.favoriteKey)
    }

    private var isCustomOptionFavorite: Bool {
        customOption.map(isFavorite) ?? false
    }

    private func isSelected(_ option: ModelCatalogOption) -> Bool {
        option.matchesSelection(
            modelID: selectedModelID,
            providerID: selectedModelProviderID
        )
    }

    private var filteredModelGroups: [ModelCatalogGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseGroups: [ModelCatalogGroup]

        if query.isEmpty {
            baseGroups = modelGroups
        } else {
            baseGroups = modelGroups.compactMap { group in
                let filteredModels = group.allModels.filter { option in
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
        let catalogKeys = Set(modelGroups.flatMap(\.allModels).map(\.favoriteKey))
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
        guard let option = selectedModelOption else { return nil }
        let isRendered = Self.isRenderedByCurrentPicker(
            option: option,
            modelGroups: modelGroups,
            searchQuery: searchText,
            overflowExpansion: overflowExpansion
        )
        guard !isRendered else { return nil }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || matches(option, query: query) else { return nil }
        return option
    }

    /// Whether `option` is already represented by a rendered picker row under
    /// the current query. Empty query renders the server's visible slice plus
    /// any provider groups the user expanded; searching renders `allModels`.
    /// Classifying every empty-query group against the full catalog would hide
    /// the "Current Custom" row for an overflow selection that is still hidden.
    static func isRenderedByCurrentPicker(
        option: ModelCatalogOption,
        modelGroups: [ModelCatalogGroup],
        searchQuery: String,
        overflowExpansion: ModelPickerOverflowExpansionState = .init()
    ) -> Bool {
        let renderedOptions: [ModelCatalogOption]
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            renderedOptions = modelGroups.flatMap { overflowExpansion.displayedModels(in: $0) }
        } else {
            renderedOptions = modelGroups.flatMap(\.allModels)
        }
        return renderedOptions.firstMatchingSelection(
            modelID: option.id,
            providerID: option.providerID
        ) != nil
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

    private func expandPrimaryProviderSections() {
        for group in modelGroups {
            let isPrimary = ProviderGlyphKind.resolve(providerID: group.providerID)?.isPrimaryCatalog == true
            let containsSelection = group.allModels.firstMatchingSelection(
                modelID: selectedModelID,
                providerID: selectedModelProviderID
            ) != nil
            if isPrimary || containsSelection {
                sectionExpansion.setExpanded(true, groupID: group.id)
            }
        }
    }

    private var selectedModelOption: ModelCatalogOption? {
        guard let selectedModelID, !selectedModelID.isEmpty else { return nil }
        return modelGroups.flatMap(\.allModels).firstMatchingSelection(
            modelID: selectedModelID,
            providerID: selectedModelProviderID
        ) ?? ModelCatalogOption(
            id: selectedModelID,
            displayName: selectedModelID,
            providerID: selectedModelProviderID
        )
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

/// Field chrome for the custom-model entry, matching the model rows' geometry.
private struct CustomModelFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
