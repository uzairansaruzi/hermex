import SwiftUI

/// What the Bot Chat's one `@` panel draws, in order: this connection's bots,
/// then this conversation's workspace files.
enum BotAtPanelSection {
    case bots([BotMentions.Completion])
    case files([ComposerFilePathSearch.Match])

    /// The sections in drawing order. A group with nothing to show is absent,
    /// so a connection with no roster shows files alone and a failed or empty
    /// file lookup leaves the Bots section standing. A lookup still in flight
    /// shows the Files section with no rows yet.
    static func sections(
        botCompletions: [BotMentions.Completion],
        fileMatches: [ComposerFilePathSearch.Match],
        isLoadingFiles: Bool
    ) -> [BotAtPanelSection] {
        var sections: [BotAtPanelSection] = []
        if !botCompletions.isEmpty { sections.append(.bots(botCompletions)) }
        if isLoadingFiles || !fileMatches.isEmpty { sections.append(.files(fileMatches)) }
        return sections
    }
}

/// The Bot Chat's `@` panel: roster rows above workspace file rows, on the
/// slash panel's glass. Section headers are the only chrome.
///
/// Rooms use `BotMentionAutocompleteView` directly and never reach this panel,
/// so their mentions stay members-only.
struct BotAtAutocompleteView: View {
    let botCompletions: [BotMentions.Completion]
    let avatars: [String: UIImage]
    let fileMatches: [ComposerFilePathSearch.Match]
    let isLoadingFiles: Bool
    let onSelectBot: (BotMentions.Completion) -> Void
    let onSelectFile: (ComposerFilePathSearch.Match) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 28
    private let maxPanelHeight: CGFloat = 280

    private var sections: [BotAtPanelSection] {
        BotAtPanelSection.sections(
            botCompletions: botCompletions,
            fileMatches: fileMatches,
            isLoadingFiles: isLoadingFiles
        )
    }

    /// Tracks Dynamic Type and the rows actually drawn, like the two panels it
    /// combines. The loading row counts as the file group's one row.
    private var panelHeight: CGFloat {
        var height = CGFloat(sections.count) * headerHeight
        for section in sections {
            switch section {
            case .bots(let completions): height += CGFloat(completions.count) * rowHeight
            case .files(let matches): height += CGFloat(max(1, matches.count)) * rowHeight
            }
        }
        return min(maxPanelHeight, height)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 { Divider().padding(.horizontal, 16) }
                    switch section {
                    case .bots(let completions): botRows(completions)
                    case .files(let matches): fileRows(matches)
                    }
                }
            }
        }
        .frame(height: panelHeight)
        // Clip the scrolling content before Liquid Glass composites the surface.
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .adaptiveGlass(.regular, fallbackMaterial: .ultraThinMaterial,
                       in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityIdentifier("bot-at-autocomplete")
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: headerHeight)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func botRows(_ completions: [BotMentions.Completion]) -> some View {
        header("Bots")
        ForEach(Array(completions.enumerated()), id: \.element.id) { index, item in
            BotMentionRow(item: item, avatars: avatars, onSelect: onSelectBot)
            if index < completions.count - 1 { Divider().padding(.horizontal, 16) }
        }
    }

    @ViewBuilder
    private func fileRows(_ matches: [ComposerFilePathSearch.Match]) -> some View {
        header("Files")
        if matches.isEmpty {
            Text("Searching files…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
        } else {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                FilePathRow(match: match, onSelect: onSelectFile)
                if index < matches.count - 1 { Divider().padding(.horizontal, 16) }
            }
        }
    }
}
