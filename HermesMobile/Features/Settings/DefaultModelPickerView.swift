import SwiftUI

struct DefaultModelPickerView: View {
    let server: URL
    let currentDefaultModel: String?
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var groups: [ModelCatalogGroup] = []
    @State private var defaultModel: String?
    @State private var activeProvider: String?
    @State private var selectedModel: String?
    @State private var selectedProvider: String?
    @State private var favoriteModelKeys: [ModelFavoriteKey] = []
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isSavingCustom = false
    @State private var saveError: String?

    var body: some View {
        ModelPickerSheet(
            configuration: .serverDefault,
            modelGroups: groups,
            selectedModelID: defaultModel,
            selectedModelProviderID: activeProvider,
            favoriteModelKeys: favoriteModelKeys,
            isSelected: isCurrentDefault,
            loadStatus: loadStatus,
            inFlightKey: inFlightKey,
            isCommittingCustom: isSavingCustom,
            isSelectionDisabled: isSaving,
            errorMessage: saveError,
            onSelect: { option in
                Task { await save(option.id, providerID: option.providerID) }
            },
            onCommitCustom: { option in
                Task { await save(option.id, providerID: option.providerID, isCustom: true) }
            },
            onToggleFavorite: { option in
                favoriteModelKeys = ModelFavoritesStore(server: server).toggleFavorite(for: option)
            }
        )
        .task {
            favoriteModelKeys = ModelFavoritesStore(server: server).favoriteKeys
            await loadModels()
        }
    }

    private var loadStatus: ModelPickerLoadStatus {
        if isLoading && groups.isEmpty { return .loading }
        if let errorMessage, groups.isEmpty { return .failed(errorMessage) }
        return .loaded
    }

    private var inFlightKey: ModelFavoriteKey? {
        guard isSaving, !isSavingCustom, let selectedModel else { return nil }
        return ModelFavoriteKey(modelID: selectedModel, providerID: selectedProvider)
    }

    private func isCurrentDefault(_ model: ModelCatalogOption) -> Bool {
        Self.isChecked(
            model,
            selectedModel: selectedModel,
            selectedProvider: selectedProvider,
            defaultModel: defaultModel,
            activeProvider: activeProvider
        )
    }

    static func isChecked(
        _ model: ModelCatalogOption,
        selectedModel: String?,
        selectedProvider: String?,
        defaultModel: String?,
        activeProvider: String?
    ) -> Bool {
        if selectedModel != nil {
            guard selectedProvider != nil else { return false }
            return model.matchesSelection(modelID: selectedModel, providerID: selectedProvider)
        }

        let defaultProvider: String?
        if defaultModel?.modelIDProviderPrefix != nil {
            defaultProvider = nil
        } else {
            defaultProvider = activeProvider
        }
        return model.matchesSelection(modelID: defaultModel, providerID: defaultProvider)
    }

    private func loadModels() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let response = try await APIClient(baseURL: server).models()
            defaultModel = response.defaultModel ?? currentDefaultModel
            groups = response.catalogGroups
            activeProvider = response.activeProvider
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false

        await overlayLiveModels()
    }

    private func overlayLiveModels() async {
        guard let live = try? await APIClient(baseURL: server).modelsLive() else { return }
        groups = groups.mergingLiveModels(from: live)
    }

    private func save(_ model: String, providerID: String? = nil, isCustom: Bool = false) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        isSavingCustom = isCustom
        saveError = nil
        selectedModel = trimmed
        selectedProvider = providerID

        do {
            let response = try await APIClient(baseURL: server).saveDefaultModel(model: trimmed, provider: providerID)
            if response.ok == true {
                onSave(trimmed)
                dismiss()
            } else {
                saveError = String(localized: "The server did not confirm the change.")
                selectedModel = nil
                selectedProvider = nil
            }
        } catch {
            saveError = error.localizedDescription
            selectedModel = nil
            selectedProvider = nil
        }

        isSaving = false
        isSavingCustom = false
    }
}
