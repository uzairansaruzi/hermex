import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import ImageIO
import CoreTransferable

#if DEBUG
/// Signed-simulator visual QA host for the production model picker. It fetches
/// the same live catalog as the app and presents the real sheet over the app's
/// canvas; no screenshot-only replica is involved.
struct ModelPickerCaptureHost: View {
    @State private var fixture: ModelPickerCaptureFixture?
    @State private var favoriteModelKeys: [ModelFavoriteKey] = []
    @State private var recentModelKeys: [ModelFavoriteKey] = []
    @State private var favoriteProviderIDs: [String] = []

    var body: some View {
        ChatPalette.appChrome(colorScheme: colorScheme).chatBackground
            .ignoresSafeArea()
            .sheet(item: $fixture) { fixture in
                ComposerModelPickerSheet(
                    modelGroups: fixture.modelGroups,
                    selectedModelID: fixture.selectedModelID,
                    selectedModelProviderID: fixture.selectedProviderID,
                    favoriteModelKeys: favoriteModelKeys,
                    recentModelKeys: recentModelKeys,
                    favoriteProviderIDs: favoriteProviderIDs,
                    onSelect: { option in
                        self.fixture = ModelPickerCaptureFixture(
                            modelGroups: fixture.modelGroups,
                            selectedModelID: option.id,
                            selectedProviderID: option.providerID
                        )
                    },
                    onToggleFavorite: { option in
                        if let index = favoriteModelKeys.firstIndex(of: option.favoriteKey) {
                            favoriteModelKeys.remove(at: index)
                        } else {
                            favoriteModelKeys.append(option.favoriteKey)
                        }
                    },
                    onToggleProviderFavorite: { providerID in
                        if let index = favoriteProviderIDs.firstIndex(of: providerID) {
                            favoriteProviderIDs.remove(at: index)
                        } else {
                            favoriteProviderIDs.append(providerID)
                        }
                    },
                    onDeleteSavedCustom: { option in
                        favoriteModelKeys.removeAll { $0 == option.favoriteKey }
                        recentModelKeys.removeAll { $0 == option.favoriteKey }
                    }
                )
                .presentationDetents([.fraction(0.84), .large])
                .presentationDragIndicator(.visible)
            }
            .task {
                await loadCatalog()
            }
    }

    @Environment(\.colorScheme) private var colorScheme

    private func loadCatalog() async {
        if ProcessInfo.processInfo.arguments.contains("--model-picker-fixture") {
            let codex = ModelCatalogOption(
                id: "gpt-5.5-codex",
                displayName: "GPT-5.5 Codex",
                providerID: "openai-codex"
            )
            fixture = ModelPickerCaptureFixture(
                modelGroups: [
                    ModelCatalogGroup(id: "openai-codex", name: "openai-codex", providerID: "openai-codex", models: [codex]),
                    ModelCatalogGroup(id: "fireworks", name: "fireworks", providerID: "fireworks", models: [
                        ModelCatalogOption(id: "accounts/fireworks/models/qwen3-coder", displayName: "Qwen3 Coder", providerID: "fireworks")
                    ]),
                    ModelCatalogGroup(id: "custom", name: "custom-private-provider", providerID: "custom-private-provider", models: [
                        ModelCatalogOption(id: "local-model", displayName: "Local Model", providerID: "custom-private-provider")
                    ])
                ],
                selectedModelID: codex.id,
                selectedProviderID: codex.providerID
            )
            return
        }
        guard let serverURL else { return }
        guard let response = try? await APIClient(baseURL: serverURL).models() else { return }
        let groups = response.catalogGroups
        let selected = groups.flatMap(\.models).first
        fixture = ModelPickerCaptureFixture(
            modelGroups: groups,
            selectedModelID: selected?.id,
            selectedProviderID: selected?.providerID
        )
    }

    private var serverURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--model-picker-server"),
              arguments.index(after: index) < arguments.endIndex
        else { return nil }
        return URL(string: arguments[arguments.index(after: index)])
    }
}

private struct ModelPickerCaptureFixture: Identifiable {
    let id = UUID()
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedProviderID: String?
}
#endif

struct ComposerModelPickerSheet: View {
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    let favoriteModelKeys: [ModelFavoriteKey]
    let recentModelKeys: [ModelFavoriteKey]
    let favoriteProviderIDs: [String]
    let onSelect: (ModelCatalogOption) -> Void
    let onToggleFavorite: (ModelCatalogOption) -> Void
    let onToggleProviderFavorite: (String) -> Void
    let onDeleteSavedCustom: (ModelCatalogOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @State private var searchText = ""
    @State private var selectedView = ModelPickerViewMode.all
    @State private var providerScopeByView: [ModelPickerViewMode: String] = [:]
    @State private var editedProvider: ModelPickerProvider?
    @State private var showsCustomModelEntry = false
    @State private var presentationRevision = 0
    @State private var didInitializeScope = false
    private let appearanceStore = ProviderAppearanceStore.shared
    private let allProvidersScope = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Model view", selection: $selectedView) {
                    ForEach(ModelPickerViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .accessibilityIdentifier(ModelPickerAccessibilityID.viewPicker)

                providerSection
                resultHeader
                modelResults
                addCustomModelButton
            }
            .appSurfaceBackground(.canvas)
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search providers & models"
            )
            .onAppear { initializeProviderScopesIfNeeded() }
            .onChange(of: displayedProviders.map(\.providerID)) { _, providerIDs in
                reconcileProviderScope(for: selectedView, validProviderIDs: Set(providerIDs))
            }
            .onChange(of: selectedView) { _, mode in
                reconcileProviderScope(for: mode, validProviderIDs: Set(displayedProviders.map(\.providerID)))
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .adaptiveFormPresentation()
        .sheet(item: $editedProvider) { provider in
            ProviderAppearanceEditor(
                provider: provider,
                serverScopeID: serverScopeID,
                store: appearanceStore,
                onChange: { presentationRevision += 1 }
            )
            .presentationDetents([.fraction(0.78), .large])
        }
        .sheet(isPresented: $showsCustomModelEntry) {
            CustomModelEntrySheet(
                providers: providers,
                initialProviderID: selectedProviderScope.isEmpty ? selectedModelProviderID : selectedProviderScope,
                favoriteModelKeys: favoriteModelKeys,
                onUse: { option in
                    onSelect(option)
                    dismiss()
                },
                onToggleFavorite: onToggleFavorite
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Providers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 18)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        providerCard(ModelPickerProvider(
                            providerID: allProvidersScope,
                            catalogName: String(localized: "All Providers"),
                            modelCount: viewOptions.count
                        ))

                        ForEach(displayedProviders) { provider in
                            providerCard(provider)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .background(HorizontalScrollAxisGuard())
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onAppear { scrollSelectedProviderIntoView(using: proxy, animated: false) }
                .onChange(of: selectedProviderScope) { _, _ in
                    scrollSelectedProviderIntoView(using: proxy, animated: true)
                }
            }
        }
    }

    private func providerCard(_ provider: ModelPickerProvider) -> some View {
        let isAllProviders = provider.providerID == allProvidersScope
        let isSelected = provider.providerID == selectedProviderScope
        let displayName = isAllProviders ? provider.catalogName : providerDisplayName(provider)

        return Button {
            providerScopeByView[selectedView] = provider.providerID
        } label: {
            providerCardContent(provider, displayName: displayName, isAllProviders: isAllProviders, isSelected: isSelected)
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 188 : 102)
            .appSurfaceBackground(
                isSelected ? .inset : .surface,
                opacity: isSelected ? 0.76 : 0.84,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        isSelected ? pickerAccent.opacity(0.34) : Color.primary.opacity(0.055),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(pickerAccentForeground)
                        .frame(width: 19, height: 19)
                        .background(pickerAccent, in: Circle())
                        .padding(7)
                }
            }
            .overlay(alignment: .topLeading) {
                if !isAllProviders, isProviderFavorite(provider.providerID) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                        .padding(9)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: Color.black.opacity(isSelected ? 0.06 : 0.025), radius: isSelected ? 7 : 3, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(provider.providerID)
        .accessibilityIdentifier(ModelPickerAccessibilityID.provider(provider.providerID))
        .accessibilityLabel(displayName)
        .accessibilityValue(isSelected ? "Selected, \(provider.modelCount) models" : "\(provider.modelCount) models")
        .contextMenu {
            if !isAllProviders {
                providerContextMenu(provider)
            }
        }
        .accessibilityActions {
            if !isAllProviders {
                Button(isProviderFavorite(provider.providerID) ? "Remove from Favorites" : "Add to Favorites") {
                    toggleProviderFavorite(provider.providerID)
                }
                Button("Edit") { editedProvider = provider }
            }
        }
    }

    @ViewBuilder
    private func providerCardContent(
        _ provider: ModelPickerProvider,
        displayName: String,
        isAllProviders: Bool,
        isSelected: Bool
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: 12) {
                providerArtwork(provider, isAllProviders: isAllProviders, isSelected: isSelected, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.58)
                        .allowsTightening(true)
                    Text("\(provider.modelCount) models")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 88)
        } else {
            VStack(spacing: 6) {
                providerArtwork(provider, isAllProviders: isAllProviders, isSelected: isSelected, size: 38)
                Text(displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("\(provider.modelCount) models")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 94)
        }
    }

    @ViewBuilder
    private func providerArtwork(
        _ provider: ModelPickerProvider,
        isAllProviders: Bool,
        isSelected: Bool,
        size: CGFloat
    ) -> some View {
        if isAllProviders {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(isSelected ? pickerAccent : .secondary)
                .frame(width: size, height: size)
        } else {
            ProviderArtworkView(
                providerID: provider.providerID,
                serverScopeID: serverScopeID,
                store: appearanceStore,
                size: size
            )
            .id("\(provider.providerID)-\(presentationRevision)")
        }
    }

    @ViewBuilder
    private func providerContextMenu(_ provider: ModelPickerProvider) -> some View {
        Button {
            toggleProviderFavorite(provider.providerID)
        } label: {
            Label(
                isProviderFavorite(provider.providerID) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isProviderFavorite(provider.providerID) ? "star.slash" : "star"
            )
        }

        Button {
            editedProvider = provider
        } label: {
            Label("Edit", systemImage: "paintbrush")
        }

        if appearanceStore.appearance(serverID: serverScopeID, providerID: provider.providerID).hasOverride {
            Button(role: .destructive) {
                appearanceStore.reset(serverID: serverScopeID, providerID: provider.providerID)
                presentationRevision += 1
            } label: {
                Label("Reset Appearance", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var resultHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(resultTitle)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.62 : 1)

            Spacer(minLength: 12)

            Text("\(filteredOptions.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .appSurfaceBackground(.inset, opacity: 0.65, in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var modelResults: some View {
        if filteredOptions.isEmpty {
            ContentUnavailableView {
                Label(emptyStateTitle, systemImage: emptyStateImage)
            } description: {
                Text(emptyStateDescription)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredOptions, id: \.favoriteKey) { option in
                        modelRow(option)
                    }
                }
                .appSurfaceBackground(.surface, opacity: 0.72, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.055), lineWidth: 0.5)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .accessibilityIdentifier(ModelPickerAccessibilityID.results)
        }
    }

    private func modelRow(_ option: ModelCatalogOption) -> some View {
        HStack(spacing: 11) {
            Button {
                onSelect(option)
                dismiss()
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: isSelected(option) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(isSelected(option) ? pickerAccent : .secondary)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.62 : 1)

                        }

                        Text(modelMetadata(option))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.62 : 1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onToggleFavorite(option)
            } label: {
                Image(systemName: isFavorite(option) ? "star.fill" : "star")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isFavorite(option) ? Color.yellow : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite(option) ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 9)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) {
            if option.favoriteKey != filteredOptions.last?.favoriteKey {
                Divider().padding(.leading, 52)
            }
        }
        .contextMenu {
            if isSavedCustomOption(option) {
                Button(role: .destructive) {
                    onDeleteSavedCustom(option)
                } label: {
                    Label("Delete Saved Custom Model", systemImage: "trash")
                }
            }
        }
        .accessibilityIdentifier(ModelPickerAccessibilityID.model(option))
    }

    private var addCustomModelButton: some View {
        Button {
            showsCustomModelEntry = true
        } label: {
            Label("Add Custom Model", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(pickerAccent)
        .appSurfaceBackground(.surface)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier(ModelPickerAccessibilityID.addCustomModel)
    }

    private var allViewOptions: [ModelCatalogOption] {
        var result = modelGroups.flatMap(\.models)
        var seen = Set(result.map(\.favoriteKey))
        for option in storedCustomOptions where seen.insert(option.favoriteKey).inserted {
            result.append(option)
        }
        if let selectedCustomOption, seen.insert(selectedCustomOption.favoriteKey).inserted {
            result.insert(selectedCustomOption, at: 0)
        }
        return result
    }

    private var viewOptions: [ModelCatalogOption] {
        switch selectedView {
        case .all:
            allViewOptions
        case .favorites:
            ModelFavoritesStore.visibleFavoriteOptions(in: modelGroups, favoriteKeys: favoriteModelKeys)
        case .recent:
            ModelRecentsStore.visibleAllRecentOptions(in: modelGroups, recentKeys: recentModelKeys)
        }
    }

    private var filteredOptions: [ModelCatalogOption] {
        ModelPickerCatalog.filteredOptions(
            viewOptions,
            query: searchText,
            providerID: selectedProviderScope.isEmpty ? nil : selectedProviderScope,
            providerDisplayNames: Dictionary(uniqueKeysWithValues: providers.map { ($0.providerID, providerDisplayName($0)) })
        )
    }

    private var providers: [ModelPickerProvider] {
        var seen = Set<String>()
        var result: [ModelPickerProvider] = []
        for group in modelGroups {
            guard let providerID = group.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !providerID.isEmpty,
                  seen.insert(providerID).inserted else { continue }
            result.append(ModelPickerProvider(providerID: providerID, catalogName: group.name, modelCount: group.models.count))
        }
        return result
    }

    private var displayedProviders: [ModelPickerProvider] {
        guard selectedView == .favorites else { return providers }
        let favorites = Set(favoriteProviderIDs)
        return providers.filter { favorites.contains($0.providerID) }
    }

    private var storedCustomOptions: [ModelCatalogOption] {
        let catalogKeys = Set(modelGroups.flatMap(\.models).map(\.favoriteKey))
        var seen = Set<ModelFavoriteKey>()
        var result: [ModelCatalogOption] = []
        for option in ModelFavoritesStore.visibleFavoriteOptions(in: modelGroups, favoriteKeys: favoriteModelKeys)
            where !catalogKeys.contains(option.favoriteKey) && seen.insert(option.favoriteKey).inserted {
            result.append(option)
        }
        for option in ModelRecentsStore.visibleAllRecentOptions(in: modelGroups, recentKeys: recentModelKeys)
            where !catalogKeys.contains(option.favoriteKey) && seen.insert(option.favoriteKey).inserted {
            result.append(option)
        }
        return result
    }

    private var selectedCustomOption: ModelCatalogOption? {
        guard let selectedModelID, !selectedModelID.isEmpty else { return nil }
        guard modelGroups.flatMap(\.models).firstMatchingSelection(
            modelID: selectedModelID,
            providerID: selectedModelProviderID
        ) == nil else { return nil }
        return ModelCatalogOption(id: selectedModelID, displayName: selectedModelID, providerID: selectedModelProviderID)
    }

    private var selectedProviderScope: String {
        providerScopeByView[selectedView] ?? allProvidersScope
    }

    private var serverScopeID: String {
        ServerRegistry.shared.activeServerID ?? "unscoped-server"
    }

    private var pickerAccent: Color {
        pickerAccentPalette.selection
    }

    private var pickerAccentForeground: Color {
        pickerAccentPalette.selectionForeground
    }

    private var pickerAccentPalette: ChatPaletteAccent {
        ChatPaletteAccent.resolved(
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue),
            colorScheme: colorScheme
        )
    }

    private var resultTitle: String {
        let providerName = providers.first { $0.providerID == selectedProviderScope }.map(providerDisplayName)
        switch selectedView {
        case .all: return providerName.map { "\($0) Models" } ?? String(localized: "All Models")
        case .favorites: return providerName.map { "\($0) Favorites" } ?? String(localized: "Favorite Models")
        case .recent: return providerName.map { "\($0) Recent" } ?? String(localized: "Recent Models")
        }
    }

    private var emptyStateTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "No Matching Models")
        }
        switch selectedView {
        case .all: return String(localized: "No Models")
        case .favorites: return String(localized: "No Favorites Yet")
        case .recent: return String(localized: "No Recent Models")
        }
    }

    private var emptyStateImage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "magnifyingglass" }
        switch selectedView {
        case .all: return "cube.transparent"
        case .favorites: return "star"
        case .recent: return "clock"
        }
    }

    private var emptyStateDescription: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Try a different provider, model name, or exact ID.")
        }
        switch selectedView {
        case .all: return String(localized: "This provider has no selectable models.")
        case .favorites: return String(localized: "Star a model to keep it close at hand.")
        case .recent: return String(localized: "Models you select will appear here.")
        }
    }

    private func initializeProviderScopesIfNeeded() {
        guard !didInitializeScope else { return }
        didInitializeScope = true
        providerScopeByView[.all] = providers.contains { $0.providerID == selectedModelProviderID }
            ? (selectedModelProviderID ?? allProvidersScope)
            : allProvidersScope
        providerScopeByView[.favorites] = allProvidersScope
        providerScopeByView[.recent] = allProvidersScope
    }

    private func reconcileProviderScope(for mode: ModelPickerViewMode, validProviderIDs: Set<String>) {
        guard let scope = providerScopeByView[mode],
              !scope.isEmpty,
              !validProviderIDs.contains(scope)
        else { return }
        providerScopeByView[mode] = allProvidersScope
    }

    private func scrollSelectedProviderIntoView(using proxy: ScrollViewProxy, animated: Bool) {
        let target = selectedProviderScope
        let action = { proxy.scrollTo(target, anchor: .center) }
        if animated {
            withAnimation(.snappy(duration: 0.24), action)
        } else {
            action()
        }
    }

    private func providerDisplayName(_ provider: ModelPickerProvider) -> String {
        appearanceStore.appearance(serverID: serverScopeID, providerID: provider.providerID).displayName
            ?? ProviderBrandCatalog.displayName(providerID: provider.providerID, catalogName: provider.catalogName)
    }

    private func modelMetadata(_ option: ModelCatalogOption) -> String {
        let providerName = option.providerID.flatMap { providerID in
            providers.first { $0.providerID == providerID }.map(providerDisplayName)
        } ?? option.providerID
        if option.id == option.displayName { return providerName ?? option.id }
        if selectedProviderScope.isEmpty {
            return [option.id, providerName].compactMap { $0 }.joined(separator: " · ")
        }
        return option.id
    }

    private func isSelected(_ option: ModelCatalogOption) -> Bool {
        option.matchesSelection(modelID: selectedModelID, providerID: selectedModelProviderID)
    }

    private func isFavorite(_ option: ModelCatalogOption) -> Bool {
        favoriteModelKeys.contains(option.favoriteKey)
    }

    private func isProviderFavorite(_ providerID: String) -> Bool {
        favoriteProviderIDs.contains(providerID)
    }

    private func toggleProviderFavorite(_ providerID: String) {
        onToggleProviderFavorite(providerID)
        if selectedView == .favorites, selectedProviderScope == providerID {
            providerScopeByView[.favorites] = allProvidersScope
        }
    }

    private func isSavedCustomOption(_ option: ModelCatalogOption) -> Bool {
        !modelGroups.flatMap(\.models).contains { $0.favoriteKey == option.favoriteKey }
    }
}

private struct HorizontalScrollAxisGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> HorizontalScrollAxisGuardView {
        HorizontalScrollAxisGuardView()
    }

    func updateUIView(_ uiView: HorizontalScrollAxisGuardView, context: Context) {
        uiView.attachToNearestScrollViewIfNeeded()
    }

    static func dismantleUIView(_ uiView: HorizontalScrollAxisGuardView, coordinator: ()) {
        uiView.detach()
    }
}

@MainActor
private final class HorizontalScrollAxisGuardView: UIView {
    private weak var guardedScrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private let verticalPanShield = UIPanGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        verticalPanShield.delegate = self
        verticalPanShield.cancelsTouchesInView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachToNearestScrollViewIfNeeded()
    }

    func attachToNearestScrollViewIfNeeded() {
        guard let scrollView = sequence(first: superview, next: { $0?.superview })
            .first(where: { $0 is UIScrollView }) as? UIScrollView else { return }

        guard scrollView !== guardedScrollView else {
            clampVerticalOffset()
            return
        }

        detach()
        guardedScrollView = scrollView
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.addGestureRecognizer(verticalPanShield)
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.clampVerticalOffset() }
        }
        clampVerticalOffset()
    }

    func detach() {
        if let view = verticalPanShield.view {
            view.removeGestureRecognizer(verticalPanShield)
        }
        offsetObservation = nil
        guardedScrollView = nil
    }

    private func clampVerticalOffset() {
        guard let scrollView = guardedScrollView else { return }
        let pinnedY = -scrollView.adjustedContentInset.top
        guard abs(scrollView.contentOffset.y - pinnedY) > 0.5 else { return }
        scrollView.contentOffset.y = pinnedY
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === verticalPanShield,
              let scrollView = guardedScrollView else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = verticalPanShield.velocity(in: scrollView)
        return abs(velocity.y) > abs(velocity.x)
    }
}

extension HorizontalScrollAxisGuardView: UIGestureRecognizerDelegate {
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        MainActor.assumeIsolated {
            otherGestureRecognizer === guardedScrollView?.panGestureRecognizer
        }
    }
}

enum ModelPickerViewMode: String, CaseIterable, Identifiable {
    case all
    case favorites
    case recent

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .favorites: String(localized: "Favorites")
        case .recent: String(localized: "Recent")
        }
    }
}

struct ModelPickerProvider: Identifiable, Hashable {
    let providerID: String
    let catalogName: String
    let modelCount: Int

    var id: String { providerID }
}

enum ModelPickerCatalog {
    static func filteredOptions(
        _ options: [ModelCatalogOption],
        query: String,
        providerID: String?,
        providerDisplayNames: [String: String]
    ) -> [ModelCatalogOption] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter { option in
            if let providerID, option.providerID != providerID { return false }
            guard !trimmedQuery.isEmpty else { return true }
            let providerName = option.providerID.flatMap { providerDisplayNames[$0] }
            return option.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || option.id.localizedCaseInsensitiveContains(trimmedQuery)
                || (option.providerID?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (providerName?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }
}

enum ModelPickerAccessibilityID {
    static let viewPicker = "model-picker.view"
    static let results = "model-picker.results"
    static let addCustomModel = "model-picker.add-custom"
    static let providerEditor = "model-picker.provider-editor"

    static func provider(_ providerID: String) -> String {
        "model-picker.provider.\(providerID.isEmpty ? "all" : providerID)"
    }

    static func model(_ option: ModelCatalogOption) -> String {
        "model-picker.model.\(option.providerID ?? "none").\(option.id)"
    }
}

struct ProviderAppearance: Codable, Equatable {
    var displayName: String?
    var artworkFileName: String?
    var usesFallback = false

    var hasOverride: Bool {
        displayName != nil || artworkFileName != nil || usesFallback
    }
}

struct ProviderAppearanceStore: @unchecked Sendable {
    static let shared = ProviderAppearanceStore()

    private struct Snapshot: Codable {
        var servers: [String: [String: ProviderAppearance]] = [:]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let artworkDirectory: URL

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "hermes.mobile.providerAppearances",
        artworkDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.artworkDirectory = artworkDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProviderArtwork", isDirectory: true)
    }

    func appearance(serverID: String, providerID: String) -> ProviderAppearance {
        snapshot.servers[serverID]?[providerID] ?? ProviderAppearance()
    }

    func setDisplayName(_ displayName: String?, serverID: String, providerID: String) {
        var value = appearance(serverID: serverID, providerID: providerID)
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        value.displayName = trimmed?.isEmpty == false ? trimmed : nil
        save(value, serverID: serverID, providerID: providerID)
    }

    func useAutomaticArtwork(serverID: String, providerID: String) {
        var value = appearance(serverID: serverID, providerID: providerID)
        removeArtworkFile(named: value.artworkFileName)
        value.artworkFileName = nil
        value.usesFallback = false
        save(value, serverID: serverID, providerID: providerID)
    }

    func useFallbackArtwork(serverID: String, providerID: String) {
        var value = appearance(serverID: serverID, providerID: providerID)
        removeArtworkFile(named: value.artworkFileName)
        value.artworkFileName = nil
        value.usesFallback = true
        save(value, serverID: serverID, providerID: providerID)
    }

    func importArtwork(_ data: Data, serverID: String, providerID: String) throws {
        let (fileName, pngData) = try preparedArtwork(data)

        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try pngData.write(to: artworkDirectory.appendingPathComponent(fileName), options: .atomic)

        var value = appearance(serverID: serverID, providerID: providerID)
        removeArtworkFile(named: value.artworkFileName)
        value.artworkFileName = fileName
        value.usesFallback = false
        save(value, serverID: serverID, providerID: providerID)
    }

    func apply(
        displayName: String?,
        artworkData: Data?,
        restoresDefaultArtwork: Bool,
        serverID: String,
        providerID: String
    ) throws {
        let currentValue = appearance(serverID: serverID, providerID: providerID)
        let prepared = try artworkData.map(preparedArtwork)

        if let prepared {
            try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            do {
                try prepared.data.write(
                    to: artworkDirectory.appendingPathComponent(prepared.fileName),
                    options: .atomic
                )
            } catch {
                removeArtworkFile(named: prepared.fileName)
                throw error
            }
        }

        var value = currentValue
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        value.displayName = trimmed?.isEmpty == false ? trimmed : nil
        if let prepared {
            value.artworkFileName = prepared.fileName
            value.usesFallback = false
        } else if restoresDefaultArtwork {
            value.artworkFileName = nil
            value.usesFallback = false
        }
        save(value, serverID: serverID, providerID: providerID)

        if (prepared != nil || restoresDefaultArtwork),
           currentValue.artworkFileName != value.artworkFileName {
            removeArtworkFile(named: currentValue.artworkFileName)
        }
    }

    func artworkImage(serverID: String, providerID: String) -> UIImage? {
        guard let fileName = validatedArtworkFileName(
            appearance(serverID: serverID, providerID: providerID).artworkFileName
        ) else { return nil }
        return UIImage(contentsOfFile: artworkDirectory.appendingPathComponent(fileName).path)
    }

    func reset(serverID: String, providerID: String) {
        let value = appearance(serverID: serverID, providerID: providerID)
        removeArtworkFile(named: value.artworkFileName)
        var current = snapshot
        current.servers[serverID]?[providerID] = nil
        if current.servers[serverID]?.isEmpty == true { current.servers[serverID] = nil }
        persist(current)
    }

    private var snapshot: Snapshot {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }
        return decoded
    }

    private func save(_ appearance: ProviderAppearance, serverID: String, providerID: String) {
        var current = snapshot
        if appearance.hasOverride {
            current.servers[serverID, default: [:]][providerID] = appearance
        } else {
            current.servers[serverID]?[providerID] = nil
        }
        persist(current)
    }

    private func persist(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func removeArtworkFile(named fileName: String?) {
        guard let fileName = validatedArtworkFileName(fileName) else { return }
        try? FileManager.default.removeItem(at: artworkDirectory.appendingPathComponent(fileName))
    }

    private func validatedArtworkFileName(_ fileName: String?) -> String? {
        guard let fileName,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName,
              fileName.hasSuffix(".png"),
              UUID(uuidString: String(fileName.dropLast(4))) != nil
        else { return nil }
        return fileName
    }

    private func preparedArtwork(_ data: Data) throws -> (fileName: String, data: Data) {
        ("\(UUID().uuidString).png", try ProviderArtworkProcessor.normalizedPNG(from: data))
    }
}

enum ProviderArtworkImportError: LocalizedError {
    case invalidImage
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            String(localized: "That file could not be read as an image.")
        case .imageTooLarge:
            String(localized: "Choose an image smaller than 20 MB and 100 megapixels.")
        }
    }
}

enum ProviderArtworkProcessor {
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static let maximumPixelCount = 100_000_000
    static let maximumOutputDimension = 512

    static func normalizedPNG(from data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes else {
            throw ProviderArtworkImportError.imageTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { throw ProviderArtworkImportError.invalidImage }

        let pixelCount = width.int64Value.multipliedReportingOverflow(by: height.int64Value)
        guard !pixelCount.overflow, pixelCount.partialValue > 0,
              pixelCount.partialValue <= Int64(maximumPixelCount)
        else { throw ProviderArtworkImportError.imageTooLarge }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumOutputDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProviderArtworkImportError.invalidImage
        }
        let normalized = UIImage(cgImage: thumbnail)
        guard let pngData = normalized.pngData() else { throw ProviderArtworkImportError.invalidImage }
        return pngData
    }

    static func normalizedPNG(fromFileAt url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumInputBytes {
            throw ProviderArtworkImportError.imageTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let boundedData = try handle.read(upToCount: maximumInputBytes + 1) ?? Data()
        guard boundedData.count <= maximumInputBytes else {
            throw ProviderArtworkImportError.imageTooLarge
        }
        return try normalizedPNG(from: boundedData)
    }
}

struct ProviderArtworkTransfer: Transferable, Sendable {
    let normalizedPNG: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            ProviderArtworkTransfer(
                normalizedPNG: try ProviderArtworkProcessor.normalizedPNG(fromFileAt: received.file)
            )
        }
    }
}

private struct ProviderArtworkView: View {
    let providerID: String
    let serverScopeID: String
    let store: ProviderAppearanceStore
    let size: CGFloat
    var usesStoredArtwork = true

    var body: some View {
        let appearance = store.appearance(serverID: serverScopeID, providerID: providerID)
        let bundledArtwork = usesStoredArtwork && appearance.usesFallback
            ? nil
            : ProviderBrandCatalog.artwork(for: providerID)

        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(bundledArtwork == nil ? providerColor.opacity(0.13) : Color.primary.opacity(0.055))

            if usesStoredArtwork,
               let image = store.artworkImage(serverID: serverScopeID, providerID: providerID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            } else if let bundledArtwork {
                Image(bundledArtwork.assetName)
                    .resizable()
                    .renderingMode(bundledArtwork.usesOriginalColor ? .original : .template)
                    .scaledToFit()
                    .foregroundStyle(.primary.opacity(0.86))
                    .padding(size * bundledArtwork.paddingRatio)
            } else {
                Image("ProviderFallback")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(providerColor)
                    .padding(size * 0.20)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var providerColor: Color {
        let palette: [Color] = [
            Color(red: 0.20, green: 0.48, blue: 0.82),
            Color(red: 0.37, green: 0.36, blue: 0.78),
            Color(red: 0.09, green: 0.56, blue: 0.50),
            Color(red: 0.76, green: 0.38, blue: 0.22),
            Color(red: 0.54, green: 0.36, blue: 0.70)
        ]
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in providerID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct ProviderBrandArtwork: Equatable {
    let assetName: String
    let usesOriginalColor: Bool
    let paddingRatio: CGFloat
}

enum ProviderBrandCatalog {
    private static let displayNames: [String: String] = [
        "ai-gateway": "AI Gateway",
        "alibaba": "Alibaba Cloud",
        "alibaba-coding-plan": "Alibaba Coding",
        "anthropic": "Anthropic",
        "bedrock": "AWS Bedrock",
        "copilot": "GitHub Copilot",
        "copilot-acp": "Copilot ACP",
        "cursor-acp": "Cursor ACP",
        "deepinfra": "DeepInfra",
        "deepseek": "DeepSeek",
        "fireworks": "Fireworks AI",
        "gemini": "Gemini",
        "gmi": "GMI Cloud",
        "google": "Google AI",
        "huggingface": "Hugging Face",
        "kimi-coding": "Kimi Coding",
        "kimi-coding-cn": "Kimi Coding China",
        "kilocode": "Kilo Code",
        "lmstudio": "LM Studio",
        "meta": "Meta AI",
        "meta-llama": "Meta Llama",
        "minimax": "MiniMax",
        "minimax-cn": "MiniMax China",
        "minimax-oauth": "MiniMax OAuth",
        "mistralai": "Mistral AI",
        "nvidia": "NVIDIA NIM",
        "ollama": "Ollama",
        "ollama-cloud": "Ollama Cloud",
        "openai": "OpenAI",
        "openai-api": "OpenAI API",
        "openai-codex": "OpenAI Codex",
        "openrouter": "OpenRouter",
        "qwen": "Qwen",
        "qwen-oauth": "Qwen OAuth",
        "vibeproxy": "VibeProxy",
        "vertex": "Google Vertex AI",
        "x-ai": "xAI",
        "xai": "xAI",
        "xai-oauth": "xAI OAuth",
        "xiaomi": "Xiaomi",
        "zai": "zAI"
    ]

    private static let artwork: [String: ProviderBrandArtwork] = [
        "alibaba": .init(assetName: "ProviderAlibabaCloud", usesOriginalColor: false, paddingRatio: 0.18),
        "alibaba-coding-plan": .init(assetName: "ProviderAlibabaCloud", usesOriginalColor: false, paddingRatio: 0.18),
        "anthropic": .init(assetName: "ProviderAnthropic", usesOriginalColor: false, paddingRatio: 0.22),
        "copilot": .init(assetName: "ProviderGitHubCopilot", usesOriginalColor: false, paddingRatio: 0.17),
        "copilot-acp": .init(assetName: "ProviderGitHubCopilot", usesOriginalColor: false, paddingRatio: 0.17),
        "cursor-acp": .init(assetName: "ProviderCursor", usesOriginalColor: false, paddingRatio: 0.18),
        "deepseek": .init(assetName: "ProviderDeepSeek", usesOriginalColor: false, paddingRatio: 0.17),
        "gemini": .init(assetName: "ProviderGemini", usesOriginalColor: false, paddingRatio: 0.22),
        "google": .init(assetName: "ProviderGoogleCloud", usesOriginalColor: false, paddingRatio: 0.20),
        "huggingface": .init(assetName: "ProviderHuggingFace", usesOriginalColor: false, paddingRatio: 0.16),
        "kimi-coding": .init(assetName: "ProviderKimi", usesOriginalColor: false, paddingRatio: 0.18),
        "kimi-coding-cn": .init(assetName: "ProviderKimi", usesOriginalColor: false, paddingRatio: 0.18),
        "lmstudio": .init(assetName: "ProviderLMStudio", usesOriginalColor: false, paddingRatio: 0.19),
        "meta": .init(assetName: "ProviderMeta", usesOriginalColor: false, paddingRatio: 0.18),
        "meta-llama": .init(assetName: "ProviderMeta", usesOriginalColor: false, paddingRatio: 0.18),
        "minimax": .init(assetName: "ProviderMiniMax", usesOriginalColor: false, paddingRatio: 0.16),
        "minimax-cn": .init(assetName: "ProviderMiniMax", usesOriginalColor: false, paddingRatio: 0.16),
        "minimax-oauth": .init(assetName: "ProviderMiniMax", usesOriginalColor: false, paddingRatio: 0.16),
        "mistralai": .init(assetName: "ProviderMistral", usesOriginalColor: false, paddingRatio: 0.18),
        "nvidia": .init(assetName: "ProviderNVIDIA", usesOriginalColor: false, paddingRatio: 0.17),
        "ollama": .init(assetName: "ProviderOllama", usesOriginalColor: false, paddingRatio: 0.16),
        "ollama-cloud": .init(assetName: "ProviderOllama", usesOriginalColor: false, paddingRatio: 0.16),
        "opencode-go": .init(assetName: "ProviderOpenCode", usesOriginalColor: false, paddingRatio: 0.17),
        "opencode-zen": .init(assetName: "ProviderOpenCode", usesOriginalColor: false, paddingRatio: 0.17),
        "openrouter": .init(assetName: "ProviderOpenRouter", usesOriginalColor: false, paddingRatio: 0.17),
        "qwen": .init(assetName: "ProviderQwen", usesOriginalColor: false, paddingRatio: 0.17),
        "qwen-oauth": .init(assetName: "ProviderQwen", usesOriginalColor: false, paddingRatio: 0.17),
        "vertex": .init(assetName: "ProviderGoogleCloud", usesOriginalColor: false, paddingRatio: 0.20),
        "x-ai": .init(assetName: "ProviderXAI", usesOriginalColor: false, paddingRatio: 0.20),
        "xai": .init(assetName: "ProviderXAI", usesOriginalColor: false, paddingRatio: 0.20),
        "xai-oauth": .init(assetName: "ProviderXAI", usesOriginalColor: false, paddingRatio: 0.20),
        "xiaomi": .init(assetName: "ProviderXiaomi", usesOriginalColor: false, paddingRatio: 0.18)
    ]

    static func displayName(providerID: String, catalogName: String) -> String {
        let key = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let name = displayNames[key] { return name }
        let trimmedCatalogName = catalogName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCatalogName.isEmpty, trimmedCatalogName.caseInsensitiveCompare(providerID) != .orderedSame {
            return trimmedCatalogName
        }
        return providerID
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func artwork(for providerID: String) -> ProviderBrandArtwork? {
        artwork[providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}

private struct CustomModelEntrySheet: View {
    let providers: [ModelPickerProvider]
    let initialProviderID: String?
    let favoriteModelKeys: [ModelFavoriteKey]
    let onUse: (ModelCatalogOption) -> Void
    let onToggleFavorite: (ModelCatalogOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var modelID = ""
    @State private var providerID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exact Model ID", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Provider ID", text: $providerID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !providers.isEmpty {
                        Menu("Choose Provider") {
                            ForEach(providers) { provider in
                                Button(
                                    ProviderBrandCatalog.displayName(
                                        providerID: provider.providerID,
                                        catalogName: provider.catalogName
                                    )
                                ) { providerID = provider.providerID }
                            }
                        }
                    }
                } header: {
                    Text("Model Identity")
                } footer: {
                    Text("The exact model ID and provider routing ID stay separate.")
                }

                Section {
                    Button {
                        guard let option else { return }
                        onUse(option)
                    } label: {
                        Label("Use Custom Model", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(option == nil)

                    Button {
                        guard let option else { return }
                        onToggleFavorite(option)
                    } label: {
                        Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
                    }
                    .disabled(option == nil)
                }
            }
            .scrollContentBackground(.hidden)
            .appSurfaceBackground(.canvas)
            .navigationTitle("Add Custom Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                guard providerID.isEmpty else { return }
                providerID = initialProviderID ?? providers.first?.providerID ?? ""
            }
        }
        .adaptiveFormPresentation()
    }

    private var option: ModelCatalogOption? {
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !trimmedProvider.isEmpty else { return nil }
        return ModelCatalogOption(id: trimmedModel, displayName: trimmedModel, providerID: trimmedProvider)
    }

    private var isFavorite: Bool {
        option.map { favoriteModelKeys.contains($0.favoriteKey) } ?? false
    }
}

private struct ProviderAppearanceEditor: View {
    let provider: ModelPickerProvider
    let serverScopeID: String
    let store: ProviderAppearanceStore
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var errorMessage: String?
    @State private var pendingArtworkData: Data?
    @State private var restoresDefaultArtwork = false
    @State private var restoresDefaultName = false
    @State private var showsProviderDetails = false

    init(provider: ModelPickerProvider, serverScopeID: String, store: ProviderAppearanceStore, onChange: @escaping () -> Void) {
        self.provider = provider
        self.serverScopeID = serverScopeID
        self.store = store
        self.onChange = onChange
        let appearance = store.appearance(serverID: serverScopeID, providerID: provider.providerID)
        _displayName = State(initialValue: appearance.displayName
            ?? ProviderBrandCatalog.displayName(providerID: provider.providerID, catalogName: provider.catalogName))
        _restoresDefaultName = State(initialValue: appearance.displayName == nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    previewCard
                    nameCard
                    imageCard
                    providerDetailsCard

                    Button {
                        displayName = defaultDisplayName
                        pendingArtworkData = nil
                        restoresDefaultArtwork = true
                        restoresDefaultName = true
                        errorMessage = nil
                    } label: {
                        Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .appSurfaceBackground(
                        .surface,
                        opacity: 0.56,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.055), lineWidth: 0.6)
                            .allowsHitTesting(false)
                    }
                    .accessibilityHint("Restores the original name and image after you save.")

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .appSurfaceBackground(.canvas)
            .navigationTitle("Edit Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .photosPicker(isPresented: $showsPhotoPicker, selection: $selectedPhoto, matching: .images)
            .onChange(of: displayName) { _, newValue in
                restoresDefaultName = newValue == defaultDisplayName
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let artwork = try await item.loadTransferable(type: ProviderArtworkTransfer.self) else {
                            throw ProviderArtworkImportError.invalidImage
                        }
                        await MainActor.run {
                            pendingArtworkData = artwork.normalizedPNG
                            restoresDefaultArtwork = false
                            errorMessage = nil
                            selectedPhoto = nil
                        }
                    } catch {
                        await MainActor.run { errorMessage = error.localizedDescription }
                    }
                }
            }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    Task {
                        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let normalized = try await Task.detached(priority: .userInitiated) {
                                try ProviderArtworkProcessor.normalizedPNG(fromFileAt: url)
                            }.value
                            await MainActor.run {
                                pendingArtworkData = normalized
                                restoresDefaultArtwork = false
                                errorMessage = nil
                            }
                        } catch {
                            await MainActor.run { errorMessage = error.localizedDescription }
                        }
                    }
                } catch {
                    if !Self.isUserCancellation(error) {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .accessibilityIdentifier(ModelPickerAccessibilityID.providerEditor)
        }
        .adaptiveFormPresentation()
    }

    private var previewCard: some View {
        ProviderEditorCard {
            HStack(spacing: 16) {
                artworkPreview(size: 68)

                VStack(alignment: .leading, spacing: 5) {
                    Text(previewDisplayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("Preview in the model picker")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var nameCard: some View {
        ProviderEditorCard(title: "Name") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Provider name", text: $displayName)
                    .font(.body.weight(.medium))
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .appSurfaceBackground(
                        .inset,
                        opacity: 0.74,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .accessibilityLabel("Provider name")
                    .accessibilityIdentifier("model-picker.provider-name")

                Text("This is the name shown in the model picker.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var imageCard: some View {
        ProviderEditorCard(title: "Image") {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    artworkPreview(size: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider image")
                            .font(.subheadline.weight(.semibold))
                        Text(imageStatusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                Divider()
                imagePickerMenu
            }
        }
    }

    private var imagePickerMenu: some View {
        ChatUIKitMenuButton(horizontalPadding: 6, verticalPadding: 6) {
            HStack(spacing: 6) {
                Image(systemName: "photo.badge.plus")
                Text("Choose Image")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .adaptiveGlass(
                .regular,
                isInteractive: true,
                fallbackMaterial: .ultraThinMaterial,
                in: Capsule()
            )
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        } menu: {
            imageMenu()
        }
        .accessibilityLabel("Choose provider image")
        .accessibilityIdentifier("model-picker.choose-image")
    }

    private var providerDetailsCard: some View {
        ProviderEditorCard {
            DisclosureGroup(isExpanded: $showsProviderDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text("Provider ID")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(provider.providerID)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Used for routing and can’t be changed here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            } label: {
                Label("Provider Details", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.primary)
        }
    }

    @ViewBuilder
    private func artworkPreview(size: CGFloat) -> some View {
        if let pendingArtworkData, let image = UIImage(data: pendingArtworkData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
        } else {
            ProviderArtworkView(
                providerID: provider.providerID,
                serverScopeID: serverScopeID,
                store: store,
                size: size,
                usesStoredArtwork: !restoresDefaultArtwork
            )
        }
    }

    private var defaultDisplayName: String {
        ProviderBrandCatalog.displayName(providerID: provider.providerID, catalogName: provider.catalogName)
    }

    private var previewDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDisplayName : trimmed
    }

    private var imageStatusText: String {
        if pendingArtworkData != nil { return String(localized: "New image selected") }
        if restoresDefaultArtwork { return String(localized: "Default image") }
        if store.artworkImage(serverID: serverScopeID, providerID: provider.providerID) != nil {
            return String(localized: "Custom image")
        }
        return String(localized: "Default image")
    }

    private func imageMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: String(localized: "Photos"), image: UIImage(systemName: "photo.on.rectangle")) { _ in
                Task { @MainActor in showsPhotoPicker = true }
            },
            UIAction(title: String(localized: "Choose File"), image: UIImage(systemName: "folder")) { _ in
                Task { @MainActor in showsFileImporter = true }
            }
        ]

        let hasReplaceableImage = pendingArtworkData != nil
            || store.appearance(serverID: serverScopeID, providerID: provider.providerID).artworkFileName != nil
        if !restoresDefaultArtwork, hasReplaceableImage {
            children.append(UIMenu(
                title: "",
                options: [.displayInline],
                children: [
                    UIAction(title: String(localized: "Restore Default Image"), image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                        Task { @MainActor in
                            pendingArtworkData = nil
                            restoresDefaultArtwork = true
                            errorMessage = nil
                        }
                    }
                ]
            ))
        }

        return UIMenu(title: "", children: children)
    }

    private func save() {
        do {
            try store.apply(
                displayName: restoresDefaultName ? nil : displayName,
                artworkData: pendingArtworkData,
                restoresDefaultArtwork: restoresDefaultArtwork,
                serverID: serverScopeID,
                providerID: provider.providerID
            )
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}

private struct ProviderEditorCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape.fill(
                ChatPalette.appChrome(colorScheme: colorScheme).surface.opacity(reduceTransparency ? 1 : 0.40)
                    )
                }
                .adaptiveGlass(.regular, fallbackMaterial: .regularMaterial, in: shape)
                .clipShape(shape)
                .overlay {
                    shape
                        .stroke(Color.primary.opacity(colorSchemeContrast == .increased ? 0.16 : 0.06), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
        }
    }
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
