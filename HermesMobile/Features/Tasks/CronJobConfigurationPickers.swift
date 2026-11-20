import SwiftUI

enum CronJobModelSelection {
    static func resolve(
        modelID: String,
        providerID: String,
        in groups: [ModelCatalogGroup]
    ) -> ModelCatalogOption? {
        guard let modelID = nonEmpty(modelID) else { return nil }
        let providerID = nonEmpty(providerID)

        return groups
            .flatMap(\.allModels)
            .firstMatchingSelection(modelID: modelID, providerID: providerID)
            ?? ModelCatalogOption(id: modelID, displayName: modelID, providerID: providerID)
    }

    static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CronJobModelRow: View {
    let selection: ModelCatalogOption?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(title)
                            .foregroundStyle(.appPrimary)

                        if let providerID = selection?.providerID {
                            Text(verbatim: providerID)
                                .font(AppFont.caption())
                                .foregroundStyle(.appSecondary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)

                    CronJobPickerChevron()
                }
            } label: {
                Text("Model")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Model"))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the task model picker.")
    }

    private var title: String {
        selection.map { ModelDisplayNames.displayLabel(for: $0.id, displayName: $0.displayName) } ?? String(localized: "Server default")
    }

    private var accessibilityValue: Text {
        guard let selection else { return Text("Server default") }
        let modelLabel = ModelDisplayNames.displayLabel(for: selection.id, displayName: selection.displayName)
        guard let providerID = selection.providerID else { return Text(verbatim: modelLabel) }
        return Text(verbatim: "\(modelLabel), \(providerID)")
    }
}

struct CronJobProfileRow: View {
    let profileName: String
    let profiles: [ProfileSummary]
    let errorMessage: String?
    let isLoading: Bool
    var isLocked = false
    let action: () -> Void
    let onRetry: () -> Void

    var body: some View {
        if isLocked {
            LabeledContent {
                Text(verbatim: title)
                    .lineLimit(2)
            } label: {
                Text("Profile")
            }
        } else {
            picker
        }
    }

    @ViewBuilder
    private var picker: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(.appPrimary)
                        .lineLimit(2)

                    CronJobPickerChevron()
                }
            } label: {
                Text("Profile")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Profile"))
        .accessibilityValue(Text(verbatim: title))
        .accessibilityHint("Opens the task profile picker.")

        if let errorMessage, !isLoading {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: errorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)

                Spacer(minLength: 0)

                Button("Try Again", action: onRetry)
                    .font(AppFont.caption(weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var title: String {
        guard let name = CronJobModelSelection.nonEmpty(profileName) else {
            return String(localized: "Server default")
        }

        return profiles.first { $0.normalizedName == name }?.displayName ?? name
    }
}

struct CronJobPickerChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(.appTertiary)
            .accessibilityHidden(true)
    }
}

struct CronJobProfilePickerSheet: View {
    let profiles: [ProfileSummary]
    let selectedProfileName: String
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            AppList(rows: .plain) {
                if trimmedSearchQuery.isEmpty {
                    serverDefaultRow
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                ForEach(listedProfiles, id: \.self) { profile in
                    profileRow(profile)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                statusPlaceholder
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .themedPageBackground()
            .navigationTitle("Task Profile")
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
            } actions: {
                Button("Try Again", action: onRetry)
            }
        } else if listedProfiles.isEmpty, !trimmedSearchQuery.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if profiles.isEmpty {
            ContentUnavailableView("No profiles available", systemImage: "person.crop.circle")
        }
    }

    private var serverDefaultRow: some View {
        let selected = CronJobModelSelection.nonEmpty(selectedProfileName) == nil

        return Button {
            onSelect(nil)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text("Server default")
                    .font(AppFont.body())
                    .lineLimit(2)

                Spacer(minLength: 0)

                if selected {
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var listedProfiles: [ProfileSummary] {
        DefaultProfilePickerView.filteredProfiles(
            Self.profilesIncludingSelection(profiles, selectedProfileName: selectedProfileName),
            query: trimmedSearchQuery
        )
    }

    static func profilesIncludingSelection(
        _ profiles: [ProfileSummary],
        selectedProfileName: String
    ) -> [ProfileSummary] {
        guard let name = CronJobModelSelection.nonEmpty(selectedProfileName),
              !profiles.contains(where: { $0.normalizedName == name }) else { return profiles }

        return [
            ProfileSummary(
                name: name,
                path: nil,
                isDefault: nil,
                isActive: nil,
                gatewayRunning: nil,
                model: nil,
                provider: nil,
                hasEnv: nil,
                skillCount: nil
            )
        ] + profiles
    }

    private func profileRow(_ profile: ProfileSummary) -> some View {
        let selected = profile.normalizedName == CronJobModelSelection.nonEmpty(selectedProfileName)

        return Button {
            onSelect(profile.normalizedName)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if ProviderGlyphKind.resolve(providerID: profile.provider) != nil {
                    ProviderGlyph(providerID: profile.provider)
                        .frame(width: 17, height: 17)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(AppFont.body())
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if let details = Self.details(for: profile) {
                        Text(details)
                            .font(AppFont.caption())
                            .foregroundStyle(
                                selected ? Color(.appCanvas).opacity(0.7) : Color(.appTextSecondary)
                            )
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                }

                Spacer(minLength: 0)

                if selected {
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
        .disabled(profile.normalizedName == nil)
        .accessibilityLabel(Self.details(for: profile).map { "\(profile.displayName), \($0)" } ?? profile.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func details(for profile: ProfileSummary) -> String? {
        var details: [String] = []

        if let model = CronJobModelSelection.nonEmpty(profile.model ?? "") {
            details.append(model)
        }

        if let provider = CronJobModelSelection.nonEmpty(profile.provider ?? "") {
            details.append(provider)
        }

        guard !details.isEmpty else { return nil }
        return details.joined(separator: " - ")
    }
}
