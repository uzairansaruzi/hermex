import SwiftUI

/// The model picker shared by the chat composer and Settings > Default Model.
///
/// The two surfaces differ only in a `ModelPickerConfiguration` preset and in
/// who owns the commit: the composer selects instantly, while Settings writes
/// to the server and drives `inFlightKey`, `isSelectionDisabled`, and
/// `errorMessage` from that request.
struct ModelPickerSheet: View {
    let configuration: ModelPickerConfiguration
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    var favoriteModelKeys: [ModelFavoriteKey] = []
    var recentModelKeys: [ModelFavoriteKey] = []
    /// The checkmark rule, supplied by the owner. Settings' rule resolves the
    /// server's `@provider:` prefix, its `activeProvider` fallback, and its
    /// in-flight projection; the composer's plain selection match must not
    /// inherit any of that.
    let isSelected: (ModelCatalogOption) -> Bool
    /// Catalog load state, for surfaces that load inside the sheet.
    var loadStatus: ModelPickerLoadStatus = .loaded
    /// The row showing a spinner in place of its checkmark, identified by the
    /// `(modelID, providerID)` pair so two providers spelling a model the same
    /// way cannot both spin.
    var inFlightKey: ModelFavoriteKey?
    /// Spinner inside the custom entry's commit button.
    var isCommittingCustom = false
    var isSelectionDisabled = false
    /// A failed commit, rendered at the top of the list. This is the save
    /// error; a failed catalog *load* travels in `loadStatus`.
    var errorMessage: String?
    let onSelect: (ModelCatalogOption) -> Void
    /// Commit for the custom entry, when it differs from picking a catalog row.
    /// Defaults to `onSelect`.
    var onCommitCustom: ((ModelCatalogOption) -> Void)?
    var onToggleFavorite: (ModelCatalogOption) -> Void = { _ in }
    var onDeleteSavedCustom: (ModelCatalogOption) -> Void = { _ in }

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
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                ForEach(filteredModelGroups) { group in
                    modelGroupDisclosure(group)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                customModelEntry
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)

                statusPlaceholder
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle(configuration.navigationTitle)
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
                // Settings loads its catalog while the sheet is already on
                // screen, so the first pass above ran against an empty list.
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

    /// Loading and load-failure states for surfaces that load inside the sheet,
    /// and the search-empty state for everyone. All three only stand in for an
    /// empty group list, so a stale catalog keeps rendering during a refresh.
    @ViewBuilder
    private var statusPlaceholder: some View {
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
        } else if filteredModelGroups.isEmpty, !trimmedSearchQuery.isEmpty {
            ContentUnavailableView.search(text: searchText)
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
                        commitCustom(customOption)
                    } label: {
                        HStack {
                            if isCommittingCustom {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(customEntryForeground)
                            } else {
                                Label(configuration.customActionTitle, systemImage: "plus")
                                    .font(.body.weight(.semibold))
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
                    customOption == nil ? Color.clear : Color.primary,
                    in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
                )
                .disabled(customOption == nil || isSelectionDisabled)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 2)
    }

    private var customEntryForeground: Color {
        customOption == nil ? Color(.tertiaryLabel) : Color(.systemBackground)
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
        let inFlight = Self.isInFlight(option, inFlightKey: inFlightKey)

        return HStack(spacing: 12) {
            Button {
                commit(option)
            } label: {
                HStack(spacing: 12) {
                    Text(option.displayName)
                        .font(.body)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    if inFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(selected ? Color(.systemBackground) : Color.primary)
                    } else if selected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSelectionDisabled)
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
        .pickerSelectionPill(isSelected: selected)
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

    /// Whether this row shows the spinner for an in-flight commit.
    ///
    /// Both the id and the provider recorded at tap time must agree: after the
    /// live overlay replaces the active provider's prefixed cached row with a
    /// bare id, two providers can offer the same spelling, and ticking by id
    /// alone would spin both rows.
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

    /// `groups` narrowed to `query`.
    ///
    /// A group whose display name matches keeps all of its models, so a
    /// provider stays findable by the name the picker actually shows it under:
    /// the id is spelled `openai-codex` where the header reads "OpenAI Codex",
    /// and matching only ids would answer "no models" to the visible name.
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
        guard configuration.showsCustomModelGroups else { return [] }

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

    /// The option the custom entry would commit, or nil while it is incomplete.
    ///
    /// `.composer` needs both halves, because a model selected mid-session is
    /// always addressed by provider. `.serverDefault` commits a bare model id
    /// with no provider, which is what Settings has always sent.
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

    /// Only the composer prefills the provider field. Prefilling it for the
    /// server default would quietly turn every "bare model id" save into a
    /// provider-scoped one.
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
    }
}

private struct ModelProviderChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Field chrome for the custom-model entry, matching the model rows' geometry.
private struct CustomModelFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
            .background(
                Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
            )
    }
}

/// Row geometry shared by every picker row in Settings, so Default Model and
/// Default Profile stay visually identical: the model rows and custom entry
/// here, and the profile rows in `DefaultProfilePickerView`.
enum PickerRowMetrics {
    static let minHeight: CGFloat = 48
    static let cornerRadius: CGFloat = 12
}

extension View {
    /// The selected-row treatment shared by the model rows and the profile
    /// rows: a filled `Color.primary` pill with the inverted foreground that
    /// fill needs. The caller owns the row's frame, because the pill can wrap
    /// content that sits outside the row's own button — the model rows'
    /// favorite star does.
    func pickerSelectionPill(isSelected: Bool) -> some View {
        foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
            .padding(.horizontal, 12)
            .background(
                isSelected ? Color.primary : Color.clear,
                in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
            )
    }
}
