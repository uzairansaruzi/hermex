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
            ScrollView {
                VStack(spacing: 24) {
                    ProfilePickerSearchField(text: $searchText)

                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    profileListContent

                    // The server 403s profile creation in single-profile mode,
                    // so the affordance is hidden there (#24).
                    if !isSingleProfileMode {
                        newProfileButton
                    }
                }
                .padding()
            }
            .navigationTitle("Default Profile")
            .navigationBarTitleDisplayMode(.inline)
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
    }

    private var newProfileButton: some View {
        Button {
            showsCreateProfile = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.subheadline)
                    .accessibilityHidden(true)

                Text("New Profile")
                    .font(.subheadline.weight(.medium))

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(isLoading)
        .accessibilityHint("Opens the new profile form.")
    }

    @ViewBuilder
    private var profileListContent: some View {
        if isLoading && profiles.isEmpty {
            ProfilePickerCard(title: String(localized: "Profiles")) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading profiles...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let errorMessage, profiles.isEmpty {
            ProfilePickerCard(title: String(localized: "Profiles")) {
                Label("Could Not Load Profiles", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))

                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if filteredProfiles.isEmpty {
            ProfilePickerCard(title: String(localized: "Profiles")) {
                Label("No Matching Profiles", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))

                Text("Try a different profile name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProfilePickerCard(title: String(localized: "Profiles")) {
                VStack(spacing: 0) {
                    ForEach(Array(filteredProfiles.enumerated()), id: \.element) { index, profile in
                        profileRow(profile)

                        if index < filteredProfiles.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var filteredProfiles: [ProfileSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return profiles }

        return profiles.filter { profile in
            profile.displayName.lowercased().contains(query)
                || (profile.normalizedName?.lowercased().contains(query) ?? false)
                || (profile.model?.lowercased().contains(query) ?? false)
                || (profile.provider?.lowercased().contains(query) ?? false)
        }
    }

    private func profileRow(_ profile: ProfileSummary) -> some View {
        Button {
            Task { await save(profile) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                        if isSelected(profile) {
                            ProfileStatusBadge(title: String(localized: "Selected"))
                        } else if profile.isDefault == true {
                            ProfileStatusBadge(title: String(localized: "Server Default"))
                        }
                    }

                    if let details = profileDetails(profile) {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                }

                Spacer(minLength: 12)

                if isSaving && selectedProfileName == profile.normalizedName {
                    ProgressView()
                } else if isSelected(profile) {
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
        .disabled(isSaving || profile.normalizedName == nil)
        .accessibilityLabel(profileAccessibilityLabel(for: profile))
        .accessibilityValue(profileAccessibilityValue(for: profile))
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
            errorMessage = error.localizedDescription
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
            if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                saveError = error
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
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profile name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isCreating)
                } footer: {
                    Text("Lowercase letters, numbers, hyphens, and underscores; must start with a letter or number.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
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
                        .disabled(!ProfileNameRules.isValid(trimmedName))
                    }
                }
            }
            .interactiveDismissDisabled(isCreating)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() async {
        let profileName = trimmedName
        guard ProfileNameRules.isValid(profileName) else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            let response = try await APIClient(baseURL: server).createProfile(name: profileName)
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

private struct ProfilePickerSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search profiles", text: $text)
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
                .accessibilityLabel("Clear profile search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ProfilePickerCard<Content: View>: View {
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

private struct ProfileStatusBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
    }
}
