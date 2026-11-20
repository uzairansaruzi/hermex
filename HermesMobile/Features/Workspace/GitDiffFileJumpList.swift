import SwiftUI

struct GitDiffFileJumpList: View {
    let files: [GitFile]
    let viewedFileIDs: Set<String>
    let onSelect: (GitFile) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private static let searchThreshold = 8

    var body: some View {
        NavigationStack {
            searchableList
                .themedPageBackground()
                .navigationTitle("Jump to File")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
        }
        .themedPageBackground()
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
        return AppList {
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

    static func files(_ files: [GitFile], matching query: String) -> [GitFile] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return files }
        return files.filter { $0.displayPath.localizedStandardContains(query) }
    }
}

private struct GitDiffFileJumpRow: View {
    let file: GitFile
    let isViewed: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
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
                        .foregroundStyle(.appSecondary)
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
        .foregroundStyle(Color(.appText))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension GitDiffView {
    static func jump(to fileID: String, review: inout ReviewDiffProgress) -> ReviewDiffScrollTarget {
        review.reveal(fileID)
        return ReviewDiffScrollTarget(fileID: fileID, token: UUID())
    }
}
