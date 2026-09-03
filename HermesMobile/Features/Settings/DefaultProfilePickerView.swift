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
            List {
                if let saveError {
                    Text(verbatim: saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                ForEach(filteredProfiles, id: \.self) { profile in
                    profileRow(profile)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                // The server 403s profile creation in single-profile mode,
                // so the affordance is hidden there (#24).
                if !isSingleProfileMode {
                    newProfileRow
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                statusPlaceholder
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
                    // Optimistic append so the new profile is visible immediately,
                    // then a fresh fetch reconciles paths/flags from the server.
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

    /// Loading, load-failure, empty, and no-match states. Each only stands in
    /// for an empty list, so an already-loaded list keeps rendering across a
    /// refresh.
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

    /// "New Profile" is the last row of the list, on the shared picker's row
    /// geometry, so it reads as part of the list rather than as its own card.
    /// It keeps the entry chrome rather than the filled pill: a second filled
    /// pill would compete with the selected profile.
    private var newProfileRow: some View {
        Button {
            showsCreateProfile = true
        } label: {
            Label("New Profile", systemImage: "plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 12)
        .background(
            Color(.tertiarySystemFill),
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

    /// `profiles` narrowed to `query`. Static so tests can pin the predicate
    /// without driving SwiftUI.
    static func filteredProfiles(_ profiles: [ProfileSummary], query: String) -> [ProfileSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }

        return profiles.filter { matches($0, query: query) }
    }

    /// A profile is findable by every string the row can show: the name the
    /// picker prints, the name it saves, its model, and its provider.
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
                // Same rule as the model picker: an unknown provider renders
                // nothing at all rather than reserving an empty glyph slot.
                if ProviderGlyphKind.resolve(providerID: profile.provider) != nil {
                    ProviderGlyph(providerID: profile.provider)
                        .frame(width: 17, height: 17)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(.body)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                        if selected {
                            ProfileStatusBadge(title: String(localized: "Selected"), isInverted: true)
                        } else if profile.isDefault == true {
                            ProfileStatusBadge(title: String(localized: "Server Default"), isInverted: false)
                        }
                    }

                    if let details = profileDetails(profile) {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(
                                selected ? Color(.systemBackground).opacity(0.7) : Color.secondary
                            )
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                }

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
            return "Selected"
        }

        return profile.isDefault == true ? "Server Default" : ""
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
            // A cancelled .task (view dismissed mid-load) must not surface a
            // "cancelled" error into state.
            if !Self.isCancellationError(error) {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    /// Mirrors `SessionListViewModel.isCancellationError`: cancellation arrives
    /// either as `CancellationError` or as a `.cancelled` `URLError`, possibly
    /// wrapped in `APIError.network`.
    static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }

    private func save(_ profile: ProfileSummary) async {
        guard let name = profile.normalizedName else { return }

        isSaving = true
        saveError = nil
        selectedProfileName = name
        defer { isSaving = false }

        do {
            let response = try await APIClient(baseURL: server).switchProfile(name: name)
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
    /// Called with the server-reported profile on success (nil if the response
    /// omitted it); the picker reconciles with a fresh `/api/profiles` fetch.
    let onCreated: (ProfileSummary?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cloneConfig = false
    @State private var modelGroups: [ModelCatalogGroup] = []
    /// nil = "Use active profile default" (the webui form's empty option).
    @State private var selectedModel: ModelCatalogOption?
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profile name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Lowercase letters, numbers, hyphens, and underscores; must start with a letter or number.")
                }

                Section {
                    Toggle("Clone config from active profile", isOn: $cloneConfig)
                }

                Section {
                    modelPicker
                } footer: {
                    Text("Choose from configured providers and models for this new profile.")
                }

                Section {
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("API key", text: $apiKey)
                } footer: {
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
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isCreating)
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

    /// The webui form lists `models` + `extra_models`; the parser doesn't
    /// dedupe across the two, so drop repeats to keep ForEach identity unique.
    private func pickerOptions(for group: ModelCatalogGroup) -> [ModelCatalogOption] {
        var seen = Set<ModelCatalogOption>()
        return (group.models + group.extraModels).filter { seen.insert($0).inserted }
    }

    // The webui lowercases the typed name before validating/submitting —
    // mirror that so "Work" creates "work" instead of dead-ending validation.
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
        // Best-effort, like the webui form: on failure the picker simply keeps
        // only the "Use active profile default" option.
        guard let response = try? await APIClient(baseURL: server).models() else { return }
        modelGroups = response.catalogGroups
    }

    private func create() async {
        let profileName = trimmedName
        guard ProfileNameRules.isValid(profileName), !hasInvalidBaseURL else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        // Mirror the webui payload: a "default" provider id is not a real
        // provider selection and is dropped.
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

/// "Selected" and "Server Default" are different facts — the current default
/// versus what the server would pick on its own — so the row shows both. On
/// the filled selection pill the accent capsule stops reading, so the badge
/// inverts onto the pill instead.
private struct ProfileStatusBadge: View {
    let title: String
    let isInverted: Bool

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isInverted ? Color(.systemBackground) : Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isInverted ? Color(.systemBackground).opacity(0.22) : Color.accentColor.opacity(0.12),
                in: Capsule(style: .continuous)
            )
    }
}
