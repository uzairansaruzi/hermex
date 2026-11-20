import SwiftUI

struct ModelPickerSheet: View {
    let configuration: ModelPickerConfiguration
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    var favoriteModelKeys: [ModelFavoriteKey] = []
    var recentModelKeys: [ModelFavoriteKey] = []
    let isSelected: (ModelCatalogOption) -> Bool
    var loadStatus: ModelPickerLoadStatus = .loaded
    var inFlightKey: ModelFavoriteKey?
    var isCommittingCustom = false
    var isSelectionDisabled = false
    var errorMessage: String?
    var clearAction: ModelPickerClearAction?
    let onSelect: (ModelCatalogOption) -> Void
    var onCommitCustom: ((ModelCatalogOption) -> Void)?
    var onToggleFavorite: (ModelCatalogOption) -> Void = { _ in }
    var onDeleteSavedCustom: (ModelCatalogOption) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.defaultMinListRowHeight) private var systemMinRowHeight
    @State private var searchText = ""
    @State private var customModelID = ""
    @State private var customProviderID = ""
    @State private var sectionExpansion = ComposerModelPickerSectionExpansionState()
    @State private var overflowExpansion = ModelPickerOverflowExpansionState()

    private let currentCustomGroupID = "current-custom-model"
    private let savedCustomGroupID = "saved-custom-models"

    var body: some View {
        let groups = filteredModelGroups

        NavigationStack {
            AppList(rows: .plain) {
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: rowContentMinHeight(verticalInsets: 8), alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                if let clearAction, trimmedSearchQuery.isEmpty {
                    clearSelectionRow(clearAction)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                ForEach(groups) { group in
                    modelGroupDisclosure(group)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                customModelEntry
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)

                statusPlaceholder(groups: groups)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .themedPageBackground()
            .navigationTitle(configuration.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: configuration.searchPrompt
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
                ToolbarItem(placement: configuration.dismissPlacement) {
                    Button(configuration.dismissTitle) {
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

    private func rowContentMinHeight(verticalInsets: CGFloat) -> CGFloat {
        max(0, systemMinRowHeight - verticalInsets)
    }

    @ViewBuilder
    private func statusPlaceholder(groups: [ModelCatalogGroup]) -> some View {
        if modelGroups.isEmpty, loadStatus == .loading {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading models...")
            }
        } else if modelGroups.isEmpty, case .failed(let message) = loadStatus {
            ContentUnavailableView {
                Label("Could Not Load Models", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            }
        } else if groups.isEmpty, !trimmedSearchQuery.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private func clearSelectionRow(_ clearAction: ModelPickerClearAction) -> some View {
        Button {
            clearAction.action()
            if configuration.dismissesOnCommit {
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Text(clearAction.title)
                    .font(AppFont.body())
                    .lineLimit(2)

                Spacer(minLength: 0)

                if clearAction.isSelected {
                    Image(systemName: "checkmark")
                        .font(AppFont.body(weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSelectionDisabled)
        .pickerSelectionPill(isSelected: clearAction.isSelected)
        .accessibilityAddTraits(clearAction.isSelected ? .isSelected : [])
    }

    private var customModelEntry: some View {
        DisclosureGroup {
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
                                .font(AppFont.footnote(weight: .semibold))
                                .foregroundStyle(.appSecondary)
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
                        commitCustom(customOption)
                    } label: {
                        HStack {
                            if isCommittingCustom {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(customEntryForeground)
                            } else {
                                Label(configuration.customActionTitle, systemImage: "plus")
                                    .font(AppFont.body(weight: .semibold))
                            }

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if configuration.showsCustomFavoriteStar {
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
                }
                .foregroundStyle(customEntryForeground)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
                .background(
                    customOption == nil ? Color.clear : Color(.appText),
                    in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
                )
                .disabled(customOption == nil || isSelectionDisabled)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        } label: {
            Text("Custom Model")
                .frame(minHeight: rowContentMinHeight(verticalInsets: 24), alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var customEntryForeground: Color {
        customOption == nil ? Color(.appTextTertiary) : Color(.appCanvas)
    }

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
                .font(AppFont.body())
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(starColor(isFavorite: isFavorite, isInverted: isInverted, isEnabled: isEnabled))
        .accessibilityLabel(isFavorite ? removeLabel : addLabel)
    }

    private func starColor(isFavorite: Bool, isInverted: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return Color(.appTextTertiary) }
        if isInverted { return Color(.appCanvas) }
        return isFavorite ? Color(.appText) : Color(.appTextTertiary)
    }

    private func modelGroupDisclosure(_ group: ModelCatalogGroup) -> some View {
        let displayedModels = overflowExpansion.displayedModels(in: group)
        let totalModelCount = group.allModels.count
        let allowsDelete = group.id == savedCustomGroupID
        let showsOverflowToggle = shouldShowOverflowToggle(for: group)
        let lastModel = displayedModels.last

        return DisclosureGroup(
            isExpanded: Binding(
                get: { sectionExpansion.isExpanded(groupID: group.id) },
                set: { isExpanded in
                    sectionExpansion.setExpanded(isExpanded, groupID: group.id)
                }
            )
        ) {
            groupDivider
                .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 1, trailing: 12))

            ForEach(displayedModels, id: \.self) { option in
                let endsGroup = option == lastModel && !showsOverflowToggle
                modelOptionRow(option, allowsDelete: allowsDelete)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: endsGroup ? 5 : 1, trailing: 12))
                    .listRowSeparator(.hidden)
            }

            if showsOverflowToggle {
                groupDivider
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 1, trailing: 12))

                overflowToggle(for: group)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 5, trailing: 12))
                    .listRowSeparator(.hidden)
            }
        } label: {
            HStack(spacing: 8) {
                if ProviderGlyphKind.resolve(providerID: group.providerID) != nil {
                    ProviderGlyph(providerID: group.providerID)
                        .frame(width: 17, height: 17)
                }

                Text(group.name)
                    .font(AppFont.fixed(size: 14, weight: .semibold))
                    .foregroundStyle(.appPrimary)
                    .lineLimit(1)
                    .textCase(.uppercase)

                Text(
                    totalModelCount > group.models.count
                        ? "\(displayedModels.count) / \(totalModelCount)"
                        : "\(displayedModels.count)"
                )
                    .font(AppFont.fixed(size: 12, weight: .medium))
                    .foregroundStyle(.appSecondary)
                    .accessibilityLabel(
                        Text("Showing \(displayedModels.count) of \(totalModelCount) models")
                    )

                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .frame(minHeight: rowContentMinHeight(verticalInsets: 10))
            .contentShape(Rectangle())
        }
        .tint(Color(.appTextSecondary))
    }

    private var groupDivider: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.leading, 10)
        }
        .listRowSeparator(.hidden)
    }

    private func shouldShowOverflowToggle(for group: ModelCatalogGroup) -> Bool {
        trimmedSearchQuery.isEmpty && !group.extraModels.isEmpty
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
                    .font(AppFont.fixed(size: 13, weight: .semibold))

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

    @ViewBuilder
    private func modelOptionRow(_ option: ModelCatalogOption, allowsDelete: Bool) -> some View {
        let row = modelOptionRowContent(option)

        if configuration.showsModelFavoriteStars || allowsDelete {
            row.contextMenu {
                if configuration.showsModelFavoriteStars {
                    Button {
                        onToggleFavorite(option)
                    } label: {
                        Label(
                            isFavorite(option) ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: isFavorite(option) ? "star.slash" : "star"
                        )
                    }
                }

                if allowsDelete {
                    Button(role: .destructive) {
                        onDeleteSavedCustom(option)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } else {
            row
        }
    }

    private func modelOptionRowContent(_ option: ModelCatalogOption) -> some View {
        let selected = isSelected(option)
        let inFlight = Self.isInFlight(option, inFlightKey: inFlightKey)
        let displayLabel = ModelDisplayNames.displayLabel(for: option.id, displayName: option.displayName)
        let showsID = displayLabel.caseInsensitiveCompare(option.id) != .orderedSame

        return HStack(spacing: 12) {
            Button {
                commit(option)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: displayLabel)
                            .font(AppFont.body())
                            .lineLimit(2)
                        if showsID {
                            Text(verbatim: option.id)
                                .font(AppFont.caption())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)

                    if inFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(selected ? Color(.appCanvas) : Color(.appText))
                    } else if selected {
                        Image(systemName: "checkmark")
                            .font(AppFont.body(weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSelectionDisabled)
            .accessibilityLabel(Text(verbatim: displayLabel))
            .accessibilityValue(Text(verbatim: showsID ? option.id : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])

            if configuration.showsModelFavoriteStars {
                favoriteStar(
                    isFavorite: isFavorite(option),
                    isInverted: selected,
                    removeLabel: Text("Remove \(displayLabel) from favorites"),
                    addLabel: Text("Add \(displayLabel) to favorites")
                ) {
                    onToggleFavorite(option)
                }
            }
        }
        .pickerSelectionPill(isSelected: selected)
    }

    private func commit(_ option: ModelCatalogOption) {
        onSelect(option)
        if configuration.dismissesOnCommit {
            dismiss()
        }
    }

    private func commitCustom(_ option: ModelCatalogOption) {
        (onCommitCustom ?? onSelect)(option)
        if configuration.dismissesOnCommit {
            dismiss()
        }
    }

    static func isInFlight(_ option: ModelCatalogOption, inFlightKey: ModelFavoriteKey?) -> Bool {
        guard let inFlightKey else { return false }
        return option.favoriteKey == inFlightKey
    }

    private func isFavorite(_ option: ModelCatalogOption) -> Bool {
        favoriteModelKeys.contains(option.favoriteKey)
    }

    private var isCustomOptionFavorite: Bool {
        customOption.map(isFavorite) ?? false
    }

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredModelGroups: [ModelCatalogGroup] {
        customModelGroups + Self.filteredGroups(modelGroups, query: trimmedSearchQuery)
    }

    static func filteredGroups(_ groups: [ModelCatalogGroup], query: String) -> [ModelCatalogGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }

        return groups.compactMap { group in
            let groupMatches = group.name.localizedCaseInsensitiveContains(query)
            let filteredModels = group.allModels.filter { option in
                groupMatches || matches(option, query: query)
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

    private var customModelGroups: [ModelCatalogGroup] {
        var groups: [ModelCatalogGroup] = []
        let storedCustomOptions = storedCustomOptions

        if configuration.showsCurrentCustomModelGroup,
           let selectedCustomOption,
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
        guard configuration.showsSavedCustomModelGroup else { return [] }

        let catalogKeys = Set(modelGroups.flatMap(\.allModels).map(\.favoriteKey))
        let query = trimmedSearchQuery
        var seen = Set<ModelFavoriteKey>()
        var result: [ModelCatalogOption] = []

        func append(_ option: ModelCatalogOption?) {
            guard let option,
                  !catalogKeys.contains(option.favoriteKey),
                  seen.insert(option.favoriteKey).inserted,
                  query.isEmpty || Self.matches(option, query: query) else { return }
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
        Self.customOption(
            modelID: customModelID,
            providerID: customProviderID,
            configuration: configuration
        )
    }

    static func customOption(
        modelID: String,
        providerID: String,
        configuration: ModelPickerConfiguration
    ) -> ModelCatalogOption? {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedModelID.isEmpty else { return nil }
        guard !trimmedProviderID.isEmpty || !configuration.requiresCustomProviderID else { return nil }

        return ModelCatalogOption(
            id: trimmedModelID,
            displayName: trimmedModelID,
            providerID: trimmedProviderID.isEmpty ? nil : trimmedProviderID
        )
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

        let query = trimmedSearchQuery
        guard query.isEmpty || Self.matches(option, query: query) else { return nil }
        return option
    }

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
        guard configuration.requiresCustomProviderID else { return }
        guard customProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        customProviderID = selectedModelProviderID ?? providerChoices.first?.id ?? ""
    }

    private func expandPrimaryProviderSections() {
        for group in modelGroups {
            let isPrimary = ProviderGlyphKind.resolve(providerID: group.providerID)?.isPrimaryCatalog == true
            if isPrimary || group.allModels.contains(where: isSelected) {
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

    static func matches(_ option: ModelCatalogOption, query: String) -> Bool {
        option.displayName.localizedCaseInsensitiveContains(query)
            || option.id.localizedCaseInsensitiveContains(query)
            || (option.providerID?.localizedCaseInsensitiveContains(query) ?? false)
            || ModelDisplayNames
                .displayLabel(for: option.id, displayName: option.displayName)
                .localizedCaseInsensitiveContains(query)
    }
}

private struct ModelProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct CustomModelFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(AppFont.body())
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
            .background(
                Color(.appFillTertiary),
                in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
            )
    }
}

enum PickerRowMetrics {
    static let minHeight: CGFloat = 48
    static let cornerRadius: CGFloat = 12
}

extension View {
    func pickerSelectionPill(isSelected: Bool) -> some View {
        foregroundStyle(isSelected ? Color(.appCanvas) : Color(.appText))
            .padding(.horizontal, 12)
            .background(
                isSelected ? Color(.appText) : Color.clear,
                in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
            )
    }
}
