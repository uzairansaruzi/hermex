import SwiftUI

/// The slash panel's dense rows and glass surface, with this connection's skills.
///
/// Commands are deliberately absent: the Bot gateway runs those only through
/// `slash.exec`, which Bot Mode does not expose, so a command row would insert
/// text nothing executes. See `BotSlashCatalog`.
struct BotSlashAutocompleteView: View {
    let suggestions: [SkillSlashSuggestion]
    let onSelect: (SkillSlashSuggestion) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, skill in
                    Button { onSelect(skill) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            Text(verbatim: "/" + skill.name)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.primary).lineLimit(1).layoutPriority(2)
                            if let category = skill.category {
                                Text(verbatim: category)
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .lineLimit(1).layoutPriority(1)
                            }
                            Spacer(minLength: 8)
                            Text(verbatim: skill.description ?? String(localized: "Skill"))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < suggestions.count - 1 { Divider().padding(.horizontal, 16) }
                }
            }
        }
        .frame(height: min(280, CGFloat(suggestions.count) * rowHeight))
        // Clip the scrolling content before Liquid Glass composites the surface.
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .adaptiveGlass(.regular, fallbackMaterial: .ultraThinMaterial,
                       in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityIdentifier("bot-slash-autocomplete")
    }
}
