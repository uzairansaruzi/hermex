import SwiftUI

struct GitActionsMenuButton: View {
    let presentation: GitToolbarPresentation
    let isEnabled: Bool
    let fetchDisabled: Bool
    let writesDisabled: Bool
    /// Shows the branch and its distance from upstream as a row and leaves out Fetch and Pull,
    /// for a repository without sync (`GitWriteAvailability.hidesSync`).
    var hidesSync = false
    /// The branch's pull request (#1391), shown first with Copy Link; nil leaves the section out.
    let pullRequest: GitPullRequest?
    let isRunningAction: Bool
    let onTap: () -> Void
    let onOpenPullRequest: (URL) -> Void
    let onCopyPullRequestLink: (URL) -> Void
    let onChanges: () -> Void
    let onStageEdit: () -> Void
    let onCommit: () -> Void
    let onCommitAndPush: () -> Void
    let onFetch: () -> Void
    let onPull: () -> Void
    let onPush: () -> Void

    private var hasChanges: Bool {
        (presentation.status?.changedCount ?? 0) > 0
    }

    var body: some View {
        Menu {
            if let pullRequest {
                Section {
                    Button { onOpenPullRequest(pullRequest.url) } label: {
                        // A string, so the number never takes a grouping separator ("#1,462").
                        Label("Pull Request #\(String(pullRequest.number))", systemImage: "arrow.triangle.pull")
                        if let state = pullRequest.state {
                            Text(state.title)
                        }
                    }

                    HapticButton { onCopyPullRequestLink(pullRequest.url) } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                }
            }

            if hidesSync, let branch = presentation.branchSummary {
                Section {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
            }

            Section("Changes") {
                Button(action: onChanges) {
                    changesLabel
                }
                .disabled(!presentation.changesAreEnabled)

                Button(action: onStageEdit) {
                    Label("Stage Changes…", systemImage: "checklist")
                }
                .disabled(!presentation.changesAreEnabled || !hasChanges)
            }

            writeSections
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .frame(width: 24, height: 24)
        }
        .disabled(!isEnabled)
        .simultaneousGesture(TapGesture().onEnded(onTap))
        .frame(minWidth: 28, minHeight: 28)
        .accessibilityLabel("Git actions")
        .accessibilityValue(Text(presentation.accessibilityValue))
    }

    @ViewBuilder
    private var writeSections: some View {
        Section("Write") {
            HapticButton(feedbackStyle: .medium, action: onCommit) {
                Label("Commit", systemImage: "checkmark.seal")
            }
            .disabled(writesDisabled || isRunningAction || !hasChanges)

            HapticButton(feedbackStyle: .medium, action: onCommitAndPush) {
                Label("Commit & Push", systemImage: "arrow.up.doc")
            }
            .disabled(writesDisabled || isRunningAction || !hasChanges)

            HapticButton(feedbackStyle: .medium, action: onPush) {
                Label("Push", systemImage: "arrow.up.circle")
            }
            .disabled(writesDisabled || isRunningAction)
        }

        if !hidesSync {
            Section("Update") {
                HapticButton(feedbackStyle: .medium, action: onFetch) {
                    Label("Fetch", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .disabled(fetchDisabled || isRunningAction)

                HapticButton(feedbackStyle: .medium, action: onPull) {
                    Label("Pull", systemImage: "arrow.down.circle")
                }
                .disabled(writesDisabled || isRunningAction)
            }
        }
    }

    @ViewBuilder
    private var changesLabel: some View {
        if presentation.statusFailed {
            Label("Changes unavailable", systemImage: "exclamationmark.circle")
        } else if let status = presentation.status, status.changedCount > 0 {
            Label {
                Text("+\(status.totalAdditions)").foregroundStyle(.green)
                + Text("  −\(status.totalDeletions)").foregroundStyle(.red)
                + Text("  \(status.changedCount)").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "doc.text.magnifyingglass")
            }
        } else {
            Label("No changes", systemImage: "checkmark.circle")
        }
    }
}

private extension GitPullRequest.State {
    var title: String {
        switch self {
        case .open: String(localized: "Open", comment: "A pull request's state")
        case .merged: String(localized: "Merged", comment: "A pull request's state")
        case .closed: String(localized: "Closed", comment: "A pull request's state")
        }
    }
}
