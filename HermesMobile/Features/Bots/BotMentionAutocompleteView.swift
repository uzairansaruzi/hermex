import SwiftUI

struct BotMentionAutocompleteView: View {
    let completions: [BotMentions.Completion]
    let avatars: [String: UIImage]
    var room: BotGroupRoom? = nil
    var roster: [BotProfile] = []
    let onSelect: (BotMentions.Completion) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 48

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(completions, id: \.id) { item in
                    BotMentionRow(item: item, avatars: avatars, room: room, roster: roster, onSelect: onSelect)
                }
            }
        }
        .adaptiveGlass(.regular, fallbackMaterial: .ultraThinMaterial,
                       in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .composerPanelHeight(CGFloat(completions.count) * rowHeight)
    }
}

struct BotMentionRow: View {
    let item: BotMentions.Completion
    let avatars: [String: UIImage]
    var room: BotGroupRoom? = nil
    var roster: [BotProfile] = []
    let onSelect: (BotMentions.Completion) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var avatarSize: CGFloat = 24

    var body: some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 12) {
                avatar
                    .accessibilityHidden(true)
                Text(verbatim: "@" + item.tag)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.appPrimary).lineLimit(1).layoutPriority(2)
                Spacer(minLength: 8)
                Text(verbatim: item.profile.name)
                    .font(AppFont.caption()).foregroundStyle(.appSecondary).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var avatar: some View {
        if let room {
            if let member = room.members.first(where: { $0.id == item.id }) {
                BotRoomMemberAvatar(member: member, roster: roster, avatars: avatars, size: avatarSize)
            } else {
                BotRoomAvatars(room: room, roster: roster, avatars: avatars, size: avatarSize)
            }
        } else {
            BotAvatarView(profile: item.profile, avatar: avatars[item.id], size: avatarSize, motion: .still)
        }
    }
}
