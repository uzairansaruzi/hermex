import SwiftUI

struct FilePathAutocompleteView: View {
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .subheadline) private var emptyPanelHeight: CGFloat = 64

    let query: String
    let search: ComposerFilePathSearch
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

    private struct LoadKey: Equatable {
        let query: String
        let scope: Int
    }

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
