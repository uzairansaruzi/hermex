import SwiftUI

struct FileBrowserView: View {
    let onAPIError: (Error) -> Void

    private let session: SessionSummary
    private let server: URL
    @State private var viewModel: FileBrowserViewModel
    @State private var searchText = ""

    init(session: SessionSummary, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.session = session
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: FileBrowserViewModel(session: session, server: server))
    }

    var body: some View {
        VStack(spacing: 0) {
            pathHeader
            searchBar

            content
                .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.workspace)
        }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadInitialRootIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.entries.isEmpty {
            ProgressView("Loading files...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage, viewModel.entries.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Files", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadRoot() }
                }
            }
        } else if visibleEntries.isEmpty {
            ContentUnavailableView {
                Label(searchText.isEmpty ? "No Files" : "No Matches", systemImage: searchText.isEmpty ? "folder" : "magnifyingglass")
            } description: {
                if searchText.isEmpty {
                    Text(viewModel.currentPath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Try a different file name or path.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            List(visibleEntries) { entry in
                if entry.isBrowsableDirectory {
                    Button {
                        Task { await load(path: entry.path ?? ".") }
                    } label: {
                        FileBrowserRow(entry: entry, showsDisclosure: true)
                    }
                    .buttonStyle(.plain)
                } else if entry.path != nil {
                    NavigationLink {
                        FilePreviewView(session: session, server: server, entry: entry, onAPIError: onAPIError)
                    } label: {
                        FileBrowserRow(entry: entry, showsDisclosure: false)
                    }
                } else {
                    FileBrowserRow(entry: entry, showsDisclosure: false)
                }
            }
            .refreshable {
                await reloadCurrentPath()
            }
            .listStyle(.plain)
        }
    }

    private var pathHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Location")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(viewModel.displayPath)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await loadRoot() }
                } label: {
                    Label("Root", systemImage: "house")
                }
                .disabled(viewModel.isAtRoot)

                Button {
                    guard let parentPath = viewModel.parentPath else { return }
                    Task { await load(path: parentPath) }
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(viewModel.parentPath == nil)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(viewModel.breadcrumbs.enumerated()), id: \.element.id) { index, breadcrumb in
                            if index > 0 {
                                Image(systemName: "chevron.forward")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }

                            Button {
                                Task { await load(path: breadcrumb.path) }
                            } label: {
                                Text(breadcrumb.title)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .disabled(breadcrumb.path == viewModel.currentPath)
                            .accessibilityLabel("Open \(breadcrumb.title)")
                        }
                    }
                    .frame(height: 30)
                }
                .frame(height: 30)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
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
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var visibleEntries: [WorkspaceEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.entries }

        return viewModel.entries.filter { entry in
            entry.searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    private func loadRoot() async {
        await viewModel.loadRoot()
        handleLastError()
    }

    private func loadInitialRootIfNeeded() async {
        await viewModel.loadInitialRootIfNeeded()
        handleLastError()
    }

    private func reloadCurrentPath() async {
        await viewModel.reloadCurrentPath()
        handleLastError()
    }

    private func load(path: String) async {
        await viewModel.load(path: path)
        handleLastError()
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

private struct FileBrowserRow: View {
    let entry: WorkspaceEntry
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconBackground)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if let detailText {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var displayName: String {
        let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Untitled")
        }
        return name
    }

    private var detailText: String? {
        if isDirectory {
            return entry.path
        }

        guard let size = entry.size else {
            return entry.path
        }

        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var accessibilityLabel: String {
        let kind = isDirectory ? String(localized: "Folder") : String(localized: "File")
        if let detailText {
            return String(localized: "\(kind), \(displayName), \(detailText)")
        }
        return String(localized: "\(kind), \(displayName)")
    }

    private var isDirectory: Bool {
        entry.isBrowsableDirectory
    }

    private var iconName: String {
        isDirectory ? "folder" : "doc.text"
    }

    private var iconColor: Color {
        isDirectory ? .primary : .secondary
    }

    private var iconBackground: Color {
        isDirectory ? Color(.tertiarySystemFill) : Color(.secondarySystemFill)
    }
}

private extension WorkspaceEntry {
    var searchableText: String {
        [name, path, type]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
