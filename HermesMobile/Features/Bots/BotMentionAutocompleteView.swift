import SwiftUI

/// The slash panel's dense rows and glass surface, with connection-local bots.
struct BotMentionAutocompleteView: View {
    let completions: [BotMentions.Completion]
    let avatars: [String: UIImage]
    let onSelect: (BotMentions.Completion) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48

    @ScaledMetric(relativeTo: .subheadline) private var avatarSize: CGFloat = 24

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(completions.enumerated()), id: \.element.id) { index, item in
                    Button { onSelect(item) } label: {
                        HStack(spacing: 12) {
                            BotAvatarView(profile: item.profile, avatar: avatars[item.id], size: avatarSize, motion: .still)
                                .accessibilityHidden(true)
                            Text(verbatim: "@" + item.tag)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.primary).lineLimit(1).layoutPriority(2)
                            Spacer(minLength: 8)
                            Text(verbatim: item.profile.name)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < completions.count - 1 { Divider().padding(.horizontal, 16) }
                }
            }
        }
        .adaptiveGlass(.regular, fallbackMaterial: .ultraThinMaterial,
                       in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(height: min(280, CGFloat(completions.count) * rowHeight))
    }
}
