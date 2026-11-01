import SwiftUI

/// "Jump to File" for the diff sheet: every file in sheet order with its folder, counts and
/// viewed mark, searchable once the list outgrows a phone screen. Picking a row hands the
/// file to `onSelect`; the host scrolls to it and closes this sheet.
struct GitDiffFileJumpList: View {
    let files: [GitFile]
    let viewedFileIDs: Set<String>
    let onSelect: (GitFile) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    /// About a medium detent's worth of rows; past it, search earns its place.
    private static let searchThreshold = 8

    var body: some View {
        NavigationStack {
            searchableList
                .navigationTitle("Jump to File")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var searchableList: some View {
        if files.count > Self.searchThreshold {
            list.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search files")
        } else {
            list
        }
    }

    private var list: some View {
        let matches = Self.files(files, matching: query)
        return List {
            Section {
                ForEach(matches) { file in
                    Button { onSelect(file) } label: {
                        GitDiffFileJumpRow(file: file, isViewed: viewedFileIDs.contains(file.id))
                    }
                }
            } header: {
                Text("\(files.count) files changed")
            }
        }
        .overlay {
            if matches.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    /// Files whose path contains `query` (folder or name, any case), in sheet order; a
    /// blank query keeps them all.
    static func files(_ files: [GitFile], matching query: String) -> [GitFile] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return files }
        return files.filter { $0.displayPath.localizedStandardContains(query) }
    }
}

/// Name over folder, then counts and a checkmark when viewed. VoiceOver reads it as one
/// element: "name, folder, N added, M removed, Viewed".
private struct GitDiffFileJumpRow: View {
    let file: GitFile
    let isViewed: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Accessibility sizes stack the counts under the path so the name keeps its width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                DiffCountsLabel(additions: file.additions ?? 0, deletions: file.deletions ?? 0)
                if isViewed {
                    Image(systemName: "checkmark")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Viewed")
                }
            }
        }
        // A List button tints its label, and `.primary`/`.secondary` would resolve against
        // that tint; a concrete label colour keeps the name primary and the folder secondary.
        .foregroundStyle(Color.primary)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension GitDiffView {
    /// Picking a file in Jump to File: the file expands as a user choice (`ReviewDiffProgress.reveal`,
    /// so no default refolds it and its viewed mark stays) and the diff scrolls to its header,
    /// again on every pick, even to where it is.
    static func jump(to fileID: String, review: inout ReviewDiffProgress) -> ReviewDiffScrollTarget {
        review.reveal(fileID)
        return ReviewDiffScrollTarget(fileID: fileID, token: UUID())
    }
}
