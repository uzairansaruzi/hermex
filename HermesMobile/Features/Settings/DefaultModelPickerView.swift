import SwiftUI

struct DefaultModelPickerView: View {
    let server: URL
    let currentDefaultModel: String?
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var isLoading = false
    @State private var groups: [ModelCatalogGroup] = []
    @State private var defaultModel: String?
    @State private var customModel = ""
    @State private var selectedModel: String?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isSavingCustom = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ModelPickerSearchField(text: $searchText)

                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ModelPickerCard(title: String(localized: "Custom")) {
                        TextField("Custom model ID", text: $customModel)
                            .font(.subheadline)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("Type a model ID exactly as the server expects it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ModelPickerButton(
                            String(localized: "Save Custom Model"),
                            isLoading: isSavingCustom
                        ) {
                            Task { await save(customModel, isCustom: true) }
                        }
                        .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    }

                    modelListContent
                }
                .padding()
            }
            .navigationTitle("Default Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadModels()
            }
        }
        .adaptiveFormPresentation()
    }

    @ViewBuilder
    private var modelListContent: some View {
        if isLoading && groups.isEmpty {
            ModelPickerCard(title: String(localized: "Models")) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading models...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let errorMessage, groups.isEmpty {
            ModelPickerCard(title: String(localized: "Models")) {
                Label("Could Not Load Models", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))

                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if filteredGroups.isEmpty {
            ModelPickerCard(title: String(localized: "Models")) {
                Label("No Matching Models", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))

                Text("Try a different model name or ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(filteredGroups) { group in
                ModelPickerCard(title: group.name) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                            modelRow(model)

                            if index < group.models.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredGroups: [ModelCatalogGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return groups }

        return groups.compactMap { group in
            let matchingModels = group.models.filter { model in
                model.displayName.lowercased().contains(query)
                    || model.id.lowercased().contains(query)
                    || group.name.lowercased().contains(query)
            }

            guard !matchingModels.isEmpty else { return nil }
            return ModelCatalogGroup(
                id: group.id,
                name: group.name,
                providerID: group.providerID,
                models: matchingModels
            )
        }
    }

    private func modelRow(_ model: ModelCatalogOption) -> some View {
        Button {
            Task { await save(model.id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if !model.id.isEmpty && model.id != model.displayName {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                }

                Spacer(minLength: 12)

                if isSaving && selectedModel == model.id {
                    ProgressView()
                } else if model.id == defaultModel || model.id == selectedModel {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(modelAccessibilityLabel(for: model))
        .accessibilityValue(model.id == defaultModel || model.id == selectedModel ? "Selected" : "")
    }

    private func modelAccessibilityLabel(for model: ModelCatalogOption) -> String {
        guard !model.id.isEmpty, model.id != model.displayName else {
            return model.displayName
        }

        return "\(model.displayName), \(model.id)"
    }

    private func loadModels() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let response = try await APIClient(baseURL: server).models()
            defaultModel = response.defaultModel ?? currentDefaultModel
            groups = response.catalogGroups
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

    private func save(_ model: String, isCustom: Bool = false) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSaving = true
        isSavingCustom = isCustom
        saveError = nil
        selectedModel = trimmed

        do {
            let response = try await APIClient(baseURL: server).saveDefaultModel(model: trimmed)
            if response.ok == true {
                onSave(trimmed)
                dismiss()
            } else {
                saveError = String(localized: "The server did not confirm the change.")
                selectedModel = nil
            }
        } catch {
            saveError = error.localizedDescription
            selectedModel = nil
        }

        isSaving = false
        isSavingCustom = false
    }

}

private struct ModelPickerSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search models", text: $text)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear model search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ModelPickerCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct ModelPickerButton: View {
    let title: String
    var isLoading = false
    let action: () -> Void

    init(_ title: String, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
