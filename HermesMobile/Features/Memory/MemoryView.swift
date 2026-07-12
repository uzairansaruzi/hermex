import SwiftUI

struct MemoryView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: MemoryViewModel
    @State private var editingSection: MemorySection?

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: MemoryViewModel(server: server))
    }

    var body: some View {
        content
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadMemory() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .sheet(item: $editingSection) { section in
                MemoryEditSheet(
                    section: section,
                    initialContent: viewModel.content(for: section),
                    isSaving: viewModel.isSaving,
                    errorMessage: viewModel.actionErrorMessage
                ) { content in
                    let didSave = await viewModel.save(section: section, content: content)
                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                    return didSave
                }
            }
            .task {
                await loadMemory()
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            ProgressView("Loading memory...")
        } else if let errorMessage = viewModel.errorMessage, !viewModel.hasLoaded {
            ContentUnavailableView {
                Label("Could Not Load Memory", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadMemory() }
                }
            }
        } else if !viewModel.hasLoaded {
            ProgressView("Loading memory...")
        } else {
            List {
                ForEach(MemorySection.allCases) { section in
                    Section {
                        MemorySectionContent(
                            section: section,
                            content: viewModel.content(for: section)
                        )
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    } header: {
                        MemorySectionHeader(
                            section: section,
                            modifiedAt: viewModel.modifiedAt(for: section),
                            isEditingDisabled: viewModel.isSaving
                        ) {
                            viewModel.clearActionError()
                            editingSection = section
                        }
                    }
                }

                if viewModel.showsProjectContext {
                    Section {
                        MarkdownRenderer(content: viewModel.projectContextText ?? "")
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    } header: {
                        ProjectContextSectionHeader(modifiedAt: viewModel.projectContextMtime)
                    } footer: {
                        ProjectContextSectionFooter(
                            detail: viewModel.projectContextDetail,
                            isShadowed: viewModel.isProjectContextShadowed
                        )
                    }
                }
            }
            .refreshable {
                await loadMemory()
            }
        }
    }

    private func loadMemory() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

private struct MemorySectionHeader: View {
    let section: MemorySection
    let modifiedAt: Date?
    let isEditingDisabled: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(section.title, systemImage: section.systemImage)
            Spacer()
            if let modifiedAt {
                Text("Modified \(modifiedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: onEdit) {
                Label("Edit \(section.title)", systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .disabled(isEditingDisabled)
            .buttonStyle(.borderless)
        }
    }
}

/// Header for the read-only project-context document: no edit affordance — the
/// server has no write path for this section — so a lock icon marks it read-only.
private struct ProjectContextSectionHeader: View {
    let modifiedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            Label("Project Context", systemImage: "folder.badge.gearshape")
            Spacer()
            if let modifiedAt {
                Text("Modified \(modifiedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Read-only"))
        }
    }
}

private struct ProjectContextSectionFooter: View {
    let detail: String?
    let isShadowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail {
                Text(verbatim: detail)
            }
            if isShadowed {
                Text("A workspace-local file is overriding the global project context.")
            }
        }
    }
}

private struct MemorySectionContent: View {
    let section: MemorySection
    let content: String

    var body: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(section.emptyMessage)
                .foregroundStyle(.secondary)
                .italic()
        } else {
            MarkdownRenderer(content: content)
        }
    }
}

private struct MemoryEditSheet: View {
    let section: MemorySection
    let isSaving: Bool
    let errorMessage: String?
    let onSave: (String) async -> Bool

    @State private var content: String
    @Environment(\.dismiss) private var dismiss

    init(
        section: MemorySection,
        initialContent: String,
        isSaving: Bool,
        errorMessage: String?,
        onSave: @escaping (String) async -> Bool
    ) {
        self.section = section
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onSave = onSave
        _content = State(initialValue: initialContent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(section.title) {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 320)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isSaving)
                        .accessibilityLabel(section.title)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit \(section.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await onSave(content) {
                                dismiss()
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

private extension MemorySection {
    var title: String {
        switch self {
        case .memory:
            return String(localized: "My Notes")
        case .user:
            return String(localized: "User Profile")
        case .soul:
            return String(localized: "Agent Soul")
        }
    }

    var emptyMessage: String {
        switch self {
        case .memory:
            return String(localized: "No notes yet.")
        case .user:
            return String(localized: "No profile yet.")
        case .soul:
            return String(localized: "No soul defined yet.")
        }
    }

    var systemImage: String {
        switch self {
        case .memory:
            return "brain"
        case .user:
            return "person.crop.circle"
        case .soul:
            return "sparkles"
        }
    }
}
