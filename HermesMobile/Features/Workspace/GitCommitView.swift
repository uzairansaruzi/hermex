import SwiftUI

/// Advanced staging & commit sheet (issue #315, Slice C, surface C).
///
/// Lets the user select changed files, stage / unstage / discard them, generate or write
/// a commit message, and commit (all staged) or commit only the selected paths — with an
/// optional push afterwards. All write actions are disabled while the chat is streaming or
/// viewing cached data; "Suggest message" stays available because it is a read-only call.
struct GitCommitView: View {
    private let session: SessionSummary
    private let server: URL
    let writesDisabled: Bool
    let onAPIError: (Error) -> Void
    /// Called after every successful commit so the host can refresh the toolbar badge.
    let onCommitted: () -> Void

    @State private var viewModel: GitCommitViewModel
    @State private var showsDiscardConfirmation = false
    @State private var pushAfterCommit = false
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.dismiss) private var dismiss

    init(
        session: SessionSummary,
        server: URL,
        writesDisabled: Bool,
        onAPIError: @escaping (Error) -> Void,
        onCommitted: @escaping () -> Void
    ) {
        self.session = session
        self.server = server
        self.writesDisabled = writesDisabled
        self.onAPIError = onAPIError
        self.onCommitted = onCommitted
        _viewModel = State(initialValue: GitCommitViewModel(session: session, server: server))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Commit Changes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    await viewModel.load()
                    if let error = viewModel.lastError { onAPIError(error) }
                }
        }
        .presentationDetents([.large])
        .adaptivePagePresentation()
        .alert("Discard local changes?", isPresented: $showsDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Discard Changes", role: .destructive) {
                Task { await viewModel.discardSelectedOrAll(deleteUntracked: discardIncludesUntracked) }
            }
        } message: {
            Text(discardIncludesUntracked
                ? "This removes local uncommitted changes and deletes untracked files. This cannot be undone."
                : "This removes local uncommitted changes. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.status == nil {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.loadErrorMessage != nil && viewModel.status == nil {
            ContentUnavailableView {
                Label("Could Not Load Changes", systemImage: "exclamationmark.triangle")
            } description: {
                if let detail = viewModel.loadErrorMessage { Text(detail) }
            } actions: {
                Button("Try Again") { Task { await viewModel.load() } }
            }
        } else if !viewModel.hasChanges {
            emptyState
        } else {
            fileList
                .safeAreaInset(edge: .bottom) { commitBar }
        }
    }

    /// Shown when the working tree is clean. Normally "No Changes", but a commit + push can
    /// leave the tree clean while the push fails — the commit bar (the error's usual home)
    /// is gone, so surface `actionErrorMessage` here instead of swallowing it.
    @ViewBuilder
    private var emptyState: some View {
        if let error = viewModel.actionErrorMessage {
            ContentUnavailableView {
                Label("Changes Committed", systemImage: "exclamationmark.icloud")
            } description: {
                Text(error)
            }
        } else {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("Your working tree is clean.")
            )
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                batchActionsBar

                ForEach(viewModel.trackedFiles) { file in
                    GitCommitFileRow(
                        file: file,
                        isSelected: viewModel.isSelected(file),
                        onTap: { viewModel.toggleSelection(file) }
                    )
                }

                if viewModel.status?.truncated == true {
                    Text("Showing first 500 changed files.")
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
            }
            .padding(16)
        }
        .refreshable { await viewModel.load() }
    }

    private var batchActionsBar: some View {
        HStack(spacing: 8) {
            Text(viewModel.hasSelection
                ? "\(viewModel.selectedPaths.count) selected"
                : "All changes")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            batchButton("Stage", systemImage: "plus.circle", running: viewModel.busyOperation == .staging) {
                Task { await viewModel.stageSelectedOrAll() }
            }
            batchButton("Unstage", systemImage: "minus.circle", running: viewModel.busyOperation == .unstaging) {
                Task { await viewModel.unstageSelectedOrAll() }
            }
            batchButton("Discard", systemImage: "trash", running: viewModel.busyOperation == .discarding, role: .destructive) {
                showsDiscardConfirmation = true
            }
        }
    }

    private func batchButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        running: Bool,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            action()
        } label: {
            HStack(spacing: 4) {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(AppFont.caption(weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(writesDisabled || viewModel.isBusy)
    }

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = viewModel.actionErrorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(AppFont.caption())
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 8) {
                TextField("Commit message", text: $viewModel.message, axis: .vertical)
                    .font(AppFont.mono(style: .subheadline))
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                Button {
                    HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
                    Task { await viewModel.suggestMessage() }
                } label: {
                    if viewModel.busyOperation == .suggesting {
                        ProgressView().controlSize(.small).frame(width: 22)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(viewModel.isBusy || !viewModel.hasChanges)
                .accessibilityLabel("Suggest commit message")
            }

            if viewModel.messageWasTruncated {
                Text("Diff was large; message may be partial.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            Toggle("Push after commit", isOn: $pushAfterCommit)
                .font(AppFont.subheadline())
                .disabled(writesDisabled || viewModel.isBusy)

            HStack(spacing: 10) {
                if viewModel.hasSelection {
                    Button {
                        Task { await runCommit { await viewModel.commitSelected(push: pushAfterCommit) } }
                    } label: {
                        commitLabel("Commit Selected")
                    }
                    .buttonStyle(.bordered)
                    .disabled(commitDisabled)
                }

                Button {
                    Task { await runCommit { await viewModel.commit(push: pushAfterCommit) } }
                } label: {
                    commitLabel(pushAfterCommit ? "Commit & Push" : "Commit")
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitDisabled || !viewModel.hasStagedChanges)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func commitLabel(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            if viewModel.busyOperation == .committing {
                ProgressView().controlSize(.small)
            }
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }

    private var commitDisabled: Bool {
        writesDisabled || viewModel.isBusy || viewModel.trimmedMessage.isEmpty
    }

    /// True when discarding the targets can delete a file from disk — i.e. any new file:
    /// untracked, or a staged add/rename (which discard turns into an untracked file to
    /// delete once it is unstaged). Drives the stronger "deletes files" confirmation copy
    /// and the `deleteUntracked` flag, so the server never rejects the discard.
    private var discardIncludesUntracked: Bool {
        let targets = viewModel.hasSelection
            ? viewModel.trackedFiles.filter { viewModel.isSelected($0) }
            : viewModel.trackedFiles
        return targets.contains {
            $0.untracked == true || $0.changeKind == .added || $0.changeKind == .renamed
        }
    }

    private func runCommit(_ commit: @escaping () async -> Bool) async {
        HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
        if await commit() {
            onCommitted()
        }
    }
}

/// One selectable changed-file row in the staging sheet, showing a selection checkbox,
/// the file name + path, diff counts, and whether it is currently staged.
private struct GitCommitFileRow: View {
    let file: GitFile
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

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

                if file.staged == true {
                    Text("Staged")
                        .font(AppFont.caption2(weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
                DiffCountsLabel(additions: file.additions ?? 0, deletions: file.deletions ?? 0)
                GitStatusChip(kind: file.changeKind)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color(.separator).opacity(0.35), lineWidth: isSelected ? 1 : 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
