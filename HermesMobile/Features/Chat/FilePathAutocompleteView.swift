import SwiftUI

/// The `@` panel: the workspace files and folders that match the path being
/// typed, on the same glass as the `/` panel so the two read as one surface.
struct FilePathAutocompleteView: View {
    // Row height tracks Dynamic Type so the panel is never taller or shorter
    // than the rows it actually draws.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var emptyPanelHeight: CGFloat = 64

    /// The path typed after the `@`, without it.
    let query: String
    /// Owned by the composer, so its directory listings outlive one open panel.
    let search: ComposerFilePathSearch
    /// Answers one query with rows. Sessions lists the workspace folder the
    /// query names; Bot Chats complete the word through `complete.path`.
    let load: (String) async -> Void
    let onSelect: (ComposerFilePathSearch.Match) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if search.matches.isEmpty {
                emptyText
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appSecondary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(search.matches, id: \.id) { match in
                            FilePathRow(match: match, onSelect: onSelect)
                        }
                    }
                }
            }
        }
        .adaptiveGlass(
            .regular,
            fallbackMaterial: .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
        .composerPanelHeight(panelHeight)
        .task(id: LoadKey(query: query, scope: search.scopeRevision)) {
            await load(query)
        }
    }

    /// What one load answers: the query, in the folder a reloading reset last moved the search to.
    private struct LoadKey: Equatable {
        let query: String
        let scope: Int
    }

    /// A listing that failed reads as "nothing matched": the panel is a
    /// shortcut past typing the path, never the only way to name a file.
    @ViewBuilder
    private var emptyText: some View {
        if search.isLoading {
            Text("Searching files…")
        } else {
            Text("No matching files or folders.")
        }
    }

    private var panelHeight: CGFloat {
        guard !search.matches.isEmpty else { return emptyPanelHeight }
        return CGFloat(search.matches.count) * rowHeight
    }
}

/// One file or folder row: the entry's own glyph, its name, and the folder it
/// sits in. A folder ends in a chevron, because picking one goes deeper rather
/// than finishing the reference. The Sessions panel and the Bot `@` panel draw
/// the same row.
struct FilePathRow: View {
    let match: ComposerFilePathSearch.Match
    let onSelect: (ComposerFilePathSearch.Match) -> Void

    var body: some View {
        Button {
            onSelect(match)
        } label: {
            HStack(spacing: 12) {
                icon(for: match)
                    .frame(width: 20)

                Text(match.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.appPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(2)

                if !match.parentPath.isEmpty {
                    Text(match.parentPath)
                        .font(AppFont.caption())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(1)
                }

                Spacer(minLength: 8)

                if match.isDirectory {
                    Image(systemName: "chevron.forward")
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(.appTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: match))
        .accessibilityAddTraits(.isButton)
    }

    /// The same glyphs the file tree draws: a quiet grey folder, or the file's
    /// own type icon.
    @ViewBuilder
    private func icon(for match: ComposerFilePathSearch.Match) -> some View {
        if match.isDirectory {
            Image(systemName: "folder")
                .font(.system(size: 16))
                .foregroundStyle(Color(uiColor: .systemGray))
        } else {
            FileIcon.resolve(match.name).image
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }

    private func accessibilityLabel(for match: ComposerFilePathSearch.Match) -> String {
        let kind = match.isDirectory ? String(localized: "Folder") : String(localized: "File")
        return String(localized: "\(kind), \(match.name)")
    }
}
