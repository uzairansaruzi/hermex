import SwiftUI

struct MemoryView: View {
    let server: URL
    let onAPIError: (Error) -> Void
    /// The Hermes Profile whose memory this is (#1073), named under the title; nil on webui.
    private let profile: String?

    @State private var viewModel: MemoryViewModel
    @State private var editingSection: MemorySection?

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        profile = nil
        _viewModel = State(initialValue: MemoryViewModel(server: server))
    }

    /// One Hermes Profile's memory, through `client` (#1073).
    init(server: URL, client: any MemoryDataClient, profile: String, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        self.profile = profile
        _viewModel = State(initialValue: MemoryViewModel(server: server, client: client))
    }

    var body: some View {
        content
            .navigationTitle("Memory")
            .modifier(MemoryProfileSubtitle(profile: profile))
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
                    limit: viewModel.characterLimit(for: section),
                    isReadOnly: viewModel.isReadOnly(section),
                    notesNextSession: viewModel.features.editsApplyNextSession,
                    isSaving: viewModel.isSaving,
                    isReloading: viewModel.isReloading,
                    isConflicted: viewModel.conflictedSection == section,
                    errorMessage: viewModel.actionErrorMessage
                ) { content, loaded in
                    let didSave = await viewModel.save(section: section, content: content, loaded: loaded)
                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                    return didSave
                } onReload: {
                    let text = await viewModel.reload(section)
                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                    return text
                }
            }
            .task {
                await loadMemory()
            }
            .transcriptLinks()
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
                ForEach(viewModel.visibleSections) { section in
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
                            isReadOnly: viewModel.isReadOnly(section),
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
            // Wide tables fade into the grouped row they sit on.
            .environment(\.markdownTableEdgeFadeColor, Color(.secondarySystemGroupedBackground))
        }
    }

    private func loadMemory() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

/// A section's title, when it last changed, and its edit button, or a lock for a Hermes file
/// too large to read whole or not text (#1073), which is shown but not edited here.
private struct MemorySectionHeader: View {
    let section: MemorySection
    let modifiedAt: Date?
    let isReadOnly: Bool
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
            if isReadOnly {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Read-only"))
            } else {
                Button(action: onEdit) {
                    Label("Edit \(section.title)", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .disabled(isEditingDisabled)
                .buttonStyle(.borderless)
            }
        }
    }
}

/// Names the Hermes Profile under the Memory title, where the system offers a subtitle.
private struct MemoryProfileSubtitle: ViewModifier {
    let profile: String?

    func body(content: Content) -> some View {
        if #available(iOS 26, *), let profile {
            content.navigationSubtitle(profile)
        } else {
            content
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

/// One section's editor. On a Hermes host (#1073) it also counts the draft against the host's
/// limit beside Save, which it disables over the limit; shows a save that found the file
/// changed on the host as a banner whose Reload replaces the draft; and notes when edits apply.
/// A file Reload finds read-only on the host keeps Save off and says so.
private struct MemoryEditSheet: View {
    let section: MemorySection
    let limit: Int?
    let isReadOnly: Bool
    let notesNextSession: Bool
    let isSaving: Bool
    let isReloading: Bool
    let isConflicted: Bool
    let errorMessage: String?
    /// Saves the draft, given the text the editor last loaded; true once saved.
    let onSave: (String, String) async -> Bool
    /// The host's current text, or nil when it could not be read.
    let onReload: () async -> String?

    @State private var content: String
    /// The text the draft started from: what the editor opened with, or what Reload brought.
    @State private var loaded: String
    @Environment(\.dismiss) private var dismiss

    init(
        section: MemorySection,
        initialContent: String,
        limit: Int?,
        isReadOnly: Bool,
        notesNextSession: Bool,
        isSaving: Bool,
        isReloading: Bool,
        isConflicted: Bool,
        errorMessage: String?,
        onSave: @escaping (String, String) async -> Bool,
        onReload: @escaping () async -> String?
    ) {
        self.section = section
        self.limit = limit
        self.isReadOnly = isReadOnly
        self.notesNextSession = notesNextSession
        self.isSaving = isSaving
        self.isReloading = isReloading
        self.isConflicted = isConflicted
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onReload = onReload
        _content = State(initialValue: initialContent)
        _loaded = State(initialValue: initialContent)
    }

    var body: some View {
        let count = limit.map { MemoryCharacterCount(draft: content, limit: $0) }
        let isBusy = isSaving || isReloading
        NavigationStack {
            Form {
                if isConflicted {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Changed on the host", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .font(.headline)
                            Text("\(section.title) changed since you opened it. Your draft is kept. Reload shows the host's text and drops this draft.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Button("Reload") {
                            Task {
                                if let text = await onReload() {
                                    content = text
                                    loaded = text
                                }
                            }
                        }
                        .disabled(isBusy)
                    }
                }

                Section {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 320)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isBusy)
                        .accessibilityLabel(section.title)
                } header: {
                    Text(section.title)
                } footer: {
                    if isReadOnly {
                        Label("Read-only", systemImage: "lock.fill")
                    } else if notesNextSession {
                        Text("Edits apply from the agent's next session.")
                    }
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
                if let count {
                    ToolbarItem(placement: .principal) {
                        MemoryEditTitle(title: "Edit \(section.title)", count: count)
                    }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isBusy)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await onSave(content, loaded) {
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
                    .disabled(isBusy || isReadOnly || count?.isOver == true)
                }
            }
        }
        .adaptiveFormPresentation()
    }
}

/// The editor's title with the draft's count against the host's limit under it, beside Save,
/// so it stays in view above the keyboard. Over the limit the count turns red and says by how
/// much, which is why Save is off.
private struct MemoryEditTitle: View {
    let title: LocalizedStringKey
    let count: MemoryCharacterCount

    var body: some View {
        let used = count.count.formatted()
        let limit = count.limit.formatted()
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
            Group {
                if count.isOver {
                    Text("\(used) / \(limit) · \(count.overBy.formatted()) over")
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("\(used) of \(limit) characters, \(count.overBy.formatted()) over the limit"))
                } else {
                    Text(verbatim: "\(used) / \(limit)")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("\(used) of \(limit) characters"))
                }
            }
            .font(.caption)
            .monospacedDigit()
        }
        .lineLimit(1)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
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
