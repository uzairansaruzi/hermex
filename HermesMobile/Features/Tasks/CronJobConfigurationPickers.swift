import SwiftUI

/// Resolves what the Task editor's Model row shows for a draft.
enum CronJobModelSelection {
    /// The option the row renders, or `nil` for "Server default".
    ///
    /// A model the catalog no longer offers resolves to itself rather than to
    /// nothing, so a task configured last month against a since-removed model
    /// keeps showing which model that was instead of quietly reading as
    /// unconfigured. Same rule as the picker's `Current Custom` group.
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

/// The Task editor's Model row: the current model and provider, or "Server
/// default" when the draft leaves both blank.
///
/// No provider glyph here, unlike the picker's own rows. A Form row gives the
/// value whatever width the label leaves it, and a glyph in front of a long
/// model name is the difference between "Muse Spark 1.3 Contributor Free"
/// fitting and clipping. The glyphs stay inside the picker, where the rows are
/// full-width.
struct CronJobModelRow: View {
    let selection: ModelCatalogOption?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(title)
                            .foregroundStyle(.primary)

                        if let providerID = selection?.providerID {
                            Text(verbatim: providerID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
        selection?.displayName ?? String(localized: "Server default")
    }

    private var accessibilityValue: Text {
        guard let selection else { return Text("Server default") }
        guard let providerID = selection.providerID else { return Text(verbatim: selection.displayName) }
        return Text(verbatim: "\(selection.displayName), \(providerID)")
    }
}

/// The Task editor's Profile row, plus the inline load failure and retry that
/// replace it when `/api/profiles` will not load. Free text is not an option
/// here: upstream 400s an unknown profile name, so typing one has exactly one
/// failure mode the user cannot predict.
struct CronJobProfileRow: View {
    let profileName: String
    let profiles: [ProfileSummary]
    let errorMessage: String?
    let isLoading: Bool
    let action: () -> Void
    let onRetry: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(.primary)
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

        // The saved value keeps showing above; only the list is missing.
        if let errorMessage, !isLoading {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)

                Spacer(minLength: 0)

                Button("Try Again", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// The saved name still renders when the list will not load, so an existing
    /// job never looks unconfigured because a request failed.
    private var title: String {
        guard let name = CronJobModelSelection.nonEmpty(profileName) else {
            return String(localized: "Server default")
        }

        return profiles.first { $0.normalizedName == name }?.displayName ?? name
    }
}

/// Trailing affordance on a Form row that opens a sheet rather than pushing.
private struct CronJobPickerChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// The Task editor's profile picker. Presentation follows Settings > Default
/// Profile (48pt body rows, leading provider glyph, filled selection pill), but
/// this one only writes to the editor's draft — it never switches the server's
/// active profile.
struct CronJobProfilePickerSheet: View {
    let profiles: [ProfileSummary]
    let selectedProfileName: String
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void
    /// `nil` clears the draft's profile back to the server's own choice.
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
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

    /// Loading, load-failure with a retry, no-match, and empty. Each only
    /// stands in for an empty list, so a loaded list keeps rendering across a
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
                    .font(.body)
                    .lineLimit(2)

                Spacer(minLength: 0)

                if selected {
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server's list, plus a row for a saved profile the server no longer
    /// lists, so an existing job's selection is always visible and always
    /// checked.
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
                // Same rule as the model picker: an unknown provider renders
                // nothing at all rather than reserving an empty glyph slot.
                if ProviderGlyphKind.resolve(providerID: profile.provider) != nil {
                    ProviderGlyph(providerID: profile.provider)
                        .frame(width: 17, height: 17)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.body)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    // The profile's own model and provider, so the inheritance
                    // the section footer describes is visible rather than
                    // implied.
                    if let details = Self.details(for: profile) {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(
                                selected ? Color(.systemBackground).opacity(0.7) : Color.secondary
                            )
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }
                }

                Spacer(minLength: 0)

                if selected {
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
