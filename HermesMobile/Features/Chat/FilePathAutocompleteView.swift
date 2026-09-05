import SwiftUI

/// The `@` panel: the workspace files and folders that match the path being
/// typed, on the same glass as the `/` panel so the two read as one surface.
struct FilePathAutocompleteView: View {
    // Row height tracks Dynamic Type so the panel is never taller or shorter
    // than the rows it actually draws.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var emptyPanelHeight: CGFloat = 64
    private let maxPanelHeight: CGFloat = 280

    /// The path typed after the `@`, without it.
    let query: String
    let sessionID: String
    let apiClient: APIClient
    /// Owned by the composer, so its directory listings outlive one open panel.
    let search: ComposerFilePathSearch
    let onSelect: (ComposerFilePathSearch.Match) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if search.matches.isEmpty {
                emptyText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(search.matches.enumerated()), id: \.element.id) { index, match in
                            row(match)

                            if index < search.matches.count - 1 {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
        }
        .adaptiveGlass(
            .regular,
            fallbackMaterial: .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
        .frame(height: panelHeight)
        .task(id: query) {
            await search.search(query, sessionID: sessionID, apiClient: apiClient)
        }
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
        return min(maxPanelHeight, CGFloat(search.matches.count) * rowHeight)
    }

    /// One row: the entry's own glyph, its name, and the folder it sits in.
    /// A folder ends in a chevron, because picking one goes deeper rather than
    /// finishing the reference.
    private func row(_ match: ComposerFilePathSearch.Match) -> some View {
        Button {
            onSelect(match)
        } label: {
            HStack(spacing: 12) {
                icon(for: match)
                    .frame(width: 20)

                Text(match.name)
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(2)

                if !match.parentPath.isEmpty {
                    Text(match.parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(1)
                }

                Spacer(minLength: 8)

                if match.isDirectory {
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
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
