import SwiftUI

/// Turn-end "File changes" recap card shown under the latest assistant turn for git
/// workspaces (issue #316, Slice D, surface B). The per-file list is derived from the
/// turn's tool-call metadata and joined to `git/status` for counts/chips. The card is
/// collapsible (default expanded); the header "Open diff" opens the per-turn diff sheet
/// and each file row opens that file's diff. The host owns the actual sheet presentation.
struct GitTurnChangesCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var isExpanded = true

    let summary: TurnFileChangeSummary
    /// Open the diff sheet for every changed file in the turn (header "Open diff").
    let onOpenAll: () -> Void
    /// Open a single file's diff (per-row tap). Only called for rows with a status match.
    let onOpenFile: (GitFile) -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }
    private var dividerColor: Color { Color(.separator).opacity(colorScheme == .dark ? 0.8 : 1.0) }
    private var showsTotals: Bool { summary.totalAdditions > 0 || summary.totalDeletions > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                divider
                ForEach(Array(summary.changes.enumerated()), id: \.element.id) { index, change in
                    fileRow(change)
                    if index != summary.changes.count - 1 {
                        divider.padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: shape)
        .overlay { shape.stroke(dividerColor, lineWidth: 0.5) }
        .clipShape(shape)
        .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)

            Text("File changes")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)

            if showsTotals {
                DiffCountsLabel(additions: summary.totalAdditions, deletions: summary.totalDeletions)
            }

            Spacer(minLength: 8)

            if !summary.diffFiles.isEmpty {
                headerButton(systemImage: "arrow.up.right", accessibility: "Open diff") {
                    HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
                    onOpenAll()
                }
            }

            headerButton(
                systemImage: "chevron.down",
                accessibility: isExpanded
                    ? String(localized: "Collapse file changes")
                    : String(localized: "Expand file changes"),
                rotation: isExpanded ? 0 : -90
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    private func headerButton(
        systemImage: String,
        accessibility: String,
        rotation: Double = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private func fileRow(_ change: TurnFileChange) -> some View {
        Button {
            guard let file = change.gitFile else { return }
            HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            onOpenFile(file)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(change.gitFile?.displayPath ?? change.path)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if change.additions > 0 || change.deletions > 0 {
                    DiffCountsLabel(additions: change.additions, deletions: change.deletions)
                }

                GitStatusChip(kind: change.changeKind)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(change.gitFile == nil)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(dividerColor).frame(height: 0.5)
    }
}

/// Per-turn diff sheet: lists the turn's changed files and drills into each file's diff
/// (reusing the restyled #318 `GitDiffView`). Presented for the composer capsule tap and
/// the recap card's "Open diff" button.
struct GitTurnDiffSheet: View {
    let session: SessionSummary
    let server: URL
    let files: [GitFile]
    let onAPIError: (Error) -> Void

    @State private var selectedFile: GitFile?
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        files.count == 1
            ? String(localized: "1 file changed")
            : String(localized: "\(files.count) files changed")
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
        .adaptivePagePresentation()
        .sheet(item: $selectedFile) { file in
            GitDiffView(session: session, server: server, file: file, onAPIError: onAPIError)
        }
    }

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            ContentUnavailableView(
                "No File Diffs",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Diffs for this turn aren't available yet.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(files) { file in
                        Button {
                            selectedFile = file
                        } label: {
                            GitFileCard(file: file)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }
}
