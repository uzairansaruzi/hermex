import SwiftUI

/// The Task editor's Skills row and its multi-select picker. Separate from the
/// model and profile pickers because it is the only one that commits a
/// collection: the sheet stays open as rows toggle, and each toggle writes
/// straight to the draft.

/// The Task editor's Skills row, plus the inline load failure and retry that
/// replace it when `/api/skills` will not load.
struct CronJobSkillsRow: View {
    let selection: [String]
    let errorMessage: String?
    let isLoading: Bool
    let action: () -> Void
    let onRetry: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)

                    CronJobPickerChevron()
                }
            } label: {
                Text("Skills")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Skills"))
        .accessibilityValue(Text(verbatim: title))
        .accessibilityHint("Opens the task skills picker.")

        // The saved skills keep showing above; only the list is missing.
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

    /// The selected names themselves rather than a count: three skills fit, and
    /// "3 skills" would make the row's own value unreadable without opening it.
    private var title: String {
        selection.isEmpty ? String(localized: "None") : selection.joined(separator: ", ")
    }
}

/// The Task editor's skills picker. Multi-select, so it stays open as rows are
/// toggled and commits each change straight to the draft.
///
/// Unlike the profile picker this one keeps a free-text entry: upstream accepts
/// `skills` unvalidated, and without it a failed `/api/skills` would turn a
/// field that used to accept anything into a read-only one.
struct CronJobSkillsPickerSheet: View {
    let skills: [SkillSummary]
    let selection: [String]
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void
    let onToggle: (String) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var customSkillName = ""

    var body: some View {
        NavigationStack {
            List {
                if trimmedSearchQuery.isEmpty {
                    clearRow
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                ForEach(listedSkills, id: \.id) { skill in
                    skillRow(skill)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                        .listRowSeparator(.hidden)
                }

                customSkillEntry
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)

                statusPlaceholder
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Task Skills")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search skills"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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
        if skills.isEmpty, isLoading {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading skills...")
            }
        } else if skills.isEmpty, let errorMessage {
            ContentUnavailableView {
                Label("Could Not Load Skills", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: errorMessage)
            } actions: {
                Button("Try Again", action: onRetry)
            }
        } else if listedSkills.isEmpty, !trimmedSearchQuery.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if skills.isEmpty {
            ContentUnavailableView("No skills available", systemImage: "wand.and.stars")
        }
    }

    /// Clears every selected skill at once. Deselecting one at a time still
    /// works; this is the way out of a long list.
    private var clearRow: some View {
        let selected = selection.isEmpty

        return Button {
            onClear()
        } label: {
            HStack(spacing: 12) {
                Text("None")
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

    private var customSkillEntry: some View {
        let name = customSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isArmed = !name.isEmpty && !selection.contains(name)

        return VStack(spacing: 6) {
            TextField("Skill name", text: $customSkillName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
                .background(
                    Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
                )

            Button {
                onToggle(name)
                customSkillName = ""
            } label: {
                HStack {
                    Label("Add skill", systemImage: "plus")
                        .font(.body.weight(.semibold))

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isArmed ? Color(.systemBackground) : Color(.tertiaryLabel))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
            .background(
                isArmed ? Color.primary : Color.clear,
                in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
            )
            .disabled(!isArmed)
        }
    }

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server's list, plus a row for every selected skill it does not
    /// offer, so a saved selection is always visible and always removable.
    private var listedSkills: [SkillSummary] {
        Self.filteredSkills(
            Self.skillsIncludingSelection(skills, selection: selection),
            query: trimmedSearchQuery
        )
    }

    static func skillsIncludingSelection(
        _ skills: [SkillSummary],
        selection: [String]
    ) -> [SkillSummary] {
        let known = Set(skills.compactMap(\.name))
        let missing = selection.filter { !known.contains($0) }
        guard !missing.isEmpty else { return skills }

        return missing.map { SkillSummary(name: $0, category: nil, description: nil, path: nil) } + skills
    }

    /// A skill is findable by every string its row shows.
    static func filteredSkills(_ skills: [SkillSummary], query: String) -> [SkillSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }

        return skills.filter { skill in
            (skill.name?.localizedCaseInsensitiveContains(query) ?? false)
                || (skill.category?.localizedCaseInsensitiveContains(query) ?? false)
                || (skill.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func skillRow(_ skill: SkillSummary) -> some View {
        let name = skill.name ?? ""
        let selected = selection.contains(name)

        return Button {
            onToggle(name)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name)
                        .font(.body)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if let details = Self.details(for: skill) {
                        Text(verbatim: details)
                            .font(.caption)
                            .foregroundStyle(
                                selected ? Color(.systemBackground).opacity(0.7) : Color.secondary
                            )
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
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
        .disabled(name.isEmpty)
        .accessibilityLabel(Self.details(for: skill).map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func details(for skill: SkillSummary) -> String? {
        CronJobModelSelection.nonEmpty(skill.description ?? "")
            ?? CronJobModelSelection.nonEmpty(skill.category ?? "")
    }
}
