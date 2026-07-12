import SwiftUI

struct ProjectColorOption: Identifiable, Equatable {
    let name: String
    let hex: String

    var id: String { hex }

    var color: Color {
        Color(hexString: hex) ?? .accentColor
    }
}

enum ProjectCreationPalette {
    static let approvedColors: [ProjectColorOption] = [
        ProjectColorOption(name: String(localized: "Sky"), hex: "#7cb9ff"),
        ProjectColorOption(name: String(localized: "Gold"), hex: "#f5c542"),
        ProjectColorOption(name: String(localized: "Red"), hex: "#e94560"),
        ProjectColorOption(name: String(localized: "Green"), hex: "#50c878"),
        ProjectColorOption(name: String(localized: "Violet"), hex: "#c084fc"),
        ProjectColorOption(name: String(localized: "Orange"), hex: "#fb923c"),
        ProjectColorOption(name: String(localized: "Cyan"), hex: "#67e8f9"),
        ProjectColorOption(name: String(localized: "Pink"), hex: "#f472b6")
    ]

    static func defaultColor(existingProjectCount: Int) -> ProjectColorOption {
        approvedColors[existingProjectCount % approvedColors.count]
    }
}

struct ProjectCreationSheet: View {
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (String, String) -> Void

    private let initialColor: ProjectColorOption

    init(
        existingProjectCount: Int,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String) -> Void
    ) {
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        initialColor = ProjectCreationPalette.defaultColor(existingProjectCount: existingProjectCount)
    }

    var body: some View {
        ProjectFormSheet(
            title: String(localized: "New Project"),
            initialName: "",
            initialColorHex: initialColor.hex,
            isSaving: isSaving,
            onCancel: onCancel
        ) { name, color in
            onSave(name, color ?? initialColor.hex)
        }
    }
}

struct ProjectRenameSheet: View {
    let project: ProjectSummary
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (String, String?) -> Void

    var body: some View {
        ProjectFormSheet(
            title: String(localized: "Rename Project"),
            initialName: project.name ?? "",
            initialColorHex: project.color,
            isSaving: isSaving,
            onCancel: onCancel,
            onSave: onSave
        )
    }
}

private struct ProjectFormSheet: View {
    let title: String
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (String, String?) -> Void

    @State private var projectName: String
    @State private var selectedColorHex: String?
    @FocusState private var nameIsFocused: Bool

    init(
        title: String,
        initialName: String,
        initialColorHex: String?,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String?) -> Void
    ) {
        self.title = title
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        _projectName = State(initialValue: initialName)
        _selectedColorHex = State(initialValue: initialColorHex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $projectName)
                        .textInputAutocapitalization(.words)
                        .focused($nameIsFocused)
                        .disabled(isSaving)
                }

                Section("Color") {
                    LazyVGrid(columns: colorColumns, alignment: .leading, spacing: 16) {
                        ForEach(ProjectCreationPalette.approvedColors) { option in
                            colorButton(for: option)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(trimmedProjectName, selectedColorHex)
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(trimmedProjectName.isEmpty || isSaving)
                }
            }
            .onAppear {
                nameIsFocused = true
            }
        }
        .adaptiveFormPresentation()
    }

    private var trimmedProjectName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var colorColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 44), spacing: 16)]
    }

    private func colorButton(for option: ProjectColorOption) -> some View {
        let isSelected = selectedColorHex?.caseInsensitiveCompare(option.hex) == .orderedSame

        return Button {
            selectedColorHex = option.hex
        } label: {
            ZStack {
                Circle()
                    .fill(option.color)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Circle()
                            .strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5)
                    }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(checkmarkColor(for: option.hex))
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func checkmarkColor(for hex: String) -> Color {
        HeaderLogoColor.prefersDarkForeground(for: hex) ? .black : .white
    }
}
