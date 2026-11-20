import SwiftUI

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
                        .foregroundStyle(selection.isEmpty ? .appSecondary : .appPrimary)
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
        selection.isEmpty ? String(localized: "None") : selection.joined(separator: ", ")
    }
}

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
            AppList(rows: .plain) {
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
            .themedPageBackground()
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

    private var clearRow: some View {
        let selected = selection.isEmpty

        return Button {
            onClear()
        } label: {
            HStack(spacing: 12) {
                Text("None")
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

    private var customSkillEntry: some View {
        let name = customSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isArmed = !name.isEmpty && !selection.contains(name)

        return VStack(spacing: 6) {
            TextField("Skill name", text: $customSkillName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(AppFont.body())
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
                .background(
                    Color(.appFillTertiary),
                    in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
                )

            Button {
                onToggle(name)
                customSkillName = ""
            } label: {
                HStack {
                    Label("Add skill", systemImage: "plus")
                        .font(AppFont.body(weight: .semibold))

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isArmed ? Color(.appCanvas) : Color(.appTextTertiary))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: PickerRowMetrics.minHeight, alignment: .leading)
            .background(
                isArmed ? Color(.appText) : Color.clear,
                in: RoundedRectangle(cornerRadius: PickerRowMetrics.cornerRadius, style: .continuous)
            )
            .disabled(!isArmed)
        }
    }

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                        .font(AppFont.body())
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if let details = Self.details(for: skill) {
                        Text(verbatim: details)
                            .font(AppFont.caption())
                            .foregroundStyle(
                                selected ? Color(.appCanvas).opacity(0.7) : Color(.appTextSecondary)
                            )
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
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
        .disabled(name.isEmpty)
        .accessibilityLabel(Self.details(for: skill).map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func details(for skill: SkillSummary) -> String? {
        CronJobModelSelection.nonEmpty(skill.description ?? "")
            ?? CronJobModelSelection.nonEmpty(skill.category ?? "")
    }
}
