import SwiftUI

enum BotAtPanelSection {
    case bots([BotMentions.Completion])
    case files([ComposerFilePathSearch.Match])

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

struct BotAtAutocompleteView: View {
    let botCompletions: [BotMentions.Completion]
    let avatars: [String: UIImage]
    let fileMatches: [ComposerFilePathSearch.Match]
    let isLoadingFiles: Bool
    let onSelectBot: (BotMentions.Completion) -> Void
    let onSelectFile: (ComposerFilePathSearch.Match) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 28

    private var sections: [BotAtPanelSection] {
        BotAtPanelSection.sections(
            botCompletions: botCompletions,
            fileMatches: fileMatches,
            isLoadingFiles: isLoadingFiles
        )
    }

    private var panelHeight: CGFloat {
        var height = CGFloat(sections.count) * headerHeight
        for section in sections {
            switch section {
            case .bots(let completions): height += CGFloat(completions.count) * rowHeight
            case .files(let matches): height += CGFloat(max(1, matches.count)) * rowHeight
            }
        }
        return height
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    switch section {
                    case .bots(let completions): botRows(completions)
                    case .files(let matches): fileRows(matches)
                    }
                }
            }
        }
        .composerPanelHeight(panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .adaptiveGlass(.regular, fallbackMaterial: .ultraThinMaterial,
                       in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityIdentifier("bot-at-autocomplete")
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(AppFont.caption2(weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.appSecondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: headerHeight)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func botRows(_ completions: [BotMentions.Completion]) -> some View {
        header("Bots")
        ForEach(completions, id: \.id) { item in
            BotMentionRow(item: item, avatars: avatars, onSelect: onSelectBot)
        }
    }

    @ViewBuilder
    private func fileRows(_ matches: [ComposerFilePathSearch.Match]) -> some View {
        header("Files")
        if matches.isEmpty {
            Text("Searching files…")
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
        } else {
            ForEach(matches, id: \.id) { match in
                FilePathRow(match: match, onSelect: onSelectFile)
            }
        }
    }
}
