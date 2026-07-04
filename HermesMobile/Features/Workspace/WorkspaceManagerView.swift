import SwiftUI

/// Workspace-registry management sheet (issue #22): add, rename, reorder, and
/// remove registered workspaces. Removal only unregisters a path from the
/// server's list — it never deletes files — and is confirmation-gated.
struct WorkspaceManagerView: View {
    @State private var viewModel: WorkspaceRegistryViewModel

    /// Called when the sheet disappears after at least one successful mutation,
    /// so the presenting surface can refresh its own copy of the registry.
    private let onRegistryChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsAddSheet = false
    @State private var renameTargetPath: String?
    @State private var renameText = ""

    init(server: URL, onRegistryChanged: @escaping () async -> Void) {
        _viewModel = State(initialValue: WorkspaceRegistryViewModel(server: server))
        self.onRegistryChanged = onRegistryChanged
    }

    init(viewModel: WorkspaceRegistryViewModel, onRegistryChanged: @escaping () async -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onRegistryChanged = onRegistryChanged
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if viewModel.managementUnavailable {
                    Section {
                        Text("Workspace management isn't available on this server.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.rows.isEmpty {
                    Section {
                        ForEach(viewModel.rows, id: \.path) { workspace in
                            workspaceRow(workspace)
                        }
                        .onMove { source, destination in
                            Task {
                                await viewModel.moveWorkspaces(fromOffsets: source, toOffset: destination)
                            }
                        }
                        .onDelete { offsets in
                            guard let index = offsets.first, viewModel.rows.indices.contains(index) else { return }
                            viewModel.requestRemoval(of: viewModel.rows[index])
                        }
                    } footer: {
                        Text("Removing a workspace only unregisters its path from the server's list. No files are deleted.")
                    }
                } else if !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("No Workspaces", systemImage: "folder")
                    } description: {
                        Text("Add a workspace to make it available when starting sessions.")
                    }
                }
            }
            .navigationTitle("Manage Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                        .disabled(viewModel.rows.isEmpty)

                    Button {
                        showsAddSheet = true
                    } label: {
                        Label("Add Workspace", systemImage: "plus")
                    }
                    .disabled(viewModel.isMutating)
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.rows.isEmpty {
                    ProgressView()
                }
            }
            .task {
                await viewModel.load()
            }
            .sheet(isPresented: $showsAddSheet) {
                WorkspaceAddSheet(viewModel: viewModel)
            }
            .alert(
                "Rename Workspace",
                isPresented: renameAlertBinding
            ) {
                TextField("Workspace name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    renameTargetPath = nil
                }
                Button("Save") {
                    let path = renameTargetPath
                    let name = renameText
                    renameTargetPath = nil
                    guard let path else { return }
                    Task {
                        await viewModel.renameWorkspace(path: path, to: name)
                    }
                }
            }
            .confirmationDialog(
                "Remove Workspace?",
                isPresented: removalDialogBinding,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        await viewModel.confirmPendingRemoval()
                    }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelPendingRemoval()
                }
            } message: {
                Text("Removing a workspace only unregisters its path from the server's list. No files are deleted.")
            }
            .onDisappear {
                guard viewModel.didMutateRegistry else { return }
                Task {
                    await onRegistryChanged()
                }
            }
        }
    }

    private func workspaceRow(_ workspace: WorkspaceRoot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayName(for: workspace))
                .font(.body)

            if let path = workspace.path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                renameText = workspace.name ?? ""
                renameTargetPath = workspace.path
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func displayName(for workspace: WorkspaceRoot) -> String {
        if let name = workspace.name, !name.isEmpty {
            return name
        }
        return workspace.path?.lastPathComponentFallback ?? ""
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTargetPath != nil },
            set: { isPresented in
                if !isPresented {
                    renameTargetPath = nil
                }
            }
        )
    }

    private var removalDialogBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelPendingRemoval()
                }
            }
        )
    }
}

/// Add-workspace form: path (with server suggestions), optional display name,
/// and an opt-in "create the folder" flag mirroring the web UI's Add Space.
private struct WorkspaceAddSheet: View {
    let viewModel: WorkspaceRegistryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var name = ""
    @State private var createIfMissing = false
    @State private var suggestions: [String] = []
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Workspace path", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Name (optional)", text: $name)

                    Toggle("Create the folder if it doesn't exist", isOn: $createIfMissing)
                } footer: {
                    Text("Suggestions are limited to trusted workspace roots from the server.")
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !filteredSuggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(filteredSuggestions, id: \.self) { suggestion in
                            Button {
                                path = suggestion
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(Color(.secondaryLabel))
                                    Text(suggestion)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        submit()
                    }
                    .disabled(trimmedPath.isEmpty || isSubmitting)
                }
            }
            .task(id: path) {
                if !path.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                suggestions = await viewModel.loadSuggestions(prefix: path)
            }
        }
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSuggestions: [String] {
        var seen = Set<String>()
        return suggestions.filter { !$0.isEmpty && $0 != trimmedPath && seen.insert($0).inserted }
    }

    private func submit() {
        guard !trimmedPath.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            let succeeded = await viewModel.addWorkspace(path: trimmedPath, name: name, create: createIfMissing)
            isSubmitting = false
            if succeeded {
                dismiss()
            }
        }
    }
}
