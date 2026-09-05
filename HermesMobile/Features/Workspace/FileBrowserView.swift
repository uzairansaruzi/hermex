import SwiftUI

/// The workspace file tree: folders open in place, search keeps matches with their parents,
/// and a file row pushes its preview.
struct FileBrowserView: View {
    let onAPIError: (Error) -> Void

    private let session: SessionSummary
    private let server: URL
    @State private var viewModel: FileBrowserViewModel
    @State private var searchText = ""
    @State private var openedFile: FileTreeNode?

    init(session: SessionSummary, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.session = session
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: FileBrowserViewModel(session: session, server: server))
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
                session: session,
                server: server,
                entry: node.entry,
                prefetchedFile: viewModel.prefetchedFile(at: node.path),
                onAPIError: onAPIError
            )
        }
        .task {
            await viewModel.loadInitialRootIfNeeded()
            handleLastError()
        }
    }

    @ViewBuilder
    private var content: some View {
        let visibleNodes = viewModel.visibleNodes(matching: searchText)

        if viewModel.isLoadingRoot && !viewModel.tree.isRootLoaded {
            ProgressView("Loading files...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage, !viewModel.tree.isRootLoaded {
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
        } else if visibleNodes.isEmpty {
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
            List(visibleNodes) { item in
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

        viewModel.keepPrefetch(for: node.path)
        openedFile = node
        Task { await viewModel.select(path: node.path) }
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
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

                Image(systemName: iconName)
                    .font(.system(size: 17))
                    .foregroundStyle(iconColor)
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

    private var iconName: String {
        if node.isSymlink { return "link" }
        return node.isDirectory ? (isExpanded ? "folder.fill" : "folder") : "doc.text"
    }

    private var iconColor: Color {
        node.isDirectory ? .accentColor : .secondary
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
