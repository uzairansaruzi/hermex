import SwiftUI

struct GitWorkspaceView: View {
    let onAPIError: (Error) -> Void

    private let session: SessionSummary
    private let server: URL
    @State private var viewModel: GitWorkspaceViewModel
    @State private var selectedFile: GitFile?
    @Environment(\.dismiss) private var dismiss

    init(session: SessionSummary, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.session = session
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: GitWorkspaceViewModel(session: session, server: server))
    }

    var body: some View {
        NavigationStack {
            content
                .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.workspace)
                .navigationTitle("Git")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    await viewModel.loadIfNeeded()
                    handleLastError()
                }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $selectedFile) { file in
            GitDiffView(session: session, server: server, file: file, onAPIError: onAPIError)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.status == nil {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.errorMessage != nil && viewModel.status == nil {
            unavailable("Could Not Load Changes", image: "exclamationmark.triangle", detail: viewModel.errorMessage) {
                Task { await reload() }
            }
        } else if viewModel.isNonRepository {
            ContentUnavailableView(
                "Not a Git Repository",
                systemImage: "folder.badge.questionmark",
                description: Text("Git actions are unavailable for this workspace.")
            )
        } else if let status = viewModel.status {
            statusContent(status)
        } else {
            unavailable("Could Not Load Changes", image: "exclamationmark.triangle", detail: viewModel.errorMessage) {
                Task { await reload() }
            }
        }
    }

    private func statusContent(_ status: GitStatus) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summaryHeader(status)

                if status.trackedFiles.isEmpty {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "checkmark.circle",
                        description: Text("Your working tree is clean.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                } else {
                    ForEach(status.trackedFiles) { file in
                        Button {
                            selectedFile = file
                        } label: {
                            GitFileCard(file: file)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if status.truncated == true {
                    Text("Showing first 500 changed files.")
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            }
            .padding(16)
        }
        .refreshable { await reload() }
    }

    private func summaryHeader(_ status: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(status.changedCount) files changed")
                    .font(AppFont.subheadline(weight: .semibold))
                Spacer()
                DiffCountsLabel(additions: status.totalAdditions, deletions: status.totalDeletions)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(status.branch ?? "HEAD")
                    .font(AppFont.mono(style: .subheadline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                GitAheadBehindBadges(ahead: status.ahead ?? 0, behind: status.behind ?? 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func unavailable(
        _ title: LocalizedStringKey,
        image: String,
        detail: String?,
        retry: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: image)
        } description: {
            if let detail { Text(detail) }
        } actions: {
            Button("Try Again", action: retry)
        }
    }

    private func reload() async {
        await viewModel.load()
        handleLastError()
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError { onAPIError(lastError) }
    }
}

struct GitAheadBehindBadges: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        if ahead > 0 || behind > 0 {
            Text(verbatim: "↑\(ahead) ↓\(behind)")
                .font(AppFont.mono(style: .caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct DiffCountsLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "+\(additions)").foregroundStyle(.green)
            Text(verbatim: "−\(deletions)").foregroundStyle(.red)
        }
        .font(AppFont.mono(style: .caption, weight: .semibold))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(additions) added") + Text(verbatim: ", ") + Text("\(deletions) removed")
        )
    }
}

struct GitFileCard: View {
    let file: GitFile

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.fileName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let parent = file.parentDirectory {
                    Text(parent)
                        .font(AppFont.mono(style: .caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            DiffCountsLabel(additions: file.additions ?? 0, deletions: file.deletions ?? 0)
            GitStatusChip(kind: file.changeKind)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct GitStatusChip: View {
    let kind: GitFile.ChangeKind

    var body: some View {
        if let label {
            Text(label)
                .font(AppFont.caption2(weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.18), in: Capsule())
                .foregroundStyle(tint)
        }
    }

    private var label: String? {
        switch kind {
        case .modified: return String(localized: "Modified")
        case .added: return String(localized: "Added")
        case .deleted: return String(localized: "Deleted")
        case .renamed: return String(localized: "Renamed")
        case .untracked: return String(localized: "Untracked")
        case .conflict: return String(localized: "Conflict")
        case .ignored, .unknown: return nil
        }
    }

    private var tint: Color {
        switch kind {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .conflict: return .orange
        case .modified: return .yellow
        case .ignored, .unknown: return .secondary
        }
    }
}
