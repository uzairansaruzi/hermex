import SwiftUI

struct DefaultProfileSelection: Equatable {
    let name: String
    let displayName: String
    let defaultModel: String?
}

struct DefaultProfilePickerView: View {
    let server: URL
    let currentDefaultProfileName: String?
    let onSave: (DefaultProfileSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isLoading = false
    @State private var profiles: [ProfileSummary] = []
    @State private var activeProfileName: String?
    @State private var selectedProfileName: String?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isSingleProfileMode = false
    @State private var showsCreateProfile = false

    var body: some View {
        NavigationStack {
            AppList(rows: .plain) {
                if let saveError {
                    Text(verbatim: saveError)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 12))
                }

                ForEach(filteredProfiles, id: \.self) { profile in
                    profileRow(profile)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                }

                if !isSingleProfileMode {
                    newProfileRow
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 12))
                }

                statusPlaceholder
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .themedPageBackground()
            .navigationTitle("Default Profile")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search profiles"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadProfiles()
            }
            .sheet(isPresented: $showsCreateProfile) {
                CreateProfileSheet(server: server) { createdProfile in
                    if let createdProfile, !profiles.contains(createdProfile) {
                        profiles.append(createdProfile)
                    }
                    Task { await loadProfiles() }
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

    @ViewBuilder
    private var statusPlaceholder: some View {
        if profiles.isEmpty, isLoading {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading profiles...")
            }
        } else if profiles.isEmpty, let errorMessage {
            ContentUnavailableView {
                Label("Could Not Load Profiles", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: errorMessage)
            }
        } else if filteredProfiles.isEmpty, !trimmedSearchQuery.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if profiles.isEmpty {
            ContentUnavailableView("No profiles available", systemImage: "person.crop.circle")
        }
    }

    private var newProfileRow: some View {
        Button {
            showsCreateProfile = true
        } label: {
            Label("New Profile", systemImage: "plus")
                .font(AppFont.body(weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(.appText))
        .padding(.horizontal, 12)
        .background(
            Color(.appFillTertiary),
            in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
        )
        .disabled(isLoading || isSaving)
        .accessibilityHint("Opens the new profile form.")
    }

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredProfiles: [ProfileSummary] {
        Self.filteredProfiles(profiles, query: trimmedSearchQuery)
    }

    static func filteredProfiles(_ profiles: [ProfileSummary], query: String) -> [ProfileSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }

        return profiles.filter { matches($0, query: query) }
    }

    static func matches(_ profile: ProfileSummary, query: String) -> Bool {
        profile.displayName.localizedCaseInsensitiveContains(query)
            || (profile.normalizedName?.localizedCaseInsensitiveContains(query) ?? false)
            || (profile.model?.localizedCaseInsensitiveContains(query) ?? false)
            || (profile.provider?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func profileRow(_ profile: ProfileSummary) -> some View {
        let selected = isSelected(profile)
        let inFlight = isSaving && selectedProfileName == profile.normalizedName

        return Button {
            Task { await save(profile) }
        } label: {
            HStack(spacing: 12) {
                if ProviderGlyphKind.resolve(providerID: profile.provider) != nil {
                    ProviderGlyph(providerID: profile.provider)
                        .frame(width: 17, height: 17)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(AppFont.body())
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                        if selected {
                            ProfileStatusBadge(title: String(localized: "Selected"), isInverted: true)
                        } else if profile.isDefault == true {
                            ProfileStatusBadge(title: String(localized: "Server Default"), isInverted: false)
                        }
                    }

                    if let details = profileDetails(profile) {
                        Text(details)
                            .font(AppFont.caption())
                            .foregroundStyle(
                                selected ? Color(.appCanvas).opacity(0.7) : Color(.appTextSecondary)
                            )
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
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
        .pickerSelectionPill(isSelected: selected)
        .disabled(isSaving || profile.normalizedName == nil)
        .accessibilityLabel(profileAccessibilityLabel(for: profile))
        .accessibilityValue(profileAccessibilityValue(for: profile))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func profileAccessibilityLabel(for profile: ProfileSummary) -> String {
        guard let details = profileDetails(profile) else {
            return profile.displayName
        }

        return "\(profile.displayName), \(details)"
    }

    private func profileAccessibilityValue(for profile: ProfileSummary) -> String {
        if isSelected(profile) {
            return String(localized: "Selected")
        }

        return profile.isDefault == true ? String(localized: "Server Default") : ""
    }

    private func isSelected(_ profile: ProfileSummary) -> Bool {
        guard let name = profile.normalizedName else { return false }
        return selectedProfileName == name || activeProfileName == name
    }

    private func profileDetails(_ profile: ProfileSummary) -> String? {
        var details: [String] = []

        if let model = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            details.append(model)
        }

        if let provider = profile.provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            details.append(provider)
        }

        if let skillCount = profile.skillCount {
            details.append(String(localized: "\(skillCount) skills"))
        }

        guard !details.isEmpty else { return nil }
        return details.joined(separator: " - ")
    }

    private func loadProfiles() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let response = try await APIClient(baseURL: server).profiles()
            profiles = response.profiles ?? []
            activeProfileName = response.effectiveDefaultProfileName ?? currentDefaultProfileName
            isSingleProfileMode = response.singleProfileMode ?? false
        } catch {
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func save(_ profile: ProfileSummary) async {
        guard let name = profile.normalizedName else { return }

        isSaving = true
        saveError = nil
        selectedProfileName = name
        defer { isSaving = false }

        do {
            let response = try await APIClient(baseURL: server).switchProfile(name: name)
            guard !Task.isCancelled else { return }
            if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                saveError = error
                selectedProfileName = nil
                return
            }

            let returnedActiveName = response.active?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = returnedActiveName?.isEmpty == false ? returnedActiveName : name
            let updatedProfiles = response.profiles ?? profiles
            let selectionResponse = ProfilesResponse(profiles: updatedProfiles, active: resolvedName)
            profiles = updatedProfiles
            activeProfileName = selectionResponse.effectiveDefaultProfileName ?? name

            let selection = DefaultProfileSelection(
                name: activeProfileName ?? name,
                displayName: selectionResponse.displayName(for: activeProfileName) ?? profile.displayName,
                defaultModel: response.defaultModel
            )
            onSave(selection)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            selectedProfileName = nil
        }
    }
}

private struct CreateProfileSheet: View {
    let server: URL
    let onCreated: (ProfileSummary?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cloneConfig = false
    @State private var modelGroups: [ModelCatalogGroup] = []
    @State private var selectedModel: ModelCatalogOption?
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField("Profile name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } appFooter: {
                    Text("Lowercase letters, numbers, hyphens, and underscores; must start with a letter or number.")
                }

                Section {
                    Toggle("Clone config from active profile", isOn: $cloneConfig)
                }

                Section {
                    modelPicker
                } appFooter: {
                    Text("Choose from configured providers and models for this new profile.")
                }

                Section {
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("API key", text: $apiKey)
                } appFooter: {
                    if hasInvalidBaseURL {
                        Text("Base URL must start with http:// or https://.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Optional. Base URL example: http://localhost:11434")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppFont.caption())
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isCreating)
            .themedPageBackground()
            .navigationTitle("New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isCreating)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(!ProfileNameRules.isValid(trimmedName) || hasInvalidBaseURL)
                    }
                }
            }
            .interactiveDismissDisabled(isCreating)
            .task {
                await loadModels()
            }
        }
        .adaptiveFormPresentation()
    }

    private var modelPicker: some View {
        Picker("Model", selection: $selectedModel) {
            Text("Use active profile default")
                .tag(ModelCatalogOption?.none)

            ForEach(modelGroups) { group in
                Section(group.name) {
                    ForEach(pickerOptions(for: group)) { option in
                        Text(option.displayName)
                            .tag(Optional(option))
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }

    private func pickerOptions(for group: ModelCatalogGroup) -> [ModelCatalogOption] {
        var seen = Set<ModelCatalogOption>()
        return (group.models + group.extraModels).filter { seen.insert($0).inserted }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasInvalidBaseURL: Bool {
        !trimmedBaseURL.isEmpty && !ProfileNameRules.isValidBaseURL(trimmedBaseURL)
    }

    private func loadModels() async {
        guard let response = try? await APIClient(baseURL: server).models() else { return }
        modelGroups = response.catalogGroups
    }

    private func create() async {
        let profileName = trimmedName
        guard ProfileNameRules.isValid(profileName), !hasInvalidBaseURL else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let provider = selectedModel?.providerID
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let response = try await APIClient(baseURL: server).createProfile(
                name: profileName,
                cloneConfig: cloneConfig,
                defaultModel: selectedModel?.id,
                modelProvider: provider == "default" ? nil : provider,
                baseUrl: trimmedBaseURL.isEmpty ? nil : trimmedBaseURL,
                apiKey: trimmedAPIKey.isEmpty ? nil : trimmedAPIKey
            )
            if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                errorMessage = error
                return
            }

            onCreated(response.profile)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProfileStatusBadge: View {
    let title: String
    let isInverted: Bool

    var body: some View {
        Text(title)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(isInverted ? Color(.appCanvas) : Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isInverted ? Color(.appCanvas).opacity(0.22) : Color.accentColor.opacity(0.12),
                in: Capsule(style: .continuous)
            )
    }
}
