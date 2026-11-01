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

/// The folder a Hermes project is made on (#1052): its primary, where the sessions it holds
/// work. The field offers the host's own folders as the user types.
struct ProjectFolderField {
    /// What the field starts with, such as the working folder of the session being moved.
    var initialPath: String
    /// The host's folders that complete a typed path, each ending in `/`, and whether to ask
    /// for more of the name.
    var complete: (String) async -> HermesFolderCompletion.Suggestions
}

struct ProjectCreationSheet: View {
    let isSaving: Bool
    let folder: ProjectFolderField?
    let errorMessage: String?
    let onCancel: () -> Void
    /// The name, the color and, with a `folder` field, the folder.
    let onSave: (String, String, String?) -> Void

    private let initialColor: ProjectColorOption

    /// `folder` adds the required folder field a Hermes project needs; `errorMessage` is the
    /// server's reason for refusing the last save.
    init(
        existingProjectCount: Int,
        isSaving: Bool,
        folder: ProjectFolderField? = nil,
        errorMessage: String? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String, String?) -> Void
    ) {
        self.isSaving = isSaving
        self.folder = folder
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onSave = onSave
        initialColor = ProjectCreationPalette.defaultColor(existingProjectCount: existingProjectCount)
    }

    var body: some View {
        ProjectFormSheet(
            title: String(localized: "New Project"),
            initialName: "",
            initialColorHex: initialColor.hex,
            folder: folder,
            errorMessage: errorMessage,
            isSaving: isSaving,
            onCancel: onCancel
        ) { name, color, folder in
            onSave(name, color ?? initialColor.hex, folder)
        }
    }
}

struct ProjectRenameSheet: View {
    let project: ProjectSummary
    let isSaving: Bool
    /// The server's reason for refusing the last save.
    var errorMessage: String?
    let onCancel: () -> Void
    let onSave: (String, String?) -> Void

    var body: some View {
        ProjectFormSheet(
            title: String(localized: "Rename Project"),
            initialName: project.name ?? "",
            initialColorHex: project.color,
            folder: nil,
            errorMessage: errorMessage,
            isSaving: isSaving,
            onCancel: onCancel
        ) { name, color, _ in
            onSave(name, color)
        }
    }
}

private struct ProjectFormSheet: View {
    /// The most host folders the folder field offers at once.
    private static let folderSuggestionLimit = 8

    let title: String
    let folder: ProjectFolderField?
    let errorMessage: String?
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (String, String?, String?) -> Void

    @State private var projectName: String
    @State private var selectedColorHex: String?
    @State private var folderPath: String
    @State private var folderSuggestions: [String] = []
    @State private var folderNeedsMoreTyping = false
    @FocusState private var nameIsFocused: Bool

    init(
        title: String,
        initialName: String,
        initialColorHex: String?,
        folder: ProjectFolderField?,
        errorMessage: String?,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String?, String?) -> Void
    ) {
        self.title = title
        self.folder = folder
        self.errorMessage = errorMessage
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        _projectName = State(initialValue: initialName)
        _selectedColorHex = State(initialValue: initialColorHex)
        _folderPath = State(initialValue: folder?.initialPath ?? "")
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

                if let folder {
                    folderSection(folder)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
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
                        onSave(trimmedProjectName, selectedColorHex, folder == nil ? nil : trimmedFolderPath)
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(trimmedProjectName.isEmpty || (folder != nil && trimmedFolderPath.isEmpty) || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                nameIsFocused = true
            }
        }
        .adaptiveFormPresentation()
    }

    private var trimmedProjectName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedFolderPath: String {
        folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The folder field and, under it, the host's folders that complete what is typed, or a hint
    /// to type more when the host's listing ran out before any folder. A pick fills the field and
    /// lists that folder's own folders next.
    private func folderSection(_ folder: ProjectFolderField) -> some View {
        Section {
            TextField(text: $folderPath, prompt: Text(verbatim: "~/Projects/app")) {
                Text("Folder")
            }
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(isSaving)

            ForEach(folderSuggestions, id: \.self) { suggestion in
                Button {
                    folderPath = suggestion
                } label: {
                    // A host folder's name is the user's own text, never a catalog key.
                    Label {
                        Text(verbatim: suggestion.split(separator: "/").last.map(String.init) ?? suggestion)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .lineLimit(1)
                }
                .disabled(isSaving)
                .accessibilityLabel(Text(verbatim: suggestion))
            }

            if folderNeedsMoreTyping {
                Text("Type more of the folder name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Folder")
        } footer: {
            Text("Sessions working in this folder belong to the project.")
        }
        .task(id: folderPath) {
            // Waits for a pause in typing, and a newer path cancels this one.
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
            let suggestions = await folder.complete(trimmedFolderPath)
            guard !Task.isCancelled else { return }
            folderSuggestions = Array(suggestions.folders.filter { $0 != trimmedFolderPath }.prefix(Self.folderSuggestionLimit))
            folderNeedsMoreTyping = suggestions.needsMoreTyping
        }
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
