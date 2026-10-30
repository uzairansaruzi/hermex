import SwiftUI

/// The workspace file tree: folders open in place, search keeps matches with their parents,
/// and a file row pushes its preview. With a `search`, a query also lists the host's matching
/// files from folders not yet opened in a Workspace section above the tree's ("Open Folders")
/// (#1389). A client for another workspace, as when a Hermes chat's folder moves, replaces the
/// whole tree.
struct FileBrowserView: View {
    let onAPIError: (Error) -> Void
    /// Forwarded to each pushed preview's Comment…; nil outside a chat that can take a draft.
    let onAddToPrompt: ((String) -> Void)?

    private let files: (any WorkspaceFileClient)?
    private let search: FileWorkspaceSearch?
    @State private var viewModel: FileBrowserViewModel
    @State private var searchText = ""
    /// Bumped by the Workspace section's Try Again, which runs the same query again.
    @State private var searchAttempt = 0
    @State private var openedFile: FileTreeNode?
    /// The warm fetch handed over when `openedFile` was tapped; consumed by that preview only.
    @State private var openedFilePrefetch: Task<FileResponse, Error>?

    init(
        files: (any WorkspaceFileClient)?,
        search: FileWorkspaceSearch? = nil,
        onAPIError: @escaping (Error) -> Void,
        onAddToPrompt: ((String) -> Void)? = nil
    ) {
        self.files = files
        self.search = search
        self.onAPIError = onAPIError
        self.onAddToPrompt = onAddToPrompt
        _viewModel = State(initialValue: FileBrowserViewModel(files: files))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            content
                .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.workspace)
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedFile) { node in
            FilePreviewView(
                files: files,
                entry: node.entry,
                prefetchedFile: openedFilePrefetch,
                onAPIError: onAPIError,
                onAddToPrompt: onAddToPrompt
            )
            .id(node.id)
        }
        // A file opened from the old workspace reads through the old client: close it.
        .onChange(of: files?.scope) {
            openedFile = nil
            openedFilePrefetch?.cancel()
            openedFilePrefetch = nil
        }
        .task(id: files?.scope) {
            await viewModel.switchWorkspace(to: files)
            await viewModel.loadInitialRootIfNeeded()
            handleLastError()
        }
        .task(id: WorkspaceSearchKey(query: searchText, scope: files?.scope, attempt: searchAttempt)) {
            await viewModel.searchWorkspace(searchText, in: files?.scope, using: search)
        }
    }

    @ViewBuilder
    private var content: some View {
        let visibleNodes = viewModel.visibleNodes(matching: searchText)
        let workspaceSearch = search == nil ? nil
            : viewModel.workspaceSearchState(for: searchText, in: files?.scope, hiding: visibleNodes)
        let showsWorkspaceSection = workspaceSearch.map { $0 != .found([]) } ?? false

        // A workspace search keeps the list up while the root loads or fails; the bar over
        // it carries the root's progress, error and retry.
        if viewModel.isLoadingRoot && !viewModel.tree.isRootLoaded && !showsWorkspaceSection {
            ProgressView("Loading files...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage, !viewModel.tree.isRootLoaded, !showsWorkspaceSection {
            ContentUnavailableView {
                Label("Could Not Load Files", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task {
                        await viewModel.retryRoot()
                        handleLastError()
                    }
                }
            }
        } else if visibleNodes.isEmpty, !showsWorkspaceSection {
            ContentUnavailableView {
                Label(searchText.isEmpty ? "No Files" : "No Matches", systemImage: searchText.isEmpty ? "folder" : "magnifyingglass")
            } description: {
                if !searchText.isEmpty {
                    Text("Try a different file name or path.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            List {
                if let workspaceSearch, showsWorkspaceSection {
                    workspaceSection(workspaceSearch)
                    if !visibleNodes.isEmpty {
                        Section {
                            treeRows(visibleNodes)
                        } header: {
                            sectionHeader("Open Folders")
                        }
                    }
                } else {
                    treeRows(visibleNodes)
                }
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.refresh()
                handleLastError()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if viewModel.isLoadingRoot {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading files...")
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                } else if let errorMessage = viewModel.errorMessage {
                    HStack(spacing: 12) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Spacer(minLength: 0)

                        Button("Try Again") {
                            Task {
                                await viewModel.retryRoot()
                                handleLastError()
                            }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                }
            }
        }
    }

    private func treeRows(_ visibleNodes: [VisibleFileTreeNode]) -> some View {
        ForEach(visibleNodes) { item in
            FileTreeRowView(
                item: item,
                isExpanded: viewModel.isExpanded(item.node.path),
                isLoading: viewModel.isLoading(item.node.path),
                isSelected: item.node.path == viewModel.selectedPath,
                hasLoadFailure: viewModel.loadFailure(for: item.node.path) != nil,
                childCount: viewModel.childCount(of: item.node.path),
                onPressDown: { viewModel.prefetchFile(at: item.node.path) },
                onTap: { open(item.node) }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
        }
    }

    /// The host's matches for the query (#1389): static "Searching…" until they land, an inline
    /// Try Again when the search failed, else one row per file.
    private func workspaceSection(_ state: WorkspaceSearchState) -> some View {
        Section {
            switch state {
            case .searching:
                Text("Searching…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
            case .unavailable:
                HStack(spacing: 12) {
                    Label("Workspace search unavailable", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button("Try Again") { searchAttempt += 1 }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                .frame(minHeight: 42)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
            case .found(let matches):
                ForEach(matches) { match in
                    WorkspaceSearchRowView(match: match) { open(match) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            sectionHeader("Workspace")
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search files", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear file search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func open(_ node: FileTreeNode) {
        if node.isDirectory {
            Task {
                await viewModel.toggleDirectory(node.path)
                handleLastError()
            }
            return
        }

        openedFilePrefetch = viewModel.takePrefetch(for: node.path)
        openedFile = node
        Task { await viewModel.select(path: node.path) }
    }

    /// Opens a Workspace hit's preview without selecting it, which would list every folder
    /// above it (#1233).
    private func open(_ match: ComposerFilePathSearch.Match) {
        guard let node = viewModel.openWorkspaceHit(match) else { return }
        openedFilePrefetch = nil
        openedFile = node
    }

    private func handleLastError() {
        if let error = viewModel.takeLastError() {
            onAPIError(error)
        }
    }
}

/// What re-runs the Workspace search: the query, the workspace it searches, and Try Again.
private struct WorkspaceSearchKey: Equatable {
    let query: String
    let scope: String?
    let attempt: Int
}

/// One Workspace hit (#1389): the file's name over its folder, at the tree's top-level indent.
private struct WorkspaceSearchRowView: View {
    let match: ComposerFilePathSearch.Match
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 12, height: 1)

                FileIcon.resolve(match.name).image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(match.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !match.parentPath.isEmpty {
                        Text(match.parentPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(FileTreeRowButtonStyle(isSelected: false, onPressChanged: { _ in }))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(match.parentPath.isEmpty ? match.name : String(localized: "\(match.name), in \(match.parentPath)"))
    }
}

/// One tree row: 42 pt tall, indented 18 pt per level, chevron for folders, child count once
/// the folder has been listed. Press-down warms the file preview before the tap lands.
private struct FileTreeRowView: View {
    let item: VisibleFileTreeNode
    let isExpanded: Bool
    let isLoading: Bool
    let isSelected: Bool
    let hasLoadFailure: Bool
    let childCount: Int?
    let onPressDown: () -> Void
    let onTap: () -> Void

    private var node: FileTreeNode { item.node }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }

                icon
                    .frame(width: 22)

                Text(node.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected || node.isDirectory ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                trailingAccessory
            }
            .padding(.leading, 8 + CGFloat(item.depth) * 18)
            .padding(.trailing, 12)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(FileTreeRowButtonStyle(isSelected: isSelected, onPressChanged: { isPressed in
            if isPressed, !node.isDirectory {
                onPressDown()
            }
        }))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if node.isDirectory {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if hasLoadFailure {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let childCount {
                Text(childCount, format: .number)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// Folders and symlinks are quiet grey symbols; a file shows the glyph for its type.
    /// Everything sits at 17 pt so the column lines up.
    @ViewBuilder
    private var icon: some View {
        if node.isDirectory || node.isSymlink {
            Image(systemName: node.isSymlink ? "link" : "folder")
                .font(.system(size: 17))
                .foregroundStyle(Color(uiColor: .systemGray))
        } else {
            FileIcon.resolve(node.name).image
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
        }
    }

    private var accessibilityLabel: String {
        let kind: String
        if node.isSymlink {
            kind = String(localized: "Link")
        } else {
            kind = node.isDirectory ? String(localized: "Folder") : String(localized: "File")
        }
        return String(localized: "\(kind), \(node.name)")
    }

    private var accessibilityValue: String {
        guard node.isDirectory else { return "" }
        if hasLoadFailure { return String(localized: "Could Not Load Files") }
        return isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
    }
}

/// Highlights the row while pressed and reports press changes so the row can prefetch.
private struct FileTreeRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(background(isPressed: configuration.isPressed))
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isPressed)
            }
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed { return Color(.tertiarySystemFill) }
        return isSelected ? Color(.secondarySystemFill) : .clear
    }
}
