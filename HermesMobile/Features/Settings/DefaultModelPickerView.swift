import SwiftUI

/// Settings > Default Model: the loader and server-saver around the shared
/// `ModelPickerSheet`. The sheet owns the list, search, favorites, and the
/// custom entry; this view owns the catalog request, the save request, and the
/// checkmark rule that has to reconcile the server's saved spelling with the
/// catalog's.
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
    @State private var favoriteModelKeys: [ModelFavoriteKey] = ModelFavoritesStore.shared.favoriteKeys
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
                favoriteModelKeys = ModelFavoritesStore.shared.toggleFavorite(for: option)
            }
        )
        .task {
            await loadModels()
        }
    }

    private var loadStatus: ModelPickerLoadStatus {
        if isLoading && groups.isEmpty { return .loading }
        if let errorMessage, groups.isEmpty { return .failed(errorMessage) }
        return .loaded
    }

    /// The tapped catalog row while its save is in flight. A custom save names
    /// no catalog row — the custom entry owns that spinner via
    /// `isCommittingCustom` — so it stays nil.
    private var inFlightKey: ModelFavoriteKey? {
        guard isSaving, !isSavingCustom, let selectedModel else { return nil }
        return ModelFavoriteKey(modelID: selectedModel, providerID: selectedProvider)
    }

    /// Whether this row is the current default.
    ///
    /// Compared through `matchesSelection`, which normalizes the `@provider:`
    /// prefix the server adds to models outside the active provider. A raw `==`
    /// left the checkmark off every row whose saved spelling differed from the
    /// catalog's current one, so the picker could not answer "which one am I on"
    /// at all.
    ///
    /// The in-flight branch matches against the provider captured at tap time,
    /// so only the tapped row announces "Selected". The stored default is
    /// matched against the provider its own spelling names — an embedded
    /// `@provider:` prefix stays authoritative — falling back to
    /// `activeProvider` for a bare id, which belongs to whichever provider is
    /// active. Without that fallback, Core's catalog dedup can prefix the
    /// active provider's own rows while an inactive provider keeps the bare
    /// spelling, and the wrong row ticks.
    private func isCurrentDefault(_ model: ModelCatalogOption) -> Bool {
        Self.isChecked(
            model,
            selectedModel: selectedModel,
            selectedProvider: selectedProvider,
            defaultModel: defaultModel,
            activeProvider: activeProvider
        )
    }

    /// The checkmark rule, static and internal so tests can pin the
    /// decoded-response-to-checked-row mapping without driving SwiftUI.
    static func isChecked(
        _ model: ModelCatalogOption,
        selectedModel: String?,
        selectedProvider: String?,
        defaultModel: String?,
        activeProvider: String?
    ) -> Bool {
        // An in-flight tap owns the projection: OR-ing the previous default
        // would leave two rows announcing "Selected" until the save finishes.
        // A custom / providerless save names no catalog row — matching with
        // `providerID: nil` would tick every bare same-id row after the live
        // overlay. Leave the catalog unchecked; the custom button owns the
        // spinner via `isSavingCustom`.
        if selectedModel != nil {
            guard selectedProvider != nil else { return false }
            return model.matchesSelection(modelID: selectedModel, providerID: selectedProvider)
        }

        // A stored `@provider:` spelling must not be pre-split with
        // `lastIndex(of: ":")` — that turns `@ollama:qwen3:32b` into provider
        // `ollama:qwen3`. Detect the prefix by whether one exists at all
        // (`@cf/meta/...` model ids start with `@` but have no colon, so they
        // stay bare and match against `activeProvider`). Passing nil then
        // lets `matchesSelection` use the row's own `providerID` as the
        // prefix key.
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

    /// Overlays the active provider's live (uncached) list onto the cached
    /// catalog so newly available models appear. Failures are silent by
    /// design — the cached list stays as-is (issue #236).
    private func overlayLiveModels() async {
        guard let live = try? await APIClient(baseURL: server).modelsLive() else { return }
        groups = groups.mergingLiveModels(from: live)
    }

    /// Saves `model` as the server default. The sheet stays open until the
    /// server confirms with `ok == true`; a failure clears the optimistic
    /// selection so no wrong row reads as checked.
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
