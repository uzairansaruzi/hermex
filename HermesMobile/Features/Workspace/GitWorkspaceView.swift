import SwiftUI

/// The Changes sheet: the working tree's uncommitted files and, on a Hermes host, what the branch
/// committed since its base (This Branch, #1386). Each opens every listed file in one `GitDiffView`
/// at the tapped one. It only reads: writes live in the commit sheet and the Git menu.
struct GitWorkspaceView: View {
    let onAPIError: (Error) -> Void
    /// Forwarded to the diff surface so a line selection can land in the composer.
    let onAddToPrompt: ((String) -> Void)?

    private let git: (any GitDataClient)?
    private let progress: ReviewProgressStore
    @State private var viewModel: GitWorkspaceViewModel
    @State private var openedReview: OpenedReview?
    /// The latest Try Again load, cancelled by the next one and when the sheet closes.
    @State private var retryTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    /// The tapped file with the rows and range it was listed in.
    private struct OpenedReview: Identifiable {
        let file: GitFile
        let files: [GitFile]
        let scope: GitReviewScope
        let base: String?

        var id: String { "\(scope)|\(file.id)" }
    }

    /// `git` is the chat's repository client, shared with its toolbar menu; `progress` is the
    /// chat's review progress, which each complete read of a scope prunes within that scope.
    init(
        git: (any GitDataClient)?,
        progress: ReviewProgressStore,
        onAPIError: @escaping (Error) -> Void,
        onAddToPrompt: ((String) -> Void)? = nil
    ) {
        self.git = git
        self.onAPIError = onAPIError
        self.onAddToPrompt = onAddToPrompt
        self.progress = progress
        _viewModel = State(initialValue: GitWorkspaceViewModel(git: git, progress: progress))
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
                // A switch cancels the other scope's read, which then publishes nothing.
                .task(id: viewModel.scope) {
                    await viewModel.loadIfNeeded()
                    handleLastError()
                }
        }
        .onDisappear { retryTask?.cancel() }
        .presentationDetents([.medium, .large])
        .adaptivePagePresentation()
        .sheet(item: $openedReview) { opened in
            GitDiffView(
                git: git,
                files: opened.files,
                initialFile: opened.file,
                scope: opened.scope,
                base: opened.base,
                progress: progress,
                onAPIError: onAPIError,
                onAddToPrompt: onAddToPrompt
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.showsScopePicker {
            VStack(spacing: 0) {
                Picker("Changes", selection: $viewModel.scope) {
                    Text("Uncommitted").tag(GitReviewScope.uncommitted)
                    Text("This Branch").tag(GitReviewScope.branch)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 8)

                switch viewModel.scope {
                case .uncommitted, .since: uncommittedContent
                case .branch: branchContent
                }
            }
        } else {
            uncommittedContent
        }
    }

    @ViewBuilder
    private var uncommittedContent: some View {
        if viewModel.showsStatusFailure {
            unavailable("Could Not Load Changes", image: "exclamationmark.triangle", detail: viewModel.errorMessage) {
                retry()
            }
        } else if viewModel.isNonRepository {
            notARepository
        } else if let status = viewModel.status {
            statusContent(status)
        } else {
            loading
        }
    }

    @ViewBuilder
    private var branchContent: some View {
        if viewModel.branchErrorMessage != nil {
            unavailable("Could Not Load Changes", image: "exclamationmark.triangle", detail: viewModel.branchErrorMessage) {
                retry()
            }
        } else if let review = viewModel.branchReview {
            branchReviewContent(review)
        } else if viewModel.hasLoadedBranch && !viewModel.isLoadingBranch {
            notARepository
        } else {
            loading
        }
    }

    private var loading: some View {
        ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notARepository: some View {
        ContentUnavailableView(
            "Not a Git Repository",
            systemImage: "folder.badge.questionmark",
            description: Text("Git actions are unavailable for this workspace.")
        )
    }

    private func statusContent(_ status: GitStatus) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summaryHeader(changed: status.changedCount, additions: status.totalAdditions,
                              deletions: status.totalDeletions, branch: status.branch) {
                    GitAheadBehindBadges(ahead: status.ahead ?? 0, behind: status.behind ?? 0)
                }

                if status.trackedFiles.isEmpty {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "checkmark.circle",
                        description: Text("Your working tree is clean.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                } else {
                    fileCards(status.trackedFiles, scope: .uncommitted, base: nil)
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

    /// The branch's committed files. The host doesn't say which branch it took the base from, so
    /// the header never names one.
    private func branchReviewContent(_ review: GitBranchReview) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summaryHeader(changed: review.files.count, additions: review.totalAdditions,
                              deletions: review.totalDeletions, branch: review.branch,
                              note: review.base == nil ? nil : "Compared with branch base") {
                    if review.detached { GitDetachedChip() }
                }

                if review.files.isEmpty {
                    Group {
                        if review.base == nil {
                            ContentUnavailableView("No base branch found", systemImage: "arrow.triangle.branch")
                        } else {
                            ContentUnavailableView(
                                "No Changes",
                                systemImage: "checkmark.circle",
                                description: Text("No committed changes against the branch base.")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                } else {
                    fileCards(review.files, scope: .branch, base: review.base)
                }
            }
            .padding(16)
        }
        .refreshable { await reload() }
    }

    private func fileCards(_ files: [GitFile], scope: GitReviewScope, base: String?) -> some View {
        ForEach(files) { file in
            Button {
                openedReview = OpenedReview(file: file, files: files, scope: scope, base: base)
            } label: {
                GitFileCard(file: file)
            }
            .buttonStyle(.plain)
        }
    }

    /// The file count and totals, then the branch (`HEAD` when it has no name) with `accessory`
    /// at its end, then `note`.
    private func summaryHeader(
        changed: Int,
        additions: Int,
        deletions: Int,
        branch: String?,
        note: LocalizedStringKey? = nil,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(changed) files changed")
                    .font(AppFont.subheadline(weight: .semibold))
                Spacer()
                DiffCountsLabel(additions: additions, deletions: deletions)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(branch ?? "HEAD")
                    .font(AppFont.mono(style: .subheadline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                accessory()
            }

            if let note {
                Text(note)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
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

    private func retry() {
        retryTask?.cancel()
        retryTask = Task { await reload() }
    }

    private func reload() async {
        await viewModel.load()
        handleLastError()
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError { onAPIError(lastError) }
    }
}

/// "Detached", beside a detached HEAD's name.
private struct GitDetachedChip: View {
    var body: some View {
        Text("Detached")
            .font(AppFont.caption2(weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
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

/// "+N −M" in green and red. `deletions: nil` hides the red count, for a
/// change whose deletions are unknown (a written file's old content).
struct DiffCountsLabel: View {
    let additions: Int
    let deletions: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "+\(additions)").foregroundStyle(.green)
            if let deletions {
                Text(verbatim: "−\(deletions)").foregroundStyle(.red)
            }
        }
        .font(AppFont.mono(style: .caption, weight: .semibold))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenText(additions: additions, deletions: deletions))
    }

    /// "3 added, 1 removed", or "3 added" when deletions are unknown.
    static func spokenText(additions: Int, deletions: Int?) -> String {
        let added = String(localized: "\(additions) added")
        guard let deletions else { return added }
        return added + ", " + String(localized: "\(deletions) removed")
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
